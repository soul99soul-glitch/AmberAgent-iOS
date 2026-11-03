import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Agent 化身（Soul）存储与工具的最小契约测试。
///
/// 只覆盖会影响用户可见行为的三件事：称呼/签名/正文能存住、旧版进快照可回退、
/// 注入片段只在有内容时出现且带称呼。不做渲染或网络验证。
@MainActor
final class AgentSoulStoreTests: XCTestCase {

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "AgentSoulStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    func testUpdatePersistsAndInjectsDisplayName() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var posted: [String] = []
        let store = AgentSoulStore(userDefaults: defaults, notePoster: { posted.append($0) })

        XCTAssertEqual(store.displayName, AgentSoulStore.defaultDisplayName)
        XCTAssertTrue(store.isDefault)

        let changed = store.update(
            displayName: "赵大哥",
            tagline: "《燕云十六声》里亲切和蔼的老哥",
            soulPrompt: "说话慢半拍，爱用北方口语，逗逼但靠得住。",
            summary: "对话自塑"
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(store.displayName, "赵大哥")
        XCTAssertFalse(store.isDefault)

        // 正文必须写进既有的 soul 注入通道，否则 system prompt 拿不到。
        XCTAssertEqual(posted.last, "说话慢半拍，爱用北方口语，逗逼但靠得住。")
        let section = store.systemPromptSection
        XCTAssertTrue(section.contains("赵大哥"))
        XCTAssertTrue(section.contains("北方口语"))

        // 重新读盘仍是新值。
        let reloaded = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        XCTAssertEqual(reloaded.displayName, "赵大哥")
        XCTAssertEqual(reloaded.tagline, "《燕云十六声》里亲切和蔼的老哥")
    }

    func testUpdateSnapshotsPreviousVersionAndCanRollBack() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "赵大哥", tagline: nil, soulPrompt: "第一版人设", summary: "v1")
        store.update(displayName: "赵大哥", tagline: nil, soulPrompt: "第二版人设", summary: "v2")

        XCTAssertEqual(store.soulPrompt, "第二版人设")
        // 首次设置前是空白默认态，不值得占一档；所以两次写入只留下 v1 这一条。
        XCTAssertEqual(store.snapshots.count, 1)
        let firstSnapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(firstSnapshot.soulPrompt, "第一版人设")

        XCTAssertTrue(store.restore(snapshotID: firstSnapshot.id))
        XCTAssertEqual(store.soulPrompt, "第一版人设")
        // 回退本身也会压栈，保证还能再撤回。
        XCTAssertEqual(store.snapshots.count, 2)
    }

    func testSnapshotStackIsCappedAtEight() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "Amber", tagline: nil, soulPrompt: "seed", summary: "seed")
        for index in 0..<12 {
            store.update(displayName: "Amber", tagline: nil, soulPrompt: "版本 \(index)", summary: "v\(index)")
        }
        XCTAssertEqual(store.snapshots.count, AgentSoulStore.maximumSnapshots)
    }

    func testResetToDefaultClearsAndKeepsRollback() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "赵大哥", tagline: "老哥", soulPrompt: "人设", summary: "v1")
        XCTAssertTrue(store.resetToDefault())
        XCTAssertTrue(store.isDefault)
        XCTAssertEqual(store.displayName, AgentSoulStore.defaultDisplayName)
        XCTAssertEqual(store.soulPrompt, "")
        XCTAssertFalse(store.snapshots.isEmpty, "恢复默认前必须留下可回退快照")
    }

    func testDefaultStoreInjectsNothing() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        // 默认状态下不往 system prompt 塞任何东西，避免污染普通对话。
        XCTAssertEqual(store.systemPromptSection, "")
    }

    // MARK: - 工具

    func testSoulToolGetReturnsCurrentSoul() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        store.update(displayName: "赵大哥", tagline: "老哥", soulPrompt: "人设正文", summary: "v1")

        let service = AgentSoulToolService(store: store)
        let json = service.execute(toolName: AgentSoulToolCatalog.getToolName, arguments: "{}")
        XCTAssertTrue(json.contains("\"status\":\"ok\""))
        XCTAssertTrue(json.contains("赵大哥"))
        XCTAssertTrue(json.contains("人设正文"))
    }

    func testSoulToolUpdateAppliesAndReportsChange() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let service = AgentSoulToolService(store: store)

        let arguments = #"{"displayName":"赵大哥","tagline":"老哥","soulPrompt":"新写的人设","summary":"对话自塑"}"#
        let json = service.execute(toolName: AgentSoulToolCatalog.updateToolName, arguments: arguments)

        XCTAssertTrue(json.contains("\"changed\":true"))
        XCTAssertEqual(store.displayName, "赵大哥")
        XCTAssertEqual(store.soulPrompt, "新写的人设")
        XCTAssertEqual(store.source, .conversation)
    }

    func testSoulToolUpdateRejectsEmptyPayload() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let service = AgentSoulToolService(store: store)
        let json = service.execute(
            toolName: AgentSoulToolCatalog.updateToolName,
            arguments: #"{"displayName":"","tagline":"","soulPrompt":""}"#
        )
        XCTAssertTrue(json.contains("empty_update"))
        XCTAssertTrue(store.isDefault, "空更新不得改动既有设定")
    }

    func testSoulUpdateToolNeedsNoApproval() {
        // 产品决定：对话内自塑人设免审批。若将来改回审批，这里会先失败。
        XCTAssertTrue(AgentSoulToolCatalog.toolNames.contains("agent_soul_get"))
        XCTAssertTrue(AgentSoulToolCatalog.toolNames.contains("agent_soul_update"))
        XCTAssertFalse(
            AgentSoulToolCatalog.toolNames.contains(where: { $0.contains("soul_import") }),
            "旧的 soul_import 仍是独立的高风险导入工具，不应被混入"
        )
    }

    func testRuntimeContextBuilderInjectsSoulEmbodimentAndPreservesLegacyMarkdown() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var credentials: [String: String] = [:]
        let settings = IOSSharedSettingsStore(
            userDefaults: defaults,
            loadCredential: { credentials[$0] },
            storeCredential: { credentials[$0] = $1; return true },
            deleteCredential: { credentials.removeValue(forKey: $0); return true }
        )
        let soulStore = AgentSoulStore(userDefaults: defaults, notePoster: { _ in })
        let baseMessages = [UIMessage.companion.user(prompt: "你好")]

        settings.setAgentSoulMarkdown("")
        let emptyPrepared = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: .shared,
            miniAppRuntimeEnabled: false,
            soulStore: soulStore
        ).injectingRuntimeContext(into: baseMessages, coalesceSystemMessages: false)
        XCTAssertFalse(emptyPrepared.contains { $0.toText().contains("<agents_md>") })

        settings.setAgentSoulMarkdown("# Legacy Soul Rule\nYou are Amber, a personal agent on the user's device.")
        let legacyPrepared = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: .shared,
            miniAppRuntimeEnabled: false,
            soulStore: soulStore
        ).injectingRuntimeContext(into: baseMessages, coalesceSystemMessages: false)
        XCTAssertTrue(legacyPrepared.contains { $0.toText().contains("# Legacy Soul Rule") })

        soulStore.update(
            displayName: "赵大哥",
            tagline: "燕云十六声热心老哥",
            soulPrompt: "说话豪爽接地气，自称老哥。",
            summary: "测试自塑"
        )
        let embodiedPrepared = ChatRuntimeContextBuilder(
            sharedSettings: settings,
            mcpTools: [],
            miniAppRepository: .shared,
            miniAppRuntimeEnabled: false,
            soulStore: soulStore
        ).injectingRuntimeContext(into: baseMessages, coalesceSystemMessages: false)
        let soulSystemText = embodiedPrepared
            .filter { $0.role == MessageRole.system }
            .map { $0.toText() }
            .joined(separator: "\n")
        XCTAssertTrue(soulSystemText.contains("赵大哥"))
        XCTAssertTrue(soulSystemText.contains("燕云十六声热心老哥"))
        XCTAssertTrue(soulSystemText.contains("说话豪爽接地气，自称老哥。"))
        XCTAssertTrue(soulSystemText.contains("# Legacy Soul Rule"))
        XCTAssertTrue(soulSystemText.contains("You are 赵大哥, a personal agent on the user's device."))
        XCTAssertFalse(soulSystemText.contains("You are Amber, a personal agent on the user's device."))
    }
}
