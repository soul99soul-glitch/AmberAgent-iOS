import CryptoKit
import Foundation

enum NovelProjectCreationMode: String, Codable, CaseIterable, Sendable {
    case blank
    case quickStart
}

/// Project-level collaboration style. Ghostwrite auto-pipeline arrives in Phase 2;
/// Phase 1 persists the mode, enforces readiness, and requires a chapter plan.
enum NovelCollaborationMode: String, Codable, CaseIterable, Sendable {
    case cocreation
    case ghostwrite

    var displayName: String {
        switch self {
        case .cocreation: IOSAppLocalization.string("共创模式", defaultValue: "共创模式")
        case .ghostwrite: IOSAppLocalization.string("代笔模式", defaultValue: "代笔模式")
        }
    }

    var shortSummary: String {
        switch self {
        case .cocreation: IOSAppLocalization.string(
            "一起商量，你点收录才进书",
            defaultValue: "一起商量，你点收录才进书"
        )
        case .ghostwrite: IOSAppLocalization.string(
            "先定好这一章要写什么，再按章代笔；过关后自动进书",
            defaultValue: "先定好这一章要写什么，再按章代笔；过关后自动进书"
        )
        }
    }
}

enum NovelChapterPlanStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case confirmed
}

struct NovelChapterPlanRecord: Codable, Equatable, Sendable {
    let id: NovelChapterPlanID
    let branchID: NovelBranchID
    var status: NovelChapterPlanStatus
    /// Short placement note such as "第 3 章 · 中段转折".
    var outlinePlacement: String
    var goalAndConflict: String
    var mustHappen: [String]
    var mustNotHappen: [String]
    var endingHook: String
    /// Facts the POV is allowed to know in this chapter.
    var visibleFacts: [String]
    var contentDigest: String
    var updatedAt: Date
    var confirmedAt: Date?

    var isConfirmed: Bool { status == .confirmed }

    func canonicalDigestPayload() -> String {
        let must = mustHappen.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let mustNot = mustNotHappen.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let visible = visibleFacts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return [
            outlinePlacement.trimmingCharacters(in: .whitespacesAndNewlines),
            goalAndConflict.trimmingCharacters(in: .whitespacesAndNewlines),
            must,
            mustNot,
            endingHook.trimmingCharacters(in: .whitespacesAndNewlines),
            visible,
        ].joined(separator: "\n---\n")
    }

    func injectionText() -> String {
        var lines = [
            "Status: \(status.rawValue)",
            "Digest: \(contentDigest)",
            "Placement: \(outlinePlacement)",
            "Goal and conflict:\n\(goalAndConflict)",
        ]
        if !mustHappen.isEmpty {
            lines.append("Must happen:\n" + mustHappen.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !mustNotHappen.isEmpty {
            lines.append("Must not happen:\n" + mustNotHappen.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !endingHook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Ending hook:\n\(endingHook)")
        }
        if !visibleFacts.isEmpty {
            lines.append(
                "POV-visible facts:\n" + visibleFacts.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        return lines.joined(separator: "\n\n")
    }

    static func digest(forCanonicalPayload payload: String) -> String {
        SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedLines(_ lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum NovelGhostwriteReadinessIssue: String, Equatable, Hashable, Sendable, CaseIterable {
    case mainBranchRequired
    case missingMasterOutline
    case missingCharacter
    case missingWritingRequirements
    case branchNeedsSync
    case unresolvedPlot
    case pendingOperations
    case activeRun
    case missingChapterPlan

    var displayName: String {
        switch self {
        case .mainBranchRequired: IOSAppLocalization.string(
            "代笔仅支持当前主分支",
            defaultValue: "代笔仅支持当前主分支"
        )
        case .missingMasterOutline: IOSAppLocalization.string(
            "缺少总剧情大纲",
            defaultValue: "缺少总剧情大纲"
        )
        case .missingCharacter: IOSAppLocalization.string(
            "至少需要一名人物档案",
            defaultValue: "至少需要一名人物档案"
        )
        case .missingWritingRequirements: IOSAppLocalization.string(
            "缺少写作要求",
            defaultValue: "缺少写作要求"
        )
        case .branchNeedsSync: IOSAppLocalization.string(
            "当前分支资料待同步",
            defaultValue: "当前分支资料待同步"
        )
        case .unresolvedPlot: IOSAppLocalization.string(
            NovelWorkspaceLedger.unresolvedPlotGateMessage,
            defaultValue: NovelWorkspaceLedger.unresolvedPlotGateMessage
        )
        case .pendingOperations: IOSAppLocalization.string(
            "仍有未完成的正文或同步操作",
            defaultValue: "仍有未完成的正文或同步操作"
        )
        case .activeRun: IOSAppLocalization.string(
            "当前还有进行中的生成",
            defaultValue: "当前还有进行中的生成"
        )
        case .missingChapterPlan: IOSAppLocalization.string(
            "还没有确认的本章计划",
            defaultValue: "还没有确认的本章计划"
        )
        }
    }
}

enum NovelGhostwriteReadiness {
    static func issues(
        in document: NovelProjectDocumentV1,
        branchID: NovelBranchID,
        requireChapterPlan: Bool
    ) -> [NovelGhostwriteReadinessIssue] {
        issues(
            materials: document.materials,
            materialRevisions: document.materialRevisions,
            branches: document.branches,
            pendingOperations: document.pendingOperations,
            polishTransactions: document.polishTransactions,
            activeRuns: document.activeRuns,
            chapterPlans: document.chapterPlans,
            stateSnapshots: document.stateSnapshots,
            mainBranchID: document.project.mainBranchID,
            branchID: branchID,
            requireChapterPlan: requireChapterPlan
        )
    }

    static func issues(
        materials: [NovelMaterialRecord],
        materialRevisions: [NovelMaterialRevisionRecord],
        branches: [NovelBranchRecord],
        pendingOperations: [NovelPendingOperationRecord],
        polishTransactions: [NovelPendingPolishTransactionRecord],
        activeRuns: [NovelActiveRunRecord],
        chapterPlans: [NovelChapterPlanRecord],
        stateSnapshots: [NovelStateSnapshotRecord] = [],
        mainBranchID: NovelBranchID,
        branchID: NovelBranchID,
        requireChapterPlan: Bool
    ) -> [NovelGhostwriteReadinessIssue] {
        var issues: [NovelGhostwriteReadinessIssue] = []
        if branchID != mainBranchID {
            issues.append(.mainBranchRequired)
        }
        let activeMaterials = materials.filter { !$0.isDeleted }
        let revisionByID = Dictionary(
            uniqueKeysWithValues: materialRevisions.map { ($0.id, $0) }
        )
        func hasNonEmptyMaterial(kind: NovelMaterialKind) -> Bool {
            activeMaterials.contains { material in
                guard material.kind == kind,
                      let revision = revisionByID[material.currentRevisionID] else { return false }
                return !revision.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        if !hasNonEmptyMaterial(kind: .masterOutline) {
            issues.append(.missingMasterOutline)
        }
        if !hasNonEmptyMaterial(kind: .character) {
            issues.append(.missingCharacter)
        }
        if !hasNonEmptyMaterial(kind: .writingRequirements) {
            issues.append(.missingWritingRequirements)
        }
        guard let branch = branches.first(where: { $0.id == branchID }) else {
            issues.append(.branchNeedsSync)
            return issues
        }
        if branch.syncStatus != .synchronized {
            issues.append(.branchNeedsSync)
        }
        if let snapshot = stateSnapshots.first(where: { $0.id == branch.currentStateSnapshotID }),
           snapshot.hasStaleChapterPlots {
            issues.append(.unresolvedPlot)
        }
        if pendingOperations.contains(where: { $0.branchID == branchID }) ||
            polishTransactions.contains(where: {
                $0.branchID == branchID &&
                    ($0.status == .pending || $0.status == .retryable || $0.status == .blocked)
            }) {
            issues.append(.pendingOperations)
        }
        if branch.activeRunID != nil ||
            activeRuns.contains(where: {
                $0.branchID == branchID && $0.status == .running
            }) {
            issues.append(.activeRun)
        }
        if requireChapterPlan,
           chapterPlans.first(where: { $0.branchID == branchID && $0.isConfirmed }) == nil {
            issues.append(.missingChapterPlan)
        }
        return issues
    }
}

enum NovelGenerationGranularity: String, Codable, CaseIterable, Sendable {
    case continuation
    case wholeChapter
}

enum NovelProjectModelPolicy: Codable, Equatable, Sendable {
    case global
    /// Stable provider and model UUID strings. `modelID` is never the wire model name.
    case fixed(providerID: String, modelID: String)
}

enum NovelModelRole: String, Codable, CaseIterable, Sendable {
    case creation
    case stateSync
    /// 代笔合同验收与连续性软门；缺省跟随 App 默认（通常为 global）。
    case review
}

struct NovelQuickStartSeed: Codable, Equatable, Sendable {
    let genre: String
    let coreIdea: String
}

/// 分支级「往后几章」有界备注：软上下文，跨多章保留，直到用户改写或清除。
struct NovelUpcomingArcRecord: Codable, Equatable, Sendable {
    static let maxBeats = 8
    static let maxBeatCharacterCount = 160

    let branchID: NovelBranchID
    var beats: [String]
    var updatedAt: Date

    init(branchID: NovelBranchID, beats: [String], updatedAt: Date) {
        self.branchID = branchID
        self.beats = Self.normalizedBeats(beats)
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        branchID = try values.decode(NovelBranchID.self, forKey: .branchID)
        beats = Self.normalizedBeats(try values.decode([String].self, forKey: .beats))
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case branchID
        case beats
        case updatedAt
    }

    static func normalizedBeats(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = trimmed.count > maxBeatCharacterCount
                ? String(trimmed.prefix(maxBeatCharacterCount))
                : trimmed
            let key = clipped.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(clipped)
            if result.count >= maxBeats { break }
        }
        return result
    }

    func injectionText() -> String {
        beats.map { "- \($0)" }.joined(separator: "\n")
    }
}
