import SwiftUI
import Shared
import SwiftStreamingMarkdown

enum ChatMarkdownOpenURLPolicy {
    /// 注入 `\.openURL` 的常量动作：每次 body 新建的 OpenURLAction 不可判等，
    /// 会让子树里所有链接文本随父视图重算而失效。
    @MainActor static let openURLAction = OpenURLAction { url in result(for: url) }

    static func url(from raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              isAllowed(url) else {
            return nil
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    static func result(for url: URL) -> OpenURLAction.Result {
        isAllowed(url) ? .systemAction : .discarded
    }
}
enum ChatMarkdownRendererSelection: Equatable {
    case block
    case stable
}

enum ChatMarkdownRendererPolicy {
    static func selection(
        blockRendererEnabled: Bool
    ) -> ChatMarkdownRendererSelection {
        if blockRendererEnabled {
            return .block
        }
        return .stable
    }
}

enum ChatDataImageLoadState: Sendable {
    case loading
    case success(UIImage)
    case failure

    static func resolve(urlString: String) async -> ChatDataImageLoadState {
        await Task.detached(priority: .userInitiated) {
            guard let comma = urlString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])),
                  let image = UIImage(data: data) else {
                return ChatDataImageLoadState.failure
            }
            return ChatDataImageLoadState.success(image)
        }.value
    }
}


/// 唯一的 assistant Markdown 渲染入口:聊天页与模型议会共用同一组件,
/// 跟随同一组 Markdown 渲染偏好。默认走 App 自有同步渲染器(吃字体/排版偏好),
/// 实验渲染器在这里互斥切换,避免两边各渲染各的、视觉不一致。
struct ChatAssistantMarkdownView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let markdown: String
    var renderCacheNamespace: String?
    var displaySetting: DisplaySetting?
    var generativeUiSetting: GenerativeUiSetting?
    var isStreaming = false
    var hasEverStreamed = false
    var liveRenderingEnabled = true
    var frozenMarkdownSnapshot: String?
    var onGenerativeWidgetAction: (String) -> Void = { _ in }

    // 渲染器选择已硬编码：block 渲染器无条件参与竞争，coalesced 合并默认开启。
    // 不再暴露 microsoft/liyanan/streamingBlock/coalesced 开关给用户。
    @AppStorage(IOSDisplayPreferenceKeys.fontScale) private var fontScale = 1.0
    @AppStorage(IOSDisplayPreferenceKeys.chatFont) private var chatFont = IOSChatFont.default.rawValue
    @ScaledMetric(relativeTo: .body) private var scaledBodyPointSize: CGFloat = 17
    /// per-view-instance 的「这个 bubble 用过 block 流式渲染」latch，覆盖 completion 瞬间；
    /// 回收后的完成态由 projection 层 hasEverStreamed + liveRenderingEnabled 驱动。
    @State private var hasUsedBlockMarkdownRenderer = false
    @State private var renderedMarkdownSnapshot = ""
    /// 表格/widget 探测器放在引用盒子里而不是 @State 值类型:探测器每个 chunk 都要
    /// 增量消费新字节,值类型 @State 的突变会让每个 delta 额外触发一轮 body 重求值,
    /// 与 signal 驱动的那轮叠加成倍放大热路径成本。body 只依赖下面两个显式 latch。
    @State private var detection: ChatStreamingDetectionBox
    /// body 读取的 widget 探测 latch(IOSGenerativeWidgetPayloadDetector 的增量结果)。
    /// 只在 false→true 翻转时写入一次,不随每个 chunk 失效。
    @State private var mayContainWidgetPayload: Bool

    init(
        markdown: String,
        renderCacheNamespace: String? = nil,
        displaySetting: DisplaySetting? = nil,
        generativeUiSetting: GenerativeUiSetting? = nil,
        isStreaming: Bool = false,
        hasEverStreamed: Bool = false,
        liveRenderingEnabled: Bool = true,
        frozenMarkdownSnapshot: String? = nil,
        onGenerativeWidgetAction: @escaping (String) -> Void = { _ in }
    ) {
        self.markdown = markdown
        self.renderCacheNamespace = renderCacheNamespace
        self.displaySetting = displaySetting
        self.generativeUiSetting = generativeUiSetting
        self.isStreaming = isStreaming
        self.hasEverStreamed = hasEverStreamed
        self.liveRenderingEnabled = liveRenderingEnabled
        self.frozenMarkdownSnapshot = frozenMarkdownSnapshot
        self.onGenerativeWidgetAction = onGenerativeWidgetAction
        // 流式尾行的 view struct 每个 delta 重建,State(initialValue:) 首帧之后
        // 全部被丢弃——eager 种子扫描曾按"微秒级"评估保留,采样实测占主线程
        // ~6.6%(24KB×逐字节×每 delta×两次 body eval),证伪。改为:只有
        // 非流式行(历史行,首帧结果必须就位且不会每 delta 重建)做 eager 扫描;
        // 流式行从空状态起步,由 onAppear/onChange 的持久盒增量补齐——
        // 代价仅是"流式中途重进入"首帧探测未就位(下一帧补齐)。
        if isStreaming {
            let detection = ChatStreamingDetectionBox(markdown: "")
            _detection = State(initialValue: detection)
            _mayContainWidgetPayload = State(initialValue: false)
            _hasUsedBlockMarkdownRenderer = State(initialValue:
                ChatStreamingMarkdownRendererPolicy.initialBlockRendererLatch(
                    isStreaming: isStreaming,
                    hasEverStreamed: hasEverStreamed,
                    liveRenderingEnabled: liveRenderingEnabled
                )
            )
        } else {
            let detection = ChatStreamingDetectionBox(markdown: markdown)
            _detection = State(initialValue: detection)
            _mayContainWidgetPayload = State(initialValue: detection.widget.mayContainPayload)
            _hasUsedBlockMarkdownRenderer = State(initialValue:
                ChatStreamingMarkdownRendererPolicy.initialBlockRendererLatch(
                    isStreaming: isStreaming,
                    hasEverStreamed: hasEverStreamed,
                    liveRenderingEnabled: liveRenderingEnabled
                )
            )
        }
    }

    var body: some View {
        let widgetSettings = IOSGenerativeWidgetSettings(generativeUiSetting)
        let renderedMarkdown = renderedMarkdownText
        let liveStreaming = isStreaming && liveRenderingEnabled
        Group {
            // 探测走增量 latch(mayContainWidgetPayload @State),不再每次 body 求值
            // 对全文做 13+ 次 caseInsensitive 扫描(32KB 实测 46ms/次,是长内容
            // 流式掉帧的头号单项)。latch 基于完整 markdown,对 frozen snapshot
            // 只可能过检不可能欠检;过检时 parse 找不到 widget 段仍走纯文本分支。
            if widgetSettings.enabled && mayContainWidgetPayload {
                let segments = IOSGenerativeWidgetParser.parse(renderedMarkdown, streaming: liveStreaming)
                let hasWidgetSegment = segments.contains { segment in
                    switch segment {
                    case .widget, .loading:
                        return true
                    case .text:
                        return false
                    }
                }
                if hasWidgetSegment {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(segments) { segment in
                            switch segment {
                            case .text(let id, let content):
                                markdownText(
                                    content,
                                    liveStreaming: liveStreaming,
                                    cacheIdentitySuffix: "widget:\(id)"
                                )
                            case .widget(let widget):
                                IOSGenerativeWidgetCard(
                                    widget: widget,
                                    generativeUiSetting: generativeUiSetting,
                                    onAction: onGenerativeWidgetAction
                                )
                            case .loading:
                                IOSGenerativeWidgetLoadingView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    markdownText(renderedMarkdown, liveStreaming: liveStreaming)
                }
            } else {
                markdownText(renderedMarkdown, liveStreaming: liveStreaming)
            }
        }
        .onAppear {
            if renderedMarkdownSnapshot.isEmpty {
                renderedMarkdownSnapshot = markdown
            }
            updateWidgetPayloadLatch(with: markdown)
            if isStreaming && liveRenderingEnabled {
                updateTableRendererLatch(with: renderedMarkdown)
            }
        }
        .onChange(of: markdown) { _, newValue in
            updateWidgetPayloadLatch(with: newValue)
            if isStreaming,
               liveRenderingEnabled,
               !hasUsedBlockMarkdownRenderer {
                updateTableRendererLatch(with: newValue)
            }
        }
        .onChange(of: isStreaming) { _, newValue in
            if newValue && liveRenderingEnabled {
                renderedMarkdownSnapshot = markdown
                if !hasUsedBlockMarkdownRenderer {
                    updateTableRendererLatch(with: markdown)
                }
            } else if !newValue {
                renderedMarkdownSnapshot = markdown
                // Completion may replace the cumulative stream with one final full
                // message. Reconcile once here instead of validating the whole prefix
                // on every append-only chunk.
                reconcileFinalWidgetPayloadLatch(with: markdown)
            }
        }
        .onChange(of: liveRenderingEnabled) { _, newValue in
            // Capture once at the live/frozen boundary. Mirroring every live delta
            // into @State only schedules a duplicate body update.
            renderedMarkdownSnapshot = markdown
            if ChatStreamingMarkdownRendererPolicy.initialBlockRendererLatch(
                isStreaming: isStreaming,
                hasEverStreamed: hasEverStreamed,
                liveRenderingEnabled: newValue
            ) {
                hasUsedBlockMarkdownRenderer = true
            }
            if newValue && isStreaming {
                if !hasUsedBlockMarkdownRenderer {
                    updateTableRendererLatch(with: markdown)
                }
            }
        }
        .environment(\.openURL, ChatMarkdownOpenURLPolicy.openURLAction)
    }

    private var renderedMarkdownText: String {
        if !liveRenderingEnabled, let frozenMarkdownSnapshot, !frozenMarkdownSnapshot.isEmpty {
            return frozenMarkdownSnapshot
        }
        if isStreaming && !liveRenderingEnabled && !renderedMarkdownSnapshot.isEmpty {
            return renderedMarkdownSnapshot
        }
        return markdown
    }

    private func shouldUseBlockStreamingRenderer(liveStreaming: Bool) -> Bool {
        // 流式从首帧一律走同一块路径，表格前后的稳定块可以冻结复用；绝不允许
        // 中途从单文档切到块路径，否则 vendor ParagraphView 重建会让已上屏内容
        // 整段重淡入。latch 保证完成瞬间保持 renderer 连续；表格探测仍兜底
        // 回收后历史行的入场判定。
        return liveStreaming || hasUsedBlockMarkdownRenderer ||
            (hasEverStreamed && liveRenderingEnabled)
    }

    private func updateTableRendererLatch(with text: String) {
        if isStreaming, liveRenderingEnabled {
            hasUsedBlockMarkdownRenderer = true
        }
        detection.table.update(with: text)
        if detection.table.containsTable {
            hasUsedBlockMarkdownRenderer = true
        }
    }

    private func updateWidgetPayloadLatch(with text: String) {
        guard !mayContainWidgetPayload else { return }
        detection.widget.update(with: text)
        if detection.widget.mayContainPayload {
            mayContainWidgetPayload = true
        }
    }

    private func reconcileFinalWidgetPayloadLatch(with text: String) {
        guard !mayContainWidgetPayload else { return }
        detection.widget.reconcileFinalText(text)
        if detection.widget.mayContainPayload {
            mayContainWidgetPayload = true
        }
    }

    /// 流式渲染器(SwiftStreamingMarkdown)排版参数单侧对齐紧凑基准 AmberMarkdownView,
    /// 全部取设计原值:字体 17×scale、行距 4×scale(与 ChatAssistantText wrapper 同源,
    /// 见 ChatMessageListSupport.swift:112-136)、块间距 8pt(MarkdownView.swift:173)、
    /// 列表项间距 4pt(MarkdownView.swift:413/424)、表格 cell padding 水平 12/垂直 8、
    /// 表格正文 17pt(MarkdownView.swift:368-371)。heading 行距同样传 4×scale——
    /// 紧凑基准的标题(SwiftUI Text)吃 wrapper 的 .lineSpacing environment。
    /// collapsesSoftBreaks 对齐紧凑基准的 CommonMark softBreak 语义(段内单换行折叠
    /// 为空格、CJK 间折叠为空,而非硬换行)——这是行数级差异,不折叠则每个 softBreak
    /// 多出一行。
    /// 只调排版度量,不碰渲染管线——渐进渲染/逐词淡入只在真正 liveStreaming 时开启。
    /// 完成态的 view 实例可以继续使用 SwiftStreamingMarkdown 保持 renderer 连续性,但必须
    /// 退出文字动画路径,避免 UIKit 段落视图在完成/回收阶段继续走动态文字更新和尺寸缓存。
    private var boundedFontScale: Double {
        min(max(fontScale, 0.88), 1.25)
    }

    private func streamingMarkdownConfig(liveStreaming: Bool) -> SwiftStreamingMarkdown.MarkdownRenderConfig {
        let scale = boundedFontScale
        let foreground = UIColor(AmberTheme.foreground)
        let foreground2 = UIColor(AmberTheme.foreground2)
        let muted = UIColor(AmberTheme.muted)
        let surface2 = UIColor(AmberTheme.surface2)
        let border = UIColor(AmberTheme.border)
        let accent = UIColor(AmberTheme.accent)
        let bodyFonts = ChatStreamingMarkdownTypography.bodyFonts(
            chatFont: IOSChatFont(rawValue: chatFont) ?? .default,
            pointSize: scaledBodyPointSize * scale
        )
        let headingFonts = ChatStreamingMarkdownTypography.applyingChatFont(
            IOSChatFont(rawValue: chatFont) ?? .default,
            to: SwiftStreamingMarkdown.MarkdownRenderConfig.defaultHeadingStyle
        )
        let paragraphStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: bodyFonts,
            textColor: foreground
        )
        let blockQuoteStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: bodyFonts,
            textColor: muted
        )
        let orderedListStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownTextStyle(
            textFonts: bodyFonts,
            textColor: foreground
        )
        let headingStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: headingFonts.h1Font,
            h2Font: headingFonts.h2Font,
            h3Font: headingFonts.h3Font,
            h4Font: headingFonts.h4Font,
            h5Font: headingFonts.h5Font,
            h6Font: headingFonts.h6Font,
            textColor: foreground
        )
        let tableStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownTableTextStyle(
            textFonts: bodyFonts,
            headerTextColor: foreground,
            regularTextColor: foreground,
            headerBackgroundColor: surface2,
            borderColor: border,
            actionButtonColor: accent
        )
        let inlineStyle = SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownInlineTextStyle(
            boldTextColor: foreground,
            linkTextFont: bodyFonts.normal,
            linkTextColor: accent,
            codeTextFont: SwiftStreamingMarkdown.MarkdownRenderConfig.defaultInlineStyle.codeTextFont,
            codeTextColor: foreground2,
            codeBackgroundColor: surface2,
            codeUnderlineColor: border
        )
        // Reduce Motion 下流式淡入全关（与思考框 animatesStreamingBody 同语义）。
        let animates = liveStreaming && !reduceMotion
        return SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: animates)
            // 逐拍尾段整体淡入 + 解除 window 门控：修「开头看不到淡入、一拍一跳」
            // 与逐词淡入的 display-link 主线程开销（vendor 默认值不变）。
            .withAnimatesAppendedTailAsUnit(value: animates)
            .withBlockQuoteStyle(value: blockQuoteStyle)
            .withHeadingStyle(value: headingStyle)
            .withOrderedListStyle(value: orderedListStyle)
            .withParagraphStyle(value: paragraphStyle)
            .withTableStyle(value: tableStyle)
            .withInlineStyle(value: inlineStyle)
            .withParagraphLineSpacing(value: 4 * scale)
            .withHeadingLineSpacing(value: 4 * scale)
            .withBlockSpacing(value: 8)
            .withListItemSpacing(value: 4)
            .withTableCellHorizontalPadding(value: 12)
            .withTableCellVerticalPadding(value: 8)
            .withTableMaxColumnWidth(value: 300)
            // 紧凑基准无序列表的内容缩进 = Text("•") 宽(~7pt)+ spacing 8 ≈ 15pt;
            // vendor 内容缩进 = bulletWidth + spacing 1,故 bulletWidth 取 15 对齐,
            // 消除因内容可用宽度不同导致的折行行数差。
            .withUnorderedListBulletWidth(value: 15)
            .withCollapsesSoftBreaks(value: true)
            // 相邻纯正文段落合并成一个文本视图：长回复的 ParagraphUIView 数量从
            // 「段落数」降到 1,每次流式提交不再走 O(段落数) 的 SwiftUI 子树 diff,
            // 新段落也不再是「新建视图 + 从 alpha 0 淡入」。合并块内的增长仍走
            // ParagraphUIView 的 append 快路径(行距/段距烘进属性串,视图侧传 nil)。
            // 这里是三个界面(Chat/议会/小说)共用的唯一 config 构造点。
            .withCoalescesAdjacentTextBlocks(value: true)
    }

    @ViewBuilder
    private func markdownText(
        _ content: String,
        liveStreaming: Bool,
        cacheIdentitySuffix: String = "document"
    ) -> some View {
        let config = detection.markdownConfig(
            for: ChatStreamingDetectionBox.MarkdownConfigKey(
                liveStreaming: liveStreaming,
                reduceMotion: reduceMotion,
                fontScale: boundedFontScale,
                bodyPointSize: scaledBodyPointSize,
                chatFont: chatFont,
                themePaper: AmberThemeRuntime.shared.paper.rawValue,
                themeAccentHex: AmberThemeRuntime.shared.accentHex,
                coalescedTextBlocks: true
            ),
            build: { streamingMarkdownConfig(liveStreaming: liveStreaming) }
        )
        switch ChatMarkdownRendererPolicy.selection(
            blockRendererEnabled: shouldUseBlockStreamingRenderer(liveStreaming: liveStreaming)
        ) {
        case .block:
            ChatStreamingBlockMarkdownView(
                text: content,
                config: config,
                liveStreaming: liveStreaming,
                renderCacheNamespace: renderCacheNamespace.map { "\($0):\(cacheIdentitySuffix)" }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .stable:
            AmberMarkdownView(markdown: content, displaySetting: displaySetting)
        }
    }
}

enum ChatStreamingMarkdownRendererPolicy {
    static func initialBlockRendererLatch(
        isStreaming: Bool,
        hasEverStreamed: Bool,
        liveRenderingEnabled: Bool
    ) -> Bool {
        (isStreaming || hasEverStreamed) && liveRenderingEnabled
    }
}

private enum ChatStreamingMarkdownTypography {
    static func bodyFonts(chatFont: IOSChatFont, pointSize: CGFloat) -> SwiftStreamingMarkdown.TextFonts {
        let regular = UIFont.systemFont(ofSize: pointSize, weight: .regular)
        let semibold = UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        return SwiftStreamingMarkdown.TextFonts(
            normal: applyingChatFont(chatFont, to: regular),
            italic: applyingChatFont(chatFont, to: regular.withItalicTrait()),
            bold: applyingChatFont(chatFont, to: semibold),
            boldItalic: applyingChatFont(chatFont, to: semibold.withItalicTrait()),
            preferredLetterSpacing: 0,
            preferredLineHeight: nil
        )
    }

    static func applyingChatFont(
        _ chatFont: IOSChatFont,
        to style: SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle
    ) -> SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle {
        SwiftStreamingMarkdown.MarkdownRenderConfig.MarkdownHeadingTextStyle(
            h1Font: applyingChatFont(chatFont, to: style.h1Font),
            h2Font: applyingChatFont(chatFont, to: style.h2Font),
            h3Font: applyingChatFont(chatFont, to: style.h3Font),
            h4Font: applyingChatFont(chatFont, to: style.h4Font),
            h5Font: applyingChatFont(chatFont, to: style.h5Font),
            h6Font: applyingChatFont(chatFont, to: style.h6Font),
            textColor: style.textColor
        )
    }

    private static func applyingChatFont(
        _ chatFont: IOSChatFont,
        to fonts: SwiftStreamingMarkdown.TextFonts
    ) -> SwiftStreamingMarkdown.TextFonts {
        SwiftStreamingMarkdown.TextFonts(
            normal: applyingChatFont(chatFont, to: fonts.normal),
            italic: fonts.italic.map { applyingChatFont(chatFont, to: $0) },
            bold: fonts.bold.map { applyingChatFont(chatFont, to: $0) },
            boldItalic: fonts.boldItalic.map { applyingChatFont(chatFont, to: $0) },
            preferredLetterSpacing: fonts.preferredLetterSpacing,
            preferredLineHeight: fonts.preferredLineHeight
        )
    }

    private static func applyingChatFont(_ chatFont: IOSChatFont, to font: UIFont) -> UIFont {
        chatFont.applying(to: font)
    }
}

#if DEBUG
enum ChatStreamingMarkdownTypographyTestSupport {
    static func bodyFontName(chatFont: IOSChatFont) -> String {
        bodyFonts(chatFont: chatFont).normal.fontName
    }

    static func bodyFonts(chatFont: IOSChatFont) -> SwiftStreamingMarkdown.TextFonts {
        ChatStreamingMarkdownTypography.bodyFonts(chatFont: chatFont, pointSize: 17)
    }
}
#endif

private struct ChatStreamingBlockMarkdownView: View {
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
private final class ChatStreamingMarkdownBlockController: ObservableObject {
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

private struct ChatStreamingMarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(String)
        case table(ChatStreamingMarkdownTable)
    }

    let id: String
    let kind: Kind
}

private struct ChatStreamingMarkdownTable: Equatable, Sendable {
    let id: String
    let markdown: String
    let headers: [String]
    let rows: [[String]]
}

private struct ChatStreamingMarkdownParsedTable: Sendable {
    let table: ChatStreamingMarkdownTable
    let consumedLineCount: Int
}

private enum ChatStreamingMarkdownBlockParser {
    static func containsTable(in text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }
        var activeFenceMarker: Character?

        for index in 0..<(lines.count - 1) {
            let line = lines[index]
            if let marker = fenceMarker(in: line) {
                if activeFenceMarker == nil {
                    activeFenceMarker = marker
                } else if activeFenceMarker == marker {
                    activeFenceMarker = nil
                }
                continue
            }
            guard activeFenceMarker == nil else { continue }
            let headers = splitTableCells(line)
            if headers.count >= 2,
               isDelimiterLine(lines[index + 1], expectedCount: headers.count) {
                return true
            }
        }
        return false
    }

    static func startsWithTable(in text: String) -> Bool {
        let firstLines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard firstLines.count >= 2 else { return false }
        let headers = splitTableCells(String(firstLines[0]))
        return headers.count >= 2 &&
            isDelimiterLine(String(firstLines[1]), expectedCount: headers.count)
    }

    static func blocks(
        in text: String,
        includeTrailingPartialTableRow: Bool = true,
        includeParsedTableCells: Bool = false
    ) -> [ChatStreamingMarkdownBlock] {
        parseBlocks(
            in: text,
            includeTrailingPartialTableRow: includeTrailingPartialTableRow,
            includeParsedTableCells: includeParsedTableCells
        )
    }

    private static func parseBlocks(
        in text: String,
        includeTrailingPartialTableRow: Bool,
        includeParsedTableCells: Bool
    ) -> [ChatStreamingMarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [ChatStreamingMarkdownBlock] = []
        var textStart = 0
        var index = 0
        var blockOrdinal = 0
        var activeFenceMarker: Character?

        func flushText(until end: Int) {
            guard textStart < end else { return }
            let content = lines[textStart..<end].joined(separator: "\n")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                textStart = end
                return
            }
            blocks.append(ChatStreamingMarkdownBlock(
                id: "text-\(blockOrdinal)",
                kind: .text(content)
            ))
            blockOrdinal += 1
            textStart = end
        }

        while index < lines.count {
            let line = lines[index]
            if let marker = fenceMarker(in: line) {
                if activeFenceMarker == nil {
                    activeFenceMarker = marker
                } else if activeFenceMarker == marker {
                    activeFenceMarker = nil
                }
                index += 1
                continue
            }

            if activeFenceMarker == nil,
               index + 1 < lines.count,
               let parsedTable = parseTable(
                lines: lines,
                start: index,
                sourceEndsWithNewline: text.hasSuffix("\n"),
                includeTrailingPartialTableRow: includeTrailingPartialTableRow,
                includeParsedTableCells: includeParsedTableCells
               ) {
                flushText(until: index)
                blocks.append(ChatStreamingMarkdownBlock(
                    id: "table-\(blockOrdinal)",
                    kind: .table(parsedTable.table)
                ))
                blockOrdinal += 1
                index += parsedTable.consumedLineCount
                textStart = index
                continue
            }

            index += 1
        }

        flushText(until: lines.count)
        return blocks
    }

    private static func parseTable(
        lines: [String],
        start: Int,
        sourceEndsWithNewline: Bool,
        includeTrailingPartialTableRow: Bool,
        includeParsedTableCells: Bool
    ) -> ChatStreamingMarkdownParsedTable? {
        guard start + 1 < lines.count else { return nil }
        let headers = splitTableCells(lines[start])
        guard headers.count >= 2, isDelimiterLine(lines[start + 1], expectedCount: headers.count) else {
            return nil
        }

        var rows: [[String]] = []
        var renderedLines: [String] = [lines[start], lines[start + 1]]
        var index = start + 2
        var renderedEndIndex = start + 2
        let headerUsesLeadingPipe = lines[start]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("|")
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTrailingPartialLine = !includeTrailingPartialTableRow &&
                !sourceEndsWithNewline &&
                index == lines.count - 1
            let canBeNoLeadingPipePartialRow = isTrailingPartialLine && !headerUsesLeadingPipe
            guard !trimmed.isEmpty,
                  line.contains("|") || canBeNoLeadingPipePartialRow,
                  !isDelimiterLine(line, expectedCount: headers.count) else {
                break
            }
            // 含管道的尾行流式期立即渲染为部分行（缺的单元格补空渲染），消除
            // 完成瞬间「最后一行成批出现」的排版重排。无管道尾行保持只消费不
            // 渲染（防「文本↔表格行」中途互变——guard 的
            // `line.contains("|") || canBeNoLeadingPipePartialRow` 已做形状判别）。
            if isTrailingPartialLine {
                if line.contains("|") {
                    if includeParsedTableCells {
                        let cells = ChatStreamingMarkdownTableRowCache.shared.cells(
                            for: line,
                            expectedCount: headers.count
                        ) {
                            normalizedRow(splitTableCells(line), count: headers.count)
                        }
                        rows.append(cells)
                    }
                    renderedLines.append(
                        renderedRowLine(line, columnCount: headers.count, leadingPipe: headerUsesLeadingPipe)
                    )
                    renderedEndIndex = index + 1
                }
                index += 1
                break
            }
            if includeParsedTableCells {
                let cells = ChatStreamingMarkdownTableRowCache.shared.cells(
                    for: line,
                    expectedCount: headers.count
                ) {
                    normalizedRow(splitTableCells(line), count: headers.count)
                }
                rows.append(cells)
            }
            renderedLines.append(
                renderedRowLine(line, columnCount: headers.count, leadingPipe: headerUsesLeadingPipe)
            )
            renderedEndIndex = index + 1
            index += 1
        }
        let consumedLineCount = index - start

        return ChatStreamingMarkdownParsedTable(
            table: ChatStreamingMarkdownTable(
                id: "table-\(start)",
                markdown: renderedLines.joined(separator: "\n"),
                headers: includeParsedTableCells ? normalizedRow(headers, count: headers.count) : [],
                rows: rows
            ),
            consumedLineCount: consumedLineCount
        )
    }

    /// 行单元格数与表头一致时保留原始行文本（转义管道 `\|` 不能被重组吞掉，
    /// 复制表格用 rawMarkdown 还原）；不足时补空单元格到表头列数后重组——
    /// vendor 的 `Table+.swift` 会过滤「列数 ≠ 表头列数」的行，不补空则流式期
    /// 渲染出的部分行会在完成时被静默丢弃，形成「行消失」差分。
    private static func renderedRowLine(
        _ line: String,
        columnCount: Int,
        leadingPipe: Bool
    ) -> String {
        let cells = splitTableCells(line)
        guard cells.count != columnCount else { return line }
        let padded = normalizedRow(cells, count: columnCount)
        let body = padded.joined(separator: " | ")
        return leadingPipe ? "| \(body) |" : body
    }

    private static func splitTableCells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
        var cells: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\",
               index + 1 < characters.count,
               characters[index + 1] == "|" {
                current.append("|")
                index += 2
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        if cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func normalizedRow(_ cells: [String], count: Int) -> [String] {
        if cells.count == count {
            return cells
        }
        if cells.count > count {
            return Array(cells.prefix(count))
        }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private static func isDelimiterLine(_ line: String, expectedCount: Int) -> Bool {
        let cells = splitTableCells(line)
        guard cells.count == expectedCount else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    private static func fenceMarker(in line: String) -> Character? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return "`" }
        if trimmed.hasPrefix("~~~") { return "~" }
        return nil
    }

    static func tableHeaderColumnCountForDetection(in line: String) -> Int? {
        let count = splitTableCells(line).count
        return count >= 2 ? count : nil
    }

    static func isDelimiterLineForDetection(_ line: String, expectedCount: Int) -> Bool {
        isDelimiterLine(line, expectedCount: expectedCount)
    }

    static func fenceMarkerForDetection(in line: String) -> Character? {
        fenceMarker(in: line)
    }
}

/// 表格/widget 增量探测器的引用盒。
/// `ChatAssistantMarkdownView` 的 body 不读取盒内字段(只读显式的 latch @State),
/// 因此每个 chunk 的增量消费不触发 SwiftUI 失效。新增探测器时保持这个约束。
@MainActor
private final class ChatStreamingDetectionBox {
    struct MarkdownConfigKey: Hashable {
        let liveStreaming: Bool
        let reduceMotion: Bool
        let fontScale: Double
        let bodyPointSize: CGFloat
        let chatFont: String
        let themePaper: String
        let themeAccentHex: UInt32
        // 必须是无默认值的 `let`:其余字段都靠"漏传即编译失败"来保证任何新的
        // config 构造点都会被迫接上。给默认值会让漏传的构造点静默复用别人的
        // 缓存条目,同屏出现两种渲染策略且无红灯。
        let coalescedTextBlocks: Bool
    }

    var table: ChatStreamingTableDetectionState
    var widget: IOSGenerativeWidgetPayloadDetector
    /// 渲染 config 记忆化。此前每次 body 求值都重建 config,其中
    /// `UIColor(AmberTheme.xxx)` 每次产生新的 dynamic-provider UIColor 实例,
    /// `isEqual` 恒 false → `MarkdownRenderConfig ==` 每 delta 必假 →
    /// vendor `DocumentView` 的 Equatable 短路每 delta 被击穿,全部表格块
    /// 33Hz 重建+整表重测量(2026-07-10 缩放矩阵 tables24≈284ms/delta 的根因),
    /// 同时 configHash 漂移让 renderable 静态缓存与 `.task(id:)` 全部失效。
    /// 复用同一 config 实例后,动态色仍按 trait 在绘制时解析,明暗模式不受影响。
    private var configCache: [MarkdownConfigKey: SwiftStreamingMarkdown.MarkdownRenderConfig] = [:]

    init(markdown: String) {
        table = ChatStreamingTableDetectionState(text: markdown)
        widget = IOSGenerativeWidgetPayloadDetector(text: markdown)
    }

    func markdownConfig(
        for key: MarkdownConfigKey,
        build: () -> SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> SwiftStreamingMarkdown.MarkdownRenderConfig {
        if let cached = configCache[key] {
            return cached
        }
        let built = build()
        configCache[key] = built
        // 键随排版/主题变化，旧键不会再被读取；限个上限防设置反复横跳。
        if configCache.count > 6 {
            configCache.removeAll()
            configCache[key] = built
        }
        return built
    }
}

private struct ChatStreamingTableDetectionState {
    private static let checkpointLength = 32

    private var processedUTF8Count = 0
    private var checkpoint: [UInt8] = []
    private var pendingLineBytes: [UInt8] = []
    private var previousHeaderColumnCount: Int?
    private var activeFenceMarker: Character?
    private(set) var containsTable = false
    private(set) var totalConsumedUTF8Count = 0

    init(text: String = "") {
        if !text.isEmpty {
            update(with: text)
        }
    }

    mutating func update(with text: String) {
        guard !containsTable else { return }
        let utf8 = text.utf8
        let count = utf8.count
        guard count != processedUTF8Count || !checkpointMatches(in: utf8) else { return }

        if count < processedUTF8Count || !checkpointMatches(in: utf8) {
            resetParserState()
        }

        let start = utf8.index(utf8.startIndex, offsetBy: processedUTF8Count)
        let appended = utf8[start...]
        totalConsumedUTF8Count += appended.count
        for byte in appended {
            if byte == 0x0A {
                processCompletedLine()
                pendingLineBytes.removeAll(keepingCapacity: true)
            } else {
                pendingLineBytes.append(byte)
            }
            if containsTable { break }
        }
        processedUTF8Count = count
        checkpoint = Array(utf8.suffix(Self.checkpointLength))
        evaluatePendingDelimiter()
    }

    private func checkpointMatches(in utf8: String.UTF8View) -> Bool {
        guard processedUTF8Count > 0 else { return true }
        guard processedUTF8Count <= utf8.count, checkpoint.count <= processedUTF8Count else { return false }
        let startOffset = processedUTF8Count - checkpoint.count
        let start = utf8.index(utf8.startIndex, offsetBy: startOffset)
        let end = utf8.index(start, offsetBy: checkpoint.count)
        return utf8[start..<end].elementsEqual(checkpoint)
    }

    private mutating func resetParserState() {
        processedUTF8Count = 0
        checkpoint.removeAll(keepingCapacity: true)
        pendingLineBytes.removeAll(keepingCapacity: true)
        previousHeaderColumnCount = nil
        activeFenceMarker = nil
        containsTable = false
    }

    private mutating func processCompletedLine() {
        if pendingLineBytes.last == 0x0D {
            pendingLineBytes.removeLast()
        }
        let line = String(decoding: pendingLineBytes, as: UTF8.self)
        if let marker = ChatStreamingMarkdownBlockParser.fenceMarkerForDetection(in: line) {
            if activeFenceMarker == nil {
                activeFenceMarker = marker
            } else if activeFenceMarker == marker {
                activeFenceMarker = nil
            }
            previousHeaderColumnCount = nil
            return
        }
        guard activeFenceMarker == nil else {
            previousHeaderColumnCount = nil
            return
        }
        if let expectedCount = previousHeaderColumnCount,
           ChatStreamingMarkdownBlockParser.isDelimiterLineForDetection(
            line,
            expectedCount: expectedCount
           ) {
            containsTable = true
            return
        }
        previousHeaderColumnCount = ChatStreamingMarkdownBlockParser
            .tableHeaderColumnCountForDetection(in: line)
    }

    private mutating func evaluatePendingDelimiter() {
        guard !containsTable,
              activeFenceMarker == nil,
              let expectedCount = previousHeaderColumnCount else { return }
        let line = String(decoding: pendingLineBytes, as: UTF8.self)
        guard ChatStreamingMarkdownBlockParser.fenceMarkerForDetection(in: line) == nil else { return }
        if ChatStreamingMarkdownBlockParser.isDelimiterLineForDetection(
            line,
            expectedCount: expectedCount
        ) {
            containsTable = true
        }
    }
}

private final class ChatStreamingMarkdownTableRowCache: @unchecked Sendable {
    static let shared = ChatStreamingMarkdownTableRowCache()

    private final class Box {
        let cells: [String]

        init(_ cells: [String]) {
            self.cells = cells
        }
    }

    private let cache = NSCache<NSString, Box>()
#if DEBUG
    private let metricsLock = NSLock()
    private var hitCount = 0
    private var missCount = 0
#endif

    private init() {
        cache.countLimit = 512
    }

    func cells(for line: String, expectedCount: Int, build: () -> [String]) -> [String] {
        let key = "\(expectedCount):\(line)" as NSString
        if let cached = cache.object(forKey: key) {
#if DEBUG
            recordHit()
#endif
            return cached.cells
        }
        let cells = build()
        cache.setObject(Box(cells), forKey: key)
#if DEBUG
        recordMiss()
#endif
        return cells
    }

#if DEBUG
    private func recordHit() {
        metricsLock.lock()
        hitCount += 1
        metricsLock.unlock()
    }

    private func recordMiss() {
        metricsLock.lock()
        missCount += 1
        metricsLock.unlock()
    }

    func resetForTesting() {
        cache.removeAllObjects()
        metricsLock.lock()
        hitCount = 0
        missCount = 0
        metricsLock.unlock()
    }

    var metricsForTesting: (hits: Int, misses: Int) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return (hitCount, missCount)
    }
#endif
}

#if DEBUG
struct ChatStreamingMarkdownBlockParserTestBlock: Equatable {
    let kind: String
    let text: String
    let markdown: String
    let headers: [String]
    let rows: [[String]]
}

enum ChatStreamingMarkdownBlockParserTestSupport {
    static func containsTable(in text: String) -> Bool {
        ChatStreamingMarkdownBlockParser.containsTable(in: text)
    }

    static func blocks(
        in text: String,
        includeTrailingPartialTableRow: Bool
    ) -> [ChatStreamingMarkdownBlockParserTestBlock] {
        ChatStreamingMarkdownBlockParser.blocks(
            in: text,
            includeTrailingPartialTableRow: includeTrailingPartialTableRow,
            includeParsedTableCells: true
        ).map { block in
            switch block.kind {
            case .text(let content):
                return ChatStreamingMarkdownBlockParserTestBlock(
                    kind: "text",
                    text: content,
                    markdown: content,
                    headers: [],
                    rows: []
                )
            case .table(let table):
                return ChatStreamingMarkdownBlockParserTestBlock(
                    kind: "table",
                    text: "",
                    markdown: table.markdown,
                    headers: table.headers,
                    rows: table.rows
                )
            }
        }
    }

    static func productionTableCellCounts(in text: String) -> (headers: Int, rows: Int)? {
        for block in ChatStreamingMarkdownBlockParser.blocks(in: text) {
            if case .table(let table) = block.kind {
                return (table.headers.count, table.rows.count)
            }
        }
        return nil
    }

    static func resetRowCache() {
        ChatStreamingMarkdownTableRowCache.shared.resetForTesting()
    }

    static var rowCacheMetrics: (hits: Int, misses: Int) {
        ChatStreamingMarkdownTableRowCache.shared.metricsForTesting
    }
}

@MainActor
enum ChatStreamingMarkdownConfigCacheTestSupport {
    static func buildCount(themeKeys: [(paper: String, accentHex: UInt32)]) -> Int {
        let detection = ChatStreamingDetectionBox(markdown: "")
        var buildCount = 0
        for theme in themeKeys {
            _ = detection.markdownConfig(
                for: ChatStreamingDetectionBox.MarkdownConfigKey(
                    liveStreaming: true,
                    reduceMotion: false,
                    fontScale: 1,
                    bodyPointSize: 17,
                    chatFont: IOSChatFont.default.rawValue,
                    themePaper: theme.paper,
                    themeAccentHex: theme.accentHex,
                    coalescedTextBlocks: false
                ),
                build: {
                    buildCount += 1
                    return SwiftStreamingMarkdown.MarkdownRenderConfig.default
                }
            )
        }
        return buildCount
    }
}

enum ChatStreamingTableDetectionTestSupport {
    static func replay(_ texts: [String]) -> (containsTable: Bool, consumedUTF8Count: Int) {
        var detector = ChatStreamingTableDetectionState()
        for text in texts {
            detector.update(with: text)
        }
        return (detector.containsTable, detector.totalConsumedUTF8Count)
    }
}

#endif

private struct ChatStableStreamingMarkdownView: View {
    let text: String
    let config: SwiftStreamingMarkdown.MarkdownRenderConfig
    var cacheIdentity: String? = nil
    var preservesRenderedTable = false
    @StateObject private var controller = ChatStableStreamingMarkdownController()

    var body: some View {
        let resolution = controller.resolution(
            for: text,
            config: config,
            cacheIdentity: cacheIdentity,
            preservesRenderedTable: preservesRenderedTable
        )
        // 占位按空行拆段：空行不再按整行文本高度渲染，段间距由 BlockView 的
        // blockSpacing 提供，使冷行首帧高度贴近异步解析后的真实高度，
        // 消除历史行首次实例化时"占位偏高→解析后整章收缩"的可见位移。
        let renderable = resolution.renderable
            ?? SwiftStreamingMarkdown.RenderableDocument(
                plainText: text,
                id: "0",
                config: config,
                splittingParagraphsOnBlankLines: true
            )
        SwiftStreamingMarkdown.DocumentView(
            renderableDocument: renderable,
            config: config,
            animateInitialText: !resolution.suppressesInitialFade,
            usesLayerBackedTableAnimation: config.shouldAnimateText,
            usesTextKit1ForAttachmentFreeText: true
        )
            .task(id: ChatStableStreamingMarkdownParseKey(
                text: text,
                animate: config.shouldAnimateText,
                configHash: config.hashValue,
                cacheIdentity: cacheIdentity
            )) {
                controller.scheduleParse(text: text, config: config, cacheIdentity: cacheIdentity)
            }
    }
}

private struct ChatStableStreamingMarkdownParseKey: Equatable {
    let text: String
    let animate: Bool
    let configHash: Int
    let cacheIdentity: String?
}

@MainActor
private final class ChatStableStreamingMarkdownController: ObservableObject {
    private struct RenderSignature: Hashable {
        let visualConfigHash: Int
        let speculative: Bool
    }

    private struct RenderableCacheKey: Hashable {
        let text: String
        let signature: RenderSignature
    }

    private struct IdentityCacheKey: Hashable {
        let identity: String
        let visualConfigHash: Int
    }

    private struct IdentityCacheEntry {
        let text: String
        let signature: RenderSignature
        let renderable: SwiftStreamingMarkdown.RenderableDocument
    }

    private static var renderableCache: [RenderableCacheKey: SwiftStreamingMarkdown.RenderableDocument] = [:]
    private static var renderableCacheOrder: [RenderableCacheKey] = []
    private static let renderableCacheLimit = 24
    private static var identityCache: [IdentityCacheKey: IdentityCacheEntry] = [:]
    private static var identityCacheOrder: [IdentityCacheKey] = []
    // 长篇(小说/长对话)可有上百个段落 block。完成态重挂载/LOD 翻转时,只要 identity
    // 缓存还持有该段落的 renderable,resolution 就返回 suppressesInitialFade=true,不再
    // 重新淡入(闪烁)。64 会让靠前的段落在后续解析中被挤出 → 完成时重新淡入;提到 256
    // 让整篇已完成段落基本都能命中,消除完成瞬间的整屏闪烁。
    private static let identityCacheLimit = 256

    @Published private(set) var revision = 0
    private var renderedText: String?
    private var renderableDocument: SwiftStreamingMarkdown.RenderableDocument?
    private var renderedSignature: RenderSignature?
    private var restoredFromCache = false
    private var pendingParse: (
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        cacheIdentity: String?
    )?
    private var parseTask: Task<Void, Never>?
    private var parseTaskGeneration: UInt64 = 0
    private var lastLiveParseAt = Date.distantPast

    deinit {
        parseTask?.cancel()
    }

    func renderable(
        for text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> SwiftStreamingMarkdown.RenderableDocument? {
        resolution(for: text, config: config, cacheIdentity: nil).renderable
    }

    func resolution(
        for text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        cacheIdentity: String?,
        preservesRenderedTable: Bool = false
    ) -> (renderable: SwiftStreamingMarkdown.RenderableDocument?, suppressesInitialFade: Bool) {
        let signature = Self.renderSignature(for: config)
        // 完全匹配:返回最新解析结果。utf16.count 先行短路,避免流式期每次
        // body 求值都对不等长文本做 O(n) 字符串比较。
        if let renderedSignature,
           renderedSignature.visualConfigHash == signature.visualConfigHash,
           let rendered = renderedText,
           rendered.utf16.count == text.utf16.count,
           rendered == text {
            return (
                renderableDocument,
                restoredFromCache || renderedSignature.speculative != signature.speculative
            )
        }
        // 解析落后于最新 delta:返回上一次成功解析的结果(对应稍旧的文本前缀),
        // 让已格式化的内容持续显示,新增尾部文本会在下次解析完成后补上。
        // 之前用严格相等导致高速 delta 下 renderedText 永远落后于 text,
        // 恒返回 nil → 退回纯文本 fallback(用户看不到表格/代码块等格式)。
        //
        // 完成切换的原子性:比较只用 visualConfigHash(跨 speculative 稳定),
        // 不要求 speculative 相同——流式(speculative)解析的格式化前缀在完成
        // (非 speculative)解析落地前继续上屏,替换延迟到终态 renderable 就绪
        // 的同一帧(「不换纸」)。若此处收紧,完成瞬间 speculative 翻转会把
        // 解析落后的块打进 `RenderableDocument(plainText:)` 兜底——整段正文
        // 退回未渲染的 markdown 原文,直到终态首次异步解析落地才重新渲染
        // (真机完成瞬间闪原文的根因)。
        //
        // 顺序说明:本实例的 stale-prefix 命中放在静态缓存之前——流式期几乎
        // 每次都命中这条,静态缓存查询(全文 Hasher + 最多 12 次 hasPrefix,
        // 32KB 实测 ~0.2ms)只留给实例重建/LOD 翻转等冷路径。追加式流式下
        // 静态缓存不可能持有比本实例更新的精确条目(旧条目都是当前文本的前缀)。
        if let renderedSignature,
           renderedSignature.visualConfigHash == signature.visualConfigHash,
           let renderedText,
           !renderedText.isEmpty,
           // Partial table rows contain synthetic closing pipes/empty cells. The
           // next delta rewrites that suffix, so it is not an append-only prefix.
           // Keep this table visible until its replacement has finished parsing.
           preservesRenderedTable || (text.utf16.count >= renderedText.utf16.count && text.hasPrefix(renderedText)) {
            return (renderableDocument, false)
        }
        if let cacheIdentity,
           let cached = Self.cachedIdentityRenderable(
            for: cacheIdentity,
            text: text,
            signature: signature,
            preservesRenderedTable: preservesRenderedTable
           ) {
            return (cached, true)
        }
        if let cached = Self.cachedRenderable(for: text, config: config) {
            return (cached, true)
        }
        return (nil, false)
    }

    func scheduleParse(
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        cacheIdentity: String? = nil
    ) {
        if !config.shouldAnimateText {
            pendingParse = nil
            parseTaskGeneration &+= 1
            let generation = parseTaskGeneration
            parseTask?.cancel()
            parseTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.parseNow(text: text, config: config, cacheIdentity: cacheIdentity)
                guard self.parseTaskGeneration == generation else { return }
                self.parseTask = nil
                self.startPendingAnimatedParseIfNeeded()
            }
            return
        }

        pendingParse = (text, config, cacheIdentity)
        startPendingAnimatedParseIfNeeded()
    }

    private func startPendingAnimatedParseIfNeeded() {
        guard parseTask == nil, pendingParse != nil else { return }
        parseTaskGeneration &+= 1
        let generation = parseTaskGeneration
        parseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.parseTaskGeneration == generation {
                    self.parseTask = nil
                    self.startPendingAnimatedParseIfNeeded()
                }
            }
            while !Task.isCancelled {
                guard let next = self.pendingParse else { return }
                self.pendingParse = nil

                let elapsed = Date().timeIntervalSince(self.lastLiveParseAt)
                let liveParseInterval = self.liveParseInterval(for: next.text)
                if elapsed < liveParseInterval {
                    let delay = UInt64((liveParseInterval - elapsed) * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                }

                self.lastLiveParseAt = Date()
                await self.parseNow(
                    text: next.text,
                    config: next.config,
                    cacheIdentity: next.cacheIdentity
                )
            }
        }
    }

    private func liveParseInterval(for text: String) -> TimeInterval {
        Self.liveParseInterval(
            utf16Length: text.utf16.count,
            isTable: ChatStreamingMarkdownBlockParser.startsWithTable(in: text)
        )
    }

    /// 表格越大发布越慢,降低整表布局产生 79ms 级主线程卡顿的频率(P1-5 止血)。
    /// 根因(增量表格布局)在 vendor 侧,这里只是频域降频;<12K 档位保持原值,
    /// 只给超大表格新增 0.5s 档。
    static func liveParseInterval(utf16Length length: Int, isTable: Bool) -> TimeInterval {
        // 普通文本已经经过 coordinator 的 48ms snapshot gate。这里不能再加
        // 独立定时门：两个窗口错相时会把可见高度更新合并到约 132ms，表现为
        // 累计数行后整段上跳。解析仍由 single-flight/latest-wins 自然背压。
        guard isTable else { return 0 }
        if length < 1_200 {
            return 0.12
        }
        if length < 4_000 {
            return 0.20
        }
        if length < 12_000 {
            return 0.32
        }
        return 0.5
    }

    private func parseNow(
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        cacheIdentity: String?
    ) async {
        // S3: 流式场景(shouldAnimateText=true)启用 speculativeRewrite,
        // 让 PartialTableMarkupPostParsingRewriter/PartialStrongMarkupPostParsingRewriter 生效,
        // 半截表格/未闭合强调不会渲染成乱码,而是降级成段落,等后续 delta 补齐再升级。
        let animate = config.shouldAnimateText
        let signature = Self.renderSignature(for: config)
        if renderedSignature == signature, renderedText == text {
            return
        }
        // Only remounts need a static lookup; an active stream already owns its
        // newest result and should not hash the growing text on every parse.
        let cached = renderedText == nil ? Self.cachedExactRenderable(
            for: text,
            signature: signature,
            cacheIdentity: cacheIdentity
        ) : nil
        let previousText = renderedText
        let previousRenderable = renderedSignature?.visualConfigHash == signature.visualConfigHash
            ? renderableDocument
            : nil
        let renderable: SwiftStreamingMarkdown.RenderableDocument
        if let cached {
            renderable = cached
            ChatPerfTrace.event("MarkdownCacheHit")
        } else {
            renderable = await Task.detached(priority: .userInitiated) {
                let parser = SwiftStreamingMarkdown.MarkdownParserImpl()
                // repairsRejectedStrongEmphasis：修复 CommonMark flanking 拒绝的粗体
                // （**（重点）**、CJK 紧邻 __…__ 等），流式与完成态同修。
                let option = SwiftStreamingMarkdown.MarkdownParseOption(
                    speculativeRewrite: animate,
                    repairsRejectedStrongEmphasis: true
                )
                let result = await ChatPerfTrace.measure("MarkdownParse", count: { text.utf16.count }) {
                    await parser.parse(text: text, option: option)
                }
                let converted = await ChatPerfTrace.measure("MarkdownConvert", count: { text.utf16.count }) {
                    await SwiftStreamingMarkdown.RenderableDocument(
                        document: result.document,
                        config: config
                    )
                }
                guard let previousText,
                      let previousRenderable,
                      text.utf16.count >= previousText.utf16.count,
                      text.hasPrefix(previousText) else { return converted }
                return converted.reusingUnchangedPrefix(from: previousRenderable)
            }.value
        }
        guard !Task.isCancelled else { return }
        guard renderedText != text || renderedSignature != signature || renderableDocument != renderable else {
            return
        }
        ChatPerfTrace.measure("MarkdownPublish", count: { text.utf16.count }) {
            renderedText = text
            renderableDocument = renderable
            renderedSignature = signature
            restoredFromCache = cached != nil
            Self.storeCachedRenderable(renderable, for: text, config: config)
            if let cacheIdentity {
                Self.storeIdentityRenderable(
                    renderable,
                    for: cacheIdentity,
                    text: text,
                    signature: signature
                )
            }
            revision &+= 1
        }
    }

    // Display reuse allows an older prefix or speculative result. Skipping parsing
    // requires the same full text and parse mode, including after a row remounts.
    private static func cachedExactRenderable(
        for text: String,
        signature: RenderSignature,
        cacheIdentity: String?
    ) -> SwiftStreamingMarkdown.RenderableDocument? {
        if let cacheIdentity,
           let entry = identityCache[IdentityCacheKey(
            identity: cacheIdentity,
            visualConfigHash: signature.visualConfigHash
           )],
           entry.signature == signature,
           entry.text == text {
            return entry.renderable
        }
        return renderableCache[RenderableCacheKey(text: text, signature: signature)]
    }

    private static func cachedRenderable(
        for text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> SwiftStreamingMarkdown.RenderableDocument? {
        let signature = renderSignature(for: config)
        let exactKey = RenderableCacheKey(
            text: text,
            signature: signature
        )
        if let exact = renderableCache[exactKey] {
            // 命中移到队尾(LRU):多界面并发流式时,静态缓存按纯插入序驱逐会把
            // 仍在活跃复用的条目挤出,复出成本是整段全文重解析。
            if let index = renderableCacheOrder.lastIndex(of: exactKey) {
                renderableCacheOrder.remove(at: index)
                renderableCacheOrder.append(exactKey)
            }
            return exact
        }
        // 前缀命中的 speculative 门槛只为「完成切换原子性」而开:流式期存入的
        // speculative 条目在完成(非 speculative)解析落地前同样可复用——否则
        // 完成瞬间冷路径(行重建/LOD 解冻)会退回纯文本兜底闪原文。visualConfigHash
        // 相同即视觉等价,渲染差异只来自 speculativeRewrite 对未闭合标记的降级,
        // 由随后落地的权威解析原子替换。
        return renderableCacheOrder.reversed().lazy.compactMap { key -> SwiftStreamingMarkdown.RenderableDocument? in
            guard key.signature.visualConfigHash == signature.visualConfigHash,
                  text.hasPrefix(key.text),
                  !key.text.isEmpty else { return nil }
            return renderableCache[key]
        }.first
    }

    private static func storeCachedRenderable(
        _ renderable: SwiftStreamingMarkdown.RenderableDocument,
        for text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) {
        let key = RenderableCacheKey(
            text: text,
            signature: renderSignature(for: config)
        )
        if renderableCache[key] == nil {
            renderableCacheOrder.append(key)
        }
        renderableCache[key] = renderable
        while renderableCacheOrder.count > renderableCacheLimit {
            let removed = renderableCacheOrder.removeFirst()
            renderableCache.removeValue(forKey: removed)
        }
    }

    private static func cachedIdentityRenderable(
        for identity: String,
        text: String,
        signature: RenderSignature,
        preservesRenderedTable: Bool = false
    ) -> SwiftStreamingMarkdown.RenderableDocument? {
        let key = IdentityCacheKey(identity: identity, visualConfigHash: signature.visualConfigHash)
        guard let entry = identityCache[key] else { return nil }
        if preservesRenderedTable || (entry.text.utf16.count == text.utf16.count && entry.text == text) {
            return entry.renderable
        }
        // 与 cachedRenderable 同理由:前缀命中不设 speculative 门槛,保证完成
        // 切换/解冻的冷路径持续复用已格式化的前缀渲染,直到权威解析落地。
        guard !entry.text.isEmpty,
              text.utf16.count >= entry.text.utf16.count,
              text.hasPrefix(entry.text) else {
            return nil
        }
        return entry.renderable
    }

    private static func storeIdentityRenderable(
        _ renderable: SwiftStreamingMarkdown.RenderableDocument,
        for identity: String,
        text: String,
        signature: RenderSignature
    ) {
        let key = IdentityCacheKey(identity: identity, visualConfigHash: signature.visualConfigHash)
        if identityCache[key] != nil {
            identityCacheOrder.removeAll { $0 == key }
        }
        identityCache[key] = IdentityCacheEntry(text: text, signature: signature, renderable: renderable)
        identityCacheOrder.append(key)
        while identityCacheOrder.count > identityCacheLimit {
            let removed = identityCacheOrder.removeFirst()
            identityCache.removeValue(forKey: removed)
        }
    }

    private static func renderSignature(
        for config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> RenderSignature {
        RenderSignature(
            visualConfigHash: visualConfigHash(for: config),
            speculative: config.shouldAnimateText
        )
    }

    private static func visualConfigHash(for config: SwiftStreamingMarkdown.MarkdownRenderConfig) -> Int {
        // 动画类 flag 全部归一：visual hash 只反映非动画视觉，
        // 与「同 key 同渲染」的缓存契约对称。
        //
        // 不能直接哈希 config：生产 config 的色板是动态 UIColor(AmberTheme.*)，
        // 每次构建都是新实例，UIColor 的 hashValue 是实例身份哈希（实测同一
        // 主题构建三份实例得到三个不同的 hashValue）。流式与完成各走一次
        // config 构建（detection 的 configCache 按 key 各存一份实例），直接
        // 哈希会让 visualConfigHash 在完成瞬间失配 → 前缀/identity 缓存全部
        // 落空 → 已显示块退回 placeholder 闪帧（「完成后排版重排」的载体）。
        // 改为逐项枚举视觉输入并稳定哈希：颜色按固定 trait 解析后的分量哈希
        // （同一主题任意构建实例同值），字体/度量直接哈希。textContextMenu /
        // citationConfig 未被生产 builder 覆盖，始终是 default 的共享实例，
        // 跨实例稳定，无需枚举。
        var hasher = Hasher()
        hasher.combine(config.blockSpacing)
        hasher.combine(config.paragraphLineSpacing)
        hasher.combine(config.headingLineSpacing)
        hasher.combine(config.tableCellHorizontalPadding)
        hasher.combine(config.tableCellVerticalPadding)
        hasher.combine(config.listItemSpacing)
        hasher.combine(config.tableMaxColumnWidth)
        hasher.combine(config.unorderedListBulletWidth)
        hasher.combine(config.collapsesSoftBreaks)
        hasher.combine(config.coalescesAdjacentTextBlocks)
        hasher.combine(config.paragraphStyle.textFonts)
        // 字体跨实例相等且哈希稳定（UIFont 语义）。漏掉 tableStyle.textFonts
        // 会在未来 builder 单独改表格字体时静默复用旧 renderable。
        hasher.combine(config.tableStyle.textFonts)
        hasher.combine(config.blockQuoteStyle.textFonts)
        hasher.combine(config.orderedListStyle.textFonts)
        hasher.combine(config.headingStyle.h1Font)
        hasher.combine(config.headingStyle.h2Font)
        hasher.combine(config.headingStyle.h3Font)
        hasher.combine(config.headingStyle.h4Font)
        hasher.combine(config.headingStyle.h5Font)
        hasher.combine(config.headingStyle.h6Font)
        hasher.combine(config.inlineStyle.linkTextFont)
        hasher.combine(config.inlineStyle.codeTextFont)
        combineResolvedColor(config.paragraphStyle.textColor, into: &hasher)
        combineResolvedColor(config.blockQuoteStyle.textColor, into: &hasher)
        combineResolvedColor(config.headingStyle.textColor, into: &hasher)
        combineResolvedColor(config.orderedListStyle.textColor, into: &hasher)
        combineResolvedColor(config.tableStyle.headerTextColor, into: &hasher)
        combineResolvedColor(config.tableStyle.regularTextColor, into: &hasher)
        combineResolvedColor(config.tableStyle.headerBackgroundColor, into: &hasher)
        combineResolvedColor(config.tableStyle.borderColor, into: &hasher)
        combineResolvedColor(config.tableStyle.actionButtonColor, into: &hasher)
        combineResolvedColor(config.inlineStyle.boldTextColor, into: &hasher)
        combineResolvedColor(config.inlineStyle.linkTextColor, into: &hasher)
        combineResolvedColor(config.inlineStyle.codeTextColor, into: &hasher)
        combineResolvedColor(config.inlineStyle.codeBackgroundColor, into: &hasher)
        combineResolvedColor(config.inlineStyle.codeUnderlineColor, into: &hasher)
        return hasher.finalize()
    }

    /// 动态色按固定 trait 解析为静态色后哈希 RGBA 分量：同一主题任意构建
    /// 实例得到同一值（动态 UIColor 的 hashValue 是实例身份哈希，跨实例不稳）。
    private static func combineResolvedColor(_ color: UIColor, into hasher: inout Hasher) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            hasher.combine(red)
            hasher.combine(green)
            hasher.combine(blue)
            hasher.combine(alpha)
        } else {
            // 非 RGB（如系统占位色）：静态色实例之间哈希稳定，直接兜底。
            hasher.combine(resolved.hashValue)
        }
    }

#if DEBUG
    var renderedTextForTesting: String? {
        renderedText
    }

    func seedRenderableForTesting(
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        cacheIdentity: String? = nil
    ) {
        renderedText = text
        let renderable = SwiftStreamingMarkdown.RenderableDocument(plainText: text, config: config)
        let signature = Self.renderSignature(for: config)
        renderableDocument = renderable
        renderedSignature = signature
        if let cacheIdentity {
            Self.storeIdentityRenderable(
                renderable,
                for: cacheIdentity,
                text: text,
                signature: signature
            )
        }
    }

    static func resetRenderableCacheForTesting() {
        renderableCache.removeAll()
        renderableCacheOrder.removeAll()
        identityCache.removeAll()
        identityCacheOrder.removeAll()
    }

    static func storeRenderableForTesting(
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) {
        storeCachedRenderable(
            SwiftStreamingMarkdown.RenderableDocument(plainText: text, config: config),
            for: text,
            config: config
        )
    }

    static func hasCachedRenderableForTesting(
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> Bool {
        cachedRenderable(for: text, config: config) != nil
    }

    static func storeIdentityRenderableForTesting(
        identity: String,
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) {
        storeIdentityRenderable(
            SwiftStreamingMarkdown.RenderableDocument(plainText: text, config: config),
            for: identity,
            text: text,
            signature: renderSignature(for: config)
        )
    }

    static func hasCachedIdentityRenderableForTesting(
        identity: String,
        text: String,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> Bool {
        cachedIdentityRenderable(
            for: identity,
            text: text,
            signature: renderSignature(for: config)
        ) != nil
    }

    static func visualConfigHashForTesting(
        config: SwiftStreamingMarkdown.MarkdownRenderConfig
    ) -> Int {
        visualConfigHash(for: config)
    }
#endif
}

#if DEBUG
@MainActor
enum ChatStableStreamingMarkdownCacheTestSupport {
    static func reset() {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
    }

    static func store(text: String, animate: Bool) {
        ChatStableStreamingMarkdownController.storeRenderableForTesting(
            text: text,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: animate)
        )
    }

    static func hasCachedRenderable(text: String, animate: Bool) -> Bool {
        ChatStableStreamingMarkdownController.hasCachedRenderableForTesting(
            text: text,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: animate)
        )
    }

    static func storeIdentity(identity: String, text: String, animate: Bool) {
        ChatStableStreamingMarkdownController.storeIdentityRenderableForTesting(
            identity: identity,
            text: text,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: animate)
        )
    }

    static func hasCachedIdentity(identity: String, text: String, animate: Bool) -> Bool {
        ChatStableStreamingMarkdownController.hasCachedIdentityRenderableForTesting(
            identity: identity,
            text: text,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: animate)
        )
    }
}

@MainActor
enum ChatStreamingMarkdownThrottleTestSupport {
    static func liveParseInterval(utf16Length: Int, isTable: Bool) -> TimeInterval {
        ChatStableStreamingMarkdownController.liveParseInterval(utf16Length: utf16Length, isTable: isTable)
    }

    static func blockPublishInterval(utf16Length: Int, isTableTail: Bool) -> TimeInterval {
        ChatStreamingMarkdownBlockController.publishInterval(utf16Length: utf16Length, isTableTail: isTableTail)
    }
}

@MainActor
enum ChatStableStreamingMarkdownControllerTestSupport {
    static func visualConfigHash(for config: SwiftStreamingMarkdown.MarkdownRenderConfig) -> Int {
        ChatStableStreamingMarkdownController.visualConfigHashForTesting(config: config)
    }

    static func renderedTextAfterNonAnimatedThenAnimatedParse() async -> String? {
        let controller = ChatStableStreamingMarkdownController()
        let initialText = "initial completed text"
        let updatedText = "initial completed text with live delta"

        controller.scheduleParse(
            text: initialText,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: false)
        )
        guard await waitUntilRendered(initialText, by: controller) else {
            return controller.renderedTextForTesting
        }

        controller.scheduleParse(
            text: updatedText,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: true)
        )
        _ = await waitUntilRendered(updatedText, by: controller)
        return controller.renderedTextForTesting
    }

    static func renderedTextWhenAnimatedParseArrivesDuringNonAnimatedParse() async -> String? {
        let controller = ChatStableStreamingMarkdownController()
        let updatedText = "non-animated parse followed immediately by live delta"

        controller.scheduleParse(
            text: "non-animated parse",
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: false)
        )
        controller.scheduleParse(
            text: updatedText,
            config: SwiftStreamingMarkdown.MarkdownRenderConfig.default.withShouldAnimateText(value: true)
        )

        _ = await waitUntilRendered(updatedText, by: controller)
        return controller.renderedTextForTesting
    }

    static func hasStaleRenderable(
        renderedText: String,
        requestedText: String,
        preservesRenderedTable: Bool = false
    ) -> Bool {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
        let controller = ChatStableStreamingMarkdownController()
        let config = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        controller.seedRenderableForTesting(text: renderedText, config: config)
        return controller.resolution(
            for: requestedText,
            config: config,
            cacheIdentity: nil,
            preservesRenderedTable: preservesRenderedTable
        ).renderable != nil
    }

    static func instanceResolutionAfterSpeculativeModeChange() -> (
        hasRenderable: Bool,
        suppressesInitialFade: Bool
    ) {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
        let controller = ChatStableStreamingMarkdownController()
        let streamingConfig = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        let completedConfig = streamingConfig.withShouldAnimateText(value: false)
        controller.seedRenderableForTesting(text: "same text", config: streamingConfig)
        let resolution = controller.resolution(
            for: "same text",
            config: completedConfig,
            cacheIdentity: nil
        )
        return (resolution.renderable != nil, resolution.suppressesInitialFade)
    }

    /// 跨 speculative 模式复用是刻意取舍：完成瞬间即使文本停在未闭合语法
    /// （中断/超时终止），也先复用流式 renderable 保持画面连续，随后由
    /// scheduleParse 的非动画分支立即重解析纠正。此函数把该取舍固化为契约。
    static func instanceResolutionAfterSpeculativeModeChangeWithUnclosedMarkup() -> (
        hasRenderable: Bool,
        suppressesInitialFade: Bool
    ) {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
        let controller = ChatStableStreamingMarkdownController()
        let streamingConfig = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        let unclosedText = "结尾停在未闭合的 **强调 与半截表格\n| 列一 | 列二 |\n|---|---|\n| 单元格 |"
        controller.seedRenderableForTesting(text: unclosedText, config: streamingConfig)
        let resolution = controller.resolution(
            for: unclosedText,
            config: streamingConfig.withShouldAnimateText(value: false),
            cacheIdentity: nil
        )
        return (resolution.renderable != nil, resolution.suppressesInitialFade)
    }

    static func coldCompletionIdentityResolution() -> (
        hasRenderable: Bool,
        suppressesInitialFade: Bool
    ) {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
        let streamingConfig = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        let cacheIdentity = "message:text-0"
        let firstController = ChatStableStreamingMarkdownController()
        firstController.seedRenderableForTesting(
            text: "completed text",
            config: streamingConfig,
            cacheIdentity: cacheIdentity
        )

        let completedController = ChatStableStreamingMarkdownController()
        let resolution = completedController.resolution(
            for: "completed text",
            config: streamingConfig.withShouldAnimateText(value: false),
            cacheIdentity: cacheIdentity
        )
        return (resolution.renderable != nil, resolution.suppressesInitialFade)
    }

    static func hasInstanceRenderableAfterVisualConfigChange() -> Bool {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
        let controller = ChatStableStreamingMarkdownController()
        let initialConfig = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        let changedConfig = initialConfig.withParagraphLineSpacing(value: 9)
        controller.seedRenderableForTesting(text: "same text", config: initialConfig)
        return controller.renderable(for: "same text", config: changedConfig) != nil
    }

    static func coldReentryIdentityPrefixResolution() -> (
        hasRenderable: Bool,
        suppressesInitialFade: Bool
    ) {
        ChatStableStreamingMarkdownController.resetRenderableCacheForTesting()
        let config = SwiftStreamingMarkdown.MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
        let cacheIdentity = "message:text-0"
        let firstController = ChatStableStreamingMarkdownController()
        firstController.seedRenderableForTesting(
            text: "already rendered prefix",
            config: config,
            cacheIdentity: cacheIdentity
        )

        let reenteredController = ChatStableStreamingMarkdownController()
        let resolution = reenteredController.resolution(
            for: "already rendered prefix with new delta",
            config: config,
            cacheIdentity: cacheIdentity
        )
        return (resolution.renderable != nil, resolution.suppressesInitialFade)
    }

    private static func waitUntilRendered(
        _ expectedText: String,
        by controller: ChatStableStreamingMarkdownController
    ) async -> Bool {
        for _ in 0..<200 {
            if controller.renderedTextForTesting == expectedText {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
#endif

private extension UIFont {
    /// 给已有字体叠加斜体符号特征,用于构造流式渲染器排版对齐所需的 boldItalic 变体。
    func withItalicTrait() -> UIFont {
        let traits = fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
