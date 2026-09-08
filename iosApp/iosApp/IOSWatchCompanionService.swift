import Foundation
import Observation
@preconcurrency import Shared

/// The iPhone-owned, lightweight store for Watch content.
///
/// Notes deliberately live outside the conversation and memory stores. A note
/// is an inbox item written by the user, so receiving it must not create a chat
/// turn or trigger memory extraction. The small receipt ledger makes a replay
/// of the same Watch request safe after a process restart.
@MainActor
@Observable
final class IOSWatchCompanionService {
    static let shared = IOSWatchCompanionService()

    static let maxQuickActions = 4
    static let maxRecentConversations = 10
    static let maxRecentActivities = 20
    static let maxNotes = 500
    static let maxReceipts = 128

    private struct Receipt: Codable {
        let request: WatchTaskActionRequest
        let runId: String
        let accepted: Bool
        let message: String?
        let conversationId: String?
        let deliveryUnknown: Bool?
        let pending: Bool

        init(request: WatchTaskActionRequest, result: WatchTaskActionResult, pending: Bool = false) {
            self.request = request
            self.runId = result.runId
            self.accepted = result.accepted
            self.message = result.message
            self.conversationId = result.conversationId
            self.deliveryUnknown = result.deliveryUnknown
            self.pending = pending
        }

        private enum CodingKeys: String, CodingKey {
            case request, runId, accepted, message, conversationId, deliveryUnknown, pending
            case legacyResult = "result"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let request = try container.decode(WatchTaskActionRequest.self, forKey: .request)
            let legacy = try container.decodeIfPresent(WatchTaskActionResult.self, forKey: .legacyResult)
            self.request = request
            self.runId = try container.decodeIfPresent(String.self, forKey: .runId)
                ?? legacy?.runId
                ?? request.runId
            self.accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted)
                ?? legacy?.accepted
                ?? false
            self.message = try container.decodeIfPresent(String.self, forKey: .message)
                ?? legacy?.message
            self.conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
                ?? legacy?.conversationId
            self.deliveryUnknown = try container.decodeIfPresent(Bool.self, forKey: .deliveryUnknown)
                ?? legacy?.deliveryUnknown
            self.pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(request, forKey: .request)
            try container.encode(runId, forKey: .runId)
            try container.encode(accepted, forKey: .accepted)
            try container.encodeIfPresent(message, forKey: .message)
            try container.encodeIfPresent(conversationId, forKey: .conversationId)
            try container.encodeIfPresent(deliveryUnknown, forKey: .deliveryUnknown)
            try container.encode(pending, forKey: .pending)
        }

        var result: WatchTaskActionResult {
            WatchTaskActionResult(
                requestId: request.requestId,
                runId: runId,
                accepted: accepted,
                message: message,
                snapshot: nil,
                conversationId: conversationId,
                deliveryUnknown: deliveryUnknown
            )
        }
    }

    private let fileManager: FileManager
    private let notesURL: URL
    private let receiptsURL: URL
    private let activitiesURL: URL
    private let defaults: UserDefaults
    private let selectedQuickActionIDsKey = "app.amber.ios.watch.selectedQuickActionIDs"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) var notes: [WatchNote] = []
    /// Terminal task history. Notes remain in `notes` and are projected as
    /// `kind == "note"` activities without competing for this task window.
    private(set) var recentActivities: [WatchRecentActivity] = []
    private(set) var selectedQuickActionIDs: [String] = []
    private(set) var hasConfiguredQuickActionSelection = false
    private(set) var storageError: String?
    private var receipts: [String: Receipt] = [:]
    private var receiptOrder: [String] = []
    private var notesStorageInvalid = false
    private var receiptsStorageInvalid = false
    private var activitiesStorageInvalid = false
    private var conversationTitlesByID: [String: String] = [:]

    /// JSONEncoder's ISO-8601 strategy stores whole seconds on iOS. Keep the
    /// request payload checks strict while allowing that serialization loss in
    /// the durable createdAt field.
    static func receiptRequestsMatch(
        _ lhs: WatchTaskActionRequest,
        _ rhs: WatchTaskActionRequest
    ) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.runId == rhs.runId
            && lhs.conversationId == rhs.conversationId
            && lhs.decisionId == rhs.decisionId
            && lhs.action == rhs.action
            && lhs.optionId == rhs.optionId
            && lhs.text == rhs.text
            && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) <= 1
    }

    init(
        baseDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            root = applicationSupport.appendingPathComponent("AmberAgent/Watch", isDirectory: true)
        }
        self.notesURL = root.appendingPathComponent("notes.json")
        self.receiptsURL = root.appendingPathComponent("action-receipts.json")
        self.activitiesURL = root.appendingPathComponent("activities.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    // MARK: - Notes

    /// Stores a note exactly once. A matching id with different text is
    /// rejected so a request id can never be silently reused for new content.
    @discardableResult
    func saveNote(_ note: WatchNote) -> Bool {
        // Keep the original text. Validation trims only for emptiness so a
        // note received offline is never acknowledged with altered content.
        guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.text.count <= 2_000 else { return false }
        guard let existingIndex = notes.firstIndex(where: { $0.id == note.id }) else {
            // Reject at capacity so the Watch still owns the unsaved note.
            guard notes.count < Self.maxNotes else { return false }
            var candidate = notes
            candidate.insert(note, at: 0)
            guard persistNotes(candidate) else { return false }
            notes = candidate
            return true
        }

        guard notes[existingIndex].text == note.text else { return false }
        // A repeated delivery may arrive without a sync timestamp. Preserve a
        // durable timestamp once one has been assigned.
        if notes[existingIndex].syncedAt == nil, let syncedAt = note.syncedAt {
            var candidate = notes
            candidate[existingIndex].syncedAt = syncedAt
            guard persistNotes(candidate) else { return false }
            notes = candidate
        }
        return true
    }

    @discardableResult
    func markNoteSynced(id: String, at date: Date = Date()) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        guard notes[index].syncedAt == nil else { return true }
        var candidate = notes
        candidate[index].syncedAt = date
        guard persistNotes(candidate) else { return false }
        notes = candidate
        return true
    }

    @discardableResult
    func deleteNote(id: String) -> Bool {
        guard notes.contains(where: { $0.id == id }) else { return false }
        let candidate = notes.filter { $0.id != id }
        guard persistNotes(candidate) else { return false }
        notes = candidate
        return true
    }

    // MARK: - Recent activities

    /// Records one real terminal run. The run id, rather than a caller's
    /// presentation timestamp, is the durable identity: repeated publishes
    /// keep the first terminal content and completion time stable, except
    /// when a previously failed save later produces a confirmed completion.
    @discardableResult
    func recordTerminalActivity(_ activity: WatchRecentActivity) -> Bool {
        guard let normalized = normalizedTerminalActivity(activity) else { return false }
        return restoreTerminalActivities([normalized])
    }

    /// Older builds recorded an unknown tool outcome as failure. Once the
    /// durable recovery path identifies that run, remove only that false
    /// failure; confirmed completions and cancellations remain untouched.
    @discardableResult
    func discardFailedActivityForUnresolvedRun(_ runId: String) -> Bool {
        let candidate = recentActivities.filter {
            !($0.phase == "failed" && $0.runId?.caseInsensitiveCompare(runId) == .orderedSame)
        }
        guard candidate != recentActivities else { return false }
        return commitTerminalActivities(candidate)
    }

    /// Imports terminal rows recovered from the durable run ledger. Recovery
    /// only contributes rows explicitly marked completed/failed/cancelled;
    /// running or recoverable rows never become fabricated history.
    @discardableResult
    func restoreTerminalActivities(_ activities: [WatchRecentActivity]) -> Bool {
        // If a recovery source contains more than one row for a run, prefer
        // its newest terminal state before de-duplicating. Existing live
        // history is kept as-is within a terminal phase. A confirmed completed
        // row can replace a failure emitted while saving was recoveryPending.
        // Completed and cancelled outcomes never regress to a later callback.
        let normalized = activities
            .compactMap(normalizedTerminalActivity)
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
        guard !normalized.isEmpty else { return true }

        var candidate = recentActivities
        for activity in normalized {
            if let index = candidate.firstIndex(where: {
                $0.runId?.lowercased() == activity.runId?.lowercased()
                    || $0.id.caseInsensitiveCompare(activity.id) == .orderedSame
            }) {
                if candidate[index].phase == "failed", activity.phase == "completed" {
                    candidate[index] = activity
                }
            } else {
                candidate.append(activity)
            }
        }
        guard candidate != recentActivities else { return true }
        return commitTerminalActivities(candidate)
    }

    /// Best effort title cache populated from the same conversation summaries
    /// used by the library. It is deliberately not a second title store.
    func conversationTitle(for conversationID: String) -> String? {
        conversationTitlesByID[conversationID.lowercased()]
    }

    private func normalizedTerminalActivity(_ activity: WatchRecentActivity) -> WatchRecentActivity? {
        guard let runId = activity.runId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runId.isEmpty,
              Self.terminalActivityPhases.contains(activity.phase) else { return nil }
        var normalized = activity
        normalized.runId = runId
        normalized.id = "run:\(runId)"
        normalized.title = activity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.title.isEmpty { normalized.title = "Amber 任务" }
        normalized.summary = activity.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private func commitTerminalActivities(_ values: [WatchRecentActivity]) -> Bool {
        var deduplicated: [WatchRecentActivity] = []
        var seenRuns = Set<String>()
        for activity in values {
            guard let runId = activity.runId?.lowercased(),
                  !seenRuns.contains(runId) else { continue }
            seenRuns.insert(runId)
            deduplicated.append(activity)
        }
        deduplicated.sort {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        let candidate = Array(deduplicated.prefix(Self.maxRecentActivities))
        guard persistActivities(candidate) else { return false }
        recentActivities = candidate
        return true
    }

    private static let terminalActivityPhases: Set<String> = [
        "completed", "failed", "cancelled"
    ]

    private func noteActivity(_ note: WatchNote) -> WatchRecentActivity {
        let firstLine = note.text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WatchRecentActivity(
            id: "note:\(note.id)",
            runId: nil,
            conversationId: nil,
            kind: "note",
            phase: "saved",
            title: WatchTaskText.singleLine(firstLine, maxLength: 80) ?? "Watch 记事",
            summary: WatchTaskText.clipped(note.text, maxLength: 280) ?? "",
            updatedAt: note.createdAt
        )
    }

    // MARK: - Quick actions

    /// Edit the existing settings collection so Watch, Siri and phone share
    /// the same stable message identity; do not create a second prompt store.
    @discardableResult
    func saveQuickAction(id: String? = nil, title: String, prompt: String,
                         sharedSettings: IOSSharedSettingsStore) -> WatchQuickAction? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 40, WatchQuickAction.supports(prompt: prompt) else { return nil }
        let id = id ?? UUID().uuidString.lowercased()
        guard updateQuickMessages(sharedSettings: sharedSettings, transform: { messages in
            messages.removeAll { ($0["id"] as? String)?.lowercased() == id.lowercased() }
            messages.append(["id": id, "title": title, "content": prompt])
        }) else { return nil }
        return WatchQuickAction(id: id, title: title, prompt: prompt)
    }

    @discardableResult
    func deleteQuickAction(id: String, sharedSettings: IOSSharedSettingsStore) -> Bool {
        let selectedIDs = hasConfiguredQuickActionSelection ? selectedQuickActionIDs
            : sharedSettings.snapshot.quickMessages.filter { WatchQuickAction.supports(prompt: $0.content) }
                .prefix(Self.maxQuickActions).map { $0.id.toHexDashString() }
        guard updateQuickMessages(sharedSettings: sharedSettings, transform: { messages in
            messages.removeAll { ($0["id"] as? String)?.lowercased() == id.lowercased() }
        }) else { return false }
        setSelectedQuickActionIDs(selectedIDs.filter { $0.lowercased() != id.lowercased() })
        return true
    }

    private func updateQuickMessages(sharedSettings: IOSSharedSettingsStore,
                                    transform: (inout [[String: Any]]) -> Void) -> Bool {
        do {
            let json = IosSettingsJsonBridge.shared.encode(settings: sharedSettings.snapshot)
            guard var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
            var messages = object["quickMessages"] as? [[String: Any]] ?? []
            transform(&messages)
            object["quickMessages"] = messages
            let data = try JSONSerialization.data(withJSONObject: object)
            let settings = try IosSettingsJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
            sharedSettings.restoreSnapshot(settings)
            return true
        } catch { return false }
    }

    func setSelectedQuickActionIDs(_ ids: [String]) {
        var seen = Set<String>()
        let candidate = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.maxQuickActions)
            .map { $0 }
        selectedQuickActionIDs = candidate
        hasConfiguredQuickActionSelection = true
        defaults.set(candidate, forKey: selectedQuickActionIDsKey)
    }

    func toggleQuickAction(id: String, enabled: Bool) {
        var ids = selectedQuickActionIDs.filter { $0 != id }
        if enabled { ids.append(id) }
        setSelectedQuickActionIDs(ids)
    }

    /// Converts the current iPhone settings and conversation summaries into
    /// the small library projection sent to Watch. The source prompt is only
    /// included for the selected quick actions; no credentials are projected.
    func makeLibrarySnapshot(
        sharedSettings: IOSSharedSettingsStore,
        conversationStore: IOSConversationStore?,
        configurationMessage: String? = nil,
        now: Date = Date()
    ) async -> WatchLibrarySnapshot {
        let settings = sharedSettings.snapshot
        let assistant = settings.getCurrentAssistant()
        let assistantName = assistant.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Amber"
            : assistant.name

        let available = settings.quickMessages
            .compactMap { quickMessage -> WatchQuickAction? in
                let id = quickMessage.id.toHexDashString()
                let title = quickMessage.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = quickMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !title.isEmpty, WatchQuickAction.supports(prompt: prompt) else { return nil }
                return WatchQuickAction(id: id, title: title, prompt: prompt)
            }
        let availableByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id.lowercased(), $0) })
        let configuredIDs = selectedQuickActionIDs.compactMap {
            availableByID[$0.lowercased()]?.id
        }
        let ids = !hasConfiguredQuickActionSelection
            ? available.prefix(Self.maxQuickActions).map(\.id)
            : Array(configuredIDs.prefix(Self.maxQuickActions))
        let quickActions = ids.compactMap { availableByID[$0.lowercased()] }

        var recent: [WatchRecentConversation] = []
        let summaries = await conversationStore?.appIntentSummaries(limit: Self.maxRecentConversations) ?? []
        for summary in summaries.prefix(Self.maxRecentConversations) {
            guard let conversationStore else { break }
            let conversationID = summary.id.toHexDashString()
            let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "新对话" : WatchTaskText.singleLine(title, maxLength: 60) ?? "新对话"
            conversationTitlesByID[conversationID.lowercased()] = displayTitle
            let messages = await conversationStore.messages(for: summary.id) ?? []
            let preview = messages.reversed().compactMap { message -> String? in
                guard message.role == MessageRole.user || message.role == MessageRole.assistant else {
                    return nil
                }
                let text = message.toText().trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : WatchTaskText.singleLine(text, maxLength: 120)
            }.first ?? ""
            recent.append(WatchRecentConversation(
                id: conversationID,
                title: displayTitle,
                preview: preview,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(summary.updateAt.toEpochMilliseconds()) / 1_000),
                runId: nil
            ))
        }

        var projectedActivities = recentActivities + notes.map(noteActivity)
        projectedActivities = projectedActivities.map { activity in
            // Preserve a producer-owned result title (for example an exact
            // persisted MiniApp name). Conversation titles are only the
            // fallback for ordinary activities and older rows.
            if let resultTitle = activity.resultTitle,
               !resultTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return activity
            }
            guard let conversationID = activity.conversationId,
                  let title = conversationTitlesByID[conversationID.lowercased()] else {
                return activity
            }
            var titled = activity
            titled.title = title
            return titled
        }
        projectedActivities.sort {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
        let activities = Array(projectedActivities.prefix(Self.maxRecentConversations))

        return WatchLibrarySnapshot(
            assistantName: assistantName,
            isConfigured: configurationMessage == nil,
            configurationMessage: configurationMessage,
            quickActions: quickActions,
            recent: recent,
            activities: activities.isEmpty ? nil : activities,
            updatedAt: now
        )
    }

    // MARK: - Durable request receipts

    func receipt(for requestId: String) -> (request: WatchTaskActionRequest, result: WatchTaskActionResult)? {
        guard let receipt = receipts[requestId] else { return nil }
        return (receipt.request, receipt.result)
    }

    /// Claims a side-effecting Watch request before starting it. A pending
    /// claim survives a process kill as `deliveryUnknown`, so a replay never
    /// starts a second model run.
    @discardableResult
    func claimReceipt(request: WatchTaskActionRequest) -> Bool {
        guard receipts[request.requestId] == nil else { return false }
        let pendingResult = WatchTaskActionResult(
            requestId: request.requestId,
            runId: request.runId,
            accepted: false,
            message: "请求已接收，结果待核实，请在 iPhone 查看",
            snapshot: nil,
            conversationId: request.conversationId,
            deliveryUnknown: true
        )
        let receipt = Receipt(request: request, result: pendingResult, pending: true)
        var candidateReceipts = receipts
        var candidateOrder = receiptOrder
        candidateReceipts[request.requestId] = receipt
        candidateOrder.append(request.requestId)
        while candidateOrder.count > Self.maxReceipts {
            guard let removableIndex = candidateOrder.firstIndex(where: {
                candidateReceipts[$0]?.pending != true
            }) else {
                return false
            }
            let expired = candidateOrder.remove(at: removableIndex)
            candidateReceipts.removeValue(forKey: expired)
        }
        guard persistReceipts(candidateReceipts, order: candidateOrder) else { return false }
        receipts = candidateReceipts
        receiptOrder = candidateOrder
        return true
    }

    @discardableResult
    func recordReceipt(request: WatchTaskActionRequest, result: WatchTaskActionResult) -> Bool {
        if let existing = receipts[request.requestId] {
            guard Self.receiptRequestsMatch(existing.request, request) else { return false }
            guard existing.pending
                    || (request.action == .saveNote && !existing.accepted) else { return true }
            var candidateReceipts = receipts
            candidateReceipts[request.requestId] = Receipt(request: request, result: result)
            guard persistReceipts(candidateReceipts, order: receiptOrder) else { return false }
            receipts = candidateReceipts
            return true
        }
        let receipt = Receipt(request: request, result: result)
        var candidateReceipts = receipts
        var candidateOrder = receiptOrder
        candidateReceipts[request.requestId] = receipt
        candidateOrder.append(request.requestId)
        while candidateOrder.count > Self.maxReceipts {
            guard let removableIndex = candidateOrder.firstIndex(where: {
                candidateReceipts[$0]?.pending != true
            }) else {
                return false
            }
            let expired = candidateOrder.remove(at: removableIndex)
            candidateReceipts.removeValue(forKey: expired)
        }
        guard persistReceipts(candidateReceipts, order: candidateOrder) else { return false }
        receipts = candidateReceipts
        receiptOrder = candidateOrder
        return true
    }

    // MARK: - Persistence

    private func load() {
        if let object = defaults.object(forKey: selectedQuickActionIDsKey) {
            hasConfiguredQuickActionSelection = true
            selectedQuickActionIDs = (object as? [String]) ?? []
        }
        if fileManager.fileExists(atPath: notesURL.path) {
            do {
                notes = try decoder.decode([WatchNote].self, from: Data(contentsOf: notesURL))
            } catch {
                notesStorageInvalid = true
                setStorageError("Watch 记事存储损坏，已停止覆盖原文件")
            }
        }
        if fileManager.fileExists(atPath: activitiesURL.path) {
            do {
                let decoded = try decoder.decode([WatchRecentActivity].self, from: Data(contentsOf: activitiesURL))
                var deduplicated: [WatchRecentActivity] = []
                var seenRuns = Set<String>()
                for activity in decoded {
                    guard let normalized = normalizedTerminalActivity(activity),
                          let runId = normalized.runId?.lowercased(),
                          !seenRuns.contains(runId) else { continue }
                    seenRuns.insert(runId)
                    deduplicated.append(normalized)
                }
                recentActivities = Array(deduplicated.sorted {
                    if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                    return $0.updatedAt > $1.updatedAt
                }.prefix(Self.maxRecentActivities))
            } catch {
                activitiesStorageInvalid = true
                setStorageError("Watch 活动历史存储损坏，已停止覆盖原文件")
            }
        }
        if fileManager.fileExists(atPath: receiptsURL.path) {
            do {
                let decoded = try decoder.decode([Receipt].self, from: Data(contentsOf: receiptsURL))
                // Keep pending claims even if an older file grew past the
                // normal window. New writes evict only completed entries;
                // silently taking a suffix here could make a recent claim
                // replayable after a process restart.
                for receipt in decoded {
                    receiptOrder.removeAll { $0 == receipt.request.requestId }
                    receipts[receipt.request.requestId] = receipt
                    receiptOrder.append(receipt.request.requestId)
                }
            } catch {
                receiptsStorageInvalid = true
                setStorageError("Watch 操作回执存储损坏，已停止覆盖原文件")
            }
        }
    }

    private func setStorageError(_ message: String) {
        if storageError == nil {
            storageError = message
        }
    }

    @discardableResult
    private func persistNotes(_ candidate: [WatchNote]) -> Bool {
        guard !notesStorageInvalid else { return false }
        return persist(candidate, to: notesURL)
    }

    @discardableResult
    private func persistActivities(_ candidate: [WatchRecentActivity]) -> Bool {
        guard !activitiesStorageInvalid else { return false }
        return persist(candidate, to: activitiesURL)
    }

    @discardableResult
    private func persistReceipts(
        _ candidate: [String: Receipt],
        order: [String]
    ) -> Bool {
        guard !receiptsStorageInvalid else { return false }
        let ordered = order.compactMap { candidate[$0] }
        return persist(ordered, to: receiptsURL)
    }

    @discardableResult
    private func persist<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            setStorageError(IOSAppLocalization.string("Watch 数据无法保存", defaultValue: "Watch 数据无法保存") + ": " + error.localizedDescription)
            return false
        }
    }
}
