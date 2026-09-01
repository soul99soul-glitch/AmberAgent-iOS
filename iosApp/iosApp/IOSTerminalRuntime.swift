import Foundation
import Observation
@preconcurrency import Shared

enum IOSTerminalRuntimeKind: String, CaseIterable, Codable, Identifiable {
    case remoteSSH = "remote_ssh"
    case localIOSTools = "local_ios_tools"
    case remoteMosh = "remote_mosh"
    case ishExperimental = "ish_experimental"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .remoteSSH: "Remote SSH"
        case .localIOSTools: "AmberShell"
        case .remoteMosh: "Remote Mosh"
        case .ishExperimental: "iSH Experimental"
        }
    }
}

enum IOSTerminalRuntimeTier: String {
    case stable
    case experimental

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .experimental: "Experimental"
        }
    }
}

enum IOSTerminalLicenseClass: String {
    case permissive
    case gplReviewRequired = "gpl_review_required"

    var displayName: String {
        switch self {
        case .permissive: "Permissive"
        case .gplReviewRequired: "GPL review required"
        }
    }
}

struct IOSTerminalRuntimeCapability: Identifiable {
    let runtime: IOSTerminalRuntimeKind
    let tier: IOSTerminalRuntimeTier
    let supportsPTY: Bool
    let supportsPackageInstall: Bool
    let supportsLongRunningJobs: Bool
    let supportsInteractiveLogin: Bool
    let supportsFileSync: Bool
    let appStoreSafeByDefault: Bool
    let supportsExternalCLIByDefault: Bool
    let licenseClass: IOSTerminalLicenseClass
    let summary: String

    var id: String { runtime.rawValue }
}

enum IOSTerminalRuntimeCapabilities {
    static let all: [IOSTerminalRuntimeCapability] = IOSTerminalRuntimeKind.allCases.map { runtime in
        let shared = TerminalRuntimeCapabilities.shared.forRuntime(runtime: runtime.sharedKind)
        guard let tier = IOSTerminalRuntimeTier(rawValue: shared.tier.wireName),
              let licenseClass = IOSTerminalLicenseClass(rawValue: shared.licenseClass.wireName) else {
            preconditionFailure("Unsupported terminal capability metadata for \(runtime.rawValue).")
        }
        return IOSTerminalRuntimeCapability(
            runtime: runtime,
            tier: tier,
            supportsPTY: shared.supportsPty,
            supportsPackageInstall: shared.supportsPackageInstall,
            supportsLongRunningJobs: shared.supportsLongRunningJobs,
            supportsInteractiveLogin: shared.supportsInteractiveLogin,
            supportsFileSync: shared.supportsFileSync,
            appStoreSafeByDefault: shared.appStoreSafeByDefault,
            supportsExternalCLIByDefault: shared.supportsExternalCliByDefault,
            licenseClass: licenseClass,
            summary: shared.summary
        )
    }

    static func capability(for runtime: IOSTerminalRuntimeKind) -> IOSTerminalRuntimeCapability {
        all.first { $0.runtime == runtime }!
    }
}

private extension IOSTerminalRuntimeKind {
    var sharedKind: TerminalRuntimeKind {
        switch self {
        case .remoteSSH: .remoteSsh
        case .localIOSTools: .localIosTools
        case .remoteMosh: .remoteMosh
        case .ishExperimental: .ishExperimental
        }
    }
}

enum IOSTerminalBuildPolicy {
    #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
    static let experimentalRuntimesLinked = true
    #else
    static let experimentalRuntimesLinked = false
    #endif

    static var selectableRuntimes: [IOSTerminalRuntimeKind] {
        if experimentalRuntimesLinked {
            return [.remoteSSH, .localIOSTools, .ishExperimental]
        }
        return [.remoteSSH, .localIOSTools]
    }

    static func normalizedDefaultRuntime(_ runtime: IOSTerminalRuntimeKind) -> IOSTerminalRuntimeKind {
        selectableRuntimes.contains(runtime) ? runtime : .remoteSSH
    }
}

enum IOSRemoteTerminalToolCatalog {
    static let jobStartToolName = "terminal_job_start"
    static let jobReadToolName = "terminal_job_read"
    static let jobWaitToolName = "terminal_job_wait"
    static let jobStopToolName = "terminal_job_stop"

    static let jobToolNames: Set<String> = [
        jobStartToolName, jobReadToolName, jobWaitToolName, jobStopToolName,
    ]
    static let approvalToolNames: Set<String> = [
        "terminal_execute", jobStartToolName, jobStopToolName,
    ]
    static let readOnlyToolNames: Set<String> = [jobReadToolName, jobWaitToolName]
    static let supportedToolNames = Set(["terminal_execute"]).union(jobToolNames)
}

enum IOSAmberShellToolCatalog {
    static let executeToolName = "ios_shell_execute"
    static let supportedToolNames: Set<String> = [executeToolName]
    static let approvalToolNames = supportedToolNames
}

/// Cross-layer contract for `ios_shell_execute.stdin`.
///
/// JSON Schema cannot express a UTF-8 byte limit with its standard
/// `maxLength` keyword (which counts Unicode characters). The model-facing
/// schema documents this limit in prose, while the parser and AmberShell
/// engine enforce this shared byte ceiling.
enum IOSAmberShellInputContract {
    static let maxStdinBytes = 64 * 1024
}

enum IOSAgentTerminalToolCatalog {
    static var supportedToolNames: Set<String> {
        IOSRemoteTerminalToolCatalog.supportedToolNames
            .union(IOSAmberShellToolCatalog.supportedToolNames)
            .union(IOSIshToolCatalog.supportedToolNames)
            .union(IOSEmbeddedIshToolCatalog.supportedToolNames)
    }
}

struct IOSTerminalJobSnapshot: Identifiable {
    let id: String
    let runtime: IOSTerminalRuntimeKind
    let status: String
    let exitCode: Int?
    let outputTail: String
    let stdoutTail: String
    let stderrTail: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let startedAt: Date
    let updatedAt: Date
    let error: String?

    init(
        id: String,
        runtime: IOSTerminalRuntimeKind,
        status: String,
        exitCode: Int?,
        outputTail: String,
        stdoutTail: String? = nil,
        stderrTail: String = "",
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        startedAt: Date,
        updatedAt: Date,
        error: String?
    ) {
        self.id = id
        self.runtime = runtime
        self.status = status
        self.exitCode = exitCode
        self.outputTail = outputTail
        self.stdoutTail = stdoutTail ?? outputTail
        self.stderrTail = stderrTail
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.error = error
    }
}

enum IOSTerminalJobStatus: String {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case timedOut = "timed_out"
    case interrupted

    var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .timedOut: "已超时"
        case .interrupted: "已中断"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .interrupted:
            true
        case .queued, .running:
            false
        }
    }
}

enum IOSAdvancedTaskKind: String, Codable, CaseIterable, Identifiable {
    case subAgent = "sub_agent"
    case modelCouncil = "model_council"
    case remoteCommand = "remote_command"
    case embeddedIsh = "embedded_ish"
    case toolApproval = "tool_approval"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subAgent: "SubAgent"
        case .modelCouncil: "模型议会"
        case .remoteCommand: "远程执行"
        case .embeddedIsh: "内置 iSH 作业"
        case .toolApproval: "工具审批"
        }
    }
}

enum IOSAdvancedTaskStatus: String, Codable, CaseIterable, Identifiable {
    case queued
    case running
    case approvalRequired = "approval_required"
    case completed
    case failed
    case cancelled
    case timedOut = "timed_out"
    case interrupted

    var id: String { rawValue }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .interrupted:
            true
        case .queued, .running, .approvalRequired:
            false
        }
    }

    var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .approvalRequired: "等待确认"
        case .completed: "已完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .timedOut: "已超时"
        case .interrupted: "已中断"
        }
    }
}

struct IOSAdvancedTaskRecord: Codable, Equatable, Identifiable {
    var id: String
    var kind: IOSAdvancedTaskKind
    var title: String
    var objective: String
    var status: IOSAdvancedTaskStatus
    var roleId: String?
    var toolScope: [String]
    var budgetSummary: String
    var connectionSummary: String
    var commandPreview: String
    var resultSummary: String
    var logTail: String
    var error: String
    var retryable: Bool
    var cancelCapability: Bool
    var sourceToolName: String
    var metadata: [String: String]
    var createdAt: Date
    var updatedAt: Date

    var canRetry: Bool {
        retryable && status.isTerminal
    }

    var compactSummary: String {
        if !resultSummary.isEmpty { return resultSummary }
        if !error.isEmpty { return error }
        if !logTail.isEmpty { return logTail }
        return objective
    }
}

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
        self.tasks = Self.load(from: userDefaults, key: storageKey, decoder: decoder)
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
            metadata: metadata.mapValues(Self.redacted),
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
            for (key, value) in metadata {
                tasks[index].metadata[key] = Self.redacted(value)
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

    @discardableResult
    func upsert(_ record: IOSAdvancedTaskRecord) -> IOSAdvancedTaskRecord {
        var sanitized = record
        sanitized.title = Self.redacted(record.title)
        sanitized.objective = Self.redacted(record.objective)
        sanitized.commandPreview = Self.redactedCommand(record.commandPreview)
        sanitized.logTail = Self.redactedLog(record.logTail)
        sanitized.resultSummary = Self.redacted(record.resultSummary)
        sanitized.error = Self.redacted(record.error)
        sanitized.metadata = record.metadata.mapValues(Self.redacted)

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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{6,}"#,
            #"(?i)(api[_-]?key|token|password|passwd|secret|authorization)\s*[:=]\s*["']?[^"'\s]+["']?"#,
            #"sk-[A-Za-z0-9_\-]{12,}"#,
            #"(?i)(ssh-rsa|ssh-ed25519)\s+[A-Za-z0-9+/=]+"#
        ]
        var output = trimmed
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

enum IOSRemoteCommandPolicyResult {
    case success(String)
    case failure(String)
}

enum IOSRemoteCommandPolicy {
    static func validate(_ command: String) -> IOSRemoteCommandPolicyResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Command is required.")
        }
        guard trimmed.count <= 2_000 else {
            return .failure("Command is too long for a single remote execution task.")
        }

        let lowercased = trimmed.lowercased()
        let blockedFragments = [
            "rm -rf /",
            "mkfs",
            "diskutil erase",
            "shutdown",
            "reboot",
            ":(){",
            "dd if=",
            ">:",
            "chmod -r 777 /"
        ]
        if let fragment = blockedFragments.first(where: { lowercased.contains($0) }) {
            return .failure("Blocked potentially destructive command fragment: \(fragment)")
        }
        return .success(trimmed)
    }
}

/// Embedded iSH runs inside an app-owned guest, so it intentionally accepts
/// larger scripts and ordinary guest writes. Keep only a short accidental
/// root-destruction guard here; explicit per-launch approval remains the main
/// policy boundary.
enum IOSEmbeddedIshCommandPolicy {
    static let maxCommandLength = 32_000

    static func validate(_ command: String) -> IOSRemoteCommandPolicyResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Command is required.")
        }
        guard trimmed.count <= maxCommandLength else {
            return .failure("Embedded iSH scripts are limited to \(maxCommandLength) characters.")
        }

        let blockedPatterns = [
            #"(?i)\brm\s+(?=[^\n;]*(?:-(?:[a-z-]*r[a-z-]*f|[a-z-]*f[a-z-]*r)\b|--recursive\b[^\n;]*--force\b|--force\b[^\n;]*--recursive\b))[^\n;]*?\s(?:--\s+)?['\"]?/(?:['\"]?|\*|\.\??\*)\s*(?:$|[;&|])"#,
            #"(?i)\bfind\s+['\"]?/['\"]?\s+[^\n;]*-delete\b"#,
            #"(?i)\b(?:mkfs(?:\.[a-z0-9_-]+)?|shutdown|reboot|poweroff|halt)\b"#,
            #"(?i)\binit\s+0\b"#,
            #"(?i)\bkill\s+(?:-9|-kill)\s+1\b"#,
            #"(?i):\s*\(\s*\)\s*\{[^\n]*:\s*\|\s*:"#,
        ]
        if blockedPatterns.contains(where: {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }) {
            return .failure("Blocked a command that can destroy or stop the embedded iSH guest root environment.")
        }
        return .success(command)
    }
}

enum IOSPOSIXWorkingDirectory {
    static let embeddedDefault = "/workspace"

    static func normalized(_ value: String?, default defaultValue: String? = nil) throws -> String? {
        guard let rawValue = value?.nilIfBlank ?? defaultValue else { return nil }
        let path = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.first == "/" else {
            throw IOSPOSIXWorkingDirectoryError.notAbsolute
        }
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw IOSPOSIXWorkingDirectoryError.containsControlCharacters
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw IOSPOSIXWorkingDirectoryError.notCanonical
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func remoteCommand(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory else { return command }
        return "cd \(shellQuote(workingDirectory)) && \(command)"
    }

    static func embeddedCommand(_ command: String, workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && exec /bin/sh -lc \(shellQuote(command))"
    }
}

enum IOSPOSIXWorkingDirectoryError: LocalizedError {
    case notAbsolute
    case containsControlCharacters
    case notCanonical

    var errorDescription: String? {
        switch self {
        case .notAbsolute:
            "Working directory must be an absolute POSIX path."
        case .containsControlCharacters:
            "Working directory cannot contain NUL or line breaks."
        case .notCanonical:
            "Working directory cannot contain . or .. path components."
        }
    }
}

protocol IOSSSHRuntimeBackendProtocol: Sendable {
    func testConnection(profile: IOSSSHProfile, password: String) async throws -> IOSSSHConnectionProbeResult
    func execute(
        command: String,
        profile: IOSSSHProfile,
        password: String,
        timeout: TimeInterval,
        output: @escaping @Sendable (IOSSSHOutputChunk) -> Void
    ) async throws -> IOSSSHCommandResult
}

/// Seam for embedded-iSH job execution. The production witness is
/// `IOSEmbeddedIshRuntime.shared`; tests inject fakes so job orchestration
/// (streaming, cancellation, timeout) is verifiable in the stable test
/// bundle without linking the GPL runtime. Cancelling the task returned by
/// the surrounding job must terminate the guest command.
protocol IOSEmbeddedIshJobBackend: Sendable {
    func runJob(
        command: String,
        workingDirectory: String,
        timeoutSeconds: TimeInterval,
        onOutput: @escaping @Sendable (IOSEmbeddedIshOutputChunk) -> Void
    ) async -> IOSEmbeddedIshCommandResult
}

private final class IOSTerminalJobState {
    let id: String
    let runtime: IOSTerminalRuntimeKind
    let startedAt: Date
    var updatedAt: Date
    var status: IOSTerminalJobStatus
    var exitCode: Int?
    var outputTail: String
    var stdoutTail: String
    var stderrTail: String
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
    var lastOutputWasStderr: Bool?
    var error: String?
    var task: Task<Void, Never>?

    init(id: String, runtime: IOSTerminalRuntimeKind, startedAt: Date, status: IOSTerminalJobStatus) {
        self.id = id
        self.runtime = runtime
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.status = status
        self.outputTail = ""
        self.stdoutTail = ""
        self.stderrTail = ""
        self.stdoutTruncated = false
        self.stderrTruncated = false
    }

    var snapshot: IOSTerminalJobSnapshot {
        IOSTerminalJobSnapshot(
            id: id,
            runtime: runtime,
            status: status.rawValue,
            exitCode: exitCode,
            outputTail: outputTail,
            stdoutTail: stdoutTail,
            stderrTail: stderrTail,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            startedAt: startedAt,
            updatedAt: updatedAt,
            error: error
        )
    }
}

@MainActor
final class IOSTerminalRuntime {
    static let shared = IOSTerminalRuntime(sshBackend: IOSSSHRuntimeBackend())

    private static let outputTailLimit = 128 * 1024

    private let sshBackend: IOSSSHRuntimeBackendProtocol
    private let embeddedIshBackend: IOSEmbeddedIshJobBackend
    private let experimentalRuntimesLinked: Bool
    private var jobs: [String: IOSTerminalJobState] = [:]

    init(
        sshBackend: IOSSSHRuntimeBackendProtocol,
        embeddedIshBackend: IOSEmbeddedIshJobBackend = IOSEmbeddedIshRuntime.shared,
        experimentalRuntimesLinked: Bool = IOSTerminalBuildPolicy.experimentalRuntimesLinked
    ) {
        self.sshBackend = sshBackend
        self.embeddedIshBackend = embeddedIshBackend
        self.experimentalRuntimesLinked = experimentalRuntimesLinked
    }

    func testSSHConnection(profile: IOSSSHProfile, password: String) async throws -> IOSSSHConnectionProbeResult {
        let validated = try profile.validated()
        guard !password.isEmpty else { throw IOSSSHError.missingPassword }
        return try await sshBackend.testConnection(profile: validated, password: password)
    }

    func startJob(
        command: String,
        runtime: IOSTerminalRuntimeKind,
        experimentalEnabled: Bool,
        workingDirectory: String? = nil,
        amberShellStdin: String? = nil
    ) async -> IOSTerminalJobSnapshot {
        await startJob(
            command: command,
            runtime: runtime,
            experimentalEnabled: experimentalEnabled,
            workingDirectory: workingDirectory,
            sshProfile: nil,
            sshPassword: nil,
            amberShellStdin: amberShellStdin
        )
    }

    func startJob(
        command: String,
        runtime: IOSTerminalRuntimeKind,
        experimentalEnabled: Bool,
        workingDirectory: String? = nil,
        sshProfile: IOSSSHProfile?,
        sshPassword: String?,
        timeoutSeconds: TimeInterval = 60,
        jobId: String? = nil,
        workspaceStore: IOSWorkspaceStore = .shared,
        amberShellStdin: String? = nil,
        amberShellExecutionEvent: ((IOSAmberShellExecutionEvent) -> Void)? = nil
    ) async -> IOSTerminalJobSnapshot {
        let now = Date()
        let capability = IOSTerminalRuntimeCapabilities.capability(for: runtime)
        if capability.tier == .experimental && !experimentalRuntimesLinked {
            return failedSnapshot(
                runtime: runtime,
                command: command,
                now: now,
                message: "\(runtime.displayName) is not linked in this stable build.",
                id: jobId
            )
        }
        if capability.tier == .experimental && !experimentalEnabled {
            return failedSnapshot(
                runtime: runtime,
                command: command,
                now: now,
                message: "\(runtime.displayName) is experimental and disabled in the stable build.",
                id: jobId
            )
        }

        switch runtime {
        case .remoteSSH:
            return startSSHJob(
                command: command,
                workingDirectory: workingDirectory,
                now: now,
                profile: sshProfile,
                password: sshPassword,
                timeoutSeconds: timeoutSeconds,
                jobId: jobId
            )
        case .localIOSTools:
            do {
                let cwd = try IOSPOSIXWorkingDirectory.normalized(
                    workingDirectory,
                    default: IOSPOSIXWorkingDirectory.embeddedDefault
                ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
                guard cwd == IOSPOSIXWorkingDirectory.embeddedDefault else {
                    return failedSnapshot(
                        runtime: runtime,
                        command: command,
                        now: now,
                        message: "AmberShell currently exposes only /workspace.",
                        id: jobId
                    )
                }
                return try await runLocalTool(
                    command: command,
                    workingDirectory: cwd,
                    workspaceStore: workspaceStore,
                    amberShellStdin: amberShellStdin,
                    timeoutSeconds: timeoutSeconds,
                    now: now,
                    jobId: jobId,
                    onExecutionEvent: amberShellExecutionEvent
                )
            } catch {
                return failedSnapshot(
                    runtime: runtime,
                    command: command,
                    now: now,
                    message: error.localizedDescription,
                    id: jobId
                )
            }
        case .remoteMosh:
            return failedSnapshot(
                runtime: runtime,
                command: command,
                now: now,
                message: "Remote Mosh requires GPL/license review before it can be linked into a distributable build.",
                id: jobId
            )
        case .ishExperimental:
            return startEmbeddedIshJob(
                command: command,
                workingDirectory: workingDirectory,
                now: now,
                timeoutSeconds: timeoutSeconds,
                jobId: jobId
            )
        }
    }

    func readJob(id: String) -> IOSTerminalJobSnapshot? {
        jobs[id]?.snapshot
    }

    /// One-shot executors consume their terminal snapshot after constructing
    /// the tool result. Durable job handles remain available to read/wait/stop.
    func consumeTerminalJob(id: String) -> IOSTerminalJobSnapshot? {
        guard let job = jobs[id], job.status.isTerminal else { return nil }
        jobs.removeValue(forKey: id)
        return job.snapshot
    }

    func waitJob(id: String, timeoutSeconds: TimeInterval = 60) async -> IOSTerminalJobSnapshot? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            // Caller cancellation stops the wait, not the job: hand back the
            // current snapshot without mutating job state.
            guard !Task.isCancelled else { return jobs[id]?.snapshot }
            guard let job = jobs[id] else { return nil }
            if job.status.isTerminal {
                return job.snapshot
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let job = jobs[id] else { return nil }
        guard !job.status.isTerminal else { return job.snapshot }
        job.task?.cancel()
        job.status = .timedOut
        job.error = Self.timeoutMessage(for: job.runtime)
        job.updatedAt = Date()
        return job.snapshot
    }

    func stopJob(id: String) -> IOSTerminalJobSnapshot? {
        guard let job = jobs[id] else { return nil }
        guard !job.status.isTerminal else { return job.snapshot }
        job.task?.cancel()
        job.status = .cancelled
        job.error = Self.cancellationMessage(for: job.runtime)
        job.updatedAt = Date()
        return job.snapshot
    }

    private func startSSHJob(
        command: String,
        workingDirectory: String?,
        now: Date,
        profile: IOSSSHProfile?,
        password: String?,
        timeoutSeconds: TimeInterval,
        jobId: String?
    ) -> IOSTerminalJobSnapshot {
        let validatedCommand: String
        switch IOSRemoteCommandPolicy.validate(command) {
        case .success(let command):
            validatedCommand = command
        case .failure(let message):
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: message,
                id: jobId
            )
        }
        let normalizedWorkingDirectory: String?
        do {
            normalizedWorkingDirectory = try IOSPOSIXWorkingDirectory.normalized(workingDirectory)
        } catch {
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: error.localizedDescription,
                id: jobId
            )
        }
        let validated: IOSSSHProfile
        do {
            guard let profile else { throw IOSSSHError.noDefaultProfile }
            validated = try profile.validated()
            guard validated.knownHostSHA256?.isEmpty == false else {
                throw IOSSSHError.hostKeyNotTrusted("Run Test Connection and Trust Host first.")
            }
            guard let password, !password.isEmpty else { throw IOSSSHError.missingPassword }
        } catch {
            return failedSnapshot(
                runtime: .remoteSSH,
                command: command,
                now: now,
                message: error.localizedDescription,
                id: jobId
            )
        }

        let job = IOSTerminalJobState(
            id: jobId ?? UUID().uuidString,
            runtime: .remoteSSH,
            startedAt: now,
            status: .running
        )
        jobs[job.id] = job

        let jobId = job.id
        let sshBackend = sshBackend
        let sshPassword = password ?? ""
        job.task = Task {
            do {
                let result = try await sshBackend.execute(
                    command: IOSPOSIXWorkingDirectory.remoteCommand(
                        validatedCommand,
                        workingDirectory: normalizedWorkingDirectory
                    ),
                    profile: validated,
                    password: sshPassword,
                    timeout: timeoutSeconds,
                    output: { chunk in
                        Task { @MainActor in
                            self.appendOutput(chunk, to: jobId)
                        }
                    }
                )
                updateJob(
                    id: jobId,
                    status: result.exitCode == 0 ? .completed : .failed,
                    exitCode: result.exitCode,
                    output: result.output,
                    error: result.exitCode == 0 ? nil : "Remote command exited with \(result.exitCode ?? -1).",
                    stdout: result.stdout,
                    stderr: result.stderr
                )
            } catch is CancellationError {
                updateJob(
                    id: jobId,
                    status: .cancelled,
                    exitCode: nil,
                    output: nil,
                    error: IOSSSHError.commandCancelled.localizedDescription
                )
            } catch IOSSSHError.commandTimedOut {
                updateJob(
                    id: jobId,
                    status: .timedOut,
                    exitCode: nil,
                    output: nil,
                    error: IOSSSHError.commandTimedOut.localizedDescription
                )
            } catch {
                updateJob(
                    id: jobId,
                    status: .failed,
                    exitCode: nil,
                    output: nil,
                    error: error.localizedDescription
                )
            }
        }
        return job.snapshot
    }

    private func appendOutput(_ chunk: IOSSSHOutputChunk, to id: String) {
        guard let job = jobs[id], !chunk.text.isEmpty else { return }
        guard !job.status.isTerminal else { return }
        if chunk.isStderr {
            let value = job.stderrTail + chunk.text
            job.stderrTruncated = job.stderrTruncated || exceedsOutputLimit(value)
            job.stderrTail = limitedTail(value)
            if job.lastOutputWasStderr != true {
                let separator = job.outputTail.isEmpty || job.outputTail.hasSuffix("\n") ? "" : "\n"
                job.outputTail = limitedTail(job.outputTail + separator + "[stderr]\n")
            }
        } else {
            let value = job.stdoutTail + chunk.text
            job.stdoutTruncated = job.stdoutTruncated || exceedsOutputLimit(value)
            job.stdoutTail = limitedTail(value)
        }
        job.outputTail = limitedTail(job.outputTail + chunk.text)
        job.lastOutputWasStderr = chunk.isStderr
        job.updatedAt = Date()
    }

    private func appendOutput(_ chunk: IOSEmbeddedIshOutputChunk, to id: String) {
        guard let job = jobs[id], !chunk.text.isEmpty else { return }
        guard !job.status.isTerminal else { return }
        if chunk.isStderr {
            let value = job.stderrTail + chunk.text
            job.stderrTruncated = job.stderrTruncated || exceedsOutputLimit(value)
            job.stderrTail = limitedTail(value)
            if job.lastOutputWasStderr != true {
                let separator = job.outputTail.isEmpty || job.outputTail.hasSuffix("\n") ? "" : "\n"
                job.outputTail = limitedTail(job.outputTail + separator + "[stderr]\n")
            }
        } else {
            let value = job.stdoutTail + chunk.text
            job.stdoutTruncated = job.stdoutTruncated || exceedsOutputLimit(value)
            job.stdoutTail = limitedTail(value)
        }
        job.outputTail = limitedTail(job.outputTail + chunk.text)
        job.lastOutputWasStderr = chunk.isStderr
        job.updatedAt = Date()
    }

    private func updateJob(
        id: String,
        status: IOSTerminalJobStatus,
        exitCode: Int?,
        output: String?,
        error: String?,
        stdout: String? = nil,
        stderr: String? = nil,
        stdoutTruncated: Bool? = nil,
        stderrTruncated: Bool? = nil
    ) {
        guard let job = jobs[id] else { return }
        guard !job.status.isTerminal else { return }
        if let output {
            job.outputTail = limitedTail(output)
        }
        if let stdout {
            job.stdoutTruncated = stdoutTruncated ?? exceedsOutputLimit(stdout)
            job.stdoutTail = limitedTail(stdout)
        }
        if let stderr {
            job.stderrTruncated = stderrTruncated ?? exceedsOutputLimit(stderr)
            job.stderrTail = limitedTail(stderr)
        }
        job.status = status
        job.exitCode = exitCode
        job.error = error
        job.updatedAt = Date()
    }

    private func limitedTail(_ value: String) -> String {
        let utf8 = Array(value.utf8)
        guard utf8.count > Self.outputTailLimit else { return value }
        let suffix = utf8.suffix(Self.outputTailLimit)
        return String(decoding: suffix, as: UTF8.self)
    }

    private func exceedsOutputLimit(_ value: String) -> Bool {
        value.utf8.count > Self.outputTailLimit
    }

    private static func timeoutMessage(for runtime: IOSTerminalRuntimeKind) -> String {
        switch runtime {
        case .ishExperimental:
            "Embedded iSH command timed out."
        case .remoteSSH, .localIOSTools, .remoteMosh:
            IOSSSHError.commandTimedOut.localizedDescription
        }
    }

    private static func cancellationMessage(for runtime: IOSTerminalRuntimeKind) -> String {
        switch runtime {
        case .ishExperimental:
            "Embedded iSH command was cancelled."
        case .remoteSSH, .localIOSTools, .remoteMosh:
            IOSSSHError.commandCancelled.localizedDescription
        }
    }

    private func runLocalTool(
        command: String,
        workingDirectory: String,
        workspaceStore: IOSWorkspaceStore,
        amberShellStdin: String?,
        timeoutSeconds: TimeInterval,
        now: Date,
        jobId: String?,
        onExecutionEvent: ((IOSAmberShellExecutionEvent) -> Void)?
    ) async throws -> IOSTerminalJobSnapshot {
        let control = try IOSAmberShellExecutionControl(timeoutSeconds: timeoutSeconds)
        let result = await withTaskCancellationHandler {
            await IOSAmberShellEngine.execute(
                command: command,
                stdin: amberShellStdin,
                workspaceStore: workspaceStore,
                control: control,
                onExecutionEvent: onExecutionEvent
            )
        } onCancel: {
            control.cancel()
        }

        var finalTermination = result.termination
        // A final checkpoint is valid only before any mutation was dispatched.
        // Otherwise it can turn a known commit into a retryable cancellation.
        if result.dispatchOutcome == .notDispatched {
            do {
                try control.checkpoint()
            } catch let termination as IOSAmberShellTermination {
                finalTermination = termination
            }
        }

        let mayHaveApplied = result.dispatchOutcome == .mayHaveApplied
        let status: String
        let terminationError: String?
        switch (mayHaveApplied, finalTermination) {
        case (true, _):
            status = "unknown_after_action"
            terminationError = "AmberShell action may have applied before execution stopped; the outcome is unknown."
        case (false, .cancelled):
            status = IOSTerminalJobStatus.cancelled.rawValue
            terminationError = "AmberShell command was cancelled."
        case (false, .timedOut):
            status = IOSTerminalJobStatus.timedOut.rawValue
            terminationError = "AmberShell command timed out after \(Int(timeoutSeconds)) seconds."
        case (false, nil):
            status = result.exitCode == 0
                ? IOSTerminalJobStatus.completed.rawValue
                : IOSTerminalJobStatus.failed.rawValue
            terminationError = nil
        }
        let stderr = terminationError.map { $0 + "\n" } ?? result.stderr
        let outputTail = result.stdout + stderr
        let completed = status == IOSTerminalJobStatus.completed.rawValue

        return IOSTerminalJobSnapshot(
            id: jobId ?? UUID().uuidString,
            runtime: .localIOSTools,
            status: status,
            exitCode: finalTermination == nil && !mayHaveApplied ? result.exitCode : nil,
            outputTail: outputTail,
            stdoutTail: result.stdout,
            stderrTail: stderr,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated,
            startedAt: now,
            updatedAt: Date(),
            error: completed ? nil : (terminationError ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    private func failedSnapshot(
        runtime: IOSTerminalRuntimeKind,
        command: String,
        now: Date,
        message: String,
        id: String? = nil
    ) -> IOSTerminalJobSnapshot {
        IOSTerminalJobSnapshot(
            id: id ?? UUID().uuidString,
            runtime: runtime,
            status: IOSTerminalJobStatus.failed.rawValue,
            exitCode: nil,
            outputTail: "\(message)\nCommand: \(command)",
            stdoutTail: "",
            startedAt: now,
            updatedAt: Date(),
            error: message
        )
    }
}

// MARK: - Embedded iSH job execution

extension IOSTerminalRuntime {
    private func startEmbeddedIshJob(
        command: String,
        workingDirectory: String?,
        now: Date,
        timeoutSeconds: TimeInterval,
        jobId: String?
    ) -> IOSTerminalJobSnapshot {
        let validatedCommand: String
        switch IOSEmbeddedIshCommandPolicy.validate(command) {
        case .success(let command):
            validatedCommand = command
        case .failure(let message):
            return failedSnapshot(
                runtime: .ishExperimental,
                command: command,
                now: now,
                message: message,
                id: jobId
            )
        }
        let normalizedWorkingDirectory: String
        do {
            normalizedWorkingDirectory = try IOSPOSIXWorkingDirectory.normalized(
                workingDirectory,
                default: IOSPOSIXWorkingDirectory.embeddedDefault
            ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
        } catch {
            return failedSnapshot(
                runtime: .ishExperimental,
                command: command,
                now: now,
                message: error.localizedDescription,
                id: jobId
            )
        }

        let job = IOSTerminalJobState(
            id: jobId ?? UUID().uuidString,
            runtime: .ishExperimental,
            startedAt: now,
            status: .running
        )
        jobs[job.id] = job

        let jobId = job.id
        let embeddedIshBackend = embeddedIshBackend
        job.task = Task {
            let result = await embeddedIshBackend.runJob(
                command: validatedCommand,
                workingDirectory: normalizedWorkingDirectory,
                timeoutSeconds: timeoutSeconds,
                onOutput: { chunk in
                    Task { @MainActor in
                        self.appendOutput(chunk, to: jobId)
                    }
                }
            )
            guard !Task.isCancelled else {
                updateJob(
                    id: jobId,
                    status: .cancelled,
                    exitCode: nil,
                    output: nil,
                    error: Self.cancellationMessage(for: .ishExperimental)
                )
                return
            }
            let output = Self.embeddedIshOutput(stdout: result.stdout, stderr: result.stderr)
            let status: IOSTerminalJobStatus
            if result.timedOut {
                status = .timedOut
            } else if result.exitCode == 0, result.error == nil {
                status = .completed
            } else {
                status = .failed
            }
            updateJob(
                id: jobId,
                status: status,
                exitCode: result.exitCode,
                output: output,
                error: result.error ?? (status == .failed ? "Embedded iSH command exited with \(result.exitCode ?? -1)." : nil),
                stdout: result.stdout,
                stderr: result.stderr,
                stdoutTruncated: result.stdoutTruncated,
                stderrTruncated: result.stderrTruncated
            )
        }
        return job.snapshot
    }

    private static func embeddedIshOutput(stdout: String, stderr: String) -> String {
        var parts: [String] = []
        if !stdout.isEmpty {
            parts.append(stdout)
        }
        if !stderr.isEmpty {
            parts.append("[stderr]\n\(stderr)")
        }
        return parts.joined(separator: stdout.hasSuffix("\n") ? "" : "\n")
    }
}

// MARK: - Agent Remote SSH execution

private struct IOSRemoteTerminalExecuteRequest {
    let command: String
    let profileId: String?
    let timeoutSeconds: TimeInterval
    let purpose: String?
    let workingDirectory: String?
}

@MainActor
enum IOSRemoteTerminalExecuteExecutor {
    private static let defaultTimeout: TimeInterval = 60
    private static let maxTimeout: TimeInterval = 180

    static func execute(
        input: String,
        settingsStore: SettingsStore?,
        runtime: IOSTerminalRuntime = .shared,
        expectedProfileId: String? = nil,
        expectedTargetDigest: String? = nil
    ) async -> String {
        do {
            let request = try parseRequest(input)
            guard let settingsStore else {
                throw IOSRemoteTerminalExecuteError.settingsUnavailable
            }
            let profile: IOSSSHProfile
            let effectiveProfileId = expectedProfileId ?? request.profileId
            if let requestProfileId = request.profileId,
               let expectedProfileId,
               requestProfileId != expectedProfileId {
                throw IOSRemoteTerminalExecuteError.approvedTargetChanged
            }
            if let profileId = effectiveProfileId {
                guard let selected = settingsStore.sshProfiles.first(where: { $0.id == profileId }) else {
                    throw IOSRemoteTerminalExecuteError.profileNotFound(profileId)
                }
                profile = selected
            } else {
                guard let selected = settingsStore.defaultSSHProfile else {
                    throw IOSSSHError.noDefaultProfile
                }
                profile = selected
            }
            if let expectedTargetDigest,
               expectedTargetDigest != remoteSSHTargetDigest(profile) {
                throw IOSRemoteTerminalExecuteError.approvedTargetChanged
            }
            let password = settingsStore.passwordForSSHProfile(id: profile.id) ?? ""
            return await execute(request: request, profile: profile, password: password, runtime: runtime)
        } catch {
            return failureJSON(error)
        }
    }

    static func execute(
        input: String,
        profile: IOSSSHProfile,
        password: String,
        runtime: IOSTerminalRuntime
    ) async -> String {
        do {
            return await execute(
                request: try parseRequest(input),
                profile: profile,
                password: password,
                runtime: runtime
            )
        } catch {
            return failureJSON(error)
        }
    }

    static func approvalPreview(
        input: String,
        settingsStore: SettingsStore? = nil
    ) -> IshHandoffToolApprovalRequest? {
        guard let request = try? parseRequest(input), let settingsStore else { return nil }
        let profile: IOSSSHProfile
        if let profileId = request.profileId {
            guard let selected = settingsStore.sshProfiles.first(where: { $0.id == profileId }) else {
                return nil
            }
            profile = selected
        } else {
            guard let selected = settingsStore.defaultSSHProfile else { return nil }
            profile = selected
        }
        let profileLabel = "\(profile.displayName) · \(profile.username)@\(profile.host):\(profile.port)"
        let targetLabel = request.workingDirectory.map { "\(profileLabel) · \($0)" } ?? profileLabel
        return IshHandoffToolApprovalRequest(
            id: chatInputDigest(for: input),
            mode: .remoteSSH,
            commandPreview: request.command,
            filename: targetLabel,
            reason: "Amber 将在已信任的 Remote SSH 连接上执行一次非交互命令，并回传 stdout/stderr/exit code。",
            remoteProfileId: profile.id,
            remoteTargetDigest: remoteSSHTargetDigest(profile)
        )
    }

    private static func execute(
        request: IOSRemoteTerminalExecuteRequest,
        profile: IOSSSHProfile,
        password: String,
        runtime: IOSTerminalRuntime
    ) async -> String {
        let started = await runtime.startJob(
            command: request.command,
            runtime: .remoteSSH,
            experimentalEnabled: false,
            workingDirectory: request.workingDirectory,
            sshProfile: profile,
            sshPassword: password,
            timeoutSeconds: request.timeoutSeconds
        )
        var snapshot = started
        if started.status == IOSTerminalJobStatus.running.rawValue {
            snapshot = await runtime.waitJob(
                id: started.id,
                timeoutSeconds: request.timeoutSeconds + 1
            ) ?? started
            if Task.isCancelled {
                snapshot = runtime.stopJob(id: started.id) ?? snapshot
            }
        }
        _ = runtime.consumeTerminalJob(id: started.id)

        let completed = snapshot.status == IOSTerminalJobStatus.completed.rawValue && snapshot.exitCode == 0
        let exitCode: Any = snapshot.exitCode.map { $0 as Any } ?? NSNull()
        return IOSWorkspaceStore.json([
            "ok": completed,
            "tool": "terminal_execute",
            "runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue,
            "profile_id": profile.id,
            "profile_name": profile.displayName,
            "cwd": request.workingDirectory ?? "",
            "status": snapshot.status,
            "purpose": request.purpose ?? "",
            "exit_code": exitCode,
            "stdout": snapshot.stdoutTail,
            "stderr": snapshot.stderrTail,
            "stdout_available": true,
            "stderr_available": true,
            "exit_code_available": snapshot.exitCode != nil,
            "timed_out": snapshot.status == IOSTerminalJobStatus.timedOut.rawValue,
            "error": snapshot.error ?? ""
        ])
    }

    private static func parseRequest(_ input: String) throws -> IOSRemoteTerminalExecuteRequest {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSRemoteTerminalExecuteError.emptyInput }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return IOSRemoteTerminalExecuteRequest(
                command: trimmed,
                profileId: nil,
                timeoutSeconds: defaultTimeout,
                purpose: nil,
                workingDirectory: nil
            )
        }
        guard let command = nonEmptyString(object["command"]) else {
            throw IOSRemoteTerminalExecuteError.emptyInput
        }
        let timeout = numericValue(object["timeout_seconds"]) ?? defaultTimeout
        return IOSRemoteTerminalExecuteRequest(
            command: command,
            profileId: nonEmptyString(object["profile_id"]),
            timeoutSeconds: min(max(1, timeout), maxTimeout),
            purpose: nonEmptyString(object["purpose"]),
            workingDirectory: try workingDirectory(from: object)
        )
    }

    private static func failureJSON(_ error: Error, purpose: String? = nil) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": "terminal_execute",
            "runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue,
            "status": IOSTerminalJobStatus.failed.rawValue,
            "purpose": purpose ?? "",
            "exit_code": NSNull(),
            "stdout": "",
            "stderr": "",
            "stdout_available": false,
            "stderr_available": false,
            "exit_code_available": false,
            "timed_out": false,
            "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        ])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workingDirectory(from object: [String: Any]) throws -> String? {
        guard let value = object["cwd"] else { return nil }
        guard let string = value as? String else {
            throw IOSRemoteTerminalExecuteError.invalidArguments("cwd must be a string.")
        }
        return try IOSPOSIXWorkingDirectory.normalized(string)
    }

    private static func numericValue(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

}

// MARK: - Agent AmberShell execution

private struct IOSAmberShellExecuteRequest {
    let command: String
    let stdin: String?
    let purpose: String?
    let workingDirectory: String
    let timeoutSeconds: TimeInterval
}

@MainActor
enum IOSAmberShellExecuteExecutor {
    static func execute(
        input: String,
        runtime: IOSTerminalRuntime = .shared,
        workspaceStore: IOSWorkspaceStore = .shared,
        onExecutionEvent: ((IOSAmberShellExecutionEvent) -> Void)? = nil
    ) async -> String {
        do {
            let request = try parseRequest(input)
            let snapshot = await runtime.startJob(
                command: request.command,
                runtime: .localIOSTools,
                experimentalEnabled: false,
                workingDirectory: request.workingDirectory,
                sshProfile: nil,
                sshPassword: nil,
                timeoutSeconds: request.timeoutSeconds,
                workspaceStore: workspaceStore,
                amberShellStdin: request.stdin,
                amberShellExecutionEvent: onExecutionEvent
            )
            let completed = snapshot.status == IOSTerminalJobStatus.completed.rawValue
                && snapshot.exitCode == 0
            let mayHaveApplied = snapshot.status == "unknown_after_action"
            return IOSWorkspaceStore.json([
                "ok": completed,
                "tool": IOSAmberShellToolCatalog.executeToolName,
                "runtime": IOSTerminalRuntimeKind.localIOSTools.rawValue,
                "cwd": request.workingDirectory,
                "status": snapshot.status,
                "purpose": request.purpose ?? "",
                "exit_code": snapshot.exitCode.map { $0 as Any } ?? NSNull(),
                "stdout": snapshot.stdoutTail,
                "stderr": snapshot.stderrTail,
                "stdout_available": true,
                "stderr_available": true,
                "exit_code_available": snapshot.exitCode != nil,
                "stdout_truncated": snapshot.stdoutTruncated,
                "stderr_truncated": snapshot.stderrTruncated,
                "timed_out": snapshot.status == IOSTerminalJobStatus.timedOut.rawValue,
                "error_code": mayHaveApplied ? "unknown_after_action" : "",
                "may_have_applied": mayHaveApplied,
                "error": snapshot.error ?? "",
            ])
        } catch {
            return failureJSON(error)
        }
    }

    static func approvalPreview(input: String) -> IshHandoffToolApprovalRequest? {
        guard let request = try? parseRequest(input) else { return nil }
        return IshHandoffToolApprovalRequest(
            id: chatInputDigest(for: input),
            mode: .amberShell,
            commandPreview: request.command,
            filename: "AmberShell · \(request.workingDirectory)",
            reason: IOSAppLocalization.string(
                "Amber 将在 App 自有 /workspace 中执行一次非交互 AmberShell 命令，并回传 stdout/stderr/exit code。",
                defaultValue: "Amber 将在 App 自有 /workspace 中执行一次非交互 AmberShell 命令，并回传 stdout/stderr/exit code。"
            ),
            contextLines: [
                IOSAppLocalization.string(
                    "模式：稳定版本地执行（无 PTY）",
                    defaultValue: "模式：稳定版本地执行（无 PTY）"
                ),
                IOSAppLocalization.formatted(
                    "工作目录：%@",
                    defaultValue: "工作目录：%@",
                    arguments: [request.workingDirectory]
                ),
                IOSAppLocalization.formatted(
                    "超时：%lld 秒（协作式）",
                    defaultValue: "超时：%lld 秒（协作式）",
                    arguments: [Int64(request.timeoutSeconds)]
                ),
            ] + (request.stdin.map {
                $0.isEmpty ? [] : [IOSAppLocalization.formatted(
                    "stdin：%lld bytes",
                    defaultValue: "stdin：%lld bytes",
                    arguments: [Int64($0.utf8.count)]
                )]
            } ?? [])
        )
    }

    private static func parseRequest(_ input: String) throws -> IOSAmberShellExecuteRequest {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSAmberShellExecuteError.emptyInput }

        let object: [String: Any]
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = decoded
        } else {
            object = ["command": trimmed]
        }
        guard let command = nonEmptyString(object["command"]) else {
            throw IOSAmberShellExecuteError.emptyInput
        }
        let cwd = try IOSPOSIXWorkingDirectory.normalized(
            object["cwd"] as? String,
            default: IOSPOSIXWorkingDirectory.embeddedDefault
        ) ?? IOSPOSIXWorkingDirectory.embeddedDefault
        guard cwd == IOSPOSIXWorkingDirectory.embeddedDefault else {
            throw IOSAmberShellExecuteError.unsupportedWorkingDirectory(cwd)
        }
        let stdin: String?
        if let rawStdin = object["stdin"] {
            guard let value = rawStdin as? String else {
                throw IOSAmberShellExecuteError.invalidArguments("stdin must be a string.")
            }
            guard value.utf8.count <= IOSAmberShellInputContract.maxStdinBytes else {
                throw IOSAmberShellExecuteError.invalidArguments(
                    "stdin cannot exceed \(IOSAmberShellInputContract.maxStdinBytes) UTF-8 bytes."
                )
            }
            stdin = value
        } else {
            stdin = nil
        }
        let timeoutSeconds: TimeInterval
        if let rawTimeout = object["timeout_seconds"] {
            guard let number = rawTimeout as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw IOSAmberShellExecuteError.invalidArguments(
                    "timeout_seconds must be an integer from 1 through 180."
                )
            }
            let value = number.doubleValue
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  (1...180).contains(value) else {
                throw IOSAmberShellExecuteError.invalidArguments(
                    "timeout_seconds must be an integer from 1 through 180."
                )
            }
            timeoutSeconds = value
        } else {
            timeoutSeconds = 60
        }
        return IOSAmberShellExecuteRequest(
            command: command,
            stdin: stdin,
            purpose: nonEmptyString(object["purpose"]),
            workingDirectory: cwd,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func failureJSON(_ error: Error) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": IOSAmberShellToolCatalog.executeToolName,
            "runtime": IOSTerminalRuntimeKind.localIOSTools.rawValue,
            "status": IOSTerminalJobStatus.failed.rawValue,
            "exit_code": NSNull(),
            "stdout": "",
            "stderr": "",
            "stdout_available": false,
            "stderr_available": false,
            "exit_code_available": false,
            "timed_out": false,
            "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        ])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}

// MARK: - Agent terminal jobs

private struct IOSRemoteTerminalJobStartRequest {
    let command: String
    let profileId: String?
    let timeoutSeconds: TimeInterval
    let purpose: String?
    let workingDirectory: String?
}

private struct IOSRemoteTerminalJobReferenceRequest {
    let jobId: String
    let waitTimeoutSeconds: TimeInterval
}

@MainActor
enum IOSAgentTerminalJobExecutor {
    private static let defaultCommandTimeout: TimeInterval = 60
    private static let maxCommandTimeout: TimeInterval = 180
    private static let defaultWaitTimeout: TimeInterval = 10
    private static let maxWaitTimeout: TimeInterval = 30

    static func execute(
        toolName: String,
        input: String,
        settingsStore: SettingsStore?,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore,
        expectedProfileId: String? = nil,
        expectedTargetDigest: String? = nil
    ) async -> String {
        do {
            switch toolName {
            case IOSRemoteTerminalToolCatalog.jobStartToolName:
                return try await start(
                    request: parseStartRequest(input),
                    settingsStore: settingsStore,
                    runtime: runtime,
                    taskStore: taskStore,
                    expectedProfileId: expectedProfileId,
                    expectedTargetDigest: expectedTargetDigest
                )
            case IOSRemoteTerminalToolCatalog.jobReadToolName:
                return try read(
                    request: parseReferenceRequest(input, allowsWait: false),
                    runtime: runtime,
                    taskStore: taskStore,
                    toolName: toolName
                )
            case IOSRemoteTerminalToolCatalog.jobWaitToolName:
                return try await wait(
                    request: parseReferenceRequest(input, allowsWait: true),
                    runtime: runtime,
                    taskStore: taskStore
                )
            case IOSRemoteTerminalToolCatalog.jobStopToolName:
                return try stop(
                    request: parseReferenceRequest(input, allowsWait: false),
                    runtime: runtime,
                    taskStore: taskStore
                )
            default:
                throw IOSRemoteTerminalJobError.unsupportedTool(toolName)
            }
        } catch let error as IOSRemoteTerminalJobError {
            let responseRuntime = error.jobId
                .flatMap { taskStore.task(id: $0) }
                .flatMap(runtimeKind(for:))
            return failureJSON(
                toolName: toolName,
                jobId: error.jobId,
                runtime: responseRuntime,
                errorCode: error.code,
                message: error.localizedDescription
            )
        } catch {
            return failureJSON(
                toolName: toolName,
                jobId: nil,
                runtime: nil,
                errorCode: "invalid_arguments",
                message: error.localizedDescription
            )
        }
    }

    static func startEmbeddedJob(
        command: String,
        purpose: String?,
        workingDirectory: String,
        timeoutSeconds: TimeInterval,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) async -> String {
        let jobId = UUID().uuidString
        let now = Date()
        taskStore.startTask(
            id: jobId,
            kind: .embeddedIsh,
            title: purpose ?? "Agent 内置 iSH 作业",
            objective: purpose ?? command,
            connectionSummary: "ExperimentalGPL 内置 iSH · \(workingDirectory)",
            commandPreview: command,
            sourceToolName: "ios_ish_execute",
            metadata: [
                "terminal_job": "true",
                "runtime": IOSTerminalRuntimeKind.ishExperimental.rawValue,
                "purpose": purpose ?? "",
                "cwd": workingDirectory,
                "execution_mode": "background",
                "lifecycle": "process_local",
                "command_timeout_seconds": String(Int(timeoutSeconds)),
                "started_at_ms": milliseconds(now),
                "stdout_tail": "",
                "stderr_tail": "",
            ],
            now: now
        )

        let started = await runtime.startJob(
            command: command,
            runtime: .ishExperimental,
            experimentalEnabled: true,
            workingDirectory: workingDirectory,
            sshProfile: nil,
            sshPassword: nil,
            timeoutSeconds: timeoutSeconds,
            jobId: jobId
        )
        persist(snapshot: started, taskId: jobId, taskStore: taskStore)

        if started.status == IOSTerminalJobStatus.running.rawValue {
            Task { @MainActor in
                if let finished = await runtime.waitJob(
                    id: jobId,
                    timeoutSeconds: timeoutSeconds + 1
                ) {
                    persist(snapshot: finished, taskId: jobId, taskStore: taskStore)
                    _ = runtime.consumeTerminalJob(id: jobId)
                }
            }
        }
        return responseJSON(
            toolName: "ios_ish_execute",
            jobId: jobId,
            snapshot: started,
            record: taskStore.task(id: jobId),
            operationOK: started.status == IOSTerminalJobStatus.running.rawValue,
            waitTimedOut: false,
            alreadyTerminal: false
        )
    }

    static func approvalPreview(
        toolName: String,
        input: String,
        settingsStore: SettingsStore?,
        taskStore: IOSAdvancedTaskStore
    ) -> IshHandoffToolApprovalRequest? {
        switch toolName {
        case IOSRemoteTerminalToolCatalog.jobStartToolName:
            guard let request = try? parseStartRequest(input) else { return nil }
            guard let profile = resolvedProfile(profileId: request.profileId, settingsStore: settingsStore) else {
                return nil
            }
            return IshHandoffToolApprovalRequest(
                id: chatInputDigest(for: input),
                mode: .remoteJobStart,
                commandPreview: request.command,
                filename: targetLabel(
                    profile: profile,
                    profileId: request.profileId,
                    workingDirectory: request.workingDirectory
                ),
                reason: "Amber 将在已信任的 Remote SSH 连接上启动一个可轮询的非 PTY 作业。",
                contextLines: [
                    "模式：异步 Job（无 PTY、无 stdin）",
                    "工作目录：\(request.workingDirectory ?? "SSH 账户默认目录")",
                    "超时：\(Int(request.timeoutSeconds)) 秒",
                ],
                remoteProfileId: profile.id,
                remoteTargetDigest: remoteSSHTargetDigest(profile)
            )
        case IOSRemoteTerminalToolCatalog.jobStopToolName:
            guard let request = try? parseReferenceRequest(input, allowsWait: false) else { return nil }
            let record = taskStore.task(id: request.jobId)
            let isEmbedded = record?.kind == .embeddedIsh
            return IshHandoffToolApprovalRequest(
                id: chatInputDigest(for: input),
                mode: isEmbedded ? .embeddedJobStop : .remoteJobStop,
                commandPreview: record?.commandPreview.nilIfBlank
                    ?? "停止终端作业 \(request.jobId)",
                filename: record?.connectionSummary.nilIfBlank ?? "Job · \(String(request.jobId.prefix(12)))",
                reason: isEmbedded
                    ? "Amber 将取消当前 App 进程仍在控制的内置 iSH 非 PTY 作业。"
                    : "Amber 将取消当前 App 进程仍在控制的 Remote SSH 作业。",
                contextLines: [
                    "Job ID：\(request.jobId)",
                    "运行环境：\(isEmbedded ? "ExperimentalGPL 内置 iSH" : "Remote SSH")",
                ]
            )
        default:
            return nil
        }
    }

    private static func start(
        request: IOSRemoteTerminalJobStartRequest,
        settingsStore: SettingsStore?,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore,
        expectedProfileId: String?,
        expectedTargetDigest: String?
    ) async throws -> String {
        guard let settingsStore else { throw IOSRemoteTerminalJobError.settingsUnavailable }
        if let requestProfileId = request.profileId,
           let expectedProfileId,
           requestProfileId != expectedProfileId {
            throw IOSRemoteTerminalJobError.approvedTargetChanged
        }
        let effectiveProfileId = expectedProfileId ?? request.profileId
        guard let profile = resolvedProfile(profileId: effectiveProfileId, settingsStore: settingsStore) else {
            if let profileId = effectiveProfileId {
                throw IOSRemoteTerminalJobError.profileNotFound(profileId)
            }
            throw IOSRemoteTerminalJobError.noDefaultProfile
        }
        if let expectedTargetDigest,
           expectedTargetDigest != remoteSSHTargetDigest(profile) {
            throw IOSRemoteTerminalJobError.approvedTargetChanged
        }
        let password = settingsStore.passwordForSSHProfile(id: profile.id) ?? ""
        let jobId = UUID().uuidString
        let now = Date()
        taskStore.startTask(
            id: jobId,
            kind: .remoteCommand,
            title: request.purpose ?? "Agent Remote SSH 作业",
            objective: request.purpose ?? request.command,
            connectionSummary: profileLabel(profile: profile, profileId: profile.id),
            commandPreview: request.command,
            sourceToolName: IOSRemoteTerminalToolCatalog.jobStartToolName,
            metadata: [
                "terminal_job": "true",
                "runtime": IOSTerminalRuntimeKind.remoteSSH.rawValue,
                "profile_id": profile.id,
                "profile_name": profile.displayName,
                "purpose": request.purpose ?? "",
                "cwd": request.workingDirectory ?? "",
                "execution_mode": "background",
                "lifecycle": "process_local",
                "command_timeout_seconds": String(Int(request.timeoutSeconds)),
                "started_at_ms": milliseconds(now),
                "stdout_tail": "",
                "stderr_tail": "",
            ],
            now: now
        )

        let started = await runtime.startJob(
            command: request.command,
            runtime: .remoteSSH,
            experimentalEnabled: false,
            workingDirectory: request.workingDirectory,
            sshProfile: profile,
            sshPassword: password,
            timeoutSeconds: request.timeoutSeconds,
            jobId: jobId
        )
        persist(snapshot: started, taskId: jobId, taskStore: taskStore)

        if started.status == IOSTerminalJobStatus.running.rawValue {
            Task { @MainActor in
                if let finished = await runtime.waitJob(
                    id: jobId,
                    timeoutSeconds: request.timeoutSeconds + 1
                ) {
                    persist(snapshot: finished, taskId: jobId, taskStore: taskStore)
                    _ = runtime.consumeTerminalJob(id: jobId)
                }
            }
        }
        return responseJSON(
            toolName: IOSRemoteTerminalToolCatalog.jobStartToolName,
            jobId: jobId,
            snapshot: started,
            record: taskStore.task(id: jobId),
            operationOK: started.status == IOSTerminalJobStatus.running.rawValue,
            waitTimedOut: false,
            alreadyTerminal: false
        )
    }

    private static func read(
        request: IOSRemoteTerminalJobReferenceRequest,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore,
        toolName: String
    ) throws -> String {
        let resolved = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
        return responseJSON(
            toolName: toolName,
            jobId: request.jobId,
            snapshot: resolved.snapshot,
            record: resolved.record,
            operationOK: true,
            waitTimedOut: false,
            alreadyTerminal: resolved.status.isTerminal
        )
    }

    private static func wait(
        request: IOSRemoteTerminalJobReferenceRequest,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) async throws -> String {
        let initial = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
        if initial.status.isTerminal {
            _ = runtime.consumeTerminalJob(id: request.jobId)
            return responseJSON(
                toolName: IOSRemoteTerminalToolCatalog.jobWaitToolName,
                jobId: request.jobId,
                snapshot: initial.snapshot,
                record: initial.record,
                operationOK: true,
                waitTimedOut: false,
                alreadyTerminal: true
            )
        }

        let deadline = Date().addingTimeInterval(request.waitTimeoutSeconds)
        var latest = initial
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            latest = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
            if latest.status.isTerminal { break }
        }
        if latest.status.isTerminal {
            _ = runtime.consumeTerminalJob(id: request.jobId)
        }
        return responseJSON(
            toolName: IOSRemoteTerminalToolCatalog.jobWaitToolName,
            jobId: request.jobId,
            snapshot: latest.snapshot,
            record: latest.record,
            operationOK: true,
            waitTimedOut: !latest.status.isTerminal,
            alreadyTerminal: false
        )
    }

    private static func stop(
        request: IOSRemoteTerminalJobReferenceRequest,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) throws -> String {
        let current = try resolveSnapshot(jobId: request.jobId, runtime: runtime, taskStore: taskStore)
        if current.status.isTerminal {
            return responseJSON(
                toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
                jobId: request.jobId,
                snapshot: current.snapshot,
                record: current.record,
                operationOK: true,
                waitTimedOut: false,
                alreadyTerminal: true
            )
        }
        guard let stopped = runtime.stopJob(id: request.jobId) else {
            let interrupted = interruptMissingRuntimeJob(record: current.record, taskStore: taskStore)
            return responseJSON(
                toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
                jobId: request.jobId,
                snapshot: nil,
                record: interrupted,
                operationOK: true,
                waitTimedOut: false,
                alreadyTerminal: false
            )
        }
        persist(snapshot: stopped, taskId: request.jobId, taskStore: taskStore)
        _ = runtime.consumeTerminalJob(id: request.jobId)
        return responseJSON(
            toolName: IOSRemoteTerminalToolCatalog.jobStopToolName,
            jobId: request.jobId,
            snapshot: stopped,
            record: taskStore.task(id: request.jobId),
            operationOK: true,
            waitTimedOut: false,
            alreadyTerminal: false
        )
    }

    private static func resolveSnapshot(
        jobId: String,
        runtime: IOSTerminalRuntime,
        taskStore: IOSAdvancedTaskStore
    ) throws -> (snapshot: IOSTerminalJobSnapshot?, record: IOSAdvancedTaskRecord, status: IOSAdvancedTaskStatus) {
        guard var record = taskStore.task(id: jobId),
              runtimeKind(for: record) != nil,
              record.metadata["terminal_job"] == "true" else {
            throw IOSRemoteTerminalJobError.jobNotFound(jobId)
        }
        if let snapshot = runtime.readJob(id: jobId) {
            let changed = record.status != advancedStatus(snapshot.status)
                || record.metadata["updated_at_ms"] != milliseconds(snapshot.updatedAt)
            if changed {
                persist(snapshot: snapshot, taskId: jobId, taskStore: taskStore)
                record = taskStore.task(id: jobId) ?? record
            }
            return (snapshot, record, record.status)
        }
        if record.status == .running {
            record = interruptMissingRuntimeJob(record: record, taskStore: taskStore) ?? record
        }
        return (nil, record, record.status)
    }

    @discardableResult
    private static func interruptMissingRuntimeJob(
        record: IOSAdvancedTaskRecord,
        taskStore: IOSAdvancedTaskStore
    ) -> IOSAdvancedTaskRecord? {
        let isEmbedded = record.kind == .embeddedIsh
        return taskStore.updateTask(
            id: record.id,
            status: .interrupted,
            resultSummary: isEmbedded
                ? "应用进程已结束，内置 iSH 命令的最终结果未知。"
                : "应用进程已结束，远程命令的最终结果未知。",
            error: isEmbedded
                ? "无法重新连接该内置 iSH 作业。"
                : "无法重新连接该 Remote SSH 作业。",
            retryable: false,
            cancelCapability: false,
            metadata: [
                "interruption_reason": "process_terminated",
                "outcome": "unknown",
            ]
        )
    }

    private static func persist(
        snapshot: IOSTerminalJobSnapshot,
        taskId: String,
        taskStore: IOSAdvancedTaskStore
    ) {
        let status = advancedStatus(snapshot.status)
        let runtimeTitle = snapshot.runtime == .ishExperimental ? "内置 iSH" : "Remote SSH"
        let summary: String
        switch status {
        case .running, .queued:
            summary = ""
        case .completed:
            summary = "\(runtimeTitle) 作业已完成。"
        case .failed:
            summary = "\(runtimeTitle) 作业执行失败。"
        case .cancelled:
            summary = "\(runtimeTitle) 作业已取消。"
        case .timedOut:
            summary = "\(runtimeTitle) 作业已超时。"
        case .interrupted:
            summary = "\(runtimeTitle) 作业已中断。"
        case .approvalRequired:
            summary = "\(runtimeTitle) 作业等待确认。"
        }
        taskStore.updateTask(
            id: taskId,
            status: status,
            resultSummary: summary,
            logTail: snapshot.outputTail,
            error: snapshot.error ?? "",
            retryable: false,
            cancelCapability: status == .running,
            metadata: [
                "runtime_job_id": snapshot.id,
                "runtime": snapshot.runtime.rawValue,
                "stdout_tail": snapshot.stdoutTail,
                "stderr_tail": snapshot.stderrTail,
                "stdout_truncated": String(snapshot.stdoutTruncated),
                "stderr_truncated": String(snapshot.stderrTruncated),
                "stdout_persisted_truncated": String(snapshot.stdoutTail.count > 4_000),
                "stderr_persisted_truncated": String(snapshot.stderrTail.count > 4_000),
                "exit_code": snapshot.exitCode.map(String.init) ?? "",
                "started_at_ms": milliseconds(snapshot.startedAt),
                "updated_at_ms": milliseconds(snapshot.updatedAt),
            ]
        )
    }

    private static func responseJSON(
        toolName: String,
        jobId: String,
        snapshot: IOSTerminalJobSnapshot?,
        record: IOSAdvancedTaskRecord?,
        operationOK: Bool,
        waitTimedOut: Bool,
        alreadyTerminal: Bool
    ) -> String {
        let status = snapshot?.status ?? terminalStatus(record?.status).rawValue
        let exitCode = snapshot?.exitCode ?? record?.metadata["exit_code"].flatMap(Int.init)
        let stdout = snapshot?.stdoutTail ?? record?.metadata["stdout_tail"] ?? ""
        let stderr = snapshot?.stderrTail ?? record?.metadata["stderr_tail"] ?? ""
        let output = snapshot?.outputTail ?? record?.logTail ?? ""
        let terminalStatus = IOSTerminalJobStatus(rawValue: status)
        let runtime = snapshot?.runtime ?? record.flatMap(runtimeKind(for:))
        let commandOK: Any
        if terminalStatus == .completed {
            commandOK = (exitCode == 0)
        } else if terminalStatus == .failed {
            commandOK = false
        } else {
            commandOK = NSNull()
        }
        let errorCode: Any
        if terminalStatus == .interrupted {
            errorCode = "process_terminated"
        } else if terminalStatus == .timedOut {
            errorCode = "timeout"
        } else {
            errorCode = NSNull()
        }
        return IOSWorkspaceStore.json([
            "ok": operationOK,
            "tool": toolName,
            "runtime": runtime?.rawValue ?? "unknown",
            "job_id": jobId,
            "cwd": record?.metadata["cwd"] ?? "",
            "background": record?.metadata["execution_mode"] == "background",
            "lifecycle": record?.metadata["lifecycle"] ?? "process_local",
            "status": status,
            "running": terminalStatus == .running,
            "command_ok": commandOK,
            "exit_code": exitCode.map { $0 as Any } ?? NSNull(),
            "stdout": stdout,
            "stderr": stderr,
            "output_tail": output,
            "stdout_available": true,
            "stderr_available": true,
            "stdout_truncated": snapshot?.stdoutTruncated
                ?? (record?.metadata["stdout_truncated"] == "true"),
            "stderr_truncated": snapshot?.stderrTruncated
                ?? (record?.metadata["stderr_truncated"] == "true"),
            "persisted_snapshot": snapshot == nil,
            "stdout_persisted_truncated": record?.metadata["stdout_persisted_truncated"] == "true",
            "stderr_persisted_truncated": record?.metadata["stderr_persisted_truncated"] == "true",
            "exit_code_available": exitCode != nil,
            "started_at_ms": timestampValue(snapshot?.startedAt, fallback: record?.createdAt),
            "updated_at_ms": timestampValue(snapshot?.updatedAt, fallback: record?.updatedAt),
            "wait_timed_out": waitTimedOut,
            "already_terminal": alreadyTerminal,
            "error_code": errorCode,
            "error": snapshot?.error ?? record?.error ?? "",
            "related_tools": [
                IOSRemoteTerminalToolCatalog.jobReadToolName,
                IOSRemoteTerminalToolCatalog.jobWaitToolName,
                IOSRemoteTerminalToolCatalog.jobStopToolName,
            ],
        ])
    }

    private static func failureJSON(
        toolName: String,
        jobId: String?,
        runtime: IOSTerminalRuntimeKind?,
        errorCode: String,
        message: String
    ) -> String {
        IOSWorkspaceStore.json([
            "ok": false,
            "tool": toolName,
            "runtime": runtime?.rawValue ?? "unknown",
            "job_id": jobId ?? "",
            "status": IOSTerminalJobStatus.failed.rawValue,
            "running": false,
            "command_ok": NSNull(),
            "exit_code": NSNull(),
            "stdout": "",
            "stderr": "",
            "output_tail": "",
            "stdout_available": false,
            "stderr_available": false,
            "stdout_truncated": false,
            "stderr_truncated": false,
            "exit_code_available": false,
            "wait_timed_out": false,
            "already_terminal": false,
            "error_code": errorCode,
            "error": message,
        ])
    }

    private static func parseStartRequest(_ input: String) throws -> IOSRemoteTerminalJobStartRequest {
        let object = try inputObject(input)
        guard let command = nonEmptyString(object["command"]) else {
            throw IOSRemoteTerminalJobError.invalidArguments("A Remote SSH command is required.")
        }
        let timeout = numericValue(object["timeout_seconds"]) ?? defaultCommandTimeout
        return IOSRemoteTerminalJobStartRequest(
            command: command,
            profileId: nonEmptyString(object["profile_id"]),
            timeoutSeconds: min(max(1, timeout), maxCommandTimeout),
            purpose: nonEmptyString(object["purpose"]),
            workingDirectory: try workingDirectory(from: object)
        )
    }

    private static func parseReferenceRequest(
        _ input: String,
        allowsWait: Bool
    ) throws -> IOSRemoteTerminalJobReferenceRequest {
        let object = try inputObject(input)
        guard let jobId = nonEmptyString(object["job_id"]) else {
            throw IOSRemoteTerminalJobError.invalidArguments("job_id is required.")
        }
        let wait = allowsWait
            ? min(max(1, numericValue(object["wait_timeout_seconds"]) ?? defaultWaitTimeout), maxWaitTimeout)
            : 0
        return IOSRemoteTerminalJobReferenceRequest(jobId: jobId, waitTimeoutSeconds: wait)
    }

    private static func inputObject(_ input: String) throws -> [String: Any] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSRemoteTerminalJobError.invalidArguments("A JSON object is required.")
        }
        return object
    }

    private static func resolvedProfile(
        profileId: String?,
        settingsStore: SettingsStore?
    ) -> IOSSSHProfile? {
        guard let settingsStore else { return nil }
        if let profileId {
            return settingsStore.sshProfiles.first(where: { $0.id == profileId })
        }
        return settingsStore.defaultSSHProfile
    }

    private static func profileLabel(profile: IOSSSHProfile?, profileId: String?) -> String {
        if let profile {
            return "\(profile.displayName) · \(profile.username)@\(profile.host):\(profile.port)"
        }
        if let profileId { return "SSH Profile · \(String(profileId.prefix(12)))" }
        return "默认 SSH Profile"
    }

    private static func targetLabel(
        profile: IOSSSHProfile?,
        profileId: String?,
        workingDirectory: String?
    ) -> String {
        let profile = profileLabel(profile: profile, profileId: profileId)
        return workingDirectory.map { "\(profile) · \($0)" } ?? profile
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workingDirectory(from object: [String: Any]) throws -> String? {
        guard let value = object["cwd"] else { return nil }
        guard let string = value as? String else {
            throw IOSRemoteTerminalJobError.invalidArguments("cwd must be a string.")
        }
        return try IOSPOSIXWorkingDirectory.normalized(string)
    }

    private static func numericValue(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func runtimeKind(for record: IOSAdvancedTaskRecord) -> IOSTerminalRuntimeKind? {
        let persistedRuntime = record.metadata["runtime"].flatMap(IOSTerminalRuntimeKind.init(rawValue:))
        switch record.kind {
        case .remoteCommand:
            guard persistedRuntime == nil || persistedRuntime == .remoteSSH else { return nil }
            return .remoteSSH
        case .embeddedIsh:
            guard persistedRuntime == nil || persistedRuntime == .ishExperimental else { return nil }
            return .ishExperimental
        case .subAgent, .modelCouncil, .toolApproval:
            return nil
        }
    }

    private static func advancedStatus(_ rawValue: String) -> IOSAdvancedTaskStatus {
        switch IOSTerminalJobStatus(rawValue: rawValue) {
        case .queued: .queued
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .interrupted: .interrupted
        case nil: .failed
        }
    }

    private static func terminalStatus(_ status: IOSAdvancedTaskStatus?) -> IOSTerminalJobStatus {
        switch status {
        case .queued: .queued
        case .running: .running
        case .completed: .completed
        case .failed, .approvalRequired, nil: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .interrupted: .interrupted
        }
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1_000))
    }

    private static func timestampValue(_ date: Date?, fallback: Date?) -> Any {
        guard let date = date ?? fallback else { return NSNull() }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}

private enum IOSAmberShellExecuteError: LocalizedError {
    case emptyInput
    case invalidArguments(String)
    case unsupportedWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "需要提供 AmberShell 命令。"
        case .invalidArguments(let message):
            message
        case .unsupportedWorkingDirectory(let path):
            "AmberShell 当前只开放 /workspace，不支持 \(path)。"
        }
    }
}

private enum IOSRemoteTerminalJobError: LocalizedError {
    case invalidArguments(String)
    case settingsUnavailable
    case noDefaultProfile
    case profileNotFound(String)
    case jobNotFound(String)
    case unsupportedTool(String)
    case approvedTargetChanged

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .settingsUnavailable, .noDefaultProfile, .profileNotFound: "configuration_error"
        case .jobNotFound: "job_not_found"
        case .unsupportedTool: "unsupported_tool"
        case .approvedTargetChanged: "approved_target_changed"
        }
    }

    var jobId: String? {
        if case .jobNotFound(let id) = self { return id }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .settingsUnavailable: "SSH settings are unavailable."
        case .noDefaultProfile: "No default SSH profile is selected."
        case .profileNotFound(let id): "SSH profile was not found: \(id)"
        case .jobNotFound(let id): "Terminal job was not found: \(id)"
        case .unsupportedTool(let name): "Unsupported terminal job tool: \(name)"
        case .approvedTargetChanged: "The approved SSH profile or trusted endpoint changed before execution. Review and approve the updated target again."
        }
    }
}

private enum IOSRemoteTerminalExecuteError: LocalizedError {
    case emptyInput
    case invalidArguments(String)
    case profileNotFound(String)
    case settingsUnavailable
    case approvedTargetChanged

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "A Remote SSH command is required."
        case .invalidArguments(let message):
            message
        case .profileNotFound(let id):
            "SSH profile was not found: \(id)"
        case .settingsUnavailable:
            "SSH settings are unavailable."
        case .approvedTargetChanged:
            "The approved SSH profile or trusted endpoint changed before execution. Review and approve the updated target again."
        }
    }
}

private func remoteSSHTargetDigest(_ profile: IOSSSHProfile) -> String {
    chatInputDigest(for: [
        profile.id,
        profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
        profile.host.trimmingCharacters(in: .whitespacesAndNewlines),
        String(profile.port),
        profile.knownHostSHA256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        profile.knownHostHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        profile.knownHostPort.map(String.init) ?? "",
    ].joined(separator: "\n"))
}
