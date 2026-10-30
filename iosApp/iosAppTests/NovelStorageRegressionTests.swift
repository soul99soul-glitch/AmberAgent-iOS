import Foundation
import XCTest
@testable import iosApp

final class NovelStorageRegressionTests: XCTestCase {
    func testSameRevisionReplacementFailurePreservesDiskAndInventory() async throws {
        for workspaceNative in [false, true] {
            let root = try NovelTestFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let original = try NovelTestFixtures.document()
            let repository = NovelFileProjectRepository(rootDirectory: root)
            _ = try await repository.createProject(original, workspaceNative: workspaceNative)
            var imported = original
            imported.project.name = "Different imported content at the same revision"
            let failing = NovelFileProjectRepository(
                rootDirectory: root,
                failingStages: [.afterTempWrite]
            )

            await NovelXCTAssertThrowsErrorAsync(
                try await failing.replaceProject(imported, expectedRevision: original.project.revision)
            ) { error in
                guard case .repositoryFailure = error as? NovelError else {
                    return XCTFail("Expected an uninstalled replacement failure, got \(error)")
                }
            }

            let restarted = NovelFileProjectRepository(rootDirectory: root)
            let loaded = try await restarted.loadProject(id: original.project.id)
            let summaries = try await restarted.listProjects()
            XCTAssertEqual(loaded.document, original)
            XCTAssertEqual(summaries.first?.name, original.project.name)
        }
    }

    func testSameRevisionReplacementRecognizesCompleteLateInstall() async throws {
        for workspaceNative in [false, true] {
            let root = try NovelTestFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let original = try NovelTestFixtures.document()
            let repository = NovelFileProjectRepository(rootDirectory: root)
            _ = try await repository.createProject(original, workspaceNative: workspaceNative)
            var imported = original
            imported.project.name = "Installed import"
            let lateFailure = NovelFileProjectRepository(
                rootDirectory: root,
                failingStages: [.afterTempValidation]
            )

            let result = try await lateFailure.replaceProject(imported, expectedRevision: original.project.revision)
            let loaded = try await NovelFileProjectRepository(rootDirectory: root)
                .loadProject(id: original.project.id)

            XCTAssertEqual(result.document, imported)
            XCTAssertEqual(loaded.document, imported)
            XCTAssertEqual(loaded.access, .readWrite)
        }
    }

    func testLegacyRecoveryReadNeverMigratesPreviousUntilExplicitRestore() async throws {
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try NovelTestFixtures.document()
        let repository = NovelFileProjectRepository(rootDirectory: root)
        _ = try await repository.createProject(original)
        let current = try NovelReducer.apply(
            NovelTestFixtures.renameAction(document: original, name: "Current version"),
            to: original
        ).document
        _ = try await repository.commitProject(current, expectedRevision: original.project.revision)
        let package = root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(original.project.id.description, isDirectory: true)
        try Data("corrupt current".utf8).write(
            to: NovelProjectShardedStorage.layoutURL(in: package),
            options: [.atomic]
        )

        for _ in 1...2 {
            let restarted = NovelFileProjectRepository(rootDirectory: root, automaticWorkspaceMigration: true)
            let loaded = try await restarted.loadProject(id: original.project.id)
            guard case .degradedPrevious = loaded.access else {
                return XCTFail("Reading the backup must remain degraded until the author restores it.")
            }
            XCTAssertEqual(loaded.document, original)
            XCTAssertFalse(NovelWorkspaceProjectStore.isWorkspaceNative(projectDirectory: package))
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("legacy-package").path))
        }

        let restoring = NovelFileProjectRepository(rootDirectory: root, automaticWorkspaceMigration: true)
        let restored = try await restoring.restorePreviousProject(
            id: original.project.id,
            expectedDocumentSHA256: NovelProjectPackageCodec.encode(original).projectSHA256
        )
        XCTAssertEqual(restored.access, .readWrite)
        XCTAssertEqual(restored.document, original)
        XCTAssertTrue(NovelWorkspaceProjectStore.isWorkspaceNative(projectDirectory: package))
    }
}

extension NovelGenerationReducerTests {
    func testCandidateRetainsItsGranularityAcrossQuietRestAndLaterGeneration() async throws {
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try NovelTestFixtures.document()
        let continuation = makeRequest(document: original, kind: .prose, granularity: .continuation)
        let started = try begin(continuation, in: original)
        let completed = try NovelGenerationReducer.complete(
            runID: continuation.id, content: "The next passage.", in: started, now: terminalTime
        ).document
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let firstPersisted = try await repository.createProject(completed, workspaceNative: true).document
        XCTAssertTrue(firstPersisted.activeRuns.isEmpty)

        let wholeChapter = makeRequest(document: firstPersisted, kind: .prose, granularity: .wholeChapter)
        let nextStarted = try begin(wholeChapter, in: firstPersisted)
        _ = try await repository.commitProject(nextStarted, expectedRevision: firstPersisted.project.revision)
        let nextCompleted = try NovelGenerationReducer.complete(
            runID: wholeChapter.id, content: "A complete new chapter.", in: nextStarted,
            now: terminalTime.addingTimeInterval(1)
        ).document
        _ = try await repository.commitProject(nextCompleted, expectedRevision: nextStarted.project.revision)
        let reloaded = try await NovelFileProjectRepository(rootDirectory: root)
            .loadProject(id: original.project.id).document

        XCTAssertTrue(reloaded.activeRuns.isEmpty)
        XCTAssertEqual(reloaded.project.lastGenerationGranularity, .wholeChapter)
        XCTAssertEqual(reloaded.candidates.first { $0.id == continuation.candidateID }?.generationGranularity, .continuation)
        XCTAssertEqual(reloaded.candidates.first { $0.id == wholeChapter.candidateID }?.generationGranularity, .wholeChapter)
    }

    func testLegacyCandidateWithoutGranularityStillDecodes() throws {
        let original = try NovelTestFixtures.document()
        let request = makeRequest(document: original, kind: .prose, granularity: .continuation)
        let started = try begin(request, in: original)
        let completed = try NovelGenerationReducer.complete(
            runID: request.id, content: "A legacy candidate.", in: started, now: terminalTime
        ).document
        let legacy = try mutateEncodedDocument(completed) { object in
            var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            candidates[0].removeValue(forKey: "generationGranularity")
            object["candidates"] = candidates
        }

        XCTAssertNil(legacy.candidates.first?.generationGranularity)
        XCTAssertNoThrow(try NovelDocumentValidator.validate(legacy))
    }
}
