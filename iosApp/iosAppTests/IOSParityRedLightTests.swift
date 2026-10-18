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
        router.path = [.chat, .settings]

        router.goBack()

        XCTAssertEqual(router.path, [.chat])
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

    private func makeDeepReadModel(_ modelId: String = "test-model") -> Model {
        Model(
            modelId: modelId, displayName: modelId, id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [],
            outputModalities: [], abilities: [], tools: Set<BuiltInTools>(),
            contextWindowTokens: nil, providerOverwrite: nil
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

    // MARK: - DeepRead (truth_matrix row `deepread`)

    /// RED for P0. GREEN target: P0.5 / P3.
    /// Cell: deepread.provider_real.
    ///
    /// When the user has selected a Claude provider, the Deep Read pipeline must
    /// resolve to a `ProviderSetting.Claude` and ultimately call Anthropic's
    /// native `/messages` — NOT silently rebuild an OpenAI setting and hit
    /// `/chat/completions`. Today `BoardView.createAndGenerateTask`
    /// (BoardView.swift:513) unconditionally constructs `ProviderSetting.OpenAI`
    /// regardless of the selected provider, so there is no Claude construction
    /// path at all. This test asserts the parity target: a Claude-selected run
    /// must construct a Claude setting.
    ///
    /// The test reaches the resolver the same way the pipeline does — via the
    /// canonical chat provider-resolution path that P3 will route DeepRead
    /// through. Until that routing exists, the resolved setting for a
    /// Claude selection is OpenAI (the rebuild), so the assertion fails.
    func test_deepread_claudeSelected_constructsClaudeSetting() {
        // The parity target: selecting Claude must yield a Claude provider
        // setting for the Deep Read pipeline.
        let selectedClaude = makeClaudeProvider()
        let resolved = deepReadResolvedProvider(forSelected: selectedClaude)

        // Must be Claude, not a silently-rebuilt OpenAI setting (and not nil).
        XCTAssertTrue(
            resolved is ProviderSetting.Claude,
            "Deep Read must use the user's selected Claude provider, not a rebuilt OpenAI setting. "
                + "Currently resolves to: \(String(describing: resolved.map { String(describing: type(of: $0)) })) — this is the rebuild gap (P3)."
        )
    }

    /// RED for P0. GREEN target: P4.
    /// Cell: deepread.honest_fail.
    ///
    /// When every synthesis stage throws, the task must end in `.failed` with an
    /// honest failure message — not `.succeeded` with empty sections. Today
    /// `synthesize` swallows errors and returns "" (IOSBoardPersistence.swift:2900),
    /// and `createAndGenerateTask` unconditionally calls `complete(...)`
    /// (BoardView.swift:539), so an all-stages-failed run is marked succeeded.
    /// P4 introduces the queued/running/ready/failed state machine + honest
    /// failure. This test drives a failing provider through the generator and
    /// asserts the resulting task status reflects failure.
    func test_deepread_allStagesThrow_statusFailed() async throws {
        let task = makeDeepReadTask()
        let store = IOSDeepReadStore(baseDirectory: makeTempDir())
        let running = try store.createTask(
            title: task.title,
            sources: task.sources,
            templateId: task.templateId
        )
        store.markRunning(id: running.id)
        let failingProvider = FailingTextProvider()
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: store.task(id: running.id) ?? running,
            providerSetting: makeOpenAIProvider(),
            model: makeDeepReadModel("any-model"),
            provider: failingProvider
        )
        // Apply the result via the SAME production decision function the create
        // and retry view paths use (IOSDeepReadDraftGenerator.outcome), not a
        // re-implemented branch — so this guards caller-honoring, not a copy.
        switch IOSDeepReadDraftGenerator.outcome(for: result, offlineFallback: "") {
        case .failed(let reason):
            store.fail(id: running.id, message: "所有生成阶段失败：\(reason)")
        case .completed(let markdown, _):
            store.complete(id: running.id, markdown: markdown)
        }
        let final = store.task(id: running.id)

        // Parity target: when all stages threw, status MUST be .failed, not
        // succeeded.
        XCTAssertEqual(
            final?.status,
            IOSDeepReadTaskStatus.failed,
            "All-stages-threw must surface as status=.failed, not .succeeded. "
                + "Got: \(String(describing: final?.status)) — honest-fail state machine (P0.5)."
        )
    }

    /// RED for P0. GREEN target: P4.
    /// Cell: deepread.honest_fail.
    ///
    /// A stage that produces empty output must NOT let the task be marked as
    /// successfully completed/ready. P4's state machine distinguishes a "ready"
    /// (usable) result from an empty one. Today empty sections still flow to
    /// `complete(...)`. This test asserts an empty-output run is not marked
    /// ready/succeeded.
    func test_deepread_stageEmpty_notMarkedReady() async throws {
        let task = makeDeepReadTask()
        let store = IOSDeepReadStore(baseDirectory: makeTempDir())
        let running = try store.createTask(
            title: task.title,
            sources: task.sources,
            templateId: task.templateId
        )
        store.markRunning(id: running.id)
        // Provider returns empty for every stage.
        let emptyProvider = EmptyTextProvider()
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: store.task(id: running.id) ?? running,
            providerSetting: makeOpenAIProvider(),
            model: makeDeepReadModel("any-model"),
            provider: emptyProvider
        )
        // Empty-output run must surface as honest failure, not succeeded/ready —
        // decided by the production outcome function, not a test-local branch.
        switch IOSDeepReadDraftGenerator.outcome(for: result, offlineFallback: "") {
        case .failed:
            store.fail(id: running.id, message: "生成内容为空：所有阶段未产出可用内容")
        case .completed(let markdown, _):
            store.complete(id: running.id, markdown: markdown)
        }
        let final = store.task(id: running.id)

        XCTAssertNotEqual(
            final?.status,
            IOSDeepReadTaskStatus.succeeded,
            "A run whose every stage was empty must not be marked succeeded/ready. "
                + "Got: \(String(describing: final?.status)) — honest-fail state machine (P0.5)."
        )
    }

    /// GREEN guard for the Deep Read RETRY surface (parity fix, this change).
    /// Cell: deepread.honest_fail (retry path).
    ///
    /// The retry button previously called a thin wrapper that discarded
    /// `didFail` and always `complete(...)`d, so an all-stages-failed retry was
    /// marked succeeded with empty sections. `retryOutcome` now propagates the
    /// failure. Driving a failing provider end-to-end through the real retry
    /// decision must yield `.failed` — this exercises the actual production seam
    /// (`IOSDeepReadDraftGenerator.retryOutcome`), not a re-implemented branch.
    func test_deepread_retry_allStagesThrow_returnsFailed() async {
        let outcome = await IOSDeepReadDraftGenerator.retryOutcome(
            resolvedProvider: makeOpenAIProvider(),
            model: makeDeepReadModel("any-model"),
            task: makeDeepReadTask(),
            provider: FailingTextProvider()
        )
        guard case .failed = outcome else {
            return XCTFail("All-stages-failed retry must return .failed, got \(outcome)")
        }
    }

    /// GREEN guard: a successful retry returns `.completed` with the model text.
    func test_deepread_retry_success_returnsCompleted() async {
        let outcome = await IOSDeepReadDraftGenerator.retryOutcome(
            resolvedProvider: makeOpenAIProvider(),
            model: makeDeepReadModel("any-model"),
            task: makeDeepReadTask(),
            provider: IOSDeepReadPipelineTests.StageProvider([#"{"summary":"这个 overview 摘要长度足够，可以正常通过深度阅读的门闩。"}"#])
        )
        guard case .completed(let markdown, _) = outcome else {
            return XCTFail("Successful retry must return .completed, got \(outcome)")
        }
        XCTAssertTrue(markdown.contains("ov"), "Completed retry must carry the model output (summary).")
    }

    /// GREEN guard for the search-failure source state (de-faked this change).
    /// Cell: deepread.honest_fail (search/source failure mapping).
    ///
    /// A failed search must be recorded as a DISTINCT, machine-readable
    /// source-failure state (scrape_status="failed"), not silently fed to the
    /// model as factual content — and a single failed source must NOT hard-fail
    /// the whole task when surviving sources exist. Previously this test passed
    /// against a hand-built fixture via a title-substring fallback (the production
    /// catch path wrote no marker); it now drives the production source builder
    /// (IOSDeepReadSourceNormalizer.searchFailureSource, the same one BoardView's
    /// catch path uses) and asserts the marker strictly.
    func test_deepread_searchFailure_isSourceFailure() async throws {
        let task = makeDeepReadTask()
        let store = IOSDeepReadStore(baseDirectory: makeTempDir())
        // Build the failed-search source exactly the way production does (the
        // catch path in createDeepReadTask), not a hand-rolled fixture.
        let failedSource = try IOSDeepReadSourceNormalizer.searchFailureSource(
            query: "query",
            error: "network error"
        )
        // The production builder must stamp the machine-readable failure marker.
        XCTAssertEqual(
            failedSource.metadata["scrape_status"],
            "failed",
            "A failed search must produce a source carrying scrape_status=failed."
        )
        let goodSource = task.sources[0]
        let running = try store.createTask(
            title: task.title,
            sources: [goodSource, failedSource],
            templateId: task.templateId
        )
        store.markRunning(id: running.id)
        let provider = IOSDeepReadPipelineTests.StageProvider(["ov", "na", "an"])
        let draft = await IOSDeepReadDraftGenerator.generateViaLLM(
            task: store.task(id: running.id) ?? running,
            providerSetting: makeOpenAIProvider(),
            model: makeDeepReadModel("any-model"),
            provider: provider
        )
        store.complete(id: running.id, markdown: draft)
        let final = store.task(id: running.id)

        // Parity target A: the marker must survive into the persisted task —
        // asserted STRICTLY via metadata (no title-substring fallback).
        let persistedFailure = (final?.sources ?? []).first { $0.metadata["scrape_status"] == "failed" }
        XCTAssertNotNil(
            persistedFailure,
            "The failed-search source-level marker must survive into the persisted task."
        )
        // Parity target B: the task must NOT be hard-failed solely because a
        // source failed to fetch (it should run over surviving sources).
        XCTAssertNotEqual(
            final?.status,
            IOSDeepReadTaskStatus.failed,
            "A source-level search failure must not fail the whole task when surviving sources exist."
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

    /// Isolated temp directory for per-test DeepRead stores (avoids polluting
    /// the shared Documents/deep_read store across tests).
    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("redlight-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDeepReadTask() -> IOSDeepReadTask {
        IOSDeepReadTask(
            id: "redlight-task-\(UUID().uuidString)",
            title: "RedLight Deep Read",
            status: .running,
            templateId: IOSDeepReadTemplate.analysis.id,
            sources: [
                IOSDeepReadSource(kind: .manualText, title: "Source A", content: "AmberAgent is an iOS app with chat and tools."),
                IOSDeepReadSource(kind: .manualText, title: "Source B", content: "It supports deep reading and subagents.")
            ],
            resultMarkdown: "",
            failureMessage: nil,
            createdAt: 1,
            updatedAt: 1,
            completedAt: nil,
            retryCount: 0
        )
    }

    /// DeepRead provider resolver. Calls the REAL resolver the pipeline now uses
    /// (`IOSDeepReadDraftGenerator.resolveProviderSetting`), which honors the
    /// selected sealed type. P0.5 routed BoardView through this; the test asserts
    /// a Claude selection yields a `ProviderSetting.Claude`.
    private func deepReadResolvedProvider(forSelected selected: ProviderSetting) -> ProviderSetting? {
        IOSDeepReadDraftGenerator.resolveProviderSetting(selected: selected)
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
