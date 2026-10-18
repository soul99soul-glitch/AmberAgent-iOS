import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionTailPresentationTests: NovelSessionViewModelTestCase {
    func testDiscussionCompletesAsOneDurableAssistantBubble() async throws {
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta("零散"),
            .replacement("完整讨论建议"),
            .complete,
        ])])
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "下一步该怎么规划？")
        XCTAssertTrue(didStart)
        let didFinish = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed &&
                harness.session.durableMessages.last?.kind == .discussion &&
                harness.session.durableMessages.last?.content == "完整讨论建议"
        }
        XCTAssertTrue(didFinish)

        XCTAssertEqual(harness.session.durableMessages.map(\.kind), [.userInput, .discussion])
        XCTAssertEqual(harness.session.durableMessages.last?.content, "完整讨论建议")
        XCTAssertNil(harness.session.durableMessages.last?.candidateID)
        XCTAssertNil(harness.session.transientTail)
        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.purpose, .discussion)
    }

    func testTerminalTailLingersUnlockedThroughQuietWindowThenRetires() async throws {
        // B' 的核心状态:完成后输入区立即解锁(terminalAwaitingRefresh 立刻清除),但
        // transient tail 在静窗内保留,避免 durable 正文接管瞬间整屏「跳一下」。旧实现
        // 「解锁」与「tail 还在」不能共存(清 tail 与解锁错时),完成瞬间会闪烁。
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .replacement("完成的讨论建议"),
            .complete,
        ])], terminalQuietDelay: 1.0)
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "下一步该怎么规划？")
        XCTAssertTrue(didStart)
        let didFinish = await eventually { !harness.session.isRunning }
        XCTAssertTrue(didFinish)

        let lingerUnlocked = await eventually {
            harness.session.canSend && harness.session.transientTail != nil
        }
        XCTAssertTrue(lingerUnlocked, "静窗内 tail 应保留,同时输入区已解锁")

        let tailID = try XCTUnwrap(harness.session.transientTail?.messageID)
        let quietWindowModel = try XCTUnwrap(harness.session.projectedListModel(
            project: try XCTUnwrap(harness.workspace.projectSnapshot),
            branch: try XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertEqual(
            quietWindowModel.rows.first(where: { $0.id == tailID })?.transientPhase,
            .terminalAwaitingRefresh,
            "Durable refresh must not bypass the quiet window and replace the visible tail immediately."
        )

        // 静窗过后 tail 退役清空。
        let didRetire = await eventually(timeout: 3) { harness.session.transientTail == nil }
        XCTAssertTrue(didRetire, "静窗过后终态 tail 应退役清空")
    }

    func testNewRunWithinQuietWindowCancelsPreviousTailRetirement() async throws {
        // 静窗内开新 run:installTail 应取消上一场的退役任务,新 run 的 tail 不被上一场
        // 退役任务误清,且整条链路能正确跑到第二场完成。
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.replacement("第一场完成"), .complete]),
            NovelModelScript(steps: [.replacement("第二场完成"), .complete]),
        ], terminalQuietDelay: 0.4)
        harness.session.mode = .discussPlan

        _ = await harness.session.send(text: "第一场")
        let firstDone = await eventually { !harness.session.isRunning }
        XCTAssertTrue(firstDone)

        // 静窗内输入区已解锁,可立即开第二场。
        let secondStarted = await eventually { harness.session.canSend }
        XCTAssertTrue(secondStarted, "静窗内输入区应解锁,允许立即开新 run")
        // 判别点:B' 延迟退役下,解锁时第一场的 tail 仍在静窗里保留(unlocked+tail 共存);
        // 旧「完成即清空」实现解锁时 tail 已被清空,此断言会红。
        XCTAssertNotNil(harness.session.transientTail, "第一场 tail 应在静窗内保留,而非立即退役")
        _ = await harness.session.send(text: "第二场")
        let secondDone = await eventually(timeout: 3) { !harness.session.isRunning }
        XCTAssertTrue(secondDone)

        // 第二场结果正确落盘;tail 最终由第二场自己的静窗退役,而非被第一场任务提前清掉。
        let retired = await eventually(timeout: 3) { harness.session.transientTail == nil }
        XCTAssertTrue(retired)
        XCTAssertEqual(harness.session.durableMessages.last?.content, "第二场完成")
    }

    func testFailedStartWithinQuietWindowRestoresPreviousTailRetirement() async throws {
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            scripts: [NovelModelScript(steps: [.replacement("第一场完成"), .complete])],
            terminalQuietDelay: 0.2
        )
        harness.session.mode = .discussPlan

        let firstStarted = await harness.session.send(text: "第一场")
        XCTAssertTrue(firstStarted)
        let firstFinished = await eventually {
            !harness.session.isRunning && harness.session.canSend
        }
        XCTAssertTrue(firstFinished)
        let firstTailID = try XCTUnwrap(harness.session.transientTail?.messageID)

        await repository.failNextCommits(1)
        let secondStarted = await harness.session.send(text: "启动会失败的第二场")
        XCTAssertFalse(secondStarted)
        XCTAssertEqual(harness.session.transientTail?.messageID, firstTailID)

        let retired = await eventually(timeout: 2) { harness.session.transientTail == nil }
        XCTAssertTrue(
            retired,
            "Restoring the old tail must also restore its cancelled quiet-window retirement task."
        )
    }

    func testAskUserAnswerStartsTheNextDiscussionTurn() async throws {
        let prompt = NovelAskUserPrompt(
            question: "他此刻更害怕失去谁？",
            options: ["家人", "同伴"]
        )
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.askUser(prompt, preface: "先确认人物动机。")]),
            NovelModelScript(steps: [.replacement("那就先强化他保护家人的选择。"), .complete]),
        ])
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "帮我梳理人物动机")
        XCTAssertTrue(didStart)
        let didAsk = await eventually {
            !harness.session.isRunning && harness.session.canSend &&
                harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(didAsk)
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)
        XCTAssertEqual(promptMessage.interaction, .askUser(prompt))

        let didAnswer = await harness.session.answerAskUser(
            promptMessageID: promptMessage.id,
            answer: "家人"
        )
        XCTAssertTrue(didAnswer, harness.session.operationErrorMessage ?? "No answer error was reported.")
        let didFinish = await eventually {
            !harness.session.isRunning && harness.session.durableMessages.count == 4
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.session.durableMessages.count, 4)
        let answerMessage = try XCTUnwrap(harness.session.durableMessages.dropFirst(2).first)
        let nextAssistantMessage = try XCTUnwrap(harness.session.durableMessages.dropFirst(3).first)
        XCTAssertEqual(answerMessage.content, "家人")
        XCTAssertEqual(nextAssistantMessage.content, "那就先强化他保护家人的选择。")
    }

    func testFailedAskUserAnswerRestoresCachedCard() async throws {
        let prompt = NovelAskUserPrompt(question: "下一步去哪？", options: ["城门", "码头"])
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            scripts: [NovelModelScript(steps: [.askUser(prompt, preface: "先确定方向。")])]
        )
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "继续规划")
        XCTAssertTrue(started)
        let didAsk = await eventually {
            !harness.session.isRunning && harness.session.canSend &&
                harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(didAsk)
        let promptID = try XCTUnwrap(harness.session.durableMessages.last?.id)

        func cardResponse() throws -> NovelAskUserResponse? {
            let list = try XCTUnwrap(harness.session.projectedListModel(
                project: XCTUnwrap(harness.workspace.projectSnapshot),
                branch: XCTUnwrap(harness.workspace.branchSnapshot)
            ))
            return list.rows.first(where: { $0.id == promptID })?.askUser?.response
        }
        XCTAssertNil(try cardResponse()) // Populate the projection cache before the answer.

        await repository.blockNextCommit()
        await repository.failNextCommits(1)
        let answerTask = Task { @MainActor in
            await harness.session.answerAskUser(promptMessageID: promptID, answer: "城门")
        }
        let commitBlocked = await eventually { await repository.commitIsBlocked() }
        let optimisticAnswer = try? cardResponse()?.answer
        await repository.resumeBlockedCommit()
        XCTAssertTrue(commitBlocked)
        XCTAssertEqual(optimisticAnswer, "城门")

        let answered = await answerTask.value
        XCTAssertFalse(answered)
        XCTAssertNil(harness.session.answeringAskUserMessageID)
        XCTAssertNil(try cardResponse(), "失败后已缓存的已回答投影必须撤回。")
    }

    func testGhostwritePlanApprovalPersistsPlanAndStartsSelectedBatch() async throws {
        try await assertGhostwritePlanApprovalPersistsAndStarts(initialMode: .cocreation, proposedArc: [])
    }

    func testGhostwritePlanApprovalInGhostwriteModeCanSupplyMissingPlan() async throws {
        try await assertGhostwritePlanApprovalPersistsAndStarts(initialMode: .ghostwrite, proposedArc: [])
    }

    func testGhostwritePlanApprovalRecordsAnswerWithFinalArcSave() async throws {
        try await assertGhostwritePlanApprovalPersistsAndStarts(
            initialMode: .ghostwrite, proposedArc: ["按批准计划推进下一章"]
        )
    }

    private func assertGhostwritePlanApprovalPersistsAndStarts(
        initialMode: NovelCollaborationMode,
        proposedArc: [String]
    ) async throws {
        var document = try NovelTestFixtures.document()
        for (kind, title, content) in [
            (NovelMaterialKind.masterOutline, "总纲", "主角必须夺回信物。"),
            (.character, "林晚", "冷静的调查员。"),
            (.writingRequirements, "写作要求", "第三人称，节奏紧凑。"),
        ] {
            document = try NovelReducer.apply(.reviseMaterial(NovelReviseMaterialCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id,
                materialID: NovelMaterialID(),
                revisionID: NovelMaterialRevisionID(),
                kind: kind,
                title: title,
                content: content,
                tags: [],
                injectionMode: .always
            )), to: document).document
        }
        let preservedArc = ["保留已有的后续方向"]
        document = try NovelReducer.apply(.upsertUpcomingArc(NovelUpsertUpcomingArcCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            beats: preservedArc
        )), to: document).document
        if initialMode == .ghostwrite {
            document = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id, branchID: document.branches[0].id, mode: initialMode
            )), to: document).document
        }
        let branch = document.branches[0]
        let proposal = NovelGhostwritePlanProposal(
            projectID: document.project.id,
            branchID: branch.id,
            planID: NovelChapterPlanID(),
            expectedHeadRevision: branch.headRevision,
            expectedWorkingRevision: branch.workingRevision,
            expectedCurrentPlanDigest: nil,
            outlinePlacement: "第 1 章 · 开场",
            goalAndConflict: "林晚潜入档案馆夺回证据",
            mustHappen: ["林晚拿到被篡改的卷宗"],
            mustNotHappen: ["幕后主使立刻现身"],
            endingHook: "卷宗上出现父亲的签名",
            visibleFacts: ["林晚只知道卷宗被替换过"],
            upcomingArc: proposedArc,
            suggestedChapterCount: 3,
            reason: "承接刚才确认的父女矛盾"
        )
        let prompt = NovelAskUserPrompt(
            question: "按这份剧情计划开始代笔？你可以先选择这批写几章。",
            options: NovelGhostwritePlanApproval.options,
            ghostwritePlan: proposal
        )
        let harness = try await makeHarness(
            document: document,
            scripts: [
                NovelModelScript(steps: [.askUser(prompt, preface: "剧情方向已经收拢。")]),
                NovelModelScript(steps: [.pause]),
            ]
        )
        harness.session.mode = .discussPlan

        let discussionStarted = await harness.session.send(text: "就按刚才讨论的方向写")
        XCTAssertTrue(discussionStarted)
        let didAsk = await eventually {
            !harness.session.isRunning &&
                harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(didAsk)
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)

        let approved = await harness.session.answerAskUser(
            promptMessageID: promptMessage.id,
            answer: NovelGhostwritePlanApproval.approvedAnswer(chapterCount: 4)
        )
        XCTAssertTrue(approved, harness.session.operationErrorMessage ?? "审批后未能启动代笔")
        let started = await eventually {
            harness.session.ghostwriteProgress?.targetChapterCount == 4 &&
                harness.session.isGhostwriting
        }
        XCTAssertTrue(started)
        XCTAssertEqual(harness.workspace.projectSnapshot?.project.collaborationMode, .ghostwrite)
        XCTAssertEqual(
            harness.workspace.projectSnapshot?.confirmedChapterPlan(for: branch.id)?.goalAndConflict,
            proposal.goalAndConflict
        )
        XCTAssertEqual(
            harness.workspace.projectSnapshot?.upcomingArc(for: branch.id)?.beats,
            proposedArc.isEmpty ? preservedArc : proposedArc
        )
        let saved = try await harness.repository.loadProject(id: harness.projectID).document
        let response = NovelAskUserResponse(
            promptMessageID: promptMessage.id,
            answer: NovelGhostwritePlanApproval.approvedAnswer(chapterCount: 4)
        )
        XCTAssertEqual(saved.sessions[0].messages.filter { $0.interaction == .askUserAnswer(response) }.count, 1)
        harness.session.pauseGhostwrite()
    }

    func testStaleManuscriptDeleteApprovalDoesNotDeleteChapter() async throws {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let prompt = NovelAskUserPrompt(
            question: "将第 1 章《第一章》从正文目录删除？",
            options: NovelManuscriptDeleteApproval.options,
            manuscriptDelete: NovelManuscriptDeleteProposal(
                chapterIDs: [fixture.chapterID],
                chapterTitles: ["第一章"],
                chapterOrdinals: [1],
                expectedHeadRevision: branch.headRevision,
                expectedWorkingRevision: branch.workingRevision,
                reason: nil
            )
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [.askUser(prompt, preface: "请确认是否抽掉这一章。")]),
                NovelModelScript(steps: [.delta(validRebuildJSON), .complete]),
            ]
        )
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "删掉第一章")
        XCTAssertTrue(didStart)
        let didAsk = await eventually {
            !harness.session.isRunning &&
                harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(didAsk)
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)

        let saved = await harness.workspace.saveManualRewrite(
            chapterID: fixture.chapterID,
            title: "第一章",
            content: "Mara opened the archive."
        )
        XCTAssertTrue(saved)

        let didAnswer = await harness.session.answerAskUser(
            promptMessageID: promptMessage.id,
            answer: NovelManuscriptDeleteApproval.approveOption
        )
        XCTAssertFalse(didAnswer)
        XCTAssertEqual(harness.session.operationErrorMessage, "当前分支已经变化，请重新发起删除。")
        XCTAssertTrue(
            harness.workspace.branchSnapshot?.branch.workingChapterSelections.contains {
                $0.chapterID == fixture.chapterID
            } == true
        )
    }

    func testAskUserAppearsOnTransientTailBeforeQuietWindowRetire() async throws {
        let prompt = NovelAskUserPrompt(
            question: "他此刻更害怕失去谁？",
            options: ["家人", "同伴"]
        )
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.askUser(prompt, preface: "先确认人物动机。")])],
            terminalQuietDelay: 1.0
        )
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "帮我梳理人物动机")
        XCTAssertTrue(didStart)
        let didAsk = await eventually {
            harness.session.transientTail?.askUser?.prompt == prompt
        }
        XCTAssertTrue(didAsk, "审批卡必须挂在直播尾上，不能等 tail 退役才从 durable 露出来。")
        XCTAssertEqual(harness.session.transientTail?.content, "先确认人物动机。")
        XCTAssertNotNil(harness.session.transientTail)

        let list = try XCTUnwrap(harness.session.projectedListModel(
            project: try XCTUnwrap(harness.workspace.projectSnapshot),
            branch: try XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertEqual(list.rows.last?.askUser?.prompt, prompt)
        XCTAssertEqual(list.rows.last?.content, "先确认人物动机。")
        XCTAssertEqual(list.rows.last?.transientPhase, .terminalAwaitingRefresh)
    }

    func testRetryAfterFailedAskUserAnswerDoesNotReplayAnswerInteraction() async throws {
        let prompt = NovelAskUserPrompt(
            question: "目录里哪几章要改？",
            options: ["5-10", "全部"]
        )
        let transportFailure = NovelModelFailure(
            code: "discussion_provider_failed",
            message: #"Exception in http request: Error Domain=NSURLErrorDomain Code=-1005 "网络连接已中断。""#,
            isRetryable: true
        )
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.askUser(prompt, preface: "先确认改名范围。")]),
            NovelModelScript(steps: [.fail(transportFailure)]),
            NovelModelScript(steps: [.replacement("按你点的那几章重排标题。"), .complete]),
        ])
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "章节标题有问题")
        XCTAssertTrue(didStart)
        let didAsk = await eventually {
            !harness.session.isRunning && harness.session.canSend &&
                harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(didAsk)
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)

        let didAnswer = await harness.session.answerAskUser(
            promptMessageID: promptMessage.id,
            answer: "5、6、8、10、15、16"
        )
        XCTAssertTrue(didAnswer, harness.session.operationErrorMessage ?? "No answer error was reported.")
        let failed = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed &&
                harness.session.canSend
        }
        XCTAssertTrue(
            failed,
            "Discussion retry was not ready: busy=\(harness.session.isBusy), running=\(harness.session.isRunning), error=\(harness.session.errorMessage ?? "none")"
        )
        let failedRunID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)
        let failedUser = try XCTUnwrap(
            harness.workspace.branchSnapshot?.session.messages.first(where: {
                $0.runID == failedRunID && $0.role == .user
            })
        )
        guard case .some(.askUserAnswer) = failedUser.interaction else {
            return XCTFail("Failed answer turn must keep the durable askUserAnswer interaction.")
        }

        // Bubble「重新生成」must not replay askUserResponse (already answered).
        // It should re-send the same text as a normal discussion turn.
        let retried = await harness.session.retryGeneration(runID: failedRunID)
        XCTAssertTrue(
            retried,
            "retryGeneration failed: \(harness.session.operationErrorMessage ?? "nil")"
        )
        let completed = await eventually {
            !harness.session.isRunning &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed &&
                harness.workspace.projectSnapshot?.activeRuns.last?.id != failedRunID
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(
            harness.workspace.branchSnapshot?.session.messages.last?.content,
            "按你点的那几章重排标题。"
        )
        XCTAssertNil(harness.session.operationErrorMessage)
        let userInputs = harness.workspace.branchSnapshot?.session.messages
            .filter { $0.role == .user }
            .map(\.content) ?? []
        XCTAssertEqual(userInputs, ["章节标题有问题", "5、6、8、10、15、16", "5、6、8、10、15、16"])
    }

    func testAskUserAnswerStartsTheNextQuickStartTurn() async throws {
        let prompt = NovelAskUserPrompt(
            question: "这座城市最核心的代价是什么？",
            options: ["失去记忆", "失去时间"]
        )
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [
                NovelModelScript(steps: [.askUser(prompt, preface: "先确定世界规则。")]),
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
            ],
            usesSnapshotGate: true
        )

        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let firstRunID = try XCTUnwrap(startedRunID)
        await harness.session.bindToCurrentSelection()
        let firstRunCompleted = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.first(where: {
                $0.id == firstRunID
            })?.status == .completed && {
                if case .awaitingUser = harness.workspace.quickStartStatus { return true }
                return false
            }()
        }
        XCTAssertTrue(firstRunCompleted)
        await harness.session.bindToCurrentSelection()
        let didAsk = !harness.session.isRunning
        XCTAssertTrue(
            didAsk,
            "run=\(String(describing: harness.workspace.projectSnapshot?.activeRuns.first(where: { $0.id == firstRunID })?.status)) isRunning=\(harness.session.isRunning) tailPhase=\(String(describing: harness.session.transientTail?.phase)) startingRun=\(String(describing: harness.workspace.quickStartStartingRun?.id)) workspaceError=\(String(describing: harness.workspace.errorMessage))"
        )
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)
        XCTAssertEqual(promptMessage.interaction, .askUser(prompt))
        XCTAssertEqual(
            harness.workspace.quickStartStatus,
            .awaitingUser(promptMessageID: promptMessage.id)
        )

        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockNextBindingRestore()
        let answerTask = Task { @MainActor in
            await harness.session.answerAskUser(promptMessageID: promptMessage.id, answer: "失去记忆")
        }
        let bindingBlocked = await eventually { await gate.bindingRestoreIsBlocked() }
        XCTAssertTrue(bindingBlocked)
        let completedBeforeBindingReturned = await eventually {
            harness.workspace.projectSnapshot?.settingProposals.count == 4 &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed &&
                harness.workspace.quickStartStatus == .idle
        }
        XCTAssertTrue(completedBeforeBindingReturned)
        await gate.resumeBlockedBindingRestore()
        let didAnswer = await answerTask.value
        XCTAssertTrue(didAnswer)
        let proposalsCompleted = await eventually {
            harness.workspace.projectSnapshot?.settingProposals.count == 4 &&
                !harness.session.isRunning && harness.session.canSend
        }
        XCTAssertTrue(proposalsCompleted)
        await harness.session.bindToCurrentSelection()
        let didFinish = !harness.session.isRunning
        XCTAssertTrue(
            didFinish,
            "proposalCount=\(harness.workspace.projectSnapshot?.settingProposals.count ?? -1) isRunning=\(harness.session.isRunning) tailPhase=\(String(describing: harness.session.transientTail?.phase)) startingRun=\(String(describing: harness.workspace.quickStartStartingRun?.id)) workspaceError=\(String(describing: harness.workspace.errorMessage))"
        )
        XCTAssertEqual(harness.session.durableMessages[2].content, "失去记忆")
    }

    func testSuspendedTailPresentationHoldsPublishesThenCatchesUpOnResume() async throws {
        let longBody = String(repeating: "长章正文。", count: 2_000)
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta(longBody),
            .pause,
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "生成这一整章")
        XCTAssertTrue(didStart)
        let sawPacedPrefix = await eventually {
            guard let content = harness.session.transientTail?.content else { return false }
            return !content.isEmpty && content.count < longBody.count / 2
        }
        XCTAssertTrue(sawPacedPrefix)

        harness.session.setTailPresentationSuspended(true)
        let frozen = try XCTUnwrap(harness.session.transientTail?.content)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.session.transientTail?.content, frozen)

        harness.session.setTailPresentationSuspended(false)
        let resumed = try XCTUnwrap(harness.session.transientTail?.content)
        XCTAssertGreaterThan(resumed.count, frozen.count)
        XCTAssertTrue(longBody.hasPrefix(resumed))
        let caughtUp = await eventually(timeout: 20) {
            harness.session.transientTail?.content == longBody
        }
        XCTAssertTrue(caughtUp)

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        let didFinish = await eventually(timeout: 20) { !harness.session.isRunning }
        XCTAssertTrue(didFinish)
    }

    func testWholeChapterUsesOneMonotonicTransientTailThenPersistsCandidate() async throws {
        let longBody = String(repeating: "长章正文。", count: 2_000)
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta(longBody),
            .pause,
            .delta("结尾。"),
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "生成这一整章")
        XCTAssertTrue(didStart)
        // Presentation is paced: a ~10k-char provider burst drains over many 48ms ticks.
        // First prove the tail is monotonic and mid-drain (prefix only), then wait for catch-up.
        let sawPacedPrefix = await eventually {
            guard let content = harness.session.transientTail?.content else { return false }
            return !content.isEmpty
                && content.count < longBody.count
                && longBody.hasPrefix(content)
        }
        XCTAssertTrue(
            sawPacedPrefix,
            "Long-chapter burst must publish a paced prefix before the full body."
        )
        let sawLongTail = await eventually(timeout: 20) {
            harness.session.transientTail?.content == longBody
        }
        XCTAssertTrue(sawLongTail)
        XCTAssertFalse(harness.workspace.canMutate)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let firstRevision = try XCTUnwrap(harness.session.transientTail?.renderRevision)
        XCTAssertEqual(harness.session.durableMessages.count, 1)
        XCTAssertEqual(harness.session.transientTail?.kind, .proseCandidate)
        // Multi-line burst must take more than one paced publication to fully reveal.
        XCTAssertGreaterThan(
            firstRevision,
            1,
            "Long-chapter backlog should surface through multiple presentation ticks."
        )

        await harness.adapter.resume(runID: runID)
        let expectedFinal = longBody + "结尾。"
        let didFinish = await eventually(timeout: 20) {
            !harness.session.isRunning
                && harness.session.transientTail == nil
                && harness.session.availableProseCandidates.first?.content == expectedFinal
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.session.availableProseCandidates.first?.content, expectedFinal)
        XCTAssertNil(harness.session.transientTail)
        XCTAssertTrue(harness.workspace.canMutate)
        XCTAssertGreaterThan(firstRevision, 0)
        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.purpose, .prose)
        // 2026-07-25 契约变更(用户明确裁决):四类生成任务不再人为设置输出上限。
        // 原断言锁的是整章 8_192,现改为断言「不设限」——人为上限会被推理模型的
        // 思考 token 吃掉并触发假失败(见 NovelGenerationLifecycle.modelParameters 注释)。
        XCTAssertNil(request.parameters.maxOutputTokens)
    }

    func testWholeChapterBurstCoalescesUIPublicationsWithoutChangingDurableFinalText() async throws {
        let deltaCount = 240
        let fragment = "雾"
        let expected = String(repeating: fragment, count: deltaCount)
        let harness = try await makeHarness(scripts: [NovelModelScript(
            steps: Array(repeating: .delta(fragment), count: deltaCount) + [.pause, .complete]
        )])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "生成一段连续的雾景")
        XCTAssertTrue(didStart)
        let caughtUp = await eventually {
            harness.session.transientTail?.content == expected
        }
        XCTAssertTrue(caughtUp)
        let presentationRevision = try XCTUnwrap(harness.session.transientTail?.renderRevision)
        XCTAssertLessThan(
            presentationRevision,
            UInt64(deltaCount / 2),
            "Provider chunk count must not directly determine SwiftUI publication count."
        )

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        // isRunning 在终态 presentation(terminalAwaitingRefresh 置位)即转假,早于 durable
        // 刷新落盘;只等 !isRunning 会撞上「run 已结束但 assistant 消息尚未落盘」的竞态
        // (此刻 durableMessages.last 暂时还是用户那条)。等到 durable 末条真正落盘再断言——
        // 与本文件 prose 用例的 durable 等待一致,放宽容忍窗口但不放宽断言本身。
        let didFinish = await eventually(timeout: 5) {
            !harness.session.isRunning && harness.session.durableMessages.last?.content == expected
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.session.durableMessages.last?.content, expected)
    }

    func testReasoningPresentsOnTailWithoutEnteringDurableManuscript() async throws {
        let reasoning = "先想清楚人物动机。"
        let prose = "巷口的雨停了。"
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .reasoningDelta(reasoning),
            .pause,
            .delta(prose),
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "写一段")
        XCTAssertTrue(didStart)
        let sawReasoning = await eventually {
            harness.session.transientTail?.reasoningContent == reasoning &&
                harness.session.transientTail?.isReasoningLive == true
        }
        XCTAssertTrue(sawReasoning, "Thinking must surface on the transient tail.")
        XCTAssertEqual(harness.session.transientTail?.content ?? "", "")

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        let didFinish = await eventually(timeout: 5) {
            !harness.session.isRunning &&
                harness.session.durableMessages.last?.content == prose
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.session.availableProseCandidates.first?.content, prose)
        XCTAssertFalse(
            harness.session.availableProseCandidates.first?.content.contains(reasoning) ?? true
        )
        XCTAssertFalse(
            harness.session.durableMessages.contains { $0.content.contains(reasoning) }
        )
    }

    func testReasoningDoesNotStayLiveAfterVisibleTextHasStarted() async throws {
        let firstThought = "先想清楚人物动机。"
        let prose = "巷口的雨停了。"
        let lateThought = "正文已经写完后的补充思考。"
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .reasoningDelta(firstThought),
            .pause,
            .delta(prose),
            .pause,
            .reasoningDelta(lateThought),
            .pause,
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "写一段")
        XCTAssertTrue(didStart)
        let sawLiveThought = await eventually {
            harness.session.transientTail?.reasoningContent == firstThought &&
                harness.session.transientTail?.isReasoningLive == true
        }
        XCTAssertTrue(sawLiveThought)

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        let sawBody = await eventually {
            harness.session.transientTail?.content == prose &&
                harness.session.transientTail?.isReasoningLive == false
        }
        XCTAssertTrue(sawBody, "First visible text must close the live thinking state.")

        await harness.adapter.resume(runID: runID)
        let absorbedLateThought = await eventually {
            harness.session.transientTail?.reasoningContent.contains(lateThought) == true
        }
        XCTAssertTrue(absorbedLateThought)
        XCTAssertEqual(harness.session.transientTail?.isReasoningLive, false)
        XCTAssertEqual(harness.session.transientTail?.content, prose)

        await harness.adapter.resume(runID: runID)
        let didFinish = await eventually(timeout: 5) {
            !harness.session.isRunning &&
                harness.session.durableMessages.last?.content == prose
        }
        XCTAssertTrue(didFinish)
    }

    func testTerminalBurstDrainsVisibleBacklogAfterGenerationControlCloses() async throws {
        let target = String(repeating: "终", count: 720)
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta(target),
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "生成一段突发正文")
        XCTAssertTrue(didStart)
        let durableCompleted = await eventually(timeout: 3) {
            let document = try? await harness.repository.loadProject(id: harness.projectID).document
            return document?.activeRuns.first?.status == .completed
        }
        XCTAssertTrue(durableCompleted)

        // Lifecycle 已经持久化终态后，UI 仍应按 48ms 节拍追平剩余正文；旧实现会在
        // terminal 回调里取消节拍任务并直接发布 720 字全文，稳定落入这里的反断言。
        try? await Task.sleep(nanoseconds: 120_000_000)
        let visibleCount = harness.session.transientTail?.content.count ?? target.count
        XCTAssertFalse(harness.session.isRunning, "模型终态到达后必须立即关闭生成控制 owner。")
        XCTAssertFalse(harness.session.canStop, "仅剩 UI 排空时不能继续暴露 Stop。")
        XCTAssertFalse(harness.session.canSend, "可见积压排空并刷新 durable 前不能开始下一轮。")
        XCTAssertTrue(harness.session.isBusy, "终态排空与 durable 接管前必须继续锁住资料操作。")
        XCTAssertGreaterThan(visibleCount, 0)
        XCTAssertLessThan(
            visibleCount,
            target.count,
            "终态不能绕过 pacer 把全部积压正文一次交给布局。"
        )

        await harness.session.stop()
        let visibleAfterStop = harness.session.transientTail?.content ?? target
        XCTAssertTrue(target.hasPrefix(visibleAfterStop))
        XCTAssertLessThan(
            visibleAfterStop.count,
            target.count,
            "终态排空期间的过期 Stop 不能清空 tail 后用 durable 全文瞬时接管。"
        )

        let didFinish = await eventually(timeout: 5) {
            guard harness.session.durableMessages.last?.content == target else { return false }
            return harness.session.transientTail == nil ||
                harness.session.transientTail?.content == target
        }
        XCTAssertTrue(didFinish)
    }

    func testFencedTerminalProseContinuesFromVisiblePrefixInsteadOfSnapping() async throws {
        let target = String(repeating: "围城旧雨。", count: 120)
        let fencedTarget = "```markdown\n\(target)\n```"
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta(fencedTarget),
            .pause,
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "生成带围栏的正文")
        XCTAssertTrue(didStart)
        // Presentation buffer strips the spurious fence so pacer and bubble share
        // one string; visible text is a paced prefix of the manuscript body.
        let sawPacedBody = await eventually {
            guard let content = harness.session.transientTail?.content else { return false }
            return !content.hasPrefix("```") &&
                target.hasPrefix(content) &&
                !content.isEmpty &&
                content.count < target.count
        }
        XCTAssertTrue(sawPacedBody, "Fenced model output must present as paced bare manuscript.")

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        let durableCompleted = await eventually(timeout: 3) {
            let document = try? await harness.repository.loadProject(id: harness.projectID).document
            return document?.activeRuns.first?.status == .completed
        }
        XCTAssertTrue(durableCompleted)

        try? await Task.sleep(nanoseconds: 120_000_000)
        let visibleContent = harness.session.transientTail?.content ?? target
        XCTAssertTrue(target.hasPrefix(visibleContent))
        XCTAssertGreaterThan(visibleContent.count, 0)
        XCTAssertLessThan(
            visibleContent.count,
            target.count,
            "Terminal fence normalize must continue pacing, not snap the whole chapter."
        )

        let didFinish = await eventually(timeout: 5) {
            guard harness.session.durableMessages.last?.content == target else { return false }
            return harness.session.transientTail == nil ||
                harness.session.transientTail?.content == target
        }
        XCTAssertTrue(didFinish)
    }

    func testStreamingTailRevisionReusesDurableProjection() async throws {
        let longBody = String(repeating: "长章投影。", count: 2_000)
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta(longBody),
            .pause,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "验证投影缓存")
        XCTAssertTrue(didStart)
        let sawFirstPacedFrame = await eventually {
            guard let tail = harness.session.transientTail else { return false }
            return !tail.content.isEmpty && tail.content.count < longBody.count
        }
        XCTAssertTrue(sawFirstPacedFrame)

        let project = try XCTUnwrap(harness.workspace.projectSnapshot)
        let branch = try XCTUnwrap(harness.workspace.branchSnapshot)
        let firstRevision = try XCTUnwrap(harness.session.transientTail?.renderRevision)
        _ = try XCTUnwrap(harness.session.projectedListModel(project: project, branch: branch))
        let fullBuildsAfterFirstFrame = harness.session.fullProjectionBuildCountForTesting

        let advanced = await eventually {
            (harness.session.transientTail?.renderRevision ?? 0) > firstRevision
        }
        XCTAssertTrue(advanced)
        let updated = try XCTUnwrap(
            harness.session.projectedListModel(project: project, branch: branch)
        )

        XCTAssertEqual(
            harness.session.fullProjectionBuildCountForTesting,
            fullBuildsAfterFirstFrame,
            "A content-only tail revision must update one row without rebuilding every durable row."
        )
        XCTAssertEqual(updated.rows.last?.content, harness.session.transientTail?.content)
        await harness.session.stop()
    }

    func testSendingBlocksCachedDurableActionsBeforeStartedRefresh() async throws {
        var document = try documentWithChapter().document
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        let content = "Mara crossed the quiet hall."
        document.sessions[0].messages = [NovelSessionMessageRecord(
            id: messageID,
            sequence: 0,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: content,
            createdAt: document.project.updatedAt,
            runID: nil,
            candidateID: candidateID
        )]
        document.sessions[0].revision = 1
        document.candidates.append(NovelCandidateRecord(
            id: candidateID,
            kind: .prose,
            branchID: document.branches[0].id,
            sessionID: document.sessions[0].id,
            sourceMessageID: messageID,
            baseCheckpointID: document.branches[0].headCheckpointID,
            baseHeadRevision: document.branches[0].headRevision,
            status: .available,
            content: content,
            sourceChapterVersionID: nil,
            collectedCheckpointID: nil,
            createdAt: document.project.updatedAt
        ))
        try NovelDocumentValidator.validate(document)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        let before = harness.session.projectedListModel(
            project: try XCTUnwrap(harness.workspace.projectSnapshot),
            branch: try XCTUnwrap(harness.workspace.branchSnapshot)
        )
        XCTAssertNil(before?.rows.flatMap(\.actions).first(where: {
            $0.action == .collectProse(candidateID)
        })?.blocker)

        await gate.blockNextSnapshot()
        harness.session.mode = .discussPlan
        let sent = await harness.session.send(text: "继续讨论")
        let refreshBlocked = await eventually { await gate.snapshotIsBlocked() }
        let project = harness.workspace.projectSnapshot
        let branch = harness.workspace.branchSnapshot
        let tail = harness.session.transientTail
        let cached = project.flatMap { project in
            branch.flatMap { branch in
                harness.session.projectedListModel(project: project, branch: branch)
            }
        }
        let full = project.flatMap { project in
            branch.map { branch in
                NovelSessionPresentation.project(NovelSessionProjectionInput(
                    project: project,
                    branch: branch,
                    transientTail: tail
                ))
            }
        }
        await gate.resumeBlockedSnapshot()

        XCTAssertTrue(sent)
        XCTAssertTrue(refreshBlocked)
        XCTAssertNotNil(tail)
        XCTAssertEqual(cached, full)
        XCTAssertEqual(cached?.rows.flatMap(\.actions).first(where: {
            $0.action == .collectProse(candidateID)
        })?.blocker, .generationRunning)
        await harness.session.stop()
    }

    func testBufferedReplacementSupersedesUnpublishedDeltasAndKeepsFollowingText() async throws {
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta("应被替换"),
            .replacement("最终前缀"),
            .delta("与结尾"),
            .pause,
            .complete,
        ])])
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "测试替换式输出")
        XCTAssertTrue(didStart)
        let sawReplacement = await eventually {
            harness.session.transientTail?.content == "最终前缀与结尾"
        }
        XCTAssertTrue(sawReplacement)

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        let didFinish = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.id == runID &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed &&
                harness.session.durableMessages.last?.content == "最终前缀与结尾"
        }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(harness.session.durableMessages.last?.content, "最终前缀与结尾")
    }

}
