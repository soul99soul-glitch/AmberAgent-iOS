import Foundation
import XCTest
@testable import iosApp

@MainActor
final class NovelWorkspaceRetryTests: NovelSessionViewModelTestCase {
    func testRetryableGenerationFailureRemainsRetryableAfterWorkspaceReload() async throws {
        let root = try NovelTestFixtures.temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let repository = NovelFileProjectRepository(rootDirectory: root)
        _ = try await repository.createProject(document, workspaceNative: true)
        let failure = NovelModelFailure(
            code: "retryable_provider_failure",
            message: "模型暂时不可用，请重试。",
            isRetryable: true
        )
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "session-provider",
                ownerProviderID: "session-owner",
                modelID: "session-model",
                wireModelID: "session-wire",
                displayName: "Session Model",
                contextWindowTokens: 128_000
            ),
            scripts: [
                NovelModelScript(steps: [.delta("未完成的续写"), .fail(failure)]),
                NovelModelScript(steps: [.delta("重试后完成的续写。"), .complete]),
            ]
        )
        let creation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            now: { Date(timeIntervalSince1970: 1_700_800_000) }
        )
        let workspace = NovelCreationViewModel(creation: creation)
        await workspace.loadProjects(selecting: document.project.id)
        let session = NovelSessionViewModel(workspace: workspace, terminalQuietDelay: 0)
        await session.bindToCurrentSelection()
        session.mode = .writeProse
        session.granularity = .continuation
        let originalText = "保留这次的调整方向，再继续这一段。"
        let started = await session.send(text: originalText)
        XCTAssertTrue(started)
        let failed = await eventually {
            session.transientTail == nil &&
                session.durableMessages.last?.kind == .interruptedDraft
        }
        XCTAssertTrue(failed)
        let failedMessage = try XCTUnwrap(session.durableMessages.last)
        let failedRunID = try XCTUnwrap(failedMessage.runID)

        let reloaded = try await NovelFileProjectRepository(rootDirectory: root)
            .loadProject(id: document.project.id).document
        let persistedRun = try XCTUnwrap(reloaded.activeRuns.first { $0.id == failedRunID })
        XCTAssertEqual(persistedRun.status, .failed)
        XCTAssertEqual(persistedRun.terminalFailure?.isRetryable, true)
        XCTAssertEqual(persistedRun.granularity, .continuation)
        let refreshed = await session.refresh()
        XCTAssertTrue(refreshed)

        let retried = await session.retryGeneration(runID: failedRunID)
        XCTAssertTrue(retried)
        let completed = await eventually {
            session.transientTail == nil &&
                session.durableMessages.last?.content == "重试后完成的续写。"
        }
        XCTAssertTrue(completed)
        let final = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(final.sessions[0].messages.filter { $0.role == .user }.map(\.content), [
            originalText, originalText,
        ])
        let retryRun = try XCTUnwrap(final.activeRuns.last)
        XCTAssertNotEqual(retryRun.id, failedRunID)
        XCTAssertEqual(retryRun.status, .completed)
        XCTAssertEqual(retryRun.mode, .writeProse)
        XCTAssertEqual(retryRun.granularity, .continuation)
    }
}
