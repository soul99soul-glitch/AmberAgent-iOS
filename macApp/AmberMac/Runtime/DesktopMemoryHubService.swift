import Foundation

extension DesktopPluginStore {
    static func memoryHubResourceDirectory() throws -> URL {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("MemoryHub", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("plugin.json").path) else {
            throw DesktopRuntimeError.message("记忆中心资源未包含在应用中。")
        }
        return root
    }

    static func makeBuiltInMemoryHub(enabled: Bool) throws -> DesktopInstalledPlugin {
        let root = try memoryHubResourceDirectory()
        let manifest = try JSONDecoder().decode(DesktopPluginManifest.self, from: Data(contentsOf: root.appendingPathComponent("plugin.json")))
        try manifest.validated()
        guard manifest.id == "memory_hub", manifest.isV3 else {
            throw DesktopRuntimeError.message("记忆中心内置清单无效。")
        }
        return DesktopInstalledPlugin(manifest: manifest, scriptSource: "", enabled: enabled, isBuiltIn: true)
    }
}

/// The bundled view can call only the explicitly listed memory operations, never an arbitrary MCP tool.
@MainActor final class DesktopMemoryHubService {
    private let knowledge: DesktopKnowledgeStore
    private let storage: any DesktopConversationStorage
    private var client: IOSMcpClient?
    private let cloudMethods: [String: (String, Set<String>)] = [
        "recent": ("memory_recent", ["workspace", "project", "limit"]),
        "search": ("memory_query", ["workspace", "project", "query", "path_prefix", "limit"]),
        "read": ("memory_read_page", ["workspace", "project", "scope", "path", "max_chars"]),
        "write": ("memory_write_page", ["workspace", "project", "scope", "path", "body", "title", "kind", "tier", "tags", "entities", "abstract", "relations", "pinned", "expires_at", "applies_to", "enforced_by", "expected_page_id", "create_only"]),
        "delete": ("memory_delete_page", ["workspace", "project", "scope", "path", "expected_page_id"]),
        "handoffs": ("memory_handoff_list", ["workspace", "project", "limit"]),
        "handoff_create": ("memory_handoff_begin", ["workspace", "project", "summary", "open_questions", "next_steps", "shared"]),
        "handoff_cancel": ("memory_handoff_cancel", ["workspace", "project", "handoff_id"]),
        "briefing": ("memory_briefing", ["workspace", "project", "recent_pages_limit"]),
        "checkpoints": ("memory_restore_page", ["workspace", "project", "path", "limit"]),
        "restore": ("memory_restore_page", ["workspace", "project", "path", "rev"])
    ]

    init(knowledge: DesktopKnowledgeStore, storage: any DesktopConversationStorage) {
        self.knowledge = knowledge
        self.storage = storage
    }

    func perform(method: String, arguments: [String: Any], confirm: (@MainActor (String, String) async -> Bool)?) async throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments), data.count <= 1_000_000 else {
            throw DesktopRuntimeError.message("请求数据无效或超过 1 MB。")
        }
        if ["delete", "restore", "handoff_cancel", "local_delete", "local_clear_polluted"].contains(method) {
            let target = (arguments["path"] ?? arguments["handoff_id"] ?? arguments["id"]) as? CustomStringConvertible
            let detail = target?.description ?? "所选记录"
            let scope = [arguments["workspace"] as? String, arguments["project"] as? String].compactMap { $0 }.joined(separator: "/")
            let location = scope.isEmpty ? "" : "（\(scope)）"
            guard let confirm, await confirm("确认操作", "将对「\(detail)」\(location)执行\(method == "restore" ? "历史版本恢复" : method == "handoff_cancel" ? "作废" : method == "local_clear_polluted" ? "清理污染标记" : "删除")。请确认目标与项目。") else {
                throw DesktopRuntimeError.message("操作已取消。")
            }
        }
        if method.hasPrefix("local_") {
            return try await local(method: method, arguments: arguments)
        }
        guard let (tool, allowed) = cloudMethods[method], Set(arguments.keys).isSubset(of: allowed) else {
            throw DesktopRuntimeError.message("不支持的记忆操作或参数。")
        }
        let mcp = try await connectedClient()
        var dispatched = false
        let result: [String: Any]
        do {
            result = try await mcp.callToolResult(name: tool, arguments: arguments, onDispatched: { dispatched = true })
        } catch {
            client?.disconnect()
            client = nil
            let timedOut: Bool
            if case .requestTimedOut = error as? IOSMcpClientError { timedOut = true } else { timedOut = false }
            if dispatched && ["write", "delete", "restore", "handoff_create", "handoff_cancel"].contains(method),
               error is CancellationError || timedOut {
                throw DesktopRuntimeError.message("请求已发送但结果未知，请先刷新检查，避免重复操作。")
            }
            throw error
        }
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        if result["isError"] as? Bool == true {
            throw DesktopRuntimeError.message(text.isEmpty ? "记忆服务返回错误。" : text)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)), JSONSerialization.isValidJSONObject(payload) else {
            throw DesktopRuntimeError.message("记忆服务返回了无法识别的数据。")
        }
        return try DesktopPluginStore.encodeAnyJSON(payload)
    }

    private func connectedClient() async throws -> IOSMcpClient {
        if let client { return client }
        let candidates = [NSHomeDirectory() + "/.local/bin/ai-memory", "/opt/homebrew/bin/ai-memory", "/usr/local/bin/ai-memory"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DesktopRuntimeError.message("未找到 ai-memory CLI，请先安装并配置现有服务连接。")
        }
        var server = DesktopMCPServer()
        server.name = "ai-memory"
        server.transport = .stdio
        server.command = executable
        server.arguments = ["mcp-bridge", "--no-session-id"]
        let next = IOSMcpClient(transport: DesktopMCPStdioTransport(configuration: server), requestTimeoutSeconds: 30,
                                preferredProtocolVersion: "2025-03-26", clientName: "Amber Memory Hub")
        _ = try await next.connect(config: server.clientConfiguration)
        client = next
        return next
    }

    private func local(method: String, arguments: [String: Any]) async throws -> String {
        if let error = knowledge.loadError { throw DesktopRuntimeError.message(error) }
        switch method {
        case "local_list":
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let records = knowledge.memories.filter { query.isEmpty || $0.content.localizedCaseInsensitiveContains(query) || ($0.topicTitle ?? "").localizedCaseInsensitiveContains(query) }
                .sorted { $0.updatedAt > $1.updatedAt }
            let data = try JSONEncoder().encode(records)
            return String(decoding: data, as: UTF8.self)
        case "local_save":
            guard let content = arguments["content"] as? String,
                  let scope = DesktopMemoryScope(rawValue: arguments["scope"] as? String ?? "core"),
                  let kind = DesktopMemoryKind(rawValue: arguments["kind"] as? String ?? "note"), kind != .topic else {
                throw DesktopRuntimeError.message("记忆内容、范围或分类无效。")
            }
            let id = (arguments["id"] as? NSNumber)?.intValue ?? 0
            var record: DesktopMemoryRecord
            if id == 0 { record = DesktopMemoryRecord(content: content, scope: scope, kind: kind) }
            else {
                guard let existing = knowledge.memories.first(where: { $0.id == id }) else { throw DesktopRuntimeError.message("记忆已不存在。") }
                record = existing
                record.content = content
                record.scope = scope
                record.kind = kind
            }
            record.pinned = arguments["pinned"] as? Bool ?? record.pinned
            return String(decoding: try JSONEncoder().encode(knowledge.saveMemory(record)), as: UTF8.self)
        case "local_delete":
            guard let id = (arguments["id"] as? NSNumber)?.intValue else { throw DesktopRuntimeError.message("缺少记忆编号。") }
            try knowledge.deleteMemory(id: id)
            return "{\"ok\":true}"
        case "local_evidence":
            guard let id = (arguments["id"] as? NSNumber)?.intValue,
                  let record = knowledge.memories.first(where: { $0.id == id }) else { throw DesktopRuntimeError.message("记忆已不存在。") }
            guard let source = record.sourceConversationId, let conversationID = UUID(uuidString: source),
                  let conversation = try await storage.load(conversationID) else {
                return try DesktopPluginStore.encodeAnyJSON(["messages": [], "available": false])
            }
            let ids = Set(record.sourceMessageIds.map { $0.lowercased() })
            let messages = conversation.messages.filter { ids.contains($0.id.uuidString.lowercased()) }.map {
                ["id": $0.id.uuidString, "role": $0.role.rawValue, "text": $0.text]
            }
            return try DesktopPluginStore.encodeAnyJSON(["conversation": conversation.title, "messages": messages, "available": true])
        case "local_polluted":
            return try DesktopJSON.encode(await storage.pollutedConversations())
        case "local_clear_polluted":
            guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) else {
                throw DesktopRuntimeError.message("会话编号无效。")
            }
            guard try await storage.clearPollutedConversation(id) else {
                throw DesktopRuntimeError.message("会话已不存在或不再处于污染状态，请刷新。")
            }
            return "{\"ok\":true}"

        default: throw DesktopRuntimeError.message("不支持的本机记忆操作。")
        }
    }
}
