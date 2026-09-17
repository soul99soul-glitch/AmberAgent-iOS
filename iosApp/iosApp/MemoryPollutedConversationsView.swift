import SwiftUI
@preconcurrency import Shared

/// 受外部内容影响的会话列表。这些会话曾成功调用联网搜索、网页抓取或 MCP
/// 工具（或写入过 provider 密钥），其记忆提炼资格已被暂停；逐个「恢复」
/// 或底部「全部恢复」可重置回启用。
struct MemoryPollutedConversationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IOSConversationStore.self) private var conversationStore

    /// nil = 尚未加载；避免进入时先闪现"没有受外部内容影响的会话"。
    @State private var pollutedConversations: [ConversationSummary]? = nil
    @State private var operationError: String?
    @State private var showRestoreAllConfirmation = false

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    chrome

                    Text("这些会话曾接触外部内容（联网搜索、网页抓取、MCP 输出），已暂停从它们提炼记忆。确认内容可信后逐个恢复，或一次全部恢复。")
                        .font(.callout)
                        .foregroundStyle(AmberTheme.foreground2)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                    if let list = pollutedConversations {
                        if list.isEmpty {
                            AmberFormGroup {
                                Text("没有受外部内容影响的会话。")
                                    .font(.subheadline)
                                    .foregroundStyle(AmberTheme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 14)
                            }
                        } else {
                            AmberFormGroup {
                                ForEach(Array(list.enumerated()), id: \.element.id) { index, summary in
                                    pollutedRow(summary)

                                    if index < list.count - 1 {
                                        MemoryDivider(leading: 52)
                                    }
                                }
                            }

                            Button {
                                showRestoreAllConfirmation = true
                            } label: {
                                Text("全部恢复")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(AmberTheme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: reload)
        .alert("无法保存", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好") { operationError = nil }
        } message: {
            Text(operationError ?? "未知错误")
        }
        .confirmationDialog(
            "恢复全部会话的记忆提炼？",
            isPresented: $showRestoreAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("全部恢复") { restoreAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复后将重新从这些会话提炼记忆。")
        }
    }

    private var chrome: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回记忆", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text("受外部内容影响的会话")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(pollutedConversations.map { "\($0.count) 个会话" } ?? "…")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func pollutedRow(_ summary: ConversationSummary) -> some View {
        let title = summary.title.isEmpty
            ? IOSAppLocalization.string("未命名会话", defaultValue: "未命名会话")
            : summary.title
        return HStack(spacing: 10) {
            Image(systemName: "globe")
                .accessibilityHidden(true)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AmberTheme.accentAmber)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(IOSAppLocalization.formatted(
                    "%@ 曾接触外部内容，已暂停记忆抽取",
                    defaultValue: "%@ 曾接触外部内容，已暂停记忆抽取",
                    arguments: [pollutedTime(summary.updateAt)]
                ))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("恢复") {
                restore(summary.id)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AmberTheme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(IOSAppLocalization.formatted(
                "恢复「%@」的记忆抽取",
                defaultValue: "恢复「%@」的记忆抽取",
                arguments: [title]
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func pollutedTime(_ updateAt: KotlinInstant) -> String {
        let seconds = TimeInterval(updateAt.toEpochMilliseconds()) / 1000.0
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = IOSAppLanguagePreference.selected().resolvedLocale()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: seconds), relativeTo: Date())
    }

    private func restore(_ id: KotlinUuid) {
        Task { @MainActor in
            if await conversationStore.resetConversationMemoryPollution(id) {
                reload()
            } else {
                operationError = "恢复失败，请重试。"
            }
        }
    }

    private func restoreAll() {
        let ids = pollutedConversations?.map(\.id) ?? []
        Task { @MainActor in
            var failed = false
            for id in ids {
                if await !conversationStore.resetConversationMemoryPollution(id) {
                    failed = true
                }
            }
            reload()
            if failed {
                operationError = "部分会话恢复失败，请重试。"
            }
        }
    }

    private func reload() {
        Task { @MainActor in
            pollutedConversations = await conversationStore.pollutedConversationSummaries()
        }
    }
}
