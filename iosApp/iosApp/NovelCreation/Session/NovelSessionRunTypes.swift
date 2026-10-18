import Foundation

struct NovelSessionBinding: Equatable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

struct NovelCharacterIdentityMention: Identifiable, Equatable, Sendable {
    let name: String
    var id: String { NovelCharacterIdentityResolver.normalize(name) }
}

/// 批量整章润色中单章的结果。
struct NovelBatchPolishChapterResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// 通过漂移校验,已采用为该章新版本。
        case adopted
        /// 漂移校验判定润色改动了剧情事实,自动跳过(原文不变)。
        case skippedDrift
        /// 生成或采用失败。
        case failed
        /// 批量被停止时尚未轮到。
        case cancelled
    }

    let chapterID: NovelChapterID
    let title: String
    var outcome: Outcome
    var message: String? = nil
}

/// 批量整章润色的实时进度与最终报告。`phase == .running` 期间随观察更新,
/// 完成/停止后保留为报告,直到 `clearBatchPolish()` 清空回到选择态。
struct NovelBatchPolishProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        case done
        case cancelled
    }

    let binding: NovelSessionBinding
    let total: Int
    var completed: Int
    var currentTitle: String?
    var phase: Phase
    var results: [NovelBatchPolishChapterResult]
    let startedAt: Date

    var adoptedCount: Int { results.filter { $0.outcome == .adopted }.count }
    var skippedCount: Int { results.filter { $0.outcome == .skippedDrift }.count }
    var failedCount: Int { results.filter { $0.outcome == .failed }.count }
    var cancelledCount: Int { results.filter { $0.outcome == .cancelled }.count }
}

struct NovelSessionRunDraft: Equatable, Sendable {
    let kind: NovelRunKind
    let mode: NovelSessionMode
    let granularity: NovelGenerationGranularity?
    let userText: String
    let sourceChapterVersionID: NovelChapterVersionID?
    let askUserResponse: NovelAskUserResponse?
    let injectionOverrides: NovelInjectionOverrides
    let inputBudgetTokens: Int
    var contextualCharacterMention: String? = nil
    var ghostwritePlanID: NovelChapterPlanID? = nil
    /// 代笔自愈/润修：不注入近期会话全文，避免失败稿污染下一 attempt。
    var suppressRecentSessionMessages: Bool = false
}

/// Absolute presentation target for one streaming run identity.
///
/// Deltas and replacements update `targetContent`; the UI only advances through
/// `NovelSessionPresentationPacer` so provider bursts do not dump multi-line
/// height steps into the sizeChanges-anchored list in a single flush.
