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
        case wakeTasks
        case wakeDueTasks
        case wakeTask(id: String)
        case agentActivity(AgentActivityDeepLink.Target)
        /// 深度阅读实时活动卡片的落点。
        case deepReadTask(id: String)
        /// `amber://gateway/pair?p=<base64url>` from the `amber-gateway pair` QR code.
        case gatewayPair(payload: String)
        /// Task board of the paired Mac: `amber://tasks`. Mac Gateway pushes still carry the older
        /// `amber://settings/mac-gateway`, which lands here too.
        case macTasks
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
        case ("settings", ["mac-gateway"]) where queryItems.isEmpty:
            return .macTasks
        case ("tasks", []) where queryItems.isEmpty:
            return .macTasks
        case (AgentActivityDeepLink.deepReadHost, let parts) where parts.count == 1 && queryItems.isEmpty:
            guard isSafeIdentifier(parts[0], maxLength: 64) else { return nil }
            return .deepReadTask(id: parts[0])
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
        case .wakeTasks:
            components.host = "wake"
        case .wakeDueTasks:
            components.host = "wake"
            components.path = "/due"
        case .wakeTask(let id):
            guard UUID(uuidString: id) != nil else { return nil }
            components.host = "wake"
            components.path = "/\(id)"
        case .macTasks:
            components.host = "tasks"
        case .gatewayPair(let payload):
            guard isSafeIdentifier(payload, maxLength: MacGatewayPairingPayload.maximumLinkLength) else { return nil }
            components.host = "gateway"
            components.path = "/pair"
            components.queryItems = [URLQueryItem(name: "p", value: payload)]
        case .deepReadTask(let id):
            return AgentActivityDeepLink.makeDeepReadURL(taskId: id)
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

    static let maximumPromptLength = 2_000

    static func normalizedPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumPromptLength else { return nil }
        return trimmed
    }
}
