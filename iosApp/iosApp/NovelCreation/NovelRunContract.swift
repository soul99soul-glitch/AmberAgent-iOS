import CryptoKit
import Foundation

enum NovelRunKind: String, Codable, Sendable {
    case quickStart
    case characterProposal
    case discussion
    case prose
    case polish
    /// 整章重新生成。与 `.prose` 的区别是它**必须**携带被重写章节的版本 id
    /// (`sourceChapterVersionID`),与 `.polish` 的区别是它**允许改变剧情事实**
    /// ——不走润色的漂移闸,产出普通 prose 候选,由用户以 `.replaceChapter` 收录。
    case regenerate

    /// 「给输出留多少上下文空间」——**纯本地算术,绝不发给 provider**。
    ///
    /// 与 `NovelStructuredModelTaskKind.outputReservationTokens` 同一语义,分别服务于
    /// 生成侧与结构化侧的输入预算反推。两处的**唯一**职责就是这个;发给模型的硬上限
    /// 已一律取消(`maxOutputTokens: nil`),不要再把这两件事合并回一个字段——那正是
    /// 2026-07-26「模型回复达到输出上限」故障的根源。
    var outputReservationTokens: Int {
        switch self {
        case .prose, .polish, .regenerate: 8_192
        case .quickStart, .characterProposal, .discussion: 4_096
        }
    }
}

struct NovelRunRequest: Equatable, Sendable {
    let id: NovelRunID
    let operationID: NovelOperationID
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let kind: NovelRunKind
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let userText: String
    let userMessageID: NovelMessageID
    let assistantMessageID: NovelMessageID
    let candidateID: NovelCandidateID?
    let generationReceiptID: NovelReceiptID
    let injectionReceiptID: NovelReceiptID
    let sourceChapterVersionID: NovelChapterVersionID?
    let askUserResponse: NovelAskUserResponse?
    let contextualCharacterMention: String?
    let ghostwritePlanID: NovelChapterPlanID?
    let injectionOverrides: NovelInjectionOverrides
    let inputBudgetTokens: Int
    /// 代笔自愈/润修：规划时不带近期会话消息（仍注入合同/状态/要点）。
    let suppressRecentSessionMessages: Bool
    let expectedProjectRevision: Int64
    let expectedConfigRevision: Int64
    let expectedBranchHeadRevision: Int64

    init(
        id: NovelRunID,
        operationID: NovelOperationID,
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        kind: NovelRunKind,
        mode: NovelSessionMode,
        granularity: NovelGenerationGranularity?,
        userText: String,
        userMessageID: NovelMessageID,
        assistantMessageID: NovelMessageID,
        candidateID: NovelCandidateID?,
        generationReceiptID: NovelReceiptID,
        injectionReceiptID: NovelReceiptID,
        sourceChapterVersionID: NovelChapterVersionID?,
        askUserResponse: NovelAskUserResponse? = nil,
        contextualCharacterMention: String? = nil,
        ghostwritePlanID: NovelChapterPlanID? = nil,
        injectionOverrides: NovelInjectionOverrides = .none,
        inputBudgetTokens: Int = 16_000,
        suppressRecentSessionMessages: Bool = false,
        expectedProjectRevision: Int64,
        expectedConfigRevision: Int64,
        expectedBranchHeadRevision: Int64
    ) {
        self.id = id
        self.operationID = operationID
        self.projectID = projectID
        self.branchID = branchID
        self.kind = kind
        self.mode = mode
        self.granularity = granularity
        self.userText = userText
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.candidateID = candidateID
        self.generationReceiptID = generationReceiptID
        self.injectionReceiptID = injectionReceiptID
        self.sourceChapterVersionID = sourceChapterVersionID
        self.askUserResponse = askUserResponse
        self.contextualCharacterMention = contextualCharacterMention
        self.ghostwritePlanID = ghostwritePlanID
        self.injectionOverrides = NovelInjectionOverrides(
            forceIncludeMaterialIDs: Array(Set(injectionOverrides.forceIncludeMaterialIDs)).sorted {
                $0.description < $1.description
            },
            forceExcludeMaterialIDs: Array(Set(injectionOverrides.forceExcludeMaterialIDs)).sorted {
                $0.description < $1.description
            }
        )
        self.inputBudgetTokens = inputBudgetTokens
        self.suppressRecentSessionMessages = suppressRecentSessionMessages
        self.expectedProjectRevision = expectedProjectRevision
        self.expectedConfigRevision = expectedConfigRevision
        self.expectedBranchHeadRevision = expectedBranchHeadRevision
    }

    func canonicalPayloadSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = NovelCanonicalRunPayload(
            id: id,
            projectID: projectID,
            branchID: branchID,
            kind: kind,
            mode: mode,
            granularity: granularity,
            userText: userText,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            candidateID: candidateID,
            generationReceiptID: generationReceiptID,
            injectionReceiptID: injectionReceiptID,
            sourceChapterVersionID: sourceChapterVersionID,
            askUserResponse: askUserResponse,
            contextualCharacterMention: contextualCharacterMention,
            ghostwritePlanID: ghostwritePlanID,
            injectionOverrides: injectionOverrides,
            inputBudgetTokens: inputBudgetTokens,
            suppressRecentSessionMessages: suppressRecentSessionMessages
        )
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct NovelCanonicalRunPayload: Codable {
    let id: NovelRunID
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let kind: NovelRunKind
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let userText: String
    let userMessageID: NovelMessageID
    let assistantMessageID: NovelMessageID
    let candidateID: NovelCandidateID?
    let generationReceiptID: NovelReceiptID
    let injectionReceiptID: NovelReceiptID
    let sourceChapterVersionID: NovelChapterVersionID?
    let askUserResponse: NovelAskUserResponse?
    let contextualCharacterMention: String?
    let ghostwritePlanID: NovelChapterPlanID?
    let injectionOverrides: NovelInjectionOverrides
    let inputBudgetTokens: Int
    let suppressRecentSessionMessages: Bool
}

struct NovelRunReceipt: Codable, Equatable, Sendable {
    let runID: NovelRunID
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let receiptID: NovelReceiptID
}

struct NovelSessionMessageSnapshot: Codable, Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let message: NovelSessionMessageRecord
}

struct NovelFailure: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let isRetryable: Bool
}

struct NovelDiscussionArchiveDraftDecision: Identifiable, Equatable, Sendable {
    let id: UUID
    var topic: String
    var decision: String
    let relatedMaterialID: NovelMaterialID?
}

struct NovelDiscussionArchiveDraft: Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let sessionID: NovelSessionID
    let throughSequence: Int64
    let chapterID: NovelChapterID?
    let summary: String
    let decisions: [NovelDiscussionArchiveDraftDecision]
}

/// One review-model pass over a ghostwritten chapter. The host, rather than the
/// model's summary booleans, decides whether the candidate can enter canon.
struct NovelGhostwriteChapterAdjudicationResult: Equatable, Sendable {
    let adjudication: NovelChapterAdjudicationV1
    let blockingContinuityIssues: [NovelContinuityIssue]
    let droppedContinuityIssueCount: Int
    /// Present only when prose, state delta, and plan consumption committed together.
    let collectionOutcome: NovelOutcome?

    var didCollect: Bool { collectionOutcome != nil }
}

struct NovelRun: Sendable {
    let id: NovelRunID
    let events: AsyncStream<NovelRunEvent>
}

enum NovelRunEvent: Sendable {
    case started(NovelRunReceipt)
    /// Presentation-only thinking stream. Must not be written into manuscript partials.
    case reasoningDelta(String)
    /// Full thinking snapshot; separate from incremental reasoning deltas.
    case reasoningReplacement(String)
    case delta(String)
    case replaced(String)
    case completed(NovelSessionMessageSnapshot)
    case interrupted(NovelSessionMessageSnapshot?)
    case failed(NovelFailure)
    case persistenceBlocked(NovelFailure)
}

/// 一次成功项目 mutation 的广播元素。operationID 供订阅方抑制自身发起的回流。
struct NovelProjectMutationEvent: Sendable, Equatable {
    let projectID: NovelProjectID
    let operationID: NovelOperationID
    let refreshesSelection: Bool

    init(
        projectID: NovelProjectID,
        operationID: NovelOperationID,
        refreshesSelection: Bool = true
    ) {
        self.projectID = projectID
        self.operationID = operationID
        self.refreshesSelection = refreshesSelection
    }
}
