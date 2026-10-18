import Foundation
import Observation
@preconcurrency import Shared

/// Live transcript of a `model_council_run` tool call, observed by
/// `ChatToolDetailSheet`. The tool path feeds it the same room events the
/// Council room view consumes, so the chat capsule is no longer a black box.
///
/// `messages` only changes on append; each message observes its own body and
/// status, so a streaming beat re-renders just the speaking row. Streaming
/// beats are coalesced into one commit per `streamingFlushInterval` (the room
/// view keeps its own per-beat typing cadence); terminal updates apply at once.
@MainActor
@Observable
final class CouncilLiveModel {
    private(set) var taskId: String?
    private(set) var state: String?
    private(set) var speakers: [IOSCouncilRoomSpeaker] = []
    private(set) var activeSpeakerId: String?
    private(set) var failedSpeakerIds: Set<String> = []
    private(set) var messages: [CouncilLiveMessage] = []
    private(set) var isRunning = true

    @ObservationIgnored private let streamingFlushInterval: Duration
    @ObservationIgnored private var pendingBodies: [UUID: String] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(streamingFlushInterval: Duration = .milliseconds(100)) {
        self.streamingFlushInterval = streamingFlushInterval
    }

    func ingest(_ event: IOSCouncilRoomEvent) {
        switch event {
        case .taskStarted(let id):
            taskId = id
        case .state(let value):
            state = value
        case .roster(let roster, let activeId, let failedIds):
            speakers = roster
            activeSpeakerId = activeId
            failedSpeakerIds = failedIds
        case .append(let message):
            messages.append(CouncilLiveMessage(message))
        case .updateMessage(let id, let body, let status, _):
            guard let message = messages.last(where: { $0.id == id }) else { return }
            if status == .speaking {
                pendingBodies[id] = body
                scheduleFlush()
            } else {
                pendingBodies[id] = nil
                message.update(body: body, status: status)
            }
        }
    }

    /// The runner's error exit (e.g. a thrown host synthesis) appends a system
    /// failure without closing the in-flight message; close it here, the same
    /// way the Council room's `finishStreamingMessages` does.
    func finish(completed: Bool) {
        flushPendingBodies()
        isRunning = false
        activeSpeakerId = nil
        for message in messages where message.status == .speaking {
            message.update(status: completed ? .completed : .failed)
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, streamingFlushInterval] in
            try? await Task.sleep(for: streamingFlushInterval)
            self?.flushPendingBodies()
        }
    }

    private func flushPendingBodies() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingBodies.isEmpty else { return }
        let pending = pendingBodies
        pendingBodies = [:]
        for message in messages {
            if let body = pending[message.id] { message.update(body: body) }
        }
    }
}

/// One live council message; observed per row by `ChatToolDetailSheet`.
@MainActor
@Observable
final class CouncilLiveMessage: Identifiable {
    let id: UUID
    let kind: IOSCouncilRoomMessageKind
    let author: String
    let subtitle: String?
    private(set) var body: String
    private(set) var status: IOSCouncilRoomMessageStatus

    init(_ event: IOSCouncilRoomMessageEvent) {
        id = event.id
        kind = event.kind
        author = event.author
        subtitle = event.subtitle
        body = event.body
        status = event.status
    }

    fileprivate func update(body: String? = nil, status: IOSCouncilRoomMessageStatus? = nil) {
        if let body, body != self.body { self.body = body }
        if let status, status != self.status { self.status = status }
    }
}

/// Links a `model_council_run` tool call to its live model (same shape as
/// `SubAgentLiveRegistry`), bounded with FIFO eviction. Observable so a detail
/// sheet opened before approval picks up the model once the run registers it.
@MainActor
@Observable
final class CouncilLiveRegistry {
    static let shared = CouncilLiveRegistry()

    private var models: [String: CouncilLiveModel] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private let capacity = 16

    func register(toolCallId: String, _ model: CouncilLiveModel) {
        guard !toolCallId.isEmpty else { return }
        if models[toolCallId] == nil {
            order.append(toolCallId)
        }
        models[toolCallId] = model
        while order.count > capacity {
            models.removeValue(forKey: order.removeFirst())
        }
    }

    /// Some providers reuse short tool-call ids ("call_1"); when the finished
    /// tool output names its task, a live model from another task is rejected.
    func model(forToolCallId id: String, taskId: String?) -> CouncilLiveModel? {
        guard let model = models[id] else { return nil }
        guard let taskId, let liveTaskId = model.taskId else { return model }
        return liveTaskId == taskId ? model : nil
    }
}

/// Chat-tool entry point for the iOS Council Room. Formal runs use
/// `IOSCouncilRoomRunner` so iOS can stream the host and seats as a real room
/// without pretending to support cross-provider model mixing.
@MainActor
@Observable
final class CouncilRunner {
    @ObservationIgnored private let taskStore: IOSAdvancedTaskStore
    @ObservationIgnored private let roomSettingsStore: IOSCouncilRoomSettingsStore
    @ObservationIgnored private let roomStreamer: any IOSCouncilTextStreaming

    var lastRunResult: String = "(未运行)"
    var isRunning: Bool = false
    var lastTask: IOSAdvancedTaskRecord?

    init(
        taskStore: IOSAdvancedTaskStore = .shared,
        roomSettingsStore: IOSCouncilRoomSettingsStore = .shared,
        roomStreamer: any IOSCouncilTextStreaming = IOSCouncilTextStreamer()
    ) {
        self.taskStore = taskStore
        self.roomSettingsStore = roomSettingsStore
        self.roomStreamer = roomStreamer
    }

    var recentTasks: [IOSAdvancedTaskRecord] {
        taskStore.recent(kind: .modelCouncil, limit: 5)
    }

    /// Run an input-driven Council Room cycle for the chat-tool dispatch path.
    /// Failures return an honest JSON status — never empty/fabricated success.
    func run(
        objective: String,
        seats: [IOSCouncilSeatDescriptor] = [],
        maxSeats: Int? = nil,
        outputBudgetChars: Int? = nil,
        providerSetting: ProviderSetting,
        currentModel: Model,
        baseParams: TextGenerationParams,
        toolCallId: String? = nil
    ) async -> String {
        let currentModelId = currentModel.modelId
        var roomSettings = roomSettingsStore.settings.normalized(currentModelId: currentModelId)
        let seatLimit = max(2, min(maxSeats ?? roomSettings.limits.maxSeats, 8))
        if !seats.isEmpty {
            roomSettings.seats = Array(seats.filter { $0.id != "host" }.prefix(seatLimit)).map {
                IOSCouncilRoomSeatConfig(
                    id: $0.id,
                    name: $0.name,
                    rolePrompt: $0.role,
                    modelId: $0.modelLabel == "当前模型" ? currentModelId : $0.modelLabel,
                    reasoning: .off,
                    prompt: "",
                    isDefault: true
                )
            }
        }
        roomSettings.limits.maxSeats = seatLimit
        if let outputBudgetChars {
            roomSettings.limits.outputBudgetCharacters = outputBudgetChars
        }
        roomSettings = roomSettings.normalized(currentModelId: currentModelId)
        isRunning = true
        defer { isRunning = false }

        let request = IOSCouncilRoomRunRequest(
            objective: objective,
            mode: .freeChat,
            settings: roomSettings,
            currentModelId: currentModelId,
            currentModel: currentModel,
            baseParams: baseParams,
            providerSetting: providerSetting,
            providerSettings: [providerSetting],
            searchSettings: nil,
            researchConsent: .unavailable,
            dynamicSeatGeneration: seats.isEmpty ? roomSettingsStore.dynamicSeatGeneration : false
        )
        let roomRunner = IOSCouncilRoomRunner(streamer: roomStreamer, taskStore: taskStore)
        let live = CouncilLiveModel()
        if let toolCallId {
            CouncilLiveRegistry.shared.register(toolCallId: toolCallId, live)
        }
        let outcome = await roomRunner.run(request: request) { live.ingest($0) }
        live.finish(completed: outcome.status == .completed)
        lastTask = taskStore.tasks.first { $0.id == outcome.taskId }
        let runSummary = outcome.status == .completed
            ? "模型议会已完成，席位：\(outcome.seatNames.joined(separator: ", "))。"
            : "模型议会未完成：\(outcome.status.title)。"
        lastRunResult = "\(runSummary) taskId: \(outcome.taskId)，provider: \(providerSetting.name)。"
        var result: [String: Any] = [
            "ok": outcome.status == .completed,
            "task_id": outcome.taskId,
            "kind": IOSAdvancedTaskKind.modelCouncil.rawValue,
            "run_id": outcome.taskId,
            "status": outcome.status.rawValue,
            "mode": IOSCouncilRoomRunMode.freeChat.rawValue,
            "seat_count": outcome.seatNames.count,
            "seats": outcome.seatNames,
            "failed_seats": outcome.failedSeats,
            "budget_chars": roomSettings.limits.outputBudgetCharacters,
            "summary": lastRunResult
        ]
        if outcome.status == .completed {
            result["final_answer"] = outcome.finalAnswer
        } else {
            result["reason"] = outcome.failureReason ?? outcome.status.title
        }
        return Self.json(result)
    }

    private static func defaultSeatDescriptors() -> [IOSCouncilSeatDescriptor] {
        [
            IOSCouncilSeatDescriptor(id: "host", name: "Host", role: "主持、串联、综合", modelLabel: "当前模型"),
            IOSCouncilSeatDescriptor(id: "risk", name: "Risk", role: "风险与失败模式", modelLabel: "当前模型"),
            IOSCouncilSeatDescriptor(id: "opponent", name: "Opponent", role: "反方质询", modelLabel: "当前模型")
        ]
    }

    #if DEBUG
    /// Test accessor for the default seat roster.
    static func defaultSeatDescriptorsForTesting() -> [IOSCouncilSeatDescriptor] {
        defaultSeatDescriptors()
    }
    #endif

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }
}
