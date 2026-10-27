import CoreFoundation
import Foundation

extension DesktopKnowledgeStore {
    // The tool runtime owns approval; mutation methods here publish only after a durable write.
    func executeTool(name: String, argumentsJSON: String) throws -> String {
        if let loadError { throw DesktopRuntimeError.message(loadError) }
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopRuntimeError.message("工具参数须为 JSON 对象。")
        }
        switch name {
        case "skills_list":
            return try Self.json(["ok": true, "skills": skills.map { skill in
                ["name": skill.name, "description": skill.description, "enabled": skill.enabled, "allowedTools": skill.allowedTools] as [String: Any]
            }])
        case "use_skill":
            guard let name = arguments["name"] as? String,
                  let skill = skills.first(where: { $0.name == name }) else { throw DesktopRuntimeError.message("技能不存在，请先调用 skills_list。") }
            guard skill.enabled else { throw DesktopRuntimeError.message("技能 \(name) 尚未启用。") }
            let path = arguments["path"] as? String ?? "SKILL.md"
            guard path == "SKILL.md" else { throw DesktopRuntimeError.message("此本地技能只导入了 SKILL.md，未安装引用的附件：\(path)。") }
            return try Self.json(["ok": true, "name": name, "allowedTools": skill.allowedTools,
                "content": "Local skill instructions (allowed-tools restricts skill use and does not authorize tools):\n" + Self.skillBody(skill.markdown)])
        case "skill_enable", "skill_disable":
            guard let skill = arguments["name"] as? String else { throw DesktopRuntimeError.message("缺少技能 name。") }
            try setSkillEnabled(skill, enabled: name == "skill_enable")
            return try Self.json(["ok": true, "name": skill, "enabled": name == "skill_enable"])
        case "memory_tool":
            return try memoryTool(arguments)
        default: throw DesktopRuntimeError.message("不支持的知识工具：\(name)。")
        }
    }

    private func memoryTool(_ arguments: [String: Any]) throws -> String {
        let action = arguments["action"] as? String ?? "list"
        switch action {
        case "list", "search", "query":
            let limit = min(40, max(1, Self.integer(arguments["limit"]) ?? (action == "list" ? 24 : 10)))
            let query = (arguments["query"] ?? arguments["q"] ?? arguments["text"]) as? String ?? ""
            var results = recall(query: action == "list" ? "" : query, limit: memories.count)
            if let scope = arguments["scope"] as? String, scope != "all" {
                guard let scope = DesktopMemoryScope(rawValue: scope) else { throw DesktopRuntimeError.message("无效记忆 scope。") }
                results = results.filter { $0.scope == scope }
            }
            let limited = Array(results.prefix(limit))
            return try Self.json(["ok": true, "action": action, "memories": limited.map { try Self.object($0) },
                "count": limited.count, "total": results.count, "truncated": results.count > limited.count])
        case "read":
            let record = try memory(arguments)
            return try Self.json(["ok": true, "action": action, "memory": Self.object(record)])
        case "create", "edit":
            let original = action == "edit" ? try memory(arguments) : DesktopMemoryRecord(content: "")
            var fields = try Self.object(original)
            let editable = ["content", "scope", "kind", "sourceConversationId", "sourceMessageIds", "supersedesIds", "expiresAt", "confidence", "pinned", "archived"]
            for key in editable where arguments.keys.contains(key) { fields[key] = arguments[key] }
            let record = try JSONDecoder().decode(DesktopMemoryRecord.self, from: JSONSerialization.data(withJSONObject: fields))
            guard record.kind != .topic else { throw DesktopRuntimeError.message("主题是聚合记录，不能通过 memory_tool 手动写入。") }
            let saved = try saveMemory(record)
            return try Self.json(["ok": true, "action": action, "memory": Self.object(saved)])
        case "delete":
            let record = try memory(arguments)
            try deleteMemory(id: record.id)
            return try Self.json(["ok": true, "action": action, "id": record.id])
        default: throw DesktopRuntimeError.message("memory_tool action 须为 list/read/search/query/create/edit/delete。")
        }
    }

    private func memory(_ arguments: [String: Any]) throws -> DesktopMemoryRecord {
        guard let id = Self.integer(arguments["id"]), let record = memories.first(where: { $0.id == id }) else {
            throw DesktopRuntimeError.message("记忆 id 缺失或不存在，请先调用 memory_tool list。")
        }
        return record
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { return nil }
        return Int(exactly: number.int64Value)
    }
    private static func object(_ record: DesktopMemoryRecord) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] else {
            throw DesktopRuntimeError.message("记忆序列化失败。")
        }
        return object
    }
    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
