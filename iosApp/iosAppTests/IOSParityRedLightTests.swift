import XCTest
@preconcurrency import Shared
@testable import iosApp

/// P0 red-light tests for the ios-parity-closure goal.
///
/// Each test here codifies a CONFIRMED parity gap as a white-box test that does
/// NOT depend on a live API key. These are the "named red-lights" from
/// GOAL_ios_parity_closure.md (P0 exit, lines 59-68): they MUST currently be RED
/// (the gap is real), and later phases (P0.5–P5) turn them GREEN.
///
/// Naming convention is the spec's snake_case (`test_<capability>_<scenario>`)
/// even though the rest of the suite uses camelCase — the spec names are the
/// contract that verify/refute check against, so they are kept verbatim.
///
/// Why each is RED is documented per-test. The truth_matrix cell each one binds
/// is noted in the doc comment.
@MainActor
final class IOSParityRedLightTests: XCTestCase {

    func testRouterPathGoBackRemovesOnlyTheTopRoute() {
        let router = RouterPath()
        // 聊天是根：`.chat` 被吸收，栈里只剩真正被 push 的页面。
        router.path = [.chat, .settings]

        router.goBack()

        XCTAssertEqual(router.path, [])
        XCTAssertTrue(router.isShowingChat)
    }

    func testToolBudgetExhaustionInjectsWrapUpPromptAndKeepsConversation() {
        let userMessage = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [UIMessagePart.Text(text: "查资料后写一份总结", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )

        let belowLimit = ChatGenerationSupport.continuationMessagesAfterToolBudgetExhaustion(
            [userMessage],
            resumeCount: 3,
            maxResumeCount: 4
        )
        XCTAssertEqual(belowLimit.count, 1, "预算未耗尽时不得注入收尾提示")

        let atLimit = ChatGenerationSupport.continuationMessagesAfterToolBudgetExhaustion(
            [userMessage],
            resumeCount: 4,
            maxResumeCount: 4
        )
        XCTAssertEqual(atLimit.count, 2, "预算耗尽时注入一条收尾系统提示")
        XCTAssertEqual(atLimit.first?.role, MessageRole.system)
        let prompt = atLimit.first?.toText() ?? ""
        XCTAssertTrue(prompt.contains("总结收尾"))
        XCTAssertTrue(prompt.contains("未完成"))
        XCTAssertEqual(atLimit.last?.role, MessageRole.user)
    }

    // MARK: - shared fixtures

    /// A Claude provider as it would be constructed for a user who selected
    /// Anthropic as their chat provider. Mirrors the KMP
    /// `ProviderSetting.Claude` shape (ProviderSetting.kt:310).
    func makeClaudeProvider(apiKey: String = "sk-ant-test-SECRET") -> ProviderSetting.Claude {
        ProviderSetting.Claude(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "Claude",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: apiKey,
            baseUrl: "https://api.anthropic.com/v1",
            promptCaching: false
        )
    }

    func makeOpenAIProvider(apiKey: String = "sk-test-SECRET") -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "OpenAI-compatible",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: apiKey,
            baseUrl: "https://api.example.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    // MARK: - SubAgent (truth_matrix row `subagent_standalone`)

    // MARK: - Council (truth_matrix row `council`)

    /// RED for P0. GREEN target: P3 (now GREEN).
    /// Cell: council.provider_real.
    ///
    /// When the user has selected a Claude provider, Council must construct a
    /// `ProviderSetting.Claude` (native /messages), not silently rebuild an
    /// OpenAI setting. P3 added `IOSCouncilRoomRunner.resolveProviderSetting`
    /// (SLICE_TEMPLATE pattern 1, copied from DeepRead) and routed both council
    /// entries through it. The lower-level streamer dispatches on the sealed
    /// type, so a Claude setting flows to native.
    func test_council_claudeSelected_constructsClaudeSetting() {
        let selectedClaude = makeClaudeProvider()
        let resolved = councilResolvedProvider(forSelected: selectedClaude)

        XCTAssertTrue(
            resolved is ProviderSetting.Claude,
            "Council must use the user's selected Claude provider, not a rebuilt OpenAI setting. "
                + "Currently resolves to: \(String(describing: resolved.map { String(describing: type(of: $0)) })) — council resolver (P3)."
        )
    }

    /// Council provider resolver. Calls the REAL resolver the council runtime
    /// now uses (`IOSCouncilRoomRunner.resolveProviderSetting`), which honors
    /// the selected sealed type. P3 routed both council entries through it; the
    /// test asserts a Claude selection yields a `ProviderSetting.Claude`.
    private func councilResolvedProvider(forSelected selected: ProviderSetting) -> ProviderSetting? {
        IOSCouncilRoomRunner.resolveProviderSetting(selected: selected)
    }

    /// A provider that throws on every call — models all-stages-failed.
    final class FailingTextProvider: IOSAgentTextProvider, @unchecked Sendable {
        private(set) var callCount = 0
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            callCount += 1
            throw NSError(domain: "redlight", code: 1, userInfo: [NSLocalizedDescriptionKey: "stage failed"])
        }
    }

    /// A provider that returns an empty string for every call.
    final class EmptyTextProvider: IOSAgentTextProvider, @unchecked Sendable {
        private(set) var callCount = 0
        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            callCount += 1
            let message = UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: "", metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 6, day: 22, hour: 0, minute: 0, second: 0, nanosecond: 0),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            return MessageChunk(
                id: "empty-\(callCount)",
                model: "test",
                choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "stop")],
                usage: nil
            )
        }
    }

}
