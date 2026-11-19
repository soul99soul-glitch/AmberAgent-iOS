import SwiftUI
@preconcurrency import Shared

/// 全部记忆记录的管理页：主页面只放聚合后的 Markdown 文档，单条记录的
/// 搜索、筛选、查看、编辑、删除集中在这里。
struct MemoryRecordsListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore

    @State private var persistence = IOSMemoryPersistence.shared
    @State private var query = ""
    @State private var scopeFilter: IOSMemoryScopeFilter = .all
    @State private var pendingDeleteRecord: MemoryRecord?
    @State private var recentlyArchivedRecord: MemoryRecord?
    @State private var operationError: String?

    private var conversationTitles: [String: String] {
        Dictionary(
            conversationStore.summaries.map { ($0.id.toHexDashString(), $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var filteredRecords: [MemoryRecord] {
        IOSMemoryLibrary.filteredRecords(records: persistence.records, query: query, scopeFilter: scopeFilter)
    }

    var body: some View {
        let rows = filteredRecords
        return ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    chrome
                    libraryToolbar

                    if let archived = recentlyArchivedRecord {
                        undoArchiveBanner(for: archived)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }

                    if rows.isEmpty {
                        AmberFormGroup {
                            if scopeFilter == .archived {
                                MemoryEmptyState(
                                    isSearching: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    archived: true
                                )
                            } else {
                                // 只剩归档记录（被取代、作废或过期）时库对用户而言是空的，不是"没有匹配"。
                                MemoryEmptyState(isSearching: persistence.records.contains { !$0.archived })
                            }
                        }
                    } else {
                        AmberFormGroup {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                                MemoryRecordRow(
                                    record: record,
                                    memberCount: record.kind == .topic
                                        ? IOSMemoryLibrary.liveMemberCount(of: record, in: persistence.records)
                                        : 0,
                                    conversationTitles: conversationTitles,
                                    onEdit: {
                                        router.navigate(to: .memoryEdit(
                                            recordId: Int(record.id),
                                            text: record.content,
                                            scope: IOSMemoryLibrary.scopeTitle(record.scope),
                                            pinned: record.pinned
                                        ))
                                    },
                                    onArchive: {
                                        archive(record)
                                    },
                                    onDelete: {
                                        pendingDeleteRecord = record
                                    },
                                    onRestore: {
                                        restore(record)
                                    }
                                )

                                if index < rows.count - 1 {
                                    MemoryDivider(leading: 14)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .alert("无法保存", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好") { operationError = nil }
        } message: {
            Text(operationError ?? "未知错误")
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: Binding(
                get: { pendingDeleteRecord != nil },
                set: { if !$0 { pendingDeleteRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let record = pendingDeleteRecord {
                    delete(record)
                }
                pendingDeleteRecord = nil
            }
            Button("取消", role: .cancel) { pendingDeleteRecord = nil }
        } message: {
            Text("删除后不可恢复。若只是暂时停用，建议改为归档。")
        }
    }

    private func undoArchiveBanner(for record: MemoryRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.accentAmber)
                .accessibilityHidden(true)

            Text("已归档「\(IOSMemoryLibrary.preview(record.content, limit: 22))」")
                .font(.caption.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                restore(record)
                recentlyArchivedRecord = nil
            } label: {
                Text("撤销")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AmberTheme.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                recentlyArchivedRecord = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            AmberTheme.surface,
            in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
        }
    }

    private var chrome: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回记忆", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text("全部记忆")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text("\(IOSMemoryLibrary.liveMemoryCount(persistence.records)) 条本地记忆")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            AmberGlassIconButton(
                systemImage: "plus",
                accessibilityLabel: "新增记忆",
                size: 44,
                symbolSize: 20,
                tint: AmberTheme.accent,
                prominent: true
            ) {
                router.navigate(to: .memoryEdit(recordId: nil, text: "", scope: "核心", pinned: false))
            }
            .disabled(persistence.loadState == .unreadable)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// 记忆库工具条：搜索 + 五枚过滤（四个范围 + 已归档，等分铺开，不做横滑簇拥）。
    private var libraryToolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AmberTheme.muted)
                    .accessibilityHidden(true)
                TextField("搜索内容、来源或标签", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AmberTheme.muted2)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("清除搜索")
                }
            }
            .font(.body)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .amberGlass(cornerRadius: AmberTheme.radiusLarge)
            .overlay {
                RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 0.5)
            }

            HStack(spacing: 8) {
                ForEach(IOSMemoryScopeFilter.allCases) { filter in
                    Button {
                        scopeFilter = filter
                    } label: {
                        MemoryScopeFilterChip(
                            title: filter.title,
                            isSelected: scopeFilter == filter
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(scopeFilter == filter ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// 归档记录：支持一键撤销或切到「已归档」恢复。
    private func archive(_ record: MemoryRecord) {
        guard persistence.records.contains(where: { $0.id == record.id && $0.updatedAt == record.updatedAt }) else {
            operationError = "这条记忆已在其他地方更新或删除，请重试。"
            persistence.refresh()
            return
        }
        let previousRecords = persistence.records
        guard let archivedRecord = IosMemoryFactory.shared.setArchived(id: record.id, archived: true) else {
            operationError = "这条记忆不存在，请重试。"
            persistence.refresh()
            return
        }
        guard persistence.persist(previousRecords: previousRecords) else {
            operationError = persistence.lastErrorMessage ?? "无法写入记忆。"
            return
        }
        IOSMemoryWriteAuditStore.shared.record(
            action: "invalidate",
            status: "user_saved",
            memoryId: Int(record.id),
            scope: record.scope.wireName,
            kind: record.kind.wireName,
            contentPreview: IOSMemoryLibrary.preview(record.content)
        )
        persistence.refresh()
        recentlyArchivedRecord = archivedRecord
    }

    /// 恢复归档记录：与删除相同的陈旧检查，失败回滚并提示。
    private func restore(_ record: MemoryRecord) {
        guard persistence.records.contains(where: { $0.id == record.id }) else {
            operationError = "这条记忆已在其他地方删除，请重试。"
            persistence.refresh()
            return
        }
        let previousRecords = persistence.records
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard IosMemoryFactory.shared.restoreMemory(id: record.id, now: now) != nil else {
            operationError = "这条记忆已不在归档中，请重试。"
            persistence.refresh()
            return
        }
        guard persistence.persist(previousRecords: previousRecords) else {
            operationError = persistence.lastErrorMessage ?? "无法写入记忆。"
            return
        }
        IOSMemoryWriteAuditStore.shared.record(
            action: "restore",
            status: "user_saved",
            memoryId: Int(record.id),
            scope: record.scope.wireName,
            kind: record.kind.wireName,
            contentPreview: IOSMemoryLibrary.preview(record.content)
        )
        persistence.refresh()
        if recentlyArchivedRecord?.id == record.id {
            recentlyArchivedRecord = nil
        }
    }

    private func delete(_ record: MemoryRecord) {
        guard persistence.records.contains(where: { $0.id == record.id && $0.updatedAt == record.updatedAt }) else {
            operationError = "这条记忆已在其他地方更新或删除，请重试。"
            persistence.refresh()
            return
        }
        let previousRecords = persistence.records
        IosMemoryFactory.shared.deleteMemory(id: record.id)
        guard persistence.persist(previousRecords: previousRecords) else {
            operationError = persistence.lastErrorMessage ?? "无法写入记忆。"
            return
        }
        IOSMemoryWriteAuditStore.shared.record(
            action: "delete",
            status: "user_deleted",
            memoryId: Int(record.id),
            scope: record.scope.wireName,
            kind: record.kind.wireName,
            contentPreview: IOSMemoryLibrary.preview(record.content)
        )
        persistence.refresh()
        if recentlyArchivedRecord?.id == record.id {
            recentlyArchivedRecord = nil
        }
    }
}

struct MemoryRecordRow: View {
    let record: MemoryRecord
    /// Live topic members (archived ones excluded); ignored for non-topic rows.
    let memberCount: Int
    var conversationTitles: [String: String] = [:]
    let onEdit: () -> Void
    var onArchive: (() -> Void)? = nil
    let onDelete: () -> Void
    let onRestore: () -> Void

    private var isTopic: Bool { record.kind == .topic }

    private var primaryTypeText: String {
        IOSMemoryLibrary.primaryTypeTitle(for: record)
    }

    private var primaryTypeTint: Color {
        switch primaryTypeText {
        case "核心": AmberTheme.accent
        case "长期": AmberTheme.accentGreen
        case "短期": AmberTheme.accentAmber
        case "话题": AmberTheme.accent
        case "经验": AmberTheme.accentAmber
        default: AmberTheme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                // 主类型徽标（核心 / 长期 / 短期 / 话题 / 经验）
                MemoryTag(text: primaryTypeText, tint: primaryTypeTint)

                if let secondaryKind = IOSMemoryLibrary.secondaryKindTitle(for: record) {
                    MemoryTag(text: secondaryKind)
                }
                if isTopic, memberCount > 0 {
                    MemoryTag(text: "含 \(memberCount) 条", tint: AmberTheme.accent)
                }
                if record.pinned {
                    MemoryTag(text: "置顶", tint: AmberTheme.accentAmber)
                }
                if record.archived {
                    MemoryTag(text: "已归档")
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if record.archived {
                        Button(action: onRestore) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("恢复")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(AmberTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AmberTheme.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("恢复记忆")
                    } else {
                        if !isTopic {
                            Button(action: onEdit) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AmberTheme.accent)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("编辑记忆")
                        }

                        if let onArchive, !isTopic {
                            Button(action: onArchive) {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AmberTheme.foreground2)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("归档记忆")
                        }
                    }

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AmberTheme.accentRed)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除记忆")
                }
            }

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 6) {
                    if isTopic {
                        Text(record.topicTitle ?? record.content)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(2)
                        if record.topicTitle != nil, !record.content.isEmpty {
                            Text(record.content)
                                .font(.subheadline)
                                .foregroundStyle(AmberTheme.foreground2)
                                .lineLimit(3)
                        }
                    } else {
                        Text(record.content)
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }

                    let lastUsed = IOSMemoryLibrary.lastUsedDisplay(for: record)
                    HStack(spacing: 8) {
                        Label(
                            IOSMemoryLibrary.sourceDisplay(for: record, conversationTitles: conversationTitles),
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .lineLimit(1)

                        Text("·")
                            .foregroundStyle(AmberTheme.muted2)

                        Label(
                            lastUsed.text,
                            systemImage: lastUsed.hasBeenUsed ? "clock.arrow.circlepath" : "clock"
                        )
                        .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(record.archived && !isTopic)
            .accessibilityLabel(isTopic ? "查看主题" : "编辑记忆")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct MemoryTag: View {
    let text: String
    var tint: Color = AmberTheme.muted

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct MemoryScopeFilterChip: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? AmberTheme.accentInk : AmberTheme.foreground2)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                isSelected ? AmberTheme.accent : AmberTheme.surface,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? AmberTheme.accent.opacity(0.16) : AmberTheme.borderSoft,
                        lineWidth: 0.5
                    )
            }
    }
}

struct MemoryEmptyState: View {
    let isSearching: Bool
    /// 已归档筛选下的空状态：说明归档的来源与可恢复性。
    var archived = false

    private var title: String {
        if isSearching { return "没有匹配结果" }
        return archived ? "没有已归档的记忆" : "暂无记忆"
    }

    private var message: String {
        if isSearching { return "换个关键词或范围再试。" }
        return archived
            ? "被更新取代、被你否定、过期或久未使用的记忆会归档在这里，可随时恢复。"
            : "点右上角新增，或在聊天中批准模型写入。"
    }

    private var systemImage: String {
        if isSearching { return "magnifyingglass" }
        return archived ? "archivebox" : "tray"
    }

    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AmberTheme.surface2.opacity(0.82))
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(AmberTheme.muted2)
                    .accessibilityHidden(true)
            }
            .frame(width: 58, height: 58)

            VStack(spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
    }
}

struct MemoryDivider: View {
    var leading: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(AmberTheme.borderSoft.opacity(0.82))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}
