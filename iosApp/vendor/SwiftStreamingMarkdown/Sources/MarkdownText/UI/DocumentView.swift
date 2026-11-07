//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Equatable
import Markdown
import SwiftUI

/// A SwiftUI view that renders a pre-parsed `RenderableDocument`. Use this
/// view when you already have a parsed document (e.g. driven by a streaming
/// pipeline); use `MarkdownView` when you want the package to parse for you.
@Equatable
public struct DocumentView: View {
  @StateObject var controller: MarkdownController

  let renderableDocument: RenderableDocument
  let config: MarkdownRenderConfig
  let animateInitialText: Bool
  let usesLayerBackedTableAnimation: Bool
  let usesTextKit1ForAttachmentFreeText: Bool

  /// Create a `DocumentView`.
  /// - Parameters:
  ///   - renderableDocument: The parsed Markdown document to render.
  ///   - config: Render configuration. Defaults to `.default`.
  ///   - animateInitialText: Whether newly mounted paragraphs should fade in.
  ///   - usesLayerBackedTableAnimation: Whether table text entrances should be
  ///     composited by Core Animation instead of SwiftUI's text renderer.
  ///   - usesTextKit1ForAttachmentFreeText: Whether attachment-free paragraphs
  ///     should use TextKit 1's lower-cost full-height layout path.
  ///   - listener: Optional listener that receives render and interaction events.
  public init(
    renderableDocument: RenderableDocument,
    config: MarkdownRenderConfig = .default,
    animateInitialText: Bool = true,
    usesLayerBackedTableAnimation: Bool = false,
    usesTextKit1ForAttachmentFreeText: Bool = false,
    listener: MarkdownListener? = nil
  ) {
    self.renderableDocument = renderableDocument
    self.config = config
    self.animateInitialText = animateInitialText
    self.usesLayerBackedTableAnimation = usesLayerBackedTableAnimation
    self.usesTextKit1ForAttachmentFreeText = usesTextKit1ForAttachmentFreeText
    self._controller = StateObject(wrappedValue: MarkdownController(listener: listener))
  }

  public var body: some View {
    BlockView(renderables: renderableDocument.renderables)
    .environment(\.markdownConfig, config)
    .environment(\.markdownAnimateInitialText, animateInitialText)
    .environment(\.markdownUsesLayerBackedTableAnimation, usesLayerBackedTableAnimation)
    .environment(\.markdownUsesTextKit1ForAttachmentFreeText, usesTextKit1ForAttachmentFreeText)
    .environment(\.markdownController, controller)
    .task {
      controller.onAppear(markdown: renderableDocument)
    }
    .onChange(of: renderableDocument, perform: { md in
      controller.onChange(markdown: md)
    })
    .onDisappear {
      controller.onDisappear()
    }
  }
}

extension EnvironmentValues {
  /// The render configuration applied to descendant Markdown views.
  @Entry public var markdownConfig: MarkdownRenderConfig = .default
  /// Whether newly mounted paragraph views should run their initial fade.
  @Entry public var markdownAnimateInitialText: Bool = true
  /// Whether table text entrances should run on Core Animation layers instead
  /// of invalidating the surrounding SwiftUI table on every animation frame.
  @Entry public var markdownUsesLayerBackedTableAnimation: Bool = false
  @Entry var markdownUsesTextKit1ForAttachmentFreeText: Bool = false
  /// The shared controller used by descendant Markdown views to route
  /// table/context-menu events to the configured `MarkdownListener`.
  @Entry public var markdownController: MarkdownController?
  /// Vendored addition (AmberAgent): opt-in sink allowing streaming hosts to
  /// append plain-text characters directly into the trailing TextKit 1
  /// `ParagraphUIView` and gate height invalidation by laid-out line count.
  /// Defaults to `nil`, keeping legacy package behavior unchanged.
  @Entry public var markdownStreamingTailSink: MarkdownStreamingTailSink? = nil
}

/// Identity-stable bridge between a streaming host and the mounted trailing
/// TextKit 1 `ParagraphUIView`.
@MainActor
public final class MarkdownStreamingTailSink: Equatable {
  public nonisolated static func == (lhs: MarkdownStreamingTailSink, rhs: MarkdownStreamingTailSink) -> Bool {
    lhs === rhs
  }

  weak var tailParagraphView: ParagraphUIView?
  private(set) var targetTailContents: NSMutableAttributedString?
  private(set) var shouldAnimateText = false
  private(set) var appendsTailFadeAsUnit = false
  private(set) var gatesHeightByLineCount = false

  public nonisolated init() {}

  public func updateStreamingConfig(
    shouldAnimateText: Bool,
    appendsTailFadeAsUnit: Bool,
    gatesHeightByLineCount: Bool
  ) {
    self.shouldAnimateText = shouldAnimateText
    self.appendsTailFadeAsUnit = appendsTailFadeAsUnit
    self.gatesHeightByLineCount = gatesHeightByLineCount
    tailParagraphView?.setGatesStreamingHeightByLineCount(gatesHeightByLineCount)
  }

  public func configureTarget(
    contents: NSMutableAttributedString?,
    shouldAnimateText: Bool,
    appendsTailFadeAsUnit: Bool,
    gatesHeightByLineCount: Bool
  ) {
    self.targetTailContents = contents
    self.shouldAnimateText = shouldAnimateText
    self.appendsTailFadeAsUnit = appendsTailFadeAsUnit
    self.gatesHeightByLineCount = gatesHeightByLineCount

    if let view = tailParagraphView {
      if let contents {
        if view.paragraphContents === contents || view.baseParagraphContents === contents {
          view.setGatesStreamingHeightByLineCount(gatesHeightByLineCount)
        } else if view.paragraphContents == contents {
          view.adoptEquivalentParagraphContents(contents)
          view.setGatesStreamingHeightByLineCount(gatesHeightByLineCount)
        } else {
          if !gatesHeightByLineCount {
            view.setGatesStreamingHeightByLineCount(false)
          }
          tailParagraphView = nil
        }
      } else {
        view.setGatesStreamingHeightByLineCount(false)
        tailParagraphView = nil
      }
    }
  }

  public func setGatesHeightByLineCount(_ enabled: Bool) {
    gatesHeightByLineCount = enabled
    tailParagraphView?.setGatesStreamingHeightByLineCount(enabled)
  }

  public func canDirectAppend() -> Bool {
    guard let targetTailContents,
          let view = tailParagraphView,
          view.paragraphContents === targetTailContents || view.baseParagraphContents === targetTailContents else {
      return false
    }
    return view.canDirectAppendPlainTail()
  }

  public enum PlainTailAppendResult {
    case notAppended
    case appendedSameLine
    case appendedHeightChanged
  }

  @discardableResult
  public func appendPlainTail(_ suffixText: String) -> Bool {
    appendPlainTailWithResult(suffixText, suppressIntrinsicInvalidation: false) != .notAppended
  }

  public func appendPlainTailWithResult(
    _ suffixText: String,
    suppressIntrinsicInvalidation: Bool = false
  ) -> PlainTailAppendResult {
    guard !suffixText.isEmpty,
          let targetTailContents,
          let view = tailParagraphView,
          view.paragraphContents === targetTailContents || view.baseParagraphContents === targetTailContents else {
      return .notAppended
    }
    view.setGatesStreamingHeightByLineCount(gatesHeightByLineCount)
    let shouldAnimate = shouldAnimateText && (appendsTailFadeAsUnit || view.window != nil)
    let outcome = view.appendStreamingPlainTail(
      suffixText,
      animatedByWord: shouldAnimate,
      appendsTailFadeAsUnit: appendsTailFadeAsUnit,
      suppressIntrinsicInvalidation: suppressIntrinsicInvalidation
    )
    switch outcome {
    case .notAppended:
      return .notAppended
    case .appendedSameLine:
      return .appendedSameLine
    case .appendedHeightChanged:
      return .appendedHeightChanged
    }
  }

  func syncParagraphView(
    _ view: ParagraphUIView,
    contents: NSMutableAttributedString,
    usesTextKit1: Bool
  ) -> Bool {
    guard usesTextKit1,
          let targetTailContents,
          contents === targetTailContents else {
      if tailParagraphView === view {
        view.setGatesStreamingHeightByLineCount(false)
        tailParagraphView = nil
      }
      return false
    }
    if let previous = tailParagraphView, previous !== view {
      previous.setGatesStreamingHeightByLineCount(false)
    }
    tailParagraphView = view
    view.setGatesStreamingHeightByLineCount(gatesHeightByLineCount)
    return true
  }

  func unbindParagraphView(_ view: ParagraphUIView) {
    guard tailParagraphView === view else { return }
    view.setGatesStreamingHeightByLineCount(false)
    tailParagraphView = nil
  }
}

#if DEBUG

let text = """
 I found some resources that can help you compare gyms in your neighborhood. Here's a brief overview:

1. **The Ultimate Gym Guide** provides a comprehensive database of gyms where you can compare amenities, locations with pools, saunas, childcare, and more.
2. **Best Gyms Near Me** on Yelp lists gyms with a variety of classes, equipment, and amenities, from budget-friendly options to high-end gyms with all the bells and whistles.

You can visit these sites to get detailed information on membership prices and amenities for each gym. Remember to consider what's most important for your fitness routine when making your decision!
"""

#Preview {
  return MarkdownView(text: text)
}

#endif
