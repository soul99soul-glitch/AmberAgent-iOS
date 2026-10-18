import XCTest
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSConversationStorePersistenceTests: IOSConversationStoreTestCase {
    func testScreenshotDataURLsLiveInBlobsAndBackupsStaySelfContained() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreBlobs-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var bytes = [UInt8](repeating: 0, count: 40_000)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
        let payload = Data(bytes).base64EncodedString()
        let dataURL = "data:image/png;base64," + payload
        let screenshot = UIMessage(
            id: KotlinUuid.companion.random(), role: .assistant,
            parts: [UIMessagePart.Image(url: dataURL, metadata: nil)],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 10, day: 16, hour: 0, minute: 0, second: 0, nanosecond: 0),
            finishedAt: nil, modelId: nil, usage: nil, translation: nil
        )
        func imageURLs(_ store: IOSConversationStore) -> [String] {
            store.currentMessages.flatMap { $0.parts }.compactMap { ($0 as? UIMessagePart.Image)?.url }
        }

        let store = IOSConversationStore(baseDirectory: source)
        await store.bootstrap()
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "shot"), screenshot])
        let id = try XCTUnwrap(store.currentConversation?.id)

        // On disk: small JSON with a reference, decoded bytes in the blob directory.
        let raw = try String(contentsOf: source.appendingPathComponent("\(id).json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("amber-blob://"))
        XCTAssertFalse(raw.contains(String(payload.prefix(512))))
        let blobDirectory = source.appendingPathComponent("\(id).blobs")
        let blobs = try FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(try Data(contentsOf: blobDirectory.appendingPathComponent(blobs[0])), Data(bytes))

        // Upper layers still see the exact inline data URL after a restart.
        let restarted = IOSConversationStore(baseDirectory: source)
        await restarted.bootstrap()
        await restarted.selectConversation(id: id)
        XCTAssertEqual(imageURLs(restarted), [dataURL])

        // Backups inline the blob so they restore anywhere (including older versions).
        let zip = try XCTUnwrap(IOSSyncBackup.conversationsZip(fromDirectory: source))
        let documents = try IOSSyncBackup.conversationDocuments(zipData: zip)
        XCTAssertEqual(documents.count, 1)
        XCTAssertTrue(documents[0].contains(dataURL))
        XCTAssertFalse(documents[0].contains("amber-blob://"))

        let destination = IOSConversationStore(baseDirectory: target)
        await destination.bootstrap()
        _ = try await destination.importConversationDocuments(documents)
        await destination.selectConversation(id: id)
        XCTAssertEqual(imageURLs(destination), [dataURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("\(id).blobs").path))

        // Corrupt or unreadable blobs fail backup; the store keeps a detectable
        // placeholder and the original reference.
        let blobURL = blobDirectory.appendingPathComponent(blobs[0])
        let blobBytes = try Data(contentsOf: blobURL)
        var changedBytes = blobBytes
        changedBytes[changedBytes.startIndex] ^= 1
        for corruptBytes in [changedBytes, Data()] {
            try corruptBytes.write(to: blobURL)
            XCTAssertThrowsError(try IOSSyncBackup.conversationsZip(fromDirectory: source))
            let corrupted = IOSConversationStore(baseDirectory: source)
            await corrupted.bootstrap()
            await corrupted.selectConversation(id: id)
            let image = try XCTUnwrap(
                corrupted.currentMessages.flatMap { $0.parts }.compactMap { $0 as? UIMessagePart.Image }.first
            )
            XCTAssertTrue(image.isMissingBlobPlaceholder())
            XCTAssertNotNil(image.metadata?[ConversationBlobsKt.MISSING_BLOB_METADATA_KEY])
        }
        try FileManager.default.removeItem(at: blobURL)
        try FileManager.default.createDirectory(at: blobURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try IOSSyncBackup.conversationsZip(fromDirectory: source))
        let unreadable = IOSConversationStore(baseDirectory: source)
        await unreadable.bootstrap()
        await unreadable.selectConversation(id: id)
        let placeholder = try XCTUnwrap(
            unreadable.currentMessages.flatMap { $0.parts }.compactMap { $0 as? UIMessagePart.Image }.first
        )
        XCTAssertTrue(placeholder.isMissingBlobPlaceholder())
        XCTAssertNotNil(placeholder.metadata?[ConversationBlobsKt.MISSING_BLOB_METADATA_KEY])
        try FileManager.default.removeItem(at: blobURL)
        try blobBytes.write(to: blobURL)

        // Deleting the conversation removes its blobs.
        let deleted = await restarted.deleteConversation(id: id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobDirectory.path))
    }

    func testSendMessagePersistsAcrossStoreRestart() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStorePhase2Acceptance-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let firstStore = IOSConversationStore(baseDirectory: baseDirectory)
        await firstStore.bootstrap()
        let firstConversationId = try XCTUnwrap(firstStore.currentConversation?.id)

        let firstViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        firstViewModel.conversationStore = firstStore
        firstViewModel.reloadFromStore()
        firstViewModel.inputText = "phase2 persistence acceptance"
        firstViewModel.sendMessage()

        let didPersistBeforeRestart = await waitFor {
            firstStore.currentMessages.map { $0.toText() } == ["phase2 persistence acceptance"]
        }
        XCTAssertTrue(didPersistBeforeRestart)

        let restartedStore = IOSConversationStore(baseDirectory: baseDirectory)
        await restartedStore.bootstrap()
        XCTAssertEqual(restartedStore.currentConversation?.id, firstConversationId)

        let restartedViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        restartedViewModel.conversationStore = restartedStore
        restartedViewModel.reloadFromStore()

        XCTAssertEqual(restartedViewModel.messages.map { $0.toText() }, ["phase2 persistence acceptance"])
    }

    func testSelectedFileContextPersistsAcrossStoreRestart() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreFileContext-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let firstStore = IOSConversationStore(baseDirectory: baseDirectory)
        await firstStore.bootstrap()
        let firstConversationId = try XCTUnwrap(firstStore.currentConversation?.id)

        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(text: "Persistent selected file body"))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let firstViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        firstViewModel.conversationStore = firstStore
        firstViewModel.reloadFromStore()

        await firstViewModel.attachSelectedFilePreviewToNextMessage()
        firstViewModel.inputText = "Use this file"
        firstViewModel.sendMessage()

        let didPersistBeforeRestart = await waitFor {
            firstStore.currentMessages.first?.toText().contains("[文件上下文]") == true
        }
        XCTAssertTrue(didPersistBeforeRestart)

        let restartedStore = IOSConversationStore(baseDirectory: baseDirectory)
        await restartedStore.bootstrap()
        XCTAssertEqual(restartedStore.currentConversation?.id, firstConversationId)

        let restartedViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        restartedViewModel.conversationStore = restartedStore
        restartedViewModel.reloadFromStore()

        let text = try XCTUnwrap(restartedViewModel.messages.first?.toText())
        XCTAssertTrue(text.contains("Use this file"))
        XCTAssertTrue(text.contains("[文件上下文]"))
        XCTAssertTrue(text.contains("来源文件："))
        XCTAssertTrue(text.contains("Persistent selected file body"))
    }

    func testCurrentConversationCanBecomeDeepReadSourceAndReceiveResult() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreDeepRead-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "请深度阅读这个搜索结果"),
            UIMessage.companion.assistant(prompt: "可以，先整理来源和关键问题。")
        ])

        let source = try store.currentConversationDeepReadSource()
        XCTAssertEqual(source.kind, .conversation)
        XCTAssertTrue(source.content.contains("请深度阅读"))

        let deepReadStore = IOSDeepReadStore(baseDirectory: baseDirectory)
        let task = try deepReadStore.createTask(title: "会话深读", sources: [source])
        deepReadStore.complete(id: task.id, markdown: "# 会话深读\n\n结果")
        let saved = await store.appendDeepReadResultToCurrentConversation(try XCTUnwrap(deepReadStore.task(id: task.id)))

        XCTAssertTrue(saved)
        XCTAssertTrue(store.currentMessages.map { $0.toText() }.joined(separator: "\n").contains("已保存深度阅读结果"))
        XCTAssertTrue(store.currentMessages.map { $0.toText() }.joined(separator: "\n").contains("# 会话深读"))
    }

    /// P2.5 回归防线:后台生成/工具回填落盘必须 bump 定向的 backgroundContentRevision +
    /// 把目标会话 id 加入 pendingBackgroundContentConversationIds,但绝不能碰
    /// conversationSwitchedRevision(否则会复发"每次落盘重灌历史"的甩回老 bug)。
    /// 同时锁定普通前台落盘(saveCurrent/save)不得触碰这个定向信号。
    func testBackgroundCompletionBumpsDirectedSignalWithoutTouchingSwitchRevision() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreBackgroundCompletion-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)

        let baseMessages = [UIMessage.companion.user(prompt: "q")]
        await store.saveCurrent(messages: baseMessages)

        // 基线:先确认普通前台落盘(saveCurrent)不碰 backgroundContentRevision。
        XCTAssertEqual(store.backgroundContentRevision, 0, "普通前台落盘不应 bump backgroundContentRevision")
        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.isEmpty,
            "普通前台落盘不应往 pendingBackgroundContentConversationIds 塞任何 id"
        )

        let switchBaseline = store.conversationSwitchedRevision

        // 1) saveBackgroundCompletion 成功落盘后:backgroundContentRevision +1、
        //    pendingBackgroundContentConversationIds 含目标会话、conversationSwitchedRevision 不变。
        let completedMessages = baseMessages + [UIMessage.companion.assistant(prompt: "背景生成结果")]
        await store.saveBackgroundCompletion(
            baseMessages: baseMessages,
            completedMessages: completedMessages,
            to: convId
        )
        XCTAssertEqual(store.backgroundContentRevision, 1, "saveBackgroundCompletion 应 bump backgroundContentRevision")
        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.contains(String(describing: convId)),
            "saveBackgroundCompletion 应把目标会话加入 pendingBackgroundContentConversationIds"
        )
        XCTAssertEqual(
            store.conversationSwitchedRevision, switchBaseline,
            "saveBackgroundCompletion 不应 bump conversationSwitchedRevision"
        )
        XCTAssertEqual(store.currentMessages.map { $0.toText() }, ["q", "背景生成结果"])

        // 2) saveBackgroundToolCompletion 同上验证。
        let baseMessages2 = store.currentMessages
        let completedMessages2 = baseMessages2 + [UIMessage.companion.assistant(prompt: "工具回填结果")]
        await store.saveBackgroundToolCompletion(
            baseMessages: baseMessages2,
            completedMessages: completedMessages2,
            to: convId
        )
        XCTAssertEqual(store.backgroundContentRevision, 2, "saveBackgroundToolCompletion 应再次 bump backgroundContentRevision")
        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.contains(String(describing: convId)),
            "saveBackgroundToolCompletion 应把目标会话加入 pendingBackgroundContentConversationIds"
        )
        XCTAssertEqual(
            store.conversationSwitchedRevision, switchBaseline,
            "saveBackgroundToolCompletion 不应 bump conversationSwitchedRevision"
        )

        // 3) 再来一次普通前台落盘(save(messages:to:)):backgroundContentRevision 不应继续增长。
        await store.save(messages: store.currentMessages + [UIMessage.companion.user(prompt: "foreground edit")], to: convId)
        XCTAssertEqual(store.backgroundContentRevision, 2, "普通前台 save(messages:to:) 不应继续 bump backgroundContentRevision")
    }

    func testBackgroundToolCompletionPatchesExistingToolCallAndPreservesForegroundMessages() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreBackgroundToolParity-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)

        let user = UIMessage.companion.user(prompt: "查一下 amber")
        let pendingTool = assistantToolMessage()
        let baseMessages = [user, pendingTool]
        await store.saveCurrent(messages: baseMessages)

        let foreground = UIMessage.companion.user(prompt: "同时补一句前台消息")
        await store.saveCurrent(messages: baseMessages + [foreground])

        let completedTool = assistantToolMessage(output: [
            UIMessagePart.Text(text: "{\"result\":\"done\"}", metadata: nil)
        ])
        await store.saveBackgroundToolCompletion(
            baseMessages: baseMessages,
            completedMessages: [user, completedTool],
            to: convId
        )

        XCTAssertEqual(store.currentMessages.count, 3)
        XCTAssertEqual(store.currentMessages[0].toText(), "查一下 amber")
        XCTAssertEqual(store.currentMessages[2].toText(), "同时补一句前台消息")
        let tool = store.currentMessages[1].parts.compactMap { $0 as? UIMessagePart.Tool }.first
        let output = tool?.output.compactMap { $0 as? UIMessagePart.Text }.first?.text
        XCTAssertEqual(output, "{\"result\":\"done\"}")
        XCTAssertFalse(
            store.currentMessages.map { $0.toText() }.contains { $0.contains("后台工具执行已完成") },
            "能原地补齐 tool output 时不应追加 notice 气泡"
        )
    }

    func testBackgroundSaveReportsFailureAfterConversationWasDeleted() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreBackgroundSaveResult-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let deletedId = try XCTUnwrap(store.currentConversation?.id)
        let baseMessages = [UIMessage.companion.user(prompt: "base")]
        await store.saveCurrent(messages: baseMessages)
        await store.deleteConversation(id: deletedId)

        let completionSaved = await store.saveBackgroundCompletion(
            baseMessages: baseMessages,
            completedMessages: baseMessages + [UIMessage.companion.assistant(prompt: "late")],
            to: deletedId
        )
        let toolSaved = await store.saveBackgroundToolCompletion(
            baseMessages: baseMessages,
            completedMessages: baseMessages,
            to: deletedId
        )

        XCTAssertFalse(completionSaved)
        XCTAssertFalse(toolSaved)
    }

    func testDeleteFailureDoesNotCommitOwnerCleanupOrSwitchConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreDeleteFailure-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        store.beforeDeleteForTesting = {
            throw NSError(domain: "IOSConversationStoreTests", code: 1)
        }
        var didCommitOwnerCleanup = false

        let didDelete = await store.deleteConversation(id: conversationId) { _ in
            didCommitOwnerCleanup = true
        }

        XCTAssertFalse(didDelete)
        XCTAssertFalse(didCommitOwnerCleanup)
        XCTAssertEqual(store.currentConversation?.id, conversationId)
        XCTAssertTrue(store.summaries.contains(where: { $0.id == conversationId }))
    }

    /// 观察合并丢通知防线:两会话在同一 tick 先后落盘时,单值信号会被后落盘的覆盖,
    /// 先落的那个会话丢失通知。集合语义天然免疫——两个 id 都应留在待通知集合里。
    func testPendingBackgroundContentConversationIdsSurvivesSameTickMultiConversationLanding() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStorePendingMerge-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let firstConvId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q1")])

        await store.newConversation()
        let secondConvId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q2")])

        // 会话一先落盘后台完成。
        await store.saveBackgroundCompletion(
            baseMessages: [UIMessage.companion.user(prompt: "q1")],
            completedMessages: [UIMessage.companion.user(prompt: "q1"), UIMessage.companion.assistant(prompt: "a1")],
            to: firstConvId
        )
        // 会话二紧接着（同 tick）落盘后台完成。
        await store.saveBackgroundCompletion(
            baseMessages: [UIMessage.companion.user(prompt: "q2")],
            completedMessages: [UIMessage.companion.user(prompt: "q2"), UIMessage.companion.assistant(prompt: "a2")],
            to: secondConvId
        )

        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.contains(String(describing: firstConvId)),
            "先落盘的会话一不应被后落盘的会话二覆盖丢失"
        )
        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.contains(String(describing: secondConvId)),
            "后落盘的会话二也应保留在待通知集合里"
        )
    }

    /// consumeBackgroundContentNotification 只应移除指定会话的待通知状态,不得误清其他会话。
    func testConsumeBackgroundContentNotificationOnlyRemovesSpecifiedConversation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreConsumeSelective-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let firstConvId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q1")])

        await store.newConversation()
        let secondConvId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q2")])

        await store.saveBackgroundCompletion(
            baseMessages: [UIMessage.companion.user(prompt: "q1")],
            completedMessages: [UIMessage.companion.user(prompt: "q1"), UIMessage.companion.assistant(prompt: "a1")],
            to: firstConvId
        )
        await store.saveBackgroundCompletion(
            baseMessages: [UIMessage.companion.user(prompt: "q2")],
            completedMessages: [UIMessage.companion.user(prompt: "q2"), UIMessage.companion.assistant(prompt: "a2")],
            to: secondConvId
        )

        store.consumeBackgroundContentNotification(for: String(describing: firstConvId))

        XCTAssertFalse(
            store.pendingBackgroundContentConversationIds.contains(String(describing: firstConvId)),
            "consume 应移除指定会话的待通知状态"
        )
        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.contains(String(describing: secondConvId)),
            "consume 不应误清其他会话的待通知状态"
        )
    }

    /// 负向锁:普通前台落盘(saveCurrent/save)绝不能往 pendingBackgroundContentConversationIds 塞 id,
    /// 否则会误触发 ChatView 的后台内容上屏路径。
    func testForegroundSaveDoesNotPopulatePendingBackgroundContentConversationIds() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStoreForegroundNoPending-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let convId = try XCTUnwrap(store.currentConversation?.id)

        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q")])
        await store.save(messages: [UIMessage.companion.user(prompt: "q"), UIMessage.companion.assistant(prompt: "a")], to: convId)

        XCTAssertTrue(
            store.pendingBackgroundContentConversationIds.isEmpty,
            "普通前台落盘不应往 pendingBackgroundContentConversationIds 塞任何 id"
        )
    }

}
