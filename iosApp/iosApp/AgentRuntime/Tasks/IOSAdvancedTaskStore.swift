import Foundation
import Observation

@MainActor
@Observable
final class IOSAdvancedTaskStore {
    static let shared = IOSAdvancedTaskStore()

    private static let defaultStorageKey = "app.amber.ios.advancedTasks.v1"
    private static let maxPersistedTasks = 80
    private static let maxFieldLength = 4_000
    private static let maxLogLength = 24_000

    var tasks: [IOSAdvancedTaskRecord]

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = IOSAdvancedTaskStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        let loadedTasks = Self.load(from: userDefaults, key: storageKey, decoder: decoder)
        self.tasks = loadedTasks
        // Establish the process boundary at the moment this store hydrates.
        // AppShell may be created after a new dispatch has already started;
        // sweeping there would incorrectly interrupt that live execution.
        markInterruptedSubAgentTasks(now: Date())
    }

    @discardableResult
    func startTask(
        id: String? = nil,
        kind: IOSAdvancedTaskKind,
        title: String,
        objective: String,
        roleId: String? = nil,
        toolScope: [String] = [],
        budgetSummary: String = "",
        connectionSummary: String = "",
        commandPreview: String = "",
        sourceToolName: String = "",
        metadata: [String: String] = [:],
        now: Date = Date()
    ) -> IOSAdvancedTaskRecord {
        let record = IOSAdvancedTaskRecord(
            id: id ?? UUID().uuidString,
            kind: kind,
            title: Self.redacted(title),
            objective: Self.redacted(objective),
            status: .running,
            roleId: roleId,
            toolScope: toolScope.map(Self.redacted),
            budgetSummary: Self.redacted(budgetSummary),
            connectionSummary: Self.redacted(connectionSummary),
            commandPreview: Self.redactedCommand(commandPreview),
            resultSummary: "",
            logTail: "",
            error: "",
            retryable: false,
            cancelCapability: true,
            sourceToolName: sourceToolName,
            metadata: Self.redactedMetadata(metadata),
            createdAt: now,
            updatedAt: now
        )
        upsert(record)
        return record
    }

    @discardableResult
    func updateTask(
        id: String,
        status: IOSAdvancedTaskStatus? = nil,
        resultSummary: String? = nil,
        logTail: String? = nil,
        error: String? = nil,
        retryable: Bool? = nil,
        cancelCapability: Bool? = nil,
        metadata: [String: String]? = nil,
        now: Date = Date()
    ) -> IOSAdvancedTaskRecord? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        if let status { tasks[index].status = status }
        if let resultSummary { tasks[index].resultSummary = Self.redacted(resultSummary) }
        if let logTail { tasks[index].logTail = Self.redactedLog(logTail) }
        if let error { tasks[index].error = Self.redacted(error) }
        if let retryable { tasks[index].retryable = retryable }
        if let cancelCapability { tasks[index].cancelCapability = cancelCapability }
        if let metadata {
            for (key, value) in Self.redactedMetadata(metadata) {
                tasks[index].metadata[key] = value
            }
        }
        tasks[index].updatedAt = now
        persist()
        return tasks[index]
    }

    func appendLog(id: String, chunk: String, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].logTail = Self.redactedLog(tasks[index].logTail + chunk)
        tasks[index].updatedAt = now
        persist()
    }

    func recent(kind: IOSAdvancedTaskKind? = nil, limit: Int = 8) -> [IOSAdvancedTaskRecord] {
        tasks
            .filter { kind == nil || $0.kind == kind }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    func task(id: String) -> IOSAdvancedTaskRecord? {
        tasks.first(where: { $0.id == id })
    }

    /// Called once at app startup. A process-local Council run cannot still own
    /// work after relaunch, so persisted running rows must become honest terminals.
    @discardableResult
    func markInterruptedCouncilTasks(now: Date = Date()) -> [String] {
        let ids = tasks
            .filter { $0.kind == .modelCouncil && $0.status == .running }
            .map(\.id)
        guard !ids.isEmpty else { return [] }

        let idSet = Set(ids)
        for index in tasks.indices where idSet.contains(tasks[index].id) {
            let wasContinuation = tasks[index].metadata["continuation_base_completed"] == "true"
            tasks[index].status = wasContinuation ? .completed : .interrupted
            tasks[index].resultSummary = wasContinuation
                ? "既有议会结论已保留，追问因应用进程结束而中断。"
                : "模型议会因应用进程结束而中断。"
            tasks[index].error = ""
            tasks[index].retryable = false
            tasks[index].cancelCapability = false
            tasks[index].metadata["interruption_reason"] = "process_terminated"
            if wasContinuation {
                tasks[index].metadata["continuation_status"] = IOSAdvancedTaskStatus.interrupted.rawValue
            }
            tasks[index].updatedAt = now
        }
        persist()
        return ids
    }

    /// Process-local Remote SSH jobs cannot be reattached after relaunch.
    /// Preserve their last persisted output and mark the final outcome unknown.
    @discardableResult
    func markInterruptedRemoteCommandTasks(now: Date = Date()) -> [String] {
        let ids = tasks
            .filter { $0.kind == .remoteCommand && $0.status == .running }
            .map(\.id)
        guard !ids.isEmpty else { return [] }

        let idSet = Set(ids)
        for index in tasks.indices where idSet.contains(tasks[index].id) {
            tasks[index].status = .interrupted
            tasks[index].resultSummary = "应用进程已结束，远程命令的最终结果未知。"
            tasks[index].error = "无法在重启后重新连接该 Remote SSH 作业。"
            tasks[index].retryable = false
            tasks[index].cancelCapability = false
            tasks[index].metadata["interruption_reason"] = "process_terminated"
            tasks[index].metadata["outcome"] = "unknown"
            tasks[index].updatedAt = now
        }
        persist()
        return ids
    }

    /// Embedded iSH jobs are process-local and cannot be reattached after relaunch.
    @discardableResult
    func markInterruptedEmbeddedIshTasks(now: Date = Date()) -> [String] {
        let ids = tasks
            .filter { $0.kind == .embeddedIsh && $0.status == .running }
            .map(\.id)
        guard !ids.isEmpty else { return [] }

        let idSet = Set(ids)
        for index in tasks.indices where idSet.contains(tasks[index].id) {
            tasks[index].status = .interrupted
            tasks[index].resultSummary = "应用进程已结束，内置 iSH 命令的最终结果未知。"
            tasks[index].error = "无法在重启后重新连接该内置 iSH 作业。"
            tasks[index].retryable = false
            tasks[index].cancelCapability = false
            tasks[index].metadata["interruption_reason"] = "process_terminated"
            tasks[index].metadata["outcome"] = "unknown"
            tasks[index].updatedAt = now
        }
        persist()
        return ids
    }

    /// SubAgent provider streams are process-local and have no cursor that can
    /// be reattached after relaunch. Sweep every non-terminal row (including a
    /// leaked approval/queued row) before the cross-conversation activity
    /// projection starts, so an old execution cannot appear alive forever.
    @discardableResult
    private func markInterruptedSubAgentTasks(now: Date = Date()) -> [String] {
        let ids = tasks
            .filter {
                $0.kind == .subAgent
                    && !$0.status.isTerminal
            }
            .map(\.id)
        guard !ids.isEmpty else { return [] }

        let idSet = Set(ids)
        for index in tasks.indices where idSet.contains(tasks[index].id) {
            tasks[index].status = .interrupted
            tasks[index].retryable = false
            tasks[index].cancelCapability = false
            tasks[index].metadata["interruption_reason"] = "process_terminated"
            tasks[index].metadata["execution_finished_at"] = String(now.timeIntervalSince1970)
            tasks[index].updatedAt = now
        }
        persist()
        return ids
    }

    @discardableResult
    func upsert(_ record: IOSAdvancedTaskRecord) -> IOSAdvancedTaskRecord {
        var sanitized = record
        sanitized.title = Self.redacted(record.title)
        sanitized.objective = Self.redacted(record.objective)
        sanitized.commandPreview = Self.redactedCommand(record.commandPreview)
        sanitized.logTail = Self.redactedLog(record.logTail)
        sanitized.resultSummary = Self.redacted(record.resultSummary)
        sanitized.error = Self.redacted(record.error)
        sanitized.metadata = Self.redactedMetadata(record.metadata)

        if let index = tasks.firstIndex(where: { $0.id == sanitized.id }) {
            tasks[index] = sanitized
        } else {
            tasks.insert(sanitized, at: 0)
        }
        tasks = Array(tasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxPersistedTasks))
        persist()
        return sanitized
    }

    func replaceAll(_ records: [IOSAdvancedTaskRecord]) {
        tasks = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxPersistedTasks))
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(tasks) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private static func load(from defaults: UserDefaults, key: String, decoder: JSONDecoder) -> [IOSAdvancedTaskRecord] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([IOSAdvancedTaskRecord].self, from: data) else {
            return []
        }
        return Array(decoded.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxPersistedTasks))
    }

    static func redactedCommand(_ value: String) -> String {
        redacted(value)
    }

    static func redactedLog(_ value: String) -> String {
        let redacted = redacted(value)
        guard redacted.count > maxLogLength else { return redacted }
        return String(redacted.suffix(maxLogLength))
    }

    static func redacted(_ value: String) -> String {
        redact(value, preservingWhitespace: false)
    }

    private static func redactedMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, entry in
            let isOutput = entry.key == "stdout_tail" || entry.key == "stderr_tail"
            result[entry.key] = redact(entry.value, preservingWhitespace: isOutput)
        }
    }

    private static func redact(_ value: String, preservingWhitespace: Bool) -> String {
        let trimmed = preservingWhitespace ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{6,}"#,
            #"(?i)(api[_-]?key|token|password|passwd|secret|authorization)\s*[:=]\s*["']?[^"'\s]+["']?"#,
            #"sk-[A-Za-z0-9_\-]{12,}"#,
            #"(?i)(ssh-rsa|ssh-ed25519)\s+[A-Za-z0-9+/=]+"#
        ]
        var output = IOSSSHOutputRedactor.redact(trimmed, credential: .password(""))
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        guard output.count > maxFieldLength else { return output }
        return String(output.prefix(maxFieldLength)) + "..."
    }
}

