import Foundation

/// Presentation only. The source remains intact for persistence and model context.
struct ChatTextWindow {
    static let limit = 2_000

    /// How far the window may grow past `limit` before its start slides
    /// forward. Streaming deltas are typically tens of characters; sliding
    /// the window start on every delta forced `text`'s leading edge to
    /// change on every publish, which defeats TextKit 1's append-only fast
    /// path (`ParagraphUIView.setParagraphContents` /
    /// `appendedTailRange(toBecome:)`) and the markdown renderer's own
    /// prefix-reuse checks — every publish degraded to a full
    /// attributed-string replacement and relayout. Advancing `windowStart`
    /// only once accumulated growth exceeds `step` keeps `text` a pure
    /// prefix extension of its previous value between slides, so the fast
    /// path fires on nearly every publish; only the (rare) slide itself pays
    /// for a full relayout. 1,000 — half of `limit` — bounds the extra
    /// visible overshoot to a modest 50% of the cap while cutting slide
    /// frequency by roughly two orders of magnitude versus sliding on every
    /// delta (streaming deltas run tens of characters, not thousands).
    static let step = 1_000

    private var source = ""
    private var characterCount = 0
    /// Characters of `source` before the visible window (equal to
    /// `omittedCount`); advances only on slides — see `step`.
    private var windowStart = 0
    private(set) var text = ""
    private(set) var omittedCount = 0

    init(_ source: String = "") {
        update(source)
    }

    /// Returns whether the update appends to the previous source. Consumers
    /// reuse this result instead of scanning the full prefix a second time.
    @discardableResult
    mutating func update(_ next: String) -> Bool {
        // KMP 桥接来的是外来（NSString）字符串，逐字符比较会走慢路径且随长度线性变慢；
        // 先整体转成原生 UTF-8，比较与前缀检查都变成 memcmp。
        var next = next
        next.makeContiguousUTF8()
        guard next != source else { return false }
        let isAppend = Self.hasUTF8Prefix(next, source)
        if isAppend, let last = source.last {
            // Recount the boundary grapheme too: a delta can extend an emoji or
            // combining character. Ordinary appends only count the new delta.
            let boundary = source.utf16.count - String(last).utf16.count
            let delta = (next as NSString).substring(from: boundary)
            characterCount += delta.count - 1
            source = next

            // `text`'s tail always mirrors `source`'s tail (same boundary
            // grapheme), so extend it the same way instead of recomputing
            // the whole suffix from scratch (see `step`).
            text = String(text.dropLast()) + delta

            let windowLength = characterCount - windowStart
            if windowLength > Self.limit + Self.step {
                // Overshot by more than one step: slide the start forward
                // just enough to land back at exactly `limit` (see `step`).
                let newWindowStart = characterCount - Self.limit
                text = String(text.dropFirst(newWindowStart - windowStart))
                windowStart = newWindowStart
            }
        } else {
            characterCount = next.count
            source = next
            windowStart = max(0, characterCount - Self.limit)
            text = String(next.suffix(Self.limit))
        }
        omittedCount = windowStart
        return isAppend
    }

    private static func hasUTF8Prefix(_ string: String, _ prefix: String) -> Bool {
        var string = string
        var prefix = prefix
        return string.withUTF8 { whole in
            prefix.withUTF8 { head in
                head.count <= whole.count &&
                    (head.isEmpty || memcmp(whole.baseAddress!, head.baseAddress!, head.count) == 0)
            }
        }
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
