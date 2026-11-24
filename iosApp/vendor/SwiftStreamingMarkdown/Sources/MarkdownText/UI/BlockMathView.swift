//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import iosMath
import SwiftUI

public struct BlockMathView: UIViewRepresentable {
  let latex: String
  let color: Color
  let pointSize: CGFloat

  public init(latex: String, color: Color, pointSize: CGFloat) {
    self.latex = latex
    self.color = color
    self.pointSize = pointSize
  }

  public func makeCoordinator() -> Coordinator { Coordinator() }

  public func makeUIView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.displayErrorInline = false
    label.setContentHuggingPriority(.defaultHigh, for: .vertical)
    updateUIView(label, context: context)
    return label
  }

  public func updateUIView(_ uiView: MTMathUILabel, context: Context) {
    context.coordinator.update(self, label: uiView, environment: context.environment)
  }

  public func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
    context.coordinator.sizeThatFits(self, label: uiView, width: proposal.width)
  }

  @MainActor public final class Coordinator {
    private var sizesByWidth: [CGFloat?: CGSize] = [:]

    func update(_ formula: BlockMathView, label: MTMathUILabel, environment: EnvironmentValues) {
      updateGeometry(formula, label: label)
      let textColor: UIColor
      if #available(iOS 17, *) {
        textColor = UIColor(cgColor: formula.color.resolve(in: environment).cgColor)
      } else {
        textColor = UIColor(formula.color)
      }
      if label.textColor != textColor {
        label.textColor = textColor
      }
    }

    func sizeThatFits(_ formula: BlockMathView, label: MTMathUILabel, width: CGFloat?) -> CGSize {
      updateGeometry(formula, label: label)
      let widthBucket = width?.rounded(.down)
      if let cached = sizesByWidth[widthBucket] { return cached }
      label.sizeToFit()
      let size = label.bounds.size
      // Short formulas can be clipped without the extra point of height.
      let fitted = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up) + 1)
      sizesByWidth[widthBucket] = fitted
      return fitted
    }

    private func updateGeometry(_ formula: BlockMathView, label: MTMathUILabel) {
      // iosMath reparses LaTeX on every setter call, even for the same source.
      if label.latex != formula.latex {
        label.latex = formula.latex
        sizesByWidth.removeAll(keepingCapacity: true)
      }
      if label.fontSize != formula.pointSize {
        label.fontSize = formula.pointSize
        sizesByWidth.removeAll(keepingCapacity: true)
      }
    }
  }
}
