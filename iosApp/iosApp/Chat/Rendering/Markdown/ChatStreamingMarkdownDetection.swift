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

    private var processedUTF8Count = 0
    private var checkpoint: [UInt8] = []
    private var pendingLineBytes: [UInt8] = []
    private var previousHeaderColumnCount: Int?
    private var fenceState = ChatStreamingMarkdownFenceState()
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

