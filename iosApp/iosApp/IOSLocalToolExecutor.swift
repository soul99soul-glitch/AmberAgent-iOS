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
    let siteMemoryChanges: [String]?
    let siteMemoryBaseline: String?
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
                if request.toolName == "wm_site_memory",
                   !request.isUserInitiated,
                   !webMountAllowsUnlistedHosts(request: request, capability: capability),
                   Self.webMountInputObject(request.operation)["action"] as? String == "propose" {
                    if webMountApprovalPreview(toolName: request.toolName, input: request.operation) == nil {
                        let invalid = await webMountController.execute(
                            toolName: request.toolName, input: request.operation, isUserInitiated: false,
                            context: webMountContext
                        )
                        return .webMountResult(invalid)
                    }
                    return .needsUserAction("确认这批站点记忆变更后将保存到本机。")
                }
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
                // A batch may already have dispatched earlier steps. Return its
                // partial result so consequence approval cannot replay it.
                // Human handoff still uses its completion card without replay.
                if request.toolName == "wm_act",
                   Self.webMountUserActionReason(output) != nil {
                    return .webMountResult(output)
                }
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
        if toolName == "wm_site_memory", object["action"] as? String == "propose",
           webMountController.siteMemoryApprovalLines(input: input) == nil { return nil }
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
        let hostSite = (object["host"] as? String)?.nilIfBlank.flatMap { host in
            webMountController.registry.sites.first {
                IOSWebMountURLPolicy.host(host, matchesAnyOf: $0.allowedHosts)
            }
        }
        let site = requestedSite ?? urlSite ?? recordSite ?? hostSite
        let host = (toolName == "wm_site_memory" ? (object["host"] as? String)?.nilIfBlank : nil)
            ?? site?.homepageHost
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
                : nil,
            siteMemoryChanges: toolName == "wm_site_memory"
                ? webMountController.siteMemoryApprovalLines(input: input) : nil,
            siteMemoryBaseline: toolName == "wm_site_memory"
                ? webMountController.siteMemoryApprovalBaseline(input: input) : nil
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
        // wm_act 批量内某步触发 requires_human 时，交接同样发生在会话级
        // （输入带 session_id）——不在白名单内会让审批卡永远无法完成。
        guard ["wm_click", "wm_tap", "wm_type", "wm_keys", "wm_select", "wm_act"].contains(toolName) else {
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
        guard ["wm_click", "wm_tap", "wm_type", "wm_keys", "wm_select", "wm_act"].contains(toolName),
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
        case "wm_site_memory": "修改站点记忆"
        case "wm_act": "按顺序执行一批网页动作"
        case "wm_run_goal": "自动执行网页目标"
        default: toolName
        }
    }

    private static func webMountApprovalTarget(toolName: String, object: [String: Any]) -> String? {
        if toolName == "wm_tap", let x = object["x"], let y = object["y"] {
            return IOSWebMountRedactor.redactedText("viewport (\(x), \(y))")
        }
        // wm_act 的"目标"是整批步骤：摘要动作序列让用户看到要批准什么。
        if toolName == "wm_act",
           let steps = object["steps"] as? [[String: Any]], !steps.isEmpty {
            let actions = steps.map { (($0["action"] as? String) ?? "?").lowercased() }
            return IOSWebMountRedactor.redactedText(
                actions.joined(separator: " → ") + "（共 \(actions.count) 步）"
            )
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
        case "wm_site_memory":
            return "批准后会将卡片列出的条目变更保存到本机站点记忆。"
        case "wm_click", "wm_tap", "wm_keys", "wm_select", "wm_type":
            if let target, target.localizedCaseInsensitiveContains("enter") {
                return "可能提交当前表单；执行前会再次核对页面快照。"
            }
            return "可能提交、授权或改变远端状态；批准只绑定当前页面快照与目标。"
        case "wm_act":
            return "会按顺序执行最多 8 个页面动作；每一步仍按页面快照、目标与后果门校验，中途导航或高后果步骤会自动停止。"
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
