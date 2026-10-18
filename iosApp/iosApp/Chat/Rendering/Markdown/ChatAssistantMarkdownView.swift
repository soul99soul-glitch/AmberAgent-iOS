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
    var isSourceMessageComplete = true
    var sourceMessageID: String? = nil
    var sourceTextPartIndex: Int = 0
    @State private var taskSegments: [IOSIntelligentUISegment] = []
    @State private var taskPreview: IOSIntelligentUIStreamingPreview?

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
        onGenerativeWidgetAction: @escaping (String) -> Void = { _ in },
        isSourceMessageComplete: Bool = true,
        sourceMessageID: String? = nil,
        sourceTextPartIndex: Int = 0
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
        self.isSourceMessageComplete = isSourceMessageComplete
        self.sourceMessageID = sourceMessageID
        self.sourceTextPartIndex = sourceTextPartIndex
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
            if widgetSettings.enabled && (mayContainWidgetPayload || !taskSegments.isEmpty) {
                if !taskSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(taskSegments.enumerated()), id: \.offset) { index, segment in
                            switch segment {
                            case .text(let text):
                                visualContent(text, liveStreaming: liveStreaming, segmentIdentity: "task:\(index)")
                            case .card(let definition):
                                if isStreaming {
                                    IOSIntelligentUIStreamingPreviewView(preview: .complete(definition),
                                        generationNamespace: liveStreaming ? taskGenerationNamespace(index) : nil,
                                        isAnimating: liveStreaming)
                                        .id(taskCardIdentity(definition.cardID))
                                } else {
                                    ChatIntelligentUIBlock(definition: definition,
                                                           isMessageComplete: isSourceMessageComplete,
                                                           interactionEnabled: widgetSettings.enableActions,
                                                           messageID: sourceMessageID, textPartIndex: sourceTextPartIndex)
                                        .id(taskCardIdentity(definition.cardID))
                                }
                            case .loading:
                                if let taskPreview {
                                    IOSIntelligentUIStreamingPreviewView(preview: taskPreview,
                                        generationNamespace: liveStreaming ? taskGenerationNamespace(index) : nil,
                                        isAnimating: liveStreaming)
                                        .id(taskGenerationNamespace(index))
                                } else {
                                    HStack(spacing: 6) {
                                        IOSGenerationActivityIndicator(isActive: liveStreaming)
                                        Text("正在组织任务界面…")
                                    }
                                        .font(.footnote).foregroundStyle(AmberTheme.muted)
                                }
                            case .invalid(let raw, let reason):
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(reason, systemImage: "exclamationmark.circle")
                                        .font(.footnote).foregroundStyle(AmberTheme.accentRed)
                                    DisclosureGroup("查看原始内容") {
                                        Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    visualContent(renderedMarkdown, liveStreaming: liveStreaming)
                }
            } else {
                markdownText(renderedMarkdown, liveStreaming: liveStreaming)
            }
        }
        .onAppear {
            if renderedMarkdownSnapshot.isEmpty {
                renderedMarkdownSnapshot = markdown
            }
            updateTaskSegments(reconcile: true)
            updateWidgetPayloadLatch(with: markdown)
            if isStreaming && liveRenderingEnabled {
                updateTableRendererLatch(with: renderedMarkdown)
            }
        }
        .onChange(of: markdown) { _, newValue in
            updateTaskSegments()
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
            updateTaskSegments(reconcile: true)
        }
        .onChange(of: liveRenderingEnabled) { _, newValue in
            // Capture once at the live/frozen boundary. Mirroring every live delta
            // into @State only schedules a duplicate body update.
            renderedMarkdownSnapshot = markdown
            updateTaskSegments(reconcile: true)
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
        .onChange(of: frozenMarkdownSnapshot) { _, _ in updateTaskSegments(reconcile: true) }
        .onChange(of: sourceMessageID) { _, _ in resetTaskSource() }
        .onChange(of: sourceTextPartIndex) { _, _ in resetTaskSource() }
        .onChange(of: renderCacheNamespace) { _, _ in resetTaskSource() }
        .environment(\.openURL, ChatMarkdownOpenURLPolicy.openURLAction)
    }

    @ViewBuilder
    private func visualContent(_ renderedMarkdown: String, liveStreaming: Bool, segmentIdentity: String? = nil) -> some View {
        let widgetSettings = IOSGenerativeWidgetSettings(generativeUiSetting)
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
                                    cacheIdentitySuffix: [segmentIdentity, "widget:\(id)"].compactMap { $0 }.joined(separator: ":")
                                )
                            case .widget(let widget):
                                IOSGenerativeWidgetCard(
                                    widget: widget,
                                    isStreaming: liveStreaming,
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
                    markdownText(renderedMarkdown, liveStreaming: liveStreaming, cacheIdentitySuffix: segmentIdentity ?? "document")
                }
            } else {
                markdownText(renderedMarkdown, liveStreaming: liveStreaming, cacheIdentitySuffix: segmentIdentity ?? "document")
            }
    }

    private func updateTaskSegments(reconcile: Bool = false) {
        let text = renderedMarkdownText
        if reconcile || !isStreaming {
            detection.taskUI.reconcileFinalText(text)
        } else {
            detection.taskUI.update(with: text)
        }
        guard detection.taskUI.mayContainPayload else {
            if !taskSegments.isEmpty { taskSegments = [] }
            if taskPreview != nil { taskPreview = nil }
            if reconcile { detection.taskPreview.reset() }
            return
        }
        if isStreaming {
            if reconcile { detection.taskPreview.reconcile(text) }
            else { detection.taskPreview.update(with: text) }
            if detection.taskPreview.preview != taskPreview { taskPreview = detection.taskPreview.preview }
        } else {
            detection.taskPreview.reset()
            if taskPreview != nil { taskPreview = nil }
        }
        let parsed = IOSIntelligentUIProtocol.parse(text, isStreaming: isStreaming)
        let next = parsed.contains { segment in
            if case .text = segment { return false }
            return true
        } ? parsed : []
        if next != taskSegments { taskSegments = next }
    }

    private func resetTaskSource() {
        detection.taskPreview.reset()
        if taskPreview != nil { taskPreview = nil }
        if !taskSegments.isEmpty { taskSegments = [] }
        updateTaskSegments(reconcile: true)
    }

    private func taskCardIdentity(_ cardID: String) -> String {
        "\(sourceMessageID ?? renderCacheNamespace ?? "message"):text:\(sourceTextPartIndex):task:\(cardID)"
    }

    private func taskGenerationNamespace(_ index: Int) -> String {
        "\(sourceMessageID ?? renderCacheNamespace ?? "message"):text:\(sourceTextPartIndex):task:\(index)"
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
        ChatMarkdownMediaContent(text: content, isStreaming: liveStreaming) { fragment, identity in
            markdownFragment(fragment, liveStreaming: liveStreaming, config: config,
                             cacheIdentitySuffix: "\(cacheIdentitySuffix):\(identity)")
        }
    }

    @ViewBuilder
    private func markdownFragment(
        _ content: String,
        liveStreaming: Bool,
        config: SwiftStreamingMarkdown.MarkdownRenderConfig,
        cacheIdentitySuffix: String
    ) -> some View {
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

