import SwiftUI
import UIKit
import Shared

extension View {
    /// 原生 Liquid Glass 输入胶囊:`.regular` 提供半透折射,`.interactive()` 提供触控时的
    /// HDR 高光/透镜响应。低于 iOS 26 时回退到 `.thinMaterial`。
    /// 内部可见(非 private),以便模型议会等其他页面复用同一套原生输入胶囊样式。
    ///
    /// `glassChrome.quieter` / `.solid` 时垫一层与首页同源的弱底，避免 appWide 网格在
    /// 输入条下折射发脏；`.standard` 不垫，保持经典包体观感。
    @ViewBuilder
    func composerDockGlass(cornerRadius: CGFloat) -> some View {
        let cornerRadius = AmberTheme.controlRadius(cornerRadius)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Matches home `HomeGlassControlModifier`; 0 keeps classic packs unchanged.
        let pad: Double = {
            switch AmberThemeRuntime.shared.glassChrome {
            case .standard: 0
            case .quieter: 0.18
            case .solid: 0.52
            }
        }()
        if #available(iOS 26.0, *) {
            if pad > 0 {
                background(AmberTheme.homeGlassTop.opacity(pad), in: shape)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                    .overlay { shape.strokeBorder(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
            } else {
                glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                    .overlay { shape.strokeBorder(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
            }
        } else {
            background(.thinMaterial, in: shape)
                .overlay {
                    shape.stroke(AmberTheme.border.opacity(0.42), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}

/// 「回到底部」悬浮玻璃圆键 —— 上滑看历史时浮现在输入框正上方,点击跳回最新消息。
/// 复用 composer 的原生 Liquid Glass 圆形样式,保持视觉统一。
struct ChatScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(AmberTheme.foreground2)
                .frame(width: 38, height: 38)
                .modifier(ComposerDockCircleGlass(tint: nil))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.9, haptic: .selection))
        .accessibilityLabel("回到最新消息")
    }
}

/// Apple Music dock 风格的独立圆形发送/停止键 —— 与输入胶囊分离的原生 Liquid Glass。
/// 启用时给玻璃染上 accent 色调,触控时由 `.interactive()` 产生 HDR 透镜高光。
/// 内部可见(非 private),以便模型议会等其他页面复用同一颗原生发送键。
struct ComposerDockSendButton: View {
    var isLoading: Bool
    var isStopping: Bool = false
    var sendEnabled: Bool
    var diameter: CGFloat = 54
    let onSend: () -> Void
    let onStop: () -> Void

    private var isActionable: Bool { isLoading || sendEnabled }

    var body: some View {
        Button {
            if isStopping { return }
            if isLoading { onStop() } else { onSend() }
        } label: {
            ZStack {
                Image(systemName: isLoading ? "stop.fill" : "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .opacity(isStopping ? 0 : 1)
                // 只在停止中挂载：透明的 ProgressView 仍会持续动画并逐帧重绘玻璃按钮。
                if isStopping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmberTheme.muted)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .modifier(ComposerDockCircleGlass(tint: glassTint))
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.88, haptic: isLoading ? .mediumImpact : .lightImpact))
        .disabled(!isActionable)
        .disabled(isStopping)
        .animation(.easeOut(duration: 0.18), value: isLoading)
        .animation(.easeOut(duration: 0.18), value: isStopping)
        .animation(.easeOut(duration: 0.18), value: sendEnabled)
        .accessibilityLabel(isStopping ? "正在停止生成" : (isLoading ? "停止生成" : "发送消息"))
    }

    private var iconColor: Color {
        if isLoading { return .white }
        // 启用时白色箭头叠在 accent 玻璃上;禁用时用 muted(与左侧「+」同档),
        // 比更淡的 muted2 在深色玻璃上更清晰,不再暗淡。
        return sendEnabled ? .white : AmberTheme.muted
    }

    private var glassTint: Color? {
        if isLoading { return AmberTheme.accentRed }
        return sendEnabled ? AmberTheme.accent : nil
    }
}

@MainActor
final class ComposerInputController {
    weak var textView: UITextView?

    func currentText() -> String? {
        textView?.text
    }

    func committedText() -> String? {
        guard let textView else { return nil }
        textView.unmarkText()
        return textView.text
    }
}

struct ComposerInputTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isFocused: Binding<Bool>
    var isEnabled: Bool
    var sendOnEnter: Bool
    var controller: ComposerInputController
    var onSubmit: () -> Void

    private let minHeight: CGFloat = 40
    private let maxLines: CGFloat = 5

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        controller.textView = textView
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = UIColor(AmberTheme.accent)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .interactive
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = textView
        if textView.markedTextRange == nil, textView.text != text {
            textView.text = text
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.returnKeyType = sendOnEnter ? .send : .default
        context.coordinator.updateFocus(for: textView)
        context.coordinator.updateHeight(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        if coordinator.controller.textView === uiView {
            coordinator.controller.textView = nil
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerInputTextView
        let controller: ComposerInputController
        private var lastMeasuredText: String?
        private var lastMeasuredWidth: CGFloat = 0
        private var lastMeasuredFont: UIFont?
        private var lastMeasuredInsets: UIEdgeInsets = .zero
        private var measurementRevision = 0
        private var focusUpdateScheduled = false

        init(parent: ComposerInputTextView) {
            self.parent = parent
            self.controller = parent.controller
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused.wrappedValue = false
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text {
                parent.text = textView.text
            }
            updateHeight(for: textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n", parent.sendOnEnter else { return true }
            if textView.markedTextRange != nil {
                return true
            }
            parent.onSubmit()
            return false
        }

        func updateFocus(for textView: UITextView) {
            let needsFocus = parent.isEnabled && parent.isFocused.wrappedValue && !textView.isFirstResponder
            let needsResign = !parent.isEnabled && textView.isFirstResponder
            guard needsFocus || needsResign, !focusUpdateScheduled else { return }
            focusUpdateScheduled = true
            // UIKit changes the responder chain synchronously. Doing that inside
            // updateUIView re-enters SwiftUI's AttributeGraph update on device.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.focusUpdateScheduled = false
                guard let textView, self.controller.textView === textView,
                      textView.window != nil else { return }
                if !self.parent.isEnabled, textView.isFirstResponder {
                    textView.resignFirstResponder()
                } else if self.parent.isEnabled, self.parent.isFocused.wrappedValue,
                          !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                }
            }
        }

        func updateHeight(for textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            let font = textView.font ?? .preferredFont(forTextStyle: .body)
            guard lastMeasuredText != textView.text || lastMeasuredWidth != width ||
                    lastMeasuredFont != font || lastMeasuredInsets != textView.textContainerInset else { return }
            lastMeasuredText = textView.text
            lastMeasuredWidth = width
            lastMeasuredFont = font
            lastMeasuredInsets = textView.textContainerInset
            measurementRevision &+= 1
            let revision = measurementRevision
            let fittingSize = textView.sizeThatFits(
                CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            )
            let maxHeight = ceil(font.lineHeight * parent.maxLines)
                + textView.textContainerInset.top
                + textView.textContainerInset.bottom
            let nextHeight = min(max(parent.minHeight, ceil(fittingSize.height)), maxHeight)
            let shouldScroll = fittingSize.height > maxHeight + 0.5
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.measurementRevision == revision,
                      self.controller.textView === textView else { return }
                if abs(self.parent.height - nextHeight) > 0.5 {
                    self.parent.height = nextHeight
                }
                if textView.isScrollEnabled != shouldScroll {
                    textView.isScrollEnabled = shouldScroll
                }
            }
        }
    }
}

struct ComposerDockCircleGlass: ViewModifier {
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // 单一 glassEffect 调用 —— 只让可空的 tint 参数在 accent ↔ nil 间变化,保持视图身份
            // 不变。若按 tint 有无拆成两条分支,SwiftUI 会移除/插入两个不同身份的玻璃视图并做
            // 交叉淡入,删字回到清玻璃时会闪过一帧发白。
            content.glassEffect(.regular.tint(tint).interactive(), in: Circle())
        } else {
            content
                .background {
                    Circle().fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.thinMaterial))
                }
                .overlay {
                    Circle().stroke(AmberTheme.border.opacity(0.42), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        }
    }
}

struct ContextRingButton: View {
    let snapshot: ChatContextSnapshot
    let compactState: ChatContextCompactState
    let action: () -> Void
    @State private var rotates = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0.5% 步进（18pt 环上约 0.28pt，肉眼不可辨）：流式每拍的占用增长不再
    /// 各自触发一段 0.3s 动画，避免环与玻璃按钮在整段流式中逐帧重算。
    private var displayedFillFraction: CGFloat {
        (snapshot.contextFillFraction * 200).rounded() / 200
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if compactState.isActive {
                    Circle()
                        .stroke(Color.blue.opacity(0.16), lineWidth: 3)
                    Circle()
                        .trim(from: 0.05, to: 0.78)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : (rotates ? 360 : 0)))
                    Image(systemName: "shippingbox")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.blue)
                } else {
                    // 轨道:强调色(用户可调的主题色,不一定是琥珀)的「很浅」版本,由 mix 混白得到。
                    // 不能用 accent.opacity(...):半透明强调色会和背后的玻璃混色,深色玻璃会把它压暗,
                    // 所以调透明度看着都一样。mix(with:.white) 才是真正把强调色调浅成不透明、背景无关的浅色。
                    Circle()
                        .stroke(AmberTheme.accent.mix(with: .white, by: 0.82), lineWidth: 3)
                    // 进度:随上下文增长用强调色覆盖填充,呈现增长效果。填充上限按模型真实
                    // contextWindow 计算(见 snapshot.contextFillFraction)。
                    Circle()
                        .trim(from: 0, to: displayedFillFraction)
                        .stroke(AmberTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: 34, height: 34)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: displayedFillFraction)
            .animation(
                reduceMotion ? nil : .linear(duration: 1.0).repeatForever(autoreverses: false),
                value: rotates
            )
            .modifier(ComposerDockCircleGlass(tint: nil))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.9, haptic: .selection))
        .onAppear { rotates = compactState.isActive && !reduceMotion }
        .onChange(of: compactState.isActive) { _, active in
            rotates = active && !reduceMotion
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            rotates = compactState.isActive && !shouldReduceMotion
        }
        .accessibilityLabel("上下文统计")
        .accessibilityValue(compactState.isActive ? "正在压缩上下文" : snapshot.occupancyText)
    }
}

struct ComposerContextPanel: View {
    let snapshot: ChatContextSnapshot
    let novelInjection: NovelInjectionPanelModel?
    let jevRunSummary: IOSJevRunSummary?

    init(
        snapshot: ChatContextSnapshot,
        novelInjection: NovelInjectionPanelModel? = nil,
        jevRunSummary: IOSJevRunSummary? = nil
    ) {
        self.snapshot = snapshot
        self.novelInjection = novelInjection
        self.jevRunSummary = jevRunSummary
    }

    var body: some View {
        ComposerPopoverSurface(width: popoverWidth) {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    VStack {
                        ZStack {
                            Circle()
                                .stroke(AmberTheme.surface2, lineWidth: 8)
                            Circle()
                                // 下一轮预计装载量 / 模型窗口。0 时空环。
                                .trim(from: 0, to: snapshot.contextFillFraction)
                                .stroke(
                                    AmberTheme.accent,
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 52, height: 52)
                    }
                    .frame(width: 68)

                    VStack(spacing: 8) {
                        ComposerContextCompactStatRow(
                            label: "总消息数",
                            value: "\(snapshot.messageCount)"
                        )
                        if let novelInjection, novelInjection.hasReceipt {
                            ComposerContextCompactStatRow(
                                label: "本次注入",
                                value: "\(ChatContextSnapshot.formatTokenCount(novelInjection.estimatedInputTokens)) / \(ChatContextSnapshot.formatTokenCount(novelInjection.maxEstimatedInputTokens))"
                            )
                        }
                        ComposerContextCompactStatRow(
                            label: "上下文",
                            value: snapshot.occupancyText
                        )
                        ComposerContextCompactStatRow(label: "速度", value: snapshot.speedText)
                        ComposerContextCompactStatRow(label: "缓存命中率", value: snapshot.cacheHitRateText)
                    }
                    .frame(maxWidth: .infinity)
                }

                if let novelInjection {
                    Divider()
                    NovelInjectionPanelDetails(model: novelInjection)
                }

                if let jevRunSummary, jevRunSummary.decisions > 0 {
                    Divider()
                    ComposerJevRunSummaryDetails(summary: jevRunSummary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private var popoverWidth: CGFloat {
        novelInjection != nil || (jevRunSummary?.decisions ?? 0) > 0 ? 300 : 248
    }
}

private struct ComposerJevRunSummaryDetails: View {
    let summary: IOSJevRunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IOSAppLocalization.string("本轮 Jev 判断", defaultValue: "本轮 Jev 判断"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)

            ComposerContextCompactStatRow(
                label: "判断次数",
                value: formattedCount(summary.decisions, unit: "次")
            )
            ComposerContextCompactStatRow(
                label: "记忆选中",
                value: summary.memorySelected.map { formattedCount($0, unit: "条") } ?? missingValue
            )
            ComposerContextCompactStatRow(
                label: "注入筛查命中",
                value: summary.memoryInjectionHits.map { formattedCount($0, unit: "条") } ?? missingValue
            )
            ComposerContextCompactStatRow(
                label: "隐藏字符",
                value: summary.hiddenCharacters.map { formattedCount($0, unit: "字") } ?? missingValue
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(IOSAppLocalization.string("所选模型 ID", defaultValue: "所选模型 ID"))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                Text(summary.selectedModelId ?? missingValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(summary.selectedModelId == nil ? AmberTheme.muted : AmberTheme.foreground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var missingValue: String {
        IOSAppLocalization.string("暂无数据", defaultValue: "暂无数据")
    }

    private func formattedCount(_ count: Int, unit: String) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return "\(number) \(IOSAppLocalization.string(unit, defaultValue: unit))"
    }
}

private struct NovelInjectionPanelDetails: View {
    let model: NovelInjectionPanelModel

    var body: some View {
        if model.hasReceipt {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("设定条目")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)

                    if model.materials.isEmpty {
                        Text("本次未注入设定条目")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    } else {
                        ForEach(model.materials) { material in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "book.closed")
                                    .font(.caption2)
                                    .foregroundStyle(AmberTheme.accent)
                                Text(material.title)
                                    .font(.caption)
                                    .foregroundStyle(AmberTheme.foreground)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text(material.kindTitle)
                                    .font(.caption2)
                                    .foregroundStyle(AmberTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                VStack(spacing: 8) {
                    ComposerContextCompactStatRow(
                        label: "剧情状态",
                        value: IOSAppLocalization.string(
                            model.includesPlotState ? "已携带" : "未携带",
                            defaultValue: model.includesPlotState ? "已携带" : "未携带"
                        )
                    )
                    ComposerContextCompactStatRow(
                        label: "会话窗口",
                        value: IOSAppLocalization.formatted(
                            "%lld 轮",
                            defaultValue: "%lld 轮",
                            arguments: [Int64(model.recentMessageRoundCount)]
                        )
                    )
                    if model.budgetExcludedItemCount > 0 {
                        ComposerContextCompactStatRow(
                            label: "预算未纳入",
                            value: IOSAppLocalization.formatted(
                                "%lld 项",
                                defaultValue: "%lld 项",
                                arguments: [Int64(model.budgetExcludedItemCount)]
                            )
                        )
                    }
                }
            }
        } else {
            Text("尚无生成上下文记录")
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ComposerContextCompactStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(IOSAppLocalization.string(label, defaultValue: label))
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)

            Spacer(minLength: 10)

            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

struct ComposerPopoverDivider: View {
    let index: Int

    var body: some View {
        if index > 0 {
            Divider()
                .overlay(AmberTheme.borderSoft)
                .padding(.leading, 44)
        }
    }
}

struct ComposerPopoverSurface<Content: View>: View {
    let width: CGFloat
    let content: Content

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: width)
            .amberGlass(cornerRadius: 14, interactive: false)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.border.opacity(0.75), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 22, y: 5)
    }
}
