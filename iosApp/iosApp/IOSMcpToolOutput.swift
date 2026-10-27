import Foundation
import Shared

struct IOSMcpToolOutput {
    let text: String
    let parts: [UIMessagePart]

    init(text: String, parts: [UIMessagePart]? = nil) {
        self.text = text
        self.parts = parts ?? [UIMessagePart.Text(text: text, metadata: nil)]
    }
}

@MainActor
protocol IOSMcpClienting: AnyObject {
    func connect(config: IOSMcpServerConfig) async throws -> Bool
    // Replace the session without invalidating requests already in the queue.
    func reconnect(config: IOSMcpServerConfig) async throws -> Bool
    func listTools() async throws -> [IOSMcpTool]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
    func callToolOutput(name: String, arguments: [String: Any]) async throws -> IOSMcpToolOutput
    func disconnect()
}

extension IOSMcpClienting {
    func reconnect(config: IOSMcpServerConfig) async throws -> Bool {
        disconnect()
        return try await connect(config: config)
    }

    func callToolOutput(name: String, arguments: [String: Any]) async throws -> IOSMcpToolOutput {
        IOSMcpToolOutput(text: try await callTool(name: name, arguments: arguments))
    }
}

extension IOSMcpClient: IOSMcpClienting {
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        try await callToolOutput(name: name, arguments: arguments).text
    }

    func callToolOutput(name: String, arguments: [String: Any]) async throws -> IOSMcpToolOutput {
        let result = try await callToolResult(name: name, arguments: arguments)
        return try Self.toolOutput(result: result)
    }

    static func toolOutput(result: [String: Any]) throws -> IOSMcpToolOutput {
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
        if result["isError"] as? Bool == true {
            throw IOSMcpClientError.rpcError(text.nilIfBlank ?? "MCP tool returned an error result.")
        }
        // Keep the legacy string contract for scripts and non-chat consumers.
        let legacyText: String
        if !text.isEmpty {
            legacyText = text
        } else if let structured = result["structuredContent"], let serialized = serializedJSON(structured) {
            legacyText = serialized
        } else if !content.isEmpty, let serialized = serializedJSON(content) {
            legacyText = serialized
        } else {
            throw IOSMcpClientError.unsupportedContent
        }

        var parts: [[String: Any]] = []
        for item in content {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(["type": "text", "text": text]) }
            case "image":
                if let mime = item["mimeType"] as? String, mime.lowercased().hasPrefix("image/"),
                   let data = item["data"] as? String, !data.isEmpty {
                    parts.append(["type": "image", "url": "data:\(mime);base64,\(data)"])
                }
            case "resource_link":
                if let part = linkedMediaPart(item) {
                    parts.append(part)
                    // Providers consume tool Text/Image, so keep the video URI
                    // available for the next model step as well as the UI card.
                    if part["type"] as? String == "video", let uri = part["url"] as? String, !text.contains(uri) {
                        let title = item["title"] as? String ?? item["name"] as? String ?? "视频"
                        parts.append(["type": "text", "text": "\(title)\n\(uri)"])
                    }
                } else if let uri = item["uri"] as? String {
                    let title = item["title"] as? String ?? item["name"] as? String ?? "资源"
                    parts.append(["type": "text", "text": "\(title)\n\(uri)"])
                }
            case "resource":
                guard let resource = item["resource"] as? [String: Any] else { continue }
                if let embeddedText = resource["text"] as? String {
                    parts.append(["type": "text", "text": embeddedText])
                    continue
                }
                guard let mime = resource["mimeType"] as? String else { continue }
                if mime.lowercased().hasPrefix("image/"), let blob = resource["blob"] as? String, !blob.isEmpty {
                    parts.append([
                        "type": "image", "url": "data:\(mime);base64,\(blob)",
                        "metadata": ["app.amber.media.sourceURL": resource["uri"] as? String ?? ""]
                    ])
                } else if mime.lowercased().hasPrefix("video/"), resource["blob"] != nil {
                    let uri = resource["uri"] as? String ?? ""
                    parts.append(["type": "text", "text": "此 MCP 资源为内嵌视频，暂不支持直接播放。\n\(uri)"])
                }
            default:
                break
            }
        }
        if text.isEmpty, let structured = result["structuredContent"], let serialized = serializedJSON(structured) {
            parts.append(["type": "text", "text": serialized])
        }
        guard !parts.isEmpty else { return IOSMcpToolOutput(text: legacyText) }
        // Build JSON-owned metadata in Kotlin; Swift dictionaries are not JsonObject.
        let data = try JSONSerialization.data(withJSONObject: parts)
        let decoded = try IosToolOutputJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
        return IOSMcpToolOutput(text: legacyText, parts: decoded)
    }

    private static func linkedMediaPart(_ item: [String: Any]) -> [String: Any]? {
        guard let rawURL = item["uri"] as? String, let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil,
              let mime = (item["mimeType"] as? String)?.lowercased() else { return nil }
        let type: String
        if mime.hasPrefix("image/") { type = "image" }
        else if mime.hasPrefix("video/") { type = "video" }
        else { return nil }
        return [
            "type": type,
            "url": rawURL,
            "metadata": [
                "app.amber.media.title": item["title"] as? String ?? item["name"] as? String ?? "",
                "app.amber.media.sourceURL": rawURL
            ]
        ]
    }

    private static func serializedJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

}
