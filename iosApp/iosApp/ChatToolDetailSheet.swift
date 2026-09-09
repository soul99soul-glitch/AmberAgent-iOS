import SwiftUI
@preconcurrency import Shared

/// Identifiable wrapper so a tapped tool can drive `.sheet(item:)`.
struct ToolDetailTarget: Identifiable {
    let toolCallId: String
    let initialTool: UIMessagePart.Tool

    var id: String { toolCallId }

    init(tool: UIMessagePart.Tool) {
        self.toolCallId = tool.toolCallId
        self.initialTool = tool
    }
}

struct SubagentConversationLink: Identifiable, Equatable {
    let id: String
    let title: String

    static func links(from tool: UIMessagePart.Tool) -> [Self] {
        guard ["spawn_agent", "followup_task", "send_message", "interrupt_agent", "list_agents"].contains(tool.toolName) else { return [] }
        var links: [Self] = []
        for case let part as UIMessagePart.Text in tool.output {
            guard let data = part.text.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  result["ok"] as? Bool == true else { continue }
            let entries = tool.toolName == "list_agents" ? (result["threads"] as? [[String: Any]] ?? []) : [result]
            for entry in entries {
                guard let rawID = (entry["child_thread_id"] ?? entry["recipient_thread_id"]) as? String,
                      let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                      !links.contains(where: { $0.id == id }) else { continue }
                let path = (entry["agent_path"] ?? entry["task_name"] ?? entry["target"]) as? String
                let title = path?.split(separator: "/").last.map(String.init) ?? "子代理会话"
                links.append(Self(id: id, title: title))
            }
        }
        return links
    }
}

/// Detail sheet shown when a tool / subagent capsule is tapped. Mirrors the
/// Android `ToolCallPreviewSheet` / `SubAgentRunSheet`: for a normal tool it
/// shows the call arguments + rendered output; for a subagent it shows the
/// task objective, status, and the generated report. Live token streaming for a
/// still-running subagent is layered on top via `SubAgentLiveModel` (only used
/// when a live flow exists; otherwise this falls back to the stored output).
struct ChatToolDetailSheet: View {
    let tool: UIMessagePart.Tool
    /// Optional live model for a running subagent (nil for normal tools or when
    /// no live flow is available — then the stored `tool.output` is shown).
    var live: SubAgentLiveModel? = nil
    var onOpenSubagentConversation: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var isSubAgent: Bool { tool.toolName.contains("subagent_dispatch") }
    private var executed: Bool { !tool.output.isEmpty }

    private var storedOutputText: String {
        tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var outputImages: [UIMessagePart.Image] {
        tool.output.compactMap { $0 as? UIMessagePart.Image }
    }

    /// Subagent body text: prefer live stream, fall back to the stored report.
    private var subAgentText: String {
        if let liveText = live?.text, !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveText
        }
        return storedOutputText
    }

    private var isRunning: Bool {
        if let live { return live.isRunning }
        return !executed
    }

    private var outputFailureReason: String? {
        ChatToolOutputFormatter.failureReason(from: tool.output)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let onOpenSubagentConversation {
                        ForEach(SubagentConversationLink.links(from: tool)) { link in
                            Button {
                                dismiss()
                                onOpenSubagentConversation(link.id)
                            } label: {
                                HStack {
                                    Label("查看会话：\(link.title)", systemImage: "text.bubble")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("tool.openSubagentConversation")
                        }
                    }
                    if isSubAgent {
                        subAgentSections
                    } else if tool.toolName == "spawn_agent" || tool.toolName == "followup_task" {
                        orchestrationSections
                    } else {
                        toolSections
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(AmberTheme.background)
            .navigationTitle(localizedFriendlyName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await live?.start() }
        .onDisappear { live?.stop() }
    }

    // MARK: - Normal tool

    @ViewBuilder private var orchestrationSections: some View {
        if let message = ChatToolCallParsing.jsonObject(tool.input)?["message"] as? String {
            section("任务") {
                Text(message).font(.subheadline).textSelection(.enabled)
            }
        }
        section("本次操作") {
            if let outputFailureReason {
                Text(outputFailureReason).font(.subheadline).foregroundStyle(AmberTheme.accentAmber)
            } else if !executed {
                statusLine("正在提交任务…")
            } else {
                let result = ChatToolCallParsing.jsonObject(storedOutputText)
                if result?["status"] as? String == "started" {
                    statusLine("启动请求已提交，打开会话查看执行记录。")
                } else if result?["status"] as? String == "queued" {
                    statusLine("后续任务已排队，打开会话查看记录。")
                } else {
                    statusLine("本次调用已返回，打开会话查看记录。")
                }
            }
        }
        DisclosureGroup("调用详情") { toolSections }
            .font(.subheadline)
    }

    @ViewBuilder private var toolSections: some View {
        section("工具") {
            Text(tool.toolName.isEmpty ? friendlyName : tool.toolName)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        let parametersSource: String = {
            if IOSProviderConfigToolCatalog.toolNames.contains(tool.toolName) {
                return IOSProviderConfigToolCatalog.redactedArgumentsJSON(tool.input)
            }
            return tool.input
        }()
        if let pretty = Self.prettyJSON(parametersSource) {
            section("参数") { codeBlock(pretty) }
        }
        section("结果") {
            if !executed {
                statusLine("尚未执行或无返回")
            } else {
                if let notice = webMountUncertainNotice {
                    Label(notice, systemImage: "arrow.clockwise.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !storedOutputText.isEmpty { codeBlock(storedOutputText) }
                ForEach(Array(outputImages.enumerated()), id: \.offset) { _, img in
                    AsyncImage(url: Self.imageURL(from: img.url)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if storedOutputText.isEmpty && outputImages.isEmpty {
                    statusLine("(无文本结果)")
                }
            }
        }
    }

    // MARK: - Subagent

    @ViewBuilder private var subAgentSections: some View {
        if let objective = Self.subAgentObjective(from: tool.input) {
            section("任务目标") {
                Text(objective)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
                    .textSelection(.enabled)
            }
        }
        section("状态") {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.mini).tint(AmberTheme.accent)
                    Text("正在工作").foregroundStyle(AmberTheme.accent)
                } else if outputFailureReason != nil {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AmberTheme.accentRed)
                    Text("执行失败").foregroundStyle(AmberTheme.accentRed)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AmberTheme.accentGreen)
                    Text("已完成").foregroundStyle(AmberTheme.accentGreen)
                }
            }
            .font(.footnote.weight(.medium))
        }
        section("生成内容") {
            let text = subAgentText
            if let outputFailureReason {
                Text(outputFailureReason)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if text.isEmpty {
                statusLine(isRunning ? "等待输出…" : "(无输出)")
            } else {
                LazyToolTextBlock(text: text, style: .markdown)
            }
        }
    }

    // MARK: - Building blocks

    private var localizedFriendlyName: String {
        IOSAppLocalization.string(friendlyName, defaultValue: friendlyName)
    }

    private var friendlyName: String {
        if ["spawn_agent", "followup_task", "send_message", "list_agents", "interrupt_agent", "wait_agent"].contains(tool.toolName) {
            return ChatToolStepModel.friendlyToolTitle(tool.toolName, executed: executed)
        }
        if isSubAgent { return "子智能体" }
        if tool.toolName == "terminal_execute" { return "Remote SSH 执行" }
        if tool.toolName == IOSAmberShellToolCatalog.executeToolName {
            return IOSAppLocalization.string("AmberShell 执行", defaultValue: "AmberShell 执行")
        }
        if tool.toolName == "ish_handoff" { return "iSH 交接" }
        if tool.toolName == "ios_ish_execute" { return "内置 iSH 执行" }
        if IOSPluginToolCatalog.toolNames.contains(tool.toolName) {
            return ChatToolStepModel.friendlyToolTitle(tool.toolName, executed: !tool.output.isEmpty)
        }
        if IOSAppleAgentToolCatalog.toolNames.contains(tool.toolName) {
            return McpToolApprovalRequest.displayName(for: tool.toolName)
        }
        if IOSRemoteTerminalToolCatalog.jobToolNames.contains(tool.toolName) {
            let runtime = ChatToolStepModel.firstJSONObject(in: tool.output)?["runtime"] as? String
            return runtime == IOSTerminalRuntimeKind.ishExperimental.rawValue
                ? "内置 iSH 作业控制"
                : (runtime == IOSTerminalRuntimeKind.remoteSSH.rawValue
                    ? "Remote SSH 作业控制"
                    : "终端作业控制")
        }
        if tool.toolName.isEmpty { return "工具调用" }
        return tool.toolName
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IOSAppLocalization.string(title, defaultValue: title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(_ text: String) -> some View {
        LazyToolTextBlock(text: text)
    }

    private func statusLine(_ text: String) -> some View {
        Text(IOSAppLocalization.string(text, defaultValue: text))
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
    }

    private var webMountUncertainNotice: String? {
        guard tool.toolName.hasPrefix("wm_"),
              let object = ChatToolStepModel.firstJSONObject(in: tool.output),
              object["may_have_applied"] as? Bool == true,
              let status = (object["status"] as? String)?.lowercased(),
              ["dispatched_unverified", "ambiguous", "unknown_after_action"].contains(status) else {
            return nil
        }
        return "操作已发送，但结果尚未验证；请先重新观察页面。"
    }

    // MARK: - Parsing helpers

    static func prettyJSON(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: pretty, encoding: .utf8)
        else { return trimmed }
        return str
    }

    static func subAgentObjective(from input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // iOS subagent_dispatch uses "objective"; the KMP path nests under task.objective.
        if let objective = obj["objective"] as? String, !objective.isEmpty { return objective }
        if let task = obj["task"] as? [String: Any], let objective = task["objective"] as? String, !objective.isEmpty {
            return objective
        }
        return nil
    }

    static func imageURL(from raw: String) -> URL? {
        IOSImageGenerationRepository.resolvedImageURL(from: raw)
    }

    static func markdownAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct LazyToolTextBlock: View {
    enum Style {
        case code
        case markdown
    }

    let text: String
    var style: Style = .code
    @State private var isExpanded = false

    private let previewLimit = 1_600

    private var isLong: Bool {
        text.utf8.count > previewLimit
    }

    private var displayText: String {
        guard isLong, !isExpanded else { return text }
        return String(text.prefix(previewLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            renderedText

            if isLong {
                Divider().overlay(AmberTheme.borderSoft)

                Button {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isExpanded ? "收起完整内容" : "展开完整内容")
                        Spacer(minLength: 0)
                        Text(byteCountText)
                            .foregroundStyle(AmberTheme.muted2)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var renderedText: some View {
        Group {
            switch style {
            case .code:
                Text(displayText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AmberTheme.foreground2)
            case .markdown:
                Text(ChatToolDetailSheet.markdownAttributed(displayText))
                    .font(.callout)
                    .foregroundStyle(AmberTheme.foreground)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var byteCountText: String {
        Int64(text.utf8.count).formatted(
            .byteCount(style: .file)
                .locale(IOSAppLanguagePreference.selected().resolvedLocale())
        )
    }
}
