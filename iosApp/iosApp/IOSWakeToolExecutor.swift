import Foundation
@preconcurrency import Shared

@MainActor
enum IOSWakeToolExecutor {
    static func execute(
        tool: UIMessagePart.Tool,
        runID: String,
        conversationID: String?,
        messages: [UIMessage],
        scheduler: IOSWakeScheduler
    ) async -> String {
        guard let conversationID, !conversationID.isEmpty, !runID.isEmpty else {
            return failure(tool.toolName, "续跑任务缺少所属会话或运行标识。")
        }
        guard let args = ChatToolCallParsing.jsonObject(tool.input) else {
            return failure(tool.toolName, "参数必须是 JSON 对象。")
        }
        do {
            switch tool.toolName {
            case IOSWakeToolCatalog.schedule:
                guard Set(args.keys).isSubset(of: ["title", "prompt", "fire_at", "event", "requires_foreground"]) else {
                    return failure(tool.toolName, "计划只接受任务内容与触发条件；所属会话和原始授权由 Amber 绑定。")
                }
                guard let title = nonemptyString(args["title"]), title.count <= 200,
                      let prompt = nonemptyString(args["prompt"]), prompt.count <= 8_000 else {
                    return failure(tool.toolName, "title 和 prompt 必须是非空文本，分别最多 200 和 8000 字符。")
                }
                let fireAt: Date?
                if let raw = args["fire_at"] {
                    guard let text = nonemptyString(raw), let parsed = date(text) else {
                        return failure(tool.toolName, "fire_at 必须是带时区的 ISO8601 时间。")
                    }
                    fireAt = parsed
                } else {
                    fireAt = nil
                }
                let event: String?
                if let raw = args["event"] {
                    guard let value = nonemptyString(raw), value.count <= 200 else {
                        return failure(tool.toolName, "event 必须是非空事件名，最多 200 字符。")
                    }
                    event = value
                } else {
                    event = nil
                }
                guard fireAt != nil || event != nil else {
                    return failure(tool.toolName, "至少提供 fire_at 或 event 作为触发条件。")
                }
                if let raw = args["requires_foreground"], !(raw is Bool) {
                    return failure(tool.toolName, "requires_foreground 必须是布尔值。")
                }
                guard let origin = scheduler.origin(forRunID: runID) ?? userOrigin(in: messages) else {
                    return failure(tool.toolName, "未找到本次任务的原始用户授权，无法保存自动续跑计划。")
                }
                let callID = tool.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !callID.isEmpty else {
                    return failure(tool.toolName, "计划缺少工具调用标识，无法保证重复投递不创建重复任务。")
                }
                let task = try await scheduler.schedule(
                    conversationID: conversationID,
                    sourceRunID: runID,
                    origin: origin,
                    title: title,
                    prompt: prompt,
                    fireAt: fireAt,
                    event: event,
                    requiresForeground: args["requires_foreground"] as? Bool ?? false,
                    requestID: "\(runID):\(callID)"
                )
                return IOSWorkspaceStore.json([
                    "ok": true,
                    "tool": tool.toolName,
                    "status": "saved",
                    "task": try jsonObject(task),
                    "execution_guaranteed": false,
                    "scheduling_status": scheduler.schedulingStatus,
                    "note": "计划已保存；iOS 不保证准点执行或自动切到前台。requires_foreground 的工作等待前台执行机会。event 只由快捷指令或外部入口显式报告同名事件触发，不代表正在监听其他 App。"
                ])
            case IOSWakeToolCatalog.list:
                guard args.isEmpty else { return failure(tool.toolName, "wake_list 不接受参数，只读取当前会话。") }
                return IOSWorkspaceStore.json([
                    "ok": true,
                    "tool": tool.toolName,
                    "tasks": try jsonObject(scheduler.tasks(conversationID: conversationID))
                ])
            case IOSWakeToolCatalog.cancel:
                guard Set(args.keys).isSubset(of: ["task_id"]),
                      let id = nonemptyString(args["task_id"]) else {
                    return failure(tool.toolName, "请提供当前会话中的 task_id。")
                }
                try await scheduler.cancel(id: id, conversationID: conversationID)
                let task = scheduler.tasks(conversationID: conversationID).first { $0.id == id }
                return IOSWorkspaceStore.json([
                    "ok": true, "tool": tool.toolName, "status": task?.status.rawValue ?? "cancel_requested", "task_id": id,
                    "note": "取消不能撤销已经发生的操作；已完成的任务保留实际完成状态。"
                ])
            default:
                return failure(tool.toolName, "未知的续跑工具。")
            }
        } catch {
            return failure(tool.toolName, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func userOrigin(in messages: [UIMessage]) -> IOSWakeOrigin? {
        for message in messages.reversed() where message.role == .user {
            if message.toText().hasPrefix("[Amber scheduled continuation]") {
                // A restored continuation retains its original authorization
                // in host metadata, never in the model-facing event text.
                for part in message.parts {
                    guard let encoded = IosToolOutputJsonBridge.shared.metadataString(
                        part: part, key: ChatViewModel.scheduledWakeOriginMetadataKey
                    ), let data = encoded.data(using: .utf8),
                    let origin = try? JSONDecoder().decode(IOSWakeOrigin.self, from: data) else { continue }
                    return origin
                }
                continue
            }
            if let text = nonemptyString(message.toText()) {
                return IOSWakeOrigin(userMessageID: message.id.toHexDashString(), userText: text)
            }
        }
        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    private static func failure(_ tool: String, _ reason: String) -> String {
        IOSWorkspaceStore.json(["ok": false, "tool": tool, "status": "failed", "reason": reason])
    }
}
