import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P1-a: 生成中 steer 消息队列（对齐 Android `ChatService.enqueuePendingUserMessage`
/// + `ConversationSession` 的 STEER 语义，MAX_PENDING_USER_MESSAGES = 20）。
///
/// 契约：
/// 1. 生成激活期间 composer 发送不再被 `.generationActive` 拦截，改为入队（不直接发）。
/// 2. 工具循环边界消费：出队全部排队消息 → 真实 user 消息上屏 + 持久化进会话
///    + 折入下一轮 upload。
/// 3. 撤销同步删 sidecar 文件条目（exactly once）。
/// 4. 队列满（20）时发送回到禁用态（`.steerQueueFull`）。
/// 5. run 成功终态自动发队列头一条；取消/失败才回填 composer（含附件留队）。
/// 6. sidecar store 往返 + 冷启动（新实例读同一路径）恢复；不同会话不串。
/// 7. 生成中可带图/选中文件入队；drain 折入 Image parts；旧纯文本 sidecar 仍可读。
@MainActor
final class IOSSteerQueueTests: XCTestCase {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "IOSSteerQueueTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeTempDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeConversationStore(directory: URL) -> IOSConversationStore {
        let store = IOSConversationStore(baseDirectory: directory)
        return store
    }

    private func makeViewModel(
        conversationStore: IOSConversationStore,
        queueDirectory: URL
    ) -> ChatViewModel {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false,
            steerQueueStore: IOSSteerQueueStore(directoryURL: queueDirectory)
        )
        viewModel.conversationStore = conversationStore
        viewModel.reloadFromStore()
        return viewModel
    }

    /// 轮询等待 drain 的异步会话落盘完成（drain 的 persist 走 fire-and-forget Task，
    /// 与 appendUserMessage 同一模式）。
    private func pollPersistedUserTexts(
        store: IOSConversationStore,
        conversationId: KotlinUuid,
        minUserMessages: Int,
        timeout: TimeInterval = 5
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String] = []
        while Date() < deadline {
            let messages = await store.messages(for: conversationId) ?? []
            last = messages.filter { $0.role == MessageRole.user }.map { $0.toText() }
            if last.count >= minUserMessages { return last }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return last
    }

    // MARK: - 1. 生成中 send → 入队（不直接发）

    func testSendDuringGenerationEnqueuesInsteadOfSending() async throws {
        let base = makeTempDirectory("SteerQueueEnqueue")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "继续搜索"
        XCTAssertTrue(viewModel.sendMessage())

        // 入队：不直接发，messages 无新增 user 节点。
        XCTAssertEqual(viewModel.steerQueue.count, 1)
        XCTAssertEqual(viewModel.steerQueue.first?.text, "继续搜索")
        XCTAssertEqual(viewModel.messages.filter { $0.role == MessageRole.user }.count, 0)
        XCTAssertTrue(viewModel.inputText.isEmpty, "发送后输入框应清空")

        // 发送按钮不再被 generationActive 拦截（队列条可见状态由 steerQueue 驱动）。
        XCTAssertNil(viewModel.composerSendBlockReason(for: "再排一条"))
    }

    // MARK: - 2. 工具循环边界消费

    func testToolLoopBoundaryConsumptionFoldsQueuedMessagesIntoNextRoundUpload() async throws {
        let base = makeTempDirectory("SteerQueueBoundary")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "第一句排队"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.inputText = "第二句排队"
        XCTAssertTrue(viewModel.sendMessage())

        // 模拟工具结果轮：continueAfterToolResult 边界消费（mailbox 先于 steer；
        // 本测试无信封，mailbox drain 为空，行为与 P1-a 一致）。
        let baseMessages = [UIMessage.companion.assistant(prompt: "工具结果")]
        let nextRoundUpload = await viewModel.nextRoundMessagesAfterMailboxAndSteerConsumptionForTesting(
            baseMessages: baseMessages
        )

        // 下一轮 upload 含排队文本（顺序保持）。
        let uploadUserTexts = nextRoundUpload
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertEqual(uploadUserTexts, ["第一句排队", "第二句排队"])

        // 队列清空。
        XCTAssertTrue(viewModel.steerQueue.isEmpty)

        // 会话内存出现 user 节点。
        let memoryUserTexts = viewModel.messages
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertEqual(memoryUserTexts, ["第一句排队", "第二句排队"])

        // 会话持久化出 user 消息节点（exactly once：出队即落盘）。
        let persisted = try await pollPersistedUserTexts(
            store: store,
            conversationId: conversationId,
            minUserMessages: 2
        )
        XCTAssertEqual(persisted, ["第一句排队", "第二句排队"])

        // sidecar 文件同步清空。
        let coldStore = IOSSteerQueueStore(directoryURL: base)
        XCTAssertTrue(coldStore.load(conversationId: conversationId).isEmpty)
    }

    // MARK: - 3. 撤销

    func testRemovingQueuedMessageDeletesItFromSidecarStore() async throws {
        let base = makeTempDirectory("SteerQueueRemove")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "排队甲"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.inputText = "排队乙"
        XCTAssertTrue(viewModel.sendMessage())

        let first = try XCTUnwrap(viewModel.steerQueue.first)
        viewModel.removeSteerMessage(id: first.id)

        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["排队乙"])
        let fresh = IOSSteerQueueStore(directoryURL: base).load(conversationId: conversationId)
        XCTAssertEqual(fresh.map(\.text), ["排队乙"], "撤销后 sidecar 应同步删除该条目")

        viewModel.removeSteerMessage(id: viewModel.steerQueue[0].id)
        XCTAssertTrue(viewModel.steerQueue.isEmpty)
        XCTAssertTrue(
            IOSSteerQueueStore(directoryURL: base).load(conversationId: conversationId).isEmpty,
            "队列清空时 sidecar 文件应删除"
        )
    }

    // MARK: - 4. 上限

    func testQueueFullRejectsSendWithBlockReason() async throws {
        let base = makeTempDirectory("SteerQueueFull")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        for index in 0..<IOSSteerQueueStore.maxPendingUserMessages {
            viewModel.inputText = "排队消息 \(index)"
            XCTAssertTrue(viewModel.sendMessage())
        }
        XCTAssertEqual(viewModel.steerQueue.count, IOSSteerQueueStore.maxPendingUserMessages)

        // 满时：发送按钮回到禁用态（block reason），send 拒绝。
        XCTAssertEqual(
            viewModel.composerSendBlockReason(for: "再来一条"),
            .steerQueueFull
        )
        XCTAssertFalse(viewModel.sendMessage())
        XCTAssertEqual(viewModel.steerQueue.count, IOSSteerQueueStore.maxPendingUserMessages)
    }

    // MARK: - 5. run 成功终态 → 自动发下一条；取消/失败 → 回填 composer

    func testRunTerminalAutoSendsNextQueuedMessage() async throws {
        let base = makeTempDirectory("SteerQueueTerminal")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "先排队的一条"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.inputText = "再排队的一条"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil

        viewModel.handleSteerQueueAtRunTerminal(for: conversationId, autoContinue: true)
        await viewModel.currentRun.state.steerQueueAutoContinueTask?.value

        // 成功终态：头一条上屏发出；下一条仍留队列；不回填 composer。
        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.map { $0.toText() },
            ["先排队的一条"]
        )
        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["再排队的一条"])
    }

    func testRunCancelRestoresLeftoverToComposerInOrder() async throws {
        let base = makeTempDirectory("SteerQueueCancelRestore")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "先排队的一条"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.inputText = "再排队的一条"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil

        viewModel.handleSteerQueueAtRunTerminal(
            for: store.currentConversation?.id,
            autoContinue: false
        )

        XCTAssertEqual(viewModel.inputText, "先排队的一条\n再排队的一条")
        XCTAssertTrue(viewModel.steerQueue.isEmpty)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            0
        )
    }

    /// 无边界场景的另一面：run 期间（未到工具边界）队列保持不动。
    func testQueueIsUntouchedUntilBoundaryOrTerminal() async throws {
        let base = makeTempDirectory("SteerQueueUntouched")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "排队中"
        XCTAssertTrue(viewModel.sendMessage())

        // 未调用任何边界消费：队列原样保留。
        XCTAssertEqual(viewModel.steerQueue.count, 1)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            0,
            "无工具边界的 run 不消费队列"
        )
    }

    // MARK: - 6. store 往返 + 冷启动恢复

    func testStoreRoundTripAndColdStartRestore() async throws {
        let base = makeTempDirectory("SteerQueueStoreRoundTrip")
        defer { try? FileManager.default.removeItem(at: base) }
        let conversationIdA = KotlinUuid.companion.random()
        let conversationIdB = KotlinUuid.companion.random()
        let entries = [
            IOSSteerQueueEntry(id: "entry-1", text: "冷启动排队一", createdAt: Date(timeIntervalSince1970: 100)),
            IOSSteerQueueEntry(id: "entry-2", text: "冷启动排队二", createdAt: Date(timeIntervalSince1970: 200)),
        ]

        let firstStore = IOSSteerQueueStore(directoryURL: base)
        firstStore.persist(entries, for: conversationIdA)

        // 冷启动：新实例读同一路径。
        let secondStore = IOSSteerQueueStore(directoryURL: base)
        XCTAssertEqual(secondStore.load(conversationId: conversationIdA), entries)

        // 不同会话不串。
        XCTAssertTrue(secondStore.load(conversationId: conversationIdB).isEmpty)

        // 空队列删文件。
        secondStore.persist([], for: conversationIdA)
        XCTAssertTrue(secondStore.load(conversationId: conversationIdA).isEmpty)
    }

    /// 冷启动恢复的会话级路径：打开会话时队列重新出现（不自动发送）。
    func testConversationReopenRestoresQueueFromStore() async throws {
        let base = makeTempDirectory("SteerQueueReopen")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)

        // 模拟进程被杀后的遗留文件：先直写 sidecar。
        let seedStore = IOSSteerQueueStore(directoryURL: base)
        seedStore.persist(
            [IOSSteerQueueEntry(id: "cold-1", text: "被杀前的排队消息", createdAt: Date())],
            for: conversationId
        )

        // 新 ViewModel（冷启动）：reloadFromStore 时队列重新出现，不自动发送。
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)
        await viewModel.steerQueueLoadTask?.value
        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["被杀前的排队消息"])
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            0,
            "恢复只进队列 UI，不自动发送"
        )
    }

    /// 发送键 stop/send 状态矩阵：run 激活且发送被拦截时（队列满）必须保持停止键。
    func testComposerSendButtonStopModeMatrix() {
        // 无 run：永不 stop（走普通发送逻辑）。
        XCTAssertFalse(ChatView.composerSendButtonIsStopMode(
            isRunActive: false, isRecognizingImages: false, hasSendableContent: true, sendEnabled: true
        ))
        // run + 无可入队内容：停止。
        XCTAssertTrue(ChatView.composerSendButtonIsStopMode(
            isRunActive: true, isRecognizingImages: false, hasSendableContent: false, sendEnabled: false
        ))
        // run + 可入队（文本/图/文件）：发送（加入队列），非 stop。
        XCTAssertFalse(ChatView.composerSendButtonIsStopMode(
            isRunActive: true, isRecognizingImages: false, hasSendableContent: true, sendEnabled: true
        ))
        // run + 队列满（发送被拦截）：必须保持 stop。
        XCTAssertTrue(ChatView.composerSendButtonIsStopMode(
            isRunActive: true, isRecognizingImages: false, hasSendableContent: true, sendEnabled: false
        ))
        // 识图中：恒 stop。
        XCTAssertTrue(ChatView.composerSendButtonIsStopMode(
            isRunActive: false, isRecognizingImages: true, hasSendableContent: true, sendEnabled: true
        ))
    }

    // MARK: - 7. 图/附件入队

    func testSendWithImageDuringGenerationEnqueuesAttachments() async throws {
        let base = makeTempDirectory("SteerQueueImageEnqueue")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        let preview = Data("preview".utf8)
        let dataUrl = "data:image/png;base64,aaa"
        viewModel.addPendingImage(dataUrl: dataUrl, previewData: preview)
        viewModel.inputText = "看看这张图"
        XCTAssertNil(viewModel.composerSendBlockReason(for: "看看这张图"))
        XCTAssertTrue(viewModel.sendMessage())

        XCTAssertEqual(viewModel.steerQueue.count, 1)
        let entry = try XCTUnwrap(viewModel.steerQueue.first)
        XCTAssertEqual(entry.text, "看看这张图")
        XCTAssertEqual(entry.images.count, 1)
        XCTAssertEqual(entry.images.first?.dataUrl, dataUrl)
        XCTAssertTrue(viewModel.pendingImages.isEmpty, "入队后应清空 composer 附件")
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.count,
            0,
            "入队不上屏"
        )

        // sidecar 往返保留图片。
        let cold = IOSSteerQueueStore(directoryURL: base).load(conversationId: conversationId)
        XCTAssertEqual(cold.first?.images.first?.dataUrl, dataUrl)
    }

    func testDrainSteerQueueFoldsImagePartsIntoUserMessage() async throws {
        let base = makeTempDirectory("SteerQueueImageDrain")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.addPendingImage(dataUrl: "data:image/jpeg;base64,bbb", previewData: Data("p".utf8))
        viewModel.inputText = "带图插话"
        XCTAssertTrue(viewModel.sendMessage())

        let drained = await viewModel.drainSteerQueue(conversationId: store.currentConversation?.id)
        XCTAssertEqual(drained.count, 1)
        let parts = drained[0].parts
        XCTAssertTrue(parts.contains { $0 is UIMessagePart.Text })
        XCTAssertTrue(parts.contains { $0 is UIMessagePart.Image })
        XCTAssertTrue(viewModel.steerQueue.isEmpty)
    }

    func testTerminalKeepsAttachmentLeftoverInQueue() async throws {
        let base = makeTempDirectory("SteerQueueImageTerminal")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.addPendingImage(dataUrl: "data:image/png;base64,ccc", previewData: Data("q".utf8))
        viewModel.inputText = "终态勿丢图"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil

        // 取消/失败路径：含附件 leftover 不拼回 composer，留在队列条。
        viewModel.handleSteerQueueAtRunTerminal(for: conversationId, autoContinue: false)

        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertEqual(viewModel.steerQueue.count, 1)
        XCTAssertTrue(viewModel.steerQueue[0].hasAttachments)
    }

    func testLegacyTextOnlySidecarStillLoads() throws {
        let base = makeTempDirectory("SteerQueueLegacy")
        defer { try? FileManager.default.removeItem(at: base) }
        let conversationId = KotlinUuid.companion.random()
        let url = base.appendingPathComponent("\(conversationId.toHexDashString()).json")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 旧格式：仅 id/text/createdAt（无 images / selectedFile）。
        struct LegacyEntry: Codable {
            let id: String
            let text: String
            let createdAt: Date
        }
        let data = try JSONEncoder().encode([
            LegacyEntry(id: "legacy-1", text: "旧排队", createdAt: Date(timeIntervalSince1970: 100))
        ])
        try data.write(to: url)
        let loaded = IOSSteerQueueStore(directoryURL: base).load(conversationId: conversationId)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "旧排队")
        XCTAssertTrue(loaded.first?.images.isEmpty == true)
        XCTAssertNil(loaded.first?.selectedFile)
    }

    func testImageOnlyDuringGenerationEnqueuesAndIsSendable() async throws {
        let base = makeTempDirectory("SteerQueueImageOnly")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.addPendingImage(dataUrl: "data:image/png;base64,ddd", previewData: Data("r".utf8))
        viewModel.inputText = ""
        XCTAssertNil(viewModel.composerSendBlockReason(for: ""))
        XCTAssertFalse(ChatView.composerSendButtonIsStopMode(
            isRunActive: true, isRecognizingImages: false, hasSendableContent: true, sendEnabled: true
        ))
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertEqual(viewModel.steerQueue.count, 1)
        XCTAssertEqual(viewModel.steerQueue[0].text, "")
        XCTAssertEqual(viewModel.steerQueue[0].images.count, 1)
    }

    func testFileOnlyDuringGenerationEnqueues() async throws {
        let base = makeTempDirectory("SteerQueueFileOnly")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.pendingSelectedFilePreview = SelectedDocumentReadResult(
            fileName: "notes.md",
            fileType: "text/markdown",
            totalBytes: 12,
            bytesRead: 12,
            characterCount: 5,
            preview: "hello",
            isTruncated: false,
            note: nil
        )
        viewModel.inputText = ""
        XCTAssertNil(viewModel.composerSendBlockReason(for: ""))
        XCTAssertTrue(viewModel.sendMessage())
        XCTAssertEqual(viewModel.steerQueue.count, 1)
        XCTAssertEqual(viewModel.steerQueue[0].selectedFile?.fileName, "notes.md")
        XCTAssertNil(viewModel.pendingSelectedFilePreview)
    }

    func testMixedLeftoverRestoresTextOnlyKeepsAttachments() async throws {
        let base = makeTempDirectory("SteerQueueMixedLeftover")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeConversationStore(directory: base)
        await store.newConversation()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: base)

        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "纯文本插话"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.addPendingImage(dataUrl: "data:image/png;base64,eee", previewData: Data("s".utf8))
        viewModel.inputText = "带图插话"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil

        viewModel.handleSteerQueueAtRunTerminal(for: conversationId, autoContinue: true)
        await viewModel.currentRun.state.steerQueueAutoContinueTask?.value

        // 成功终态先发纯文本头一条；带图条目仍留队列。
        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertEqual(
            viewModel.messages.filter { $0.role == MessageRole.user }.map { $0.toText() },
            ["纯文本插话"]
        )
        XCTAssertEqual(viewModel.steerQueue.count, 1)
        XCTAssertTrue(viewModel.steerQueue[0].hasAttachments)
        XCTAssertEqual(viewModel.steerQueue[0].text, "带图插话")
    }

    func testFailedConversationCommitKeepsSteerSidecarAndReplayUsesOneMessageID() async throws {
        let root = makeTempDirectory("SteerCommitFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("conversations")
        let queueDirectory = root.appendingPathComponent("queue")
        let heldConversations = root.appendingPathComponent("held-conversations")
        let store = makeConversationStore(directory: conversations)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: queueDirectory)
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "must survive a failed write"
        XCTAssertTrue(viewModel.sendMessage())
        let entry = try XCTUnwrap(viewModel.steerQueue.first)

        try FileManager.default.moveItem(at: conversations, to: heldConversations)
        try Data().write(to: conversations)
        let failed = await viewModel.drainSteerQueue(conversationId: id)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(IOSSteerQueueStore(directoryURL: queueDirectory).load(conversationId: id), [entry])
        XCTAssertNotNil(store.lastIOError)

        try FileManager.default.removeItem(at: conversations)
        try FileManager.default.moveItem(at: heldConversations, to: conversations)
        let reloadedStore = makeConversationStore(directory: conversations)
        await reloadedStore.bootstrap()
        await reloadedStore.selectConversation(id: id)
        let reloaded = makeViewModel(conversationStore: reloadedStore, queueDirectory: queueDirectory)
        let committed = await reloaded.drainSteerQueue(conversationId: id)
        XCTAssertEqual(committed.map { $0.toText() }, [entry.text])
        let committedID = try XCTUnwrap(committed.first?.id)
        XCTAssertTrue(IOSSteerQueueStore(directoryURL: queueDirectory).load(conversationId: id).isEmpty)

        // Model a process ending after the conversation commit but before sidecar cleanup.
        IOSSteerQueueStore(directoryURL: queueDirectory).persist([entry], for: id)
        let replayed = makeViewModel(conversationStore: reloadedStore, queueDirectory: queueDirectory)
        let replayedDrain = await replayed.drainSteerQueue(conversationId: id)
        XCTAssertTrue(replayedDrain.isEmpty)
        let persisted = await reloadedStore.messages(for: id) ?? []
        XCTAssertEqual(persisted.map(\.id), [committedID])
        XCTAssertTrue(IOSSteerQueueStore(directoryURL: queueDirectory).load(conversationId: id).isEmpty)
    }

    func testSteerCommitKeepsMessagesEnqueuedWhileSaveIsSuspended() async throws {
        let root = makeTempDirectory("SteerEnqueueDuringCommit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeConversationStore(directory: root.appendingPathComponent("conversations"))
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let queueDirectory = root.appendingPathComponent("queue")
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: queueDirectory)
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "first batch"
        XCTAssertTrue(viewModel.sendMessage())
        var releaseSave: CheckedContinuation<Void, Never>?
        let saveEntered = expectation(description: "conversation commit began")
        store.beforePersistForTesting = { _ in
            store.beforePersistForTesting = nil
            saveEntered.fulfill()
            await withCheckedContinuation { releaseSave = $0 }
        }
        let consumption = Task { await viewModel.drainSteerQueue(conversationId: id) }
        await fulfillment(of: [saveEntered], timeout: 2)
        XCTAssertNotNil(releaseSave)
        viewModel.inputText = "next batch"
        XCTAssertTrue(viewModel.sendMessage())
        releaseSave?.resume()
        let committed = await consumption.value
        XCTAssertEqual(committed.map { $0.toText() }, ["first batch"])
        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["next batch"])
        XCTAssertEqual(IOSSteerQueueStore(directoryURL: queueDirectory).load(conversationId: id).map(\.text), ["next batch"])
    }

    func testSteerWaitsForRegeneratedAnswerVariantCommit() async throws {
        let root = makeTempDirectory("SteerPendingVariant")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeConversationStore(directory: root.appendingPathComponent("conversations"))
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: root.appendingPathComponent("queue"))
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "follow-up after regeneration"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.currentRun.state.pendingAssistantRegeneration = PendingAssistantRegeneration(
            conversationId: id, targetMessageIndex: 1, generatedMessageIndex: 1
        )
        var writes = 0
        store.beforePersistForTesting = { _ in writes += 1 }

        let drained = await viewModel.drainSteerQueue(conversationId: id)
        XCTAssertTrue(drained.isEmpty)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["follow-up after regeneration"])
        XCTAssertEqual(viewModel.currentRun.state.pendingAssistantRegeneration?.targetMessageIndex, 1)
    }

    func testCancellingAutoContinueDuringCommitDoesNotDuplicateCommittedTextInComposer() async throws {
        let root = makeTempDirectory("SteerCancelDuringCommit")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeConversationStore(directory: root.appendingPathComponent("conversations"))
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: root.appendingPathComponent("queue"))
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "committed while cancelling"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil
        let saveEntered = expectation(description: "terminal queue commit began")
        var releaseSave: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { _ in
            store.beforePersistForTesting = nil
            saveEntered.fulfill()
            await withCheckedContinuation { releaseSave = $0 }
        }
        viewModel.handleSteerQueueAtRunTerminal(for: id, autoContinue: true)
        let continuation = viewModel.currentRun.state.steerQueueAutoContinueTask
        await fulfillment(of: [saveEntered], timeout: 2)
        viewModel.handleSteerQueueAtRunTerminal(for: id, autoContinue: false)
        releaseSave?.resume()
        await continuation?.value

        XCTAssertTrue(viewModel.inputText.isEmpty)
        XCTAssertTrue(viewModel.steerQueue.isEmpty)
        XCTAssertEqual(viewModel.messages.map { $0.toText() }, ["committed while cancelling"])
        XCTAssertFalse(viewModel.isGenerationActive)
    }

    func testConversationSwitchRetainsTerminalQueueCommitOwnerAndNewDraft() async throws {
        let root = makeTempDirectory("SteerCommitConversationSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeConversationStore(directory: root.appendingPathComponent("conversations"))
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: root.appendingPathComponent("queue"))
        let originalRun = viewModel.currentRun
        let originalHost = viewModel.kernelRunHost
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "belongs to the original conversation"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil
        let saveEntered = expectation(description: "queue commit began before switching")
        var releaseSave: CheckedContinuation<Void, Never>?
        store.beforePersistForTesting = { _ in
            store.beforePersistForTesting = nil
            saveEntered.fulfill()
            await withCheckedContinuation { releaseSave = $0 }
        }
        viewModel.handleSteerQueueAtRunTerminal(for: id, autoContinue: true)
        let continuation = originalRun.state.steerQueueAutoContinueTask
        await fulfillment(of: [saveEntered], timeout: 2)
        await store.newConversation()
        viewModel.reloadFromStore()
        let newConversationID = try XCTUnwrap(store.currentConversation?.id)
        viewModel.inputText = "keep this new draft"
        XCTAssertTrue(viewModel.runRegistry.run(for: id) === originalRun)
        XCTAssertTrue(viewModel.host(for: id) === originalHost)
        releaseSave?.resume()
        await continuation?.value

        XCTAssertEqual(store.currentConversation?.id, newConversationID)
        XCTAssertEqual(viewModel.inputText, "keep this new draft")
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(originalRun.state.messages.map { $0.toText() }, ["belongs to the original conversation"])
        let persisted = await store.messages(for: id)
        XCTAssertEqual(persisted?.map { $0.toText() }, ["belongs to the original conversation"])
    }

    func testTerminalAutoContinueDoesNotConsumeQueueWhenSaveFails() async throws {
        let root = makeTempDirectory("SteerTerminalCommitFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("conversations")
        let store = makeConversationStore(directory: conversations)
        await store.newConversation()
        let id = try XCTUnwrap(store.currentConversation?.id)
        let queueDirectory = root.appendingPathComponent("queue")
        let viewModel = makeViewModel(conversationStore: store, queueDirectory: queueDirectory)
        viewModel.generationActiveOverrideForTesting = { _ in true }
        viewModel.inputText = "continue only after commit"
        XCTAssertTrue(viewModel.sendMessage())
        viewModel.generationActiveOverrideForTesting = nil
        try FileManager.default.moveItem(at: conversations, to: root.appendingPathComponent("held"))
        try Data().write(to: conversations)

        viewModel.handleSteerQueueAtRunTerminal(for: id, autoContinue: true)
        await viewModel.currentRun.state.steerQueueAutoContinueTask?.value
        XCTAssertEqual(viewModel.steerQueue.map(\.text), ["continue only after commit"])
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isGenerationActive)
    }

    func testQueueRowTitleShowsImageAndFile() {
        let entry = IOSSteerQueueEntry(
            id: "row",
            text: "",
            createdAt: Date(),
            images: [IOSSteerQueueImage(dataUrl: "data:image/png;base64,x", previewData: Data("t".utf8))],
            selectedFile: IOSSteerQueuedFile(SelectedDocumentReadResult(
                fileName: "brief.pdf",
                fileType: "application/pdf",
                totalBytes: 1,
                bytesRead: 1,
                characterCount: 1,
                preview: "x",
                isTruncated: false,
                note: nil
            ))
        )
        XCTAssertEqual(ChatSteerQueueStrip.rowTitle(for: entry), "图片 · brief.pdf")
    }
}
