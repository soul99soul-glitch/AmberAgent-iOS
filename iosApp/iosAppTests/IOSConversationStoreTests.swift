import XCTest
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSConversationStoreTests: IOSConversationStoreTestCase {
    func testSavingNewMessagesRefreshesConversationAndSummaryUpdateTime() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreUpdateTime-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "first message")])
        let before = try XCTUnwrap(store.currentConversation?.updateAt.toEpochMilliseconds())
        try await Task.sleep(nanoseconds: 5_000_000)

        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "first message"),
            UIMessage.companion.assistant(prompt: "reply"),
        ])

        let conversationUpdate = try XCTUnwrap(store.currentConversation?.updateAt.toEpochMilliseconds())
        let summaryUpdate = try XCTUnwrap(store.summaries.first { $0.id == conversationId }?.updateAt.toEpochMilliseconds())
        XCTAssertGreaterThan(conversationUpdate, before)
        XCTAssertEqual(summaryUpdate, conversationUpdate)
    }

    func testFailedVisibilityReadDoesNotExposeChildrenOrSelectANewConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = IOSConversationStore(baseDirectory: directory)
        await seed.bootstrap()
        let childID = try XCTUnwrap(seed.currentConversation?.id)
        var fails = true
        let store = IOSConversationStore(baseDirectory: directory, subagentConversationIDsProvider: {
            if fails { throw NSError(domain: "EdgeRead", code: 1) }
            return [childID.toHexDashString()]
        })
        await store.bootstrap()
        XCTAssertNil(store.currentConversation)
        XCTAssertTrue(store.summaries.isEmpty)
        fails = false
        await store.bootstrap()
        XCTAssertFalse(store.summaries.contains { $0.id == childID })
        XCTAssertTrue(store.allSummaries.contains { $0.id == childID })
        XCTAssertNotEqual(store.currentConversation?.id, childID)
    }

    func testRegisteredSubagentIsExcludedFromVisibleSummariesButRetainedInAllSummaries() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreSubagentProjection-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        var subagentIDs = Set<String>()
        let store = IOSConversationStore(
            baseDirectory: baseDirectory,
            subagentConversationIDsProvider: { subagentIDs }
        )
        await store.bootstrap()
        let childID = KotlinUuid.companion.random()
        subagentIDs.insert(childID.toHexDashString())
        store.registerSubagentConversation(id: childID)

        let didSave = await store.saveForkedConversation(Conversation.companion.ofId(
            id: childID,
            assistantId: AssistantKt.DEFAULT_ASSISTANT_ID,
            messages: [],
            newConversation: false
        ))
        XCTAssertTrue(didSave)

        XCTAssertTrue(store.allSummaries.contains { $0.id == childID })
        XCTAssertFalse(store.summaries.contains { $0.id == childID })
    }

    func testBootstrapDoesNotSelectPersistedSubagentAsCurrentConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreSubagentBootstrap-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        var subagentIDs = Set<String>()
        let firstStore = IOSConversationStore(
            baseDirectory: baseDirectory,
            subagentConversationIDsProvider: { subagentIDs }
        )
        await firstStore.bootstrap()
        let rootID = try XCTUnwrap(firstStore.currentConversation?.id)
        let childID = KotlinUuid.companion.random()
        subagentIDs.insert(childID.toHexDashString())
        firstStore.registerSubagentConversation(id: childID)
        let didSave = await firstStore.saveForkedConversation(Conversation.companion.ofId(
            id: childID,
            assistantId: AssistantKt.DEFAULT_ASSISTANT_ID,
            messages: [],
            newConversation: false
        ))
        XCTAssertTrue(didSave)

        let restartedStore = IOSConversationStore(
            baseDirectory: baseDirectory,
            subagentConversationIDsProvider: { subagentIDs }
        )
        await restartedStore.bootstrap()

        XCTAssertEqual(restartedStore.currentConversation?.id, rootID)
        XCTAssertFalse(restartedStore.summaries.contains { $0.id == childID })
        XCTAssertTrue(restartedStore.allSummaries.contains { $0.id == childID })
    }

    func testRefreshingSubagentVisibilityHidesAnExistingSummary() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreSubagentRefresh-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        var subagentIDs = Set<String>()
        let store = IOSConversationStore(
            baseDirectory: baseDirectory,
            subagentConversationIDsProvider: { subagentIDs }
        )
        await store.bootstrap()
        let childID = KotlinUuid.companion.random()
        let didSave = await store.saveForkedConversation(Conversation.companion.ofId(
            id: childID,
            assistantId: AssistantKt.DEFAULT_ASSISTANT_ID,
            messages: [],
            newConversation: false
        ))
        XCTAssertTrue(didSave)
        XCTAssertTrue(store.summaries.contains { $0.id == childID })

        subagentIDs.insert(childID.toHexDashString())
        try await store.refreshSubagentConversationVisibility()

        XCTAssertFalse(store.summaries.contains { $0.id == childID })
        XCTAssertTrue(store.allSummaries.contains { $0.id == childID })
    }

    func testImportConversationDocumentsUsesStorageOwnedBatchImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreImport-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("source")
        let destinationDirectory = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = IOSConversationStore(baseDirectory: sourceDirectory)
        await source.bootstrap()
        await source.saveCurrent(messages: [UIMessage.companion.user(prompt: "restored message")])
        let sourceId = try XCTUnwrap(source.currentConversation?.id)
        let documentURL = sourceDirectory.appendingPathComponent("\(sourceId).json")
        let document = try String(contentsOf: documentURL, encoding: .utf8)

        await source.newConversation()
        let childId = try XCTUnwrap(source.currentConversation?.id)
        let childDocument = try String(contentsOf: sourceDirectory.appendingPathComponent("\(childId).json"), encoding: .utf8)
        let edge = IOSConversationThreadEdge(
            childThreadId: childId.toHexDashString(), parentThreadId: sourceId.toHexDashString(),
            agentPath: "/root/research", nickname: nil, roleAssistantId: nil,
            forkTurns: "none", status: "Open", createdAt: 1
        )
        let database = IosDatabaseFactory.shared.createDatabase(atFilePath: root.appendingPathComponent("restored.db").path)
        let destination = IOSConversationStore(baseDirectory: destinationDirectory, threadEdgeDaoProvider: { database.threadEdgeDao() })
        await destination.bootstrap()
        let importedCount = try await destination.importConversationDocuments([document, childDocument], threadEdges: [edge])

        XCTAssertEqual(importedCount, 2)
        XCTAssertTrue(destination.summaries.contains { $0.id == sourceId })
        XCTAssertFalse(destination.summaries.contains { $0.id == childId })
        await destination.selectConversation(id: sourceId)
        XCTAssertEqual(destination.currentMessages.map { $0.toText() }, ["restored message"])
        let restarted = IOSConversationStore(baseDirectory: destinationDirectory, threadEdgeDaoProvider: { database.threadEdgeDao() })
        await restarted.bootstrap()
        XCTAssertFalse(restarted.summaries.contains { $0.id == childId })
        let restoredEdges = try await restarted.orchestrationEdgesForBackup()
        XCTAssertEqual(restoredEdges, [edge])

        // The local child edge remains while only the parent is re-imported.
        // Reversing that parent link must not form a cycle through local data.
        let cyclic = IOSConversationThreadEdge(
            childThreadId: sourceId.toHexDashString(), parentThreadId: childId.toHexDashString(),
            agentPath: "/root/cycle", nickname: nil, roleAssistantId: nil,
            forkTurns: "none", status: "Open", createdAt: 2
        )
        do {
            _ = try await restarted.importConversationDocuments([document], threadEdges: [cyclic])
            XCTFail("循环关系应在写入前被拒绝")
        } catch let error as IOSConversationThreadEdgeValidationError {
            guard case .cycle = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testImportInvalidatesPreImportBaselineEvenWhenSequenceIsZero() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreImportEpoch-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("source")
        let destinationDirectory = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = IOSConversationStore(baseDirectory: sourceDirectory)
        await source.bootstrap()
        let conversationId = try XCTUnwrap(source.currentConversation?.id)
        await source.saveCurrent(messages: [UIMessage.companion.user(prompt: "first restored state")])
        let documentURL = sourceDirectory.appendingPathComponent("\(conversationId).json")
        let firstDocument = try String(contentsOf: documentURL, encoding: .utf8)

        let destination = IOSConversationStore(baseDirectory: destinationDirectory)
        await destination.bootstrap()
        let unrelatedId = try XCTUnwrap(destination.currentConversation?.id)
        destination.setListPreview(id: unrelatedId, preview: "keep unrelated preview")
        _ = try await destination.importConversationDocuments([firstDocument])
        await destination.selectConversation(id: conversationId)
        let staleBaseline = destination.writeBaseline(for: conversationId)
        destination.setListPreview(id: conversationId, preview: "old preview")
        destination.setListIconKey(id: conversationId, key: "book")
        XCTAssertTrue(destination.canApplyAuxiliaryResult(since: staleBaseline))

        await source.saveCurrent(messages: [UIMessage.companion.user(prompt: "new restored state")])
        let replacementDocument = try String(contentsOf: documentURL, encoding: .utf8)
        _ = try await destination.importConversationDocuments([replacementDocument])
        XCTAssertFalse(destination.canApplyAuxiliaryResult(since: staleBaseline))
        XCTAssertEqual(destination.listPreview(for: conversationId), "")
        XCTAssertNil(destination.listIconKey(for: conversationId))
        XCTAssertEqual(destination.listPreview(for: unrelatedId), "keep unrelated preview")

        let didLateWrite = await destination.save(
            messages: [UIMessage.companion.user(prompt: "old run wrote after restore")],
            to: conversationId,
            ifUnchangedSince: staleBaseline
        )

        XCTAssertFalse(didLateWrite)
        XCTAssertEqual(destination.currentMessages.map { $0.toText() }, ["new restored state"])
    }

    func testImportDrainsInFlightSnapshotWriteBeforeReloadingCurrentConversation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreImportGate-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("source")
        let destinationDirectory = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = IOSConversationStore(baseDirectory: sourceDirectory)
        await source.bootstrap()
        let conversationId = try XCTUnwrap(source.currentConversation?.id)
        await source.saveCurrent(messages: [UIMessage.companion.user(prompt: "first restored state")])
        let documentURL = sourceDirectory.appendingPathComponent("\(conversationId).json")
        let firstDocument = try String(contentsOf: documentURL, encoding: .utf8)

        let destination = IOSConversationStore(baseDirectory: destinationDirectory)
        await destination.bootstrap()
        _ = try await destination.importConversationDocuments([firstDocument])
        await destination.selectConversation(id: conversationId)

        await source.saveCurrent(messages: [UIMessage.companion.user(prompt: "restored after in-flight write")])
        let replacementDocument = try String(contentsOf: documentURL, encoding: .utf8)

        let reachedPersist = expectation(description: "old snapshot reached store persist")
        var allowPersist: CheckedContinuation<Void, Never>?
        destination.beforePersistForTesting = { conversation in
            guard conversation.id == conversationId else { return }
            reachedPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        let staleSave = Task { @MainActor in
            await destination.save(
                messages: [UIMessage.companion.user(prompt: "old snapshot must not survive restore")],
                to: conversationId
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)

        let restore = Task { @MainActor in
            try await destination.importConversationDocuments([replacementDocument])
        }
        let didEnterImport = await waitFor {
            destination.isImportingConversationDocuments
        }
        XCTAssertTrue(didEnterImport)

        destination.beforePersistForTesting = nil
        allowPersist?.resume()

        let didWriteStaleSnapshot = await staleSave.value
        let restoredCount = try await restore.value
        XCTAssertFalse(didWriteStaleSnapshot)
        XCTAssertEqual(restoredCount, 1)
        XCTAssertFalse(destination.isImportingConversationDocuments)
        XCTAssertEqual(
            destination.currentMessages.map { $0.toText() },
            ["restored after in-flight write"]
        )
    }

    func testStartNewConversationReusesCurrentEmptyConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreReuseCurrentEmpty-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let emptyConversationId = try XCTUnwrap(store.currentConversation?.id)
        let summaryCount = store.summaries.count

        await store.startNewConversationReusingEmpty()

        XCTAssertEqual(store.currentConversation?.id, emptyConversationId)
        XCTAssertEqual(store.summaries.count, summaryCount)
        XCTAssertTrue(store.currentMessages.isEmpty)
    }

    func testStartNewConversationReusesMostRecentEmptyConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreReuseRecentEmpty-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let populatedConversationId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "已开始的对话")])

        await store.newConversation()
        let emptyConversationId = try XCTUnwrap(store.currentConversation?.id)
        let summaryCount = store.summaries.count

        await store.selectConversation(id: populatedConversationId)
        XCTAssertEqual(store.currentConversation?.id, populatedConversationId)

        await store.startNewConversationReusingEmpty()

        XCTAssertEqual(store.currentConversation?.id, emptyConversationId)
        XCTAssertEqual(store.summaries.count, summaryCount)
        XCTAssertTrue(store.currentMessages.isEmpty)
    }

    func testSelectingMissingConversationFailsWithoutChangingCurrentConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreMissingSelection-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let originalId = try XCTUnwrap(store.currentConversation?.id)

        let didSelect = await store.selectConversationIfAvailable(id: KotlinUuid.companion.random())

        XCTAssertFalse(didSelect)
        XCTAssertEqual(store.currentConversation?.id, originalId)
    }

    func testConditionalSelectionDoesNotCommitAfterItsOwnerBecomesStale() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreConditionalSelection-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let originalId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "original")])
        await store.newConversation()
        let currentId = try XCTUnwrap(store.currentConversation?.id)

        let didSelect = await store.selectConversationIfAvailable(
            id: originalId,
            commitIf: { false }
        )

        XCTAssertFalse(didSelect)
        XCTAssertEqual(store.currentConversation?.id, currentId)
    }

    func testConditionalNewConversationDoesNotCommitAfterItsOwnerBecomesStale() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreConditionalNew-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let originalId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "original")])

        var canCommit = true
        store.beforePersistForTesting = { _ in canCommit = false }
        let didCreate = await store.newConversation(commitIf: { canCommit })
        store.beforePersistForTesting = nil

        XCTAssertFalse(didCreate)
        XCTAssertEqual(store.currentConversation?.id, originalId)

        await store.newConversation()
        let emptyId = try XCTUnwrap(store.currentConversation?.id)
        await store.selectConversation(id: originalId)

        let didReuse = await store.startNewConversationReusingEmpty(commitIf: { false })

        XCTAssertFalse(didReuse)
        XCTAssertEqual(store.currentConversation?.id, originalId)
        XCTAssertNotEqual(store.currentConversation?.id, emptyId)
    }

    func testImageGenerationResumeScanUsesPersistedCrossConversationOwner() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreImageResume-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let completedMessage = imageGenerationMessage(
            toolCallID: "completed-image-tool",
            prompt: "已完成的图片",
            output: [UIMessagePart.Image(
                url: "amber-image-generation://completed.png",
                metadata: nil
            )]
        )
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "生成一张已完成的图片"),
            completedMessage
        ])

        await store.newConversation()
        let runningMessage = imageGenerationMessage(
            toolCallID: "running-image-tool",
            prompt: "正在生成的图片",
            output: []
        )
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "生成一张仍在处理的图片"),
            runningMessage
        ])

        let restartedStore = IOSConversationStore(baseDirectory: baseDirectory)
        await restartedStore.bootstrap()
        var persistedRunningOwner: (conversationID: KotlinUuid, messageID: String)?
        var persistedCompletedOwner: (conversationID: KotlinUuid, messageID: String)?
        for summary in restartedStore.summaries {
            guard let messages = await restartedStore.messages(for: summary.id) else { continue }
            for message in messages {
                let toolCallIDs = message.parts.compactMap {
                    ($0 as? UIMessagePart.Tool)?.toolCallId
                }
                if toolCallIDs.contains("running-image-tool") {
                    persistedRunningOwner = (
                        summary.id,
                        ChatMessageProjector.messageId(for: message)
                    )
                }
                if toolCallIDs.contains("completed-image-tool") {
                    persistedCompletedOwner = (
                        summary.id,
                        ChatMessageProjector.messageId(for: message)
                    )
                }
            }
        }
        let runningOwner = try XCTUnwrap(persistedRunningOwner)
        let completedOwner = try XCTUnwrap(persistedCompletedOwner)

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.conversationStore = restartedStore
        viewModel.generationActiveOverrideForTesting = {
            $0 == runningOwner.conversationID
        }
        let loadedRunningMessages = await restartedStore.messages(
            for: runningOwner.conversationID
        )
        let persistedRunningMessages = try XCTUnwrap(loadedRunningMessages)
        XCTAssertNotNil(ChatImageGenerationResumeProjection.latest(
            in: persistedRunningMessages,
            conversationID: runningOwner.conversationID.toHexDashString(),
            isGenerationActive: true
        ))
        XCTAssertTrue(viewModel.isGenerationActive(conversationId: runningOwner.conversationID))

        let persistedRunningContext = await viewModel.latestImageGenerationResumeContext()
        let runningContext = try XCTUnwrap(persistedRunningContext)
        XCTAssertEqual(runningContext.conversationID, runningOwner.conversationID.toHexDashString())
        XCTAssertEqual(runningContext.messageID, runningOwner.messageID)
        XCTAssertEqual(runningContext.toolCallID, "running-image-tool")
        XCTAssertEqual(runningContext.state, .running)

        viewModel.generationActiveOverrideForTesting = { _ in false }
        let persistedCompletedContext = await viewModel.latestImageGenerationResumeContext()
        let completedContext = try XCTUnwrap(persistedCompletedContext)
        XCTAssertEqual(completedContext.conversationID, completedOwner.conversationID.toHexDashString())
        XCTAssertEqual(completedContext.messageID, completedOwner.messageID)
        XCTAssertEqual(completedContext.toolCallID, "completed-image-tool")
        XCTAssertEqual(completedContext.state, .completed)

        let didSelectOwner = await restartedStore.selectConversationIfAvailable(
            id: completedOwner.conversationID
        )
        XCTAssertTrue(didSelectOwner)
        XCTAssertEqual(restartedStore.currentConversation?.id, completedOwner.conversationID)

        await restartedStore.deleteConversation(id: completedOwner.conversationID)
        let contextAfterOwnerDeletion = await viewModel.latestImageGenerationResumeContext()
        XCTAssertNil(contextAfterOwnerDeletion)
    }

    func testSaveMessagesToExplicitConversationDoesNotOverwriteCurrentConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.newConversation()
        let firstConversationId = try XCTUnwrap(store.currentConversation?.id)
        let firstMessages = [UIMessage.companion.user(prompt: "first conversation message")]
        await store.saveCurrent(messages: firstMessages)

        await store.newConversation()
        let secondConversationId = try XCTUnwrap(store.currentConversation?.id)

        let lateFirstMessages = [UIMessage.companion.user(prompt: "late first conversation update")]
        await store.save(messages: lateFirstMessages, to: firstConversationId)

        XCTAssertEqual(store.currentConversation?.id, secondConversationId)
        XCTAssertTrue(store.currentMessages.isEmpty)

        await store.selectConversation(id: firstConversationId)
        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["late first conversation update"])

        await store.selectConversation(id: secondConversationId)
        XCTAssertTrue(store.currentMessages.isEmpty)
    }

    /// 锁定 viewport 用来区分「真切换」与「同会话落盘」的修订号语义。
    /// 落盘/分支/重命名都不应 bump conversationSwitchedRevision,否则生成中的落盘会被
    /// ChatView 误当成切会话,重建 ScrollView → 抖动 + 上滑看历史被甩回锚点。
    func testConversationSwitchedRevisionOnlyBumpsOnRealSwitch() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreSwitchRevision-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()

        let baseline = store.conversationSwitchedRevision

        // 同会话落盘:不应 bump switchedRevision
        let convId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "first")])
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "同会话落盘不应 bump conversationSwitchedRevision")

        // 重命名:不应 bump
        await store.renameConversation(id: convId, title: "renamed")
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "重命名不应 bump conversationSwitchedRevision")

        // 真切换:newConversation 应 bump
        await store.newConversation()
        XCTAssertEqual(store.conversationSwitchedRevision, baseline + 1, "新建会话应 bump conversationSwitchedRevision")
        let afterNew = store.conversationSwitchedRevision

        // 切回旧会话:selectConversation 应 bump
        await store.selectConversation(id: convId)
        XCTAssertEqual(store.conversationSwitchedRevision, afterNew + 1, "selectConversation 应 bump conversationSwitchedRevision")

        // currentRevision 在所有这些操作中都应该增长(它是「内容可能变了」的粗信号)
        XCTAssertGreaterThan(store.currentRevision, baseline)
    }

    /// 回归防线:分支/编辑/删除消息/置顶都不得 bump conversationSwitchedRevision。
    /// 这些都是「同一会话内的内容变更」,若误 bump 会让生成中的编辑触发 ScrollView 重建 → 抖动。
    /// 同时验证 deleteConversation 删当前会话(真切换)必须 bump,删非当前会话不 bump。
    func testBranchAndDeleteOperationsDoNotBumpSwitchRevision() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreSwitchRevisionBranch-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        // bootstrap 在空 store 上必须 bump 一次(0 → 1),这是 UI 能感知首个会话的前提。
        await store.bootstrap()
        XCTAssertEqual(store.conversationSwitchedRevision, 1, "bootstrap 应把 conversationSwitchedRevision 从 0 bump 到 1")

        // 种入 [user, assistant] 一轮,作为分支操作的载体。
        await store.newConversation()  // 真切换 → bump
        let convId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "q"),
            UIMessage.companion.assistant(prompt: "a"),
        ])
        let baseline = store.conversationSwitchedRevision

        // 置顶:不应 bump
        await store.togglePin(id: convId)
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "togglePin 不应 bump conversationSwitchedRevision")

        // appendVariant(编辑/重生成原语):不应 bump
        _ = await store.appendVariant(messageIndex: 1, message: UIMessage.companion.assistant(prompt: "a2"))
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "appendVariant 不应 bump conversationSwitchedRevision")

        // selectVariant:不应 bump
        await store.selectVariant(messageIndex: 1, variantIndex: 1)
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "selectVariant 不应 bump conversationSwitchedRevision")

        // deleteMessage:不应 bump
        await store.deleteMessage(messageIndex: 1)
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "deleteMessage 不应 bump conversationSwitchedRevision")

        // truncateAfter:不应 bump
        await store.truncateAfter(messageIndex: 0)
        XCTAssertEqual(store.conversationSwitchedRevision, baseline, "truncateAfter 不应 bump conversationSwitchedRevision")

        // deleteConversation 删的是【当前】会话 → 回退到别的会话或新建,是真切换,必须 bump。
        await store.deleteConversation(id: convId)
        XCTAssertGreaterThan(
            store.conversationSwitchedRevision, baseline,
            "删除当前会话(回退到别的/新建)必须 bump conversationSwitchedRevision"
        )
    }

}
