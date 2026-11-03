import SwiftUI
import Shared

/// 「记忆」栏：直接复用既有本地记忆库（`IOSMemoryPersistence` + `IosMemoryFactory`），
/// 对齐 `ios-agent-embodiment-v1` 屏 2 视觉规范：
/// - 顶栏左「已记住的偏好与背景 · N 条」+ 右「+ 记一条」描边胶囊
/// - 记忆卡片含分类微签、日期微标、右上省略号菜单、干净正文与左滑露出红色「删除」
struct AgentSoulMemorySection: View {
    @State private var persistence = IOSMemoryPersistence.shared
    @State private var isAdding = false
    @State private var draft = ""
    @State private var errorText: String?
    @State private var swipedRecordId: Int32?

    private var records: [MemoryRecord] {
        persistence.records.filter { !$0.archived && $0.kind != .topic }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已记住的偏好与背景 · \(records.count) 条")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.inkSecondary)

                Spacer()

                Button {
                    draft = ""
                    isAdding = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text(IOSAppLocalization.string("记一条", defaultValue: "记一条"))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(AgentEmbodimentPalette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(AgentEmbodimentPalette.accentBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.memory.add")
            }
            .padding(.horizontal, 2)

            if records.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(records, id: \.id) { record in
                        MemorySwipeItemCard(
                            record: record,
                            isSwipedOpen: swipedRecordId == record.id,
                            onSetSwiped: { isOpen in
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                    swipedRecordId = isOpen ? record.id : nil
                                }
                            },
                            onDelete: {
                                delete(record)
                            }
                        )
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 11))
                    Text("左滑任意条目可快速删除，或在主对话直接吩咐\(AgentSoulStore.shared.displayName)记住新习惯")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(AgentEmbodimentPalette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                Form {
                    Section(IOSAppLocalization.string("记一条", defaultValue: "记一条")) {
                        TextEditor(text: $draft)
                            .frame(minHeight: 140)
                            .accessibilityIdentifier("embodiment.memory.draft")
                    }
                }
                .navigationTitle(IOSAppLocalization.string("新增记忆", defaultValue: "新增记忆"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(IOSAppLocalization.string("取消", defaultValue: "取消")) { isAdding = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IOSAppLocalization.string("保存", defaultValue: "保存")) {
                            addMemory()
                            isAdding = false
                        }
                        .fontWeight(.semibold)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 22))
                .foregroundStyle(AgentEmbodimentPalette.inkMuted)
            Text(IOSAppLocalization.string(
                "还没有记住任何事。聊过的事我会自己记下来，也可以点右上角「+ 记一条」。",
                defaultValue: "还没有记住任何事。聊过的事我会自己记下来，也可以点右上角「+ 记一条」。"
            ))
            .font(.system(size: 13))
            .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AgentEmbodimentPalette.cardBg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }

    private func addMemory() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let previous = persistence.records
        _ = IosMemoryFactory.shared.addDetailedMemory(
            scope: MemoryScope.core,
            kind: MemoryKind.note,
            content: text,
            assistantId: "core",
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1,
            pinned: false,
            archived: false
        )
        if !persistence.persist(previousRecords: previous) {
            errorText = persistence.lastErrorMessage ?? "保存失败，请重试。"
        } else {
            errorText = nil
        }
    }

    private func delete(_ record: MemoryRecord) {
        if swipedRecordId == record.id {
            swipedRecordId = nil
        }
        let previous = persistence.records
        IosMemoryFactory.shared.deleteMemory(id: record.id)
        if !persistence.persist(previousRecords: previous) {
            errorText = persistence.lastErrorMessage ?? "删除失败，请重试。"
        } else {
            errorText = nil
        }
    }
}

// MARK: - 单条记忆卡片（支持左滑露出红色「删除」与右上菜单删除）

private struct MemorySwipeItemCard: View {
    let record: MemoryRecord
    let isSwipedOpen: Bool
    let onSetSwiped: (Bool) -> Void
    let onDelete: () -> Void

    @State private var dragTranslationX: CGFloat = 0

    private static let deleteActionWidth: CGFloat = 68

    private var categoryInfo: (title: String, isAccent: Bool) {
        switch record.kind.wireName {
        case "project":
            return ("近期项目", true)
        case "routine", "user", "feedback":
            return ("偏好习惯", false)
        case "reference":
            return ("参考资料", false)
        default:
            if record.scope == .core {
                return ("偏好习惯", false)
            }
            return ("近期项目", true)
        }
    }

    private var timeLabel: String {
        let timestampMs = record.updatedAt > 0 ? record.updatedAt : record.createdAt
        guard timestampMs > 0 else { return "近期" }
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
        return AgentEmbodimentHomeSheet.shortDate(date)
    }

    private var effectiveTrailingInset: CGFloat {
        let base: CGFloat = isSwipedOpen ? Self.deleteActionWidth : 0
        let combined = base - dragTranslationX
        return min(max(0, combined), Self.deleteActionWidth + 14)
    }

    var body: some View {
        let category = categoryInfo
        let revealDelete = isSwipedOpen || dragTranslationX < -6

        ZStack(alignment: .trailing) {
            if revealDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        VStack(spacing: 3) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(IOSAppLocalization.string("删除", defaultValue: "删除"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 64)
                    }
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AgentEmbodimentPalette.danger)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.memory.swipeDelete")
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(category.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            category.isAccent
                                ? AgentEmbodimentPalette.accent
                                : AgentEmbodimentPalette.inkSecondary
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    category.isAccent
                                        ? AgentEmbodimentPalette.accentSoftBg
                                        : AgentEmbodimentPalette.cardElevated
                                )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    category.isAccent
                                        ? Color.clear
                                        : AgentEmbodimentPalette.hairline,
                                    lineWidth: 1
                                )
                        }

                    Text(timeLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AgentEmbodimentPalette.inkMuted)

                    Spacer(minLength: 4)

                    Menu {
                        if isSwipedOpen {
                            Button(IOSAppLocalization.string("收起操作", defaultValue: "收起操作")) {
                                onSetSwiped(false)
                            }
                        } else {
                            Button(IOSAppLocalization.string("显示删除按钮", defaultValue: "显示删除按钮")) {
                                onSetSwiped(true)
                            }
                        }
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label(IOSAppLocalization.string("删除此条记忆", defaultValue: "删除此条记忆"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                            .frame(width: 24, height: 20, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("embodiment.memory.delete")
                }

                Text(record.content)
                    .font(.system(size: 13))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AgentEmbodimentPalette.cardBg)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
            }
            .padding(.trailing, effectiveTrailingInset)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                if isSwipedOpen {
                    onSetSwiped(false)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 18, coordinateSpace: .local)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.25 else {
                            return
                        }
                        dragTranslationX = value.translation.width
                    }
                    .onEnded { value in
                        defer { dragTranslationX = 0 }
                        guard abs(value.translation.width) > abs(value.translation.height) else {
                            return
                        }
                        if value.translation.width < -28 {
                            onSetSwiped(true)
                        } else if value.translation.width > 20 {
                            onSetSwiped(false)
                        }
                    }
            )
        }
    }
}
