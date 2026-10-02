import Foundation
@preconcurrency import Shared

enum ChatToolCallParsing {
    static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func stringArray(_ value: Any?) -> [String]? {
        if let values = value as? [String] {
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let text = value as? String {
            let values = text
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }
        return nil
    }

    static func requestId(for toolCall: UIMessagePart.Tool) -> String {
        let rawId = toolCall.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawId.isEmpty ? inputDigest(for: toolCall.input) : rawId
    }

    static func truncatedMcpArguments(_ value: Any?, maxLength: Int = 360) -> String {
        guard let value else { return "{}" }
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let serialized = String(data: data, encoding: .utf8) {
            text = serialized
        } else {
            text = String(describing: value)
        }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "..."
    }

    static func truncatedSearchTarget(_ value: String, maxLength: Int = 180) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    private static func inputDigest(for text: String) -> String {
        chatInputDigest(for: text)
    }
}
