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

    private var isSubAgent: Bool {
        tool.toolName.contains("subagent_dispatch")
            || tool.toolName == "spawn_agent"
            || tool.toolName == "followup_task"
    }

    private var isCouncil: Bool { tool.toolName == "model_council_run" }

    private var councilResult: [String: Any]? {
        isCouncil ? ChatToolStepModel.firstJSONObject(in: tool.output) : nil
    }

    /// Resolved inside `body` so the observable registry re-renders a sheet that
    /// was opened before approval once the run registers its live transcript.
    private var councilLive: CouncilLiveModel? {
        guard isCouncil else { return nil }
        return CouncilLiveRegistry.shared.model(
            forToolCallId: tool.toolCallId,
            taskId: councilResult?["task_id"] as? String
        )
    }

    private var isSubAgentOrchestration: Bool {
        tool.toolName == "spawn_agent" || tool.toolName == "followup_task"
    }

    private var capsulePresentation: ChatSubAgentCapsulePresentation? {
        ChatToolStepModel(tool: tool).subAgentPresentation
    }

    private var subAgentTask: String? {
        ChatToolStepModel.subAgentTask(from: tool.input)
    }

    private var receiptStatus: String? {
        (ChatToolStepModel.firstJSONObject(in: tool.output)?["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

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
        if let councilLive { return councilLive.isRunning }
        return !executed
    }

    private var outputFailureReason: String? {
        ChatToolOutputFormatter.failureReason(from: tool.output)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !isSubAgent, let onOpenSubagentConversation {
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
                    } else if isCouncil {
                        councilSections
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

    // MARK: - Council

    @ViewBuilder private var councilSections: some View {
        let result = councilResult
        let live = councilLive
        let finalAnswer = (result?["final_answer"] as? String)?.trimmedNilIfBlank

        if let objective = (ChatToolCallParsing.jsonObject(tool.input)?["objective"] as? String)?.trimmedNilIfBlank {
            section("议题") {
                LazyToolTextBlock(text: objective, style: .markdown)
            }
        }

        if let live, isRunning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                statusLine(live.state ?? "准备议会")
            }
        }

        if let finalAnswer {
            section("结论") {
                AmberMarkdownView(markdown: finalAnswer, style: .compact)
                    .font(.callout)
                    .foregroundStyle(AmberTheme.foreground)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else if Self.councilShowsFailureReason(liveMessages: live?.messages),
                  let reason = outputFailureReason ?? (result?["reason"] as? String) {
            // 讨论过程里已有失败系统消息时不再重复。
            section("结论") {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.accentRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let live {
            if !live.speakers.isEmpty {
                section("席位") {
                    CouncilRosterStrip(
                        speakers: live.speakers,
                        activeSpeakerId: live.activeSpeakerId,
                        failedSpeakerIds: live.failedSpeakerIds
                    )
                }
            }
            section("讨论过程") {
                let messages = councilTranscript(live.messages, finalAnswer: finalAnswer)
                if messages.isEmpty {
                    statusLine(isRunning ? "等待发言…" : "(无发言记录)")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            CouncilTranscriptRow(message: message)
                                .equatable()
                        }
                    }
                }
            }
        } else if let log = councilStoredLog(taskId: result?["task_id"] as? String) {
            // 本次 App 会话之外的运行：没有实时模型，回退到任务日志（仅保留末尾约 24K 字）。
            section("讨论记录") {
                LazyToolTextBlock(text: log, style: .markdown)
            }
        } else if isRunning {
            // 运行一开始就会登记实时模型；没有实时模型又没有输出，说明还在等审批或即将启动。
            statusLine("等待开始…")
        }

        DisclosureGroup("调用详情") { toolSections }
            .font(.subheadline)
    }

    /// The host synthesis is already shown under 结论; drop its duplicate tail
    /// together with the "主持总结" divider that introduces it.
    private func councilTranscript(
        _ messages: [IOSCouncilRoomMessageEvent],
        finalAnswer: String?
    ) -> [IOSCouncilRoomMessageEvent] {
        guard let finalAnswer,
              let lastIndex = messages.lastIndex(where: { $0.kind != .divider }),
              messages[lastIndex].kind == .host,
              messages[lastIndex].body.trimmingCharacters(in: .whitespacesAndNewlines) == finalAnswer else {
            return messages
        }
        var start = lastIndex
        if start > 0, messages[start - 1].kind == .divider { start -= 1 }
        return Array(messages[..<start]) + messages[(lastIndex + 1)...]
    }

    /// The runner's interrupted/cancelled and empty-objective exits return without
    /// appending a system failure message, so the transcript alone may not say why.
    static func councilShowsFailureReason(liveMessages: [IOSCouncilRoomMessageEvent]?) -> Bool {
        guard let liveMessages else { return true }
        return !liveMessages.contains { $0.kind == .system && $0.status == .failed }
    }

    private func councilStoredLog(taskId: String?) -> String? {
        guard let taskId,
              let log = IOSAdvancedTaskStore.shared.tasks.first(where: { $0.id == taskId })?.logTail
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !log.isEmpty else { return nil }
        return log
    }

    // MARK: - Subagent

    @ViewBuilder private var subAgentSections: some View {
        subAgentIdentityHeader

        if subAgentConversationLinks.count > 1, let onOpenSubagentConversation {
            ForEach(subAgentConversationLinks) { link in
                compactConversationLink(link, onOpen: onOpenSubagentConversation)
            }
        }

        if let subAgentTask {
            section("任务") {
                LazyToolTextBlock(text: subAgentTask, style: .markdown)
            }
        }

        if isSubAgentOrchestration {
            subAgentReceiptSection
        } else {
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

        DisclosureGroup("调用详情") { toolSections }
            .font(.subheadline)
    }

    @ViewBuilder private var subAgentIdentityHeader: some View {
        let presentation = capsulePresentation
        let links = subAgentConversationLinks
        if let onOpenSubagentConversation,
           links.count == 1,
           let link = links.first {
            Button {
                dismiss()
                onOpenSubagentConversation(link.id)
            } label: {
                subAgentIdentityContent(presentation: presentation, showsConversationChevron: true)
            }
            .buttonStyle(.plain)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .accessibilityLabel("查看子代理会话 \(link.title)")
            .accessibilityIdentifier("tool.openSubagentConversation")
        } else {
            subAgentIdentityContent(presentation: presentation, showsConversationChevron: false)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AmberTheme.borderSoft, lineWidth: 1)
                }
        }
    }

    @ViewBuilder private func subAgentIdentityContent(
        presentation: ChatSubAgentCapsulePresentation?,
        showsConversationChevron: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ChatSubAgentPixelAvatar(
                identity: presentation?.identity ?? "call:\(tool.toolCallId)",
                size: 28,
                isRunning: isRunning
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.map { "@\($0.displayName)" } ?? "子代理")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let workSummary = presentation?.workSummary {
                    Text(workSummary)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)

            if showsConversationChevron {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            presentation.map { "@\($0.displayName) \($0.workSummary ?? "")" } ?? "子代理"
        )
    }

    private var subAgentConversationLinks: [SubagentConversationLink] {
        SubagentConversationLink.links(from: tool)
    }

    private func compactConversationLink(
        _ link: SubagentConversationLink,
        onOpen: @escaping (String) -> Void
    ) -> some View {
        Button {
            dismiss()
            onOpen(link.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "text.bubble")
                Text("查看会话")
                Text(link.title)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("tool.openSubagentConversation")
        .accessibilityLabel("查看子代理会话 \(link.title)")
    }

    @ViewBuilder private var subAgentReceiptSection: some View {
        section("本次操作") {
            if let outputFailureReason {
                Text(outputFailureReason)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !executed {
                statusLine("正在提交任务…")
            } else {
                Text(subAgentReceiptSummary)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subAgentReceiptSummary: String {
        switch receiptStatus {
        case "queued": return "后续任务已排队；本次请求已提交。"
        default: return "本次请求已提交，打开会话查看执行记录。"
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
        if isCouncil { return "模型议会" }
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

private extension String {
    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One council transcript entry. Equatable so streaming updates re-render only
/// the message that changed. Speaking and finished bodies share `.callout` so
/// completion does not jump; finished bodies render Markdown.
private struct CouncilTranscriptRow: View, Equatable {
    let message: IOSCouncilRoomMessageEvent

    var body: some View {
        if message.kind == .divider {
            Text(message.body)
                .font(.caption.weight(.medium))
                .foregroundStyle(AmberTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header
                bodyText
                    .font(.callout)
                    .foregroundStyle(message.status == .failed ? AmberTheme.accentRed : AmberTheme.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 1)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(message.author)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = message.subtitle?.trimmedNilIfBlank {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        // 状态图标（转圈/失败）放在 overlay 里，不参与行高，各状态下头部高度一致。
        .padding(.trailing, message.status == .completed ? 0 : 22)
        .overlay(alignment: .trailing) {
            if message.status == .speaking {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            } else if message.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            message.status == .speaking
                ? IOSAppLocalization.string("发言中", defaultValue: "发言中")
                : (message.status == .failed ? IOSAppLocalization.string("失败", defaultValue: "失败") : "")
        )
    }

    @ViewBuilder private var bodyText: some View {
        if message.status == .completed {
            AmberMarkdownView(markdown: message.body, style: .compact)
        } else {
            // 流式中用纯文本，避免每拍重排 Markdown。
            Text(message.body)
        }
    }
}

/// Council seats as a single scrollable row of chips: host marked with a
/// crown, the active speaker tinted, failed seats in red.
private struct CouncilRosterStrip: View {
    let speakers: [IOSCouncilRoomSpeaker]
    let activeSpeakerId: String?
    let failedSpeakerIds: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(speakers) { speaker in
                    chip(speaker)
                }
            }
        }
        // 滚到 sheet 内边距之外再裁切，避免标签在内容边缘被硬切。
        .scrollClipDisabled()
    }

    private func chip(_ speaker: IOSCouncilRoomSpeaker) -> some View {
        let failed = failedSpeakerIds.contains(speaker.id)
        let active = !failed && speaker.id == activeSpeakerId
        let tint = failed ? AmberTheme.accentRed : (active ? AmberTheme.accent : AmberTheme.muted)
        return HStack(spacing: 4) {
            if speaker.isHost {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10, weight: .semibold))
            } else if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
            } else if active {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(speaker.name)
                .font(.footnote.weight(speaker.isHost || active ? .semibold : .regular))
                .lineLimit(1)
        }
        .foregroundStyle(failed || active ? tint : AmberTheme.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(failed || active ? 0.12 : 0.08), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(speaker, failed: failed, active: active))
    }

    private func accessibilityLabel(_ speaker: IOSCouncilRoomSpeaker, failed: Bool, active: Bool) -> String {
        var parts = [speaker.name]
        if speaker.isHost { parts.append(IOSAppLocalization.string("主持", defaultValue: "主持")) }
        if failed {
            parts.append(IOSAppLocalization.string("失败", defaultValue: "失败"))
        } else if active {
            parts.append(IOSAppLocalization.string("发言中", defaultValue: "发言中"))
        }
        return parts.joined(separator: "，")
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
