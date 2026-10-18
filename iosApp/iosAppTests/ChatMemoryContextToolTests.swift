import XCTest
import WebKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatMemoryContextToolTests: ChatViewModelContextTestCase {

    func testPreparedUploadMessagesIncludeMemoryContextWithoutPersistingSystemMessage() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
        }

        let memoryText = "用户喜欢把复杂任务拆成可验证的小闭环"
        IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.core,
            kind: MemoryKind.note,
            content: memoryText,
            assistantId: IosMemoryFactory.shared.GLOBAL_MEMORY_ID
        )

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.inputText = "帮我规划一下"
        viewModel.sendMessage()

        let uploadMessages = viewModel.preparedUploadMessagesForTesting(viewModel.messages)
        // The memory system message may no longer be `.first` now that the
        // assistant system prompt is also injected (Android parity). Find it by
        // content instead of position.
        let memoryMessage = try XCTUnwrap(uploadMessages.first { textContent(of: $0).contains(memoryText) })
        XCTAssertEqual(memoryMessage.role, MessageRole.system)
        XCTAssertTrue(uploadMessages.contains { $0.role == MessageRole.user })
        XCTAssertFalse(
            viewModel.messages.contains { $0.role == MessageRole.system },
            "memory context should be upload-only and must not pollute persisted chat history"
        )
    }

    func testPreparedUploadMessagesRespectDisabledMemoryScopes() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
        }

        let coreText = "core memory should stay out"
        let longTermText = "long-term memory should remain"
        IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.core,
            kind: MemoryKind.note,
            content: coreText,
            assistantId: IosMemoryFactory.shared.GLOBAL_MEMORY_ID
        )
        IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: longTermText,
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )

        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.restoreSnapshot(
            IosSettingsMutations.shared.setMemoryRuntimeEnabled(
                settings: sharedSettings.snapshot,
                enableCoreMemory: false,
                enableShortTermMemory: false,
                enableLongTermMemory: true
            )
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        viewModel.inputText = "long-term memory should remain，帮我规划一下"
        viewModel.sendMessage()

        let uploadMessages = viewModel.preparedUploadMessagesForTesting(viewModel.messages)
        // Locate the memory system message by content (it's no longer `.first`
        // after the assistant system-prompt injection was added).
        let memoryMessage = try XCTUnwrap(uploadMessages.first { textContent(of: $0).contains(longTermText) })
        let memoryText = textContent(of: memoryMessage)
        XCTAssertFalse(memoryText.contains(coreText))
        XCTAssertTrue(memoryText.contains(longTermText))
    }

    func testMemoryToolDeclarationFollowsRuntimeSwitches() {
        let enabledSettings = memorySettings(core: false, shortTerm: true, longTerm: false)
        let enabledViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: enabledSettings,
            autoGenerateResponses: false
        )
        XCTAssertTrue(Set(enabledViewModel.currentToolDeclarationNames()).contains("memory_tool"))

        let disabledSettings = memorySettings(core: false, shortTerm: false, longTerm: false)
        let disabledViewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: disabledSettings,
            autoGenerateResponses: false
        )
        XCTAssertFalse(Set(disabledViewModel.currentToolDeclarationNames()).contains("memory_tool"))
    }

    func testMiniAppInstructionIsInjectedByDefault() throws {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        XCTAssertTrue(sharedSettings.isCapabilityGateEnabled(.miniApps))
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        viewModel.inputText = "帮我做一个 MiniApp 计时器"
        viewModel.sendMessage()

        let uploadMessages = viewModel.preparedUploadMessagesForTesting(viewModel.messages)
        let miniAppInstruction = uploadMessages
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .first { $0.contains("AmberAgent MiniApp V3") }
        XCTAssertNotNil(miniAppInstruction)
        XCTAssertTrue(miniAppInstruction?.contains("Schema:") == true)
        XCTAssertTrue(miniAppInstruction?.contains(#""permissions""#) == true)
        XCTAssertTrue(miniAppInstruction?.contains(#""html""#) == true)
    }

    func testMemoryToolCreateEditDeletePersistsAndFeedsPrompt() throws {
        IOSMemoryPersistence.shared.load()
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            let testRecords = IosMemoryFactory.shared.snapshotRecords()
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
            IOSMemoryPersistence.shared.persist(previousRecords: testRecords)
        }

        let sharedSettings = memorySettings(core: true, shortTerm: true, longTerm: true)
        let createOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"long_term","kind":"user","content":"用户喜欢先做端到端验证","pinned":true,"confidence":0.8}"#,
            runtime: sharedSettings.agentRuntime,
            writePolicy: .allow
        )
        let createPayload = try jsonObject(createOutput)
        XCTAssertEqual(createPayload["ok"] as? Bool, true)

        var record = try XCTUnwrap(IosMemoryFactory.shared.getAllRecords().first)
        let id = Int(record.id)
        let lastUsedAtBeforeEdit = record.lastUsedAt?.int64Value
        XCTAssertEqual(record.scope, MemoryScope.longTerm)
        XCTAssertEqual(record.kind, MemoryKind.user)
        XCTAssertTrue(record.pinned)
        XCTAssertEqual(record.confidence, 0.8, accuracy: 0.001)

        let editedText = "用户喜欢先做端到端验证，再提交小批量改动"
        let editOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"edit","id":\#(id),"scope":"short_term","kind":"project","content":"\#(editedText)","pinned":false}"#,
            runtime: sharedSettings.agentRuntime,
            writePolicy: .allow
        )
        let editPayload = try jsonObject(editOutput)
        XCTAssertEqual(editPayload["ok"] as? Bool, true)

        record = try XCTUnwrap(IosMemoryFactory.shared.getAllRecords().first { Int($0.id) == id })
        XCTAssertEqual(record.content, editedText)
        XCTAssertEqual(record.scope, MemoryScope.shortTerm)
        XCTAssertEqual(record.kind, MemoryKind.project)
        XCTAssertFalse(record.pinned)
        XCTAssertEqual(record.lastUsedAt?.int64Value, lastUsedAtBeforeEdit)

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            autoGenerateResponses: false
        )
        viewModel.inputText = "端到端验证后，下一步怎么做"
        viewModel.sendMessage()

        let uploadMessages = viewModel.preparedUploadMessagesForTesting(viewModel.messages)
        // Locate the memory prompt by content (assistant system-prompt injection
        // means the memory message is no longer `.first`).
        let memoryPrompt = textContent(of: try XCTUnwrap(uploadMessages.first { textContent(of: $0).contains(editedText) }))
        XCTAssertTrue(memoryPrompt.contains(editedText))
        XCTAssertTrue(memoryPrompt.contains("[short_term/project]"))

        let deleteOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"delete","id":\#(id)}"#,
            runtime: sharedSettings.agentRuntime,
            writePolicy: .allow
        )
        let deletePayload = try jsonObject(deleteOutput)
        XCTAssertEqual(deletePayload["ok"] as? Bool, true)
        XCTAssertFalse(IosMemoryFactory.shared.getAllRecords().contains { Int($0.id) == id })
    }

    func testMemoryToolRejectsDisabledScope() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
        }

        let sharedSettings = memorySettings(core: false, shortTerm: false, longTerm: true)
        let output = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"core","content":"disabled scope should not save"}"#,
            runtime: sharedSettings.agentRuntime,
            writePolicy: .allow
        )
        let payload = try jsonObject(output)

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["scope"] as? String, "core")
        XCTAssertTrue(IosMemoryFactory.shared.getAllRecords().isEmpty)
    }

    func testMemoryToolRejectsUnknownScopeAndKind() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }
        let runtime = memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime

        let scopePayload = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"unknown","content":"must not save"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        let kindPayload = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"core","kind":"unknown","content":"must not save"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))

        XCTAssertEqual(scopePayload["error"] as? String, "invalid memory scope")
        XCTAssertEqual(kindPayload["error"] as? String, "invalid memory kind")
        XCTAssertTrue(IosMemoryFactory.shared.getAllRecords().isEmpty)
    }

    func testDeleteApprovalPreviewShowsStoredTargetContent() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }
        let record = MemoryRecord(
            id: 77,
            content: "删除前必须展示的记忆正文",
            scope: .core,
            kind: .note,
            assistantId: IosMemoryFactory.shared.GLOBAL_MEMORY_ID,
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1,
            pinned: false,
            archived: false,
            createdAt: 1,
            updatedAt: 1,
            lastUsedAt: nil,
            topicTitle: nil,
            memberIds: [], lastReinforcedAt: nil
        )
        IosMemoryFactory.shared.replaceAll(records: [record])

        let preview = try XCTUnwrap(IOSMemoryToolExecutor.approvalPreview(
            input: #"{"action":"delete","id":77}"#
        ))

        XCTAssertEqual(preview.targetId, 77)
        XCTAssertEqual(preview.contentPreview, "删除前必须展示的记忆正文")
    }

    func testDeniedMemoryWriteAuditDoesNotPersistContentPreview() {
        let auditStore = IOSMemoryWriteAuditStore.shared
        auditStore.clear()
        defer { auditStore.clear() }

        _ = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"core","content":"sensitive denied content"}"#,
            runtime: memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime,
            writePolicy: .deniedByUser("user denied")
        )

        XCTAssertEqual(auditStore.records.first?.status, "denied_by_user")
        XCTAssertNil(auditStore.records.first?.contentPreview)
    }

    func testMemoryToolWritePolicyBlocksMutationButAllowsList() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
        }

        let sharedSettings = memorySettings(core: true, shortTerm: true, longTerm: true)
        IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "list should remain readable",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )

        let listOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"list","scope":"long_term"}"#,
            runtime: sharedSettings.agentRuntime,
            writePolicy: .needsUserAction("writes blocked")
        )
        let listPayload = try jsonObject(listOutput)
        XCTAssertEqual(listPayload["ok"] as? Bool, true)
        XCTAssertEqual(listPayload["count"] as? Int, 1)

        let createOutput = IOSMemoryToolExecutor.execute(
            input: #"{"action":"create","scope":"long_term","content":"should not save"}"#,
            runtime: sharedSettings.agentRuntime,
            writePolicy: .needsUserAction("Memory writes require foreground approval.")
        )
        let createPayload = try jsonObject(createOutput)
        XCTAssertEqual(createPayload["ok"] as? Bool, false)
        XCTAssertEqual(createPayload["needs_user_action"] as? Bool, true)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().count, 1)
    }

    func testMemoryToolReadReturnsExactRecordAndStructuredMiss() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }

        let runtime = memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime
        let record = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "端到端验证先行",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )
        let id = Int(record.id)

        let hit = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"read","id":\#(id)}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(hit["ok"] as? Bool, true)
        let memory = try XCTUnwrap(hit["memory"] as? [String: Any])
        XCTAssertEqual(memory["id"] as? Int, id)
        XCTAssertEqual(memory["content"] as? String, "端到端验证先行")

        let miss = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"read","id":999999}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(miss["ok"] as? Bool, false)
        XCTAssertEqual(miss["error"] as? String, "memory not found")
        XCTAssertTrue((miss["hint"] as? String)?.contains("list") ?? false)
    }

    func testMemoryToolSearchRanksByRelevance() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }

        let runtime = memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime
        let first = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "用户偏好深色主题与简洁界面",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )
        let second = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "设计稿里要用到界面布局",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )
        _ = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "午餐吃什么",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )

        let output = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"search","query":"主题 界面"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(output["ok"] as? Bool, true)
        XCTAssertEqual(output["query"] as? String, "主题 界面")
        let memories = try XCTUnwrap(output["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.compactMap { $0["id"] as? Int }, [Int(first.id), Int(second.id)])

        // query 与 search 同语义（q 别名也生效）；只命中第一条
        let queryOutput = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"query","q":"主题"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        let queryMemories = try XCTUnwrap(queryOutput["memories"] as? [[String: Any]])
        XCTAssertEqual(queryMemories.compactMap { $0["id"] as? Int }, [Int(first.id)])
    }

    func testMemoryToolSearchRespectsLimitAndDefaultCap() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }

        let runtime = memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime
        for index in 0..<12 {
            _ = IosMemoryFactory.shared.addMemory(
                scope: MemoryScope.longTerm,
                kind: MemoryKind.note,
                content: "主题相关记录 \(index)",
                assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
            )
        }

        let defaultOutput = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"search","query":"主题"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(defaultOutput["count"] as? Int, 10)

        let cappedOutput = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"search","query":"主题","limit":5}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(cappedOutput["count"] as? Int, 5)
    }

    func testMemoryToolStatusReturnsSummaryNotDump() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }
        IosMemoryFactory.shared.replaceAll(records: [])

        let runtime = memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime
        _ = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "长时记忆一",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )
        _ = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: "长时记忆二",
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )
        let archived = MemoryRecord(
            id: 4242,
            content: "已归档的核心记忆",
            scope: .core,
            kind: .note,
            assistantId: IosMemoryFactory.shared.GLOBAL_MEMORY_ID,
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1,
            pinned: false,
            archived: true,
            createdAt: 1,
            updatedAt: 1,
            lastUsedAt: nil,
            topicTitle: nil,
            memberIds: [], lastReinforcedAt: nil
        )
        IosMemoryFactory.shared.replaceAll(records: IosMemoryFactory.shared.getAllRecords() + [archived])

        let output = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"status"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(output["ok"] as? Bool, true)
        XCTAssertEqual(output["available"] as? Bool, true)
        XCTAssertEqual(output["visibleCount"] as? Int, 2)
        XCTAssertEqual(output["archivedCount"] as? Int, 1)
        XCTAssertNil(output["memories"])

        let scopes = try XCTUnwrap(output["scopes"] as? [[String: Any]])
        let longTerm = try XCTUnwrap(scopes.first { $0["scope"] as? String == "long_term" })
        XCTAssertEqual(longTerm["enabled"] as? Bool, true)
        XCTAssertEqual(longTerm["visible"] as? Int, 2)
        let core = try XCTUnwrap(scopes.first { $0["scope"] as? String == "core" })
        XCTAssertEqual(core["archived"] as? Int, 1)

        let recallDefaults = try XCTUnwrap(output["recallDefaults"] as? [String: Any])
        XCTAssertEqual(recallDefaults["maxItems"] as? Int, 24)
        XCTAssertEqual(recallDefaults["maxPromptChars"] as? Int, 6_000)
    }

    func testMemoryToolListTruncatesContentAndCapsCount() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer { IosMemoryFactory.shared.replaceAll(records: originalRecords) }

        let runtime = memorySettings(core: true, shortTerm: true, longTerm: true).agentRuntime
        for index in 0..<60 {
            _ = IosMemoryFactory.shared.addMemory(
                scope: MemoryScope.longTerm,
                kind: MemoryKind.note,
                content: "记录 \(index)",
                assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
            )
        }
        // updatedAt 只有毫秒精度；跨过一个 tick，避免 61 次快速插入同毫秒时
        // 退化到 id 排序、把最后的长记录挤出前 50 条。
        Thread.sleep(forTimeInterval: 0.01)
        _ = IosMemoryFactory.shared.addMemory(
            scope: MemoryScope.longTerm,
            kind: MemoryKind.note,
            content: String(repeating: "长", count: 700),
            assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
        )

        let output = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"list"}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(output["ok"] as? Bool, true)
        XCTAssertEqual(output["count"] as? Int, 50)
        XCTAssertEqual(output["total"] as? Int, 61)
        XCTAssertEqual(output["truncated"] as? Bool, true)

        let memories = try XCTUnwrap(output["memories"] as? [[String: Any]])
        let longPayload = try XCTUnwrap(memories.first {
            ($0["content"] as? String)?.hasSuffix("...") == true
        })
        XCTAssertEqual(longPayload["truncated"] as? Bool, true)
        XCTAssertTrue((longPayload["content"] as? String)?.hasSuffix("...") ?? false)
        XCTAssertEqual((longPayload["content"] as? String)?.count, 503)
        // 未超限记录不带 truncated 标记
        let shortPayload = try XCTUnwrap(memories.first {
            ($0["content"] as? String)?.hasPrefix("记录 ") == true
        })
        XCTAssertNil(shortPayload["truncated"])

        // 入参 limit 生效
        let limitedOutput = try jsonObject(IOSMemoryToolExecutor.execute(
            input: #"{"action":"list","limit":5}"#,
            runtime: runtime,
            writePolicy: .allow
        ))
        XCTAssertEqual(limitedOutput["count"] as? Int, 5)
    }

    func testChatMemoryToolModelWriteRequiresForegroundApproval() throws {
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
        }

        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore()
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: memorySettings(core: true, shortTerm: true, longTerm: true),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        let input = #"{"action":"create","scope":"long_term","kind":"project","content":"model write should wait"}"#

        let request = try XCTUnwrap(viewModel.memoryApprovalRequestForTesting(input: input))
        XCTAssertEqual(request.action, "create")
        XCTAssertEqual(request.title, "保存记忆")
        XCTAssertEqual(request.scope, "long_term")
        XCTAssertEqual(request.kind, "project")
        XCTAssertEqual(request.contentPreview, "model write should wait")

        let output = viewModel.memoryToolOutputForTesting(input: input)
        let payload = try jsonObject(output)

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["needs_user_action"] as? Bool, true)
        XCTAssertTrue(IosMemoryFactory.shared.getAllRecords().isEmpty)
    }

    func testMemoryToolApprovalAllowWritesAndDenyDoesNotWrite() throws {
        IOSMemoryPersistence.shared.load()
        let originalRecords = IosMemoryFactory.shared.getAllRecords()
        IosMemoryFactory.shared.replaceAll(records: [])
        defer {
            let testRecords = IosMemoryFactory.shared.snapshotRecords()
            IosMemoryFactory.shared.replaceAll(records: originalRecords)
            IOSMemoryPersistence.shared.persist(previousRecords: testRecords)
        }

        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore()
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: memorySettings(core: true, shortTerm: true, longTerm: true),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        let input = #"{"action":"create","scope":"long_term","content":"approved memory write"}"#

        let deniedOutput = viewModel.memoryToolApprovalOutputForTesting(input: input, allow: false)
        let deniedPayload = try jsonObject(deniedOutput)
        XCTAssertEqual(deniedPayload["ok"] as? Bool, false)
        XCTAssertEqual(deniedPayload["denied"] as? Bool, true)
        XCTAssertEqual(deniedPayload["policy"] as? String, "user_denied")
        XCTAssertTrue(IosMemoryFactory.shared.getAllRecords().isEmpty)

        let allowedOutput = viewModel.memoryToolApprovalOutputForTesting(input: input, allow: true)
        let allowedPayload = try jsonObject(allowedOutput)
        XCTAssertEqual(allowedPayload["ok"] as? Bool, true)
        XCTAssertEqual(IosMemoryFactory.shared.getAllRecords().map(\.content), ["approved memory write"])
    }

    private func memorySettings(core: Bool, shortTerm: Bool, longTerm: Bool) -> IOSSharedSettingsStore {
        let store = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        store.restoreSnapshot(
            IosSettingsMutations.shared.setMemoryRuntimeEnabled(
                settings: store.snapshot,
                enableCoreMemory: core,
                enableShortTermMemory: shortTerm,
                enableLongTermMemory: longTerm
            )
        )
        return store
    }
}
