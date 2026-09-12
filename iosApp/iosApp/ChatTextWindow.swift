import Foundation

/// Presentation only. The source remains intact for persistence and model context.
struct ChatTextWindow {
    static let limit = 2_000

    private var source = ""
    private var characterCount = 0
    private(set) var text = ""
    private(set) var omittedCount = 0

    init(_ source: String = "") {
        update(source)
    }

    /// Returns whether the update appends to the previous source. Consumers
    /// reuse this result instead of scanning the full prefix a second time.
    @discardableResult
    mutating func update(_ next: String) -> Bool {
        guard next != source else { return false }
        let isAppend = next.utf8.starts(with: source.utf8)
        if isAppend, let last = source.last {
            // Recount the boundary grapheme too: a delta can extend an emoji or
            // combining character. Ordinary appends only count the new delta.
            let boundary = source.utf16.count - String(last).utf16.count
            let delta = (next as NSString).substring(from: boundary)
            characterCount += delta.count - 1
        } else {
            characterCount = next.count
        }
        source = next
        text = String(next.suffix(Self.limit))
        omittedCount = max(0, characterCount - Self.limit)
        return isAppend
    }

    var omissionNotice: String? {
        guard omittedCount > 0 else { return nil }
        return IOSAppLocalization.formatted(
            "已省略 %lld 字",
            defaultValue: "已省略 %lld 字",
            arguments: [Int64(omittedCount)]
        )
    }

    var displayText: String {
        guard let omissionNotice else { return text }
        return omissionNotice + "\n" + text
    }
}
