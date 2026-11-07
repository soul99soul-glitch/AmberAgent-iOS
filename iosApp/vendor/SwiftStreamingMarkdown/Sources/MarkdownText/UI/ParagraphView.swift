//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import SwiftUI

struct ParagraphView: UIViewRepresentable {
  @Environment(\.openURL) var openURL
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  @Environment(\.markdownAnimateInitialText) var animateInitialText
  @Environment(\.markdownController) var markdownController: MarkdownController?
  @Environment(\.markdownStreamingTailSink) var streamingTailSink: MarkdownStreamingTailSink?

  var contents: NSMutableAttributedString
  var lineSpacing: CGFloat?
  var usesTextKit1 = false
  var suppressesInitialFade = false

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> ParagraphUIView {
    let openUrlFunction = openURL.callAsFunction(_:)
    let view = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(
      contents: contents,
      lineSpacing: lineSpacing,
      usesTextKit1: usesTextKit1
    )
    view.onUrlTap = openUrlFunction
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    view.setTextContextMenu(config.textContextMenu)
    view.setMarkdownController(markdownController)
    syncTailSinkBinding(for: view, coordinator: context.coordinator)

    let willFade = ParagraphInitialFadePolicy.shouldAnimate(
      configShouldAnimateText: config.shouldAnimateText,
      animateInitialText: animateInitialText,
      suppressesInitialFade: suppressesInitialFade
    )
    // Vendored fix (AmberAgent): test-only observation hook, nil in production.
    // Lets integration tests detect a `makeUIView` re-fade of already-displayed
    // text (block retyping/splitting) without pumping a live UIKit animation
    // runloop to read back `view.alpha`.
    ParagraphInitialFadePolicy.testFadeObserver?(contents.string, willFade)
    if willFade {
      view.alpha = 0
      UIView.animate(withDuration: ParagraphUIView.animationDuration) {
        view.alpha = 1
      }
    }

    return view
  }

  static func dismantleUIView(_ uiView: ParagraphUIView, coordinator: Coordinator) {
    coordinator.boundTailSink?.unbindParagraphView(uiView)
    coordinator.boundTailSink = nil
    ParagraphUIViewCache.shared.recycle(uiView)
  }

  func updateUIView(_ view: ParagraphUIView, context: Context) {
    syncTailSinkBinding(for: view, coordinator: context.coordinator)
    // Vendored fix (AmberAgent): identity-first short circuit. Frozen/settled
    // streaming blocks re-pass the same NSMutableAttributedString instance on
    // every layout pass; the deep attributed-string compare is O(content) per
    // paragraph per pass and dominated long-document streaming profiles.
    // Direct-appended streaming tails also stay untouched while `contents` still
    // points at the base attributed string they extended.
    if !view.isUpToDate(with: contents, lineSpacing: lineSpacing) {
      // Vendored fix (AmberAgent): streaming publishes land while cells are
      // still being configured (window == nil), so the window gate silently
      // skipped the fade and whole beats popped in unfaded. Unit-tail mode
      // animates regardless of attachment; the legacy per-word mode keeps the
      // original gate.
      let shouldAnimate = config.shouldAnimateText
        && (config.animatesAppendedTailAsUnit || view.window != nil)
      view.setParagraphContents(
        contents,
        lineSpacing: lineSpacing,
        animatedByWord: shouldAnimate,
        appendsTailFadeAsUnit: config.animatesAppendedTailAsUnit
      )
      context.coordinator.sizeCache.removeAll()
      context.coordinator.lastContents = nil
      context.coordinator.lastDirectAppendLayoutRevision = view.directAppendLayoutRevision
    }
    view.setTextContextMenu(config.textContextMenu)
    view.setMarkdownController(markdownController)
  }

  // If we don't implement this function, the snapshot tests will fail with incorrect sizing.
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ParagraphUIView, context: Context) -> CGSize? {
    // Vendored fix (AmberAgent): a nil proposal used to fall through to
    // screen-width intrinsic and widen the chat column. Reuse the last finite
    // proposal from this representable; otherwise defer to intrinsicContentSize
    // (which no longer advertises screen width).
    let width: CGFloat
    if let proposed = proposal.width, proposed > 0, proposed.isFinite {
      width = proposed
      context.coordinator.lastProposedWidth = proposed
    } else if let last = context.coordinator.lastProposedWidth, last > 0, last.isFinite {
      width = last
    } else {
      return nil
    }

    // Vendored fix (AmberAgent): test-only observation hook, see the enum below.
    #if DEBUG
    ParagraphViewSizeThatFitsTestHook.recordCall()
    #endif

    syncTailSinkBinding(for: uiView, coordinator: context.coordinator)

    // Vendored fix (AmberAgent): SwiftUI invokes sizeThatFits BEFORE updateUIView
    // in the same layout pass. Synchronize uiView's contents here (while
    // suppressing intrinsic size invalidation since we are already returning the
    // new measurement to SwiftUI) so the first pass measures the real text and
    // updateUIView does not have to invalidate and trigger a second layout pass.
    if !uiView.isUpToDate(with: contents, lineSpacing: lineSpacing) {
      let shouldAnimate = config.shouldAnimateText
        && (config.animatesAppendedTailAsUnit || uiView.window != nil)
      uiView.setParagraphContents(
        contents,
        lineSpacing: lineSpacing,
        animatedByWord: shouldAnimate,
        appendsTailFadeAsUnit: config.animatesAppendedTailAsUnit,
        suppressIntrinsicInvalidation: true
      )
    }

    // Check if content, lineSpacing, or direct-append layout revision changed - if so, clear the cache
    // Vendored fix (AmberAgent): identity-first short circuit, see updateUIView.
    let contentsUnchanged = contents === context.coordinator.lastContents
      || contents == context.coordinator.lastContents
    if !contentsUnchanged
        || lineSpacing != context.coordinator.lastLineSpacing
        || uiView.directAppendLayoutRevision != context.coordinator.lastDirectAppendLayoutRevision {
      context.coordinator.sizeCache.removeAll()
      context.coordinator.lastContents = contents
      context.coordinator.lastLineSpacing = lineSpacing
      context.coordinator.lastDirectAppendLayoutRevision = uiView.directAppendLayoutRevision
    }

    // Round width to avoid cache misses from floating point precision issues
    let cacheKey = (width * 10).rounded() / 10 // Round to 1 decimal place

    // Check if we have a cached size for this width
    if let cachedSize = context.coordinator.sizeCache[cacheKey] {
      #if DEBUG
      ParagraphViewSizeThatFitsTestHook.recordCacheHit()
      #endif
      return cachedSize
    }

    // Calculate new size
    let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    let size = uiView.sizeThatFits(targetSize)
    // Vendored fix (AmberAgent): UITextView can report a width wider than the
    // proposal; SwiftUI centers non-conforming views, clipping both edges.
    // Amber's attachment-free blocks fill their proposed column. Returning the
    // used glyph width would place a narrower UITextView, so its next full-column
    // measurement sees a width transition and throws away incremental layout.
    let calculatedSize = CGSize(
      width: usesTextKit1 ? width : min(size.width, width),
      height: size.height.rounded(.up)
    )

    context.coordinator.sizeCache[cacheKey] = calculatedSize

    return calculatedSize
  }

  private func syncTailSinkBinding(for view: ParagraphUIView, coordinator: Coordinator) {
    if let streamingTailSink {
      if coordinator.boundTailSink !== streamingTailSink {
        coordinator.boundTailSink?.unbindParagraphView(view)
      }
      if streamingTailSink.syncParagraphView(view, contents: contents, usesTextKit1: usesTextKit1) {
        coordinator.boundTailSink = streamingTailSink
      } else if coordinator.boundTailSink === streamingTailSink {
        view.setGatesStreamingHeightByLineCount(false)
        coordinator.boundTailSink = nil
      }
    } else {
      coordinator.boundTailSink?.unbindParagraphView(view)
      coordinator.boundTailSink = nil
      if view.gatesStreamingHeightByLineCount {
        view.setGatesStreamingHeightByLineCount(false)
      }
    }
  }

  class Coordinator {
    // Cache all calculated sizes keyed by width
    var sizeCache: [CGFloat: CGSize] = [:]
    var lastContents: NSMutableAttributedString?
    var lastLineSpacing: CGFloat?
    var lastDirectAppendLayoutRevision: UInt64 = 0
    weak var boundTailSink: MarkdownStreamingTailSink?
    /// Last finite width SwiftUI proposed. Used when a later pass sends a nil
    /// proposal so we do not fall back to the screen-width intrinsic guess.
    var lastProposedWidth: CGFloat?
  }
}

enum ParagraphInitialFadePolicy {
  // Vendored fix (AmberAgent): test-only hook, see `ParagraphView.makeUIView`.
  static var testFadeObserver: ((_ contents: String, _ willFade: Bool) -> Void)?

  static func shouldAnimate(
    configShouldAnimateText: Bool,
    animateInitialText: Bool,
    suppressesInitialFade: Bool
  ) -> Bool {
    configShouldAnimateText && animateInitialText && !suppressesInitialFade
  }
}

extension ParagraphView: Equatable {
  static func == (lhs: ParagraphView, rhs: ParagraphView) -> Bool {
    // Vendored fix (AmberAgent): identity-first short circuit, see updateUIView.
    (lhs.contents === rhs.contents || lhs.contents == rhs.contents)
      && lhs.lineSpacing == rhs.lineSpacing
  }
}

#if DEBUG
/// Test-only observation hook for `ParagraphView.sizeThatFits`: how many times
/// SwiftUI's layout engine actually invokes this representable's measurement
/// entry point per publish, and how many of those hit `Coordinator.sizeCache`
/// vs. fall through to a real `UITextView.sizeThatFits` call. Compiled out of
/// Release builds entirely (guarded by `#if DEBUG`, matching the existing
/// `ParagraphUIViewAppendPathTestHook` pattern in `UIKit/ParagraphUIView.swift`).
/// Not read by any production code path — added solely so `xcodebuild test`
/// targets can distinguish "SwiftUI walked every paragraph but measurement was
/// cached" from "every paragraph was re-measured" without guessing from
/// external side effects (2026-07-25 prefix-reuse-cost experiment).
@MainActor
enum ParagraphViewSizeThatFitsTestHook {
  static var callCount = 0
  static var cacheHitCount = 0

  static func reset() {
    callCount = 0
    cacheHitCount = 0
  }

  static func recordCall() {
    callCount += 1
  }

  static func recordCacheHit() {
    cacheHitCount += 1
  }
}
#endif
