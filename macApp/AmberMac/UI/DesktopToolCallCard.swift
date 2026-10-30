import SwiftUI

/// One tool call in the transcript: a quiet one-line header saying what it does, unfolding to arguments and result.
struct DesktopToolCallCard: View {
    let tool: DesktopToolCall
    @Binding var expanded: Bool

    var body: some View {
        let activity = DesktopToolActivity(tool)
        VStack(alignment: .leading, spacing: 0) {
            HeaderButton(tool: tool, activity: activity, expanded: $expanded)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tool.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.inkTertiary)
                        .textSelection(.enabled)
                    if let pluginSummary = Self.pluginPreviewSummary(tool: tool) {
                        HStack(spacing: 8) {
                            Image(systemName: pluginSummary.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesktopTheme.accent)
                            Text(pluginSummary.text)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DesktopTheme.ink)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DesktopTheme.honeySoft, in: RoundedRectangle(cornerRadius: 7))
                    }
                    section("参数", Self.prettyJSON(tool.input))
                    if !tool.output.isEmpty { section("结果", Self.prettyJSON(tool.output)) }
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .overlay(alignment: .leading) { Rectangle().fill(DesktopTheme.hairlineStrong).frame(width: 1) }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    private struct HeaderButton: View {
        let tool: DesktopToolCall
        let activity: DesktopToolActivity
        @Binding var expanded: Bool
        @State private var hovering = false

        var body: some View {
            Button {
                withAnimation(.smooth(duration: 0.24)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    statusIcon
                    Text(activity.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(hovering || expanded ? DesktopTheme.ink : DesktopTheme.inkSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let detail = activity.detail {
                        Text(detail)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(DesktopTheme.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DesktopTheme.inkTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering || expanded ? DesktopTheme.hover : DesktopTheme.paperDeep.opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DesktopTheme.hairline, lineWidth: 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tool.name)
            .accessibilityLabel("\(expanded ? "收起" : "展开")：\(activity.title)\(activity.detail.map { " " + $0 } ?? "")")
        }

        @ViewBuilder private var statusIcon: some View {
            switch tool.status {
            case .running: DesktopPulse()
            case .pending: Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(DesktopTheme.accent)
            case .denied: Image(systemName: "nosign").font(.system(size: 11)).foregroundStyle(DesktopTheme.danger)
            case .complete: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(DesktopTheme.success)
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopTheme.inkTertiary)
            ScrollView(.vertical) {
                Text(body.isEmpty ? "（空）" : body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Indents JSON objects/arrays for reading; anything else is shown as received.
    static func prettyJSON(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return value }
        return String(decoding: data, as: UTF8.self)
    }

    static func pluginPreviewSummary(tool: DesktopToolCall) -> (symbol: String, text: String)? {
        guard tool.name.hasPrefix("plugin__"),
              tool.output.utf8.count <= 16_384,
              let data = tool.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let event = obj["event"] as? [String: Any],
           let summary = event["summary"] as? String {
            let start = (event["start_time"] as? String) ?? (event["startTime"] as? String) ?? ""
            let loc = (event["location"] as? String) ?? ""
            let meta = [start, loc].filter { !$0.isEmpty }.joined(separator: " · ")
            return ("calendar.badge.checkmark", meta.isEmpty ? summary : "\(summary)（\(meta)）")
        }
        if let count = obj["count"] as? Int, obj["events"] != nil {
            return ("calendar", "共读取 \(count) 项飞书日历日程")
        }
        if let freeSlots = obj["free_slots"] as? [[String: Any]] {
            return ("clock.badge.checkmark", "发现 \(freeSlots.count) 个可约空闲时段")
        }
        if let msgID = obj["message_id"] as? String, !msgID.isEmpty,
           let title = obj["title"] as? String {
            let target = (obj["target"] as? String) ?? ""
            return ("paperplane", target.isEmpty ? "已推送：\(title)" : "已推送至 \(target)：\(title)")
        }
        if let count = obj["count"] as? Int, obj["messages"] != nil {
            let chatID = (obj["chat_id"] as? String) ?? "飞书群"
            return ("bubble.left.and.bubble.right", "已拉取 \(chatID) 近 \(count) 条消息")
        }
        if let docID = obj["document_id"] as? String, !docID.isEmpty,
           let title = obj["title"] as? String {
            return ("doc.text", "\(title)（\(docID)）")
        }
        return nil
    }
}
