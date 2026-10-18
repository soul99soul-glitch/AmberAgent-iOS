import SwiftUI
import Shared
import SwiftStreamingMarkdown

struct ChatStableStreamingMarkdownView: View {
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

