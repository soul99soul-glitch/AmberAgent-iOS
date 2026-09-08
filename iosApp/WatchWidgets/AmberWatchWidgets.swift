import Foundation
import SwiftUI
import WidgetKit

private enum AmberWatchWidgetKind {
    static let ask = "AmberWatchAskWidget"
    static let note = "AmberWatchNoteWidget"
    static let recent = "AmberWatchRecentWidget"
    static let currentTask = "AmberWatchCurrentTaskWidget"
}

private enum AmberWatchWidgetAction {
    case ask
    case note
    case recent

    var title: String {
        switch self {
        case .ask: AmberWatchWidgetCopy.localized("Ask Amber", fallback: "Ask Amber")
        case .note: AmberWatchWidgetCopy.localized("Take a note", fallback: "Take a note")
        case .recent: AmberWatchWidgetCopy.localized("Recent records", fallback: "Recent records")
        }
    }

    var symbol: String {
        switch self {
        case .ask: "sparkles"
        case .note: "square.and.pencil"
        case .recent: "clock.arrow.circlepath"
        }
    }
}

private enum AmberWatchWidgetCopy {
    static func localized(
        _ key: String,
        fallback: String,
        languageCode: String? = nil
    ) -> String {
        WatchTaskLocalization.string(
            key,
            defaultValue: fallback,
            languageCode: languageCode ?? WatchWidgetCache.load()?.languageCode
        )
    }

    static func formatted(
        _ key: String,
        fallback: String,
        argument: CVarArg,
        languageCode: String?
    ) -> String {
        WatchTaskLocalization.formatted(
            key,
            defaultValue: fallback,
            arguments: [argument],
            languageCode: languageCode
        )
    }
}

private enum AmberWatchDeepLink {
    private static var scheme: String {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "AmberWatchURLScheme"
        ) as? String,
        !value.isEmpty,
        !value.contains("$(") else {
            return "amber-watch"
        }
        return value
    }

    static func ask() -> URL? { endpoint("ask") }
    static func note() -> URL? { endpoint("note") }
    static func recent() -> URL? { endpoint("recent") }

    static func task(runId: String) -> URL? {
        guard !runId.isEmpty else { return recent() }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "task"
        components.queryItems = [URLQueryItem(name: "runId", value: runId)]
        return components.url
    }

    private static func endpoint(_ host: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        return components.url
    }
}

private struct AmberWatchQuickEntry: TimelineEntry {
    let date: Date
}

private struct AmberWatchQuickProvider: TimelineProvider {
    let action: AmberWatchWidgetAction

    func placeholder(in context: Context) -> AmberWatchQuickEntry {
        AmberWatchQuickEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (AmberWatchQuickEntry) -> Void
    ) {
        completion(AmberWatchQuickEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<AmberWatchQuickEntry>) -> Void
    ) {
        let entry = AmberWatchQuickEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private struct AmberWatchQuickView: View {
    let action: AmberWatchWidgetAction

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: action.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(action.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .containerBackground(for: .widget) {
            Color.black
        }
        .widgetURL(url)
    }

    private var url: URL? {
        switch action {
        case .ask: AmberWatchDeepLink.ask()
        case .note: AmberWatchDeepLink.note()
        case .recent: AmberWatchDeepLink.recent()
        }
    }
}

private struct AmberWatchTaskEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchTaskSnapshot
}

private struct AmberWatchTaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> AmberWatchTaskEntry {
        AmberWatchTaskEntry(date: Date(), snapshot: .idle)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (AmberWatchTaskEntry) -> Void
    ) {
        completion(AmberWatchTaskEntry(
            date: Date(),
            snapshot: WatchWidgetCache.load() ?? .idle
        ))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<AmberWatchTaskEntry>) -> Void
    ) {
        let now = Date()
        let snapshot = WatchWidgetCache.load() ?? .idle
        var entries = [AmberWatchTaskEntry(date: now, snapshot: snapshot)]

        if snapshot.isActive,
           !snapshot.isStale,
           !["completed", "failed", "cancelled"].contains(snapshot.phase) {
            let expiration = snapshot.updatedAt.addingTimeInterval(
                WatchSnapshotFreshnessPolicy.staleAfter
            )
            if expiration > now {
                var stale = snapshot
                stale.phase = "stale"
                stale.stage = "stale"
                stale.detail = nil
                stale.metricText = nil
                stale.decision = nil
                stale.actions = []
                stale.isStale = true
                entries.append(AmberWatchTaskEntry(date: expiration, snapshot: stale))
            }
        }

        completion(Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(15 * 60))
        ))
    }
}

private struct AmberWatchTaskView: View {
    let entry: AmberWatchTaskEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: statusSymbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                Text("Amber")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if entry.snapshot.updatedAt != .distantPast {
                    Text(entry.snapshot.updatedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.7)
                }
            }
            Text(statusTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .containerBackground(for: .widget) {
            Color.black
        }
        .widgetURL(targetURL)
    }

    private var targetURL: URL? {
        if entry.snapshot.isActive {
            return AmberWatchDeepLink.task(runId: entry.snapshot.runId)
        }
        return AmberWatchDeepLink.recent()
    }

    private var isExpired: Bool {
        entry.snapshot.isStale
            || (isExpirable
                && entry.date.timeIntervalSince(entry.snapshot.updatedAt)
                    >= WatchSnapshotFreshnessPolicy.staleAfter)
    }

    private var isExpirable: Bool {
        entry.snapshot.isActive
            && !["completed", "failed", "cancelled"].contains(entry.snapshot.phase)
    }

    private var statusTitle: String {
        let languageCode = entry.snapshot.languageCode
        if isExpired {
            return AmberWatchWidgetCopy.localized(
                "State expired",
                fallback: "State expired",
                languageCode: languageCode
            )
        }
        switch entry.snapshot.phase {
        case "running":
            return AmberWatchWidgetCopy.localized(
                "Processing",
                fallback: "Processing",
                languageCode: languageCode
            )
        case "waitingForUser":
            return AmberWatchWidgetCopy.localized(
                "Waiting for your action",
                fallback: "Waiting for your action",
                languageCode: languageCode
            )
        case "reconnecting":
            return AmberWatchWidgetCopy.localized(
                "Reconnecting",
                fallback: "Reconnecting",
                languageCode: languageCode
            )
        case "completed":
            return AmberWatchWidgetCopy.localized(
                "Completed",
                fallback: "Completed",
                languageCode: languageCode
            )
        case "failed":
            return AmberWatchWidgetCopy.localized(
                "Failed",
                fallback: "Failed",
                languageCode: languageCode
            )
        case "cancelled":
            return AmberWatchWidgetCopy.localized(
                "Cancelled",
                fallback: "Cancelled",
                languageCode: languageCode
            )
        default:
            return AmberWatchWidgetCopy.localized(
                "No task in progress",
                fallback: "No task in progress",
                languageCode: languageCode
            )
        }
    }

    private var statusDetail: String {
        let languageCode = entry.snapshot.languageCode
        if isExpired {
            return AmberWatchWidgetCopy.localized(
                "Open Amber to see the latest status",
                fallback: "Open Amber to see the latest status",
                languageCode: languageCode
            )
        }
        if entry.snapshot.isActive {
            let time = entry.snapshot.updatedAt.formatted(
                date: .omitted,
                time: .shortened
            )
            return AmberWatchWidgetCopy.formatted(
                "Last synced %@",
                fallback: "Last synced %@",
                argument: time,
                languageCode: languageCode
            )
        }
        return AmberWatchWidgetCopy.localized(
            "Tap to view recent records",
            fallback: "Tap to view recent records",
            languageCode: languageCode
        )
    }

    private var statusSymbol: String {
        if isExpired { return "clock.badge.exclamationmark" }
        switch entry.snapshot.phase {
        case "running", "reconnecting": return "arrow.triangle.2.circlepath"
        case "waitingForUser": return "hand.raised.fill"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "cancelled": return "stop.circle"
        default: return "sparkles"
        }
    }

    private var statusColor: Color {
        if isExpired { return .yellow }
        switch entry.snapshot.phase {
        case "completed": return .green
        case "failed": return .red
        case "waitingForUser": return .orange
        default: return .orange
        }
    }
}

struct AmberWatchAskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: AmberWatchWidgetKind.ask,
            provider: AmberWatchQuickProvider(action: .ask)
        ) { _ in
            AmberWatchQuickView(action: .ask)
        }
        .configurationDisplayName("Ask Amber")
        .description("Start a question from your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct AmberWatchNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: AmberWatchWidgetKind.note,
            provider: AmberWatchQuickProvider(action: .note)
        ) { _ in
            AmberWatchQuickView(action: .note)
        }
        .configurationDisplayName("Take a note")
        .description("Save a note from your watch face.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct AmberWatchRecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: AmberWatchWidgetKind.recent,
            provider: AmberWatchQuickProvider(action: .recent)
        ) { _ in
            AmberWatchQuickView(action: .recent)
        }
        .configurationDisplayName("Recent records")
        .description("Open Amber's recent records.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct AmberWatchCurrentTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: AmberWatchWidgetKind.currentTask,
            provider: AmberWatchTaskProvider()
        ) { entry in
            AmberWatchTaskView(entry: entry)
        }
        .configurationDisplayName("Current task")
        .description("View the current task's private status.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct AmberWatchWidgets: WidgetBundle {
    var body: some Widget {
        AmberWatchAskWidget()
        AmberWatchNoteWidget()
        AmberWatchRecentWidget()
        AmberWatchCurrentTaskWidget()
    }
}
