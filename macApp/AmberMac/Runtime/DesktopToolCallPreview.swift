import Foundation

/// Compact summaries for tool call cards. Pure, so the runtime tests cover the plugin output shapes
/// without linking SwiftUI.
enum DesktopToolCallPreview {
    struct Summary: Equatable, Sendable {
        let symbol: String
        let text: String
    }

    static func pluginSummary(for tool: DesktopToolCall) -> Summary? {
        guard tool.name.hasPrefix("plugin__"),
              tool.output.utf8.count <= 16_384,
              let data = tool.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let isAppleSchedule = (obj["plugin"] as? String) == DesktopAppleScheduleTools.pluginID
            || tool.name.hasPrefix("plugin__\(DesktopAppleScheduleTools.pluginID)__")
        if let event = obj["event"] as? [String: Any],
           let summary = (event["summary"] as? String) ?? (event["title"] as? String), !summary.isEmpty {
            let start = (event["start_time"] as? String) ?? (event["startTime"] as? String)
                ?? (event["start_at"] as? String) ?? ""
            let loc = (event["location"] as? String) ?? ""
            let meta = [start, loc].filter { !$0.isEmpty }.joined(separator: " · ")
            return Summary(symbol: "calendar.badge.checkmark", text: meta.isEmpty ? summary : "\(summary)（\(meta)）")
        }
        if let count = obj["count"] as? Int, obj["events"] != nil {
            let sourceName = isAppleSchedule ? "本机日历" : "飞书日历"
            return Summary(symbol: "calendar", text: "共读取 \(count) 项\(sourceName)日程")
        }
        if let count = obj["count"] as? Int, obj["reminders"] != nil {
            return Summary(symbol: "checklist", text: "共读取 \(count) 项本机提醒事项")
        }
        if let freeSlots = obj["free_slots"] as? [[String: Any]] {
            return Summary(symbol: "clock.badge.checkmark", text: "发现 \(freeSlots.count) 个可约空闲时段")
        }
        if let msgID = obj["message_id"] as? String, !msgID.isEmpty,
           let title = obj["title"] as? String {
            let target = (obj["target"] as? String) ?? ""
            return Summary(symbol: "paperplane", text: target.isEmpty ? "已推送：\(title)" : "已推送至 \(target)：\(title)")
        }
        if let count = obj["count"] as? Int, obj["messages"] != nil {
            let chatID = (obj["chat_id"] as? String) ?? "飞书群"
            return Summary(symbol: "bubble.left.and.bubble.right", text: "已拉取 \(chatID) 近 \(count) 条消息")
        }
        if let docID = obj["document_id"] as? String, !docID.isEmpty,
           let title = obj["title"] as? String {
            return Summary(symbol: "doc.text", text: "\(title)（\(docID)）")
        }
        return nil
    }
}
