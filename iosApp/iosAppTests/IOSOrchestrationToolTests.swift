import XCTest
import SQLite3
@preconcurrency import Shared
@testable import iosApp


/// Spawn bootstrap, child limits, and thread ancestry.
@MainActor
final class IOSOrchestrationToolTests: IOSOrchestrationToolTestCase {
    // MARK: - spawn 全链路

    func testSpawnDoesNotSaveChildOrStartWhenEdgeWriteFails() async throws {
        let base = makeTempDirectory("SpawnEdgeFailure")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        _ = try await db.threadEdgeDao().allEdges()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(base.appendingPathComponent("orchestration.db").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,
            "CREATE TRIGGER reject_test_edge BEFORE INSERT ON thread_edge BEGIN SELECT RAISE(ABORT, 'edge write rejected'); END",
            nil, nil, nil), SQLITE_OK)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(store: store, db: db, scheduler: scheduler, currentConversationId: { parentId })
        let result = parseJSON(await service.execute(
            toolName: "spawn_agent", arguments: spawnArguments(taskName: "rejected"),
            providerSetting: makeProviderSetting(), params: makeParams(), runId: "edge-failure"
        ))
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertNil(scheduler.startedHandoff)
        XCTAssertEqual(store.allSummaries.map { $0.id }, [parentId])
        XCTAssertTrue((result["reason"] as? String)?.contains("关系保存失败") == true)
    }

    func testSpawnForkAllWritesEdgeBootstrapsTaskAndStartsBackgroundRun() async throws {
        let base = makeTempDirectory("SpawnAll")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let parentHex = parentId.toHexDashString()
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "q1"),
            UIMessage.companion.assistant(prompt: "a1"),
        ])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId }
        )
        let executionPolicy = IOSExecutionPolicySnapshot(
            capabilityPolicies: ["ios.agent.subagent_dispatch": "autoApprove"],
            globalAutoApproveEnabled: true,
            highRiskAutoApproveEnabled: false,
            execJavaScriptEnabled: true,
            webSearchEnabled: false
        )
        let providerSetting = makeProviderSetting()
        let params = makeParams()
        var checkedInitialChildWrite = false
        store.beforePersistForTesting = { conversation in
            guard conversation.id != parentId, !checkedInitialChildWrite else { return }
            checkedInitialChildWrite = true
            let edge = try? await db.threadEdgeDao().edgeFor(childThreadId: conversation.id.toHexDashString())
            XCTAssertEqual(edge?.parentThreadId, parentHex, "首次写子会话之前，编排关系必须已落盘")
        }

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "research", message: "调研房价", forkTurns: "all"),
            providerSetting: providerSetting,
            params: params,
            runId: "parent-run-1",
            executionPolicy: executionPolicy
        ))

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["status"] as? String, "started")
        XCTAssertTrue(checkedInitialChildWrite)
        XCTAssertEqual(result["task_name"] as? String, "research")
        XCTAssertEqual(result["agent_path"] as? String, "/root/research")
        let childHex = try XCTUnwrap(result["child_thread_id"] as? String)

        // edge 写入（Open，forkTurns=all）。
        let edge = try await db.threadEdgeDao().edgeFor(childThreadId: childHex)
        XCTAssertEqual(edge?.parentThreadId, parentHex)
        XCTAssertEqual(edge?.agentPath, "/root/research")
        XCTAssertEqual(edge?.status, "Open")
        XCTAssertEqual(edge?.forkTurns, "all")

        // 子会话含 NEW_TASK 渲染消息（bootstrap 直接持久化）。
        let childId = try! KotlinUuid.companion.parse(uuidString: childHex)
        let childMessages = await store.messages(for: childId) ?? []
        XCTAssertFalse(store.summaries.contains { $0.id == childId })
        XCTAssertTrue(store.allSummaries.contains { $0.id == childId })
        XCTAssertEqual(store.currentConversation?.id, parentId)
        XCTAssertEqual(IosMailboxMessageBridge.shared.sender(message: try XCTUnwrap(childMessages.last)), "/root")
        let childUserTexts = childMessages.filter { $0.role == MessageRole.user }.map { $0.toText() }
        XCTAssertEqual(
            childUserTexts,
            ["q1", "[mailbox NEW_TASK from /root]\n调研房价"],
            "fork=all 继承全部历史 + bootstrap 初始任务",
        )

        // 后台 start 被调且 payload 正确。
        let handoff = try XCTUnwrap(scheduler.startedHandoff)
        XCTAssertEqual(handoff.conversationId.toHexDashString(), childHex)
        XCTAssertEqual(handoff.executionPolicy, executionPolicy)
        // 场景 C 修复后：upload 首条为子线程向编排语境（system），其后与持久化一致。
        XCTAssertEqual(
            handoff.uploadMessages.filter { $0.role != MessageRole.system },
            childMessages.filter { $0.role != MessageRole.system }
        )
        XCTAssertEqual(handoff.uploadMessages.first?.role, MessageRole.system)
        XCTAssertEqual(
            handoff.uploadMessages.filter { $0.role == MessageRole.user }.last?.toText(),
            "[mailbox NEW_TASK from /root]\n调研房价"
        )

        // 子 run 已记账，且能从 Chat descriptor 的可恢复集合查到。
        let runs = try await db.agentRuntimeDao().listRecoverable(descriptorIds: ["chat"])
        let childRun = try XCTUnwrap(
            runs.first { $0.conversationId == childHex && $0.status == "running" }
        )
        XCTAssertEqual(childRun.providerId, providerSetting.id.description())
        XCTAssertEqual(childRun.modelId, params.model.modelId)
        XCTAssertNil(childRun.promptVersion)
        XCTAssertEqual(
            childRun.toolCatalogVersion,
            chatInputDigest(
                for: IosRunRequestSnapshotJsonBridge.shared.encodeToolCatalog(tools: params.tools)
            )
        )
        XCTAssertEqual(childRun.capabilitySnapshot, executionPolicy.encodedJSON)
    }

    func testSpawnForkAllExcludesPendingParentToolBatchFromChildAndHandoff() async throws {
        let base = makeTempDirectory("SpawnPendingParentTools")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        func assistant(parts: [UIMessagePart]) -> UIMessage {
            let seed = UIMessage.companion.assistant(prompt: "")
            return UIMessage(
                id: seed.id, role: seed.role, parts: parts, annotations: seed.annotations,
                createdAt: seed.createdAt, finishedAt: seed.finishedAt,
                modelId: seed.modelId, usage: seed.usage, translation: seed.translation
            )
        }
        func tool(_ id: String, name: String, output: [UIMessagePart]) -> UIMessagePart.Tool {
            UIMessagePart.Tool(
                toolCallId: id, toolName: name, input: "{}", output: output,
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
        }
        let completedHistory = assistant(parts: [
            UIMessagePart.Text(text: "已完成的助手历史", metadata: nil),
            tool("historical-completed", name: "workspace_read", output: [
                UIMessagePart.Text(text: "已读取", metadata: nil)
            ])
        ])
        let pendingBatch = assistant(parts: [
            tool("approved-write", name: "workspace_write", output: [
                UIMessagePart.Text(text: "已写入", metadata: nil)
            ]),
            tool("pending-spawn", name: "spawn_agent", output: [])
        ])
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "q1"), completedHistory,
            UIMessage.companion.user(prompt: "q2"), pendingBatch
        ])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "clean-history", message: "独立任务", forkTurns: "all"),
            providerSetting: makeProviderSetting(), params: makeParams(), runId: "parent-pending-tools"
        ))

        XCTAssertEqual(result["ok"] as? Bool, true)
        let childHex = try XCTUnwrap(result["child_thread_id"] as? String)
        let childId = try KotlinUuid.companion.parse(uuidString: childHex)
        let loadedChildMessages = await store.messages(for: childId)
        let childMessages = try XCTUnwrap(loadedChildMessages)
        let handoff = try XCTUnwrap(scheduler.startedHandoff)
        for (label, messages) in [
            ("persisted child", childMessages),
            ("handoff display", handoff.displayMessages),
            ("handoff upload", handoff.uploadMessages)
        ] {
            let tools = messages.flatMap { $0.parts.compactMap { $0 as? UIMessagePart.Tool } }
            XCTAssertEqual(tools.map(\.toolCallId), ["historical-completed"], label)
            XCTAssertTrue(messages.contains { $0.id == completedHistory.id }, label)
            XCTAssertFalse(messages.contains { $0.id == pendingBatch.id }, label)
            XCTAssertTrue(messages.contains { $0.role == .user && $0.toText() == "q2" }, label)
        }
        XCTAssertEqual(store.currentConversation?.id, parentId)
        XCTAssertTrue(store.currentConversation?.messageNodes.contains {
            $0.messages.contains { $0.id == pendingBatch.id }
        } == true, "fork must preserve the parent batch for its own executor")
    }

    // MARK: - M3: spawn/followup 的 handoff fullToolNames 取桥全目录

    /// 红测试对应缺陷：startDurableBackgroundRun 用 params.tools.map(\.name)（当轮
    /// 可见子集）作 fullToolNames → 子线程目录永久截断（未暴露的 wm_* 永远不可
    /// search/命中）。修复后从 run 桥全目录取名集合（对齐 ChatKernelRunHost）。
    func testSpawnHandoffFullToolNamesComeFromBridgeFullCatalog() async throws {
        let base = makeTempDirectory("SpawnFullNames")
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

        // 桥全目录（heavy → lazy）。params.tools = 首轮可见子集（不含 wm_*）。
        let bridge = IosToolExposureBridge(tools: fullIosDeclarations())
        XCTAssertTrue(bridge.lazyModeEnabled())
        let visibleNames = Set(bridge.visibleTools().map(\.name))
        XCTAssertFalse(visibleNames.contains("wm_type"), "fixture 前提：wm_type 首轮未暴露")

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "fullnames", message: "调研"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-run-m3",
            conversationId: parentId,
            toolExposureBridge: bridge
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)

        let handoff = try XCTUnwrap(scheduler.startedHandoff, "spawn 必须启动子 run")
        let fullNames = Set(handoff.fullToolNames)
        XCTAssertTrue(
            fullNames.contains("wm_type"),
            "fullToolNames 必须来自桥全目录（含未暴露的 wm_*），实际缺 wm_type"
        )
        XCTAssertTrue(fullNames.contains("spawn_agent"), "目录必须含线程编排工具")
        XCTAssertTrue(fullNames.isSuperset(of: visibleNames), "全目录必须覆盖当轮可见子集")
    }

    // MARK: - M4: role_assistant_id 应用到子会话 assistantId + 存在性校验

    func testSpawnAppliesRoleAssistantIdToChildConversation() async throws {
        let base = makeTempDirectory("SpawnRole")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q1")])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let roleId = KotlinUuid.companion.random()
        let roleHex = roleId.toHexDashString()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId },
            roleAssistantExists: { candidate in candidate.toHexDashString() == roleHex }
        )

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "rolechild", message: "按角色调研", roleAssistantId: roleHex),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-run-role",
            conversationId: parentId
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        let childHex = try XCTUnwrap(result["child_thread_id"] as? String)

        // 子会话 assistantId = role（fork 后应用并保存）。
        let childId = try! KotlinUuid.companion.parse(uuidString: childHex)
        let loadedChild = try? await store.loadConversationForOrchestration(childId)
        let childConversation = try XCTUnwrap(loadedChild, "子会话必须已持久化")
        XCTAssertEqual(
            childConversation.assistantId.toHexDashString(), roleHex,
            "role_assistant_id 必须应用到子会话 assistantId"
        )
        // edge 同样记录 role（list_agents 展示）。
        let edge = try await db.threadEdgeDao().edgeFor(childThreadId: childHex)
        XCTAssertEqual(edge?.roleAssistantId, roleHex)
    }

    func testSpawnRejectsUnknownRoleAssistantIdWithoutStartingRun() async throws {
        let base = makeTempDirectory("SpawnBadRole")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [UIMessage.companion.user(prompt: "q1")])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId },
            roleAssistantExists: { _ in false }
        )

        // 存在但校验器拒绝 → 结构化错误。
        let knownButRejected = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(
                taskName: "badrole",
                message: "x",
                roleAssistantId: "11111111-1111-1111-1111-111111111111"
            ),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-run-bad",
            conversationId: parentId
        ))
        XCTAssertEqual(knownButRejected["ok"] as? Bool, false)
        XCTAssertNotNil(knownButRejected["error"], "无效 role 必须返回结构化错误")
        XCTAssertNil(scheduler.startedHandoff, "无效 role 不得创建子线程/启动 run")

        // 非 UUID 字符串 → 结构化错误（解析失败）。
        let unparsable = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "badrole2", message: "x", roleAssistantId: "not-a-uuid"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-run-bad2",
            conversationId: parentId
        ))
        XCTAssertEqual(unparsable["ok"] as? Bool, false)
        XCTAssertNil(scheduler.startedHandoff)
        // 没有残留 running 行（未创建子 run）。
        let runs = try await db.agentRuntimeDao().listRecoverable(descriptorIds: ["chat"])
        XCTAssertTrue(runs.isEmpty)
    }

    func testSpawnForkTurns3KeepsLastThreeUserTurnsInChildConversation() async throws {
        let base = makeTempDirectory("SpawnThree")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "q1"),
            UIMessage.companion.assistant(prompt: "a1"),
            UIMessage.companion.user(prompt: "q2"),
            UIMessage.companion.assistant(prompt: "a2"),
            UIMessage.companion.user(prompt: "q3"),
            UIMessage.companion.assistant(prompt: "a3"),
            UIMessage.companion.user(prompt: "q4"),
            UIMessage.companion.assistant(prompt: "a4"),
        ])
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "digest", message: "汇总", forkTurns: "3"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "parent-run-2"
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        let childHex = try XCTUnwrap(result["child_thread_id"] as? String)
        let childId = try! KotlinUuid.companion.parse(uuidString: childHex)

        let childUserTexts = (await store.messages(for: childId) ?? [])
            .filter { $0.role == MessageRole.user }
            .map { $0.toText() }
        XCTAssertEqual(
            childUserTexts,
            ["q2", "q3", "q4", "[mailbox NEW_TASK from /root]\n汇总"],
            "fork_turns=3 只保留最近 3 个用户轮次 + 初始任务",
        )
    }

    func testSpawnValidatesTaskNameAndUsesStableNamesForConflicts() async throws {
        let base = makeTempDirectory("SpawnValidation")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )

        // 非法 task_name。
        let invalid = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "Bad Name"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(invalid["error"] as? String, "invalid_task_name")
        XCTAssertNil(scheduler.startedHandoff, "非法 task_name 不得启动子 run")

        // 缺 message。
        let missing = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: #"{"task_name":"ok_name"}"#,
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(missing["error"] as? String, "invalid_arguments")

        // 同名冲突优先分配稳定的英文别名，保留唯一的 agentPath。
        let first = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "research"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r1"
        ))
        XCTAssertEqual(first["task_name"] as? String, "research")
        let second = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "research"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r2"
        ))
        XCTAssertEqual(second["task_name"] as? String, "nova")
        XCTAssertEqual(second["agent_path"] as? String, "/root/nova")
        let third = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "research"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r3"
        ))
        XCTAssertEqual(third["task_name"] as? String, "leo")
        XCTAssertEqual(third["agent_path"] as? String, "/root/leo")
    }

    func testSpawnRejectsDepthThreeChain() async throws {
        let base = makeTempDirectory("SpawnDepth")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        let db = makeDatabase(directory: base)

        // 造 depth-2 链：root → child1（depth1）→ child2（depth2）。
        await store.newConversation()
        let rootId = try XCTUnwrap(store.currentConversation?.id)
        let child1 = KotlinUuid.companion.random()
        let child2 = KotlinUuid.companion.random()
        await store.saveForkedConversation(Conversation.companion.ofId(
            id: child1, assistantId: AssistantKt.DEFAULT_ASSISTANT_ID, messages: [], newConversation: false
        ))
        await store.saveForkedConversation(Conversation.companion.ofId(
            id: child2, assistantId: AssistantKt.DEFAULT_ASSISTANT_ID, messages: [], newConversation: false
        ))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: child1.toHexDashString(),
            parentThreadId: rootId.toHexDashString(),
            agentPath: "/root/grand",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: now
        ))
        try await db.threadEdgeDao().insertEdge(edge: ThreadEdgeEntity(
            childThreadId: child2.toHexDashString(),
            parentThreadId: child1.toHexDashString(),
            agentPath: "/root/grand/great",
            nickname: nil,
            roleAssistantId: nil,
            forkTurns: "all",
            status: "Open",
            createdAt: now
        ))

        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { child2 }
        )
        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "deep"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["error"] as? String, "agent_depth_limit")
        XCTAssertNil(scheduler.startedHandoff)
    }

    /// P1-e 核心行为变化：崩溃残留的 running 行（无活跃注册）不再占用并发槽，
    /// spawn 放行。活注册表计数 = 前台 run(0/1) + 后台 activeJobs + 在途 bootstrap，
    /// 全部与 Room 的全局可恢复行无关。
    func testSpawnAllowsWhenOnlyResidualLedgerRowsExist() async throws {
        let base = makeTempDirectory("SpawnLimit")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        // 4 个残留 running 行（模拟崩溃/恢复扫描前的窗口期），但无前台 run、
        // 无后台 job、无在途 bootstrap → 旧全局账本计数会误伤，新计数放行。
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<4 {
            _ = try await db.agentRuntimeDao().insertRunIfAbsent(run: AgentRunEntity(
                runId: "run-\(index)",
                parentRunId: nil,
                agentDescriptorId: "chat",
                agentVersion: "1",
                conversationId: index == 0 ? parentId.toHexDashString() : nil,
                messageNodeId: nil,
                producesMessageId: nil,
                assistantId: nil,
                status: "running",
                inputDigest: "d",
                inputSnapshotRef: nil,
                inputSchemaVersion: 1,
                startedAt: now,
                finishedAt: nil,
                interruptedReason: nil,
                terminalReason: nil,
                providerId: nil,
                modelId: nil,
                promptVersion: nil,
                toolCatalogVersion: nil,
                capabilitySnapshot: nil
            ))
        }
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )
        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "busy"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNotNil(scheduler.startedHandoff)
    }

    /// P1-e：子代理活注册表满额（2 个子代理 = 默认 2 槽满）→ spawn 拒绝；
    /// 降为 1 个子代理 → 放行。父线程不计入子代理并发。
    func testSpawnRejectsWhenActiveRegistrationsAtCapacity() async throws {
        let base = makeTempDirectory("SpawnLimit")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        scheduler.activeSubAgentJobCount = 2
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId }
        )
        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "busy"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(result["error"] as? String, "agent_limit_reached")
        XCTAssertNil(scheduler.startedHandoff)

        // 边界：1 个子代理 < 默认上限 2 → 放行。
        scheduler.activeSubAgentJobCount = 1
        let retry = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "busy"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r"
        ))
        XCTAssertEqual(retry["ok"] as? Bool, true)
    }

    /// P1-e：并发 spawn 共享在途 bootstrap 槽——限额 1 时两个并发 spawn 恰好
    /// 一个通过（先到者占槽），另一个收到 agent_limit_reached；完成后槽位释放。
    func testConcurrentSpawnsShareInFlightBootstrapSlot() async throws {
        let base = makeTempDirectory("SpawnLimit")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        let service = makeService(
            store: store, db: db, scheduler: scheduler, currentConversationId: { parentId },
            maxConcurrentRuns: 1
        )

        // 两个并发 spawn 在 MainActor 的 await 点交错：先到者完成「检查+占槽」
        // 原子段（无 await），后到者的检查看到在途槽 → 拒绝。
        // 参数先提升为局部量：async let 初始化器不能调用 self 方法（Sendable 限制）。
        let provider = makeProviderSetting()
        let params = makeParams()
        let argsA = spawnArguments(taskName: "inflight_a")
        let argsB = spawnArguments(taskName: "inflight_b")
        async let first = service.execute(
            toolName: "spawn_agent",
            arguments: argsA,
            providerSetting: provider,
            params: params,
            runId: "r1"
        )
        async let second = service.execute(
            toolName: "spawn_agent",
            arguments: argsB,
            providerSetting: provider,
            params: params,
            runId: "r2"
        )
        let outcomes = [parseJSON(await first), parseJSON(await second)]
        let succeeded = outcomes.filter { $0["ok"] as? Bool == true }.count
        let rejected = outcomes.filter { $0["error"] as? String == "agent_limit_reached" }.count
        XCTAssertEqual(succeeded, 1, "限额 1 时并发 spawn 只能有一个通过")
        XCTAssertEqual(rejected, 1, "另一个并发 spawn 必须收到 agent_limit_reached")
        XCTAssertNotNil(scheduler.startedHandoff)

        // 两个 spawn 都结束后在途槽释放 → 新 spawn 恢复。
        let third = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "after"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "r3"
        ))
        XCTAssertEqual(third["ok"] as? Bool, true)
    }

    func testSettingsConcurrencyLimitSupportsTenChildRuns() async throws {
        let base = makeTempDirectory("SpawnLimitTen")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(directory: base)
        await store.newConversation()
        let parentId = try XCTUnwrap(store.currentConversation?.id)
        let db = makeDatabase(directory: base)
        let scheduler = FakeBackgroundScheduler()
        scheduler.activeSubAgentJobCount = 9
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setSubAgentExecutionLimits(maxConcurrentRuns: 10, timeoutMinutes: 5)
        let service = makeService(
            store: store,
            db: db,
            scheduler: scheduler,
            currentConversationId: { parentId },
            sharedSettings: sharedSettings
        )

        let result = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "limit_ten"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "limit-ten"
        ))
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNotNil(scheduler.startedHandoff)

        scheduler.activeSubAgentJobCount = 10
        let rejected = parseJSON(await service.execute(
            toolName: "spawn_agent",
            arguments: spawnArguments(taskName: "limit_ten_rejected"),
            providerSetting: makeProviderSetting(),
            params: makeParams(),
            runId: "limit-ten-rejected"
        ))
        XCTAssertEqual(rejected["error"] as? String, "agent_limit_reached")
    }

}
