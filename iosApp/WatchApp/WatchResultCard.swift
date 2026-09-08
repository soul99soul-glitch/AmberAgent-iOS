import SwiftUI

/// A compact preview of a real phone-authored result; the detail opens its full content.
struct WatchResultCard: View {
    let status: String
    let symbol: String
    let title: String
    let summary: String
    var updatedAt: Date? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .headline) private var titleSize = 23.0
    @ScaledMetric(relativeTo: .caption2) private var metadataSize = 14.0
    @ScaledMetric(relativeTo: .caption) private var summarySize = 12.5

    private let copper = Color(red: 0.91, green: 0.47, blue: 0.25)
    private let ivory = Color(red: 1, green: 0.97, blue: 0.91)

    var body: some View {
        Group {
            if typeSize >= .xxLarge {
                content(scale: 1)
                    .padding(14)
            } else {
                GeometryReader { geometry in
                    let scale = min(1, geometry.size.width / 192)
                    content(scale: scale)
                        .padding(.horizontal, 16 * scale)
                        .padding(.vertical, 13 * scale)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .aspectRatio(1.625, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.29, green: 0.14, blue: 0.085),
                                             Color(red: 0.10, green: 0.065, blue: 0.05),
                                             Color(red: 0.055, green: 0.035, blue: 0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(LinearGradient(colors: [copper.opacity(0.70), copper.opacity(0.25)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(status), \(title), \(summary)"))
    }

    private func content(scale: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 7 * scale) {
                Text(status)
                    .font(.system(size: metadataSize * scale, weight: .semibold))
                    .foregroundStyle(copper)
                    .lineLimit(1).minimumScaleFactor(0.8)
                timeLabel(scale: scale)
                Spacer(minLength: 0)
                Image(systemName: symbol == "checkmark.circle.fill" ? "doc" : symbol)
                    .font(.system(size: 20 * scale, weight: .medium))
                    .overlay {
                        if symbol == "checkmark.circle.fill" {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8 * scale, weight: .bold))
                                .offset(y: 3 * scale)
                        }
                    }
                    .foregroundStyle(copper)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: titleSize * scale, weight: .bold))
                .foregroundStyle(ivory)
                .lineLimit(typeSize >= .xxLarge ? 4 : 2, reservesSpace: typeSize < .xxLarge)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4 * scale)
            HStack(spacing: 8 * scale) {
                Text(summary)
                    .font(.system(size: summarySize * scale))
                    .foregroundStyle(ivory.opacity(0.58))
                    .lineLimit(typeSize >= .xxLarge ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(ivory.opacity(0.64))
                    .offset(y: -4 * scale)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func timeLabel(scale: Double) -> some View {
        if let updatedAt {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(locale)))
                    .font(.system(size: metadataSize * scale))
                    .foregroundStyle(ivory.opacity(0.53))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
}

extension WatchRecentActivity {
    var statusKey: String {
        if kind == "note" { return phase == "pending" ? "已存手表，待同步" : "记事已保存" }
        switch phase {
        case "failed": return "未能完成"
        case "cancelled": return "已取消"
        default: return "最近完成"
        }
    }

    var statusSymbol: String {
        if kind == "note" { return phase == "pending" ? "clock" : "square.and.pencil" }
        switch phase {
        case "failed": return "exclamationmark.circle.fill"
        case "cancelled": return "stop.circle"
        default: return "checkmark.circle.fill"
        }
    }
}
