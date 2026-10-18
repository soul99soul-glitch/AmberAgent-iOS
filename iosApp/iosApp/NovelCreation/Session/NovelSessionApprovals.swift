import Foundation

extension NovelSessionViewModel {
    @discardableResult
    func answerAskUser(
        promptMessageID: NovelMessageID,
        answer: String
    ) async -> Bool {
        guard answeringAskUserMessageID != promptMessageID else { return false }
        guard locallyResolvedAskUser[promptMessageID] == nil,
              !durableMessages.contains(where: {
                  if case .some(.askUserAnswer(let response)) = $0.interaction {
                      return response.promptMessageID == promptMessageID
                  }
                  return false
              }) else {
            operationErrorMessage = "这个问题已经回答过了。"
            return false
        }
        guard let promptMessage = durableMessages.first(where: {
            $0.id == promptMessageID && $0.role == .assistant
        }), case .some(.askUser(let prompt)) = promptMessage.interaction else {
            operationErrorMessage = "这个问题已经失效，请重新发起讨论。"
            return false
        }
        answeringAskUserMessageID = promptMessageID
        // 卡片先本地收口为已回答，不等写盘 / durable refresh；失败时撤回，
        // 让卡片回到可重试状态（错误文案由各分支写入 operationErrorMessage）。
        let optimisticResponse = NovelAskUserResponse(
            promptMessageID: promptMessageID,
            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let hadLocalResponse = locallyResolvedAskUser[promptMessageID] != nil
        if !hadLocalResponse {
            locallyResolvedAskUser[promptMessageID] = optimisticResponse
        }
        let answered = await resolveAskUser(
            prompt: prompt,
            promptMessage: promptMessage,
            promptMessageID: promptMessageID,
            answer: answer
        )
        answeringAskUserMessageID = nil
        if !answered, !hadLocalResponse,
           locallyResolvedAskUser[promptMessageID] == optimisticResponse {
            locallyResolvedAskUser[promptMessageID] = nil
            // 投影下次从未叠加本地回答的 durable base 重建卡片。
        }
        // 卡片在点击时已乐观变形；成功触感只在写入真正落定后发出，失败回滚不误报。
        if answered, Self.isApprovedApproval(prompt: prompt, answer: optimisticResponse.answer) {
            AmberHaptics.trigger(.success)
        }
        return answered
    }

    private static func isApprovedApproval(prompt: NovelAskUserPrompt, answer: String) -> Bool {
        if prompt.ghostwritePlan != nil {
            return NovelGhostwritePlanApproval.approvedChapterCount(from: answer) != nil
        }
        if prompt.chapterRevision != nil { return answer == NovelChapterRevisionApproval.approveOption }
        if prompt.workspacePlot != nil { return answer == NovelWorkspacePlotApproval.approveOption }
        if prompt.manuscriptRevert != nil { return answer == NovelManuscriptRevertApproval.approveOption }
        if prompt.manuscriptDelete != nil { return answer == NovelManuscriptDeleteApproval.approveOption }
        return false
    }

    private func resolveAskUser(
        prompt: NovelAskUserPrompt,
        promptMessage: NovelSessionMessageRecord,
        promptMessageID: NovelMessageID,
        answer: String
    ) async -> Bool {
        let approvalResponse = NovelAskUserResponse(
            promptMessageID: promptMessageID,
            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let proposal = prompt.ghostwritePlan {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let chapterCount = NovelGhostwritePlanApproval.approvedChapterCount(from: trimmed) {
                guard await applyGhostwritePlanApproval(
                    proposal,
                    targetChapterCount: chapterCount,
                    approvalResponse: approvalResponse
                ) else { return false }
                locallyResolvedAskUser[promptMessageID] = NovelAskUserResponse(
                    promptMessageID: promptMessageID,
                    answer: trimmed
                )
                return true
            } else if trimmed != NovelGhostwritePlanApproval.rejectOption {
                operationErrorMessage = "请选择代笔章数后开始，或暂不开始。"
                return false
            }
        }
        if let revision = prompt.chapterRevision {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == NovelChapterRevisionApproval.approveOption {
                guard await applyChapterRevision(revision, approvalResponse: approvalResponse) else { return false }
                locallyResolvedAskUser[promptMessageID] = NovelAskUserResponse(
                    promptMessageID: promptMessageID,
                    answer: trimmed
                )
                operationErrorMessage = nil
                return true
            } else if trimmed != NovelChapterRevisionApproval.rejectOption {
                operationErrorMessage = "请选择写入正文或拒绝这次修改。"
                return false
            }
        }
        if let plot = prompt.workspacePlot {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == NovelWorkspacePlotApproval.approveOption {
                if let failure = await workspace.applyWorkspacePlot(
                    path: plot.path, body: plot.body, approvalResponse: approvalResponse
                ) {
                    operationErrorMessage = failure
                    return false
                }
                locallyResolvedAskUser[promptMessageID] = NovelAskUserResponse(
                    promptMessageID: promptMessageID,
                    answer: trimmed
                )
                operationErrorMessage = nil
                await bindToCurrentSelection()
                return true
            } else if trimmed != NovelWorkspacePlotApproval.rejectOption {
                operationErrorMessage = "请选择写入剧情或拒绝这次修改。"
                return false
            }
        }
        if let revert = prompt.manuscriptRevert {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == NovelManuscriptRevertApproval.approveOption {
                guard await applyManuscriptRevert(revert, approvalResponse: approvalResponse) else { return false }
                locallyResolvedAskUser[promptMessageID] = NovelAskUserResponse(
                    promptMessageID: promptMessageID,
                    answer: trimmed
                )
                operationErrorMessage = nil
                return true
            } else if trimmed != NovelManuscriptRevertApproval.rejectOption {
                operationErrorMessage = "请选择回退这几章或取消回退。"
                return false
            }
        }
        if let deletion = prompt.manuscriptDelete {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == NovelManuscriptDeleteApproval.approveOption {
                guard await applyManuscriptDelete(deletion, approvalResponse: approvalResponse) else { return false }
                locallyResolvedAskUser[promptMessageID] = NovelAskUserResponse(
                    promptMessageID: promptMessageID,
                    answer: trimmed
                )
                operationErrorMessage = nil
                return true
            } else if trimmed != NovelManuscriptDeleteApproval.rejectOption {
                operationErrorMessage = "请选择从正文目录删除或取消这次删除。"
                return false
            }
        }
        let response = NovelAskUserResponse(
            promptMessageID: promptMessageID,
            answer: answer
        )
        if let promptRunID = promptMessage.runID,
           workspace.projectSnapshot?.activeRuns.first(where: {
               $0.id == promptRunID
           })?.kind == .quickStart {
            guard await workspace.startQuickStartSuggestions(
                exactUserText: answer,
                askUserResponse: response
            ) != nil else { return false }
            operationErrorMessage = nil
            refreshErrorMessage = nil
            await bindToCurrentSelection()
            return true
        }
        let draft = NovelSessionRunDraft(
            kind: .discussion,
            mode: .discussPlan,
            granularity: nil,
            userText: answer,
            sourceChapterVersionID: nil,
            askUserResponse: response,
            injectionOverrides: .none,
            inputBudgetTokens: 16_000
        )
        return await start(draft)
    }

    private func applyGhostwritePlanApproval(
        _ proposal: NovelGhostwritePlanProposal,
        targetChapterCount: Int,
        approvalResponse: NovelAskUserResponse
    ) async -> Bool {
        guard let binding,
              binding.projectID == proposal.projectID,
              binding.branchID == proposal.branchID,
              workspace.selectedProjectID == proposal.projectID,
              workspace.selectedBranchID == proposal.branchID,
              let project = workspace.projectSnapshot,
              let branch = project.branches.first(where: { $0.id == proposal.branchID }) else {
            operationErrorMessage = "这张代笔计划不属于当前项目，请重新发起讨论。"
            return false
        }
        guard !isGhostwriting, !isRunning else {
            operationErrorMessage = "当前已有生成在进行，请结束后再确认代笔计划。"
            return false
        }
        if let blocker = ghostwriteBlocker, blocker != .chapterPlanRequired,
           !(blocker == .ghostwriteRequirementsMissing && ghostwriteReadinessIssue == .missingChapterPlan) {
            operationErrorMessage = blocker.displayName
            return false
        }
        guard branch.headRevision == proposal.expectedHeadRevision,
              branch.workingRevision == proposal.expectedWorkingRevision else {
            operationErrorMessage = "当前正文已经变化，请基于最新内容重新讨论代笔计划。"
            return false
        }
        let currentPlan = project.chapterPlan(for: proposal.branchID)
        if let currentPlan {
            let matchesOriginal = currentPlan.id == proposal.planID
                && currentPlan.contentDigest == proposal.expectedCurrentPlanDigest
            let matchesApprovedRetry = currentPlan.id == proposal.planID
                && currentPlan.contentDigest == proposal.proposedPlanDigest
            guard matchesOriginal || matchesApprovedRetry else {
                operationErrorMessage = "本章计划已经变化，请重新发起讨论。"
                return false
            }
        } else if proposal.expectedCurrentPlanDigest != nil {
            operationErrorMessage = "原本章计划已经被清除，请重新发起讨论。"
            return false
        }
        let readinessIssues = workspace.ghostwriteReadinessIssues(requireChapterPlan: false)
        guard readinessIssues.isEmpty else {
            operationErrorMessage = readinessIssues.map(\.displayName).joined(separator: "；")
            return false
        }

        let needsModeChange = project.project.collaborationMode != .ghostwrite
        let hasUpcomingArc = !proposal.upcomingArc.isEmpty
        let planSaved = await workspace.upsertChapterPlan(
            planID: proposal.planID,
            status: .confirmed,
            outlinePlacement: proposal.outlinePlacement,
            goalAndConflict: proposal.goalAndConflict,
            mustHappen: proposal.mustHappen,
            mustNotHappen: proposal.mustNotHappen,
            endingHook: proposal.endingHook,
            visibleFacts: proposal.visibleFacts,
            approvalResponse: !needsModeChange && !hasUpcomingArc ? approvalResponse : nil
        )
        guard planSaved else {
            operationErrorMessage = workspace.errorMessage ?? "本章计划保存失败，请重试。"
            return false
        }
        if hasUpcomingArc {
            let arcSaved = await workspace.upsertUpcomingArc(
                beats: proposal.upcomingArc,
                approvalResponse: needsModeChange ? nil : approvalResponse
            )
            guard arcSaved else {
                operationErrorMessage = workspace.errorMessage ?? "后续剧情参考保存失败，请重试。"
                return false
            }
        }
        if needsModeChange {
            let modeSaved = await workspace.setCollaborationMode(.ghostwrite, approvalResponse: approvalResponse)
            guard modeSaved else {
                operationErrorMessage = workspace.errorMessage ?? "未能切入代笔模式，请重试。"
                return false
            }
        }
        reconcileComposerIntent()
        ghostwriteTargetChapterCount = NovelGhostwriteBatch.clamp(targetChapterCount)
        // The configuration approval is durable. A later pipeline start failure
        // remains actionable through the existing ghostwrite start/continue UI.
        _ = startGhostwriteChapter(targetChapterCount: ghostwriteTargetChapterCount)
        return true
    }

    private func applyChapterRevision(
        _ proposal: NovelChapterRevisionProposal,
        approvalResponse: NovelAskUserResponse
    ) async -> Bool {
        if isGhostwriting {
            operationErrorMessage = "代笔正在推进本章，暂时不能改正文。"
            return false
        }
        guard let binding,
              let snapshot = workspace.projectSnapshot,
              let branch = snapshot.branches.first(where: { $0.id == binding.branchID }),
              let selection = branch.workingChapterSelections.first(where: {
                  $0.chapterID == proposal.chapterID
              }),
              let version = snapshot.chapterVersions.first(where: {
                  $0.id == selection.versionID && $0.chapterID == proposal.chapterID
              }) else {
            operationErrorMessage = "目标章节已经不在工作正文里，无法写入。"
            return false
        }
        let replaced: (oldText: String, newContent: String)
        do {
            replaced = try NovelParagraphParser.replacingParagraphs(
                in: version.content,
                start: proposal.startParagraph,
                end: proposal.endParagraph,
                with: proposal.newText
            )
        } catch {
            operationErrorMessage = "改正文失败：\(error.localizedDescription)"
            return false
        }
        guard replaced.oldText == proposal.oldText else {
            operationErrorMessage = "正文已变化，请重新读取后再改。"
            return false
        }
        let saved = await workspace.saveManualRewrite(
            chapterID: proposal.chapterID,
            title: version.title,
            content: replaced.newContent,
            approvalResponse: approvalResponse
        )
        if !saved {
            operationErrorMessage = workspace.errorMessage ?? "改正文保存失败，请重试。"
            return false
        }
        return true
    }

    private func applyManuscriptRevert(
        _ proposal: NovelManuscriptRevertProposal,
        approvalResponse: NovelAskUserResponse
    ) async -> Bool {
        if isGhostwriting {
            operationErrorMessage = "代笔正在推进本章，暂时不能回退章节。"
            return false
        }
        let reverted = await workspace.revertRecentChapters(proposal, approvalResponse: approvalResponse)
        if !reverted {
            operationErrorMessage = workspace.errorMessage ?? "回退章节失败，请重试。"
            return false
        }
        return true
    }

    private func applyManuscriptDelete(
        _ proposal: NovelManuscriptDeleteProposal,
        approvalResponse: NovelAskUserResponse
    ) async -> Bool {
        if isGhostwriting {
            operationErrorMessage = "代笔正在推进本章，暂时不能从正文目录删除章节。"
            return false
        }
        guard let binding,
              let snapshot = workspace.projectSnapshot,
              let branch = snapshot.branches.first(where: { $0.id == binding.branchID }) else {
            operationErrorMessage = "当前分支不可用，无法从正文目录删除章节。"
            return false
        }
        guard branch.headRevision == proposal.expectedHeadRevision,
              branch.workingRevision == proposal.expectedWorkingRevision else {
            operationErrorMessage = "当前分支已经变化，请重新发起删除。"
            return false
        }
        for (index, chapterID) in proposal.chapterIDs.enumerated() {
            let deleted = await workspace.deleteChapterFromManuscript(
                chapterID: chapterID,
                approvalResponse: index == proposal.chapterIDs.count - 1 ? approvalResponse : nil
            )
            if !deleted {
                operationErrorMessage = workspace.errorMessage ?? "从正文目录删除失败，请重试。"
                return false
            }
        }
        return true
    }

    @discardableResult
    func associateCharacterAlias(
        _ alias: String,
        with materialID: NovelMaterialID
    ) async -> Bool {
        guard let project = workspace.projectSnapshot,
              let material = workspace.activeMaterials.first(where: {
                  $0.id == materialID && $0.kind == .character
              }),
              let revision = NovelPresentation.currentRevision(for: material, in: project) else {
            operationErrorMessage = "目标角色已经不存在。"
            return false
        }
        let expectedBinding = binding
        let expectedToken = bindingToken
        await workspace.saveMaterial(
            materialID: material.id,
            kind: .character,
            title: revision.title,
            content: revision.content,
            tags: revision.tags,
            injectionMode: revision.injectionMode,
            aliases: material.aliases + [alias],
            refreshProjectList: false
        )
        operationErrorMessage = workspace.errorMessage
        if workspace.errorMessage == nil,
           workspace.selectedProjectID == project.project.id,
           workspace.projectSnapshot?.project.revision == project.project.revision {
            _ = await refreshDurable(binding: expectedBinding, token: expectedToken)
        }
        return workspace.errorMessage == nil
    }

    @discardableResult
    func ignoreCharacterIdentityMention(_ mention: String) async -> Bool {
        await clarifyCharacterIdentityMention(
            mention,
            clarification: "这是一次性出现的路人，不需要建立人物档案。"
        )
    }

    @discardableResult
    func clarifyCharacterIdentityMention(
        _ mention: String,
        clarification: String
    ) async -> Bool {
        let normalized = clarification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            operationErrorMessage = "请先输入人物身份说明。"
            return false
        }
        let expectedBinding = binding
        let expectedToken = bindingToken
        let previousProject = workspace.projectSnapshot?.project
        let succeeded = await workspace.clarifyCharacterIdentity(
            mention: mention,
            clarification: normalized,
            refreshProjectList: false
        )
        operationErrorMessage = workspace.errorMessage
        if succeeded, workspace.errorMessage == nil,
           let previousProject,
           workspace.selectedProjectID == previousProject.id,
           workspace.projectSnapshot?.project.revision == previousProject.revision {
            _ = await refreshDurable(binding: expectedBinding, token: expectedToken)
        }
        return succeeded && workspace.errorMessage == nil
    }

    @discardableResult
    func startCharacterProposal(
        for mention: String,
        guidance: String
    ) async -> Bool {
        let normalizedMention = mention.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGuidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedPendingCharacterIdentityMentions.contains(where: {
            NovelCharacterIdentityResolver.normalize($0.name) ==
                NovelCharacterIdentityResolver.normalize(normalizedMention)
        }) else {
            operationErrorMessage = "这个人物身份问题已经失效。"
            return false
        }
        guard activeCharacterProposal(for: normalizedMention) == nil else {
            operationErrorMessage = "这个人物已有待确认建议。"
            return false
        }
        var userText = """
        请为正文中新出现但尚未建档的人物生成一份可确认的人物建议。

        当前称呼：\(normalizedMention)
        """
        if !normalizedGuidance.isEmpty {
            userText += "\n\n作者补充：\(normalizedGuidance)"
        }
        return await start(NovelSessionRunDraft(
            kind: .characterProposal,
            mode: .discussPlan,
            granularity: nil,
            userText: userText,
            sourceChapterVersionID: nil,
            askUserResponse: nil,
            injectionOverrides: .none,
            inputBudgetTokens: 16_000,
            contextualCharacterMention: normalizedMention
        ))
    }

}
