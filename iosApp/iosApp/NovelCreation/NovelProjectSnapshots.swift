import Foundation

enum NovelProjectLoadAccess: Equatable, Sendable {
    case readWrite
    case degradedPrevious(primaryFailure: String)
}

struct NovelLoadedProject: Equatable, Sendable {
    let document: NovelProjectDocumentV1
    let access: NovelProjectLoadAccess
}

struct NovelProjectSummary: Codable, Equatable, Sendable {
    let id: NovelProjectID
    let name: String
    let mainBranchID: NovelBranchID?
    let updatedAt: Date
    let revision: Int64
    let isDegraded: Bool
    let hasRunningRun: Bool
    let loadError: String?

    init(document: NovelProjectDocumentV1, isDegraded: Bool = false) {
        id = document.project.id
        name = document.project.name
        mainBranchID = document.project.mainBranchID
        updatedAt = document.project.updatedAt
        revision = document.project.revision
        self.isDegraded = isDegraded
        hasRunningRun = document.activeRuns.contains(where: { $0.status == .running })
        loadError = nil
    }

    init(unavailableProjectID: NovelProjectID, error: Error) {
        id = unavailableProjectID
        name = "Unavailable Project"
        mainBranchID = nil
        updatedAt = Date(timeIntervalSince1970: 0)
        revision = 0
        isDegraded = true
        hasRunningRun = false
        loadError = String(describing: error)
    }
}

struct NovelProjectSnapshot: Equatable, Sendable {
    let project: NovelProjectRecord
    let materials: [NovelMaterialRecord]
    let materialRevisions: [NovelMaterialRevisionRecord]
    let branches: [NovelBranchRecord]
    let sessions: [NovelSessionRecord]
    let chapters: [NovelChapterRecord]
    let chapterVersions: [NovelChapterVersionRecord]
    let events: [NovelStoryEventRecord]
    let stateSnapshots: [NovelStateSnapshotRecord]
    let checkpoints: [NovelBranchCheckpointRecord]
    let candidates: [NovelCandidateRecord]
    let chapterPlans: [NovelChapterPlanRecord]
    let upcomingArcs: [NovelUpcomingArcRecord]
    let injectionReceipts: [NovelInjectionReceiptRecord]
    let generationReceipts: [NovelGenerationReceiptRecord]
    let factAttempts: [NovelFactAttemptRecord]
    let polishTransactions: [NovelPendingPolishTransactionRecord]
    let polishAttempts: [NovelPolishAttemptRecord]
    let polishAssessments: [NovelPolishAssessmentRecord]
    let pendingOperations: [NovelPendingOperationRecord]
    let activeRuns: [NovelActiveRunRecord]
    let settingProposals: [NovelSettingProposalRecord]
    let appliedOperations: [NovelAppliedOperationRecord]
    let workspacePassthrough: NovelWorkspacePassthroughRecord
    let access: NovelProjectLoadAccess

    init(loaded: NovelLoadedProject) {
        let document = loaded.document
        project = document.project
        materials = document.materials
        materialRevisions = document.materialRevisions
        branches = document.branches
        sessions = document.sessions
        chapters = document.chapters
        chapterVersions = document.chapterVersions
        events = document.events
        stateSnapshots = document.stateSnapshots
        checkpoints = document.checkpoints
        candidates = document.candidates
        chapterPlans = document.chapterPlans
        upcomingArcs = document.upcomingArcs
        injectionReceipts = document.injectionReceipts
        generationReceipts = document.generationReceipts
        factAttempts = document.factAttempts
        polishTransactions = document.polishTransactions
        polishAttempts = document.polishAttempts
        polishAssessments = document.polishAssessments
        pendingOperations = document.pendingOperations
        activeRuns = document.activeRuns
        settingProposals = document.settingProposals
        appliedOperations = document.appliedOperations
        workspacePassthrough = document.workspacePassthrough
        access = loaded.access
    }

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

struct NovelBranchSnapshot: Equatable, Sendable {
    let projectID: NovelProjectID
    let projectRevision: Int64
    let configRevision: Int64
    let branch: NovelBranchRecord
    let session: NovelSessionRecord
    let headCheckpoint: NovelBranchCheckpointRecord
    let currentState: NovelStateSnapshotRecord
    let chapterSelections: [NovelChapterSelection]
    let activeSettingProposals: [NovelSettingProposalRecord]
    let access: NovelProjectLoadAccess
}
