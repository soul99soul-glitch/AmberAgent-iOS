import SwiftUI
@preconcurrency import Shared

struct MemoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IOSConversationStore.self) private var conversationStore

    private let recordId: Int?

    @State private var text: String
    @State private var scope: MemoryEditScope
    @State private var pinned: Bool
    @State private var persistence = IOSMemoryPersistence.shared
    @State private var existingRecord: MemoryRecord?
    @State private var showDeleteInfo = false
    @State private var saveError: String?

    init(recordId: Int? = nil, initialText: String, initialScope: String, initialPinned: Bool) {
        self.recordId = recordId
        self._text = State(initialValue: initialText)
        self._scope = State(initialValue: MemoryEditScope(title: initialScope))
        self._pinned = State(initialValue: initialPinned)
    }

    private var conversationTitles: [String: String] {
        Dictionary(
            conversationStore.summaries.map { ($0.id.toHexDashString(), $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    sourceSection
                    contentSection
                    membersSection
                    classificationSection
                    actionsSection
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: loadRecordIfNeeded)
        .alert(deleteTitle, isPresented: $showDeleteInfo) {
            Button("删除", role: .destructive) {
                deleteCurrentRecord()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回记忆列表", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text(isTopicRecord ? "话题详情" : (recordId == nil ? "新增记忆" : "编辑记忆"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(existingRecord.map { IOSMemoryLibrary.primaryTypeTitle(for: $0) } ?? "本地保存")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
            }

            Spacer()

            MemoryDraftCloseButton {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var sourceSection: some View {
        if let existingRecord {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "记忆信息")
                AmberFormGroup {
                    let typeLabel: String = {
                        let primary = IOSMemoryLibrary.primaryTypeTitle(for: existingRecord)
                        if let secondary = IOSMemoryLibrary.secondaryKindTitle(for: existingRecord) {
                            return "\(primary) · \(secondary)"
                        }
                        return primary
                    }()
                    MemoryPreviewLine(label: "类型", value: typeLabel)
                    MemoryEditDivider()
                    if isTopicRecord {
                        MemoryPreviewLine(label: "来源对话", value: "由记忆整理自动维护")
                        MemoryEditDivider()
                        MemoryPreviewLine(label: "聚合记忆", value: "\(topicMembers.count) 条")
                    } else {
                        MemoryPreviewLine(
                            label: "来源对话",
                            value: IOSMemoryLibrary.sourceDisplay(for: existingRecord, conversationTitles: conversationTitles)
                        )
                    }
                    MemoryEditDivider()
                    MemoryPreviewLine(
                        label: "最近被用到",
                        value: existingRecord.lastUsedAt.map { dateText($0.int64Value) } ?? "尚未被引用"
                    )
                    MemoryEditDivider()
                    MemoryPreviewLine(label: "更新时间", value: dateText(existingRecord.updatedAt))
                    if let expiresAt = existingRecord.expiresAt?.int64Value {
                        MemoryEditDivider()
                        // expiresAt 是失效的那一刻（通常是次日 0 点），显示最后有效时刻。
                        MemoryPreviewLine(label: "有效期至", value: dateText(expiresAt - 1))
                    }
                }
            }
        }
    }

    /// 主题详情：列出成员记忆的正文，只读；与来源行的计数共用同一解析结果，
    /// 只统计仍能解析且未归档的成员。
    private var topicMembers: [MemoryRecord] {
        guard let topic = existingRecord, isTopicRecord else { return [] }
        let memberIds = Set(topic.memberIds.map { Int(truncating: $0) })
        return persistence.records.filter { memberIds.contains(Int($0.id)) && !$0.archived && $0.kind != .topic }
    }

    @ViewBuilder
    private var membersSection: some View {
        if isTopicRecord, !topicMembers.isEmpty {
            VStack(spacing: 0) {
                AmberSectionLabel(text: "成员记忆")
                AmberFormGroup {
                    ForEach(Array(topicMembers.enumerated()), id: \.element.id) { index, member in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.content)
                                .font(.subheadline)
                                .foregroundStyle(AmberTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(IOSMemoryLibrary.scopeTitle(member.scope)) · \(IOSMemoryLibrary.kindTitle(member.kind))")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < topicMembers.count - 1 {
                            MemoryEditDivider()
                        }
                    }
                }
            }
        }
    }

    private var isTopicRecord: Bool { existingRecord?.kind == .topic }

    private var contentSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "内容")

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground2)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 176)
                    .disabled(isTopicRecord)

                if text.isEmpty {
                    Text("写一条偏好、事实或项目上下文")
                        .font(.body)
                        .foregroundStyle(AmberTheme.muted2)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .background(AmberTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
            }
            .padding(.horizontal, 16)

            if isTopicRecord {
                Text("主题由记忆整理自动维护，仅支持查看与删除。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
        }
    }

    private var classificationSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "归类")
            AmberFormGroup {
                Menu {
                    ForEach(MemoryEditScope.allCases) { option in
                        Button(option.title) {
                            scope = option
                        }
                    }
                } label: {
                    MemoryValueRow(
                        title: "记忆层级",
                        subtitle: "决定聊天参考这条记忆的场景。",
                        value: scope.title
                    )
                }
                .disabled(isTopicRecord)

                MemoryEditDivider()

                Button {
                    pinned.toggle()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("置顶")
                                .font(.body)
                                .foregroundStyle(AmberTheme.foreground)
                            Text("置顶记忆会更优先被聊天参考。")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        MemoryEditSwitch(isOn: pinned)
                    }
                    .frame(minHeight: 58)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isTopicRecord)
                .accessibilityLabel("置顶")
                .accessibilityValue(pinned ? "已置顶" : "未置顶")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// 底栏动作：主按钮「保存」突出显示，次级提供「归档 / 恢复」与「删除」。
    private var actionsSection: some View {
        VStack(spacing: 10) {
            if !isTopicRecord {
                Button {
                    saveMemory()
                } label: {
                    Text("保存")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canSave ? AmberTheme.accentInk : AmberTheme.muted2)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .background(
                    canSave ? AmberTheme.accent : AmberTheme.surface,
                    in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                        .stroke(canSave ? AmberTheme.accent.opacity(0.2) : AmberTheme.borderSoft, lineWidth: 0.5)
                }
            }

            if let existingRecord {
                HStack(spacing: 12) {
                    if !isTopicRecord {
                        Button {
                            toggleArchive(existingRecord)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: existingRecord.archived ? "arrow.uturn.backward" : "archivebox")
                                    .font(.subheadline.weight(.semibold))
                                Text(existingRecord.archived ? "恢复记忆" : "归档")
                                    .font(.body.weight(.semibold))
                            }
                            .foregroundStyle(existingRecord.archived ? AmberTheme.accent : AmberTheme.foreground2)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                                .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteInfo = true
                    } label: {
                        Text("删除")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AmberTheme.radiusXLarge, style: .continuous)
                            .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    private func toggleArchive(_ record: MemoryRecord) {
        saveError = nil
        persistence.refresh()
        guard let current = persistence.records.first(where: { $0.id == record.id }),
              current.updatedAt == record.updatedAt else {
            saveError = "操作失败：这条记忆已在其他地方更新，请返回后重新打开。"
            return
        }
        let previousRecords = persistence.records
        let now = nowMillis()
        let updated: MemoryRecord?
        if current.archived {
            updated = IosMemoryFactory.shared.restoreMemory(id: current.id, now: now)
        } else {
            updated = IosMemoryFactory.shared.setArchived(id: current.id, archived: true)
        }
        guard let saved = updated else {
            saveError = "操作失败：这条记忆不存在。"
            return
        }
        guard persistence.persist(previousRecords: previousRecords) else {
            saveError = persistence.lastErrorMessage ?? "操作失败：无法写入记忆。"
            return
        }
        IOSMemoryWriteAuditStore.shared.record(
            action: current.archived ? "restore" : "invalidate",
            status: "user_saved",
            memoryId: Int(saved.id),
            scope: saved.scope.wireName,
            kind: saved.kind.wireName,
            contentPreview: IOSMemoryLibrary.preview(saved.content)
        )
        dismiss()
    }

    private var canSave: Bool {
        persistence.loadState != .unreadable &&
            !isTopicRecord &&
            (recordId == nil || existingRecord != nil) &&
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var deleteTitle: String {
        recordId == nil ? "删除记忆？" : "删除这条记忆？"
    }

    private var deleteMessage: String {
        "删除后不会再被聊天召回。此操作不可恢复。"
    }

    private func loadRecordIfNeeded() {
        guard persistence.loadState != .unreadable else {
            saveError = persistence.lastErrorMessage
            return
        }
        guard let recordId else { return }
        persistence.refresh()
        guard let record = persistence.records.first(where: { Int($0.id) == recordId }) else {
            saveError = "这条记忆不存在，可能已经被删除。"
            return
        }
        existingRecord = record
        text = record.content
        scope = MemoryEditScope(scope: record.scope)
        pinned = record.pinned
    }

    private func saveMemory() {
        saveError = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            saveError = "内容不能为空。"
            return
        }
        guard recordId == nil || existingRecord != nil else {
            saveError = "保存失败：这条记忆不存在，可能已经被删除。"
            return
        }

        if let existingRecord {
            guard let current = persistence.records.first(where: { $0.id == existingRecord.id }),
                  current.updatedAt == existingRecord.updatedAt else {
                saveError = "保存失败：这条记忆已在其他地方更新，请返回后重新打开。"
                return
            }
            guard current.kind != .topic else {
                saveError = "主题由记忆整理自动维护，不支持编辑。"
                return
            }
            let updatedAt = nowMillis()
            let updated = MemoryRecord(
                id: existingRecord.id,
                content: trimmed,
                scope: scope.memoryScope,
                kind: current.kind,
                assistantId: scope.bucket,
                sourceConversationId: current.sourceConversationId,
                sourceMessageIds: current.sourceMessageIds,
                supersedesIds: current.supersedesIds,
                expiresAt: current.expiresAt,
                confidence: current.confidence,
                pinned: pinned,
                archived: current.archived,
                createdAt: current.createdAt,
                updatedAt: updatedAt,
                lastUsedAt: current.lastUsedAt,
                topicTitle: current.topicTitle,
                memberIds: current.memberIds,
                lastReinforcedAt: current.lastReinforcedAt
            )
            let previousRecords = persistence.records
            guard let saved = IosMemoryFactory.shared.updateRecord(record: updated) else {
                saveError = "保存失败：这条记忆不存在。"
                IOSMemoryWriteAuditStore.shared.record(action: "edit", status: "failed", reason: "memory not found", memoryId: Int(existingRecord.id))
                return
            }
            guard persistence.persist(previousRecords: previousRecords) else {
                saveError = persistence.lastErrorMessage ?? "保存失败：无法写入记忆。"
                return
            }
            IOSMemoryWriteAuditStore.shared.record(
                action: "edit",
                status: "user_saved",
                memoryId: Int(saved.id),
                scope: saved.scope.wireName,
                kind: saved.kind.wireName,
                contentPreview: IOSMemoryLibrary.preview(saved.content)
            )
        } else {
            let previousRecords = persistence.records
            let record = IosMemoryFactory.shared.addDetailedMemory(
                scope: scope.memoryScope,
                kind: scope.memoryScope == MemoryScope.shortTerm ? MemoryKind.project : MemoryKind.note,
                content: trimmed,
                assistantId: scope.bucket,
                sourceConversationId: nil,
                sourceMessageIds: [],
                supersedesIds: [],
                expiresAt: nil,
                confidence: 1,
                pinned: pinned,
                archived: false
            )
            guard persistence.persist(previousRecords: previousRecords) else {
                saveError = persistence.lastErrorMessage ?? "保存失败：无法写入记忆。"
                return
            }
            IOSMemoryWriteAuditStore.shared.record(
                action: "create",
                status: "user_saved",
                memoryId: Int(record.id),
                scope: record.scope.wireName,
                kind: record.kind.wireName,
                contentPreview: IOSMemoryLibrary.preview(record.content)
            )
        }
        dismiss()
    }

    private func deleteCurrentRecord() {
        guard let recordId else { return }
        persistence.refresh()
        guard let current = persistence.records.first(where: { Int($0.id) == recordId }),
              existingRecord?.updatedAt == current.updatedAt else {
            saveError = "删除失败：这条记忆已在其他地方更新，请返回后重新打开。"
            return
        }
        let previousRecords = persistence.records
        IosMemoryFactory.shared.deleteMemory(id: Int32(recordId))
        guard persistence.persist(previousRecords: previousRecords) else {
            saveError = persistence.lastErrorMessage ?? "删除失败：无法写入记忆。"
            return
        }
        IOSMemoryWriteAuditStore.shared.record(action: "delete", status: "user_deleted", memoryId: recordId)
        dismiss()
    }

    private func dateText(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
        let formatter = DateFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

private enum MemoryEditScope: String, CaseIterable, Identifiable {
    case core
    case longTerm
    case shortTerm

    init(title: String) {
        switch title {
        case "长期":
            self = .longTerm
        case "短期":
            self = .shortTerm
        default:
            self = .core
        }
    }

    init(scope: MemoryScope) {
        if scope == MemoryScope.shortTerm {
            self = .shortTerm
        } else if scope == MemoryScope.longTerm {
            self = .longTerm
        } else {
            self = .core
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "核心"
        case .longTerm: "长期"
        case .shortTerm: "短期"
        }
    }

    var memoryScope: MemoryScope {
        switch self {
        case .core: MemoryScope.core
        case .longTerm: MemoryScope.longTerm
        case .shortTerm: MemoryScope.shortTerm
        }
    }

    var bucket: String {
        switch self {
        case .core: IosMemoryFactory.shared.GLOBAL_MEMORY_ID
        case .shortTerm: IosMemoryFactory.shared.SHORT_TERM_MEMORY_ID
        case .longTerm: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        }
    }
}

private struct MemoryValueRow: View {
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

private struct MemoryEditSwitch: View {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(isOn ? AmberTheme.accent : AmberTheme.surface2)
            .frame(width: 48, height: 28)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                    .padding(2)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isOn)
    }
}

private struct MemoryPreviewLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
    }
}

private struct MemoryEditDivider: View {
    var body: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

private struct MemoryDraftCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("关闭")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground2)
                .frame(height: 36)
                .padding(.horizontal, 14)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Capsule())
        .amberGlass(cornerRadius: AmberTheme.radiusPill)
        .accessibilityLabel("关闭")
    }
}
