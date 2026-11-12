//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
import SwiftUI

private actor HighlightTaskManager: ObservableObject {
  /// Shared Highlight instance to avoid creating multiple JSContext/HLJS instances.
  /// Each Highlight() creates its own JSContext and evaluates highlight.min.js (~600KB).
  /// When multiple CodeBlockViews render concurrently, N separate JSContexts cause
  /// JavaScriptCore OOM crashes (COPILOT-IOS-3F9C, 3F7Z, 3FSQ).
  private static let sharedHighlight = Highlight()
  private static let minimumHighlightIntervalNs: UInt64 = 90_000_000

  private var latestRequest: (code: String, language: String)?
  private var isProcessing = false
  private var lastHighlightFinishedUptimeNs: UInt64 = 0

  func enqueueCode(_ code: String, language: String, completion: @escaping (String, AttributedString) -> Void) {
    latestRequest = (code, language)

    if !isProcessing {
      Task {
        await processQueue(completion: completion)
      }
    }
  }

  private func processQueue(completion: @escaping (String, AttributedString) -> Void) async {
    guard !isProcessing else { return }

    isProcessing = true

    while latestRequest != nil {
      if lastHighlightFinishedUptimeNs > 0 {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = nowNs >= lastHighlightFinishedUptimeNs ? nowNs - lastHighlightFinishedUptimeNs : 0
        if elapsedNs < Self.minimumHighlightIntervalNs {
          try? await Task.sleep(nanoseconds: Self.minimumHighlightIntervalNs - elapsedNs)
        }
      }
      guard let request = latestRequest else { break }
      latestRequest = nil
      let codeToProcess = request.code
      let normalizedLanguage = request.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

      let css: String = await CodeBlockView.syntaxHighlightingCss
      let highlightColors: HighlightColors = .custom(css: css, background: "")
      let highlighted: AttributedString?
      if !normalizedLanguage.isEmpty,
         let explicit = try? await Self.sharedHighlight.attributedText(
           codeToProcess,
           language: normalizedLanguage,
           colors: highlightColors
         ) {
        highlighted = explicit
      } else {
        highlighted = try? await Self.sharedHighlight.attributedText(
          codeToProcess,
          colors: highlightColors
        )
      }
      if let result = highlighted {
        lastHighlightFinishedUptimeNs = DispatchTime.now().uptimeNanoseconds
        await MainActor.run {
          completion(codeToProcess, result)
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

  @State var copied: Bool = false
  @State var attributedString: AttributedString?
  @State private var highlightedCode: String?
  @StateObject private var taskManager: HighlightTaskManager = HighlightTaskManager()

  public init(language: String, code: String, onCodeCopied: (() -> Void)? = nil,
              autoWrap: Bool = false, autoCollapse: Bool = false, headerAccessory: AnyView? = nil) {
    self.language = language
    self.code = code
    self.onCodeCopied = onCodeCopied
    self.autoWrap = autoWrap
    self.autoCollapse = autoCollapse
    self.headerAccessory = headerAccessory
  }

  private func copyCode() {
    copied = true
    UIPasteboard.general.string = code
    if let onCodeCopied {
      onCodeCopied()
    }
  }

  private func updateAttributedString(code: String, language: String? = nil) async {
    await taskManager.enqueueCode(code, language: language ?? self.language) { processedCode, newAttributedString in
      self.highlightedCode = processedCode
      self.attributedString = newAttributedString
    }
  }

  private var shouldCollapse: Bool {
    autoCollapse && code.count > 500 && !expanded
  }

  private var displayedCode: String {
    shouldCollapse ? String(code.prefix(300)) : code
  }

  @available(iOS 16.1, *)
  private var renderedAttributedCode: AttributedString {
    let currentCode = displayedCode
    guard let attributedString, let highlightedCode else {
      return AttributedString(currentCode)
    }
    if highlightedCode == currentCode {
      return attributedString
    }
    if currentCode.utf8.starts(with: highlightedCode.utf8),
       let utf8Split = currentCode.utf8.index(
         currentCode.utf8.startIndex,
         offsetBy: highlightedCode.utf8.count,
         limitedBy: currentCode.utf8.endIndex
       ),
       let scalarBoundary = utf8Split.samePosition(in: currentCode) {
      var combined = attributedString
      combined.append(AttributedString(String(currentCode[scalarBoundary...])))
      return combined
    }
    if currentCode.hasPrefix(highlightedCode) {
      var combined = attributedString
      combined.append(AttributedString(String(currentCode.dropFirst(highlightedCode.count))))
      return combined
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
      Task {
        await updateAttributedString(code: value)
      }
    })
    .onChange(of: language, perform: { newLanguage in
      Task {
        await updateAttributedString(code: displayedCode, language: newLanguage)
      }
    })
    .onAppear(perform: {
      Task {
        await updateAttributedString(code: displayedCode)
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
