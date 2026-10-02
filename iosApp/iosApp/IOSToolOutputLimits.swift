import Foundation

enum IOSToolOutputLimits {
    /// 单次工具输出（search_web 格式化结果 / scrape_web JSON / 漏斗文本）总上限。
    static let maxOutputChars = 12_000
    /// 搜索结果单条 snippet 上限。
    static let maxSnippetChars = 1_200
    /// 与 IOSContextCompactionCoordinator.compactedToolOutputMarker 同文的压缩占位
    /// 标记（压缩处理过的输出豁免收口截断，避免二次截断）。
    static let compactedToolOutputMarker = "[tool output compacted]"
    /// 截断标记：`\n…[truncated N chars]`
    static func truncationMarker(droppedChars: Int) -> String {
        "\n…[truncated \(droppedChars) chars]"
    }
}

