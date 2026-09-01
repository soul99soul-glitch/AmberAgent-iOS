import Foundation
import Observation
import WebKit

enum IOSWebMountBackendKind: String, Codable, CaseIterable, Identifiable {
    case local
    case moli
    case playwright_mcp
    case steel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            IOSAppLocalization.string("本地 WKWebView", defaultValue: "本地 WKWebView")
        case .moli:
            IOSAppLocalization.string("Moli", defaultValue: "Moli")
        case .playwright_mcp:
            IOSAppLocalization.string("Playwright MCP", defaultValue: "Playwright MCP")
        case .steel:
            IOSAppLocalization.string("Steel", defaultValue: "Steel")
        }
    }
}

enum IOSWebMountDesktopEndpointPolicyError: Error, Equatable, LocalizedError {
    case disabled
    case unsupportedTransport
    case invalidURL
    case httpsRequired
    case missingHost
    case userInfoNotAllowed
    case loopbackHost

    var errorDescription: String? {
        switch self {
        case .disabled: "Desktop WebMount MCP server is disabled."
        case .unsupportedTransport: "Desktop WebMount requires Streamable HTTP."
        case .invalidURL: "Desktop WebMount endpoint is invalid."
        case .httpsRequired: "Desktop WebMount endpoint must use HTTPS."
        case .missingHost: "Desktop WebMount endpoint has no host."
        case .userInfoNotAllowed: "Desktop WebMount endpoint must not contain URL userinfo."
        case .loopbackHost: "A mobile device cannot reach a desktop through localhost or loopback."
        }
    }
}

struct IOSWebMountDesktopEndpointPolicy {
    func validate(_ config: IOSMcpServerConfig) throws -> URL {
        guard config.enabled else { throw IOSWebMountDesktopEndpointPolicyError.disabled }
        guard case .streamableHTTP = config else {
            throw IOSWebMountDesktopEndpointPolicyError.unsupportedTransport
        }
        guard let components = URLComponents(
            string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let url = components.url else {
            throw IOSWebMountDesktopEndpointPolicyError.invalidURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw IOSWebMountDesktopEndpointPolicyError.httpsRequired
        }
        guard let host = components.host?.lowercased().nilIfBlank else {
            throw IOSWebMountDesktopEndpointPolicyError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw IOSWebMountDesktopEndpointPolicyError.userInfoNotAllowed
        }
        guard !Self.isLoopback(host) else {
            throw IOSWebMountDesktopEndpointPolicyError.loopbackHost
        }
        return url
    }

    private static func isLoopback(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
            .lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }
        if host.hasPrefix("127.") || host == "0.0.0.0" || host == "::" {
            return true
        }
        if host.hasPrefix("::ffff:") {
            return isLoopback(String(host.dropFirst(7)))
        }
        return false
    }
}

enum IOSWebMountDesktopBackendStatus: Equatable {
    case idle
    case connecting
    case connected
    case needsReopen
    case failed(String)
    case closed

    var code: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .needsReopen: "needs_reopen"
        case .failed: "failed"
        case .closed: "closed"
        }
    }

    var title: String {
        switch self {
        case .idle:
            IOSAppLocalization.string("未连接", defaultValue: "未连接")
        case .connecting:
            IOSAppLocalization.string("连接中", defaultValue: "连接中")
        case .connected:
            IOSAppLocalization.string("已连接", defaultValue: "已连接")
        case .needsReopen:
            IOSAppLocalization.string("需要重新连接", defaultValue: "需要重新连接")
        case .failed:
            IOSAppLocalization.string("连接失败", defaultValue: "连接失败")
        case .closed:
            IOSAppLocalization.string("已关闭", defaultValue: "已关闭")
        }
    }
}

struct IOSWebMountDesktopCapability: Equatable, Identifiable {
    let amberToolName: String
    let remoteToolName: String
    let available: Bool

    var id: String { amberToolName }
}

enum IOSWebMountDesktopBackendError: Error, Equatable, LocalizedError {
    case localBackend
    case missingConfiguration
    case invalidArguments(String)
    case mappingUnsupported(String)
    case unsafeBrowserTool(String)
    case gatewayToolMissing(String)
    case minimumCapabilitiesMissing
    case notConnected(String)
    case sensitiveFieldRequiresHuman
    case staleSnapshot

    var errorCode: String {
        switch self {
        case .localBackend: "invalid_backend"
        case .missingConfiguration: "desktop_backend_not_configured"
        case .invalidArguments: "invalid_arguments"
        case .mappingUnsupported: "mapping_unsupported"
        case .unsafeBrowserTool: "unsafe_tool_blocked"
        case .gatewayToolMissing, .minimumCapabilitiesMissing: "desktop_gateway_tool_missing"
        case .notConnected: "desktop_gateway_unavailable"
        case .sensitiveFieldRequiresHuman: "sensitive_field_requires_human"
        case .staleSnapshot: "stale_snapshot"
        }
    }

    var errorDescription: String? {
        switch self {
        case .localBackend: "The local backend does not use the desktop MCP adapter."
        case .missingConfiguration: "Desktop WebMount has no MCP server configuration."
        case .invalidArguments(let message): message
        case .mappingUnsupported(let tool): "No safe desktop mapping exists for \(tool)."
        case .unsafeBrowserTool(let tool): "Unsafe browser tool is blocked: \(tool)."
        case .gatewayToolMissing(let tool): "Desktop gateway did not advertise \(tool)."
        case .minimumCapabilitiesMissing: "Desktop gateway must advertise browser_navigate and browser_snapshot."
        case .notConnected: "Desktop WebMount session is not connected."
        case .sensitiveFieldRequiresHuman: "Sensitive fields stay in local, user-controlled WebMount."
        case .staleSnapshot: "Observe the page again before mutating this desktop session."
        }
    }
}

private struct IOSWebMountDesktopMapping {
    let remoteToolName: String
    let mutating: Bool
    let requiresSnapshot: Bool
}

private struct IOSWebMountDesktopToolDescriptor {
    let tool: IOSMcpTool
    let inputProperties: Set<String>?

    func explicitlySupports(_ name: String) -> Bool {
        inputProperties?.contains(name) == true
    }
}

private struct IOSWebMountDesktopSemanticElement: Equatable {
    let refs: Set<String>
    let selectors: Set<String>
    let role: String?
    let name: String?
    let inputType: String?
    let tag: String?
    let visible: Bool?
    let focused: Bool?
    let actionable: Bool?
    let disabled: Bool?

    func matchesReference(_ target: String) -> Bool {
        refs.contains(target)
    }

    func matchesSelector(_ target: String) -> Bool {
        selectors.contains(target)
    }

    func hasSameIdentity(as other: Self) -> Bool {
        [role, name, inputType, tag].map(Self.normalizedIdentityPart)
            == [other.role, other.name, other.inputType, other.tag].map(Self.normalizedIdentityPart)
    }

    private static func normalizedIdentityPart(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfBlank
    }

    var contractDictionary: [String: Any] {
        var value: [String: Any] = [:]
        if let ref = refs.sorted().first { value["ref"] = ref }
        if let selector = selectors.sorted().first { value["selector"] = selector }
        if let role { value["role"] = role }
        if let name { value["name"] = name }
        if let inputType { value["input_type"] = inputType }
        if let tag { value["tag"] = tag }
        if let visible { value["visible"] = visible }
        if let focused { value["focused"] = focused }
        if let actionable { value["actionable"] = actionable }
        if let disabled { value["disabled"] = disabled }
        return value
    }
}

private struct IOSWebMountDesktopPageIdentity: Equatable {
    let documentID: String?
    let currentURL: String?

    func matches(_ other: Self) -> Bool {
        if documentID != nil || other.documentID != nil {
            return documentID != nil && documentID == other.documentID
        }
        return currentURL != nil && currentURL == other.currentURL
    }
}

private enum IOSWebMountDesktopActionDisposition {
    case safe
    case approval(reason: String, label: String)
    case human(reason: String, label: String)
}

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

    private static let minimumToolNames: Set<String> = [
        "browser_navigate", "browser_snapshot"
    ]

    private static let mappings: [String: IOSWebMountDesktopMapping] = [
        "wm_open": .init(remoteToolName: "browser_navigate", mutating: true, requiresSnapshot: false),
        "wm_forward": .init(remoteToolName: "browser_navigate_forward", mutating: true, requiresSnapshot: false),
        "wm_back": .init(remoteToolName: "browser_navigate_back", mutating: true, requiresSnapshot: false),
        "wm_state": .init(remoteToolName: "browser_snapshot", mutating: false, requiresSnapshot: false),
        "wm_observe": .init(remoteToolName: "browser_snapshot", mutating: false, requiresSnapshot: false),
        "wm_extract": .init(remoteToolName: "browser_extract", mutating: false, requiresSnapshot: false),
        "wm_get": .init(remoteToolName: "browser_get", mutating: false, requiresSnapshot: true),
        "wm_find": .init(remoteToolName: "browser_find", mutating: false, requiresSnapshot: false),
        "wm_click": .init(remoteToolName: "browser_click", mutating: true, requiresSnapshot: true),
        "wm_tap": .init(remoteToolName: "browser_click", mutating: true, requiresSnapshot: true),
        "wm_type": .init(remoteToolName: "browser_type", mutating: true, requiresSnapshot: true),
        "wm_keys": .init(remoteToolName: "browser_press_key", mutating: true, requiresSnapshot: true),
        "wm_select": .init(remoteToolName: "browser_select_option", mutating: true, requiresSnapshot: true),
        "wm_wait": .init(remoteToolName: "browser_wait_for", mutating: false, requiresSnapshot: false)
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
                        inputProperties: Self.inputProperties(from: tool.inputSchema)
                    )
                )
            })
            guard Self.minimumToolNames.isSubset(of: tools.keys) else {
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
        approvedHighConsequence: Bool = false
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
        guard Self.mappings[toolName] != nil else {
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
            let mapping = try resolvedMapping(
                toolName: toolName,
                arguments: arguments,
                connection: connection
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
                    let target = try semanticTarget(arguments, toolName: toolName)
                    guard let element = semanticElement(
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
                if let remoteError = Self.remoteErrorMessage(from: freshRawResult) {
                    throw IOSMcpClientError.rpcError(remoteError)
                }
                let freshElements = Self.semanticElements(
                    from: freshRawResult,
                    backend: connection.backend,
                    remoteToolName: snapshotTool.tool.name
                )
                let freshPageIdentity = Self.pageIdentity(
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
                    let target = try semanticTarget(arguments, toolName: toolName)
                    freshTarget = semanticElement(
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
            let mapped = try mappedArguments(
                toolName: toolName,
                arguments: arguments,
                remoteTool: remoteTool,
                sessionId: sessionId
            )
            didDispatchMutation = mapping.mutating
            let rawResult = try await connection.client.callTool(
                name: mapping.remoteToolName,
                arguments: mapped
            )
            if let remoteError = Self.remoteErrorMessage(from: rawResult) {
                throw IOSMcpClientError.rpcError(remoteError)
            }
            let semanticElements = Self.semanticElements(
                from: rawResult,
                backend: connection.backend,
                remoteToolName: mapping.remoteToolName
            )
            let snapshotID: String?
            let containsSnapshot = mapping.remoteToolName == "browser_snapshot"
                || (connection.backend == .playwright_mcp
                    && Self.playwrightResponseContainsSnapshot(rawResult))
            let carriesSemanticTargets = !semanticElements.isEmpty
                && ["browser_find", "browser_extract"].contains(mapping.remoteToolName)
            if containsSnapshot || carriesSemanticTargets {
                let generated = "remote_" + String(UUID().uuidString.prefix(12))
                snapshotIDs[sessionId] = generated
                snapshotElements[sessionId] = semanticElements
                if let pageIdentity = Self.pageIdentity(from: rawResult, backend: connection.backend) {
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
              let mapping = Self.mappings[toolName],
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
        return Self.mappings.keys.sorted().compactMap { toolName in
            guard let mapping = Self.mappings[toolName] else { return nil }
            let available = connection.map {
                Self.mappingIsAvailable(toolName: toolName, mapping: mapping, connection: $0)
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
              let mapping = Self.mappings["wm_wait"],
              let remoteTool = connection.tools[mapping.remoteToolName],
              remoteTool.explicitlySupports("timeout_ms") || remoteTool.explicitlySupports("timeout"),
              (try? mappedArguments(
                toolName: "wm_wait",
                arguments: arguments,
                remoteTool: remoteTool,
                sessionId: logicalSessionId
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
        guard let mapping = Self.mappings[toolName] else { return true }
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

    private func resolvedMapping(
        toolName: String,
        arguments: [String: Any],
        connection: Connection
    ) throws -> IOSWebMountDesktopMapping {
        guard let mapping = Self.mappings[toolName] else {
            throw IOSWebMountDesktopBackendError.mappingUnsupported(toolName)
        }
        guard connection.tools[mapping.remoteToolName] != nil else {
            if ["wm_forward", "wm_extract", "wm_get", "wm_find"].contains(toolName) {
                throw IOSWebMountDesktopBackendError.mappingUnsupported(toolName)
            }
            throw IOSWebMountDesktopBackendError.gatewayToolMissing(mapping.remoteToolName)
        }
        if toolName == "wm_extract" {
            let mode = string(arguments, "mode") ?? "readable"
            guard ["readable", "interactive", "snapshot"].contains(mode) else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_extract/\(mode)")
            }
        }
        if toolName == "wm_get",
           (string(arguments, "kind") ?? "text") == "attr",
           let attrName = string(arguments, "attr_name") {
            if attrName.caseInsensitiveCompare("value") == .orderedSame {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/attr=value")
            }
            if Self.isSensitiveTarget(attrName) {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/attr")
            }
        }
        return mapping
    }

    private static func mappingIsAvailable(
        toolName: String,
        mapping: IOSWebMountDesktopMapping,
        connection: Connection
    ) -> Bool {
        guard let remoteTool = connection.tools[mapping.remoteToolName] else { return false }
        switch toolName {
        case "wm_extract":
            return remoteTool.explicitlySupports("mode")
        case "wm_get":
            return remoteTool.explicitlySupports("kind")
                && supportsTarget(remoteTool)
        case "wm_find":
            return remoteTool.explicitlySupports("text")
                || remoteTool.explicitlySupports("regex")
                || remoteTool.explicitlySupports("selector")
        case "wm_click", "wm_tap":
            return supportsTarget(remoteTool)
        case "wm_type":
            return supportsTarget(remoteTool)
                && (remoteTool.explicitlySupports("text") || remoteTool.explicitlySupports("value"))
        case "wm_select":
            return supportsTarget(remoteTool) && remoteTool.explicitlySupports("values")
        case "wm_keys":
            return remoteTool.explicitlySupports("key")
        case "wm_wait":
            return remoteTool.explicitlySupports("text")
                || remoteTool.explicitlySupports("textGone")
                || remoteTool.explicitlySupports("time")
                || remoteTool.explicitlySupports("selector")
                || remoteTool.explicitlySupports("url_contains")
                || remoteTool.explicitlySupports("ready_state")
                || remoteTool.explicitlySupports("dom_stable")
        default:
            return true
        }
    }

    private static func supportsTarget(_ remoteTool: IOSWebMountDesktopToolDescriptor) -> Bool {
        remoteTool.explicitlySupports("selector")
            || remoteTool.explicitlySupports("target")
            || remoteTool.explicitlySupports("ref")
            || remoteTool.explicitlySupports("element")
    }

    private static func inputProperties(from schema: String?) -> Set<String>? {
        guard let schema,
              let data = schema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = object["properties"] as? [String: Any] else {
            return nil
        }
        return Set(properties.keys)
    }

    private func mappedArguments(
        toolName: String,
        arguments: [String: Any],
        remoteTool: IOSWebMountDesktopToolDescriptor,
        sessionId: String
    ) throws -> [String: Any] {
        switch toolName {
        case "wm_open":
            guard let url = string(arguments, "url") else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_open requires url.")
            }
            return applyingRemoteTimeout(
                from: arguments,
                remoteTool: remoteTool,
                to: ["url": url]
            )
        case "wm_back", "wm_forward", "wm_state", "wm_observe":
            return [:]
        case "wm_extract":
            let mode = string(arguments, "mode") ?? "readable"
            guard ["readable", "interactive", "snapshot"].contains(mode) else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_extract/\(mode)")
            }
            guard remoteTool.explicitlySupports("mode") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_extract/\(mode)")
            }
            var mapped: [String: Any] = ["mode": mode]
            if let maxChars = arguments["max_chars"], remoteTool.explicitlySupports("max_chars") {
                mapped["max_chars"] = maxChars
            }
            if let maxLinks = arguments["max_links"], remoteTool.explicitlySupports("max_links") {
                mapped["max_links"] = maxLinks
            }
            return mapped
        case "wm_get":
            let kind = string(arguments, "kind") ?? "text"
            guard ["text", "value", "attr"].contains(kind),
                  remoteTool.explicitlySupports("kind") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/\(kind)")
            }
            var mapped = try mappedTarget(arguments, remoteTool: remoteTool, toolName: toolName)
            if kind == "attr" {
                guard let attrName = string(arguments, "attr_name"),
                      remoteTool.explicitlySupports("attr_name") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_get/attr")
                }
                mapped["attr_name"] = attrName
            }
            if let maxChars = arguments["max_chars"], remoteTool.explicitlySupports("max_chars") {
                mapped["max_chars"] = maxChars
            }
            mapped["kind"] = kind
            return mapped
        case "wm_find":
            if let selector = string(arguments, "selector") {
                guard remoteTool.explicitlySupports("selector") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/selector")
                }
                return ["selector": selector]
            }
            let text = string(arguments, "text")
            let regex = string(arguments, "regex")
            guard (text == nil) != (regex == nil) else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_find requires exactly one of text or regex.")
            }
            if let text {
                guard remoteTool.explicitlySupports("text") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/text")
                }
                return ["text": text]
            }
            guard remoteTool.explicitlySupports("regex"), let regex else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_find/regex")
            }
            return ["regex": regex]
        case "wm_click", "wm_tap":
            if arguments["x"] != nil || arguments["y"] != nil {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("coordinate tap")
            }
            return try mappedTarget(arguments, remoteTool: remoteTool, toolName: toolName)
        case "wm_type":
            let target = try requireSafeTarget(arguments, toolName: toolName, sessionId: sessionId)
            guard let text = string(arguments, "text") ?? string(arguments, "value") else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_type requires text.")
            }
            var mapped = try mappedTarget(
                arguments,
                remoteTool: remoteTool,
                toolName: toolName,
                knownTarget: target
            )
            if remoteTool.explicitlySupports("text") {
                mapped["text"] = text
            } else if remoteTool.explicitlySupports("value") {
                mapped["value"] = text
            } else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_type/text")
            }
            if let submit = arguments["submit"] as? Bool, remoteTool.explicitlySupports("submit") {
                mapped["submit"] = submit
            }
            if let slowly = arguments["slowly"] as? Bool, remoteTool.explicitlySupports("slowly") {
                mapped["slowly"] = slowly
            }
            return mapped
        case "wm_keys":
            guard let key = string(arguments, "key") ?? string(arguments, "text"),
                  Self.allowedKey(key),
                  remoteTool.explicitlySupports("key") else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_keys accepts one character or a bounded named key.")
            }
            return ["key": key]
        case "wm_select":
            let target = try requireSafeTarget(arguments, toolName: toolName, sessionId: sessionId)
            let values: [String]
            if let provided = arguments["values"] as? [String], !provided.isEmpty {
                values = provided
            } else if let value = string(arguments, "value") ?? string(arguments, "text") {
                values = [value]
            } else {
                throw IOSWebMountDesktopBackendError.invalidArguments("wm_select requires a value.")
            }
            var mapped = try mappedTarget(
                arguments,
                remoteTool: remoteTool,
                toolName: toolName,
                knownTarget: target
            )
            guard remoteTool.explicitlySupports("values") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_select/values")
            }
            mapped["values"] = values
            return mapped
        case "wm_wait":
            let condition = (string(arguments, "condition") ?? "").lowercased()
            if condition == "text", let text = string(arguments, "text") {
                guard remoteTool.explicitlySupports("text") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/text")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["text": text])
            }
            if condition == "text_gone", let text = string(arguments, "text") {
                guard remoteTool.explicitlySupports("textGone") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/text_gone")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["textGone": text])
            }
            if condition == "delay", let milliseconds = number(arguments, "timeout_ms") {
                guard remoteTool.explicitlySupports("time") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/delay")
                }
                return ["time": min(max(milliseconds / 1_000, 0), 60)]
            }
            if condition == "selector", let target = string(arguments, "selector") ?? string(arguments, "target") {
                guard remoteTool.explicitlySupports("selector") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/selector")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["selector": target])
            }
            if condition == "url_contains", let fragment = string(arguments, "url_contains") {
                guard remoteTool.explicitlySupports("url_contains") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/url_contains")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["url_contains": fragment])
            }
            if condition == "ready_state", let readyState = string(arguments, "ready_state") {
                guard remoteTool.explicitlySupports("ready_state") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/ready_state")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: ["ready_state": readyState])
            }
            if condition == "dom_stable" {
                guard remoteTool.explicitlySupports("dom_stable") else {
                    throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/dom_stable")
                }
                return applyingRemoteTimeout(from: arguments, remoteTool: remoteTool, to: [:])
            }
            throw IOSWebMountDesktopBackendError.mappingUnsupported("wm_wait/\(condition.nilIfBlank ?? "condition")")
        default:
            throw IOSWebMountDesktopBackendError.mappingUnsupported(toolName)
        }
    }

    private func semanticTarget(
        _ arguments: [String: Any],
        toolName: String,
        knownTarget: String? = nil
    ) throws -> String {
        if let knownTarget { return knownTarget }
        let target = string(arguments, "target")
        let selector = string(arguments, "selector")
        guard target == nil || selector == nil else {
            throw IOSWebMountDesktopBackendError.invalidArguments("\(toolName) accepts one of target or selector.")
        }
        guard let value = target ?? selector else {
            throw IOSWebMountDesktopBackendError.invalidArguments("\(toolName) requires a semantic target from the latest snapshot.")
        }
        return value
    }

    private func mappedTarget(
        _ arguments: [String: Any],
        remoteTool: IOSWebMountDesktopToolDescriptor,
        toolName: String,
        knownTarget: String? = nil
    ) throws -> [String: Any] {
        let target = try semanticTarget(arguments, toolName: toolName, knownTarget: knownTarget)
        if string(arguments, "selector") != nil {
            guard remoteTool.explicitlySupports("selector") else {
                throw IOSWebMountDesktopBackendError.mappingUnsupported("\(toolName)/selector")
            }
            return ["selector": target]
        }
        if remoteTool.explicitlySupports("target") {
            return ["target": target]
        }
        if remoteTool.explicitlySupports("ref") {
            return ["ref": target]
        }
        if remoteTool.explicitlySupports("element") {
            return ["element": target]
        }
        throw IOSWebMountDesktopBackendError.mappingUnsupported("\(toolName)/target")
    }

    private func semanticElement(
        matching target: String,
        arguments: [String: Any],
        elements: [IOSWebMountDesktopSemanticElement]
    ) -> IOSWebMountDesktopSemanticElement? {
        if string(arguments, "selector") != nil {
            return elements.first(where: { $0.matchesSelector(target) })
        }
        return elements.first(where: { $0.matchesReference(target) })
    }

    private func requireSafeTarget(
        _ arguments: [String: Any],
        toolName: String,
        sessionId: String
    ) throws -> String {
        let target = try semanticTarget(arguments, toolName: toolName)
        guard !Self.isSensitiveTarget(target),
              let element = semanticElement(
                  matching: target,
                  arguments: arguments,
                  elements: snapshotElements[sessionId] ?? []
              ),
              Self.isSafe(element, for: toolName) else {
            throw IOSWebMountDesktopBackendError.sensitiveFieldRequiresHuman
        }
        return target
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
            disposition = Self.actionDisposition(element: element, toolName: toolName, arguments: arguments)
        case "wm_click", "wm_tap", "wm_type", "wm_select":
            guard let target = try? semanticTarget(arguments, toolName: toolName),
                  let element = semanticElement(
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
            disposition = Self.actionDisposition(element: element, toolName: toolName, arguments: arguments)
        case "wm_get":
            guard let target = try? semanticTarget(arguments, toolName: toolName),
                  let element = semanticElement(
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
            let kind = (string(arguments, "kind") ?? "text").lowercased()
            guard Self.isVisibleAndSafe(element, kind: kind) else {
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

    private static func actionDisposition(
        element: IOSWebMountDesktopSemanticElement,
        toolName: String,
        arguments: [String: Any]
    ) -> IOSWebMountDesktopActionDisposition {
        let label = element.name?.nilIfBlank ?? element.role?.nilIfBlank ?? "page element"
        guard element.visible == true else {
            return .human(reason: "target_visibility_unconfirmed", label: label)
        }
        guard element.disabled != true, element.actionable != false else {
            return .human(reason: "target_not_actionable", label: label)
        }
        guard hasSufficientSemantics(element) else {
            return .human(reason: "target_semantics_unconfirmed", label: label)
        }
        let requestedTarget = [arguments["target"] as? String, arguments["selector"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
            .joined(separator: " ")
        let identity = [element.role, element.name, element.inputType, element.tag]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ") + " " + requestedTarget.lowercased()
        if isSensitiveElement(element)
            || isSensitiveTarget(requestedTarget)
            || identity.range(
                of: #"captcha|two.?factor|2fa|mfa|otp|one.?time|verification.?code|passkey|oauth|sign.?in|log.?in|登录|验证码|人机验证"#,
                options: .regularExpression
            ) != nil {
            return .human(reason: "login_or_sensitive_field", label: label)
        }
        if toolName == "wm_keys",
           (arguments["key"] as? String ?? arguments["text"] as? String ?? "")
            .caseInsensitiveCompare("Enter") == .orderedSame {
            return .approval(reason: "enter_may_submit", label: "Enter")
        }
        if toolName == "wm_type", arguments["submit"] as? Bool == true {
            return .approval(reason: "type_and_submit", label: label)
        }
        let highConsequencePattern = #"(?i)\b(pay|payment|purchase|buy|checkout|place.?order|submit|authorize|approve|confirm|send|publish|delete|remove)\b|支付|付款|购买|下单|提交|授权|确认|发送|发布|删除"#
        if identity.range(of: highConsequencePattern, options: .regularExpression) != nil {
            return .approval(reason: "high_consequence_action", label: label)
        }
        if toolName == "wm_select",
           identity.range(
               of: #"payment|billing|checkout|order|支付|账单|订单"#,
               options: [.regularExpression, .caseInsensitive]
           ) != nil {
            return .approval(reason: "payment_or_billing_selection", label: label)
        }
        return .safe
    }

    private static func hasSufficientSemantics(_ element: IOSWebMountDesktopSemanticElement) -> Bool {
        let role = element.role?.nilIfBlank
        let name = element.name?.nilIfBlank
        let inputType = element.inputType?.nilIfBlank
        let tag = element.tag?.nilIfBlank
        return role != nil && name != nil && (inputType != nil || tag != nil)
    }

    private static func isVisibleAndSafe(
        _ element: IOSWebMountDesktopSemanticElement,
        kind: String
    ) -> Bool {
        guard element.visible == true,
              element.disabled != true,
              hasSufficientSemantics(element),
              !isSensitiveElement(element) else {
            return false
        }
        guard kind == "value" else { return true }
        let role = element.role?.lowercased() ?? ""
        let tag = element.tag?.lowercased() ?? ""
        return ["textbox", "searchbox", "combobox", "listbox"].contains(role)
            || ["input", "textarea", "select"].contains(tag)
    }

    private func normalizedSessionID(_ value: String) throws -> String {
        guard let value = value.nilIfBlank else {
            throw IOSWebMountDesktopBackendError.invalidArguments("session_id is required.")
        }
        return value
    }

    private func string(_ values: [String: Any], _ key: String) -> String? {
        (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func number(_ values: [String: Any], _ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue
    }

    private func applyingRemoteTimeout(
        from arguments: [String: Any],
        remoteTool: IOSWebMountDesktopToolDescriptor,
        to mapped: [String: Any]
    ) -> [String: Any] {
        guard let timeout = number(arguments, "timeout_ms") else { return mapped }
        var result = mapped
        let clamped = Int(timeout).clamped(to: 100...30_000)
        if remoteTool.explicitlySupports("timeout_ms") {
            result["timeout_ms"] = clamped
        } else if remoteTool.explicitlySupports("timeout") {
            result["timeout"] = clamped
        }
        if let stable = number(arguments, "stable_ms"),
           remoteTool.explicitlySupports("stable_ms") {
            result["stable_ms"] = Int(stable).clamped(to: 50...5_000)
        }
        return result
    }

    private static func isSensitiveTarget(_ target: String) -> Bool {
        let value = target.lowercased()
        return [
            "password", "passwd", "passcode", "otp", "one-time", "mfa", "2fa",
            "captcha", "card", "pan", "cvv", "cvc", "payment", "billing"
        ].contains { value.contains($0) }
    }

    private static func isSensitiveElement(_ element: IOSWebMountDesktopSemanticElement) -> Bool {
        let inputType = element.inputType?.lowercased() ?? ""
        if [
            "password", "hidden", "one-time-code", "otp", "cc-number", "cc-csc",
            "credit-card", "new-password", "current-password"
        ].contains(inputType) {
            return true
        }
        let identity = [element.role, element.name, element.inputType, element.tag]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return isSensitiveTarget(identity)
    }

    private static func isSafe(
        _ element: IOSWebMountDesktopSemanticElement,
        for toolName: String
    ) -> Bool {
        guard element.visible == true,
              element.disabled != true,
              element.actionable != false,
              !isSensitiveElement(element) else { return false }
        let role = element.role?.lowercased() ?? ""
        let tag = element.tag?.lowercased() ?? ""
        let inputType = element.inputType?.lowercased() ?? "text"
        let safeInputTypes = Set([
            "text", "email", "search", "tel", "url", "number", "date", "datetime-local",
            "month", "week", "time"
        ])
        switch toolName {
        case "wm_type":
            if ["textbox", "searchbox"].contains(role) { return true }
            return ["input", "textarea"].contains(tag) && safeInputTypes.contains(inputType)
        case "wm_select":
            return ["combobox", "listbox"].contains(role) || tag == "select" || inputType == "select"
        default:
            return false
        }
    }

    private static func semanticElements(
        from text: String,
        backend: IOSWebMountBackendKind,
        remoteToolName: String
    ) -> [IOSWebMountDesktopSemanticElement] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            guard backend == .playwright_mcp else { return [] }
            return playwrightSemanticElements(from: text, remoteToolName: remoteToolName)
        }
        var elements: [IOSWebMountDesktopSemanticElement] = []

        func stringValue(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let refs = Set([
                    stringValue(dictionary["ref"]),
                    stringValue(dictionary["target_ref"]),
                    stringValue(dictionary["target"]),
                    stringValue(dictionary["id"])
                ].compactMap { $0 })
                let selectors = Set([
                    stringValue(dictionary["selector"]),
                    stringValue(dictionary["css_selector"])
                ].compactMap { $0 })
                let role = stringValue(dictionary["role"])
                    ?? stringValue(dictionary["aria_role"])
                let name = stringValue(dictionary["name"])
                    ?? stringValue(dictionary["accessible_name"])
                    ?? stringValue(dictionary["label"])
                    ?? stringValue(dictionary["text"])
                let inputType = stringValue(dictionary["input_type"])
                    ?? stringValue(dictionary["inputType"])
                    ?? stringValue(dictionary["type"])
                let tag = stringValue(dictionary["tag"])
                    ?? stringValue(dictionary["tag_name"])
                    ?? stringValue(dictionary["tagName"])
                let visible = (dictionary["visible"] as? NSNumber)?.boolValue
                    ?? (dictionary["is_visible"] as? NSNumber)?.boolValue
                let focused = (dictionary["focused"] as? NSNumber)?.boolValue
                    ?? (dictionary["is_focused"] as? NSNumber)?.boolValue
                let actionable = (dictionary["actionable"] as? NSNumber)?.boolValue
                    ?? (dictionary["is_actionable"] as? NSNumber)?.boolValue
                let disabled = (dictionary["disabled"] as? NSNumber)?.boolValue
                    ?? (dictionary["aria_disabled"] as? NSNumber)?.boolValue
                if !refs.isEmpty || !selectors.isEmpty {
                    let element = IOSWebMountDesktopSemanticElement(
                        refs: refs,
                        selectors: selectors,
                        role: role,
                        name: name,
                        inputType: inputType,
                        tag: tag,
                        visible: visible,
                        focused: focused,
                        actionable: actionable,
                        disabled: disabled
                    )
                    let isDuplicate = elements.contains {
                        !$0.refs.isDisjoint(with: element.refs)
                            || !$0.selectors.isDisjoint(with: element.selectors)
                    }
                    if !isDuplicate { elements.append(element) }
                }
                for child in dictionary.values { visit(child) }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }

        visit(root)
        return elements.sorted { lhs, rhs in
            let lhsComplete = hasSufficientSemantics(lhs)
            let rhsComplete = hasSufficientSemantics(rhs)
            if lhsComplete != rhsComplete { return lhsComplete }
            let lhsKey = lhs.refs.sorted().first ?? lhs.selectors.sorted().first ?? ""
            let rhsKey = rhs.refs.sorted().first ?? rhs.selectors.sorted().first ?? ""
            return lhsKey < rhsKey
        }
    }

    private static func playwrightSemanticElements(
        from text: String,
        remoteToolName: String
    ) -> [IOSWebMountDesktopSemanticElement] {
        let lines: [Substring]
        if let snapshot = playwrightSnapshotBody(from: text) {
            lines = snapshot.split(separator: "\n", omittingEmptySubsequences: false)
        } else if remoteToolName == "browser_find" {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        } else {
            return []
        }
        let pattern = #"^\s*-\s+([A-Za-z][A-Za-z0-9_-]*)(?:\s+\"((?:[^\"\\]|\\.)*)\")?.*\[ref=([^\]\s]+)\].*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var elements: [IOSWebMountDesktopSemanticElement] = []
        for lineSlice in lines {
            let line = String(lineSlice)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let roleRange = Range(match.range(at: 1), in: line),
                  let refRange = Range(match.range(at: 3), in: line) else {
                continue
            }
            let role = String(line[roleRange]).lowercased()
            let ref = String(line[refRange])
            let name: String?
            if let range = Range(match.range(at: 2), in: line) {
                name = String(line[range])
                    .replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\\"#, with: "\\")
                    .nilIfBlank
            } else {
                name = nil
            }
            let roleMetadata = playwrightRoleMetadata(role)
            let disabled = line.range(
                of: #"\[disabled(?:=true)?\]"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let element = IOSWebMountDesktopSemanticElement(
                refs: [ref],
                selectors: [],
                role: role,
                name: name,
                inputType: roleMetadata.inputType,
                tag: roleMetadata.tag,
                // Playwright's accessibility snapshot excludes aria-hidden and
                // display-hidden nodes; parsed entries are therefore visible in
                // the semantic tree. Structured gateways must still send an
                // explicit visible=true flag.
                visible: true,
                focused: line.range(
                    of: #"\[focused(?:=true)?\]"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil,
                actionable: !disabled,
                disabled: disabled
            )
            if !elements.contains(where: { $0.refs.contains(ref) }) {
                elements.append(element)
            }
        }
        return elements
    }

    private static func playwrightRoleMetadata(
        _ role: String
    ) -> (tag: String?, inputType: String?) {
        switch role {
        case "button": ("button", nil)
        case "link": ("a", nil)
        case "textbox": ("input", "text")
        case "searchbox": ("input", "search")
        case "combobox", "listbox": ("select", "select")
        case "checkbox": ("input", "checkbox")
        case "radio": ("input", "radio")
        case "option": ("option", nil)
        default: (nil, nil)
        }
    }

    private static func playwrightResponseContainsSnapshot(_ text: String) -> Bool {
        playwrightSnapshotBody(from: text) != nil
    }

    private static func playwrightSnapshotBody(from text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let stateIndex = lines.firstIndex(where: {
            $0 == "### Page state"
        }), let snapshotIndex = lines[(stateIndex + 1)...].firstIndex(where: {
            $0 == "- Page Snapshot:" || $0 == "- Page Snapshot"
        }) else {
            return nil
        }
        let body = lines[(snapshotIndex + 1)...]
            .drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "```yaml" })
            .prefix(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "```" })
        return body.joined(separator: "\n")
    }

    private static func remoteErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["isError"] as? Bool == true {
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let error = object["error"] as? String, !error.isEmpty { return error }
            return "MCP tool returned an error result."
        }
        if object["ok"] as? Bool == false {
            for key in ["reason", "message", "error", "detail"] {
                if let message = (object[key] as? String)?.nilIfBlank { return message }
            }
            return "MCP tool returned ok=false."
        }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String)?.nilIfBlank ?? "MCP JSON-RPC error"
        }
        return nil
    }

    private static func allowedKey(_ key: String) -> Bool {
        if key.count == 1 { return true }
        return [
            "Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown",
            "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"
        ].contains(key)
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
            removeURLFields: Self.mappings[toolName]?.mutating == true
        )
        let remoteObject = rawResult.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let remoteMayHaveApplied = remoteObject?["may_have_applied"] as? Bool == true
        let remoteStatus = (remoteObject?["status"] as? String)?.nilIfBlank
        let remoteOutcomeUnknown = Self.mappings[toolName]?.mutating == true
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
        if let currentURL = Self.topLevelCurrentURL(from: rawResult, backend: connection.backend),
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
                Self.normalizedObservation(
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
            Self.mappings.keys.sorted().filter { mappedToolName in
                guard let mapping = Self.mappings[mappedToolName] else { return false }
                return Self.mappingIsAvailable(
                    toolName: mappedToolName,
                    mapping: mapping,
                    connection: connection
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
        let sanitized = removeURLFields ? removingURLFields(from: value) : value
        return IOSWebMountRedactor.redactedJSONObject(sanitized)
    }

    private static func waitMatched(from text: String) -> Bool? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["matched"] as? NSNumber)?.boolValue
    }

    private static func normalizedObservation(
        rawResult: String,
        sessionId: String,
        backend: IOSWebMountBackendKind,
        snapshotID: String?,
        pageRevision: Int,
        semanticElements: [IOSWebMountDesktopSemanticElement]
    ) -> [String: Any] {
        let root: [String: Any]? = rawResult.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let payload: [String: Any]? = {
            guard let root else { return nil }
            for key in ["webmount", "observation", "snapshot"] {
                if let nested = root[key] as? [String: Any] { return nested }
            }
            return root
        }()
        let explicitSemanticVersion = (payload?["contract_version"] as? String)?.nilIfBlank
        let parseQuality: String
        if explicitSemanticVersion != nil {
            parseQuality = "versioned_structured"
        } else if root != nil {
            parseQuality = "structured_compat"
        } else if backend == .playwright_mcp, playwrightResponseContainsSnapshot(rawResult) {
            parseQuality = "playwright_accessibility"
        } else {
            parseQuality = "opaque"
        }

        let rawPage = payload?["page"] as? [String: Any]
        let rawURL = (rawPage?["url"] as? String)
            ?? (payload?["current_url"] as? String)
            ?? topLevelCurrentURL(from: rawResult, backend: backend)
        let rawTitle = (rawPage?["title"] as? String)
            ?? (payload?["title"] as? String)
            ?? playwrightPageTitle(from: rawResult)
        var page: [String: Any] = [
            "document_id": (payload?["document_id"] as? String)?.nilIfBlank ?? "remote:\(sessionId)",
            "page_revision": pageRevision,
            "snapshot_id": snapshotID ?? ""
        ]
        if let rawURL, let url = IOSWebMountRedactor.redactedURL(rawURL) { page["url"] = url }
        if let title = rawTitle?.nilIfBlank { page["title"] = IOSWebMountRedactor.redactedText(title) }
        if let readyState = (rawPage?["ready_state"] as? String)?.nilIfBlank
            ?? (payload?["ready_state"] as? String)?.nilIfBlank {
            page["ready_state"] = readyState
        }

        let accessibilityText = semanticElements.compactMap(\.name).joined(separator: "\n")
        let visibleText = ((payload?["visible_text"] as? String)
            ?? (payload?["text"] as? String)
            ?? (parseQuality == "playwright_accessibility" ? accessibilityText : ""))
        let links = (payload?["links"] as? [[String: Any]] ?? [])
            .prefix(100)
            .map { IOSWebMountRedactor.redactedJSONObject($0) }
        let visualCandidates = (payload?["visual_candidates"] as? [[String: Any]] ?? [])
            .prefix(100)
            .map { IOSWebMountRedactor.redactedJSONObject($0) }
        let interactiveElements = semanticElements
            .prefix(200)
            .map(\.contractDictionary)

        return [
            "semantic_contract_version": "webmount.semantic.v2",
            "source_contract_version": explicitSemanticVersion ?? "",
            "parse_quality": parseQuality,
            "document_id": page["document_id"] ?? "remote:\(sessionId)",
            "page_revision": pageRevision,
            "snapshot_id": snapshotID ?? "",
            "page": page,
            "visible_text": String(IOSWebMountRedactor.redactedText(visibleText).prefix(20_000)),
            "links": links,
            "interactive_elements": interactiveElements,
            "visual_candidates": visualCandidates
        ]
    }

    private static func removingURLFields(from value: Any) -> Any {
        let urlKeys: Set<String> = ["current_url", "currentURL", "url", "origin"]
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                guard !urlKeys.contains(entry.key) else { return }
                result[entry.key] = removingURLFields(from: entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map { removingURLFields(from: $0) }
        }
        return value
    }

    private static func topLevelCurrentURL(
        from text: String,
        backend: IOSWebMountBackendKind
    ) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["current_url", "currentURL", "url", "origin"] {
                if let url = (object[key] as? String)?.nilIfBlank {
                    return url
                }
            }
            let payload = (object["webmount"] as? [String: Any])
                ?? (object["observation"] as? [String: Any])
                ?? object
            if ["webmount.semantic.v2", "wm/2"].contains(payload["contract_version"] as? String ?? "") {
                if let url = (payload["current_url"] as? String)?.nilIfBlank {
                    return url
                }
                if let page = payload["page"] as? [String: Any],
                   let url = (page["url"] as? String)?.nilIfBlank {
                    return url
                }
            }
        }
        guard backend == .playwright_mcp else { return nil }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let stateIndex = lines.firstIndex(where: {
            $0 == "### Page state"
        }) else {
            return nil
        }
        for lineSlice in lines[(stateIndex + 1)...] {
            let line = String(lineSlice)
            if line == "- Page Snapshot:" || line == "- Page Snapshot" || line.hasPrefix("### ") {
                return nil
            }
            let prefix = "- Page URL:"
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank
            }
        }
        return nil
    }

    private static func pageIdentity(
        from text: String,
        backend: IOSWebMountBackendKind
    ) -> IOSWebMountDesktopPageIdentity? {
        let root: [String: Any]? = text.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let payload = (root?["webmount"] as? [String: Any])
            ?? (root?["observation"] as? [String: Any])
            ?? (root?["snapshot"] as? [String: Any])
            ?? root
        let documentID = (payload?["document_id"] as? String)?.nilIfBlank
            ?? ((payload?["page"] as? [String: Any])?["document_id"] as? String)?.nilIfBlank
        let rawURL = topLevelCurrentURL(from: text, backend: backend)
        let normalizedURL: String? = rawURL.flatMap { value in
            guard var components = URLComponents(string: value) else { return value.nilIfBlank }
            components.user = nil
            components.password = nil
            components.fragment = nil
            return components.string?.nilIfBlank
        }
        guard documentID != nil || normalizedURL != nil else { return nil }
        return IOSWebMountDesktopPageIdentity(documentID: documentID, currentURL: normalizedURL)
    }

    private static func playwrightPageTitle(from text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let stateIndex = lines.firstIndex(where: { $0 == "### Page state" }) else {
            return nil
        }
        for lineSlice in lines[(stateIndex + 1)...] {
            let line = String(lineSlice)
            if line == "- Page Snapshot:" || line == "- Page Snapshot" || line.hasPrefix("### ") {
                return nil
            }
            let prefix = "- Page Title:"
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfBlank
            }
        }
        return nil
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

enum IOSWebMountRemoteRuntimeError: Error, LocalizedError {
    case localOperationUnavailable

    var errorDescription: String? {
        "This logical desktop session has no local WKWebView."
    }
}

@MainActor
final class IOSWebMountRemotePlaceholderRuntime: IOSWebMountRuntimeServicing {
    let webView: WKWebView? = nil
    private(set) var snapshot: IOSWebMountRuntimeSnapshot

    init(sessionId: String? = nil) {
        let resolved = sessionId?.nilIfBlank ?? "ios_remote_" + String(UUID().uuidString.prefix(8))
        snapshot = .idle(sessionId: resolved)
    }

    func apply(resultText: String, toolName: String, requestedURL: String? = nil) {
        let object = resultText.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let ok = object?["ok"] as? Bool == true
        snapshot.status = ok ? .ready : .failed
        if let requestedURL {
            snapshot.requestedURL = IOSWebMountRedactor.redactedURL(requestedURL)
        }
        if ok {
            snapshot.currentURL = IOSWebMountRedactor.redactedURL(object?["current_url"] as? String)
                ?? snapshot.requestedURL
        }
        snapshot.title = ok ? "Desktop · \(toolName)" : snapshot.title
        snapshot.error = ok ? nil : IOSWebMountRedactor.redactedText(object?["error"] as? String ?? "Desktop gateway failed")
        snapshot.updatedAtMillis = IOSWebMountClock.nowMillis()
    }

    func open(_ url: URL, timeoutMillis: UInt64) async -> IOSWebMountRuntimeSnapshot {
        snapshot.status = .failed
        snapshot.error = IOSWebMountRemoteRuntimeError.localOperationUnavailable.localizedDescription
        return snapshot
    }

    func state() async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func extract(mode: String, maxChars: Int, maxLinks: Int) async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func interact(method: String, selector: String?, text: String?, options: [String: Any]) async throws -> [String: Any] { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func screenshot() async throws -> IOSWebMountScreenshotCapture { throw IOSWebMountRemoteRuntimeError.localOperationUnavailable }
    func back() async -> IOSWebMountRuntimeSnapshot { await open(URL(string: "about:blank")!, timeoutMillis: 0) }
    func forward() async -> IOSWebMountRuntimeSnapshot { await open(URL(string: "about:blank")!, timeoutMillis: 0) }
}
