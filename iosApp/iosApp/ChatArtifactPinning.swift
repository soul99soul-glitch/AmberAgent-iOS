import CryptoKit
import Foundation
import Shared

enum ChatArtifactPinning {
    static func snippet(
        messageID: String,
        text: String,
        kind: ChatArtifactPinKind,
        codeLanguage: String? = nil,
        messages: [UIMessage]
    ) -> IOSPinnedSnippet? {
        var turn = 0
        for message in messages where ChatMessageProjector.isConversationMessage(message) {
            if message.role == MessageRole.user { turn += 1 }
            guard ChatMessageProjector.messageId(for: message) == messageID else { continue }
            let suffix = kind == .code
                ? ":code:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                : ""
            return IOSPinnedSnippet(
                id: messageID + suffix, messageID: messageID, turn: max(1, turn),
                text: text, kind: kind, codeLanguage: codeLanguage?.nilIfBlank
            )
        }
        return nil
    }

    /// 只展示原消息仍在当前分支中的收藏；其余保留在 store，切回原分支后重新出现。
    static func visibleSnippets(_ snippets: [IOSPinnedSnippet], messages: [UIMessage]) -> [IOSPinnedSnippet] {
        guard !snippets.isEmpty else { return [] }
        let messageIDs = Set(messages.map(ChatMessageProjector.messageId(for:)))
        return snippets.filter { messageIDs.contains($0.messageID) }
    }

    static func anchor(
        for snippet: IOSPinnedSnippet,
        conversationID: String,
        messages: [UIMessage]
    ) -> ChatMessageAnchor? {
        guard messages.contains(where: { ChatMessageProjector.messageId(for: $0) == snippet.messageID }) else {
            return nil
        }
        return ChatMessageAnchor(
            conversationID: conversationID, messageID: snippet.messageID, requestToken: UUID()
        )
    }
}
