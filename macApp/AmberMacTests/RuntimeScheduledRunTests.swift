import XCTest
@preconcurrency import GatewayCore
@preconcurrency import GatewayTransport
@testable import AmberMac

/// Headless scheduled runs through DesktopWorkspace with a scripted provider.
@MainActor final class RuntimeScheduledRunTests: XCTestCase {
    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        var contexts: [DesktopRunContext] = []
        var messages: [[DesktopMessage]] = []
        var configurations: [DesktopProviderConfiguration] = []
        var fail = false
        var onStart: ((DesktopGeneration, DesktopRunContext, UUID) -> Void)?
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            XCTFail("scheduled runs always pass a context"); return DesktopGeneration()
        }
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage],
            responseID: UUID, context: DesktopRunContext) throws -> DesktopGeneration {
            if fail { throw DesktopRuntimeError.message("provider down") }
            let run = DesktopGeneration()
            runs.append(run); contexts.append(context); self.messages.append(messages); configurations.append(configuration)
            onStart?(run, context, responseID)
            return run
        }
    }

    private func setup(_ conversations: [DesktopConversation] = []) throws
        -> (DesktopWorkspace, Provider, DesktopMemoryConversationStorage, DesktopAgentTasks) {
        let defaults = UserDefaults(suiteName: "amber.scheduled-run.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!
        config.modelID = "test-model"
        try settings.saveProvider(config, apiKey: "test-key")
        let provider = Provider()
        let storage = DesktopMemoryConversationStorage(conversations)
        let tasks = DesktopAgentTasks(defaults: defaults)
        // Global switches on: a scheduled run must ignore them.
        tasks.toolsEnabled = false
        tasks.autoApprove = true
        tasks.autoApproveHighRisk = true
        let workspace = DesktopWorkspace(settings: settings, storage: storage, provider: provider,
            initialConversations: conversations, agentTasks: tasks)
        return (workspace, provider, storage, tasks)
    }

    private func task(_ output: DesktopScheduleOutput = .newConversation) -> DesktopScheduledTask {
        var value = DesktopScheduledTask(name: "每日汇总", prompt: "汇总新文件", schedule: .daily(hour: 9, minute: 0))
        value.output = output
        value.approval.allowedTools = ["workspace_file_list"]
        return value
    }

    private func waitForRun(_ provider: Provider, count: Int = 1) async {
        let deadline = Date().addingTimeInterval(2)
        while provider.runs.count < count, deadline.timeIntervalSince(Date()) > 0 { await Task.yield() }
    }

    func testNewConversationRunUsesTaskPolicyAndLeavesComposerAlone() async throws {
        let existing = DesktopConversation(title: "我的对话")
        let (workspace, provider, storage, _) = try setup([existing])
        workspace.draft = "未发送的草稿"
        let scheduled = task()
        let running = Task { await workspace.runScheduled(scheduled, scheduledFor: Date(timeIntervalSince1970: 1)) }
        await waitForRun(provider)
        let run = try XCTUnwrap(provider.runs.first)
        let context = try XCTUnwrap(provider.contexts.first)
        XCTAssertEqual(context.approvalPolicy, DesktopApprovalPolicy(autoApproveOrdinary: false, autoApproveHighRisk: false,
            allowedTools: ["workspace_file_list"], deniesOutsideAllowList: true))
        XCTAssertTrue(context.toolsEnabled, "task's own tool switch, not the global one")
        XCTAssertTrue(workspace.scheduledRunConversationIDs.contains(context.conversationID))
        XCTAssertFalse(workspace.isGenerating, "the composer's generation slot stays free")
        XCTAssertEqual(provider.messages[0].last?.text, "汇总新文件")

        run.yield(.snapshot(text: "汇总完成", reasoning: ""))
        run.yield(.complete)
        let record = await running.value
        _ = await workspace.flush()

        XCTAssertEqual(record.status, .completed, record.error ?? "")
        XCTAssertEqual(record.scheduledFor, Date(timeIntervalSince1970: 1))
        XCTAssertNotNil(record.finishedAt)
        XCTAssertEqual(record.conversationID, context.conversationID)
        XCTAssertEqual(workspace.selectedID, existing.id)
        XCTAssertEqual(workspace.draft, "未发送的草稿")
        XCTAssertTrue(workspace.scheduledRunConversationIDs.isEmpty)
        let saved = try XCTUnwrap(storage.values.first { $0.id == context.conversationID })
        XCTAssertTrue(saved.title.hasPrefix("⏱ 每日汇总 · "), saved.title)
        XCTAssertEqual(saved.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(saved.messages.last?.text, "汇总完成")
        XCTAssertEqual(saved.messages.last?.state, .complete)
    }

    func testAppendRunWritesAfterExistingHistoryAndBlocksComposerMeanwhile() async throws {
        let target = DesktopConversation(title: "日报", messages: [
            DesktopMessage(role: .user, text: "昨天"), DesktopMessage(role: .assistant, text: "昨天的汇总")])
        let (workspace, provider, storage, _) = try setup([target])
        let running = Task { await workspace.runScheduled(self.task(.appendTo(target.id))) }
        await waitForRun(provider)
        workspace.draft = "插话"
        workspace.send()
        XCTAssertEqual(workspace.draft, "插话", "the composer cannot write into a conversation a scheduled run owns")
        XCTAssertNotNil(workspace.errorMessage)

        let toolTurn = DesktopMessage(role: .assistant, text: "列目录")
        let final = DesktopMessage(role: .assistant, text: "今天的汇总")
        provider.runs[0].yield(.transcript([toolTurn, final]))
        provider.runs[0].yield(.complete)
        let record = await running.value
        _ = await workspace.flush()

        XCTAssertEqual(record.status, .completed)
        let saved = try XCTUnwrap(storage.values.first { $0.id == target.id })
        XCTAssertEqual(saved.messages.map(\.text), ["昨天", "昨天的汇总", "汇总新文件", "列目录", "今天的汇总"])
        XCTAssertEqual(saved.messages.last?.state, .complete)
        XCTAssertEqual(saved.title, "日报")
    }

    func testProviderFailureAndDeletedTargetBecomeFailedRecords() async throws {
        let (workspace, provider, _, _) = try setup()
        provider.fail = true
        let failed = await workspace.runScheduled(task())
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("provider down") == true, failed.error ?? "")
        XCTAssertTrue(workspace.scheduledRunConversationIDs.isEmpty)

        let missing = await workspace.runScheduled(task(.appendTo(UUID())))
        XCTAssertEqual(missing.status, .failed)
        XCTAssertNil(missing.conversationID)

        provider.fail = false
        let running = Task { await workspace.runScheduled(self.task()) }
        await waitForRun(provider)
        provider.runs[0].yield(.failed("模型报错"))
        let record = await running.value
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.error, "模型报错")
    }

    func testCancelScheduledRunsStopsTheRun() async throws {
        let (workspace, provider, storage, _) = try setup()
        let running = Task { await workspace.runScheduled(self.task()) }
        await waitForRun(provider)
        workspace.cancelScheduledRuns()
        let record = await running.value
        _ = await workspace.flush()
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.error, "运行已取消。")
        XCTAssertEqual(storage.values.first?.messages.last?.state, .cancelled)
    }

    func testUnansweredApprovalPastTimeoutFailsTheRun() async throws {
        let (workspace, provider, _, tasks) = try setup()
        await tasks.waitUntilLoaded()
        var now = Date()
        // Stand in for the agent engine: open a run, ask for approval, then wait like DesktopAgentProvider does.
        provider.onStart = { run, context, _ in
            Task { @MainActor in
                let id = try await tasks.begin(conversationID: context.conversationID, title: "写文件", cancel: { run.cancel() })
                try await tasks.requestApproval(runID: id, approval: DesktopToolApproval(id: "call-1",
                    name: "workspace_file_write", arguments: "{}", reason: "写入"))
                let allowed = await tasks.awaitDecision(runID: id, toolID: "call-1")
                XCTAssertFalse(allowed)
                await tasks.finish(id, status: .cancelled)
            }
        }
        var scheduled = task()
        scheduled.approval.approvalTimeoutHours = 1
        let running = Task { await workspace.runScheduled(scheduled, clock: { now }, approvalPollInterval: .milliseconds(10)) }
        await waitForRun(provider)
        let deadline = Date().addingTimeInterval(2)
        while !tasks.records.contains(where: { $0.status == .waiting }), deadline.timeIntervalSince(Date()) > 0 { await Task.yield() }
        XCTAssertTrue(tasks.records.contains { $0.status == .waiting })
        // Still inside the window: nothing happens.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(tasks.records.contains { $0.status == .waiting })
        now = now.addingTimeInterval(3601)
        let record = await running.value
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.error?.contains("审批等待超过 1 小时") == true, record.error ?? "")
        XCTAssertNotNil(record.agentRunID)
    }

    func testPinnedModelIsUsedAndMissingModelFails() async throws {
        let (workspace, provider, _, _) = try setup()
        var scheduled = task()
        scheduled.modelID = UUID()
        let missing = await workspace.runScheduled(scheduled)
        XCTAssertEqual(missing.status, .failed)
        XCTAssertTrue(missing.error?.contains("模型已删除或停用") == true)
        XCTAssertTrue(provider.runs.isEmpty)
        XCTAssertTrue(workspace.summaries.isEmpty, "a run that never started leaves no empty conversation behind")

        let model = try XCTUnwrap(workspace.settings.selectedProvider?.selectedModel)
        scheduled.modelID = model.id
        let running = Task { await workspace.runScheduled(scheduled) }
        await waitForRun(provider)
        XCTAssertEqual(provider.configurations.first?.selectedModel?.id, model.id)
        provider.runs[0].yield(.complete)
        _ = await running.value
    }

    func testTaskPolicyDeniesOutsideAllowListOnlyForUnattendedRuns() {
        let policy = DesktopUnattendedApproval(autoApproveOrdinary: true, allowedTools: ["workspace_file_list"]).policy
        XCTAssertTrue(policy.denies("workspace_file_write"))
        XCTAssertFalse(policy.denies("workspace_file_list"))
        XCTAssertFalse(DesktopUnattendedApproval().policy.denies("terminal_exec"), "no allow-list = nothing refused outright")
        let conversational = DesktopApprovalPolicy(autoApproveOrdinary: true, autoApproveHighRisk: false, allowedTools: ["a"])
        XCTAssertFalse(conversational.denies("b"), "a conversation still asks instead of refusing")
        let tasks = DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.scheduled-policy.\(UUID().uuidString)")!)
        tasks.autoApprove = true
        tasks.autoApproveHighRisk = true
        XCTAssertFalse(tasks.autoApproves("workspace_file_write", policy: DesktopUnattendedApproval().policy))
        XCTAssertFalse(tasks.autoApproves("terminal_exec", policy: DesktopUnattendedApproval(autoApproveOrdinary: true).policy))
    }

    private final class SummaryProvider: DesktopTextProvider {
        var generations: [DesktopGeneration] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let gen = DesktopGeneration()
            generations.append(gen)
            return gen
        }
    }

    func testPostRunSummaryReleasesConversationWithoutClobberingSubsequentRun() async throws {
        let target = DesktopConversation(title: "日报", messages: [DesktopMessage(role: .user, text: "昨天")])
        let (workspace, provider, _, tasks) = try setup([target])
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("asr-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let paths = GatewayPaths(stateDir: dir)
        let reporter = DesktopGatewayReporter(paths: paths, isEnabled: { true }, process: nil)
        let summaryProvider = SummaryProvider()
        let boardWriter = DesktopBoardWriter(
            provider: summaryProvider,
            paths: paths,
            available: { true },
            request: { workspace.boardWriterRequest() }
        )
        workspace.gatewayReporter = reporter
        workspace.boardWriter = boardWriter

        var firstTask = task(.appendTo(target.id))
        firstTask.name = "早报"
        var secondTask = task(.appendTo(target.id))
        secondTask.name = "午报"

        let run1Task = Task { await workspace.runScheduled(firstTask) }
        await waitForRun(provider, count: 1)
        let run1SessionKey = try XCTUnwrap(reporter.sessionKey(forConversation: target.id))
        XCTAssertEqual(tasks.unattendedConversations[target.id], "早报")

        provider.runs[0].yield(.snapshot(text: "早报一切正常", reasoning: ""))
        provider.runs[0].yield(.complete)

        let summaryDeadline = Date().addingTimeInterval(2)
        while summaryProvider.generations.count < 1, summaryDeadline.timeIntervalSince(Date()) > 0 {
            await Task.yield()
        }
        XCTAssertEqual(summaryProvider.generations.count, 1)

        // While Run 1 is suspended inside boardWriter.summarize, conversation ownership is completely released:
        XCTAssertFalse(workspace.scheduledRunConversationIDs.contains(target.id))
        XCTAssertNil(tasks.unattendedConversations[target.id])
        XCTAssertNil(reporter.sessionKey(forConversation: target.id))

        // Run 2 starts on the same conversation while Run 1's summary is still in flight:
        let run2Task = Task { await workspace.runScheduled(secondTask) }
        await waitForRun(provider, count: 2)
        let run2SessionKey = try XCTUnwrap(reporter.sessionKey(forConversation: target.id))
        XCTAssertNotEqual(run1SessionKey, run2SessionKey)
        XCTAssertTrue(workspace.scheduledRunConversationIDs.contains(target.id))
        XCTAssertEqual(tasks.unattendedConversations[target.id], "午报")

        // Finish Run 1's summary (quiet): must NOT clobber Run 2's active conversation ownership or gateway session!
        summaryProvider.generations[0].yield(.snapshot(text: #"{"summary":"早报无异常","noteworthy":false}"#, reasoning: ""))
        summaryProvider.generations[0].yield(.complete)
        let record1 = await run1Task.value
        XCTAssertEqual(record1.status, .completed)
        XCTAssertEqual(record1.summary, "早报无异常")
        XCTAssertEqual(record1.noteworthy, false)

        XCTAssertTrue(workspace.scheduledRunConversationIDs.contains(target.id))
        XCTAssertEqual(tasks.unattendedConversations[target.id], "午报")
        XCTAssertEqual(reporter.sessionKey(forConversation: target.id), run2SessionKey)

        // Finish Run 2 cleanly as well:
        provider.runs[1].yield(.snapshot(text: "午报有新告警", reasoning: ""))
        provider.runs[1].yield(.complete)
        while summaryProvider.generations.count < 2, Date().timeIntervalSinceNow < 2 {
            await Task.yield()
        }
        summaryProvider.generations[1].yield(.snapshot(text: #"{"summary":"发现新告警","noteworthy":true}"#, reasoning: ""))
        summaryProvider.generations[1].yield(.complete)
        let record2 = await run2Task.value
        XCTAssertEqual(record2.status, .completed)

        // Verify both runExit events were delivered to Spool with Run 1 marked quiet == true:
        let drainDeadline = Date().addingTimeInterval(2)
        var runExits: [GatewayEvent] = []
        while runExits.count < 2, drainDeadline.timeIntervalSince(Date()) > 0 {
            Spool(dir: paths.spoolDir).drain { event in
                if event.kind == .runExit { runExits.append(event) }
            }
            if runExits.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        }
        let exit1 = try XCTUnwrap(runExits.first { "amber:" + $0.sessionId == run1SessionKey })
        let exit2 = try XCTUnwrap(runExits.first { "amber:" + $0.sessionId == run2SessionKey })
        XCTAssertEqual(exit1.quiet, true)
        XCTAssertNotEqual(exit2.quiet, true)
    }
}
