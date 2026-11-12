import Darwin
import Foundation
import Shared

/// Aligns iOS chat MiniApp finish handling with Android `MiniAppOutputTransformer`:
/// replace the assistant JSON text with a short status + `UIMessagePart.MiniApp` card ref.
enum IOSMiniAppChatMessageFactory {
    private static let jsonDescriptionBytes: [UInt8] = Array("\"description\"".utf8)
    private static let jsonHtmlBytes: [UInt8] = Array("\"html\"".utf8)
    private static let jsonTitleBytes: [UInt8] = Array("\"title\"".utf8)
    private static let doctypeLowerBytes: [UInt8] = Array("<!doctype html".utf8)
    private static let htmlTagLowerBytes: [UInt8] = Array("<html".utf8)

    static func mightContainMiniApp(_ text: String) -> Bool {
        if let hit = text.utf8.withContiguousStorageIfAvailable({ mightContainMiniApp(in: $0) }) {
            return hit
        }
        let contiguous = Array(text.utf8)
        return contiguous.withUnsafeBufferPointer { mightContainMiniApp(in: $0) }
    }

    private static func mightContainMiniApp(in buffer: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = buffer.baseAddress, buffer.count >= 5 else { return false }
        if containsExactASCII(base: base, count: buffer.count, needle: jsonDescriptionBytes),
           containsExactASCII(base: base, count: buffer.count, needle: jsonHtmlBytes),
           containsExactASCII(base: base, count: buffer.count, needle: jsonTitleBytes) {
            return true
        }
        return containsHTMLMarkerCaseInsensitive(base: base, count: buffer.count)
    }

    private static func containsExactASCII(
        base: UnsafePointer<UInt8>,
        count: Int,
        needle: [UInt8]
    ) -> Bool {
        let needleCount = needle.count
        guard count >= needleCount, let firstByte = needle.first else { return false }
        let lastStart = count - needleCount
        return needle.withUnsafeBufferPointer { needleBuf in
            guard let needleBase = needleBuf.baseAddress else { return false }
            var offset = 0
            while offset <= lastStart {
                guard let found = memchr(base.advanced(by: offset), Int32(firstByte), lastStart - offset + 1) else {
                    return false
                }
                let matchPtr = found.assumingMemoryBound(to: UInt8.self)
                if memcmp(matchPtr, needleBase, needleCount) == 0 {
                    return true
                }
                offset = base.distance(to: matchPtr) + 1
            }
            return false
        }
    }

    private static func containsHTMLMarkerCaseInsensitive(
        base: UnsafePointer<UInt8>,
        count: Int
    ) -> Bool {
        let minLen = htmlTagLowerBytes.count // 5 ("<html")
        guard count >= minLen else { return false }
        let lastStart = count - minLen
        var offset = 0
        while offset <= lastStart {
            guard let found = memchr(base.advanced(by: offset), Int32(0x3C), lastStart - offset + 1) else {
                return false
            }
            let ptr = found.assumingMemoryBound(to: UInt8.self)
            let idx = base.distance(to: ptr)
            let remaining = count - idx
            if remaining >= htmlTagLowerBytes.count,
               matchesASCIILower(ptr, lowerNeedle: htmlTagLowerBytes) {
                return true
            }
            if remaining >= doctypeLowerBytes.count,
               matchesASCIILower(ptr, lowerNeedle: doctypeLowerBytes) {
                return true
            }
            offset = idx + 1
        }
        return false
    }

    @inline(__always)
    private static func matchesASCIILower(_ ptr: UnsafePointer<UInt8>, lowerNeedle: [UInt8]) -> Bool {
        for i in 1..<lowerNeedle.count {
            let b = ptr[i]
            let lowered = (b >= 0x41 && b <= 0x5A) ? (b &+ 0x20) : b
            if lowered != lowerNeedle[i] {
                return false
            }
        }
        return true
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
