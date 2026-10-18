import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionViewModelTests: NovelSessionViewModelTestCase {
    func testDiscussionArchiveDistillsWithoutPersistingThenCommitsEditedDecisions() async throws {
        var document = try NovelTestFixtures.document()
        let omittedProse = String(repeating: "这段正文候选绝不能进入讨论蒸馏。", count: 80)
        document.sessions[0].messages = [
            NovelSessionMessageRecord(
                id: NovelMessageID(), sequence: 0, role: .user, mode: .discussPlan,
                kind: .userInput, content: "主角应在何时揭示身世？",
                createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                runID: nil, candidateID: nil
            ),
            NovelSessionMessageRecord(
                id: NovelMessageID(), sequence: 1, role: .assistant, mode: .discussPlan,
                kind: .discussion, content: "建议第三章末揭示。",
                createdAt: Date(timeIntervalSince1970: 1_700_000_002),
                runID: nil, candidateID: nil
            ),
            NovelSessionMessageRecord(
                id: NovelMessageID(), sequence: 2, role: .assistant, mode: .writeProse,
                kind: .proseCandidate, content: omittedProse,
                createdAt: Date(timeIntervalSince1970: 1_700_000_003),
                runID: nil, candidateID: nil
            ),
            NovelSessionMessageRecord(
                id: NovelMessageID(), sequence: 3, role: .user, mode: .discussPlan,
                kind: .userInput, content: "就定在第三章末。",
                createdAt: Date(timeIntervalSince1970: 1_700_000_004),
                runID: nil, candidateID: nil
            ),
        ]
        document.sessions[0].revision = 4
        try NovelDocumentValidator.validate(document)
        let archiveJSON = """
        {"schemaVersion":1,"decisions":[{"topic":"身世揭示","decision":"第三章末揭示。","relatedMaterialID":null}],"summary":"已确定身世揭示时点。"}
        """
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta(archiveJSON), .complete])]
        )

        let distilled = await harness.session.distillDiscussionArchive(chapterID: nil)
        let draft = try XCTUnwrap(distilled)
        XCTAssertEqual(draft.throughSequence, 3)
        XCTAssertEqual(draft.decisions.map(\.topic), ["身世揭示"])
        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertFalse(request.messages.map(\.content).joined().contains(omittedProse))

        var persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertNil(persisted.sessions[0].archiveCursor)
        XCTAssertFalse(persisted.materials.contains { $0.kind == .decisionLog })

        let rejected = await harness.session.confirmDiscussionArchive(
            draft,
            decisions: [],
            summary: draft.summary
        )
        XCTAssertFalse(rejected)
        persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertNil(persisted.sessions[0].archiveCursor)

        var edited = draft.decisions
        edited[0].decision = "第五章开场揭示。"
        let confirmed = await harness.session.confirmDiscussionArchive(
            draft,
            decisions: edited,
            summary: "确认在第五章开场揭示身世。"
        )
        XCTAssertTrue(confirmed)

        persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.sessions[0].archiveCursor, .through(sequence: 3))
        XCTAssertEqual(persisted.sessions[0].discussionArchives?.last?.summary, "确认在第五章开场揭示身世。")
        let decisionMaterial = try XCTUnwrap(
            persisted.materials.first { $0.kind == .decisionLog }
        )
        XCTAssertEqual(
            persisted.materialRevisions.first { $0.materialID == decisionMaterial.id }?.content,
            "第五章开场揭示。"
        )
    }

    func testCancellingDiscussionArchivePreparationDoesNotPublishAnError() async throws {
        var document = try NovelTestFixtures.document()
        document.sessions[0].messages = [
            NovelSessionMessageRecord(
                id: NovelMessageID(),
                sequence: 0,
                role: .user,
                mode: .discussPlan,
                kind: .userInput,
                content: "讨论这一章的关键决定。",
                createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                runID: nil,
                candidateID: nil
            ),
            NovelSessionMessageRecord(
                id: NovelMessageID(),
                sequence: 1,
                role: .assistant,
                mode: .discussPlan,
                kind: .discussion,
                content: "建议让主角在结尾公开真相。",
                createdAt: Date(timeIntervalSince1970: 1_700_000_002),
                runID: nil,
                candidateID: nil
            ),
        ]
        document.sessions[0].revision = 2
        try NovelDocumentValidator.validate(document)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )

        let preparation = Task { @MainActor in
            await harness.session.distillDiscussionArchive(chapterID: nil)
        }
        let requestStarted = await eventually {
            await harness.adapter.requests.count == 1
        }
        XCTAssertTrue(requestStarted)

        preparation.cancel()
        let draft = await preparation.value

        XCTAssertNil(draft)
        XCTAssertNil(harness.session.errorMessage)
        XCTAssertFalse(harness.session.isPerformingAction)
        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        let cancelledRunIDs = await harness.adapter.cancelledRunIDs
        XCTAssertFalse(cancelledRunIDs.isEmpty)
        XCTAssertTrue(cancelledRunIDs.allSatisfy { $0 == request.runID })
    }

    func testStartingRunProjectsUserPromptBeforeProviderConnects() async throws {
        var document = try NovelTestFixtures.document()
        document.sessions[0].messages = [
            NovelSessionMessageRecord(
                id: NovelMessageID(),
                sequence: 0,
                role: .user,
                mode: .discussPlan,
                kind: .userInput,
                content: "上一轮问题",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                runID: nil,
                candidateID: nil
            ),
            NovelSessionMessageRecord(
                id: NovelMessageID(),
                sequence: 1,
                role: .assistant,
                mode: .discussPlan,
                kind: .discussion,
                content: String(repeating: "上一轮回答仍应留在视口布局中。", count: 80),
                createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                runID: nil,
                candidateID: nil
            ),
        ]
        document.sessions[0].revision = 2
        try NovelDocumentValidator.validate(document)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])],
            usesAttachGate: true
        )
        let gate = try XCTUnwrap(harness.attachGate)
        await gate.blockNextStart()

        let sendTask = Task { @MainActor in
            await harness.session.send(text: "这一轮问题必须立即可见")
        }
        let startBlocked = await eventually {
            await gate.startIsBlocked()
        }
        XCTAssertTrue(startBlocked)

        let project = try XCTUnwrap(harness.workspace.projectSnapshot)
        let branch = try XCTUnwrap(harness.workspace.branchSnapshot)
        let listModel = try XCTUnwrap(
            harness.session.projectedListModel(project: project, branch: branch)
        )
        let rows = listModel.rows
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(rows[0].content, "上一轮问题")
        XCTAssertEqual(rows[2].content, "这一轮问题必须立即可见")
        XCTAssertEqual(rows.last?.transientPhase, .waitingForFirstToken)
        XCTAssertEqual(listModel.historicalRows.map(\.role), [.user, .assistant])
        XCTAssertEqual(listModel.activeRunRows.map(\.role), [.user, .assistant])
        let startingUserDigest = rows[2].digest

        await gate.resumeBlockedStart()
        let didStart = await sendTask.value
        XCTAssertTrue(didStart)
        let durablePromptPublished = await eventually {
            harness.session.durableMessages.contains {
                $0.content == "这一轮问题必须立即可见"
            }
        }
        XCTAssertTrue(durablePromptPublished)
        let refreshedProject = try XCTUnwrap(harness.workspace.projectSnapshot)
        let refreshedBranch = try XCTUnwrap(harness.workspace.branchSnapshot)
        let refreshedRows = try XCTUnwrap(
            harness.session.projectedListModel(project: refreshedProject, branch: refreshedBranch)
        ).rows
        XCTAssertEqual(
            refreshedRows.filter { $0.content == "这一轮问题必须立即可见" }.count,
            1
        )
        XCTAssertEqual(refreshedRows[2].digest, startingUserDigest)
        await harness.session.stop()
    }

    func testSessionInitializesFromAnAlreadyCompleteWorkspaceSelection() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let workspace = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await workspace.selectProject(document.project.id)
        XCTAssertTrue(didSelect)

        let session = NovelSessionViewModel(workspace: workspace)

        XCTAssertEqual(session.binding?.projectID, document.project.id)
        XCTAssertEqual(session.binding?.branchID, document.branches.first?.id)
        XCTAssertEqual(session.durableMessages, document.sessions.first?.messages)
        XCTAssertEqual(session.mode, .discussPlan)
        XCTAssertEqual(
            NovelComposerIntent(mode: session.mode, granularity: session.granularity),
            .discuss
        )
    }

    func testStartedRefreshDoesNotBlockFollowingRunEvents() async throws {
        let delta = "started 刷新等待时仍应收到正文"
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.delta(delta), .pause])],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockNextSnapshot()
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "继续讨论")
        XCTAssertTrue(didStart)
        let startedRefreshBlocked = await eventually {
            await gate.snapshotIsBlocked()
        }
        XCTAssertTrue(startedRefreshBlocked)

        let followingDeltaPublished = await eventually(timeout: 3) {
            harness.session.transientTail?.content == delta
        }
        XCTAssertTrue(followingDeltaPublished)

        await gate.resumeBlockedSnapshot()
        await harness.session.stop()
    }

    func testComposerIntentRemembersWriteAPassageAndDoesNotSnapBackToWholeChapter() async throws {
        let defaults = UserDefaults(suiteName: "session-composer-\(UUID().uuidString)")!
        let repository = InMemoryNovelProjectRepository()
        var document = try NovelTestFixtures.document()
        document.project.lastGenerationGranularity = .wholeChapter
        _ = try await repository.createProject(document)
        let workspace = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await workspace.selectProject(document.project.id)
        XCTAssertTrue(didSelect)

        let session = NovelSessionViewModel(
            workspace: workspace,
            composerDefaults: defaults
        )
        session.setComposerIntent(.continueProse)
        XCTAssertEqual(session.mode, .writeProse)
        XCTAssertEqual(session.granularity, .continuation)

        await session.bindToCurrentSelection()
        XCTAssertEqual(session.mode, .writeProse)
        XCTAssertEqual(session.granularity, .continuation)

        let reopened = NovelSessionViewModel(
            workspace: workspace,
            composerDefaults: defaults
        )
        XCTAssertEqual(reopened.mode, .writeProse)
        XCTAssertEqual(reopened.granularity, .continuation)
    }

    func testIgnoringIncidentalCharacterIdentityMentionClosesItDurably() async throws {
        let document = try documentWithUnresolvedCharacterMention("瘦子")
        let repository = InMemoryNovelProjectRepository()
        let harness = try await makeHarness(
            repository: repository,
            document: document,
            scripts: []
        )
        // Domain list is stage-independent; presentation list stays empty until secondary.
        XCTAssertEqual(
            harness.session.resolvedPendingCharacterIdentityMentions.map(\.name),
            ["瘦子"]
        )
        XCTAssertTrue(harness.session.pendingCharacterIdentityMentions.isEmpty)
        harness.session.advanceLoadStage(to: .steadyTranscript)
        harness.session.advanceLoadStage(to: .secondaryChrome)
        XCTAssertEqual(harness.session.pendingCharacterIdentityMentions.map(\.name), ["瘦子"])

        let ignored = await harness.session.ignoreCharacterIdentityMention("瘦子")

        XCTAssertTrue(ignored)
        XCTAssertTrue(harness.session.resolvedPendingCharacterIdentityMentions.isEmpty)
        XCTAssertTrue(harness.session.pendingCharacterIdentityMentions.isEmpty)

        let reloadedWorkspace = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await reloadedWorkspace.loadProjects(selecting: document.project.id)
        let reloadedSession = NovelSessionViewModel(workspace: reloadedWorkspace)
        await reloadedSession.bindToCurrentSelection()
        XCTAssertTrue(reloadedSession.resolvedPendingCharacterIdentityMentions.isEmpty)
    }

    func testIdentityCardRefreshesWhenSelectionTokenChangesDuringSave() async throws {
        let harness = try await makeHarness(
            document: try documentWithUnresolvedCharacterMention("瘦子"),
            scripts: [],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockNextPerform()
        let saveTask = Task { @MainActor in
            await harness.session.ignoreCharacterIdentityMention("瘦子")
        }
        let blocked = await eventually { await gate.performIsBlocked() }
        try await harness.workspace.refreshCurrentSelection(
            projectID: harness.projectID,
            refreshProjectList: false
        )
        await gate.resumeBlockedPerform()
        XCTAssertTrue(blocked)
        let saved = await saveTask.value
        XCTAssertTrue(saved)
        XCTAssertTrue(harness.session.resolvedPendingCharacterIdentityMentions.isEmpty)
    }

    func testCustomCharacterIdentityClarificationClosesItAndPersistsTheAnswer() async throws {
        let document = try documentWithUnresolvedCharacterMention("瘦子")
        let repository = InMemoryNovelProjectRepository()
        let harness = try await makeHarness(
            repository: repository,
            document: document,
            scripts: []
        )
        let clarification = "这是一次性出现的路人，不需要建立人物档案。"

        let clarified = await harness.session.clarifyCharacterIdentityMention(
            "瘦子",
            clarification: clarification
        )

        XCTAssertTrue(clarified)
        XCTAssertTrue(harness.session.resolvedPendingCharacterIdentityMentions.isEmpty)
        let persisted = try await repository.loadProject(id: document.project.id).document
        let branch = try XCTUnwrap(persisted.branches.first)
        let state = try XCTUnwrap(persisted.stateSnapshots.first(where: {
            $0.id == branch.currentStateSnapshotID
        }))
        XCTAssertTrue(state.unresolvedEntityNames.isEmpty)
        XCTAssertEqual(state.characterIdentityClarifications.map(\.mention), ["瘦子"])
        XCTAssertEqual(
            state.characterIdentityClarifications.map(\.clarification),
            [clarification]
        )

        let plan = try NovelInjectionPlanner.plan(
            document: persisted,
            request: NovelInjectionPlanningRequest(
                branchID: branch.id,
                promptKind: .discussion,
                userText: "继续讨论剧情。"
            )
        )
        XCTAssertTrue(plan.contextText.contains("瘦子: \(clarification)"))
        XCTAssertFalse(plan.contextText.contains("Unresolved entities:\n瘦子"))

        let projectedState = try NovelManualSyncChunker.projectedStateContext(
            baseState: state,
            accumulated: nil
        )
        XCTAssertTrue(projectedState.contains(clarification))
        XCTAssertTrue(projectedState.contains("\"unresolvedEntityNames\":[]"))
    }

}
