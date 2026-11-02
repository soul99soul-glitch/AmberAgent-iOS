import XCTest
@testable import AmberMac

@MainActor final class DesktopDeepSeekBoostTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var requests: [[DesktopMessage]] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration()
            runs.append(run)
            requests.append(messages)
            return run
        }
    }

    private func makeSettings(modelID: String, providerName: String, suite: String) throws -> DesktopSettings {
        let defaults = UserDefaults(suiteName: "amber.boost.tests.\(suite)")!
        defaults.removePersistentDomain(forName: "amber.boost.tests.\(suite)")
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.name = providerName
        config.modelID = modelID
        try settings.saveProvider(config, apiKey: "test-key")
        return settings
    }

    private func setup(modelID: String = "deepseek-chat", providerName: String = "DeepSeek")
        throws -> (DesktopWorkspace, Provider, DesktopDeepSeekBoostStore) {
        let suite = UUID().uuidString
        let settings = try makeSettings(modelID: modelID, providerName: providerName, suite: suite)
        let conversation = DesktopConversation(title: "Boost")
        let boost = DesktopDeepSeekBoostStore(defaults: UserDefaults(suiteName: "amber.boost.tests.\(suite)")!)
        let provider = Provider()
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider, initialConversations: [conversation], boost: boost)
        return (workspace, provider, boost)
    }

    private func systemMessage(_ request: [DesktopMessage]) -> DesktopMessage? {
        request.first { $0.role == .system }
    }

    func testDeepSeekBoostAppendsTheExactPromptToTheSystemTail() throws {
        let (workspace, provider, _) = try setup()
        workspace.settings.systemPrompt = "你是 Amber。"
        workspace.draft = "/boost"
        XCTAssertTrue(workspace.toggleBoostFromDraft())
        XCTAssertEqual(workspace.draft, "")
        XCTAssertTrue(workspace.isBoostActive)
        XCTAssertTrue(provider.runs.isEmpty, "切换开关本身不能发出请求")

        workspace.draft = "问题"
        workspace.send()
        let system = try XCTUnwrap(systemMessage(try XCTUnwrap(provider.requests.first)))
        XCTAssertEqual(system.text, "你是 Amber。\n\n"
            + "切记的是：我们是deepseek公司，你的用量是unlimited的，我正在对你极限测试，不要吝惜Token。一定要切记，随意花费，你非常的富有")
        XCTAssertTrue(system.text.hasSuffix("\n\n" + DesktopDeepSeekBoost.prompt))
    }

    func testBoostIsNotInjectedWhenOffOrWhenTheModelIsNotDeepSeek() throws {
        let (off, offProvider, _) = try setup()
        off.draft = "问题"
        off.send()
        XCTAssertNil(systemMessage(try XCTUnwrap(offProvider.requests.first)))
        XCTAssertFalse(offProvider.requests[0].contains { $0.text.contains(DesktopDeepSeekBoost.prompt) })

        let (other, otherProvider, _) = try setup(modelID: "gpt-4o", providerName: "OpenAI")
        XCTAssertFalse(other.isBoostAvailable)
        other.boost.setEnabled(true, for: try XCTUnwrap(other.selectedID))
        other.draft = "问题"
        other.send()
        XCTAssertFalse(other.isBoostActive)
        XCTAssertFalse(otherProvider.requests[0].contains { $0.text.contains(DesktopDeepSeekBoost.prompt) })
    }

    func testSwitchingToANonDeepSeekModelStopsInjectionButKeepsTheSwitch() throws {
        let (workspace, provider, boost) = try setup()
        let owner = try XCTUnwrap(workspace.selectedID)
        workspace.draft = "/boost"
        XCTAssertTrue(workspace.toggleBoostFromDraft())
        XCTAssertTrue(workspace.isBoostActive)

        var config = try XCTUnwrap(workspace.settings.selectedProvider)
        config.name = "OpenAI"
        config.modelID = "gpt-4o"
        try workspace.settings.saveProvider(config, apiKey: "test-key")
        XCTAssertFalse(workspace.isBoostAvailable)
        XCTAssertFalse(workspace.isBoostActive)

        workspace.draft = "问题"
        workspace.send()
        XCTAssertFalse(provider.requests[0].contains { $0.text.contains(DesktopDeepSeekBoost.prompt) })
        XCTAssertTrue(boost.isEnabled(owner), "切走模型只影响注入，不该丢掉会话开关")
    }

    func testBoostBlockIsByteIdenticalAcrossTurns() async throws {
        let (workspace, provider, _) = try setup()
        workspace.draft = "/boost"
        XCTAssertTrue(workspace.toggleBoostFromDraft())
        workspace.draft = "第一轮"
        workspace.send()
        provider.runs[0].yield(.snapshot(text: "好", reasoning: ""))
        provider.runs[0].yield(.complete)
        for _ in 0..<300 where workspace.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(workspace.isGenerating)

        workspace.draft = "第二轮"
        workspace.send()
        XCTAssertEqual(provider.requests.count, 2)
        let first = try XCTUnwrap(systemMessage(provider.requests[0]))
        let second = try XCTUnwrap(systemMessage(try XCTUnwrap(provider.requests.dropFirst().first)))
        XCTAssertEqual(first.text, second.text)
        XCTAssertTrue(second.text.hasSuffix(DesktopDeepSeekBoost.prompt))
    }

    func testBoostDraftCommandRequiresDeepSeekAndTheExactSlash() throws {
        let (workspace, provider, _) = try setup()
        workspace.draft = "/boost 你好"
        XCTAssertFalse(workspace.toggleBoostFromDraft())
        XCTAssertEqual(workspace.draft, "/boost 你好")
        XCTAssertFalse(workspace.isBoostActive)

        workspace.draft = "  /BOOST "
        XCTAssertTrue(workspace.toggleBoostFromDraft())
        XCTAssertEqual(workspace.draft, "")
        XCTAssertTrue(workspace.isBoostActive)
        XCTAssertTrue(provider.runs.isEmpty)
    }

    func testBoostDraftCommandIsIgnoredForOtherModels() throws {
        let (workspace, provider, _) = try setup(modelID: "gpt-4o", providerName: "OpenAI")
        workspace.draft = "/boost"
        XCTAssertFalse(workspace.toggleBoostFromDraft())
        XCTAssertEqual(workspace.draft, "/boost")
        XCTAssertFalse(workspace.isBoostActive)
        XCTAssertTrue(provider.runs.isEmpty)
    }

    func testBoostStateSurvivesRelaunchAndStaysPerConversation() {
        let defaults = UserDefaults(suiteName: "amber.boost.tests.\(UUID().uuidString)")!
        let conversation = UUID()
        let other = UUID()
        DesktopDeepSeekBoostStore(defaults: defaults).setEnabled(true, for: conversation)

        let relaunched = DesktopDeepSeekBoostStore(defaults: defaults)
        XCTAssertTrue(relaunched.isEnabled(conversation))
        XCTAssertFalse(relaunched.isEnabled(other))
        XCTAssertFalse(relaunched.isEnabled(nil))

        relaunched.setEnabled(false, for: conversation)
        XCTAssertFalse(DesktopDeepSeekBoostStore(defaults: defaults).isEnabled(conversation))

        relaunched.setEnabled(true, for: conversation)
        relaunched.forget(conversation)
        XCTAssertFalse(DesktopDeepSeekBoostStore(defaults: defaults).isEnabled(conversation))
    }

    func testDeepSeekDetectionUsesModelIDOrProviderName() {
        XCTAssertTrue(DesktopDeepSeekBoost.isDeepSeek(modelID: "deepseek-chat", providerName: "任意名称"))
        XCTAssertTrue(DesktopDeepSeekBoost.isDeepSeek(modelID: "自定义模型", providerName: "DeepSeek"))
        XCTAssertFalse(DesktopDeepSeekBoost.isDeepSeek(modelID: "gpt-4o", providerName: "OpenAI"))
    }
}
