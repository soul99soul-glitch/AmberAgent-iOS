import XCTest
@preconcurrency import Shared
@testable import iosApp

/// I2.5：默认继续当前会话；工具往返、待审批、未保存变更期间禁止建议切会话；
/// 只有“阶段完成 + 验收证据”同时存在才建议。iOS 没有自动切换路径。
final class IOSContextStageRouterTests: XCTestCase {

    func testDefaultsToContinue() {
        XCTAssertEqual(IOSContextStageRouter.decide(IOSContextStageInput()), .continueCurrent)
        XCTAssertEqual(
            IOSContextStageRouter.decide(.init(completedStage: "  ", acceptanceEvidence: [" "])),
            .continueCurrent
        )
    }

    func testSuggestsOnlyWithCompletedStageAndAcceptanceEvidence() {
        let route = IOSContextStageRouter.decide(.init(
            completedStage: "I2",
            acceptanceEvidence: ["12 类 needle 测试通过", "history_search 命中真实会话"]
        ))
        XCTAssertEqual(
            route,
            .suggestNewConversation(
                completedStage: "I2",
                evidence: ["12 类 needle 测试通过", "history_search 命中真实会话"]
            )
        )
    }

    func testPendingToolRoundTripBlocksSuggestion() {
        XCTAssertEqual(
            IOSContextStageRouter.decide(.init(
                pendingToolRoundTrip: true,
                completedStage: "I2",
                acceptanceEvidence: ["done"]
            )),
            .continueCurrent
        )
    }

    func testPendingApprovalBlocksSuggestion() {
        XCTAssertEqual(
            IOSContextStageRouter.decide(.init(
                pendingApproval: true,
                completedStage: "I2",
                acceptanceEvidence: ["done"]
            )),
            .continueCurrent
        )
    }

    func testUnsavedChangesBlockSuggestion() {
        XCTAssertEqual(
            IOSContextStageRouter.decide(.init(
                hasUnsavedChanges: true,
                completedStage: "I2",
                acceptanceEvidence: ["done"]
            )),
            .continueCurrent
        )
    }

    func testMessagesDerivePendingToolAndApproval() {
        let pendingApproval = toolMessage(output: [], approval: ToolApprovalState.Pending.shared)
        let input = IOSContextStageInput.from(
            messages: [pendingApproval],
            completedStage: "I2",
            acceptanceEvidence: ["done"]
        )
        XCTAssertTrue(input.pendingToolRoundTrip)
        XCTAssertTrue(input.pendingApproval)
        XCTAssertEqual(IOSContextStageRouter.decide(input), .continueCurrent)

        let completed = toolMessage(output: ["ok"], approval: ToolApprovalState.Auto.shared)
        let completedInput = IOSContextStageInput.from(
            messages: [completed],
            completedStage: "I2",
            acceptanceEvidence: ["done"]
        )
        XCTAssertFalse(completedInput.pendingToolRoundTrip)
        XCTAssertFalse(completedInput.pendingApproval)
        XCTAssertEqual(
            IOSContextStageRouter.decide(completedInput),
            .suggestNewConversation(completedStage: "I2", evidence: ["done"])
        )
    }

    private func toolMessage(output: [String], approval: ToolApprovalState) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(
                    toolCallId: "call-1",
                    toolName: "history_search",
                    input: "{}",
                    output: output.map { UIMessagePart.Text(text: $0, metadata: nil) },
                    approvalState: approval,
                    streamIndex: nil,
                    metadata: nil
                )
            ],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 10, day: 31, hour: 12, minute: 0, second: 0, nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }
}
