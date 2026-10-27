import Foundation

// Model response progress shared by the Apple app runtimes and activity widgets.
public enum AgentActivityStage: String, Codable, Hashable, Sendable {
    case preparing
    case thinking
    case searching
    case readingSources
    case readingWeb
    case generating
    case generatingImage
    case organizing
    case readingDocument
    case updatingMemory
    case runningTool
    case waitingForConfirmation
    case reconnecting
    case stale
    case completed
    case failed
    case cancelled
}


enum AgentActivityResponseStagePolicy {
    static let initialStage = AgentActivityStage.preparing

    static func updatedStage(
        hasReasoningDelta: Bool,
        hasTextDelta: Bool
    ) -> AgentActivityStage? {
        if hasReasoningDelta { return .thinking }
        if hasTextDelta { return .generating }
        return nil
    }

    static func nextPublishedStage(
        current: AgentActivityStage?,
        candidate: AgentActivityStage
    ) -> AgentActivityStage? {
        guard current != candidate else { return nil }
        if current == .generating, candidate == .thinking { return nil }
        return candidate
    }
}

