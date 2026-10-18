import SwiftUI
import UIKit
import Shared

/// The compact identity/status projection used by a subagent capsule.
///
/// The model output is deliberately kept out of the row. A dispatch can return
/// a long report and that report must never become a continuously remeasured
/// label in the chat timeline. The capsule only gets a bounded role name,
/// status, and one short work hint; the detail sheet remains the place for the
/// full objective and report.
struct ChatSubAgentCapsulePresentation: Equatable {
    let identity: String
    let displayName: String
    let status: String
    let workSummary: String?
    /// The child conversation that owns this orchestration request. This is
    /// intentionally kept separate from the display identity so a dynamic
    /// name can be changed without losing the durable run lookup key.
    let threadID: String?
    /// Only successful spawn/followup receipts may be reconciled with a child
    /// run. A failed request can still contain a target id, but its old child
    /// status must never repaint the failed tool capsule as completed.
    let hasAcceptedReceipt: Bool

    var statusLine: String {
        guard let workSummary, !workSummary.isEmpty else { return status }
        return "\(status) · \(workSummary)"
    }
}

/// Runtime-only projection for orchestration capsules. The tool receipt says
/// that a request was accepted; this value says what the child run actually
/// did. It is intentionally not persisted back into the historical tool part.
enum ChatSubAgentRunVisualState: Equatable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case unknown

    init?(rawStatus: String?) {
        guard let rawStatus else { return nil }
        let normalized = rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized != "none" else { return nil }
        switch normalized {
        case "created", "queued", "pending", "waiting", "waiting_user", "waiting_external",
             "awaiting_permission", "recovery_pending", "resumable":
            self = .queued
        case "started", "running":
            self = .running
        case "completed", "complete", "done":
            self = .completed
        case "failed", "failure", "error":
            self = .failed
        case "cancelled", "canceled", "interrupted":
            self = .cancelled
        case "outcome_unknown", "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    var stepState: ChatToolStepState {
        switch self {
        case .queued, .completed:
            .done
        case .unknown:
            // The child may have produced an irreversible side effect before
            // the app lost its outcome. Reuse the existing exclamation slot
            // so this cannot be mistaken for a successful green dot.
            .failed
        case .running:
            .active
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    /// A dot is reserved for an accepted request whose work is still queued.
    /// An unknown outcome uses the exclamation slot instead of looking healthy.
    var usesPendingIndicator: Bool {
        switch self {
        case .queued:
            true
        case .running, .completed, .failed, .cancelled, .unknown:
            false
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .queued:
            IOSAppLocalization.string("已排队", defaultValue: "已排队")
        case .running:
            IOSAppLocalization.string("进行中", defaultValue: "进行中")
        case .completed:
            IOSAppLocalization.string("已完成", defaultValue: "已完成")
        case .failed:
            IOSAppLocalization.string("执行失败", defaultValue: "执行失败")
        case .cancelled:
            IOSAppLocalization.string("已取消", defaultValue: "已取消")
        case .unknown:
            IOSAppLocalization.string("状态未知", defaultValue: "状态未知")
        }
    }
}

struct ChatSubAgentPixelAvatar: View {
    let identity: String
    var size: CGFloat = 20
    /// While a child run is active the sprite loops its 4-step pixel cycle
    /// (stand → crouch → hop …); queued and terminal states stay on the base
    /// frame so motion itself signals "working".
    var isRunning: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isRunning, !reduceMotion {
                TimelineView(.periodic(from: .now, by: frameInterval)) { context in
                    sprite(step: step(at: context.date))
                }
            } else {
                sprite(step: 0)
            }
        }
        // Frame swaps change pixel content only; the fixed frame keeps the
        // surrounding row layout perfectly still.
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var frameInterval: TimeInterval {
        ChatSubAgentPixelSpriteLibrary.frameInterval(for: identity)
    }

    private func step(at date: Date) -> Int {
        let tick = Int(date.timeIntervalSinceReferenceDate / frameInterval)
        let phase = ChatSubAgentPixelSpriteLibrary.animationPhase(for: identity)
        return (tick + phase) % ChatSubAgentPixelSpriteLibrary.animationStepCount
    }

    @ViewBuilder
    private func sprite(step: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(4, size * 0.24), style: .continuous)
                .fill(ChatSubAgentPixelSpriteLibrary.background(for: identity))
            ForEach(ChatSubAgentPixelSpriteLibrary.animatedLayers(
                forSprite: ChatSubAgentPixelSpriteLibrary.spriteIndex(for: identity),
                identity: identity,
                step: step
            )) { layer in
                HomePixelSitShape(bits: layer.bits)
                    .fill(layer.color)
            }
            .padding(size * 0.10)
        }
    }
}

