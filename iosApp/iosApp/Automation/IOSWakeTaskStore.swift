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

    func isDue(at date: Date) -> Bool {
        status == .scheduled && (eventReceivedAt != nil || fireAt.map { $0 <= date } == true)
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
        requestID: String
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
        guard !title.isEmpty, title.count <= 200, !prompt.isEmpty, prompt.count <= 8_000 else {
            throw IOSWakeError.invalid("标题须为 1–200 字，续跑说明须为 1–8000 字。")
        }
        guard event == nil || (event?.isEmpty == false && event!.count <= 200) else {
            throw IOSWakeError.invalid("事件名须为 1–200 字。")
        }
        guard fireAt != nil || event != nil else {
            throw IOSWakeError.invalid("请提供触发时间或事件名。")
        }
        guard fireAt == nil || fireAt!.timeIntervalSince1970.isFinite else {
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
            createdAt: now(),
            fireAt: fireAt,
            event: event,
            requiresForeground: requiresForeground
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
    func finish(runID: String, status: IOSWakeTask.Status, message: String?, result: String? = nil) throws -> IOSWakeTask? {
        guard let task = tasks.first(where: { $0.executionRunID == runID && $0.status == .running }) else { return nil }
        guard [.completed, .failed, .cancelled, .interrupted].contains(status) else {
            throw IOSWakeError.invalid("无效的任务终态。")
        }
        try update(id: task.id) { task in
            task.status = status
            task.finishedAt = now()
            task.lastMessage = message
            task.resultText = result
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
