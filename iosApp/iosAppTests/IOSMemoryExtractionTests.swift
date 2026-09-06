import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSMemoryExtractionTests: XCTestCase {
    func testQueuedUserMemorySurvivesRestartAndKeepsConcurrentManualRecord() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            let answer = UIMessage.companion.assistant(prompt: "模型虚构的偏好不能存进记忆")
            _ = await f.store.saveCurrent(messages: [user, answer])
            let sourceId = try XCTUnwrap(f.store.currentConversation?.id)
            let provider = StubProvider { prompt, modelId in
                XCTAssertTrue(prompt.contains("我习惯用中文交流。"))
                XCTAssertFalse(prompt.contains("模型虚构的偏好不能存进记忆"))
                XCTAssertEqual(modelId, "memory-test")
                let before = IosMemoryFactory.shared.snapshotRecords()
                _ = IosMemoryFactory.shared.addMemory(scope: .core, kind: .note, content: "并发手动记录", assistantId: "__global__")
                XCTAssertTrue(f.persistence.persist(previousRecords: before))
                await f.store.newConversation()
                return Self.output(content: "我习惯用中文交流。", source: user, duplicate: true)
            }
            let queued = f.coordinator(provider: provider, environment: { (false, true, false) })
            queued.enqueue(conversationId: sourceId, baseline: [user], completed: [user, answer])
            await queued.processPending()
            XCTAssertEqual(queued.pendingCount, 1)

            let restored = f.coordinator(provider: provider)
            XCTAssertEqual(restored.pendingCount, 1)
            await restored.processPending()
            XCTAssertEqual(restored.pendingCount, 0)
            XCTAssertNotEqual(f.store.currentConversation?.id, sourceId)
            let reloaded = IOSMemoryPersistence(fileURL: f.memoryURL)
            reloaded.load()
            XCTAssertEqual(Set(reloaded.records.map(\.content)), ["并发手动记录", "我习惯用中文交流。"])
            let memory = try XCTUnwrap(reloaded.records.first { $0.kind == .user })
            XCTAssertEqual(memory.sourceConversationId, sourceId.toHexDashString())
            XCTAssertEqual(memory.sourceMessageIds, [user.id.toHexDashString()])
            XCTAssertEqual(f.audit.records.first?.status, "auto_saved")
            XCTAssertFalse(IOSSharedSettingsStore(userDefaults: f.defaults).agentRuntime.memoryWorker.runOnlyOnCharging)
        }
    }

    func testPollutionDuringModelCallPreventsAutomaticWrite() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            var calls = 0
            let provider = StubProvider { _, _ in
                calls += 1
                let marked = await f.store.markConversationMemoryPolluted(id)
                XCTAssertTrue(marked)
                return Self.output(content: "我习惯用中文交流。", source: user)
            }
            let coordinator = f.coordinator(provider: provider)
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()
            XCTAssertTrue(f.persistence.records.isEmpty)
            XCTAssertTrue(coordinator.statusMessage.contains("来源会话已变化"))
            await coordinator.processPending()
            XCTAssertEqual(calls, 1, "已污染的会话不能再次进入模型提炼")
            XCTAssertEqual(coordinator.pendingCount, 0)
        }
    }

    func testChargingAndPermissionGatesThenRejectsUngroundedOutput() async throws {
        try await withFixture { f in
            let user = UIMessage.companion.user(prompt: "我习惯用中文交流。")
            _ = await f.store.saveCurrent(messages: [user])
            let id = try XCTUnwrap(f.store.currentConversation?.id)
            f.settings.setMemoryExtractionSettings(runOnlyOnCharging: true)
            var charging = false
            var writable = true
            var calls = 0
            let provider = StubProvider { _, _ in
                calls += 1
                return Self.output(content: "模型猜测的偏好", source: user)
            }
            let coordinator = f.coordinator(provider: provider, environment: { (true, true, charging) }, writable: { writable })
            coordinator.enqueue(conversationId: id, baseline: [user], completed: [user])
            await coordinator.processPending()
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(coordinator.statusMessage.contains("等待充电"))
            charging = true
            writable = false
            await coordinator.processPending()
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(coordinator.statusMessage.contains("权限已关闭"))
            writable = true
            await coordinator.processPending()
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(f.persistence.records.isEmpty)
            XCTAssertEqual(f.audit.records.first?.status, "failed")
            XCTAssertTrue(coordinator.statusMessage.contains("用户原文校验"))
            await coordinator.processPending()
            XCTAssertEqual(calls, 1, "失败后等待明确重试，不循环消耗模型")
        }
    }

    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let settings: IOSSharedSettingsStore
        let store: IOSConversationStore
        let persistence: IOSMemoryPersistence
        let audit: IOSMemoryWriteAuditStore
        let memoryURL: URL

        func coordinator(
            provider: any IOSAgentTextProvider,
            environment: @escaping () -> (foreground: Bool, idle: Bool, charging: Bool) = { (true, true, true) },
            writable: @escaping () -> Bool = { true }
        ) -> IOSMemoryExtractionCoordinator {
            let coordinator = IOSMemoryExtractionCoordinator(
                defaults: defaults, persistence: persistence, audit: audit, provider: provider, environment: environment
            )
            coordinator.configure(settings: settings, conversations: store, writesEnabled: writable)
            return coordinator
        }
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let original = IosMemoryFactory.shared.snapshotRecords()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryExtraction-\(UUID().uuidString)")
        let suite = "MemoryExtraction-\(UUID().uuidString)"
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
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
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
        try await body(Fixture(defaults: defaults, settings: settings, store: store, persistence: persistence,
                               audit: IOSMemoryWriteAuditStore(userDefaults: defaults), memoryURL: memoryURL))
    }

    private static func output(content: String, source: UIMessage, duplicate: Bool = false) -> String {
        let item: [String: Any] = ["content": content, "scope": "long_term", "kind": "user",
                                   "sourceMessageId": source.id.toHexDashString(), "sensitive": false]
        let data = try! JSONSerialization.data(withJSONObject: ["memories": duplicate ? [item, item] : [item]])
        return String(decoding: data, as: UTF8.self)
    }

    private final class StubProvider: IOSAgentTextProvider, @unchecked Sendable {
        let response: @MainActor (String, String) async throws -> String
        init(_ response: @escaping @MainActor (String, String) async throws -> String) { self.response = response }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            let text = try await response(messages.map { $0.toText() }.joined(), params.model.modelId)
            return MessageChunk(id: "memory-test", model: "memory-test", choices: [
                UIMessageChoice(index: 0, delta: nil, message: UIMessage.companion.assistant(prompt: text), finishReason: "stop")
            ], usage: nil)
        }
    }
}
