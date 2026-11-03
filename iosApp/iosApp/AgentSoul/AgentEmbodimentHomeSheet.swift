import SwiftUI

/// Agent 化身主页：顶部角色头卡 + 人设 / 记忆 / 灵感 三栏。
///
/// 设计取舍（Arquiel Design）：
/// - 首屏只放「我是谁」和当前称呼，不放配置项与技术说明。
/// - 三栏内容各自独立，记忆与灵感都是**只读汇总**，写入仍回到既有入口，
///   避免在主页里再造一套编辑语义。
/// - 「更换形象」是二级动作：主页只提供入口，原有四段精灵图配置 100% 保留。
struct AgentEmbodimentHomeSheet: View {
    let sharedSettings: IOSSharedSettingsStore
    var onStartConversation: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var soul = AgentSoulStore.shared
    @State private var tab: Tab = .soul
    @State private var isShowingPersonaStudio = false
    @State private var isEditingSoul = false

    enum Tab: String, CaseIterable, Identifiable {
        case soul = "人设"
        case memory = "记忆"
        case ideas = "灵感"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    tabPicker
                    switch tab {
                    case .soul: soulSection
                    case .memory: AgentSoulMemorySection()
                    case .ideas: AgentSoulIdeasSection(onPick: handleIdeaPicked)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("化身主页", defaultValue: "化身主页"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accent)
                        .accessibilityIdentifier("embodiment.doneButton")
                }
            }
            .sheet(isPresented: $isShowingPersonaStudio) {
                // 原有四段精灵图 / 上传 / 生成 配置完整保留。
                AmberPersonaStudioSheet(sharedSettings: sharedSettings)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - 头卡

    private var heroCard: some View {
        VStack(spacing: 10) {
            Button {
                isShowingPersonaStudio = true
            } label: {
                AmberAgentPersonaMedallionView(mood: .idle, diameter: 108)
                    .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("embodiment.avatar")

            VStack(spacing: 3) {
                Text(soul.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground)
                if !soul.tagline.isEmpty {
                    Text(soul.tagline)
                        .font(.footnote)
                        .foregroundStyle(AmberTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                isShowingPersonaStudio = true
            } label: {
                Label(IOSAppLocalization.string("更换形象", defaultValue: "更换形象"), systemImage: "photo.on.rectangle.angled")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AmberTheme.surface, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous).stroke(AmberTheme.border, lineWidth: 0.7)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("embodiment.changeAvatarButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("embodiment.tabPicker")
    }

    // MARK: - 人设

    private var soulSection: some View {
        VStack(spacing: 12) {
            AgentSoulCard(
                title: IOSAppLocalization.string("灵魂设定", defaultValue: "灵魂设定"),
                text: soul.soulPrompt.isEmpty
                    ? IOSAppLocalization.string(
                        "还没有设定。可以在对话里直接说「你给自己写个人设」，或点上方编辑。",
                        defaultValue: "还没有设定。可以在对话里直接说「你给自己写个人设」，或点上方编辑。"
                    )
                    : soul.soulPrompt,
                isPlaceholder: soul.soulPrompt.isEmpty
            ) {
                isEditingSoul = true
            }

            if !soul.snapshots.isEmpty {
                snapshotCard
            }

            if !soul.isDefault {
                Button(role: .destructive) {
                    soul.resetToDefault()
                } label: {
                    Text(IOSAppLocalization.string("恢复默认 Amber", defaultValue: "恢复默认 Amber"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AmberTheme.accentRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AmberTheme.accentRed.opacity(0.08), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.resetToDefault")
            }
        }
        .sheet(isPresented: $isEditingSoul) {
            AgentSoulEditorSheet(store: soul)
                .presentationDetents([.large])
        }
    }

    private var snapshotCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IOSAppLocalization.string("历史人设快照", defaultValue: "历史人设快照"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)

            ForEach(soul.snapshots) { snapshot in
                Button {
                    soul.restore(snapshotID: snapshot.id)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.displayName)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(snapshot.summary?.isEmpty == false
                                 ? snapshot.summary!
                                 : Self.relativeTime(snapshot.savedAt))
                                .font(.caption2)
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(IOSAppLocalization.string("回退", defaultValue: "回退"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AmberTheme.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(AmberTheme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private func handleIdeaPicked(_ idea: AgentSoulIdea) {
        dismiss()
        onStartConversation(idea.prompt)
    }

    static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 通用说明卡片。
struct AgentSoulCard: View {
    let title: String
    /// 注意：不能叫 `body`，会与 View 的 `var body` 重名。
    let text: String
    var isPlaceholder: Bool = false
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.foreground)
                Spacer(minLength: 4)
                if let onEdit {
                    Button(IOSAppLocalization.string("编辑", defaultValue: "编辑"), action: onEdit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.accent)
                        .buttonStyle(.plain)
                }
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(isPlaceholder ? AmberTheme.muted : AmberTheme.foreground2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }
}

/// 人设编辑：称呼 / 签名 / 灵魂正文。
struct AgentSoulEditorSheet: View {
    let store: AgentSoulStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var tagline = ""
    @State private var soulText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(IOSAppLocalization.string("称呼", defaultValue: "称呼")) {
                    TextField("Amber", text: $name)
                        .accessibilityIdentifier("soulEditor.name")
                }
                Section(IOSAppLocalization.string("一句话签名", defaultValue: "一句话签名")) {
                    TextField(IOSAppLocalization.string("可选", defaultValue: "可选"), text: $tagline)
                        .accessibilityIdentifier("soulEditor.tagline")
                }
                Section(IOSAppLocalization.string("灵魂设定", defaultValue: "灵魂设定")) {
                    TextEditor(text: $soulText)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier("soulEditor.soul")
                }
            }
            .navigationTitle(IOSAppLocalization.string("编辑人设", defaultValue: "编辑人设"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSAppLocalization.string("取消", defaultValue: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSAppLocalization.string("保存", defaultValue: "保存")) {
                        store.update(
                            displayName: name,
                            tagline: tagline,
                            soulPrompt: soulText,
                            summary: IOSAppLocalization.string("手动编辑", defaultValue: "手动编辑"),
                            source: .manual
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("soulEditor.save")
                }
            }
            .onAppear {
                name = store.displayName
                tagline = store.tagline
                soulText = store.soulPrompt
            }
        }
    }
}
