import Foundation
import Observation

enum DesktopAgentStatus: String, Codable, Sendable {
    case running, waiting, completed, failed, cancelled, interrupted, outcomeUnknown
}

struct DesktopToolApproval: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
    var reason: String
}

struct DesktopToolTransaction: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var argsDigest: String
    var effect: String
    var state: String
    var outcome: String?
    var resultPayload: String?
    var canonicalInvocation: String?
}

struct DesktopAgentTask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var conversationID: UUID
    var title: String
    var status: DesktopAgentStatus
    var createdAt: Date
    var updatedAt: Date
    var approval: DesktopToolApproval?
    var transactions: [DesktopToolTransaction] = []
    var error: String?
    var requestDigests: [String]?
    var resultText: String?
}

enum DesktopToolPreparation: Sendable, Equatable {
    case ready, replay(String), blocked(String)
}

actor DesktopAgentJournal {
    private let directory: URL?
    private var records: [UUID: DesktopAgentTask] = [:]
    private var loaded = false

    init(directory: URL? = nil) { self.directory = directory }

    func load() throws -> [DesktopAgentTask] {
        if !loaded {
            if let directory, FileManager.default.fileExists(atPath: directory.path) {
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where url.pathExtension == "json" {
                    var record = try JSONDecoder().decode(DesktopAgentTask.self, from: Data(contentsOf: url))
                    if record.status == .running || record.status == .waiting {
                        let uncertain = record.transactions.contains { $0.state == "started" }
                        record.status = uncertain ? .outcomeUnknown : .interrupted
                        record.approval = nil
                        record.error = uncertain ? "上次工具执行中断，结果需要核对；不会自动重放。" : "上次任务已中断，可以从原会话继续。"
                        for index in record.transactions.indices where record.transactions[index].state == "started" {
                            record.transactions[index].state = "outcome_unknown"
                        }
                        try save(record)
                    }
                    records[record.id] = record
                }
            }
            loaded = true
        }
        return records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func value(_ id: UUID) throws -> DesktopAgentTask {
        _ = try load()
        guard let value = records[id] else { throw DesktopRuntimeError.message("找不到此任务。") }
        return value
    }

    func save(_ value: DesktopAgentTask) throws {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(value.id.uuidString + ".json"), options: .atomic)
        }
        records[value.id] = value
    }

    func change(_ id: UUID, _ update: @Sendable (inout DesktopAgentTask) throws -> Void) throws -> DesktopAgentTask {
        var record = try value(id)
        try update(&record)
        record.updatedAt = Date()
        try save(record)
        return record
    }

    func prepare(_ runID: UUID, callID: String, name: String, argsDigest: String, effect: String) throws -> DesktopToolPreparation {
        var record = try value(runID)
        guard record.status == .running || record.status == .waiting else { return .blocked("任务已结束，工具未执行。") }
        if let existing = record.transactions.first(where: { $0.id == callID }) {
            guard existing.name == name, existing.argsDigest == argsDigest else { return .blocked("相同call ID的工具参数发生变化，未执行。") }
            switch existing.state {
            case "finished":
                if let payload = existing.resultPayload { return .replay(payload) }
                return .blocked("此工具调用已结束，不会重放。")
            case "prepared", "waiting_user": return .ready
            default: return .blocked("此工具调用已经开始或结果未知，请核对原任务。")
            }
        }
        record.transactions.append(DesktopToolTransaction(id: callID, name: name, argsDigest: argsDigest, effect: effect, state: "prepared"))
        record.updatedAt = Date()
        try save(record)
        return .ready
    }
}

@MainActor @Observable
final class DesktopAgentTasks {
    private(set) var records: [DesktopAgentTask] = []
    private(set) var errorMessage: String?
    var toolsEnabled: Bool {
        didSet { defaults.set(toolsEnabled, forKey: "desktop.agent-tools-enabled") }
    }
    @ObservationIgnored let journal: DesktopAgentJournal
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications: DesktopNotifications?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var decisions: [UUID: [String: Bool]] = [:]
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var cancellations: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var deciding: Set<UUID> = []
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var invalidated: Set<UUID> = []

    init(directory: URL? = nil, defaults: UserDefaults = .standard, notifications: DesktopNotifications? = nil) {
        self.defaults = defaults
        self.notifications = notifications
        toolsEnabled = defaults.bool(forKey: "desktop.agent-tools-enabled")
        journal = DesktopAgentJournal(directory: directory)
        loading = Task {
            do { records = try await journal.load() }
            catch { loadFailed = true; errorMessage = "读取任务记录失败，原始文件已保留。" }
        }
    }

    func waitUntilLoaded() async { await loading?.value }

    func begin(id: UUID = UUID(), conversationID: UUID, title: String, cancel: @escaping @MainActor () -> Void) async throws -> UUID {
        await loading?.value
        guard !loadFailed else { throw DesktopRuntimeError.message("任务记录不可读，请先修复读取问题。") }
        let record = DesktopAgentTask(id: id, conversationID: conversationID, title: String(title.prefix(100)),
            status: .running, createdAt: Date(), updatedAt: Date())
        try await journal.save(record)
        publish(record)
        cancellations[id] = cancel
        return id
    }

    func publish(_ record: DesktopAgentTask) {
        var updated = records.filter { $0.id != record.id }
        updated.append(record)
        records = updated.sorted { $0.updatedAt > $1.updatedAt }
    }

    func requestApproval(runID: UUID, approval: DesktopToolApproval) async throws {
        guard !invalidated.contains(runID) else { throw CancellationError() }
        let record = try await journal.change(runID) { $0.status = .waiting; $0.approval = approval }
        publish(record)
    }

    func decision(runID: UUID, toolID: String) -> Bool? { decisions[runID]?[toolID] }

    func awaitDecision(runID: UUID, toolID: String) async -> Bool {
        if invalidated.contains(runID) { return false }
        if let decision = decisions[runID]?[toolID] { return decision }
        if Task.isCancelled { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                if Task.isCancelled { $0.resume(returning: false) }
                else { waiters[runID] = $0 }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: runID)?.resume(returning: false) } }
    }

    func decide(runID: UUID, allow: Bool) {
        guard let approval = records.first(where: { $0.id == runID })?.approval,
              !invalidated.contains(runID),
              deciding.insert(runID).inserted else { return }
        Task {
            defer { deciding.remove(runID) }
            do {
                let record = try await journal.change(runID) {
                    guard $0.status == .waiting, $0.approval?.id == approval.id else { throw DesktopRuntimeError.message("此审批已经结束。") }
                    $0.approval = nil; $0.status = .running
                }
                guard cancellations[runID] != nil else { return }
                // Only the exact call id receives this one-use decision. Another call must ask again.
                decisions[runID, default: [:]][approval.id] = allow
                publish(record)
                waiters.removeValue(forKey: runID)?.resume(returning: allow)
            } catch { errorMessage = "无法保存审批决定，工具尚未执行，请重试。" }
        }
    }

    func finish(_ runID: UUID, status: DesktopAgentStatus, error: String? = nil) async {
        invalidated.insert(runID)
        do {
            let record = try await journal.change(runID) { $0.status = status; $0.error = error; $0.approval = nil }
            publish(record)
            if let notifications, status == .completed || status == .failed || status == .outcomeUnknown {
                Task { await notifications.notify(runID: runID, conversationID: record.conversationID,
                    outcome: status == .completed ? .completed : .failed) }
            }
        } catch { errorMessage = "无法保存任务终态，请保留应用并检查存储权限。" }
        waiters.removeValue(forKey: runID)?.resume(returning: false)
        cancellations[runID] = nil
        decisions[runID] = nil
    }

    func cancel(_ runID: UUID) {
        invalidated.insert(runID)
        cancellations[runID]?()
        waiters.removeValue(forKey: runID)?.resume(returning: false)
    }

    func cancelAll() { for id in Array(cancellations.keys) { cancel(id) } }
}
