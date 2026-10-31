import XCTest
@testable import AmberMac

@MainActor final class DesktopAgentRunLimitsTests: XCTestCase {
    func testDefaultsAreBuiltForLongRunsAndClampToTheOfferedSteps() {
        XCTAssertEqual(DesktopAgentRunLimits.rounds(nil), DesktopAgentRunLimits.defaultRounds)
        XCTAssertEqual(DesktopAgentRunLimits.defaultRounds, 2048)
        XCTAssertEqual(DesktopAgentRunLimits.defaultMinutes, 300)

        XCTAssertEqual(DesktopAgentRunLimits.rounds(1), DesktopAgentRunLimits.roundOptions.first)
        XCTAssertEqual(DesktopAgentRunLimits.rounds(999_999), DesktopAgentRunLimits.roundOptions.last)
        XCTAssertEqual(DesktopAgentRunLimits.clampedMinutes(0), DesktopAgentRunLimits.minuteOptions.first)
        XCTAssertEqual(DesktopAgentRunLimits.clampedMinutes(999_999), DesktopAgentRunLimits.minuteOptions.last)
    }

    func testDeadlineAddsTheConfiguredMinutes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(DesktopAgentRunLimits.deadline(minutes: 300, from: start).timeIntervalSince(start), 18_000)
        XCTAssertEqual(DesktopAgentRunLimits.deadline(minutes: 999_999, from: start).timeIntervalSince(start),
            TimeInterval(DesktopAgentRunLimits.minuteOptions.last!) * 60)
    }

    func testSettingsPersistAndClampTheRunLimits() {
        let suite = "amber.runlimits.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        XCTAssertEqual(settings.agentToolRoundLimit, DesktopAgentRunLimits.defaultRounds)
        XCTAssertEqual(settings.agentRunMinutes, DesktopAgentRunLimits.defaultMinutes)

        settings.agentToolRoundLimit = 1024
        settings.agentRunMinutes = 480
        let reloaded = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        XCTAssertEqual(reloaded.agentToolRoundLimit, 1024)
        XCTAssertEqual(reloaded.agentRunMinutes, 480)

        reloaded.agentToolRoundLimit = 5
        reloaded.agentRunMinutes = 5
        XCTAssertEqual(reloaded.agentToolRoundLimit, DesktopAgentRunLimits.roundOptions.first)
        XCTAssertEqual(reloaded.agentRunMinutes, DesktopAgentRunLimits.minuteOptions.first)
        let clamped = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        XCTAssertEqual(clamped.agentToolRoundLimit, DesktopAgentRunLimits.roundOptions.first)
        XCTAssertEqual(clamped.agentRunMinutes, DesktopAgentRunLimits.minuteOptions.first)
    }

    func testStopReasonMapsEveryEngineTerminalToItsOwnMessage() {
        let ok = result(steps: 3)
        XCTAssertNil(DesktopAgentProvider.stopReason(ok, rounds: 2048))

        XCTAssertEqual(DesktopAgentProvider.stopReason(result(steps: 8, hitStepLimit: true), rounds: 2048), .roundLimit(2048))
        XCTAssertEqual(DesktopAgentProvider.stopReason(result(steps: 4, guardStopped: true), rounds: 2048), .loopGuard)
        XCTAssertEqual(DesktopAgentProvider.stopReason(result(steps: 2, providerFailure: "网络错误"), rounds: 2048), .providerFailure)
        // 输出上限同时带着 providerFailureMessage，必须先判它。
        XCTAssertEqual(DesktopAgentProvider.stopReason(
            result(steps: 2, providerFailure: "模型回复达到输出上限", hitOutputLimit: true), rounds: 2048), .outputLimit)

        XCTAssertTrue(DesktopAgentStopReason.roundLimit(2048).banner.contains("2048"))
        XCTAssertTrue(DesktopAgentStopReason.timeLimit(minutes: 300).banner.contains("300"))
        XCTAssertEqual(DesktopAgentStopReason.loopGuard.record, "重复同一工具调用被停止。")
        XCTAssertNotEqual(DesktopAgentStopReason.roundLimit(2048).banner, DesktopAgentStopReason.guardStoppedFallback.banner)
    }

    /// 设置里的两个上限必须真的到达运行上下文（不在 provider 里再写死）。
    func testWorkspacePassesTheConfiguredLongRunLimitsIntoTheRunContext() throws {
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.runlimits.tests.\(UUID().uuidString)")!,
            credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        settings.agentToolRoundLimit = 1024
        settings.agentRunMinutes = 480

        let provider = ContextRecordingProvider()
        let conversation = DesktopConversation(title: "长任务")
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider, initialConversations: [conversation])
        workspace.agentTasks.toolsEnabled = true
        workspace.draft = "跑一个长任务"
        workspace.send()

        let context = try XCTUnwrap(provider.contexts.first)
        XCTAssertEqual(context.toolRounds, 1024)
        XCTAssertEqual(context.runMinutes, 480)
    }

    private final class ContextRecordingProvider: DesktopTextProvider {
        var contexts: [DesktopRunContext] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            DesktopGeneration()
        }

        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
            contexts.append(context)
            return try start(configuration: configuration, apiKey: apiKey, messages: messages, responseID: responseID)
        }
    }

    private func result(steps: Int, hitStepLimit: Bool = false, guardStopped: Bool = false,
        providerFailure: String? = nil, hitOutputLimit: Bool = false) -> IOSAgentToolEngineResult {
        IOSAgentToolEngineResult(messages: [], stepsExecuted: steps, pendingApproval: nil,
            hitStepLimit: hitStepLimit, providerFailureMessage: providerFailure,
            hitOutputLimit: hitOutputLimit, guardStopped: guardStopped)
    }
}

private extension DesktopAgentStopReason {
    /// 只是给「两种原因文案不能相同」这条断言一个对照值（守卫停止是同一枚举的另一个 case）。
    static var guardStoppedFallback: DesktopAgentStopReason { .loopGuard }
}
