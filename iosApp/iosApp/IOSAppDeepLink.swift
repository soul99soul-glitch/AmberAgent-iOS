import Foundation

/// Single parsing boundary for every app-owned URL. System surfaces may only
/// hand the shell a typed destination produced here; no view parses URL text.
enum IOSAppDeepLink {
    enum Destination: Equatable {
        case newConversation
        case latestConversation
        case conversation(id: String)
        case agentPrompt(handoffID: String)
        case activeTask
        case healthSummary
        case weather
        case appleIntegrations
        case phoneControl
        case wakeTasks
        case wakeDueTasks
        case wakeTask(id: String)
        case agentActivity(AgentActivityDeepLink.Target)
        /// `amber://gateway/pair?p=<base64url>` from the `amber-gateway pair` QR code.
        case gatewayPair(payload: String)
        /// Task board of the paired Mac: `amber://tasks`. Mac Gateway pushes still carry the older
        /// `amber://settings/mac-gateway`, which lands here too.
        case macTasks
        case gatewayTasks(MacGatewayEndpointRole)
        /// Paired Cloud schedule or native task detail (`amber://cloud-task/<workItemId>`).
        case cloudTask(workItemId: String)
        /// iOS Share Sheet prefill handoff (`amber://share/<handoffID>`).
        case shareInbox(handoffID: String)
    }

    static func parse(
        _ url: URL,
        expectedScheme: String = AgentActivityDeepLink.scheme
    ) -> Destination? {
        if let activity = AgentActivityDeepLink.parse(url) {
            return .agentActivity(activity)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare(expectedScheme) == .orderedSame,
              components.fragment == nil,
              let host = components.host?.lowercased() else { return nil }

        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let queryItems = components.queryItems ?? []
        switch (host, path) {
        case ("conversation", ["new"]) where queryItems.isEmpty:
            return .newConversation
        case ("conversation", ["latest"]) where queryItems.isEmpty:
            return .latestConversation
        case ("conversation", let parts) where parts.count == 1 && queryItems.isEmpty:
            let id = parts[0]
            guard isSafeIdentifier(id, maxLength: 64) else { return nil }
            return .conversation(id: id)
        case ("agent", let parts) where parts.count == 2 && parts[0] == "ask":
            guard queryItems.isEmpty,
                  isSafeIdentifier(parts[1], maxLength: 64) else { return nil }
            return .agentPrompt(handoffID: parts[1])
        case ("task", ["active"]) where queryItems.isEmpty:
            return .activeTask
        case ("wake", []) where queryItems.isEmpty:
            return .wakeTasks
        case ("wake", ["due"]) where queryItems.isEmpty:
            return .wakeDueTasks
        case ("wake", let parts) where parts.count == 1 && queryItems.isEmpty:
            guard UUID(uuidString: parts[0]) != nil else { return nil }
            return .wakeTask(id: parts[0])
        case ("settings", ["health"]) where queryItems.isEmpty:
            return .healthSummary
        case ("settings", ["weather"]) where queryItems.isEmpty:
            return .weather
        case ("settings", ["apple-integrations"]) where queryItems.isEmpty:
            return .appleIntegrations
        case ("settings", ["phone-control"]) where queryItems.isEmpty:
            return .phoneControl
        case ("settings", ["mac-gateway"]) where queryItems.isEmpty:
            return .macTasks
        case ("tasks", let parts) where parts.count == 1 && queryItems.isEmpty:
            guard let role = MacGatewayEndpointRole(rawValue: parts[0]) else { return nil }
            return .gatewayTasks(role)
        case ("tasks", []) where queryItems.isEmpty:
            return .macTasks
        case ("cloud-task", let parts) where parts.count == 1 && queryItems.isEmpty:
            guard isSafeWorkItemIdentifier(parts[0]) else { return nil }
            return .cloudTask(workItemId: parts[0])
        case ("share", let parts) where parts.count == 1 && queryItems.isEmpty:
            guard isSafeIdentifier(parts[0], maxLength: 64) else { return nil }
            return .shareInbox(handoffID: parts[0])
        case ("gateway", ["pair"]):
            guard queryItems.count == 1, queryItems[0].name == "p",
                  let payload = queryItems[0].value,
                  isSafeIdentifier(payload, maxLength: MacGatewayPairingPayload.maximumLinkLength) else { return nil }
            return .gatewayPair(payload: payload)
        default:
            return nil
        }
    }

    static func url(
        for destination: Destination,
        scheme: String = AgentActivityDeepLink.scheme
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch destination {
        case .newConversation:
            components.host = "conversation"
            components.path = "/new"
        case .latestConversation:
            components.host = "conversation"
            components.path = "/latest"
        case .conversation(let id):
            guard isSafeIdentifier(id, maxLength: 64) else { return nil }
            components.host = "conversation"
            components.path = "/\(id)"
        case .agentPrompt(let handoffID):
            guard isSafeIdentifier(handoffID, maxLength: 64) else { return nil }
            components.host = "agent"
            components.path = "/ask/\(handoffID)"
        case .activeTask:
            components.host = "task"
            components.path = "/active"
        case .healthSummary:
            components.host = "settings"
            components.path = "/health"
        case .weather:
            components.host = "settings"
            components.path = "/weather"
        case .appleIntegrations:
            components.host = "settings"
            components.path = "/apple-integrations"
        case .phoneControl:
            components.host = "settings"
            components.path = "/phone-control"
        case .wakeTasks:
            components.host = "wake"
        case .wakeDueTasks:
            components.host = "wake"
            components.path = "/due"
        case .wakeTask(let id):
            guard UUID(uuidString: id) != nil else { return nil }
            components.host = "wake"
            components.path = "/\(id)"
        case .gatewayTasks(let role):
            components.host = "tasks"
            components.path = "/\(role.rawValue)"
        case .macTasks:
            components.host = "tasks"
        case .cloudTask(let workItemId):
            guard isSafeWorkItemIdentifier(workItemId) else { return nil }
            components.host = "cloud-task"
            components.path = "/\(workItemId)"
        case .shareInbox(let handoffID):
            guard isSafeIdentifier(handoffID, maxLength: 64) else { return nil }
            components.host = "share"
            components.path = "/\(handoffID)"
        case .gatewayPair(let payload):
            guard isSafeIdentifier(payload, maxLength: MacGatewayPairingPayload.maximumLinkLength) else { return nil }
            components.host = "gateway"
            components.path = "/pair"
            components.queryItems = [URLQueryItem(name: "p", value: payload)]
        case .agentActivity(let target):
            return AgentActivityDeepLink.makeURL(
                runId: target.runId,
                conversationId: target.conversationId,
                focus: target.focus
            )
        }
        return components.url
    }

    private static func isSafeIdentifier(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeWorkItemIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static let maximumPromptLength = 2_000

    static func normalizedPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumPromptLength else { return nil }
        return trimmed
    }
}
