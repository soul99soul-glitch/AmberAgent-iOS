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

@MainActor
final class IOSWebMountController {
    static let shared = IOSWebMountController(sessionDefaults: .standard)

    let registry: IOSWebMountRegistry
    let settings: IOSWebMountSettings
    let cookieStore: IOSWebMountCookieStoreProtocol
    let sessionStore: IOSWebMountSessionStore
    let desktopBackend: IOSWebMountDesktopBackendAdapter
    let mcpServerProvider: () -> [IOSMcpServerConfig]
    let resolveHost: IOSWebMountHostResolver

    private lazy var localCommands = IOSWebMountLocalCommands(controller: self, stations: stationCommands)
    private lazy var desktopCommands = IOSWebMountDesktopCommands(controller: self)
    private lazy var stationCommands = IOSWebMountStationCommands(controller: self)

    func desktopStatus(sessionId: String) -> IOSWebMountDesktopBackendStatus {
        desktopCommands.desktopStatus(sessionId: sessionId)
    }

    func desktopCapabilities(sessionId: String) -> [IOSWebMountDesktopCapability] {
        desktopCommands.desktopCapabilities(sessionId: sessionId)
    }

    func reconnectDesktopSession(sessionId: String) async -> String {
        await desktopCommands.reconnectDesktopSession(sessionId: sessionId)
    }

    func siteMemoryApprovalLines(input: String) -> [String]? {
        stationCommands.siteMemoryApprovalLines(input: input)
    }

    func siteMemoryApprovalBaseline(input: String) -> String? {
        stationCommands.siteMemoryApprovalBaseline(input: input)
    }

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
        resolveHost: @escaping IOSWebMountHostResolver = IOSPublicURLPolicy.resolveIPAddresses
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

    func reloadForUser(sessionId: String) -> IOSWebMountRuntimeSnapshot {
        let runtime = sessionStore.runtimeIfPresent(sessionId: sessionId) as? IOSWebMountWKRuntime
        var failure = runtime?.snapshot ?? .idle(sessionId: sessionId)
        failure.status = .failed
        failure.updatedAtMillis = IOSWebMountClock.nowMillis()
        guard let record = sessionStore.record(sessionId: sessionId),
              record.backend == .local,
              let runtime else {
            failure.error = "此站点会话不存在或无法在本机重新加载，请重新打开站点。"
            return failure
        }
        guard record.controlOwner == .user else {
            failure.error = "请先接管页面，再重新加载。"
            return failure
        }
        guard !record.needsReopen else {
            failure.error = "此站点会话需要重新打开，请先打开站点。"
            return failure
        }
        let snapshot = runtime.reload()
        sessionStore.touch(sessionId: sessionId)
        return snapshot
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
        if payload["session_id"] == nil,
           let requestedSessionId = (Self.parseObject(input)["session_id"] as? String)?.nilIfBlank,
           let record = sessionStore.record(sessionId: requestedSessionId),
           record.backend == .local {
            let canAssociateWithRun: Bool
            if let context {
                canAssociateWithRun = context.hasCompleteBinding
                    && (record.ownerConversationId == nil || record.ownerConversationId == context.conversationId)
            } else {
                canAssociateWithRun = true
            }
            if canAssociateWithRun {
                payload["session_id"] = requestedSessionId
            }
        }
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

    func executeResult(
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
                if toolName == "wm_act" {
                    // wm_act 是宿主复合工具（逐步走本管道），无 desktop 网关映射——
                    // 落入 desktopResult 只会得到误导性的 mapping_unsupported。
                    return Self.json(["ok": false, "error_code": "unsupported_backend", "reason": "wm_act currently supports local WKWebView sessions only."])
                }
                return try await desktopCommands.desktopResult(
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
                return await stationCommands.stationsResult(args: args)
            case "wm_tab_list":
                return tabListResult()
            case "wm_tab_new":
                return try await tabNewResult(args: args, isUserInitiated: isUserInitiated, context: context)
            case "wm_tab_close":
                return try tabCloseResult(args: args, context: context)
            case "wm_open":
                return try await localCommands.openResult(
                    args: args,
                    context: context,
                    allowUnlistedHosts: allowUnlistedHosts
                )
            case "wm_state":
                return try await localCommands.stateResult(args: args, context: context)
            case "wm_observe":
                return try await localCommands.observeResult(args: args, context: context)
            case "wm_act":
                return try await localCommands.actResult(
                    args: args,
                    isUserInitiated: isUserInitiated,
                    context: context,
                    allowUnlistedHosts: allowUnlistedHosts,
                    visualRead: visualRead
                )
            case "wm_extract":
                return try await localCommands.extractResult(args: args, context: context)
            case "wm_get":
                return try await localCommands.getResult(args: args, context: context)
            case "wm_visual_snapshot":
                return try await localCommands.visualSnapshotResult(args: args, context: context)
            case "wm_visual_read":
                guard isUserInitiated else {
                    return Self.json(["ok": false, "needs_user_action": true, "reason": "Visual reading sends the viewport screenshot to the configured vision provider and requires foreground approval."])
                }
                return try await localCommands.visualReadResult(args: args, context: context, reader: visualRead)
            case "wm_screenshot":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Viewport screenshots require an explicit foreground user action"
                    ])
                }
                return try await localCommands.screenshotResult(args: args, context: context)
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
                if let page = try? await runtime.state() {
                    _ = localCommands.pageDrift(sessionId: snapshot.sessionId, page: page, context: context)
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
                if let page = try? await runtime.state() {
                    _ = localCommands.pageDrift(sessionId: snapshot.sessionId, page: page, context: context)
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
                return try await localCommands.clearSessionResult(args: args)
            case "wm_site_add":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Adding a WebMount station requires an explicit foreground user action"
                    ])
                }
                return try stationCommands.siteAddResult(args: args)
            case "wm_site_remove":
                guard isUserInitiated else {
                    return Self.json([
                        "ok": false,
                        "tool": toolName,
                        "needs_user_action": true,
                        "reason": "Removing a WebMount station requires an explicit foreground user action"
                    ])
                }
                return try stationCommands.siteRemoveResult(args: args)
            case "wm_site_memory":
                return stationCommands.siteMemoryResult(args: args, isUserInitiated: isUserInitiated)
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
                        var postconditionOptions = postcondition
                        postconditionOptions["_amber_preserve_action_target"] = true
                        postconditionResult = try await runtime.interact(
                            method: "wait",
                            selector: nil,
                            text: nil,
                            options: postconditionOptions
                        )
                    }
                    let after = try await runtime.state()
                    if result["ok"] as? Bool == true {
                        _ = localCommands.pageDrift(sessionId: runtime.snapshot.sessionId, page: after, context: context)
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
                    let diff = Self.webMountStateDiff(before: before, after: after, method: method)
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
                    var receipt: [String: Any] = [
                        "outcome": outcome,
                        "dispatched": dispatched,
                        "page_changed": diff["changed"] ?? false,
                        "unattributed_page_activity": diff["unattributed_page_activity"] ?? false,
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
                    if let locator = result["locator"] as? [String: Any] {
                        receipt["locator"] = IOSWebMountRedactor.redactedJSONObject(locator)
                    }
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
                        "unattributed_page_activity": diff["unattributed_page_activity"] ?? false,
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

    func sessionRuntime(
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

    func touch(sessionId: String, context: IOSWebMountExecutionContext?) {
        sessionStore.touch(
            sessionId: sessionId,
            makeCurrent: context?.isAgentInvocation != true
        )
    }

    func agentOwnershipLost(
        sessionId: String,
        context: IOSWebMountExecutionContext?
    ) -> Bool {
        guard let context, context.isAgentInvocation else { return false }
        let record = sessionStore.record(sessionId: sessionId)
        return record?.controlOwner != .agent || record?.ownerRunId != context.runId
    }

    static func localNavigationOwnershipUnknown(
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
                    "error_code": IOSWebMountDesktopCommands.desktopErrorCode(error),
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
        "wm_stations", "wm_tab_list", "wm_tab_new", "wm_tab_close", "wm_site_add", "wm_site_remove", "wm_site_memory"
    ]

    private static let localSessionPolicyToolNames: Set<String> = [
        "wm_state", "wm_observe", "wm_extract", "wm_get", "wm_visual_snapshot", "wm_screenshot", "wm_visual_read",
        "wm_back", "wm_forward", "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll",
        "wm_select", "wm_find", "wm_wait", "wm_act"
    ]

    static let desktopMutatingToolNames: Set<String> = [
        "wm_open", "wm_back", "wm_forward", "wm_click", "wm_tap", "wm_type",
        "wm_keys", "wm_scroll", "wm_select", "wm_clear_session"
    ]

    static let interactionMutatingToolNames: Set<String> = [
        "wm_click", "wm_tap", "wm_type", "wm_keys", "wm_scroll", "wm_select"
    ]

    func siteFromArgs(_ args: [String: Any]) -> IOSWebMountSite? {
        if let siteId = (args["site_id"] as? String)?.nilIfBlank {
            return registry.site(id: siteId)
        }
        if let rawURL = args["url"] as? String,
           let url = URL(string: rawURL) {
            return registry.site(for: url)
        }
        return nil
    }

    static func webMountPostconditionOptions(from args: [String: Any]) -> [String: Any]? {
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

    static func webMountStateDiff(before: [String: Any], after: [String: Any], method: String? = nil) -> [String: Any] {
        let keys = ["document_id", "url", "url_revision", "dom_revision", "title", "text_length", "links_count", "scroll"]
        let changedFields = keys.filter { key in
            !NSDictionary(dictionary: ["value": before[key] ?? NSNull()])
                .isEqual(to: ["value": after[key] ?? NSNull()])
        }
        let navigationChanged = changedFields.contains { ["document_id", "url", "url_revision"].contains($0) }
        let targetChanged = after["target_region_changed"] as? Bool == true
            || after["focus_changed"] as? Bool == true
            || after["new_dialog"] as? Bool == true
            || (method == "scroll" && changedFields.contains("scroll"))
        let attributed = navigationChanged || targetChanged
        let unrelatedChanged = changedFields.contains { !["document_id", "url", "url_revision"].contains($0) }
        return [
            "changed": attributed,
            "changed_fields": changedFields,
            "unattributed_page_activity": !attributed && unrelatedChanged,
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

    static func webMountRetryAdvice(dispatched: Bool) -> [String: Any] {
        ["automatic_retry_allowed": false,
         "risk": dispatched ? "duplicate_side_effect_possible" : "not_dispatched",
         "next_step": dispatched
            ? "Inspect final_observation or re-observe. Reconcile the intended effect before repeating an action; a failed wait does not mean the action failed."
            : "Correct the rejected arguments or permission issue, then observe again before issuing a new action."]
    }

    func boundedFinalObservation(runtime: IOSWebMountRuntimeServicing) async -> [String: Any] {
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

    static func parseObject(_ input: String) -> [String: Any] {
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

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
