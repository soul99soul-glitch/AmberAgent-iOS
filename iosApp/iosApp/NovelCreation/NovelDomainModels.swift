import Foundation

enum NovelMaterialKind: Codable, Equatable, Sendable {
    case world
    case character
    /// Author-approved relationship planning. Runtime relationship facts remain
    /// in `NovelStateSnapshotRecord` and are still derived from manuscript evidence.
    case relationship
    case masterOutline
    case writingRequirements
    case decisionLog
    case custom(String)
}

enum NovelInjectionMode: String, Codable, CaseIterable, Sendable {
    case always
    case smart
    case off
}

enum NovelBranchSyncStatus: String, Codable, Sendable {
    case synchronized
    case needsSync
}

enum NovelBranchLifecycle: String, Codable, Sendable {
    case active
    case deleted
}

enum NovelCheckpointKind: String, Codable, CaseIterable, Sendable {
    case initial
    case collection
    case manualSync
    case discussionArchive
    case identityClarification
    case polish
    case restore
}

enum NovelChapterVersionKind: String, Codable, CaseIterable, Sendable {
    case collected
    case manualEdit
    case polish
    case restore
}

enum NovelSessionRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum NovelSessionMode: String, Codable, Sendable {
    case writeProse
    case discussPlan
}

enum NovelSessionMessageKind: String, Codable, Sendable {
    case userInput
    case discussion
    case proseCandidate
    case polishCandidate
    case interruptedDraft
    case error
}

struct NovelAskUserPrompt: Codable, Equatable, Sendable {
    let question: String
    let options: [String]
    /// Present only for `novel_revise_chapter` approval cards. Ordinary Ask User
    /// prompts leave this nil so historical documents keep decoding.
    let chapterRevision: NovelChapterRevisionProposal?
    /// Present only for `novel_revert_recent_chapters` approval cards.
    let manuscriptRevert: NovelManuscriptRevertProposal?
    /// Present only for `novel_delete_chapters` approval cards.
    let manuscriptDelete: NovelManuscriptDeleteProposal?
    /// Present only for `novel_workspace_write` of plot files.
    let workspacePlot: NovelWorkspacePlotProposal?
    /// Present only for `novel_prepare_ghostwrite` approval cards.
    let ghostwritePlan: NovelGhostwritePlanProposal?

    init(
        question: String,
        options: [String],
        chapterRevision: NovelChapterRevisionProposal? = nil,
        manuscriptRevert: NovelManuscriptRevertProposal? = nil,
        manuscriptDelete: NovelManuscriptDeleteProposal? = nil,
        workspacePlot: NovelWorkspacePlotProposal? = nil,
        ghostwritePlan: NovelGhostwritePlanProposal? = nil
    ) {
        self.question = question
        self.options = options
        self.chapterRevision = chapterRevision
        self.manuscriptRevert = manuscriptRevert
        self.manuscriptDelete = manuscriptDelete
        self.workspacePlot = workspacePlot
        self.ghostwritePlan = ghostwritePlan
    }
}

enum NovelGhostwritePlanApproval {
    static let approveOption = "开始代笔"
    static let rejectOption = "暂不开始"
    static let options = [approveOption, rejectOption]
    private static let approvedPrefix = "开始代笔 · "
    private static let approvedSuffix = " 章"

    static func approvedAnswer(chapterCount: Int) -> String {
        "\(approvedPrefix)\(NovelGhostwriteBatch.clamp(chapterCount))\(approvedSuffix)"
    }

    static func approvedChapterCount(from answer: String) -> Int? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(approvedPrefix), trimmed.hasSuffix(approvedSuffix) else {
            return nil
        }
        let start = trimmed.index(trimmed.startIndex, offsetBy: approvedPrefix.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -approvedSuffix.count)
        guard start < end, let count = Int(trimmed[start..<end]) else { return nil }
        guard count == NovelGhostwriteBatch.clamp(count) else { return nil }
        return count
    }
}

struct NovelGhostwritePlanProposal: Codable, Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let planID: NovelChapterPlanID
    let expectedHeadRevision: Int64
    let expectedWorkingRevision: Int64
    let expectedCurrentPlanDigest: String?
    let outlinePlacement: String
    let goalAndConflict: String
    let mustHappen: [String]
    let mustNotHappen: [String]
    let endingHook: String
    let visibleFacts: [String]
    let upcomingArc: [String]
    let suggestedChapterCount: Int
    let reason: String?

    var proposedPlanDigest: String {
        let must = NovelChapterPlanRecord.normalizedLines(mustHappen).joined(separator: "\n")
        let mustNot = NovelChapterPlanRecord.normalizedLines(mustNotHappen).joined(separator: "\n")
        let visible = NovelChapterPlanRecord.normalizedLines(visibleFacts).joined(separator: "\n")
        let payload = [
            outlinePlacement.trimmingCharacters(in: .whitespacesAndNewlines),
            goalAndConflict.trimmingCharacters(in: .whitespacesAndNewlines),
            must,
            mustNot,
            endingHook.trimmingCharacters(in: .whitespacesAndNewlines),
            visible,
        ].joined(separator: "\n---\n")
        return NovelChapterPlanRecord.digest(forCanonicalPayload: payload)
    }
}

struct NovelWorkspacePlotProposal: Codable, Equatable, Sendable {
    let path: String
    let body: String
    let reason: String?
}

enum NovelWorkspacePlotApproval {
    static let approveOption = "写入剧情"
    static let rejectOption = "拒绝这次修改"
    static let options = [approveOption, rejectOption]
}

enum NovelChapterRevisionApproval {
    static let approveOption = "写入正文"
    static let rejectOption = "拒绝这次修改"
    static let options = [approveOption, rejectOption]
}

struct NovelChapterRevisionProposal: Codable, Equatable, Sendable {
    let chapterID: NovelChapterID
    let chapterOrdinal: Int
    let chapterTitle: String
    let startParagraph: Int
    let endParagraph: Int
    let oldText: String
    let newText: String
    let reason: String?
}

enum NovelManuscriptRevertApproval {
    static let approveOption = "回退这几章"
    static let rejectOption = "取消回退"
    static let options = [approveOption, rejectOption]
}

struct NovelManuscriptRevertProposal: Codable, Equatable, Sendable {
    let chapterCount: Int
    let chapterIDs: [NovelChapterID]
    let chapterTitles: [String]
    let chapterOrdinals: [Int]
    let targetCheckpointID: NovelCheckpointID
    let expectedHeadRevision: Int64
    let expectedWorkingRevision: Int64
    let reason: String?
}

enum NovelManuscriptDeleteApproval {
    static let approveOption = "从正文目录删除"
    static let rejectOption = "取消这次删除"
    static let options = [approveOption, rejectOption]
}

struct NovelManuscriptDeleteProposal: Codable, Equatable, Sendable {
    let chapterIDs: [NovelChapterID]
    let chapterTitles: [String]
    let chapterOrdinals: [Int]
    let expectedHeadRevision: Int64
    let expectedWorkingRevision: Int64
    let reason: String?
}

struct NovelAskUserResponse: Codable, Equatable, Sendable {
    let promptMessageID: NovelMessageID
    let answer: String
}

enum NovelSessionInteraction: Codable, Equatable, Sendable {
    case askUser(NovelAskUserPrompt)
    case askUserAnswer(NovelAskUserResponse)
}

enum NovelCandidateKind: String, Codable, Sendable {
    case prose
    case polish
}

enum NovelCandidateStatus: String, Codable, Sendable {
    case available
    case collected
    case adopted
    case interrupted
    case superseded
    case inheritedReadOnly
}

enum NovelRunStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
    case failed
}

enum NovelRunInterruptionReason: String, Codable, Sendable {
    case user
    case background
    case routeExit
    case expiration
    case recovery
}

enum NovelPendingOperationKind: String, Codable, Sendable {
    case collection
    case manualSync
}

enum NovelPendingOperationStatus: String, Codable, Sendable {
    case pending
    case retryable
}

enum NovelCollectionTarget: Codable, Equatable, Sendable {
    case appendToChapter(NovelChapterID)
    /// 整章重新生成:用候选内容**替换**该章正文,而不是追加到末尾。
    /// 版本类型仍是 `.collected`,因此必须另起事实兼容链——这正是
    /// 「允许改变剧情事实」的形式化表达(见 NovelCompatibilityLineageValidator)。
    case replaceChapter(NovelChapterID)
    case createNextChapter(chapterID: NovelChapterID, title: String)
}
