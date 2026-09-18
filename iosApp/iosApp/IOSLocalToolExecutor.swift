import Foundation
import Darwin
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
        now: Date = Date(),
        visualRead: IOSWebMountVisualReadHandler? = nil
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
                if !request.isUserInitiated,
                   ["wm_site_add", "wm_site_remove"].contains(request.toolName) {
                    return .needsUserAction("修改站点列表需要你确认；高风险浏览可直接访问公共网站，无需添加白名单。")
                }
                let output = await webMountController.execute(
                    toolName: request.toolName,
                    input: request.operation,
                    // This flag grants approval; the unchanged context still
                    // identifies the caller as an agent for session ownership.
                    isUserInitiated: request.isUserInitiated || webMountAllowsUnlistedHosts(
                        request: request,
                        capability: capability
                    ),
                    context: webMountContext,
                    allowUnlistedHosts: webMountAllowsUnlistedHosts(
                        request: request,
                        capability: capability
                    ),
                    visualRead: visualRead
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
        if policy == .autoApproveHighRisk
            || (executionPolicy?.highRiskAutoApproveEnabled ?? Self.isHighRiskAutoApproveEnabled) {
            return .allow(capabilityId: capability.id)
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
        conversationId: String,
        executionPolicy: IOSExecutionPolicySnapshot? = nil
    ) async -> String? {
        // Execution still checks targets and human handoff. Auto-approved
        // recipes do not need a separate approval-only preflight.
        if let capability = IOSCapabilityRegistry.capability(forToolName: toolName),
           (executionPolicy?.policy(for: capability) ?? permissionStore.policy(for: capability)) == .autoApproveHighRisk
            || (executionPolicy?.highRiskAutoApproveEnabled ?? Self.isHighRiskAutoApproveEnabled) {
            return nil
        }
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
        case "wm_visual_read": "截图并调用视觉模型验证页面"
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
        case "wm_visual_read":
            return "会将当前页面截图发送给已配置的视觉模型服务商进行分析，截图可能包含页面中的敏感信息。不会自动点击或提交表单。"
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
                allowedHosts: [
                    "m.weibo.cn", "weibo.cn", "weibo.com", "www.weibo.com",
                    "passport.weibo.cn", "visitor.passport.weibo.cn", "passport.weibo.com",
                    "security.weibo.com", "login.sina.com.cn", "passport.sinaimg.cn"
                ],
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
                let migrationKey = storageKey + ".weiboLoginHosts.v1"
                if !userDefaults.bool(forKey: migrationKey) {
                    if let index = sites.firstIndex(where: {
                        $0.id == "weibo" && ["m.weibo.cn", "weibo.cn", "weibo.com", "www.weibo.com"].contains($0.homepageHost)
                    }), let seed = IOSWebMountSite.seeds().first(where: { $0.id == "weibo" }) {
                        sites[index].allowedHosts = (sites[index].allowedHosts + seed.allowedHosts).uniqued()
                        if let data = try? encoder.encode(sites) { userDefaults.set(data, forKey: storageKey) }
                    }
                    userDefaults.set(true, forKey: migrationKey)
                }
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
    case hostResolutionFailed(String)
    case resolvedHostNotPublic(String)
    case fakeIPPublicDNSFailed(String)
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
        case .hostResolutionFailed(let host):
            "DNS resolution failed or returned no addresses for: \(host). Check DNS and VPN/proxy settings. Navigation to this host was blocked."
        case .resolvedHostNotPublic(let host):
            "DNS returned a non-public or reserved address for: \(host). Fake-IP compatibility requires HTTPS, standard 198.18.0.0/15 answers without other private addresses, and successful public DNS verification."
        case .fakeIPPublicDNSFailed(let host):
            "VPN Fake-IP was detected, but encrypted public DNS verification failed for: \(host). Navigation was blocked; check network access to the public DNS resolver."
        case .navigationTargetNotVerified(let host):
            "Navigation target was not verified before commit: \(host)"
        case .hostNotAllowed(let host):
            "Host is not in the WebMount allowlist: \(host)"
        }
    }

    var errorCode: String {
        switch self {
        case .invalidURL: "invalid_url"
        case .unsupportedScheme: "unsupported_scheme"
        case .missingHost: "missing_host"
        case .embeddedCredentialsNotAllowed: "embedded_credentials_not_allowed"
        case .privateHostNotAllowed: "private_host_not_allowed"
        case .hostResolutionFailed: "dns_resolution_failed"
        case .resolvedHostNotPublic: "dns_non_public_address"
        case .fakeIPPublicDNSFailed: "fake_ip_public_dns_failed"
        case .navigationTargetNotVerified: "navigation_target_not_verified"
        case .hostNotAllowed: "host_not_allowed"
        }
    }
}

typealias IOSWebMountHostResolver = @Sendable (String) throws -> [String]
typealias IOSWebMountPublicHostResolver = @Sendable (String) async throws -> [String]

struct IOSWebMountURLPolicy {
    let allowedSchemes: Set<String>
    let allowedHosts: Set<String>
    private(set) var allowUnlistedHosts: Bool
    private(set) var allowFakeIPFallback: Bool
    private let resolvePublicHost: IOSWebMountPublicHostResolver

    @MainActor
    init(
        settings: IOSWebMountSettings,
        extraAllowedHosts: [String] = [],
        allowUnlistedHosts: Bool = false,
        allowFakeIPFallback: Bool = false,
        resolvePublicHost: @escaping IOSWebMountPublicHostResolver = IOSWebMountPublicDNS.resolve
    ) {
        self.allowedSchemes = Set(settings.allowedSchemes.map { $0.lowercased() })
        self.allowedHosts = Set(settings.allowedHosts.map { $0.lowercased() })
            .union(extraAllowedHosts.compactMap(Self.normalizedHost))
        self.allowUnlistedHosts = allowUnlistedHosts
        self.allowFakeIPFallback = allowFakeIPFallback
        self.resolvePublicHost = resolvePublicHost
    }

    func allowingPublicUserNavigation() -> Self {
        var policy = self
        policy.allowUnlistedHosts = true
        policy.allowFakeIPFallback = true
        return policy
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
            // Auto-approval expands access to unlisted hosts; it must preserve
            // the existing allowlist path for registered sites behind proxy DNS.
            let registeredHosts = allowedHosts.union(site?.allowedHosts.compactMap(Self.normalizedHost) ?? [])
            if Self.host(host, matchesAnyOf: Array(registeredHosts)) {
                return .success(url)
            }
            do {
                let addresses = try await Task.detached(priority: .userInitiated) {
                    try resolveHost(host)
                }.value
                guard !addresses.isEmpty else {
                    return .failure(.hostResolutionFailed(host))
                }
                if addresses.allSatisfy(Self.isPublicAddress) {
                    return .success(url)
                }
                // Fake-IP is a VPN routing token, not evidence of a public destination.
                // In the existing high-risk preflight model, validate HTTPS hostnames
                // independently and continue trusting the user's VPN hostname routing.
                // This is not socket/IP pinning; never use it for plaintext HTTP.
                guard allowFakeIPFallback, url.scheme?.lowercased() == "https",
                      addresses.contains(where: Self.isStandardFakeIPAddress),
                      addresses.allSatisfy({ Self.isStandardFakeIPAddress($0) || Self.isPublicAddress($0) }) else {
                    return .failure(.resolvedHostNotPublic(host))
                }
                do {
                    let publicAddresses = try await resolvePublicHost(host)
                    guard !publicAddresses.isEmpty, publicAddresses.allSatisfy(Self.isPublicAddress) else {
                        return .failure(.fakeIPPublicDNSFailed(host))
                    }
                    return .success(url)
                } catch {
                    return .failure(.fakeIPPublicDNSFailed(host))
                }
            } catch {
                return .failure(.hostResolutionFailed(host))
            }
        }
    }

    private static func isPublicAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return (inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1)
            && IOSSearchExecutor.publicHostAllowed(value)
    }

    private static func isStandardFakeIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, value, &ipv4) == 1 else { return false }
        return UInt32(bigEndian: ipv4.s_addr) & 0xfffe0000 == 0xc6120000
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

typealias IOSWebMountVisualReadHandler = @MainActor (IOSWebMountScreenshotCapture, String) async throws -> String

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
            "dom_revision": interactive["dom_revision"] ?? page["dom_revision"] ?? 0,
            "url_revision": interactive["url_revision"] ?? page["url_revision"] ?? 0,
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
struct IOSWebMountBrowserDialog: Identifiable {
    enum Kind { case alert, confirm, prompt }
    let id = UUID()
    let kind: Kind
    let message: String
    let host: String
    let defaultText: String
}

@MainActor
final class IOSWebMountWKRuntime: NSObject, ObservableObject, IOSWebMountRuntimeServicing, WKNavigationDelegate, WKUIDelegate {
    static let automationContentWorld = WKContentWorld.world(name: "app.amber.webmount.automation")

    let webView: WKWebView?
    @Published private(set) var snapshot: IOSWebMountRuntimeSnapshot
    @Published private(set) var popupWebViews: [WKWebView] = []
    @Published private(set) var popupNavigationRevision = 0
    @Published private(set) var browserDialog: IOSWebMountBrowserDialog?
    @Published var browserNotice: String?
    private var browserDialogCompletion: ((String?) -> Void)?
    private weak var browserDialogWebView: WKWebView?
    private var browserPresentationHosts: Set<UUID> = []
    private var isClosed = false
    private var popupApprovedDestinations: [ObjectIdentifier: String] = [:]
    private var popupPolicyRevision = 0

    private var loadSequence = 0
    private var pendingLoad: (id: Int, continuation: CheckedContinuation<IOSWebMountRuntimeSnapshot, Never>)?
    private var pendingLoadTimeoutTask: Task<Void, Never>?
    private var navigationPolicy: IOSWebMountURLPolicy?
    private(set) var userBrowsingEnabled = false
    private var effectiveNavigationPolicy: IOSWebMountURLPolicy? {
        userBrowsingEnabled ? navigationPolicy?.allowingPublicUserNavigation() : navigationPolicy
    }

    func setUserBrowsingEnabled(_ enabled: Bool) {
        guard !isClosed || !enabled else { return }
        guard userBrowsingEnabled != enabled else { return }
        userBrowsingEnabled = enabled
        invalidateNavigationDecisions()
        if !enabled {
            cancelBrowserPresentation()
            for popup in popupWebViews { closePopup(popup) }
        }
    }

    func invalidateNavigationDecisions() {
        navigationDecisionSequence += 1
        popupPolicyRevision += 1
        popupApprovedDestinations.removeAll()
        approvedMainFrameDestination = nil
    }

    func closeSession() {
        isClosed = true
        setUserBrowsingEnabled(false)
        invalidateNavigationDecisions()
        browserPresentationHosts.removeAll()
        cancelBrowserPresentation()
        for popup in popupWebViews { closePopup(popup) }
        webView?.stopLoading()
        webView?.isUserInteractionEnabled = false
        snapshot.status = .failed
        snapshot.error = "站点会话已关闭。"
        completePendingLoad()
    }

    private var navigationSite: IOSWebMountSite?
    private var navigationHostResolver: IOSWebMountHostResolver = IOSSearchExecutor.resolveIPAddresses
    private var navigationDecisionSequence = 0
    private var approvedMainFrameDestination: String?
    private var fragmentNavigationTarget: URL?
    private var verifiedFragmentLoadId: Int?
    private var urlObservation: NSKeyValueObservation?
    private var subframeNavigationDenialCount = 0
    private var lastSubframeNavigationDenial: [String: Any]?
    private static let maxNavigationEvents = 8
    private var navigationEvents: [[String: Any]] = []

    override convenience init() {
        self.init(sessionId: nil)
    }

    init(sessionId: String?) {
        let resolvedSessionId = sessionId?.nilIfBlank
            ?? "ios_wm_" + String(UUID().uuidString.prefix(8))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Agent-owned sessions can stay detached from SwiftUI's foreground layout.
        // Give those sessions a real viewport; a mounted view will replace this
        // frame through its normal layout pass.
        let webView = WKWebView(frame: UIScreen.main.bounds, configuration: configuration)
        self.webView = webView
        self.snapshot = .idle(sessionId: resolvedSessionId)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, let webView = self.webView else { return }
                if let target = self.fragmentNavigationTarget,
                   let pendingLoad = self.pendingLoad,
                   self.verifiedFragmentLoadId == pendingLoad.id,
                   webView.url == target {
                    self.finishNavigation(webView)
                } else if self.snapshot.status == .ready,
                          let currentURL = self.snapshot.currentURL.flatMap(URL.init(string:)),
                          let url = webView.url,
                          let origin = Self.navigationDestinationKey(currentURL),
                          origin == Self.navigationDestinationKey(url) {
                    // History API and hash changes stay within the loaded origin
                    // and may not trigger didCommit/didFinish.
                    self.snapshot.currentURL = IOSWebMountRedactor.redactedURL(url.absoluteString)
                    self.snapshot.canGoBack = webView.canGoBack
                    self.snapshot.canGoForward = webView.canGoForward
                    self.snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
                }
            }
        }
    }

    func setNavigationPolicy(
        _ policy: IOSWebMountURLPolicy,
        site: IOSWebMountSite?,
        resolveHost: @escaping IOSWebMountHostResolver = IOSSearchExecutor.resolveIPAddresses
    ) {
        let policyChanged = navigationPolicy?.allowedSchemes != policy.allowedSchemes
            || navigationPolicy?.allowedHosts != policy.allowedHosts
            || navigationPolicy?.allowUnlistedHosts != policy.allowUnlistedHosts
            || navigationPolicy?.allowFakeIPFallback != policy.allowFakeIPFallback
            || navigationSite != site
        navigationPolicy = policy
        navigationSite = site
        navigationHostResolver = resolveHost
        navigationDecisionSequence += 1
        approvedMainFrameDestination = nil
        if policyChanged {
            invalidateNavigationDecisions()
            resetNavigationDiagnostics()
        }
    }

    func open(_ url: URL, timeoutMillis: UInt64 = 30_000) async -> IOSWebMountRuntimeSnapshot {
        guard !isClosed else { return snapshot }
        guard let webView else {
            snapshot.status = .failed
            snapshot.error = "WKWebView is unavailable"
            return snapshot
        }
        cancelBrowserPresentation()
        for popup in popupWebViews { closePopup(popup) }
        browserNotice = nil
        pendingLoadTimeoutTask?.cancel()
        pendingLoadTimeoutTask = nil
        loadSequence += 1
        let loadId = loadSequence
        pendingLoad?.continuation.resume(returning: snapshot)
        pendingLoad = nil
        fragmentNavigationTarget = nil
        verifiedFragmentLoadId = nil
        if !webView.isLoading, let currentURL = webView.url,
           currentURL != url || url.fragment != nil,
           var currentDocument = URLComponents(url: currentURL, resolvingAgainstBaseURL: true),
           var requestedDocument = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            currentDocument.fragment = nil
            requestedDocument.fragment = nil
            if currentDocument == requestedDocument {
                fragmentNavigationTarget = url
            }
        }
        resetNavigationDiagnostics()
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
        return await withCheckedContinuation { continuation in
            pendingLoad = (loadId, continuation)
            if fragmentNavigationTarget == nil {
                webView.load(URLRequest(url: url))
            } else {
                let decisionSequence = navigationDecisionSequence
                Task { @MainActor [weak self] in
                    guard let self, self.pendingLoad?.id == loadId else { return }
                    // WebKit may omit navigation delegate callbacks for fragments.
                    // Verify these destinations before loading, including no-op retries.
                    if self.fragmentNavigationTarget != nil, let policy = self.effectiveNavigationPolicy {
                        let result = await policy.validateResolvedPublicHost(
                            url.absoluteString,
                            site: self.navigationSite,
                            resolveHost: self.navigationHostResolver
                        )
                        guard self.pendingLoad?.id == loadId else { return }
                        guard self.navigationDecisionSequence == decisionSequence else {
                            self.rejectNavigation(.navigationTargetNotVerified(url.host ?? ""), url: url, webView: webView)
                            return
                        }
                        switch result {
                        case .success(let verifiedURL):
                            self.approvedMainFrameDestination = Self.navigationDestinationKey(verifiedURL)
                        case .failure(let error):
                            self.rejectNavigation(error, url: url, webView: webView)
                            return
                        }
                    }
                    guard self.pendingLoad?.id == loadId else { return }
                    self.verifiedFragmentLoadId = loadId
                    if self.fragmentNavigationTarget != nil, webView.url == url {
                        self.finishNavigation(webView)
                    } else {
                        webView.load(URLRequest(url: url))
                    }
                }
            }
            pendingLoadTimeoutTask = Task { @MainActor [weak self] in
                let nanos = timeoutMillis * 1_000_000
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return
                }
                guard let self,
                      let pendingLoad = self.pendingLoad,
                      pendingLoad.id == loadId else { return }
                self.pendingLoadTimeoutTask = nil
                self.snapshot.status = .failed
                self.snapshot.error = "load timed out after \(timeoutMillis)ms"
                self.snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
                self.pendingLoad = nil
                pendingLoad.continuation.resume(returning: self.snapshot)
            }
        }
    }

    func state() async throws -> [String: Any] {
        var bridgeState = try await evaluateJSON(IOSWebMountBridgeScripts.state)
        bridgeState["navigation_diagnostics"] = navigationDiagnostics
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
        var page = (observation["page"] as? [String: Any] ?? [:])
            .merging(snapshot.dictionary(redactURLs: true)) { page, _ in page }
        page["navigation_diagnostics"] = navigationDiagnostics
        observation["page"] = page
        observation["navigation_diagnostics"] = navigationDiagnostics
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
            let selectorTarget = selector?.nilIfBlank
            let optionSelector = (waitOptions["selector"] as? String)?.nilIfBlank
            let optionTarget = (options["target"] as? String)?.nilIfBlank
            let providedTargets = [selectorTarget, optionSelector, optionTarget].compactMap { $0 }
            if Set(providedTargets).count > 1 {
                return [
                    "ok": false,
                    "method": "wait",
                    "error_code": "conflicting_target_arguments",
                    "matched": false,
                    "dispatched": false,
                    "navigation_diagnostics": navigationDiagnostics
                ]
            }
            if optionSelector == nil, let selectorTarget {
                waitOptions["selector"] = selectorTarget
            }
            if (waitOptions["selector"] as? String)?.nilIfBlank == nil, let optionTarget {
                waitOptions["selector"] = optionTarget
            }
            var result = await waitForCondition(options: waitOptions)
            result["navigation_diagnostics"] = navigationDiagnostics
            return result
        }
        var result = try await evaluateJSON(
            IOSWebMountBridgeScripts.interact(
                method: method,
                selector: selector,
                text: text,
                options: options
            )
        )
        result["navigation_diagnostics"] = navigationDiagnostics
        return result
    }

    private func waitForCondition(options: [String: Any]) async -> [String: Any] {
        let condition = ((options["condition"] as? String)?.nilIfBlank ?? "dom_stable").lowercased()
        let supported = Set([
            "dom_stable", "selector", "text", "url_contains", "ready_state", "delay",
            "document_changed", "url_changed"
        ])
        guard supported.contains(condition) else {
            return [
                "ok": false,
                "method": "wait",
                "error_code": "unsupported_wait_condition",
                "condition": condition
            ]
        }
        let beforeDocumentId = (options["before_document_id"] as? String)?.nilIfBlank
        let beforeURL = (options["before_url"] as? String)?.nilIfBlank
        let beforeURLRevision = (options["before_url_revision"] as? Int)
            ?? (options["before_url_revision"] as? NSNumber)?.intValue
            ?? (options["before_url_revision"] as? Double).map(Int.init)
        let beforeDOMRevision = (options["before_dom_revision"] as? Int)
            ?? (options["before_dom_revision"] as? NSNumber)?.intValue
            ?? (options["before_dom_revision"] as? Double).map(Int.init)
        let requirePageChange = options["require_page_change"] as? Bool ?? false
        let requiredArgument: String?
        switch condition {
        case "selector": requiredArgument = (options["selector"] as? String)?.nilIfBlank
        case "text": requiredArgument = (options["text"] as? String)?.nilIfBlank
        case "url_contains": requiredArgument = (options["url_contains"] as? String)?.nilIfBlank
        case "ready_state": requiredArgument = (options["ready_state"] as? String)?.nilIfBlank
        case "document_changed": requiredArgument = beforeDocumentId
        case "url_changed": requiredArgument = beforeURL != nil || (beforeURLRevision != nil && beforeDocumentId != nil) ? "baseline" : nil
        default: requiredArgument = "not-required"
        }
        guard requiredArgument != nil else {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": ["document_changed", "url_changed"].contains(condition)
                    ? "missing_wait_baseline"
                    : "missing_wait_argument",
                "matched": false
            ]
        }
        if requirePageChange && beforeDocumentId == nil && beforeURL == nil && beforeURLRevision == nil && beforeDOMRevision == nil {
            return [
                "ok": false,
                "method": "wait",
                "condition": condition,
                "error_code": "missing_wait_baseline",
                "matched": false,
                "require_page_change": true
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
                    var result = boundedWaitProbe(probe)
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
                    let pageChanged = probe["page_changed"] as? Bool ?? false
                    if snapshotId == lastSnapshotId,
                       readyState != "loading",
                       !requirePageChange || pageChanged {
                        stableSince = stableSince ?? Date()
                        if let stableSince,
                           Date().timeIntervalSince(stableSince) * 1_000 >= Double(stableMillis) {
                            var result = boundedWaitProbe(probe)
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
                    var result = boundedWaitProbe(probe)
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
                    "last_error": IOSWebMountRedactor.redactedText(lastError ?? ""),
                    "last_probe": boundedWaitProbe(lastProbe),
                    "require_page_change": requirePageChange
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

    private func boundedWaitProbe(_ probe: [String: Any]) -> [String: Any] {
        let allowedKeys: Set<String> = [
            "ok", "matched", "error_code", "ready_state", "url", "document_id",
            "page_revision", "dom_revision", "snapshot_id", "document_changed",
            "url_revision", "url_changed", "dom_changed", "page_changed", "condition_matched", "require_page_change",
            "before_document_id", "before_url", "before_url_revision", "before_dom_revision"
        ]
        var result: [String: Any] = [:]
        for (key, value) in probe where allowedKeys.contains(key) {
            if key == "url" || key == "before_url", let rawURL = value as? String {
                result[key] = IOSWebMountRedactor.redactedURL(rawURL) ?? ""
            } else {
                result[key] = value
            }
        }
        return result
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
        guard !isClosed else { decisionHandler(.cancel); return }
        if webView !== self.webView {
            validatePopupNavigation(navigationAction.request.url, in: webView,
                                    mainFrame: navigationAction.targetFrame?.isMainFrame == true) { allowed in
                decisionHandler(allowed ? .allow : .cancel)
            }
            return
        }
        if let target = navigationAction.request.url?.absoluteString,
           (navigationAction.targetFrame == nil && target == "about:blank") ||
            (navigationAction.targetFrame?.isMainFrame == false && ["about:blank", "about:srcdoc"].contains(target)) {
            // Local documents used to bootstrap login windows and embedded forms
            // have no network host; their subsequent navigations still use policy.
            decisionHandler(.allow)
            return
        }
        guard let policy = effectiveNavigationPolicy,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let site = navigationSite
        let resolver = navigationHostResolver
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
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
                } else if !isMainFrame, decisionSequence == self.navigationDecisionSequence {
                    self.recordNavigationEvent(
                        kind: "navigation_policy_denied",
                        decision: "cancel",
                        url: url,
                        errorCode: error.errorCode,
                        reason: error.localizedDescription,
                        frame: "subframe"
                    )
                    self.recordSubframeNavigationDenial(error, url: url)
                }
                decisionHandler(.cancel)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard popupWebViews.count < 4 else {
            reportPopupFailure("打开的窗口过多，请先关闭不用的窗口。", url: navigationAction.request.url,
                               errorCode: "popup_limit_reached")
            return nil
        }
        // WebKit's supplied configuration preserves window.opener, POST bodies
        // and the opener's cookie store; loading this URL in the parent breaks SSO.
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        popupWebViews.append(popup)
        recordNavigationEvent(kind: "new_window_request", decision: "opened", url: navigationAction.request.url)
        return popup
    }

    func closePopup(_ popup: WKWebView) {
        guard popupWebViews.contains(where: { $0 === popup }) else { return }
        if browserDialogWebView === popup { cancelBrowserPresentation() }
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popupApprovedDestinations.removeValue(forKey: ObjectIdentifier(popup))
        popupWebViews.removeAll { $0 === popup }
    }

    func cancelBrowserPresentation() {
        resolveBrowserDialog(nil)
    }

    func setBrowserPresentationAvailable(_ available: Bool, hostID: UUID) {
        guard !isClosed else { return }
        if available {
            browserPresentationHosts.insert(hostID)
        } else {
            browserPresentationHosts.remove(hostID)
            if browserPresentationHosts.isEmpty { cancelBrowserPresentation() }
        }
    }

    func cancelPopupDialogs() {
        if browserDialogWebView != nil && browserDialogWebView !== webView { resolveBrowserDialog(nil) }
    }

    func resolveBrowserDialog(_ response: String?, dialogID: UUID? = nil) {
        if let dialogID, browserDialog?.id != dialogID { return }
        let completion = browserDialogCompletion
        browserDialogCompletion = nil
        browserDialogWebView = nil
        browserDialog = nil
        completion?(response)
    }

    private func presentBrowserDialog(
        kind: IOSWebMountBrowserDialog.Kind,
        webView: WKWebView,
        message: String,
        frame: WKFrameInfo,
        defaultText: String = "",
        completion: @escaping (String?) -> Void
    ) {
        guard userBrowsingEnabled, !browserPresentationHosts.isEmpty else {
            browserNotice = userBrowsingEnabled
                ? "网页需要你确认或输入，请返回页面后重新操作。"
                : "网页需要你确认或输入，请接管页面后重新操作。"
            recordNavigationEvent(kind: "javascript_dialog", decision: "requires_user_control",
                                  url: frame.request.url, errorCode: "user_control_required")
            completion(nil)
            return
        }
        guard browserDialog == nil else {
            completion(nil)
            return
        }
        browserDialogCompletion = completion
        browserDialogWebView = webView
        browserDialog = IOSWebMountBrowserDialog(
            kind: kind, message: message, host: frame.securityOrigin.host, defaultText: defaultText
        )
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        presentBrowserDialog(kind: .alert, webView: webView, message: message, frame: frame) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        presentBrowserDialog(kind: .confirm, webView: webView, message: message, frame: frame) { completionHandler($0 != nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        presentBrowserDialog(kind: .prompt, webView: webView, message: prompt, frame: frame,
                             defaultText: defaultText ?? "", completion: completionHandler)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(webView)
    }

    private func validatePopupNavigation(
        _ url: URL?, in popup: WKWebView, mainFrame: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard popupWebViews.contains(where: { $0 === popup }), let url else {
            completion(false)
            return
        }
        // A newly created window needs its inherited, empty document before a
        // login script can assign its URL. Every network destination is checked.
        if url.absoluteString == "about:blank" || (!mainFrame && url.absoluteString == "about:srcdoc") {
            completion(true)
            return
        }
        guard let policy = effectiveNavigationPolicy else {
            completion(true)
            return
        }
        let site = navigationSite
        let revision = popupPolicyRevision
        let resolver = navigationHostResolver
        Task { @MainActor [weak self, weak popup] in
            let result = await policy.validateResolvedPublicHost(url.absoluteString, site: site, resolveHost: resolver)
            guard let self, let popup,
                  self.popupWebViews.contains(where: { $0 === popup }),
                  revision == self.popupPolicyRevision else {
                completion(false)
                return
            }
            switch result {
            case .success(let verifiedURL):
                if mainFrame {
                    self.popupApprovedDestinations[ObjectIdentifier(popup)] = Self.navigationDestinationKey(verifiedURL)
                }
                completion(true)
            case .failure(let error):
                self.reportPopupFailure(error.localizedDescription, url: url, errorCode: error.errorCode)
                completion(false)
            }
        }
    }

    private func reportPopupFailure(_ message: String, url: URL?, errorCode: String? = nil) {
        browserNotice = "登录窗口：" + IOSWebMountRedactor.redactedText(message)
        recordNavigationEvent(kind: "popup_navigation", decision: "cancel", url: url,
                              errorCode: errorCode, reason: message, frame: "popup")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard !isClosed else { decisionHandler(.cancel); return }
        if webView !== self.webView {
            guard navigationResponse.canShowMIMEType else {
                reportPopupFailure("此窗口不支持下载文件。", url: navigationResponse.response.url)
                decisionHandler(.cancel)
                return
            }
            validatePopupNavigation(navigationResponse.response.url, in: webView,
                                    mainFrame: navigationResponse.isForMainFrame) { allowed in
                decisionHandler(allowed ? .allow : .cancel)
            }
            return
        }
        if !navigationResponse.canShowMIMEType {
            recordNavigationEvent(
                kind: "download",
                decision: "cancel",
                url: navigationResponse.response.url,
                errorCode: "download_unsupported",
                reason: "WebMount does not automatically download navigation responses."
            )
            decisionHandler(.cancel)
            return
        }
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        guard let policy = effectiveNavigationPolicy else {
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
        guard !isClosed else { return }
        if browserDialogWebView === webView { cancelBrowserPresentation() }
        guard webView === self.webView else { return }
        snapshot.status = .loading
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.error = nil
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isClosed else { return }
        if webView !== self.webView {
            objectWillChange.send()
            guard let policy = effectiveNavigationPolicy, let url = webView.url,
                  url.absoluteString != "about:blank" else { return }
            guard case .success = policy.validate(url.absoluteString, site: navigationSite),
                  let destination = Self.navigationDestinationKey(url),
                  popupApprovedDestinations[ObjectIdentifier(webView)] == destination else {
                webView.stopLoading()
                reportPopupFailure("窗口跳转尚未通过验证。", url: url, errorCode: "navigation_target_not_verified")
                return
            }
            return
        }
        guard committedNavigationIsAllowed(webView) else { return }
        snapshot.currentURL = IOSWebMountRedactor.redactedURL(webView.url?.absoluteString)
        snapshot.estimatedProgress = webView.estimatedProgress
        snapshot.canGoBack = webView.canGoBack
        snapshot.canGoForward = webView.canGoForward
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        guard webView === self.webView else {
            popupNavigationRevision += 1
            return
        }
        finishNavigation(webView)
    }

    private func finishNavigation(_ webView: WKWebView) {
        if let target = fragmentNavigationTarget, let pendingLoad {
            guard verifiedFragmentLoadId == pendingLoad.id, webView.url == target else { return }
        }
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
        if webView !== self.webView {
            if (error as NSError).code != NSURLErrorCancelled {
                reportPopupFailure(error.localizedDescription, url: webView.url)
            }
            return
        }
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView !== self.webView {
            if (error as NSError).code != NSURLErrorCancelled {
                reportPopupFailure(error.localizedDescription, url: webView.url)
            }
            return
        }
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView !== self.webView {
            closePopup(webView)
            reportPopupFailure("窗口进程已退出，请重新打开登录窗口。", url: webView.url)
            return
        }
        cancelBrowserPresentation()
        fail(NSError(
            domain: WKErrorDomain,
            code: WKError.Code.webContentProcessTerminated.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Web content process terminated. Reopen the page before continuing."]
        ))
    }

    private func fail(_ error: Error) {
        recordNavigationEvent(
            kind: "navigation_failure",
            decision: "failed",
            url: webView?.url,
            errorCode: nil,
            reason: error.localizedDescription
        )
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

    private var navigationDiagnostics: [String: Any] {
        var diagnostics: [String: Any] = [
            "open_window_count": popupWebViews.count,
            "dialog_pending": browserDialog != nil,
            "subframe_navigation_denied_count": subframeNavigationDenialCount,
            "recent_events": navigationEvents
        ]
        if let lastSubframeNavigationDenial {
            diagnostics["last_subframe_navigation_denial"] = lastSubframeNavigationDenial
        }
        return diagnostics
    }

    private func recordSubframeNavigationDenial(
        _ error: IOSWebMountURLPolicyError,
        url: URL
    ) {
        subframeNavigationDenialCount += 1
        browserNotice = "网页内嵌页面被阻止：" + (url.host ?? "") + " · " + error.localizedDescription
        lastSubframeNavigationDenial = [
            "frame": "subframe",
            "decision": "cancel",
            "url": IOSWebMountRedactor.redactedURL(url.absoluteString) ?? "",
            "host": IOSWebMountURLPolicy.normalizedHost(url.host) ?? "",
            "error_code": error.errorCode,
            "reason": error.localizedDescription,
            "count": subframeNavigationDenialCount
        ]
    }

    private func recordNavigationEvent(
        kind: String,
        decision: String,
        url: URL?,
        errorCode: String? = nil,
        reason: String? = nil,
        frame: String? = nil
    ) {
        var event: [String: Any] = [
            "kind": kind,
            "decision": decision,
            "at_ms": IOSWebMountClock.nowMillis()
        ]
        if let url {
            event["url"] = IOSWebMountRedactor.redactedURL(url.absoluteString) ?? ""
            event["host"] = IOSWebMountURLPolicy.normalizedHost(url.host) ?? ""
        }
        if let errorCode = errorCode?.nilIfBlank {
            event["error_code"] = errorCode
        }
        if let reason = reason?.nilIfBlank {
            event["reason"] = IOSWebMountRedactor.redactedText(reason)
        }
        if let frame = frame?.nilIfBlank {
            event["frame"] = frame
        }
        navigationEvents.append(event)
        if navigationEvents.count > Self.maxNavigationEvents {
            navigationEvents.removeFirst(navigationEvents.count - Self.maxNavigationEvents)
        }
    }

    private func resetNavigationDiagnostics() {
        subframeNavigationDenialCount = 0
        lastSubframeNavigationDenial = nil
        navigationEvents.removeAll(keepingCapacity: true)
    }

    private func committedNavigationIsAllowed(_ webView: WKWebView) -> Bool {
        guard let policy = effectiveNavigationPolicy, let url = webView.url else { return true }
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
        recordNavigationEvent(
            kind: "navigation_policy_denied",
            decision: "cancel",
            url: url,
            errorCode: error.errorCode,
            reason: error.localizedDescription,
            frame: "main"
        )
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
        pendingLoadTimeoutTask?.cancel()
        pendingLoadTimeoutTask = nil
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        fragmentNavigationTarget = nil
        pendingLoad.continuation.resume(returning: snapshot)
    }

    private func evaluateJSON(_ script: String) async throws -> [String: Any] {
        guard !isClosed else { return ["ok": false, "error_code": "session_closed", "reason": "站点会话已关闭。"] }
        guard browserDialog == nil else {
            return ["ok": false, "error_code": "user_dialog_pending",
                    "reason": "网页正在等待用户处理确认或输入框，请在 WebMount 中接管处理。"]
        }
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
      var amberInteractiveQuery="a,button,input,textarea,select,[contenteditable='true'],[role='button'],[role='link'],[role='tab'],[role='menuitem'],[role='checkbox'],[role='radio'],[role='combobox'],[role='textbox'],[role='switch'],[role='row'],[role='treeitem'],[role='gridcell'],[role='option'],[tabindex]:not([tabindex='-1'])";
      function amberSafeURL(raw,base){
        try{var u=new URL(raw,(base&&base.location&&base.location.href)||location.href);return u.origin+u.pathname;}
        catch(e){return "";}
      }
      function amberBridge(){
        var bridge=window.__amberWebMountBridgeV1;
        if(!bridge || bridge.document!==document || !bridge.frames){
          var documentId=(Date.now().toString(36)+Math.random().toString(36).slice(2,10));
          bridge={document:document,window:window,documentId:documentId,revision:0,domRevision:0,urlRevision:0,lastURL:String(location.href||""),nextRef:1,nextFrame:1,refs:{},elementRefs:new WeakMap(),frames:[],frameDiagnostics:[]};
          bridge.snapshotId=function(){return bridge.documentId+":"+bridge.revision;};
          bridge.bump=function(){bridge.revision+=1;return bridge.snapshotId();};
          bridge.noteDomMutation=function(){bridge.domRevision+=1;bridge.revision+=1;bridge.pruneRefs();return bridge.domRevision;};
          bridge.flushMutations=function(){
            var changed=false;
            (bridge.frames||[]).forEach(function(frame){
              if(!frame.observer||!frame.observer.takeRecords) return;
              try{if(frame.observer.takeRecords().length) changed=true;}catch(e){}
            });
            if(changed) bridge.noteDomMutation();
            return changed;
          };
          bridge.pruneRefs=function(){
            Object.keys(bridge.refs).forEach(function(key){
              var item=bridge.refs[key];
              if(!item || !item.isConnected || !item.ownerDocument){delete bridge.refs[key];}
            });
          };
          bridge.refFor=function(el){
            if(!el || el.nodeType!==1) return "";
            var existing=bridge.elementRefs.get(el);
            if(existing) return existing;
            bridge.pruneRefs();
            var ref="wm:"+bridge.documentId+":"+(bridge.nextRef++);
            bridge.elementRefs.set(el,ref);bridge.refs[ref]=el;return ref;
          };
          bridge.frameForDocument=function(doc){
            for(var i=0;i<bridge.frames.length;i++) if(bridge.frames[i].document===doc) return bridge.frames[i];
            return null;
          };
          bridge.queryAll=function(selector,maxResults,visibleOnly,frameId){
            var matches=[], limit=maxResults||600;
            if(frameId && !bridge.frames.some(function(frame){return frame.id===frameId;})) return {errorCode:"stale_frame",matches:[]};
            for(var i=0;i<bridge.frames.length && matches.length<limit;i++){
              if(frameId && bridge.frames[i].id!==frameId) continue;
              try{
                var found=bridge.frames[i].document.querySelectorAll(selector);
                for(var j=0;j<found.length && matches.length<limit;j++){
                  if(!visibleOnly || amberVisible(found[j])) matches.push(found[j]);
                }
              }catch(e){return {errorCode:"invalid_selector",matches:[]};}
            }
            return {errorCode:"",matches:matches};
          };
          bridge.resolve=function(raw){
            var target=String(raw||""), frameId="", selector=target;
            if(target.indexOf("wm:")===0){
              if(target.indexOf("wm:"+bridge.documentId+":")!==0) return {errorCode:"stale_ref",element:null};
              var referenced=bridge.refs[target];
              if(!referenced || !referenced.isConnected || !bridge.frameForDocument(referenced.ownerDocument)){
                return {errorCode:"stale_ref",element:null};
              }
              return {errorCode:"",element:referenced};
            }
            if(target.indexOf("frame:")===0){
              var marker=target.indexOf(":css:");
              if(marker<0) return {errorCode:"invalid_selector",element:null};
              frameId=target.slice(6,marker); selector=target.slice(marker+5);
              for(var f=0;f<bridge.frames.length;f++) if(bridge.frames[f].id===frameId){
                try{return {errorCode:"",element:bridge.frames[f].document.querySelector(selector)};}
                catch(e){return {errorCode:"invalid_selector",element:null};}
              }
              return {errorCode:"stale_frame",element:null};
            }
            if(selector.indexOf("css:")===0) selector=selector.slice(4);
            if(!selector) return {errorCode:"missing_target",element:null};
            var result=bridge.queryAll(selector,1);
            return result.errorCode ? {errorCode:result.errorCode,element:null} : {errorCode:"",element:result.matches[0]||null};
          };
          bridge.refreshFrames=function(){
            var previous=bridge.frames||[], next=[], diagnostics=[], changed=false;
            function previousForFrame(frameElement){
              for(var p=0;p<previous.length;p++) if(previous[p].frameElement===frameElement) return previous[p];
              return null;
            }
            function append(doc,win,frameElement,parent,depth){
              if(depth>8 || next.length>=64) return;
              var old=frameElement?previousForFrame(frameElement):previous[0];
              var state={
                id:frameElement?(old?old.id:"f"+(bridge.nextFrame++)):"root",
                document:doc,window:win,frameElement:frameElement,parentId:parent?parent.id:null,depth:depth,
                observer:old&&old.document===doc?old.observer:null,observedDocument:old&&old.document===doc?old.observedDocument:null
              };
              if(!old || old.document!==doc) changed=true;
              next.push(state);
              var children=[];
              try{children=doc.querySelectorAll("iframe,frame");}catch(e){return;}
              for(var i=0;i<children.length;i++){
                var child=children[i], childDoc=null, childWin=null, src=child.getAttribute("src")||"";
                try{
                  childDoc=child.contentDocument;
                  childWin=child.contentWindow;
                  if(!childDoc || !childWin){
                    var crossOrigin=false;
                    try{if(childWin) void childWin.location.href;}catch(e){crossOrigin=true;}
                    diagnostics.push({frame_id:state.id+"/"+i,frame_ref:bridge.refFor(child),accessible:false,error_code:crossOrigin?"cross_origin_frame":"frame_not_ready",url:amberSafeURL(src,doc.defaultView)});
                    continue;
                  }
                  void childDoc.location.href;
                  append(childDoc,childWin,child,state,depth+1);
                }catch(e){
                  diagnostics.push({frame_id:state.id+"/"+i,frame_ref:bridge.refFor(child),accessible:false,error_code:"cross_origin_frame",url:amberSafeURL(src,doc.defaultView)});
                }
              }
            }
            append(document,window,null,null,0);
            previous.forEach(function(old){
              var still=next.some(function(item){return item.document===old.document;});
              if(!still){
                changed=true;
                Object.keys(bridge.refs).forEach(function(key){
                  var item=bridge.refs[key];
                  if(item && item.ownerDocument===old.document) delete bridge.refs[key];
                });
                if(old.observer&&old.observer.disconnect) try{old.observer.disconnect();}catch(e){}
              }
            });
            bridge.frames=next;
            bridge.frameDiagnostics=diagnostics;
            next.forEach(function(state){
              if(state.observedDocument===state.document) return;
              try{
                state.observer=new MutationObserver(function(records){if(records&&records.length) bridge.noteDomMutation();});
                state.observer.observe(state.document,{subtree:true,childList:true,attributes:true,characterData:true});
                state.observedDocument=state.document;
              }catch(e){}
              try{
                state.eventBump=function(){bridge.revision+=1;};
                state.document.addEventListener("input",state.eventBump,true);
                state.document.addEventListener("change",state.eventBump,true);
                state.window.addEventListener("scroll",state.eventBump,true);
              }catch(e){}
            });
            if(changed) bridge.revision+=1;
            bridge.pruneRefs();
          };
          window.__amberWebMountBridgeV1=bridge;
        }
        var currentURL=String(location.href||"");
        if(bridge.lastURL!==currentURL){bridge.lastURL=currentURL;bridge.urlRevision+=1;bridge.revision+=1;}
        bridge.refreshFrames();
        bridge.flushMutations();
        return bridge;
      }
      function amberFrameForDocument(doc){
        var bridge=window.__amberWebMountBridgeV1;
        return bridge&&bridge.frameForDocument?bridge.frameForDocument(doc):null;
      }
      function amberTopRect(el){
        var rect=el.getBoundingClientRect(), left=rect.left, top=rect.top, state=amberFrameForDocument(el.ownerDocument), guard=0;
        while(state&&state.frameElement&&guard++<8){
          var frame=state.frameElement, frameRect=frame.getBoundingClientRect();
          left+=frameRect.left+(frame.clientLeft||0);top+=frameRect.top+(frame.clientTop||0);
          state=amberFrameForDocument(frame.ownerDocument);
        }
        return {left:left,top:top,right:left+rect.width,bottom:top+rect.height,width:rect.width,height:rect.height};
      }
      function amberVisible(el){
        if(!el || !el.isConnected) return false;
        var ownerDocument=el.ownerDocument, ownerWindow=ownerDocument&&ownerDocument.defaultView||window, node=el;
        while(node&&node.nodeType===1){
          var style=ownerWindow.getComputedStyle?ownerWindow.getComputedStyle(node):null;
          if(node.hidden || (style&&(style.display==="none"||style.visibility==="hidden"||Number(style.opacity)===0))) return false;
          node=node.parentElement;
        }
        var rect=el.getBoundingClientRect();
        if(!(rect.width&&rect.height&&rect.bottom>=0&&rect.right>=0&&rect.top<=(ownerWindow.innerHeight||0)&&rect.left<=(ownerWindow.innerWidth||0))) return false;
        var topRect=amberTopRect(el), bridge=window.__amberWebMountBridgeV1;
        if(!(topRect.width&&topRect.height&&topRect.bottom>=0&&topRect.right>=0&&topRect.top<=(bridge.window.innerHeight||0)&&topRect.left<=(bridge.window.innerWidth||0))) return false;
        var state=amberFrameForDocument(ownerDocument);
        while(state&&state.frameElement){
          var frame=state.frameElement, frameRect=amberTopRect(frame);
          if(!frame.isConnected || !amberVisible(frame)) return false;
          if(topRect.right<=frameRect.left||topRect.left>=frameRect.right||topRect.bottom<=frameRect.top||topRect.top>=frameRect.bottom) return false;
          state=amberFrameForDocument(frame.ownerDocument);
        }
        return true;
      }
      function amberRole(el){
        var explicit=el&&el.getAttribute?el.getAttribute("role"):"";
        if(explicit) return explicit;
        var tag=(el&&el.tagName||"").toLowerCase();
        if(tag==="a") return "link"; if(tag==="button") return "button";
        if(tag==="input"){
          var type=(el.getAttribute("type")||"text").toLowerCase();
          if(type==="file"||type==="color"||type==="hidden") return type;
          if(type==="checkbox"||type==="radio"||type==="button"||type==="submit"||type==="reset"||type==="range") return type==="submit"||type==="reset"?"button":type;
          return "textbox";
        }
        if(tag==="textarea" || (el&&el.isContentEditable)) return "textbox";
        if(tag==="select") return "combobox"; return tag;
      }
      function amberName(el){
        if(!el) return "";
        var tag=(el.tagName||"").toLowerCase(), ownerDocument=el.ownerDocument, label=el.getAttribute&&(el.getAttribute("aria-label")||el.getAttribute("alt")||el.getAttribute("title")||el.getAttribute("placeholder"))||"";
        if(!label&&el.getAttribute){
          var labelledBy=String(el.getAttribute("aria-labelledby")||"").trim().split(/\\s+/).filter(Boolean);
          label=labelledBy.map(function(id){var node=ownerDocument.getElementById(id);return node?(node.innerText||node.textContent||""):"";}).join(" ");
        }
        if(!label&&el.labels&&el.labels.length&&amberVisible(el.labels[0])) label=el.labels[0].innerText||"";
        var text=label||((tag==="input"||tag==="textarea"||tag==="select")?"":(el.innerText||""));
        return String(text).replace(/\\s+/g," ").trim().slice(0,240);
      }
      function amberSelectorForElement(el,path){
        var frame=amberFrameForDocument(el&&el.ownerDocument);
        return frame&&frame.id!=="root"?"frame:"+frame.id+":css:"+path:"css:"+path;
      }
      function amberFrameSummary(){
        var bridge=window.__amberWebMountBridgeV1;
        return (bridge.frames||[]).map(function(frame){return {frame_id:frame.id,parent_frame_id:frame.parentId||"",accessible:true,url:amberSafeURL(frame.document.location&&frame.document.location.href,frame.document.defaultView),depth:frame.depth};});
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
        var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window, node=el;
        while(node && node.nodeType===1){
          var style=ownerWindow.getComputedStyle?ownerWindow.getComputedStyle(node):null;
          if(node.inert || node.getAttribute("aria-hidden")==="true" || (style&&style.pointerEvents==="none")) return false;
          node=node.parentElement;
        }
        var frame=amberFrameForDocument(el.ownerDocument);
        if(frame&&frame.frameElement&&!amberActionable(frame.frameElement)) return false;
        return !(el.disabled || (el.getAttribute&&el.getAttribute("aria-disabled")==="true"));
      }
      function amberTypeable(el){
        if(!el || amberSensitiveField(el)) return false;
        if(el.tagName==="TEXTAREA" || el.isContentEditable) return true;
        return el.tagName==="INPUT" && /^(text|email|search|tel|url|number|date|datetime-local|month|week|time)$/.test((el.getAttribute("type")||"text").toLowerCase());
      }
      function amberInteractiveTarget(el){
        for(var node=el;node;node=node.parentElement){
          if(node.matches(amberInteractiveQuery) && typeof node.click==="function" && amberActionable(node)) return node;
        }
        return null;
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
      var textLength=0, linksCount=0;
      bridge.frames.forEach(function(frame){
        if(frame.id!=="root"&&!amberVisible(frame.frameElement)) return;
        var frameBody=frame.document.body;
        textLength+=frameBody&&frameBody.innerText?frameBody.innerText.length:0;
        try{linksCount+=frame.document.links?frame.document.links.length:0;}catch(e){}
      });
      return JSON.stringify({
        url: cleanUrl(location.href),
        title: document.title || "",
        ready_state: document.readyState || "unknown",
        document_id: bridge.documentId,
        page_revision: bridge.revision,
        dom_revision: bridge.domRevision,
        url_revision: bridge.urlRevision,
        snapshot_id: bridge.snapshotId(),
        text_length: textLength,
        links_count: linksCount,
        frame_count: bridge.frames.length,
        frames: amberFrameSummary(),
        frame_diagnostics: bridge.frameDiagnostics,
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
          function currentValueMeta(el){
            var tag=(el&&el.tagName||"").toLowerCase();
            if(tag!=="input"&&tag!=="textarea"&&!el.isContentEditable) return {current_value:"",value_length:0,truncated:false,value_redacted:false};
            if(amberSensitiveField(el)) return {current_value:"",value_length:null,truncated:false,value_redacted:true};
            var raw=el.isContentEditable?String(el.textContent||""):String(el.value||"");
            return {current_value:raw.slice(0,120),value_length:raw.length,truncated:raw.length>120,value_redacted:false};
          }
          if(mode==="interactive" || mode==="snapshot"){
            var queriedNodes=bridge.queryAll(amberInteractiveQuery,200,true);
            if(queriedNodes.errorCode) return JSON.stringify({ok:false,error_code:queriedNodes.errorCode,snapshot_id:bridge.snapshotId()});
            var nodes=queriedNodes.matches.sort(function(a,b){return Number(amberTypeable(b))-Number(amberTypeable(a));}).slice(0,100).map(function(el,idx){
                var rect=amberTopRect(el);
              var valueMeta=currentValueMeta(el);
              return {
                ref:bridge.refFor(el),
                selector:amberSelectorForElement(el,cssPath(el)),
                tag:(el.tagName||"").toLowerCase(),
                role:amberRole(el),
                name:amberName(el),
                text:amberName(el),
                href: el.href ? cleanUrl(el.href) : "",
                visible: amberVisible(el),
                actionable: amberActionable(el),
                typeable: amberTypeable(el) && !el.readOnly && amberActionable(el),
                disabled: !!el.disabled,
                checked: typeof el.checked==="boolean" ? el.checked : null,
                focused: el.ownerDocument.activeElement===el,
                current_value:valueMeta.current_value,
                value_length:valueMeta.value_length,
                truncated:valueMeta.truncated,
                value_redacted:valueMeta.value_redacted,
                rect: {
                  x: Math.round(rect.left || 0),
                  y: Math.round(rect.top || 0),
                  width: Math.round(rect.width || 0),
                  height: Math.round(rect.height || 0)
                }
              };
            });
            if(mode==="interactive"){
              return JSON.stringify({ mode: mode, url: cleanUrl(location.href), document_id:bridge.documentId, page_revision:bridge.revision, dom_revision:bridge.domRevision, url_revision:bridge.urlRevision, snapshot_id:bridge.snapshotId(), nodes: nodes, frame_count:bridge.frames.length, frames:amberFrameSummary(), frame_diagnostics:bridge.frameDiagnostics, truncated_fields:queriedNodes.matches.length>100?["nodes"]:[] });
            }
            function nearbyText(el){
              var text="";
              if(el.getAttribute) text = el.getAttribute("alt") || el.getAttribute("title") || el.getAttribute("aria-label") || "";
              if(!text && el.parentElement) text = el.parentElement.innerText || "";
              return String(text || "").replace(/\\s+/g," ").trim().slice(0,240);
            }
            var queriedCandidates=bridge.queryAll("img,iframe,canvas,video,svg,picture,h1,h2,h3,p,blockquote,article,section",120);
            if(queriedCandidates.errorCode) return JSON.stringify({ok:false,error_code:queriedCandidates.errorCode,snapshot_id:bridge.snapshotId()});
            var candidates=queriedCandidates.matches.map(function(el){
              var rect=amberTopRect(el), interactiveTarget=amberInteractiveTarget(el);
              return {
                ref:bridge.refFor(el),
                selector:amberSelectorForElement(el,cssPath(el)),
                tag:(el.tagName||"").toLowerCase(),
                src: el.currentSrc ? cleanUrl(el.currentSrc) : (el.src ? cleanUrl(el.src) : ""),
                href: el.href ? cleanUrl(el.href) : "",
                alt: el.getAttribute ? (el.getAttribute("alt") || "") : "",
                title: el.getAttribute ? (el.getAttribute("title") || "") : "",
                nearby_text: nearbyText(el),
                visible: amberVisible(el),
                single_click_supported: typeof el.click==="function" && amberActionable(el),
                interactive_target_ref: interactiveTarget?bridge.refFor(interactiveTarget):"",
                rect: {
                  x: Math.round(rect.left || 0),
                  y: Math.round(rect.top || 0),
                  width: Math.round(rect.width || 0),
                  height: Math.round(rect.height || 0)
                }
              };
            }).filter(function(item){ return item.visible && (item.rect.width || item.rect.height); });
            var visibleTextRaw=bridge.frames.filter(function(frame){return frame.id==="root"||amberVisible(frame.frameElement);}).map(function(frame){return frame.document.body&&frame.document.body.innerText?frame.document.body.innerText:"";}).join(" ").replace(/\\s+/g," ").trim();
            var visibleText=visibleTextRaw.slice(0,\(maxChars));
            var queriedLinks=bridge.queryAll("a[href]",500);
            var visibleLinks=(queriedLinks.matches||[]).filter(amberVisible);
            var links=visibleLinks.slice(0,\(maxLinks)).map(function(a){
              return { text:(a.innerText||a.getAttribute("aria-label")||"").trim().slice(0,200), href: cleanUrl(a.href) };
            });
            var totalTextLength=0,totalLinksCount=0;
            bridge.frames.forEach(function(frame){
              if(frame.id!=="root"&&!amberVisible(frame.frameElement)) return;
              var frameBody=frame.document.body;
              totalTextLength+=frameBody&&frameBody.innerText?frameBody.innerText.length:0;
              try{totalLinksCount+=frame.document.links?frame.document.links.length:0;}catch(e){}
            });
            var page={
              url:cleanUrl(location.href),
              title:document.title||"",
              ready_state:document.readyState||"unknown",
              document_id:bridge.documentId,
              page_revision:bridge.revision,
              dom_revision:bridge.domRevision,
              url_revision:bridge.urlRevision,
              snapshot_id:bridge.snapshotId(),
              text_length:totalTextLength,
              links_count:totalLinksCount,
              frame_count:bridge.frames.length,
              frames:amberFrameSummary(),
              frame_diagnostics:bridge.frameDiagnostics,
              viewport:{width:window.innerWidth||0,height:window.innerHeight||0},
              scroll:{x:window.scrollX||0,y:window.scrollY||0}
            };
            return JSON.stringify({
              mode: mode,
              url: cleanUrl(location.href),
              document_id: bridge.documentId,
              page_revision: bridge.revision,
              dom_revision: bridge.domRevision,
              url_revision: bridge.urlRevision,
              snapshot_id: bridge.snapshotId(),
              page: page,
              visible_text: visibleText,
              visible_text_length: visibleTextRaw.length,
              visible_text_returned_length: visibleText.length,
              visible_text_truncated: visibleText.length < visibleTextRaw.length,
              links: links,
              links_count: visibleLinks.length,
              links_returned_count: links.length,
              links_truncated: links.length < visibleLinks.length,
              interactive_elements: nodes,
              viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
              interactive_nodes: nodes,
              visual_candidates: candidates,
              frame_count:bridge.frames.length,
              frames:amberFrameSummary(),
              frame_diagnostics:bridge.frameDiagnostics,
              redacted: true,
              truncated_fields: (visibleText.length < visibleTextRaw.length ? ["visible_text"] : [])
                .concat(links.length < visibleLinks.length ? ["links"] : [])
                .concat(queriedNodes.matches.length > 100 ? ["interactive_elements"] : [])
            });
          }
          var textRaw=bridge.frames.filter(function(frame){return frame.id==="root"||amberVisible(frame.frameElement);}).map(function(frame){return frame.document.body&&frame.document.body.innerText?frame.document.body.innerText:"";}).join(" ");
          var text=textRaw.slice(0,\(maxChars));
          var queriedReadableLinks=bridge.queryAll("a[href]",500);
          var readableLinks=(queriedReadableLinks.matches||[]).filter(amberVisible);
          var links=readableLinks.slice(0,\(maxLinks)).map(function(a){
            return { text:(a.innerText||a.getAttribute("aria-label")||"").trim().slice(0,200), href: cleanUrl(a.href) };
          });
          return JSON.stringify({ mode:"readable", url: cleanUrl(location.href), title: document.title || "", document_id:bridge.documentId, page_revision:bridge.revision, dom_revision:bridge.domRevision, url_revision:bridge.urlRevision, snapshot_id:bridge.snapshotId(), text: text, text_length:textRaw.length, returned_text_length:text.length, text_truncated:text.length<textRaw.length, links: links, links_count:readableLinks.length, links_returned_count:links.length, links_truncated:links.length<readableLinks.length, frame_count:bridge.frames.length, frames:amberFrameSummary(), frame_diagnostics:bridge.frameDiagnostics, truncated_fields:(text.length<textRaw.length?["text"]:[]).concat(links.length<readableLinks.length?["links"]:[]) });
        })();
        """
    }

    static func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) -> String {
        let selectorTarget = selector?.nilIfBlank
        let optionTarget = target?.nilIfBlank
        let targetConflict = selectorTarget != nil && optionTarget != nil && selectorTarget != optionTarget
        let targetLiteral = jsString(selectorTarget ?? optionTarget ?? "css:body")
        let kindLiteral = jsString(kind)
        let attrLiteral = jsString(attrName ?? "")
        let maxChars = max(0, min(maxChars, 100_000))
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw, location.href);return u.origin+u.pathname;}catch(e){return "";}}
          var bridge=amberBridge(), target=\(targetLiteral), kind=\(kindLiteral), attr=\(attrLiteral);
          if(\(targetConflict ? "true" : "false")){ return JSON.stringify({ok:false,error_code:"conflicting_target_arguments",document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()}); }
          var resolved=bridge.resolve(target), el=resolved.element;
          if(resolved.errorCode){ return JSON.stringify({ok:false,error_code:resolved.errorCode,snapshot_id:bridge.snapshotId()}); }
          if(!el){ return JSON.stringify({ok:false,error_code:"target_not_found",snapshot_id:bridge.snapshotId()}); }
          if(!amberVisible(el)){ return JSON.stringify({ok:false,error_code:"target_not_visible",target_ref:bridge.refFor(el),snapshot_id:bridge.snapshotId()}); }
          var sensitive=amberSensitiveField(el) || /csrf|xsrf|auth/i.test((el.id||"")+" "+(el.name||""));
          if(kind==="value" && sensitive){
            return JSON.stringify({ok:false,error_code:"sensitive_value_denied",value_redacted:true,truncated:false,target_ref:bridge.refFor(el),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
          }
          if(kind==="attr" && /password|passwd|token|csrf|xsrf|secret|cookie|authorization|auth/i.test(attr)){
            return JSON.stringify({ok:false,error_code:"sensitive_attribute_denied",value_redacted:true,truncated:false,target_ref:bridge.refFor(el),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
          }
          if(kind==="attr" && attr.toLowerCase()==="value" && (el.tagName==="INPUT" || el.tagName==="TEXTAREA")){
            return JSON.stringify({ok:false,error_code:"sensitive_attribute_denied",value_redacted:true,truncated:false,target_ref:bridge.refFor(el),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
          }
          var value="";
          if(kind==="value"){ value=el.value || ""; }
          else if(kind==="attr"){ value=attr ? (el.getAttribute(attr) || "") : ""; if(attr==="href" || attr==="src") value=amberSafeURL(value,el.ownerDocument.defaultView); }
          else if(kind==="html"){ value=el.outerHTML || ""; }
          else { value=el.innerText || ""; }
          var rawValue=String(value), returnedValue=rawValue.slice(0,\(maxChars));
          return JSON.stringify({ok:true,target_ref:bridge.refFor(el),kind:kind,value:returnedValue,original_length:rawValue.length,returned_length:returnedValue.length,truncated:returnedValue.length<rawValue.length,value_redacted:false,document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
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
        let selectorTarget = selector?.nilIfBlank
        let optionSelector = (options["selector"] as? String)?.nilIfBlank
        let optionTarget = (options["target"] as? String)?.nilIfBlank
        let providedTargets = [selectorTarget, optionSelector, optionTarget].compactMap { $0 }
        let targetConflict = Set(providedTargets).count > 1
        let target = selectorTarget ?? optionTarget ?? optionSelector ?? ""
        let snapshotId = options["snapshot_id"] as? String ?? ""
        let xLiteral = intOption(["x"]).map(String.init) ?? "null"
        let yLiteral = intOption(["y"]).map(String.init) ?? "null"
        let byY = intOption(["dy", "by_y"]) ?? 0
        let clickCount = max(1, min(intOption(["click_count"]) ?? 1, 2))
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
          var clickCount=\(clickCount);
          var allowHighConsequence=\(allowHighConsequence ? "true" : "false");
          var preflightOnly=\(preflightOnly ? "true" : "false");
          function base(extra){
            var value={method:method,document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()};
            Object.keys(extra||{}).forEach(function(key){value[key]=extra[key];});
            return value;
          }
          function fail(code,extra){return JSON.stringify(base(Object.assign({ok:false,error_code:code},extra||{})));}
          function finish(extra){return JSON.stringify(base(Object.assign({ok:true},extra||{})));}
          var targetConflict=\(targetConflict ? "true" : "false");
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
          if(targetConflict) return fail("conflicting_target_arguments",{dispatched:false,verified:false});
          function isDisabled(el){return !!(el && (el.disabled || (el.getAttribute&&el.getAttribute("aria-disabled")==="true")));}
          function topmost(el){
            var ownerDocument=el.ownerDocument, rect=el.getBoundingClientRect(), x=rect.left+rect.width/2, y=rect.top+rect.height/2;
            var hit=ownerDocument.elementFromPoint(x,y);
            if(hit && hit!==el && !el.contains(hit)) return false;
            var state=amberFrameForDocument(ownerDocument), localX=x, localY=y;
            while(state&&state.frameElement){
              var frame=state.frameElement, frameDocument=frame.ownerDocument, frameRect=frame.getBoundingClientRect();
              var parentX=frameRect.left+(frame.clientLeft||0)+localX, parentY=frameRect.top+(frame.clientTop||0)+localY;
              var parentHit=frameDocument.elementFromPoint(parentX,parentY);
              if(parentHit&&parentHit!==frame&&!frame.contains(parentHit)) return false;
              localX=parentX;localY=parentY;state=amberFrameForDocument(frameDocument);
            }
            return true;
          }
          function nativeSetValue(el,value){
            if(el && el.isContentEditable){el.textContent=value;return;}
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window;
            var proto=el.tagName==="TEXTAREA"?ownerWindow.HTMLTextAreaElement&&ownerWindow.HTMLTextAreaElement.prototype:ownerWindow.HTMLInputElement&&ownerWindow.HTMLInputElement.prototype;
            var descriptor=proto&&Object.getOwnPropertyDescriptor(proto,"value");
            if(descriptor&&descriptor.set) descriptor.set.call(el,value); else el.value=value;
          }
          function keyEvent(el,type,key){var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,Constructor=ownerWindow.KeyboardEvent||KeyboardEvent;return el.dispatchEvent(new Constructor(type,{key:key,bubbles:true,cancelable:true}));}
          function inputEvent(el,type,data){
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,Constructor=ownerWindow.InputEvent||InputEvent;
            try{return el.dispatchEvent(new Constructor("beforeinput",{inputType:type,data:data,bubbles:true,cancelable:true}));}
            catch(e){return true;}
          }
          function insertText(el,value){
            var current=String(el.value||""), start=typeof el.selectionStart==="number"?el.selectionStart:current.length;
            var end=typeof el.selectionEnd==="number"?el.selectionEnd:start;
            var next=current.slice(0,start)+value+current.slice(end);
            nativeSetValue(el,next);
            try{el.setSelectionRange(start+value.length,start+value.length);}catch(e){}
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,InputConstructor=ownerWindow.InputEvent||InputEvent,EventConstructor=ownerWindow.Event||Event;
            try{el.dispatchEvent(new InputConstructor("input",{inputType:"insertText",data:value,bubbles:true}));}
            catch(e){el.dispatchEvent(new EventConstructor("input",{bubbles:true}));}
            return next.length;
          }
          function activeElementDeep(){
            var active=document.activeElement, guard=0;
            while(active&&active.tagName&&active.tagName.toLowerCase()==="iframe"&&active.contentDocument&&guard++<8){active=active.contentDocument.activeElement;}
            return active;
          }
          function currentValueMeta(el){
            if(amberSensitiveField(el)) return {current_value:"",truncated:false,value_redacted:true};
            var raw=el&&el.isContentEditable?String(el.textContent||""):String(el&&el.value||"");
            return {current_value:raw.slice(0,120),truncated:raw.length>120,value_redacted:false};
          }
          function elementAtViewportPoint(x,y){
            var currentDocument=bridge.document, hit=currentDocument.elementFromPoint(x,y), guard=0;
            while(hit&&hit.tagName&&hit.tagName.toLowerCase()==="iframe"&&hit.contentDocument&&guard++<8){
              var frameRect=hit.getBoundingClientRect();
              currentDocument=hit.contentDocument;
              hit=currentDocument.elementFromPoint(x-frameRect.left-(hit.clientLeft||0),y-frameRect.top-(hit.clientTop||0));
            }
            return hit;
          }
          function scrollElement(el,position,byY){
            var ownerDocument=el&&el.ownerDocument||bridge.document, ownerWindow=ownerDocument.defaultView||window;
            if(el&&el.tagName&&el.tagName.toLowerCase()==="iframe"&&el.contentWindow&&el.contentDocument){
              if(position==="top") el.contentWindow.scrollTo({top:0});
              else if(position==="bottom") el.contentWindow.scrollTo({top:el.contentDocument.documentElement.scrollHeight});
              else el.contentWindow.scrollBy({top:byY||400});
              return {window:el.contentWindow,element:el};
            }
            if(el){
              var style=ownerWindow.getComputedStyle?ownerWindow.getComputedStyle(el):null;
              var scrollable=style&&/(auto|scroll|overlay)/.test(style.overflowY||"")&&el.scrollHeight>el.clientHeight;
              if(scrollable){
                if(position==="top") el.scrollTop=0;
                else if(position==="bottom") el.scrollTop=el.scrollHeight;
                else if(el.scrollBy) el.scrollBy({top:byY||400});
                else el.scrollTop+=byY||400;
              }else{
                el.scrollIntoView({block:position==="top"?"start":position==="bottom"?"end":"center",inline:"nearest"});
                var frameState=amberFrameForDocument(ownerDocument);
                while(frameState&&frameState.frameElement){
                  frameState.frameElement.scrollIntoView({block:position==="top"?"start":position==="bottom"?"end":"center",inline:"nearest"});
                  frameState=amberFrameForDocument(frameState.frameElement.ownerDocument);
                }
              }
              return {window:ownerWindow,element:el};
            }
            if(position==="top") ownerWindow.scrollTo({top:0});
            else if(position==="bottom") ownerWindow.scrollTo({top:ownerDocument.documentElement.scrollHeight});
            else ownerWindow.scrollBy({top:byY||400});
            return {window:ownerWindow,element:null};
          }
          if(expectedSnapshot && expectedSnapshot!==bridge.snapshotId()){
            return fail("stale_snapshot",{expected_snapshot_id:expectedSnapshot});
          }

          if(method==="click" || method==="tap"){
            var el=null, x=\(xLiteral), y=\(yLiteral);
            if(method==="tap" && x!==null && y!==null){el=elementAtViewportPoint(x,y);}
            else {
              var resolved=resolveTarget(true);
              if(resolved.errorCode) return fail(resolved.errorCode);
              el=resolved.element;
            }
            if(!el) return fail("target_not_found");
            if(clickCount===1 && typeof el.click!=="function") return fail("target_not_clickable",{
              target_ref:bridge.refFor(el),
              interactive_target_ref:bridge.refFor(amberInteractiveTarget(el)),
              reason:"This visual target does not support a direct single click. Choose an interactive element or use wm_find to locate the control."
            });
            if(!preflightOnly && method==="click") scrollElement(el,"center",0);
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            if(isDisabled(el)) return fail("target_disabled",{target_ref:bridge.refFor(el)});
            if(method==="click" && !topmost(el)) return fail("target_occluded",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,method==="tap" && x!==null && y!==null);
            if(blocked) return blocked;
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            if(typeof el.focus==="function" && (amberTypeable(el) || el.tabIndex>=0)) el.focus();
            var doubleClickEvent=null;
            if(clickCount===2){
              try{
                var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,MouseConstructor=ownerWindow.MouseEvent||MouseEvent;
                doubleClickEvent=new MouseConstructor("dblclick",{bubbles:true,cancelable:true,detail:2,view:ownerWindow});
              }catch(e){return fail("double_click_dispatch_failed",{target_ref:bridge.refFor(el)});}
              el.dispatchEvent(new MouseConstructor("click",{bubbles:true,cancelable:true,detail:1,view:ownerWindow}));
              el.dispatchEvent(new MouseConstructor("click",{bubbles:true,cancelable:true,detail:2,view:ownerWindow}));
              el.dispatchEvent(doubleClickEvent);
            }else el.click();
            bridge.bump();
            return finish({found:true,target_ref:bridge.refFor(el),dispatched:true,click_count:clickCount,dblclick_dispatched:clickCount===2,focused:el.ownerDocument.activeElement===el,verified:false});
          }

          if(method==="type" || method==="keys"){
            var hasExplicitTarget=!!target, resolved=resolveTarget(method==="type"), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(!el && method==="keys" && !hasExplicitTarget) el=activeElementDeep();
            if(!el) return fail(hasExplicitTarget?"target_not_found":"focused_field_not_found");
            if(el===el.ownerDocument.body || el===el.ownerDocument.documentElement) return fail("focused_field_not_found");
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
            var wasFocused=el.ownerDocument.activeElement===el;
            el.focus();
            if(method==="keys" && !wasFocused && typeof el.setSelectionRange==="function"){
              var end=String(el.value||"").length;
              try{el.setSelectionRange(end,end);}catch(e){}
            }
            if(method==="type"){
              if(!inputEvent(el,"insertText",text)) return fail("input_cancelled",{target_ref:bridge.refFor(el)});
              nativeSetValue(el,text);
              var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,InputConstructor=ownerWindow.InputEvent||InputEvent,EventConstructor=ownerWindow.Event||Event;
              try{el.dispatchEvent(new InputConstructor("input",{inputType:"insertText",data:text,bubbles:true}));}
              catch(e){el.dispatchEvent(new EventConstructor("input",{bubbles:true}));}
              bridge.bump();
              var resolvedValue=contentEditable?String(el.textContent||""):String(el.value||"");
              var typeVerified=resolvedValue===text;
              var valueMeta=currentValueMeta(el);
              return finish({found:true,target_ref:bridge.refFor(el),value_length:resolvedValue.length,current_value:valueMeta.current_value,truncated:valueMeta.truncated,value_redacted:valueMeta.value_redacted,focused:el.ownerDocument.activeElement===el,verified:typeVerified});
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
                var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,EventConstructor=ownerWindow.Event||Event;
                el.dispatchEvent(new EventConstructor("input",{bubbles:true})); defaultApplied=true;
              }
              keyEvent(el,"keyup",key); bridge.bump();
              var specialValue=String(el.value||""), specialMeta=currentValueMeta(el);
              return finish({found:true,target_ref:bridge.refFor(el),key:key,event_dispatched:true,default_applied:defaultApplied,trusted:false,value_length:specialValue.length,current_value:specialMeta.current_value,truncated:specialMeta.truncated,value_redacted:specialMeta.value_redacted,verified:defaultApplied});
            }
            var beforeLength=String(el.value||"").length, inserted=0;
            for(var i=0;i<text.length;i++){
              var ch=text.charAt(i), allowed=keyEvent(el,"keydown",ch);
              if(allowed && inputEvent(el,"insertText",ch)){insertText(el,ch);inserted+=1;}
              keyEvent(el,"keyup",ch);
            }
            bridge.bump();
            var afterLength=String(el.value||"").length;
            var typedMeta=currentValueMeta(el);
            return finish({found:true,target_ref:bridge.refFor(el),event_count:text.length,inserted_count:inserted,trusted:false,value_length:afterLength,current_value:typedMeta.current_value,truncated:typedMeta.truncated,value_redacted:typedMeta.value_redacted,verified:inserted===text.length&&afterLength>=beforeLength});
          }

          if(method==="scroll"){
            var resolved=resolveTarget(false), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(el && /^(IFRAME|FRAME)$/.test(el.tagName) && !bridge.frames.some(function(frame){return frame.frameElement===el;})){
              var frameDiagnostic=bridge.frameDiagnostics.find(function(item){return item.frame_ref===bridge.refFor(el);});
              return fail(frameDiagnostic?frameDiagnostic.error_code:"frame_not_ready",{target_ref:bridge.refFor(el)});
            }
            if(preflightOnly) return finish({preflight_only:true,target_ref:el?bridge.refFor(el):"",target_label:el?amberName(el):"",verified:true});
            var position=\(jsString(namedPosition)), byY=\(byY);
            var beforeWindow=el&&el.tagName&&el.tagName.toLowerCase()==="iframe"&&el.contentWindow?el.contentWindow:el&&el.ownerDocument&&el.ownerDocument.defaultView||window;
            var beforeX=Math.round(beforeWindow.scrollX||0), beforeY=Math.round(beforeWindow.scrollY||0), beforeElementScrollTop=el&&typeof el.scrollTop==="number"?el.scrollTop:null, beforeTopRect=el?amberTopRect(el):null, scrollResult=scrollElement(el,position,byY);
            bridge.bump();
            var afterWindow=scrollResult.window||beforeWindow, afterX=Math.round(afterWindow.scrollX||0), afterY=Math.round(afterWindow.scrollY||0), elementScrollTop=scrollResult.element&&scrollResult.element.scrollTop, afterTopRect=el?amberTopRect(el):null, topRectChanged=beforeTopRect&&afterTopRect&&(beforeTopRect.left!==afterTopRect.left||beforeTopRect.top!==afterTopRect.top);
            return finish({found:!!el,target_ref:el?bridge.refFor(el):"",scroll_x:afterX,scroll_y:afterY,element_scroll_top:typeof elementScrollTop==="number"?Math.round(elementScrollTop):null,verified:beforeX!==afterX||beforeY!==afterY||(typeof elementScrollTop==="number"&&elementScrollTop!==beforeElementScrollTop)||!!topRectChanged});
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
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,EventConstructor=ownerWindow.Event||Event;
            el.value=text; el.dispatchEvent(new EventConstructor("input",{bubbles:true})); el.dispatchEvent(new EventConstructor("change",{bubbles:true})); bridge.bump();
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
                var css=target.indexOf("css:")===0?target.slice(4):target, frameId="";
                if(target.indexOf("frame:")===0){
                  var marker=target.indexOf(":css:");
                  if(marker<0) return fail("invalid_selector");
                  frameId=target.slice(6,marker);css=target.slice(marker+5);
                }
                var queried=bridge.queryAll(css,maxResults,true,frameId);
                if(queried.errorCode) return fail(queried.errorCode);
                matches=queried.matches;
              }
            } else if(query){
              var queried=bridge.queryAll(amberInteractiveQuery+",label,p,span,div,main,li,h1,h2,h3,h4,h5,h6,td,th,article,section,[role]",600,true);
              if(queried.errorCode) return fail(queried.errorCode);
              matches=queried.matches.map(function(item){return {element:item,name:amberName(item).toLowerCase(),interactive:item.matches(amberInteractiveQuery)};})
                .filter(function(item){return item.name.indexOf(query)>=0;})
                .sort(function(a,b){return Number(b.name===query)-Number(a.name===query) || Number(b.interactive)-Number(a.interactive);})
                .slice(0,maxResults).map(function(item){return item.element;});
            }
            var output=matches.filter(amberVisible).slice(0,maxResults).map(function(item){return {ref:bridge.refFor(item),tag:(item.tagName||"").toLowerCase(),role:amberRole(item),name:amberName(item),visible:true,actionable:amberActionable(item),typeable:amberTypeable(item)&&!item.readOnly&&amberActionable(item),focused:item.ownerDocument.activeElement===item};});
            return finish({found:output.length>0,count:output.length,matches:output,verified:output.length>0});
          }
          return fail("unsupported_interaction");
        })();
        """
    }

    static func waitProbe(condition: String, options: [String: Any]) -> String {
        let selector = (options["selector"] as? String)?.nilIfBlank ?? ""
        let text = options["text"] as? String ?? ""
        let urlFragment = options["url_contains"] as? String ?? ""
        let readyState = (options["ready_state"] as? String)?.lowercased() ?? "complete"
        let beforeDocumentId = (options["before_document_id"] as? String)?.nilIfBlank ?? ""
        let beforeURL = (options["before_url"] as? String)?.nilIfBlank ?? ""
        let beforeURLRevision = (options["before_url_revision"] as? Int)
            ?? (options["before_url_revision"] as? NSNumber)?.intValue
            ?? (options["before_url_revision"] as? Double).map(Int.init)
        let beforeDOMRevision = (options["before_dom_revision"] as? Int)
            ?? (options["before_dom_revision"] as? NSNumber)?.intValue
            ?? (options["before_dom_revision"] as? Double).map(Int.init)
        let requirePageChange = options["require_page_change"] as? Bool ?? false
        let beforeURLRevisionLiteral = beforeURLRevision.map(String.init) ?? "null"
        let beforeDOMRevisionLiteral = beforeDOMRevision.map(String.init) ?? "null"
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw);return u.origin+u.pathname;}catch(e){return "";}}
          var bridge=amberBridge(), condition=\(jsString(condition)), conditionMatched=false, matched=false, errorCode="";
          var beforeDocumentId=\(jsString(beforeDocumentId)), beforeURL=\(jsString(beforeURL)), beforeURLRevision=\(beforeURLRevisionLiteral), beforeDOMRevision=\(beforeDOMRevisionLiteral), requirePageChange=\(requirePageChange ? "true" : "false");
          var currentURL=cleanUrl(location.href), sameDocument=!!beforeDocumentId && bridge.documentId===beforeDocumentId, urlRevisionChanged=sameDocument && beforeURLRevision!==null && bridge.urlRevision!==beforeURLRevision, documentChanged=!!beforeDocumentId && !sameDocument, urlChanged=urlRevisionChanged || (!!beforeURL && currentURL!==cleanUrl(beforeURL)), domChanged=beforeDOMRevision!==null && bridge.domRevision!==beforeDOMRevision, pageChanged=documentChanged||urlChanged||domChanged;
          if(condition==="selector"){
            var resolved=bridge.resolve(\(jsString(selector)));
            errorCode=resolved.errorCode||""; conditionMatched=!!resolved.element && amberVisible(resolved.element);
          } else if(condition==="text"){
            conditionMatched=bridge.frames.some(function(frame){return (frame.id==="root"||amberVisible(frame.frameElement)) && String(frame.document.body&&frame.document.body.innerText||"").indexOf(\(jsString(text)))>=0;});
          } else if(condition==="url_contains"){
            conditionMatched=String(location.href||"").indexOf(\(jsString(urlFragment)))>=0;
          } else if(condition==="ready_state"){
            var expected=\(jsString(readyState));
            conditionMatched=expected==="interactive"?(document.readyState==="interactive"||document.readyState==="complete"):document.readyState===expected;
          } else if(condition==="document_changed"){
            conditionMatched=documentChanged;
          } else if(condition==="url_changed"){
            conditionMatched=urlChanged;
          } else if(condition==="dom_stable"){
            conditionMatched=true;
          }
          matched=conditionMatched && (!requirePageChange || pageChanged);
          return JSON.stringify({ok:!errorCode,matched:matched,condition_matched:conditionMatched,error_code:errorCode,ready_state:document.readyState||"unknown",url:currentURL,document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId(),document_changed:documentChanged,url_changed:urlChanged,dom_changed:domChanged,page_changed:pageChanged,require_page_change:requirePageChange,before_document_id:beforeDocumentId,before_url:beforeURL?cleanUrl(beforeURL):"",before_url_revision:beforeURLRevision,before_dom_revision:beforeDOMRevision});
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
    var cardHidden: Bool = false
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
    var cardHidden: Bool
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
        case cardHidden
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
        cardHidden: Bool = false,
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
        self.cardHidden = cardHidden
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
        cardHidden = try container.decodeIfPresent(Bool.self, forKey: .cardHidden) ?? false
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
        // A reclaimed Agent session keeps only its bound metadata so the
        // conversation and management page can offer an honest reopen entry.
        // The runtime itself is absent until an explicit reopen action.
        let sessionIds = Set(runtimes.keys).union(
            metadata.compactMap { sessionId, item in
                guard runtimes[sessionId] == nil,
                      item.needsReopen,
                      item.ownerConversationId?.nilIfBlank != nil else { return nil }
                return sessionId
            }
        )
        return sessionIds
            .sorted { lhs, rhs in
                if lhs == currentSessionId { return true }
                if rhs == currentSessionId { return false }
                return (metadata[lhs]?.lastActivityMillis ?? 0) > (metadata[rhs]?.lastActivityMillis ?? 0)
            }
            .compactMap { sessionId -> IOSWebMountSessionRecord? in
                guard let metadata = metadata[sessionId] else { return nil }
                let snapshot = runtimes[sessionId]?.snapshot
                guard snapshot != nil || metadata.needsReopen else { return nil }
                return IOSWebMountSessionRecord(
                    id: sessionId,
                    siteId: metadata.siteId,
                    siteName: metadata.siteName,
                    title: IOSWebMountRedactor.redactedText(snapshot?.title?.nilIfBlank ?? metadata.lastTitle?.nilIfBlank ?? "未命名页面"),
                    redactedURL: snapshot?.currentURL ?? snapshot?.requestedURL ?? metadata.redactedURL ?? "",
                    status: metadata.needsReopen ? "needs_reopen" : snapshot?.status.rawValue ?? "idle",
                    canGoBack: snapshot?.canGoBack ?? false,
                    canGoForward: snapshot?.canGoForward ?? false,
                    lastActivityMillis: metadata.lastActivityMillis,
                    isCurrent: sessionId == currentSessionId,
                    ownerConversationId: metadata.ownerConversationId,
                    ownerRunId: metadata.ownerRunId,
                    controlOwner: effectiveControlOwner(metadata, now: nowMillis()),
                    leaseExpiresAtMillis: metadata.leaseExpiresAtMillis,
                    persistentOptIn: metadata.persistentOptIn,
                    needsReopen: metadata.needsReopen,
                    cardHidden: metadata.cardHidden,
                    backend: metadata.backend,
                    mcpServerName: metadata.mcpServerName
                )
            }
    }

    var activeRecords: [IOSWebMountSessionRecord] {
        records.filter { runtimes[$0.id] != nil }
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

    /// Rebuild a reclaimed session only for an explicit reopen action. The
    /// restored runtime starts from an idle page; metadata never restores old
    /// page state or actions.
    @discardableResult
    func reopen(sessionId: String) -> IOSWebMountSessionRecord? {
        guard let item = metadata[sessionId], item.needsReopen else {
            return record(sessionId: sessionId)
        }
        if runtimes[sessionId] != nil {
            return record(sessionId: sessionId)
        }
        let runtime: IOSWebMountRuntimeServicing?
        if item.backend == .local {
            runtime = restoredRuntimeFactory?(sessionId)
        } else {
            runtime = remoteRuntimeFactory?(sessionId, item.backend)
        }
        guard let runtime, runtime.snapshot.sessionId == sessionId else { return nil }
        if runtimes.count >= maxSessions,
           !evictLeastRecentlyUsedSession(allowCurrent: false) {
            return nil
        }
        runtimes[sessionId] = runtime
        if var reopenedMetadata = metadata[sessionId] {
            reopenedMetadata.lastActivityMillis = nowMillis()
            metadata[sessionId] = reopenedMetadata
        }
        persistSessions()
        return record(sessionId: sessionId)
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
        guard runtimes[sessionId] != nil || metadata[sessionId] != nil else {
            throw IOSWebMountSessionError.sessionNotFound(sessionId)
        }
        guard runtimes[sessionId] != nil else {
            metadata.removeValue(forKey: sessionId)
            persistSessions()
            return record(sessionId: currentSessionId)
        }
        if runtimes.count == 1 {
            removeSession(sessionId, preserveReopenEntry: false)
            expireInactiveSessions()
            persistSessions()
            return record(sessionId: currentSessionId)
        }
        removeSession(sessionId, preserveReopenEntry: false)
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
            (runtimes[sessionId] as? IOSWebMountWKRuntime)?.setUserBrowsingEnabled(false)
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
        (runtimes[sessionId] as? IOSWebMountWKRuntime)?.setUserBrowsingEnabled(true)
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
        (runtimes[sessionId] as? IOSWebMountWKRuntime)?.setUserBrowsingEnabled(false)
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
                (runtimes[sessionId] as? IOSWebMountWKRuntime)?.invalidateNavigationDecisions()
            }
            metadata[sessionId] = item
            changed = true
        }
        if changed {
            persistSessions()
        }
    }

    func hideCard(sessionId: String) {
        guard var item = metadata[sessionId], !item.cardHidden else { return }
        item.cardHidden = true
        metadata[sessionId] = item
        persistSessions()
    }

    func showCard(sessionId: String) {
        guard var item = metadata[sessionId], item.cardHidden else { return }
        item.cardHidden = false
        metadata[sessionId] = item
        persistSessions()
    }

    func expireInactiveSessions(nowMillis explicitNow: Int64? = nil) {
        let now = explicitNow ?? nowMillis()
        normalizeExpiredAgentLeases(now: now)
        let expired = metadata.compactMap { sessionId, item -> String? in
            guard runtimes[sessionId] != nil,
                  !item.persistentOptIn,
                  effectiveControlOwner(item, now: now) != .user,
                  now - item.lastActivityMillis >= Self.ephemeralTTLMillis else { return nil }
            return sessionId
        }
        for sessionId in expired {
            removeSession(sessionId, preserveReopenEntry: true)
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
        removeSession(candidate, preserveReopenEntry: true)
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
            cardHidden: metadata[sessionId]?.cardHidden ?? false,
            backend: metadata[sessionId]?.backend ?? .local,
            mcpServerName: metadata[sessionId]?.mcpServerName
        )
    }

    private func removeSession(_ sessionId: String, preserveReopenEntry: Bool = false) {
        guard let removedRuntime = runtimes.removeValue(forKey: sessionId) else { return }
        if let browser = removedRuntime as? IOSWebMountWKRuntime {
            browser.closeSession()
        }
        if preserveReopenEntry,
           var item = metadata[sessionId],
           item.ownerConversationId?.nilIfBlank != nil {
            item.ownerRunId = nil
            item.controlOwner = .none
            item.leaseExpiresAtMillis = nil
            item.needsReopen = true
            metadata[sessionId] = item
        } else {
            metadata.removeValue(forKey: sessionId)
        }
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
        (runtimes[sessionId] as? IOSWebMountWKRuntime)?.invalidateNavigationDecisions()
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
            (runtimes[sessionId] as? IOSWebMountWKRuntime)?.invalidateNavigationDecisions()
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
            cardHidden: false,
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
        .init(name: "wm_visual_read", description: "Read a real local viewport screenshot with a vision model after approval. Use after navigation and key actions to verify the visible result; DOM candidates alone are not visual verification.", requiresUserAction: true),
        .init(name: "wm_back", description: "Navigate the current WebMount session backward.", requiresUserAction: false),
        .init(name: "wm_forward", description: "Navigate the current WebMount session forward.", requiresUserAction: false),
        .init(name: "wm_clear_session", description: "Clear cookies and website data for one station after explicit user action.", requiresUserAction: true),
        .init(name: "wm_site_add", description: "Add an iOS WebMount station and sync the URL allowlist after foreground approval.", requiresUserAction: true),
        .init(name: "wm_site_remove", description: "Remove an iOS WebMount station and sync the URL allowlist after foreground approval. Cookies are not cleared.", requiresUserAction: true),
        .init(name: "wm_click", description: "Click an observed semantic target bound to the current session and snapshot.", requiresUserAction: false),
        .init(name: "wm_tap", description: "Tap an observed semantic target; coordinates require direct user action.", requiresUserAction: false),
        .init(name: "wm_type", description: "Type text into an observed input target and verify its current value.", requiresUserAction: false),
        .init(name: "wm_keys", description: "Send a short key sequence to the current WebMount page or focused field.", requiresUserAction: false),
        .init(name: "wm_scroll", description: "Scroll the page or an element into view.", requiresUserAction: false),
        .init(name: "wm_select", description: "Select an option value using an observed semantic target.", requiresUserAction: false),
        .init(name: "wm_find", description: "Read-only selector or visible-text search that returns stable element refs without input values.", requiresUserAction: false),
        .init(name: "wm_wait", description: "Wait up to 30 seconds for a target, text, URL, document change, DOM stability, readiness, or delay; readiness alone does not verify the task goal.", requiresUserAction: false),
        .init(name: "wm_run_goal", description: "Run a bounded Jev fast action loop toward one verifiable goal on an open session; every executed action still passes its own approval and the ledger, and it never submits, deletes, pays, or logs in.", requiresUserAction: false)
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
        "wm_site_adapter"
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

    func openForUser(site: IOSWebMountSite, sessionId: String? = nil, url rawURL: String? = nil) async -> IOSWebMountRuntimeSnapshot {
        let requestedURL = rawURL ?? site.homepageURL
        if let sessionId = sessionId?.nilIfBlank,
           let record = sessionStore.record(sessionId: sessionId),
           record.backend != .local {
            let current = sessionStore.runtimeIfPresent(sessionId: sessionId)?.snapshot
                ?? .idle(sessionId: sessionId)
            return IOSWebMountRuntimeSnapshot(
                sessionId: current.sessionId,
                status: .failed,
                requestedURL: IOSWebMountRedactor.redactedURL(requestedURL),
                currentURL: current.currentURL,
                title: current.title,
                estimatedProgress: current.estimatedProgress,
                canGoBack: current.canGoBack,
                canGoForward: current.canGoForward,
                error: "Desktop WebMount sessions cannot be opened through the local user WebMount view.",
                updatedAtMillis: IOSWebMountClock.nowMillis()
            )
        }
        guard let runtime = try? sessionStore.runtime(sessionId: sessionId, makeCurrent: true) else {
            var failed = IOSWebMountRuntimeSnapshot.idle(sessionId: sessionId ?? "")
            failed.status = .failed
            failed.error = "此站点会话不存在或已过期，请重新打开站点。"
            return failed
        }
        _ = try? sessionStore.acquireUserControl(sessionId: runtime.snapshot.sessionId)
        sessionStore.showCard(sessionId: runtime.snapshot.sessionId)
        let policy = IOSWebMountURLPolicy(settings: settings, extraAllowedHosts: registry.sites.flatMap(\.allowedHosts))
        let result = await policy.allowingPublicUserNavigation().validateResolvedPublicHost(
            requestedURL, site: site, resolveHost: resolveHost
        )
        guard sessionStore.record(sessionId: runtime.snapshot.sessionId)?.controlOwner == .user,
              sessionStore.runtimeIfPresent(sessionId: runtime.snapshot.sessionId) === runtime else {
            var failed = runtime.snapshot
            failed.status = .failed
            failed.error = "页面控制权已变化，请接管后重新打开。"
            return failed
        }
        switch result {
        case .success(let url):
            (runtime as? IOSWebMountWKRuntime)?.setNavigationPolicy(
                policy,
                site: site,
                resolveHost: resolveHost
            )
            if registry.site(id: site.id) != nil {
                sessionStore.tag(sessionId: runtime.snapshot.sessionId, site: site)
            }
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
                requestedURL: IOSWebMountRedactor.redactedURL(requestedURL),
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
        allowUnlistedHosts: Bool = false,
        visualRead: IOSWebMountVisualReadHandler? = nil
    ) async -> String {
        let output = await executeResult(
            toolName: toolName, input: input, isUserInitiated: isUserInitiated,
            context: context, allowUnlistedHosts: allowUnlistedHosts, visualRead: visualRead
        )
        var payload = Self.parseObject(output)
        payload["tool"] = toolName
        payload["tool_available"] = IOSWebMountToolCatalog.supportedToolNames.contains(toolName)
        if Self.desktopMutatingToolNames.contains(toolName) {
            // A missing receipt from an interrupted backend is unknown, never success.
            if payload["dispatched"] == nil {
                let rejectedBeforeDispatch = payload["ok"] as? Bool == false
                    && payload["may_have_applied"] as? Bool != true
                payload["dispatched"] = rejectedBeforeDispatch ? false as Any : NSNull()
            }
            if payload["page_changed"] == nil { payload["page_changed"] = NSNull() }
            if payload["goal_verified"] == nil { payload["goal_verified"] = false }
            if payload["retry"] == nil {
                payload["retry"] = Self.webMountRetryAdvice(dispatched: payload["dispatched"] as? Bool != false)
            }
        }
        return Self.json(payload)
    }

    private func executeResult(
        toolName: String,
        input: String,
        isUserInitiated: Bool,
        context: IOSWebMountExecutionContext?,
        allowUnlistedHosts: Bool,
        visualRead: IOSWebMountVisualReadHandler?
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
        var args = Self.parseObject(input)
        if let conflict = Self.webMountTargetConflict(toolName: toolName, args: args) {
            return conflict
        }
        if (args["selector"] as? String)?.nilIfBlank == nil
            || (args["selector"] as? String)?.nilIfBlank == (args["target"] as? String)?.nilIfBlank {
            args.removeValue(forKey: "selector")
        }
        if let limitFailure = Self.webMountInputLimitFailure(toolName: toolName, args: args) {
            return limitFailure
        }
        do {
            if !Self.desktopRoutingExemptToolNames.contains(toolName),
               let sessionId = (args["session_id"] as? String)?.nilIfBlank,
               let record = sessionStore.record(sessionId: sessionId),
               record.backend != .local {
                if toolName == "wm_visual_read" {
                    return Self.json(["ok": false, "error_code": "unsupported_backend", "reason": "wm_visual_read currently supports local WKWebView sessions only."])
                }
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
            case "wm_visual_read":
                guard isUserInitiated else {
                    return Self.json(["ok": false, "needs_user_action": true, "reason": "Visual reading sends the viewport screenshot to the configured vision provider and requires foreground approval."])
                }
                return try await visualReadResult(args: args, context: context, reader: visualRead)
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
                var postcondition = mutating ? Self.webMountPostconditionOptions(from: args) : nil
                if mutating, args["postcondition"] != nil, postcondition == nil {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "denied": true,
                        "error_code": "invalid_postcondition",
                        "reason": "postcondition requires a supported condition and a value except for dom_stable, document_changed, or url_changed."
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
                let selector = (args["target"] as? String)?.nilIfBlank
                    ?? (args["selector"] as? String)?.nilIfBlank
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
                var dispatchEvidence: Bool?
                do {
                    let before = try await runtime.state()
                    if postcondition != nil {
                        postcondition?["before_document_id"] = before["document_id"]
                        postcondition?["before_url"] = before["url"]
                        postcondition?["before_dom_revision"] = before["dom_revision"]
                        postcondition?["before_url_revision"] = before["url_revision"]
                    }
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
                    dispatchEvidence = mutating && (result["dispatched"] as? Bool
                        ?? (result["ok"] as? Bool == true && result["preflight_only"] as? Bool != true))
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
                    let dispatched = dispatchEvidence == true
                    let readinessOnly = ["ready_state", "dom_stable", "document_changed", "url_changed", "delay"]
                        .contains(postcondition?["condition"] as? String ?? (method == "wait" ? args["condition"] as? String ?? "dom_stable" : ""))
                    let verified: Bool
                    let verificationSource: String
                    if !mutating {
                        verified = (result["verified"] as? Bool)
                            ?? ((method == "find" && result["found"] as? Bool == true)
                                || (method == "wait" && result["matched"] as? Bool == true))
                        verificationSource = verified ? method : ""
                    } else if postcondition != nil {
                        verified = dispatched && postconditionMatched && !preconditionMatched && !readinessOnly
                        verificationSource = verified ? "postcondition" : ""
                    } else if dispatched && actionVerified {
                        verified = true
                        verificationSource = "action"
                    } else {
                        verified = false
                        verificationSource = ""
                    }
                    let goalVerified = verified && !readinessOnly && (mutating || method == "wait")
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
                    } else if dispatched {
                        status = "ambiguous"
                    } else {
                        status = errorCode == "wait_timeout" ? "timed_out" : "rejected"
                    }
                    let outcome: String
                    if verified {
                        outcome = "verified"
                    } else if errorCode == "wait_timeout" {
                        outcome = "timed_out"
                    } else if succeeded || dispatched {
                        outcome = method == "find" ? "not_found" : "ambiguous"
                    } else {
                        outcome = "rejected"
                    }
                    let receipt: [String: Any] = [
                        "outcome": outcome,
                        "dispatched": dispatched,
                        "page_changed": diff["changed"] ?? false,
                        "goal_verified": goalVerified,
                        "retry": Self.webMountRetryAdvice(dispatched: dispatched),
                        "verified": verified,
                        "verification_source": verificationSource,
                        "before_snapshot_id": before["snapshot_id"] as? String ?? "",
                        "after_snapshot_id": after["snapshot_id"] as? String ?? result["snapshot_id"] as? String ?? "",
                        "changed_fields": diff["changed_fields"] ?? [],
                        "precondition": IOSWebMountRedactor.redactedJSONObject(preconditionResult ?? [:]),
                        "postcondition": IOSWebMountRedactor.redactedJSONObject(postconditionResult ?? [:])
                    ]
                    var response: [String: Any] = [
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
                        "dispatched": dispatched,
                        "page_changed": diff["changed"] ?? false,
                        "goal_verified": goalVerified,
                        "readiness_met": readinessOnly && (method == "wait"
                            ? result["matched"] as? Bool == true : postconditionMatched),
                        "retry": Self.webMountRetryAdvice(dispatched: dispatched),
                        "verified": verified,
                        "before_snapshot_id": before["snapshot_id"] as? String ?? "",
                        "snapshot_id": after["snapshot_id"] as? String ?? result["snapshot_id"] as? String ?? "",
                        "before": IOSWebMountRedactor.redactedJSONObject(before),
                        "after": IOSWebMountRedactor.redactedJSONObject(after),
                        "diff": diff,
                        "action_receipt": receipt,
                        "action": IOSWebMountRedactor.redactedJSONObject(result)
                    ]
                    if (dispatched && !verified) || (method == "wait" && !verified) {
                        response["final_observation"] = await boundedFinalObservation(runtime: runtime)
                    }
                    return Self.json(response)
                } catch {
                    touch(sessionId: runtime.snapshot.sessionId, context: context)
                    let mayHaveApplied = mutating && actionStarted && dispatchEvidence != false
                    var response: [String: Any] = [
                        "ok": false,
                        "tool": toolName,
                        "session_id": runtime.snapshot.sessionId,
                        "status": mayHaveApplied ? "unknown_after_action" : "failed",
                        "error_code": mayHaveApplied ? "unknown_after_action" : "runtime_error",
                        "may_have_applied": mayHaveApplied,
                        "dispatched": dispatchEvidence.map { $0 as Any } ?? (mayHaveApplied ? NSNull() : false as Any),
                        "page_changed": NSNull(),
                        "goal_verified": false,
                        "retry": Self.webMountRetryAdvice(dispatched: mayHaveApplied),
                        "verified": false,
                        "error": IOSWebMountRedactor.redactedText(error.localizedDescription)
                    ]
                    if mayHaveApplied && !Task.isCancelled {
                        response["final_observation"] = await boundedFinalObservation(runtime: runtime)
                    }
                    return Self.json(response)
                }
            default:
                return Self.unsupportedToolResult(toolName: toolName)
            }
        } catch let error as IOSWebMountVisionReader.RequestFailure {
            return Self.json([
                "ok": false,
                "tool": toolName,
                "error_code": "vision_request_failed",
                "visual_verified": false,
                "dom_only": true,
                "automatic_retry_allowed": false,
                "error": error.localizedDescription,
                "diagnostics": error.diagnostics
            ])
        } catch let error as IOSWebMountVisionReader.Error {
            return Self.json([
                "ok": false, "tool": toolName, "error_code": "vision_unavailable",
                "visual_verified": false, "dom_only": true, "automatic_retry_allowed": false,
                "error": error.localizedDescription,
                "diagnostics": ["stage": "vision_preflight"]
            ])
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
        var args = Self.parseObject(input)
        if let conflict = Self.webMountTargetConflict(toolName: toolName, args: args) { return conflict }
        if (args["selector"] as? String)?.nilIfBlank == nil
            || (args["selector"] as? String)?.nilIfBlank == (args["target"] as? String)?.nilIfBlank {
            args.removeValue(forKey: "selector")
        }
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
            let selector = (args["target"] as? String)?.nilIfBlank
                ?? (args["selector"] as? String)?.nilIfBlank
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
            "count": sessionStore.activeRecords.count,
            "sessions": sessionStore.activeRecords.map(sessionDictionary)
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
            "sessions": sessionStore.activeRecords.map(sessionDictionary)
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
            "sessions": sessionStore.activeRecords.map(sessionDictionary)
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
           postcondition["require_page_change"] as? Bool == true
            || !desktopBackend.supportsVerifiedWait(
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
            let readinessOnly = ["ready_state", "dom_stable", "document_changed", "url_changed"]
                .contains(postcondition?["condition"] as? String ?? "")
            let verified = postcondition != nil && postconditionMatched && !preconditionMatched && !readinessOnly
            let postconditionPreexisting = postcondition != nil && preconditionMatched
            let postconditionFailed = postcondition != nil && (!postconditionMatched || preconditionMatched)
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
                "dispatched": true,
                "page_changed": NSNull(),
                "goal_verified": verified,
                "readiness_met": readinessOnly && postconditionMatched,
                "retry": Self.webMountRetryAdvice(dispatched: true),
                "verified": verified,
                "action_receipt": [
                    "outcome": verified ? "verified" : "ambiguous",
                    "dispatched": true,
                    "page_changed": NSNull(),
                    "goal_verified": verified,
                    "retry": Self.webMountRetryAdvice(dispatched: true),
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
            allowUnlistedHosts: allowUnlistedHosts,
            allowFakeIPFallback: true
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
        "wm_state", "wm_observe", "wm_extract", "wm_get", "wm_visual_snapshot", "wm_screenshot", "wm_visual_read",
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
                loginStatus = "not_required"
            case .cookie:
                if summary.hasLoginCookie == false {
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
                "login_verified": false,
                "authentication_required": site.authKind != .anonymous,
                "authentication_evidence": site.authKind == .anonymous ? "not_required"
                    : (summary.hasLoginCookie == true ? "cookie_present_unverified" : "none"),
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
            allowUnlistedHosts: allowUnlistedHosts,
            allowFakeIPFallback: true
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
                "error_code": error.errorCode,
                "reason": error.localizedDescription,
                "url": IOSWebMountRedactor.redactedURL(rawURL) ?? ""
            ])
        case .success(let url):
            let timeout = UInt64((args["timeout_ms"] as? Int) ?? 30_000).clamped(to: 1_000...60_000)
            if let sessionId = (args["session_id"] as? String)?.nilIfBlank,
               let record = sessionStore.record(sessionId: sessionId),
               record.needsReopen {
                if let context, let owner = record.ownerConversationId, owner != context.conversationId {
                    throw IOSWebMountSessionError.sessionBindingMismatch(sessionId)
                }
                guard sessionStore.reopen(sessionId: sessionId) != nil else {
                    return Self.json([
                        "ok": false,
                        "denied": true,
                        "session_id": sessionId,
                        "error_code": "session_reopen_unavailable",
                        "reason": "WebMount session needs to be reopened, but its runtime is unavailable."
                    ])
                }
            }
            let runtime = try sessionRuntime(from: args, context: context)
            sessionStore.showCard(sessionId: runtime.snapshot.sessionId)
            (runtime as? IOSWebMountWKRuntime)?.setNavigationPolicy(
                policy,
                site: site,
                resolveHost: resolveHost
            )
            sessionStore.tag(sessionId: runtime.snapshot.sessionId, site: site)
            let before = try? await runtime.state()
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
            let after = try? await runtime.state()
            let pageChanged: Any
            if let before, let after {
                pageChanged = Self.webMountStateDiff(before: before, after: after)["changed"] ?? false
            } else {
                pageChanged = NSNull()
            }
            var response: [String: Any] = [
                "ok": snapshot.status != .failed,
                "session_id": snapshot.sessionId,
                "status": timedOut ? "unknown_after_action" : snapshot.status.rawValue,
                "error_code": timedOut ? "unknown_after_action" : "",
                "may_have_applied": timedOut,
                "dispatched": snapshot.status == .failed ? NSNull() : true as Any,
                "page_changed": pageChanged,
                "goal_verified": false,
                "navigation_ready": snapshot.status == .ready,
                "url": snapshot.currentURL ?? snapshot.requestedURL ?? "",
                "title": IOSWebMountRedactor.redactedText(snapshot.title ?? ""),
                "error": IOSWebMountRedactor.redactedText(snapshot.error ?? ""),
                "waited": true
            ]
            if snapshot.status == .failed {
                response["final_observation"] = await boundedFinalObservation(runtime: runtime)
            }
            return Self.json(response)
        }
    }

    private static func runtimeFailure(_ result: [String: Any], sessionId: String) -> String? {
        guard result["ok"] as? Bool == false else { return nil }
        var failure = result
        failure["session_id"] = sessionId
        return json(IOSWebMountRedactor.redactedJSONObject(failure))
    }

    private func stateResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?
    ) async throws -> String {
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let page = try await runtime.state()
        if let failure = Self.runtimeFailure(page, sessionId: runtime.snapshot.sessionId) { return failure }
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
        let maxChars = ((args["max_chars"] as? Int) ?? 2_000).clamped(to: 0...8_000)
        let maxLinks = ((args["max_links"] as? Int) ?? 20).clamped(to: 0...40)
        let observation = try await runtime.observe(maxChars: maxChars, maxLinks: maxLinks)
        if let failure = Self.runtimeFailure(observation, sessionId: runtime.snapshot.sessionId) { return failure }
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
            "truncated_fields": observation["truncated_fields"] ?? [],
            "redaction_applied": true,
            "read_more": "Use wm_find for a local target, then wm_get with session_id, snapshot_id and target. Use wm_extract with max_chars for more page text.",
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
        if let failure = Self.runtimeFailure(result, sessionId: runtime.snapshot.sessionId) { return failure }
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
        if let expectedSnapshot = (args["snapshot_id"] as? String)?.nilIfBlank {
            let page = try await runtime.state()
            guard page["snapshot_id"] as? String == expectedSnapshot else {
                return Self.json(["ok": false, "error_code": "stale_snapshot", "requires_reobserve": true,
                                  "session_id": runtime.snapshot.sessionId, "snapshot_id": page["snapshot_id"] ?? ""])
            }
        }
        let result = try await runtime.get(
            selector: (args["selector"] as? String)?.nilIfBlank,
            target: (args["target"] as? String)?.nilIfBlank,
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
        if let failure = Self.runtimeFailure(result, sessionId: runtime.snapshot.sessionId) { return failure }
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

    private func visualReadResult(
        args: [String: Any],
        context: IOSWebMountExecutionContext?,
        reader: IOSWebMountVisualReadHandler?
    ) async throws -> String {
        guard let reader else {
            return Self.json(["ok": false, "error_code": "vision_unavailable", "visual_verified": false,
                              "dom_only": true, "automatic_retry_allowed": false,
                              "reason": "No vision model reader is connected. Visual verification was not performed."])
        }
        let question = (args["question"] as? String)?.nilIfBlank
            ?? "Describe the visible page, loading errors, dialogs and controls. Verify whether the intended browser action visibly succeeded; state uncertainty."
        guard question.count <= 4_000 else {
            return Self.json(["ok": false, "error_code": "invalid_arguments", "reason": "question must be at most 4000 characters."])
        }
        let runtime = try sessionRuntime(from: args, context: context, requiresControl: false)
        let before = try await runtime.state()
        let snapshotId = before["snapshot_id"] as? String ?? ""
        let capturedAt = IOSWebMountClock.nowMillis()
        let capture = try await runtime.screenshot()
        let afterCapture = try await runtime.state()
        guard !snapshotId.isEmpty, afterCapture["snapshot_id"] as? String == snapshotId else {
            return Self.json(["ok": false, "error_code": "page_changed", "requires_reobserve": true, "reason": "The page changed during capture. Wait for a stable page and retry visual reading."])
        }
        try Task.checkCancellation()
        let analysis = try await reader(capture, question)
        try Task.checkCancellation()
        let current = try? await runtime.state()
        let stale = current?["snapshot_id"] as? String != snapshotId
            || sessionStore.record(sessionId: runtime.snapshot.sessionId) == nil
        touch(sessionId: runtime.snapshot.sessionId, context: context)
        return Self.json([
            "ok": !stale,
            "tool": "wm_visual_read",
            "session_id": runtime.snapshot.sessionId,
            "snapshot_id": snapshotId,
            "captured_at_ms": capturedAt,
            "width": capture.width,
            "height": capture.height,
            "verification_source": "screenshot",
            "observation_only": true,
            "untrusted_page_content": true,
            "requires_reobserve": stale,
            "error_code": stale ? "stale_visual_read" : "",
            "reason": stale ? "The page changed while the vision model was reading. This analysis describes an older screenshot; observe again before acting." : "",
            "analysis": IOSWebMountRedactor.redactedText(String(analysis.prefix(16_000)))
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
              ["selector", "text", "url_contains", "ready_state", "dom_stable", "document_changed", "url_changed"].contains(condition) else {
            return nil
        }
        let value = (raw["value"] as? String)?.nilIfBlank
        if !["dom_stable", "document_changed", "url_changed"].contains(condition), value == nil {
            return nil
        }
        if condition == "ready_state",
           !["interactive", "complete"].contains(value?.lowercased() ?? "") {
            return nil
        }
        var options: [String: Any] = ["condition": condition]
        if let requireChange = raw["require_page_change"] as? Bool {
            options["require_page_change"] = requireChange
        }
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
        let keys = ["document_id", "url", "url_revision", "dom_revision", "title", "text_length", "links_count", "scroll"]
        let changedFields = keys.filter { key in
            !NSDictionary(dictionary: ["value": before[key] ?? NSNull()])
                .isEqual(to: ["value": after[key] ?? NSNull()])
        }
        return [
            "changed": !changedFields.isEmpty,
            "changed_fields": changedFields,
            "revision_changed": String(describing: before["snapshot_id"] ?? NSNull()) != String(describing: after["snapshot_id"] ?? NSNull())
        ]
    }

    private static func webMountTargetConflict(toolName: String, args: [String: Any]) -> String? {
        guard interactionMutatingToolNames.contains(toolName) || ["wm_get", "wm_find", "wm_wait"].contains(toolName),
              let target = (args["target"] as? String)?.nilIfBlank,
              let selector = (args["selector"] as? String)?.nilIfBlank,
              target != selector else { return nil }
        return json([
            "ok": false, "tool": toolName, "status": "rejected", "error_code": "conflicting_target_arguments",
            "dispatched": false, "page_changed": false, "goal_verified": false, "may_have_applied": false,
            "reason": "target and selector identify different targets. Use the observed target ref and omit selector.",
            "retry": webMountRetryAdvice(dispatched: false)
        ])
    }

    private static func webMountRetryAdvice(dispatched: Bool) -> [String: Any] {
        ["automatic_retry_allowed": false,
         "risk": dispatched ? "duplicate_side_effect_possible" : "not_dispatched",
         "next_step": dispatched
            ? "Inspect final_observation or re-observe. Reconcile the intended effect before repeating an action; a failed wait does not mean the action failed."
            : "Correct the rejected arguments or permission issue, then observe again before issuing a new action."]
    }

    private func boundedFinalObservation(runtime: IOSWebMountRuntimeServicing) async -> [String: Any] {
        do {
            let observation = try await runtime.observe(maxChars: 1_200, maxLinks: 6)
            let page = observation["page"] as? [String: Any] ?? [:]
            return IOSWebMountRedactor.redactedJSONObject([
                "available": true,
                "session_id": runtime.snapshot.sessionId,
                "snapshot_id": observation["snapshot_id"] ?? page["snapshot_id"] ?? "",
                "page": page,
                "visible_text": observation["visible_text"] ?? "",
                "interactive_elements": Array((observation["interactive_elements"] as? [[String: Any]] ?? []).prefix(8)),
                "links": Array((observation["links"] as? [[String: Any]] ?? []).prefix(6)),
                "bounded": true, "untrusted_page_content": true, "redaction_applied": true,
                "read_more": "wm_observe or wm_find, followed by wm_get on a fresh target ref"
            ]) as? [String: Any] ?? [:]
        } catch {
            return ["available": false, "error_code": "final_observation_unavailable", "requires_reobserve": true]
        }
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
