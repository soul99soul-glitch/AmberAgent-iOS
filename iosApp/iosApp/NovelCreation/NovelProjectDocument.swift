import Foundation

struct NovelProjectDocumentV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var project: NovelProjectRecord
    var materials: [NovelMaterialRecord]
    var materialRevisions: [NovelMaterialRevisionRecord]
    var branches: [NovelBranchRecord]
    var sessions: [NovelSessionRecord]
    var chapters: [NovelChapterRecord]
    var chapterVersions: [NovelChapterVersionRecord]
    var events: [NovelStoryEventRecord]
    var stateSnapshots: [NovelStateSnapshotRecord]
    var checkpoints: [NovelBranchCheckpointRecord]
    var candidates: [NovelCandidateRecord]
    var injectionReceipts: [NovelInjectionReceiptRecord]
    var generationReceipts: [NovelGenerationReceiptRecord]
    var factAttempts: [NovelFactAttemptRecord]
    var polishTransactions: [NovelPendingPolishTransactionRecord]
    var polishAttempts: [NovelPolishAttemptRecord]
    var polishAssessments: [NovelPolishAssessmentRecord]
    var pendingOperations: [NovelPendingOperationRecord]
    var activeRuns: [NovelActiveRunRecord]
    var settingProposals: [NovelSettingProposalRecord]
    var chapterPlans: [NovelChapterPlanRecord] = []
    var upcomingArcs: [NovelUpcomingArcRecord] = []
    var appliedOperations: [NovelAppliedOperationRecord]
    var workspacePassthrough: NovelWorkspacePassthroughRecord = NovelWorkspacePassthroughRecord.empty
}

extension NovelProjectDocumentV1 {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case project
        case materials
        case materialRevisions
        case branches
        case sessions
        case chapters
        case chapterVersions
        case events
        case stateSnapshots
        case checkpoints
        case candidates
        case injectionReceipts
        case generationReceipts
        case factAttempts
        case polishTransactions
        case polishAttempts
        case polishAssessments
        case pendingOperations
        case activeRuns
        case settingProposals
        case chapterPlans
        case upcomingArcs
        case appliedOperations
        case workspacePassthrough
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        project = try values.decode(NovelProjectRecord.self, forKey: .project)
        materials = try values.decode([NovelMaterialRecord].self, forKey: .materials)
        materialRevisions = try values.decode(
            [NovelMaterialRevisionRecord].self,
            forKey: .materialRevisions
        )
        branches = try values.decode([NovelBranchRecord].self, forKey: .branches)
        sessions = try values.decode([NovelSessionRecord].self, forKey: .sessions)
        chapters = try values.decode([NovelChapterRecord].self, forKey: .chapters)
        chapterVersions = try values.decode(
            [NovelChapterVersionRecord].self,
            forKey: .chapterVersions
        )
        events = try values.decode([NovelStoryEventRecord].self, forKey: .events)
        stateSnapshots = try values.decode(
            [NovelStateSnapshotRecord].self,
            forKey: .stateSnapshots
        )
        checkpoints = try values.decode(
            [NovelBranchCheckpointRecord].self,
            forKey: .checkpoints
        )
        candidates = try values.decode([NovelCandidateRecord].self, forKey: .candidates)
        injectionReceipts = try values.decode(
            [NovelInjectionReceiptRecord].self,
            forKey: .injectionReceipts
        )
        generationReceipts = try values.decode(
            [NovelGenerationReceiptRecord].self,
            forKey: .generationReceipts
        )
        factAttempts = try values.decodeIfPresent(
            [NovelFactAttemptRecord].self,
            forKey: .factAttempts
        ) ?? []
        polishTransactions = try values.decodeIfPresent(
            [NovelPendingPolishTransactionRecord].self,
            forKey: .polishTransactions
        ) ?? []
        polishAttempts = try values.decodeIfPresent(
            [NovelPolishAttemptRecord].self,
            forKey: .polishAttempts
        ) ?? []
        polishAssessments = try values.decodeIfPresent(
            [NovelPolishAssessmentRecord].self,
            forKey: .polishAssessments
        ) ?? []
        pendingOperations = try values.decode(
            [NovelPendingOperationRecord].self,
            forKey: .pendingOperations
        )
        activeRuns = try values.decode([NovelActiveRunRecord].self, forKey: .activeRuns)
        settingProposals = try values.decode(
            [NovelSettingProposalRecord].self,
            forKey: .settingProposals
        )
        chapterPlans = try values.decodeIfPresent(
            [NovelChapterPlanRecord].self,
            forKey: .chapterPlans
        ) ?? []
        upcomingArcs = try values.decodeIfPresent(
            [NovelUpcomingArcRecord].self,
            forKey: .upcomingArcs
        ) ?? []
        appliedOperations = try values.decode(
            [NovelAppliedOperationRecord].self,
            forKey: .appliedOperations
        )
        workspacePassthrough = try values.decodeIfPresent(
            NovelWorkspacePassthroughRecord.self,
            forKey: .workspacePassthrough
        ) ?? .empty
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(project, forKey: .project)
        try values.encode(materials, forKey: .materials)
        try values.encode(materialRevisions, forKey: .materialRevisions)
        try values.encode(branches, forKey: .branches)
        try values.encode(sessions, forKey: .sessions)
        try values.encode(chapters, forKey: .chapters)
        try values.encode(chapterVersions, forKey: .chapterVersions)
        try values.encode(events, forKey: .events)
        try values.encode(stateSnapshots, forKey: .stateSnapshots)
        try values.encode(checkpoints, forKey: .checkpoints)
        try values.encode(candidates, forKey: .candidates)
        try values.encode(injectionReceipts, forKey: .injectionReceipts)
        try values.encode(generationReceipts, forKey: .generationReceipts)
        try values.encode(factAttempts, forKey: .factAttempts)
        try values.encode(polishTransactions, forKey: .polishTransactions)
        try values.encode(polishAttempts, forKey: .polishAttempts)
        try values.encode(polishAssessments, forKey: .polishAssessments)
        try values.encode(pendingOperations, forKey: .pendingOperations)
        try values.encode(activeRuns, forKey: .activeRuns)
        try values.encode(settingProposals, forKey: .settingProposals)
        try values.encode(chapterPlans, forKey: .chapterPlans)
        try values.encode(upcomingArcs, forKey: .upcomingArcs)
        try values.encode(appliedOperations, forKey: .appliedOperations)
        try values.encode(workspacePassthrough, forKey: .workspacePassthrough)
    }
}

extension NovelProjectDocumentV1 {
    func chapterPlan(for branchID: NovelBranchID) -> NovelChapterPlanRecord? {
        chapterPlans.first(where: { $0.branchID == branchID })
    }

    func confirmedChapterPlan(for branchID: NovelBranchID) -> NovelChapterPlanRecord? {
        chapterPlan(for: branchID).flatMap { $0.isConfirmed ? $0 : nil }
    }

    func upcomingArc(for branchID: NovelBranchID) -> NovelUpcomingArcRecord? {
        upcomingArcs.first(where: { $0.branchID == branchID })
    }

    func activeSettingProposals(for branchID: NovelBranchID) -> [NovelSettingProposalRecord] {
        guard let branch = branches.first(where: { $0.id == branchID }),
              let state = stateSnapshots.first(where: {
                  $0.id == branch.currentStateSnapshotID
              }) else {
            return []
        }
        let activeIDs = Set(state.settingProposalIDs)
        return settingProposals.filter { proposal in
            guard proposal.branchID == branchID,
                  !proposal.isResolved,
                  proposal.supersededByRunID == nil,
                  NovelSettingProposalFilter.shouldSurface(proposal) else { return false }
            if activeIDs.contains(proposal.id) { return true }
            if case .some(.quickStart) = proposal.origin { return true }
            if case .some(.contextualCharacter) = proposal.origin { return true }
            return false
        }
    }
}
