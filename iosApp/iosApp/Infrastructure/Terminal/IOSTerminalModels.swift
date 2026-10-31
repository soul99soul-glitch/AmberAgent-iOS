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
    let hopFailure: IOSSSHHopFailure?

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
        error: String?,
        hopFailure: IOSSSHHopFailure? = nil
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
        self.hopFailure = hopFailure
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

