import XCTest
import Shared
@testable import iosApp

final class IOSPhoneToolPresentationTests: XCTestCase {
    private func tool(_ name: String = "phone_act", result: String?, extra: [String] = []) -> UIMessagePart.Tool {
        UIMessagePart.Tool(toolCallId: "phone-presentation", toolName: name,
                           input: #"{"action":"type","text":"private-input-value","ref":"old-ref"}"#,
                           output: ((result.map { [$0] } ?? []) + extra).map { UIMessagePart.Text(text: $0, metadata: nil) },
                           approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)
    }

    func testActivePhoneCapsuleDoesNotExposeInput() {
        let model = ChatToolStepModel(tool: tool(result: nil))
        XCTAssertEqual(model.title, "操作手机")
        XCTAssertEqual(model.state, .active)
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.visualKind, .apple)
    }

    func testUnknownReceiptIsNeverPresentedAsCompletedOrReplayable() throws {
        let model = ChatToolStepModel(tool: tool("phone_run_goal", result:
            #"{"status":"unknown","outcome":"unknown","steps":["search: completed","submit: unknown"],"retry_safe":false,"message":"response lost"}"#))
        XCTAssertEqual(model.state, .failed)
        XCTAssertFalse(model.canApplySubAgentRunStatus)
        XCTAssertEqual(model.title, "执行手机目标 · 待核对")
        XCTAssertEqual(model.statusTitle, "结果未知，需核对")
        XCTAssertEqual(model.detail, "已确认执行 1 步")
        let presentation = try XCTUnwrap(model.phonePresentation)
        XCTAssertTrue(presentation.notice?.contains("不要重放") == true)
        XCTAssertEqual(presentation.reason, "response lost")
        XCTAssertFalse(model.detail?.contains("private-input-value") == true)
    }

    func testHandbackRetainsAcknowledgedStepsAndFreshEvidence() {
        let model = ChatToolStepModel(tool: tool("phone_run_goal", result:
            #"{"status":"handback","outcome":"completed","steps":["open: completed","search: completed"],"reason":"completion not visible"}"#,
            extra: ["app=com.example pid=3 observation=new backend=xcui truncated=false nodes=12\nr1 Button label=private-page-value"]))
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.title, "执行手机目标 · 待继续")
        XCTAssertEqual(model.statusTitle, "已交回，待继续")
        XCTAssertEqual(model.detail, "已确认执行 2 步；已附新界面")
        XCTAssertFalse(model.detail?.contains("private-page-value") == true)
    }

    func testHumanTakeoverSummaryUsesPriorReceiptAndCurrentFreshness() {
        let model = ChatToolStepModel(tool: tool("phone_run_goal", result:
            #"{"status":"handback","reason_code":"human_intervened","fresh_observation_available":true,"prior_tool_receipt":{"kind":"filled","result":"{\"status\":\"handback\",\"steps\":[\"open: completed\"]}"}}"#))
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.detail, "已确认执行 1 步；已附新界面")
    }

    func testNotSentPhoneFailureWithoutGenericFailureKeysDoesNotGetGreenCheck() {
        let model = ChatToolStepModel(tool: tool(result:
            #"{"outcome":"not_sent","retry_safe":false,"code":"phone_control_start_failed","message":"runner failed"}"#))
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.statusTitle, "未执行")
        XCTAssertEqual(model.detail, "本次未发送手机动作")
    }

    func testAcknowledgedActionWithoutVerificationOnlyClaimsExecution() {
        let model = ChatToolStepModel(tool: tool(result:
            #"{"outcome":"completed","retry_safe":false,"fresh_observation_available":true}"#))
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(model.statusTitle, "已执行")
        XCTAssertEqual(model.detail, "已有动作执行回执；已附新界面；业务结果尚未验收")
    }

    func testAcknowledgedActionWithUnmetVerificationShowsPendingVerification() {
        for verification in ["unmet", "insufficient"] {
            let model = ChatToolStepModel(tool: tool(result:
                "{\"outcome\":\"completed\",\"verification\":{\"status\":\"\(verification)\",\"reason\":\"target unavailable\"}}"))
            XCTAssertEqual(model.state, .cancelled)
            XCTAssertEqual(model.title, "操作手机 · 待核验")
            XCTAssertEqual(model.statusTitle, "已执行，待核验")
            XCTAssertEqual(model.detail, "已有动作执行回执")
        }
    }

    func testAcknowledgedActionWithoutFreshObservationStillPreservesReceipt() {
        let model = ChatToolStepModel(tool: tool(result:
            #"{"outcome":"completed","fresh_observation_available":false,"observation_error":"read failed"}"#))
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.detail, "已有动作执行回执；尚无新界面；业务结果尚未验收")
    }

    func testSatisfiedVerificationCanShowSuccess() {
        let model = ChatToolStepModel(tool: tool(result:
            #"{"outcome":"completed","verification":{"status":"satisfied"}}"#))
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(model.statusTitle, "已完成")
        XCTAssertEqual(model.detail, "已有动作执行回执；验收条件已满足")
    }

    func testListCollectionSummaryDoesNotClaimCompleteListOrExposeItems() {
        let model = ChatToolStepModel(tool: tool("phone_collect_list", result:
            #"{"status":"handback","outcome":"completed","swipe_count":2,"screen_count":3,"items":[{"text":"private-row"},{"text":"private-row-2"}],"coverage":"observed_screens_only"}"#))
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.detail, "已派发 2 次滑动；已采集 2 项；观察 3 屏；仅覆盖已观察页面")
        XCTAssertFalse(model.detail?.contains("private-row") == true)
    }

    func testReadOnlyListCollectionCompletesWithoutSendingAnAction() {
        let model = ChatToolStepModel(tool: tool("phone_collect_list", result:
            #"{"status":"completed","outcome":"not_sent","screen_count":1,"swipe_count":0,"items":[{"text":"private-row"}],"coverage":"observed_screens_only"}"#))
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(model.statusTitle, "已完成")
        XCTAssertEqual(model.detail, "本次未发送手机动作；已派发 0 次滑动；已采集 1 项；观察 1 屏；仅覆盖已观察页面")
    }

    func testScreenTextSummaryUsesAllMetadataWithoutExposingText() {
        let model = ChatToolStepModel(tool: tool("phone_observe", result:
            "app=com.example pid=3 observation=new backend=xcui truncated=false nodes=1",
            extra: [#"{"observation_metrics":{"total_ms":50}}"#,
                    #"{"screen_text":{"items":[{"text":"private-ocr-value"},{"text":"private-ocr-value-2"}]}}"#]))
        XCTAssertEqual(model.detail, "已附新界面；OCR 识别 2 项文字")
        XCTAssertFalse(model.detail?.contains("private-ocr") == true)
    }

    func testFlowStructuredStepsOnlyCountAcknowledgedOutcomes() {
        let model = ChatToolStepModel(tool: tool("phone_run_flow", result:
            #"{"status":"unknown","outcome":"unknown","steps":[{"id":"open","outcome":"completed"},{"id":"search","outcome":"unknown","status":"completed"}]}"#))
        XCTAssertEqual(model.title, "执行手机流程 · 待核对")
        XCTAssertEqual(model.detail, "已确认执行 1 步")
        XCTAssertEqual(model.state, .failed)
    }
}
