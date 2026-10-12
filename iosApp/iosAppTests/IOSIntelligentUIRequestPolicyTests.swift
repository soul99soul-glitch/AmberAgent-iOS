import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSIntelligentUIRequestPolicyTests: XCTestCase {
    func testExplicitIntelligentUITimelineDoesNotForceLegacySVGRepair() throws {
        let message = UIMessage.companion.user(prompt: "用智能 UI 展示明朝皇帝的时间线，能点开详情")
        let plan = IOSGenerativeUiRequestPolicy.plan(setting: makeSetting(), messages: [message], params: makeParams())
        let prompt = try XCTUnwrap(plan.uploadMessages.first?.toText())
        XCTAssertFalse(plan.requirement.required)
        XCTAssertFalse(prompt.contains("Emit a concise show-widget SVG block"))
        let json = #"""
        {"version":1,"card_id":"ming-timeline","kind":"explore","goal":"了解明朝年号的时间线",
         "fields":[{"id":"details","label":"展开详情","required":false,"type":"presentation"}],
         "components":[{"id":"timeline","kind":"timeline","rows":[{"label":"洪武","detail":"朱元璋建立明朝"},{"label":"永乐","detail":"朱棣在位时期"}]},
         {"id":"details","kind":"disclosure","title":"查看年号详情","field_id":"details","children":[{"id":"detail-text","kind":"body","text":"英宗先后使用正统与天顺两个年号。"}]}],
         "submit":{"label":"根据时间线继续","intent":"continue"}}
        """#
        let definition = try IOSIntelligentUIProtocol.decode(json)
        let native = UIMessage.companion.assistant(prompt: "```task-ui\n" + json + "\n```")
        XCTAssertEqual(definition.kind, "explore")
        XCTAssertNil(IOSGenerativeUiRequestPolicy.widgetIssue(in: [message, native], afterDisplayMessageCount: 1, requirement: plan.requirement))
    }

    func testNaturalLearningRequestReceivesAdaptiveCapabilityWithoutForcedVisualArtifact() throws {
        let message = UIMessage.companion.user(prompt: "用智能 UI 帮我记忆明朝十六帝")
        let plan = IOSGenerativeUiRequestPolicy.plan(setting: makeSetting(), messages: [message], params: makeParams())
        let prompt = try XCTUnwrap(plan.uploadMessages.first?.toText())
        XCTAssertTrue(prompt.contains("用户无需点名"))
        XCTAssertTrue(prompt.contains("学习记忆与练习"))
        XCTAssertTrue(prompt.contains("直接在消息内操作"))
        XCTAssertFalse(prompt.contains("只有用户明确要求选择"))
        XCTAssertFalse(plan.requirement.required)
        XCTAssertEqual(plan.uploadMessages.last, message)
        for (example, kind) in [(IOSIntelligentUIProtocol.exampleJSON, "decision"),
                                (IOSIntelligentUIProtocol.formExampleJSON, "form"),
                                (IOSIntelligentUIProtocol.exploreExampleJSON, "explore"),
                                (IOSIntelligentUIProtocol.studyExampleJSON, "study")] {
            XCTAssertEqual(try IOSIntelligentUIProtocol.decode(example).kind, kind,
                "实际传给模型的示例必须通过生产协议校验。")
        }
    }

    func testNativeMediumChoicePreservesExplicitVisualArtifactsAndDisabledActions() throws {
        let setting = makeSetting()
        for text in ["用智能 UI 展示 SVG 时间线", "用智能 UI 生成 vector diagram",
                     "用智能 UI 制作 PPT 幻灯片", "用智能 UI 输出 HTML 时间线",
                     "[ROUTE:diagram] 用智能 UI 展示时间线", "用智能 UI 制作 MiniApp"] {
            let messages = [UIMessage.companion.user(prompt: text)]
            let params = makeParams()
            let plan = IOSGenerativeUiRequestPolicy.plan(setting: setting, messages: messages, params: params)
            let legacy = GenerativeUiPlanner.shared.widgetRequirement(setting: setting, messages: messages)
            XCTAssertEqual(plan.requirement, IOSGenerativeUiRequirement(legacy), text)
            let route = GenerativeUiPlanner.shared.buildPrompt(setting: setting, messages: messages, hasImageGenTool: false)
            XCTAssertTrue(try XCTUnwrap(plan.uploadMessages.first?.toText()).contains(route), text)
            XCTAssertEqual(plan.params.tools.map(\.name), params.tools.map(\.name))
        }
        let plan = IOSGenerativeUiRequestPolicy.plan(setting: makeSetting(enableActions: false),
            messages: [UIMessage.companion.user(prompt: "用智能 UI 展示时间线")], params: makeParams())
        XCTAssertTrue(plan.requirement.required)
        XCTAssertFalse(try XCTUnwrap(plan.uploadMessages.first?.toText()).contains(IOSIntelligentUIProtocol.capabilityPrompt))
    }

    func testRefusingIntelligentUIDoesNotSelectTheNativeMedium() throws {
        for text in ["不要智能 UI，画一个时间线", "不用智能UI，画时间线",
                     "不要使用智能UI，画时间线", "不需要使用智能UI，画时间线",
                     "不需要智能 UI，画时间线", "without intelligent UI, draw a timeline",
                     "don't use intelligent UI, draw a timeline"] {
            let messages = [UIMessage.companion.user(prompt: text)]
            let setting = makeSetting()
            let plan = IOSGenerativeUiRequestPolicy.plan(setting: setting, messages: messages, params: makeParams())
            XCTAssertEqual(plan.requirement, IOSGenerativeUiRequirement(
                GenerativeUiPlanner.shared.widgetRequirement(setting: setting, messages: messages)), text)
            let route = GenerativeUiPlanner.shared.buildPrompt(setting: setting, messages: messages, hasImageGenTool: false)
            XCTAssertTrue(try XCTUnwrap(plan.uploadMessages.first?.toText()).contains(route), text)
        }
    }

    @MainActor
    func testNativeTimelineSubmissionContinuesWithoutForcedWidgetRepair() throws {
        let original = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.exploreExampleJSON)
        for goal in ["继续学习明朝皇帝的时间线", "学习 HTML DOM 结构图", "学习 SVG 时间线", "通过 PPT 研究时间线"] {
        let definition = IOSIntelligentUICardDefinition(cardID: original.cardID, kind: original.kind,
            goal: goal, question: original.question, options: original.options,
            fields: original.fields, submit: original.submit, components: original.components)
        let source = IOSIntelligentUISource(conversationID: "policy-conversation", messageID: "policy-message",
                                             textPartIndex: 0, cardID: definition.cardID)
        let store = IOSIntelligentUIStateStore()
        store.register(source: source, definition: definition)
        let submission = try IOSIntelligentUISubmission(source: source, definition: definition,
            draft: store.draft(for: source, definition: definition))
        let base = UIMessage.companion.user(prompt: submission.prompt())
        let message = UIMessage(id: base.id, role: .user,
            parts: [IosToolOutputJsonBridge.shared.textPart(text: base.toText(), metadata: try submission.metadata)],
            annotations: base.annotations, createdAt: base.createdAt, finishedAt: base.finishedAt,
            modelId: base.modelId, usage: base.usage, translation: base.translation)
        let plan = IOSGenerativeUiRequestPolicy.plan(setting: makeSetting(), messages: [message], params: makeParams())
        XCTAssertFalse(plan.requirement.required)
        XCTAssertFalse(try XCTUnwrap(plan.uploadMessages.first?.toText()).contains("Emit a concise show-widget SVG block"))
        XCTAssertEqual(plan.uploadMessages.last, message)
        }
    }

    func testEnabledPlanAddsTaskCapabilityBesideExistingVisualCapability() {
        let user = UIMessage.companion.user(prompt: "比较两个方案并让我选择")
        let assistant = UIMessage.companion.assistant(prompt: "已收集需求")
        let params = makeParams()
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: makeSetting(), messages: [user, assistant], params: params
        )

        XCTAssertEqual(plan.uploadMessages.count, 3)
        XCTAssertEqual(plan.uploadMessages.first?.role, .system)
        let prompt = plan.uploadMessages.first?.toText() ?? ""
        XCTAssertTrue(prompt.contains(IOSIntelligentUIProtocol.capabilityPrompt))
        XCTAssertTrue(prompt.contains("show-widget"))
        XCTAssertTrue(prompt.contains("three.js"))
        XCTAssertEqual(Array(plan.uploadMessages.dropFirst()), [user, assistant])
        XCTAssertEqual(plan.params.tools.map(\.name), params.tools.map(\.name))
        XCTAssertEqual(plan.params.model, params.model)
        XCTAssertFalse(plan.requirement.required, "任务卡能力不应强制生成绘图组件")
    }

    func testLearningTopicDoesNotForceLegacyWidgetRepair() {
        let request = UIMessage.companion.user(prompt: "用智能 UI 帮我学习三省六部制，直接翻卡和做选择题")
        let plan = IOSGenerativeUiRequestPolicy.plan(setting: makeSetting(), messages: [request], params: makeParams())
        XCTAssertFalse(plan.requirement.required, "主题名称不能强制将原生学习卡补绘成 SVG。")
        let diagram = UIMessage.companion.user(prompt: "画一个三省六部制流程图")
        XCTAssertTrue(IOSGenerativeUiRequestPolicy.plan(setting: makeSetting(), messages: [diagram], params: makeParams()).requirement.required)
    }

    func testDisabledSettingLeavesMessagesUntouched() {
        let messages = [UIMessage.companion.user(prompt: "帮我选择实施方案")]
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: makeSetting(enabled: false), messages: messages, params: makeParams()
        )

        XCTAssertEqual(plan.uploadMessages, messages)
        XCTAssertEqual(plan.requirement, .none)
        XCTAssertEqual(IOSIntelligentUIRequestPolicy.prompt(setting: makeSetting(enabled: false)), "")
    }

    func testActionsDisabledRetainsVisualPromptWithoutTaskCapability() {
        let messages = [UIMessage.companion.user(prompt: "回答这个问题")]
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: makeSetting(enableActions: false), messages: messages, params: makeParams()
        )

        XCTAssertEqual(plan.uploadMessages.count, 2)
        let prompt = plan.uploadMessages.first?.toText() ?? ""
        XCTAssertTrue(prompt.contains("show-widget"))
        XCTAssertFalse(prompt.contains(IOSIntelligentUIProtocol.capabilityPrompt))
        XCTAssertEqual(Array(plan.uploadMessages.dropFirst()), messages)
    }

    func testMiniAppTurnDoesNotInjectEitherCapability() {
        let messages = [UIMessage.companion.user(prompt: "制作一个小应用")]
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: makeSetting(), messages: messages, params: makeParams(), suppressForMiniApp: true
        )

        XCTAssertEqual(plan.uploadMessages, messages)
        XCTAssertEqual(plan.requirement, .none)
        XCTAssertEqual(IOSIntelligentUIRequestPolicy.prompt(
            setting: makeSetting(), suppressForMiniApp: true
        ), "")
    }

    func testSubmissionSnapshotRemainsUserInputWithItsMetadata() throws {
        let original = UIMessage.companion.user(prompt: "按这个方案继续：采用原生组件，补充输入：预算 3000 元")
        let snapshot = #"{"source":{"cardID":"budget"}}"#
        let literal = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        let metadata = ["amber_task_ui_submission":
            Kotlinx_serialization_jsonJson.companion.parseToJsonElement(string: literal)]
        let submission = UIMessage(
            id: original.id, role: .user,
            parts: [IosToolOutputJsonBridge.shared.textPart(text: original.toText(), metadata: metadata)],
            annotations: original.annotations, createdAt: original.createdAt,
            finishedAt: original.finishedAt, modelId: original.modelId,
            usage: original.usage, translation: original.translation
        )
        let plan = IOSGenerativeUiRequestPolicy.plan(
            setting: makeSetting(), messages: [submission], params: makeParams()
        )

        XCTAssertEqual(plan.uploadMessages.count, 2)
        let uploaded = plan.uploadMessages[1]
        XCTAssertEqual(uploaded.id, submission.id)
        XCTAssertEqual(uploaded.role, .user)
        XCTAssertEqual(uploaded.toText(), submission.toText())
        XCTAssertEqual((uploaded.parts.first as? UIMessagePart.Text)?.metadata, metadata)
        XCTAssertFalse(plan.uploadMessages[0].toText().contains("预算 3000 元"))
    }

    private func makeSetting(enabled: Bool = true, enableActions: Bool = true) -> GenerativeUiSetting {
        GenerativeUiSetting(
            enabled: enabled, maxWidgetCodeChars: 12_000, maxWidgetHeightDp: 720,
            enableActions: enableActions, enableStructuredRenderers: true,
            enableInteractiveCharts: true, slidesMagazineFontPack: "source-han-serif-sc-regular",
            slidesSwissFontPack: "source-han-sans-sc-regular"
        )
    }

    private func makeParams() -> TextGenerationParams {
        IOSChatForegroundFixtures.makeParams(toolNames: ["search_web"])
    }
}
