import Foundation

protocol NovelCreation: Sendable {
    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot
    func perform(_ action: NovelAction) async throws -> NovelOutcome
    func applyWorkspacePlot(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        path: String,
        body: String
    ) async throws
    func applyWorkspacePlot(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        path: String,
        body: String,
        approvalResponse: NovelAskUserResponse?
    ) async throws
    func applyWorkspaceFastForwardPlot(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID,
        chapterTitle: String,
        chapterContent: String
    ) async throws
    func applyWorkspacePlotRelink(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws
    func applyWorkspacePlotAcceptStale(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws
    /// Publish available candidates into `checkout/drafts/` without reprinting chapters.
    func materializeWorktreeDrafts(projectID: NovelProjectID) async throws
    /// Body of `drafts/*.md` for this candidate, or nil if the worktree is absent.
    func worktreeDraftBody(
        projectID: NovelProjectID,
        candidateID: NovelCandidateID
    ) async -> String?
    func worktreeManifestExists(projectID: NovelProjectID) async -> Bool
    /// 项目文档每次成功 mutation 后广播事件。订阅方（UI VM）据此刷新快照，
    /// 让非 UI 写入源（如讨论工具 executor）的改动即时反映到界面。
    /// 默认实现为立即结束的空流，测试替身免实现。
    func mutationEvents() async -> AsyncStream<NovelProjectMutationEvent>
    func start(_ request: NovelRunRequest) async throws -> NovelRun
    /// Closes a user-visible run across the pre-durable start and durable runtime boundary.
    /// Success means the requested run can no longer become an active hidden run.
    func interruptRun(_ command: NovelCancelRunCommand) async throws
    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async
    /// Reconnects only server-backed runs that were locally detached when iOS
    /// reclaimed background execution time. Non-resumable providers are ignored.
    func resumeDetachedGenerationRuns() async
    func retryPendingTerminal(runID: NovelRunID) async throws
    /// Cancels in-flight fact-sync mutations for a project so UI Stop can interrupt
    /// long model work instead of only cancelling the outer awaiter.
    /// Production implementations must not cancel polish-adopt from this entry.
    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async
    func distillDiscussionArchive(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID?
    ) async throws -> NovelDiscussionArchiveDraft
    /// 发起前的预估:扫几章、切几块。块数等于这次要发多少个模型请求。
    func planContinuityAudit(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditPlan
    /// 扫描全书正文,列出前后打架的地方。结果只在内存里,不写进项目文档。
    func auditContinuity(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditReport
    /// 代笔软门：把尚未收录的整章候选当作下一章，与已有正文一并做连续性检查。不写盘。
    /// - Parameter maxPriorManuscriptChapters: 只带最近若干已收正文 + 候选；`nil` 表示全书（手动深扫）。
    func auditContinuityIncludingCandidate(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        maxPriorManuscriptChapters: Int?
    ) async throws -> NovelContinuityAuditReport
    /// 按检查结果改写冲突段落：先文不动，只改较后的一章。走既有 `saveManualEdit`。
    func repairContinuity(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        report: NovelContinuityAuditReport,
        issueIDs: Set<String>?
    ) async throws -> NovelContinuityRepairReport
    /// 代笔验收：用审稿模型核对候选是否满足已确认本章计划。结果不写进项目文档。
    func acceptChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID
    ) async throws -> NovelChapterPlanAcceptanceV1
    /// 代笔单章联合审查：一次模型调用完成计划验收、近距连续性检查与状态增量；
    /// 通过硬门后，正文、状态与本章计划在同一提交中落盘。
    func adjudicateAndCollectGhostwriteChapter(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        prepareNextPlan: Bool
    ) async throws -> NovelGhostwriteChapterAdjudicationResult
    /// 代笔多章：自动拟定并确认下一章合同（创作模型）。批内第 2～N 章走此路径。
    func proposeAndConfirmNextChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        nextChapterOrdinal: Int,
        previousPlanSummary: String?
    ) async throws -> NovelChapterPlanRecord
    /// 首次/无确认计划：根据前文生成草稿本章计划，仍须用户确认。
    func proposeNextChapterPlanDraft(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        nextChapterOrdinal: Int,
        previousPlanSummary: String?
    ) async throws -> NovelChapterPlanRecord
    /// 跨进程代笔批进度 sidecar。
    func loadGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelGhostwriteBatchProgressRecord?
    func saveGhostwriteBatchProgress(_ record: NovelGhostwriteBatchProgressRecord) async throws
    func removeGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws
}

extension NovelCreation {
    func applyWorkspacePlot(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        path: String,
        body: String,
        approvalResponse: NovelAskUserResponse?
    ) async throws {
        guard approvalResponse == nil else {
            throw NovelError.invalidInput("Workspace plot approval is unavailable.")
        }
        try await applyWorkspacePlot(projectID: projectID, branchID: branchID, path: path, body: body)
    }

    func applyWorkspacePlot(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        path: String,
        body: String
    ) async throws {
        _ = projectID
        _ = branchID
        _ = path
        _ = body
        throw NovelError.invalidInput("Workspace plot write is unavailable.")
    }

    func applyWorkspaceFastForwardPlot(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID,
        chapterTitle: String,
        chapterContent: String
    ) async throws {
        _ = projectID
        _ = branchID
        _ = chapterID
        _ = chapterTitle
        _ = chapterContent
        throw NovelError.invalidInput("Workspace plot write is unavailable.")
    }

    func applyWorkspacePlotRelink(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws {
        _ = projectID
        _ = branchID
        throw NovelError.invalidInput("Workspace plot write is unavailable.")
    }

    func applyWorkspacePlotAcceptStale(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws {
        _ = projectID
        _ = branchID
        throw NovelError.invalidInput("Workspace plot write is unavailable.")
    }

    func materializeWorktreeDrafts(projectID: NovelProjectID) async throws {
        _ = projectID
    }

    func worktreeDraftBody(
        projectID: NovelProjectID,
        candidateID: NovelCandidateID
    ) async -> String? {
        _ = projectID
        _ = candidateID
        return nil
    }

    func worktreeManifestExists(projectID: NovelProjectID) async -> Bool {
        _ = projectID
        return false
    }

    func mutationEvents() async -> AsyncStream<NovelProjectMutationEvent> {
        AsyncStream { $0.finish() }
    }

    func loadGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelGhostwriteBatchProgressRecord? {
        _ = projectID
        _ = branchID
        return nil
    }

    func saveGhostwriteBatchProgress(_ record: NovelGhostwriteBatchProgressRecord) async throws {
        _ = record
    }

    func removeGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws {
        _ = projectID
        _ = branchID
    }

    func resumeDetachedGenerationRuns() async {
        // Test doubles and non-live runtimes do not own resumable provider jobs.
    }

    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async {
        // Default no-op for test doubles that never schedule background mutations.
    }

    func distillDiscussionArchive(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        chapterID: NovelChapterID?
    ) async throws -> NovelDiscussionArchiveDraft {
        throw NovelError.invalidInput("This novel runtime cannot distill discussion archives.")
    }

    func planContinuityAudit(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditPlan {
        throw NovelError.invalidInput("This novel runtime cannot audit story continuity.")
    }

    func auditContinuity(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditReport {
        throw NovelError.invalidInput("This novel runtime cannot audit story continuity.")
    }

    func auditContinuityIncludingCandidate(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        maxPriorManuscriptChapters: Int?
    ) async throws -> NovelContinuityAuditReport {
        throw NovelError.invalidInput("This novel runtime cannot audit story continuity.")
    }

    func repairContinuity(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        report: NovelContinuityAuditReport,
        issueIDs: Set<String>?
    ) async throws -> NovelContinuityRepairReport {
        throw NovelError.invalidInput("This novel runtime cannot repair story continuity.")
    }

    func acceptChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID
    ) async throws -> NovelChapterPlanAcceptanceV1 {
        throw NovelError.invalidInput("This novel runtime cannot accept chapter-plan candidates.")
    }

    func adjudicateAndCollectGhostwriteChapter(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        candidateID: NovelCandidateID,
        prepareNextPlan: Bool
    ) async throws -> NovelGhostwriteChapterAdjudicationResult {
        throw NovelError.invalidInput("This novel runtime cannot adjudicate ghostwritten chapters.")
    }

    func proposeAndConfirmNextChapterPlan(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        nextChapterOrdinal: Int,
        previousPlanSummary: String?
    ) async throws -> NovelChapterPlanRecord {
        throw NovelError.invalidInput("This novel runtime cannot propose chapter plans.")
    }

    func proposeNextChapterPlanDraft(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        nextChapterOrdinal: Int,
        previousPlanSummary: String?
    ) async throws -> NovelChapterPlanRecord {
        throw NovelError.invalidInput("This novel runtime cannot propose chapter plans.")
    }

    func interruptRun(_ command: NovelCancelRunCommand) async throws {
        _ = try await perform(.cancelRun(command))
    }

    func interruptForBackground(projectID: NovelProjectID, deadline: Date) async {
        await interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: nil
        )
    }

    func interruptForBackground(projectID: NovelProjectID) async {
        await interruptForBackground(
            projectID: projectID,
            deadline: Date().addingTimeInterval(5),
            runID: nil
        )
    }
}
