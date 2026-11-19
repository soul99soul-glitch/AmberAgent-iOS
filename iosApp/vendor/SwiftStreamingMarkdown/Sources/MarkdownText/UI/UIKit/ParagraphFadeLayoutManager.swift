import UIKit

/// Drawing-only opacity for the opted-in TextKit 1 tail fade. The text storage
/// remains authoritative for colors, selection, accessibility and measurement.
final class ParagraphFadeLayoutManager: NSLayoutManager {
  struct OpacityRange {
    let range: NSRange
    let alpha: CGFloat
  }

  private(set) var opacityRanges: [OpacityRange] = []

  func setOpacityRanges(_ ranges: [OpacityRange]) {
    let dirty = opacityRanges + ranges
    opacityRanges = ranges
    guard let start = dirty.map(\.range.location).min(),
      let end = dirty.map({ NSMaxRange($0.range) }).max() else { return }
    let document = NSRange(location: 0, length: textStorage?.length ?? 0)
    let range = NSIntersectionRange(NSRange(location: start, length: end - start), document)
    // Adjacent streaming beats share one dirty region. Invalidating once avoids
    // a display invalidation for every old/new fade range on every frame.
    if range.length > 0 { invalidateDisplay(forCharacterRange: range) }
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    guard !opacityRanges.isEmpty, let context = UIGraphicsGetCurrentContext() else {
      super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
      return
    }
    let document = NSRange(location: 0, length: textStorage?.length ?? 0)
    let fades = opacityRanges.compactMap { item -> OpacityRange? in
      let characters = NSIntersectionRange(item.range, document)
      guard characters.length > 0 else { return nil }
      let glyphs = NSIntersectionRange(
        glyphRange(forCharacterRange: characters, actualCharacterRange: nil), glyphsToShow
      )
      return glyphs.length > 0 ? OpacityRange(range: glyphs, alpha: item.alpha) : nil
    }
    guard !fades.isEmpty else {
      super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
      return
    }
    let boundaries = Set([glyphsToShow.location, NSMaxRange(glyphsToShow)] +
      fades.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
    for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
      var alpha: CGFloat = 1
      // Ligatures may belong to adjacent character ranges. Draw the shared
      // glyph once, using the lowest opacity, rather than painting it twice.
      for fade in fades where NSLocationInRange(start, fade.range) { alpha = min(alpha, fade.alpha) }
      context.saveGState()
      context.setAlpha(alpha)
      super.drawGlyphs(forGlyphRange: NSRange(location: start, length: end - start), at: origin)
      context.restoreGState()
    }
  }
}
