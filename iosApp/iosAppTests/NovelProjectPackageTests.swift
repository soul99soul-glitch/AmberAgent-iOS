import Foundation
import XCTest
@testable import iosApp

final class NovelProjectPackageTests: NovelPolishTestCase {
    func testFileRepositoryImportsCompletedPackageAndWorkspaceHistory() async throws {
        let packageDocument = try completedHistoricalDocument()
        let workspaceDocument = try NovelWorkspaceImporter.makeDocument(
            from: NovelWorkspaceBackup.export(makeNovelWorkspaceBackupFixture())
        )
        for document in [packageDocument, workspaceDocument] {
            let root = try NovelTestFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertFalse(document.activeRuns.isEmpty)
            XCTAssertTrue(document.activeRuns.allSatisfy { $0.status == .completed })
            let command = try completedHistoryImportCommand(document: document)
            let prepared = try NovelProjectLifecycle.prepareImport(command)
            let expectedDocument = NovelWorkspaceProjectStore.persistableAtRest(prepared.document)
            XCTAssertNotEqual(expectedDocument, prepared.document)
            let repository = NovelFileProjectRepository(rootDirectory: root)
            let creation = DefaultNovelCreation(repository: repository)

            let outcome = try await creation.perform(.importProject(command))
            let installed = try await repository.loadProject(id: document.project.id)
            XCTAssertEqual(installed.document, expectedDocument)
            XCTAssertEqual(installed.access, .readWrite)
            let record = try await repository.lifecycleOperation(
                projectID: document.project.id,
                operationID: command.context.operationID
            )
            XCTAssertEqual(record?.state, .completed)
            XCTAssertEqual(
                record?.targetProjectSHA256,
                try NovelProjectPackageCodec.encode(expectedDocument).projectSHA256
            )
            let pending = try await repository.listPendingLifecycleOperations()
            XCTAssertTrue(pending.isEmpty)
            let replay = try await creation.perform(.importProject(command))
            XCTAssertEqual(replay, outcome)

            let restartedRepository = NovelFileProjectRepository(rootDirectory: root)
            let restarted = DefaultNovelCreation(repository: restartedRepository)
            let restartedReplay = try await restarted.perform(.importProject(command))
            XCTAssertEqual(restartedReplay, outcome)
            _ = try await restarted.perform(NovelTestFixtures.materialAction(
                document: expectedDocument,
                title: "After Import",
                content: "The imported project remains writable."
            ))
        }
    }

    func testCompletedPackageReplaceUsesPersistedTargetAndMemoryRepositoryKeepsHistory() async throws {
        let document = try completedHistoricalDocument()
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let original = try NovelReducer.apply(
            .renameProject(NovelRenameProjectCommand(
                context: mutationContext(document: document),
                projectID: document.project.id,
                name: "Project Before Replacement"
            )),
            to: document,
            now: now.addingTimeInterval(20)
        ).document
        _ = try await repository.createProject(original, workspaceNative: true)
        let command = try completedHistoryImportCommand(
            document: document,
            policy: .replace(expectedRevision: original.project.revision),
            expectedRevision: original.project.revision
        )
        let creation = DefaultNovelCreation(repository: repository)
        let outcome = try await creation.perform(.importProject(command))
        let installed = try await repository.loadProject(id: document.project.id)
        XCTAssertEqual(installed.document, NovelWorkspaceProjectStore.persistableAtRest(document))
        let replay = try await creation.perform(.importProject(command))
        XCTAssertEqual(replay, outcome)
        let pending = try await repository.listPendingLifecycleOperations()
        XCTAssertTrue(pending.isEmpty)

        let memory = InMemoryNovelProjectRepository()
        let memoryCommand = try completedHistoryImportCommand(document: document)
        _ = try await DefaultNovelCreation(repository: memory).perform(.importProject(memoryCommand))
        let memoryInstalled = try await memory.loadProject(id: document.project.id)
        XCTAssertEqual(memoryInstalled.document, document)
    }

    func testCompletedHistoryImportRetainsOriginalOperationIdentityChecks() async throws {
        let document = try completedHistoricalDocument()
        let start = try XCTUnwrap(document.appliedOperations.first { $0.kind == .startRun })
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let command = NovelImportProjectCommand(
            context: NovelTestFixtures.context(operationID: start.operationID),
            projectID: document.project.id,
            packageData: try NovelProjectPackageCodec.encode(document).data,
            policy: .reject
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await DefaultNovelCreation(repository: repository).perform(.importProject(command))
        ) { error in
            XCTAssertEqual(error as? NovelError, .idempotencyConflict(start.operationID))
        }
        let pending = try await repository.listPendingLifecycleOperations()
        XCTAssertTrue(pending.isEmpty)
    }

    func testPendingCompletedHistoryImportRecoversFromInstalledPersistedTarget() async throws {
        let document = try completedHistoricalDocument()
        let command = try completedHistoryImportCommand(document: document)
        let prepared = try NovelProjectLifecycle.prepareImport(command)
        let target = NovelWorkspaceProjectStore.persistableAtRest(prepared.document)
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        // Simulate process death after the project install and before the
        // lifecycle completion write, using the actual file repository.
        let record = NovelProjectLifecycleOperationRecord(
            projectID: command.projectID,
            operationID: command.context.operationID,
            kind: .importProject,
            payloadSHA256: try NovelAction.importProject(command).canonicalPayloadSHA256(),
            intent: .importCreate,
            sourceProjectSHA256: nil,
            targetProjectSHA256: try NovelProjectPackageCodec.encode(target).projectSHA256,
            outcome: .projectImported(
                sourceProjectID: prepared.sourceProjectID,
                projectID: prepared.destinationProjectID,
                disposition: prepared.disposition,
                interruptedRunCount: prepared.interruptedRunCount,
                revision: target.project.revision
            )
        )
        try await repository.writeLifecycleOperation(record)
        _ = try await repository.createProject(prepared.document, workspaceNative: true)
        let retry = try await DefaultNovelCreation(repository: repository)
            .executeImportProject(command, prepared: prepared)
        XCTAssertEqual(retry, record.outcome)

        // A fresh pending record exercises cold-start recovery rather than
        // the same-operation retry path above.
        let recoveryCommand = try completedHistoryImportCommand(document: document)
        let recoveryRecord = NovelProjectLifecycleOperationRecord(
            projectID: record.projectID,
            operationID: recoveryCommand.context.operationID,
            kind: record.kind,
            payloadSHA256: try NovelAction.importProject(recoveryCommand).canonicalPayloadSHA256(),
            intent: record.intent,
            sourceProjectSHA256: nil,
            targetProjectSHA256: record.targetProjectSHA256,
            outcome: record.outcome
        )
        try await repository.writeLifecycleOperation(recoveryRecord)
        let restartedRepository = NovelFileProjectRepository(rootDirectory: root)
        let restarted = DefaultNovelCreation(repository: restartedRepository)
        _ = try await restarted.snapshot(.project(document.project.id))
        let recovered = try await restartedRepository.lifecycleOperation(
            projectID: document.project.id,
            operationID: recoveryCommand.context.operationID
        )
        XCTAssertEqual(recovered?.state, .completed)
        let pending = try await restartedRepository.listPendingLifecycleOperations()
        XCTAssertTrue(pending.isEmpty)
        _ = try await restarted.perform(NovelTestFixtures.materialAction(
            document: target,
            title: "After Recovery",
            content: "Recovered imports remain writable."
        ))
    }

    func testLegacyFullHashPendingImportRetriesOnlyExactInstalledProjection() async throws {
        let document = try completedHistoricalDocument()
        let source = try NovelReducer.apply(
            NovelTestFixtures.renameAction(document: document, name: "Previous Project"),
            to: document
        ).document
        for replacing in [false, true] {
            for exactTarget in [false, true] {
                let root = try NovelTestFixtures.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let command = try completedHistoryImportCommand(
                    document: document,
                    policy: replacing ? .replace(expectedRevision: source.project.revision) : .reject,
                    expectedRevision: replacing ? source.project.revision : nil
                )
                let prepared = try NovelProjectLifecycle.prepareImport(command)
                let target = NovelWorkspaceProjectStore.persistableAtRest(prepared.document)
                let actual = exactTarget ? target : try NovelReducer.apply(
                    NovelTestFixtures.renameAction(document: target, name: "Later Authoritative State"),
                    to: target
                ).document
                let record = NovelProjectLifecycleOperationRecord(
                    projectID: command.projectID,
                    operationID: command.context.operationID,
                    kind: .importProject,
                    payloadSHA256: try NovelAction.importProject(command).canonicalPayloadSHA256(),
                    intent: replacing ? .importReplace(expectedRevision: source.project.revision) : .importCreate,
                    sourceProjectSHA256: replacing ? try NovelProjectPackageCodec.encode(source).projectSHA256 : nil,
                    targetProjectSHA256: try NovelProjectPackageCodec.encode(prepared.document).projectSHA256,
                    outcome: .projectImported(
                        sourceProjectID: prepared.sourceProjectID,
                        projectID: prepared.destinationProjectID,
                        disposition: prepared.disposition,
                        interruptedRunCount: prepared.interruptedRunCount,
                        revision: prepared.document.project.revision
                    )
                )
                let repository = NovelFileProjectRepository(rootDirectory: root)
                try await repository.writeLifecycleOperation(record)
                _ = try await repository.createProject(actual, workspaceNative: true)
                let restartedRepository = NovelFileProjectRepository(rootDirectory: root)
                let restarted = DefaultNovelCreation(repository: restartedRepository)

                let changed = try NovelReducer.apply(
                    NovelTestFixtures.renameAction(document: document, name: "Different Package"),
                    to: document
                ).document
                let changedCommand = NovelImportProjectCommand(
                    context: command.context,
                    projectID: command.projectID,
                    packageData: try NovelProjectPackageCodec.encode(changed).data,
                    policy: command.policy
                )
                await NovelXCTAssertThrowsErrorAsync(
                    try await restarted.perform(.importProject(changedCommand))
                ) { error in
                    XCTAssertEqual(error as? NovelError, .idempotencyConflict(command.context.operationID))
                }

                if exactTarget {
                    let outcome = try await restarted.perform(.importProject(command))
                    XCTAssertEqual(outcome, record.outcome)
                    let replay = try await restarted.perform(.importProject(command))
                    XCTAssertEqual(replay, outcome)
                    let pending = try await restartedRepository.listPendingLifecycleOperations()
                    XCTAssertTrue(pending.isEmpty)
                    _ = try await restarted.perform(NovelTestFixtures.materialAction(
                        document: target,
                        title: "After Legacy Retry",
                        content: "The exact imported project is writable."
                    ))
                } else {
                    await NovelXCTAssertThrowsErrorAsync(
                        try await restarted.perform(.importProject(command))
                    ) { error in
                        XCTAssertEqual(error as? NovelError, .storageIndeterminate(command.projectID))
                    }
                    let installed = try await restartedRepository.loadProject(id: command.projectID)
                    XCTAssertEqual(installed.document, actual)
                    let pending = try await restartedRepository.lifecycleOperation(
                        projectID: command.projectID,
                        operationID: command.context.operationID
                    )
                    XCTAssertEqual(pending?.state, .pending)
                }
            }
        }
    }

    func testPendingImportWithUnrelatedTargetHashStillRejectsRetry() async throws {
        let document = try completedHistoricalDocument()
        let command = try completedHistoryImportCommand(document: document)
        let prepared = try NovelProjectLifecycle.prepareImport(command)
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let record = NovelProjectLifecycleOperationRecord(
            projectID: command.projectID,
            operationID: command.context.operationID,
            kind: .importProject,
            payloadSHA256: try NovelAction.importProject(command).canonicalPayloadSHA256(),
            intent: .importCreate,
            sourceProjectSHA256: nil,
            targetProjectSHA256: String(repeating: "f", count: 64),
            outcome: .projectImported(
                sourceProjectID: prepared.sourceProjectID,
                projectID: prepared.destinationProjectID,
                disposition: prepared.disposition,
                interruptedRunCount: prepared.interruptedRunCount,
                revision: prepared.document.project.revision
            )
        )
        try await repository.writeLifecycleOperation(record)
        _ = try await repository.createProject(prepared.document, workspaceNative: true)
        await NovelXCTAssertThrowsErrorAsync(
            try await DefaultNovelCreation(repository: repository).perform(.importProject(command))
        ) { error in
            XCTAssertEqual(error as? NovelError, .idempotencyConflict(command.context.operationID))
        }
        let retained = try await repository.lifecycleOperation(
            projectID: command.projectID,
            operationID: command.context.operationID
        )
        XCTAssertEqual(retained, record)
    }

    func testPackageRoundTripPreservesComplexDocumentAndRawPayloadEvidence() throws {
        let document = try complexRunningDocument()

        let artifact = try NovelProjectPackageCodec.encode(document)
        let decoded = try NovelProjectPackageCodec.decode(artifact.data)
        let envelope = try envelopeObject(from: artifact.data)
        let payload = try XCTUnwrap(projectPayload(from: envelope))

        XCTAssertEqual(decoded.document, document)
        XCTAssertEqual(decoded.artifact, artifact)
        XCTAssertEqual(artifact.projectByteCount, payload.count)
        XCTAssertEqual(artifact.projectSHA256, NovelProjectPackageCodec.sha256(payload))
        XCTAssertEqual((envelope["projectByteCount"] as? NSNumber)?.intValue, payload.count)
        XCTAssertEqual(envelope["projectSHA256"] as? String, artifact.projectSHA256)
        XCTAssertEqual(
            try JSONDecoder().decode(NovelProjectDocumentV1.self, from: payload),
            document
        )
        XCTAssertEqual(try NovelProjectPackageCodec.encode(decoded.document).data, artifact.data)
    }

    func testPackageRejectsTamperedByteCountHashBase64AndPayload() throws {
        let artifact = try NovelProjectPackageCodec.encode(documentWithChapterAndState().document)

        let wrongCount = try mutateEnvelope(artifact.data) { envelope in
            let count = try XCTUnwrap((envelope["projectByteCount"] as? NSNumber)?.intValue)
            envelope["projectByteCount"] = count + 1
        }
        assertInvalidPackage(wrongCount)

        let wrongHash = try mutateEnvelope(artifact.data) { envelope in
            envelope["projectSHA256"] = String(repeating: "0", count: 64)
        }
        XCTAssertThrowsError(try NovelProjectPackageCodec.decode(wrongHash)) { error in
            XCTAssertEqual(error as? NovelError, .packageChecksumMismatch)
        }

        let invalidBase64 = try mutateEnvelope(artifact.data) { envelope in
            envelope["projectJSONBase64"] = "%%%not-base64%%%"
        }
        assertInvalidPackage(invalidBase64)

        let changedPayload = try mutateEnvelope(artifact.data) { envelope in
            var payload = try XCTUnwrap(projectPayload(from: envelope))
            payload[payload.startIndex] ^= 0x01
            envelope["projectJSONBase64"] = payload.base64EncodedString()
        }
        XCTAssertThrowsError(try NovelProjectPackageCodec.decode(changedPayload)) { error in
            XCTAssertEqual(error as? NovelError, .packageChecksumMismatch)
        }
    }

    func testImportRejectsExternalPackageWithEscapingOpaquePathBeforeRepositoryAccess() async throws {
        let document = try NovelTestFixtures.document()
        let artifact = try NovelProjectPackageCodec.encode(document)
        // External packages do not pass through our encoder. Rebuild a valid
        // envelope checksum around an unsafe project payload to exercise decode.
        let hostile = try mutateEnvelope(artifact.data) { envelope in
            let payload = try XCTUnwrap(projectPayload(from: envelope))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            var passthrough = object["workspacePassthrough"] as? [String: Any] ?? [:]
            passthrough["opaqueFiles"] = ["../outside.md": "overwrite outside the workspace"]
            object["workspacePassthrough"] = passthrough
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            envelope["projectByteCount"] = changed.count
            envelope["projectSHA256"] = NovelProjectPackageCodec.sha256(changed)
            envelope["projectJSONBase64"] = changed.base64EncodedString()
        }
        assertInvalidPackage(hostile)
        let repository = CountingNovelProjectRepository()
        let command = NovelImportProjectCommand(
            context: NovelTestFixtures.context(),
            projectID: document.project.id,
            packageData: hostile,
            policy: .reject
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await DefaultNovelCreation(repository: repository).perform(.importProject(command))
        ) { error in
            guard case .invalidPackage = error as? NovelError else {
                return XCTFail("Expected unsafe external package rejection, got \(error)")
            }
        }
        let calls = await repository.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testPackageRejectsUnsupportedAndMismatchedSchemas() throws {
        let artifact = try NovelProjectPackageCodec.encode(documentWithChapterAndState().document)
        let futureSchema = NovelProjectDocumentV1.currentSchemaVersion + 1

        let unsupportedEnvelope = try mutateEnvelope(artifact.data) { envelope in
            envelope["projectSchemaVersion"] = futureSchema
        }
        XCTAssertThrowsError(try NovelProjectPackageCodec.decode(unsupportedEnvelope)) { error in
            XCTAssertEqual(error as? NovelError, .unsupportedSchema(futureSchema))
        }

        let mismatchedPayload = try mutateEnvelope(artifact.data) { envelope in
            let payload = try XCTUnwrap(projectPayload(from: envelope))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            object["schemaVersion"] = futureSchema
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            envelope["projectByteCount"] = changed.count
            envelope["projectSHA256"] = NovelProjectPackageCodec.sha256(changed)
            envelope["projectJSONBase64"] = changed.base64EncodedString()
        }
        assertInvalidPackage(mismatchedPayload)
    }

    func testPackageEnforcesPayloadAndEnvelopeLimits() throws {
        let document = try documentWithChapterAndState().document
        let payloadLimited = NovelProjectPackageLimits(
            maximumProjectBytes: 1,
            maximumEnvelopeBytes: 1_024
        )
        XCTAssertThrowsError(try NovelProjectPackageCodec.encode(
            document,
            limits: payloadLimited
        )) { error in
            XCTAssertEqual(error as? NovelError, .packageTooLarge(maximumBytes: 1))
        }

        let artifact = try NovelProjectPackageCodec.encode(document)
        let envelopeLimit = artifact.data.count - 1
        XCTAssertGreaterThan(envelopeLimit, 1)
        XCTAssertThrowsError(try NovelProjectPackageCodec.decode(
            artifact.data,
            limits: NovelProjectPackageLimits(
                maximumProjectBytes: 1,
                maximumEnvelopeBytes: envelopeLimit
            )
        )) { error in
            XCTAssertEqual(
                error as? NovelError,
                .packageTooLarge(maximumBytes: envelopeLimit)
            )
        }
    }

    func testHigherSchemaImportDoesNotTouchRepository() async throws {
        let document = try documentWithChapterAndState().document
        let artifact = try NovelProjectPackageCodec.encode(document)
        let futureSchema = NovelProjectDocumentV1.currentSchemaVersion + 1
        let unsupported = try mutateEnvelope(artifact.data) { envelope in
            envelope["projectSchemaVersion"] = futureSchema
        }
        let repository = CountingNovelProjectRepository()
        let creation = DefaultNovelCreation(repository: repository)
        let command = NovelImportProjectCommand(
            context: NovelTestFixtures.context(),
            projectID: document.project.id,
            packageData: unsupported,
            policy: .reject
        )

        await NovelXCTAssertThrowsErrorAsync(
            try await creation.perform(.importProject(command))
        ) { error in
            XCTAssertEqual(error as? NovelError, .unsupportedSchema(futureSchema))
        }
        let repositoryCalls = await repository.callCount()
        XCTAssertEqual(repositoryCalls, 0)
    }

    func testKeepBothRemapsTypedProjectReferencesWithoutChangingHistoricalHashes() throws {
        let source = try complexRunningDocument()
        let destinationID = NovelProjectID()
        let artifact = try NovelProjectPackageCodec.encode(source)
        let command = NovelImportProjectCommand(
            context: NovelTestFixtures.context(),
            projectID: destinationID,
            packageData: artifact.data,
            policy: .keepBoth(destinationProjectID: destinationID)
        )

        let prepared = try NovelProjectLifecycle.prepareImport(command)
        let imported = prepared.document
        let historical = Array(imported.appliedOperations.prefix(source.appliedOperations.count))

        XCTAssertEqual(prepared.sourceProjectID, source.project.id)
        XCTAssertEqual(prepared.destinationProjectID, destinationID)
        XCTAssertEqual(prepared.disposition, .keptBoth)
        XCTAssertEqual(prepared.interruptedRunCount, 1)
        XCTAssertEqual(imported.project.id, destinationID)
        XCTAssertTrue(imported.injectionReceipts.allSatisfy { $0.projectID == destinationID })
        XCTAssertTrue(imported.appliedOperations.allSatisfy { $0.outcome.projectID == destinationID })
        XCTAssertEqual(historical.map(\.operationID), source.appliedOperations.map(\.operationID))
        XCTAssertEqual(historical.map(\.payloadSHA256), source.appliedOperations.map(\.payloadSHA256))
        XCTAssertEqual(historical.map(\.kind), source.appliedOperations.map(\.kind))
        XCTAssertEqual(source.injectionReceipts.map(\.projectID), [source.project.id])
        XCTAssertNoThrow(try NovelDocumentValidator.validate(imported))
    }

    func testRunningNormalizationIsDeterministicAndIdempotent() throws {
        let source = try complexRunningDocument()

        let first = try NovelImportedProjectNormalizer.normalizeRunningRuns(in: source)
        let replay = try NovelImportedProjectNormalizer.normalizeRunningRuns(in: source)
        let idempotent = try NovelImportedProjectNormalizer.normalizeRunningRuns(in: first.document)

        XCTAssertEqual(first.document, replay.document)
        XCTAssertEqual(first.interruptedRunCount, 1)
        XCTAssertEqual(replay.interruptedRunCount, 1)
        XCTAssertEqual(idempotent.document, first.document)
        XCTAssertEqual(idempotent.interruptedRunCount, 0)
        XCTAssertEqual(first.document.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(first.document.activeRuns.first?.interruptionReason, .recovery)
        XCTAssertNil(first.document.branches.first?.activeRunID)
        XCTAssertEqual(first.document.project.revision, source.project.revision + 1)
        XCTAssertEqual(first.document.appliedOperations, source.appliedOperations)
        XCTAssertNoThrow(try NovelDocumentValidator.validate(first.document))
    }

    func testMarkdownUsesHeadCheckpointInsteadOfUnsynchronizedWorkingVersion() throws {
        let fixture = try documentWithChapterAndState()
        let source = fixture.document
        let branch = try XCTUnwrap(source.branches.first)
        let chapterID = try XCTUnwrap(branch.workingChapterSelections.first?.chapterID)
        let workingContent = "Mara opens the sealed gate, changing the unresolved plot."
        let command = NovelSaveManualEditCommand(
            context: mutationContext(document: source),
            projectID: source.project.id,
            branchID: branch.id,
            chapterID: chapterID,
            versionID: NovelChapterVersionID(),
            title: "Working Rewrite",
            content: workingContent,
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let edited = try NovelFactTransactionReducer.saveManualEdit(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: source,
            now: now.addingTimeInterval(10)
        ).document

        let exported = try NovelMarkdownExporter.export(edited, branchID: branch.id)

        XCTAssertEqual(edited.branches[0].syncStatus, .needsSync)
        XCTAssertNotEqual(
            edited.branches[0].workingChapterSelections,
            source.branches[0].workingChapterSelections
        )
        XCTAssertTrue(exported.markdown.contains(fixture.sourceContent))
        XCTAssertFalse(exported.markdown.contains(workingContent))
        XCTAssertTrue(exported.markdown.contains("# Chapter One"))
        XCTAssertTrue(exported.markdown.hasSuffix("\n"))
    }

    func testRejectReplaceExportAndDeleteLifecycle() async throws {
        let document = try documentWithChapterAndState().document
        let artifact = try NovelProjectPackageCodec.encode(document)
        let repository = InMemoryNovelProjectRepository()
        let creation = DefaultNovelCreation(repository: repository)
        let importCommand = NovelImportProjectCommand(
            context: NovelTestFixtures.context(),
            projectID: document.project.id,
            packageData: artifact.data,
            policy: .reject
        )

        let importedOutcome = try await creation.perform(.importProject(importCommand))
        XCTAssertEqual(
            importedOutcome,
            .projectImported(
                sourceProjectID: document.project.id,
                projectID: document.project.id,
                disposition: .created,
                interruptedRunCount: 0,
                revision: document.project.revision
            )
        )
        guard case .package(let exported) = try await creation.snapshot(
            .projectPackage(document.project.id)
        ) else {
            return XCTFail("Expected a project package snapshot.")
        }
        XCTAssertEqual(exported.data, artifact.data)

        let duplicate = NovelImportProjectCommand(
            context: NovelTestFixtures.context(),
            projectID: document.project.id,
            packageData: artifact.data,
            policy: .reject
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await creation.perform(.importProject(duplicate))
        ) { error in
            XCTAssertEqual(error as? NovelError, .projectAlreadyExists(document.project.id))
        }

        let imported = try await repository.loadProject(id: document.project.id).document
        _ = try await creation.perform(NovelTestFixtures.renameAction(document: imported))
        let renamed = try await repository.loadProject(id: document.project.id).document
        let replace = NovelImportProjectCommand(
            context: NovelTestFixtures.context(projectRevision: renamed.project.revision),
            projectID: document.project.id,
            packageData: artifact.data,
            policy: .replace(expectedRevision: renamed.project.revision)
        )
        let replacedOutcome = try await creation.perform(.importProject(replace))
        XCTAssertEqual(
            replacedOutcome,
            .projectImported(
                sourceProjectID: document.project.id,
                projectID: document.project.id,
                disposition: .replaced,
                interruptedRunCount: 0,
                revision: document.project.revision
            )
        )
        let replacedDocument = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(replacedDocument, document)

        let delete = NovelDeleteProjectCommand(
            context: NovelTestFixtures.context(projectRevision: document.project.revision),
            projectID: document.project.id
        )
        let deletedOutcome = try await creation.perform(.deleteProject(delete))
        XCTAssertEqual(
            deletedOutcome,
            .projectDeleted(projectID: document.project.id)
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await creation.snapshot(.project(document.project.id))
        ) { error in
            XCTAssertEqual(error as? NovelError, .projectNotFound(document.project.id))
        }
    }

    func testActiveRunAllowsMarkdownSnapshotButBlocksPackageAndMutatingLifecycle() async throws {
        let fixture = try documentWithChapterAndState()
        let document = fixture.document
        let artifact = try NovelProjectPackageCodec.encode(document)
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: resolvedModel,
            scripts: [NovelModelScript(steps: [
                .pause,
                .delta("The plan remains unchanged."),
                .complete,
            ])]
        )
        let creation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            now: { Date(timeIntervalSince1970: 1_700_500_100) }
        )
        let request = discussionRequest(for: document)
        let run = try await creation.start(request)
        let busy = NovelError.projectBusy(document.project.id)

        await NovelXCTAssertThrowsErrorAsync(
            try await creation.snapshot(.projectPackage(document.project.id))
        ) { XCTAssertEqual($0 as? NovelError, busy) }
        guard case .markdown(let markdown) = try await creation.snapshot(.branchMarkdown(
            projectID: document.project.id,
            branchID: document.branches[0].id
        )) else {
            return XCTFail("Expected a Markdown snapshot while generation remains active.")
        }
        XCTAssertTrue(markdown.markdown.contains(fixture.sourceContent))
        let runningAfterExport = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(runningAfterExport.activeRuns.first?.status, .running)
        XCTAssertEqual(runningAfterExport.branches.first?.activeRunID, request.id)

        let reject = NovelImportProjectCommand(
            context: NovelTestFixtures.context(),
            projectID: document.project.id,
            packageData: artifact.data,
            policy: .reject
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await creation.perform(.importProject(reject))
        ) { XCTAssertEqual($0 as? NovelError, busy) }

        let runningRevision = document.project.revision + 1
        let replace = NovelImportProjectCommand(
            context: NovelTestFixtures.context(projectRevision: runningRevision),
            projectID: document.project.id,
            packageData: artifact.data,
            policy: .replace(expectedRevision: runningRevision)
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await creation.perform(.importProject(replace))
        ) { XCTAssertEqual($0 as? NovelError, busy) }

        let delete = NovelDeleteProjectCommand(
            context: NovelTestFixtures.context(projectRevision: runningRevision),
            projectID: document.project.id
        )
        await NovelXCTAssertThrowsErrorAsync(
            try await creation.perform(.deleteProject(delete))
        ) { XCTAssertEqual($0 as? NovelError, busy) }

        await adapter.resume(runID: request.id)
        var didComplete = false
        for await event in run.events {
            if case .completed = event {
                didComplete = true
            }
        }
        XCTAssertTrue(didComplete)
    }
}

private extension NovelProjectPackageTests {
    func completedHistoricalDocument() throws -> NovelProjectDocumentV1 {
        let running = try complexRunningDocument()
        let run = try XCTUnwrap(running.activeRuns.first)
        return try NovelGenerationReducer.complete(
            runID: run.id,
            content: "The sealed gate remains closed.",
            in: running,
            now: now.addingTimeInterval(10)
        ).document
    }

    func completedHistoryImportCommand(
        document: NovelProjectDocumentV1,
        policy: NovelProjectImportPolicy = .reject,
        expectedRevision: Int64? = nil
    ) throws -> NovelImportProjectCommand {
        NovelImportProjectCommand(
            context: NovelTestFixtures.context(projectRevision: expectedRevision),
            projectID: document.project.id,
            packageData: try NovelProjectPackageCodec.encode(document).data,
            policy: policy
        )
    }

    func complexRunningDocument() throws -> NovelProjectDocumentV1 {
        var document = try documentWithChapterAndState().document
        document = try NovelReducer.apply(
            NovelTestFixtures.materialAction(
                document: document,
                title: "Gate Covenant",
                content: "The sealed gate records every promise spoken nearby."
            ),
            to: document,
            now: now.addingTimeInterval(1)
        ).document
        let request = discussionRequest(for: document)
        let plan = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: request.branchID,
                promptKind: .discussion,
                userText: request.userText
            )
        )
        let injection = NovelInjectionReceiptRecord(
            id: request.injectionReceiptID,
            runID: request.id,
            projectID: request.projectID,
            branchID: request.branchID,
            plan: plan,
            overrides: request.injectionOverrides,
            providerID: "package-provider",
            modelID: "package-model",
            parameters: ["temperature": "0.7"],
            createdAt: now.addingTimeInterval(2)
        )
        let generation = NovelGenerationReceiptRecord(
            id: request.generationReceiptID,
            runID: request.id,
            providerID: injection.providerID,
            modelID: injection.modelID,
            promptVersion: injection.promptVersion,
            injectionReceiptID: injection.id,
            parameters: injection.parameters,
            requestSHA256: NovelTestFixtures.hashA,
            createdAt: now.addingTimeInterval(2)
        )
        return try NovelGenerationReducer.begin(
            request,
            artifacts: NovelGenerationStartArtifacts(
                injectionReceipt: injection,
                generationReceipt: generation
            ),
            in: document,
            now: now.addingTimeInterval(2)
        ).document
    }

    func discussionRequest(for document: NovelProjectDocumentV1) -> NovelRunRequest {
        let branch = document.branches[0]
        return NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: branch.id,
            kind: .discussion,
            mode: .discussPlan,
            granularity: nil,
            userText: "Should the sealed gate remain closed?",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: nil,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
    }

    func mutationContext(document: NovelProjectDocumentV1) -> NovelMutationContext {
        NovelMutationContext(
            operationID: NovelOperationID(),
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: document.branches[0].headRevision
        )
    }

    func envelopeObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func projectPayload(from envelope: [String: Any]) -> Data? {
        guard let encoded = envelope["projectJSONBase64"] as? String else { return nil }
        return Data(base64Encoded: encoded, options: [])
    }

    func mutateEnvelope(
        _ data: Data,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var envelope = try envelopeObject(from: data)
        try mutation(&envelope)
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    func assertInvalidPackage(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NovelProjectPackageCodec.decode(data),
            file: file,
            line: line
        ) { error in
            guard case .invalidPackage = error as? NovelError else {
                return XCTFail("Expected invalidPackage, got \(error)", file: file, line: line)
            }
        }
    }
}

private actor CountingNovelProjectRepository: NovelProjectPersisting {
    private var calls = 0

    func callCount() -> Int { calls }

    func listProjects() async throws -> [NovelProjectSummary] {
        calls += 1
        throw unexpectedCall()
    }

    func loadProject(id: NovelProjectID) async throws -> NovelLoadedProject {
        calls += 1
        throw unexpectedCall()
    }

    func createProject(_ document: NovelProjectDocumentV1) async throws -> NovelLoadedProject {
        calls += 1
        throw unexpectedCall()
    }

    func commitProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64,
        authorization: NovelRepositoryCommitAuthorization?
    ) async throws -> NovelLoadedProject {
        calls += 1
        throw unexpectedCall()
    }

    func replaceProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64
    ) async throws -> NovelLoadedProject {
        calls += 1
        throw unexpectedCall()
    }

    func deleteProject(id: NovelProjectID, expectedRevision: Int64) async throws {
        calls += 1
        throw unexpectedCall()
    }

    func restorePreviousProject(
        id: NovelProjectID,
        expectedDocumentSHA256: String
    ) async throws -> NovelLoadedProject {
        calls += 1
        throw unexpectedCall()
    }

    func listRecoverySidecars() async throws -> [NovelRecoverySidecarV1] {
        calls += 1
        throw unexpectedCall()
    }

    func writeRecoverySidecar(_ sidecar: NovelRecoverySidecarV1) async throws {
        calls += 1
        throw unexpectedCall()
    }

    func removeRecoverySidecar(projectID: NovelProjectID, runID: NovelRunID) async throws {
        calls += 1
        throw unexpectedCall()
    }

    private func unexpectedCall() -> NovelError {
        .repositoryFailure("Repository must not be touched during package preflight.")
    }

    /// 废弃的章不得进入成稿。此前只有生成上下文排除了它们,导出照单全收,
    /// 用户表现为「明明废弃了，导出来还在」。导出此前零测试覆盖。
    func testExportSkipsDiscardedChapters() throws {
        var document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let branch = document.branches[0]

        func addChapter(title: String, content: String, discarded: Bool) -> NovelChapterSelection {
            let chapterID = NovelChapterID()
            let versionID = NovelChapterVersionID()
            document.chapters.append(NovelChapterRecord(
                id: chapterID,
                createdAt: document.project.updatedAt,
                discardedAt: discarded ? document.project.updatedAt : nil
            ))
            document.chapterVersions.append(NovelChapterVersionRecord(
                id: versionID,
                chapterID: chapterID,
                kind: .collected,
                title: title,
                content: content,
                factCompatibilityID: UUID(),
                sourceCandidateID: nil,
                createdAt: document.project.updatedAt,
                operationID: document.appliedOperations[0].operationID
            ))
            return NovelChapterSelection(chapterID: chapterID, versionID: versionID)
        }

        let kept = addChapter(title: "第一章", content: "保留的正文。", discarded: false)
        let dropped = addChapter(title: "第二章", content: "废弃的正文。", discarded: true)
        let selections = [kept, dropped]

        let checkpointIndex = try XCTUnwrap(document.checkpoints.firstIndex {
            $0.id == branch.headCheckpointID
        })
        let checkpoint = document.checkpoints[checkpointIndex]
        document.checkpoints[checkpointIndex] = NovelBranchCheckpointRecord(
            id: checkpoint.id,
            kind: checkpoint.kind,
            createdOnBranchID: checkpoint.createdOnBranchID,
            parentCheckpointID: checkpoint.parentCheckpointID,
            chapterSelections: selections,
            stateSnapshotID: checkpoint.stateSnapshotID,
            sessionCursor: checkpoint.sessionCursor,
            branchOverrideRevisionIDs: checkpoint.branchOverrideRevisionIDs,
            sourceCandidateID: checkpoint.sourceCandidateID,
            baseHeadRevision: checkpoint.baseHeadRevision,
            operationID: checkpoint.operationID,
            createdAt: checkpoint.createdAt
        )
        document.branches[0].workingChapterSelections = selections

        let exported = try NovelMarkdownExporter.export(document, branchID: branch.id)
        XCTAssertTrue(exported.markdown.contains("保留的正文。"))
        XCTAssertFalse(exported.markdown.contains("废弃的正文。"), "废弃的章不得进入成稿")
    }
}
