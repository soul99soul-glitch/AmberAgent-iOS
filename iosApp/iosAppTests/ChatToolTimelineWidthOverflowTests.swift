import XCTest
import SwiftUI
import Shared
@testable import iosApp

/// WebMount 工具胶囊标题不得把聊天列撑出左右对称裁切。
@MainActor
final class ChatToolTimelineWidthOverflowTests: XCTestCase {

    private let screenWidth: CGFloat = 393
    private let columnWidth: CGFloat = 393 - ChatLayout.contentHorizontalInset * 2

    func testCollapsedReasoningAndTappableToolsUseSameRowHeight() {
        let proposal = CGSize(width: columnWidth, height: UIView.layoutFittingExpandedSize.height)
        let reasoning = UIHostingController(rootView: ChatReasoningCard(bodyText: "已完成思考"))
        let reasoningHeight = reasoning.sizeThatFits(in: proposal).height
        XCTAssertEqual(reasoningHeight, 44, accuracy: 0.5)
        let outputs: [[UIMessagePart]] = [[], [UIMessagePart.Text(text: "完成", metadata: nil)]]
        for output in outputs {
            let tool = UIMessagePart.Tool(
                toolCallId: "capsule-height", toolName: "search_web", input: "{}", output: output,
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil
            )
            let host = UIHostingController(rootView: ChatToolTimeline(
                steps: [ChatToolStepModel(tool: tool)], onTapStep: { _ in }
            ))
            XCTAssertEqual(host.sizeThatFits(in: proposal).height, reasoningHeight, accuracy: 0.5)
        }
    }

    func testWebMountCapsuleUsesStableActionTitleInsteadOfRawJSON() {
        let input = """
        {"display_name":"GitHub","homepage_url":"https://github.com/openai/codex","site_id":"user_github"}
        """
        let tool = UIMessagePart.Tool(
            toolCallId: "call_wm_site_add",
            toolName: "wm_site_add",
            input: input,
            output: [UIMessagePart.Text(text: #"{"ok":true}"#, metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let title = ChatToolStepModel(tool: tool).title
        XCTAssertEqual(
            title,
            IOSAppLocalization.string("添加 WebMount 站点", defaultValue: "添加 WebMount 站点")
        )
        XCTAssertFalse(title.contains("{"), "标题不应再塞整段 JSON，实际=\(title)")
    }

    func testWebMountCapsuleActionTitleDoesNotDependOnInputShape() {
        let input = #"{"name":"OpenAI Codex","url":"https://github.com/openai/codex"}"#
        let tool = UIMessagePart.Tool(
            toolCallId: "call_wm_site_add_name",
            toolName: "wm_site_add",
            input: input,
            output: [UIMessagePart.Text(text: #"{"ok":true}"#, metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let title = ChatToolStepModel(tool: tool).title
        XCTAssertEqual(
            title,
            IOSAppLocalization.string("添加 WebMount 站点", defaultValue: "添加 WebMount 站点")
        )
        XCTAssertFalse(title.contains("https://"), "不应退回整段 URL，实际=\(title)")
    }

    func testWebMountCapsuleRedactsTypedTextAndURLQuery() {
        let typedSecret = "typed-private-value"
        let typeTool = UIMessagePart.Tool(
            toolCallId: "call_wm_type_private",
            toolName: "wm_type",
            input: "{\"selector\":\"#password\",\"text\":\"\(typedSecret)\"}",
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let typeStep = ChatToolStepModel(tool: typeTool)
        XCTAssertEqual(typeStep.title, "输入网页字段")
        XCTAssertFalse(typeStep.title.contains(typedSecret))
        XCTAssertFalse(typeStep.detail?.contains(typedSecret) == true)

        let URLSecret = "query-private-value"
        let openTool = UIMessagePart.Tool(
            toolCallId: "call_wm_open_private",
            toolName: "wm_open",
            input: "{\"url\":\"https://example.com/orders?token=\(URLSecret)\"}",
            output: [UIMessagePart.Text(
                text: "{\"status\":\"ready\",\"url\":\"https://example.com/orders?token=\(URLSecret)\"}",
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let openStep = ChatToolStepModel(tool: openTool)
        XCTAssertFalse(openStep.title.contains(URLSecret))
        XCTAssertFalse(openStep.detail?.contains(URLSecret) == true)
        XCTAssertEqual(openStep.title, "打开网页")
    }

    /// cell 自 sizing 用无界提案询问理想宽度：胶囊理想宽必须自身就在列宽预算内，
    /// 否则列宽随 toolCallStarted/完成换词跳变、超长行被居中裁切顶到屏幕两端。
    /// 有界提案下的 truncation 由上一条用例覆盖，这里只锁理想宽。
    func testToolCapsuleIdealWidthStaysWithinColumnUnderUnboundedProposal() {
        let longCJK = String(repeating: "长", count: 40)
        let tools: [UIMessagePart.Tool] = [
            UIMessagePart.Tool(
                toolCallId: "call_search_long",
                toolName: "search_web",
                input: #"{"query":""# + longCJK + #""}"#,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "call_image_long",
                toolName: "generate_image",
                input: #"{"prompt":""# + longCJK + #""}"#,
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
            UIMessagePart.Tool(
                toolCallId: "call_mcp_long",
                toolName: "mcp__a_very_long_server_name__a_very_long_tool_name",
                input: "{}",
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ),
        ]
        for tool in tools {
            let host = UIHostingController(rootView: ChatToolTimeline(steps: [ChatToolStepModel(tool: tool)]))
            let fitted = host.sizeThatFits(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: UIView.layoutFittingExpandedSize.height
            ))
            XCTAssertLessThanOrEqual(
                fitted.width,
                columnWidth + 1,
                "胶囊理想宽超出列宽（\(tool.toolName)）：fitted=\(fitted)"
            )
        }
    }

    /// 搜索胶囊生命周期三阶段宽度恒定契约（本轮真机 bug 的红测试）：
    /// 同一 tool call 的胶囊理想宽不得随「正在搜索 → 已搜索」换词或状态图标
    /// （转圈 → 对勾）变化——否则执行期间撑宽、完成缩回，胶囊/列宽随
    /// toolCallStarted / toolResultAppended 跳变。
    func testSearchCapsuleIdealWidthConstantAcrossLifecyclePhases() {
        // 真实形态：20+ 字中文查询（超过 subject 截断预算，三阶段共用同一截断后宽度）。
        let query = "苹果公司2026年秋季新品发布会时间安排和产品阵容一览表"
        XCTAssertGreaterThanOrEqual(query.count, 20, "用例前置：查询词应 ≥20 字")
        let input = #"{"query":"\#(query)"}"#

        func capsuleIdealWidth(output: [UIMessagePart]) -> CGFloat {
            let tool = UIMessagePart.Tool(
                toolCallId: "call_search_lifecycle",
                toolName: "search_web",
                input: input,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let host = UIHostingController(rootView: ChatToolTimeline(steps: [ChatToolStepModel(tool: tool)]))
            return host.sizeThatFits(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: UIView.layoutFittingExpandedSize.height
            )).width
        }

        let started = capsuleIdealWidth(output: [])
        let executing = capsuleIdealWidth(output: [])
        let completed = capsuleIdealWidth(output: [
            UIMessagePart.Text(text: #"{"results":[{"title":"苹果秋季发布会 2026"}]}"#, metadata: nil)
        ])

        XCTAssertEqual(
            executing, started,
            "toolCallStarted 与执行中阶段胶囊理想宽不一致：started=\(started) executing=\(executing)"
        )
        XCTAssertEqual(
            completed, started,
            "toolResultAppended 换词（正在搜索→已搜索）后胶囊理想宽变化（执行期间撑宽、完成缩回）：started=\(started) completed=\(completed)"
        )
    }

    /// 流式 tool 参数会按 `input + delta` 拼 JSON。未完成 JSON 不得回退成胶囊标题，
    /// 否则「搜索 {\"query\":...」先撑宽、解析成功后再缩回短 query。
    func testSearchCapsuleTitleIgnoresIncompleteJSONAndKeepsVerb() {
        func title(input: String, output: [UIMessagePart] = []) -> String {
            ChatToolStepModel(tool: UIMessagePart.Tool(
                toolCallId: "call_search_stream_title",
                toolName: "search_web",
                input: input,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )).title
        }

        XCTAssertEqual(title(input: ""), "搜索网页")
        XCTAssertEqual(title(input: "{"), "搜索网页")
        XCTAssertEqual(title(input: #"{"query":"天气"#), "搜索网页")
        XCTAssertEqual(title(input: "{}"), "搜索网页")
        XCTAssertEqual(title(input: #"{"query":"天气"}"#), "搜索网页")
        XCTAssertEqual(
            title(
                input: #"{"query":"天气"}"#,
                output: [UIMessagePart.Text(text: #"{"results":[]}"#, metadata: nil)]
            ),
            "搜索网页"
        )
        for input in ["", "{", #"{"query":"天气"#, "{}", #"{"query":"天气"}"#] {
            XCTAssertFalse(
                title(input: input).contains("{"),
                "搜索标题不应暴露原始 JSON，input=\(input) title=\(title(input: input))"
            )
        }
    }

    /// 搜索胶囊从空参 → 截断 JSON → 短 query → 长 query → 出结果，理想宽必须同一值。
    /// 生产路径带详情 chevron；无界提案下 hug 标题会随流式参数跳变。
    func testSearchCapsuleIdealWidthConstantAcrossStreamingInput() {
        func capsuleIdealWidth(input: String, output: [UIMessagePart] = []) -> CGFloat {
            let tool = UIMessagePart.Tool(
                toolCallId: "call_search_stream_width",
                toolName: "search_web",
                input: input,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            let host = UIHostingController(
                rootView: ChatToolTimeline(
                    steps: [ChatToolStepModel(tool: tool)],
                    onTapStep: { _ in }
                )
            )
            return host.sizeThatFits(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: UIView.layoutFittingExpandedSize.height
            )).width
        }

        let empty = capsuleIdealWidth(input: "")
        let brace = capsuleIdealWidth(input: "{")
        let partial = capsuleIdealWidth(input: #"{"query":"天气"#)
        let shortQuery = capsuleIdealWidth(input: #"{"query":"天气"}"#)
        let longQuery = capsuleIdealWidth(input: #"{"query":"苹果公司2026年秋季新品发布会时间安排和产品阵容一览表"}"#)
        let completed = capsuleIdealWidth(
            input: #"{"query":"天气"}"#,
            output: [UIMessagePart.Text(text: #"{"results":[{"title":"天气预报"}]}"#, metadata: nil)]
        )

        for (name, width) in [
            ("empty", empty),
            ("brace", brace),
            ("partialJSON", partial),
            ("shortQuery", shortQuery),
            ("longQuery", longQuery),
            ("completed", completed),
        ] {
            XCTAssertEqual(
                width,
                empty,
                "搜索胶囊理想宽在 \(name) 阶段变化：empty=\(empty) \(name)=\(width)"
            )
        }
        XCTAssertLessThanOrEqual(empty, columnWidth + 1, "搜索胶囊理想宽超出列宽：\(empty)")
    }

    func testToolSearchCapsuleHugsContentAndFitsCompactAccessibilityWidth() {
        func model(toolName: String) -> ChatToolStepModel {
            ChatToolStepModel(tool: UIMessagePart.Tool(
                toolCallId: "call_\(toolName)",
                toolName: toolName,
                input: "{}",
                output: [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ))
        }

        func idealWidth(_ step: ChatToolStepModel) -> CGFloat {
            UIHostingController(rootView: ChatToolTimeline(steps: [step]))
                .sizeThatFits(in: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: UIView.layoutFittingExpandedSize.height
                ))
                .width
        }

        let toolSearch = model(toolName: "tool_search")
        XCTAssertEqual(toolSearch.title, "查找工具")
        XCTAssertLessThanOrEqual(
            idealWidth(toolSearch),
            idealWidth(model(toolName: "search_web")) + 1,
            "tool_search 应只按自身可见标题自适应"
        )

        let compactColumnWidth = 320 - ChatLayout.contentHorizontalInset * 2
        let compactHost = UIHostingController(
            rootView: ChatToolTimeline(steps: [toolSearch])
                .dynamicTypeSize(.accessibility3)
        )
        let fitted = compactHost.sizeThatFits(in: CGSize(
            width: compactColumnWidth,
            height: UIView.layoutFittingExpandedSize.height
        ))
        XCTAssertLessThanOrEqual(fitted.width, compactColumnWidth + 1, "fitted=\(fitted)")
    }

    func testToolSearchCapsuleIdealWidthConstantAcrossLifecycle() {
        func idealWidth(output: [UIMessagePart]) -> CGFloat {
            let tool = UIMessagePart.Tool(
                toolCallId: "call_tool_search_lifecycle",
                toolName: "tool_search",
                input: #"{"query":"browser automation"}"#,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            return UIHostingController(
                rootView: ChatToolTimeline(
                    steps: [ChatToolStepModel(tool: tool)],
                    onTapStep: { _ in }
                )
            )
            .sizeThatFits(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: UIView.layoutFittingExpandedSize.height
            ))
            .width
        }

        let active = idealWidth(output: [])
        let completed = idealWidth(output: [
            UIMessagePart.Text(text: #"{"tools":[{"name":"wm_click"}]}"#, metadata: nil)
        ])
        let failed = idealWidth(output: [
            UIMessagePart.Text(text: #"{"error":"tool search failed"}"#, metadata: nil)
        ])

        XCTAssertEqual(completed, active, "tool_search 完成时不应改变胶囊宽度")
        XCTAssertEqual(failed, active, "tool_search 失败时不应改变胶囊宽度")
    }

    func testWebMountCapsuleIdealWidthConstantAcrossStreamingAndLifecycle() {
        func idealWidth(input: String, output: [UIMessagePart] = []) -> CGFloat {
            let tool = UIMessagePart.Tool(
                toolCallId: "call_wm_click_lifecycle",
                toolName: "wm_click",
                input: input,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )
            return UIHostingController(
                rootView: ChatToolTimeline(
                    steps: [ChatToolStepModel(tool: tool)],
                    onTapStep: { _ in }
                )
            )
            .sizeThatFits(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: UIView.layoutFittingExpandedSize.height
            ))
            .width
        }

        let empty = idealWidth(input: "")
        let partialJSON = idealWidth(input: #"{"target":"css:button"#)
        let completeInput = idealWidth(input: #"{"target":"css:button"}"#)
        let completed = idealWidth(
            input: #"{"target":"css:button"}"#,
            output: [UIMessagePart.Text(text: #"{"ok":true,"status":"ready"}"#, metadata: nil)]
        )
        let failed = idealWidth(
            input: #"{"target":"css:button"}"#,
            output: [UIMessagePart.Text(text: #"{"error":"click failed"}"#, metadata: nil)]
        )

        for (phase, width) in [
            ("partialJSON", partialJSON),
            ("completeInput", completeInput),
            ("completed", completed),
            ("failed", failed),
        ] {
            XCTAssertEqual(width, empty, "WebMount 胶囊在 \(phase) 阶段改变宽度")
        }
        XCTAssertLessThanOrEqual(empty, columnWidth + 1, "WebMount 胶囊理想宽超出列宽：\(empty)")
    }

    /// 状态/标签页这类短浏览器动作不携带需要常驻胶囊的目标信息。标题本身应当
    /// 在执行中、成功、失败间保持稳定，并按可见内容收缩；不能再用 20 字透明
    /// 占位把短标题撑成近整列宽。
    func testShortWebMountCapsulesHugStableVisibleTitleWithoutHiddenSentinel() {
        func model(toolName: String, output: [UIMessagePart]) -> ChatToolStepModel {
            ChatToolStepModel(tool: UIMessagePart.Tool(
                toolCallId: "call_\(toolName)_compact",
                toolName: toolName,
                input: #"{"session_id":"ios_wm_example"}"#,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ))
        }

        for (toolName, expectedTitle) in [
            ("wm_state", "读取网页状态"),
            ("wm_tab_list", "读取网页标签页"),
        ] {
            let active = model(toolName: toolName, output: [])
            let completed = model(
                toolName: toolName,
                output: [UIMessagePart.Text(text: #"{"ok":true}"#, metadata: nil)]
            )
            let failed = model(
                toolName: toolName,
                output: [UIMessagePart.Text(text: #"{"error":"failed"}"#, metadata: nil)]
            )

            XCTAssertEqual(active.title, expectedTitle)
            XCTAssertEqual(completed.title, expectedTitle)
            XCTAssertEqual(failed.title, expectedTitle)
            let host = UIHostingController(
                rootView: ChatToolTimeline(steps: [active], onTapStep: { _ in })
            )
            let fitted = host.sizeThatFits(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: UIView.layoutFittingExpandedSize.height
            ))
            XCTAssertLessThan(
                fitted.width,
                columnWidth * 0.75,
                "短浏览器工具应按内容收缩（\(toolName)）：fitted=\(fitted)"
            )
        }
    }

    func testStatefulToolCapsulesKeepOneAdaptiveTitleAcrossLifecycle() {
        let cases: [(name: String, title: String, input: String)] = [
            ("subagent_dispatch", "启动子智能体", #"{"objective":"检查调用链"}"#),
            ("search_web", "搜索网页", #"{"query":"天气"}"#),
            ("scrape_web", "读取网页", #"{"url":"https://example.com"}"#),
            ("memory_tool", "更新核心记忆", "{}"),
            ("mcp_call", "调用 MCP", #"{"server":"demo","tool":"read"}"#),
            ("model_council_run", "模型议会", "{}"),
            ("generate_image", "生成图片", #"{"prompt":"一只猫"}"#),
            ("ish_handoff", "iSH 交接", "{}"),
            ("ios_ish_execute", "内置 iSH 执行", "{}"),
            ("terminal_execute", "Remote SSH 执行", "{}"),
            (IOSAmberShellToolCatalog.executeToolName, "AmberShell 执行", "{}"),
            (IOSRemoteTerminalToolCatalog.jobStartToolName, "启动终端作业", "{}"),
            ("workspace_file_read", "读取 Workspace 文件", #"{"path":"/workspace/a.md"}"#),
        ]

        func model(_ item: (name: String, title: String, input: String), output: [UIMessagePart]) -> ChatToolStepModel {
            ChatToolStepModel(tool: UIMessagePart.Tool(
                toolCallId: "call_\(item.name)",
                toolName: item.name,
                input: item.input,
                output: output,
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            ))
        }

        func idealWidth(_ step: ChatToolStepModel) -> CGFloat {
            UIHostingController(rootView: ChatToolTimeline(steps: [step], onTapStep: { _ in }))
                .sizeThatFits(in: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: UIView.layoutFittingExpandedSize.height
                ))
                .width
        }

        for item in cases {
            let active = model(item, output: [])
            let completed = model(item, output: [
                UIMessagePart.Text(text: #"{"ok":true,"status":"completed"}"#, metadata: nil)
            ])
            let failed = model(item, output: [
                UIMessagePart.Text(text: #"{"ok":false,"status":"failed","error":"failed"}"#, metadata: nil)
            ])
            XCTAssertEqual(active.title, item.title, item.name)
            XCTAssertEqual(completed.title, item.title, item.name)
            XCTAssertEqual(failed.title, item.title, item.name)
            XCTAssertEqual(idealWidth(completed), idealWidth(active), item.name)
            XCTAssertEqual(idealWidth(failed), idealWidth(active), item.name)
            XCTAssertLessThanOrEqual(idealWidth(active), columnWidth + 1, item.name)
        }
    }

    func testLongWebMountToolTitleFitsWhenColumnWidthIsProposed() {
        let input = """
        {"display_name":"GitHub","homepage_url":"https://github.com/openai/codex","site_id":"user_github","timeout_ms":15000}
        """
        let tool = UIMessagePart.Tool(
            toolCallId: "call_wm_site_add",
            toolName: "wm_site_add",
            input: input,
            output: [UIMessagePart.Text(text: #"{"ok":true}"#, metadata: nil)],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let host = UIHostingController(rootView: ChatToolTimeline(steps: [ChatToolStepModel(tool: tool)]))
        let fitted = host.sizeThatFits(in: CGSize(
            width: columnWidth,
            height: UIView.layoutFittingExpandedSize.height
        ))
        XCTAssertLessThanOrEqual(fitted.width, columnWidth + 1, "fitted=\(fitted)")
    }

    func testAgentBrowserTaskCardFitsLongAutomationMetadataWithinChatColumn() {
        let record = makeLongWebMountRecord()
        let host = UIHostingController(rootView: AgentBrowserTaskCard(record: record, onOpen: {}))
        let fitted = host.sizeThatFits(in: CGSize(
            width: columnWidth,
            height: UIView.layoutFittingExpandedSize.height
        ))

        XCTAssertLessThanOrEqual(fitted.width, columnWidth + 1, "fitted=\(fitted)")
    }

    func testAgentBrowserCompactBarDoesNotExpandChatForLongRunSummary() {
        let longSummary = String(repeating: "网页自动化摘要没有空格", count: 80)
        let host = UIHostingController(rootView: AgentBrowserTaskCompactBar(
            record: makeLongWebMountRecord(),
            runSummary: longSummary,
            onExpand: {}
        ))
        let fitted = host.sizeThatFits(in: CGSize(
            width: columnWidth,
            height: UIView.layoutFittingExpandedSize.height
        ))

        XCTAssertLessThanOrEqual(fitted.width, columnWidth + 1, "fitted=\(fitted)")
    }

    func testWebMountApprovalCardFitsLongAutomationMetadataWithinChatColumn() {
        let longToken = String(repeating: "segment-without-breaks-", count: 24)
        let request = WebMountToolApprovalRequest(
            id: "approval",
            toolName: "wm_click",
            siteId: "site-\(longToken)",
            siteName: "自动化站点-\(longToken)",
            host: "example.com",
            backend: IOSWebMountBackendKind.local.rawValue,
            mcpServerName: nil,
            redactedURL: "https://example.com/\(longToken)",
            snapshotId: "snapshot-\(longToken)",
            target: "target-\(longToken)",
            action: "点击目标",
            consequence: "可能提交当前页面内容",
            screenshotRetentionWarning: nil,
            requiresHumanHandoff: false,
            reason: "需要批准当前浏览器动作",
            sessionId: nil,
            runId: nil
        )
        let host = UIHostingController(rootView: WebMountToolApprovalCard(
            request: request,
            onOpenSession: nil,
            onApprove: {},
            onDeny: {}
        ))
        let fitted = host.sizeThatFits(in: CGSize(
            width: columnWidth,
            height: UIView.layoutFittingExpandedSize.height
        ))

        XCTAssertLessThanOrEqual(fitted.width, columnWidth + 1, "fitted=\(fitted)")
    }

    func testDispatchedWebMountMutationKeepsReobserveHintWithoutRenderingAsFailure() {
        let tool = UIMessagePart.Tool(
            toolCallId: "call_wm_unverified",
            toolName: "wm_click",
            input: #"{"target":"css:button","snapshot_id":"document:1"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"status":"dispatched_unverified","may_have_applied":true}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )

        let model = ChatToolStepModel(tool: tool)
        XCTAssertEqual(model.state, .done)
        XCTAssertTrue(model.detail?.contains("尚未验证") == true)
    }

    private func makeLongWebMountRecord() -> IOSWebMountSessionRecord {
        let longToken = String(repeating: "segment-without-breaks-", count: 24)
        return IOSWebMountSessionRecord(
            id: "session-\(longToken)",
            siteId: "site-\(longToken)",
            siteName: "自动化站点-\(longToken)",
            title: "页面-\(longToken)",
            redactedURL: "https://example.com/\(longToken)",
            status: IOSWebMountRuntimeStatus.ready.rawValue,
            canGoBack: false,
            canGoForward: false,
            lastActivityMillis: 0,
            isCurrent: true,
            ownerConversationId: nil,
            ownerRunId: nil,
            controlOwner: .agent,
            leaseExpiresAtMillis: nil,
            persistentOptIn: false,
            needsReopen: false,
            backend: .local,
            mcpServerName: nil
        )
    }
}

@MainActor
final class ChatToolGlyphMappingTests: XCTestCase {
    @MainActor
    private final class StatusLoaderProbe {
        var responses: [[String: String]]
        private(set) var calls = 0

        init(responses: [[String: String]]) {
            self.responses = responses
        }

        func load(_ conversationHexes: [String]) async -> [String: String] {
            calls += 1
            guard !responses.isEmpty else { return [:] }
            let index = min(calls - 1, responses.count - 1)
            return responses[index]
        }
    }

    func testSubAgentNotificationRefreshesHostedCapsuleStatus() async throws {
        let probe = StatusLoaderProbe(responses: [
            ["child-ui": "running"],
            ["child-ui": "completed"]
        ])
        let tool = UIMessagePart.Tool(
            toolCallId: "subagent-ui-state",
            toolName: "spawn_agent",
            input: #"{"task_name":"browser","message":"观察页面"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"task_name":"browser","child_thread_id":"child-ui","status":"started"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let step = ChatToolStepModel(tool: tool)
        let host = UIHostingController(rootView: ChatToolTimeline(
            steps: [step],
            onTapStep: { _ in },
            subAgentRunStatusLoader: { [probe] conversationHexes in
                await probe.load(conversationHexes)
            }
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 240)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        let loadedInitialStatus = await waitUntil(timeout: 1.0) { probe.calls >= 1 }
        XCTAssertTrue(loadedInitialStatus, "Hosted capsule must load the child's durable status on appearance")
        let initialCalls = probe.calls
        NotificationCenter.default.post(
            name: .amberChatBackgroundJobStateDidChange,
            object: IOSChatBackgroundJobStateEvent(conversationId: "child-ui")
        )
        let refreshed = await waitUntil(timeout: 1.0) { probe.calls > initialCalls }
        XCTAssertTrue(refreshed, "A matching runtime notification must refresh the hosted capsule's status")
    }

    func testFailedOrchestrationReceiptCannotApplyStaleChildRunStatus() throws {
        let tool = UIMessagePart.Tool(
            toolCallId: "orchestration-followup-failed",
            toolName: "followup_task",
            input: #"{"target":"child-old","message":"补充检查"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":false,"recipient_thread_id":"child-old","status":"failed","error":"start_failed"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )

        let step = ChatToolStepModel(tool: tool)
        let presentation = try XCTUnwrap(step.subAgentPresentation)
        XCTAssertEqual(step.state, .failed)
        XCTAssertEqual(presentation.threadID, "child-old")
        XCTAssertFalse(presentation.hasAcceptedReceipt)
        XCTAssertFalse(step.canApplySubAgentRunStatus)
    }

    func testSubAgentRunVisualStateMapsDurableWireStatuses() {
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "started"), .running)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "created"), .queued)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "WAITING_EXTERNAL"), .queued)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "running"), .running)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "COMPLETED"), .completed)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "failed"), .failed)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "cancelled"), .cancelled)
        XCTAssertEqual(ChatSubAgentRunVisualState(rawStatus: "outcome_unknown"), .unknown)
        XCTAssertEqual(ChatSubAgentRunVisualState.unknown.stepState, .failed)
        XCTAssertNil(ChatSubAgentRunVisualState(rawStatus: "none"))
        XCTAssertNil(ChatSubAgentRunVisualState(rawStatus: nil))
    }

    func testSubAgentRunVisualStateNeverShowsPendingDotForTerminalOutcome() {
        XCTAssertTrue(ChatSubAgentRunVisualState.queued.usesPendingIndicator)
        XCTAssertFalse(ChatSubAgentRunVisualState.unknown.usesPendingIndicator)
        XCTAssertFalse(ChatSubAgentRunVisualState.running.usesPendingIndicator)
        XCTAssertFalse(ChatSubAgentRunVisualState.completed.usesPendingIndicator)
        XCTAssertFalse(ChatSubAgentRunVisualState.failed.usesPendingIndicator)
        XCTAssertFalse(ChatSubAgentRunVisualState.cancelled.usesPendingIndicator)
    }

    func testSubAgentCapsuleResolvesBuiltInIdentityAndShortWorkHint() throws {
        let objective = "搜索公开资料并整理关键证据，然后交叉核对来源和时间线"
        let tool = UIMessagePart.Tool(
            toolCallId: "subagent-explorer-1",
            toolName: "subagent_dispatch",
            input: #"{"role_id":"explorer","objective":"\#(objective)"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )

        let step = ChatToolStepModel(tool: tool)
        let presentation = try XCTUnwrap(step.subAgentPresentation)
        XCTAssertTrue(step.isSubAgent)
        XCTAssertEqual(presentation.identity, "role:explorer")
        XCTAssertEqual(
            presentation.displayName,
            IOSAppLocalization.string("探索者", defaultValue: "探索者")
        )
        let activeStatus = IOSAppLocalization.string("进行中", defaultValue: "进行中")
        XCTAssertEqual(presentation.status, activeStatus)
        let searchTask = IOSAppLocalization.string("搜索资料", defaultValue: "搜索资料")
        XCTAssertEqual(presentation.workSummary, searchTask)
        XCTAssertEqual(presentation.statusLine, "\(activeStatus) · \(searchTask)")
    }

    func testSubAgentCapsuleKeepsDynamicNameAndIdentityAcrossCompletion() throws {
        let input = #"{"role_id":"source_checker","custom_role_name":"@来源核查","objective":"核对网页来源"}"#
        let activeTool = UIMessagePart.Tool(
            toolCallId: "subagent-dynamic-1",
            toolName: "subagent_dispatch",
            input: input,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let completedTool = UIMessagePart.Tool(
            toolCallId: "subagent-dynamic-1",
            toolName: "subagent_dispatch",
            input: input,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"role_id":"source_checker","role_name":"来源核查","status":"completed","summary":"已核对来源"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )

        let active = try XCTUnwrap(ChatToolStepModel(tool: activeTool).subAgentPresentation)
        let completed = try XCTUnwrap(ChatToolStepModel(tool: completedTool).subAgentPresentation)
        XCTAssertEqual(active.displayName, "来源核查")
        XCTAssertEqual(completed.displayName, active.displayName)
        XCTAssertEqual(completed.identity, active.identity)
        XCTAssertEqual(completed.status, IOSAppLocalization.string("已完成", defaultValue: "已完成"))
        XCTAssertEqual(
            completed.workSummary,
            IOSAppLocalization.string("核对来源", defaultValue: "核对来源")
        )
    }

    func testSpawnCapsuleUsesResolvedNameAfterSiblingCollision() throws {
        let spawn = UIMessagePart.Tool(
            toolCallId: "name-collision", toolName: "spawn_agent",
            input: #"{"task_name":"alex","message":"核对来源"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"task_name":"alex_2","agent_path":"/root/alex_2","child_thread_id":"child-2","status":"started"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let presentation = try XCTUnwrap(ChatToolStepModel(tool: spawn).subAgentPresentation)
        XCTAssertEqual(presentation.displayName, "alex_2")
        XCTAssertEqual(presentation.identity, "dynamic:alex_2")
        XCTAssertEqual(presentation.threadID, "child-2")
    }

    func testOrchestrationCapsulesMapSpawnAndFollowupStatuses() throws {
        let spawn = UIMessagePart.Tool(
            toolCallId: "orchestration-spawn-1",
            toolName: "spawn_agent",
            input: #"{"task_name":"browser","message":"观察页面并整理关键结论"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"task_name":"browser","agent_path":"/root/browser","child_thread_id":"child-1","status":"started"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let spawnStep = ChatToolStepModel(tool: spawn)
        let spawnPresentation = try XCTUnwrap(spawnStep.subAgentPresentation)
        XCTAssertTrue(spawnStep.isSubAgent)
        XCTAssertEqual(spawnStep.state, .done)
        XCTAssertEqual(spawnPresentation.displayName, "browser")
        XCTAssertEqual(
            spawnPresentation.status,
            IOSAppLocalization.string("已启动", defaultValue: "已启动")
        )
        XCTAssertEqual(
            spawnPresentation.workSummary,
            IOSAppLocalization.string("检查网页", defaultValue: "检查网页")
        )
        XCTAssertEqual(spawnPresentation.threadID, "child-1")
        XCTAssertNotEqual(
            spawnPresentation.status,
            IOSAppLocalization.string("已完成", defaultValue: "已完成")
        )

        let followup = UIMessagePart.Tool(
            toolCallId: "orchestration-followup-1",
            toolName: "followup_task",
            input: #"{"target":"child-old","message":"补充核对登录状态"}"#,
            output: [UIMessagePart.Text(
                text: #"{"ok":true,"target":"child-1","agent_path":"/root/browser","recipient_thread_id":"child-1","status":"queued"}"#,
                metadata: nil
            )],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let followupStep = ChatToolStepModel(tool: followup)
        let followupPresentation = try XCTUnwrap(followupStep.subAgentPresentation)
        XCTAssertTrue(followupStep.isSubAgent)
        XCTAssertEqual(followupStep.state, .done)
        XCTAssertEqual(followupPresentation.displayName, "browser")
        XCTAssertEqual(
            followupPresentation.status,
            IOSAppLocalization.string("已排队", defaultValue: "已排队")
        )
        XCTAssertEqual(
            followupPresentation.workSummary,
            IOSAppLocalization.string("核对登录", defaultValue: "核对登录")
        )
        XCTAssertEqual(followupPresentation.threadID, "child-1")
        XCTAssertEqual(followupPresentation.identity, "dynamic:browser")
        XCTAssertTrue(followupPresentation.hasAcceptedReceipt)
    }

    func testKoboyoMarksParseToNonEmptyPaths() {
        for mark in ChatKoboyoMark.allCases {
            let bounds = mark.renderedPath.boundingRect
            XCTAssertFalse(
                bounds.isNull || bounds.isEmpty || bounds.width < 1 || bounds.height < 1,
                "\(mark.rawValue) path should parse to a drawable glyph"
            )
        }
    }

    func testVisualKindMapsKnownTools() {
        let cases: [(String, ChatToolVisualKind, ChatKoboyoMark, String)] = [
            ("search_web", .search, .solidSearch, "magnifyingglass"),
            ("scrape_web", .web, .solidGlobe, "globe"),
            ("wm_open", .webMount, .solidMonitor, "globe.badge.chevron.backward"),
            ("wm_observe", .webMountObserve, .solidEye, "globe.badge.chevron.backward"),
            ("wm_screenshot", .webMountCapture, .solidCamera, "globe.badge.chevron.backward"),
            ("workspace_file_read", .workspaceRead, .solidDocument, "doc.text"),
            ("workspace_file_write", .workspaceWrite, .solidPen, "folder"),
            ("workspace_artifact_delete", .workspaceDelete, .solidWrench, "folder"),
            ("generate_image", .image, .solidImage, "photo.on.rectangle"),
            ("ish_handoff", .terminal, .solidTerminal, "terminal"),
            ("ios_ish_execute", .terminal, .solidTerminal, "terminal"),
            ("mcp_call", .mcp, .solidPuzzle, "puzzlepiece.extension"),
            ("subagent_dispatch", .subagent, .solidUsers, "person.2.fill"),
            ("spawn_agent", .subagent, .solidUsers, "person.2.fill"),
            ("followup_task", .subagent, .solidUsers, "person.2.fill"),
            ("model_council_run", .council, .solidPeopleGroup, "person.3.sequence"),
            ("memory_tool", .memory, .solidBrain, "brain.head.profile"),
        ]
        for (name, kind, mark, systemImage) in cases {
            let resolved = ChatToolVisualKind.resolve(toolName: name)
            XCTAssertEqual(resolved, kind, name)
            XCTAssertEqual(resolved.koboyoMark, mark, name)
            XCTAssertEqual(resolved.systemImage, systemImage, name)
        }
    }

    func testStepModelUsesKoboyoMarkAndKeepsIslandSystemImage() {
        let tool = UIMessagePart.Tool(
            toolCallId: "c1",
            toolName: "search_web",
            input: #"{"query":"amber"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let step = ChatToolStepModel(tool: tool)
        XCTAssertEqual(step.visualKind, .search)
        XCTAssertEqual(step.koboyoMark, .solidSearch)
        XCTAssertEqual(step.systemImage, "magnifyingglass")
        XCTAssertTrue(step.visualKind.isImageTool == false)
    }

    func testImageToolVisualKindFlagsIslandImageKind() {
        XCTAssertTrue(ChatToolVisualKind.image.isImageTool)
        XCTAssertEqual(ChatToolVisualKind.image.activeIslandTint, .green)
        XCTAssertEqual(ChatToolVisualKind.search.activeIslandTint, .cyan)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

}
