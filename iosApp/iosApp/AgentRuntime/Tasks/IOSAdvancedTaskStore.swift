import Foundation
import Observation
import os

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
    @ObservationIgnored let snapshotFile: DebouncedSnapshotFile?
    @ObservationIgnored private var logStreams: [String: TaskLogStream] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = IOSAdvancedTaskStore.defaultStorageKey,
        fileURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        let url = fileURL ?? (userDefaults === UserDefaults.standard
            ? URL.applicationSupportDirectory.appending(path: storageKey + ".json") : nil)
        self.snapshotFile = url.map(DebouncedSnapshotFile.init)
        self.tasks = Self.load(from: userDefaults, key: storageKey, fileURL: url)
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
        if let logTail {
            logStreams.removeValue(forKey: id)
            tasks[index].logTail = Self.redactedLog(logTail)
        }
        if let error { tasks[index].error = Self.redacted(error) }
        if let retryable { tasks[index].retryable = retryable }
        if let cancelCapability { tasks[index].cancelCapability = cancelCapability }
        if let metadata {
            for (key, value) in Self.redactedMetadata(metadata) {
                tasks[index].metadata[key] = value
            }
        }
        tasks[index].updatedAt = now
        if status?.isTerminal == true, let stream = logStreams.removeValue(forKey: id) {
            tasks[index].logTail = stream.finish()
        }
        persist(immediately: status?.isTerminal == true)
        return tasks[index]
    }

    func appendLog(id: String, chunk: String, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let stream = logStreams[id] ?? TaskLogStream(prefix: tasks[index].logTail)
        logStreams[id] = stream
        tasks[index].logTail = stream.append(chunk)
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
        persist(immediately: true)
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
        persist(immediately: true)
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
        persist(immediately: true)
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
        persist(immediately: true)
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
        logStreams.removeValue(forKey: record.id)
        if !logStreams.isEmpty {
            let retained = Set(tasks.map(\.id))
            logStreams = logStreams.filter { retained.contains($0.key) }
        }
        persist(immediately: record.status.isTerminal)
        return sanitized
    }

    func replaceAll(_ records: [IOSAdvancedTaskRecord]) {
        logStreams.removeAll()
        tasks = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxPersistedTasks))
        persist()
    }

    private func persist(immediately: Bool = false) {
        let snapshot = tasks
        if let snapshotFile, !immediately {
            snapshotFile.schedule { try JSONEncoder().encode(snapshot) }
            return
        }
        do {
            let data = try JSONEncoder().encode(snapshot)
            if let snapshotFile {
                // A caller can end its system background task as soon as a terminal update returns.
                snapshotFile.cancel()
                try DebouncedSnapshotFile.write(data, to: snapshotFile.url)
            } else {
                userDefaults.set(data, forKey: storageKey)
            }
        } catch {
            DebouncedSnapshotFile.logger.error("Task checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults, key: String, fileURL: URL?) -> [IOSAdvancedTaskRecord] {
        do {
            let data: Data
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                data = try Data(contentsOf: fileURL)
            } else if let legacy = defaults.data(forKey: key) {
                data = legacy
            } else {
                return []
            }
            let records = try JSONDecoder().decode([IOSAdvancedTaskRecord].self, from: data)
            if let fileURL, defaults.object(forKey: key) != nil {
                do {
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        try DebouncedSnapshotFile.write(data, to: fileURL)
                    }
                    defaults.removeObject(forKey: key)
                } catch {
                    DebouncedSnapshotFile.logger.error("Task migration deferred: \(error.localizedDescription, privacy: .public)")
                }
            }
            return Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxPersistedTasks))
        } catch {
            DebouncedSnapshotFile.logger.error("Task restore failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
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
        var output = IOSSSHOutputRedactor.redact(trimmed, credential: .password(""))
        for rule in TaskLogRedactionRule.all {
            output = rule.replaceMatches(in: output)
        }
        return clippedField(output)
    }

    fileprivate static func clippedField(_ output: String) -> String {
        guard output.count > maxFieldLength else { return output }
        return String(output.prefix(maxFieldLength)) + "..."
    }
}


/// Each stage keeps only an unfinished introducer. Once a credential matches, further
/// value characters are discarded until its delimiter, even if it spans many chunks.
private struct TaskLogRedactionRule {
    let match: NSRegularExpression
    let incomplete: NSRegularExpression
    let continuation: NSRegularExpression
    let quoted: Bool

    init(_ markers: [String], value: String, unfinished: String, continuation: String,
         caseSensitive: Bool = false, quoted: Bool = false) {
        let flags: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let marker = "(?:" + markers.joined(separator: "|") + ")"
        let prefixes = Set(markers.flatMap { word in
            (1..<word.count).map { String(word.prefix($0)) }
        })
        match = try! NSRegularExpression(pattern: marker + value, options: flags)
        incomplete = try! NSRegularExpression(
            pattern: "(?:" + marker + unfinished + "|" + prefixes.joined(separator: "|") + #")\z"#,
            options: flags
        )
        self.continuation = try! NSRegularExpression(pattern: "^" + continuation, options: flags)
        self.quoted = quoted
    }

    static let all = [
        Self(["bearer"], value: #"\s+[A-Za-z0-9._~+/=-]{6,}"#, unfinished: #"(?:\s+[A-Za-z0-9._~+/=-]{0,5})?"#,
             continuation: #"[A-Za-z0-9._~+/=-]*"#),
        Self(["apikey", "api_key", "api-key", "token", "password", "passwd", "secret", "authorization"],
             value: #"\s*[:=]\s*["']?[^"'\s]+["']?"#, unfinished: #"\s*(?:[:=]\s*["']?)?"#,
             continuation: #"[^"'\s]*["']?"#, quoted: true),
        Self(["sk-"], value: #"[A-Za-z0-9_\-]{12,}"#, unfinished: #"[A-Za-z0-9_\-]{0,11}"#,
             continuation: #"[A-Za-z0-9_\-]*"#, caseSensitive: true),
        Self(["ssh-rsa", "ssh-ed25519"], value: #"\s+[A-Za-z0-9+/=]+"#, unfinished: #"\s*"#,
             continuation: #"[A-Za-z0-9+/=]*"#)
    ]

    func replaceMatches(in text: String) -> String {
        match.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                       withTemplate: IOSSSHOutputRedactor.replacement)
    }

    struct Stream {
        let rule: TaskLogRedactionRule
        var pending = ""
        var insideValue = false

        mutating func consume(_ chunk: String, finishing: Bool = false) -> String {
            var input = pending + chunk
            pending = ""
            if insideValue {
                let range = NSRange(input.startIndex..., in: input)
                if let match = rule.continuation.firstMatch(in: input, range: range),
                   let consumed = Range(match.range, in: input) {
                    insideValue = consumed.upperBound == input.endIndex && !endsWithClosingQuote(input[consumed])
                    input.removeSubrange(consumed)
                }
            }
            let range = NSRange(input.startIndex..., in: input)
            let last = rule.match.matches(in: input, range: range).last
            let end = last.map { NSMaxRange($0.range) } ?? 0
            if !finishing, let last, end == range.length, let matched = Range(last.range, in: input) {
                insideValue = !endsWithClosingQuote(input[matched])
            } else if !finishing, let suffix = rule.incomplete.firstMatch(
                in: input, range: NSRange(location: end, length: range.length - end)
            ), let held = Range(suffix.range, in: input) {
                pending = String(input[held])
                input.removeSubrange(held)
            }
            return rule.replaceMatches(in: input)
        }

        private func endsWithClosingQuote(_ matched: Substring) -> Bool {
            rule.quoted && (matched.last == "\"" || matched.last == "'")
        }
    }
}

@MainActor
private final class TaskLogStream {
    private let pem = IOSSSHOutputRedactor(credentials: [])
    private var stages = TaskLogRedactionRule.all.map { TaskLogRedactionRule.Stream(rule: $0) }
    private var prefix: String

    init(prefix: String) {
        self.prefix = ""
        if !prefix.isEmpty { _ = append(prefix) }
    }

    func append(_ chunk: String) -> String {
        render(pem.redact(.init(text: chunk, isStderr: false))?.text ?? "", finishing: false)
    }

    func finish() -> String {
        render(pem.finish().map(\.text).joined(), finishing: true)
    }

    private func render(_ text: String, finishing: Bool) -> String {
        var safe = text
        for i in stages.indices { safe = stages[i].consume(safe, finishing: finishing) }
        if prefix.isEmpty { safe = String(safe.drop(while: { $0.isWhitespace })) }
        // Keep the existing 4,000-character display boundary of redactedLog.
        prefix = IOSAdvancedTaskStore.clippedField(prefix + safe)
        var preview = ""
        for var stage in stages { preview = stage.consume(preview, finishing: true) }
        return IOSAdvancedTaskStore.clippedField((prefix + preview).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
