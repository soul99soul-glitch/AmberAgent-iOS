import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
@preconcurrency import WebKit
#endif
@preconcurrency import Network
@preconcurrency import Shared
struct IOSDeepReadHistoryRow: View {
    let task: IOSDeepReadTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)

                Text(verbatim: historySummary)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: task.status.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(verbatim: IOSBoardDateFormatters.localizedMonthDayTime(
                    Date(timeIntervalSince1970: TimeInterval(task.updatedAt) / 1_000)
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(AmberTheme.muted2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var historySummary: String {
        let sourceSummary = task.localizedSourceSummary
        func joined(_ label: String) -> String { sourceSummary.isEmpty ? label : "\(label) · \(sourceSummary)" }
        if let primary = task.sources.first(where: DeepReadCloseReader.isPrimary) {
            return joined(primary.metadata[DeepReadCloseReader.originalOnlyKey] == "true" ? "原文" : "精读")
        }
        if let synthesis = DeepReadSynthesisTemplate(rawValue: task.templateId) { return joined(synthesis.name) }
        let template = task.template
        let isBuiltIn = template.id == IOSDeepReadTemplate.magazine.id
            || template.id == IOSDeepReadTemplate.editorial.id
            || template.id == IOSDeepReadTemplate.analysis.id
        let templateName = isBuiltIn
            ? IOSAppLocalization.string(template.name, defaultValue: template.name)
            : template.name
        return joined(templateName)
    }

    private var iconName: String {
        switch task.status {
        case .queued: "clock"
        case .running: "clock.arrow.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .unsupported: "nosign"
        }
    }

    private var tint: Color {
        switch task.status {
        case .queued, .running: AmberTheme.accentAmber
        case .succeeded: AmberTheme.accentGreen
        case .failed: AmberTheme.accentRed
        case .unsupported: AmberTheme.muted2
        }
    }
}

struct IOSHotTopicRow: View {
    let topic: IOSHotTopic
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("#\(topic.bestRank)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AmberTheme.accent)
                Text("\(topic.sourceCount) 源")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AmberTheme.muted2)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(topic.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                Text(topic.sources.prefix(4).map { "\($0.providerName) #\($0.rank)" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct IOSHotProviderItemRow: View {
    let provider: IOSHotListProviderSnapshot
    let item: IOSHotlistItem

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(item.rank)")
                .font(.caption.weight(.bold))
                .foregroundStyle(AmberTheme.accent)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.presentationTitle)
                    .font(.body)
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let heat = item.heat ?? item.score.map(String.init), !heat.isEmpty {
                        Text("热度 \(heat)")
                    }
                    if provider.stale {
                        Text("缓存")
                    }
                    if item.url != nil {
                        Text("可抓取链接")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AmberTheme.muted2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
