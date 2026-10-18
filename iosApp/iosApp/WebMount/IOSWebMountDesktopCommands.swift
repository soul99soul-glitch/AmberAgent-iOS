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
final class IOSWebMountDesktopCommands {
    private unowned let controller: IOSWebMountController
    private var sessionStore: IOSWebMountSessionStore { controller.sessionStore }
    private var desktopBackend: IOSWebMountDesktopBackendAdapter { controller.desktopBackend }
    private var registry: IOSWebMountRegistry { controller.registry }
    private var settings: IOSWebMountSettings { controller.settings }
    private var mcpServerProvider: () -> [IOSMcpServerConfig] { controller.mcpServerProvider }
    private var resolveHost: IOSWebMountHostResolver { controller.resolveHost }

    init(controller: IOSWebMountController) {
        self.controller = controller
    }

    func desktopStatus(sessionId: String) -> IOSWebMountDesktopBackendStatus {
        desktopBackend.status(logicalSessionId: sessionId)
    }

    func desktopCapabilities(sessionId: String) -> [IOSWebMountDesktopCapability] {
        desktopBackend.capabilities(logicalSessionId: sessionId)
    }

    func reconnectDesktopSession(sessionId: String) async -> String {
        guard let record = sessionStore.record(sessionId: sessionId), record.backend != .local else {
            return IOSWebMountController.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "session_not_found"
            ])
        }
        guard let siteId = record.siteId,
              let site = registry.site(id: siteId) else {
            return IOSWebMountController.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "site_binding_required",
                "reason": "Remote WebMount sessions require a registered bound site."
            ])
        }
        guard site.enabled else {
            return IOSWebMountController.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "site_disabled",
                "site_id": site.id,
                "reason": "WebMount station is disabled"
            ])
        }
        guard site.authKind == .anonymous else {
            return IOSWebMountController.json([
                "ok": false,
                "session_id": sessionId,
                "error_code": "local_privacy_session_required",
                "reason": "Login, OAuth, and App-private stations stay in local WKWebView."
            ])
        }
        guard let serverName = record.mcpServerName,
              let config = mcpServerProvider().first(where: { $0.name == serverName }) else {
            return IOSWebMountController.json([
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
            return IOSWebMountController.json([
                "ok": true,
                "session_id": sessionId,
                "backend": record.backend.rawValue,
                "mcp_server_name": serverName,
                "status": "connected",
                "capabilities": desktopCapabilities(sessionId: sessionId).filter(\.available).map(\.amberToolName)
            ])
        } catch {
            return IOSWebMountController.json([
                "ok": false,
                "session_id": sessionId,
                "backend": record.backend.rawValue,
                "mcp_server_name": serverName,
                "error_code": Self.desktopErrorCode(error),
                "reason": IOSWebMountRedactor.redactedText(error.localizedDescription)
            ])
        }
    }

    func desktopResult(
        toolName: String,
        args: [String: Any],
        record: IOSWebMountSessionRecord,
        isUserInitiated: Bool,
        context: IOSWebMountExecutionContext?,
        allowUnlistedHosts: Bool
    ) async throws -> String {
        guard let siteId = record.siteId,
              let site = registry.site(id: siteId) else {
            return IOSWebMountController.json([
                "ok": false,
                "tool": toolName,
                "session_id": record.id,
                "backend": record.backend.rawValue,
                "error_code": "site_binding_required",
                "reason": "Remote WebMount sessions require a registered bound site."
            ])
        }
        guard site.enabled else {
            return IOSWebMountController.json([
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
            return IOSWebMountController.json([
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
        let requiresControl = IOSWebMountController.desktopMutatingToolNames.contains(toolName)
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
           IOSWebMountController.desktopMutatingToolNames.contains(toolName) {
            let usesRawPageTarget = args["selector"] != nil || args["x"] != nil || args["y"] != nil
            let requiresSemanticTarget = ["wm_click", "wm_tap", "wm_type", "wm_select"].contains(toolName)
            let hasSemanticTarget = (args["target"] as? String)?.nilIfBlank != nil
            if usesRawPageTarget || (requiresSemanticTarget && !hasSemanticTarget) {
                return IOSWebMountController.json([
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
            return IOSWebMountController.json([
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

        let postcondition = IOSWebMountController.interactionMutatingToolNames.contains(toolName)
            ? Self.webMountRemotePostconditionOptions(from: args)
            : nil
        if IOSWebMountController.interactionMutatingToolNames.contains(toolName),
           args["postcondition"] != nil,
           postcondition == nil {
            return IOSWebMountController.json([
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
            return IOSWebMountController.json([
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
            preconditionObject = IOSWebMountController.parseObject(probeOutput)
            guard preconditionObject?["ok"] as? Bool == true,
                  preconditionObject?["match_explicit"] as? Bool == true else {
                sessionStore.touch(sessionId: record.id, makeCurrent: false)
                return IOSWebMountController.json([
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
                return IOSWebMountController.json([
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
            if let requestedSite = controller.siteFromArgs(args), requestedSite.id != site.id {
                return IOSWebMountController.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "error_code": "session_binding_mismatch",
                    "reason": "Remote navigation must use the session's bound WebMount station."
                ])
            }
            guard site.enabled else {
                return IOSWebMountController.json([
                    "ok": false,
                    "tool": toolName,
                    "session_id": record.id,
                    "error_code": "host_not_allowed",
                    "reason": "Desktop navigation requires an enabled registered WebMount station."
                ])
            }
            guard site.authKind == .anonymous else {
                return IOSWebMountController.json([
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
                return IOSWebMountController.json([
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
                    return IOSWebMountController.json([
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
            return IOSWebMountController.json([
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
            approvedHighConsequence: isUserInitiated,
            canDispatchMutation: { !ownershipLost() }
        )
        let actionObject = IOSWebMountController.parseObject(output)
        let interactionMutation = IOSWebMountController.interactionMutatingToolNames.contains(toolName)
        let desktopMutation = IOSWebMountController.desktopMutatingToolNames.contains(toolName)
        let actionSucceeded = actionObject["ok"] as? Bool == true
        let actionMayHaveApplied = actionObject["may_have_applied"] as? Bool == true
        let actionDispatched = desktopMutation && (actionSucceeded || actionMayHaveApplied)

        func unknownAfterControlChange(postconditionResult: [String: Any]? = nil) -> String {
            if Self.remoteNavigationToolNames.contains(toolName) {
                sessionStore.markNeedsReopen(sessionId: record.id)
            }
            return IOSWebMountController.json([
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
            postconditionObject = IOSWebMountController.parseObject(postconditionOutput)
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
                "retry": IOSWebMountController.webMountRetryAdvice(dispatched: true),
                "verified": verified,
                "action_receipt": [
                    "outcome": verified ? "verified" : "ambiguous",
                    "dispatched": true,
                    "page_changed": NSNull(),
                    "goal_verified": verified,
                    "retry": IOSWebMountController.webMountRetryAdvice(dispatched: true),
                    "verified": verified,
                    "verification_source": verified ? "postcondition" : "",
                    "before_snapshot_id": args["snapshot_id"] as? String ?? "",
                    "after_snapshot_id": actionObject["snapshot_id"] as? String ?? "",
                    "precondition": IOSWebMountRedactor.redactedJSONObject(preconditionObject ?? [:]),
                    "postcondition": IOSWebMountRedactor.redactedJSONObject(postconditionObject ?? [:])
                ],
                "action": IOSWebMountRedactor.redactedJSONObject(actionObject)
            ]) { _, new in new }
            output = IOSWebMountController.json(composed)
        }
        (sessionStore.runtimeIfPresent(sessionId: record.id) as? IOSWebMountRemotePlaceholderRuntime)?
            .apply(resultText: output, toolName: toolName, requestedURL: requestedURL)
        let outputObject = IOSWebMountController.parseObject(output)
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
                    let stateObject = IOSWebMountController.parseObject(stateOutput)
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
        IOSWebMountController.json([
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

    static func desktopErrorCode(_ error: Error) -> String {
        if let error = error as? IOSWebMountDesktopBackendError { return error.errorCode }
        if let error = error as? IOSMcpClientError, error == .mcpSessionExpired {
            return "mcp_session_expired"
        }
        if error is IOSWebMountDesktopEndpointPolicyError {
            return "desktop_endpoint_rejected"
        }
        return "desktop_gateway_unavailable"
    }

    private static func webMountRemotePostconditionOptions(from args: [String: Any]) -> [String: Any]? {
        guard var options = IOSWebMountController.webMountPostconditionOptions(from: args) else { return nil }
        if let timeout = options.removeValue(forKey: "wait_ms") {
            options["timeout_ms"] = timeout
        } else {
            options["timeout_ms"] = 5_000
        }
        return options
    }

}
