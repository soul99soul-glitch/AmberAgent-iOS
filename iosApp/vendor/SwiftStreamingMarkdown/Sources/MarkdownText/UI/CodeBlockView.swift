//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

internal final class CodeBlockHighlightCache: @unchecked Sendable {
  static let shared = CodeBlockHighlightCache()

  static let defaultCountLimit = 256
  static let defaultTotalCostLimit = 8 * 1024 * 1024

  private final class CacheKey: NSObject {
    let css: String
    let appearance: String
    let language: String
    let code: String
    private let cachedHash: Int

    init(css: String, appearance: String, language: String, code: String) {
      self.css = css
      self.appearance = appearance
      self.language = language
      self.code = code
      var hasher = Hasher()
      hasher.combine(css)
      hasher.combine(appearance)
      hasher.combine(language)
      hasher.combine(code)
      self.cachedHash = hasher.finalize()
      super.init()
    }

    override var hash: Int { cachedHash }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      if self === other { return true }
      return cachedHash == other.cachedHash
        && appearance == other.appearance
        && language == other.language
        && css == other.css
        && code == other.code
    }
  }

  private final class CacheEntry {
    let attributedString: AttributedString

    init(attributedString: AttributedString) {
      self.attributedString = attributedString
    }
  }

  private let storage: NSCache<CacheKey, CacheEntry>

  init(countLimit: Int = defaultCountLimit, totalCostLimit: Int = defaultTotalCostLimit) {
    let cache = NSCache<CacheKey, CacheEntry>()
    cache.countLimit = countLimit
    cache.totalCostLimit = totalCostLimit
    self.storage = cache
  }

  var countLimit: Int { storage.countLimit }
  var totalCostLimit: Int { storage.totalCostLimit }

  func attributedString(
    for code: String,
    language: String,
    css: String,
    appearance: String
  ) -> AttributedString? {
    let key = CacheKey(css: css, appearance: appearance, language: language, code: code)
    return storage.object(forKey: key)?.attributedString
  }

  func store(
    _ attributedString: AttributedString,
    for code: String,
    language: String,
    css: String,
    appearance: String
  ) {
    let key = CacheKey(css: css, appearance: appearance, language: language, code: code)
    let cost = Self.estimatedCost(for: code)
    storage.setObject(CacheEntry(attributedString: attributedString), forKey: key, cost: cost)
  }

  func removeAll() {
    storage.removeAllObjects()
  }

  static func estimatedCost(for code: String) -> Int {
    // AttributedString stores UTF-8 characters plus attribute runs (~4x source byte size).
    max(1, code.utf8.count * 4)
  }
}

private actor HighlightTaskManager: ObservableObject {
  /// Shared Highlight instance to avoid creating multiple JSContext/HLJS instances.
  /// Each Highlight() creates its own JSContext and evaluates highlight.min.js (~600KB).
  /// When multiple CodeBlockViews render concurrently, N separate JSContexts cause
  /// JavaScriptCore OOM crashes (COPILOT-IOS-3F9C, 3F7Z, 3FSQ).
  private static let sharedHighlight = Highlight()
  private static let minimumHighlightIntervalNs: UInt64 = 90_000_000

  struct Request: Sendable {
    let code: String
    let language: String
    let css: String
    let appearance: String
  }

  private var latestRequest: Request?
  private var isProcessing = false
  private var lastHighlightFinishedUptimeNs: UInt64 = 0

  static func highlightText(_ code: String, css: String) async throws -> AttributedString {
    try await sharedHighlight.attributedText(code, colors: .custom(css: css, background: ""))
  }

  func enqueue(
    _ request: Request,
    cache: CodeBlockHighlightCache = .shared,
    completion: @escaping (String, String, AttributedString) -> Void
  ) {
    latestRequest = request

    if !isProcessing {
      Task {
        await processQueue(cache: cache, completion: completion)
      }
    }
  }

  private func processQueue(
    cache: CodeBlockHighlightCache,
    completion: @escaping (String, String, AttributedString) -> Void
  ) async {
    guard !isProcessing else { return }

    isProcessing = true

    while let pendingRequest = latestRequest {
      if let cached = cache.attributedString(
        for: pendingRequest.code,
        language: pendingRequest.language,
        css: pendingRequest.css,
        appearance: pendingRequest.appearance
      ) {
        latestRequest = nil
        await MainActor.run {
          completion(pendingRequest.code, pendingRequest.appearance, cached)
        }
        continue
      }

      if lastHighlightFinishedUptimeNs > 0 {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = nowNs >= lastHighlightFinishedUptimeNs ? nowNs - lastHighlightFinishedUptimeNs : 0
        if elapsedNs < Self.minimumHighlightIntervalNs {
          try? await Task.sleep(nanoseconds: Self.minimumHighlightIntervalNs - elapsedNs)
        }
      }
      guard let request = latestRequest else { break }
      latestRequest = nil

      if let cached = cache.attributedString(
        for: request.code,
        language: request.language,
        css: request.css,
        appearance: request.appearance
      ) {
        await MainActor.run {
          completion(request.code, request.appearance, cached)
        }
        continue
      }

      if let result = try? await Self.highlightText(request.code, css: request.css) {
        cache.store(
          result,
          for: request.code,
          language: request.language,
          css: request.css,
          appearance: request.appearance
        )
        lastHighlightFinishedUptimeNs = DispatchTime.now().uptimeNanoseconds
        await MainActor.run {
          completion(request.code, request.appearance, result)
        }
      } else {
        lastHighlightFinishedUptimeNs = DispatchTime.now().uptimeNanoseconds
      }
    }

    isProcessing = false
  }
}

private struct CodeBlockCopyHitOutsetKey: EnvironmentKey {
  static let defaultValue: CGFloat? = nil
}

public extension EnvironmentValues {
  /// Optional outset that enlarges the header "Copy" control's tap area (icon + label) without changing layout.
  /// The default nil keeps the original text-only tap target.
  var swiftStreamingMarkdownCodeCopyHitOutset: CGFloat? {
    get { self[CodeBlockCopyHitOutsetKey.self] }
    set { self[CodeBlockCopyHitOutsetKey.self] = newValue }
  }
}

public struct CodeBlockView: View {

  let language: String
  let code: String
  let onCodeCopied: (() -> Void)?
  let autoWrap: Bool
  let autoCollapse: Bool
  let headerAccessory: AnyView?

  @State private var expanded = false
  @Environment(\.swiftStreamingMarkdownCodeCopyHitOutset) private var copyHitOutset
  @Environment(\.colorScheme) private var colorScheme

  @State var copied: Bool = false
  @State var attributedString: AttributedString?
  @State private var highlightedCode: String?
  @State private var highlightedAppearance: String?
  @StateObject private var taskManager: HighlightTaskManager = HighlightTaskManager()
  internal let didPrepopulateHighlightFromCache: Bool

  public init(language: String, code: String, onCodeCopied: (() -> Void)? = nil,
              autoWrap: Bool = false, autoCollapse: Bool = false, headerAccessory: AnyView? = nil) {
    self.language = language
    self.code = code
    self.onCodeCopied = onCodeCopied
    self.autoWrap = autoWrap
    self.autoCollapse = autoCollapse
    self.headerAccessory = headerAccessory

    let initialCode = Self.displayedCode(for: code, autoCollapse: autoCollapse, expanded: false)
    let initialAppearance = Self.currentAppearanceKey()
    let initialCss = Self.syntaxHighlightingCss(for: initialAppearance)
    if let cached = CodeBlockHighlightCache.shared.attributedString(
      for: initialCode,
      language: language,
      css: initialCss,
      appearance: initialAppearance
    ) {
      _attributedString = State(initialValue: cached)
      _highlightedCode = State(initialValue: initialCode)
      _highlightedAppearance = State(initialValue: initialAppearance)
      self.didPrepopulateHighlightFromCache = true
    } else {
      _attributedString = State(initialValue: nil)
      _highlightedCode = State(initialValue: nil)
      _highlightedAppearance = State(initialValue: nil)
      self.didPrepopulateHighlightFromCache = false
    }
  }

  internal static func appearanceKey(for colorScheme: ColorScheme) -> String {
    colorScheme == .dark ? "dark" : "light"
  }

  internal static func currentAppearanceKey() -> String {
    #if canImport(UIKit)
    return UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
    #else
    return "light"
    #endif
  }

  internal static func syntaxHighlightingCss(for appearance: String) -> String {
    _ = appearance
    return syntaxHighlightingCss
  }

  internal static func displayedCode(for code: String, autoCollapse: Bool, expanded: Bool) -> String {
    (autoCollapse && code.count > 500 && !expanded) ? String(code.prefix(300)) : code
  }

  internal static func highlight(
    code: String,
    language: String,
    css: String? = nil,
    appearance: String,
    cache: CodeBlockHighlightCache = .shared
  ) async -> AttributedString? {
    let resolvedCss = css ?? syntaxHighlightingCss(for: appearance)
    if let cached = cache.attributedString(
      for: code,
      language: language,
      css: resolvedCss,
      appearance: appearance
    ) {
      return cached
    }
    guard let result = try? await HighlightTaskManager.highlightText(code, css: resolvedCss) else {
      return nil
    }
    cache.store(result, for: code, language: language, css: resolvedCss, appearance: appearance)
    return result
  }

  private func copyCode() {
    copied = true
    UIPasteboard.general.string = code
    if let onCodeCopied {
      onCodeCopied()
    }
  }

  @MainActor
  private func updateAttributedString(code: String, appearance: String) async {
    if highlightedCode == code,
       highlightedAppearance == appearance,
       attributedString != nil {
      return
    }
    let css = Self.syntaxHighlightingCss(for: appearance)
    if let cached = CodeBlockHighlightCache.shared.attributedString(
      for: code,
      language: language,
      css: css,
      appearance: appearance
    ) {
      self.highlightedCode = code
      self.highlightedAppearance = appearance
      self.attributedString = cached
      return
    }
    let request = HighlightTaskManager.Request(
      code: code,
      language: language,
      css: css,
      appearance: appearance
    )
    await taskManager.enqueue(request) { processedCode, processedAppearance, newAttributedString in
      let currentAppearance = Self.appearanceKey(for: self.colorScheme)
      guard processedAppearance == currentAppearance else { return }
      let currentCode = self.displayedCode
      guard processedCode == currentCode || currentCode.hasPrefix(processedCode) else { return }
      if self.highlightedAppearance == currentAppearance,
         let existing = self.highlightedCode,
         existing.count > processedCode.count,
         currentCode.hasPrefix(existing) {
        return
      }
      self.highlightedCode = processedCode
      self.highlightedAppearance = processedAppearance
      self.attributedString = newAttributedString
    }
  }

  private var shouldCollapse: Bool {
    autoCollapse && code.count > 500 && !expanded
  }

  private var displayedCode: String {
    Self.displayedCode(for: code, autoCollapse: autoCollapse, expanded: expanded)
  }

  @available(iOS 16.1, *)
  private var renderedAttributedCode: AttributedString {
    let currentCode = displayedCode
    let currentAppearance = Self.appearanceKey(for: colorScheme)
    if let attributedString,
       let highlightedCode,
       highlightedAppearance == currentAppearance {
      if highlightedCode == currentCode {
        return attributedString
      }
      if currentCode.hasPrefix(highlightedCode) {
        var combined = attributedString
        combined.append(AttributedString(String(currentCode.dropFirst(highlightedCode.count))))
        return combined
      }
    }
    let css = Self.syntaxHighlightingCss(for: currentAppearance)
    if let cached = CodeBlockHighlightCache.shared.attributedString(
      for: currentCode,
      language: language,
      css: css,
      appearance: currentAppearance
    ) {
      return cached
    }
    return AttributedString(currentCode)
  }

  @ViewBuilder
  private var codeText: some View {
    if #available(iOS 16.1, *) {
      Text(renderedAttributedCode)
        .font(Typography.codeTextFonts)
        .foregroundStyle(Color.Theme.Component.CodeBlock.Foreground.FunctionParameter)
        .transition(.opacity)
    } else {
      Text(displayedCode)
        .font(Typography.codeTextFonts)
        .foregroundStyle(Color.Theme.Component.CodeBlock.Foreground.FunctionParameter)
        .transition(.opacity)
    }
  }

  var codeblock: some View {
    VStack(alignment: .leading, spacing: 8) {
      if autoWrap || shouldCollapse {
        codeText
          .lineLimit(shouldCollapse ? 8 : nil)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView(.horizontal) {
          HStack(alignment: .top) {
            codeText
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        // Keep long code lines inside the proposed chat column width.
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if shouldCollapse {
        Button("展开（共 \(code.count) 字符）") {
          expanded = true
        }
        .font(Typography.smallTextFonts)
        .foregroundStyle(Color.Static.Stone.Stone350)
        .buttonStyle(.plain)
      }
    }
    .transaction { transaction in
      // The horizontal scrollView resizing animation was causing the code block to animate
      // all janky.
      transaction.animation = nil
    }
    .padding(16)
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        Text(language)
          .font(Typography.smallTextFonts)
          .foregroundStyle(Color.Static.Stone.Stone350)
        Spacer()
        headerAccessory
          .foregroundStyle(Color.Static.Stone.Stone350)
        if let copyHitOutset {
          HStack(alignment: .firstTextBaseline, spacing: 6.0) {
            Image("copyIcon14", bundle: .module)
              .renderingMode(.template)
              .foregroundStyle(Color.Static.Stone.Stone350)
            Text(copied ? String.codeCopiedLabel : String.codeCopyLabel)
              .accessibilityAddTraits(.isButton)
              .font(Typography.smallTextFonts)
              .foregroundStyle(Color.Static.Stone.Stone350)
          }
          .contentShape(Rectangle().inset(by: -copyHitOutset))
          .onTapGesture(perform: copyCode)
        } else {
          HStack(alignment: .firstTextBaseline, spacing: 6.0) {
            Image("copyIcon14", bundle: .module)
              .renderingMode(.template)
              .foregroundStyle(Color.Static.Stone.Stone350)
            Text(copied ? String.codeCopiedLabel : String.codeCopyLabel)
              .accessibilityAddTraits(.isButton)
              .font(Typography.smallTextFonts)
              .foregroundStyle(Color.Static.Stone.Stone350)
              .onTapGesture(perform: copyCode)
          }
        }
      }.frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
          Color.Theme.Component.CodeBlock.Background.Background750
            .clipShape(.rect(
              topLeadingRadius: 20,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: 20
            ))
        )
      codeblock
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.automatic)
        .background(Color.Theme.Component.CodeBlock.Background.Background750
          .clipShape(.rect(
            topLeadingRadius: 0,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 20,
            topTrailingRadius: 0
          ))
        )
    }.onChange(of: copied, perform: { isCopied in
      if isCopied {
        Task {
          try await Task.sleep(seconds: 3)
          copied = false
        }
      }
    })
    .onChange(of: displayedCode, perform: { value in
      let appearance = Self.appearanceKey(for: colorScheme)
      Task {
        await updateAttributedString(code: value, appearance: appearance)
      }
    })
    .onChange(of: colorScheme, perform: { newScheme in
      let appearance = Self.appearanceKey(for: newScheme)
      let value = displayedCode
      Task {
        await updateAttributedString(code: value, appearance: appearance)
      }
    })
    .onAppear(perform: {
      let appearance = Self.appearanceKey(for: colorScheme)
      let value = displayedCode
      if highlightedCode == value,
         highlightedAppearance == appearance,
         attributedString != nil {
        return
      }
      Task {
        await updateAttributedString(code: value, appearance: appearance)
      }
    })
  }
}

#if DEBUG

#Preview {
  return LazyVStack {
    Spacer()
    CodeBlockView(language: "Python", code: "import random\n\ndef generate_and_add_numbers(num_numbers):\n    # Generate a list of random numbers random_numbers\n    random_numbers = [random.randint(1, 100) for _ in range(num_numbers)]\n\n\n    # Add the numbers together\n    sum_of_numbers = sum(random_numbers)\n\n    return random_numbers, sum_of_numbers\n\n# Example: Generate 5 random numbers and add them together\nnum_numbers = 5\nrandom_numbers, sum_of_numbers = generate_and_add_numbers(num_numbers)\nprint(f\"Generated numbers: {random_numbers}\")\nprint(f\"Sum of numbers: {sum_of_numbers}\")")
    Spacer()
  }.padding(24)
}

#endif
