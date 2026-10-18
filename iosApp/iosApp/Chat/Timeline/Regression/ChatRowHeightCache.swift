import SwiftUI
import UIKit
import Shared
import ChatLayout
import Combine

private final class ChatRowHeightCache {
    private var heights: [String: CGFloat] = [:]
    /// 每个 item 的最近一次实测高度(按宽度),签名失效后作为估算兜底:
    /// 旧实测顶多差一两行,110 默认估算对巨型消息会差几千 pt,
    /// 造成 contentSize 塌陷(完成后大片空白/上滑跳没的根因)。
    private var latestHeights: [String: (width: CGFloat, height: CGFloat)] = [:]

    func height(for itemID: String, signature: String?, width: CGFloat) -> CGFloat? {
        if let exact = heights[key(itemID: itemID, signature: signature, width: width)] {
            return exact
        }
        if let latest = latestHeights[itemID],
           abs(latest.width - width) <= 80 {
            return latest.height
        }
        return nil
    }

    func exactHeight(for itemID: String, signature: String?, width: CGFloat) -> CGFloat? {
        heights[key(itemID: itemID, signature: signature, width: width)]
    }

    @discardableResult
    func set(
        height: CGFloat,
        for itemID: String,
        signature: String?,
        width: CGFloat,
        monotonic: Bool = false
    ) -> CGFloat {
        guard height > 0 else { return height }
        let storedHeight: CGFloat
        if monotonic,
           let latest = latestHeights[itemID],
           abs(latest.width - width) <= 80 {
            storedHeight = max(height, latest.height)
        } else {
            storedHeight = height
        }
        heights[key(itemID: itemID, signature: signature, width: width)] = storedHeight
        latestHeights[itemID] = (width: width, height: storedHeight)
        return storedHeight
    }

    func invalidate(itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        let prefixes = itemIDs.map { "\($0)-" }
        heights = heights.filter { key, _ in
            !prefixes.contains { key.hasPrefix($0) }
        }
        // 有意不清 latestHeights:invalidate 的语义是"精确值不再可信",
        // 兜底估算仍然比 110 默认值准得多。
    }

    /// 会话/分支切换后收口:只保留仍存在的 message 行与非 message 行(bottomSpacer 等
    /// 固定 id),防止长期使用无界增长。
    func retain(messageItemIDs: Set<String>) {
        heights = heights.filter { key, _ in
            !key.hasPrefix("message-") || messageItemIDs.contains(where: { key.hasPrefix("\($0)-") })
        }
        latestHeights = latestHeights.filter { itemID, _ in
            !itemID.hasPrefix("message-") || messageItemIDs.contains(itemID)
        }
    }

    private func key(itemID: String, signature: String?, width: CGFloat) -> String {
        "\(itemID)-s\(signature ?? "none")-w\(Int(width.rounded()))"
    }
}

