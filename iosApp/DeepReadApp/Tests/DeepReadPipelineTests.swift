import XCTest
@preconcurrency import Shared
@testable import AmberDeepRead

/// Exercises the standalone provider bridge through the shared synthesis pipeline.
@MainActor
final class DeepReadPipelineTests: XCTestCase {
    private func makeDeepReadModel(_ modelId: String = "test-model") -> Model {
        Model(
            modelId: modelId, displayName: modelId, id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [], customBodies: [], inputModalities: [],
            outputModalities: [], abilities: [], tools: Set<BuiltInTools>(),
            contextWindowTokens: nil, providerOverwrite: nil
        )
    }

    private func makeProviderSetting(model: Model? = nil) -> ProviderSetting.OpenAI {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "deepread-test",
            models: model.map { [$0] } ?? [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    /// A plan reply for the planning call (call #1 of every run).
    private let planReply = #"{"overview_angle":"从产品与生态角度解读","narrative_slots":["背景与触发","关键进展","后续观察"],"analysis_questions":["核心矛盾是什么","影响哪些群体"],"stakeholders":["用户","开发者","监管机构"],"risk_or_uncertainty":["未印证的事实需降格表达"],"required_source_ids":[1,2]}"#

    /// A gate-passing (≥24 chars) overview summary.
    private let goodSummaryReply = #"{"topic_type":"product","summary":"两个来源共同描述了一个支持聊天、工具与深度阅读的 iOS 应用产品。","key_entities":["AmberAgent"]}"#

    private func makeTask() -> IOSDeepReadTask {
        makeTask(sources: [
            IOSDeepReadSource(kind: .manualText, title: "Source A", content: "AmberAgent is an iOS app with chat and tools."),
            IOSDeepReadSource(kind: .manualText, title: "Source B", content: "It supports deep reading and subagents.")
        ])
    }

    private func makeTask(sources: [IOSDeepReadSource]) -> IOSDeepReadTask {
        IOSDeepReadTask(
            id: "test-task",
            title: "Test Deep Read",
            status: .running,
            templateId: IOSDeepReadTemplate.analysis.id,
            sources: sources,
            resultMarkdown: "",
            failureMessage: nil,
            createdAt: 1,
            updatedAt: 1,
            completedAt: nil,
            retryCount: 0
        )
    }

    /// A scripted provider that returns one canned reply per call and records
    /// every call so we can assert the stage loop ran 1 plan + 4 stage calls.
    /// `throwAtCalls` makes the given 1-based call indexes throw (transient-
    /// failure simulation for the in-stage retry).
    final class StageProvider: IOSAgentTextProvider, @unchecked Sendable {
        private let replies: [String]
        private let throwAtCalls: Set<Int>
        private let finishReasons: [Int: String]
        private(set) var receivedParams: [TextGenerationParams] = []
        private(set) var callCount = 0
        var onCall: ((Int) throws -> Void)?
        private(set) var userPrompts: [String] = []
        init(_ replies: [String], throwAtCalls: Set<Int> = [], finishReasons: [Int: String] = [:]) {
            self.replies = replies
            self.throwAtCalls = throwAtCalls
            self.finishReasons = finishReasons
        }

        func generateText(
            providerSetting: ProviderSetting,
            messages: [UIMessage],
            params: TextGenerationParams
        ) async throws -> MessageChunk {
            callCount += 1
            try onCall?(callCount)
            receivedParams.append(params)
            if throwAtCalls.contains(callCount) {
                throw NSError(domain: "deepread-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "transient failure"])
            }
            if let user = messages.last(where: { $0.role == MessageRole.user }) {
                userPrompts.append(user.toText())
            }
            let reply = replies[(callCount - 1) % replies.count]
            let message = UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: reply, metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 6, day: 20, hour: 0, minute: 0, second: 0, nanosecond: 0),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            return MessageChunk(
                id: "chunk-\(callCount)",
                model: "test",
                choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: finishReasons[callCount] ?? "stop")],
                usage: nil
            )
        }
    }


    private let timelineReply = #"{"timeline":[{"date":"今天","event":"事件发生并逐步展开。"}],"core_points":[{"point":"能力分层"}]}"#
    private let analysisReply = #"{"analysis":{"core_dispute":"是否已到产品化拐点","perspectives":[{"viewpoint":"还早","holder":"观察者"}],"implications":"需要更多验证","quotes":[{"text":"这只是开始。","attribution":"观察者"}]}}"#
    private let extendedReply = #"{"extended_reading":[{"title":"发布时间线","url":"https://example.com","source":"Amber"}],"references":[{"title":"参考来源","url":"https://example.org","source":"Amber"}],"hero_image_url":"","hero_caption":""}"#

    func testPipelineRunsPlanAndFourJSONStagesAndAssemblesStructured() async throws {
        let provider = StageProvider([
            planReply,
            goodSummaryReply,
            timelineReply,
            analysisReply,
            extendedReply
        ])
        let model = Model(
            modelId: "configured-model", displayName: "Configured", id: KotlinUuid.companion.random(),
            type: .chat, customHeaders: [CustomHeader(name: "X-Model", value: "deep-read")],
            customBodies: [CustomBody(key: "reasoning_effort", value: Kotlinx_serialization_jsonJson.companion.parseToJsonElement(string: "\"low\""))],
            inputModalities: [.text], outputModalities: [.text], abilities: [.reasoning],
            tools: Set<BuiltInTools>(), contextWindowTokens: KotlinInt(value: 272_000), providerOverwrite: nil
        )
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: model,
            provider: provider
        )

        // 1 planning call + 4 synthesis calls (overview/narrative/analysis/extended-reading).
        XCTAssertEqual(provider.callCount, 5)
        XCTAssertFalse(result.didFail)
        XCTAssertTrue(result.missingSections.isEmpty, "no stage should be missing: \(result.missingSections)")

        for params in provider.receivedParams {
            XCTAssertEqual(params.model.id, model.id)
            XCTAssertEqual(params.model.abilities, model.abilities)
            XCTAssertEqual(params.customHeaders, model.customHeaders)
            XCTAssertEqual(params.customBody, model.customBodies)
            XCTAssertNil(params.maxTokens, "Use the provider/model output budget instead of a hard-coded 3500-token cap")
            // GPT-5 / Kimi 等只接受默认温度，固定 0.3 会被 400 拒绝；与聊天一致交给服务商默认。
            XCTAssertNil(params.temperature, "Deep read must not pin a sampling temperature")
        }

        // The merged structured output carries every stage's fields.
        let json = try XCTUnwrap(result.structuredJSON)
        let output = try JSONDecoder().decode(IOSDeepReadOutput.self, from: Data(json.utf8))
        XCTAssertEqual(output.topicType, "product")
        XCTAssertTrue(output.summary.count >= 24)
        XCTAssertEqual(output.timeline.count, 1)
        XCTAssertEqual(output.corePoints.first?.point, "能力分层")
        XCTAssertEqual(output.analysis.coreDispute, "是否已到产品化拐点")
        XCTAssertEqual(output.analysis.quotes.first?.attribution, "观察者")
        XCTAssertEqual(output.extendedReading.first?.url, "https://example.com")
        XCTAssertEqual(output.references.first?.url, "https://example.org")

        // The serialized markdown (for share / fallback) carries the section headings.
        XCTAssertTrue(result.markdown.contains("## 摘要"))
        XCTAssertTrue(result.markdown.contains("## 时间轴"))
        XCTAssertTrue(result.markdown.contains("## 关键脉络"))
        XCTAssertTrue(result.markdown.contains("## 深度分析"))
        XCTAssertTrue(result.markdown.contains("## 扩展阅读"))
        XCTAssertTrue(result.markdown.contains("## 参考来源"))
    }

    func testLaterStagesSeededWithEarlierStructuredJSON() async {
        // Each stage's prompt must carry the merged prior-stage JSON.
        let provider = StageProvider([
            planReply,
            #"{"summary":"这是一个足够长的概览摘要，用来通过门闩并传递给后续段落。"}"#,
            #"{"core_points":[{"point":"叙事要点"}]}"#,
            #"{"analysis":{"core_dispute":"分析分歧"}}"#,
            #"{"extended_reading":[{"title":"链接","url":"https://example.com","source":"示例"}]}"#
        ])
        _ = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: makeDeepReadModel("test-model"),
            provider: provider
        )
        XCTAssertEqual(provider.userPrompts.count, 5)
        // Prompt 0 is the planning call; stage 1 is prompt 1.
        XCTAssertTrue(provider.userPrompts[0].contains("结构规划"))
        // Stage 2 prompt references the overview summary (merged JSON).
        XCTAssertTrue(provider.userPrompts[2].contains("足够长的概览摘要"))
        // Stage 3 references the narrative core point.
        XCTAssertTrue(provider.userPrompts[3].contains("叙事要点"))
        // Stage 4 references the analysis dispute.
        XCTAssertTrue(provider.userPrompts[4].contains("分析分歧"))
    }


    func testTruncatedJSONIsRepairedWithoutRetry() async throws {
        // Narrative output is cut mid-array: repair balances it, the stage is
        // accepted, and no retry call is spent.
        let provider = StageProvider([
            planReply,
            goodSummaryReply,
            #"{"timeline":[{"date":"今天","event":"事件发生"}"#,
            analysisReply,
            extendedReply
        ], finishReasons: [3: "length"])
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: makeDeepReadModel("test-model"),
            provider: provider
        )
        XCTAssertEqual(provider.callCount, 5)
        XCTAssertFalse(result.didFail)
        XCTAssertTrue(result.missingSections.isEmpty)
        let json = try XCTUnwrap(result.structuredJSON)
        let output = try JSONDecoder().decode(IOSDeepReadOutput.self, from: Data(json.utf8))
        XCTAssertEqual(output.timeline.first?.event, "事件发生")
    }

    func testPersistentlyFailingStageIsReportedNotSilentlyDropped() async {
        // Analysis returns prose on both attempts (calls 4 and 5); the run still
        // completes with the other sections and reports the missing one.
        let provider = StageProvider([
            planReply,
            goodSummaryReply,
            timelineReply,
            "分析部分我想写一段长文……",
            "分析部分我想写一段长文……",
            extendedReply
        ])
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: makeDeepReadModel("test-model"),
            provider: provider
        )
        XCTAssertEqual(provider.callCount, 6) // analysis consumed its retry
        XCTAssertFalse(result.didFail, "partial content is a completed draft")
        XCTAssertEqual(result.missingSections, ["深度分析"])
        XCTAssertTrue(result.markdown.contains("## 时间轴"))
        XCTAssertTrue(result.markdown.contains("## 扩展阅读"))
        XCTAssertFalse(result.markdown.contains("## 深度分析"))
    }

    // 全部调用失败且报错是未归类的英文时，失败原因要带上服务商原话，不能只剩「操作失败」。
    func testAllStagesThrowingSurfacesRawProviderError() async {
        final class RejectingProvider: IOSAgentTextProvider, @unchecked Sendable {
            func generateText(
                providerSetting: ProviderSetting,
                messages: [UIMessage],
                params: TextGenerationParams
            ) async throws -> MessageChunk {
                throw NSError(domain: "deepread-test", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported value: 'temperature' does not support 0.3 with this model."
                ])
            }
        }
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: makeDeepReadModel("test-model"),
            provider: RejectingProvider()
        )
        XCTAssertTrue(result.didFail)
        XCTAssertTrue(
            result.failureReason.contains("does not support 0.3"),
            "raw provider error must survive: \(result.failureReason)"
        )
        // 与启动方一致再过一次清洗，原话仍须保留。
        XCTAssertTrue(IOSDeepReadUserFacingText.sanitize(result.failureReason).contains("does not support 0.3"))
    }


    private func priorOutput() -> IOSDeepReadOutput {
        var output = IOSDeepReadOutput()
        output.summary = "这是一个已有的概览摘要，长度足够通过任何门闩。"
        output.timeline = [IOSDeepReadTimelineEvent(date: "今天", event: "既有事件")]
        output.extendedReading = [IOSDeepReadLink(title: "既有链接", url: "https://example.com")]
        return output
    }

    func testTargetedRetryRegeneratesOnlyTargetedStage() async throws {
        let provider = StageProvider([
            planReply,
            analysisReply
        ])
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: makeDeepReadModel("test-model"),
            provider: provider,
            initialOutput: priorOutput(),
            targetStages: ["深度分析"]
        )
        // Plan + the single targeted stage; the other sections are untouched.
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertFalse(result.didFail)
        XCTAssertTrue(result.missingSections.isEmpty)
        let json = try XCTUnwrap(result.structuredJSON)
        let output = try JSONDecoder().decode(IOSDeepReadOutput.self, from: Data(json.utf8))
        XCTAssertEqual(output.timeline.first?.event, "既有事件")
        XCTAssertEqual(output.analysis.coreDispute, "是否已到产品化拐点")
    }

    func testTargetedRetryFailureKeepsPriorSectionsAndReportsMissing() async {
        let provider = StageProvider([
            planReply,
            "分析部分我想写一段长文……",
            "分析部分我想写一段长文……"
        ])
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: makeTask(),
            providerSetting: makeProviderSetting(),
            model: makeDeepReadModel("test-model"),
            provider: provider,
            initialOutput: priorOutput(),
            targetStages: ["深度分析"]
        )
        XCTAssertEqual(provider.callCount, 3)
        XCTAssertFalse(result.didFail, "prior sections keep the run completed")
        XCTAssertEqual(result.missingSections, ["深度分析"])
        XCTAssertTrue(result.markdown.contains("## 时间轴"))
    }

}
