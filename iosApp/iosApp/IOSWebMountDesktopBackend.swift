import Foundation
import Observation
import WebKit


@MainActor
@Observable
final class IOSWebMountDesktopBackendAdapter {
    typealias ClientFactory = @MainActor () -> any IOSMcpClienting

    static let safeBrowserToolNames: Set<String> = [
        "browser_navigate",
        "browser_navigate_forward",
        "browser_navigate_back",
        "browser_snapshot",
        "browser_extract",
        "browser_get",
        "browser_find",
        "browser_click",
        "browser_type",
        "browser_press_key",
        "browser_select_option",
        "browser_wait_for"
    ]

    private struct Connection {
        let backend: IOSWebMountBackendKind
        let serverName: String
        let config: IOSMcpServerConfig
        let client: any IOSMcpClienting
        let tools: [String: IOSWebMountDesktopToolDescriptor]
    }

    private let clientFactory: ClientFactory
    private let endpointPolicy: IOSWebMountDesktopEndpointPolicy
    private var connections: [String: Connection] = [:]
    private var snapshotIDs: [String: String] = [:]
    private var snapshotElements: [String: [IOSWebMountDesktopSemanticElement]] = [:]
    private var snapshotPageIdentities: [String: IOSWebMountDesktopPageIdentity] = [:]
    private var snapshotRevisions: [String: Int] = [:]

    private(set) var statuses: [String: IOSWebMountDesktopBackendStatus] = [:]

    init(
        clientFactory: @escaping ClientFactory = { IOSMcpClient(requestTimeoutSeconds: 30) },
        endpointPolicy: IOSWebMountDesktopEndpointPolicy = .init()
    ) {
        self.clientFactory = clientFactory
        self.endpointPolicy = endpointPolicy
    }

    func connect(
        logicalSessionId: String,
        backend: IOSWebMountBackendKind,
        config: IOSMcpServerConfig
    ) async throws {
        guard backend != .local else { throw IOSWebMountDesktopBackendError.localBackend }
        _ = try endpointPolicy.validate(config)
        let sessionId = try normalizedSessionID(logicalSessionId)
        close(logicalSessionId: sessionId)
        statuses[sessionId] = .connecting
        let client = clientFactory()
        do {
            _ = try await client.connect(config: config)
            let discovered = try await client.listTools()
            let enabledConfigured: Set<String>? = config.tools.isEmpty
                ? nil
                : Set(config.tools.filter(\.enabled).map(\.name))
            let tools = Dictionary(uniqueKeysWithValues: discovered.compactMap { tool -> (String, IOSWebMountDesktopToolDescriptor)? in
                guard Self.safeBrowserToolNames.contains(tool.name), tool.enabled else { return nil }
                if let enabledConfigured, !enabledConfigured.contains(tool.name) { return nil }
                return (
                    tool.name,
                    IOSWebMountDesktopToolDescriptor(
                        tool: tool,
                        inputProperties: IOSWebMountDesktopMappingPolicy.inputProperties(from: tool.inputSchema)
                    )
                )
            })
            guard IOSWebMountDesktopMappingPolicy.minimumToolNames.isSubset(of: tools.keys) else {
                throw IOSWebMountDesktopBackendError.minimumCapabilitiesMissing
            }
            connections[sessionId] = Connection(
                backend: backend,
                serverName: config.name,
                config: config,
                client: client,
                tools: tools
            )
            statuses[sessionId] = .connected
        } catch {
            client.disconnect()
            connections.removeValue(forKey: sessionId)
            snapshotIDs.removeValue(forKey: sessionId)
            snapshotElements.removeValue(forKey: sessionId)
            snapshotPageIdentities.removeValue(forKey: sessionId)
            snapshotRevisions.removeValue(forKey: sessionId)
            statuses[sessionId] = .failed(Self.redactedError(error))
            throw error
        }
    }

    func execute(
        toolName: String,
        arguments: [String: Any],
        logicalSessionId: String,
        approvedHighConsequence: Bool = false,
        canDispatchMutation: (() -> Bool)? = nil
    ) async -> String {
        let sessionId: String
        do {
            sessionId = try normalizedSessionID(logicalSessionId)
        } catch {
            return failureOutput(
                toolName: toolName,
                sessionId: logicalSessionId,
                connection: nil,
                error: error,
                mayHaveApplied: false
            )
        }
        guard !toolName.hasPrefix("browser_") else {
            return failureOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connections[sessionId],
                error: IOSWebMountDesktopBackendError.unsafeBrowserTool(toolName),
                mayHaveApplied: false
            )
        }
        guard IOSWebMountDesktopMappingPolicy.mappings[toolName] != nil else {
            return failureOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connections[sessionId],
                error: IOSWebMountDesktopBackendError.mappingUnsupported(toolName),
                mayHaveApplied: false
            )
        }
        guard let connection = connections[sessionId], statuses[sessionId] == .connected else {
            return failureOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connections[sessionId],
                error: IOSWebMountDesktopBackendError.notConnected(sessionId),
                mayHaveApplied: false
            )
        }
        if toolName == "wm_tap", arguments["x"] != nil || arguments["y"] != nil {
            return failureOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connection,
                error: IOSWebMountDesktopBackendError.mappingUnsupported("coordinate tap"),
                mayHaveApplied: false
            )
        }

        var didDispatchMutation = false
        do {
            let mapping = try IOSWebMountDesktopMappingPolicy.resolvedMapping(
                toolName: toolName,
                arguments: arguments,
                tools: connection.tools
            )
            guard let remoteTool = connection.tools[mapping.remoteToolName] else {
                throw IOSWebMountDesktopBackendError.gatewayToolMissing(mapping.remoteToolName)
            }
            if mapping.requiresSnapshot {
                guard let expected = snapshotIDs[sessionId],
                      (arguments["snapshot_id"] as? String)?.nilIfBlank == expected else {
                    throw IOSWebMountDesktopBackendError.staleSnapshot
                }
            }
            if let preflight = actionPreflightOutput(
                toolName: toolName,
                arguments: arguments,
                sessionId: sessionId,
                connection: connection,
                approvedHighConsequence: approvedHighConsequence
            ) {
                return preflight
            }
            if mapping.requiresSnapshot, mapping.mutating {
                let priorTarget: IOSWebMountDesktopSemanticElement
                guard let priorPageIdentity = snapshotPageIdentities[sessionId] else {
                    throw IOSWebMountDesktopBackendError.staleSnapshot
                }
                switch toolName {
                case "wm_click", "wm_tap", "wm_type", "wm_select":
                    let target = try IOSWebMountDesktopMappingPolicy.semanticTarget(arguments, toolName: toolName)
                    guard let element = IOSWebMountDesktopSemantics.semanticElement(
                        matching: target,
                        arguments: arguments,
                        elements: snapshotElements[sessionId] ?? []
                    ) else {
                        throw IOSWebMountDesktopBackendError.staleSnapshot
                    }
                    priorTarget = element
                case "wm_keys":
                    guard let element = snapshotElements[sessionId]?.first(where: { $0.focused == true }) else {
                        throw IOSWebMountDesktopBackendError.staleSnapshot
                    }
                    priorTarget = element
                default:
                    throw IOSWebMountDesktopBackendError.staleSnapshot
                }
                guard let snapshotTool = connection.tools["browser_snapshot"] else {
                    throw IOSWebMountDesktopBackendError.gatewayToolMissing("browser_snapshot")
                }
                let freshRawResult = try await connection.client.callTool(
                    name: snapshotTool.tool.name,
                    arguments: [:]
                )
                if let remoteError = IOSWebMountDesktopSemantics.remoteErrorMessage(from: freshRawResult) {
                    throw IOSMcpClientError.rpcError(remoteError)
                }
                let freshElements = IOSWebMountDesktopSemantics.semanticElements(
                    from: freshRawResult,
                    backend: connection.backend,
                    remoteToolName: snapshotTool.tool.name
                )
                let freshPageIdentity = IOSWebMountDesktopSemantics.pageIdentity(
                    from: freshRawResult,
                    backend: connection.backend
                )
                guard !freshElements.isEmpty,
                      let freshPageIdentity,
                      priorPageIdentity.matches(freshPageIdentity) else {
                    snapshotIDs.removeValue(forKey: sessionId)
                    snapshotElements.removeValue(forKey: sessionId)
                    snapshotPageIdentities.removeValue(forKey: sessionId)
                    throw IOSWebMountDesktopBackendError.staleSnapshot
                }
                let freshTarget: IOSWebMountDesktopSemanticElement?
                if toolName == "wm_keys" {
                    freshTarget = freshElements.first(where: { $0.focused == true })
                } else {
                    let target = try IOSWebMountDesktopMappingPolicy.semanticTarget(arguments, toolName: toolName)
                    freshTarget = IOSWebMountDesktopSemantics.semanticElement(
                        matching: target,
                        arguments: arguments,
                        elements: freshElements
                    )
                }
                guard let freshTarget, priorTarget.hasSameIdentity(as: freshTarget) else {
                    snapshotIDs.removeValue(forKey: sessionId)
                    snapshotElements.removeValue(forKey: sessionId)
                    snapshotPageIdentities.removeValue(forKey: sessionId)
                    throw IOSWebMountDesktopBackendError.staleSnapshot
                }
                snapshotElements[sessionId] = freshElements
                snapshotPageIdentities[sessionId] = freshPageIdentity
                snapshotRevisions[sessionId, default: 0] += 1
            }
            if let preflight = actionPreflightOutput(
                toolName: toolName,
                arguments: arguments,
                sessionId: sessionId,
                connection: connection,
                approvedHighConsequence: approvedHighConsequence
            ) {
                return preflight
            }
            let mapped = try IOSWebMountDesktopMappingPolicy.mappedArguments(
                toolName: toolName,
                arguments: arguments,
                remoteTool: remoteTool,
                elements: snapshotElements[sessionId] ?? []
            )
            if mapping.mutating, canDispatchMutation?() == false {
                throw IOSWebMountDesktopBackendError.controlUnavailable
            }
            didDispatchMutation = mapping.mutating
            let rawResult = try await connection.client.callTool(
                name: mapping.remoteToolName,
                arguments: mapped
            )
            if let remoteError = IOSWebMountDesktopSemantics.remoteErrorMessage(from: rawResult) {
                throw IOSMcpClientError.rpcError(remoteError)
            }
            let semanticElements = IOSWebMountDesktopSemantics.semanticElements(
                from: rawResult,
                backend: connection.backend,
                remoteToolName: mapping.remoteToolName
            )
            let snapshotID: String?
            let containsSnapshot = mapping.remoteToolName == "browser_snapshot"
                || (connection.backend == .playwright_mcp
                    && IOSWebMountDesktopSemantics.playwrightResponseContainsSnapshot(rawResult))
            let carriesSemanticTargets = !semanticElements.isEmpty
                && ["browser_find", "browser_extract"].contains(mapping.remoteToolName)
            if containsSnapshot || carriesSemanticTargets {
                let generated = "remote_" + String(UUID().uuidString.prefix(12))
                snapshotIDs[sessionId] = generated
                snapshotElements[sessionId] = semanticElements
                if let pageIdentity = IOSWebMountDesktopSemantics.pageIdentity(from: rawResult, backend: connection.backend) {
                    snapshotPageIdentities[sessionId] = pageIdentity
                } else if containsSnapshot {
                    snapshotPageIdentities.removeValue(forKey: sessionId)
                }
                snapshotRevisions[sessionId, default: 0] += 1
                snapshotID = generated
            } else {
                if mapping.mutating {
                    snapshotIDs.removeValue(forKey: sessionId)
                    snapshotElements.removeValue(forKey: sessionId)
                    snapshotPageIdentities.removeValue(forKey: sessionId)
                }
                snapshotID = nil
            }
            return successOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connection,
                rawResult: rawResult,
                snapshotID: snapshotID,
                semanticElements: semanticElements
            )
        } catch {
            let mayHaveApplied = didDispatchMutation && Self.mayBeUnknownAfterDispatch(error)
            if let clientError = error as? IOSMcpClientError, clientError == .mcpSessionExpired {
                statuses[sessionId] = .needsReopen
                connections.removeValue(forKey: sessionId)?.client.disconnect()
                snapshotIDs.removeValue(forKey: sessionId)
                snapshotElements.removeValue(forKey: sessionId)
                snapshotPageIdentities.removeValue(forKey: sessionId)
                snapshotRevisions.removeValue(forKey: sessionId)
            }
            return failureOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connection,
                error: error,
                mayHaveApplied: mayHaveApplied
            )
        }
    }

    func preflightAction(
        toolName: String,
        arguments: [String: Any],
        logicalSessionId: String
    ) -> String? {
        guard let sessionId = try? normalizedSessionID(logicalSessionId),
              let mapping = IOSWebMountDesktopMappingPolicy.mappings[toolName],
              mapping.mutating,
              let connection = connections[sessionId],
              statuses[sessionId] == .connected else {
            return nil
        }
        if toolName == "wm_tap", arguments["x"] != nil || arguments["y"] != nil {
            return failureOutput(
                toolName: toolName,
                sessionId: sessionId,
                connection: connection,
                error: IOSWebMountDesktopBackendError.mappingUnsupported("coordinate tap"),
                mayHaveApplied: false
            )
        }
        if mapping.requiresSnapshot {
            guard let expected = snapshotIDs[sessionId],
                  (arguments["snapshot_id"] as? String)?.nilIfBlank == expected else {
                return failureOutput(
                    toolName: toolName,
                    sessionId: sessionId,
                    connection: connection,
                    error: IOSWebMountDesktopBackendError.staleSnapshot,
                    mayHaveApplied: false
                )
            }
        }
        return actionPreflightOutput(
            toolName: toolName,
            arguments: arguments,
            sessionId: sessionId,
            connection: connection,
            approvedHighConsequence: false
        )
    }

    func status(logicalSessionId: String) -> IOSWebMountDesktopBackendStatus {
        statuses[logicalSessionId] ?? .idle
    }

    func capabilities(logicalSessionId: String) -> [IOSWebMountDesktopCapability] {
        let connection = connections[logicalSessionId]
        return IOSWebMountDesktopMappingPolicy.mappings.keys.sorted().compactMap { toolName in
            guard let mapping = IOSWebMountDesktopMappingPolicy.mappings[toolName] else { return nil }
            let available = connection.map {
                IOSWebMountDesktopMappingPolicy.mappingIsAvailable(toolName: toolName, mapping: mapping, tools: $0.tools)
            } ?? false
            return IOSWebMountDesktopCapability(
                amberToolName: toolName,
                remoteToolName: mapping.remoteToolName,
                available: available
            )
        }
    }

    func supportsVerifiedWait(
        arguments: [String: Any],
        logicalSessionId: String
    ) -> Bool {
        guard let connection = connections[logicalSessionId],
              statuses[logicalSessionId] == .connected,
              let mapping = IOSWebMountDesktopMappingPolicy.mappings["wm_wait"],
              let remoteTool = connection.tools[mapping.remoteToolName],
              remoteTool.explicitlySupports("timeout_ms") || remoteTool.explicitlySupports("timeout"),
              (try? IOSWebMountDesktopMappingPolicy.mappedArguments(
                toolName: "wm_wait",
                arguments: arguments,
                remoteTool: remoteTool,
                elements: snapshotElements[logicalSessionId] ?? []
              )) != nil else {
            return false
        }
        return true
    }

    func allowsCurrentConfiguration(
        _ config: IOSMcpServerConfig,
        toolName: String,
        logicalSessionId: String
    ) -> Bool {
        guard let connection = connections[logicalSessionId],
              connection.config == config,
              config.enabled,
              (try? endpointPolicy.validate(config)) != nil else {
            return false
        }
        guard let mapping = IOSWebMountDesktopMappingPolicy.mappings[toolName] else { return true }
        if config.tools.isEmpty { return true }
        return config.tools.first(where: { $0.name == mapping.remoteToolName })?.enabled == true
    }

    func close(logicalSessionId: String) {
        connections.removeValue(forKey: logicalSessionId)?.client.disconnect()
        snapshotIDs.removeValue(forKey: logicalSessionId)
        snapshotElements.removeValue(forKey: logicalSessionId)
        snapshotPageIdentities.removeValue(forKey: logicalSessionId)
        snapshotRevisions.removeValue(forKey: logicalSessionId)
        statuses[logicalSessionId] = .closed
    }

    private func actionPreflightOutput(
        toolName: String,
        arguments: [String: Any],
        sessionId: String,
        connection: Connection,
        approvedHighConsequence: Bool
    ) -> String? {
        let disposition: IOSWebMountDesktopActionDisposition
        switch toolName {
        case "wm_keys":
            guard let element = snapshotElements[sessionId]?.first(where: { $0.focused == true }) else {
                disposition = .human(reason: "focused_target_unconfirmed", label: "focused element")
                break
            }
            disposition = IOSWebMountDesktopSemantics.actionDisposition(element: element, toolName: toolName, arguments: arguments)
        case "wm_click", "wm_tap", "wm_type", "wm_select":
            let target: String
            do {
                target = try IOSWebMountDesktopMappingPolicy.semanticTarget(arguments, toolName: toolName)
            } catch {
                return failureOutput(
                    toolName: toolName,
                    sessionId: sessionId,
                    connection: connection,
                    error: error,
                    mayHaveApplied: false
                )
            }
            guard let element = IOSWebMountDesktopSemantics.semanticElement(
                matching: target,
                arguments: arguments,
                elements: snapshotElements[sessionId] ?? []
            ) else {
                return failureOutput(
                    toolName: toolName,
                    sessionId: sessionId,
                    connection: connection,
                    error: IOSWebMountDesktopBackendError.staleSnapshot,
                    mayHaveApplied: false
                )
            }
            disposition = IOSWebMountDesktopSemantics.actionDisposition(element: element, toolName: toolName, arguments: arguments)
        case "wm_get":
            let target: String
            do {
                target = try IOSWebMountDesktopMappingPolicy.semanticTarget(arguments, toolName: toolName)
            } catch {
                return failureOutput(
                    toolName: toolName,
                    sessionId: sessionId,
                    connection: connection,
                    error: error,
                    mayHaveApplied: false
                )
            }
            guard let element = IOSWebMountDesktopSemantics.semanticElement(
                matching: target,
                arguments: arguments,
                elements: snapshotElements[sessionId] ?? []
            ) else {
                return failureOutput(
                    toolName: toolName,
                    sessionId: sessionId,
                    connection: connection,
                    error: IOSWebMountDesktopBackendError.staleSnapshot,
                    mayHaveApplied: false
                )
            }
            let kind = (IOSWebMountDesktopMappingPolicy.string(arguments, "kind") ?? "text").lowercased()
            guard IOSWebMountDesktopSemantics.isVisibleAndSafe(element, kind: kind) else {
                disposition = .human(reason: "read_target_unconfirmed", label: element.name?.nilIfBlank ?? "page element")
                break
            }
            disposition = .safe
        default:
            disposition = .safe
        }

        switch disposition {
        case .safe:
            return nil
        case .approval(let reason, let label):
            guard !approvedHighConsequence else { return nil }
            var output = baseOutput(toolName: toolName, sessionId: sessionId, connection: connection)
            output.merge([
                "ok": false,
                "status": "approval_required",
                "error_code": "high_consequence_requires_approval",
                "needs_user_action": true,
                "reason": "This desktop page action may submit, authorize, pay, send, publish, delete, or otherwise change remote state.",
                "consequence": reason,
                "target_label": IOSWebMountRedactor.redactedText(label),
                "snapshot_id": snapshotIDs[sessionId] ?? "",
                "may_have_applied": false
            ]) { _, new in new }
            return Self.json(output)
        case .human(let reason, let label):
            var output = baseOutput(toolName: toolName, sessionId: sessionId, connection: connection)
            output.merge([
                "ok": false,
                "status": "requires_human",
                "error_code": "sensitive_field_requires_human",
                "requires_human": true,
                "handoff": true,
                "reason": "Login, verification, CAPTCHA, and payment secrets stay in local user-controlled WebMount.",
                "handoff_reason": reason,
                "resume_condition": "Complete the sensitive step in local WebMount, then return control to the Agent.",
                "target_label": IOSWebMountRedactor.redactedText(label),
                "snapshot_id": snapshotIDs[sessionId] ?? "",
                "may_have_applied": false
            ]) { _, new in new }
            return Self.json(output)
        }
    }

    private func normalizedSessionID(_ value: String) throws -> String {
        guard let value = value.nilIfBlank else {
            throw IOSWebMountDesktopBackendError.invalidArguments("session_id is required.")
        }
        return value
    }

    private static func mayBeUnknownAfterDispatch(_ error: Error) -> Bool {
        if error is IOSWebMountDesktopBackendError { return false }
        if error is CancellationError { return true }
        guard let error = error as? IOSMcpClientError else { return true }
        switch error {
        case .httpStatus(let status):
            return status >= 500
        case .rpcError:
            return true
        case .mcpSessionExpired, .toolNotFound, .toolDisabled,
             .serverNotFound, .serverDisabled, .notConnected, .invalidURL, .unsafeEndpoint:
            return false
        case .invalidResponse, .requestTimedOut, .unsupportedContent:
            return true
        }
    }

    private func successOutput(
        toolName: String,
        sessionId: String,
        connection: Connection,
        rawResult: String,
        snapshotID: String?,
        semanticElements: [IOSWebMountDesktopSemanticElement]
    ) -> String {
        let result = Self.sanitizedValue(
            rawResult,
            removeURLFields: IOSWebMountDesktopMappingPolicy.mappings[toolName]?.mutating == true
        )
        let remoteObject = rawResult.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let remoteMayHaveApplied = remoteObject?["may_have_applied"] as? Bool == true
        let remoteStatus = (remoteObject?["status"] as? String)?.nilIfBlank
        let remoteOutcomeUnknown = IOSWebMountDesktopMappingPolicy.mappings[toolName]?.mutating == true
            && (remoteMayHaveApplied
                || remoteStatus.map { ["unknown_after_action", "ambiguous"].contains($0) } == true)
        var output: [String: Any] = baseOutput(
            toolName: toolName,
            sessionId: sessionId,
            connection: connection
        )
        output.merge([
            "ok": !remoteOutcomeUnknown,
            "status": remoteOutcomeUnknown ? (remoteStatus ?? "unknown_after_action") : "completed",
            "mapped_tool": toolName,
            "may_have_applied": remoteOutcomeUnknown,
            "result": result
        ]) { _, new in new }
        if remoteOutcomeUnknown {
            output["error_code"] = (remoteObject?["error_code"] as? String)?.nilIfBlank
                ?? "unknown_after_action"
            output["verified"] = false
            output["needs_reopen"] = true
        }
        if let currentURL = IOSWebMountDesktopSemantics.topLevelCurrentURL(from: rawResult, backend: connection.backend),
           let redactedURL = IOSWebMountRedactor.redactedURL(currentURL) {
            output["current_url"] = redactedURL
        }
        if toolName == "wm_state" || toolName == "wm_observe" {
            output["state"] = result
        }
        if let snapshotID { output["snapshot_id"] = snapshotID }
        if toolName == "wm_wait" {
            let matched = Self.waitMatched(from: rawResult)
            output["matched"] = matched ?? false
            output["match_explicit"] = matched != nil
        }
        if toolName == "wm_observe" {
            output.merge(
                IOSWebMountDesktopSemantics.normalizedObservation(
                    rawResult: rawResult,
                    sessionId: sessionId,
                    backend: connection.backend,
                    snapshotID: snapshotID,
                    pageRevision: snapshotRevisions[sessionId] ?? 0,
                    semanticElements: semanticElements
                )
            ) { _, normalized in normalized }
        }
        return Self.json(output)
    }

    private func failureOutput(
        toolName: String,
        sessionId: String,
        connection: Connection?,
        error: Error,
        mayHaveApplied: Bool
    ) -> String {
        var output = baseOutput(toolName: toolName, sessionId: sessionId, connection: connection)
        let errorCode: String
        if let error = error as? IOSWebMountDesktopBackendError {
            errorCode = error.errorCode
        } else if let error = error as? IOSMcpClientError, error == .mcpSessionExpired {
            errorCode = "mcp_session_expired"
        } else {
            errorCode = mayHaveApplied ? "unknown_after_action" : "desktop_gateway_unavailable"
        }
        output.merge([
            "ok": false,
            "status": mayHaveApplied ? "unknown_after_action" : "failed",
            "error_code": errorCode,
            "may_have_applied": mayHaveApplied,
            "verified": false,
            "error": Self.redactedError(error)
        ]) { _, new in new }
        if (error as? IOSWebMountDesktopBackendError) == .controlUnavailable {
            output["status"] = "rejected"
        }
        if error is IOSWebMountDesktopBackendError,
           (error as? IOSWebMountDesktopBackendError) == .sensitiveFieldRequiresHuman {
            output["requires_human"] = true
            output["handoff"] = true
            output["resume_condition"] = "Complete the sensitive step in local WebMount, then return control to the Agent."
        }
        return Self.json(output)
    }

    private func baseOutput(
        toolName: String,
        sessionId: String,
        connection: Connection?
    ) -> [String: Any] {
        let capabilities = connection.map { connection in
            IOSWebMountDesktopMappingPolicy.mappings.keys.sorted().filter { mappedToolName in
                guard let mapping = IOSWebMountDesktopMappingPolicy.mappings[mappedToolName] else { return false }
                return IOSWebMountDesktopMappingPolicy.mappingIsAvailable(
                    toolName: mappedToolName,
                    mapping: mapping,
                    tools: connection.tools
                )
            }
        } ?? []
        return [
            "contract_version": "webmount.desktop.v2",
            "tool": toolName,
            "session_id": sessionId,
            "backend": connection?.backend.rawValue ?? "desktop",
            "mcp_server_name": connection?.serverName ?? "",
            "capabilities": capabilities,
            "untrusted_page_content": true,
            "redacted": true
        ]
    }

    private static func sanitizedValue(
        _ text: String,
        removeURLFields: Bool = false
    ) -> Any {
        let clipped = String(text.prefix(40_000))
        guard let data = clipped.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return IOSWebMountRedactor.redactedText(clipped)
        }
        let sanitized = removeURLFields ? IOSWebMountDesktopSemantics.removingURLFields(from: value) : value
        return IOSWebMountRedactor.redactedJSONObject(sanitized)
    }

    private static func waitMatched(from text: String) -> Bool? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["matched"] as? NSNumber)?.boolValue
    }

    private static func redactedError(_ error: Error) -> String {
        String(IOSWebMountRedactor.redactedText(error.localizedDescription).prefix(2_000))
    }

    private static func json(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ), let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"status":"failed","error_code":"serialization_error","redacted":true}"#
        }
        return text
    }
}
