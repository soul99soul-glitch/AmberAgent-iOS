import SwiftUI
import Shared

/// 「记忆」栏：直接复用既有本地记忆库（`IOSMemoryPersistence` + `IosMemoryFactory`），
/// 不另造孤立表。这里只做只读浏览 + 单条增删，语义与既有记忆页一致。
struct AgentSoulMemorySection: View {
    @State private var persistence = IOSMemoryPersistence.shared
    @State private var isAdding = false
    @State private var draft = ""
    @State private var errorText: String?

    private var records: [MemoryRecord] {
        persistence.records
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(IOSAppLocalization.formatted(
                    "已记住 %ld 条",
                    defaultValue: "已记住 %ld 条",
                    arguments: [records.count]
                ))
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
                Spacer()
                Button {
                    draft = ""
                    isAdding = true
                } label: {
                    Label(IOSAppLocalization.string("新增", defaultValue: "新增"), systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AmberTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.memory.add")
            }
            .padding(.horizontal, 2)

            if records.isEmpty {
                emptyState
            } else {
                ForEach(records, id: \.id) { record in
                    memoryRow(record)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.accentRed)
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
                .foregroundStyle(AmberTheme.muted2)
            Text(IOSAppLocalization.string(
                "还没有记住任何事。聊过的事我会自己记下来，也可以手动加一条。",
                defaultValue: "还没有记住任何事。聊过的事我会自己记下来，也可以手动加一条。"
            ))
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private func memoryRow(_ record: MemoryRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.content)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.scope.wireName)
                    .font(.caption2)
                    .foregroundStyle(AmberTheme.muted2)
            }
            Spacer(minLength: 4)
            Button {
                delete(record)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(AmberTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("embodiment.memory.delete")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
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
        let previous = persistence.records
        IosMemoryFactory.shared.deleteMemory(id: record.id)
        if !persistence.persist(previousRecords: previous) {
            errorText = persistence.lastErrorMessage ?? "删除失败，请重试。"
        } else {
            errorText = nil
        }
    }
}
