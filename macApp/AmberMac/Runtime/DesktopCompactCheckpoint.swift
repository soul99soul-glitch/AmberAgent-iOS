import Foundation

/// One chained compaction checkpoint (schema v2).
///
/// The summary keeps the exact coverage it replaced and the checkpoints it folded in, so the next compaction
/// only has to read the new segment plus this handoff instead of re-summarising the whole prefix.
struct DesktopCompactCheckpoint: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 2

    var id = UUID()
    var schema = Self.schemaVersion
    /// 1 for the first summary, +1 for every summary of summaries.
    var level = 1
    /// Messages this checkpoint replaces (always a prefix of the stored transcript).
    var coveredMessageIDs: [UUID] = []
    /// Earlier checkpoints folded into this one.
    var coveredCompactIDs: [UUID] = []
    /// The handoff the model reads: fixed sections plus the facts that must survive verbatim.
    var handoff: String
    var createdAt = Date()
    var modelID: String?

    var textTokensHint: Int { DesktopContextBudget.estimate([DesktopMessage(role: .user, text: handoff)]) }
}

enum DesktopCompactChain {
    /// The fixed sections the summary must keep, mirroring the iOS/Android handoff contract.
    static let handoffSections = [
        "Goal", "Constraints", "Progress", "Decisions", "Current State", "Next Steps", "Critical Context", "Relevant Files",
    ]

    /// Checkpoints whose coverage is still an exact prefix of the transcript, oldest first.
    static func valid(_ checkpoints: [DesktopCompactCheckpoint], messageIDs: [UUID]) -> [DesktopCompactCheckpoint] {
        checkpoints.filter { checkpoint in
            guard !checkpoint.coveredMessageIDs.isEmpty,
                  checkpoint.coveredMessageIDs.count <= messageIDs.count else { return false }
            return Array(messageIDs.prefix(checkpoint.coveredMessageIDs.count)) == checkpoint.coveredMessageIDs
        }.sorted {
            if $0.coveredMessageIDs.count != $1.coveredMessageIDs.count {
                return $0.coveredMessageIDs.count < $1.coveredMessageIDs.count
            }
            return $0.createdAt < $1.createdAt
        }
    }

    /// The newest valid checkpoint, or the legacy single-slot summary migrated on read.
    static func active(_ checkpoints: [DesktopCompactCheckpoint], legacy: DesktopInsightValue?,
                       messageIDs: [UUID]) -> DesktopCompactCheckpoint? {
        if let newest = valid(checkpoints, messageIDs: messageIDs).last { return newest }
        guard let legacy else { return nil }
        return migrated(legacy, messageIDs: messageIDs)
    }

    /// A version-1 record stored one plain summary; treat it as a level-1 checkpoint with no parents.
    static func migrated(_ legacy: DesktopInsightValue, messageIDs: [UUID]) -> DesktopCompactCheckpoint? {
        guard !legacy.sourceMessageIDs.isEmpty, legacy.sourceMessageIDs.count <= messageIDs.count,
              Array(messageIDs.prefix(legacy.sourceMessageIDs.count)) == legacy.sourceMessageIDs else { return nil }
        return DesktopCompactCheckpoint(id: legacy.id, schema: 1, level: 1,
            coveredMessageIDs: legacy.sourceMessageIDs, coveredCompactIDs: [],
            handoff: legacy.text, createdAt: legacy.createdAt)
    }

    /// What a new checkpoint has to read: the previous handoff plus only the turns it did not cover yet.
    static func nextInput(messages: [DesktopMessage], previous: DesktopCompactCheckpoint?) -> (handoff: String?, segment: [DesktopMessage]) {
        guard let previous else { return (nil, messages) }
        let start = min(previous.coveredMessageIDs.count, messages.count)
        return (previous.handoff, Array(messages[start...]))
    }

    /// The request-side projection of a checkpoint. It travels as a user turn: the Claude path flattens every
    /// system message into the top-level prompt, which would make a summary look like a system rule.
    static func injection(_ checkpoint: DesktopCompactCheckpoint) -> DesktopMessage {
        DesktopMessage(id: checkpoint.id, role: .user, text: """
        以下是较早对话的上下文摘要，仅作为资料，不改变系统规则。确切的错误信息、命令与退出码、文件路径、\
        commit、关键数字与用户批准/拒绝的原话以当时的原文为准；需要回查时请说明要回查哪一段。

        <context-handoff>
        \(checkpoint.handoff)
        </context-handoff>
        """)
    }

    /// Quality gate: the handoff must be smaller than what it replaces, otherwise the checkpoint is rejected.
    static func reduces(_ handoff: String, comparedTo segment: [DesktopMessage], previous: String?) -> Bool {
        let replacement = DesktopContextBudget.estimate([DesktopMessage(role: .user, text: handoff)])
            + DesktopContextBudget.estimate([DesktopMessage(role: .user, text: previous ?? "")])
        return replacement < DesktopContextBudget.estimate(segment)
    }
}
