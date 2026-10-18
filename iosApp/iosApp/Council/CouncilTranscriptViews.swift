import SwiftUI
import SwiftStreamingMarkdown
import UIKit

struct CouncilTranscriptMessagesView: View {
    let viewModel: CouncilChatViewModel
    let onFirstMessageChanged: () -> Void

    var body: some View {
        // 用非 lazy 的 VStack:议会转录是有界的(轮数 1-5 × 席位数),一次性渲染可接受,
        // 也避免 LazyVStack 回收行导致的重解析/高度跳变。
        VStack(spacing: 12) {
            ForEach(viewModel.messages) { message in
                CouncilMessageRow(
                    message: message,
                    onTapDetail: { viewModel.showCurrentDetail() },
                    onRestart: { viewModel.restart(withObjective: $0) }
                )
                // Equatable:流式逐 token 改的是最后一条,只让那一行重渲染,
                // 其余已完成气泡不再随整个 messages 数组变化而重算 body。
                .equatable()
                .id(message.id)
            }

            // 永久存在的物理底锚。留白只改变自身高度,不会在消息切换时从旧行
            // 删除再插到新行；异步 Markdown 二次增高也始终以同一个内容尾部为目标。
            Color.clear
                .frame(height: viewModel.isRunning
                    ? ChatLayout.followBottomGap
                    : ChatLayout.bottomRestGap)
                .id(CouncilTranscriptFollowPolicy.bottomAnchorID)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: viewModel.messages.first?.id) { _, _ in
            onFirstMessageChanged()
        }
    }
}

private struct CouncilMessageRow: View, Equatable {
    let message: CouncilChatMessage
    let onTapDetail: () -> Void
    /// 以指定议题重开议会(供用户气泡的「以此为题重开 / 编辑重开」)。
    let onRestart: (String) -> Void

    @State private var editing = false
    @State private var editDraft = ""

    // 只比较影响渲染的字段(闭包每次父刷新都新建但语义不变,忽略)。内部 @State
    // (editing/editDraft)变化不受此 == 影响,SwiftUI 仍会照常更新本行。
    nonisolated static func == (lhs: CouncilMessageRow, rhs: CouncilMessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.body == rhs.message.body
            && lhs.message.status == rhs.message.status
            && lhs.message.author == rhs.message.author
            && lhs.message.subtitle == rhs.message.subtitle
    }

    var body: some View {
        content
            .sheet(isPresented: $editing) { editSheet }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .divider:
            Text(message.displayBody)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AmberTheme.surface, in: Capsule())
                .frame(maxWidth: .infinity)
        case .user:
            userRow
        case .host, .guest, .system:
            assistantRow
        }
    }

    // 用户消息复用 Chat 页样式:右对齐的 accent 气泡(ChatUserBubble),无头像、无「你」标签。
    private var userRow: some View {
        HStack {
            Spacer(minLength: 48)
            ChatUserBubble(text: message.body)
                // 长按高亮平台裁成气泡形状(与 Chat 页一致),消除灰角。
                .contentShape(.contextMenuPreview, ChatUserBubble.bubbleShape)
                .contextMenu { messageActions }
        }
    }

    // 长按菜单。复制 / 分享对两类气泡通用;「以此为题重开 / 编辑重开」仅用户气泡(议题)有。
    @ViewBuilder
    private var messageActions: some View {
        Button {
            UIPasteboard.general.string = message.body
        } label: {
            Label(IOSAppLocalization.string("复制", defaultValue: "复制"), systemImage: "doc.on.doc")
        }
        ShareLink(item: message.body) {
            Label(IOSAppLocalization.string("分享", defaultValue: "分享"), systemImage: "square.and.arrow.up")
        }
        if message.kind == .user {
            Divider()
            Button {
                onRestart(message.body)
            } label: {
                Label(
                    IOSAppLocalization.string("以此为题重开", defaultValue: "以此为题重开"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            Button {
                editDraft = message.body
                editing = true
            } label: {
                Label(
                    IOSAppLocalization.string("编辑重开", defaultValue: "编辑重开"),
                    systemImage: "square.and.pencil"
                )
            }
        }
    }

    // 编辑议题后重开:预填原文,提交即清空当前画面并用改写后的议题重跑。
    private var editSheet: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $editDraft)
                    .font(.body)
                    .padding(8)
                    .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(16)
            }
            .navigationTitle(IOSAppLocalization.string("编辑议题", defaultValue: "编辑议题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSAppLocalization.string("取消", defaultValue: "取消")) { editing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSAppLocalization.string("重开", defaultValue: "重开")) {
                        editing = false
                        onRestart(editDraft)
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // Agent 消息:头像 + 元信息在顶部一行,气泡落到下一行占满整行宽度
    // ——气泡左缘对齐头像左缘,右边距 = 左边距(整体复用滚动内容的 16pt 水平内边距,左右对称)。
    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                avatar
                metaLine
            }
            bubble
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(message.displayAuthor)
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.kind == .host ? AmberTheme.accent : AmberTheme.muted)
            if let subtitle = message.subtitle, !subtitle.isEmpty {
                Text(message.displaySubtitle ?? subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted2)
                    .lineLimit(1)
            }
        }
    }

    private var bubble: some View {
        // host/guest 都由 runner 的累计流式文本产生。稳定 namespace + 明确的 live/ever
        // 标记让 Council 与标准 Chat 共用同一套增量 Markdown、完成态 renderer latch 和缓存。
        Group {
            if let markdown = message.streamingMarkdownBody {
                ChatAssistantMarkdownView(
                    markdown: markdown,
                    renderCacheNamespace: message.markdownRenderCacheNamespace,
                    isStreaming: message.isStreamingMarkdown,
                    hasEverStreamed: message.hasEverStreamedMarkdown,
                    liveRenderingEnabled: CouncilTranscriptFollowPolicy.liveRenderingEnabled
                )
            } else {
                HStack(spacing: 8) {
                    Text(message.displayBody)
                    if message.status == .speaking {
                        TypingDots()
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(message.foregroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(message.borderColor, lineWidth: message.kind == .host ? 0.8 : 0.4)
            }
            // 长按高亮平台裁成气泡圆角形状,避免方角灰底。
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
            // 轻点看详情,长按出「复制」菜单(两者共存)。
            .onTapGesture(perform: onTapDetail)
            .contextMenu { messageActions }
    }

    private var avatar: some View {
        Image(systemName: message.systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(message.tint)
            .frame(width: 30, height: 30)
            .background(message.tint.opacity(0.13), in: Circle())
    }
}

