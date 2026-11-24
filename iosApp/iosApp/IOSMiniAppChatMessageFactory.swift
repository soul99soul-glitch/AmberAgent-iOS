import Foundation
import Shared

/// Aligns iOS chat MiniApp finish handling with Android `MiniAppOutputTransformer`:
/// replace the assistant JSON text with a short status + `UIMessagePart.MiniApp` card ref.
enum IOSMiniAppChatMessageFactory {
    private static let jsonHTMLBytes: [UInt8] = Array("\"html\"".utf8)
    private static let jsonTitleBytes: [UInt8] = Array("\"title\"".utf8)
    private static let jsonDescriptionBytes: [UInt8] = Array("\"description\"".utf8)
    private static let doctypeHTMLBytes: [UInt8] = Array("<!doctype html".utf8)
    private static let htmlTagBytes: [UInt8] = Array("<html".utf8)

    static func mightContainMiniApp(_ text: String) -> Bool {
        let utf8 = text.utf8
        if let result = utf8.withContiguousStorageIfAvailable({ Self.scanMiniAppMarkers(in: $0, text: text) }) {
            return result
        }
        return scanMiniAppMarkers(in: text)
    }

    private static func scanMiniAppMarkers(in buffer: UnsafeBufferPointer<UInt8>, text: String) -> Bool {
        let count = buffer.count
        guard count >= htmlTagBytes.count else { return false }

        var hasHTML = false
        var hasTitle = false
        var hasDescription = false

        var index = 0
        while index < count {
            let byte = buffer[index]
            if byte == 0x22 { // '"'
                if !hasHTML, matchesExact(buffer, at: index, pattern: jsonHTMLBytes, text: text) {
                    hasHTML = true
                    if hasTitle && hasDescription { return true }
                } else if !hasTitle, matchesExact(buffer, at: index, pattern: jsonTitleBytes, text: text) {
                    hasTitle = true
                    if hasHTML && hasDescription { return true }
                } else if !hasDescription, matchesExact(buffer, at: index, pattern: jsonDescriptionBytes, text: text) {
                    hasDescription = true
                    if hasHTML && hasTitle { return true }
                }
            } else if byte == 0x3C { // '<'
                if matchesASCIICaseInsensitive(buffer, at: index, lowercasePattern: htmlTagBytes, text: text)
                    || matchesASCIICaseInsensitive(buffer, at: index, lowercasePattern: doctypeHTMLBytes, text: text) {
                    return true
                }
            }
            index += 1
        }
        return false
    }

    private static func scanMiniAppMarkers(in text: String) -> Bool {
        let utf8 = text.utf8
        var hasHTML = false
        var hasTitle = false
        var hasDescription = false

        var index = utf8.startIndex
        let end = utf8.endIndex
        while index < end {
            let byte = utf8[index]
            if byte == 0x22 { // '"'
                if !hasHTML, matchesExact(text, at: index, pattern: jsonHTMLBytes) {
                    hasHTML = true
                    if hasTitle && hasDescription { return true }
                } else if !hasTitle, matchesExact(text, at: index, pattern: jsonTitleBytes) {
                    hasTitle = true
                    if hasHTML && hasDescription { return true }
                } else if !hasDescription, matchesExact(text, at: index, pattern: jsonDescriptionBytes) {
                    hasDescription = true
                    if hasHTML && hasTitle { return true }
                }
            } else if byte == 0x3C { // '<'
                if matchesASCIICaseInsensitive(text, at: index, lowercasePattern: htmlTagBytes)
                    || matchesASCIICaseInsensitive(text, at: index, lowercasePattern: doctypeHTMLBytes) {
                    return true
                }
            }
            utf8.formIndex(after: &index)
        }
        return false
    }

    @inline(__always)
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? (byte | 0x20) : byte
    }

    @inline(__always)
    private static func matchesExact(
        _ buffer: UnsafeBufferPointer<UInt8>,
        at start: Int,
        pattern: [UInt8],
        text: String
    ) -> Bool {
        let length = pattern.count
        guard start + length <= buffer.count else { return false }
        for offset in 1..<length where buffer[start + offset] != pattern[offset] {
            return false
        }
        return isWholeCharacterMatch(buffer, start: start, end: start + length, text: text)
    }

    @inline(__always)
    private static func matchesASCIICaseInsensitive(
        _ buffer: UnsafeBufferPointer<UInt8>,
        at start: Int,
        lowercasePattern: [UInt8],
        text: String
    ) -> Bool {
        let length = lowercasePattern.count
        guard start + length <= buffer.count else { return false }
        for offset in 1..<length where asciiLowercased(buffer[start + offset]) != lowercasePattern[offset] {
            return false
        }
        return isWholeCharacterMatch(buffer, start: start, end: start + length, text: text)
    }

    private static func isWholeCharacterMatch(
        _ buffer: UnsafeBufferPointer<UInt8>, start: Int, end: Int, text: String
    ) -> Bool {
        // String.contains respects grapheme boundaries. ASCII neighbors guarantee them here.
        let hasASCIILeft = start == 0 || buffer[start - 1] < 0x80
        let hasASCIIRight = end == buffer.count || buffer[end] < 0x80
        if hasASCIILeft && hasASCIIRight { return true }
        let utf8 = text.utf8
        return (hasASCIILeft || utf8.index(utf8.startIndex, offsetBy: start).samePosition(in: text) != nil)
            && (hasASCIIRight || utf8.index(utf8.startIndex, offsetBy: end).samePosition(in: text) != nil)
    }

    private static func matchesExact(
        _ text: String,
        at start: String.UTF8View.Index,
        pattern: [UInt8]
    ) -> Bool {
        let utf8 = text.utf8
        var cursor = start
        for expected in pattern {
            guard cursor < utf8.endIndex, utf8[cursor] == expected else { return false }
            utf8.formIndex(after: &cursor)
        }
        return start.samePosition(in: text) != nil && cursor.samePosition(in: text) != nil
    }

    private static func matchesASCIICaseInsensitive(
        _ text: String,
        at start: String.UTF8View.Index,
        lowercasePattern: [UInt8]
    ) -> Bool {
        let utf8 = text.utf8
        var cursor = start
        for expected in lowercasePattern {
            guard cursor < utf8.endIndex, asciiLowercased(utf8[cursor]) == expected else { return false }
            utf8.formIndex(after: &cursor)
        }
        return start.samePosition(in: text) != nil && cursor.samePosition(in: text) != nil
    }

    /// Newest MiniApp-looking assistant in the current turn (after `afterUserIndex`), skipping trailing notices.
    static func assistantCandidateIndex(in messages: [UIMessage], afterUserIndex: Int) -> Int? {
        guard afterUserIndex >= messages.startIndex,
              afterUserIndex < messages.endIndex else { return nil }
        let start = messages.index(after: afterUserIndex)
        guard start < messages.endIndex else { return nil }
        for index in (start..<messages.endIndex).reversed() {
            let message = messages[index]
            guard message.role == MessageRole.assistant else { continue }
            if message.parts.contains(where: { $0 is UIMessagePart.MiniApp }) {
                return nil
            }
            if let text = message.parts.reversed().compactMap({ ($0 as? UIMessagePart.Text)?.text }).first,
               mightContainMiniApp(text) {
                return index
            }
        }
        return nil
    }

    static func parseFailureAssistant(
        _ message: UIMessage,
        textPartIndex: Int,
        reason: String
    ) -> UIMessage {
        let textMetadata = (message.parts[textPartIndex] as? UIMessagePart.Text)?.metadata
        var parts = message.parts
        parts[textPartIndex] = UIMessagePart.Text(
            text: "小应用保存失败：\(reason)",
            metadata: textMetadata
        )
        return UIMessage(
            id: message.id,
            role: message.role,
            parts: parts,
            annotations: message.annotations,
            createdAt: message.createdAt,
            finishedAt: message.finishedAt,
            modelId: message.modelId,
            usage: message.usage,
            translation: message.translation
        )
    }

    static func revisionChangeNote(from userText: String) -> String {
        let marker = "用户修改意见："
        let body: String
        if let range = userText.range(of: marker) {
            body = String(userText[range.upperBound...])
        } else {
            body = userText
        }
        let note = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("请基于") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = note.isEmpty ? "MiniApp revision" : note
        return String(normalized.prefix(240))
    }

    static func revisionPrompt(
        appId: String,
        title: String,
        version: Int,
        request: String
    ) -> String {
        """
        修改小应用
        appId: \(appId)
        currentVersion: \(version)
        title: \(title)

        用户修改意见：
        \(request.trimmingCharacters(in: .whitespacesAndNewlines))

        请基于这个已保存小应用生成新版，并保留适合的能力声明。
        """
    }

    static func miniAppPart(from record: IOSMiniAppRecord) -> UIMessagePart.MiniApp {
        UIMessagePart.MiniApp(
            appId: record.id,
            title: record.title,
            description: record.description,
            iconEmoji: record.iconEmoji,
            category: record.category,
            permissions: record.permissions,
            htmlHash: record.htmlHash,
            version: Int32(record.version),
            metadata: nil
        )
    }

    static func persistedConversationReferences(
        in messages: [UIMessage]
    ) -> Set<IOSMiniAppConversationReference> {
        Set(messages.flatMap(\.parts).compactMap { part in
            guard let miniApp = part as? UIMessagePart.MiniApp,
                  let htmlHash = miniApp.htmlHash?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !htmlHash.isEmpty else {
                return nil
            }
            return IOSMiniAppConversationReference(
                appId: miniApp.appId,
                version: Int(miniApp.version),
                htmlHash: htmlHash
            )
        })
    }

    static func updatedAssistant(
        _ message: UIMessage,
        textPartIndex: Int,
        statusText: String,
        record: IOSMiniAppRecord
    ) -> UIMessage {
        let textMetadata = (message.parts[textPartIndex] as? UIMessagePart.Text)?.metadata
        var parts: [UIMessagePart] = []
        parts.reserveCapacity(message.parts.count + 1)
        for (index, part) in message.parts.enumerated() {
            if index == textPartIndex {
                parts.append(UIMessagePart.Text(text: statusText, metadata: textMetadata))
                parts.append(miniAppPart(from: record))
            } else {
                parts.append(part)
            }
        }
        return UIMessage(
            id: message.id,
            role: message.role,
            parts: parts,
            annotations: message.annotations,
            createdAt: message.createdAt,
            finishedAt: message.finishedAt,
            modelId: message.modelId,
            usage: message.usage,
            translation: message.translation
        )
    }

    static func revisionFailedAssistant(
        _ message: UIMessage,
        textPartIndex: Int
    ) -> UIMessage {
        let textMetadata = (message.parts[textPartIndex] as? UIMessagePart.Text)?.metadata
        let parts = message.parts.enumerated().map { index, part -> UIMessagePart in
            if index == textPartIndex {
                return UIMessagePart.Text(
                    text: "小应用更新失败：目标小应用不存在，或已经被更新。请打开最新的小应用卡片后重新点击「修改」。",
                    metadata: textMetadata
                )
            }
            return part
        }
        return UIMessage(
            id: message.id,
            role: message.role,
            parts: parts,
            annotations: message.annotations,
            createdAt: message.createdAt,
            finishedAt: message.finishedAt,
            modelId: message.modelId,
            usage: message.usage,
            translation: message.translation
        )
    }
}
