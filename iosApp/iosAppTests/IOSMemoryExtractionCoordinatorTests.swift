import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryExtractionCoordinatorTests: XCTestCase {
    func testExplicitDirectiveDetectorExcludesCodeBlocksQuotesAndNonDirectives() {
        XCTAssertTrue(IOSExplicitMemoryIntentDetector.containsExplicitDirective("请记住我偏好简洁中文回复"))
        XCTAssertTrue(IOSExplicitMemoryIntentDetector.containsExplicitDirective("以后都用 pnpm 运行前端脚本"))
        XCTAssertTrue(IOSExplicitMemoryIntentDetector.containsExplicitDirective("From now on, please remember I prefer concise answers"))
        XCTAssertTrue(IOSExplicitMemoryIntentDetector.containsExplicitDirective("Don't ever auto-commit without asking"))

        // Code blocks, inline code, and quoted examples must NOT trigger fast-track.
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective("""
        请帮我解释这段代码：
        ```swift
        // 请记住：这里不能用 force unwrap
        let prompt = "from now on"
        ```
        """))
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective("文档里的 `请记住不要直接写入` 只是示例"))
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective("> 请记住把日志打开\n这行引用不用保存"))
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective(#"用户输入了"以后都用深色主题"但只是举例"#))
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective("用户说「忘掉刚才那个参数」，帮我翻译成英文"))
        XCTAssertFalse(IOSExplicitMemoryIntentDetector.containsExplicitDirective("今天天气不错，我们聊聊 Swift 并发"))
    }

    func testFastTrackPriorityDequeueSkipsIdleChargingNormalBudgetAndRequiresForeground() async throws {
        try await withFixture { f in
            f.settings.setMemoryExtractionSettings(enabled: true, runOnlyOnCharging: true)

            let convNormal = UIMessage.companion.user(prompt: "我通常早上九点开站会")
            _ = await f.store.saveCurrent(messages: [convNormal])
            let normalId = try XCTUnwrap(f.store.currentConversation?.id)

            _ = await f.store.newConversation()
            let explicitUser = UIMessage.companion.user(prompt: "请记住我每周五下午不排会议")
            _ = await f.store.saveCurrent(messages: [explicitUser])
            let convExplicit = try XCTUnwrap(f.store.currentConversation?.id)

            let day = Calendar.current.startOfDay(for: f.fixedNow).timeIntervalSince1970
            let normalQuota = Int(f.settings.agentRuntime.memoryWorker.maxDailyRuns)
            f.defaults.set(["day": day, "count": normalQuota], forKey: "app.amber.ios.memoryExtraction.dailyRuns.v1")

            var isForeground = false
            var calledPrompts: [String] = []
            let provider = StubProvider { prompt in
                calledPrompts.append(prompt)
                return Self.output(content: "我每周五下午不排会议", source: explicitUser)
            }
            let coordinator = f.coordinator(
                provider: provider,
                environment: { (isForeground, false, false) }
            )

            // Normal item queued first, explicit item second.
            coordinator.enqueue(conversationId: normalId, baseline: [convNormal], completed: [convNormal])
            coordinator.enqueue(conversationId: convExplicit, baseline: [explicitUser], completed: [explicitUser])

            // Foreground guard MUST still block even explicit fast-track.
            await coordinator.processPending()
            XCTAssertTrue(calledPrompts.isEmpty)
            XCTAssertEqual(coordinator.pendingCount, 2)

            // Back to foreground while still not idle, not charging, and normal daily quota full:
            // explicit item is dequeued ahead of the blocked normal item without incrementing normal quota.
            isForeground = true
            await coordinator.processPending()

            XCTAssertEqual(calledPrompts.count, 1)
            XCTAssertEqual(f.persistence.records.count, 1)
            XCTAssertEqual(f.persistence.records.first?.content, "我每周五下午不排会议")
            XCTAssertEqual(coordinator.pendingCount, 1)

            let normalBudget = f.defaults.dictionary(forKey: "app.amber.ios.memoryExtraction.dailyRuns.v1")
            XCTAssertEqual(normalBudget?["count"] as? Int, normalQuota)
            let explicitBudget = f.defaults.dictionary(forKey: "app.amber.ios.memoryExtraction.explicitDailyRuns.v1")
            XCTAssertEqual(explicitBudget?["count"] as? Int, 1)
        }
    }

    func testExplicitFastTrackFallsBackToNormalChannelAfterTenDailyRuns() async throws {
        try await withFixture { f in
            f.settings.setMemoryExtractionSettings(enabled: true, runOnlyOnCharging: true)

            _ = await f.store.newConversation()
            let explicitUser = UIMessage.companion.user(prompt: "请记住我只喝美式咖啡")
            _ = await f.store.saveCurrent(messages: [explicitUser])
            let conv = try XCTUnwrap(f.store.currentConversation?.id)

            let day = Calendar.current.startOfDay(for: f.fixedNow).timeIntervalSince1970
            f.defaults.set(["day": day, "count": IOSMemoryExtractionCoordinator.maxExplicitDailyRuns],
                           forKey: "app.amber.ios.memoryExtraction.explicitDailyRuns.v1")

            var charging = false
            var callCount = 0
            let provider = StubProvider { _ in
                callCount += 1
                return Self.output(content: "我只喝美式咖啡", source: explicitUser)
            }
            let coordinator = f.coordinator(
                provider: provider,
                environment: { (true, true, charging) }
            )

            coordinator.enqueue(conversationId: conv, baseline: [explicitUser], completed: [explicitUser])
            await coordinator.processPending()
            XCTAssertEqual(callCount, 0)
            XCTAssertEqual(coordinator.pendingCount, 1)

            // Once normal conditions (charging) are met, it drains via the normal channel.
            charging = true
            await coordinator.processPending()
            XCTAssertEqual(callCount, 1)
            XCTAssertEqual(f.persistence.records.first?.content, "我只喝美式咖啡")
        }
    }

    func testDirectMemoryToolMutationSuppressesExtractionEnqueueWhileReadOrFailureDoesNot() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "请记住我最喜欢的编辑模式是 Vim")
            let writeTool = UIMessagePart.Tool(
                toolCallId: "mem-write-1",
                toolName: "memory_tool",
                input: #"{"action":"create","scope":"long_term","kind":"user","content":"喜欢 Vim"}"#,
                output: [UIMessagePart.Text(text: #"{"ok":true,"id":42}"#, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let base = UIMessage.companion.assistant(prompt: "")
            let toolMessage = base.doCopy(
                id: base.id, role: base.role, parts: [writeTool], annotations: base.annotations,
                createdAt: base.createdAt, finishedAt: base.finishedAt,
                modelId: base.modelId, usage: base.usage, translation: base.translation
            )
            _ = await f.store.saveCurrent(messages: [user, toolMessage])
            let convId = try XCTUnwrap(f.store.currentConversation?.id)

            var callCount = 0
            let provider = StubProvider { _ in
                callCount += 1
                return Self.output(content: "喜欢 Vim", source: user)
            }
            let coordinator = f.coordinator(provider: provider)

            coordinator.enqueue(conversationId: convId, baseline: [user], completed: [user, toolMessage])
            await coordinator.processPending()
            XCTAssertEqual(coordinator.pendingCount, 0)
            XCTAssertEqual(callCount, 0)

            // Read-only memory_tool or failed write must NOT suppress extraction.
            let failedWrite = UIMessagePart.Tool(
                toolCallId: "mem-read-1",
                toolName: "memory_tool",
                input: #"{"action":"list"}"#,
                output: [UIMessagePart.Text(text: #"{"ok":true,"items":[]}"#, metadata: nil)],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let readMsg = base.doCopy(
                id: KotlinUuid.companion.random(), role: base.role, parts: [failedWrite], annotations: base.annotations,
                createdAt: base.createdAt, finishedAt: base.finishedAt,
                modelId: base.modelId, usage: base.usage, translation: base.translation
            )
            _ = await f.store.saveCurrent(messages: [user, readMsg])
            coordinator.enqueue(conversationId: convId, baseline: [user], completed: [user, readMsg])
            XCTAssertGreaterThan(coordinator.pendingCount, 0)
            await coordinator.processPending()
            XCTAssertEqual(callCount, 1)
        }
    }

    func testExplicitExtractionDoesNotWriteAfterAppLeavesForegroundDuringGeneration() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "请记住我只在上午开会")
            _ = await f.store.saveCurrent(messages: [user])
            let conv = try XCTUnwrap(f.store.currentConversation?.id)
            var foreground = true
            let provider = StubProvider { _ in
                foreground = false
                return Self.output(content: "我只在上午开会", source: user)
            }
            let coordinator = f.coordinator(provider: provider, environment: { (foreground, true, true) })
            coordinator.enqueue(conversationId: conv, baseline: [user], completed: [user])
            await coordinator.processPending()
            XCTAssertTrue(f.persistence.records.isEmpty)
            XCTAssertEqual(coordinator.pendingCount, 1)
        }
    }

    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let settings: IOSSharedSettingsStore
        let store: IOSConversationStore
        let persistence: IOSMemoryPersistence
        let audit: IOSMemoryWriteAuditStore
        let fixedNow: Date

        func coordinator(
            provider: any IOSAgentTextProvider,
            environment: @escaping () -> (foreground: Bool, idle: Bool, charging: Bool) = { (true, true, true) }
        ) -> IOSMemoryExtractionCoordinator {
            let coordinator = IOSMemoryExtractionCoordinator(
                defaults: defaults,
                persistence: persistence,
                audit: audit,
                provider: provider,
                environment: environment,
                now: { fixedNow }
            )
            coordinator.configure(settings: settings, conversations: store, writesEnabled: { true })
            return coordinator
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryExtractionCoord-\(UUID().uuidString)")
        let suite = "MemoryExtractionCoord-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            IosMemoryFactory.shared.replaceAll(records: original)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let memoryURL = root.appendingPathComponent("memories/memories.json")
        let persistence = IOSMemoryPersistence(fileURL: memoryURL)
        persistence.load()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
        let store = IOSConversationStore(baseDirectory: root.appendingPathComponent("conversations"))
        await store.bootstrap()
        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let model = Model(
            modelId: "memory-test", displayName: "记忆测试", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
        )
        _ = settings.addProvider(ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(), enabled: true, name: "记忆测试", models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""), builtIn: false,
            descriptionText: nil, shortDescriptionText: nil, apiKey: "test", baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions", useResponseApi: false, authMode: .apiKey, brand: .generic
        ))
        settings.setCompressModelId(model.id.toHexDashString())
        settings.setMemoryRuntimeEnabled(core: true, shortTerm: true, longTerm: true)
        settings.setMemoryExtractionSettings(enabled: true, runOnlyOnCharging: false)
        try await body(Fixture(
            defaults: defaults,
            settings: settings,
            store: store,
            persistence: persistence,
            audit: IOSMemoryWriteAuditStore(userDefaults: defaults),
            fixedNow: Date(timeIntervalSince1970: 1_795_000_000)
        ))
    }

    private static func output(content: String, source: UIMessage) -> String {
        let item: [String: Any] = [
            "content": content,
            "scope": "long_term",
            "kind": "user",
            "sourceMessageId": source.id.toHexDashString(),
            "sensitive": false
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["memories": [item]])
        return String(decoding: data, as: UTF8.self)
    }

    private final class StubProvider: IOSAgentTextProvider, @unchecked Sendable {
        let response: @MainActor (String) async throws -> String
        init(_ response: @escaping @MainActor (String) async throws -> String) { self.response = response }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            let text = try await response(messages.map { $0.toText() }.joined())
            return MessageChunk(
                id: "memory-test",
                model: "memory-test",
                choices: [
                    UIMessageChoice(index: 0, delta: nil, message: UIMessage.companion.assistant(prompt: text), finishReason: "stop")
                ],
                usage: nil
            )
        }
    }
}
