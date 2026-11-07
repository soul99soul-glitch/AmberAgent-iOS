import SwiftUI
import SwiftStreamingMarkdown
import UIKit

private struct ChatPacesStreamingTextBlocksKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ChatIsActivelyPacingRevealKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ChatStreamingTailCoordinatorKey: EnvironmentKey {
    static let defaultValue: ChatStreamingTailCoordinator? = nil
}

extension EnvironmentValues {
    var chatPacesStreamingTextBlocks: Bool {
        get { self[ChatPacesStreamingTextBlocksKey.self] }
        set { self[ChatPacesStreamingTextBlocksKey.self] = newValue }
    }

    var chatIsActivelyPacingReveal: Bool {
        get { self[ChatIsActivelyPacingRevealKey.self] }
        set { self[ChatIsActivelyPacingRevealKey.self] = newValue }
    }

    var chatStreamingTailCoordinator: ChatStreamingTailCoordinator? {
        get { self[ChatStreamingTailCoordinatorKey.self] }
        set { self[ChatStreamingTailCoordinatorKey.self] = newValue }
    }
}

/// Coordinates direct plain-text character appends from `ChatStreamingRevealPacer`
/// into the active trailing `ParagraphUIView`, bypassing per-tick Markdown re-parsing
/// and SwiftUI subtree invalidation until a block or inline syntax boundary appears.
@MainActor
final class ChatStreamingTailCoordinator: Equatable {
    nonisolated static func == (lhs: ChatStreamingTailCoordinator, rhs: ChatStreamingTailCoordinator) -> Bool {
        lhs === rhs
    }

    private weak var sink: SwiftStreamingMarkdown.MarkdownStreamingTailSink?
    private var syncedBaseText: String?
    private var syncedUTF16Count = 0
    private var syncedEndsWithTrimmedWhitespace = false
    private var lastVerifiedSourceText: String?
    private var lastVerifiedSourceUTF16Count = 0

    nonisolated init() {}

    func bindSink(_ sink: SwiftStreamingMarkdown.MarkdownStreamingTailSink) {
        guard self.sink !== sink else { return }
        self.sink?.setGatesHeightByLineCount(false)
        self.sink = sink
        invalidateSync()
    }

    func invalidateSync() {
        syncedBaseText = nil
        syncedUTF16Count = 0
        syncedEndsWithTrimmedWhitespace = false
        lastVerifiedSourceText = nil
        lastVerifiedSourceUTF16Count = 0
    }

    func didSyncRenderedText(_ text: String) {
        if syncedBaseText == text, syncedUTF16Count >= text.utf16.count {
            return
        }
        syncedBaseText = text
        syncedUTF16Count = text.utf16.count
        if let lastUnit = text.utf16.last, lastUnit == 0x20 || lastUnit == 0x09 {
            syncedEndsWithTrimmedWhitespace = true
        } else {
            syncedEndsWithTrimmedWhitespace = false
        }
        lastVerifiedSourceText = text
        lastVerifiedSourceUTF16Count = text.utf16.count
    }

    func setGatesHeightByLineCount(_ enabled: Bool) {
        sink?.setGatesHeightByLineCount(enabled)
    }

    func tryDirectAppend(
        in fullText: String,
        from currentUTF16: Int,
        to nextUTF16: Int
    ) -> SwiftStreamingMarkdown.MarkdownStreamingTailSink.PlainTailAppendResult {
        guard currentUTF16 > 0,
              nextUTF16 > currentUTF16,
              let sink,
              syncedUTF16Count == currentUTF16,
              !syncedEndsWithTrimmedWhitespace,
              let syncedBaseText,
              !syncedBaseText.isEmpty else {
            return .notAppended
        }
        let totalUTF16 = fullText.utf16.count
        guard nextUTF16 <= totalUTF16 else { return .notAppended }

        if totalUTF16 != lastVerifiedSourceUTF16Count {
            if let previousSource = lastVerifiedSourceText,
               Self.hasUTF16Prefix(fullText, matching: previousSource, length: currentUTF16) {
                lastVerifiedSourceText = fullText
                lastVerifiedSourceUTF16Count = totalUTF16
            } else if currentUTF16 == syncedBaseText.utf16.count,
                      Self.hasUTF16Prefix(fullText, matching: syncedBaseText, length: currentUTF16) {
                lastVerifiedSourceText = fullText
                lastVerifiedSourceUTF16Count = totalUTF16
            } else {
                invalidateSync()
                return .notAppended
            }
        }

        guard sink.canDirectAppend(),
              Self.canDirectAppendSlice(in: fullText, from: currentUTF16, to: nextUTF16) else {
            return .notAppended
        }

        let nsText = fullText as NSString
        let suffix = nsText.substring(with: NSRange(location: currentUTF16, length: nextUTF16 - currentUTF16))
        // Suppress out-of-band UIKit intrinsic invalidation on line wraps: when
        // `.appendedHeightChanged` is returned, `ChatStreamingRevealPacer` advances
        // `revealedUTF16Count` so SwiftUI measures and pins `.sizeChanges` in one
        // atomic `UIUpdateCycle` layout pass.
        let result = sink.appendPlainTailWithResult(suffix, suppressIntrinsicInvalidation: true)
        guard result != .notAppended else {
            return .notAppended
        }
        syncedUTF16Count = nextUTF16
        if lastVerifiedSourceUTF16Count != totalUTF16 {
            lastVerifiedSourceText = fullText
            lastVerifiedSourceUTF16Count = totalUTF16
        }
        ChatRenderProbe.record("pacer-direct-append")
        return result
    }

    private static func hasUTF16Prefix(_ fullText: String, matching previous: String, length: Int) -> Bool {
        guard length > 0 else { return true }
        let nsFull = fullText as NSString
        let nsPrev = previous as NSString
        guard nsFull.length >= length, nsPrev.length >= length else { return false }
        if nsPrev.length == length {
            return nsFull.compare(
                previous,
                options: .literal,
                range: NSRange(location: 0, length: length)
            ) == .orderedSame
        }
        let prefixSlice = nsPrev.substring(with: NSRange(location: 0, length: length))
        return nsFull.compare(
            prefixSlice,
            options: .literal,
            range: NSRange(location: 0, length: length)
        ) == .orderedSame
    }

    static func canDirectAppendSlice(in fullText: String, from currentUTF16: Int, to nextUTF16: Int) -> Bool {
        let nsText = fullText as NSString
        let totalLength = nsText.length
        guard currentUTF16 > 0, nextUTF16 > currentUTF16, nextUTF16 <= totalLength else {
            return false
        }
        // Backslash before the slice means the next ASCII punctuation character can form an escape.
        if nsText.character(at: currentUTF16 - 1) == 0x5C {
            return false
        }

        for idx in currentUTF16..<nextUTF16 {
            let unit = nsText.character(at: idx)
            if unit < 0x20 || unit == 0x2028 || unit == 0x2029 {
                return false
            }
            switch unit {
            case 0x21, // !
                 0x23, // #
                 0x24, // $
                 0x26, // &
                 0x29, // )
                 0x2A, // *
                 0x2F, // /
                 0x3B, // ;
                 0x3C, // <
                 0x3E, // >
                 0x5B, // [
                 0x5C, // \
                 0x5D, // ]
                 0x5F, // _
                 0x60, // `
                 0x7C, // |
                 0x7E: // ~
                return false
            default:
                break
            }
        }

        var lineStart = currentUTF16
        while lineStart > 0 {
            let prev = nsText.character(at: lineStart - 1)
            if prev == 0x0A || prev == 0x0D || prev == 0x2028 || prev == 0x2029 {
                break
            }
            lineStart -= 1
        }
        guard currentUTF16 > lineStart else { return false }

        var leadingSpaces = 0
        var pos = lineStart
        while pos < currentUTF16 {
            let unit = nsText.character(at: pos)
            if unit == 0x20 {
                leadingSpaces += 1
                if leadingSpaces >= 4 {
                    return false
                }
                pos += 1
            } else if unit == 0x09 {
                return false
            } else {
                break
            }
        }
        guard pos < currentUTF16 else { return false }

        let first = nsText.character(at: pos)
        switch first {
        case 0x3E, 0x7C, 0x60, 0x7E, 0x3D:
            return false
        case 0x23:
            var hashEnd = pos
            while hashEnd < currentUTF16, hashEnd - pos < 6, nsText.character(at: hashEnd) == 0x23 {
                hashEnd += 1
            }
            guard hashEnd < currentUTF16 else { return false }
            let afterHash = nsText.character(at: hashEnd)
            guard afterHash == 0x20 || afterHash == 0x09 else {
                return true
            }
            var contentStart = hashEnd + 1
            while contentStart < currentUTF16 {
                let c = nsText.character(at: contentStart)
                if c != 0x20 && c != 0x09 {
                    return true
                }
                contentStart += 1
            }
            return false
        case 0x2D, 0x2A, 0x2B:
            var i = pos + 1
            while i < currentUTF16 {
                let c = nsText.character(at: i)
                if c != first && c != 0x20 && c != 0x09 {
                    return true
                }
                i += 1
            }
            return false
        case 0x30...0x39:
            var digitEnd = pos
            while digitEnd < currentUTF16, digitEnd - pos < 10 {
                let c = nsText.character(at: digitEnd)
                if c >= 0x30 && c <= 0x39 {
                    digitEnd += 1
                } else {
                    break
                }
            }
            if digitEnd == currentUTF16 {
                return (currentUTF16 - pos) > 9
            }
            let delim = nsText.character(at: digitEnd)
            if (delim == 0x2E || delim == 0x29), digitEnd - pos <= 9 {
                let afterDelimIndex = digitEnd + 1
                guard afterDelimIndex < currentUTF16 else { return false }
                let afterDelim = nsText.character(at: afterDelimIndex)
                if afterDelim != 0x20 && afterDelim != 0x09 {
                    return true
                }
                var contentPos = afterDelimIndex + 1
                while contentPos < currentUTF16 {
                    let c = nsText.character(at: contentPos)
                    if c != 0x20 && c != 0x09 {
                        return true
                    }
                    contentPos += 1
                }
                return false
            }
            return true
        default:
            return true
        }
    }
}

/// A subtree publishes only pending/settled transitions, never per-frame text or offsets.
struct ChatStreamingRevealProgress: Equatable {
    var isMounted = false
    var hasPendingReveal = false
}

struct ChatStreamingRevealProgressKey: PreferenceKey {
    static let defaultValue = ChatStreamingRevealProgress()

    static func reduce(value: inout ChatStreamingRevealProgress, nextValue: () -> ChatStreamingRevealProgress) {
        let next = nextValue()
        value.isMounted = value.isMounted || next.isMounted
        value.hasPendingReveal = value.hasPendingReveal || next.hasPendingReveal
    }
}

/// A value writer keeps an unchanged pending flag stable through token updates.
/// A background sibling merges with descendant writers via the key's OR reduce.
struct ChatStreamingRevealProgressModifier: ViewModifier {
    let progress: ChatStreamingRevealProgress

    func body(content: Content) -> some View {
        content.background {
            Color.clear.frame(width: 0, height: 0)
                .preference(key: ChatStreamingRevealProgressKey.self, value: progress)
                .accessibilityHidden(true)
        }
    }
}

/// 流式正文的平滑吐字器 + 平滑高度。
///
/// 三个问题一起解决：
///
/// 1. **文字逐字连续吐出**：上游 delta 成块到达，直接整块上屏会一次撑高多行。
///    这里按帧小步推进已显示字数，文字以正常字色连续出现。
///
/// 2. **流式结束时绝不一次性刷出剩余文字**：网络流关闭后仍按节奏吐到追平全文
///    再落到静态终态，避免尾部突然冒出一大段。
///
/// 3. **消除折行时的高度阶梯跳变**：文本换行会让布局高度单帧 +一整行（约 22pt），
///    这是排版固有属性、无法靠逐字插值消除。所以给气泡占位高度加一层平滑：
///    内容仍按自然高度排版（`fixedSize` 垂直方向不管提议），外层只显示
///    `displayedHeight` 这么高（`alignment: .top` + `clipped`），并在内容长高时
///    用短促线性动画把 `displayedHeight` 推上去。
///
///    每帧只长高一点点，配合底部锚点（`.sizeChanges` 或原生贴底）同帧上移同样的量：
///    底边不动，已有文字与上方历史平滑上浮，新增的一行从底边缓缓露出，
///    而不是整屏 0ms 瞬移一行。
// Native timeline supplies a growth owner: the layout remains natural-sized and
// the content layer performs the same 0.14s movement. Other hosts keep the
// existing local-height transition until they opt into that owner.
struct ChatStreamingRevealPacer<Content: View>: View {
    /// 上游已到达的全部文本。
    let text: String
    /// 是否仍在流式接收。
    let isStreaming: Bool
    /// 无障碍「减弱动态效果」：不做逐字推进，也不做高度过渡。
    let reduceMotion: Bool
    /// 远滚冻结时暂停离屏逐字推进并对齐当前可见前缀，保持冻结快照与高度稳定。
    let liveRenderingEnabled: Bool
    /// 分块前已显示的正文保持原样；新尾块即使随最终快照到达也需排空。
    private let initiallyRevealedUTF16Count: Int?
    private let completionFeedback: ChatCompletionFeedback?
    private let completionRunID: String?
    private let messageID: String?
    private let textPartIndex: Int
    @ViewBuilder let content: (String, Bool) -> Content

    @Environment(\.chatTimelineGrowth) private var timelineGrowth
    @State private var revealedUTF16Count = 0
    /// 是否处于需要逐字推进或收尾排空的会话期。
    /// 历史非流式行在 `init` 时直接为 `false`，首帧即直接渲染完整 `text`，
    /// 绝不经过「先挂空串 `""` 再在 `onAppear` 二次刷全文」的双渲染路径。
    @State private var isActivelyPacing: Bool
    /// 锁定本 pacer 所属的 runID，防止同会话并发新任务覆盖当前回复的完成反馈归属。
    @State private var latchedCompletionRunID: String?
    /// 内容自然高度（不含裁剪）。
    @State private var contentHeight: CGFloat = 0
    /// 当前实际占位高度：朝 `contentHeight` 平滑逼近。
    @State private var displayedHeight: CGFloat = 0
    /// 增量维护的表格检测器：避免在 `body` 中产生状态写回或全量扫描。
    @State private var pacerBox = ChatStreamingRevealPacerBox()

    init(
        text: String,
        isStreaming: Bool,
        reduceMotion: Bool,
        liveRenderingEnabled: Bool = true,
        initiallyRevealedUTF16Count: Int? = nil,
        pacePendingText: Bool = false,
        completionFeedback: ChatCompletionFeedback? = nil,
        messageID: String? = nil,
        textPartIndex: Int = 0,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.init(
            text: text,
            isStreaming: isStreaming,
            reduceMotion: reduceMotion,
            liveRenderingEnabled: liveRenderingEnabled,
            initiallyRevealedUTF16Count: initiallyRevealedUTF16Count,
            pacePendingText: pacePendingText,
            completionFeedback: completionFeedback,
            messageID: messageID,
            textPartIndex: textPartIndex,
            content: { revealedText, _ in content(revealedText) }
        )
    }

    init(
        text: String,
        isStreaming: Bool,
        reduceMotion: Bool,
        liveRenderingEnabled: Bool = true,
        initiallyRevealedUTF16Count: Int? = nil,
        pacePendingText: Bool = false,
        completionFeedback: ChatCompletionFeedback? = nil,
        messageID: String? = nil,
        textPartIndex: Int = 0,
        @ViewBuilder content: @escaping (String, Bool) -> Content
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.reduceMotion = reduceMotion
        self.liveRenderingEnabled = liveRenderingEnabled
        self.initiallyRevealedUTF16Count = initiallyRevealedUTF16Count
        self.completionFeedback = completionFeedback
        let resolvedRunID = completionFeedback?.runID(forMessageID: messageID) ?? completionFeedback?.untrackedCurrentRunID()
        self.completionRunID = resolvedRunID
        self.messageID = messageID
        self.textPartIndex = textPartIndex
        self.content = content
        let initialUTF16 = initiallyRevealedUTF16Count ?? 0
        self._revealedUTF16Count = State(initialValue: initialUTF16)
        let initialPacing = (isStreaming || pacePendingText) && !reduceMotion
        self._isActivelyPacing = State(initialValue: initialPacing)
        self._latchedCompletionRunID = State(initialValue: resolvedRunID)
        self._pacerBox = State(initialValue: ChatStreamingRevealPacerBox(initialUTF16Count: initialUTF16))
    }

    /// 是否仍按帧吐字。流式结束后若还有尾巴没吐完，继续按同一节奏吐。
    private var isPacing: Bool { isStreaming && !reduceMotion }

    var body: some View {
        let activePacing = !reduceMotion && (isStreaming || isActivelyPacing)
        // Markdown 表格在 `ChatStreamingBlockMarkdownView` 内部已有稳定前缀 + 尾部节流分块策略；
        // 若外层再按 60fps 逐字切片并对整张 `TableView` 施加 `.frame(height: displayedHeight)` 动画，
        // 会导致数百个单元格每 16ms 触发多遍 `TableLayout` 与滚动几何反馈环（单帧卡死 200-330ms）。
        let bypassPacingForTable = activePacing && pacerBox.containsTable(in: text)
        let effectiveRevealedUTF16 = liveRenderingEnabled
            ? revealedUTF16Count
            : max(revealedUTF16Count, pacerBox.currentUTF16Count)
        let localPendingReveal = activePacing && !bypassPacingForTable && (effectiveRevealedUTF16 < text.utf16.count || isActivelyPacing)
        let hasPendingReveal = isStreaming || localPendingReveal
        let isActivelyRevealing = isStreaming || localPendingReveal
        let displayedText: String
        let heightTransitionActive: Bool
        if activePacing && !bypassPacingForTable {
            let totalUTF16 = text.utf16.count
            let clampedUTF16 = min(max(0, effectiveRevealedUTF16), totalUTF16)
            if clampedUTF16 < totalUTF16 {
                displayedText = ChatStreamingRevealTiming.slicedPrefix(of: text, utf16Count: clampedUTF16)
            } else {
                displayedText = text
            }
            heightTransitionActive = liveRenderingEnabled && (clampedUTF16 < totalUTF16 || isStreaming || isActivelyPacing)
        } else {
            displayedText = text
            heightTransitionActive = false
        }
        let observesTimelineTableGrowth = timelineGrowth != nil && initiallyRevealedUTF16Count == nil && bypassPacingForTable
        let observesGeometry = (activePacing && !bypassPacingForTable) || observesTimelineTableGrowth

        return content(displayedText, isActivelyRevealing)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                observesGeometry ? proxy.size.height : 0
            } action: { height in
                guard observesGeometry else { return }
                if let timelineGrowth {
                    // 当外层 pacer 已接管含表格整块的 timelineGrowth 观测时，内层分块 pacer 不重复累加。
                    guard initiallyRevealedUTF16Count == nil else { return }
                    #if DEBUG
                    ChatRenderProbe.record("pacer-native-height")
                    #endif
                    let previous = pacerBox.naturalHeight
                    pacerBox.naturalHeight = height
                    // A remounted live row already contains visible text. Its first
                    // measurement establishes the baseline, not new content growth.
                    let shouldGrowTimeline = heightTransitionActive || observesTimelineTableGrowth
                    if shouldGrowTimeline && previous > 0 && height > previous {
                        pacerBox.lastGrowthUptime = ProcessInfo.processInfo.systemUptime
                        timelineGrowth.contentGrew(by: height - previous)
                    }
                    return
                }
                let isFirstMeasurement = contentHeight == 0
                if !isFirstMeasurement && height > contentHeight {
                    pacerBox.lastGrowthUptime = ProcessInfo.processInfo.systemUptime
                }
                contentHeight = height
                if isFirstMeasurement,
                   initiallyRevealedUTF16Count != nil,
                   revealedUTF16Count >= text.utf16.count {
                    displayedHeight = height
                } else {
                    syncDisplayedHeight(heightTransitionActive: heightTransitionActive)
                }
            }
            .frame(
                height: timelineGrowth == nil && heightTransitionActive && (initiallyRevealedUTF16Count == nil || contentHeight > 0 || revealedUTF16Count < text.utf16.count)
                    ? displayedHeight : nil,
                alignment: .top
            )
            .clipped()
            .environment(\.chatPacesStreamingTextBlocks, bypassPacingForTable)
            .environment(\.chatIsActivelyPacingReveal, isActivelyRevealing)
            .environment(\.chatStreamingTailCoordinator, activePacing && liveRenderingEnabled && !bypassPacingForTable ? pacerBox.tailCoordinator : nil)
            .modifier(ChatStreamingRevealProgressModifier(progress: .init(
                isMounted: true, hasPendingReveal: hasPendingReveal)))
            .onPreferenceChange(ChatStreamingRevealProgressKey.self) { progress in
                guard progress.isMounted, !progress.hasPendingReveal,
                      let messageID else { return }
                let resolvedRunID = completionFeedback?.runID(forMessageID: messageID)
                    ?? latchedCompletionRunID
                    ?? completionRunID
                    ?? completionFeedback?.untrackedCurrentRunID()
                guard let resolvedRunID else { return }
                completionFeedback?.didDrain(
                    runID: resolvedRunID, messageID: messageID, partIndex: textPartIndex, text: text
                )
            }
            .onAppear {
                if latchedCompletionRunID == nil {
                    latchedCompletionRunID = completionFeedback?.runID(forMessageID: messageID) ?? completionRunID ?? completionFeedback?.untrackedCurrentRunID()
                }
                guard isPacing, revealedUTF16Count == 0 else { return }
                guard initiallyRevealedUTF16Count == nil else { return }
                if pacerBox.containsTable(in: text) {
                    let fullCount = text.utf16.count
                    pacerBox.currentUTF16Count = fullCount
                    revealedUTF16Count = fullCount
                    return
                }
                // 流式中途重进入：只补尾部，不要把已有正文整段重打。
                let startOffset = ChatStreamingRevealTiming.reentryStartUTF16Offset(
                    in: text,
                    tailCharacterBudget: ChatStreamingRevealTiming.reentryTailBudget
                )
                pacerBox.currentUTF16Count = startOffset
                revealedUTF16Count = startOffset
                displayedHeight = contentHeight
                isActivelyPacing = true
            }
            .onChange(of: completionRunID) { _, newValue in
                if let newValue, isStreaming || latchedCompletionRunID == nil {
                    latchedCompletionRunID = newValue
                }
            }
            .onChange(of: liveRenderingEnabled) { _, enabled in
                if !enabled {
                    pacerBox.lastTickUptime = nil
                    pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
                    let synced = min(pacerBox.currentUTF16Count, text.utf16.count)
                    if revealedUTF16Count != synced {
                        revealedUTF16Count = synced
                    }
                } else if isPacing, !pacerBox.containsTable(in: text) {
                    let floorOffset = ChatStreamingRevealTiming.reentryStartUTF16Offset(
                        in: text,
                        tailCharacterBudget: ChatStreamingRevealTiming.reentryTailBudget
                    )
                    if pacerBox.currentUTF16Count < floorOffset {
                        pacerBox.currentUTF16Count = floorOffset
                        pacerBox.tailCoordinator.invalidateSync()
                        revealedUTF16Count = floorOffset
                    }
                }
            }
            .task(
                id: PacingKey(
                    targetUTF16Count: activePacing && !bypassPacingForTable ? text.utf16.count : 0,
                    isStreaming: isStreaming,
                    reduceMotion: reduceMotion,
                    liveRenderingEnabled: liveRenderingEnabled
                )
            ) {
                await drain()
            }
    }

    /// 内容长高时把占位高度平滑推上去；缩短（收口）直接跟上，避免留白。
    private func syncDisplayedHeight(heightTransitionActive: Bool) {
        guard heightTransitionActive else {
            if displayedHeight != contentHeight {
                displayedHeight = contentHeight
            }
            return
        }
        guard contentHeight > displayedHeight else {
            if displayedHeight != contentHeight {
                displayedHeight = contentHeight
            }
            return
        }
        withAnimation(.linear(duration: ChatStreamingRevealTiming.heightSettleSeconds)) {
            displayedHeight = contentHeight
        }
    }

    /// 小步推进直到追平全文。全程同一节奏：流式结束后不提速、不一次性刷出。
    private func drain() async {
        guard !reduceMotion else {
            pacerBox.lastTickUptime = nil
            pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
            if isActivelyPacing { isActivelyPacing = false }
            return
        }
        guard isStreaming || isActivelyPacing else {
            pacerBox.lastTickUptime = nil
            pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
            return
        }
        guard liveRenderingEnabled else {
            pacerBox.lastTickUptime = nil
            pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
            let synced = min(pacerBox.currentUTF16Count, text.utf16.count)
            if revealedUTF16Count != synced {
                revealedUTF16Count = synced
            }
            return
        }
        if pacerBox.containsTable(in: text) {
            pacerBox.lastTickUptime = nil
            pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
            pacerBox.tailCoordinator.invalidateSync()
            let fullCount = text.utf16.count
            pacerBox.currentUTF16Count = fullCount
            revealedUTF16Count = fullCount
            // 分块子树持有各正文尾块的排空状态。完成事件后仍保留委托，
            // 包括只随最终快照新增的正文，不能拆掉其 pacer 后一次性露出全文。
            return
        }
        if isStreaming && !isActivelyPacing {
            isActivelyPacing = true
        }
        let totalUTF16 = text.utf16.count
        if pacerBox.currentUTF16Count > totalUTF16 {
            pacerBox.currentUTF16Count = min(revealedUTF16Count, totalUTF16)
            pacerBox.tailCoordinator.invalidateSync()
        } else if pacerBox.currentUTF16Count < revealedUTF16Count {
            pacerBox.currentUTF16Count = min(revealedUTF16Count, totalUTF16)
        }
        guard pacerBox.currentUTF16Count < totalUTF16 else {
            pacerBox.lastTickUptime = nil
            if !isStreaming {
                pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
            }
            if revealedUTF16Count != totalUTF16 {
                revealedUTF16Count = totalUTF16
            }
            await settleTailGrowthIfNeeded(totalUTF16: totalUTF16)
            return
        }
        let tickSeconds = Double(ChatStreamingRevealTiming.tickNanos) / 1_000_000_000
        let maxCatchUpTicks = ChatStreamingRevealTiming.maxCatchUpTicksPerWake
        let maxCreditWindow = Double(maxCatchUpTicks) * tickSeconds
        while !Task.isCancelled, pacerBox.currentUTF16Count < totalUTF16 {
            let now = ProcessInfo.processInfo.systemUptime
            let stepsToAdvance: Int
            if let lastTick = pacerBox.lastTickUptime {
                let elapsed = now - lastTick
                if elapsed < tickSeconds {
                    let remainingNanos = UInt64(max(1, (tickSeconds - elapsed) * 1_000_000_000))
                    try? await Task.sleep(nanoseconds: remainingNanos)
                    guard !Task.isCancelled else { return }
                }
                let wakeUptime = ProcessInfo.processInfo.systemUptime
                let totalElapsed = max(0, wakeUptime - lastTick)
                let dueTicks = max(1, Int(totalElapsed / tickSeconds))
                stepsToAdvance = min(maxCatchUpTicks, dueTicks)
                let advancedSeconds = Double(stepsToAdvance) * tickSeconds
                pacerBox.lastTickUptime = max(lastTick + advancedSeconds, wakeUptime - maxCreditWindow)
            } else {
                stepsToAdvance = 1
                pacerBox.lastTickUptime = now
            }

            let currentUTF16 = pacerBox.currentUTF16Count
            var nextUTF16 = currentUTF16
            for _ in 0..<stepsToAdvance {
                guard nextUTF16 < totalUTF16 else { break }
                let candidate = ChatStreamingRevealTiming.nextStepUTF16Offset(
                    in: text,
                    fromUTF16Offset: nextUTF16
                )
                if candidate <= nextUTF16 {
                    nextUTF16 = totalUTF16
                    break
                }
                nextUTF16 = min(candidate, totalUTF16)
            }
            let caughtUpToCurrentTarget = nextUTF16 >= totalUTF16
            let reachedTerminalEnd = !isStreaming && caughtUpToCurrentTarget
            let appendResult = pacerBox.tailCoordinator.tryDirectAppend(
                in: text,
                from: currentUTF16,
                to: nextUTF16
            )
            pacerBox.currentUTF16Count = nextUTF16
            if reachedTerminalEnd {
                pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
            }
            if caughtUpToCurrentTarget || appendResult != .appendedSameLine {
                if revealedUTF16Count != nextUTF16 {
                    revealedUTF16Count = nextUTF16
                }
            }
            ChatRenderProbe.record("pacer-tick")
            if pacerBox.currentUTF16Count >= totalUTF16 {
                pacerBox.lastTickUptime = nil
                break
            }
            try? await Task.sleep(nanoseconds: ChatStreamingRevealTiming.tickNanos)
        }
        await settleTailGrowthIfNeeded(totalUTF16: totalUTF16)
    }

    private func settleTailGrowthIfNeeded(totalUTF16: Int) async {
        guard !Task.isCancelled, !isStreaming, pacerBox.currentUTF16Count >= totalUTF16, isActivelyPacing else {
            return
        }
        pacerBox.lastTickUptime = nil
        pacerBox.tailCoordinator.setGatesHeightByLineCount(false)
        if revealedUTF16Count != totalUTF16 {
            revealedUTF16Count = totalUTF16
        }
        if let lastGrowth = pacerBox.lastGrowthUptime {
            let remaining = ChatStreamingRevealTiming.heightSettleSeconds - (ProcessInfo.processInfo.systemUptime - lastGrowth)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        guard !Task.isCancelled, !isStreaming, pacerBox.currentUTF16Count >= text.utf16.count else { return }
        isActivelyPacing = false
    }

    private struct PacingKey: Equatable {
        let targetUTF16Count: Int
        let isStreaming: Bool
        let reduceMotion: Bool
        let liveRenderingEnabled: Bool
    }
}

private final class ChatStreamingRevealPacerBox {
    var naturalHeight: CGFloat = 0
    var currentUTF16Count: Int
    var lastTickUptime: TimeInterval?
    var lastGrowthUptime: TimeInterval?
    let tailCoordinator = ChatStreamingTailCoordinator()
    private var tableDetector = ChatStreamingTableDetectionState()

    init(initialUTF16Count: Int = 0) {
        self.currentUTF16Count = initialUTF16Count
    }

    func containsTable(in text: String) -> Bool {
        tableDetector.update(with: text)
        return tableDetector.containsTable
    }
}

/// pacer 的调节参数。放在非泛型类型里：Swift 不允许泛型类型持有静态存储属性。
enum ChatStreamingRevealTiming {
    /// 约 60fps 一拍。
    static let tickNanos: UInt64 = 16_000_000
    /// 主线程掉帧导致单次唤醒跨多拍时，单次唤醒最多补拍的逻辑拍数上限。
    static let maxCatchUpTicksPerWake = 4
    /// 高度增长的过渡时长：短到不拖沓，长到足以盖住单帧一整行的台阶。
    static let heightSettleSeconds: Double = 0.14
    /// 中途重进入时只补齐尾部这么多个字，避免把已有正文整段重打。
    static let reentryTailBudget = 40
    /// 每拍推进上限。固定值：流式期与收尾期一致，不做收尾提速。
    static let maxStepPerTick = 4

    /// 单拍推进字数：积压越多步长越大，但上限恒为 `maxStepPerTick`。
    /// 供单测锁住「收尾不提速」这条契约。
    static func step(remaining: Int, maxStep: Int = maxStepPerTick) -> Int {
        guard remaining > 0 else { return 0 }
        return min(max(remaining / 6, 1), maxStep)
    }

    /// O(1) UTF-16 索引切片并对齐到完整字素簇边界，避免每帧 `text.prefix(count)` 从头 O(n) 扫描全文。
    static func slicedPrefix(of text: String, utf16Count: Int) -> String {
        let totalUTF16 = text.utf16.count
        guard utf16Count > 0 else { return "" }
        guard utf16Count < totalUTF16 else { return text }
        let rawIndex = String.Index(utf16Offset: utf16Count, in: text)
        let alignedIndex = rawIndex < text.endIndex
            ? text.rangeOfComposedCharacterSequence(at: rawIndex).lowerBound
            : text.endIndex
        return String(text[..<alignedIndex])
    }

    /// 中途重进入时从尾部往回数 `tailCharacterBudget` 个字，时间复杂度 O(tailCharacterBudget) 常数级。
    static func reentryStartUTF16Offset(in text: String, tailCharacterBudget: Int) -> Int {
        guard tailCharacterBudget > 0, !text.isEmpty else { return text.utf16.count }
        var index = text.endIndex
        var remaining = tailCharacterBudget
        while remaining > 0, index > text.startIndex {
            index = text.index(before: index)
            remaining -= 1
        }
        return index.utf16Offset(in: text)
    }

    /// 基于当前 UTF-16 偏移向前最多探查 `maxStepPerTick * 6`（24）个字素簇，
    /// 既保持与 `step(remaining:)` 完全一致的吐字步长，又将每帧推进从 O(n) 降为 O(1)。
    static func nextStepUTF16Offset(
        in text: String,
        fromUTF16Offset currentUTF16: Int,
        maxStep: Int = maxStepPerTick
    ) -> Int {
        let totalUTF16 = text.utf16.count
        let clamped = min(max(0, currentUTF16), totalUTF16)
        guard clamped < totalUTF16 else { return totalUTF16 }
        let rawStart = String.Index(utf16Offset: clamped, in: text)
        let startIndex = rawStart < text.endIndex
            ? text.rangeOfComposedCharacterSequence(at: rawStart).lowerBound
            : text.endIndex
        guard startIndex < text.endIndex else { return totalUTF16 }

        let lookaheadCap = max(maxStep * 6, 1)
        var probe = startIndex
        var lookaheadCount = 0
        var stepIndices: [String.Index] = []
        stepIndices.reserveCapacity(maxStep)

        while probe < text.endIndex, lookaheadCount < lookaheadCap {
            probe = text.index(after: probe)
            lookaheadCount += 1
            if lookaheadCount <= maxStep {
                stepIndices.append(probe)
            }
        }

        let chosenStep = step(remaining: lookaheadCount, maxStep: maxStep)
        guard chosenStep > 0, !stepIndices.isEmpty else { return totalUTF16 }
        let targetIndex = stepIndices[min(chosenStep, stepIndices.count) - 1]
        return targetIndex.utf16Offset(in: text)
    }
}

/// Keeps the streaming subtree's graph updates local; the surrounding timeline
/// receives only a changed natural height. Non-native and settled history keep
/// their existing hosting path.
struct ChatStreamingGraphBoundary<Content: View>: View {
    let isStreaming: Bool
    var messageID: String = ""
    var contentKey: Int? = nil
    let content: Content
    @State private var didStream: Bool
    @Environment(\.chatTimelineGrowth) private var growth

    init(
        isStreaming: Bool,
        messageID: String = "",
        contentKey: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isStreaming = isStreaming
        self.messageID = messageID
        self.contentKey = contentKey
        self.content = content()
        _didStream = State(initialValue: isStreaming)
    }

    var body: some View {
        Group {
            if growth != nil && didStream {
                ChatStreamingGraphHost(
                    isStreaming: isStreaming,
                    messageID: messageID,
                    contentKey: contentKey,
                    content: content
                )
            } else {
                content
            }
        }
        .onChange(of: isStreaming) { _, active in
            if active && !didStream { didStream = true }
        }
    }
}

private struct ChatStreamingGraphHost<Content: View>: UIViewControllerRepresentable {
    let isStreaming: Bool
    let messageID: String
    let contentKey: Int?
    let content: Content

    struct HostEnvironmentKey: Equatable {
        let reduceMotion: Bool
        let locale: Locale
        let artifactMessageID: String?
        let layoutInvalidationID: String?
        let fontScale: Double
        let chatFont: String
        let agentName: Bool
        let appLanguage: String

        @MainActor
        init(_ env: EnvironmentValues) {
            let prefs = IOSChatRenderPreferences.shared
            reduceMotion = env.accessibilityReduceMotion
            locale = env.locale
            artifactMessageID = env.chatArtifactMessageID
            layoutInvalidationID = env.markdownLayoutInvalidationID
            fontScale = prefs.fontScale
            chatFont = prefs.chatFont
            agentName = prefs.agentName
            appLanguage = prefs.appLanguage
        }
    }

    struct Root: View {
        let content: Content
        let environment: EnvironmentValues
        let heightChanged: (CGFloat) -> Void

        var body: some View {
            let _ = ChatRenderProbe.record("graph-host-root")
            content
                .environment(\.self, environment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
        }
    }

    final class SizedView: UIView {
        var height: CGFloat = 0
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: height)
        }
    }

    final class Controller: UIViewController {
        var host: UIHostingController<Root>!
        var messageID: String
        private var lastIsStreaming: Bool
        private var lastContentKey: Int?
        private var lastEnvKey: HostEnvironmentKey
        private var measuredWidth: CGFloat?
        private var hasMeasured = false
        private var sizedView: SizedView { view as! SizedView }

        init(
            content: Content,
            environment: EnvironmentValues,
            isStreaming: Bool,
            messageID: String,
            contentKey: Int?,
            envKey: HostEnvironmentKey
        ) {
            self.messageID = messageID
            self.lastIsStreaming = isStreaming
            self.lastContentKey = contentKey
            self.lastEnvKey = envKey
            super.init(nibName: nil, bundle: nil)
            ChatRenderProbe.record("graph-host-created")
            host = UIHostingController(rootView: root(content, environment: environment))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { ChatRenderProbe.record("graph-host-released") }
        override func loadView() { view = SizedView() }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.view.frame = view.bounds
        }
        func root(_ content: Content, environment: EnvironmentValues) -> Root {
            Root(content: content, environment: environment, heightChanged: { [weak self] height in
                guard let self, height.isFinite, height >= 0,
                      abs(sizedView.height - height) > 0.5 else { return }
                sizedView.height = height
                if !messageID.isEmpty {
                    ChatTimelineRowLayoutInvalidation.markRowDirty(messageID)
                }
                sizedView.invalidateIntrinsicContentSize()
                sizedView.setNeedsLayout()
            })
        }
        func shouldUpdate(
            isStreaming: Bool,
            contentKey: Int?,
            envKey: HostEnvironmentKey
        ) -> Bool {
            if let contentKey, let lastContentKey {
                return isStreaming != lastIsStreaming ||
                    contentKey != lastContentKey ||
                    envKey != lastEnvKey
            }
            if !isStreaming && !lastIsStreaming && envKey == lastEnvKey {
                return false
            }
            return true
        }
        func update(
            _ content: Content,
            environment: EnvironmentValues,
            isStreaming: Bool,
            messageID: String,
            contentKey: Int?,
            envKey: HostEnvironmentKey
        ) {
            self.messageID = messageID
            self.lastIsStreaming = isStreaming
            self.lastContentKey = contentKey
            self.lastEnvKey = envKey
            host.rootView = root(content, environment: environment)
        }
        func size(width: CGFloat) -> CGSize {
            if !hasMeasured || measuredWidth.map({ abs($0 - width) > 0.5 }) == true {
                measuredWidth = width
                let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                sizedView.height = size.height
                hasMeasured = true
            }
            return CGSize(width: width, height: sizedView.height)
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let envKey = HostEnvironmentKey(context.environment)
        return Controller(
            content: content,
            environment: context.environment,
            isStreaming: isStreaming,
            messageID: messageID,
            contentKey: contentKey,
            envKey: envKey
        )
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        let envKey = HostEnvironmentKey(context.environment)
        guard controller.shouldUpdate(
            isStreaming: isStreaming,
            contentKey: contentKey,
            envKey: envKey
        ) else {
            return
        }
        ChatRenderProbe.record("graph-host-update")
        controller.update(
            content,
            environment: context.environment,
            isStreaming: isStreaming,
            messageID: messageID,
            contentKey: contentKey,
            envKey: envKey
        )
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return uiViewController.size(width: width)
    }
}
