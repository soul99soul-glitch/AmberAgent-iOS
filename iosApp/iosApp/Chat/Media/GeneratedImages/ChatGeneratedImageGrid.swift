import SwiftUI
import Shared
import SwiftStreamingMarkdown

struct ChatGeneratedImageGrid: View {
    let images: [UIMessagePart.Image]
    var toolCallID: String? = nil
    var toolInput: String?
    var onModify: (String, String, String) -> Void = { _, _, _ in }
    var allowsModify: Bool = true

    private var display: ChatGeneratedImageRequestDisplay {
        ChatGeneratedImageRequestDisplay(toolInput: toolInput)
    }

    var body: some View {
        Group {
            if images.count <= 1 {
                if let image = images.first {
                    singleCard {
                        ChatGeneratedImageTile(
                            urlString: image.url,
                            display: display,
                            onModify: onModify,
                            allowsModify: allowsModify,
                            toolCallID: toolCallID
                        )
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            ChatGeneratedImageTile(
                                urlString: image.url,
                                display: display,
                                onModify: onModify,
                                allowsModify: allowsModify,
                                toolCallID: toolCallID
                            )
                                .frame(width: display.multiCardWidth)
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func singleCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let maxWidth = display.singleCardMaxWidth {
            content().frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ChatGeneratedImageLoadingPlaceholder: View {
    let toolInput: String
    let isAnimating: Bool
    let toolCallID: String

    private var display: ChatGeneratedImageRequestDisplay {
        ChatGeneratedImageRequestDisplay(toolInput: toolInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholder
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var placeholder: some View {
        if display.requestedCount > 1 {
            // Match ChatGeneratedImageGrid success layout (horizontal strip).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<display.requestedCount, id: \.self) { _ in
                        ChatGeneratedImageDotPlaceholder(
                            aspectRatio: display.aspectRatio,
                            isAnimating: isAnimating
                        )
                            .frame(width: display.multiCardWidth)
                            .chatIslandToolAnchorHighlight(
                                toolCallID: toolCallID,
                                cornerRadius: AmberTheme.radiusXLarge
                            )
                    }
                }
                .padding(.trailing, 16)
            }
        } else if let maxWidth = display.singleCardMaxWidth {
            ChatGeneratedImageDotPlaceholder(
                aspectRatio: display.aspectRatio,
                isAnimating: isAnimating
            )
                .frame(maxWidth: maxWidth, alignment: .leading)
                .chatIslandToolAnchorHighlight(
                    toolCallID: toolCallID,
                    cornerRadius: AmberTheme.radiusXLarge
                )
        } else {
            ChatGeneratedImageDotPlaceholder(
                aspectRatio: display.aspectRatio,
                isAnimating: isAnimating
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatIslandToolAnchorHighlight(
                    toolCallID: toolCallID,
                    cornerRadius: AmberTheme.radiusXLarge
                )
        }
    }
}

struct ChatGeneratedImageFailureCard: View {
    let reason: String
    let toolCallID: String

    var body: some View {
        HStack {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AmberTheme.accentRed)
                    .frame(width: 18, height: 18)

                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.foreground2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(AmberTheme.accentRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AmberTheme.accentRed.opacity(0.20), lineWidth: 0.5)
            }
            .chatIslandToolAnchorHighlight(toolCallID: toolCallID, cornerRadius: 10)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatGeneratedImageRequestDisplay {
    var aspectRatio: CGFloat
    var aspectRatioTitle: String
    var requestedCount: Int

    var singleCardMaxWidth: CGFloat? {
        aspectRatio < 1 ? 236 : nil
    }

    let multiCardWidth: CGFloat = 280

    init(toolInput: String?) {
        let object = Self.jsonObject(from: toolInput)
        let parsedAspect = IOSImageAspectRatio(toolValue: object?["aspect_ratio"] as? String)
        self.aspectRatio = CGFloat(parsedAspect.renderedAspectRatio)
        self.aspectRatioTitle = parsedAspect.title
        self.requestedCount = min(max(Self.intValue(object?["count"]) ?? 1, 1), 4)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func jsonObject(from input: String?) -> [String: Any]? {
        guard let input else { return nil }
        guard let data = input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

}

/// Shared animated dot surface used by image generation placeholders and MiniApp
/// streaming cards. Kept internal so chat surfaces can reuse the same motion language.
struct ChatGeneratedImageDotPlaceholder: View {
    let aspectRatio: CGFloat
    var cornerRadius: CGFloat = AmberTheme.radiusXLarge
    var showsChrome: Bool = true
    /// When false, freeze at a calm phase (no 30fps TimelineView).
    var isAnimating: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let period: TimeInterval = 2.2

    var body: some View {
        Group {
            if reduceMotion || !isAnimating {
                Canvas { context, size in
                    drawDots(context: context, size: size, phase: 0.28)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        drawDots(context: context, size: size, phase: phase(at: timeline.date))
                    }
                }
            }
        }
        .modifier(ChatWidthDrivenAspectRatio(aspectRatio: aspectRatio))
        .background(
            showsChrome ? AmberTheme.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            if showsChrome {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AmberTheme.borderSoft, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }

    private func drawDots(context: GraphicsContext, size: CGSize, phase: CGFloat) {
        let padding: CGFloat = 20
        let spacing: CGFloat = 14
        let dotRadius: CGFloat = 1.6
        let drawingWidth = max(size.width - padding * 2, spacing)
        let drawingHeight = max(size.height - padding * 2, spacing)
        let columns = max(Int(drawingWidth / spacing), 1)
        let rows = max(Int(drawingHeight / spacing), 1)
        let xOffset = padding + (drawingWidth - CGFloat(columns - 1) * spacing) / 2
        let yOffset = padding + (drawingHeight - CGFloat(rows - 1) * spacing) / 2
        let diagonalRange = max(CGFloat(columns + rows), 1)

        for column in 0..<columns {
            for row in 0..<rows {
                let diagonal = CGFloat(column + row) / diagonalRange
                let wavePhase = (phase + diagonal).truncatingRemainder(dividingBy: 1)
                let distance = abs(wavePhase - 0.5) * 2
                let energy = max(0, 1 - distance)
                let alpha = min(max(0.10 + 0.40 * energy, 0.08), 0.54)
                let radius = dotRadius + 0.7 * energy
                let color = energy > 0.64
                    ? AmberTheme.accent.opacity(0.18 + 0.18 * energy)
                    : AmberTheme.muted.opacity(alpha)
                let x = xOffset + CGFloat(column) * spacing
                let y = yOffset + CGFloat(row) * spacing
                let rect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(color)
                )
            }
        }
    }
}

/// 宽度驱动的宽高比:自定义 Layout 在同一布局 pass 内由宽度 proposal 直接推导
/// 高度(height = width / aspectRatio),首帧即正确,消除旧实现「fallback 220 →
/// onGeometryChange 回填宽度再修正」的一帧高度跳变(cell 新建/复用重进视口都会重演)。
/// UIHostingConfiguration self-sizing 的垂直 proposal 是 estimated cell 高度,不可信;
/// 宽度 proposal 始终正确,所以只信宽度。
struct ChatGeneratedImageAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.985)
            .onAppear {
                guard !appeared else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
                    appeared = true
                }
            }
    }
}

struct ChatGeneratedImageActionLabel: View {
    let title: String
    let systemImage: String
    let foreground: Color
    let fill: Color
    var isWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(foreground)
            } else {
                Image(systemName: systemImage)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }

            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(fill, in: Capsule())
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: title)
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: systemImage)
    }
}

