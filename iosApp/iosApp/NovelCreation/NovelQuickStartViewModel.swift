import Foundation
import Observation
import UIKit

struct NovelQuickStartOwner: Hashable, Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
}

enum NovelQuickStartStatus: Equatable, Sendable {
    case idle
    case starting(run: NovelActiveRunRecord)
    case generating(runID: NovelRunID)
    case awaitingUser(promptMessageID: NovelMessageID)
    case failed(message: String)
    case persistenceBlocked(runID: NovelRunID, message: String)
    case refreshFailed(message: String)
}

extension NovelCreationViewModel {
    /// - Parameters:
    ///   - guidance: 用户在「重新生成设定建议」里填的调整方向,会被并入请求正文。
    ///   - coreIdeaOverride: 用户载入最初的核心想法后编辑出的本轮版本。它只覆盖本轮
    ///     prompt 的核心想法,不会改写项目里作为创建元数据保存的 `quickStartSeed`。
    ///   - exactUserText: 重试专用。`retryGeneration` 从失败 run 的**持久化** user 消息
    ///     取回原文并原样重发,以满足 `isEligibleForExactRetry` 的「精确重试」契约。
    ///     若不传,重试会退回默认文案、把用户填过的调整方向静默丢掉(真机实测过的缺陷)。
    @discardableResult
    func startQuickStartSuggestions(
        guidance: String? = nil,
        coreIdeaOverride: String? = nil,
        exactUserText: String? = nil,
        askUserResponse: NovelAskUserResponse? = nil
    ) async -> NovelRunID? {
        guard !isPerforming,
              !requiresReload,
              let project = projectSnapshot,
              let branch = branchSnapshot,
              project.project.creationMode == .quickStart,
              branch.branch.activeRunID == nil else { return nil }
        let projectID = project.project.id
        let owner = NovelQuickStartOwner(
            projectID: projectID,
            branchID: branch.branch.id
        )
        let trimmedGuidance = guidance?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCoreIdeaOverride = coreIdeaOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let originalCoreIdea = project.project.quickStartSeed?.coreIdea
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userText: String
        if let exactUserText, !exactUserText.isEmpty {
            userText = exactUserText
        } else if let trimmedCoreIdeaOverride,
                  !trimmedCoreIdeaOverride.isEmpty,
                  trimmedCoreIdeaOverride != originalCoreIdea {
            userText = """
            请生成一组可确认的世界观、人物、总剧情大纲和写作要求建议。

            本轮核心想法（仅本次有效）：
            \(trimmedCoreIdeaOverride)

            若本轮核心想法与 QUICK START SEED 中的 Core idea 不一致，以本轮内容为准；
            题材仍沿用 QUICK START SEED。
            """
        } else if let trimmedGuidance, !trimmedGuidance.isEmpty {
            userText = "请生成一组可确认的世界观、人物、总剧情大纲和写作要求建议。\n\n用户对上一版建议不满意，要求按以下方向调整重新生成：\n\(trimmedGuidance)"
        } else {
            userText = "请生成一组可确认的世界观、人物、总剧情大纲和写作要求建议。"
        }
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: projectID,
            branchID: branch.branch.id,
            kind: .quickStart,
            mode: .discussPlan,
            granularity: nil,
            userText: userText,
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: nil,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            askUserResponse: askUserResponse,
            inputBudgetTokens: 16_000,
            expectedProjectRevision: project.project.revision,
            expectedConfigRevision: project.project.configRevision,
            expectedBranchHeadRevision: branch.branch.headRevision
        )
        guard acquireOperation(ownerID: request.id.rawValue) else { return nil }
        errorMessage = nil
        let placeholder = NovelActiveRunRecord(
            id: request.id,
            operationID: request.operationID,
            requestPayloadSHA256: (try? request.canonicalPayloadSHA256()) ?? "",
            branchID: request.branchID,
            sessionID: branch.session.id,
            kind: .quickStart,
            mode: .discussPlan,
            granularity: nil,
            userMessageID: request.userMessageID,
            messageID: request.assistantMessageID,
            candidateID: nil,
            sourceChapterVersionID: nil,
            contextualCharacterMention: nil,
            baseCheckpointID: branch.branch.headCheckpointID,
            baseHeadRevision: branch.branch.headRevision,
            status: .running,
            partialContent: "",
            receiptID: request.generationReceiptID,
            startedAt: Date(),
            terminalAt: nil,
            interruptionReason: nil,
            terminalFailure: nil,
            chapterPlanDigest: nil
        )
        quickStartStartingProjectID = projectID
        quickStartStartingRun = placeholder
        cancelledQuickStartRunIDs.remove(request.id)
        quickStartStatuses[owner] = .starting(run: placeholder)
        if let previousRunID = quickStartTaskRunIDs[owner] {
            endBackgroundGeneration(for: previousRunID)
        }
        quickStartTasks[owner]?.cancel()
        quickStartTaskRunIDs[owner] = request.id
        beginBackgroundGeneration(for: request)
        quickStartTasks[owner] = Task { @MainActor [weak self] in
            await self?.runQuickStart(request, owner: owner)
        }
        return request.id
    }

    private func runQuickStart(_ request: NovelRunRequest, owner: NovelQuickStartOwner) async {
        guard !Task.isCancelled,
              quickStartTaskRunIDs[owner] == request.id,
              !cancelledQuickStartRunIDs.contains(request.id) else {
            endBackgroundGeneration(for: request.id)
            return
        }
        let run: NovelRun
        quickStartCreationStartRunIDs.insert(request.id)
        do {
            run = try await creation.start(request)
            quickStartCreationStartRunIDs.remove(request.id)
        } catch {
            quickStartCreationStartRunIDs.remove(request.id)
            guard quickStartTaskRunIDs[owner] == request.id else { return }
            endBackgroundGeneration(for: request.id)
            if cancelledQuickStartRunIDs.contains(request.id) {
                quickStartStatuses[owner] = .failed(message: IOSAppLocalization.string(
                    "建议生成已中断，可以重新生成。",
                    defaultValue: "建议生成已中断，可以重新生成。"
                ))
                errorMessage = nil
            } else {
                let message = NovelPresentation.operationErrorMessage(error)
                quickStartStatuses[owner] = .failed(message: message)
                report(error)
            }
            finishQuickStartTask(
                owner: owner,
                runID: request.id,
                releasesStartingBusy: true
            )
            return
        }
        guard quickStartTaskRunIDs[owner] == request.id,
              !cancelledQuickStartRunIDs.contains(request.id) else {
            endBackgroundGeneration(for: request.id)
            return
        }
        quickStartStatuses[owner] = .generating(runID: run.id)
        do {
            try await refreshCurrentSelection(
                projectID: owner.projectID,
                refreshProjectList: false
            )
            errorMessage = nil
            reconcileQuickStartStartingOwner(owner: owner, runID: request.id)
        } catch {
            guard quickStartTaskRunIDs[owner] == request.id else { return }
            reportQuickStartRefreshFailure(error, owner: owner)
        }
        guard quickStartTaskRunIDs[owner] == request.id else { return }
        releaseOperation(ownerID: request.id.rawValue)
        await consumeQuickStart(run, owner: owner)
    }

    private func finishQuickStartTask(
        owner: NovelQuickStartOwner,
        runID: NovelRunID,
        releasesStartingBusy: Bool = false
    ) {
        guard quickStartTaskRunIDs[owner] == runID else { return }
        endBackgroundGeneration(for: runID)
        quickStartTasks[owner] = nil
        quickStartTaskRunIDs[owner] = nil
        if quickStartStartingRun?.id == runID {
            quickStartStartingRun = nil
            quickStartStartingProjectID = nil
        }
        cancelledQuickStartRunIDs.remove(runID)
        if releasesStartingBusy {
            releaseOperation(ownerID: runID.rawValue)
        }
    }

    private func reportQuickStartRefreshFailure(_ error: Error, owner: NovelQuickStartOwner) {
        let message = NovelPresentation.operationErrorMessage(error)
        quickStartStatuses[owner] = .refreshFailed(message: message)
        report(error)
    }

    func retryQuickStartPersistence(runID: NovelRunID) async {
        let ownerID = UUID()
        guard let projectID = selectedProjectID,
              let branchID = selectedBranchID,
              acquireOperation(ownerID: ownerID) else { return }
        let owner = NovelQuickStartOwner(projectID: projectID, branchID: branchID)
        defer { releaseOperation(ownerID: ownerID) }
        do {
            try await creation.retryPendingTerminal(runID: runID)
            try await refreshCurrentSelection(
                projectID: projectID,
                refreshProjectList: false
            )
            quickStartStatuses[owner] = nil
            errorMessage = nil
        } catch {
            let message = NovelPresentation.operationErrorMessage(error)
            quickStartStatuses[owner] = .refreshFailed(message: message)
            report(error)
        }
    }

    func reloadQuickStartProject() async {
        let ownerID = UUID()
        guard let projectID = selectedProjectID,
              let branchID = selectedBranchID,
              acquireOperation(ownerID: ownerID) else { return }
        let owner = NovelQuickStartOwner(projectID: projectID, branchID: branchID)
        defer { releaseOperation(ownerID: ownerID) }
        do {
            try await refreshCurrentSelection(
                projectID: projectID,
                refreshProjectList: false
            )
            if let runID = quickStartStartingRun?.id {
                reconcileQuickStartStartingOwner(owner: owner, runID: runID)
            }
            quickStartStatuses[owner] = nil
            errorMessage = nil
        } catch {
            let message = NovelPresentation.operationErrorMessage(error)
            quickStartStatuses[owner] = .refreshFailed(message: message)
            report(error)
        }
    }

    private func consumeQuickStart(_ run: NovelRun, owner: NovelQuickStartOwner) async {
        for await event in run.events {
            guard quickStartTaskRunIDs[owner] == run.id else { return }
            switch event {
            case .started:
                do {
                    try await refreshCurrentSelection(
                        projectID: owner.projectID,
                        refreshProjectList: false
                    )
                    reconcileQuickStartStartingOwner(owner: owner, runID: run.id)
                } catch {
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                    reportQuickStartRefreshFailure(error, owner: owner)
                }
            case .delta, .replaced, .reasoningDelta, .reasoningReplacement:
                continue
            case .completed(let snapshot):
                do {
                    try await refreshCurrentSelection(
                        projectID: owner.projectID,
                        refreshProjectList: false
                    )
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                    if case .some(.askUser) = snapshot.message.interaction {
                        quickStartStatuses[owner] = .awaitingUser(
                            promptMessageID: snapshot.message.id
                        )
                    } else {
                        quickStartStatuses[owner] = nil
                    }
                    errorMessage = nil
                } catch {
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                    reportQuickStartRefreshFailure(error, owner: owner)
                }
                finishQuickStartTask(owner: owner, runID: run.id)
                return
            case .interrupted:
                quickStartStatuses[owner] = .failed(message: IOSAppLocalization.string(
                    "建议生成已中断，可以重新生成。",
                    defaultValue: "建议生成已中断，可以重新生成。"
                ))
                do {
                    try await refreshCurrentSelection(
                        projectID: owner.projectID,
                        refreshProjectList: false
                    )
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                } catch {
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                    reportQuickStartRefreshFailure(error, owner: owner)
                }
                finishQuickStartTask(owner: owner, runID: run.id)
                return
            case .failed(let failure):
                quickStartStatuses[owner] = .failed(
                    message: NovelPresentation.failureMessage(failure)
                )
                do {
                    try await refreshCurrentSelection(
                        projectID: owner.projectID,
                        refreshProjectList: false
                    )
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                } catch {
                    guard quickStartTaskRunIDs[owner] == run.id else { return }
                    reportQuickStartRefreshFailure(error, owner: owner)
                }
                finishQuickStartTask(owner: owner, runID: run.id)
                return
            case .persistenceBlocked(let failure):
                quickStartStatuses[owner] = .persistenceBlocked(
                    runID: run.id,
                    message: NovelPresentation.failureMessage(failure)
                )
            }
        }
    }

    private func reconcileQuickStartStartingOwner(
        owner: NovelQuickStartOwner,
        runID: NovelRunID
    ) {
        guard quickStartStartingProjectID == owner.projectID,
              quickStartStartingRun?.id == runID,
              projectSnapshot?.activeRuns.contains(where: {
                  $0.id == runID && $0.branchID == owner.branchID
              }) == true else {
            return
        }
        quickStartStartingProjectID = nil
        quickStartStartingRun = nil
    }

    func reconcileQuickStartAfterInterrupt(
        owner: NovelQuickStartOwner,
        runID: NovelRunID
    ) async {
        do {
            try await refreshCurrentSelection(
                projectID: owner.projectID,
                refreshProjectList: false
            )
        } catch {
            let message = NovelPresentation.operationErrorMessage(error)
            clearQuickStartTask(
                owner: owner,
                runID: runID,
                status: .refreshFailed(message: message)
            )
            return
        }
        guard quickStartTaskRunIDs[owner] == runID else { return }
        let run = projectSnapshot?.activeRuns.first { $0.id == runID }
        let status: NovelQuickStartStatus?
        switch run?.status {
        case .completed:
            status = nil
        case .failed:
            status = .failed(
                message: run?.terminalFailure.map(NovelPresentation.failureMessage)
                    ?? IOSAppLocalization.string(
                        "建议生成失败，可以重新生成。",
                        defaultValue: "建议生成失败，可以重新生成。"
                    )
            )
        case .interrupted, nil:
            status = .failed(message: IOSAppLocalization.string(
                "建议生成已中断，可以重新生成。",
                defaultValue: "建议生成已中断，可以重新生成。"
            ))
        case .running:
            guard quickStartTaskRunIDs[owner] == runID else { return }
            quickStartStatuses[owner] = .refreshFailed(
                message: IOSAppLocalization.string(
                    "生成状态尚未收口，请重新载入后再继续。",
                    defaultValue: "生成状态尚未收口，请重新载入后再继续。"
                )
            )
            releaseOperation(ownerID: runID.rawValue)
            return
        }
        clearQuickStartTask(owner: owner, runID: runID, status: status)
    }

    func clearQuickStartTask(
        owner: NovelQuickStartOwner,
        runID: NovelRunID,
        status: NovelQuickStartStatus?
    ) {
        guard quickStartTaskRunIDs[owner] == runID else { return }
        endBackgroundGeneration(for: runID)
        quickStartTasks[owner]?.cancel()
        quickStartTasks[owner] = nil
        quickStartTaskRunIDs[owner] = nil
        quickStartCreationStartRunIDs.remove(runID)
        if quickStartStartingProjectID == owner.projectID,
           quickStartStartingRun?.id == runID {
            quickStartStartingProjectID = nil
            quickStartStartingRun = nil
        }
        cancelledQuickStartRunIDs.remove(runID)
        quickStartStatuses[owner] = status
        errorMessage = nil
        releaseOperation(ownerID: runID.rawValue)
    }

    func quickStartOwner(
        projectID: NovelProjectID,
        runID: NovelRunID
    ) -> NovelQuickStartOwner? {
        quickStartTaskRunIDs.first(where: {
            $0.key.projectID == projectID && $0.value == runID
        })?.key
    }

}
