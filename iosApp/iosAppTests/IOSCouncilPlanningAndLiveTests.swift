import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


@MainActor
final class IOSCouncilPlanningAndLiveTests: IOSCouncilMechanicsTestCase {
    func testHostSystemPromptPreservesConfiguredInstructionsWithoutInventingProviderRoutes() {
        let runner = IOSCouncilRoomRunner(
            streamer: ScriptedCouncilStreamer([]),
            researcher: StaticCouncilResearcher(),
            taskStore: IOSAdvancedTaskStore(userDefaults: isolatedDefaults(), storageKey: "host-prompt")
        )
        var settings = compactRoomSettings()
        settings.host.prompt = "主持人只用来源里的事实。"

        let prompt = runner.hostSystemPrompt(settings: settings)

        XCTAssertTrue(prompt.hasPrefix(settings.host.prompt))
        XCTAssertFalse(prompt.contains("不要声称调用了跨服务商模型"))
        XCTAssertFalse(prompt.contains("所有席位都运行在当前 OpenAI-compatible 服务商内"))
        XCTAssertTrue(prompt.contains("不要虚构模型、服务商或工具调用"))
    }

    func testChatCouncilToolUsesPersistedRoomModelsWhenArgumentsDoNotOverrideThem() async {
        let defaults = isolatedDefaults()
        let roomSettingsStore = IOSCouncilRoomSettingsStore(
            userDefaults: defaults,
            storageKey: "tool-room-settings",
            currentModelId: "gpt-main"
        )
        roomSettingsStore.settings = compactRoomSettings(defaultRounds: 1)
        roomSettingsStore.dynamicSeatGeneration = false
        let models = ["gpt-main", "gpt-host", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let currentModel = models[0]
        let baseParams = TextGenerationParams(
            model: currentModel,
            temperature: nil,
            topP: nil,
            maxTokens: nil,
            tools: [],
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("风险发言"),
            .success("主持总结")
        ])
        let runner = CouncilRunner(
            taskStore: IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks"),
            roomSettingsStore: roomSettingsStore,
            roomStreamer: streamer
        )

        _ = await runner.run(
            objective: "验证工具链设置",
            providerSetting: provider,
            currentModel: currentModel,
            baseParams: baseParams
        )

        XCTAssertEqual(streamer.receivedModels.map(\.modelId), [
            "gpt-host", "gpt-engineer", "gpt-risk", "gpt-host"
        ])
    }

    func testCouncilApprovalFollowsGlobalAutoApproveSwitches() {
        func requires(_ policy: IOSAgentPermissionPolicy?, global: Bool = false, highRisk: Bool = false) -> Bool {
            ChatToolRuntime.councilRequiresApproval(
                policy: policy,
                globalAutoApprove: global,
                highRiskAutoApprove: highRisk
            )
        }
        XCTAssertTrue(requires(.askEveryTime))
        XCTAssertTrue(requires(.allowOncePerRun))
        XCTAssertFalse(requires(.askEveryTime, global: true), "开启自动批准后议会默认自动批准")
        XCTAssertFalse(requires(.askEveryTime, highRisk: true), "开启高风险自动批准后议会默认自动批准")
        XCTAssertFalse(requires(.allowOncePerRun, global: true, highRisk: true))
        XCTAssertFalse(requires(.autoApprove))
        XCTAssertFalse(requires(nil))
    }

    func testChatCouncilToolPublishesLiveTranscriptForToolCall() async {
        let toolCallId = "council-live-\(UUID().uuidString)"
        let result = await runChatCouncilTool(
            outputs: [.success("最终议题"), .success("工程发言"), .success("风险发言"), .success("主持总结")],
            toolCallId: toolCallId
        )

        guard let live = CouncilLiveRegistry.shared.model(forToolCallId: toolCallId, taskId: nil) else {
            return XCTFail("tool-path council must register a live model for its tool call")
        }
        XCTAssertFalse(live.isRunning)
        XCTAssertEqual(live.taskId, result["task_id"] as? String)
        XCTAssertFalse(live.speakers.isEmpty)
        let bodies = live.messages.map(\.body)
        XCTAssertTrue(bodies.contains("工程发言"), "\(bodies)")
        XCTAssertTrue(bodies.contains("风险发言"), "\(bodies)")
        XCTAssertFalse(live.messages.contains { $0.status == .speaking })
    }

    func testChatCouncilLiveTranscriptClosesSpeakingMessageWhenSynthesisThrows() async {
        let toolCallId = "council-live-fail-\(UUID().uuidString)"
        let result = await runChatCouncilTool(
            outputs: [.success("最终议题"), .success("工程发言"), .success("风险发言"), .failure(CouncilTestError.unexpectedCall)],
            toolCallId: toolCallId
        )

        XCTAssertEqual(result["ok"] as? Bool, false)
        let live = CouncilLiveRegistry.shared.model(forToolCallId: toolCallId, taskId: nil)
        XCTAssertEqual(live?.isRunning, false)
        XCTAssertEqual(
            live?.messages.filter { $0.status == .speaking }.map(\.author) ?? ["<no live model>"],
            [],
            "a failed council must not leave a message spinning as speaking"
        )
    }

    func testCouncilSheetShowsFailureReasonUnlessTranscriptAlreadyHasOne() {
        func msg(_ kind: IOSCouncilRoomMessageKind, _ status: IOSCouncilRoomMessageStatus) -> CouncilLiveMessage {
            CouncilLiveMessage(IOSCouncilRoomMessageEvent(id: UUID(), kind: kind, speakerId: nil, author: "a", body: "b", subtitle: nil, status: status))
        }
        XCTAssertTrue(ChatToolDetailSheet.councilShowsFailureReason(liveMessages: nil))
        XCTAssertTrue(
            ChatToolDetailSheet.councilShowsFailureReason(liveMessages: [msg(.seat, .failed)]),
            "interrupted/cancelled exits append no system message; the reason must still be shown"
        )
        XCTAssertFalse(ChatToolDetailSheet.councilShowsFailureReason(liveMessages: [msg(.seat, .completed), msg(.system, .failed)]))
    }

    func testCouncilTranscriptSplitsIntoPrepareRoundAndSummaryTabs() {
        func msg(_ kind: IOSCouncilRoomMessageKind, _ body: String) -> CouncilLiveMessage {
            CouncilLiveMessage(IOSCouncilRoomMessageEvent(id: UUID(), kind: kind, speakerId: nil, author: "a", body: body, subtitle: nil, status: .completed))
        }
        let messages = [
            msg(.divider, "已组建 2 位议员：甲、乙"),
            msg(.divider, "辩论开始"),
            msg(.divider, IOSCouncilRoomRunner.roundDividerTitle(1)),
            msg(.seat, "甲 1"),
            msg(.seat, "乙 1"),
            msg(.divider, "主持人轮末点评"),
            msg(.host, "点评 1"),
            msg(.divider, IOSCouncilRoomRunner.roundDividerTitle(2)),
            msg(.seat, "甲 2"),
            msg(.divider, IOSCouncilRoomRunner.hostSummaryDividerTitle),
            msg(.host, "总结正文"),
        ]

        let tabs = ChatToolDetailSheet.councilTranscriptTabs(messages)

        XCTAssertEqual(tabs.map(\.title), ["准备", "第 1 轮", "第 2 轮", "总结"])
        XCTAssertEqual(tabs.map { $0.messages.map(\.body) }, [
            ["已组建 2 位议员：甲、乙", "辩论开始"],
            ["甲 1", "乙 1", "主持人轮末点评", "点评 1"],
            ["甲 2"],
            ["总结正文"],
        ])
        XCTAssertEqual(tabs[1].id, messages[2].id.uuidString, "轮次 Tab 的 id 要稳定，新消息到来时选中状态不能丢")

        let justStarted = ChatToolDetailSheet.councilTranscriptTabs(Array(messages[..<3]))
        XCTAssertEqual(justStarted.map(\.title), ["准备", "第 1 轮"], "新一轮还没有发言时也要出现，运行中才能跟随过去")
        XCTAssertTrue(justStarted[1].messages.isEmpty)
        XCTAssertFalse(IOSCouncilRoomRunner.isRoundDivider("第 N 轮"))
    }

    func testCouncilLiveRegistryRejectsModelFromAnotherTask() {
        let registry = CouncilLiveRegistry()
        let model = CouncilLiveModel()
        model.ingest(.taskStarted("task-new"))
        registry.register(toolCallId: "call_1", model)

        XCTAssertTrue(registry.model(forToolCallId: "call_1", taskId: nil) === model)
        XCTAssertTrue(registry.model(forToolCallId: "call_1", taskId: "task-new") === model)
        XCTAssertNil(
            registry.model(forToolCallId: "call_1", taskId: "task-old"),
            "a reused short tool-call id must not show another council's transcript"
        )
    }

    func testCouncilLiveRegistryNotifiesObserversWhenModelRegisters() {
        let registry = CouncilLiveRegistry()
        let changed = expectation(description: "registry lookup observed a registration")
        withObservationTracking {
            _ = registry.model(forToolCallId: "call_pending", taskId: nil)
        } onChange: {
            changed.fulfill()
        }

        registry.register(toolCallId: "call_pending", CouncilLiveModel())

        // A sheet opened before approval must pick up the live model once it registers.
        wait(for: [changed], timeout: 0.1)
    }

    func testCouncilLiveStreamingUpdatesDoNotInvalidateTranscriptList() async throws {
        let live = CouncilLiveModel()
        let message = IOSCouncilRoomMessageEvent(
            id: UUID(), kind: .seat, speakerId: "s1", author: "席位", body: "", subtitle: nil, status: .speaking
        )
        live.ingest(.append(message))
        let listChanged = expectation(description: "transcript list invalidated")
        listChanged.isInverted = true
        withObservationTracking {
            _ = live.messages
        } onChange: {
            listChanged.fulfill()
        }

        for i in 1...5 {
            live.ingest(.updateMessage(id: message.id, body: String(repeating: "字", count: i), status: .speaking, lagAllowance: 1))
        }
        try await Task.sleep(for: .milliseconds(300))

        // 逐字流式只应重绘正在发言的那一行；列表失效会让整页和全部行重新求值。
        await fulfillment(of: [listChanged], timeout: 0.05)
        XCTAssertEqual(live.messages.last?.body, "字字字字字")
    }

    func testCouncilLiveCoalescesStreamingBodyButAppliesTerminalStateImmediately() async throws {
        let live = CouncilLiveModel()
        let message = IOSCouncilRoomMessageEvent(
            id: UUID(), kind: .seat, speakerId: "s1", author: "席位", body: "", subtitle: nil, status: .speaking
        )
        live.ingest(.append(message))

        for i in 1...20 {
            live.ingest(.updateMessage(id: message.id, body: "第\(i)拍", status: .speaking, lagAllowance: 1))
        }
        XCTAssertEqual(live.messages.last?.body, "", "流式拍应合并到下一个刷新窗口，而不是每拍都提交")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(live.messages.last?.body, "第20拍")

        live.ingest(.updateMessage(id: message.id, body: "第21拍", status: .speaking, lagAllowance: 1))
        live.ingest(.updateMessage(id: message.id, body: "终稿", status: .completed, lagAllowance: 0))
        XCTAssertEqual(live.messages.last?.body, "终稿")
        XCTAssertEqual(live.messages.last?.status, .completed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(live.messages.last?.body, "终稿", "已丢弃的流式拍不能在终态之后回写")

        let second = IOSCouncilRoomMessageEvent(
            id: UUID(), kind: .seat, speakerId: "s2", author: "席位2", body: "", subtitle: nil, status: .speaking
        )
        live.ingest(.append(second))
        live.ingest(.updateMessage(id: second.id, body: "被打断前的内容", status: .speaking, lagAllowance: 1))
        live.finish(completed: false)
        XCTAssertEqual(live.messages.last?.body, "被打断前的内容", "结束时必须先落下尚未刷新的流式内容")
        XCTAssertEqual(live.messages.last?.status, .failed)
    }

    func testCouncilConnectivityTesterShowsUnsupportedConfiguredModelFallback() async throws {
        let models = ["gpt-main", "gpt-host", "gpt-engineer"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let streamer = ScriptedCouncilStreamer([
            .success("OK"),
            .success("OK"),
            .success("OK")
        ])
        let tester = IOSCouncilModelConnectivityTester(streamer: streamer)

        let results = try await tester.test(
            settings: compactRoomSettings(defaultRounds: 1),
            dynamicSeatGeneration: false,
            providerSetting: provider,
            currentModelId: "gpt-main"
        )

        XCTAssertEqual(results.map(\.configuredModelId), ["gpt-host", "gpt-engineer", "gpt-risk"])
        XCTAssertEqual(results.map(\.effectiveModelId), ["gpt-host", "gpt-engineer", "gpt-main"])
        XCTAssertTrue(results.allSatisfy(\.isReachable))
        XCTAssertTrue(results.last?.detail.contains("实际回退") == true)
        XCTAssertEqual(streamer.receivedModels.map(\.modelId), ["gpt-engineer", "gpt-host", "gpt-main"])
    }

    func testCouncilConnectivityTimeoutCancelsTheBlockedProbe() async throws {
        let models = ["gpt-main"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let streamer = BlockingCouncilProbeStreamer()
        let tester = IOSCouncilModelConnectivityTester(
            streamer: streamer,
            timeoutNanoseconds: 10_000_000
        )

        let results = try await tester.test(
            settings: compactRoomSettings(defaultRounds: 1),
            dynamicSeatGeneration: true,
            providerSetting: provider,
            currentModelId: "gpt-main"
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isReachable)
        XCTAssertTrue(results[0].detail.contains("没有完成测试"))
        XCTAssertGreaterThan(streamer.cancelCount, 0)
    }

    func testRoomSettingsPersistHostLimitsAndSeatPayload() throws {
        let defaults = isolatedDefaults()
        let store = IOSCouncilRoomSettingsStore(
            userDefaults: defaults,
            storageKey: "settings",
            currentModelId: "gpt-main"
        )

        store.updateHost(modelId: "gpt-host", reasoning: .high, prompt: "主持 prompt")
        store.updateLimits(maxSeats: 6, defaultRounds: 3, seatTimeoutSeconds: 45, outputBudgetCharacters: 16_000)
        store.addOrUpdateSeat(
            IOSCouncilRoomSeatConfig(
                id: "design",
                name: "设计",
                rolePrompt: "看体验",
                modelId: "gpt-seat",
                reasoning: .low,
                prompt: "只说关键判断",
                isDefault: false
            ),
            currentModelId: "gpt-main"
        )

        let reloaded = IOSCouncilRoomSettingsStore(
            userDefaults: defaults,
            storageKey: "settings",
            currentModelId: "gpt-main"
        )
        XCTAssertEqual(reloaded.settings.host.modelId, "gpt-host")
        XCTAssertEqual(reloaded.settings.host.reasoning, .high)
        XCTAssertEqual(reloaded.settings.host.prompt, "主持 prompt")
        XCTAssertEqual(reloaded.settings.limits.maxSeats, 6)
        XCTAssertEqual(reloaded.settings.limits.defaultRounds, 3)
        XCTAssertEqual(reloaded.settings.limits.seatTimeoutSeconds, 45)
        XCTAssertEqual(reloaded.settings.limits.outputBudgetCharacters, 16_000)

        let seat = try XCTUnwrap(reloaded.settings.seats.first { $0.id == "design" })
        XCTAssertEqual(seat.name, "设计")
        XCTAssertEqual(seat.modelId, "gpt-seat")
        XCTAssertEqual(seat.reasoning, .low)
        XCTAssertEqual(seat.prompt, "只说关键判断")
        XCTAssertFalse(seat.isDefault)
    }

    func testPlannedSeatsFromJSONPrefersDistinctAvailableModels() {
        let planned = IOSCouncilRoomRunner.plannedSeatsFromJSON(
            """
            主持人输出：
            ```json
            {"seats":[{"name":"工程","lens":"看实现复杂度"},{"name":"风险","lens":"看安全和失败模式"}]}
            ```
            """,
            maxSeats: 4,
            routes: [
                IOSCouncilModelRouteDescriptor(providerId: "provider-a", modelId: "gpt-alt-a"),
                IOSCouncilModelRouteDescriptor(providerId: "provider-b", modelId: "gpt-alt-b"),
                IOSCouncilModelRouteDescriptor(providerId: "provider-main", modelId: "gpt-main")
            ]
        )
        XCTAssertEqual(planned.map(\.name), ["工程", "风险"])
        XCTAssertEqual(planned.map(\.rolePrompt), ["看实现复杂度", "看安全和失败模式"])
        XCTAssertEqual(planned.map(\.modelId), ["gpt-alt-a", "gpt-alt-b"])
        XCTAssertEqual(planned.map(\.providerId), ["provider-a", "provider-b"])
        XCTAssertFalse(planned.contains { $0.isHost })
    }

    func testPlannedSeatsFromJSONFallsBackToEmptyWhenInsufficientOrInvalid() {
        // 少于 2 个有效席位 → 空（调用方保留已 resolve 的默认席位）
        XCTAssertTrue(IOSCouncilRoomRunner.plannedSeatsFromJSON(
            #"{"seats":[{"name":"只有一个","lens":"数量非法"}]}"#,
            maxSeats: 4,
            routes: [IOSCouncilModelRouteDescriptor(providerId: "provider-main", modelId: "gpt-main")]
        ).isEmpty)
        // 非 JSON 散文 → 空
        XCTAssertTrue(IOSCouncilRoomRunner.plannedSeatsFromJSON(
            "主持人写了一堆散文，没有任何 JSON。",
            maxSeats: 4,
            routes: [IOSCouncilModelRouteDescriptor(providerId: "provider-main", modelId: "gpt-main")]
        ).isEmpty)
        // 超过上限按 maxSeats 截断
        let capped = IOSCouncilRoomRunner.plannedSeatsFromJSON(
            #"{"seats":[{"name":"A","lens":"a"},{"name":"B","lens":"b"},{"name":"C","lens":"c"}]}"#,
            maxSeats: 2,
            routes: [IOSCouncilModelRouteDescriptor(providerId: "provider-main", modelId: "gpt-main")]
        )
        XCTAssertEqual(capped.map(\.name), ["A", "B"])
    }

    // MARK: - 动态组席回退/重试/解析鲁棒性（辩论与自由群聊共用同一条组席路径）

    /// 主持人在真正 JSON 前用了带花括号的列举时，extractJSONObject 会先抓到干扰对象；
    /// 应跳过它，继续扫描到含 seats 的对象，而不是静默回退默认席位。
    func testPlannedSeatsFromJSONSkipsLeadingBraceNoiseToFindSeats() {
        let planned = IOSCouncilRoomRunner.plannedSeatsFromJSON(
            """
            先考虑 {历史, 政治} 两个维度，再给席位：
            {"seats":[{"name":"考据","lens":"核史料"},{"name":"社会","lens":"看民生"}]}
            """,
            maxSeats: 4,
            routes: [IOSCouncilModelRouteDescriptor(providerId: "provider-main", modelId: "gpt-main")]
        )
        XCTAssertEqual(planned.map(\.name), ["考据", "社会"])
    }

    /// 动态组席解析不出 ≥2 席时，必须发一条显式「回退默认」divider，不能静默——
    /// 否则用户看到「已组建…工程、产品、风险」会误以为动态组席成功。
    func testDynamicSeatPlanParseFailureSurfacesFallbackDivider() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let models = ["gpt-main", "gpt-alt", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        var scripts: [Result<String, Error>] = [
            .success("最终议题"),
            .success("主持人这次没给 JSON，只写了一段散文。"),
        ]
        scripts.append(contentsOf: Array(repeating: .success("OK"), count: 12))
        let streamer = ScriptedCouncilStreamer(scripts)
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable,
            providerSetting: provider,
            currentModel: models[0]
        )
        request.dynamicSeatGeneration = true
        var appendedBodies: [String] = []
        _ = await runner.run(request: request, onEvent: { event in
            if case .append(let message) = event { appendedBodies.append(message.body) }
        })

        let surfacedFallback = appendedBodies.contains { body in
            body.contains("动态组席") &&
                (body.contains("默认") || body.contains("沿用") ||
                 body.contains("失败") || body.contains("未成功"))
        }
        XCTAssertTrue(
            surfacedFallback,
            "动态组席解析失败时应发显式回退 divider，实际 append: \(appendedBodies)"
        )
    }

    /// 动态组席调用第一次失败时，应重试一次；重试成功则采用动态席位，而非回退默认。
    func testDynamicSeatPlanRetriesOnceAfterFailure() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let models = ["gpt-main", "gpt-alt", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        var scripts: [Result<String, Error>] = [
            .success("最终议题"),
            .failure(CouncilTestError.scriptedFailure),
            .success(#"{"seats":[{"name":"考据","lens":"核史料"},{"name":"社会","lens":"看民生"}]}"#),
        ]
        scripts.append(contentsOf: Array(repeating: .success("OK"), count: 12))
        let streamer = ScriptedCouncilStreamer(scripts)
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: StaticCouncilResearcher(),
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable,
            providerSetting: provider,
            currentModel: models[0]
        )
        request.dynamicSeatGeneration = true
        var rosters: [[IOSCouncilRoomSpeaker]] = []
        let outcome = await runner.run(request: request, onEvent: { event in
            if case .roster(let speakers, _, _) = event { rosters.append(speakers) }
        })

        XCTAssertEqual(outcome.status, .completed)
        let finalSeats = (rosters.last ?? []).filter { !$0.isHost }
        XCTAssertEqual(Set(finalSeats.map(\.name)), Set(["考据", "社会"]))
        // 组席被调用两次：议题之后连续两次 host（首次失败 + 重试）。
        XCTAssertEqual(
            streamer.receivedModels.prefix(3).map(\.modelId),
            ["gpt-main", "gpt-main", "gpt-main"]
        )
    }

    // MARK: - 席位输出伪联网搜索文本清洗（显示兜底）

    func testSanitizeSeatOutputStripsFencedPseudoWebSearchBlock() {
        let raw = """
        我先查一下资料。
        ```html
        web_search
        query 赵匡胤 开国功臣 名将 名臣 名单
        num_results 15
        web_search
        query 李世民 凌烟阁 二十四功臣 人才来源
        num_results 10
        ```
        综上，人才池其实不小。
        """
        let cleaned = IOSCouncilRoomRunner.sanitizeSeatOutput(raw)
        XCTAssertFalse(cleaned.contains("web_search"))
        XCTAssertFalse(cleaned.contains("num_results"))
        XCTAssertFalse(cleaned.contains("```"))
        XCTAssertTrue(cleaned.contains("我先查一下资料。"))
        XCTAssertTrue(cleaned.contains("综上，人才池其实不小。"))
    }

    func testSanitizeSeatOutputStripsBarePseudoWebSearchLines() {
        let raw = """
        让我搜索。
        web_search
        query 朱元璋 淮西集团 开国将相
        num_results 10
        所以结论是 X。
        """
        let cleaned = IOSCouncilRoomRunner.sanitizeSeatOutput(raw)
        XCTAssertFalse(cleaned.contains("web_search"))
        XCTAssertFalse(cleaned.contains("num_results"))
        XCTAssertTrue(cleaned.contains("让我搜索。"))
        XCTAssertTrue(cleaned.contains("所以结论是 X。"))
    }

    func testSanitizeSeatOutputKeepsNormalProseMentioningSearch() {
        let raw = "我认为这个问题不需要联网搜索，从制度成本看即可。"
        XCTAssertEqual(IOSCouncilRoomRunner.sanitizeSeatOutput(raw), raw)
    }

    /// 行首恰为 query 的英文正常发言，在没有 web_search 上下文时不得被误删——
    /// sanitize 无条件运行(与开关无关)，误删会丢用户付费生成的合法内容。
    func testSanitizeSeatOutputKeepsEnglishQueryLineWithoutPseudoSearchContext() {
        let raw = """
        Query the archive for precedents before deciding.
        The conclusion follows from the evidence.
        """
        XCTAssertEqual(IOSCouncilRoomRunner.sanitizeSeatOutput(raw), raw)
    }

    /// web_search 行被一句正常散文隔开后，其后的 query 行已脱离伪搜索块，应保留；
    /// 而 web_search 行本身仍删。验证「query 删除依赖前序 web_search 上下文」的复位逻辑。
    func testSanitizeSeatOutputKeepsQueryLineAfterContextReset() {
        let raw = """
        web_search
        This is a normal intervening line.
        query should be kept now.
        """
        let cleaned = IOSCouncilRoomRunner.sanitizeSeatOutput(raw)
        XCTAssertFalse(cleaned.contains("web_search"))
        XCTAssertTrue(cleaned.contains("This is a normal intervening line."))
        XCTAssertTrue(cleaned.contains("query should be kept now."))
    }

    // MARK: - 席位发言前联网查证（开关 + 尊重全局联网 consent）

    /// 开关开 + consent allowed：主持调研 1 次 + 每席 1 次（2 席）= 3 次；两席发言 prompt
    /// 均注入「本席联网查证」段且含调研标记。researcher 由 runner 注入，主持与席位共用同一实例。
    func testSeatWebSearchRunsPerSeatResearchAndInjectsSummary() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let models = ["gpt-main", "gpt-host", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let researcher = CountingCouncilResearcher()
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("风险发言"),
            .success("主持总结"),
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: researcher,
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .allowed,
            providerSetting: provider,
            currentModel: models[0]
        )
        request.dynamicSeatGeneration = false
        request.seatWebSearch = true

        let outcome = await runner.run(request: request, onEvent: { _ in })

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(researcher.callCount, 3)
        let seatResearchPrompts = streamer.receivedUserPrompts.filter {
            $0.contains("本席联网查证")
        }
        XCTAssertEqual(seatResearchPrompts.count, 2)
        XCTAssertTrue(seatResearchPrompts.allSatisfy { $0.contains("SEAT_RESEARCH_MARKER_42") })
    }

    /// 开关关：席位不调研、不注入；仅主持因 consent=allowed 调研 1 次。
    func testSeatWebSearchOffSkipsPerSeatResearch() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let models = ["gpt-main", "gpt-host", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let researcher = CountingCouncilResearcher()
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("风险发言"),
            .success("主持总结"),
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: researcher,
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .allowed,
            providerSetting: provider,
            currentModel: models[0]
        )
        request.dynamicSeatGeneration = false
        request.seatWebSearch = false

        let outcome = await runner.run(request: request, onEvent: { _ in })

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(researcher.callCount, 1)
        XCTAssertEqual(
            streamer.receivedUserPrompts.filter { $0.contains("本席联网查证") }.count,
            0
        )
    }

    /// 开关开但 consent=unavailable（全局联网关）：主持与席位都不调研、不注入——
    /// 席位联网尊重全局联网开关，与主持一致，避免在用户禁用联网时偷偷发请求。
    func testSeatWebSearchRespectsUnavailableConsent() async throws {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let models = ["gpt-main", "gpt-host", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let provider = makeCouncilProvider(models: models)
        let researcher = CountingCouncilResearcher()
        let streamer = ScriptedCouncilStreamer([
            .success("最终议题"),
            .success("工程发言"),
            .success("风险发言"),
            .success("主持总结"),
        ])
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: researcher,
            taskStore: taskStore
        )
        var request = roomRequest(
            settings: compactRoomSettings(defaultRounds: 1),
            researchConsent: .unavailable,
            providerSetting: provider,
            currentModel: models[0]
        )
        request.dynamicSeatGeneration = false
        request.seatWebSearch = true

        let outcome = await runner.run(request: request, onEvent: { _ in })

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(researcher.callCount, 0)
        XCTAssertEqual(
            streamer.receivedUserPrompts.filter { $0.contains("本席联网查证") }.count,
            0
        )
    }

    func testSearchResearcherStopsAfterCancellationInsteadOfContinuingQueries() async throws {
        let secondRequestStarted = expectation(description: "second search request started")
        let transport = CancellingCouncilSearchTransport(secondRequestStarted: secondRequestStarted)
        let researcher = IOSCouncilSearchResearcher(transport: transport)
        let researchTask = Task { @MainActor in
            await researcher.research(
                objective: "取消时停止后续搜索",
                settings: nil,
                maxSearches: 4,
                maxScrapes: 0
            )
        }

        await fulfillment(of: [secondRequestStarted], timeout: 1)
        researchTask.cancel()
        _ = await researchTask.value

        XCTAssertEqual(
            Set(transport.queries),
            ["取消时停止后续搜索"],
            "Cancellation must stop the serial query loop; parallel engines for the first query are expected."
        )
        XCTAssertGreaterThanOrEqual(transport.requestCount, 2)
        XCTAssertEqual(
            transport.cancelledRequestCount,
            transport.requestCount,
            "Every in-flight engine request must receive cancellation."
        )
    }

}
