import Foundation

struct NovelStateEventV1: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let summary: String
    let entityReferences: [String]
    let evidence: String
}

struct NovelCharacterStateFactV1: Codable, Equatable, Sendable {
    let id: String
    let characterName: String
    let attribute: String
    let value: String
    let evidence: String
}

struct NovelRelationshipFactV1: Codable, Equatable, Sendable {
    let id: String
    let sourceEntity: String
    let targetEntity: String
    let relationship: String
    let state: String
    let evidence: String
}

enum NovelForeshadowingStatusV1: String, Codable, CaseIterable, Sendable {
    case introduced
    case advanced
    case resolved
    case reopened
}

struct NovelForeshadowingFactV1: Codable, Equatable, Sendable {
    let id: String
    let thread: String
    let status: NovelForeshadowingStatusV1
    let summary: String
    let evidence: String
}

struct NovelSettingProposalDraftV1: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let content: String
    let evidence: String
}

struct NovelStateDeltaV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let stateSummary: String
    let events: [NovelStateEventV1]
    let characterChanges: [NovelCharacterStateFactV1]
    let relationshipChanges: [NovelRelationshipFactV1]
    let foreshadowingChanges: [NovelForeshadowingFactV1]
    let unresolvedEntityNames: [String]
    let branchOutlinePatch: String?
    let settingProposals: [NovelSettingProposalDraftV1]
}

struct NovelStateRebuildV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let stateSummary: String
    let branchOutline: String
    let events: [NovelStateEventV1]
    let characterStates: [NovelCharacterStateFactV1]
    let relationships: [NovelRelationshipFactV1]
    let foreshadowing: [NovelForeshadowingFactV1]
    let unresolvedEntityNames: [String]
    let settingProposals: [NovelSettingProposalDraftV1]
}

enum NovelPolishDifferenceCategoryV1: String, Codable, CaseIterable, Sendable {
    case event
    case chronology
    case relationship
    case motivation
    case secret
    case outcome
    case pointOfView
    case ending
    case other
}

struct NovelPolishDifferenceV1: Codable, Equatable, Sendable {
    let id: String
    let category: NovelPolishDifferenceCategoryV1
    let summary: String
    let sourceEvidence: String
    let candidateEvidence: String
}

struct NovelPolishDriftV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let compatible: Bool
    let differences: [NovelPolishDifferenceV1]
}

struct NovelChapterPlanAcceptanceV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let legacySchemaVersion = 1

    let schemaVersion: Int
    let accepted: Bool
    let missingMustHappen: [String]
    let forbiddenViolations: [String]
    /// Soft gate: beats that clearly rehash recent written highlights. May be non-empty even when accepted.
    let obviousRepetition: [String]
    let summary: String

    init(
        schemaVersion: Int = currentSchemaVersion,
        accepted: Bool,
        missingMustHappen: [String],
        forbiddenViolations: [String],
        obviousRepetition: [String] = [],
        summary: String
    ) {
        self.schemaVersion = schemaVersion
        self.accepted = accepted
        self.missingMustHappen = missingMustHappen
        self.forbiddenViolations = forbiddenViolations
        self.obviousRepetition = obviousRepetition
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case accepted
        case missingMustHappen
        case forbiddenViolations
        case obviousRepetition
        case summary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        accepted = try container.decode(Bool.self, forKey: .accepted)
        missingMustHappen = try container.decode([String].self, forKey: .missingMustHappen)
        forbiddenViolations = try container.decode([String].self, forKey: .forbiddenViolations)
        obviousRepetition = try container.decodeIfPresent([String].self, forKey: .obviousRepetition) ?? []
        summary = try container.decode(String.self, forKey: .summary)
    }
}

/// Structured next-chapter contract for multi-chapter ghostwrite auto-planning.
struct NovelChapterPlanProposalV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let outlinePlacement: String
    let goalAndConflict: String
    let mustHappen: [String]
    let mustNotHappen: [String]
    let endingHook: String
    let visibleFacts: [String]

    init(
        schemaVersion: Int = currentSchemaVersion,
        outlinePlacement: String,
        goalAndConflict: String,
        mustHappen: [String],
        mustNotHappen: [String],
        endingHook: String,
        visibleFacts: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.outlinePlacement = outlinePlacement
        self.goalAndConflict = goalAndConflict
        self.mustHappen = mustHappen
        self.mustNotHappen = mustNotHappen
        self.endingHook = endingHook
        self.visibleFacts = visibleFacts
    }
}

/// Model-facing chapter-plan contract. Same fields as the JSON schema, parsed
/// from markdown headings so thinking models can emit prose instead of JSON.

enum NovelContinuityIssueCategoryV1: String, Codable, CaseIterable, Sendable {
    /// 同一件事被写了两遍。
    case duplicatedPlot
    /// 前后事实互相矛盾。
    case contradiction
    /// 明明见过却写成初次见面（或反过来）。
    case identityDrift
    /// 时间线错乱。
    case chronology
    /// 生死、伤情、所在位置这类状态冲突。
    case statusConflict
    case other
}

enum NovelContinuityIssueSeverityV1: String, Codable, CaseIterable, Sendable {
    case blocking
    case major
    case minor
}

/// 一条问题在正文里的落点。`chapterOrdinal` 是注入正文里 `# Chapter N` 的 N（从 1 起），
/// 由执行入口映射回 `NovelChapterID` —— 模型不知道也不该知道内部 ID。
struct NovelContinuityReferenceV1: Codable, Equatable, Sendable {
    let chapterOrdinal: Int
    let chapterTitle: String
    let evidence: String
}

struct NovelContinuityIssueV1: Codable, Equatable, Sendable {
    let id: String
    let category: NovelContinuityIssueCategoryV1
    let severity: NovelContinuityIssueSeverityV1
    let summary: String
    /// 至少两条 —— 矛盾天然是成对的，只给一处就无从对照。
    let references: [NovelContinuityReferenceV1]
}

struct NovelContinuityAuditV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let minimumReferenceCount = 2

    let schemaVersion: Int
    let consistent: Bool
    let issues: [NovelContinuityIssueV1]
}

/// 针对单章的最小补丁。`oldText` 必须是目标章里只出现一次的连续原文。
struct NovelContinuityRepairPatchV1: Codable, Equatable, Sendable {
    let issueId: String
    let oldText: String
    let newText: String
}

struct NovelContinuityRepairV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let patches: [NovelContinuityRepairPatchV1]
}

/// Joint pre-collection adjudication for one whole-chapter candidate.
/// The nested contracts remain independently strict so acceptance, continuity,
/// and state extraction cannot silently diverge at the commit boundary.
struct NovelChapterAdjudicationV1: Codable, Equatable, Sendable {
    static let legacySchemaVersion = 1
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let acceptance: NovelChapterPlanAcceptanceV1
    let continuity: NovelContinuityAuditV1
    let stateDelta: NovelStateDeltaV1
    /// Optional so a legacy response, an unavailable next-plan proposal, or a
    /// final chapter can still collect after the current chapter passes review.
    let nextPlan: NovelChapterPlanProposalV1?

    init(
        schemaVersion: Int = currentSchemaVersion,
        acceptance: NovelChapterPlanAcceptanceV1,
        continuity: NovelContinuityAuditV1,
        stateDelta: NovelStateDeltaV1,
        nextPlan: NovelChapterPlanProposalV1? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.acceptance = acceptance
        self.continuity = continuity
        self.stateDelta = stateDelta
        self.nextPlan = nextPlan
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case acceptance
        case continuity
        case stateDelta
        case nextPlan
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        acceptance = try container.decode(NovelChapterPlanAcceptanceV1.self, forKey: .acceptance)
        continuity = try container.decode(NovelContinuityAuditV1.self, forKey: .continuity)
        stateDelta = try container.decode(NovelStateDeltaV1.self, forKey: .stateDelta)
        nextPlan = try container.decodeIfPresent(NovelChapterPlanProposalV1.self, forKey: .nextPlan)
    }
}

struct NovelDiscussionArchiveDecisionV1: Codable, Equatable, Sendable {
    let topic: String
    let decision: String
    let relatedMaterialID: String?
}

struct NovelDiscussionArchiveV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let decisions: [NovelDiscussionArchiveDecisionV1]
    let summary: String
}

enum NovelStructuredOutputErrorCategory: String, Codable, Equatable, Sendable {
    case malformedJSON
    case expectedObject
    case missingField
    case unknownField
    case duplicateKey
    case typeMismatch
    case unsupportedVersion
    case invalidValue
    case duplicateIdentifier
    case invalidReference
}

struct NovelStructuredOutputFailure: Error, Equatable, Sendable {
    let category: NovelStructuredOutputErrorCategory
    let path: String
    let message: String
}

extension NovelStructuredOutputFailure: LocalizedError {
    var errorDescription: String? { message }
}

enum NovelPolishDriftVerdict: Equatable, Sendable {
    case compatible
    case incompatible([NovelPolishDifferenceV1])
    case invalidOutput(NovelStructuredOutputFailure)

    var allowsAdoption: Bool {
        if case .compatible = self { return true }
        return false
    }
}
