import XCTest
import SQLite3
@preconcurrency import Shared
@testable import iosApp


/// Thread listing, interruption, and parent mailbox terminal delivery.
@MainActor
final class IOSOrchestrationListInterruptTerminalTests: IOSOrchestrationToolTestCase {
    // MARK: - list_agents

    func testListAgentsProjectsEdgesAndLatestRunStatus() async throws {
        let base = makeTempDirectory("ListAgents")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let childHex = "11111111-1111-1111-1111-111111111111"
        let grandHex = "22222222-2222-2222-2222-222222222222"
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childHex,
            parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/research",
            nickname: nil,
            roleAssistantId: "assistant-1",
            forkTurns: "3",
            status: "Open",
            createdAt: now
        ))
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: grandHex,
            parentThreadId: childHex,
            agentPath: "/root/research/digest",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: now
        ))
        // 两个 run：旧 completed + 新 running → 取最新。
        _ = try await db.agentRuntimeDao().insertRunIfAbsent(run: AgentRunEntity(
            runId: "old", parentRunId: nil, agentDescriptorId: "chat", agentVersion: "1",
            conversationId: childHex, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: "completed", inputDigest: "d", inputSnapshotRef: nil, inputSchemaVersion: 1,
            startedAt: now, finishedAt: KotlinLong(value: now + 1), interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        ))
        _ = try await db.agentRuntimeDao().insertRunIfAbsent(run: AgentRunEntity(
            runId: "new", parentRunId: nil, agentDescriptorId: "chat", agentVersion: "1",
            conversationId: childHex, messageNodeId: nil, producesMessageId: nil, assistantId: nil,
            status: "running", inputDigest: "d", inputSnapshotRef: nil, inputSchemaVersion: 1,
            startedAt: now + 2, finishedAt: nil, interruptedReason: nil,
            terminalReason: nil, providerId: nil, modelId: nil, promptVersion: nil,
            toolCatalogVersion: nil, capabilitySnapshot: nil
        ))

        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )
        let payload = parseJSON(await service.execute(
            toolName: "list_agents",
            arguments: "{}",
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["count"] as? Int, 2)
        let threads = payload["threads"] as! [[String: Any]]
        let byPath = Dictionary(uniqueKeysWithValues: threads.map { ($0["agent_path"] as! String, $0) })
        XCTAssertEqual(byPath["/root/research"]?["run_status"] as? String, "running", "取最新 run 状态")
        XCTAssertEqual(byPath["/root/research"]?["role"] as? String, "assistant-1")
        XCTAssertEqual(byPath["/root/research/digest"]?["run_status"] as? String, "none")

        // path_prefix 过滤。
        let filtered = parseJSON(await service.execute(
            toolName: "list_agents",
            arguments: #"{"path_prefix":"/root/research/digest"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(filtered["count"] as? Int, 1)
    }

    // MARK: - interrupt_agent

    func testInterruptBackgroundRunCancelsAndPreservesThread() async throws {
        let base = makeTempDirectory("InterruptBg")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let childHex = "33333333-3333-3333-3333-333333333333"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childHex, parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/worker", nickname: nil, roleAssistantId: nil,
            forkTurns: "all", status: "Open", createdAt: now
        ))
        let scheduler = FakeBackgroundScheduler()
        scheduler.activeRunByHex[childHex] = "bg-run-9"
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )

        let result = parseJSON(await service.execute(
            toolName: "interrupt_agent",
            arguments: #"{"target":"/root/worker"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["previous_status"] as? String, "running")
        XCTAssertEqual(scheduler.cancelledRunIds, ["bg-run-9"])

        // 线程保留：edge 仍 Open。
        let edge = try await db.threadEdgeDao().edgeFor(childThreadId: childHex)
        XCTAssertEqual(edge?.status, "Open")
    }

    func testInterruptIdleThreadReturnsIdleWithoutError() async throws {
        let base = makeTempDirectory("InterruptIdle")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let childHex = "44444444-4444-4444-4444-444444444444"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childHex, parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/idle", nickname: nil, roleAssistantId: nil,
            forkTurns: "all", status: "Open", createdAt: now
        ))
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )
        let result = parseJSON(await service.execute(
            toolName: "interrupt_agent",
            arguments: #"{"target":"\#(childHex)"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["previous_status"] as? String, "idle", "无活跃 run 的 idle 不算错误")
        XCTAssertTrue(scheduler.cancelledRunIds.isEmpty)
    }

    func testInterruptNonDescendantIsRejected() async throws {
        let base = makeTempDirectory("InterruptForeign")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let foreignHex = "55555555-5555-5555-5555-555555555555"
        let otherRoot = KotlinUuid.companion.random()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // 属于另一个 root 的线程。
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: foreignHex, parentThreadId: otherRoot.toHexDashString(),
            agentPath: "/root/foreign", nickname: nil, roleAssistantId: nil,
            forkTurns: "all", status: "Open", createdAt: now
        ))
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )
        let result = parseJSON(await service.execute(
            toolName: "interrupt_agent",
            arguments: #"{"target":"/root/foreign"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["error"] as? String, "not_a_descendant")
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertTrue(scheduler.cancelledRunIds.isEmpty)
    }

    func testInterruptUnknownTargetIsRejected() async throws {
        let base = makeTempDirectory("InterruptUnknown")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )
        let result = parseJSON(await service.execute(
            toolName: "interrupt_agent",
            arguments: #"{"target":"nope"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["error"] as? String, "unknown_target")
    }

    // MARK: - FINAL_ANSWER 终态回传（前台 finishStreaming → 父 mailbox → 父边界折入）

    func testFinalAnswerReachesParentMailboxAndFoldsAtParentBoundary() async throws {
        let base = makeTempDirectory("FinalAnswer")
        defer { try? FileManager.default.removeItem(at: base) }
        let db = makeDatabase(directory: base)
        let store = IOSConversationStore(baseDirectory: base, threadEdgeDaoProvider: { db.threadEdgeDao() })
        let scheduler = FakeBackgroundScheduler()

        // 父会话 → 子会话（current）。
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.newConversation()
        let childId = try XCTUnwrap(store.currentConversation?.id)
        let finalText = String(repeating: "子线程最终回答。", count: 350) + "报告最后一条"
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "子线程任务"),
            UIMessage.companion.assistant(prompt: finalText),
        ])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childId.toHexDashString(),
            parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/sub",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: now
        ))

        try await store.refreshSubagentConversationVisibility()

        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { childId }
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            mailboxStore: IOSMailboxStore(mailboxDao: db.mailboxDao()),
            orchestrationToolService: service
        )
        viewModel.conversationStore = store
        viewModel.reloadFromStore()

        // 子线程 run 终态 → FINAL_ANSWER 进父 mailbox。
        await service.notifyRunTerminal(
            conversationId: childId,
            runId: "child-run-1",
            finalMessages: viewModel.messages
        )
        let finalEnvelope = try await pollFinalAnswerEnvelope(
            mailboxDao: db.mailboxDao(),
            recipient: parentId,
            runId: "child-run-1"
        )
        let payload = try XCTUnwrap(finalEnvelope?.payload)
        XCTAssertTrue(payload.hasPrefix(String(finalText.prefix(IOSThreadOrchestrationToolService.finalAnswerMaxChars))))
        let metadataLine = try XCTUnwrap(payload.components(separatedBy: "\n").first {
            $0.hasPrefix("{") && $0.contains("\"session_read\"")
        })
        let metadata = parseJSON(metadataLine)
        XCTAssertEqual(metadata["truncated"] as? Bool, true)
        XCTAssertEqual(metadata["run_ended"] as? Bool, true)
        let reference = try XCTUnwrap(metadata["session_read"] as? [String: Any])
        XCTAssertEqual(reference["conversation_id"] as? String, childId.toHexDashString())
        XCTAssertEqual(reference["message_id"] as? String, viewModel.messages.last?.id.toHexDashString())
        XCTAssertEqual(reference["offset"] as? Int, 0)
        XCTAssertEqual(finalEnvelope?.author, "/root/sub")

        // 父线程在其下一边界折入（复用 P1-b 机制：渲染为带结构头的 user 消息）。
        await store.selectConversation(id: parentId)
        viewModel.reloadFromStore()
        let upload = await viewModel.nextRoundMessagesAfterMailboxAndSteerConsumptionForTesting(
            baseMessages: [UIMessage.companion.assistant(prompt: "父工具结果")]
        )
        let uploadUserTexts = upload.filter { $0.role == MessageRole.user }.map { $0.toText() }
        XCTAssertEqual(uploadUserTexts, [
            "[mailbox FINAL_ANSWER from /root/sub]\n\(payload)",
        ])

        var affectedIDs: [KotlinUuid] = []
        let deleted = await store.deleteConversation(id: parentId) { affectedIDs = $0 }
        XCTAssertTrue(deleted)
        XCTAssertEqual(Set(affectedIDs.map { $0.toHexDashString() }), [parentId.toHexDashString(), childId.toHexDashString()])
        XCTAssertTrue(store.allSummaries.contains { $0.id == childId })
        XCTAssertFalse(store.summaries.contains { $0.id == childId })
        let retainedMessages = await store.messages(for: childId)
        XCTAssertEqual(retainedMessages?.last?.toText(), finalText)
        await service.notifyRunTerminal(
            conversationId: childId, runId: "after-parent-deletion",
            finalMessages: [UIMessage.companion.assistant(prompt: "late result")]
        )
        let pendingAfterDeletion = try await db.mailboxDao().pendingForRecipient(recipientId: parentId.toHexDashString())
        XCTAssertTrue(pendingAfterDeletion.isEmpty)
    }

    // MARK: - P1-c 复核修复回归（后台 runtime 注入 / run 锚定 / cancel 终态 /
    //           start 失败回收 / 空转录终态）

    func testViewModelBackgroundRuntimeInjectsOrchestrationService() async throws {
        let base = makeTempDirectory("VMBgRuntime")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q1")])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )

        // 经 VM 的真实闭包路径取后台 executor 表（隔离依赖让服务可用）。
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            orchestrationToolService: service
        )
        viewModel.conversationStore = store
        let runtime = viewModel.makeBackgroundToolRuntimeForTesting()
        let baseParams = makeParams()
        let params = TextGenerationParams(
            model: baseParams.model,
            temperature: baseParams.temperature,
            topP: nil,
            maxTokens: nil,
            tools: ToolKt.iosToolDeclarations(names: ["spawn_agent", "list_agents", "interrupt_agent"]),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let executors = runtime.backgroundToolExecutors(
            providerSetting: makeProviderSetting(),
            params: params,
            runId: "parent-run-vm",
            conversationId: parentId
        )
        let executor = try XCTUnwrap(executors["spawn_agent"], "后台 runtime 必须注册 spawn_agent")
        let outcome = await IOSToolExecutorBox(executor).execute(
            name: "spawn_agent",
            arguments: spawnArguments(taskName: "subtask", message: "后台孙线程任务"),
            isUserInitiated: false
        )
        guard case .filled(let text) = outcome else {
            return XCTFail("spawn_agent 后台执行应成功，实际: \(outcome)")
        }
        XCTAssertFalse(text.contains("线程编排工具当前不可用"), "后台 runtime 必须注入编排服务，实际: \(text)")
        let result = parseJSON(text)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["status"] as? String, "started")
        XCTAssertEqual(scheduler.startedHandoff?.conversationId.toHexDashString(),
                       result["child_thread_id"] as? String)
    }

    func testSpawnListInterruptAnchorToRunConversationNotCurrent() async throws {
        let base = makeTempDirectory("RunAnchor")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let runA = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "q1"),
            UIMessage.companion.assistant(prompt: "a1"),
        ])
        // 生成中切到会话 B：current 是 B，run 锚定 A。
        await store.newConversation()
        let runB = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "B 内容"),
        ])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { runB }
        )

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "anchored", message: "跑在 A 下"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "run-a",
            conversationId: runA
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        let childHex = try XCTUnwrap(result["child_thread_id"] as? String)

        // edge 挂在 run 锚定的 A 下，不是当前会话 B。
        let edge = try await db.threadEdgeDao().edgeFor(childThreadId: childHex)
        XCTAssertEqual(edge?.parentThreadId, runA.toHexDashString())
        XCTAssertNotEqual(edge?.parentThreadId, runB.toHexDashString())

        // fork 源是 A（含 q1），不是 B（不含「B 内容」）。
        let childId = try! KotlinUuid.companion.parse(uuidString: childHex)
        let childUserTexts = (await store.messages(for: childId) ?? [])
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertTrue(childUserTexts.contains("q1"), "fork 源应为 run 锚定会话 A")
        XCTAssertFalse(childUserTexts.contains("B 内容"), "不得 fork 当前会话 B")

        // list 以 A 为根可见子线程；以 B 为根不可见。
        let listA = parseJSON(await service.execute(
            toolName: "list_agents",
            arguments: "{}",
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "run-a",
            conversationId: runA
        ))
        XCTAssertEqual(listA["count"] as? Int, 1)
        let listB = parseJSON(await service.execute(
            toolName: "list_agents",
            arguments: "{}",
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "run-a",
            conversationId: runB
        ))
        XCTAssertEqual(listB["count"] as? Int, 0, "list 不得以当前会话 B 为根")

        // interrupt 后代校验以 A 为根：A 下可中断，B 下视为非后代。
        let interruptA = parseJSON(await service.execute(
            toolName: "interrupt_agent",
            arguments: #"{"target":"\#(childHex)"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "run-a",
            conversationId: runA
        ))
        XCTAssertEqual(interruptA["ok"] as? Bool, true)
        let interruptB = parseJSON(await service.execute(
            toolName: "interrupt_agent",
            arguments: #"{"target":"\#(childHex)"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "run-a",
            conversationId: runB
        ))
        XCTAssertEqual(interruptB["error"] as? String, "not_a_descendant")
    }

    func testCancelDeliversFinalAnswerToParentAndDoesNotDoubleSend() async throws {
        let base = makeTempDirectory("CancelFinal")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()

        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.newConversation()
        let childId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "子线程任务"),
            UIMessage.companion.assistant(prompt: "部分回答"),
        ])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childId.toHexDashString(),
            parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/sub",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: now
        ))

        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { childId }
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            mailboxStore: IOSMailboxStore(mailboxDao: db.mailboxDao()),
            orchestrationToolService: service
        )
        viewModel.conversationStore = store
        viewModel.reloadFromStore()

        // run 取消终态 → 回传父 mailbox（带 Open 父 edge）。
        await service.notifyRunTerminal(
            conversationId: childId,
            runId: "child-run-cancel",
            finalMessages: viewModel.messages
        )
        let finalEnvelope = try await pollFinalAnswerEnvelope(
            mailboxDao: db.mailboxDao(),
            recipient: parentId,
            runId: "child-run-cancel"
        )
        XCTAssertEqual(finalEnvelope?.author, "/root/sub")
        XCTAssertEqual(finalEnvelope?.payload, "部分回答")

        // 同一终态重复通知：服务按 runId 幂等去重，不双发。
        await service.notifyRunTerminal(
            conversationId: childId,
            runId: "child-run-cancel",
            finalMessages: viewModel.messages
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        let count = try await countFinalAnswerEnvelopes(
            mailboxDao: db.mailboxDao(),
            recipient: parentId,
            runId: "child-run-cancel"
        )
        XCTAssertEqual(count, 1, "cancel 与 finishStreaming 双触发不得双发 FINAL_ANSWER")
    }

    func testSpawnStartFailureReclaimsRunningRow() async throws {
        let base = makeTempDirectory("SpawnStartFail")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q1")])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        scheduler.startedReturn = false
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "doomed"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-run-fail"
        ))
        XCTAssertEqual(result["error"] as? String, "start_failed")

        // start 失败后：不留下 running 孤儿行（并发限额计数回落），
        // 该 run 行更新为 failed（保留审计事实）。
        let unfinished = try await db.agentRuntimeDao().listRecoverable(descriptorIds: ["chat"])
        XCTAssertTrue(unfinished.isEmpty, "start 失败后不得有 running 孤儿行，实际: \(unfinished.count)")
        let allRuns = try await db.agentRuntimeDao().listAllRuns()
        XCTAssertTrue(
            allRuns.contains { $0.status == "failed" },
            "start 失败的 run 行应更新为 failed"
        )
    }

    func testEmptyTranscriptTerminalDeliversStructuredEnvelope() async throws {
        let base = makeTempDirectory("EmptyTranscript")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()

        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.newConversation()
        let childId = try XCTUnwrap(store.currentConversation?.id)
        // 空转录：只有 user 消息，没有任何 assistant 文本。
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "子线程任务")])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: childId.toHexDashString(),
            parentThreadId: parentId.toHexDashString(),
            agentPath: "/root/sub",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: now
        ))

        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { childId }
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: isolatedDefaults()),
            autoGenerateResponses: false,
            mailboxStore: IOSMailboxStore(mailboxDao: db.mailboxDao()),
            orchestrationToolService: service
        )
        viewModel.conversationStore = store
        viewModel.reloadFromStore()

        // 空转录 failed 子 run → 父 Room 仍收到结构化终态信封。
        await service.notifyRunTerminal(
            conversationId: childId,
            runId: "child-run-empty",
            finalMessages: viewModel.messages
        )
        let finalEnvelope = try await pollFinalAnswerEnvelope(
            mailboxDao: db.mailboxDao(),
            recipient: parentId,
            runId: "child-run-empty"
        )
        XCTAssertEqual(finalEnvelope?.payload, "[run ended without assistant output]")
        XCTAssertEqual(finalEnvelope?.author, "/root/sub")
    }

    /// Sendable 归约：回调内只传匹配信封的 payload/author（Kotlin 实体非 Sendable）。
    private func pollFinalAnswerEnvelope(
        mailboxDao: MailboxDao,
        recipient: KotlinUuid,
        runId: String,
        timeout: TimeInterval = 5
    ) async throws -> (payload: String, author: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match: (payload: String, author: String)? = await withCheckedContinuation { cont in
                mailboxDao.pendingForRecipient(recipientId: recipient.toHexDashString()) { result, _ in
                    let pending = result ?? []
                    let hit = pending.first { $0.parentTurnId == runId && $0.type == "FINAL_ANSWER" }
                    cont.resume(returning: hit.map { (payload: $0.payload, author: $0.authorThreadId) })
                }
            }
            if let match { return match }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// 计数指定 runId 的 FINAL_ANSWER 未投递信封（终态去重断言用；
    /// 与 pollFinalAnswerEnvelope 同款 Sendable 归约）。
    private func countFinalAnswerEnvelopes(
        mailboxDao: MailboxDao,
        recipient: KotlinUuid,
        runId: String,
        timeout: TimeInterval = 5
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count: Int = await withCheckedContinuation { cont in
                mailboxDao.pendingForRecipient(recipientId: recipient.toHexDashString()) { result, _ in
                    let pending = result ?? []
                    cont.resume(returning: pending.filter {
                        $0.parentTurnId == runId && $0.type == "FINAL_ANSWER"
                    }.count)
                }
            }
            if count > 0 { return count }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return 0
    }
}

/// Sendable 桥：跨 await 调 non-Sendable 的 `any IOSToolExecutor`（照
/// IOSToolRuntimeTests.IOSToolRuntimeUncheckedExecutorBox 先例）。
private final class IOSToolExecutorBox: @unchecked Sendable {
    private let base: any IOSToolExecutor

    init(_ base: any IOSToolExecutor) {
        self.base = base
    }

    func execute(
        name: String,
        arguments: String,
        isUserInitiated: Bool
    ) async -> IOSAgentToolOutcome {
        await base.execute(
            name: name,
            arguments: arguments,
            isUserInitiated: isUserInitiated
        )
    }


}
