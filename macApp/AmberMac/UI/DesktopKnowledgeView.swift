import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopKnowledgeView: View {
    @Bindable var store: DesktopKnowledgeStore
    let conversationIDs: Set<UUID>
    let onOpenSource: (UUID, UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var soulDraft = ""
    @State private var editingSkill: DesktopSkill?
    @State private var editingMemory: DesktopMemoryRecord?
    @State private var deletingSkill: String?
    @State private var deletingMemory: DesktopMemoryRecord?
    @State private var pendingSoulImport: URL?
    @State private var confirmsClose = false
    @State private var memoryQuery = ""
    @State private var memoryScope: DesktopMemoryScope?
    @State private var error: String?
    @State private var selectedTab = 0
    @State private var previousTab = 0

    private var soulChanged: Bool { soulDraft != store.soulMarkdown }
    private var visibleMemories: [DesktopMemoryRecord] {
        store.memories.filter {
            (memoryScope == nil || $0.scope == memoryScope)
                && (memoryQuery.isEmpty || $0.content.localizedCaseInsensitiveContains(memoryQuery)
                    || $0.topicTitle?.localizedCaseInsensitiveContains(memoryQuery) == true)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("知识与偏好").font(DesktopTheme.serif(size: 22, weight: .semibold))
                    Text("管理此 Mac 上的技能、SOUL.md 与记忆。")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
                }
                Spacer()
                Button("完成") { if soulChanged { confirmsClose = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
            }
            if let error = store.loadError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("重新读取") { perform { try store.reload(); soulDraft = store.soulMarkdown } }
                }
            }
            DesktopSegmented(options: [(0, "技能"), (1, "SOUL"), (2, "记忆")], selection: $selectedTab)
                .accessibilityLabel("知识分类")
                .disabled(store.loadError != nil)
            ZStack {
                switch selectedTab {
                case 1: soul.modifier(DesktopTabTransition(forward: selectedTab > previousTab))
                case 2: memories.modifier(DesktopTabTransition(forward: selectedTab > previousTab))
                default: skills.modifier(DesktopTabTransition(forward: selectedTab > previousTab))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: selectedTab) { old, _ in previousTab = old }
            .disabled(store.loadError != nil)
        }
        .padding(24)
        .frame(width: 800, height: 640)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .onAppear { soulDraft = store.soulMarkdown }
        .interactiveDismissDisabled(soulChanged)
        .sheet(item: $editingSkill) { skill in
            DesktopTextDocumentEditor(title: skill.name, subtitle: "编辑 SKILL.md；name 保持不变。", initialText: skill.markdown) {
                try store.saveSkill(name: skill.name, markdown: $0)
            }
        }
        .sheet(item: $editingMemory) { record in
            DesktopMemoryEditor(record: record, canOpenSource: !soulChanged, conversationIDs: conversationIDs,
                onSave: { _ = try store.saveMemory($0) }, onOpenSource: onOpenSource)
        }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("有尚未保存的 SOUL.md", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("保存并关闭") { perform { try store.saveSoul(soulDraft); dismiss() } }
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("移除这个技能？", isPresented: Binding(get: { deletingSkill != nil }, set: { if !$0 { deletingSkill = nil } }), titleVisibility: .visible) {
            Button("移除技能", role: .destructive) { if let deletingSkill { perform { try store.deleteSkill(name: deletingSkill) } }; deletingSkill = nil }
            Button("取消", role: .cancel) { deletingSkill = nil }
        } message: { Text(deletingSkill ?? "") }
        .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { deletingMemory != nil }, set: { if !$0 { deletingMemory = nil } }), titleVisibility: .visible) {
            Button("删除记忆", role: .destructive) { if let deletingMemory { perform { try store.deleteMemory(id: deletingMemory.id) } }; deletingMemory = nil }
            Button("取消", role: .cancel) { deletingMemory = nil }
        } message: { Text("这条记忆将从本地记忆库移除。来源会话会保留。") }
        .confirmationDialog("导入新的 SOUL.md？", isPresented: Binding(get: { pendingSoulImport != nil }, set: { if !$0 { pendingSoulImport = nil } }), titleVisibility: .visible) {
            Button("导入并替换") { if let pendingSoulImport { importSoul(pendingSoulImport) }; pendingSoulImport = nil }
            Button("取消", role: .cancel) { pendingSoulImport = nil }
        } message: { Text("当前内容将被所选文件替换。") }
    }

    private var skills: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("启用的技能会提供给模型选择；声明工具不会自动授予执行权限。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.muted(colorScheme)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("导入 SKILL.md…") { chooseMarkdown { url in perform { _ = try store.importSkill(from: url) } } }
            }
            List(store.allSkills) { skill in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(skill.name).font(.system(size: 13, weight: .semibold))
                            if store.isBuiltInSkill(skill.name) {
                                Text("内置")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(DesktopTheme.accentInk)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(DesktopTheme.honeySoft, in: Capsule())
                            }
                        }
                        Text(skill.description).font(.system(size: 13)).foregroundStyle(DesktopTheme.inkTertiary).fixedSize(horizontal: false, vertical: true)
                        if !skill.allowedTools.isEmpty {
                            Text("声明工具：" + skill.allowedTools.joined(separator: "、")).font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                    }
                    Spacer(minLength: 12)
                    Toggle("启用", isOn: Binding(get: { skill.enabled }, set: { enabled in perform { try store.setSkillEnabled(skill.name, enabled: enabled) } }))
                        .labelsHidden().help("启用 \(skill.name)")
                    if !store.isBuiltInSkill(skill.name) {
                        Button("编辑") { editingSkill = skill }
                        Button { deletingSkill = skill.name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("移除技能 \(skill.name)")
                    }
                }
                .padding(.vertical, 8)
            }
            .listStyle(.inset)
            .listRowSeparatorTint(DesktopTheme.hairline)
            .scrollContentBackground(.hidden)
            .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
            .overlay {
                if store.allSkills.isEmpty {
                    ContentUnavailableView("还没有技能", systemImage: "sparkles.rectangle.stack", description: Text("导入带有 name 和 description 的 SKILL.md，再选择是否启用。"))
                }
            }
        }
    }

    private var soul: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.soulSource.map { "来源：\($0)" } ?? "可定义长期的表达方式、协作习惯与偏好。")
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.muted(colorScheme)).lineLimit(2)
                Spacer()
                Button("导入…") { chooseMarkdown { pendingSoulImport = $0 } }
                Button("保存") { perform { try store.saveSoul(soulDraft) } }
                    .buttonStyle(.desktopProminent).disabled(!soulChanged)
            }
            TextEditor(text: $soulDraft).font(.system(size: 13, design: .monospaced))
                .desktopEditor()
                .accessibilityLabel("SOUL.md 内容")
            Text("保存后用于后续请求；清空并保存可停用。")
                .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
        }
    }

    private var memories: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("搜索记忆", text: $memoryQuery).textFieldStyle(.desktop)
                Picker("范围", selection: $memoryScope) {
                    Text("全部范围").tag(Optional<DesktopMemoryScope>.none)
                    ForEach(DesktopMemoryScope.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 150).labelsHidden()
                Button("新增记忆", systemImage: "plus") { editingMemory = DesktopMemoryRecord(content: "") }
            }
            List(visibleMemories) { record in
                HStack(alignment: .top, spacing: 12) {
                    Button { editingMemory = record } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.topicTitle ?? record.content).font(.system(size: 13)).lineLimit(3).foregroundStyle(.primary)
                            HStack(spacing: 8) {
                                Text(record.scope.title + " · " + record.kind.title)
                                if record.pinned { Label("已置顶", systemImage: "pin") }
                                if record.archived { Text("已归档") }
                                if let expiry = record.expiresAt, expiry <= Int64(Date().timeIntervalSince1970 * 1_000) { Text("已过期") }
                            }
                            .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button { deletingMemory = record } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("删除记忆 \(record.id)")
                }
                .padding(.vertical, 8)
            }
            .listStyle(.inset)
            .listRowSeparatorTint(DesktopTheme.hairline)
            .scrollContentBackground(.hidden)
            .background(DesktopTheme.raised(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopTheme.border(colorScheme)))
            .overlay {
                if visibleMemories.isEmpty {
                    ContentUnavailableView(store.memories.isEmpty ? "还没有记忆" : "没有匹配的记忆", systemImage: "brain", description: Text("记忆可手动添加，也会记录模型获准保存的内容。"))
                }
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }

    private func chooseMarkdown(_ completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    private func importSoul(_ url: URL) {
        perform { try store.importSoul(from: url); soulDraft = store.soulMarkdown }
    }
}

struct DesktopTextDocumentEditor: View {
    let title: String
    let subtitle: String
    let initialText: String
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var text: String
    @State private var error: String?
    @State private var confirmsDiscard = false

    init(title: String, subtitle: String, initialText: String, onSave: @escaping (String) throws -> Void) {
        self.title = title; self.subtitle = subtitle; self.initialText = initialText; self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(DesktopTheme.serif(size: 22, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(DesktopTheme.muted(colorScheme))
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced))
                .desktopEditor()
                .accessibilityLabel(title + " 内容")
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { if text != initialText { confirmsDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try onSave(text); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.desktopProminent).keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(24).frame(width: 700, height: 540)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .interactiveDismissDisabled(text != initialText)
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
}

private struct DesktopMemoryEditor: View {
    let original: DesktopMemoryRecord
    let canOpenSource: Bool
    let conversationIDs: Set<UUID>
    let onSave: (DesktopMemoryRecord) throws -> Void
    let onOpenSource: (UUID, UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var record: DesktopMemoryRecord
    @State private var expiryEnabled: Bool
    @State private var expiry: Date
    @State private var error: String?
    @State private var confirmsDiscard = false

    init(record: DesktopMemoryRecord, canOpenSource: Bool, conversationIDs: Set<UUID>, onSave: @escaping (DesktopMemoryRecord) throws -> Void, onOpenSource: @escaping (UUID, UUID?) -> Void) {
        original = record; self.canOpenSource = canOpenSource; self.conversationIDs = conversationIDs
        self.onSave = onSave; self.onOpenSource = onOpenSource
        _record = State(initialValue: record)
        _expiryEnabled = State(initialValue: record.expiresAt != nil)
        _expiry = State(initialValue: record.expiresAt.map { Date(timeIntervalSince1970: Double($0) / 1_000) } ?? Date().addingTimeInterval(30 * 24 * 60 * 60))
    }

    private var proposed: DesktopMemoryRecord {
        var value = record
        value.expiresAt = expiryEnabled ? Int64((expiry.timeIntervalSince1970 * 1_000).rounded()) : nil
        return value
    }
    private var changed: Bool { proposed != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original.id == 0 ? "新增记忆" : "编辑记忆").font(DesktopTheme.serif(size: 22, weight: .semibold))
            if record.kind == .topic {
                TextField("主题名称", text: Binding(get: { record.topicTitle ?? "" }, set: { record.topicTitle = $0 }))
                    .textFieldStyle(.desktop)
            }
            TextEditor(text: $record.content).font(.system(size: 14))
                .desktopEditor()
                .accessibilityLabel("记忆内容")
            HStack(spacing: 20) {
                Picker("范围", selection: $record.scope) { ForEach(DesktopMemoryScope.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("类型", selection: $record.kind) { ForEach(DesktopMemoryKind.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            HStack(spacing: 20) {
                Toggle("置顶", isOn: $record.pinned)
                Toggle("归档", isOn: $record.archived)
                Spacer()
            }
            HStack {
                Toggle("设置有效期", isOn: $expiryEnabled)
                if expiryEnabled { DatePicker("有效期至", selection: $expiry, displayedComponents: [.date]).labelsHidden() }
                Spacer()
            }
            if let source = record.sourceConversationId, let id = UUID(uuidString: source) {
                HStack {
                    Text("来自会话 · \(record.sourceMessageIds.count) 条来源消息").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    Spacer()
                    if conversationIDs.contains(id) {
                        Button("查看来源") { dismiss(); onOpenSource(id, record.sourceMessageIds.compactMap(UUID.init(uuidString:)).first) }
                            .disabled(changed || !canOpenSource)
                            .help("先保存当前更改后查看来源。")
                    } else {
                        Text("来源会话不在此 Mac 上").font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(DesktopTheme.accent).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { if changed { confirmsDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try onSave(proposed); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.desktopProminent).disabled(record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (record.kind != .topic || (record.topicTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(24).frame(width: 650, height: 520)
        .background(DesktopTheme.background(colorScheme))
        .tint(DesktopTheme.accent)
        .interactiveDismissDisabled(changed)
        .confirmationDialog("放弃尚未保存的修改？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
}
