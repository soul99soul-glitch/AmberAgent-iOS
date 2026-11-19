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
    @Environment(\.markdownLayoutInvalidationID) private var layoutInvalidationID
    @State private var isExpanded: Bool

    init(message: UIMessage, displaySetting: DisplaySetting? = nil) {
        let bridge = IosMailboxMessageBridge.shared
        let textParts = message.parts.compactMap { $0 as? UIMessagePart.Text }
        self.init(
            sender: bridge.sender(message: message)
                ?? (bridge.kind(message: message) == "FINAL_ANSWER" ? "subagent" : "agent"),
            displayText: textParts
                .map { IOSSubAgentOutputProjection.userFacingMailboxDisplayText(part: $0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        // `displayText` is already projected; render-time initialization must not decode envelopes.
        self.sender = sender
        self.displayText = displayText
        self.displaySetting = displaySetting
        self.summary = Self.compactSummary(displayText)
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let cardID = layoutInvalidationID ?? sender
        let _ = ChatTimelineRowLayoutInvalidation.markRowDirty(layoutInvalidationID)
        #if DEBUG
        let _ = ChatTimelineRowLayoutInvalidation.registerSubAgentCardToggle(id: cardID) {
            toggleExpansion()
        }
        #endif
        ChatSubAgentResultCardLayout(isExpanded: isExpanded, cardID: cardID) {
            ChatSubAgentResultStackLayout(isExpanded: isExpanded) {
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
        .environment(\.openURL, ChatMarkdownOpenURLPolicy.openURLAction)
    }

    private func toggleExpansion() {
        ChatTimelineRowLayoutInvalidation.markRowDirty(layoutInvalidationID)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            isExpanded.toggle()
        }
    }

    private var resultShape: ChatSubAgentResultShape {
        ChatSubAgentResultShape(expansion: isExpanded ? 1 : 0)
    }

    private var header: some View {
        Button {
            toggleExpansion()
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
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text(IOSAppLocalization.string("暂无结果", defaultValue: "暂无结果"))
                .font(.subheadline)
                .foregroundStyle(AmberTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let deliverable = AmberUnifiedTaskBuilder.extractDeliverableSummary(from: trimmed)
            VStack(alignment: .leading, spacing: 8) {
                if deliverable.needsDecision, let prompt = deliverable.decisionPrompt, !prompt.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(AmberTheme.accentAmber)
                            .frame(width: 2)
                            .padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(IOSAppLocalization.string("等我拍板", defaultValue: "等我拍板"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AmberTheme.accentAmber)
                            Text(prompt)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(AmberTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, 2)
                }

                AmberMarkdownView(markdown: displayText, displaySetting: displaySetting, style: .compact)
                    .font(.subheadline)
                    .foregroundStyle(AmberTheme.foreground)
            }
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
/// Measures only the header when collapsed so an outgoing `.transition(.opacity)`
/// body fades inside the shrinking card clip without holding the row height open.
private struct ChatSubAgentResultStackLayout: Layout {
    let isExpanded: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let header = subviews.first else { return .zero }
        let widthProposal = ProposedViewSize(width: proposal.width, height: nil)
        let headerSize = header.sizeThatFits(widthProposal)
        guard isExpanded, subviews.count > 1 else {
            return headerSize
        }
        var totalHeight = headerSize.height
        var maxWidth = headerSize.width
        for bodySubview in subviews.dropFirst() {
            let bodySize = bodySubview.sizeThatFits(widthProposal)
            totalHeight += bodySize.height
            maxWidth = max(maxWidth, bodySize.width)
        }
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let header = subviews.first else { return }
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        let headerSize = header.sizeThatFits(rowProposal)
        header.place(at: bounds.origin, anchor: .topLeading, proposal: rowProposal)
        var y = bounds.minY + headerSize.height
        for bodySubview in subviews.dropFirst() {
            let bodySize = bodySubview.sizeThatFits(rowProposal)
            bodySubview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: rowProposal
            )
            y += bodySize.height
        }
    }
}

private struct ChatSubAgentResultCardLayout: Layout {
    let isExpanded: Bool
    var cardID: String = ""

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
        let contentProposal = ProposedViewSize(width: bounds.width, height: nil)
        #if DEBUG
        if !cardID.isEmpty, let content = subviews.first {
            ChatTimelineRowLayoutInvalidation.placedSubAgentCardSizes[cardID] = content.sizeThatFits(contentProposal)
        }
        #endif
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: contentProposal
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

// MARK: - Task Deliverable Preview Sheet & Inline View

/// Single-layer deliverable conclusion preview for completed or checkpointed tasks in the Tasks panel.
struct AmberTaskDeliverablePreviewSheet: View {
    let item: AmberUnifiedTaskItem
    var onOpenDestination: ((AmberUnifiedTaskItem) -> Void)? = nil
    var onQuickDecision: ((AmberUnifiedTaskItem, AmberTaskQuickDecision) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                AmberTaskDeliverablePreviewContent(
                    item: item,
                    onOpenDestination: { task in
                        dismiss()
                        onOpenDestination?(task)
                    },
                    onQuickDecision: { task, decision in
                        dismiss()
                        onQuickDecision?(task, decision)
                    }
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle(IOSAppLocalization.string("交付结论", defaultValue: "交付结论"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IOSAppLocalization.string("完成", defaultValue: "完成")) {
                        dismiss()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                }
            }
        }
        .environment(\.openURL, ChatMarkdownOpenURLPolicy.openURLAction)
        .accessibilityIdentifier("chat.duet.tasks.deliverablePreviewSheet")
    }
}

struct AmberTaskDeliverablePreviewContent: View {
    let item: AmberUnifiedTaskItem
    var onBack: (() -> Void)? = nil
    var onOpenDestination: ((AmberUnifiedTaskItem) -> Void)? = nil
    var onQuickDecision: ((AmberUnifiedTaskItem, AmberTaskQuickDecision) -> Void)? = nil

    private var distinctBullets: [String] {
        item.deliverableBullets.filter { $0 != item.resultText }
    }

    var cleanedMarkdownBody: String? {
        guard let markdown = AmberUnifiedTaskBuilder.userFacingResultMarkdown(from: item.rawResultMarkdown),
              markdown != item.resultText else { return nil }
        return markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(IOSAppLocalization.string("返回任务列表", defaultValue: "返回任务列表"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(AmberTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.duet.tasks.deliverablePreviewBack")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(AmberUnifiedTaskBuilder.statusColor(for: item))
                        .frame(width: 6, height: 6)

                    Text(item.ownership.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AmberTheme.muted)

                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(AmberTheme.muted2)

                    Text(item.statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AmberUnifiedTaskBuilder.statusColor(for: item))

                    Spacer()
                }

                Text(item.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let decisionPrompt = item.decisionPrompt, !decisionPrompt.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(AmberTheme.accentAmber)
                            .frame(width: 2)
                            .padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(IOSAppLocalization.string("等我拍板", defaultValue: "等我拍板"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AmberTheme.accentAmber)

                            Text(decisionPrompt)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(AmberTheme.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !item.quickActions.isEmpty, let onQuickDecision {
                        HStack(spacing: 8) {
                            ForEach(item.quickActions) { decision in
                                Button {
                                    onQuickDecision(item, decision)
                                } label: {
                                    Text(decision.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(decision.isPrimary ? AmberTheme.accent : AmberTheme.foreground2)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            decision.isPrimary
                                                ? AmberTheme.accent.opacity(0.12)
                                                : AmberTheme.surface2,
                                            in: Capsule(style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
                .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AmberTheme.border, lineWidth: 0.6)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(IOSAppLocalization.string("核心结论", defaultValue: "核心结论"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AmberTheme.muted)

                if let headline = item.resultText, !headline.isEmpty {
                    Text(headline)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AmberTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.subtitle)
                        .font(.system(size: 13.5))
                        .foregroundStyle(AmberTheme.foreground2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !distinctBullets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(distinctBullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("·")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AmberTheme.muted)
                                Text(bullet)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AmberTheme.foreground2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AmberTheme.border, lineWidth: 0.6)
            }

            if let markdown = cleanedMarkdownBody {
                VStack(alignment: .leading, spacing: 8) {
                    Text(IOSAppLocalization.string("完整交付记录", defaultValue: "完整交付记录"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AmberTheme.muted)
                        .padding(.leading, 4)

                    AmberMarkdownView(markdown: markdown, displaySetting: nil, style: .compact)
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AmberTheme.border, lineWidth: 0.6)
                        }
                }
            }

            if item.destination != .none, let onOpenDestination {
                Button {
                    onOpenDestination(item)
                } label: {
                    HStack(spacing: 6) {
                        Text(destinationActionLabel(for: item.destination))
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(AmberTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AmberTheme.accent.opacity(0.10), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.duet.tasks.openDestinationFromPreview")
            }
        }
        .environment(\.openURL, ChatMarkdownOpenURLPolicy.openURLAction)
    }

    private func destinationActionLabel(for destination: AmberTaskDestination) -> String {
        switch destination {
        case .subAgentConversation:
            return IOSAppLocalization.string("打开对应子会话", defaultValue: "打开对应子会话")
        case .wakeConversation:
            return IOSAppLocalization.string("打开所属会话", defaultValue: "打开所属会话")
        case .cloudDialogueWorkItem:
            return IOSAppLocalization.string("打开云端对话", defaultValue: "打开云端对话")
        case .executionRecord:
            return IOSAppLocalization.string("查看执行记录", defaultValue: "查看执行记录")
        case .cloudTaskDetail:
            return IOSAppLocalization.string("查看云端任务详情", defaultValue: "查看云端任务详情")
        case .macBoard:
            return IOSAppLocalization.string("打开完整任务看板", defaultValue: "打开完整任务看板")
        case .none:
            return IOSAppLocalization.string("查看详情", defaultValue: "查看详情")
        }
    }
}
