import SwiftUI
@preconcurrency import Shared

/// Baseline repair for commit 66eb0c29: the Duet redesign referenced these
/// types but their definitions were never committed, so the tree could not
/// compile. These minimal faithful definitions match every call site; the
/// task-stream thread owns the real versions and will supersede these on merge.

/// Display identity key for the sub-agent pixel avatar — the capsule
/// presentation's `identity` string ("role:x" / "dynamic:x" / "call:x").
typealias ChatSubAgentAvatarIdentity = String

/// Simplified status shown by the Duet task-center row's status tag; the full
/// `IOSAdvancedTaskStatus` keeps its eight-case fidelity everywhere else.
enum IOSSubAgentActivityStatus: Equatable {
    case running
    case completed
    case failed
    case cancelled

    init(_ status: IOSAdvancedTaskStatus) {
        switch status {
        case .queued, .running, .approvalRequired:
            self = .running
        case .completed:
            self = .completed
        case .failed, .timedOut:
            self = .failed
        case .cancelled, .interrupted:
            self = .cancelled
        }
    }
}

/// Destinations the Duet workspace drawer tiles can open. Maps 1:1 onto
/// `Route` via `route`; kept distinct so the drawer vocabulary stays explicit.
enum RouterDestination {
    case search
    case novelCreation
    case board
    case council
    case miniApps
    case webMount
    case macTasks
    case settings
    case account

    var route: Route {
        switch self {
        case .search: .search(initialQuery: "")
        case .novelCreation: .novelCreation
        case .board: .board
        case .council: .council
        case .miniApps: .miniApps
        case .webMount: .webMount
        case .macTasks: .macTasks
        case .settings: .settings
        case .account: .account
        }
    }
}

extension ChatPhoneToolGrouping {
    /// Step-level outcome probe used by the task-stream rollup. Mirrors the
    /// group-summary path: empty output can't lose a result, otherwise the
    /// cached presentation's `isOutcomeUnknown` is authoritative.
    enum StepInspect {
        static func hasUnknownOutcome(_ tool: UIMessagePart.Tool) -> Bool {
            guard !tool.output.isEmpty else { return false }
            return ChatPhoneToolPresentation.cached(
                toolName: tool.toolName,
                executed: true,
                analysis: ChatToolOutputFormatter.analysis(for: tool),
                language: ChatPhoneToolPresentation.currentLanguageKey()
            ).isOutcomeUnknown
        }
    }
}

extension ChatToolMediaGallery {
    /// Media URLs carried by a tool's output — same projection the gallery
    /// renders (`ChatMediaItem.toolImages`), reduced to plain URLs.
    static func mediaURLs(in tool: UIMessagePart.Tool) -> [String] {
        ChatMediaItem.toolImages(tool.output).map(\.url)
    }
}

/// Compact cloud-native task section for the Duet task-center sheet — shows
/// /v2/work-items rows inside the sheet's List; the board button below the
/// section owns navigation. Read-only: cancel/retry live on the board.
struct MacGatewayCloudTaskSection: View {
    let gateway: MacGatewayStore

    var body: some View {
        if !gateway.cloudTasks.isEmpty {
            Section(IOSAppLocalization.string("云端原生任务", defaultValue: "云端原生任务")) {
                ForEach(gateway.cloudTasks.prefix(10)) { record in
                    HStack(spacing: 10) {
                        Image(systemName: record.state?.iconName ?? "clock")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AmberTheme.accent)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: record.displayTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AmberTheme.foreground)
                            Text(verbatim: gateway.agentDisplayName(for: record.agentId) + " · " + record.summaryLine)
                                .font(.caption)
                                .foregroundStyle(AmberTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let state = record.state {
                            Text(verbatim: state.displayTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(state.isTerminal ? AmberTheme.muted : AmberTheme.accent)
                        }
                    }
                }
            }
        }
    }
}
