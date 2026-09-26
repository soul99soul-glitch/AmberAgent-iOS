import Foundation

/// 到达检测只比较事件身份，标题和预览刷新不重复触发提醒。
struct ChatTopBarArrivalState: Equatable {
    struct Input: Equatable {
        let conversationID: String?
        let isAwaitingUser: Bool
        let isGenerating: Bool
        let notices: [ConversationActivityNotice]
    }

    struct Key: Equatable {
        let id: String
        let kind: ConversationActivityNotice.Kind
        let occurredAt: Date

        init(_ notice: ConversationActivityNotice) {
            id = notice.conversationId
            kind = notice.kind
            occurredAt = notice.occurredAt
        }
    }

    static let recapHintTitle = "再聊几轮就能回顾"
    var recapHintDeadline: Date?

    @discardableResult
    mutating func didTapIneligibleTitle(at now: Date = .now) -> Bool {
        guard announcement == nil else { return false }
        recapHintDeadline = now.addingTimeInterval(1.8)
        return true
    }

    mutating func expireRecapHint(at now: Date = .now) {
        if let recapHintDeadline, now >= recapHintDeadline { self.recapHintDeadline = nil }
    }

    func islandPresentation(_ original: ChatIslandPresentation) -> ChatIslandPresentation {
        guard recapHintDeadline != nil, announcement == nil,
              original.displayedState.kind == .title else { return original }
        return .idle(.conversationTitle(Self.recapHintTitle))
    }

    private var previousInput: Input?
    var justLeftConversationID: String?
    var arrival: ConversationActivityNotice?
    var announcement: ConversationActivityNotice?

    mutating func update(_ input: Input) -> ConversationActivityNotice? {
        defer { previousInput = input }
        guard let previousInput else { return nil }
        if input.conversationID != previousInput.conversationID {
            justLeftConversationID = previousInput.isAwaitingUser ? previousInput.conversationID : nil
            if input.notices.contains(where: { $0.conversationId == justLeftConversationID && $0.kind == .awaitingUser }) {
                justLeftConversationID = nil
            }
            arrival = nil
            announcement = nil
            recapHintDeadline = nil
            return nil
        }
        if input.isGenerating {
            announcement = nil
            recapHintDeadline = nil
        }
        let previousKeys = previousInput.notices.map(Key.init)
        let newNotices = input.notices.filter { !previousKeys.contains(Key($0)) }
        let candidate = newNotices.first {
            !($0.conversationId == justLeftConversationID && $0.kind == .awaitingUser)
        }
        if newNotices.contains(where: { $0.conversationId == justLeftConversationID }) {
            justLeftConversationID = nil
        }
        guard let candidate else { return nil }
        arrival = candidate
        announcement = input.isGenerating ? nil : candidate
        if announcement != nil { recapHintDeadline = nil }
        return candidate
    }
}
