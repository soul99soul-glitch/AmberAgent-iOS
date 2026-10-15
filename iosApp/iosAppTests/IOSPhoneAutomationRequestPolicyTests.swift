import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSPhoneAutomationRequestPolicyTests: XCTestCase {
    private typealias F = IOSChatForegroundFixtures

    func testPlanningIsRequestOnlyAndReplacesOnlyItsOwnSection() {
        let ordinary = F.userMessage("Help with this exercise")
        let unrelated = PromptTranscript.shared.sectionMessage(name: "memory", text: "retained")
        let old = PromptTranscript.shared.sectionMessage(name: "phone_execution", text: "old policy")
        let canonical = [unrelated, ordinary]
        let once = IOSPhoneAutomationRequestPolicy.requestMessages(canonical, tools: IOSPhoneControlToolCatalog.declarations)
        let twice = IOSPhoneAutomationRequestPolicy.requestMessages([old] + once, tools: IOSPhoneControlToolCatalog.declarations)
        XCTAssertEqual(canonical.count, 2)
        XCTAssertFalse(canonical.contains(where: IOSPhoneAutomationRequestPolicy.isPlanningMessage))
        XCTAssertEqual(twice.filter(IOSPhoneAutomationRequestPolicy.isPlanningMessage).count, 1)
        XCTAssertEqual(twice.dropFirst().map(\.id), canonical.map(\.id))
        XCTAssertTrue(twice.first?.toText().contains("phone_run_flow") == true)
        XCTAssertTrue(twice.first?.toText().contains("wrong feedback") == true)
    }

    func testFrozenCatalogWithoutFlowAndFinalSummaryRemoveStaleGuidance() {
        let old = PromptTranscript.shared.sectionMessage(name: "phone_execution", text: "old policy")
        let user = F.userMessage("hello")
        for tools in [[], IOSPhoneControlToolCatalog.declarations.filter { $0.name != "phone_run_flow" }] {
            let result = IOSPhoneAutomationRequestPolicy.requestMessages([old, user], tools: tools)
            XCTAssertEqual(result.map(\.id), [user.id])
        }
    }

    func testCoalescedBackgroundHandoffDoesNotDuplicatePlanningOrLoseOtherContext() {
        let other = PromptTranscript.shared.sectionMessage(name: "memory", text: "retained memory")
        let user = F.userMessage("exercise")
        var messages = [other, user]
        for _ in 0..<3 {
            messages = ChatRuntimeContextBuilder.coalescingSystemMessages(
                IOSPhoneAutomationRequestPolicy.requestMessages(messages, tools: IOSPhoneControlToolCatalog.declarations))
            let system = messages.filter { $0.role == .system }.map { $0.toText() }.joined()
            XCTAssertEqual(system.components(separatedBy: IOSPhoneAutomationRequestPolicy.planningPrompt).count - 1, 1)
            XCTAssertTrue(system.contains("retained memory"))
        }
        let summary = IOSPhoneAutomationRequestPolicy.requestMessages(messages, tools: [])
        XCTAssertFalse(summary.contains { $0.toText().contains(IOSPhoneAutomationRequestPolicy.planningPrompt) })
        XCTAssertTrue(summary.contains { $0.toText().contains("retained memory") })
        XCTAssertEqual(summary.last?.id, user.id)
    }

    func testOnlyAutomaticActiveSupportedPhoneRequestsUseLow() {
        let provider = F.makeProviderSetting()
        let params = Self.params()
        for (automatic, active) in [(false, false), (false, true), (true, false)] {
            let unchanged = IOSPhoneAutomationRequestPolicy.requestParams(
                params, provider: provider, automaticReasoning: automatic, activePhoneSession: active)
            XCTAssertTrue(unchanged === params)
        }
        let low = IOSPhoneAutomationRequestPolicy.requestParams(
            params, provider: provider, automaticReasoning: true, activePhoneSession: true)
        XCTAssertEqual(low.reasoningLevel, .low)
        XCTAssertEqual(low.model.id, params.model.id)
        XCTAssertEqual(low.temperature, params.temperature)
        XCTAssertEqual(low.topP, params.topP)
        XCTAssertEqual(low.maxTokens, params.maxTokens)
        XCTAssertEqual(low.tools.map(\.name), params.tools.map(\.name))
        XCTAssertEqual(low.customHeaders.map(\.value), params.customHeaders.map(\.value))
        XCTAssertEqual(low.customBody.count, params.customBody.count)
        XCTAssertTrue(zip(low.customBody, params.customBody).allSatisfy { $0 === $1 })
        XCTAssertEqual(params.reasoningLevel, .high)
    }

    func testExplicitReasoningAndUnsupportedOrUnavailableModelsStayUnchanged() {
        let provider = F.makeProviderSetting()
        for level in [ReasoningLevel.high, .max, .low, .off] {
            let params = Self.params(reasoning: level)
            XCTAssertTrue(IOSPhoneAutomationRequestPolicy.requestParams(
                params, provider: provider, automaticReasoning: false, activePhoneSession: true) === params)
        }
        for params in [Self.params(modelID: "deepseek-chat"), Self.params(abilities: []), Self.params(tools: [])] {
            XCTAssertTrue(IOSPhoneAutomationRequestPolicy.requestParams(
                params, provider: provider, automaticReasoning: true, activePhoneSession: true) === params)
        }
        let off = Self.params(reasoning: .off)
        XCTAssertTrue(IOSPhoneAutomationRequestPolicy.requestParams(
            off, provider: provider, automaticReasoning: true, activePhoneSession: true) === off)
    }

    static func params(
        modelID: String = "deepseek-flash", reasoning: ReasoningLevel = .high,
        abilities: [ModelAbility] = [.tool, .reasoning], tools: [Tool] = IOSPhoneControlToolCatalog.declarations
    ) -> TextGenerationParams {
        let model = Model(
            modelId: modelID, displayName: modelID, id: KotlinUuid.companion.random(), type: .chat,
            customHeaders: [], customBodies: [], inputModalities: [], outputModalities: [],
            abilities: abilities, tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil)
        return TextGenerationParams(
            model: model, temperature: KotlinFloat(value: 0.2), topP: KotlinFloat(value: 0.9),
            maxTokens: KotlinInt(value: 1024), tools: tools, reasoningLevel: reasoning,
            customHeaders: [CustomHeader(name: "X-Test", value: "retained")],
            customBody: [CustomBody(key: "reasoning_effort", value: Kotlinx_serialization_jsonJson.companion.parseToJsonElement(string: "\"max\""))])
    }
}
