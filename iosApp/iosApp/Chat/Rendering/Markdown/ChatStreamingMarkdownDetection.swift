import SwiftUI
import Shared
import SwiftStreamingMarkdown

/// 表格/widget 增量探测器的引用盒。
/// `ChatAssistantMarkdownView` 的 body 不读取盒内字段(只读显式的 latch @State),
/// 因此每个 chunk 的增量消费不触发 SwiftUI 失效。新增探测器时保持这个约束。
@MainActor
final class ChatStreamingDetectionBox {
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
    var taskUI = IOSIntelligentUIPayloadDetector()
    var taskPreview = IOSIntelligentUIStreamingPreviewScanner()
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

struct ChatStreamingTableDetectionState {
    private static let checkpointLength = 32

    private var processedUTF16Count = 0
    private var checkpointUTF16: [UInt16] = []
    private var pendingLineBytes: [UInt8] = []
    private var previousHeaderColumnCount: Int?
    private var fenceState = ChatStreamingMarkdownFenceState()
    private var lastCheckedText: String?
    private(set) var containsTable = false
    // Tail checkpoints cannot prove that the earlier prefix is unchanged.
    // Resolve output flags only when consumed, from the complete current text.
    var containsCarriageReturn: Bool { lastCheckedText?.utf8.contains(0x0D) ?? false }
    var hasNonWhitespace: Bool { lastCheckedText?.contains(where: { !$0.isWhitespace }) ?? false }
    private(set) var totalConsumedUTF8Count = 0

    init(text: String = "") {
        if !text.isEmpty {
            update(with: text)
        }
    }

    mutating func update(with text: String) {
        if lastCheckedText == text {
            return
        }
        lastCheckedText = text
        guard !containsTable else { return }

        let ns = text as NSString
        let utf16Count = ns.length
        let matches = checkpointMatches(in: ns)
        guard utf16Count != processedUTF16Count || !matches else { return }

        if utf16Count < processedUTF16Count || !matches {
            resetParserState()
        }

        let appended = processedUTF16Count == 0 ? text : ns.substring(from: processedUTF16Count)
        for byte in appended.utf8 {
            totalConsumedUTF8Count += 1
            if byte == 0x0A {
                processCompletedLine()
                pendingLineBytes.removeAll(keepingCapacity: true)
            } else {
                pendingLineBytes.append(byte)
            }
            if containsTable { break }
        }
        processedUTF16Count = utf16Count
        let length = min(utf16Count, Self.checkpointLength)
        checkpointUTF16 = Self.codeUnits(
            in: ns,
            range: NSRange(location: utf16Count - length, length: length)
        )
        evaluatePendingDelimiter()
    }

    private func checkpointMatches(in ns: NSString) -> Bool {
        guard processedUTF16Count > 0 else { return true }
        let count = checkpointUTF16.count
        guard processedUTF16Count <= ns.length, count <= processedUTF16Count else { return false }
        if let last = checkpointUTF16.last, (0xD800...0xDBFF).contains(last) { return false }
        guard count > 0 else { return true }
        let range = NSRange(location: processedUTF16Count - count, length: count)
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: count) { buffer in
            ns.getCharacters(buffer.baseAddress!, range: range)
            return buffer.elementsEqual(checkpointUTF16)
        }
    }

    private static func codeUnits(in ns: NSString, range: NSRange) -> [UInt16] {
        guard range.length > 0 else { return [] }
        return [UInt16](unsafeUninitializedCapacity: range.length) { buffer, initializedCount in
            ns.getCharacters(buffer.baseAddress!, range: range)
            initializedCount = range.length
        }
    }

    private mutating func resetParserState() {
        processedUTF16Count = 0
        checkpointUTF16.removeAll(keepingCapacity: true)
        pendingLineBytes.removeAll(keepingCapacity: true)
        previousHeaderColumnCount = nil
        fenceState = ChatStreamingMarkdownFenceState()
        containsTable = false
    }

    private mutating func processCompletedLine() {
        if pendingLineBytes.last == 0x0D {
            pendingLineBytes.removeLast()
        }
        let line = String(decoding: pendingLineBytes, as: UTF8.self)
        if fenceState.consumesCodeLine(line) {
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
              !fenceState.isInsideFence,
              let expectedCount = previousHeaderColumnCount else { return }
        let line = String(decoding: pendingLineBytes, as: UTF8.self)
        if ChatStreamingMarkdownBlockParser.isDelimiterLineForDetection(
            line,
            expectedCount: expectedCount
        ) {
            containsTable = true
        }
    }
}

#if DEBUG
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

