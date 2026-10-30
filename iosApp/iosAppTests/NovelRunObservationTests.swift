import Foundation
import XCTest
@testable import iosApp

extension NovelGenerationLifecycleTests {
    func testObserveRunAttachesWithoutRebuildingASuppressedRequestOrStartingProviderAgain() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause, .delta("继续原有运行"), .complete])]
        )
        let base = makeRequest(document: document, kind: .discussion)
        let request = NovelRunRequest(
            id: base.id, operationID: base.operationID,
            projectID: base.projectID, branchID: base.branchID,
            kind: base.kind, mode: base.mode, granularity: base.granularity,
            userText: base.userText, userMessageID: base.userMessageID,
            assistantMessageID: base.assistantMessageID, candidateID: base.candidateID,
            generationReceiptID: base.generationReceiptID, injectionReceiptID: base.injectionReceiptID,
            sourceChapterVersionID: base.sourceChapterVersionID,
            suppressRecentSessionMessages: true,
            expectedProjectRevision: base.expectedProjectRevision,
            expectedConfigRevision: base.expectedConfigRevision,
            expectedBranchHeadRevision: base.expectedBranchHeadRevision
        )
        let original = try await harness.creation.start(request)

        let observed = try await harness.creation.observeRun(
            projectID: request.projectID, runID: request.id, operationID: request.operationID
        )
        let beforeResumeRequests = await harness.adapter.requests
        XCTAssertEqual(beforeResumeRequests.count, 1, "Observation must never create another provider request.")
        await harness.adapter.resume(runID: request.id)
        let events = await capturedEvents(observed.events)
        _ = await capturedEvents(original.events)
        XCTAssertEqual(events.first, .started(request.id))
        XCTAssertTrue(events.contains { if case .completed = $0 { true } else { false } })
    }

    func testObserveRunRejectsAnUnrelatedOperationAndUnknownRun() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document, scripts: [NovelModelScript(steps: [.pause, .complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        _ = try await harness.creation.start(request)

        for (runID, operationID) in [(request.id, NovelOperationID()), (NovelRunID(), request.operationID)] {
            do {
                _ = try await harness.creation.observeRun(
                    projectID: request.projectID, runID: runID, operationID: operationID
                )
                XCTFail("Observation accepted a different run identity.")
            } catch {
                XCTAssertEqual(error as? NovelError, .runNotFound(runID))
            }
        }
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
        try await harness.creation.interruptRun(.init(
            context: .init(operationID: NovelOperationID(), expectedProjectRevision: nil,
                           expectedConfigRevision: nil, expectedBranchHeadRevision: nil),
            projectID: request.projectID,
            runID: request.id, reason: .user
        ))
    }

    func testObserveCompletedRunReplaysTerminalWithoutStartingProviderAgain() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document, scripts: [NovelModelScript(steps: [.delta("完成的讨论"), .complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        let originalEvents = await capturedEvents(try await harness.creation.start(request).events)

        let observed = try await harness.creation.observeRun(
            projectID: request.projectID, runID: request.id, operationID: request.operationID
        )
        let replayEvents = await capturedEvents(observed.events)

        XCTAssertEqual(replayEvents.first, .started(request.id))
        XCTAssertEqual(replayEvents.last, originalEvents.last)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
    }
}

@MainActor
final class NovelSessionObservationTests: NovelSessionViewModelTestCase {
    func testDetachedCompletionPrunedByFileRepositoryReloadsOnReentry() async throws {
        let directory = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NovelFileProjectRepository(
            rootDirectory: directory, automaticWorkspaceMigration: true
        )
        let harness = try await makeHarness(repository: repository, scripts: [
            NovelModelScript(steps: [.delta("离页前"), .pause, .delta("，离页后完成。"), .complete]),
        ])
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "继续讨论")
        XCTAssertTrue(started)
        let streaming = await eventually { harness.session.transientTail?.content == "离页前" }
        XCTAssertTrue(streaming)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        XCTAssertEqual(harness.workspace.projectSnapshot?.activeRuns.first { $0.id == runID }?.status, .running)

        harness.session.detachConsumer()
        await harness.adapter.resume(runID: runID)
        let persisted = await eventually {
            let document = try? await repository.loadProject(id: harness.projectID).document
            return document?.branches.first?.activeRunID == nil
                && document?.sessions.first?.messages.last?.content == "离页前，离页后完成。"
        }
        XCTAssertTrue(persisted)
        let canonical = try await repository.loadProject(id: harness.projectID).document
        XCTAssertTrue(canonical.activeRuns.isEmpty, "Exercise the workspace-native quiet-rest prune.")
        XCTAssertEqual(harness.workspace.projectSnapshot?.activeRuns.first { $0.id == runID }?.status, .running,
                       "The detached workspace still holds the stale running snapshot.")

        await harness.session.bindToCurrentSelection()

        XCTAssertNil(harness.session.refreshErrorMessage)
        XCTAssertNil(harness.session.transientTail)
        XCTAssertFalse(harness.session.isRunning)
        XCTAssertTrue(harness.session.canSend)
        XCTAssertEqual(harness.session.durableMessages.last?.content, "离页前，离页后完成。")
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1, "Reentry observes the durable result instead of restarting generation.")
    }

    func testAnswerRunReattachesWithoutReapplyingItsAskUserResponse() async throws {
        let prompt = NovelAskUserPrompt(question: "主角先保护谁？", options: ["家人", "同伴"])
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.askUser(prompt, preface: "先确定人物动机。")]),
            NovelModelScript(steps: [.delta("先保护家人"), .pause, .delta("，再展开下一幕。"), .complete]),
        ])
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "规划下一幕")
        XCTAssertTrue(started)
        let asked = await eventually {
            harness.session.canSend && harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(asked)
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)
        let answered = await harness.session.answerAskUser(promptMessageID: promptMessage.id, answer: "家人")
        XCTAssertTrue(answered)
        let streaming = await eventually { harness.session.transientTail?.content == "先保护家人" }
        XCTAssertTrue(streaming)
        let runID = try XCTUnwrap(harness.session.activeRunID)

        harness.session.detachConsumer()
        await harness.session.bindToCurrentSelection()
        XCTAssertNil(harness.session.refreshErrorMessage)
        XCTAssertEqual(harness.session.activeRunID, runID)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 2, "Reattaching must not run a third discussion request.")

        await harness.adapter.resume(runID: runID)
        let completed = await eventually {
            !harness.session.isRunning && harness.session.durableMessages.last?.content == "先保护家人，再展开下一幕。"
        }
        XCTAssertTrue(completed)
    }
}
