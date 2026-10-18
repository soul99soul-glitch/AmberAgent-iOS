import SwiftUI
import Shared
import SwiftStreamingMarkdown

struct ChatStreamingBlockMarkdownView: View {
    let text: String
    let config: SwiftStreamingMarkdown.MarkdownRenderConfig
    let liveStreaming: Bool
    let renderCacheNamespace: String?
    @StateObject private var controller: ChatStreamingMarkdownBlockController

    init(
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        liveStreaming: Bool,
        renderCacheNamespace: String? = nil
    ) {
        self.text = text
        self.config = config
        self.liveStreaming = liveStreaming
        self.renderCacheNamespace = renderCacheNamespace
        _controller = StateObject(wrappedValue: ChatStreamingMarkdownBlockController(
            text: text,
            includeTrailingPartialTableRow: !liveStreaming
        ))
    }

    var body: some View {
        // 结构性隔离:本层每个 delta 都因 `text` 变化重求值,但块列表子树
        // 只依赖 controller 的结构发布。已稳定块继续复用；普通文本尾块把可见
        // 节奏交给内部 Markdown controller，表格尾块仍在本层限频，避免每个
        // table token 都重建整张表。
        ChatStreamingMarkdownBlockListView(
            controller: controller,
            config: config,
            renderCacheNamespace: renderCacheNamespace
        )
            .task(id: ChatStreamingMarkdownBlockParseKey(
                text: text,
                includeTrailingPartialTableRow: !liveStreaming
            )) {
                controller.scheduleParse(
                    text: text,
                    includeTrailingPartialTableRow: !liveStreaming
                )
            }
    }
}

private struct ChatStreamingMarkdownBlockListView: View {
    @ObservedObject var controller: ChatStreamingMarkdownBlockController
    let config: SwiftStreamingMarkdown.MarkdownRenderConfig
    let renderCacheNamespace: String?

    var body: some View {
        VStack(alignment: .leading, spacing: config.blockSpacing) {
            ForEach(controller.blocks) { block in
                switch block.kind {
                case .text(let content):
                    ChatStableStreamingMarkdownView(
                        text: content,
                        config: config,
                        cacheIdentity: renderCacheNamespace.map { "\($0):\(block.id)" }
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let table):
                    // 用 vendor 的真实 Markdown 表格渲染，保留 inline 样式、链接与
                    // shouldAnimateText 淡入；块解析只负责隐藏尚未闭合的尾行。
                    ChatStableStreamingMarkdownView(
                        text: table.markdown,
                        config: config,
                        cacheIdentity: renderCacheNamespace.map { "\($0):\(block.id)" },
                        preservesRenderedTable: true
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ChatStreamingMarkdownBlockParseKey: Equatable {
    let text: String
    let includeTrailingPartialTableRow: Bool
}

@MainActor
final class ChatStreamingMarkdownBlockController: ObservableObject {
    @Published private(set) var blocks: [ChatStreamingMarkdownBlock]

    private var pendingParse: (text: String, includeTrailingPartialTableRow: Bool)?
    private var parseTask: Task<Void, Never>?
    private var lastPublishAt = Date.distantPast

    init(text: String, includeTrailingPartialTableRow: Bool) {
        blocks = ChatPerfTrace.measure("MarkdownBlockSplitInitial", count: { text.utf16.count }) {
            ChatStreamingMarkdownBlockParser.blocks(
                in: text,
                includeTrailingPartialTableRow: includeTrailingPartialTableRow
            )
        }
    }

    deinit {
        parseTask?.cancel()
    }

    /// 普通文本尾块不在这里重复限频:块控制器只负责结构拆分，实际 Markdown
    /// 解析已有 single-flight/latest-wins 背压。表格尾块仍保留低频发布，避免
    /// 每个表格 token 都让整张表进入布局；半截行由 block parser 隐藏。
    private func publishInterval(for text: String) -> TimeInterval {
        var isTableTail = false
        if let tail = blocks.last, case .table = tail.kind {
            isTableTail = true
        }
        return Self.publishInterval(utf16Length: text.utf16.count, isTableTail: isTableTail)
    }

    /// 表格尾块发布间隔：连续于表长（无分档）——小表贴近 0.09s，大表渐近
    /// 0.22s（0.09 + 0.13 × (1 − e^(−L/4000))）。锚点值与旧四档
    /// （0.09/0.12/0.16/0.22 @ 0/1.2k/4k/12k）偏差 <12ms，行为等价但无档位边界。
    static func publishInterval(utf16Length length: Int, isTableTail: Bool) -> TimeInterval {
        guard isTableTail else { return 0 }
        return 0.09 + 0.13 * (1 - exp(-Double(length) / 4_000))
    }

    func scheduleParse(text: String, includeTrailingPartialTableRow: Bool) {
        pendingParse = (text, includeTrailingPartialTableRow)
        guard parseTask == nil else { return }
        parseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { parseTask = nil }
            while !Task.isCancelled, let next = pendingParse {
                pendingParse = nil

                let elapsed = Date().timeIntervalSince(lastPublishAt)
                let interval = publishInterval(for: next.text)
                if elapsed < interval {
                    do {
                        try await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                }
                // 节流窗内若有更新的累计文本到达,直接解析最新值。
                let target = pendingParse ?? next
                pendingParse = nil

                let parsed = await Task.detached(priority: .userInitiated) {
                    ChatPerfTrace.measure("MarkdownBlockSplit", count: { target.text.utf16.count }) {
                        ChatStreamingMarkdownBlockParser.blocks(
                            in: target.text,
                            includeTrailingPartialTableRow: target.includeTrailingPartialTableRow
                        )
                    }
                }.value
                guard !Task.isCancelled else { return }
                // 解析串行消费累计全文，当前结果一定晚于上次已发布结果。即使
                // 解析期间又来了 delta，也先发布这次前缀再继续消费最新 pending；
                // 否则长内容解析慢于 chunk 间隔时会永久没有任何结果能发布。
                lastPublishAt = Date()
                publishPreservingSettledBlocks(parsed)
            }
        }
    }

    /// 前缀块冻结的核心:新解析结果与上一次逐块比较,内容未变的块**复用旧实例**
    /// (包括其中的 String 存储)。这样 ForEach 里已定块的子视图输入按位与上一帧
    /// 完全一致,SwiftUI 直接短路整棵子树;真正重新求值/布局的只有变化中的尾部块。
    /// 全部相等时不发布,避免无效的 objectWillChange。
    private func publishPreservingSettledBlocks(_ parsed: [ChatStreamingMarkdownBlock]) {
        var merged = parsed
        var changed = merged.count != blocks.count
        for index in merged.indices {
            if index < blocks.count, blocks[index] == merged[index] {
                merged[index] = blocks[index]
            } else {
                changed = true
            }
        }
        if changed {
            blocks = merged
        }
    }
}

struct ChatStreamingMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(String)
        case table(ChatStreamingMarkdownTable)
    }

    let id: String
    let kind: Kind
}

struct ChatStreamingMarkdownTable: Equatable, Sendable {
    let id: String
    let markdown: String
    let headers: [String]
    let rows: [[String]]
}

struct ChatStreamingMarkdownParsedTable: Sendable {
    let table: ChatStreamingMarkdownTable
    let consumedLineCount: Int
}

