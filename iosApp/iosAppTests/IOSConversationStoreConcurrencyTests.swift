import XCTest
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSConversationStoreConcurrencyTests: IOSConversationStoreTestCase {
    func testSecondBranchMutationIsRejectedWhileFirstReservedWriteIsSuspended() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "A"),
            UIMessage.companion.assistant(prompt: "B"),
            UIMessage.companion.user(prompt: "C"),
        ])
        let reachedReservation = expectation(description: "first branch reserved its write")
        var resumeWrite: CheckedContinuation<Void, Never>?
        store.afterPersistReservationForTesting = { _ in
            store.afterPersistReservationForTesting = nil
            reachedReservation.fulfill()
            await withCheckedContinuation { resumeWrite = $0 }
        }
        let first = Task { @MainActor in await store.deleteMessage(messageIndex: 0) }
        await fulfillment(of: [reachedReservation], timeout: 2)
        let secondSucceeded = await store.deleteMessage(messageIndex: 1)
        resumeWrite?.resume()
        let firstSucceeded = await first.value

        XCTAssertTrue(firstSucceeded)
        XCTAssertFalse(secondSucceeded, "a competing branch action must not report success before being overwritten")
        XCTAssertNotNil(store.lastUserVisibleError, "the user must be able to retry the rejected action")
        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["B", "C"])
        let restarted = IOSConversationStore(baseDirectory: directory)
        await restarted.bootstrap()
        XCTAssertEqual(restarted.currentMessages.map { $0.toText() }, ["B", "C"])
        let retried = await store.deleteMessage(messageIndex: 0)
        XCTAssertTrue(retried, "the rejected action must remain retryable after the original save ends")
        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["C"])
    }

    func testBranchMutationDoesNotRaceAReservedForegroundSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let base = UIMessage.companion.user(prompt: "base")
        await store.saveCurrent(messages: [base])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let reachedReservation = expectation(description: "foreground save reserved its write")
        var resumeWrite: CheckedContinuation<Void, Never>?
        store.afterPersistReservationForTesting = { _ in
            store.afterPersistReservationForTesting = nil
            reachedReservation.fulfill()
            await withCheckedContinuation { resumeWrite = $0 }
        }
        let foreground = Task { @MainActor in
            await store.save(messages: [base, UIMessage.companion.assistant(prompt: "new reply")], to: conversationId)
        }
        await fulfillment(of: [reachedReservation], timeout: 2)
        let deleted = await store.deleteMessage(messageIndex: 0)
        resumeWrite?.resume()
        let saved = await foreground.value

        XCTAssertTrue(saved)
        XCTAssertFalse(deleted, "a branch snapshot must not overwrite or be overwritten by an in-flight save")
        XCTAssertNotNil(store.lastUserVisibleError)
        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["base", "new reply"])
    }

    func testForegroundSaveIsRejectedWhileBranchMutationOwnsConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let base = UIMessage.companion.user(prompt: "base")
        let retained = UIMessage.companion.assistant(prompt: "retained")
        await store.saveCurrent(messages: [base, retained])
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let reachedReservation = expectation(description: "branch owns reserved snapshot")
        var resumeWrite: CheckedContinuation<Void, Never>?
        store.afterPersistReservationForTesting = { _ in
            store.afterPersistReservationForTesting = nil
            reachedReservation.fulfill()
            await withCheckedContinuation { resumeWrite = $0 }
        }
        let branch = Task { @MainActor in await store.deleteMessage(messageIndex: 0) }
        await fulfillment(of: [reachedReservation], timeout: 2)
        let saved = await store.save(messages: [base, retained, UIMessage.companion.user(prompt: "new")], to: conversationId)
        resumeWrite?.resume()
        let deleted = await branch.value

        XCTAssertTrue(deleted)
        XCTAssertFalse(saved, "a stale foreground snapshot cannot claim success while a branch owns the document")
        XCTAssertNotNil(store.lastUserVisibleError)
        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["retained"])
    }

    func testSendDuringBranchSavePreservesComposerDraftForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "existing")])
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        viewModel.reloadFromStore()
        viewModel.inputText = "draft survives"
        let reachedReservation = expectation(description: "branch save pending")
        var resumeWrite: CheckedContinuation<Void, Never>?
        store.afterPersistReservationForTesting = { _ in
            store.afterPersistReservationForTesting = nil
            reachedReservation.fulfill()
            await withCheckedContinuation { resumeWrite = $0 }
        }
        let branch = Task { @MainActor in await store.deleteMessage(messageIndex: 0) }
        await fulfillment(of: [reachedReservation], timeout: 2)
        let sent = viewModel.sendMessage()
        resumeWrite?.resume()
        _ = await branch.value

        XCTAssertFalse(sent)
        XCTAssertEqual(viewModel.inputText, "draft survives")
        XCTAssertEqual(viewModel.messages.map { $0.toText() }, ["existing"])
        XCTAssertNotNil(viewModel.configurationError)
    }

    func testDeleteTombstonePreventsInFlightForegroundSaveFromResurrectingConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreDeleteTombstoneForeground-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let deletedConversationId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "will be deleted")])

        await store.newConversation()
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "still alive")])

        let reachedPersist = expectation(description: "foreground save reached persist")
        var allowPersist: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { conversation in
            guard String(describing: conversation.id) == String(describing: deletedConversationId) else { return }
            reachedPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        let saveTask = Task { @MainActor in
            await store.save(
                messages: [
                    UIMessage.companion.user(prompt: "will be deleted"),
                    UIMessage.companion.assistant(prompt: "late foreground write"),
                ],
                to: deletedConversationId
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)
        await store.deleteConversation(id: deletedConversationId)
        store.beforePersistForTesting = nil
        allowPersist?.resume()
        let didSave = await saveTask.value
        XCTAssertFalse(didSave, "删除墓碑命中后，挂起中的前台 save 应报告未落盘")

        let restarted = IOSConversationStore(baseDirectory: baseDirectory)
        await restarted.bootstrap()
        XCTAssertFalse(
            restarted.summaries.contains { String(describing: $0.id) == String(describing: deletedConversationId) },
            "删除墓碑应阻止已进入 persist 前窗口的前台 save 复活会话文件"
        )
    }

    func testInFlightSaveDoesNotOverwriteConcurrentRenameTitle() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreRenameRace-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "old title seed")])

        let reachedPersist = expectation(description: "foreground save captured stale metadata")
        var allowPersist: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { conversation in
            guard String(describing: conversation.id) == String(describing: convId) else { return }
            reachedPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        let saveTask = Task { @MainActor in
            await store.save(
                messages: [
                    UIMessage.companion.user(prompt: "old title seed"),
                    UIMessage.companion.assistant(prompt: "late answer"),
                ],
                to: convId
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)

        await store.renameConversation(id: convId, title: "renamed while saving")
        store.beforePersistForTesting = nil
        allowPersist?.resume()
        let didSave = await saveTask.value
        XCTAssertTrue(didSave)
        XCTAssertEqual(store.currentConversation?.title, "renamed while saving")

        let restarted = IOSConversationStore(baseDirectory: baseDirectory)
        await restarted.bootstrap()
        XCTAssertEqual(
            restarted.summaries.first(where: { String(describing: $0.id) == String(describing: convId) })?.title,
            "renamed while saving",
            "已捕获旧 metadata 的复合 save 不应把并发 rename 的新标题反向覆盖回旧值"
        )
    }

    func testGeneratedTitleDoesNotOverwriteAUserRename() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreGeneratedTitleCAS-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "initial generated seed")])
        let generatedTitleBaseline = try XCTUnwrap(store.currentConversation?.title)

        await store.renameConversation(id: conversationId, title: "用户手工标题")
        let didRename = await store.renameConversation(
            id: conversationId,
            title: "迟到的自动标题",
            ifCurrentTitleMatches: generatedTitleBaseline
        )

        XCTAssertFalse(didRename)
        XCTAssertEqual(store.currentConversation?.title, "用户手工标题")
    }

    func testGeneratedTitleReplacesItsUnchangedBaseline() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreGeneratedTitleSuccess-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "initial generated seed")])
        let generatedTitleBaseline = try XCTUnwrap(store.currentConversation?.title)

        let didRename = await store.renameConversation(
            id: conversationId,
            title: "自动标题",
            ifCurrentTitleMatches: generatedTitleBaseline
        )

        XCTAssertTrue(didRename)
        XCTAssertEqual(store.currentConversation?.title, "自动标题")
    }

    func testDeleteTombstonePreventsInFlightBackgroundCompletionFromResurrectingConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreDeleteTombstoneBackground-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let deletedConversationId = try XCTUnwrap(store.currentConversation?.id)
        let baseMessages = [UIMessage.companion.user(prompt: "background base")]
        await store.saveCurrent(messages: baseMessages)

        await store.newConversation()
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "still alive")])

        let reachedPersist = expectation(description: "background completion reached persist")
        var allowPersist: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { conversation in
            guard String(describing: conversation.id) == String(describing: deletedConversationId) else { return }
            reachedPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        let completionTask = Task { @MainActor in
            await store.saveBackgroundCompletion(
                baseMessages: baseMessages,
                completedMessages: baseMessages + [UIMessage.companion.assistant(prompt: "late background write")],
                to: deletedConversationId
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)
        await store.deleteConversation(id: deletedConversationId)
        store.beforePersistForTesting = nil
        allowPersist?.resume()
        await completionTask.value

        let restarted = IOSConversationStore(baseDirectory: baseDirectory)
        await restarted.bootstrap()
        XCTAssertFalse(
            restarted.summaries.contains { String(describing: $0.id) == String(describing: deletedConversationId) },
            "删除墓碑应阻止已进入 persist 前窗口的后台 completion 复活会话文件"
        )
    }

    func testStaleSnapshotWriteBaselineDoesNotOverwriteNewerForegroundSave() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreWriteBaselineStaleSnapshot-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)
        let baseMessages = [UIMessage.companion.user(prompt: "cancel snapshot")]
        await store.saveCurrent(messages: baseMessages)

        let staleBaseline = store.writeBaseline(for: convId)
        let newerMessages = baseMessages + [UIMessage.companion.user(prompt: "new foreground message")]
        await store.save(messages: newerMessages, to: convId)

        let didSave = await store.save(
            messages: baseMessages + [UIMessage.companion.assistant(prompt: "late cancelled snapshot")],
            to: convId,
            ifUnchangedSince: staleBaseline
        )

        XCTAssertFalse(didSave, "序列号推进后，延迟取消快照不应覆盖同会话新消息")
        XCTAssertEqual(
            store.currentMessages.map { $0.toText() },
            ["cancel snapshot", "new foreground message"]
        )
        XCTAssertNil(store.lastIOError, "预期内的 stale snapshot skip 不应弹保存错误")
    }

    func testBackgroundCompletionWriteBaselineDoesNotOverwriteForegroundMessage() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreWriteBaselineBackground-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)
        let baseMessages = [UIMessage.companion.user(prompt: "background base")]
        await store.saveCurrent(messages: baseMessages)

        let reachedPersist = expectation(description: "background completion reached persist")
        var allowPersist: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { conversation in
            guard String(describing: conversation.id) == String(describing: convId) else { return }
            reachedPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        let completionTask = Task { @MainActor in
            await store.saveBackgroundCompletion(
                baseMessages: baseMessages,
                completedMessages: baseMessages + [UIMessage.companion.assistant(prompt: "late background result")],
                to: convId
            )
        }
        await fulfillment(of: [reachedPersist], timeout: 2)

        store.beforePersistForTesting = nil
        let foregroundMessages = baseMessages + [UIMessage.companion.user(prompt: "new foreground message")]
        await store.save(messages: foregroundMessages, to: convId)
        allowPersist?.resume()
        let didSave = await completionTask.value

        XCTAssertTrue(didSave)
        XCTAssertEqual(
            store.currentMessages.map { $0.toText() },
            [
                "background base",
                "new foreground message",
                IOSAppLocalization.string("后台生成已完成；当前会话期间已有新内容，以下是后台完成的结果。"),
                "late background result",
            ],
            "前台新消息落盘后，后台重试应保留前台内容并把生成结果显式合并，而不是用旧快照覆盖"
        )
        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.contains(String(describing: convId)),
            "后台结果重试合并成功后应发布当前会话的后台内容通知"
        )
    }

    func testBackgroundMessageReplacementPreservesConcurrentMessages() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreBackgroundMessagePatch-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let user = UIMessage.companion.user(prompt: "生成小应用")
        let generated = UIMessage.companion.assistant(prompt: "已生成小应用")
        await store.saveCurrent(messages: [user, generated])

        let foreground = UIMessage.companion.user(prompt: "后台运行期间的新消息")
        await store.saveCurrent(messages: [user, generated, foreground])
        let replacement = UIMessage(
            id: generated.id,
            role: generated.role,
            parts: [UIMessagePart.Text(text: "已生成小应用\nWorkspace 同步失败", metadata: nil)],
            annotations: generated.annotations,
            createdAt: generated.createdAt,
            finishedAt: generated.finishedAt,
            modelId: generated.modelId,
            usage: generated.usage,
            translation: generated.translation
        )

        let didReplace = await store.replaceBackgroundMessage(replacement, in: conversationId)
        XCTAssertTrue(didReplace)
        XCTAssertEqual(
            store.currentMessages.map { $0.toText() },
            ["生成小应用", "已生成小应用\nWorkspace 同步失败", "后台运行期间的新消息"]
        )
    }

    func testBackgroundCompletionRetriesAfterForegroundWriteAndKeepsResult() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreBackgroundRetryAfterForeground-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)
        let baseMessages = [UIMessage.companion.user(prompt: "background base")]
        await store.saveCurrent(messages: baseMessages)

        let reachedFirstPersist = expectation(description: "background completion reached first stale persist")
        var allowPersist: CheckedContinuation<Void, Never>?
        var didBlockFirstAttempt = false
        store.beforePersistForTesting = { conversation in
            guard String(describing: conversation.id) == String(describing: convId),
                  !didBlockFirstAttempt else { return }
            didBlockFirstAttempt = true
            reachedFirstPersist.fulfill()
            await withCheckedContinuation { continuation in
                allowPersist = continuation
            }
        }

        let completionTask = Task { @MainActor in
            await store.saveBackgroundCompletion(
                baseMessages: baseMessages,
                completedMessages: baseMessages + [UIMessage.companion.assistant(prompt: "late background result")],
                to: convId
            )
        }
        await fulfillment(of: [reachedFirstPersist], timeout: 2)

        store.beforePersistForTesting = nil
        await store.save(messages: baseMessages + [UIMessage.companion.user(prompt: "new foreground message")], to: convId)
        allowPersist?.resume()
        await completionTask.value

        XCTAssertEqual(
            store.currentMessages.map { $0.toText() },
            [
                "background base",
                "new foreground message",
                IOSAppLocalization.string("后台生成已完成；当前会话期间已有新内容，以下是后台完成的结果。"),
                "late background result",
            ],
            "后台回复的旧 baseline 被拒后应以新 baseline 重试并合并为 notice，而不是凭空消失"
        )
        XCTAssertTrue(store.pendingBackgroundContentConversationIds.contains(String(describing: convId)))
        XCTAssertNil(store.lastIOError)
    }

}
