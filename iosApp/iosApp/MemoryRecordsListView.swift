import SwiftUI
@preconcurrency import Shared

/// 全部记忆记录的管理页：主页面只放聚合后的 Markdown 文档，单条记录的
/// 搜索、筛选、查看、编辑、删除集中在这里。
struct MemoryRecordsListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router

    @State private var persistence = IOSMemoryPersistence.shared
    @State private var query = ""
    @State private var scopeFilter: IOSMemoryScopeFilter = .all
    @State private var pendingDeleteRecord: MemoryRecord?
    @State private var operationError: String?

    private var filteredRecords: [MemoryRecord] {
        IOSMemoryLibrary.filteredRecords(records: persistence.records, query: query, scopeFilter: scopeFilter)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    chrome
                    libraryToolbar

                    if filteredRecords.isEmpty {
                        AmberFormGroup {
                            MemoryEmptyState(isSearching: !persistence.records.isEmpty)
                        }
                    } else {
                        AmberFormGroup {
                            ForEach(Array(filteredRecords.enumerated()), id: \.element.id) { index, record in
                                MemoryRecordRow(
                                    record: record,
                                    onEdit: {
                                        router.navigate(to: .memoryEdit(
                                            recordId: Int(record.id),
                                            text: record.content,
                                            scope: IOSMemoryLibrary.scopeTitle(record.scope),
                                            pinned: record.pinned
                                        ))
                                    },
                                    onDelete: {
                                        pendingDeleteRecord = record
                                    }
                                )

                                if index < filteredRecords.count - 1 {
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
            Text("删除后不可恢复。")
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
                Text("\(persistence.records.filter { !$0.archived }.count) 条本地记忆")
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

    /// 记忆库工具条：搜索 + 四枚范围过滤（等分铺开，不做横滑簇拥）。
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
    }
}

struct MemoryRecordRow: View {
    let record: MemoryRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isTopic: Bool { record.kind == .topic }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if isTopic {
                    // 主题记录由整理流程维护：点按进入只读详情，不提供编辑入口。
                    Button(action: onEdit) {
                        VStack(alignment: .leading, spacing: 5) {
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
                            Text("由记忆整理自动维护")
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看主题")
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.content)
                            .font(.body)
                            .foregroundStyle(AmberTheme.foreground)
                            .lineLimit(4)
                        Text(IOSMemoryLibrary.sourceSummary(record))
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    if !isTopic {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AmberTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("编辑记忆")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AmberTheme.accentRed)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除记忆")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
            }

            HStack(spacing: 6) {
                // 不对用户暴露内部 id / 召回候选等控制台语义。
                MemoryTag(text: IOSMemoryLibrary.scopeTitle(record.scope))
                MemoryTag(text: IOSMemoryLibrary.kindTitle(record.kind))
                if isTopic, !record.memberIds.isEmpty {
                    MemoryTag(text: "含 \(record.memberIds.count) 条", tint: AmberTheme.accent)
                }
                if record.pinned {
                    MemoryTag(text: "置顶", tint: AmberTheme.accentAmber)
                }
                Spacer(minLength: 0)
            }
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

    private var title: String {
        isSearching ? "没有匹配结果" : "暂无记忆"
    }

    private var message: String {
        isSearching ? "换个关键词或范围再试。" : "点右上角新增，或在聊天中批准模型写入。"
    }

    private var systemImage: String {
        isSearching ? "magnifyingglass" : "tray"
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
