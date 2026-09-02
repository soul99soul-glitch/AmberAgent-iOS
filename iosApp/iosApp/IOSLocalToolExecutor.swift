import Foundation
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

private let webMountRegistryLogger = Logger(subsystem: "app.amber.ios", category: "webmount")

struct IOSLocalToolExecutionRequest: Equatable {
    let toolName: String
    let operation: String
    let scopeDigest: String
    let payloadDigest: String
    let isUserInitiated: Bool
    let runId: String
    let conversationId: String
    let executionPolicy: IOSExecutionPolicySnapshot?
    let approvedRemoteProfileId: String?
    let approvedRemoteTargetDigest: String?

    init(
        toolName: String,
        operation: String,
        scopeDigest: String,
        payloadDigest: String,
        isUserInitiated: Bool,
        runId: String = "",
        conversationId: String = "",
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        approvedRemoteProfileId: String? = nil,
        approvedRemoteTargetDigest: String? = nil
    ) {
        self.toolName = toolName
        self.operation = operation
        self.scopeDigest = scopeDigest
        self.payloadDigest = payloadDigest
        self.isUserInitiated = isUserInitiated
        self.runId = runId
        self.conversationId = conversationId
        self.executionPolicy = executionPolicy
        self.approvedRemoteProfileId = approvedRemoteProfileId
        self.approvedRemoteTargetDigest = approvedRemoteTargetDigest
    }
}

enum IOSLocalToolExecutionOutput: Equatable {
    case selectedFilePreview(SelectedDocumentReadResult)
    case permissionsStatus(IOSPermissionsStatusSnapshot)
    case terminalResult(String)
    case ishExecuteResult(String)
    case ishHandoffResult(String)
    case webMountResult(String)
    case workspaceResult(String)
    case needsUserAction(String)
    case denied(String)
    case failed(String)
}

struct IOSWebMountToolApprovalPreview: Equatable {
    let toolName: String
    let siteId: String
    let siteName: String
    let host: String
    let sessionId: String?
    let backend: String
    let mcpServerName: String?
    let redactedURL: String
    let snapshotId: String?
    let target: String?
    let action: String
    let consequence: String
    let screenshotRetentionWarning: String?
}

struct IOSWebMountExecutionContext: Equatable {
    let runId: String
    let conversationId: String

    var isAgentInvocation: Bool {
        runId.nilIfBlank != nil || conversationId.nilIfBlank != nil
    }

    var hasCompleteBinding: Bool {
        runId.nilIfBlank != nil && conversationId.nilIfBlank != nil
    }
}

struct IOSWorkspaceToolApprovalPreview: Equatable {
    let toolName: String
    let action: String
    let target: String
    let isWrite: Bool
}

struct IOSPermissionsStatusSnapshot: Equatable {
    let generatedAt: Date
    let platform: String
    let capabilities: [IOSCapabilityStatusItem]
}

struct IOSCapabilityStatusItem: Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let domain: String
    let status: String
    let systemStatus: String
    let systemStatusMessage: String
    let risk: String
    let policy: String
    let requestKind: String
    let requestEntryPoint: String
    let canRequestInApp: Bool
    let canOpenSettings: Bool
    let uiActionNames: [String]
    let modelToolNames: [String]
    let blockedToolNames: [String]
    let defaultEnabled: Bool
    let requiresFreshUserPresence: Bool
    let allowRunScopedReuse: Bool
    let allowGlobalAutoApproval: Bool
    let requiredInfoPlistKeys: [String]
    let requiredEntitlements: [String]
    let requiredBackgroundModes: [String]
    let requiredExtensionTargets: [String]
    let reason: String?
    let executable: Bool
    let lastApprovalAction: String?
    let lastApprovalReason: String?
    let lastApprovalAt: Date?
}

@MainActor
final class IOSLocalToolExecutor {
    private let permissionStore: IOSPermissionStore
    private let documentStore: DocumentAccessStore
    private let systemPermissionCoordinator: IOSSystemPermissionCoordinator
    private let runtime: IOSToolRuntime
    private let webMountController: IOSWebMountController
    private let workspaceStore: IOSWorkspaceStore
    private let settingsStore: SettingsStore?
    private let terminalRuntime: IOSTerminalRuntime
    private let terminalTaskStore: IOSAdvancedTaskStore

    /// 全局自动批准：开启后普通工具自动放行。
    static var isGlobalAutoApproveEnabled: Bool {
        UserDefaults.standard.bool(forKey: "app.amber.ios.globalAutoApprove")
    }

    /// 高风险自动批准：开启后高风险工具也自动放行。
    static var isHighRiskAutoApproveEnabled: Bool {
        UserDefaults.standard.bool(forKey: "app.amber.ios.highRiskAutoApprove")
    }

    static func setHighRiskAutoApproveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "app.amber.ios.highRiskAutoApprove")
    }

    init(
        permissionStore: IOSPermissionStore,
        documentStore: DocumentAccessStore,
        workspaceStore: IOSWorkspaceStore = .shared,
        systemPermissionCoordinator: IOSSystemPermissionCoordinator? = nil,
        webMountController: IOSWebMountController? = nil,
        settingsStore: SettingsStore? = nil,
        terminalRuntime: IOSTerminalRuntime = .shared,
        terminalTaskStore: IOSAdvancedTaskStore = .shared
    ) {
        self.permissionStore = permissionStore
        self.documentStore = documentStore
        self.workspaceStore = workspaceStore
        self.systemPermissionCoordinator = systemPermissionCoordinator ?? IOSSystemPermissionCoordinator()
        self.runtime = IOSToolRuntime(permissionStore: permissionStore, documentStore: documentStore)
        self.webMountController = webMountController ?? IOSWebMountController.shared
        self.settingsStore = settingsStore
        self.terminalRuntime = terminalRuntime
        self.terminalTaskStore = terminalTaskStore
    }

    func executionPolicySnapshot(
        execJavaScriptEnabled: Bool,
        webSearchEnabled: Bool,
        mcpEnabled: Bool? = nil
    ) -> IOSExecutionPolicySnapshot {
        IOSExecutionPolicySnapshot(
            capabilityPolicies: Dictionary(uniqueKeysWithValues: IOSCapabilityRegistry.capabilities.map {
                ($0.id, permissionStore.policy(for: $0).rawValue)
            }),
            globalAutoApproveEnabled: Self.isGlobalAutoApproveEnabled,
            highRiskAutoApproveEnabled: Self.isHighRiskAutoApproveEnabled,
            execJavaScriptEnabled: execJavaScriptEnabled,
            webSearchEnabled: webSearchEnabled,
            mcpEnabled: mcpEnabled
        )
    }

    func executionRequest(
        toolName: String,
        operation: String,
        isUserInitiated: Bool,
        runId: String = "",
        conversationId: String = "",
        executionPolicy: IOSExecutionPolicySnapshot? = nil,
        approvedRemoteProfileId: String? = nil,
        approvedRemoteTargetDigest: String? = nil
    ) -> IOSLocalToolExecutionRequest {
        if toolName == "file_read_selected" {
            let selected = requestForCurrentSelectedFile(isUserInitiated: isUserInitiated)
            return IOSLocalToolExecutionRequest(
                toolName: selected.toolName,
                operation: selected.operation,
                scopeDigest: selected.scopeDigest,
                payloadDigest: selected.payloadDigest,
                isUserInitiated: selected.isUserInitiated,
                runId: runId,
                conversationId: conversationId,
                executionPolicy: executionPolicy,
                approvedRemoteProfileId: approvedRemoteProfileId,
                approvedRemoteTargetDigest: approvedRemoteTargetDigest
            )
        }

        let capabilityId = IOSCapabilityRegistry.capability(forToolName: toolName)?.id ?? "unknown"
        let scopeTarget: String
        if let workspace = workspaceApprovalPreview(toolName: toolName, input: operation) {
            scopeTarget = "workspace:\(workspace.target)"
        } else if let webMount = webMountApprovalPreview(toolName: toolName, input: operation) {
            scopeTarget = [
                "webmount",
                webMount.siteId,
                webMount.host,
                webMount.sessionId ?? "unbound",
                webMount.backend,
                webMount.mcpServerName ?? "local",
                webMount.snapshotId ?? "no-snapshot",
                webMount.target ?? "no-target",
                webMount.action
            ].joined(separator: ":")
        } else {
            scopeTarget = "capability:\(capabilityId)"
        }
        return IOSLocalToolExecutionRequest(
            toolName: toolName,
            operation: operation,
            scopeDigest: Self.sha256("\(toolName)\n\(scopeTarget)"),
            payloadDigest: Self.sha256(operation),
            isUserInitiated: isUserInitiated,
            runId: runId,
            conversationId: conversationId,
            executionPolicy: executionPolicy,
            approvedRemoteProfileId: approvedRemoteProfileId,
            approvedRemoteTargetDigest: approvedRemoteTargetDigest
        )
    }

    func execute(
        _ request: IOSLocalToolExecutionRequest,
        now: Date = Date()
    ) async -> IOSLocalToolExecutionOutput {
        if request.toolName == "permissions_status" {
            return .permissionsStatus(permissionsStatus(now: now))
        }
        if IOSAmberShellToolCatalog.supportedToolNames.contains(request.toolName) {
            guard let capability = IOSCapabilityRegistry.capability(forToolName: request.toolName) else {
                return .denied("Unknown AmberShell tool: \(request.toolName)")
            }
            switch resolveAmberShellExecution(request: request, capability: capability) {
            case .allow:
                return .terminalResult(await IOSAmberShellExecuteExecutor.execute(
                    input: request.operation,
                    runtime: terminalRuntime,
                    workspaceStore: workspaceStore
                ))
            case .needsUserAction(let reason):
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }
        if IOSRemoteTerminalToolCatalog.supportedToolNames.contains(request.toolName) {
            guard let capability = terminalCapability(
                toolName: request.toolName,
                input: request.operation
            ) else {
                return .denied("Unknown terminal tool: \(request.toolName)")
            }
            let gate: IOSPlatformGateDecision
            if IOSRemoteTerminalToolCatalog.readOnlyToolNames.contains(request.toolName) {
                let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
                gate = policy == .disabled
                    ? .deny(reason: "Disabled by AmberAgent \(capability.title) policy")
                    : .allow(capabilityId: capability.id)
            } else {
                gate = resolveTerminalExecution(request: request, capability: capability)
            }
            switch gate {
            case .allow:
                if IOSRemoteTerminalToolCatalog.jobToolNames.contains(request.toolName) {
                    return .terminalResult(await IOSAgentTerminalJobExecutor.execute(
                        toolName: request.toolName,
                        input: request.operation,
                        settingsStore: settingsStore,
                        runtime: terminalRuntime,
                        taskStore: terminalTaskStore,
                        expectedProfileId: request.approvedRemoteProfileId,
                        expectedTargetDigest: request.approvedRemoteTargetDigest
                    ))
                }
                return .terminalResult(await IOSRemoteTerminalExecuteExecutor.execute(
                    input: request.operation,
                    settingsStore: settingsStore,
                    runtime: terminalRuntime,
                    expectedProfileId: request.approvedRemoteProfileId,
                    expectedTargetDigest: request.approvedRemoteTargetDigest
                ))
            case .needsUserAction(let reason):
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }
        if IOSEmbeddedIshToolCatalog.supportedToolNames.contains(request.toolName) {
            guard let capability = IOSCapabilityRegistry.capability(forToolName: request.toolName) else {
                return .denied("Unknown embedded iSH tool: \(request.toolName)")
            }
            switch resolveEmbeddedIshExecute(request: request, capability: capability) {
            case .allow:
                return .ishExecuteResult(await IOSEmbeddedIshExecuteExecutor.execute(
                    input: request.operation,
                    runtime: terminalRuntime,
                    taskStore: terminalTaskStore
                ))
            case .needsUserAction(let reason):
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }
        if IOSIshToolCatalog.supportedToolNames.contains(request.toolName) {
            guard let capability = IOSCapabilityRegistry.capability(forToolName: request.toolName) else {
                return .denied("Unknown iSH handoff tool: \(request.toolName)")
            }
            switch resolveIshHandoff(request: request, capability: capability) {
            case .allow:
                return .ishHandoffResult(IOSIshHandoffExecutor.execute(input: request.operation, now: now))
            case .needsUserAction(let reason):
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }
        if IOSWorkspaceToolCatalog.supportedToolNames.contains(request.toolName) {
            guard let capability = IOSCapabilityRegistry.capability(forToolName: request.toolName) else {
                return .denied("Unknown iOS Workspace tool: \(request.toolName)")
            }
            switch resolveWorkspace(request: request, capability: capability) {
            case .allow:
                let output = await workspaceStore.executeTool(
                    toolName: request.toolName,
                    input: request.operation
                )
                return .workspaceResult(output)
            case .needsUserAction(let reason):
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }
        if IOSWebMountToolCatalog.unsupportedToolNames.contains(request.toolName) {
            return .webMountResult(IOSWebMountController.unsupportedToolResult(toolName: request.toolName))
        }
        if IOSWebMountToolCatalog.supportedToolNames.contains(request.toolName) {
            guard let capability = IOSCapabilityRegistry.capability(forToolName: request.toolName) else {
                return .denied("Unknown iOS WebMount tool: \(request.toolName)")
            }
            let webMountContext: IOSWebMountExecutionContext?
            if request.runId.isEmpty && request.conversationId.isEmpty {
                webMountContext = nil
            } else {
                webMountContext = IOSWebMountExecutionContext(
                    runId: request.runId,
                    conversationId: request.conversationId
                )
            }
            let webMountGate = resolveWebMount(request: request, capability: capability)
            switch webMountGate {
            case .allow:
                let output = await webMountController.execute(
                    toolName: request.toolName,
                    input: request.operation,
                    isUserInitiated: request.isUserInitiated,
                    context: webMountContext,
                    allowUnlistedHosts: webMountAllowsUnlistedHosts(
                        request: request,
                        capability: capability
                    )
                )
                if let reason = Self.webMountHumanActionReason(output) {
                    return .needsUserAction("human_handoff: \(reason)")
                }
                if let reason = Self.webMountUserActionReason(output) {
                    return .needsUserAction(reason)
                }
                return .webMountResult(output)
            case .needsUserAction(let reason):
                if !request.isUserInitiated,
                   let preflight = await webMountController.preflightUserAction(
                       toolName: request.toolName,
                       input: request.operation,
                       context: webMountContext
                   ) {
                    if let handoffReason = Self.webMountHumanActionReason(preflight) {
                        return .needsUserAction("human_handoff: \(handoffReason)")
                    }
                    if let actionReason = Self.webMountUserActionReason(preflight) {
                        return .needsUserAction(actionReason)
                    }
                }
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }
        if IOSCapabilityRegistry.capability(forUIActionName: request.toolName) != nil {
            return .denied("\(request.toolName) is a foreground UI action")
        }

        guard IOSCapabilityRegistry.capability(forToolName: request.toolName) != nil else {
            return .denied("Unknown iOS tool: \(request.toolName)")
        }

        let invocation = IOSToolInvocationRequest(
            toolName: request.toolName,
            operation: request.operation,
            scopeDigest: request.scopeDigest,
            payloadDigest: request.payloadDigest,
            isUserInitiated: request.isUserInitiated,
            executionPolicy: request.executionPolicy
        )

        guard request.toolName == "file_read_selected" else {
            switch runtime.resolve(request: invocation, now: now) {
            case .allow:
                return .denied("No iOS executor implementation for \(request.toolName)")
            case .needsUserAction(let reason):
                return .needsUserAction(reason)
            case .deny(let reason):
                return .denied(reason)
            }
        }

        let result = await runtime.executeFileReadSelected(request: invocation, now: now)
        switch result {
        case .success(let readResult):
            return .selectedFilePreview(readResult)
        case .needsUserAction(let reason):
            return .needsUserAction(reason)
        case .denied(let reason):
            return .denied(reason)
        case .failed(let message):
            return .failed(message)
        }
    }

    private func resolveWebMount(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        webMountGateDecision(
            toolName: request.toolName,
            isUserInitiated: request.isUserInitiated,
            executionPolicy: request.executionPolicy,
            capability: capability
        )
    }

    func webMountGateDecision(
        toolName: String,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot?
    ) -> IOSPlatformGateDecision {
        guard let capability = IOSCapabilityRegistry.capability(forToolName: toolName) else {
            return .deny(reason: "Unknown iOS WebMount tool: \(toolName)")
        }
        return webMountGateDecision(
            toolName: toolName,
            isUserInitiated: isUserInitiated,
            executionPolicy: executionPolicy,
            capability: capability
        )
    }

    private func webMountGateDecision(
        toolName: String,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot?,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        let policy = executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent policy")
        }
        if !isUserInitiated {
            if toolName == "wm_clear_session" {
                return .needsUserAction(reason: "Clearing WebMount cookies requires an explicit foreground user action")
            }
            if IOSWebMountToolCatalog.descriptors.first(where: { $0.name == toolName })?.requiresUserAction == true {
                return .needsUserAction(reason: "This WebMount action requires explicit foreground user approval: \(toolName)")
            }
        }
        if policy == .autoApprove || policy == .autoApproveHighRisk {
            return .allow(capabilityId: capability.id)
        }
        if !isUserInitiated {
            if policy == .askEveryTime || capability.gate.requiresFreshUserPresence {
                let globalAutoApprove = executionPolicy?.globalAutoApproveEnabled ?? Self.isGlobalAutoApproveEnabled
                let highRiskAutoApprove = executionPolicy?.highRiskAutoApproveEnabled ?? Self.isHighRiskAutoApproveEnabled
                // WebMount applies high-risk policy again at the URL and page-
                // action boundary. Global approval may enter that controller;
                // only high-risk approval enables unlisted public hosts.
                let autoApprove = globalAutoApprove || highRiskAutoApprove
                if autoApprove {
                    return .allow(capabilityId: capability.id)
                }
                return .needsUserAction(reason: "WebMount browser tools require explicit foreground approval before the model can use the page session.")
            }
        }
        return .allow(capabilityId: capability.id)
    }

    private func resolveEmbeddedIshExecute(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent embedded iSH policy")
        }
        guard terminalAutoApprovalEnabled(for: request, policy: policy) else {
            return .needsUserAction(reason: "Embedded iSH executes local Linux commands and returns stdout/stderr/exit code. It requires explicit foreground approval.")
        }
        return .allow(capabilityId: capability.id)
    }

    private func resolveTerminalExecution(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent \(capability.title) policy")
        }
        guard terminalAutoApprovalEnabled(for: request, policy: policy) else {
            if request.toolName == IOSRemoteTerminalToolCatalog.jobStopToolName {
                return .needsUserAction(reason: "Stopping a terminal job requires explicit foreground approval.")
            }
            if request.toolName == IOSRemoteTerminalToolCatalog.jobStartToolName {
                return .needsUserAction(reason: "Starting a Remote SSH job on the selected trusted host requires explicit foreground approval.")
            }
            return .needsUserAction(reason: "Remote SSH executes a command on the selected trusted host and returns stdout/stderr/exit code. It requires explicit foreground approval.")
        }
        return .allow(capabilityId: capability.id)
    }

    private func resolveAmberShellExecution(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent AmberShell policy")
        }
        guard terminalAutoApprovalEnabled(for: request, policy: policy) else {
            let reason = "AmberShell 会在 App 自有 /workspace 中执行本地命令并回传 stdout、stderr 与退出码；当前策略需要前台批准。"
            return .needsUserAction(reason: IOSAppLocalization.string(reason, defaultValue: reason))
        }
        return .allow(capabilityId: capability.id)
    }

    private func terminalCapability(toolName: String, input: String) -> IOSPlatformCapability? {
        if toolName == IOSRemoteTerminalToolCatalog.jobReadToolName
            || toolName == IOSRemoteTerminalToolCatalog.jobWaitToolName
            || toolName == IOSRemoteTerminalToolCatalog.jobStopToolName,
           let jobId = Self.toolInputObject(input)["job_id"] as? String,
           terminalTaskStore.task(id: jobId)?.kind == .embeddedIsh {
            guard !IOSEmbeddedIshToolCatalog.supportedToolNames.isEmpty else { return nil }
            return IOSCapabilityRegistry.capabilities.first { $0.id == "ios.embedded.ish_runtime" }
        }
        return IOSCapabilityRegistry.capability(forToolName: toolName)
    }

    func terminalApprovalCapabilityId(toolName: String, input: String) -> String? {
        terminalCapability(toolName: toolName, input: input)?.id
    }

    private func resolveIshHandoff(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent iSH handoff policy")
        }
        guard terminalAutoApprovalEnabled(for: request, policy: policy) else {
            return .needsUserAction(reason: "iSH handoff prepares a paste-ready command for another app. It requires explicit foreground approval.")
        }
        return .allow(capabilityId: capability.id)
    }

    private func terminalAutoApprovalEnabled(
        for request: IOSLocalToolExecutionRequest,
        policy: IOSAgentPermissionPolicy
    ) -> Bool {
        request.isUserInitiated
            || policy == .autoApproveHighRisk
            || highRiskAutoApproveEnabled(for: request)
    }

    private func resolveWorkspace(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> IOSPlatformGateDecision {
        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        if policy == .disabled {
            return .deny(reason: "Disabled by AmberAgent Workspace tool policy")
        }
        // 自动批准策略直接放行。
        if policy == .autoApprove || policy == .autoApproveHighRisk {
            return .allow(capabilityId: capability.id)
        }
        if !request.isUserInitiated {
            if IOSWorkspaceToolCatalog.writeToolNames.contains(request.toolName) {
                if !(policy == .autoApprove || policy == .autoApproveHighRisk) {
                    // Honor the global / high-risk auto-approve switches (writes are high-risk).
                    if globalAutoApproveEnabled(for: request) && (capability.risk != .high || highRiskAutoApproveEnabled(for: request)) {
                        return .allow(capabilityId: capability.id)
                    }
                    return .needsUserAction(reason: "Workspace writes and deletes require explicit foreground approval.")
                }
            }
            if policy == .askEveryTime || capability.gate.requiresFreshUserPresence {
                if globalAutoApproveEnabled(for: request) && (capability.risk != .high || highRiskAutoApproveEnabled(for: request)) {
                    return .allow(capabilityId: capability.id)
                }
                return .needsUserAction(reason: "Workspace reads require explicit foreground approval before the model can use saved files or artifacts.")
            }
        }
        return .allow(capabilityId: capability.id)
    }

    func permissionPolicy(capabilityId: String) -> IOSAgentPermissionPolicy? {
        guard let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.id == capabilityId }) else {
            return nil
        }
        return permissionStore.policy(for: capability)
    }

    func permissionsStatus(now: Date = Date()) -> IOSPermissionsStatusSnapshot {
        IOSPermissionsStatusSnapshot(
            generatedAt: now,
            platform: "iOS",
            capabilities: IOSCapabilityRegistry.capabilities.map { capability in
                let policy = permissionStore.policy(for: capability)
                let systemStatus = systemPermissionCoordinator.cachedStatus(for: capability, now: now)
                let latestApproval = permissionStore.latestApproval(for: capability)
                let canRequestInApp = IOSSystemPermissionCoordinator.canRequestInApp(
                    for: capability,
                    systemStatus: systemStatus.status
                )
                return IOSCapabilityStatusItem(
                    id: Self.snapshotId(for: capability),
                    title: capability.title,
                    summary: capability.summary,
                    domain: Self.snapshotDomain(for: capability),
                    status: capability.status.title,
                    systemStatus: systemStatus.status.title,
                    systemStatusMessage: systemStatus.message,
                    risk: capability.risk.title,
                    policy: policy.title,
                    requestKind: capability.requestKind.title,
                    requestEntryPoint: capability.requestEntryPoint,
                    canRequestInApp: canRequestInApp,
                    canOpenSettings: capability.canOpenSettings,
                    uiActionNames: capability.uiActionNames,
                    modelToolNames: capability.modelToolNames,
                    blockedToolNames: capability.blockedToolNames,
                    defaultEnabled: capability.defaultEnabled,
                    requiresFreshUserPresence: capability.gate.requiresFreshUserPresence,
                    allowRunScopedReuse: capability.gate.allowRunScopedReuse,
                    allowGlobalAutoApproval: capability.gate.allowGlobalAutoApproval,
                    requiredInfoPlistKeys: capability.requiredInfoPlistKeys,
                    requiredEntitlements: capability.requiredEntitlements,
                    requiredBackgroundModes: capability.requiredBackgroundModes,
                    requiredExtensionTargets: capability.requiredExtensionTargets,
                    reason: capability.unavailableReason,
                    executable: capability.status != .unsupported &&
                        policy != .disabled &&
                        (!capability.modelToolNames.isEmpty || !capability.uiActionNames.isEmpty),
                    lastApprovalAction: latestApproval?.action.title,
                    lastApprovalReason: latestApproval?.reason,
                    lastApprovalAt: latestApproval?.createdAt
                )
            }
        )
    }

    @discardableResult
    func recordApproval(
        capabilityId: String,
        toolName: String,
        action: IOSToolApprovalAction,
        reason: String,
        runId: String = "",
        scopeDigest: String = "",
        payloadDigest: String = "",
        policyDigest: String? = nil,
        now: Date = Date()
    ) -> IOSToolApprovalRecord {
        permissionStore.recordApproval(
            capabilityId: capabilityId,
            toolName: toolName,
            action: action,
            reason: reason,
            runId: runId,
            scopeDigest: scopeDigest,
            payloadDigest: payloadDigest,
            policyDigest: policyDigest,
            now: now
        )
    }

    func memoryToolWritePolicy(
        input: String,
        isUserInitiated: Bool,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) -> IOSMemoryToolWritePolicy {
        guard IOSMemoryToolExecutor.requiresWriteApproval(input: input) else {
            return .allow
        }
        guard let capability = IOSCapabilityRegistry.capabilities.first(where: { $0.id == "ios.agent.memory_write" }) else {
            return .needsUserAction("Memory writes require foreground approval.")
        }

        switch executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability) {
        case .disabled:
            return .denied("Memory writes are disabled in AmberAgent tool policy.")
        case .askEveryTime, .allowOncePerRun:
            if isUserInitiated {
                return .allow
            }
            // Honor the global / high-risk auto-approve switches (writes are high-risk).
            let globalAutoApprove = executionPolicy?.globalAutoApproveEnabled ?? Self.isGlobalAutoApproveEnabled
            let highRiskAutoApprove = executionPolicy?.highRiskAutoApproveEnabled ?? Self.isHighRiskAutoApproveEnabled
            if globalAutoApprove && (capability.risk != .high || highRiskAutoApprove) {
                return .allow
            }
            return .needsUserAction("Memory writes require explicit foreground approval before the model can change saved memories.")
        case .autoApprove, .autoApproveHighRisk:
            return .allow
        }
    }

    func webMountApprovalPreview(toolName: String, input: String) -> IOSWebMountToolApprovalPreview? {
        guard IOSWebMountToolCatalog.supportedToolNames.contains(toolName) else {
            return nil
        }
        let object = Self.webMountInputObject(input)
        let sessionId = (object["session_id"] as? String)?.nilIfBlank
        let record = sessionId.flatMap { webMountController.sessionStore.record(sessionId: $0) }
        let previewRuntime = webMountController.sessionStore.runtimeIfPresent(sessionId: sessionId)
        let requestedURL = IOSWebMountRedactor.redactedURL(object["url"] as? String)
        let currentURL = requestedURL
            ?? record?.redactedURL.nilIfBlank
            ?? IOSWebMountRedactor.redactedURL(previewRuntime?.snapshot.currentURL)
            ?? ""
        let requestedSiteId = (object["site_id"] as? String)?.nilIfBlank
        let requestedSite = requestedSiteId.flatMap { webMountController.registry.site(id: $0) }
        let urlSite = (object["url"] as? String)
            .flatMap { URL(string: $0) }
            .flatMap { webMountController.registry.site(for: $0) }
        let recordSite = record.flatMap { item in
            item.siteId.flatMap { webMountController.registry.site(id: $0) }
        }
        let site = requestedSite ?? urlSite ?? recordSite
        let host = site?.homepageHost
            ?? Self.redactedHost(from: currentURL)
            ?? "WebMount"
        let target = Self.webMountApprovalTarget(toolName: toolName, object: object)
        return IOSWebMountToolApprovalPreview(
            toolName: toolName,
            siteId: site?.id ?? record?.siteId ?? "current",
            siteName: site?.displayName ?? record?.siteName ?? "当前 WebMount 会话",
            host: host,
            sessionId: sessionId,
            backend: record?.backend.rawValue ?? "local",
            mcpServerName: record?.mcpServerName,
            redactedURL: currentURL,
            snapshotId: (object["snapshot_id"] as? String)?.nilIfBlank,
            target: target,
            action: Self.webMountApprovalAction(toolName),
            consequence: Self.webMountApprovalConsequence(toolName: toolName, target: target),
            screenshotRetentionWarning: toolName == "wm_screenshot"
                ? "完整视口截图会仅保存在本机，最长保留 24 小时，可能包含页面中的敏感信息。"
                : nil
        )
    }

    func webMountActionPreflight(
        toolName: String,
        input: String,
        runId: String,
        conversationId: String
    ) async -> String? {
        let context: IOSWebMountExecutionContext? = runId.isEmpty && conversationId.isEmpty
            ? nil
            : IOSWebMountExecutionContext(runId: runId, conversationId: conversationId)
        return await webMountController.preflightUserAction(
            toolName: toolName,
            input: input,
            context: context
        )
    }

    func webMountHandoffIsPending(toolName: String, input: String) -> Bool {
        guard ["wm_click", "wm_tap", "wm_type", "wm_keys", "wm_select"].contains(toolName) else {
            return false
        }
        let object = Self.webMountInputObject(input)
        guard let sessionId = (object["session_id"] as? String)?.nilIfBlank,
              let record = webMountController.sessionStore.record(sessionId: sessionId) else {
            return false
        }
        return record.backend == .local
            && record.controlOwner == .user
            && record.ownerRunId?.nilIfBlank != nil
    }

    /// Completes an approval-card human handoff without replaying the original
    /// sensitive page action. Local sessions return control to the bound run;
    /// desktop sessions fail so the caller can require a local privacy session.
    func completeWebMountHumanHandoff(toolName: String, input: String, runId: String) -> Bool {
        guard ["wm_click", "wm_tap", "wm_type", "wm_keys", "wm_select"].contains(toolName),
              let expectedRunId = runId.nilIfBlank else {
            return false
        }
        let object = Self.webMountInputObject(input)
        guard let sessionId = (object["session_id"] as? String)?.nilIfBlank,
              let record = webMountController.sessionStore.record(sessionId: sessionId),
              record.ownerRunId?.nilIfBlank == expectedRunId else {
            return false
        }
        guard record.backend == .local else { return false }
        switch record.controlOwner {
        case .user:
            return (try? webMountController.sessionStore.handBackToAgent(sessionId: sessionId)) != nil
        case .agent:
            return true
        case .none:
            return false
        }
    }

    private static func webMountApprovalAction(_ toolName: String) -> String {
        switch toolName {
        case "wm_click": "点击页面元素"
        case "wm_tap": "点击页面坐标或元素"
        case "wm_type": "向页面字段输入文本"
        case "wm_keys": "向页面发送按键"
        case "wm_select": "选择页面选项"
        case "wm_screenshot": "保存当前完整视口截图"
        case "wm_clear_session": "清除站点登录状态"
        case "wm_site_add": "新增 WebMount 站点"
        case "wm_site_remove": "移除 WebMount 站点"
        default: toolName
        }
    }

    private static func webMountApprovalTarget(toolName: String, object: [String: Any]) -> String? {
        if toolName == "wm_tap", let x = object["x"], let y = object["y"] {
            return IOSWebMountRedactor.redactedText("viewport (\(x), \(y))")
        }
        let raw = (object["target"] as? String)?.nilIfBlank
            ?? (object["selector"] as? String)?.nilIfBlank
            ?? (toolName == "wm_keys" ? (object["key"] as? String)?.nilIfBlank ?? (object["text"] as? String)?.nilIfBlank : nil)
        return raw.map { String(IOSWebMountRedactor.redactedText($0).prefix(160)) }
    }

    private static func webMountApprovalConsequence(toolName: String, target: String?) -> String {
        switch toolName {
        case "wm_screenshot":
            return "会在本机创建一个限时截图文件。"
        case "wm_clear_session":
            return "会删除该站点的 Cookie 与网站数据。"
        case "wm_site_add", "wm_site_remove":
            return "会更改 WebMount 站点与 URL allowlist。"
        case "wm_click", "wm_tap", "wm_keys", "wm_select", "wm_type":
            if let target, target.localizedCaseInsensitiveContains("enter") {
                return "可能提交当前表单；执行前会再次核对页面快照。"
            }
            return "可能提交、授权或改变远端状态；批准只绑定当前页面快照与目标。"
        default:
            return "批准只适用于当前会话中的这一项操作。"
        }
    }

    private static func webMountUserActionReason(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["needs_user_action"] as? Bool == true,
              object["requires_human"] as? Bool != true else {
            return nil
        }
        let reason = (object["reason"] as? String)?.nilIfBlank
            ?? (object["consequence"] as? String)?.nilIfBlank
            ?? "This WebMount action requires explicit foreground approval."
        if let label = (object["target_label"] as? String)?.nilIfBlank {
            return "\(reason) Target: \(IOSWebMountRedactor.redactedText(label))."
        }
        return reason
    }

    private static func webMountHumanActionReason(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["requires_human"] as? Bool == true else {
            return nil
        }
        let reason = (object["reason"] as? String)?.nilIfBlank
            ?? "Complete the sensitive step in user-controlled WebMount, then continue."
        if let label = (object["target_label"] as? String)?.nilIfBlank {
            return "\(reason) Target: \(IOSWebMountRedactor.redactedText(label))."
        }
        return reason
    }

    func terminalApprovalPreview(
        toolName: String,
        input: String
    ) -> IshHandoffToolApprovalRequest? {
        if IOSAmberShellToolCatalog.supportedToolNames.contains(toolName) {
            return IOSAmberShellExecuteExecutor.approvalPreview(input: input)
        }
        guard IOSRemoteTerminalToolCatalog.supportedToolNames.contains(toolName) else {
            return nil
        }
        if IOSRemoteTerminalToolCatalog.jobToolNames.contains(toolName) {
            return IOSAgentTerminalJobExecutor.approvalPreview(
                toolName: toolName,
                input: input,
                settingsStore: settingsStore,
                taskStore: terminalTaskStore
            )
        }
        return IOSRemoteTerminalExecuteExecutor.approvalPreview(
            input: input,
            settingsStore: settingsStore
        )
    }

    func workspaceApprovalPreview(toolName: String, input: String) -> IOSWorkspaceToolApprovalPreview? {
        guard IOSWorkspaceToolCatalog.supportedToolNames.contains(toolName) else {
            return nil
        }
        let object = Self.toolInputObject(input)
        let target = ((object["file_id"] as? String)?.nilIfBlank
            ?? (object["artifact_id"] as? String)?.nilIfBlank
            ?? (object["id"] as? String)?.nilIfBlank
            ?? (object["path"] as? String)?.nilIfBlank
            ?? "Workspace").trimmingCharacters(in: .whitespacesAndNewlines)
        let action: String
        switch toolName {
        case "workspace_file_read":
            action = "读取文件"
        case "workspace_file_list":
            action = "列出文件"
        case "workspace_file_search":
            action = "搜索文件"
        case "workspace_file_write":
            action = "写入文件"
        case "workspace_file_edit":
            action = "编辑文件"
        case "workspace_file_move":
            action = "移动文件"
        case "workspace_artifact_read":
            action = "读取 Artifact"
        case "workspace_artifact_delete":
            action = "删除 Artifact"
        default:
            action = toolName
        }
        return IOSWorkspaceToolApprovalPreview(
            toolName: toolName,
            action: action,
            target: target.isEmpty ? "Workspace" : target,
            isWrite: IOSWorkspaceToolCatalog.writeToolNames.contains(toolName)
        )
    }

    private static func siteId(fromWebMountInput input: String) -> String? {
        guard let siteId = webMountInputObject(input)["site_id"] as? String else {
            return nil
        }
        let trimmed = siteId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func webMountInputObject(_ input: String) -> [String: Any] {
        toolInputObject(input)
    }

    private static func toolInputObject(_ input: String) -> [String: Any] {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func redactedHost(from rawURL: String?) -> String? {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let host = components.host?.nilIfBlank else {
            return nil
        }
        return host
    }

    private static func snapshotId(for capability: IOSPlatformCapability) -> String {
        guard capability.id.hasPrefix("android.") else {
            return capability.id
        }
        return "ios.unavailable." + capability.id.dropFirst("android.".count)
    }

    private static func snapshotDomain(for capability: IOSPlatformCapability) -> String {
        if capability.id.hasPrefix("android."), capability.status == .unsupported {
            return "Unavailable on iOS"
        }
        return capability.domain.title
    }

    private func globalAutoApproveEnabled(for request: IOSLocalToolExecutionRequest) -> Bool {
        request.executionPolicy?.globalAutoApproveEnabled ?? Self.isGlobalAutoApproveEnabled
    }

    private func highRiskAutoApproveEnabled(for request: IOSLocalToolExecutionRequest) -> Bool {
        request.executionPolicy?.highRiskAutoApproveEnabled ?? Self.isHighRiskAutoApproveEnabled
    }

    private func webMountAllowsUnlistedHosts(
        request: IOSLocalToolExecutionRequest,
        capability: IOSPlatformCapability
    ) -> Bool {
        let policy = request.executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)
        return policy == .autoApproveHighRisk || highRiskAutoApproveEnabled(for: request)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func requestForCurrentSelectedFile(isUserInitiated: Bool) -> IOSLocalToolExecutionRequest {
        let request = documentStore.requestForCurrentGrant(isUserInitiated: isUserInitiated)
        return IOSLocalToolExecutionRequest(
            toolName: request.toolName,
            operation: request.operation,
            scopeDigest: request.scopeDigest,
            payloadDigest: request.payloadDigest,
            isUserInitiated: request.isUserInitiated
        )
    }
}

// MARK: - iOS WebMount Core

enum IOSWebMountAuthKind: String, Codable, CaseIterable, Identifiable {
    case anonymous
    case cookie
    case oauth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anonymous: "Anonymous"
        case .cookie: "Cookie"
        case .oauth: "OAuth"
        }
    }
}

enum IOSWebMountRuntimeStatus: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed
}

struct IOSWebMountSite: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var displayName: String
    var homepageURL: String
    var authKind: IOSWebMountAuthKind
    var loginCookieName: String?
    var nativeAdapterId: String?
    var iconKey: String?
    var oauthProviderId: String?
    var allowedHosts: [String]
    var enabled: Bool
    var addedAtMillis: Int64

    var homepageHost: String {
        URL(string: homepageURL)?.host?.lowercased() ?? homepageURL
    }

    static func seeds(nowMillis: Int64 = IOSWebMountClock.nowMillis()) -> [IOSWebMountSite] {
        [
            IOSWebMountSite(
                id: "hackernews",
                displayName: "Hacker News",
                homepageURL: "https://news.ycombinator.com",
                authKind: .anonymous,
                loginCookieName: nil,
                nativeAdapterId: "hackernews",
                iconKey: "hackernews",
                oauthProviderId: nil,
                allowedHosts: ["news.ycombinator.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "reddit",
                displayName: "Reddit",
                homepageURL: "https://www.reddit.com",
                authKind: .anonymous,
                loginCookieName: nil,
                nativeAdapterId: "reddit",
                iconKey: "reddit",
                oauthProviderId: nil,
                allowedHosts: ["www.reddit.com", "reddit.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "github",
                displayName: "GitHub",
                homepageURL: "https://github.com/login",
                authKind: .cookie,
                loginCookieName: "user_session",
                nativeAdapterId: "github",
                iconKey: "github",
                oauthProviderId: nil,
                allowedHosts: ["github.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "bilibili",
                displayName: "Bilibili",
                homepageURL: "https://passport.bilibili.com/login",
                authKind: .cookie,
                loginCookieName: "SESSDATA",
                nativeAdapterId: "bilibili",
                iconKey: "bilibili",
                oauthProviderId: nil,
                allowedHosts: ["passport.bilibili.com", "www.bilibili.com", "bilibili.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "x_com",
                displayName: "X.com",
                homepageURL: "https://x.com/i/flow/login",
                authKind: .cookie,
                loginCookieName: "auth_token",
                nativeAdapterId: nil,
                iconKey: "x_com",
                oauthProviderId: nil,
                allowedHosts: ["x.com", "twitter.com", "www.x.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "weibo",
                displayName: "微博",
                homepageURL: "https://m.weibo.cn",
                authKind: .cookie,
                loginCookieName: "SUB",
                nativeAdapterId: nil,
                iconKey: "weibo",
                oauthProviderId: nil,
                allowedHosts: ["m.weibo.cn", "weibo.cn", "weibo.com", "www.weibo.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "juejin",
                displayName: "掘金",
                homepageURL: "https://juejin.cn/login",
                authKind: .cookie,
                loginCookieName: "sessionid",
                nativeAdapterId: "juejin",
                iconKey: "juejin",
                oauthProviderId: nil,
                allowedHosts: ["juejin.cn", "www.juejin.cn"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "zhihu",
                displayName: "知乎",
                homepageURL: "https://www.zhihu.com/signin",
                authKind: .cookie,
                loginCookieName: "z_c0",
                nativeAdapterId: "zhihu",
                iconKey: "zhihu",
                oauthProviderId: nil,
                allowedHosts: ["www.zhihu.com", "zhihu.com"],
                enabled: false,
                addedAtMillis: nowMillis
            ),
            IOSWebMountSite(
                id: "feishu_docs",
                displayName: "飞书云文档",
                homepageURL: "https://www.feishu.cn/wiki",
                authKind: .oauth,
                loginCookieName: nil,
                nativeAdapterId: "feishu_docs",
                iconKey: "feishu_docs",
                oauthProviderId: "feishu",
                allowedHosts: ["www.feishu.cn", "feishu.cn"],
                enabled: false,
                addedAtMillis: nowMillis
            )
        ]
    }
}

@MainActor
@Observable
final class IOSWebMountRegistry {
    private let defaults: UserDefaults
    private let storageKey: String
    private let seededKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var sites: [IOSWebMountSite]

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "app.amber.ios.webmount.sites.v1",
        seededKey: String = "app.amber.ios.webmount.seeded.v1"
    ) {
        self.defaults = userDefaults
        self.storageKey = storageKey
        self.seededKey = seededKey

        if let data = userDefaults.data(forKey: storageKey) {
            if let decoded = try? decoder.decode([IOSWebMountSite].self, from: data) {
                self.sites = decoded
            } else {
                // 已有用户数据但解码失败（如 schema 演进）：只在内存里回退到
                // seeds，绝不把 seeds 编码写回磁盘，避免把用户配置冲掉。
                webMountRegistryLogger.error("webMount sites 解码失败，使用内存 seeds 回退（不写回存储）")
                self.sites = IOSWebMountSite.seeds()
            }
        } else {
            self.sites = IOSWebMountSite.seeds()
            if let data = try? encoder.encode(self.sites) {
                userDefaults.set(data, forKey: storageKey)
                userDefaults.set(true, forKey: seededKey)
            }
        }
    }

    func site(id: String) -> IOSWebMountSite? {
        sites.first { $0.id == id }
    }

    func site(for url: URL) -> IOSWebMountSite? {
        sites.first { site in
            IOSWebMountURLPolicy.host(url.host, matchesAnyOf: site.allowedHosts)
        }
    }

    @discardableResult
    func add(_ site: IOSWebMountSite) -> Bool {
        guard !sites.contains(where: { $0.id == site.id }) else { return false }
        sites.insert(site, at: 0)
        persist()
        return true
    }

    @discardableResult
    func addCustomSite(
        displayName: String,
        homepageURL: String,
        needsLogin: Bool = true,
        loginCookieName: String? = nil
    ) throws -> IOSWebMountSite {
        guard let url = URL(string: homepageURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSWebMountRegistryError.invalidSite
        }
        let baseId = "user_" + IOSWebMountRegistry.slug(displayName)
        var candidate = baseId
        var suffix = 2
        while sites.contains(where: { $0.id == candidate }) {
            candidate = "\(baseId)_\(suffix)"
            suffix += 1
        }
        let site = IOSWebMountSite(
            id: candidate,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            homepageURL: url.absoluteString,
            authKind: needsLogin ? .cookie : .anonymous,
            loginCookieName: needsLogin ? loginCookieName?.nilIfBlank : nil,
            nativeAdapterId: nil,
            iconKey: nil,
            oauthProviderId: nil,
            allowedHosts: [host],
            enabled: false,
            addedAtMillis: IOSWebMountClock.nowMillis()
        )
        add(site)
        return site
    }

    @discardableResult
    func remove(id: String) -> Bool {
        guard sites.contains(where: { $0.id == id }) else { return false }
        sites.removeAll { $0.id == id }
        persist()
        return true
    }

    @discardableResult
    func restoreMissingSeeds() -> Int {
        let existing = Set(sites.map(\.id))
        let missing = IOSWebMountSite.seeds().filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return 0 }
        sites.append(contentsOf: missing)
        persist()
        return missing.count
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = sites.firstIndex(where: { $0.id == id }) else { return }
        sites[index].enabled = enabled
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(sites) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.set(true, forKey: seededKey)
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let collapsed = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "site" : String(collapsed.prefix(40))
    }
}

enum IOSWebMountRegistryError: Error {
    case invalidSite
}

@MainActor
@Observable
final class IOSWebMountSettings {
    var globalEnabled: Bool {
        didSet { persist() }
    }
    var allowedHosts: Set<String> {
        didSet { persist() }
    }
    var allowedSchemes: Set<String> {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let globalKey: String
    private let hostsKey: String
    private let schemesKey: String
    private var isLoading = true

    init(
        userDefaults: UserDefaults = .standard,
        globalKey: String = "app.amber.ios.webmount.globalEnabled.v1",
        hostsKey: String = "app.amber.ios.webmount.allowedHosts.v1",
        schemesKey: String = "app.amber.ios.webmount.allowedSchemes.v1"
    ) {
        self.defaults = userDefaults
        self.globalKey = globalKey
        self.hostsKey = hostsKey
        self.schemesKey = schemesKey
        self.globalEnabled = userDefaults.object(forKey: globalKey) as? Bool ?? true
        let seedHosts = IOSWebMountSite.seeds().flatMap(\.allowedHosts)
        self.allowedHosts = Set((userDefaults.array(forKey: hostsKey) as? [String]) ?? seedHosts)
        self.allowedSchemes = Set((userDefaults.array(forKey: schemesKey) as? [String]) ?? ["http", "https"])
        self.isLoading = false
        persist()
    }

    func syncAllowedHosts(_ hosts: [String]) {
        let normalized = hosts.compactMap { IOSWebMountURLPolicy.normalizedHost($0) }
        allowedHosts = Set(normalized)
    }

    private func persist() {
        guard !isLoading else { return }
        defaults.set(globalEnabled, forKey: globalKey)
        defaults.set(Array(allowedHosts).sorted(), forKey: hostsKey)
        defaults.set(Array(allowedSchemes).sorted(), forKey: schemesKey)
    }
}

enum IOSWebMountURLPolicyError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case missingHost
    case embeddedCredentialsNotAllowed
    case privateHostNotAllowed(String)
    case navigationTargetNotVerified(String)
    case hostNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .unsupportedScheme(let scheme):
            "Unsupported URL scheme: \(scheme)"
        case .missingHost:
            "URL host is missing"
        case .embeddedCredentialsNotAllowed:
            "Embedded URL credentials are not allowed"
        case .privateHostNotAllowed(let host):
            "Local, loopback, link-local, and private hosts are not allowed: \(host)"
        case .navigationTargetNotVerified(let host):
            "Navigation target was not verified before commit: \(host)"
        case .hostNotAllowed(let host):
            "Host is not in the WebMount allowlist: \(host)"
        }
    }
}

typealias IOSWebMountHostResolver = @Sendable (String) throws -> [String]

struct IOSWebMountURLPolicy {
    let allowedSchemes: Set<String>
    let allowedHosts: Set<String>
    let allowUnlistedHosts: Bool

    @MainActor
    init(
        settings: IOSWebMountSettings,
        extraAllowedHosts: [String] = [],
        allowUnlistedHosts: Bool = false
    ) {
        self.allowedSchemes = Set(settings.allowedSchemes.map { $0.lowercased() })
        self.allowedHosts = Set(settings.allowedHosts.map { $0.lowercased() })
            .union(extraAllowedHosts.compactMap(Self.normalizedHost))
        self.allowUnlistedHosts = allowUnlistedHosts
    }

    func validate(_ rawURL: String, site: IOSWebMountSite? = nil) -> Result<URL, IOSWebMountURLPolicyError> {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let components = URLComponents(string: trimmedURL),
              let scheme = url.scheme?.lowercased() else {
            return .failure(.invalidURL)
        }
        guard allowedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard let host = Self.normalizedHost(url.host) else {
            return .failure(.missingHost)
        }
        guard components.user == nil, components.password == nil else {
            return .failure(.embeddedCredentialsNotAllowed)
        }
        if allowUnlistedHosts {
            guard IOSSearchExecutor.publicHostAllowed(host) else {
                return .failure(.privateHostNotAllowed(host))
            }
            return .success(url)
        }
        let hosts = allowedHosts.union(site?.allowedHosts.compactMap(Self.normalizedHost) ?? [])
        guard Self.host(host, matchesAnyOf: Array(hosts)) else {
            return .failure(.hostNotAllowed(host))
        }
        return .success(url)
    }

    func validateResolvedPublicHost(
        _ rawURL: String,
        site: IOSWebMountSite? = nil,
        resolveHost: @escaping IOSWebMountHostResolver
    ) async -> Result<URL, IOSWebMountURLPolicyError> {
        switch validate(rawURL, site: site) {
        case .failure(let error):
            return .failure(error)
        case .success(let url):
            guard allowUnlistedHosts, let host = Self.normalizedHost(url.host) else {
                return .success(url)
            }
            do {
                let addresses = try await Task.detached(priority: .userInitiated) {
                    try resolveHost(host)
                }.value
                guard !addresses.isEmpty,
                      addresses.allSatisfy(IOSSearchExecutor.publicHostAllowed) else {
                    return .failure(.privateHostNotAllowed(host))
                }
                return .success(url)
            } catch {
                return .failure(.privateHostNotAllowed(host))
            }
        }
    }

    static func normalizedHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func host(_ rawHost: String?, matchesAnyOf allowedHosts: [String]) -> Bool {
        guard let host = normalizedHost(rawHost) else { return false }
        return allowedHosts.compactMap(normalizedHost).contains { allowed in
            host == allowed ||
                (host.hasPrefix("www.") && String(host.dropFirst(4)) == allowed) ||
                (allowed.hasPrefix("www.") && String(allowed.dropFirst(4)) == host)
        }
    }
}

struct IOSWebMountCookieSummary: Codable, Equatable {
    let siteId: String
    let cookieCount: Int
    let cookieNames: [String]
    let domains: [String]
    let hasLoginCookie: Bool?
    let redacted: Bool
}

struct IOSWebMountCookieClearResult: Codable, Equatable {
    let siteId: String
    let deletedCookieCount: Int
    let clearedWebsiteDataRecords: Int
}

@MainActor
protocol IOSWebMountCookieStoreProtocol: AnyObject {
    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary
    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult
}

@MainActor
final class IOSWebMountCookieStore: IOSWebMountCookieStoreProtocol {
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore? = nil) {
        self.dataStore = dataStore ?? WKWebsiteDataStore.default()
    }

    func summary(for site: IOSWebMountSite) async -> IOSWebMountCookieSummary {
        let allCookies = await allCookies()
        let cookies = allCookies.filter { cookie in
            IOSWebMountURLPolicy.host(cookie.domain, matchesAnyOf: site.allowedHosts)
        }
        let names = cookies.map(\.name).uniqued().sorted()
        let domains = cookies.map(\.domain).uniqued().sorted()
        let hasLoginCookie = site.loginCookieName.map { names.contains($0) }
        return IOSWebMountCookieSummary(
            siteId: site.id,
            cookieCount: cookies.count,
            cookieNames: names,
            domains: domains,
            hasLoginCookie: hasLoginCookie,
            redacted: true
        )
    }

    func clearSession(for site: IOSWebMountSite) async -> IOSWebMountCookieClearResult {
        let allCookies = await allCookies()
        let cookies = allCookies.filter { cookie in
            IOSWebMountURLPolicy.host(cookie.domain, matchesAnyOf: site.allowedHosts)
        }
        for cookie in cookies {
            await delete(cookie)
        }
        let dataRecords = await dataRecords()
        let records = dataRecords.filter { record in
            IOSWebMountURLPolicy.host(record.displayName, matchesAnyOf: site.allowedHosts)
        }
        if !records.isEmpty {
            await remove(records: records)
        }
        return IOSWebMountCookieClearResult(
            siteId: site.id,
            deletedCookieCount: cookies.count,
            clearedWebsiteDataRecords: records.count
        )
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.delete(cookie) {
                continuation.resume()
            }
        }
    }

    private func dataRecords() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                continuation.resume(returning: records)
            }
        }
    }

    private func remove(records: [WKWebsiteDataRecord]) async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: records
            ) {
                continuation.resume()
            }
        }
    }
}

struct IOSWebMountRuntimeSnapshot: Codable, Equatable, Sendable {
    let sessionId: String
    var status: IOSWebMountRuntimeStatus
    var requestedURL: String?
    var currentURL: String?
    var title: String?
    var estimatedProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    var error: String?
    var updatedAtMillis: Int64

    static func idle(sessionId: String) -> IOSWebMountRuntimeSnapshot {
        IOSWebMountRuntimeSnapshot(
            sessionId: sessionId,
            status: .idle,
            requestedURL: nil,
            currentURL: nil,
            title: nil,
            estimatedProgress: 0,
            canGoBack: false,
            canGoForward: false,
            error: nil,
            updatedAtMillis: 0
        )
    }
}

struct IOSWebMountScreenshotCapture: Equatable {
    let data: Data
    let width: Int
    let height: Int
    let format: String
}

@MainActor
protocol IOSWebMountRuntimeServicing: AnyObject {
    var snapshot: IOSWebMountRuntimeSnapshot { get }
    var webView: WKWebView? { get }
    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot
    func state() async throws -> [String: Any]
    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any]
    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any]
    func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) async throws -> [String: Any]
    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any]
    func screenshot() async throws -> IOSWebMountScreenshotCapture
    func back() async -> IOSWebMountRuntimeSnapshot
    func forward() async -> IOSWebMountRuntimeSnapshot
}

extension IOSWebMountRuntimeServicing {
    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        let page = try await state()
        let readable = try await extract(mode: "readable", maxChars: maxChars, maxLinks: maxLinks)
        let interactive = try await extract(mode: "interactive", maxChars: 0, maxLinks: 80)
        let visual = try await extract(mode: "snapshot", maxChars: 0, maxLinks: 80)
        return [
            "observation_consistency": "legacy_multi_read",
            "document_id": interactive["document_id"] ?? page["document_id"] ?? "",
            "page_revision": interactive["page_revision"] ?? page["page_revision"] ?? 0,
            "snapshot_id": interactive["snapshot_id"] ?? page["snapshot_id"] ?? "",
            "page": page,
            "visible_text": readable["text"] ?? "",
            "links": readable["links"] ?? [],
            "interactive_elements": interactive["nodes"] ?? [],
            "visual_candidates": visual["visual_candidates"] ?? []
        ]
    }
}

@MainActor
final class IOSWebMountWKRuntime: NSObject, ObservableObject, IOSWebMountRuntimeServicing, WKNavigationDelegate {
    static let automationContentWorld = WKContentWorld.world(name: "app.amber.webmount.automation")

    let webView: WKWebView?
    @Published private(set) var snapshot: IOSWebMountRuntimeSnapshot

    private var loadSequence = 0
    private var pendingLoad: (id: Int, continuation: CheckedContinuation<IOSWebMountRuntimeSnapshot, Never>)?
    private var navigationPolicy: IOSWebMountURLPolicy?
    private var navigationSite: IOSWebMountSite?
    private var navigationHostResolver: IOSWebMountHostResolver = IOSSearchExecutor.resolveIPAddresses
    private var navigationDecisionSequence = 0
    private var approvedMainFrameDestination: String?

    override convenience init() {
        self.init(sessionId: nil)
    }

    init(sessionId: String?) {
        let resolvedSessionId = sessionId?.nilIfBlank
            ?? "ios_wm_" + String(UUID().uuidString.prefix(8))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        self.snapshot = .idle(sessionId: resolvedSessionId)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func setNavigationPolicy(
        _ policy: IOSWebMountURLPolicy,
        site: IOSWebMountSite?,
        resolveHost: @escaping IOSWebMountHostResolver = IOSSearchExecutor.resolveIPAddresses
    ) {
        navigationPolicy = policy
        navigationSite = site
        navigationHostResolver = resolveHost
        navigationDecisionSequence += 1
        approvedMainFrameDestination = nil
    }

    func open(_ url: URL, timeoutMillis: UInt64 = 30_000) async -> IOSWebMountRuntimeSnapshot {
        guard let webView else {
            snapshot.status = .failed
            snapshot.error = "WKWebView is unavailable"
            return snapshot
        }
        loadSequence += 1
        let loadId = loadSequence
        pendingLoad?.continuation.resume(returning: snapshot)
        pendingLoad = nil
        snapshot = IOSWebMountRuntimeSnapshot(
            sessionId: snapshot.sessionId,
            status: .loading,
            requestedURL: IOSWebMountRedactor.redactedURL(url.absoluteString),
            currentURL: IOSWebMountRedactor.redactedURL(webView.url?.absoluteString),
            title: webView.title,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            error: nil,
            updatedAtMillis: IOSWebMountClock.nowMillis()
        )
        webView.load(URLRequest(url: url))
        return await withCheckedContinuation { continuation in
            pendingLoad = (loadId, continuation)
            Task { @MainActor [weak self] in
                let nanos = timeoutMillis * 1_000_000
                try? await Task.sleep(nanoseconds: nanos)
                guard let self,
                      let pendingLoad = self.pendingLoad,
                      pendingLoad.id == loadId else { return }
                self.snapshot.status = .failed
                self.snapshot.error = "load timed out after \(timeoutMillis)ms"
                self.snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
                self.pendingLoad = nil
                pendingLoad.continuation.resume(returning: self.snapshot)
            }
        }
    }

    func state() async throws -> [String: Any] {
        let bridgeState = try await evaluateJSON(IOSWebMountBridgeScripts.state)
        return bridgeState.merging(snapshot.dictionary(redactURLs: true)) { page, _ in page }
    }

    func observe(maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        var observation = try await evaluateJSON(
            IOSWebMountBridgeScripts.extract(
                mode: "snapshot",
                maxChars: maxChars,
                maxLinks: maxLinks
            )
        )
        let page = (observation["page"] as? [String: Any] ?? [:])
            .merging(snapshot.dictionary(redactURLs: true)) { page, _ in page }
        observation["page"] = page
        observation["observation_consistency"] = "atomic"
        return observation
    }

    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] {
        try await evaluateJSON(
            IOSWebMountBridgeScripts.extract(
                mode: mode,
                maxChars: maxChars,
                maxLinks: maxLinks
            )
        )
    }

    func get(
        selector: String?,
        target: String?,
        kind: String,
        attrName: String?,
        maxChars: Int
    ) async throws -> [String: Any] {
        try await evaluateJSON(
            IOSWebMountBridgeScripts.get(
                selector: selector,
                target: target,
                kind: kind,
                attrName: attrName,
                maxChars: maxChars
            )
        )
    }

    /// Drives a page interaction (click/type/scroll/keys/select/find/wait) via a
    /// restricted JS bridge. Android WebMountInteractionTools parity. Only the
    /// listed methods are permitted; arbitrary JS eval stays disabled.
    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] {
        if method.lowercased() == "wait" {
            var waitOptions = options
            if waitOptions["selector"] == nil, let selector {
                waitOptions["selector"] = selector
            }
            if waitOptions["selector"] == nil, let target = options["target"] {
                waitOptions["selector"] = target
            }
            return await waitForCondition(options: waitOptions)
        }
        return try await evaluateJSON(
            IOSWebMountBridgeScripts.interact(
                method: method,
                selector: selector,
                text: text,
                options: options
            )
        )
    }

    private func waitForCondition(options: [String: Any]) async -> [String: Any] {
        let condition = ((options["condition"] as? String)?.nilIfBlank ?? "dom_stable").lowercased()
        let supported = Set(["dom_stable", "selector", "text", "url_contains", "ready_state", "delay"])
        guard supported.contains(condition) else {
            return [
                "ok": false,
                "method": "wait",
                "error_code": "unsupported_wait_condition",
                "condition": condition
            ]
        }
        let requiredArgument: String?
        switch condition {
        case "selector": requiredArgument = (options["selector"] as? String)?.nilIfBlank
        case "text": requiredArgument = (options["text"] as? String)?.nilIfBlank
        case "url_contains": requiredArgument = (options["url_contains"] as? String)?.nilIfBlank
        case "ready_state": requiredArgument = (options["ready_state"] as? String)?.nilIfBlank
        default: requiredArgument = "not-required"
        }
        guard requiredArgument != nil else {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": "missing_wait_argument",
                "matched": false
            ]
        }
        if condition == "ready_state",
           !["interactive", "complete"].contains(requiredArgument?.lowercased() ?? "") {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": "invalid_ready_state",
                "matched": false
            ]
        }

        let rawTimeout = (options["wait_ms"] as? Int)
            ?? (options["timeout_ms"] as? Int)
            ?? (options["wait_ms"] as? NSNumber)?.intValue
            ?? (options["timeout_ms"] as? NSNumber)?.intValue
            ?? 5_000
        let timeoutMillis = rawTimeout.clamped(to: 100...30_000)
        let stableMillis = ((options["stable_ms"] as? Int)
            ?? (options["stable_ms"] as? NSNumber)?.intValue
            ?? 400).clamped(to: 100...2_000)
        let startedAt = Date()

        if condition == "delay" {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutMillis) * 1_000_000)
                return [
                    "ok": true,
                    "method": "wait",
                    "condition": condition,
                    "elapsed_ms": timeoutMillis,
                    "matched": true
                ]
            } catch {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "cancelled",
                    "matched": false
                ]
            }
        }

        var lastSnapshotId: String?
        var stableSince: Date?
        var lastProbe: [String: Any] = [:]
        var lastError: String?

        while true {
            if Task.isCancelled {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "cancelled",
                    "matched": false
                ]
            }

            do {
                let probe = try await evaluateJSON(IOSWebMountBridgeScripts.waitProbe(condition: condition, options: options))
                lastProbe = probe
                lastError = nil
                if let errorCode = (probe["error_code"] as? String)?.nilIfBlank {
                    var result = probe
                    result["ok"] = false
                    result["method"] = "wait"
                    result["condition"] = condition
                    result["error_code"] = errorCode
                    result["matched"] = false
                    result["elapsed_ms"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    return result
                }
                if condition == "dom_stable" {
                    let snapshotId = probe["snapshot_id"] as? String
                    let readyState = probe["ready_state"] as? String
                    if snapshotId == lastSnapshotId, readyState != "loading" {
                        stableSince = stableSince ?? Date()
                        if let stableSince,
                           Date().timeIntervalSince(stableSince) * 1_000 >= Double(stableMillis) {
                            var result = probe
                            result["ok"] = true
                            result["method"] = "wait"
                            result["condition"] = condition
                            result["matched"] = true
                            result["elapsed_ms"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
                            return result
                        }
                    } else {
                        lastSnapshotId = snapshotId
                        stableSince = nil
                    }
                } else if probe["matched"] as? Bool == true {
                    var result = probe
                    result["ok"] = true
                    result["method"] = "wait"
                    result["condition"] = condition
                    result["elapsed_ms"] = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    return result
                }
            } catch {
                // A navigation can transiently replace the JS context. Keep polling
                // within the same bounded deadline and report the last error on timeout.
                lastError = error.localizedDescription
            }

            let elapsedMillis = Int(Date().timeIntervalSince(startedAt) * 1_000)
            if elapsedMillis >= timeoutMillis {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "wait_timeout",
                    "matched": false,
                    "elapsed_ms": elapsedMillis,
                    "last_snapshot_id": lastProbe["snapshot_id"] as? String ?? "",
                    "last_error": lastError ?? ""
                ]
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(min(100, timeoutMillis - elapsedMillis)) * 1_000_000)
            } catch {
                return [
                    "ok": false,
                    "method": "wait",
                    "condition": condition,
                    "error_code": "cancelled",
                    "matched": false
                ]
            }
        }
    }

    func screenshot() async throws -> IOSWebMountScreenshotCapture {
        guard let webView else { throw IOSWebMountRuntimeError.webViewUnavailable }
#if canImport(UIKit)
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: IOSWebMountRuntimeError.invalidBridgePayload)
                }
            }
        }
        guard let data = image.pngData() else {
            throw IOSWebMountRuntimeError.invalidBridgePayload
        }
        return IOSWebMountScreenshotCapture(
            data: data,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale),
            format: "png"
        )
#else
        throw IOSWebMountRuntimeError.webViewUnavailable
#endif
    }

    func back() async -> IOSWebMountRuntimeSnapshot {
        guard let webView, webView.canGoBack else {
            snapshot.canGoBack = webView?.canGoBack ?? false
            snapshot.canGoForward = webView?.canGoForward ?? false
            snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
            return snapshot
        }
        webView.goBack()
        snapshot.status = .loading
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        return snapshot
    }

    func forward() async -> IOSWebMountRuntimeSnapshot {
        guard let webView, webView.canGoForward else {
            snapshot.canGoBack = webView?.canGoBack ?? false
            snapshot.canGoForward = webView?.canGoForward ?? false
            snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
            return snapshot
        }
        webView.goForward()
        snapshot.status = .loading
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        return snapshot
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let policy = navigationPolicy,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let site = navigationSite
        let resolver = navigationHostResolver
        let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
        if isMainFrame {
            navigationDecisionSequence += 1
        }
        let decisionSequence = navigationDecisionSequence
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.cancel)
                return
            }
            switch await policy.validateResolvedPublicHost(
                url.absoluteString,
                site: site,
                resolveHost: resolver
            ) {
            case .success(let verifiedURL):
                guard decisionSequence == self.navigationDecisionSequence else {
                    decisionHandler(.cancel)
                    return
                }
                if isMainFrame {
                    self.approvedMainFrameDestination = Self.navigationDestinationKey(verifiedURL)
                }
                decisionHandler(.allow)
            case .failure(let error):
                if isMainFrame, decisionSequence == self.navigationDecisionSequence {
                    self.rejectNavigation(error, url: url, webView: webView)
                }
                decisionHandler(.cancel)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        guard let policy = navigationPolicy else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationResponse.response.url else {
            decisionHandler(.cancel)
            return
        }
        let site = navigationSite
        let resolver = navigationHostResolver
        let decisionSequence = navigationDecisionSequence
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.cancel)
                return
            }
            switch await policy.validateResolvedPublicHost(
                url.absoluteString,
                site: site,
                resolveHost: resolver
            ) {
            case .success(let verifiedURL):
                guard decisionSequence == self.navigationDecisionSequence else {
                    decisionHandler(.cancel)
                    return
                }
                self.approvedMainFrameDestination = Self.navigationDestinationKey(verifiedURL)
                decisionHandler(.allow)
            case .failure(let error):
                if decisionSequence == self.navigationDecisionSequence {
                    self.rejectNavigation(error, url: url, webView: webView)
                }
                decisionHandler(.cancel)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        snapshot.status = .loading
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = nil
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard committedNavigationIsAllowed(webView) else { return }
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard committedNavigationIsAllowed(webView) else { return }
        snapshot.status = .ready
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.title = webView.title
        snapshot.estimatedProgress = 1
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = nil
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        completePendingLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        snapshot.status = .failed
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView?.url?.absoluteString)
        snapshot.title = webView?.title
        snapshot.estimatedProgress = webView?.estimatedProgress ?? 0
        snapshot.canGoBack = webView?.canGoBack ?? false
        snapshot.canGoForward = webView?.canGoForward ?? false
        snapshot.error = error.localizedDescription
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        completePendingLoad()
    }

    private func committedNavigationIsAllowed(_ webView: WKWebView) -> Bool {
        guard let policy = navigationPolicy, let url = webView.url else { return true }
        guard case .failure(let error) = policy.validate(url.absoluteString, site: navigationSite) else {
            guard Self.navigationDestinationKey(url) == approvedMainFrameDestination else {
                webView.stopLoading()
                rejectNavigation(
                    .navigationTargetNotVerified(url.host ?? "unknown"),
                    url: url,
                    webView: webView
                )
                return false
            }
            return true
        }
        webView.stopLoading()
        rejectNavigation(error, url: url, webView: webView)
        return false
    }

    private static func navigationDestinationKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = IOSWebMountURLPolicy.normalizedHost(url.host) else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
        return "\(scheme)://\(host):\(port)"
    }

    private func rejectNavigation(
        _ error: IOSWebMountURLPolicyError,
        url: URL,
        webView: WKWebView
    ) {
        snapshot.status = .failed
        snapshot.requestedURL = IOSWebMountRedactor.redactedURL(url.absoluteString)
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.title = webView.title
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = error.localizedDescription
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
        completePendingLoad()
    }

    private func completePendingLoad() {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        pendingLoad.continuation.resume(returning: snapshot)
    }

    private func evaluateJSON(_ script: String) async throws -> [String: Any] {
        guard let webView else { throw IOSWebMountRuntimeError.webViewUnavailable }
        let value = try await webView.evaluateJavaScript(
            script,
            contentWorld: Self.automationContentWorld
        )
        let jsonString: String
        if let value = value as? String {
            jsonString = value
        } else if let value {
            jsonString = String(describing: value)
        } else {
            jsonString = "{}"
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOSWebMountRuntimeError.invalidBridgePayload
        }
        return object
    }
}

enum IOSWebMountRuntimeError: Error {
    case webViewUnavailable
    case invalidBridgePayload
}

enum IOSWebMountBridgeScripts {
    private static let semanticPrelude = """
      function amberBridge(){
        var bridge=window.__amberWebMountBridgeV1;
        if(!bridge || bridge.document!==document){
          var documentId=(Date.now().toString(36)+Math.random().toString(36).slice(2,10));
          bridge={document:document,documentId:documentId,revision:0,nextRef:1,refs:{},elementRefs:new WeakMap()};
          bridge.snapshotId=function(){return bridge.documentId+":"+bridge.revision;};
          bridge.bump=function(){bridge.revision+=1;return bridge.snapshotId();};
          bridge.refFor=function(el){
            if(!el || el.nodeType!==1) return "";
            var existing=bridge.elementRefs.get(el);
            if(existing) return existing;
            if(Object.keys(bridge.refs).length>256){
              Object.keys(bridge.refs).forEach(function(key){if(!bridge.refs[key]||!bridge.refs[key].isConnected) delete bridge.refs[key];});
            }
            var ref="wm:"+bridge.documentId+":"+(bridge.nextRef++);
            bridge.elementRefs.set(el,ref);bridge.refs[ref]=el;return ref;
          };
          bridge.resolve=function(raw){
            var target=String(raw||"");
            if(target.indexOf("wm:")===0){
              if(target.indexOf("wm:"+bridge.documentId+":")!==0) return {errorCode:"stale_ref",element:null};
              var referenced=bridge.refs[target];
              if(!referenced || !referenced.isConnected) return {errorCode:"stale_ref",element:null};
              return {errorCode:"",element:referenced};
            }
            if(target.indexOf("css:")===0) target=target.slice(4);
            if(!target) return {errorCode:"missing_target",element:null};
            try{return {errorCode:"",element:document.querySelector(target)};}
            catch(e){return {errorCode:"invalid_selector",element:null};}
          };
          try{
            bridge.observer=new MutationObserver(function(){
              bridge.revision+=1;
              if(Object.keys(bridge.refs).length>256){
                Object.keys(bridge.refs).forEach(function(key){if(!bridge.refs[key]||!bridge.refs[key].isConnected) delete bridge.refs[key];});
              }
            });
            bridge.observer.observe(document,{subtree:true,childList:true,attributes:true,characterData:true});
          }catch(e){}
          try{
            bridge.eventBump=function(){bridge.revision+=1;};
            document.addEventListener("input",bridge.eventBump,true);
            document.addEventListener("change",bridge.eventBump,true);
            window.addEventListener("scroll",bridge.eventBump,true);
          }catch(e){}
          window.__amberWebMountBridgeV1=bridge;
        }
        return bridge;
      }
      function amberVisible(el){
        if(!el || !el.isConnected) return false;
        var node=el;
        while(node && node.nodeType===1){
          var style=window.getComputedStyle?window.getComputedStyle(node):null;
          if(node.hidden || (style && (style.display==="none" || style.visibility==="hidden" || Number(style.opacity)===0))) return false;
          node=node.parentElement;
        }
        var rect=el.getBoundingClientRect();
        return !!(rect.width&&rect.height&&rect.bottom>=0&&rect.right>=0&&rect.top<=(window.innerHeight||0)&&rect.left<=(window.innerWidth||0));
      }
      function amberRole(el){
        var explicit=el&&el.getAttribute?el.getAttribute("role"):"";
        if(explicit) return explicit;
        var tag=(el&&el.tagName||"").toLowerCase();
        if(tag==="a") return "link"; if(tag==="button") return "button";
        if(tag==="input"){
          var type=(el.getAttribute("type")||"text").toLowerCase();
          if(type==="checkbox"||type==="radio"||type==="button"||type==="submit"||type==="reset"||type==="range") return type==="submit"||type==="reset"?"button":type;
          return "textbox";
        }
        if(tag==="textarea" || (el&&el.isContentEditable)) return "textbox";
        if(tag==="select") return "combobox"; return tag;
      }
      function amberName(el){
        if(!el) return "";
        var tag=(el.tagName||"").toLowerCase();
        var label=el.getAttribute&&(el.getAttribute("aria-label")||el.getAttribute("alt")||el.getAttribute("title")||el.getAttribute("placeholder"))||"";
        if(!label && el.getAttribute){
          var labelledBy=String(el.getAttribute("aria-labelledby")||"").trim().split(/\\s+/).filter(Boolean);
          label=labelledBy.map(function(id){var node=document.getElementById(id);return node?(node.innerText||node.textContent||""):"";}).join(" ");
        }
        if(!label && el.labels && el.labels.length && amberVisible(el.labels[0])){label=el.labels[0].innerText||"";}
        var text=label || ((tag==="input"||tag==="textarea"||tag==="select")?"":(el.innerText||""));
        return String(text).replace(/\\s+/g," ").trim().slice(0,240);
      }
      function amberSensitiveField(el){
        if(!el || !el.getAttribute) return false;
        var type=(el.getAttribute("type")||"").toLowerCase();
        var autocomplete=(el.getAttribute("autocomplete")||"").toLowerCase();
        var identity=(el.id||"")+" "+(el.name||"")+" "+(el.getAttribute("aria-label")||"")+" "+(el.getAttribute("placeholder")||"");
        return type==="password" || type==="hidden" ||
          /current-password|new-password|one-time-code|cc-number|cc-csc|cc-exp|cc-name/.test(autocomplete) ||
          /password|passwd|passcode|token|secret|cookie|authorization|otp|2fa|mfa|totp|one[-_ ]?time|verification.?code|captcha|card.?number|credit.?card|\\bpan\\b|cvv|cvc|security.?code/i.test(identity);
      }
      function amberActionable(el){
        if(!amberVisible(el)) return false;
        var node=el;
        while(node && node.nodeType===1){
          var style=window.getComputedStyle?window.getComputedStyle(node):null;
          if(node.inert || node.getAttribute("aria-hidden")==="true" || (style&&style.pointerEvents==="none")) return false;
          node=node.parentElement;
        }
        return !(el.disabled || (el.getAttribute&&el.getAttribute("aria-disabled")==="true"));
      }
      function amberActionIdentity(el){
        if(!el) return "";
        var form=el.form;
        var parts=[amberRole(el),amberName(el),el.id||"",el.name||"",el.getAttribute&&el.getAttribute("type")||"",el.getAttribute&&el.getAttribute("aria-label")||""];
        if(form) parts.push(form.id||"",form.name||"",form.getAttribute&&form.getAttribute("aria-label")||"",form.getAttribute&&form.getAttribute("action")||"");
        return parts.join(" ").replace(/\\s+/g," ").trim().slice(0,480);
      }
      function amberActionDisposition(el,method,text,coordinate){
        var identity=amberActionIdentity(el);
        var lower=identity.toLowerCase();
        var key=String(text||"").toLowerCase();
        var human=/captcha|two.?factor|2fa|mfa|\\botp\\b|one.?time|verification.?code|passkey|oauth|sign.?in|log.?in|登录|验证码|人机验证/.test(lower);
        if((method==="type"||method==="keys"||method==="select") && amberSensitiveField(el)) human=true;
        if(human) return {kind:"human",reason:"login_or_sensitive_field",label:amberName(el)};
        if(coordinate) return {kind:"approval",reason:"coordinate_tap",label:amberName(el)};
        if(method==="keys" && key==="enter") return {kind:"approval",reason:"enter_may_submit",label:amberName(el)};
        var buttonType=el && el.getAttribute ? (el.getAttribute("type")||"").toLowerCase() : "";
        var submit=el && el.getAttribute && (buttonType==="submit" || (el.tagName==="BUTTON" && el.form && !buttonType));
        var consequential=/\\b(pay|payment|purchase|buy|checkout|place.?order|submit|authorize|approve|confirm|send|publish|delete|remove)\\b|支付|付款|购买|下单|提交|授权|确认|发送|发布|删除/.test(lower);
        if(method==="type" && el && el.form && /submit|checkout|payment|order|支付|下单|提交/.test(lower)) consequential=true;
        if(method==="select" && /payment|billing|checkout|order|支付|账单|订单/.test(lower)) consequential=true;
        if(submit||consequential) return {kind:"approval",reason:"high_consequence_action",label:amberName(el)};
        return {kind:"safe",reason:"",label:amberName(el)};
      }
    """

    static let state = """
    (function(){
      \(semanticPrelude)
      function cleanUrl(raw){try{var u=new URL(raw);return u.origin+u.pathname;}catch(e){return "";}}
      var bridge=amberBridge();
      var body=document.body;
      return JSON.stringify({
        url: cleanUrl(location.href),
        title: document.title || "",
        ready_state: document.readyState || "unknown",
        document_id: bridge.documentId,
        page_revision: bridge.revision,
        snapshot_id: bridge.snapshotId(),
        text_length: body && body.innerText ? body.innerText.length : 0,
        links_count: document.links ? document.links.length : 0,
        viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
        scroll: { x: window.scrollX || 0, y: window.scrollY || 0 }
      });
    })();
    """

    static func extract(mode: String, maxChars: Int, maxLinks: Int) -> String {
        let mode = jsString(mode)
        let maxChars = max(0, min(maxChars, 80_000))
        let maxLinks = max(0, min(maxLinks, 100))
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw, location.href);return u.origin+u.pathname;}catch(e){return "";}}
          function cssPath(el){
            if(!el || !el.tagName) return "";
            var path=[];
            while(el && el.nodeType===1 && path.length<5){
              var part=el.tagName.toLowerCase();
              if(el.id){part += "#" + CSS.escape(el.id); path.unshift(part); break;}
              var parent=el.parentElement;
              if(parent){
                var peers=Array.prototype.filter.call(parent.children,function(x){return x.tagName===el.tagName;});
                if(peers.length>1) part += ":nth-of-type(" + (peers.indexOf(el)+1) + ")";
              }
              path.unshift(part); el=parent;
            }
            return path.join(" > ");
          }
          var bridge=amberBridge();
          var mode=\(mode);
          var body=document.body;
          if(mode==="interactive" || mode==="snapshot"){
            var nodes=Array.prototype.slice.call(document.querySelectorAll("a,button,input,textarea,select,[contenteditable='true'],[role='button'],[role='link'],[role='tab'],[role='menuitem'],[role='checkbox'],[role='radio'],[role='combobox'],[role='textbox'],[role='switch']"),0,200).filter(amberVisible).slice(0,100).map(function(el,idx){
                var rect=el.getBoundingClientRect();
              return {
                ref:bridge.refFor(el),
                selector:"css:"+cssPath(el),
                tag:(el.tagName||"").toLowerCase(),
                role:amberRole(el),
                name:amberName(el),
                text:amberName(el),
                href: el.href ? cleanUrl(el.href) : "",
                visible: amberVisible(el),
                actionable: amberActionable(el),
                disabled: !!el.disabled,
                checked: typeof el.checked==="boolean" ? el.checked : null,
                focused: document.activeElement===el,
                rect: {
                  x: Math.round(rect.x || 0),
                  y: Math.round(rect.y || 0),
                  width: Math.round(rect.width || 0),
                  height: Math.round(rect.height || 0)
                }
              };
            });
            if(mode==="interactive"){
              return JSON.stringify({ mode: mode, url: cleanUrl(location.href), document_id:bridge.documentId, page_revision:bridge.revision, snapshot_id:bridge.snapshotId(), nodes: nodes });
            }
            function nearbyText(el){
              var text="";
              if(el.getAttribute) text = el.getAttribute("alt") || el.getAttribute("title") || el.getAttribute("aria-label") || "";
              if(!text && el.parentElement) text = el.parentElement.innerText || "";
              return String(text || "").replace(/\\s+/g," ").trim().slice(0,240);
            }
            var candidates=Array.prototype.slice.call(document.querySelectorAll("img,iframe,canvas,video,svg,picture,h1,h2,h3,p,blockquote,article,section"),0,120).map(function(el){
              var rect=el.getBoundingClientRect();
              return {
                ref:bridge.refFor(el),
                selector:"css:"+cssPath(el),
                tag:(el.tagName||"").toLowerCase(),
                src: el.currentSrc ? cleanUrl(el.currentSrc) : (el.src ? cleanUrl(el.src) : ""),
                href: el.href ? cleanUrl(el.href) : "",
                alt: el.getAttribute ? (el.getAttribute("alt") || "") : "",
                title: el.getAttribute ? (el.getAttribute("title") || "") : "",
                nearby_text: nearbyText(el),
                visible: !!(rect.width && rect.height && rect.bottom >= 0 && rect.right >= 0 && rect.top <= (window.innerHeight || 0) && rect.left <= (window.innerWidth || 0)),
                rect: {
                  x: Math.round(rect.x || 0),
                  y: Math.round(rect.y || 0),
                  width: Math.round(rect.width || 0),
                  height: Math.round(rect.height || 0)
                }
              };
            }).filter(function(item){ return item.visible && (item.rect.width || item.rect.height); });
            var visibleText=(body && body.innerText ? body.innerText : "").replace(/\\s+/g," ").trim().slice(0,\(maxChars));
            var links=Array.prototype.slice.call(document.querySelectorAll("a[href]"),0,500).filter(amberVisible).slice(0,\(maxLinks)).map(function(a){
              return { text:(a.innerText||a.getAttribute("aria-label")||"").trim().slice(0,200), href: cleanUrl(a.href) };
            });
            var page={
              url:cleanUrl(location.href),
              title:document.title||"",
              ready_state:document.readyState||"unknown",
              document_id:bridge.documentId,
              page_revision:bridge.revision,
              snapshot_id:bridge.snapshotId(),
              text_length:body&&body.innerText?body.innerText.length:0,
              links_count:document.links?document.links.length:0,
              viewport:{width:window.innerWidth||0,height:window.innerHeight||0},
              scroll:{x:window.scrollX||0,y:window.scrollY||0}
            };
            return JSON.stringify({
              mode: mode,
              url: cleanUrl(location.href),
              document_id: bridge.documentId,
              page_revision: bridge.revision,
              snapshot_id: bridge.snapshotId(),
              page: page,
              visible_text: visibleText,
              links: links,
              interactive_elements: nodes,
              viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
              interactive_nodes: nodes,
              visual_candidates: candidates,
              redacted: true
            });
          }
          var text=(body && body.innerText ? body.innerText : "").slice(0,\(maxChars));
          var links=Array.prototype.slice.call(document.querySelectorAll("a[href]"),0,500).filter(amberVisible).slice(0,\(maxLinks)).map(function(a){
            return { text:(a.innerText||a.getAttribute("aria-label")||"").trim().slice(0,200), href: cleanUrl(a.href) };
          });
          return JSON.stringify({ mode:"readable", url: cleanUrl(location.href), title: document.title || "", document_id:bridge.documentId, page_revision:bridge.revision, snapshot_id:bridge.snapshotId(), text: text, links: links });
        })();
        """
    }

    static func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) -> String {
        let targetLiteral = jsString(selector ?? target ?? "css:body")
        let kindLiteral = jsString(kind)
        let attrLiteral = jsString(attrName ?? "")
        let maxChars = max(0, min(maxChars, 100_000))
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw, location.href);return u.origin+u.pathname;}catch(e){return "";}}
          var bridge=amberBridge(), target=\(targetLiteral), kind=\(kindLiteral), attr=\(attrLiteral);
          var resolved=bridge.resolve(target), el=resolved.element;
          if(resolved.errorCode){ return JSON.stringify({ok:false,error_code:resolved.errorCode,snapshot_id:bridge.snapshotId()}); }
          if(!el){ return JSON.stringify({ok:false,error_code:"target_not_found",snapshot_id:bridge.snapshotId()}); }
          if(!amberVisible(el)){ return JSON.stringify({ok:false,error_code:"target_not_visible",target_ref:bridge.refFor(el),snapshot_id:bridge.snapshotId()}); }
          var sensitive=amberSensitiveField(el) || /csrf|xsrf|auth/i.test((el.id||"")+" "+(el.name||""));
          if(kind==="value" && sensitive){
            return JSON.stringify({ok:false,error_code:"sensitive_value_denied",target_ref:bridge.refFor(el),snapshot_id:bridge.snapshotId()});
          }
          if(kind==="attr" && /password|passwd|token|csrf|xsrf|secret|cookie|authorization|auth/i.test(attr)){
            return JSON.stringify({ok:false,error_code:"sensitive_attribute_denied",target_ref:bridge.refFor(el),snapshot_id:bridge.snapshotId()});
          }
          if(kind==="attr" && attr.toLowerCase()==="value" && (el.tagName==="INPUT" || el.tagName==="TEXTAREA")){
            return JSON.stringify({ok:false,error_code:"sensitive_attribute_denied",target_ref:bridge.refFor(el),snapshot_id:bridge.snapshotId()});
          }
          var value="";
          if(kind==="value"){ value=el.value || ""; }
          else if(kind==="attr"){ value=attr ? (el.getAttribute(attr) || "") : ""; if(attr==="href" || attr==="src") value=cleanUrl(value); }
          else if(kind==="html"){ value=el.outerHTML || ""; }
          else { value=el.innerText || ""; }
          return JSON.stringify({ok:true,target_ref:bridge.refFor(el),kind:kind,value:String(value).slice(0,\(maxChars)),document_id:bridge.documentId,page_revision:bridge.revision,snapshot_id:bridge.snapshotId()});
        })();
        """
    }

    /// Builds a restricted interaction script. Stable refs are document-scoped,
    /// and an optional snapshot id rejects stale actions before they run.
    static func interact(method: String, selector: String?, text: String?, options: [String: Any]) -> String {
        func intOption(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = options[key] as? Int { return value }
                if let value = options[key] as? NSNumber { return value.intValue }
                if let value = options[key] as? Double { return Int(value) }
            }
            return nil
        }

        let method = method.lowercased()
        let target = selector ?? options["target"] as? String ?? ""
        let snapshotId = options["snapshot_id"] as? String ?? ""
        let xLiteral = intOption(["x"]).map(String.init) ?? "null"
        let yLiteral = intOption(["y"]).map(String.init) ?? "null"
        let byY = intOption(["dy", "by_y"]) ?? 0
        let namedPosition = (options["to"] as? String)?.lowercased() ?? ""
        let maxResults = max(1, min(intOption(["max_results"]) ?? 10, 20))
        let allowHighConsequence = options["_amber_allow_high_consequence"] as? Bool ?? false
        let preflightOnly = options["_amber_preflight_only"] as? Bool ?? false

        return """
        (function(){
          \(semanticPrelude)
          var bridge=amberBridge();
          var method=\(jsString(method)), target=\(jsString(target)), text=\(jsString(text ?? ""));
          var expectedSnapshot=\(jsString(snapshotId));
          var allowHighConsequence=\(allowHighConsequence ? "true" : "false");
          var preflightOnly=\(preflightOnly ? "true" : "false");
          function base(extra){
            var value={method:method,document_id:bridge.documentId,page_revision:bridge.revision,snapshot_id:bridge.snapshotId()};
            Object.keys(extra||{}).forEach(function(key){value[key]=extra[key];});
            return value;
          }
          function fail(code,extra){return JSON.stringify(base(Object.assign({ok:false,error_code:code},extra||{})));}
          function finish(extra){return JSON.stringify(base(Object.assign({ok:true},extra||{})));}
          function dispositionFailure(el,coordinate){
            var disposition=amberActionDisposition(el,method,text,coordinate);
            if(disposition.kind==="human"){
              return fail("sensitive_field_requires_human",{
                requires_human:true,
                handoff:true,
                handoff_reason:disposition.reason,
                resume_condition:"user_hands_back_control",
                target_ref:bridge.refFor(el),
                target_label:disposition.label||"",
                reason:"Complete login, verification, CAPTCHA, or sensitive payment input in user-controlled WebMount."
              });
            }
            if(disposition.kind==="approval" && !allowHighConsequence){
              return fail("high_consequence_requires_approval",{
                needs_user_action:true,
                consequence:disposition.reason,
                target_ref:bridge.refFor(el),
                target_label:disposition.label||"",
                reason:"This page action may submit, authorize, pay, send, publish, delete, or otherwise change remote state."
              });
            }
            return "";
          }
          function resolveTarget(required){
            if(!target) return required ? {errorCode:"missing_target",element:null} : {errorCode:"",element:null};
            return bridge.resolve(target);
          }
          function isDisabled(el){return !!(el && (el.disabled || (el.getAttribute&&el.getAttribute("aria-disabled")==="true")));}
          function topmost(el){
            var rect=el.getBoundingClientRect(), x=rect.left+rect.width/2, y=rect.top+rect.height/2;
            var hit=document.elementFromPoint(x,y);
            return !hit || hit===el || el.contains(hit);
          }
          function nativeSetValue(el,value){
            if(el && el.isContentEditable){el.textContent=value;return;}
            var proto=el.tagName==="TEXTAREA"?window.HTMLTextAreaElement&&HTMLTextAreaElement.prototype:window.HTMLInputElement&&HTMLInputElement.prototype;
            var descriptor=proto&&Object.getOwnPropertyDescriptor(proto,"value");
            if(descriptor&&descriptor.set) descriptor.set.call(el,value); else el.value=value;
          }
          function keyEvent(el,type,key){return el.dispatchEvent(new KeyboardEvent(type,{key:key,bubbles:true,cancelable:true}));}
          function inputEvent(el,type,data){
            try{return el.dispatchEvent(new InputEvent("beforeinput",{inputType:type,data:data,bubbles:true,cancelable:true}));}
            catch(e){return true;}
          }
          function insertText(el,value){
            var current=String(el.value||""), start=typeof el.selectionStart==="number"?el.selectionStart:current.length;
            var end=typeof el.selectionEnd==="number"?el.selectionEnd:start;
            var next=current.slice(0,start)+value+current.slice(end);
            nativeSetValue(el,next);
            try{el.setSelectionRange(start+value.length,start+value.length);}catch(e){}
            try{el.dispatchEvent(new InputEvent("input",{inputType:"insertText",data:value,bubbles:true}));}
            catch(e){el.dispatchEvent(new Event("input",{bubbles:true}));}
            return next.length;
          }
          if(expectedSnapshot && expectedSnapshot!==bridge.snapshotId()){
            return fail("stale_snapshot",{expected_snapshot_id:expectedSnapshot});
          }

          if(method==="click" || method==="tap"){
            var el=null, x=\(xLiteral), y=\(yLiteral);
            if(method==="tap" && x!==null && y!==null){el=document.elementFromPoint(x,y);}
            else {
              var resolved=resolveTarget(true);
              if(resolved.errorCode) return fail(resolved.errorCode);
              el=resolved.element;
            }
            if(!el) return fail("target_not_found");
            if(!preflightOnly && method==="click") el.scrollIntoView({block:"center",inline:"nearest"});
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            if(isDisabled(el)) return fail("target_disabled",{target_ref:bridge.refFor(el)});
            if(method==="click" && !topmost(el)) return fail("target_occluded",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,method==="tap" && x!==null && y!==null);
            if(blocked) return blocked;
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            el.click(); bridge.bump();
            return finish({found:true,target_ref:bridge.refFor(el),dispatched:true,verified:false});
          }

          if(method==="type" || method==="keys"){
            var hasExplicitTarget=!!target, resolved=resolveTarget(method==="type"), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(!el && method==="keys" && !hasExplicitTarget) el=document.activeElement;
            if(!el) return fail(hasExplicitTarget?"target_not_found":"focused_field_not_found");
            if(el===document.body || el===document.documentElement) return fail("focused_field_not_found");
            if(amberSensitiveField(el)) return fail("sensitive_field_requires_human",{requires_human:true,handoff:true,resume_condition:"user_hands_back_control",target_ref:bridge.refFor(el)});
            var contentEditable=!!el.isContentEditable;
            if(!(el.tagName==="INPUT" || el.tagName==="TEXTAREA" || (method==="type" && contentEditable))) return fail("target_not_typeable",{target_ref:bridge.refFor(el)});
            if(el.tagName==="INPUT"){
              var inputType=String(el.getAttribute("type")||"text").toLowerCase();
              var typeable={text:true,email:true,search:true,tel:true,url:true,number:true,date:true,"datetime-local":true,month:true,week:true,time:true};
              if(!typeable[inputType]) return fail("target_not_typeable",{target_ref:bridge.refFor(el),input_type:inputType});
            }
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,false);
            if(blocked) return blocked;
            if(isDisabled(el) || el.readOnly) return fail("target_not_editable",{target_ref:bridge.refFor(el)});
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            var wasFocused=document.activeElement===el;
            el.focus();
            if(method==="keys" && !wasFocused && typeof el.setSelectionRange==="function"){
              var end=String(el.value||"").length;
              try{el.setSelectionRange(end,end);}catch(e){}
            }
            if(method==="type"){
              if(!inputEvent(el,"insertText",text)) return fail("input_cancelled",{target_ref:bridge.refFor(el)});
              nativeSetValue(el,text);
              try{el.dispatchEvent(new InputEvent("input",{inputType:"insertText",data:text,bubbles:true}));}
              catch(e){el.dispatchEvent(new Event("input",{bubbles:true}));}
              bridge.bump();
              var resolvedValue=contentEditable?String(el.textContent||""):String(el.value||"");
              var typeVerified=resolvedValue===text;
              return finish({found:true,target_ref:bridge.refFor(el),value_length:resolvedValue.length,focused:document.activeElement===el,verified:typeVerified});
            }
            var special={enter:"Enter",tab:"Tab",escape:"Escape",backspace:"Backspace",arrowup:"ArrowUp",arrowdown:"ArrowDown",arrowleft:"ArrowLeft",arrowright:"ArrowRight"};
            var key=special[text.toLowerCase()]||"", defaultApplied=false;
            if(key){
              var allowed=keyEvent(el,"keydown",key);
              if(allowed && key==="Backspace"){
                var current=String(el.value||""), start=typeof el.selectionStart==="number"?el.selectionStart:current.length, end=typeof el.selectionEnd==="number"?el.selectionEnd:start;
                if(start===end && start>0) start-=1;
                nativeSetValue(el,current.slice(0,start)+current.slice(end));
                try{el.setSelectionRange(start,start);}catch(e){}
                el.dispatchEvent(new Event("input",{bubbles:true})); defaultApplied=true;
              }
              keyEvent(el,"keyup",key); bridge.bump();
              return finish({found:true,target_ref:bridge.refFor(el),key:key,event_dispatched:true,default_applied:defaultApplied,trusted:false,value_length:String(el.value||"").length,verified:defaultApplied});
            }
            var beforeLength=String(el.value||"").length, inserted=0;
            for(var i=0;i<text.length;i++){
              var ch=text.charAt(i), allowed=keyEvent(el,"keydown",ch);
              if(allowed && inputEvent(el,"insertText",ch)){insertText(el,ch);inserted+=1;}
              keyEvent(el,"keyup",ch);
            }
            bridge.bump();
            var afterLength=String(el.value||"").length;
            return finish({found:true,target_ref:bridge.refFor(el),event_count:text.length,inserted_count:inserted,trusted:false,value_length:afterLength,verified:inserted===text.length&&afterLength>=beforeLength});
          }

          if(method==="scroll"){
            var resolved=resolveTarget(false), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(preflightOnly) return finish({preflight_only:true,target_ref:el?bridge.refFor(el):"",target_label:el?amberName(el):"",verified:true});
            var position=\(jsString(namedPosition)), byY=\(byY);
            var beforeX=Math.round(window.scrollX||0), beforeY=Math.round(window.scrollY||0);
            if(el){el.scrollIntoView({block:position==="top"?"start":position==="bottom"?"end":"center",inline:"nearest"});}
            else if(position==="top"){window.scrollTo({top:0});}
            else if(position==="bottom"){window.scrollTo({top:document.documentElement.scrollHeight});}
            else {window.scrollBy({top:byY||400});}
            bridge.bump();
            var afterX=Math.round(window.scrollX||0), afterY=Math.round(window.scrollY||0);
            return finish({found:!!el,target_ref:el?bridge.refFor(el):"",scroll_x:afterX,scroll_y:afterY,verified:beforeX!==afterX||beforeY!==afterY});
          }

          if(method==="select"){
            var resolved=resolveTarget(true), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(!el) return fail("target_not_found");
            if(el.tagName!=="SELECT") return fail("target_not_selectable",{target_ref:bridge.refFor(el)});
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,false);
            if(blocked) return blocked;
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            var option=Array.prototype.find.call(el.options,function(item){return item.value===text;});
            if(!option) return fail("option_not_found",{target_ref:bridge.refFor(el)});
            el.value=text; el.dispatchEvent(new Event("input",{bubbles:true})); el.dispatchEvent(new Event("change",{bubbles:true})); bridge.bump();
            return finish({found:true,target_ref:bridge.refFor(el),selected_index:el.selectedIndex,verified:el.value===text});
          }

          if(method==="find"){
            var matches=[], maxResults=\(maxResults), query=text.toLowerCase();
            if(target){
              if(target.indexOf("wm:")===0){
                var resolved=bridge.resolve(target);
                if(resolved.errorCode) return fail(resolved.errorCode);
                if(resolved.element) matches=[resolved.element];
              } else {
                var css=target.indexOf("css:")===0?target.slice(4):target;
                try{matches=Array.prototype.slice.call(document.querySelectorAll(css),0,maxResults);}
                catch(e){return fail("invalid_selector");}
              }
            } else if(query){
              var candidates=Array.prototype.slice.call(document.querySelectorAll("a,button,input,textarea,select,[contenteditable='true'],label,p,span,div,main,li,h1,h2,h3,h4,h5,h6,td,th,article,section,[role]"),0,600);
              matches=candidates.filter(function(item){return amberVisible(item) && amberName(item).toLowerCase().indexOf(query)>=0;}).slice(0,maxResults);
            }
            var output=matches.filter(amberVisible).slice(0,maxResults).map(function(item){return {ref:bridge.refFor(item),tag:(item.tagName||"").toLowerCase(),role:amberRole(item),name:amberName(item),visible:true};});
            return finish({found:output.length>0,count:output.length,matches:output,verified:output.length>0});
          }
          return fail("unsupported_interaction");
        })();
        """
    }

    static func waitProbe(condition: String, options: [String: Any]) -> String {
        let selector = options["selector"] as? String ?? ""
        let text = options["text"] as? String ?? ""
        let urlFragment = options["url_contains"] as? String ?? ""
        let readyState = (options["ready_state"] as? String)?.lowercased() ?? "complete"
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw);return u.origin+u.pathname;}catch(e){return "";}}
          var bridge=amberBridge(), condition=\(jsString(condition)), matched=false, errorCode="";
          if(condition==="selector"){
            var resolved=bridge.resolve(\(jsString(selector)));
            errorCode=resolved.errorCode||""; matched=!!resolved.element && amberVisible(resolved.element);
          } else if(condition==="text"){
            matched=String(document.body&&document.body.innerText||"").indexOf(\(jsString(text)))>=0;
          } else if(condition==="url_contains"){
            matched=String(location.href||"").indexOf(\(jsString(urlFragment)))>=0;
          } else if(condition==="ready_state"){
            var expected=\(jsString(readyState));
            matched=expected==="interactive"?(document.readyState==="interactive"||document.readyState==="complete"):document.readyState===expected;
          }
          return JSON.stringify({ok:!errorCode,matched:matched,error_code:errorCode,ready_state:document.readyState||"unknown",url:cleanUrl(location.href),document_id:bridge.documentId,page_revision:bridge.revision,snapshot_id:bridge.snapshotId()});
        })();
        """
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

enum IOSWebMountControlOwner: String, Codable, Equatable {
    case none
    case agent
    case user
}

struct IOSWebMountSessionRecord: Equatable, Identifiable {
    let id: String
    let siteId: String?
    let siteName: String?
    let title: String
    let redactedURL: String
    let status: String
    let canGoBack: Bool
    let canGoForward: Bool
    let lastActivityMillis: Int64
    let isCurrent: Bool
    let ownerConversationId: String?
    let ownerRunId: String?
    let controlOwner: IOSWebMountControlOwner
    let leaseExpiresAtMillis: Int64?
    let persistentOptIn: Bool
    let needsReopen: Bool
    let backend: IOSWebMountBackendKind
    let mcpServerName: String?

    func dictionary() -> [String: Any] {
        [
            "session_id": id,
            "site_id": siteId ?? "",
            "site_name": siteName ?? "",
            "title": title,
            "url": redactedURL,
            "status": status,
            "can_go_back": canGoBack,
            "can_go_forward": canGoForward,
            "last_activity_ms": lastActivityMillis,
            "is_current": isCurrent,
            "control_owner": controlOwner.rawValue,
            "lease_expires_at_ms": leaseExpiresAtMillis ?? 0,
            "persistent": persistentOptIn,
            "needs_reopen": needsReopen,
            "backend": backend.rawValue,
            "mcp_server_name": mcpServerName ?? ""
        ]
    }
}

enum IOSWebMountSessionError: Error, LocalizedError {
    case sessionNotFound(String)
    case cannotCloseOnlySession
    case sessionLimitReached(Int)
    case sessionBindingRequired
    case sessionBindingMismatch(String)
    case siteBindingRequired
    case siteDisabled(String)
    case userControlActive(String)
    case agentLeaseUnavailable(String)

    var errorCode: String {
        switch self {
        case .sessionNotFound: "session_not_found"
        case .cannotCloseOnlySession: "cannot_close_only_session"
        case .sessionLimitReached: "session_limit_reached"
        case .sessionBindingRequired: "session_binding_required"
        case .sessionBindingMismatch: "session_binding_mismatch"
        case .siteBindingRequired: "site_binding_required"
        case .siteDisabled: "site_disabled"
        case .userControlActive: "user_control_active"
        case .agentLeaseUnavailable: "control_lease_unavailable"
        }
    }

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionId):
            "WebMount session was not found: \(sessionId)"
        case .cannotCloseOnlySession:
            "Cannot close the only WebMount session."
        case .sessionLimitReached(let limit):
            "WebMount already has \(limit) active or persistent sessions. Close one before creating another."
        case .sessionBindingRequired:
            "Agent WebMount calls require an explicit session_id and host run binding."
        case .sessionBindingMismatch(let sessionId):
            "WebMount session belongs to another conversation: \(sessionId)"
        case .siteBindingRequired:
            "WebMount session is no longer bound to a registered station."
        case .siteDisabled(let siteId):
            "WebMount station is disabled: \(siteId)"
        case .userControlActive(let sessionId):
            "The user currently controls WebMount session \(sessionId). Wait for hand-back before continuing."
        case .agentLeaseUnavailable(let sessionId):
            "WebMount agent control is unavailable for session \(sessionId)."
        }
    }
}

private struct IOSWebMountSessionMetadata: Codable, Equatable {
    var siteId: String?
    var siteName: String?
    var lastTitle: String?
    var redactedURL: String?
    var lastActivityMillis: Int64
    var ownerConversationId: String?
    var ownerRunId: String?
    var controlOwner: IOSWebMountControlOwner
    var leaseExpiresAtMillis: Int64?
    var persistentOptIn: Bool
    var needsReopen: Bool
    /// Optional for backward-compatible decoding of the existing v1 payload.
    var backendRawValue: String?
    var mcpServerName: String?

    private enum CodingKeys: String, CodingKey {
        case siteId
        case siteName
        case lastTitle
        case redactedURL
        case lastActivityMillis
        case ownerConversationId
        case ownerRunId
        case controlOwner
        case leaseExpiresAtMillis
        case persistentOptIn
        case needsReopen
        case backendRawValue
        case mcpServerName
    }

    init(
        siteId: String?,
        siteName: String?,
        lastTitle: String?,
        redactedURL: String?,
        lastActivityMillis: Int64,
        ownerConversationId: String?,
        ownerRunId: String?,
        controlOwner: IOSWebMountControlOwner,
        leaseExpiresAtMillis: Int64?,
        persistentOptIn: Bool,
        needsReopen: Bool,
        backendRawValue: String?,
        mcpServerName: String?
    ) {
        self.siteId = siteId
        self.siteName = siteName
        self.lastTitle = lastTitle
        self.redactedURL = redactedURL
        self.lastActivityMillis = lastActivityMillis
        self.ownerConversationId = ownerConversationId
        self.ownerRunId = ownerRunId
        self.controlOwner = controlOwner
        self.leaseExpiresAtMillis = leaseExpiresAtMillis
        self.persistentOptIn = persistentOptIn
        self.needsReopen = needsReopen
        self.backendRawValue = backendRawValue
        self.mcpServerName = mcpServerName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteId = try container.decodeIfPresent(String.self, forKey: .siteId)
        siteName = try container.decodeIfPresent(String.self, forKey: .siteName)
        lastTitle = try container.decodeIfPresent(String.self, forKey: .lastTitle)
        redactedURL = try container.decodeIfPresent(String.self, forKey: .redactedURL)
        lastActivityMillis = try container.decodeIfPresent(Int64.self, forKey: .lastActivityMillis) ?? 0
        ownerConversationId = try container.decodeIfPresent(String.self, forKey: .ownerConversationId)
        ownerRunId = try container.decodeIfPresent(String.self, forKey: .ownerRunId)
        controlOwner = try container.decodeIfPresent(IOSWebMountControlOwner.self, forKey: .controlOwner) ?? .none
        leaseExpiresAtMillis = try container.decodeIfPresent(Int64.self, forKey: .leaseExpiresAtMillis)
        // Entries in this store were explicitly persisted by the old v1 path;
        // restore still marks them needs_reopen before exposing a runtime.
        persistentOptIn = try container.decodeIfPresent(Bool.self, forKey: .persistentOptIn) ?? true
        needsReopen = try container.decodeIfPresent(Bool.self, forKey: .needsReopen) ?? true
        backendRawValue = try container.decodeIfPresent(String.self, forKey: .backendRawValue)
        mcpServerName = try container.decodeIfPresent(String.self, forKey: .mcpServerName)
    }

    var backend: IOSWebMountBackendKind {
        IOSWebMountBackendKind(rawValue: backendRawValue ?? "") ?? .local
    }
}

private struct IOSWebMountPersistedSession: Codable, Equatable {
    let id: String
    let metadata: IOSWebMountSessionMetadata
}

@MainActor
@Observable
final class IOSWebMountSessionStore {
    static let ephemeralTTLMillis: Int64 = 15 * 60 * 1_000
    static let agentLeaseMillis: Int64 = 2 * 60 * 1_000

    let maxSessions: Int

    private(set) var currentSessionId: String
    private(set) var recordsRevision: UInt64 = 0
    @ObservationIgnored private var runtimes: [String: IOSWebMountRuntimeServicing] = [:]
    @ObservationIgnored private var metadata: [String: IOSWebMountSessionMetadata] = [:]
    @ObservationIgnored private let runtimeFactory: () -> IOSWebMountRuntimeServicing
    @ObservationIgnored private let restoredRuntimeFactory: ((String) -> IOSWebMountRuntimeServicing)?
    @ObservationIgnored private let remoteRuntimeFactory: ((String, IOSWebMountBackendKind) -> IOSWebMountRuntimeServicing)?
    @ObservationIgnored private let userDefaults: UserDefaults?
    @ObservationIgnored private let nowMillis: () -> Int64
    @ObservationIgnored private let onSessionRemoved: ((String) -> Void)?

    private static let persistedSessionsKey = "app.amber.ios.webmount.persistent-sessions.v1"
    private static let persistedCurrentSessionKey = "app.amber.ios.webmount.persistent-current-session.v1"

    init(
        initialRuntime: IOSWebMountRuntimeServicing? = nil,
        maxSessions: Int = 3,
        runtimeFactory: @escaping () -> IOSWebMountRuntimeServicing = { IOSWebMountWKRuntime() },
        restoredRuntimeFactory: ((String) -> IOSWebMountRuntimeServicing)? = nil,
        remoteRuntimeFactory: ((String, IOSWebMountBackendKind) -> IOSWebMountRuntimeServicing)? = nil,
        userDefaults: UserDefaults? = nil,
        nowMillis: @escaping () -> Int64 = { IOSWebMountClock.nowMillis() },
        onSessionRemoved: ((String) -> Void)? = nil
    ) {
        self.maxSessions = max(1, maxSessions)
        self.runtimeFactory = runtimeFactory
        self.restoredRuntimeFactory = restoredRuntimeFactory
        self.remoteRuntimeFactory = remoteRuntimeFactory
        self.userDefaults = userDefaults
        self.nowMillis = nowMillis
        self.onSessionRemoved = onSessionRemoved
        self.currentSessionId = ""

        let persisted = Self.loadPersistedSessions(from: userDefaults)
            .filter { $0.metadata.persistentOptIn }
        // Reserve one slot for a local session. A persisted remote session must
        // never crowd the only local WKWebView out of the restored set.
        var restored: [IOSWebMountPersistedSession] = []
        if let local = persisted.first(where: { $0.metadata.backend == .local }) {
            restored.append(local)
        }
        let remoteLimit = max(0, self.maxSessions - max(1, restored.count))
        restored.append(contentsOf: persisted.filter { item in
            item.metadata.backend != .local && !restored.contains(where: { $0.id == item.id })
        }.prefix(remoteLimit))
        for item in restored {
            let backend = item.metadata.backend
            let restoredRuntime: IOSWebMountRuntimeServicing?
            if backend == .local {
                restoredRuntime = restoredRuntimeFactory?(item.id)
            } else {
                restoredRuntime = remoteRuntimeFactory?(item.id, backend)
            }
            guard let restoredRuntime else { continue }
            runtimes[item.id] = restoredRuntime
            var restoredMetadata = item.metadata
            restoredMetadata.ownerRunId = nil
            restoredMetadata.controlOwner = .none
            restoredMetadata.leaseExpiresAtMillis = nil
            restoredMetadata.needsReopen = true
            metadata[item.id] = restoredMetadata
        }

        if !metadata.values.contains(where: { $0.backend == .local }) {
            let runtime = initialRuntime ?? runtimeFactory()
            let sessionId = runtime.snapshot.sessionId
            runtimes[sessionId] = runtime
            metadata[sessionId] = Self.freshMetadata(nowMillis: nowMillis())
        }

        let persistedCurrent = userDefaults?.string(forKey: Self.persistedCurrentSessionKey)
        self.currentSessionId = persistedCurrent.flatMap { sessionId in
            guard runtimes[sessionId] != nil, metadata[sessionId]?.backend == .local else { return nil }
            return sessionId
        } ?? metadata.keys.sorted().first(where: { metadata[$0]?.backend == .local }) ?? ""
        ensureCurrentSessionIsLocal()
    }

    var currentRuntime: IOSWebMountRuntimeServicing {
        ensureCurrentSessionIsLocal()
        if let runtime = runtimes[currentSessionId] {
            return runtime
        }
        let runtime = runtimeFactory()
        let sessionId = runtime.snapshot.sessionId
        runtimes[sessionId] = runtime
        currentSessionId = sessionId
        metadata[sessionId] = Self.freshMetadata(nowMillis: nowMillis())
        return runtime
    }

    var records: [IOSWebMountSessionRecord] {
        _ = recordsRevision
        expireInactiveSessions()
        normalizeExpiredAgentLeases()
        ensureCurrentSessionIsLocal()
        return runtimes.keys
            .sorted { lhs, rhs in
                if lhs == currentSessionId { return true }
                if rhs == currentSessionId { return false }
                return (metadata[lhs]?.lastActivityMillis ?? 0) > (metadata[rhs]?.lastActivityMillis ?? 0)
            }
            .compactMap { sessionId -> IOSWebMountSessionRecord? in
                guard let runtime = runtimes[sessionId], let metadata = metadata[sessionId] else { return nil }
                let snapshot = runtime.snapshot
                return IOSWebMountSessionRecord(
                    id: sessionId,
                    siteId: metadata.siteId,
                    siteName: metadata.siteName,
                    title: IOSWebMountRedactor.redactedText(snapshot.title?.nilIfBlank ?? metadata.lastTitle?.nilIfBlank ?? "未命名页面"),
                    redactedURL: snapshot.currentURL ?? snapshot.requestedURL ?? metadata.redactedURL ?? "",
                    status: metadata.needsReopen ? "needs_reopen" : snapshot.status.rawValue,
                    canGoBack: snapshot.canGoBack,
                    canGoForward: snapshot.canGoForward,
                    lastActivityMillis: metadata.lastActivityMillis,
                    isCurrent: sessionId == currentSessionId,
                    ownerConversationId: metadata.ownerConversationId,
                    ownerRunId: metadata.ownerRunId,
                    controlOwner: effectiveControlOwner(metadata, now: nowMillis()),
                    leaseExpiresAtMillis: metadata.leaseExpiresAtMillis,
                    persistentOptIn: metadata.persistentOptIn,
                    needsReopen: metadata.needsReopen,
                    backend: metadata.backend,
                    mcpServerName: metadata.mcpServerName
                )
            }
    }

    func runtime(sessionId requestedSessionId: String?, makeCurrent: Bool = true) throws -> IOSWebMountRuntimeServicing {
        normalizeExpiredAgentLeases()
        ensureCurrentSessionIsLocal()
        let sessionId = requestedSessionId?.nilIfBlank ?? currentSessionId
        guard let runtime = runtimes[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        touch(sessionId: sessionId, makeCurrent: makeCurrent)
        return runtime
    }

    func runtimeIfPresent(sessionId requestedSessionId: String?) -> IOSWebMountRuntimeServicing? {
        expireInactiveSessions()
        ensureCurrentSessionIsLocal()
        let sessionId = requestedSessionId?.nilIfBlank ?? currentSessionId
        return runtimes[sessionId]
    }

    @discardableResult
    func newSession(
        site: IOSWebMountSite? = nil,
        persistent: Bool = false,
        makeCurrent: Bool = true,
        backend: IOSWebMountBackendKind = .local,
        mcpServerName: String? = nil,
        runtime suppliedRuntime: IOSWebMountRuntimeServicing? = nil
    ) throws -> IOSWebMountSessionRecord {
        expireInactiveSessions()
        if runtimes.count >= maxSessions {
            guard evictLeastRecentlyUsedSession(allowCurrent: makeCurrent) else {
                throw IOSWebMountSessionError.sessionLimitReached(maxSessions)
            }
        }
        let runtime = suppliedRuntime ?? runtimeFactory()
        let sessionId = runtime.snapshot.sessionId
        runtimes[sessionId] = runtime
        if makeCurrent && backend == .local {
            currentSessionId = sessionId
        }
        var newMetadata = Self.freshMetadata(nowMillis: nowMillis())
        newMetadata.persistentOptIn = persistent
        newMetadata.backendRawValue = backend.rawValue
        newMetadata.mcpServerName = mcpServerName?.nilIfBlank
        newMetadata.needsReopen = backend != .local
        metadata[sessionId] = newMetadata
        tag(sessionId: sessionId, site: site)
        ensureCurrentSessionIsLocal()
        persistSessions()
        return records.first { $0.id == sessionId } ?? fallbackRecord(for: runtime, sessionId: sessionId)
    }

    @discardableResult
    func close(sessionId: String) throws -> IOSWebMountSessionRecord? {
        ensureCurrentSessionIsLocal()
        guard runtimes[sessionId] != nil else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        if runtimes.count == 1 {
            removeSession(sessionId)
            expireInactiveSessions()
            persistSessions()
            return record(sessionId: currentSessionId)
        }
        removeSession(sessionId)
        if !metadata.values.contains(where: { $0.backend == .local }) {
            _ = try newSession(makeCurrent: true)
        }
        if currentSessionId == sessionId {
            currentSessionId = runtimes.keys.filter { metadata[$0]?.backend == .local }.max {
                (metadata[$0]?.lastActivityMillis ?? 0) < (metadata[$1]?.lastActivityMillis ?? 0)
            } ?? runtimes.keys.first ?? currentSessionId
        }
        ensureCurrentSessionIsLocal()
        persistSessions()
        return records.first { $0.id == currentSessionId }
    }

    func tag(sessionId: String, site: IOSWebMountSite?) {
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else { return }
        item.siteId = site?.id
        item.siteName = site?.displayName
        metadata[sessionId] = item
        persistSessions()
    }

    func touch(sessionId: String, makeCurrent: Bool = true) {
        normalizeExpiredAgentLeases()
        ensureCurrentSessionIsLocal()
        guard let runtime = runtimes[sessionId], var item = metadata[sessionId] else { return }
        if makeCurrent, item.backend == .local {
            currentSessionId = sessionId
        }
        let snapshot = runtime.snapshot
        item.lastActivityMillis = nowMillis()
        item.lastTitle = IOSWebMountRedactor.redactedText(snapshot.title ?? "").nilIfBlank ?? item.lastTitle
        if item.backend == .local {
            item.redactedURL = snapshot.currentURL ?? snapshot.requestedURL ?? item.redactedURL
        }
        metadata[sessionId] = item
        ensureCurrentSessionIsLocal()
        persistSessions()
    }

    @discardableResult
    func acquireAgentControl(
        sessionId: String,
        runId: String,
        conversationId: String
    ) throws -> IOSWebMountSessionRecord {
        try bindAgentSession(
            sessionId: sessionId,
            runId: runId,
            conversationId: conversationId,
            requiresControl: true
        )
    }

    @discardableResult
    func bindAgentSession(
        sessionId: String,
        runId: String,
        conversationId: String,
        requiresControl: Bool
    ) throws -> IOSWebMountSessionRecord {
        normalizeExpiredAgentLease(sessionId: sessionId)
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        guard runId.nilIfBlank != nil, conversationId.nilIfBlank != nil else {
            throw IOSWebMountSessionError.sessionBindingRequired
        }
        if let ownerConversationId = item.ownerConversationId,
           ownerConversationId != conversationId {
            throw IOSWebMountSessionError.sessionBindingMismatch(sessionId)
        }
        if let ownerRunId = item.ownerRunId,
           ownerRunId != runId {
            throw IOSWebMountSessionError.sessionBindingMismatch(sessionId)
        }
        let now = nowMillis()
        let effectiveOwner = effectiveControlOwner(item, now: now)
        if requiresControl, effectiveOwner == .user {
            throw IOSWebMountSessionError.userControlActive(sessionId)
        }
        item.ownerConversationId = conversationId.nilIfBlank ?? item.ownerConversationId
        item.ownerRunId = runId
        if requiresControl || effectiveOwner == .agent {
            item.controlOwner = .agent
            item.leaseExpiresAtMillis = now + Self.agentLeaseMillis
        }
        item.lastActivityMillis = now
        metadata[sessionId] = item
        persistSessions()
        return record(sessionId: sessionId)!
    }

    @discardableResult
    func acquireUserControl(sessionId: String) throws -> IOSWebMountSessionRecord {
        normalizeExpiredAgentLease(sessionId: sessionId)
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        let now = nowMillis()
        item.controlOwner = .user
        item.leaseExpiresAtMillis = nil
        item.lastActivityMillis = now
        metadata[sessionId] = item
        if item.backend == .local {
            currentSessionId = sessionId
        }
        ensureCurrentSessionIsLocal()
        persistSessions()
        return record(sessionId: sessionId)!
    }

    @discardableResult
    func handBackToAgent(sessionId: String) throws -> IOSWebMountSessionRecord {
        normalizeExpiredAgentLease(sessionId: sessionId)
        guard runtimes[sessionId] != nil, var item = metadata[sessionId] else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        guard item.ownerRunId?.nilIfBlank != nil else {
            item.controlOwner = .none
            item.leaseExpiresAtMillis = nil
            metadata[sessionId] = item
            persistSessions()
            return record(sessionId: sessionId)!
        }
        item.controlOwner = .agent
        item.leaseExpiresAtMillis = nowMillis() + Self.agentLeaseMillis
        metadata[sessionId] = item
        persistSessions()
        return record(sessionId: sessionId)!
    }

    func releaseAgentOwnership(runId: String) {
        guard !runId.isEmpty else { return }
        var changed = false
        for sessionId in metadata.keys where metadata[sessionId]?.ownerRunId == runId {
            guard var item = metadata[sessionId] else { continue }
            item.ownerRunId = nil
            if item.controlOwner == .agent {
                item.controlOwner = .none
                item.leaseExpiresAtMillis = nil
            }
            metadata[sessionId] = item
            changed = true
        }
        if changed {
            persistSessions()
        }
    }

    func expireInactiveSessions(nowMillis explicitNow: Int64? = nil) {
        let now = explicitNow ?? nowMillis()
        normalizeExpiredAgentLeases(now: now)
        let expired = metadata.compactMap { sessionId, item -> String? in
            guard !item.persistentOptIn,
                  effectiveControlOwner(item, now: now) != .user,
                  now - item.lastActivityMillis >= Self.ephemeralTTLMillis else { return nil }
            return sessionId
        }
        for sessionId in expired {
            removeSession(sessionId)
        }
        if !metadata.values.contains(where: { $0.backend == .local }) {
            let runtime = runtimeFactory()
            let sessionId = runtime.snapshot.sessionId
            runtimes[sessionId] = runtime
            metadata[sessionId] = Self.freshMetadata(nowMillis: now)
            currentSessionId = sessionId
        }
        ensureCurrentSessionIsLocal()
        if !expired.isEmpty {
            persistSessions()
        }
    }

    func record(sessionId: String) -> IOSWebMountSessionRecord? {
        records.first { $0.id == sessionId }
    }

    private func evictLeastRecentlyUsedSession(allowCurrent: Bool) -> Bool {
        ensureCurrentSessionIsLocal()
        let now = nowMillis()
        let localSessionIds = Set(metadata.compactMap { sessionId, item in
            item.backend == .local && runtimes[sessionId] != nil ? sessionId : nil
        })
        let candidate = runtimes.keys
            .filter { sessionId in
                guard let item = metadata[sessionId],
                      !item.persistentOptIn,
                      effectiveControlOwner(item, now: now) == .none else { return false }
                if item.backend == .local, localSessionIds.count <= 1 { return false }
                return allowCurrent || sessionId != currentSessionId
            }
            .min { lhs, rhs in
                if lhs == currentSessionId { return false }
                if rhs == currentSessionId { return true }
                return (metadata[lhs]?.lastActivityMillis ?? 0) < (metadata[rhs]?.lastActivityMillis ?? 0)
            }
        guard let candidate else { return false }
        removeSession(candidate)
        if currentSessionId == candidate {
            currentSessionId = runtimes.keys.first(where: { metadata[$0]?.backend == .local }) ?? ""
        }
        ensureCurrentSessionIsLocal()
        persistSessions()
        return true
    }

    private func fallbackRecord(for runtime: IOSWebMountRuntimeServicing, sessionId: String) -> IOSWebMountSessionRecord {
        let snapshot = runtime.snapshot
        return IOSWebMountSessionRecord(
            id: sessionId,
            siteId: metadata[sessionId]?.siteId,
            siteName: metadata[sessionId]?.siteName,
            title: IOSWebMountRedactor.redactedText(snapshot.title?.nilIfBlank ?? "Untitled"),
            redactedURL: snapshot.currentURL ?? snapshot.requestedURL ?? "",
            status: snapshot.status.rawValue,
            canGoBack: snapshot.canGoBack,
            canGoForward: snapshot.canGoForward,
            lastActivityMillis: metadata[sessionId]?.lastActivityMillis ?? snapshot.updatedAtMillis,
            isCurrent: sessionId == currentSessionId,
            ownerConversationId: metadata[sessionId]?.ownerConversationId,
            ownerRunId: metadata[sessionId]?.ownerRunId,
            controlOwner: metadata[sessionId]?.controlOwner ?? .none,
            leaseExpiresAtMillis: metadata[sessionId]?.leaseExpiresAtMillis,
            persistentOptIn: metadata[sessionId]?.persistentOptIn ?? false,
            needsReopen: metadata[sessionId]?.needsReopen ?? false,
            backend: metadata[sessionId]?.backend ?? .local,
            mcpServerName: metadata[sessionId]?.mcpServerName
        )
    }

    private func removeSession(_ sessionId: String) {
        guard runtimes.removeValue(forKey: sessionId) != nil else { return }
        metadata.removeValue(forKey: sessionId)
        onSessionRemoved?(sessionId)
    }

    func markNeedsReopen(sessionId: String) {
        guard var item = metadata[sessionId], runtimes[sessionId] != nil else { return }
        guard !item.needsReopen else { return }
        item.needsReopen = true
        metadata[sessionId] = item
        persistSessions()
    }

    func recordValidatedRemoteURL(
        sessionId: String,
        rawURL: String,
        clearNeedsReopen: Bool
    ) {
        guard var item = metadata[sessionId], runtimes[sessionId] != nil,
              let redactedURL = IOSWebMountRedactor.redactedURL(rawURL) else { return }
        item.redactedURL = redactedURL
        item.lastActivityMillis = nowMillis()
        if clearNeedsReopen {
            item.needsReopen = false
        }
        metadata[sessionId] = item
        persistSessions()
    }

    func clearNeedsReopen(sessionId: String) {
        guard var item = metadata[sessionId], runtimes[sessionId] != nil else { return }
        guard item.needsReopen else { return }
        item.needsReopen = false
        metadata[sessionId] = item
        persistSessions()
    }

    private func normalizeExpiredAgentLease(sessionId: String) {
        guard var item = metadata[sessionId],
              item.controlOwner == .agent || item.ownerRunId?.nilIfBlank != nil else { return }
        guard let leaseExpiresAtMillis = item.leaseExpiresAtMillis,
              leaseExpiresAtMillis <= nowMillis() else { return }
        item.controlOwner = .none
        item.leaseExpiresAtMillis = nil
        metadata[sessionId] = item
        persistSessions()
    }

    private func normalizeExpiredAgentLeases(now: Int64? = nil) {
        let now = now ?? nowMillis()
        var changed = false
        for sessionId in metadata.keys {
            guard var item = metadata[sessionId],
                  item.controlOwner == .agent || item.ownerRunId?.nilIfBlank != nil,
                  let leaseExpiresAtMillis = item.leaseExpiresAtMillis,
                  leaseExpiresAtMillis <= now else { continue }
            item.controlOwner = .none
            item.leaseExpiresAtMillis = nil
            metadata[sessionId] = item
            changed = true
        }
        if changed {
            persistSessions()
        }
    }

    private func ensureCurrentSessionIsLocal() {
        if let item = metadata[currentSessionId],
           item.backend == .local,
           runtimes[currentSessionId] != nil {
            return
        }
        if let localSessionId = runtimes.keys.first(where: { metadata[$0]?.backend == .local }) {
            currentSessionId = localSessionId
            return
        }
        let runtime = runtimeFactory()
        let sessionId = runtime.snapshot.sessionId
        runtimes[sessionId] = runtime
        metadata[sessionId] = Self.freshMetadata(nowMillis: nowMillis())
        currentSessionId = sessionId
    }

    private func effectiveControlOwner(_ item: IOSWebMountSessionMetadata, now: Int64) -> IOSWebMountControlOwner {
        if item.controlOwner == .user {
            return .user
        }
        guard let leaseExpiresAtMillis = item.leaseExpiresAtMillis,
              leaseExpiresAtMillis > now else {
            return .none
        }
        return item.controlOwner
    }

    private func persistSessions() {
        recordsRevision &+= 1
        guard let userDefaults else { return }
        let persisted = metadata
            .filter { $0.value.persistentOptIn }
            .map { IOSWebMountPersistedSession(id: $0.key, metadata: $0.value) }
            .sorted { $0.id < $1.id }
        if persisted.isEmpty {
            userDefaults.removeObject(forKey: Self.persistedSessionsKey)
            userDefaults.removeObject(forKey: Self.persistedCurrentSessionKey)
            return
        }
        if let data = try? JSONEncoder().encode(persisted) {
            userDefaults.set(data, forKey: Self.persistedSessionsKey)
            let persistedCurrent = persisted.first(where: { $0.id == currentSessionId && $0.metadata.backend == .local })?.id
                ?? persisted.first(where: { $0.metadata.backend == .local })?.id
            if let persistedCurrent {
                userDefaults.set(persistedCurrent, forKey: Self.persistedCurrentSessionKey)
            } else {
                userDefaults.removeObject(forKey: Self.persistedCurrentSessionKey)
            }
        }
    }

    private static func loadPersistedSessions(from userDefaults: UserDefaults?) -> [IOSWebMountPersistedSession] {
        guard let data = userDefaults?.data(forKey: persistedSessionsKey),
              let sessions = try? JSONDecoder().decode([IOSWebMountPersistedSession].self, from: data) else {
            return []
        }
        return sessions
    }

    private static func freshMetadata(nowMillis: Int64) -> IOSWebMountSessionMetadata {
        IOSWebMountSessionMetadata(
            siteId: nil,
            siteName: nil,
            lastTitle: nil,
            redactedURL: nil,
            lastActivityMillis: nowMillis,
            ownerConversationId: nil,
            ownerRunId: nil,
            controlOwner: .none,
            leaseExpiresAtMillis: nil,
            persistentOptIn: false,
            needsReopen: false,
            backendRawValue: IOSWebMountBackendKind.local.rawValue,
            mcpServerName: nil
        )
    }
}

enum IOSWebMountScreenshotArtifactStore {
    static let retentionMillis: Int64 = 24 * 60 * 60 * 1_000

    static func save(
        _ capture: IOSWebMountScreenshotCapture,
        sessionId: String,
        rootDirectory: URL? = nil,
        nowMillis: Int64 = IOSWebMountClock.nowMillis()
    ) throws -> [String: Any] {
        let fileManager = FileManager.default
        let directory = screenshotsDirectory(rootDirectory: rootDirectory)
        try prepareDirectory(directory, fileManager: fileManager)
        cleanupExpired(rootDirectory: rootDirectory, nowMillis: nowMillis)
        let safeSessionId = safePathComponent(sessionId)
        let artifactId = "wmshot-\(nowMillis)-\(safeSessionId)"
        let fileName = "\(artifactId).\(capture.format)"
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try capture.data.write(to: destination, options: [.atomic])
        return [
            "artifact_id": artifactId,
            "local_ref": "Workspace/WebMount/screenshots/\(fileName)",
            "format": capture.format,
            "width": capture.width,
            "height": capture.height,
            "size_bytes": capture.data.count,
            "created_at_ms": nowMillis,
            "expires_at_ms": nowMillis + retentionMillis,
            "retention_hours": 24,
            "contains_unredacted_viewport": true
        ]
    }

    static func cleanupExpired(
        rootDirectory: URL? = nil,
        nowMillis: Int64 = IOSWebMountClock.nowMillis()
    ) {
        let fileManager = FileManager.default
        let directory = screenshotsDirectory(rootDirectory: rootDirectory)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "png" {
            let createdMillis = timestamp(from: file.lastPathComponent)
                ?? Int64(((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000)
            if createdMillis > 0, nowMillis - createdMillis >= retentionMillis {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    static func deleteArtifacts(sessionId: String, rootDirectory: URL? = nil) {
        let fileManager = FileManager.default
        let directory = screenshotsDirectory(rootDirectory: rootDirectory)
        let suffix = "-\(safePathComponent(sessionId)).png"
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.lastPathComponent.hasSuffix(suffix) {
            try? fileManager.removeItem(at: file)
        }
    }

    private static func screenshotsDirectory(rootDirectory: URL?) -> URL {
        let root = rootDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("AmberWorkspace", isDirectory: true)
            .appendingPathComponent("WebMount", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
    }

    private static func timestamp(from fileName: String) -> Int64? {
        guard fileName.hasPrefix("wmshot-") else { return nil }
        let suffix = fileName.dropFirst("wmshot-".count)
        guard let separator = suffix.firstIndex(of: "-") else { return nil }
        return Int64(suffix[..<separator])
    }

    private static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character("_") }
        return String(value).nilIfBlank ?? "session"
    }
}

struct IOSWebMountToolDescriptor: Equatable, Identifiable {
    let name: String
    let description: String
    let requiresUserAction: Bool

    var id: String { name }
}

enum IOSWebMountToolCatalog {
    static let descriptors: [IOSWebMountToolDescriptor] = [
        .init(name: "wm_stations", description: "List configured WebMount stations without exposing cookie values.", requiresUserAction: false),
        .init(name: "wm_tab_list", description: "List up to three foreground iOS WebMount sessions.", requiresUserAction: false),
        .init(name: "wm_tab_new", description: "Create a new foreground iOS WebMount session, bounded to three sessions.", requiresUserAction: false),
        .init(name: "wm_tab_close", description: "Close one foreground iOS WebMount session by session_id.", requiresUserAction: false),
        .init(name: "wm_open", description: "Open a URL in a local WKWebView session. Unlisted public hosts require high-risk auto-approve.", requiresUserAction: false),
        .init(name: "wm_state", description: "Read current WKWebView status, title, redacted URL, and page state.", requiresUserAction: false),
        .init(name: "wm_observe", description: "Read state, visible text, links, interactive elements, and visual candidates without cookies or headers.", requiresUserAction: false),
        .init(name: "wm_extract", description: "Extract readable or interactive page content through a read-only bridge.", requiresUserAction: false),
        .init(name: "wm_get", description: "Read a visible element's text, checked value, or non-sensitive attribute through a restricted bridge. Raw HTML reads are disabled on iOS.", requiresUserAction: false),
        .init(name: "wm_visual_snapshot", description: "Return viewport visual candidates from DOM rectangles without calling an external vision model.", requiresUserAction: false),
        .init(name: "wm_screenshot", description: "Capture the current viewport to a local WebMount artifact after foreground approval.", requiresUserAction: true),
        .init(name: "wm_back", description: "Navigate the current WebMount session backward.", requiresUserAction: false),
        .init(name: "wm_forward", description: "Navigate the current WebMount session forward.", requiresUserAction: false),
        .init(name: "wm_clear_session", description: "Clear cookies and website data for one station after explicit user action.", requiresUserAction: true),
        .init(name: "wm_site_add", description: "Add an iOS WebMount station and sync the URL allowlist after foreground approval.", requiresUserAction: true),
        .init(name: "wm_site_remove", description: "Remove an iOS WebMount station and sync the URL allowlist after foreground approval. Cookies are not cleared.", requiresUserAction: true),
        .init(name: "wm_click", description: "Click an element by CSS selector on the current WebMount page.", requiresUserAction: false),
        .init(name: "wm_tap", description: "Tap a coordinate or target on the current WebMount page.", requiresUserAction: false),
        .init(name: "wm_type", description: "Type text into an input element by CSS selector.", requiresUserAction: false),
        .init(name: "wm_keys", description: "Send a short key sequence to the current WebMount page or focused field.", requiresUserAction: false),
        .init(name: "wm_scroll", description: "Scroll the page or an element into view.", requiresUserAction: false),
        .init(name: "wm_select", description: "Select an option value in a <select> element by CSS selector.", requiresUserAction: false),
        .init(name: "wm_find", description: "Read-only selector or visible-text search that returns stable element refs without input values.", requiresUserAction: false),
        .init(name: "wm_wait", description: "Wait up to 30 seconds for DOM stability, selector, visible text, URL fragment, ready state, or an explicit delay.", requiresUserAction: false)
    ]

    static let supportedToolNames = Set(descriptors.map(\.name))

    static let unsupportedToolNames: Set<String> = [
        "wm_eval",
        "wm_signed_fetch",
        "wm_network_inspect",
        "wm_fetch_replay",
        "wm_recipe_candidates",
        "wm_oauth_connect",
        "wm_oauth_refresh",
        "wm_profile_synthesize",
        "wm_site_adapter",
        "wm_visual_read"
    ]
}

@MainActor
final class IOSWebMountController {
    static let shared = IOSWebMountController(sessionDefaults: .standard)

    let registry: IOSWebMountRegistry
    let settings: IOSWebMountSettings
    let cookieStore: IOSWebMountCookieStoreProtocol
    let sessionStore: IOSWebMountSessionStore
    let desktopBackend: IOSWebMountDesktopBackendAdapter
    private let mcpServerProvider: () -> [IOSMcpServerConfig]
    private let resolveHost: IOSWebMountHostResolver

    var runtime: IOSWebMountRuntimeServicing {
        sessionStore.currentRuntime
    }

    var visibleRuntime: IOSWebMountWKRuntime? {
        runtime as? IOSWebMountWKRuntime
    }

    func releaseAgentOwnership(runId: String) {
        sessionStore.releaseAgentOwnership(runId: runId)
    }

    init(
        registry: IOSWebMountRegistry? = nil,
        settings: IOSWebMountSettings? = nil,
        cookieStore: IOSWebMountCookieStoreProtocol? = nil,
        runtime: IOSWebMountRuntimeServicing? = nil,
        runtimeFactory: (() -> IOSWebMountRuntimeServicing)? = nil,
        sessionDefaults: UserDefaults? = nil,
        sessionNowMillis: @escaping () -> Int64 = { IOSWebMountClock.nowMillis() },
        desktopBackend: IOSWebMountDesktopBackendAdapter? = nil,
        mcpServerProvider: @escaping () -> [IOSMcpServerConfig] = { IOSMcpConfigStore.shared.servers },
        resolveHost: @escaping IOSWebMountHostResolver = IOSSearchExecutor.resolveIPAddresses
    ) {
        self.registry = registry ?? IOSWebMountRegistry()
        self.settings = settings ?? IOSWebMountSettings()
        self.cookieStore = cookieStore ?? IOSWebMountCookieStore()
        let resolvedDesktopBackend = desktopBackend ?? IOSWebMountDesktopBackendAdapter()
        self.desktopBackend = resolvedDesktopBackend
        self.mcpServerProvider = mcpServerProvider
        self.resolveHost = resolveHost
        IOSWebMountScreenshotArtifactStore.cleanupExpired()
        let factory = runtimeFactory ?? { IOSWebMountWKRuntime() }
        let restoredFactory: ((String) -> IOSWebMountRuntimeServicing)? = runtimeFactory == nil
            ? { IOSWebMountWKRuntime(sessionId: $0) }
            : nil
        self.sessionStore = IOSWebMountSessionStore(
            initialRuntime: runtime,
            runtimeFactory: factory,
            restoredRuntimeFactory: restoredFactory,
            remoteRuntimeFactory: { sessionId, _ in
                IOSWebMountRemotePlaceholderRuntime(sessionId: sessionId)
            },
            userDefaults: sessionDefaults,
            nowMillis: sessionNowMillis,
            onSessionRemoved: { sessionId in
                resolvedDesktopBackend.close(logicalSessionId: sessionId)
                IOSWebMountScreenshotArtifactStore.deleteArtifacts(sessionId: sessionId)
            }
        )
        self.settings.syncAllowedHosts(self.registry.sites.flatMap(\.allowedHosts))
    }

    func openForUser(site: IOSWebMountSite, sessionId: String? = nil) async -> IOSWebMountRuntimeSnapshot {
        if let sessionId = sessionId?.nilIfBlank,
           let record = sessionStore.record(sessionId: sessionId),
           record.backend != .local {
            let current = sessionStore.runtimeIfPresent(sessionId: sessionId)?.snapshot
                ?? .idle(sessionId: sessionId)
            return IOSWebMountRuntimeSnapshot(
                sessionId: current.sessionId,
                status: .failed,
                requestedURL: IOSWebMountRedactor.redactedURL(site.homepageURL),
                currentURL: current.currentURL,
                title: current.title,
                estimatedProgress: current.estimatedProgress,
                canGoBack: current.canGoBack,
                canGoForward: current.canGoForward,
                error: "Desktop WebMount sessions cannot be opened through the local user WebMount view.",
                updatedAtMillis: IOSWebMountClock.nowMillis()
            )
        }
        let runtime = (try? sessionStore.runtime(sessionId: sessionId, makeCurrent: true))
            ?? sessionStore.currentRuntime
        _ = try? sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
        let policy = IOSWebMountURLPolicy(settings: settings, extraAllowedHosts: registry.sites.flatMap(\.allowedHosts))
        switch policy.validate(site.homepageURL, site: site) {
        case .success(let url):
            (runtime as? IOSWebMountWKRuntime)?.setNavigationPolicy(
                policy,
                site: site,
                resolveHost: resolveHost
            )
            sessionStore.tag(sessionId: runtime.snapshot.sessionId, site: site)
            let snapshot = await runtime.open(url, timeoutMillis: 30_000)
            if snapshot.status != .failed {
                sessionStore.clearNeedsReopen(sessionId: snapshot.sessionId)
            }
            sessionStore.touch(sessionId: snapshot.sessionId)
            return snapshot
        case .failure(let error):
            return IOSWebMountRuntimeSnapshot(
                sessionId: runtime.snapshot.sessionId,
                status: .failed,
                requestedURL: IOSWebMountRedactor.redactedURL(site.homepageURL),
                currentURL: runtime.snapshot.currentURL,
                title: runtime.snapshot.title,
                estimatedProgress: runtime.snapshot.estimatedProgress,
                canGoBack: runtime.snapshot.canGoBack,
                canGoForward: runtime.snapshot.canGoForward,
                error: error.localizedDescription,
                updatedAtMillis: IOSWebMountClock.nowMillis()
            )
        }
    }

    func execute(
        toolName: String,
        input: String,
        isUserInitiated: Bool,
        context: IOSWebMountExecutionContext? = nil,
        allowUnlistedHosts: Bool = false
    ) async -> String {
        guard IOSWebMountToolCatalog.supportedToolNames.contains(toolName) else {
            return Self.unsupportedToolResult(toolName: toolName)
        }
        if let context, !context.hasCompleteBinding {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "denied": true,
                "error_code": IOSWebMountSessionError.sessionBindingRequired.errorCode,
                "reason": "Agent WebMount calls require both conversation_id and run_id."
            ])
        }
        sessionStore.expireInactiveSessions()
        let args = Self.parseObject(input)
        if let limitFailure = Self.webMountInputLimitFailure(toolName: toolName, args: args) {
            return limitFailure
        }
        do {
            if !Self.desktopRoutingExemptToolNames.contains(toolName),
               let sessionId = (args["session_id"] as? String)?.nilIfBlank,
               let record = sessionStore.record(sessionId: sessionId),
               record.backend != .local {
                return try await desktopResult(
                    toolName: toolName,
                    args: args,
                    record: record,
                    isUserInitiated: isUserInitiated,
                    context: context,
                    allowUnlistedHosts: allowUnlistedHosts
                )
            }
            if let policyFailure = localSessionPolicyFailure(
                toolName: toolName,
                args: args,
                allowUnlistedHosts: allowUnlistedHosts
            ) {
                return policyFailure
            }
            switch toolName {
            case "wm_stations":
                return await stationsResult(args: args)
            case "wm_tab_list":
                return tabListResult()
            case "wm_tab_new":
                return try await tabNewResult(args: args, isUserInitiated: isUserInitiated, context: context)
            case "wm_tab_close":
                return try tabCloseResult(args: args, context: context)
            case "wm_open":
                return try await openResult(
                    args: args,
                    context: context,
                    allowUnlistedHosts: allowUnlistedHosts
                )
            case "wm_state":
                return try await stateResult(args: args, context: context)
            case "wm_observe":
                return try await observeResult(args: args, context: context)
            case "wm_extract":
                return try await extractResult(args: args, context: context)
            case "wm_get":
                return try await getResult(args: args, context: context)
            case "wm_visual_snapshot":
                return try await visualSnapshotResult(args: args, context: context)
            case "wm_screenshot":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Viewport screenshots require an explicit foreground user action"
                    ])
                }
                return try await screenshotResult(args: args, context: context)
            case "wm_back":
                let runtime = try sessionRuntime(from: args, context: context)
                let snapshot = await runtime.back()
                if agentOwnershipLost(sessionId: snapshot.sessionId, context: context) {
                    sessionStore.markNeedsReopen(sessionId: snapshot.sessionId)
                    touch(sessionId: snapshot.sessionId, context: context)
                    return Self.localNavigationOwnershipUnknown(
                        toolName: toolName,
                        sessionId: snapshot.sessionId
                    )
                }
                touch(sessionId: snapshot.sessionId, context: context)
                return Self.json([
                    "ok": true,
                    "session_id": snapshot.sessionId,
                    "state": snapshot.dictionary(redactURLs: true)
                ])
            case "wm_forward":
                let runtime = try sessionRuntime(from: args, context: context)
                let snapshot = await runtime.forward()
                if agentOwnershipLost(sessionId: snapshot.sessionId, context: context) {
                    sessionStore.markNeedsReopen(sessionId: snapshot.sessionId)
                    touch(sessionId: snapshot.sessionId, context: context)
                    return Self.localNavigationOwnershipUnknown(
                        toolName: toolName,
                        sessionId: snapshot.sessionId
                    )
                }
                touch(sessionId: snapshot.sessionId, context: context)
                return Self.json([
                    "ok": true,
                    "session_id": snapshot.sessionId,
                    "state": snapshot.dictionary(redactURLs: true)
                ])
            case "wm_clear_session":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Clearing WebMount cookies requires an explicit foreground user action"
                    ])
                }
                return try await clearSessionResult(args: args)
            case "wm_site_add":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Adding a WebMount station requires an explicit foreground user action"
                    ])
                }
                return try siteAddResult(args: args)
            case "wm_site_remove":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Removing a WebMount station requires an explicit foreground user action"
                    ])
                }
                return try siteRemoveResult(args: args)
            case "wm_click", "wm_type", "wm_scroll", "wm_select", "wm_find", "wm_wait", "wm_keys", "wm_tap":
                let method: String
                switch toolName {
                case "wm_click": method = "click"
                case "wm_tap": method = "tap"
                case "wm_type": method = "type"
                case "wm_keys": method = "keys"
                case "wm_scroll": method = "scroll"
                case "wm_select": method = "select"
                case "wm_find": method = "find"
                case "wm_wait": method = "wait"
                default: method = "click"
                }
                let mutating = method != "find" && method != "wait"
                let postcondition = mutating ? Self.webMountPostconditionOptions(from: args) : nil
                if mutating, args["postcondition"] != nil, postcondition == nil {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "denied": true,
                        "error_code": "invalid_postcondition",
                        "reason": "postcondition requires a supported condition and a value unless condition is dom_stable."
                    ])
                }
                if mutating,
                   context?.isAgentInvocation == true,
                   (args["snapshot_id"] as? String)?.nilIfBlank == nil {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "denied": true,
                        "error_code": "snapshot_required",
                        "reason": "Agent WebMount mutations require snapshot_id from the latest observation."
                    ])
                }
                if mutating, context?.isAgentInvocation == true {
                    let semanticTarget = (args["target"] as? String)?.nilIfBlank
                        ?? (args["selector"] as? String)?.nilIfBlank
                    let usesCoordinates = args["x"] != nil || args["y"] != nil
                    if usesCoordinates || (semanticTarget != nil && semanticTarget?.hasPrefix("wm:") != true) {
                        return Self.json([
                            "ok": false,
                            "tool": toolName,
                            "denied": true,
                            "error_code": "semantic_target_required",
                            "may_have_applied": false,
                            "reason": "Agent mutations must use a document-scoped target ref from the latest WebMount observation; CSS selectors and coordinates are reserved for direct user actions."
                        ])
                    }
                }
                let runtime = try sessionRuntime(
                    from: args,
                    context: context,
                    requiresControl: mutating
                )
                let selector = args["selector"] as? String ?? args["target"] as? String
                let text = args["text"] as? String ?? args["value"] as? String
                var options = args
                if options["dy"] == nil, let byY = args["by_y"] {
                    options["dy"] = byY
                }
                if options["wait_ms"] == nil, let timeout = args["timeout_ms"] {
                    options["wait_ms"] = timeout
                }
                options["_amber_allow_high_consequence"] = isUserInitiated
                options.removeValue(forKey: "_amber_preflight_only")
                var actionStarted = false
                do {
                    let before = try await runtime.state()
                    var preconditionResult: [String: Any]?
                    if mutating, let postcondition {
                        var probeOptions = postcondition
                        probeOptions["wait_ms"] = 100
                        probeOptions["_amber_postcondition_probe"] = true
                        preconditionResult = try await runtime.interact(
                            method: "wait",
                            selector: nil,
                            text: nil,
                            options: probeOptions
                        )
                    }
                    if mutating, let context, context.isAgentInvocation {
                        let record = sessionStore.record(sessionId: runtime.snapshot.sessionId)
                        guard record?.controlOwner == .agent,
                              record?.ownerRunId == context.runId else {
                            touch(sessionId: runtime.snapshot.sessionId, context: context)
                            return Self.json([
                                "ok": false,
                                "tool": toolName,
                                "session_id": runtime.snapshot.sessionId,
                                "status": "rejected",
                                "error_code": "control_unavailable",
                                "may_have_applied": false,
                                "verified": false,
                                "reason": "WebMount control changed before the action was dispatched."
                            ])
                        }
                    }
                    actionStarted = true
                    let result = try await runtime.interact(method: method, selector: selector, text: text, options: options)
                    if mutating, let context, context.isAgentInvocation {
                        let record = sessionStore.record(sessionId: runtime.snapshot.sessionId)
                        guard record?.controlOwner == .agent,
                              record?.ownerRunId == context.runId else {
                            touch(sessionId: runtime.snapshot.sessionId, context: context)
                            return Self.json([
                                "ok": false,
                                "tool": toolName,
                                "session_id": runtime.snapshot.sessionId,
                                "status": "unknown_after_action",
                                "error_code": "unknown_after_action",
                                "may_have_applied": true,
                                "verified": false,
                                "before_snapshot_id": before["snapshot_id"] as? String ?? "",
                                "reason": "WebMount control changed while the action was in flight.",
                                "action": IOSWebMountRedactor.redactedJSONObject(result)
                            ])
                        }
                    }
                    var postconditionResult: [String: Any]?
                    if mutating,
                       result["ok"] as? Bool == true,
                       let postcondition {
                        postconditionResult = try await runtime.interact(
                            method: "wait",
                            selector: nil,
                            text: nil,
                            options: postcondition
                        )
                    }
                    let after = try await runtime.state()
                    if mutating, let context, context.isAgentInvocation {
                        let record = sessionStore.record(sessionId: runtime.snapshot.sessionId)
                        guard record?.controlOwner == .agent,
                              record?.ownerRunId == context.runId else {
                            touch(sessionId: runtime.snapshot.sessionId, context: context)
                            return Self.json([
                                "ok": false,
                                "tool": toolName,
                                "session_id": runtime.snapshot.sessionId,
                                "status": "unknown_after_action",
                                "error_code": "unknown_after_action",
                                "may_have_applied": true,
                                "verified": false,
                                "before_snapshot_id": before["snapshot_id"] as? String ?? "",
                                "snapshot_id": after["snapshot_id"] as? String ?? "",
                                "reason": "WebMount control changed before the action outcome was verified.",
                                "action": IOSWebMountRedactor.redactedJSONObject(result),
                                "postcondition": IOSWebMountRedactor.redactedJSONObject(postconditionResult ?? [:])
                            ])
                        }
                    }
                    touch(sessionId: runtime.snapshot.sessionId, context: context)
                    if let gateOutput = interactionGateOutput(
                        toolName: toolName,
                        result: result,
                        sessionId: runtime.snapshot.sessionId,
                        snapshotId: after["snapshot_id"] as? String,
                        handoffToUser: context?.isAgentInvocation == true
                    ) {
                        return gateOutput
                    }
                    let succeeded = result["ok"] as? Bool ?? false
                    let diff = Self.webMountStateDiff(before: before, after: after)
                    let actionVerified = result["verified"] as? Bool == true
                    let preconditionMatched = preconditionResult?["matched"] as? Bool == true
                    let postconditionMatched = postconditionResult?["matched"] as? Bool == true
                    let dispatched = mutating && succeeded && (result["preflight_only"] as? Bool != true)
                    let verified: Bool
                    let verificationSource: String
                    if !mutating {
                        verified = (result["verified"] as? Bool)
                            ?? ((method == "find" && result["found"] as? Bool == true)
                                || (method == "wait" && result["matched"] as? Bool == true))
                        verificationSource = verified ? method : ""
                    } else if postcondition != nil {
                        verified = dispatched && postconditionMatched && !preconditionMatched
                        verificationSource = verified ? "postcondition" : ""
                    } else if actionVerified {
                        verified = true
                        verificationSource = "action"
                    } else {
                        verified = false
                        verificationSource = ""
                    }
                    let postconditionPreexisting = dispatched && postcondition != nil && preconditionMatched
                    let postconditionFailed = dispatched
                        && postcondition != nil
                        && (!postconditionMatched || postconditionPreexisting)
                    let mayHaveApplied = dispatched && !verified
                    let resultErrorCode = result["error_code"] as? String ?? ""
                    let errorCode: String
                    if postconditionPreexisting && succeeded {
                        errorCode = "postcondition_preexisting"
                    } else if postconditionFailed && succeeded {
                        errorCode = "postcondition_not_met"
                    } else {
                        errorCode = resultErrorCode
                    }
                    let responseSucceeded = succeeded && !postconditionFailed
                    let status: String
                    if postconditionFailed && succeeded {
                        status = "ambiguous"
                    } else if succeeded {
                        status = verified ? "verified" : (method == "find" ? "not_found" : "dispatched_unverified")
                    } else {
                        status = errorCode == "wait_timeout" ? "timed_out" : "rejected"
                    }
                    let outcome: String
                    if verified {
                        outcome = "verified"
                    } else if errorCode == "wait_timeout" {
                        outcome = "timed_out"
                    } else if succeeded {
                        outcome = method == "find" ? "not_found" : "ambiguous"
                    } else {
                        outcome = "rejected"
                    }
                    let receipt: [String: Any] = [
                        "outcome": outcome,
                        "dispatched": dispatched,
                        "verified": verified,
                        "verification_source": verificationSource,
                        "before_snapshot_id": before["snapshot_id"] as? String ?? "",
                        "after_snapshot_id": after["snapshot_id"] as? String ?? result["snapshot_id"] as? String ?? "",
                        "changed_fields": diff["changed_fields"] ?? [],
                        "precondition": IOSWebMountRedactor.redactedJSONObject(preconditionResult ?? [:]),
                        "postcondition": IOSWebMountRedactor.redactedJSONObject(postconditionResult ?? [:])
                    ]
                    return Self.json([
                        "ok": responseSucceeded,
                        "tool": toolName,
                        "session_id": runtime.snapshot.sessionId,
                        "status": status,
                        "error_code": errorCode,
                        "reason": postconditionPreexisting
                            ? "The requested postcondition was already true before dispatch, so it cannot verify this action. Re-observe before deciding whether to retry."
                            : (postconditionFailed
                                ? "The action was dispatched, but its postcondition was not observed before timeout. Re-observe before retrying."
                                : ""),
                        "may_have_applied": mayHaveApplied,
                        "verified": verified,
                        "before_snapshot_id": before["snapshot_id"] as? String ?? "",
                        "snapshot_id": after["snapshot_id"] as? String ?? result["snapshot_id"] as? String ?? "",
                        "before": IOSWebMountRedactor.redactedJSONObject(before),
                        "after": IOSWebMountRedactor.redactedJSONObject(after),
                        "diff": diff,
                        "action_receipt": receipt,
                        "action": IOSWebMountRedactor.redactedJSONObject(result)
                    ])
                } catch {
                    touch(sessionId: runtime.snapshot.sessionId, context: context)
                    let mayHaveApplied = mutating && actionStarted
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "session_id": runtime.snapshot.sessionId,
                        "status": mayHaveApplied ? "unknown_after_action" : "failed",
                        "error_code": mayHaveApplied ? "unknown_after_action" : "runtime_error",
                        "may_have_applied": mayHaveApplied,
                        "verified": false,
                        "error": IOSWebMountRedactor.redactedText(error.localizedDescription)
                    ])
                }
            default:
                return Self.unsupportedToolResult(toolName: toolName)
            }
        } catch let error as IOSWebMountSessionError {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "denied": true,
                "error_code": error.errorCode,
                "error": IOSWebMountRedactor.redactedText(error.localizedDescription),
                "reason": IOSWebMountRedactor.redactedText(error.localizedDescription)
            ])
        } catch {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "error": IOSWebMountRedactor.redactedText(error.localizedDescription)
            ])
        }
    }

    func preflightUserAction(
        toolName: String,
        input: String,
        context: IOSWebMountExecutionContext?
    ) async -> String? {
        guard Self.interactionMutatingToolNames.contains(toolName) else { return nil }
        let args = Self.parseObject(input)
        if context?.isAgentInvocation == true,
           (args["snapshot_id"] as? String)?.nilIfBlank == nil {
            return nil
        }
        do {
            if let sessionId = (args["session_id"] as? String)?.nilIfBlank,
               let record = sessionStore.record(sessionId: sessionId),
               record.backend != .local {
                if let context, context.isAgentInvocation {
                    guard context.hasCompleteBinding else { return nil }
                    _ = try sessionStore.bindAgentSession(
                        sessionId: sessionId,
                        runId: context.runId,
                        conversationId: context.conversationId,
                        requiresControl: true
                    )
                }
                return desktopBackend.preflightAction(
                    toolName: toolName,
                    arguments: args,
                    logicalSessionId: sessionId
                )
            }
            let runtime = try sessionRuntime(
                from: args,
                context: context,
                requiresControl: true
            )
            let method = toolName.removingPrefix("wm_")
            let selector = args["selector"] as? String ?? args["target"] as? String
            let text = args["text"] as? String ?? args["value"] as? String
            var options = args
            if options["dy"] == nil, let byY = args["by_y"] { options["dy"] = byY }
            options["_amber_preflight_only"] = true
            options["_amber_allow_high_consequence"] = false
            let result = try await runtime.interact(
                method: method,
                selector: selector,
                text: text,
                options: options
            )
            return interactionGateOutput(
                toolName: toolName,
                result: result,
                sessionId: runtime.snapshot.sessionId,
                snapshotId: result["snapshot_id"] as? String,
                handoffToUser: context?.isAgentInvocation == true
            )
        } catch {
            return nil
        }
    }

    private func interactionGateOutput(
        toolName: String,
        result: [String: Any],
        sessionId: String,
        snapshotId: String?,
        handoffToUser: Bool
    ) -> String? {
        if result["requires_human"] as? Bool == true {
            if handoffToUser {
                _ = try? sessionStore.acquireUserControl(sessionId: sessionId)
            }
            let record = sessionStore.record(sessionId: sessionId)
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": sessionId,
                "backend": record?.backend.rawValue ?? "local",
                "site_id": record?.siteId ?? "",
                "requires_human": true,
                "handoff": true,
                "error_code": result["error_code"] as? String ?? "sensitive_field_requires_human",
                "reason": IOSWebMountRedactor.redactedText(
                    result["reason"] as? String
                        ?? "Complete login, verification, CAPTCHA, or sensitive payment input in user-controlled WebMount."
                ),
                "resume_condition": "Finish the sensitive step in WebMount, then use Hand back to Agent.",
                "snapshot_id": snapshotId ?? "",
                "target_ref": result["target_ref"] as? String ?? "",
                "target_label": IOSWebMountRedactor.redactedText(result["target_label"] as? String ?? ""),
                "may_have_applied": false
            ])
        }
        if result["needs_user_action"] as? Bool == true {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": sessionId,
                "needs_user_action": true,
                "error_code": result["error_code"] as? String ?? "high_consequence_requires_approval",
                "reason": IOSWebMountRedactor.redactedText(
                    result["reason"] as? String
                        ?? "This WebMount action requires explicit foreground approval."
                ),
                "consequence": IOSWebMountRedactor.redactedText(result["consequence"] as? String ?? ""),
                "snapshot_id": snapshotId ?? "",
                "target_ref": result["target_ref"] as? String ?? "",
                "target_label": IOSWebMountRedactor.redactedText(result["target_label"] as? String ?? ""),
                "may_have_applied": false
            ])
        }
        return nil
    }

    static func unsupportedToolResult(toolName: String) -> String {
        let reason: String
        switch toolName {
        case "wm_visual_read":
            reason = "wm_visual_read is unsupported on iOS because it requires an external vision provider and a separate privacy approval path."
        case "wm_signed_fetch", "wm_network_inspect", "wm_fetch_replay", "wm_recipe_candidates":
            reason = "This network replay capability is unsupported on iOS until WebMount has isolated signed-fetch and network-log handling."
        case "wm_eval":
            reason = "Arbitrary JavaScript evaluation is not supported by iOS WebMount."
        default:
            reason = "This WebMount capability is not implemented on iOS yet"
        }
        return json([
            "ok": false,
            "tool": toolName,
            "unsupported": true,
            "reason": reason
        ])
    }

    private func sessionRuntime(
        from args: [String: Any],
        context: IOSWebMountExecutionContext?,
        requiresControl: Bool = true
    ) throws -> IOSWebMountRuntimeServicing {
        let requestedSessionId = (args["session_id"] as? String)?.nilIfBlank
        let targetSessionId = requestedSessionId ?? sessionStore.currentSessionId
        if let record = sessionStore.record(sessionId: targetSessionId), record.siteId != nil {
            guard let siteId = record.siteId,
                  let site = registry.site(id: siteId) else {
                throw IOSWebMountSessionError.siteBindingRequired
            }
            guard site.enabled else {
                throw IOSWebMountSessionError.siteDisabled(site.id)
            }
        }
        if let context {
            guard context.hasCompleteBinding else {
                throw IOSWebMountSessionError.sessionBindingRequired
            }
            guard let requestedSessionId else {
                throw IOSWebMountSessionError.sessionBindingRequired
            }
            _ = try sessionStore.bindAgentSession(
                sessionId: requestedSessionId,
                runId: context.runId,
                conversationId: context.conversationId,
                requiresControl: requiresControl
            )
            return try sessionStore.runtime(sessionId: requestedSessionId, makeCurrent: false)
        }
        return try sessionStore.runtime(sessionId: requestedSessionId, makeCurrent: true)
    }

    private func touch(sessionId: String, context: IOSWebMountExecutionContext?) {
        sessionStore.touch(
            sessionId: sessionId,
            makeCurrent: context?.isAgentInvocation != true
        )
    }

    private func agentOwnershipLost(
        sessionId: String,
        context: IOSWebMountExecutionContext?
    ) -> Bool {
        guard let context, context.isAgentInvocation else { return false }
        let record = sessionStore.record(sessionId: sessionId)
        return record?.controlOwner != .agent || record?.ownerRunId != context.runId
    }

    private static func localNavigationOwnershipUnknown(
        toolName: String,
        sessionId: String
    ) -> String {
        json([
            "ok": false,
            "tool": toolName,
            "session_id": sessionId,
            "status": "unknown_after_action",
            "error_code": "unknown_after_action",
            "may_have_applied": true,
            "verified": false,
            "needs_reopen": true,
            "reason": "WebMount control changed while navigation was in flight. Reopen the page before another mutation."
        ])
    }

    private static func webMountInputLimitFailure(
        toolName: String,
        args: [String: Any]
    ) -> String? {
        let maximum: Int
        switch toolName {
        case "wm_type": maximum = 20_000
        case "wm_keys": maximum = 64
        case "wm_select": maximum = 512
        default: return nil
        }
        let text = (args["text"] as? String) ?? (args["value"] as? String) ?? ""
        guard text.count > maximum else { return nil }
        return json([
            "ok": false,
            "tool": toolName,
            "denied": true,
            "error_code": "input_too_large",
            "may_have_applied": false,
            "reason": "WebMount input exceeds the bounded size for this action."
        ])
    }

    private func tabListResult() -> String {
        Self.json([
            "ok": true,
            "tool": "wm_tab_list",
            "current_session_id": sessionStore.currentSessionId,
            "max_sessions": sessionStore.maxSessions,
            "count": sessionStore.records.count,
            "sessions": sessionStore.records.map(sessionDictionary)
        ])
    }

    private func tabNewResult(
        args: [String: Any],
        isUserInitiated: Bool,
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        if let context, !context.hasCompleteBinding {
            return Self.json([
                "ok": false,
                "tool": "wm_tab_new",
                "denied": true,
                "error_code": IOSWebMountSessionError.sessionBindingRequired.errorCode,
                "reason": "Agent WebMount calls require both conversation_id and run_id before a session can be created."
            ])
        }
        let site = siteFromArgs(args)
        let persistent = args["persistent"] as? Bool ?? false
        if persistent && !isUserInitiated {
            return Self.json([
                "ok": false,
                "tool": "wm_tab_new",
                "needs_user_action": true,
                "error_code": "persistent_opt_in_required",
                "reason": "Persistent WebMount metadata requires an explicit App action."
            ])
        }
        let backendRaw = (args["backend"] as? String)?.nilIfBlank ?? IOSWebMountBackendKind.local.rawValue
        guard let backend = IOSWebMountBackendKind(rawValue: backendRaw) else {
            return Self.json([
                "ok": false,
                "tool": "wm_tab_new",
                "error_code": "invalid_backend",
                "reason": "Unknown WebMount backend: \(backendRaw)"
            ])
        }
        let isAgent = context?.isAgentInvocation == true
        let record: IOSWebMountSessionRecord
        if backend == .local {
            if let site, !site.enabled {
                return Self.json([
                    "ok": false,
                    "tool": "wm_tab_new",
                    "error_code": "site_disabled",
                    "site_id": site.id,
                    "reason": "WebMount station is disabled"
                ])
            }
            record = try sessionStore.newSession(
                site: site,
                persistent: persistent,
                makeCurrent: !isAgent
            )
        } else {
            guard let site else {
                return Self.json([
                    "ok": false,
                    "tool": "wm_tab_new",
                    "error_code": "site_binding_required",
                    "reason": "Remote WebMount sessions require an existing registered site_id."
                ])
            }
            guard site.enabled else {
                return Self.json([
                    "ok": false,
                    "tool": "wm_tab_new",
                    "error_code": "site_disabled",
                    "site_id": site.id,
                    "reason": "Remote WebMount sessions require an enabled registered station."
                ])
            }
            guard site.authKind == .anonymous else {
                return Self.json([
                    "ok": false,
                    "tool": "wm_tab_new",
                    "error_code": "local_privacy_session_required",
                    "reason": "Login, OAuth, and App-private stations stay in local WKWebView."
                ])
            }
            guard let serverName = (args["mcp_server_name"] as? String)?.nilIfBlank,
                  let config = mcpServerProvider().first(where: { $0.name == serverName }) else {
                return Self.json([
                    "ok": false,
                    "tool": "wm_tab_new",
                    "error_code": "desktop_backend_not_configured",
                    "reason": "Select an existing MCP server for the desktop backend."
                ])
            }
            let placeholder = IOSWebMountRemotePlaceholderRuntime()
            do {
                try await desktopBackend.connect(
                    logicalSessionId: placeholder.snapshot.sessionId,
                    backend: backend,
                    config: config
                )
                record = try sessionStore.newSession(
                    site: site,
                    persistent: persistent,
                    makeCurrent: false,
                    backend: backend,
                    mcpServerName: serverName,
                    runtime: placeholder
                )
            } catch {
                desktopBackend.close(logicalSessionId: placeholder.snapshot.sessionId)
                return Self.json([
                    "ok": false,
                    "tool": "wm_tab_new",
                    "backend": backend.rawValue,
                    "mcp_server_name": serverName,
                    "error_code": Self.desktopErrorCode(error),
                    "reason": IOSWebMountRedactor.redactedText(error.localizedDescription)
                ])
            }
        }
        if let context, isAgent {
            _ = try sessionStore.acquireAgentControl(
                sessionId: record.id,
                runId: context.runId,
                conversationId: context.conversationId
            )
        }
        return Self.json([
            "ok": true,
            "tool": "wm_tab_new",
            "session_id": record.id,
            "current_session_id": sessionStore.currentSessionId,
            "max_sessions": sessionStore.maxSessions,
            "session": sessionDictionary(record),
            "sessions": sessionStore.records.map(sessionDictionary)
        ])
    }

    private func tabCloseResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) throws -> String {
        let requestedSessionId = (args["session_id"] as? String)?.nilIfBlank
        if context?.isAgentInvocation == true, requestedSessionId == nil {
            throw IOSWebMountSessionError.sessionBindingRequired
        }
        let sessionId = requestedSessionId ?? sessionStore.currentSessionId
        if let context, context.isAgentInvocation {
            _ = try sessionStore.acquireAgentControl(
                sessionId: sessionId,
                runId: context.runId,
                conversationId: context.conversationId
            )
        }
        desktopBackend.close(logicalSessionId: sessionId)
        let next = try sessionStore.close(sessionId: sessionId)
        return Self.json([
            "ok": true,
            "tool": "wm_tab_close",
            "closed_session_id": sessionId,
            "current_session_id": sessionStore.currentSessionId,
            "current_session": next.map(sessionDictionary) ?? [:],
            "sessions": sessionStore.records.map(sessionDictionary)
        ])
    }

    func desktopStatus(sessionId: String) -> IOSWebMountDesktopBackendStatus {
        desktopBackend.status(logicalSessionId: sessionId)
    }

    func desktopCapabilities(sessionId: String) -> [IOSWebMountDesktopCapability] {
        desktopBackend.capabilities(logicalSessionId: sessionId)
    }

    func reconnectDesktopSession(sessionId: String) async -> String {
        guard let record = sessionStore.record(sessionId: sessionId), record.backend != .local else {
            return Self.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "session_not_found"
            ])
        }
        guard let siteId = record.siteId,
              let site = registry.site(id: siteId) else {
            return Self.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "site_binding_required",
                "reason": "Remote WebMount sessions require a registered bound site."
            ])
        }
        guard site.enabled else {
            return Self.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "site_disabled",
                "site_id": site.id,
                "reason": "WebMount station is disabled"
            ])
        }
        guard site.authKind == .anonymous else {
            return Self.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "local_privacy_session_required",
                "reason": "Login, OAuth, and App-private stations stay in local WKWebView."
            ])
        }
        guard let serverName = record.mcpServerName,
              let config = mcpServerProvider().first(where: { $0.name == serverName }) else {
            return Self.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "desktop_backend_not_configured"
            ])
        }
        do {
            try await desktopBackend.connect(
                logicalSessionId: sessionId,
                backend: record.backend,
                config: config
            )
            sessionStore.markNeedsReopen(sessionId: sessionId)
            sessionStore.touch(sessionId: sessionId, makeCurrent: false)
            return Self.json([
                "ok": true,
                "session_id": sessionId,
                "backend": record.backend.rawValue,
                "mcp_server_name": serverName,
                "status": "connected",
                "capabilities": desktopCapabilities(sessionId: sessionId).filter(\.available).map(\.amberToolName)
            ])
        } catch {
            return Self.json([
                "ok": false,
                "session_id": sessionId,
                "backend": record.backend.rawValue,
                "mcp_server_name": serverName,
                "error_code": Self.desktopErrorCode(error),
                "reason": IOSWebMountRedactor.redactedText(error.localizedDescription)
            ])
        }
    }

    private func desktopResult(
        toolName: String,
        args: [String: Any],
        record: IOSWebMountSessionRecord,
        isUserInitiated: Bool,
        context: IOSWebMountExecutionContext?,
        allowUnlistedHosts: Bool
    ) async throws -> String {
        guard let siteId = record.siteId,
              let site = registry.site(id: siteId) else {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "backend": record.backend.rawValue,
                "error_code": "site_binding_required",
                "reason": "Remote WebMount sessions require a registered bound site."
            ])
        }
        guard site.enabled else {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "backend": record.backend.rawValue,
                "error_code": "site_disabled",
                "site_id": site.id,
                "reason": "WebMount station is disabled"
            ])
        }
        guard site.authKind == .anonymous else {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "backend": record.backend.rawValue,
                "error_code": "local_privacy_session_required",
                "reason": "Login, OAuth, and App-private stations stay in local WKWebView."
            ])
        }
        if toolName != "wm_open" {
            guard !record.needsReopen,
                  let currentURL = record.redactedURL.nilIfBlank,
                  await remoteURLIsAllowed(
                      currentURL,
                      site: site,
                      allowUnlistedHosts: allowUnlistedHosts
                  ) else {
                sessionStore.markNeedsReopen(sessionId: record.id)
                return Self.remoteRequiresReopenResult(
                    toolName: toolName,
                    sessionId: record.id,
                    reason: "Remote WebMount requires a successful allowlisted wm_open before this operation."
                )
            }
            if desktopBackend.status(logicalSessionId: record.id) == .needsReopen {
                sessionStore.markNeedsReopen(sessionId: record.id)
                return Self.remoteRequiresReopenResult(
                    toolName: toolName,
                    sessionId: record.id,
                    reason: "The remote MCP session requires reconnecting and reopening an allowlisted page."
                )
            }
        }
        let requiresControl = Self.desktopMutatingToolNames.contains(toolName)
        if let context, context.isAgentInvocation {
            guard context.hasCompleteBinding else {
                throw IOSWebMountSessionError.sessionBindingRequired
            }
            _ = try sessionStore.bindAgentSession(
                sessionId: record.id,
                runId: context.runId,
                conversationId: context.conversationId,
                requiresControl: requiresControl
            )
        }

        func ownershipLost() -> Bool {
            guard let context, context.isAgentInvocation else { return false }
            let ownership = sessionStore.record(sessionId: record.id)
            return ownership?.controlOwner != .agent || ownership?.ownerRunId != context.runId
        }

        if context?.isAgentInvocation == true,
           Self.desktopMutatingToolNames.contains(toolName) {
            let usesRawPageTarget = args["selector"] != nil || args["x"] != nil || args["y"] != nil
            let requiresSemanticTarget = ["wm_click", "wm_tap", "wm_type", "wm_select"].contains(toolName)
            let hasSemanticTarget = (args["target"] as? String)?.nilIfBlank != nil
            if usesRawPageTarget || (requiresSemanticTarget && !hasSemanticTarget) {
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "status": "rejected",
                    "error_code": "semantic_target_required",
                    "may_have_applied": false,
                    "reason": "Agent desktop mutations require a semantic target from the latest WebMount snapshot."
                ])
            }
        }
        guard let serverName = record.mcpServerName,
              let config = mcpServerProvider().first(where: { $0.name == serverName }),
              desktopBackend.allowsCurrentConfiguration(
                config,
                toolName: toolName,
                logicalSessionId: record.id
              ) else {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "backend": record.backend.rawValue,
                "mcp_server_name": record.mcpServerName ?? "",
                "status": "failed",
                "error_code": "desktop_backend_disabled",
                "may_have_applied": false,
                "reason": "The bound MCP server or browser tool is no longer enabled. Reconnect explicitly after reviewing its configuration."
            ])
        }

        let postcondition = Self.interactionMutatingToolNames.contains(toolName)
            ? Self.webMountRemotePostconditionOptions(from: args)
            : nil
        if Self.interactionMutatingToolNames.contains(toolName),
           args["postcondition"] != nil,
           postcondition == nil {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "status": "rejected",
                "error_code": "invalid_postcondition",
                "may_have_applied": false,
                "reason": "postcondition requires a supported condition and a value unless condition is dom_stable."
            ])
        }
        if let postcondition,
           !desktopBackend.supportsVerifiedWait(
                arguments: postcondition,
                logicalSessionId: record.id
           ) {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "status": "rejected",
                "error_code": "postcondition_unsupported",
                "may_have_applied": false,
                "reason": "This desktop gateway does not expose a bounded, structured wait contract for the requested postcondition."
            ])
        }

        var preconditionObject: [String: Any]?
        if var preconditionProbe = postcondition {
            preconditionProbe["timeout_ms"] = 100
            let probeOutput = await desktopBackend.execute(
                toolName: "wm_wait",
                arguments: preconditionProbe,
                logicalSessionId: record.id
            )
            preconditionObject = Self.parseObject(probeOutput)
            guard preconditionObject?["ok"] as? Bool == true,
                  preconditionObject?["match_explicit"] as? Bool == true else {
                sessionStore.touch(sessionId: record.id, makeCurrent: false)
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "status": "rejected",
                    "error_code": "postcondition_probe_failed",
                    "may_have_applied": false,
                    "verified": false,
                    "reason": "The desktop gateway did not return an explicit matched=true/false precondition result, so the action was not dispatched."
                ])
            }
            if ownershipLost() {
                sessionStore.touch(sessionId: record.id, makeCurrent: false)
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "status": "rejected",
                    "error_code": "control_unavailable",
                    "may_have_applied": false,
                    "verified": false,
                    "reason": "WebMount control changed before the desktop action was dispatched."
                ])
            }
        }

        var routedArgs = args
        var requestedURL: String?
        if toolName == "wm_open" {
            if let requestedSite = siteFromArgs(args), requestedSite.id != site.id {
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "error_code": "session_binding_mismatch",
                    "reason": "Remote navigation must use the session's bound WebMount station."
                ])
            }
            guard site.enabled else {
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "error_code": "host_not_allowed",
                    "reason": "Desktop navigation requires an enabled registered WebMount station."
                ])
            }
            guard site.authKind == .anonymous else {
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "error_code": "local_privacy_session_required",
                    "reason": "Login, OAuth, and App-private stations stay in local WKWebView."
                ])
            }
            let rawURL = (args["url"] as? String)?.nilIfBlank ?? site.homepageURL
            let policy = IOSWebMountURLPolicy(
                settings: settings,
                extraAllowedHosts: registry.sites.flatMap(\.allowedHosts),
                allowUnlistedHosts: allowUnlistedHosts
            )
            switch await policy.validateResolvedPublicHost(
                rawURL,
                site: site,
                resolveHost: resolveHost
            ) {
            case .failure(let error):
                return Self.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "error_code": "host_not_allowed",
                    "reason": error.localizedDescription,
                    "url": IOSWebMountRedactor.redactedURL(rawURL) ?? ""
                ])
            case .success(let url):
                guard await remoteURLIsAllowed(
                    url.absoluteString,
                    site: site,
                    allowUnlistedHosts: allowUnlistedHosts
                ) else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "session_id": record.id,
                        "error_code": "host_not_allowed",
                        "reason": "Desktop navigation URL is outside the bound WebMount station allowlist.",
                        "url": IOSWebMountRedactor.redactedURL(url.absoluteString) ?? ""
                    ])
                }
                requestedURL = url.absoluteString
                routedArgs["url"] = url.absoluteString
                sessionStore.tag(sessionId: record.id, site: site)
            }
        }

        if requiresControl, ownershipLost() {
            sessionStore.touch(sessionId: record.id, makeCurrent: false)
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "status": "rejected",
                "error_code": "control_unavailable",
                "may_have_applied": false,
                "verified": false,
                "reason": "WebMount control changed before the desktop action was dispatched."
            ])
        }

        var output = await desktopBackend.execute(
            toolName: toolName,
            arguments: routedArgs,
            logicalSessionId: record.id,
            approvedHighConsequence: isUserInitiated
        )
        let actionObject = Self.parseObject(output)
        let interactionMutation = Self.interactionMutatingToolNames.contains(toolName)
        let desktopMutation = Self.desktopMutatingToolNames.contains(toolName)
        let actionSucceeded = actionObject["ok"] as? Bool == true
        let actionMayHaveApplied = actionObject["may_have_applied"] as? Bool == true
        let actionDispatched = desktopMutation && (actionSucceeded || actionMayHaveApplied)

        func unknownAfterControlChange(postconditionResult: [String: Any]? = nil) -> String {
            if Self.remoteNavigationToolNames.contains(toolName) {
                sessionStore.markNeedsReopen(sessionId: record.id)
            }
            return Self.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "backend": record.backend.rawValue,
                "status": "unknown_after_action",
                "error_code": "unknown_after_action",
                "may_have_applied": true,
                "verified": false,
                "reason": "WebMount control changed before the desktop action outcome was verified.",
                "action": IOSWebMountRedactor.redactedJSONObject(actionObject),
                "postcondition": IOSWebMountRedactor.redactedJSONObject(postconditionResult ?? [:])
            ])
        }

        if actionDispatched, ownershipLost() {
            sessionStore.touch(sessionId: record.id, makeCurrent: false)
            return unknownAfterControlChange()
        }

        var postconditionObject: [String: Any]?
        if actionSucceeded, let postcondition {
            let postconditionOutput = await desktopBackend.execute(
                toolName: "wm_wait",
                arguments: postcondition,
                logicalSessionId: record.id
            )
            postconditionObject = Self.parseObject(postconditionOutput)
            if ownershipLost() {
                sessionStore.touch(sessionId: record.id, makeCurrent: false)
                return unknownAfterControlChange(postconditionResult: postconditionObject)
            }
        }

        if interactionMutation, actionDispatched, actionSucceeded {
            let preconditionMatched = preconditionObject?["matched"] as? Bool == true
            let postconditionMatched = postconditionObject?["ok"] as? Bool == true
                && postconditionObject?["matched"] as? Bool == true
            let verified = postcondition != nil && postconditionMatched && !preconditionMatched
            let postconditionPreexisting = postcondition != nil && preconditionMatched
            let postconditionFailed = postcondition != nil && !verified
            let status: String
            let errorCode: String
            let reason: String
            if verified {
                status = "verified"
                errorCode = ""
                reason = ""
            } else if postconditionPreexisting {
                status = "ambiguous"
                errorCode = "postcondition_preexisting"
                reason = "The requested postcondition was already true before dispatch, so it cannot verify this action. Re-observe before deciding whether to retry."
            } else if postconditionFailed {
                status = "ambiguous"
                errorCode = "postcondition_not_met"
                reason = "The action was dispatched, but its postcondition was not observed before timeout. Re-observe before retrying."
            } else {
                status = "dispatched_unverified"
                errorCode = ""
                reason = ""
            }
            var composed = actionObject
            composed.merge([
                "ok": actionSucceeded && !postconditionFailed,
                "status": status,
                "error_code": errorCode,
                "reason": reason,
                "may_have_applied": !verified,
                "verified": verified,
                "action_receipt": [
                    "outcome": verified ? "verified" : "ambiguous",
                    "dispatched": true,
                    "verified": verified,
                    "verification_source": verified ? "postcondition" : "",
                    "before_snapshot_id": args["snapshot_id"] as? String ?? "",
                    "after_snapshot_id": actionObject["snapshot_id"] as? String ?? "",
                    "precondition": IOSWebMountRedactor.redactedJSONObject(preconditionObject ?? [:]),
                    "postcondition": IOSWebMountRedactor.redactedJSONObject(postconditionObject ?? [:])
                ],
                "action": IOSWebMountRedactor.redactedJSONObject(actionObject)
            ]) { _, new in new }
            output = Self.json(composed)
        }
        (sessionStore.runtimeIfPresent(sessionId: record.id) as? IOSWebMountRemotePlaceholderRuntime)?
            .apply(resultText: output, toolName: toolName, requestedURL: requestedURL)
        let outputObject = Self.parseObject(output)
        let adapterNeedsReopen = desktopBackend.status(logicalSessionId: record.id) == .needsReopen
            || outputObject["error_code"] as? String == "mcp_session_expired"
            || outputObject["error_code"] as? String == "needs_reopen"
            || outputObject["status"] as? String == "needs_reopen"
            || outputObject["needs_reopen"] as? Bool == true
        if adapterNeedsReopen {
            sessionStore.markNeedsReopen(sessionId: record.id)
        }
        if Self.remoteNavigationToolNames.contains(toolName), !adapterNeedsReopen {
            let succeeded = outputObject["ok"] as? Bool == true
            let mayHaveApplied = outputObject["may_have_applied"] as? Bool == true
            if succeeded {
                var currentURL = Self.remoteCurrentURL(from: outputObject)
                if currentURL == nil {
                    let stateOutput = await desktopBackend.execute(
                        toolName: "wm_state",
                        arguments: [:],
                        logicalSessionId: record.id
                    )
                    let stateObject = Self.parseObject(stateOutput)
                    if stateObject["ok"] as? Bool == true {
                        currentURL = Self.remoteCurrentURL(from: stateObject)
                    }
                    if ownershipLost() {
                        sessionStore.touch(sessionId: record.id, makeCurrent: false)
                        return unknownAfterControlChange()
                    }
                }
                guard let currentURL,
                      await remoteURLIsAllowed(
                          currentURL,
                          site: site,
                          allowUnlistedHosts: allowUnlistedHosts
                      ) else {
                    sessionStore.markNeedsReopen(sessionId: record.id)
                    return Self.remoteRequiresReopenResult(
                        toolName: toolName,
                        sessionId: record.id,
                        reason: "The remote gateway did not prove a current URL on the bound site after navigation."
                    )
                }
                if actionDispatched, ownershipLost() {
                    sessionStore.touch(sessionId: record.id, makeCurrent: false)
                    return unknownAfterControlChange()
                }
                sessionStore.recordValidatedRemoteURL(
                    sessionId: record.id,
                    rawURL: currentURL,
                    clearNeedsReopen: toolName == "wm_open"
                )
            } else if mayHaveApplied {
                sessionStore.markNeedsReopen(sessionId: record.id)
            }
        }
        sessionStore.touch(sessionId: record.id, makeCurrent: false)
        return output
    }

    private func sessionDictionary(_ record: IOSWebMountSessionRecord) -> [String: Any] {
        var value = record.dictionary()
        if record.backend == .local {
            value["desktop_status"] = "local"
            value["desktop_capabilities"] = []
        } else {
            value["desktop_status"] = desktopStatus(sessionId: record.id).code
            value["desktop_capabilities"] = desktopCapabilities(sessionId: record.id)
                .filter(\.available)
                .map(\.amberToolName)
        }
        return value
    }

    private func localSessionPolicyFailure(
        toolName: String,
        args: [String: Any],
        allowUnlistedHosts: Bool
    ) -> String? {
        guard Self.localSessionPolicyToolNames.contains(toolName) else { return nil }
        let sessionId = (args["session_id"] as? String)?.nilIfBlank ?? sessionStore.currentSessionId
        guard let record = sessionStore.record(sessionId: sessionId), record.backend == .local else {
            return nil
        }
        let site = record.siteId.flatMap { registry.site(id: $0) }
        let policy = IOSWebMountURLPolicy(
            settings: settings,
            extraAllowedHosts: registry.sites.flatMap(\.allowedHosts),
            allowUnlistedHosts: allowUnlistedHosts
        )
        (sessionStore.runtimeIfPresent(sessionId: sessionId) as? IOSWebMountWKRuntime)?
            .setNavigationPolicy(policy, site: site, resolveHost: resolveHost)
        guard let currentURL = record.redactedURL.nilIfBlank else { return nil }
        guard case .failure(let error) = policy.validate(currentURL, site: site) else { return nil }
        let errorCode: String
        switch error {
        case .hostNotAllowed where !allowUnlistedHosts:
            errorCode = "high_risk_auto_approve_required"
        case .privateHostNotAllowed:
            errorCode = "private_host_not_allowed"
        default:
            errorCode = "url_policy_denied"
        }
        return Self.json([
            "ok": false,
            "tool": toolName,
            "session_id": sessionId,
            "denied": true,
            "error_code": errorCode,
            "reason": error.localizedDescription,
            "url": IOSWebMountRedactor.redactedURL(currentURL) ?? ""
        ])
    }

    private static let desktopRoutingExemptToolNames: Set<String> = [
        "wm_stations", "wm_tab_list", "wm_tab_new", "wm_tab_close", "wm_site_add", "wm_site_remove"
    ]

    private static let localSessionPolicyToolNames: Set<String> = [
        "wm_state", "wm_observe", "wm_extract", "wm_get", "wm_visual_snapshot", "wm_screenshot",
        "wm_back", "wm_forward", "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll",
        "wm_select", "wm_find", "wm_wait"
    ]

    private static let desktopMutatingToolNames: Set<String> = [
        "wm_open", "wm_back", "wm_forward", "wm_click", "wm_tap", "wm_type",
        "wm_keys", "wm_scroll", "wm_select", "wm_clear_session"
    ]

    private static let interactionMutatingToolNames: Set<String> = [
        "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll", "wm_select"
    ]

    private static let remoteNavigationToolNames: Set<String> = [
        "wm_open", "wm_back", "wm_forward", "wm_click", "wm_tap", "wm_type",
        "wm_keys", "wm_scroll", "wm_select"
    ]

    private func remoteURLIsAllowed(
        _ rawURL: String,
        site: IOSWebMountSite,
        allowUnlistedHosts: Bool
    ) async -> Bool {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              Set(settings.allowedSchemes.map { $0.lowercased() }).contains(scheme),
              components.user == nil,
              components.password == nil,
              let host = components.host else {
            return false
        }
        if allowUnlistedHosts {
            let policy = IOSWebMountURLPolicy(
                settings: settings,
                allowUnlistedHosts: true
            )
            if case .failure = await policy.validateResolvedPublicHost(
                rawURL,
                resolveHost: resolveHost
            ) {
                return false
            }
        }
        return allowUnlistedHosts || IOSWebMountURLPolicy.host(host, matchesAnyOf: site.allowedHosts)
    }

    private static func remoteCurrentURL(from value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        return (object["current_url"] as? String)?.nilIfBlank
    }

    private static func remoteRequiresReopenResult(
        toolName: String,
        sessionId: String,
        reason: String
    ) -> String {
        json([
            "ok": false,
            "tool": toolName,
            "session_id": sessionId,
            "status": "unknown_after_action",
            "error_code": "requires_reopen",
            "may_have_applied": true,
            "verified": false,
            "needs_reopen": true,
            "reason": reason
        ])
    }

    private static func desktopErrorCode(_ error: Error) -> String {
        if let error = error as? IOSWebMountDesktopBackendError { return error.errorCode }
        if let error = error as? IOSMcpClientError, error == .mcpSessionExpired {
            return "mcp_session_expired"
        }
        if error is IOSWebMountDesktopEndpointPolicyError {
            return "desktop_endpoint_rejected"
        }
        return "desktop_gateway_unavailable"
    }

    private func stationsResult(args: [String: Any]) async -> String {
        let authFilter = (args["auth_kind_filter"] as? String)?.lowercased().nilIfBlank
        var stations: [[String: Any]] = []
        for site in registry.sites {
            if let authFilter, site.authKind.rawValue != authFilter { continue }
            let summary = await cookieStore.summary(for: site)
            let loginStatus: String
            switch site.authKind {
            case .anonymous:
                loginStatus = "logged_in"
            case .cookie:
                if summary.hasLoginCookie == true {
                    loginStatus = "logged_in"
                } else if summary.hasLoginCookie == false {
                    loginStatus = "logged_out"
                } else {
                    loginStatus = "unknown"
                }
            case .oauth:
                loginStatus = "unknown"
            }
            var payload: [String: Any] = [
                "id": site.id,
                "display_name": site.displayName,
                "url": IOSWebMountRedactor.redactedURL(site.homepageURL) ?? "",
                "auth_kind": site.authKind.rawValue,
                "enabled": site.enabled,
                "user_added": site.nativeAdapterId == nil,
                "login_status": loginStatus,
                "cookie_count": summary.cookieCount,
                "cookie_names": summary.cookieNames,
                "native_adapter_id": site.nativeAdapterId ?? "",
                "adapter_status": site.nativeAdapterId == nil ? "not_configured" : "unsupported_on_ios",
                "oauth_token_present": false,
                "redacted": true
            ]
            if site.authKind == .oauth {
                payload["oauth_status"] = "unsupported_on_ios"
            }
            stations.append(payload)
        }
        return Self.json([
            "ok": true,
            "global_enabled": settings.globalEnabled,
            "eval_supported": false,
            "count": stations.count,
            "stations": stations
        ])
    }

    private func openResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?,
        allowUnlistedHosts: Bool
    ) async throws -> String {
        let requestedSiteId = (args["site_id"] as? String)?.nilIfBlank
        let resolvedSite = siteFromArgs(args)
        if requestedSiteId != nil, resolvedSite == nil {
            return Self.json([
                "ok": false,
                "denied": true,
                "error_code": "site_binding_required",
                "reason": "wm_open received an unknown WebMount station."
            ])
        }
        if let resolvedSite, !resolvedSite.enabled {
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": "WebMount station is disabled",
                "site_id": resolvedSite.id
            ])
        }
        let site = resolvedSite
        if !allowUnlistedHosts, site == nil {
            return Self.json([
                "ok": false,
                "denied": true,
                "error_code": "host_not_allowed",
                "reason": "wm_open requires a registered WebMount station. Add or restore the site before opening this URL."
            ])
        }
        guard let rawURL = (args["url"] as? String)?.nilIfBlank ?? site?.homepageURL else {
            return Self.json([
                "ok": false,
                "denied": true,
                "error_code": "missing_url",
                "reason": "wm_open requires url when no WebMount station is selected."
            ])
        }
        let policy = IOSWebMountURLPolicy(
            settings: settings,
            extraAllowedHosts: registry.sites.flatMap(\.allowedHosts),
            allowUnlistedHosts: allowUnlistedHosts
        )
        switch await policy.validateResolvedPublicHost(
            rawURL,
            site: site,
            resolveHost: resolveHost
        ) {
        case .failure(let error):
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": error.localizedDescription,
                "url": IOSWebMountRedactor.redactedURL(rawURL) ?? ""
            ])
        case .success(let url):
            let timeout = UInt64((args["timeout_ms"] as? Int) ?? 30_000).clamped(to: 1_000...60_000)
            let runtime = try sessionRuntime(from: args, context: context)
            (runtime as? IOSWebMountWKRuntime)?.setNavigationPolicy(
                policy,
                site: site,
                resolveHost: resolveHost
            )
            sessionStore.tag(sessionId: runtime.snapshot.sessionId, site: site)
            let snapshot = await runtime.open(url, timeoutMillis: timeout)
            if agentOwnershipLost(sessionId: snapshot.sessionId, context: context) {
                sessionStore.markNeedsReopen(sessionId: snapshot.sessionId)
                touch(sessionId: snapshot.sessionId, context: context)
                return Self.localNavigationOwnershipUnknown(
                    toolName: "wm_open",
                    sessionId: snapshot.sessionId
                )
            }
            let timedOut = snapshot.status == .failed
                && snapshot.error?.hasPrefix("load timed out after ") == true
            if timedOut {
                sessionStore.markNeedsReopen(sessionId: snapshot.sessionId)
            } else if snapshot.status != .failed {
                sessionStore.clearNeedsReopen(sessionId: snapshot.sessionId)
            }
            touch(sessionId: snapshot.sessionId, context: context)
            return Self.json([
                "ok": snapshot.status != .failed,
                "session_id": snapshot.sessionId,
                "status": timedOut ? "unknown_after_action" : snapshot.status.rawValue,
                "error_code": timedOut ? "unknown_after_action" : "",
                "may_have_applied": timedOut,
                "url": snapshot.currentURL ?? snapshot.requestedURL ?? "",
                "title": IOSWebMountRedactor.redactedText(snapshot.title ?? ""),
                "error": IOSWebMountRedactor.redactedText(snapshot.error ?? ""),
                "waited": true
            ])
        }
    }

    private func stateResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let page = try await runtime.state()
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": true,
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": page["snapshot_id"] as? String ?? "",
            "page_revision": page["page_revision"] ?? 0,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "page": IOSWebMountRedactor.redactedJSONObject(page)
        ])
    }

    private func observeResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let observation = try await runtime.observe(maxChars: 2_000, maxLinks: 20)
        let page = observation["page"] as? [String: Any] ?? [:]
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": true,
            "tool": "wm_observe",
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": observation["snapshot_id"] as? String ?? page["snapshot_id"] as? String ?? "",
            "page_revision": observation["page_revision"] ?? page["page_revision"] ?? 0,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "page": IOSWebMountRedactor.redactedJSONObject(page),
            "visible_text": IOSWebMountRedactor.redactedJSONObject(observation["visible_text"] ?? ""),
            "links": IOSWebMountRedactor.redactedJSONObject(observation["links"] ?? []),
            "interactive_elements": IOSWebMountRedactor.redactedJSONObject(observation["interactive_elements"] ?? []),
            "visual_candidates": IOSWebMountRedactor.redactedJSONObject(observation["visual_candidates"] ?? []),
            "observation_consistency": observation["observation_consistency"] ?? "unknown",
            "untrusted_page_content": true,
            "redacted": true
        ])
    }

    private func extractResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let mode = (args["mode"] as? String)?.nilIfBlank ?? "readable"
        let maxChars = ((args["max_chars"] as? Int) ?? 20_000).clamped(to: 0...80_000)
        let maxLinks = ((args["max_links"] as? Int) ?? 20).clamped(to: 0...100)
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let result = try await runtime.extract(mode: mode, maxChars: maxChars, maxLinks: maxLinks)
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": true,
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": result["snapshot_id"] as? String ?? "",
            "page_revision": result["page_revision"] ?? 0,
            "result": IOSWebMountRedactor.redactedJSONObject(result)
        ])
    }

    private func getResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let kind = ((args["kind"] as? String)?.nilIfBlank ?? "text").lowercased()
        if kind == "html" {
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get kind=html is disabled on iOS because raw DOM can contain hidden tokens. Use text, value, or attr."
            ])
        }
        if kind == "value",
           Self.looksSensitiveSelector(args["selector"] as? String) ||
            Self.looksSensitiveSelector(args["target"] as? String) {
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get refused a value read from a selector that looks like a token, password, cookie, or secret field."
            ])
        }
        if kind == "attr", Self.looksSensitiveSelector(args["attr_name"] as? String) {
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get refused a sensitive token, password, cookie, secret, or authorization attribute."
            ])
        }
        if kind == "attr", (args["attr_name"] as? String)?.lowercased() == "value" {
            return Self.json([
                "ok": false,
                "denied": true,
                "reason": "wm_get attr_name=value is disabled on iOS. Use kind=value so sensitive fields can be checked."
            ])
        }
        let maxChars = ((args["max_chars"] as? Int) ?? 20_000).clamped(to: 0...100_000)
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let result = try await runtime.get(
            selector: args["selector"] as? String,
            target: args["target"] as? String,
            kind: kind,
            attrName: args["attr_name"] as? String,
            maxChars: maxChars
        )
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": result["ok"] as? Bool ?? false,
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": result["snapshot_id"] as? String ?? "",
            "page_revision": result["page_revision"] ?? 0,
            "result": IOSWebMountRedactor.redactedJSONObject(result)
        ])
    }

    private func visualSnapshotResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let result = try await runtime.extract(mode: "snapshot", maxChars: 0, maxLinks: 80)
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": true,
            "tool": "wm_visual_snapshot",
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": result["snapshot_id"] as? String ?? "",
            "page_revision": result["page_revision"] ?? 0,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "result": IOSWebMountRedactor.redactedJSONObject(result),
            "redacted": true
        ])
    }

    private func screenshotResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let capture = try await runtime.screenshot()
        let artifact = try IOSWebMountScreenshotArtifactStore.save(capture, sessionId: runtime.snapshot.sessionId)
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": true,
            "tool": "wm_screenshot",
            "session_id": runtime.snapshot.sessionId,
            "state": runtime.snapshot.dictionary(redactURLs: true),
            "artifact": artifact,
            "redacted": true
        ])
    }

    private func clearSessionResult(args: [String: Any]) async throws -> String {
        guard let siteId = (args["site_id"] as? String)?.nilIfBlank,
              let site = registry.site(id: siteId) else {
            return Self.json(["ok": false, "error": "wm_clear_session requires a valid site_id"])
        }
        let result = await cookieStore.clearSession(for: site)
        return Self.json([
            "ok": true,
            "site_id": result.siteId,
            "deleted_cookie_count": result.deletedCookieCount,
            "cleared_website_data_records": result.clearedWebsiteDataRecords,
            "redacted": true
        ])
    }

    private func siteAddResult(args: [String: Any]) throws -> String {
        let displayName = ((args["display_name"] as? String)?.nilIfBlank
            ?? (args["name"] as? String)?.nilIfBlank
            ?? "WebMount Site")
        guard let homepageURL = (args["homepage_url"] as? String)?.nilIfBlank
            ?? (args["url"] as? String)?.nilIfBlank else {
            return Self.json([
                "ok": false,
                "tool": "wm_site_add",
                "error": "wm_site_add requires homepage_url or url"
            ])
        }
        let needsLogin = args["needs_login"] as? Bool ?? true
        let cookieName = (args["login_cookie_name"] as? String)?.nilIfBlank
            ?? (args["cookie_name"] as? String)?.nilIfBlank
        let site = try registry.addCustomSite(
            displayName: displayName,
            homepageURL: homepageURL,
            needsLogin: needsLogin,
            loginCookieName: cookieName
        )
        let enabled = args["enabled"] as? Bool ?? true
        registry.setEnabled(id: site.id, enabled: enabled)
        let savedSite = registry.site(id: site.id) ?? site
        settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
        return Self.json([
            "ok": true,
            "tool": "wm_site_add",
            "site_id": savedSite.id,
            "display_name": savedSite.displayName,
            "url": IOSWebMountRedactor.redactedURL(savedSite.homepageURL) ?? "",
            "enabled": savedSite.enabled,
            "allowed_hosts": savedSite.allowedHosts,
            "allowlist_count": settings.allowedHosts.count,
            "redacted": true
        ])
    }

    private func siteRemoveResult(args: [String: Any]) throws -> String {
        guard let siteId = (args["site_id"] as? String)?.nilIfBlank else {
            return Self.json([
                "ok": false,
                "tool": "wm_site_remove",
                "error": "wm_site_remove requires site_id"
            ])
        }
        guard let site = registry.site(id: siteId) else {
            return Self.json([
                "ok": false,
                "tool": "wm_site_remove",
                "error": "WebMount station was not found",
                "site_id": siteId
            ])
        }
        let removed = registry.remove(id: siteId)
        settings.syncAllowedHosts(registry.sites.flatMap(\.allowedHosts))
        return Self.json([
            "ok": removed,
            "tool": "wm_site_remove",
            "site_id": siteId,
            "display_name": site.displayName,
            "removed": removed,
            "cookies_cleared": false,
            "allowlist_count": settings.allowedHosts.count,
            "redacted": true
        ])
    }

    private func siteFromArgs(_ args: [String: Any]) -> IOSWebMountSite? {
        if let siteId = (args["site_id"] as? String)?.nilIfBlank {
            return registry.site(id: siteId)
        }
        if let rawURL = args["url"] as? String,
           let url = URL(string: rawURL) {
            return registry.site(for: url)
        }
        return nil
    }

    private static func looksSensitiveSelector(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return ["password", "passwd", "token", "csrf", "xsrf", "secret", "cookie", "authorization", "auth"].contains { marker in
            lowercased.contains(marker)
        }
    }

    private static func webMountPostconditionOptions(from args: [String: Any]) -> [String: Any]? {
        guard let raw = args["postcondition"] as? [String: Any],
              let condition = (raw["condition"] as? String)?.nilIfBlank?.lowercased(),
              ["selector", "text", "url_contains", "ready_state", "dom_stable"].contains(condition) else {
            return nil
        }
        let value = (raw["value"] as? String)?.nilIfBlank
        if condition != "dom_stable", value == nil {
            return nil
        }
        if condition == "ready_state",
           !["interactive", "complete"].contains(value?.lowercased() ?? "") {
            return nil
        }
        var options: [String: Any] = ["condition": condition]
        switch condition {
        case "selector": options["selector"] = value
        case "text": options["text"] = value
        case "url_contains": options["url_contains"] = value
        case "ready_state": options["ready_state"] = value
        default: break
        }
        if let timeout = (raw["timeout_ms"] as? Int)
            ?? (raw["timeout_ms"] as? NSNumber)?.intValue {
            options["wait_ms"] = timeout.clamped(to: 100...30_000)
        }
        return options
    }

    private static func webMountRemotePostconditionOptions(from args: [String: Any]) -> [String: Any]? {
        guard var options = webMountPostconditionOptions(from: args) else { return nil }
        if let timeout = options.removeValue(forKey: "wait_ms") {
            options["timeout_ms"] = timeout
        } else {
            options["timeout_ms"] = 5_000
        }
        return options
    }

    private static func webMountStateDiff(before: [String: Any], after: [String: Any]) -> [String: Any] {
        let keys = ["url", "title", "ready_state", "text_length", "links_count"]
        let changedFields = keys.filter { key in
            String(describing: before[key] ?? NSNull()) != String(describing: after[key] ?? NSNull())
        }
        return [
            "changed": !changedFields.isEmpty,
            "changed_fields": changedFields,
            "revision_changed": String(describing: before["snapshot_id"] ?? NSNull()) != String(describing: after["snapshot_id"] ?? NSNull())
        ]
    }

    private static func parseObject(_ input: String) -> [String: Any] {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    nonisolated static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"Failed to encode WebMount result"}"#
        }
        return string
    }
}

enum IOSWebMountRedactor {
    static func redactedURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.nilIfBlank != nil else {
            return "[redacted-url]"
        }
        var safe = URLComponents()
        safe.scheme = scheme
        safe.host = components.host
        safe.port = components.port
        let path = components.path.isEmpty ? "/" : components.path
        let sensitivePathMarkers = [
            "token", "oauth", "callback", "verify", "verification", "reset",
            "recovery", "magic", "authorize", "authentication", "session"
        ]
        safe.path = sensitivePathMarkers.contains(where: { path.lowercased().contains($0) })
            ? "/redacted"
            : path
        return safe.string
    }

    static func redactedJSONObject(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, item) in dict {
                let loweredKey = key.lowercased()
                if isSensitiveKey(loweredKey) {
                    redacted[key] = "***redacted***"
                } else if loweredKey.contains("url") || loweredKey == "href" || loweredKey == "src",
                          let string = item as? String {
                    redacted[key] = redactedURL(string) ?? string
                } else {
                    redacted[key] = redactedJSONObject(item)
                }
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map(redactedJSONObject)
        }
        if let string = value as? String {
            return redactedText(string)
        }
        return value
    }

    static func redactedText(_ value: String) -> String {
        var output = value
        output = replacingMatches(
            in: output,
            pattern: #"https?://[^\s"'<>)]+"#,
            options: [.caseInsensitive]
        ) { match in
            redactedURL(match) ?? "[redacted-url]"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{6,}"#
        ) { _ in
            "Bearer ***redacted***"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)["']?\b(authorization|auth|token|access_token|refresh_token|auth_token|csrf|xsrf|session|secret|password|passcode|otp|totp|mfa|2fa|captcha|card_number|card.?number|pan|cvv|cvc|security.?code|payment|billing)["']?\s*[:=]\s*["']?[^&,\s"'<>)}\]]+"#,
            options: [.caseInsensitive]
        ) { match in
            let separatorIndex = match.firstIndex(where: { $0 == ":" || $0 == "=" })
            let prefix = separatorIndex.map { String(match[...$0]) } ?? "secret:"
            return "\(prefix) ***redacted***"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)(\b(?:otp|totp|mfa|2fa|passcode|verification\s*code|security\s*code|captcha)\b|验证码|校验码|动态码)\s*[:：=\-]?\s*\d{4,10}"#
        ) { match in
            let label = match.prefix { !$0.isNumber }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(label) ***redacted***"
        }
        output = replacingMatches(
            in: output,
            pattern: #"(?i)(\b(?:card(?:\s*number)?|credit\s*card|pan|cvv|cvc|security\s*code)\b|卡号|安全码)\s*[:：=\-]?\s*(?:\d[\s-]?){3,19}"#
        ) { match in
            let label = match.prefix { !$0.isNumber }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(label) ***redacted***"
        }
        return output
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let compact = String(key.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        if [
            "authorization", "auth", "token", "accesstoken", "refreshtoken", "authtoken",
            "cookie", "secret", "password", "passcode", "otp", "otpcode", "totp", "mfa", "2fa",
            "captcha", "verificationcode", "card", "cardnumber", "pan", "cvv", "cvv2", "cvc",
            "securitycode", "payment", "billing", "billingaddress"
        ].contains(compact) || ["验证码", "校验码", "动态码", "卡号", "安全码"].contains(where: compact.contains) {
            return true
        }
        return compact.hasSuffix("token") ||
            compact.hasSuffix("secret") ||
            compact.hasSuffix("password") ||
            compact.hasSuffix("otp") ||
            (compact.hasSuffix("code") && [
                "verification", "security", "mfa", "2fa", "captcha"
            ].contains { compact.contains($0) }) ||
            compact.hasSuffix("card") ||
            compact.hasSuffix("pan") ||
            compact.hasSuffix("cvv") ||
            compact.hasSuffix("cvc")
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }
        var output = value
        for match in matches.reversed() {
            let original = nsValue.substring(with: match.range)
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: transform(original))
            }
        }
        return output
    }
}

enum IOSWebMountClock {
    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private extension IOSWebMountRuntimeSnapshot {
    func dictionary(redactURLs: Bool) -> [String: Any] {
        [
            "session_id": sessionId,
            "status": status.rawValue,
            "requested_url": redactURLs ? (IOSWebMountRedactor.redactedURL(requestedURL) ?? "") : (requestedURL ?? ""),
            "current_url": redactURLs ? (IOSWebMountRedactor.redactedURL(currentURL) ?? "") : (currentURL ?? ""),
            "title": redactURLs ? IOSWebMountRedactor.redactedText(title ?? "") : (title ?? ""),
            "estimated_progress": estimatedProgress,
            "can_go_back": canGoBack,
            "can_go_forward": canGoForward,
            "error": redactURLs ? IOSWebMountRedactor.redactedText(error ?? "") : (error ?? ""),
            "updated_at_ms": updatedAtMillis
        ]
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
