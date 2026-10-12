import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUILiveProviderTests: XCTestCase {
    func testConfiguredProviderProducesCardAndConsumesUserSelection() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_TASK_UI_LIVE_PROVIDER"] == "1" else {
            throw XCTSkip("设置 AMBER_TASK_UI_LIVE_PROVIDER=1 才执行两轮真实 provider 验收。")
        }

        let settings = IOSSharedSettingsStore().snapshot
        guard let model = settings.getCurrentChatModel() else {
            throw XCTSkip("当前应用未配置有效的默认聊天模型；未选择其他模型。")
        }
        guard let provider = ChatProviderConfiguration.provider(for: model, providers: settings.providers) else {
            throw XCTSkip("当前默认聊天模型没有对应的 provider；未选择其他模型。")
        }
        if let issue = ChatProviderConfiguration.issue(for: model, provider: provider) {
            throw XCTSkip("当前默认模型不可请求：\(issue.message)")
        }
        let generativeUI = settings.agentRuntime.generativeUi
        guard generativeUI.enabled, generativeUI.enableActions else {
            throw XCTSkip("当前应用未启用任务 UI 所需的生成式 UI 与 actions；未修改设置。")
        }

        let conversationID = UUID().uuidString
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: KotlinInt(value: 2_048),
            tools: [], reasoningLevel: .off,
            customHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider, model: model.customHeaders, conversationId: conversationID
            ),
            customBody: model.customBodies
        )
        let adapter = OpenAIKmpProviderAdapter()
        let request = UIMessage.companion.user(prompt: """
        为个人笔记选择存储方案。请直接输出一个符合 task-ui v1 的完整 decision 任务卡：
        card_id 为 notes-storage，目标是确定笔记存储方案，问题是选本地存储还是云存储。
        options 恰好两个：第一个 id=local、title=本地存储，第二个 id=cloud、title=云存储；
        给出各自真实的 summary 和 tradeoffs，不替用户自动选择。
        fields 恰好一个 text 字段：id=constraints、label=补充约束、required=true。
        submit.label=基于选择继续、submit.intent=continue。不要添加 components。
        请输出一个独立的 task-ui fenced JSON 块；无需工具或外部资料。
        """)
        let firstPlan = IOSGenerativeUiRequestPolicy.plan(
            setting: generativeUI, messages: [request], params: params
        )
        let firstResponse = try await response(
            adapter: adapter, provider: provider, plan: firstPlan
        )
        let segments = IOSIntelligentUIProtocol.parse(firstResponse, isStreaming: false)
        let cards = segments.compactMap { segment -> IOSIntelligentUICardDefinition? in
            if case .card(let card) = segment { return card }
            return nil
        }
        XCTAssertEqual(cards.count, 1, "真实模型应产生一张通过协议校验的任务卡。")
        guard let definition = cards.first else {
            saveEvidence(modelID: model.modelId, firstResponse: firstResponse, secondResponse: nil)
            return
        }
        XCTAssertEqual(definition.cardID, "notes-storage")
        XCTAssertEqual(definition.options.count, 2)
        XCTAssertEqual(definition.options.first?.id, "local")
        XCTAssertEqual(definition.fields.count, 1)
        XCTAssertEqual(definition.fields.first?.id, "constraints")
        XCTAssertTrue(definition.fields.first?.required ?? false)
        guard let option = definition.options.first,
              definition.fields.contains(where: { $0.id == "constraints" }) else { return }

        let assistant = UIMessage.companion.assistant(prompt: firstResponse)
        let source = IOSIntelligentUISource(
            conversationID: conversationID, messageID: assistant.id.toHexDashString(),
            textPartIndex: 0, cardID: definition.cardID
        )
        let state = IOSIntelligentUIStateStore()
        state.register(source: source, definition: definition)
        try state.update(
            source: source, definition: definition, selectedOptionID: option.id,
            values: ["constraints": "必须离线可用"]
        )
        let submission = try IOSIntelligentUISubmission(
            source: source, definition: definition,
            draft: state.draft(for: source, definition: definition)
        )
        let base = UIMessage.companion.user(prompt: "")
        let userSelection = UIMessage(
            id: base.id, role: .user,
            parts: [IosToolOutputJsonBridge.shared.textPart(
                text: submission.prompt(request: "只用一句话复述所选方案的完整名称与补充约束，不执行操作，不使用工具，不生成新卡片。"),
                metadata: try submission.metadata
            )],
            annotations: [], createdAt: base.createdAt, finishedAt: nil,
            modelId: nil, usage: nil, translation: nil
        )
        let secondPlan = IOSGenerativeUiRequestPolicy.plan(
            setting: generativeUI, messages: [request, assistant, userSelection], params: params
        )
        XCTAssertEqual(secondPlan.uploadMessages.last?.role, .user)
        XCTAssertEqual(secondPlan.uploadMessages.last?.id, userSelection.id)
        XCTAssertEqual(
            (secondPlan.uploadMessages.last?.parts.first as? UIMessagePart.Text)?.metadata,
            (userSelection.parts.first as? UIMessagePart.Text)?.metadata
        )
        let secondResponse = try await response(
            adapter: adapter, provider: provider, plan: secondPlan
        )
        saveEvidence(modelID: model.modelId, firstResponse: firstResponse, secondResponse: secondResponse)
        XCTAssertTrue(secondResponse.contains(option.title), "真实模型应复述用户选中的方案名称。")
        XCTAssertTrue(secondResponse.contains("离线"), "真实模型应消费用户补充的离线约束。")
    }

    func testConfiguredProviderChoosesInlineStudyForNaturalMemoryRequest() async throws {
        guard ProcessInfo.processInfo.environment["AMBER_TASK_UI_LIVE_PROVIDER"] == "1" else {
            throw XCTSkip("真实 provider 验收需显式启用；不修改模型或认证设置。")
        }
        let settings = IOSSharedSettingsStore().snapshot
        guard let model = settings.getCurrentChatModel(),
              let provider = ChatProviderConfiguration.provider(for: model, providers: settings.providers),
              ChatProviderConfiguration.issue(for: model, provider: provider) == nil else {
            throw XCTSkip("当前应用没有可请求的模型；未选择替代 provider。")
        }
        let ui = settings.agentRuntime.generativeUi
        guard ui.enabled, ui.enableActions else { throw XCTSkip("当前智能 UI 交互未启用；不改设置。") }
        let conversationID = UUID().uuidString
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: KotlinInt(value: 8_192),
            tools: [], reasoningLevel: .off,
            customHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider, model: model.customHeaders, conversationId: conversationID
            ), customBody: model.customBodies
        )
        // The user describes a task; only the production capability prompt supplies a schema.
        let request = UIMessage.companion.user(prompt: "用智能 UI 帮我记忆明朝十六帝，最好能直接翻卡和做选择题。")
        let adapter = OpenAIKmpProviderAdapter()
        let first = try await response(adapter: adapter, provider: provider, plan:
            IOSGenerativeUiRequestPolicy.plan(setting: ui, messages: [request], params: params))
        saveEvidence(modelID: model.modelId, firstResponse: first, secondResponse: nil)
        let cards = IOSIntelligentUIProtocol.parse(first, isStreaming: false).compactMap { segment -> IOSIntelligentUICardDefinition? in
            if case .card(let card) = segment { return card }
            return nil
        }
        let card = try XCTUnwrap(cards.first, "自然记忆请求应直接生成可解析的原生学习界面。")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(card.kind, "study")
        XCTAssertFalse(first.contains("```show-widget"), "学习操作不应被放进 HTML 封面后的 Live 页面。")
        let study = try XCTUnwrap(card.study)
        XCTAssertEqual(study.items.count, 16, "明朝十六帝必须完整呈现，不能用通用占位示例。")
        let assistant = UIMessage.companion.assistant(prompt: first)
        let source = IOSIntelligentUISource(conversationID: conversationID,
            messageID: assistant.id.toHexDashString(), textPartIndex: 0, cardID: card.cardID)
        var session = IOSIntelligentUIStudySession()
        try session.setMode(.quiz, definition: study)
        let item = try XCTUnwrap(session.currentItem(definition: study))
        let wrong = try XCTUnwrap(item.options?.first { $0.id != item.correctOptionID })
        try session.answer(optionID: wrong.id, definition: study)
        let store = IOSIntelligentUIStateStore()
        try store.update(source: source, definition: card, selectedOptionID: nil,
            values: [IOSIntelligentUIStudySession.storageKey: try session.encodedValue()])
        let submission = try IOSIntelligentUISubmission(source: source, definition: card,
            draft: store.draft(for: source, definition: card))
        XCTAssertNil(submission.option, "练习结果不需要伪造一个决策方案。")
        let seed = UIMessage.companion.user(prompt: "")
        let continuation = UIMessage(id: seed.id, role: .user,
            parts: [IosToolOutputJsonBridge.shared.textPart(text: submission.prompt(request:
                "只用一行文字反馈实际题数，格式为：已答 N 题，错 N 题。N 用阿拉伯数字，不生成新的界面。"),
                metadata: try submission.metadata)],
            annotations: [], createdAt: seed.createdAt, finishedAt: nil, modelId: nil,
            usage: nil, translation: nil)
        let second = try await response(adapter: adapter, provider: provider, plan:
            IOSGenerativeUiRequestPolicy.plan(setting: ui,
                messages: [request, assistant, continuation], params: params))
        saveEvidence(modelID: model.modelId, firstResponse: first, secondResponse: second)
        XCTAssertNotNil(second.range(of: #"已答\s*1\s*题\s*[，,]\s*错\s*1\s*题"#,
            options: .regularExpression), "下一轮应消费实际已答1题、错1题的结果。")
        XCTAssertFalse(IOSIntelligentUIProtocol.parse(second, isStreaming: false).contains {
            if case .card = $0 { return true }; return false
        }, "只要求文字反馈时不应再生成一张任务卡。")
    }

    private func response(
        adapter: OpenAIKmpProviderAdapter,
        provider: ProviderSetting,
        plan: IOSGenerativeUiRequestPlan
    ) async throws -> String {
        let chunk: MessageChunk
        do {
            chunk = try await adapter.generateText(
                providerSetting: provider, messages: plan.uploadMessages, params: plan.params
            )
        } catch {
            // Transport error descriptions can include a configured URL or request details.
            throw LiveAcceptanceError.providerRequestFailed
        }
        XCTAssertFalse(chunk.choices.contains { choice in
            ((choice.message?.parts ?? []) + (choice.delta?.parts ?? []))
                .contains(where: { $0 is UIMessagePart.Tool })
        }, "此验收请求禁止工具调用。")
        return chunk.choices
            .flatMap { ($0.message?.parts ?? []) + ($0.delta?.parts ?? []) }
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined()
    }

    private func saveEvidence(modelID: String, firstResponse: String, secondResponse: String?) {
        let evidence = """
        model: \(redacted(modelID))

        first response:
        \(redacted(firstResponse))

        second response:
        \(redacted(secondResponse ?? "未请求：第一轮任务卡未通过验收"))
        """
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "task-ui-live-provider-responses"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func redacted(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"https?://[^\s\"<>]+"#, with: "[URL]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bbearer\s+[^\s\"<>]+|\bsk-[A-Za-z0-9_-]+"#,
                                  with: "[credential]", options: .regularExpression)
    }

    private enum LiveAcceptanceError: Error {
        case providerRequestFailed
    }
}
