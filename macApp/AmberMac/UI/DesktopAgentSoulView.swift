import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import GatewayCore

/// Standalone modal sheet for «形象人设» (Arquiel Design 2.0).
struct DesktopAgentSoulSheet: View {
    @Bindable var soulStore: DesktopAgentSoulStore
    var cloudSelf: DesktopCloudSelfStore?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var hasUnsavedChanges = false
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("形象人设")
                        .font(DesktopTheme.serif(size: 22, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Text("跨端统一共享的角色身份、称呼与说话口吻；宿主诚实与安全守则由系统独立保留。")
                        .font(.system(size: 13))
                        .foregroundStyle(DesktopTheme.muted(colorScheme))
                }
                Spacer()
                Button("完成") {
                    if hasUnsavedChanges {
                        confirmsDiscard = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }

            DesktopAgentSoulEditorView(
                soulStore: soulStore,
                cloudSelf: cloudSelf,
                hasUnsavedChanges: $hasUnsavedChanges
            )
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog("放弃尚未保存的形象人设修改？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
}

/// Reusable «形象人设» editor embedded in both `DesktopAgentSoulSheet` and `DesktopKnowledgeView`.
struct DesktopAgentSoulEditorView: View {
    @Bindable var soulStore: DesktopAgentSoulStore
    var cloudSelf: DesktopCloudSelfStore?
    @Binding var hasUnsavedChanges: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var nameDraft = ""
    @State private var taglineDraft = ""
    @State private var markdownDraft = ""
    @State private var historyExpanded = false
    @State private var confirmsReset = false
    @State private var errorMessage: String?

    init(
        soulStore: DesktopAgentSoulStore,
        cloudSelf: DesktopCloudSelfStore? = nil,
        hasUnsavedChanges: Binding<Bool> = .constant(false)
    ) {
        self.soulStore = soulStore
        self.cloudSelf = cloudSelf
        self._hasUnsavedChanges = hasUnsavedChanges
    }

    private var isDirty: Bool {
        let normalizedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = normalizedName.isEmpty ? DesktopAgentSoulStore.defaultDisplayName : normalizedName
        let normalizedTagline = taglineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMarkdown = markdownDraft
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return effectiveName != soulStore.displayName
            || normalizedTagline != soulStore.tagline
            || normalizedMarkdown != soulStore.soulMarkdown
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusHeaderCard
                identityFieldsCard
                markdownEditorCard
                if !soulStore.history.isEmpty {
                    historyDisclosureCard
                }
            }
            .padding(.vertical, 2)
        }
        .onAppear { loadDraftFromStore() }
        .onChange(of: soulStore.state) { _, _ in
            if !isDirty {
                loadDraftFromStore()
            }
            hasUnsavedChanges = isDirty
        }
        .onChange(of: nameDraft) { _, _ in hasUnsavedChanges = isDirty }
        .onChange(of: taglineDraft) { _, _ in hasUnsavedChanges = isDirty }
        .onChange(of: markdownDraft) { _, _ in hasUnsavedChanges = isDirty }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("恢复默认 Amber 形象人设？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                perform {
                    _ = try soulStore.resetToDefault(source: "macos_ui")
                    loadDraftFromStore()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前自定义人设会自动存入下方历史快照，随时可一键回退。")
        }
    }

    private var statusHeaderCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(soulStore.isDefault ? "默认形象人设 · Amber" : soulStore.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesktopTheme.ink)
                    Text("v\(soulStore.revision)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(DesktopTheme.accentInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(DesktopTheme.honeySoft, in: Capsule())
                    if let cloud = cloudSelf, cloud.connection != nil {
                        cloudSyncBadge(cloud)
                    }
                }
                Text(statusSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let cloud = cloudSelf, cloud.connection != nil {
                Button(cloud.isSoulSyncing ? "同步中…" : "立即同步") {
                    Task { await cloud.syncSoulNow() }
                }
                .controlSize(.small)
                .disabled(cloud.isSoulSyncing)
            }
            if !soulStore.isDefault {
                Button("恢复默认") { confirmsReset = true }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private func cloudSyncBadge(_ cloud: DesktopCloudSelfStore) -> some View {
        let online = cloud.isReachable == true
        let errorText = cloud.lastSoulSyncError
        let label = errorText != nil ? "同步待重试" : (online ? "云端已连接" : "离线自动待同步")
        let tint = (errorText == nil && online) ? DesktopTheme.success : DesktopTheme.inkTertiary
        return HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesktopTheme.inkSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(DesktopTheme.surface(colorScheme), in: Capsule())
        .help(errorText ?? "已配对云端主机，修改会自动与 /v2/soul 双向同步")
    }

    private var identityFieldsCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("称呼 / 名字")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                TextField("Amber", text: $nameDraft)
                    .textFieldStyle(.desktop)
                    .accessibilityLabel("形象人设称呼")
            }
            .frame(width: 210)

            VStack(alignment: .leading, spacing: 6) {
                Text("一句话签名")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                TextField("例如：沉稳克制的技术幕僚、古风豪迈挚友…", text: $taglineDraft)
                    .textFieldStyle(.desktop)
                    .accessibilityLabel("形象人设一句话签名")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var markdownEditorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("性格、口吻与相处方式（Markdown）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesktopTheme.inkSecondary)
                Spacer()
                Button("导入 Markdown…") { chooseMarkdownFile() }
                    .controlSize(.small)
                Button("保存形象人设") { saveCurrentDraft() }
                    .buttonStyle(.desktopProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
            TextEditor(text: $markdownDraft)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 220)
                .desktopEditor()
                .accessibilityLabel("形象人设内容")
            Text("也可直接在对话中告诉智能体「把你的人设改成……」，智能体会自动调用 agent_soul_update 同步全端。")
                .font(.system(size: 12))
                .foregroundStyle(DesktopTheme.inkTertiary)
        }
    }

    private var historyDisclosureCard: some View {
        DisclosureGroup(isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(soulStore.history) { snapshot in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(snapshot.displayName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(DesktopTheme.ink)
                                if !snapshot.tagline.isEmpty {
                                    Text("· " + snapshot.tagline)
                                        .font(.system(size: 12))
                                        .foregroundStyle(DesktopTheme.inkSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Text(snapshotSubtitle(snapshot))
                                .font(.system(size: 11.5))
                                .foregroundStyle(DesktopTheme.inkTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("回退到此版本") {
                            perform {
                                _ = try soulStore.restore(snapshotID: snapshot.id)
                                loadDraftFromStore()
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    if snapshot.id != soulStore.history.last?.id {
                        Divider().overlay(DesktopTheme.hairline)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("历史版本回退（最近 \(soulStore.history.count) 条）")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DesktopTheme.inkSecondary)
        }
        .padding(12)
        .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
    }

    private var statusSubtitle: String {
        if !soulStore.tagline.isEmpty {
            return "\(soulStore.tagline) · 来源：\(humanSource(soulStore.source))"
        }
        if soulStore.isDefault {
            return "保持自然、简洁、可靠的默认身份；自定义后自动多端同步。"
        }
        return "来源：\(humanSource(soulStore.source))"
    }

    private func snapshotSubtitle(_ snap: AmberControl.SoulSnapshot) -> String {
        let timeText: String
        if snap.updatedAtMs > 0 {
            let date = Date(timeIntervalSince1970: Double(snap.updatedAtMs) / 1_000)
            timeText = date.formatted(date: .abbreviated, time: .shortened)
        } else {
            timeText = "初始默认"
        }
        let preview = snap.soulMarkdown.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = preview.isEmpty ? "默认空白正文" : String(preview.prefix(42))
        return "\(timeText) · \(humanSource(snap.source)) · \(snippet)"
    }

    private func humanSource(_ raw: String) -> String {
        switch raw {
        case "default": "系统默认"
        case "macos_ui": "此 Mac 编辑"
        case "macos_chat_self_update", "chat_self_update": "对话内自更新"
        case "macos_rollback": "历史快照回退"
        case "legacy_migration": "旧版 SOUL.md 迁移"
        default: raw
        }
    }

    private func loadDraftFromStore() {
        nameDraft = soulStore.displayName
        taglineDraft = soulStore.tagline
        markdownDraft = soulStore.soulMarkdown
        hasUnsavedChanges = false
    }

    private func saveCurrentDraft() {
        perform {
            let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.isEmpty ? DesktopAgentSoulStore.defaultDisplayName : trimmedName
            let trimmedTagline = taglineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMarkdown = markdownDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedName == DesktopAgentSoulStore.defaultDisplayName,
               trimmedTagline.isEmpty,
               trimmedMarkdown.isEmpty {
                _ = try soulStore.resetToDefault(source: "macos_ui")
            } else {
                _ = try soulStore.update(
                    displayName: resolvedName,
                    tagline: trimmedTagline,
                    soulMarkdown: trimmedMarkdown,
                    source: "macos_ui"
                )
            }
            loadDraftFromStore()
        }
    }

    private func chooseMarkdownFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            perform {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 256_000, let text = String(data: data, encoding: .utf8) else {
                    throw DesktopRuntimeError.message("请选择不超过 250 KB 的有效 UTF-8 文本文件。")
                }
                markdownDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
