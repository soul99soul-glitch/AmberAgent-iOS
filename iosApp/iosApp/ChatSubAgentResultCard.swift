import SwiftUI
@preconcurrency import Shared

/// A completed subagent report shown on the assistant side of the chat.
///
/// The card receives the persisted mailbox message so its identity and body are
/// resolved by the same bridge that created the message. The report is rendered
/// as one static Markdown document; there is no typewriter or streaming state.
struct ChatSubAgentResultCard: View {
    private let sender: String
    private let displayText: String
    private let displaySetting: DisplaySetting?
    private let summary: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded: Bool

    init(message: UIMessage, displaySetting: DisplaySetting? = nil) {
        let bridge = IosMailboxMessageBridge.shared
        let textParts = message.parts.compactMap { $0 as? UIMessagePart.Text }
        self.init(
            sender: bridge.sender(message: message)
                ?? (bridge.kind(message: message) == "FINAL_ANSWER" ? "subagent" : "agent"),
            displayText: textParts
                .map { bridge.displayText(part: $0) }
                .joined(separator: "\n\n"),
            displaySetting: displaySetting
        )
    }

    init(
        sender: String,
        displayText: String,
        displaySetting: DisplaySetting? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.sender = sender
        self.displayText = displayText
        self.displaySetting = displaySetting
        self.summary = Self.compactSummary(displayText)
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        ChatSubAgentResultCardLayout(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                header

                if isExpanded {
                    resultBody
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            // Clip the animated content, not the glass surface or its shadow.
            // Removed text can fade only inside the shrinking card bounds.
            .clipShape(resultShape)
            .resultCardSurface(shape: resultShape, reduceTransparency: reduceTransparency)
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                ChatMarkdownOpenURLPolicy.result(for: url)
            }
        )
    }

    private var resultShape: ChatSubAgentResultShape {
        ChatSubAgentResultShape(expansion: isExpanded ? 1 : 0)
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                ChatSubAgentPixelAvatar(
                    identity: "dynamic:\(displayName.lowercased())",
                    size: 20
                )

                identityLabels

                Spacer(minLength: 0)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AmberTheme.muted)
                    .frame(width: 16, height: 20)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayTitle) \(summary)")
        .accessibilityValue(
            isExpanded
                ? IOSAppLocalization.string("已展开", defaultValue: "已展开")
                : IOSAppLocalization.string("已收起", defaultValue: "已收起")
        )
        .accessibilityHint(
            IOSAppLocalization.string("轻点展开或收起子代理结果", defaultValue: "轻点展开或收起子代理结果")
        )
    }

    private var identityLabels: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Text(displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(summary)
                .font(.caption)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
        }
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
    }

    @ViewBuilder
    private var resultBody: some View {
        if displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(IOSAppLocalization.string("暂无结果", defaultValue: "暂无结果"))
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            AmberMarkdownView(markdown: displayText, displaySetting: displaySetting, style: .compact)
                .font(.subheadline)
                .foregroundStyle(AmberTheme.foreground)
        }
    }

    private var displayTitle: String {
        "@\(displayName)"
    }

    /// Keep an already-short result heading; never turn a long report into a
    /// clipped sentence or infer that a failed operation succeeded.
    static func compactSummary(_ text: String) -> String {
        let firstLine = text.prefix(100).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let heading = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*` >-\t。.!！"))
        if !heading.isEmpty, heading.count <= 7 {
            return heading
        }
        return String(IOSAppLocalization.string("已返回结果", defaultValue: "已返回结果").prefix(7))
    }

    private var displayName: String {
        let normalized = sender
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let name = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !name.isEmpty else {
            return IOSAppLocalization.string("子代理", defaultValue: "子代理")
        }
        if name.lowercased() == "root" {
            return IOSAppLocalization.string("主代理", defaultValue: "主代理")
        }
        return name
    }
}

/// Keep the collapsed capsule compact while letting an expanded report use the
/// same proposed chat-column width as ordinary assistant content. Unlike a
/// fixed frame, short collapsed results can still hug their content.
private struct ChatSubAgentResultCardLayout: Layout {
    let isExpanded: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 340
        if isExpanded {
            return content.sizeThatFits(
                ProposedViewSize(width: max(0, available), height: nil)
            )
        }
        let limit = min(300, max(0, available * 0.88))
        let width = min(limit, content.sizeThatFits(.unspecified).width)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

/// Use the actual height for capsule ends, including accessibility sizes.
/// Interpolating the radius keeps the clip and glass aligned during expansion.
struct ChatSubAgentResultShape: Shape {
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let capsuleRadius = min(rect.width, rect.height) / 2
        let radius = capsuleRadius + (min(18, capsuleRadius) - capsuleRadius) * expansion
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

private extension View {
    @ViewBuilder
    func resultCardSurface(shape: ChatSubAgentResultShape, reduceTransparency: Bool) -> some View {
        if reduceTransparency {
            self
                .background(AmberTheme.surface2, in: shape)
                .overlay { shape.stroke(AmberTheme.border, lineWidth: 0.8) }
        } else if #available(iOS 26.0, *) {
            self
                .background(AmberTheme.glass.opacity(0.35), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(.white.opacity(0.65), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.10), radius: 12, y: 2)
        }
    }
}
