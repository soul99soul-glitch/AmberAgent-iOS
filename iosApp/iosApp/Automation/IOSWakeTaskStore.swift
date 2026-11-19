import Foundation
import Observation

struct IOSWakeOrigin: Codable, Equatable, Sendable {
    let userMessageID: String
    let userText: String
}

struct IOSWakeTask: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case scheduled, running, completed, failed, cancelled, interrupted

        var title: String {
            switch self {
            case .scheduled: "等待触发"
            case .running: "正在执行"
            case .completed: "已完成"
            case .failed: "执行失败"
            case .cancelled: "已取消"
            case .interrupted: "执行中断，等待处理"
            }
        }
    }

    let id: String
    let requestID: String
    let conversationID: String
    let sourceRunID: String
    let origin: IOSWakeOrigin
    let title: String
    let prompt: String
    let createdAt: Date
    var fireAt: Date?
    let event: String?
    let requiresForeground: Bool
    var intervalMinutes: Int? = nil
    var watchCondition: String? = nil
    var stopWhenTriggered: Bool = true
    var checkCount: Int = 0
    var lastCheckedAt: Date? = nil
    var lastCheckSummary: String? = nil
    var eventReceivedAt: Date?
    var eventContent: String?
    var reminderRequestedAt: Date?
    var status: Status = .scheduled
    var executionRunID: String?
    var startedAt: Date?
    var finishedAt: Date?
    var lastMessage: String?
    var resultText: String?
    var attemptNumber: Int?

    var isRecurringWatch: Bool {
        if let intervalMinutes, intervalMinutes > 0 { return true }
        return false
    }

    init(
        id: String,
        requestID: String,
        conversationID: String,
        sourceRunID: String,
        origin: IOSWakeOrigin,
        title: String,
        prompt: String,
        createdAt: Date,
        fireAt: Date?,
        event: String?,
        requiresForeground: Bool,
        intervalMinutes: Int? = nil,
        watchCondition: String? = nil,
        stopWhenTriggered: Bool = true,
        checkCount: Int = 0,
        lastCheckedAt: Date? = nil,
        lastCheckSummary: String? = nil,
        eventReceivedAt: Date? = nil,
        eventContent: String? = nil,
        reminderRequestedAt: Date? = nil,
        status: Status = .scheduled,
        executionRunID: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastMessage: String? = nil,
        resultText: String? = nil,
        attemptNumber: Int? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.conversationID = conversationID
        self.sourceRunID = sourceRunID
        self.origin = origin
        self.title = title
        self.prompt = prompt
        self.createdAt = createdAt
        self.fireAt = fireAt
        self.event = event
        self.requiresForeground = requiresForeground
        self.intervalMinutes = intervalMinutes
        self.watchCondition = watchCondition
        self.stopWhenTriggered = stopWhenTriggered
        self.checkCount = checkCount
        self.lastCheckedAt = lastCheckedAt
        self.lastCheckSummary = lastCheckSummary
        self.eventReceivedAt = eventReceivedAt
        self.eventContent = eventContent
        self.reminderRequestedAt = reminderRequestedAt
        self.status = status
        self.executionRunID = executionRunID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastMessage = lastMessage
        self.resultText = resultText
        self.attemptNumber = attemptNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        requestID = try container.decode(String.self, forKey: .requestID)
        conversationID = try container.decode(String.self, forKey: .conversationID)
        sourceRunID = try container.decode(String.self, forKey: .sourceRunID)
        origin = try container.decode(IOSWakeOrigin.self, forKey: .origin)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fireAt = try container.decodeIfPresent(Date.self, forKey: .fireAt)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        requiresForeground = try container.decodeIfPresent(Bool.self, forKey: .requiresForeground) ?? false
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes)
        watchCondition = try container.decodeIfPresent(String.self, forKey: .watchCondition)
        stopWhenTriggered = try container.decodeIfPresent(Bool.self, forKey: .stopWhenTriggered) ?? true
        checkCount = try container.decodeIfPresent(Int.self, forKey: .checkCount) ?? 0
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastCheckSummary = try container.decodeIfPresent(String.self, forKey: .lastCheckSummary)
        eventReceivedAt = try container.decodeIfPresent(Date.self, forKey: .eventReceivedAt)
        eventContent = try container.decodeIfPresent(String.self, forKey: .eventContent)
        reminderRequestedAt = try container.decodeIfPresent(Date.self, forKey: .reminderRequestedAt)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .scheduled
        executionRunID = try container.decodeIfPresent(String.self, forKey: .executionRunID)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage)
        resultText = try container.decodeIfPresent(String.self, forKey: .resultText)
        attemptNumber = try container.decodeIfPresent(Int.self, forKey: .attemptNumber)
    }

    func isDue(at date: Date) -> Bool {
        status == .scheduled && (eventReceivedAt != nil || fireAt.map { $0 <= date } == true)
    }
}

enum IOSWakeWatchMarkers {
    static let triggered = "[WATCH_TRIGGERED]"
    static let silent = "[WATCH_SILENT]"

    struct Evaluation: Equatable, Sendable {
        let conditionTriggered: Bool
        let summary: String?
    }

    static func evaluate(
        result: String?,
        message: String?,
        explicitTriggered: Bool?
    ) -> Evaluation {
        let raw = (result ?? message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicitTriggered {
            let cleaned = stripMarker(from: raw)
            return Evaluation(conditionTriggered: explicitTriggered, summary: cleaned.isEmpty ? nil : cleaned)
        }
        if let extracted = extractAfterMarker(triggered, in: raw) {
            return Evaluation(conditionTriggered: true, summary: extracted.isEmpty ? nil : extracted)
        }
        if let extracted = extractAfterMarker(silent, in: raw) {
            return Evaluation(conditionTriggered: false, summary: extracted.isEmpty ? nil : extracted)
        }
        return Evaluation(conditionTriggered: false, summary: raw.isEmpty ? nil : raw)
    }

    private static func stripMarker(from text: String) -> String {
        if let extracted = extractAfterMarker(triggered, in: text) { return extracted }
        if let extracted = extractAfterMarker(silent, in: text) { return extracted }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractAfterMarker(_ marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker, options: [.caseInsensitive]) else { return nil }
        let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty { return suffix }
        let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix
    }
}

enum IOSWakeError: LocalizedError {
    case invalid(String)
    case missingTask
    case wrongConversation
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .missingTask: "找不到这项续跑任务。"
        case .wrongConversation: "这项续跑任务不属于当前对话。"
        case .unreadable(let message): "无法读取续跑任务，原文件已保留：\(message)"
        }
    }
}

/// The queue is the durable owner of plans and execution claims. A failed
/// write never publishes a plan that the model could mistake for saved work.
@MainActor @Observable
final class IOSWakeTaskStore {
    private struct Archive: Codable {
        let version: Int
        let tasks: [IOSWakeTask]
    }

    static let shared = IOSWakeTaskStore()
    private(set) var tasks: [IOSWakeTask] = []
    private(set) var loadError: String?
    private let fileURL: URL
    private let now: () -> Date
    private let write: (Data, URL) throws -> Void

    init(
        fileURL: URL = IOSWakeTaskStore.defaultURL,
        now: @escaping () -> Date = Date.init,
        write: @escaping (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.write = write
        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw IOSWakeError.invalid("任务文件版本不受支持。") }
            tasks = archive.tasks
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation has no queue yet.
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("AmberAgent/WakeTasks/tasks-v1.json")
    }

    func schedule(
        conversationID: String,
        sourceRunID: String,
        origin: IOSWakeOrigin,
        title: String,
        prompt: String,
        fireAt: Date?,
        event: String?,
        requiresForeground: Bool,
        requestID: String,
        intervalMinutes: Int? = nil,
        watchCondition: String? = nil,
        stopWhenTriggered: Bool = true
    ) throws -> IOSWakeTask {
        if let existing = tasks.first(where: { $0.requestID == requestID && $0.conversationID == conversationID }) {
            return existing
        }
        guard UUID(uuidString: conversationID) != nil,
              !sourceRunID.isEmpty, !requestID.isEmpty,
              !origin.userMessageID.isEmpty, !origin.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSWakeError.invalid("续跑任务缺少原对话或用户指令来源。")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = event?.trimmingCharacters(in: .whitespacesAndNewlines)
        let watchCondition = watchCondition?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, !prompt.isEmpty, prompt.count <= 8_000 else {
            throw IOSWakeError.invalid("标题须为 1–200 字，续跑说明须为 1–8000 字。")
        }
        guard event == nil || (event?.isEmpty == false && event!.count <= 200) else {
            throw IOSWakeError.invalid("事件名须为 1–200 字。")
        }
        if let intervalMinutes {
            guard (15...43_200).contains(intervalMinutes) else {
                throw IOSWakeError.invalid("周期巡检间隔须在 15 分钟到 30 天（43200 分钟）之间。")
            }
        }
        if let watchCondition {
            guard !watchCondition.isEmpty, watchCondition.count <= 1_000 else {
                throw IOSWakeError.invalid("盯梢触发条件须为 1–1000 字。")
            }
        }
        let currentTime = now()
        let resolvedFireAt: Date?
        if let fireAt {
            resolvedFireAt = fireAt
        } else if let intervalMinutes {
            resolvedFireAt = currentTime.addingTimeInterval(TimeInterval(intervalMinutes * 60))
        } else {
            resolvedFireAt = nil
        }
        guard resolvedFireAt != nil || event != nil else {
            throw IOSWakeError.invalid("请提供触发时间、事件名或巡检间隔。")
        }
        guard resolvedFireAt == nil || resolvedFireAt!.timeIntervalSince1970.isFinite else {
            throw IOSWakeError.invalid("触发时间无效。")
        }
        // Keep space for unrelated app notifications under the system limit.
        guard tasks.filter({ $0.status == .scheduled || $0.status == .running }).count < 32 else {
            throw IOSWakeError.invalid("待执行任务已达 32 项，请先完成或取消已有任务。")
        }
        let task = IOSWakeTask(
            id: UUID().uuidString,
            requestID: requestID,
            conversationID: conversationID,
            sourceRunID: sourceRunID,
            origin: origin,
            title: title,
            prompt: prompt,
            createdAt: currentTime,
            fireAt: resolvedFireAt,
            event: event,
            requiresForeground: requiresForeground,
            intervalMinutes: intervalMinutes,
            watchCondition: watchCondition,
            stopWhenTriggered: stopWhenTriggered
        )
        try commit(tasks + [task])
        return task
    }

    func task(id: String) -> IOSWakeTask? { tasks.first { $0.id == id } }

    func receive(event: String, content: String?) throws {
        let name = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, (content?.count ?? 0) <= 8_000 else {
            throw IOSWakeError.invalid("事件名须为 1–200 字，事件资料不能超过 8000 字。")
        }
        var candidate = tasks
        for index in candidate.indices where candidate[index].status == .scheduled && candidate[index].event == name {
            // The first matching event belongs to this one-shot plan. A burst
            // of later notifications cannot replace its already queued input.
            guard candidate[index].eventReceivedAt == nil else { continue }
            candidate[index].eventReceivedAt = now()
            candidate[index].eventContent = content
            candidate[index].reminderRequestedAt = nil
        }
        try commit(candidate)
    }

    func requestExecution(id: String) throws {
        try update(id: id) { task in
            guard [.scheduled, .failed, .interrupted].contains(task.status) else {
                throw IOSWakeError.invalid("这项任务\(task.status.title)，不能再次执行。")
            }
            if task.status == .failed || task.status == .interrupted {
                task.attemptNumber = (task.attemptNumber ?? 0) + 1
            }
            task.status = .scheduled
            task.fireAt = now()
            task.executionRunID = nil
            task.startedAt = nil
            task.finishedAt = nil
            task.lastMessage = nil
            task.reminderRequestedAt = nil
            task.resultText = nil
        }
    }

    func claim(id: String, runID: String) throws -> IOSWakeTask {
        try update(id: id) { task in
            guard task.isDue(at: now()) else { throw IOSWakeError.invalid("任务尚未到期或已被领取。") }
            task.status = .running
            task.executionRunID = runID
            task.startedAt = now()
            task.lastMessage = nil
        }
        return task(id: id)!
    }

    func deferExecution(id: String, runID: String, reason: String) throws {
        try update(id: id) { task in
            guard task.status == .running, task.executionRunID == runID else { return }
            task.status = .scheduled
            task.executionRunID = nil
            task.startedAt = nil
            task.lastMessage = reason
        }
    }

    func noteWaiting(id: String, reason: String) throws {
        try update(id: id) { task in
            guard task.status == .scheduled else { return }
            task.lastMessage = reason
        }
    }

    func markReminderRequested(id: String) throws {
        try update(id: id) { task in
            guard task.status == .scheduled else { return }
            task.reminderRequestedAt = now()
        }
    }

    @discardableResult
    func finish(
        runID: String,
        status: IOSWakeTask.Status,
        message: String?,
        result: String? = nil,
        conditionTriggered: Bool? = nil
    ) throws -> IOSWakeTask? {
        guard let task = tasks.first(where: { $0.executionRunID == runID && $0.status == .running }) else { return nil }
        guard [.completed, .failed, .cancelled, .interrupted].contains(status) else {
            throw IOSWakeError.invalid("无效的任务终态。")
        }
        try update(id: task.id) { task in
            let currentTime = now()
            if let intervalMinutes = task.intervalMinutes, intervalMinutes > 0,
               status == .completed || (status == .interrupted && conditionTriggered == true) {
                let evaluation = IOSWakeWatchMarkers.evaluate(
                    result: result,
                    message: message,
                    explicitTriggered: conditionTriggered
                )
                task.checkCount += 1
                task.lastCheckedAt = currentTime
                if evaluation.conditionTriggered {
                    let summary = evaluation.summary ?? result ?? message
                    task.lastCheckSummary = summary
                    task.resultText = result ?? summary
                    if status == .interrupted {
                        task.status = .interrupted
                        task.finishedAt = currentTime
                        task.lastMessage = message ?? summary
                    } else if task.stopWhenTriggered {
                        task.status = .completed
                        task.finishedAt = currentTime
                        task.lastMessage = message ?? summary
                    } else {
                        task.status = .scheduled
                        task.fireAt = currentTime.addingTimeInterval(TimeInterval(intervalMinutes * 60))
                        task.lastMessage = message ?? summary
                        task.eventReceivedAt = nil
                        task.eventContent = nil
                        task.reminderRequestedAt = nil
                        task.executionRunID = nil
                        task.startedAt = nil
                        task.finishedAt = nil
                        task.attemptNumber = (task.attemptNumber ?? 0) + 1
                    }
                } else {
                    let summary = evaluation.summary ?? "第 \(task.checkCount) 次巡检：暂未触发提醒条件。"
                    task.lastCheckSummary = summary
                    task.lastMessage = message ?? summary
                    task.status = .scheduled
                    task.fireAt = currentTime.addingTimeInterval(TimeInterval(intervalMinutes * 60))
                    task.eventReceivedAt = nil
                    task.eventContent = nil
                    task.reminderRequestedAt = nil
                    task.executionRunID = nil
                    task.startedAt = nil
                    task.finishedAt = nil
                    task.attemptNumber = (task.attemptNumber ?? 0) + 1
                }
            } else {
                task.status = status
                task.finishedAt = currentTime
                task.lastMessage = message
                task.resultText = result
            }
        }
        return self.task(id: task.id)
    }

    func cancel(id: String, conversationID: String? = nil) throws -> IOSWakeTask {
        try update(id: id) { task in
            if let conversationID, task.conversationID.caseInsensitiveCompare(conversationID) != .orderedSame {
                throw IOSWakeError.wrongConversation
            }
            guard task.status != .completed, task.status != .cancelled else { return }
            task.status = .cancelled
            task.finishedAt = now()
            task.lastMessage = "已取消后续执行。"
        }
        return task(id: id)!
    }

    private func update(id: String, mutate: (inout IOSWakeTask) throws -> Void) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw IOSWakeError.missingTask }
        var candidate = tasks
        try mutate(&candidate[index])
        try commit(candidate)
    }

    private func commit(_ candidate: [IOSWakeTask]) throws {
        if let loadError { throw IOSWakeError.unreadable(loadError) }
        guard candidate != tasks else { return }
        let data = try JSONEncoder().encode(Archive(version: 1, tasks: candidate))
        try write(data, fileURL)
        tasks = candidate
    }
}
