import XCTest
import SwiftUI
import QuartzCore
@preconcurrency import Shared
@testable import iosApp

/// P6 测量夹具（只测量，不做优化）：把父会话 UI（`NativeChatTimelineView` +
/// `ChatSubAgentActivityBar`，二者都挂着真实的 `IOSSubAgentActivityStore` /
/// `IOSAdvancedTaskStore` 观察链路）挂进带 windowScene 的 UIWindow，并发驱动
/// N 个走生产入口 `SubAgentRunner.runViaEngine` 的子代理 run。每个 run 用
/// `IOSChatScriptedStreamingProvider`（已在 `IOSChatForegroundTestHarness.swift`
/// 中定义，复用而非重造）每 50ms 推一个 delta，持续约 3 秒后完成一轮，不触网、
/// 不调用任何父工具。`DisplayLinkGapProbe` 复刻自
/// `ChatSwiftUIStreamReplayTests`（原类型是文件私有，无法跨文件复用，这里按同一
/// 实现复制一份，不引入新协调层）。
///
/// P6 第二轮：夹具定型为回归测试。每个用例先跑一次预热（丢弃，消除冷启动），
/// 再跑一次真正测量并对 p95 断言（阈值留足余量，模拟器噪声大；max 只打印不断言）。
/// 新增覆盖：N=8；~8KB 中英混排+代码块输出且多个子代理在同一时刻附近收尾
/// （`runConcurrencyLargeOutput`）；真实隔离 Room 库（临时文件路径，非生产库）驱动
/// 的 durable run 链路——`AgentRuntimeDao.listAllRuns` 数百条历史行 + 真实
/// `ConversationActivityCenter`（`recomputeNotices`）与 `IOSSubAgentActivityStore`
/// 的 `loadRuns` 注入点都吃同一份数据，测量窗口内两次 `.amberSubAgentRunsDidChange`
/// 模拟并发到达的后台完成通知（`runConcurrencyDurable`）。
///
/// 已知未覆盖 / 简化：`SubAgentRunner` 本身不写 `IOSDurableRunStore`（子代理执行
/// 只经过 `IOSAdvancedTaskStore`），生产的 `IOSSubAgentActivityStore.loadDurableActivities`
/// 还会 join `threadEdgeDao().allEdges` 做父子会话映射——这里为保持隔离性和用例
/// 体量，注入的 `loadRuns` 闭包跳过了这个 join，只复刻 `listAllRuns` 读取 + 逐行
/// 映射（复用生产的 `durableStatus`），这是压测「全表数百条」读取/映射成本的最小近似，
/// 不是端到端复刻。
@MainActor
final class SubAgentConcurrencyPerfTests: XCTestCase {

    // MARK: - DisplayLink 帧间隔探针（复刻 ChatSwiftUIStreamReplayTests.DisplayLinkGapProbe）

    private final class DisplayLinkGapProbe: NSObject {
        private var displayLink: CADisplayLink?
        private var previousTimestamp: CFTimeInterval?
        private(set) var gaps: [TimeInterval] = []

        func start() {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ displayLink: CADisplayLink) {
            defer { previousTimestamp = displayLink.timestamp }
            guard let previousTimestamp else { return }
            gaps.append(displayLink.timestamp - previousTimestamp)
        }
    }

    // MARK: - 父会话 Harness（复刻 ChatSwiftUIStreamReplayTests.Harness 的最小子集）

    private final class HarnessModel: ObservableObject {
        @Published var signal = ChatMessageUpdateSignal(revision: 0, reason: .initialLoad)
        var messages: [UIMessage] = []
        var currentConversationID: String?
    }

    private struct Harness: View {
        @ObservedObject var model: HarnessModel
        let displaySetting: DisplaySetting
        let generativeUiSetting: GenerativeUiSetting
        let workspaceStore: IOSWorkspaceStore
        let activityStore: IOSSubAgentActivityStore

        var body: some View {
            ZStack(alignment: .bottom) {
                NativeChatTimelineView(
                    signal: model.signal,
                    configurationIssue: nil,
                    isGenerationActive: false,
                    isLoading: false,
                    isRecognizingImages: false,
                    contextCompactState: .idle,
                    followGeneration: true,
                    displaySetting: displaySetting,
                    generativeUiSetting: generativeUiSetting,
                    reasoningLevelLabel: nil,
                    workspaceStore: workspaceStore,
                    scrollToBottomTrigger: 0,
                    scrollToBottomSource: .button,
                    messageAnchor: nil,
                    currentConversationID: model.currentConversationID,
                    messagesProvider: { [weak model] in model?.messages ?? [] },
                    variantInfoProvider: { _ in nil },
                    onAction: { _ in },
                    onViewportStateChange: { _ in },
                    onDismissKeyboard: {}
                )
                ChatSubAgentActivityBar(
                    currentConversationId: model.currentConversationID,
                    isInputFocused: false,
                    activityStore: activityStore,
                    initiallyExpanded: true,
                    onOpenSource: { _ in false }
                )
            }
        }
    }

    private struct Fixture {
        let window: UIWindow
        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func makeFixture(
        model: HarnessModel,
        activityStore: IOSSubAgentActivityStore
    ) -> Fixture {
        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "SubAgentConcurrencyPerf-\(UUID().uuidString)")!
        )
        let workspaceStore = IOSWorkspaceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SubAgentConcurrencyPerf-\(UUID().uuidString)", isDirectory: true)
        )
        let host = UIHostingController(rootView: Harness(
            model: model,
            displaySetting: sharedSettings.displaySetting,
            generativeUiSetting: sharedSettings.snapshot.agentRuntime.generativeUi,
            workspaceStore: workspaceStore,
            activityStore: activityStore
        ))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return Fixture(window: window)
    }

    // MARK: - 消息种子（父会话已有一些历史，避免空列表场景失真）

    private func makeMessage(role: MessageRole, text: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 9, day: 29, hour: 0, minute: 0, second: 0, nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private func seedConversation() -> [UIMessage] {
        var out: [UIMessage] = []
        for index in 0..<6 {
            out.append(makeMessage(role: .user, text: "父会话消息 \(index)：请并发调度多个子代理完成核查任务。"))
            out.append(makeMessage(role: .assistant, text: "已收到，这是第 \(index) 轮的简要回复，正文长度适中用于铺垫真实列表高度。"))
        }
        return out
    }

    // MARK: - 泵送

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - 子代理驱动（生产入口 SubAgentRunner.runViaEngine + 既有 scripted streaming provider）

    private func makeProviderSetting() -> ProviderSetting.OpenAI {
        IOSChatForegroundFixtures.makeProviderSetting()
    }

    /// 每 50ms 一个 delta、约 3 秒、单轮完成（不调用任何工具）的流式 provider。
    private func makeStreamingProvider(totalText: String, chunkCount: Int, intervalMs: UInt64) -> IOSChatScriptedStreamingProvider {
        let deltas = iosChatScriptedTextDeltas(totalText, chunkCount: chunkCount)
        var cumulative = ""
        let chunks: [MessageChunk] = deltas.map { delta in
            cumulative += delta
            let deltaMessage = UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [UIMessagePart.Text(text: cumulative, metadata: nil)],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(year: 2026, month: 9, day: 29, hour: 0, minute: 0, second: 0, nanosecond: 0),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
            return IOSChatForegroundFixtures.streamChunk(delta: deltaMessage, finishReason: "stop")
        }
        return IOSChatScriptedStreamingProvider(streams: [
            .init(chunks: chunks, intervalNanos: intervalMs * 1_000_000)
        ])
    }

    /// 并发驱动 N 个子代理 run，同时用 DisplayLinkGapProbe 采样父会话 UI 的帧间隔。
    /// 返回 (samples, p95ms, maxMs, over50msCount)。
    private func runConcurrency(_ n: Int) async throws -> (Int, Double, Double, Int) {
        let suite = "SubAgentConcurrencyPerf-tasks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let activityStore = IOSSubAgentActivityStore(
            tasks: taskStore, defaults: defaults, launchedAt: Date(), loadRuns: { [] }
        )
        activityStore.autoDismissDelay = .never
        activityStore.start()

        let model = HarnessModel()
        model.messages = seedConversation()
        model.currentConversationID = "PARENT-CONVERSATION"
        let fixture = makeFixture(model: model, activityStore: activityStore)
        defer { fixture.tearDown() }

        pump(seconds: 0.3) // 初始布局落定

        let probe = DisplayLinkGapProbe()
        probe.start()

        let providerSetting = makeProviderSetting()
        let runner = SubAgentRunner(taskStore: taskStore)
        let longText = String(repeating: "子代理持续输出的正文内容，用于模拟真实流式 token 到达。", count: 40)
        var tasks: [Task<String, Never>] = []
        for index in 0..<n {
            let provider = makeStreamingProvider(totalText: longText, chunkCount: 60, intervalMs: 50)
            let task = Task { [runner] in
                await runner.runViaEngine(
                    objective: "并发压测子代理 #\(index)：核查接口并汇报。",
                    roleId: "fixer",
                    providerSetting: providerSetting,
                    modelId: "test-model",
                    parentToolExecutors: [:],
                    sourceConversationId: model.currentConversationID,
                    provider: provider
                )
            }
            tasks.append(task)
        }

        pump(seconds: 3.6) // 覆盖单个 run 的 ~3s 流式窗口 + 收尾

        for task in tasks { _ = await task.value }
        pump(seconds: 0.3) // 终态收尾（activity store 的异步 refresh）

        probe.stop()

        let ms = probe.gaps.dropFirst(2).map { $0 * 1_000 }.sorted()
        guard !ms.isEmpty else { return (0, 0, 0, 0) }
        let p95Index = min(ms.count - 1, Int((Double(ms.count) * 0.95).rounded(.up)) - 1)
        let p95 = ms[max(0, p95Index)]
        let max = ms.last ?? 0
        let over50 = ms.filter { $0 > 50 }.count
        return (ms.count, p95, max, over50)
    }

    // MARK: - 约 8KB 中英混排 + 代码块正文（模拟真实子代理长输出收尾）

    /// 循环拼接一个中英混排 + Swift 代码块的单元，直到 UTF-8 字节数达到
    /// `targetBytes`。用于压测长输出在流式 delta 累积、markdown 渲染、最终
    /// `resultSummary`/`public_output` 编码路径上的成本。
    private func makeMixedLanguageOutput(targetBytes: Int) -> String {
        let unit = """
        子代理正在核查目标接口的响应字段，并将关键结论整理成结构化说明，便于后续复核与归档。这一段刻意加入更多中文token，逼近真实汇报文本的长度分布。
        The sub-agent cross-checks response fields against the contract and records any deviation for follow-up review, mixing English sentences with the Chinese ones above.
        ```swift
        func verify(_ response: Response) -> Bool {
            guard response.statusCode == 200 else { return false }
            return response.body.contains("ok")
        }
        ```
        以上代码片段展示了本轮核查用到的最小校验逻辑，实际执行时还会附带更多上下文、重试策略与错误码映射表。


        """
        var result = ""
        while result.utf8.count < targetBytes {
            result += unit
        }
        return result
    }

    /// 与 `runConcurrency(_:)` 同构，仅把正文替换成可配置长度的中英混排 + 代码块
    /// 文本，覆盖“每个子代理输出约 8KB，且多个子代理在同一时刻附近收尾”。
    private func runConcurrencyLargeOutput(_ n: Int, outputBytes: Int) async throws -> (Int, Double, Double, Int) {
        let suite = "SubAgentConcurrencyPerf-tasks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let activityStore = IOSSubAgentActivityStore(
            tasks: taskStore, defaults: defaults, launchedAt: Date(), loadRuns: { [] }
        )
        activityStore.autoDismissDelay = .never
        activityStore.start()

        let model = HarnessModel()
        model.messages = seedConversation()
        model.currentConversationID = "PARENT-CONVERSATION"
        let fixture = makeFixture(model: model, activityStore: activityStore)
        defer { fixture.tearDown() }

        pump(seconds: 0.3)

        let probe = DisplayLinkGapProbe()
        probe.start()

        let providerSetting = makeProviderSetting()
        let runner = SubAgentRunner(taskStore: taskStore)
        let longText = makeMixedLanguageOutput(targetBytes: outputBytes)
        var tasks: [Task<String, Never>] = []
        for index in 0..<n {
            let provider = makeStreamingProvider(totalText: longText, chunkCount: 60, intervalMs: 50)
            let task = Task { [runner] in
                await runner.runViaEngine(
                    objective: "并发压测子代理 #\(index)：核查接口并汇报。",
                    roleId: "fixer",
                    providerSetting: providerSetting,
                    modelId: "test-model",
                    parentToolExecutors: [:],
                    sourceConversationId: model.currentConversationID,
                    provider: provider
                )
            }
            tasks.append(task)
        }

        pump(seconds: 3.6)

        for task in tasks { _ = await task.value }
        pump(seconds: 0.3)

        probe.stop()

        let ms = probe.gaps.dropFirst(2).map { $0 * 1_000 }.sorted()
        guard !ms.isEmpty else { return (0, 0, 0, 0) }
        let p95Index = min(ms.count - 1, Int((Double(ms.count) * 0.95).rounded(.up)) - 1)
        let p95 = ms[max(0, p95Index)]
        let max = ms.last ?? 0
        let over50 = ms.filter { $0 > 50 }.count
        return (ms.count, p95, max, over50)
    }

    // MARK: - 真实隔离 Room 库驱动的 durable run 链路

    /// 直接写 `agent_run` 表（不经 `IOSDurableRunStore`，不产生通知），模拟
    /// “全表数百条历史 run”对 `listAllRuns` 的读取/映射成本。少量行使用真实
    /// 会话 id（喂给 `ConversationActivityCenter` 做 preview 查找），其余用随机
    /// id（只走读取 + 过滤，不命中 preview 分支）。
    private func seedHistoricalRuns(
        dao: AgentRuntimeDao, count: Int, matchedConversationIds: [String]
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        for index in 0..<count {
            let conversationId = index < matchedConversationIds.count
                ? matchedConversationIds[index]
                : UUID().uuidString
            let status = ["completed", "failed", "running"][index % 3]
            let startedAt = now - Int64(index * 60_000)
            let run = AgentRunEntity(
                runId: "seed-run-\(index)-\(UUID().uuidString)",
                parentRunId: nil,
                agentDescriptorId: "chat",
                agentVersion: "1",
                conversationId: conversationId,
                messageNodeId: nil,
                producesMessageId: nil,
                assistantId: nil,
                status: status,
                inputDigest: "seed-digest-\(index)",
                inputSnapshotRef: nil,
                inputSchemaVersion: 1,
                startedAt: startedAt,
                finishedAt: status == "running" ? nil : KotlinLong(value: startedAt + 5_000),
                interruptedReason: nil,
                terminalReason: status == "failed" ? "error" : nil,
                providerId: nil,
                modelId: nil,
                promptVersion: nil,
                toolCatalogVersion: nil,
                capabilitySnapshot: nil
            )
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                dao.insertRunIfAbsent(run: run) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }

    /// `IOSSubAgentActivityStore.loadRuns` 注入点：复刻生产 `loadDurableActivities`
    /// 的 `listAllRuns` 读取 + 逐行映射（复用生产 `durableStatus`），但跳过
    /// `threadEdgeDao().allEdges` 的父子会话 join——独立 Room 库没有那张表的数据，
    /// 且本轮压测目标是「数百条历史行」本身的读取/映射成本，不是 join 语义。
    private func makeDurableLoadRuns(dao: AgentRuntimeDao) -> (@MainActor () async throws -> [IOSSubAgentActivity]) {
        { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[IOSSubAgentActivity], Error>) in
                dao.listAllRuns { values, error in
                    if let error { continuation.resume(throwing: error); return }
                    let activities: [IOSSubAgentActivity] = (values ?? []).compactMap { run in
                        guard IOSDurableRunStore.Descriptor.chatRecoveryAliases.contains(run.agentDescriptorId),
                              let conversationId = run.conversationId else { return nil }
                        let state = IOSSubAgentActivityStore.durableStatus(
                            run.status, reason: run.terminalReason ?? run.interruptedReason
                        )
                        return IOSSubAgentActivity(
                            id: "run:\(run.runId)", taskId: "thread:\(conversationId.lowercased())",
                            title: "历史子代理", avatarIdentity: "dynamic:历史子代理",
                            sourceConversationId: conversationId, status: state.0,
                            startedAt: Date(timeIntervalSince1970: Double(run.startedAt) / 1_000),
                            endedAt: run.finishedAt.map { Date(timeIntervalSince1970: Double($0.int64Value) / 1_000) },
                            statusDetail: state.1
                        )
                    }
                    continuation.resume(returning: activities)
                }
            }
        }
    }

    /// 最重组合：N 个子代理 + 可配置长度正文 + 真实隔离 Room 库（`historicalRunCount`
    /// 条历史 run）+ 真实 `ConversationActivityCenter`（同一份 dao，`start()` 后订阅
    /// `.amberSubAgentRunsDidChange`）。测量窗口内两次发通知，模拟并发到达的后台
    /// durable 完成事件与子代理流式收尾叠加。
    private func runConcurrencyDurable(
        _ n: Int, outputBytes: Int, historicalRunCount: Int
    ) async throws -> (Int, Double, Double, Int) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubAgentConcurrencyPerf-durable-\(UUID().uuidString).db").path
        let db = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath)
        let dao = db.agentRuntimeDao()

        let conversationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubAgentConcurrencyPerf-conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: conversationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: conversationDirectory) }
        let conversationStore = IOSConversationStore(baseDirectory: conversationDirectory)
        await conversationStore.bootstrap()

        var matchedConversationIds: [String] = []
        for index in 0..<3 {
            guard let id = conversationStore.currentConversation?.id else { break }
            _ = await conversationStore.save(
                messages: [IOSChatForegroundFixtures.assistantText("历史子代理输出 \(index)：核查完成，详情见附录。")],
                to: id
            )
            matchedConversationIds.append(id.toHexDashString())
            _ = await conversationStore.newConversation()
        }

        try await seedHistoricalRuns(dao: dao, count: historicalRunCount, matchedConversationIds: matchedConversationIds)

        let center = ConversationActivityCenter(conversationStore: conversationStore, dao: dao, startedAt: .distantPast)
        center.start()

        let suite = "SubAgentConcurrencyPerf-tasks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let activityStore = IOSSubAgentActivityStore(
            tasks: taskStore, defaults: defaults, launchedAt: Date(),
            loadRuns: makeDurableLoadRuns(dao: dao)
        )
        activityStore.autoDismissDelay = .never
        activityStore.start()

        let model = HarnessModel()
        model.messages = seedConversation()
        model.currentConversationID = "PARENT-CONVERSATION"
        let fixture = makeFixture(model: model, activityStore: activityStore)
        defer { fixture.tearDown() }

        pump(seconds: 0.3)

        let probe = DisplayLinkGapProbe()
        probe.start()

        let providerSetting = makeProviderSetting()
        let runner = SubAgentRunner(taskStore: taskStore)
        let longText = makeMixedLanguageOutput(targetBytes: outputBytes)
        var tasks: [Task<String, Never>] = []
        for index in 0..<n {
            let provider = makeStreamingProvider(totalText: longText, chunkCount: 60, intervalMs: 50)
            let task = Task { [runner] in
                await runner.runViaEngine(
                    objective: "并发压测子代理 #\(index)：核查接口并汇报。",
                    roleId: "fixer",
                    providerSetting: providerSetting,
                    modelId: "test-model",
                    parentToolExecutors: [:],
                    sourceConversationId: model.currentConversationID,
                    provider: provider
                )
            }
            tasks.append(task)
        }

        NotificationCenter.default.post(name: .amberSubAgentRunsDidChange, object: nil)
        pump(seconds: 1.5)
        NotificationCenter.default.post(name: .amberSubAgentRunsDidChange, object: nil)
        pump(seconds: 2.1)

        for task in tasks { _ = await task.value }
        NotificationCenter.default.post(name: .amberSubAgentRunsDidChange, object: nil)
        pump(seconds: 0.3)

        probe.stop()

        let ms = probe.gaps.dropFirst(2).map { $0 * 1_000 }.sorted()
        guard !ms.isEmpty else { return (0, 0, 0, 0) }
        let p95Index = min(ms.count - 1, Int((Double(ms.count) * 0.95).rounded(.up)) - 1)
        let p95 = ms[max(0, p95Index)]
        let max = ms.last ?? 0
        let over50 = ms.filter { $0 > 50 }.count
        return (ms.count, p95, max, over50)
    }

    // MARK: - 回归测试（预热一次丢弃，再测量并对 p95 断言；max 只打印不断言，模拟器噪声大）

    /// 稳定阈值来自实测：纯流式、无工具调用场景下 p95 恒为一帧（约 16.67ms）。
    /// 34ms（约两帧）留足模拟器噪声余量。
    private let framePacingP95ThresholdMs: Double = 34

    /// N 扫描只在手动测量时跑（各约 30s）；常规回归只保留最重组合 `testMeasureConcurrency8LargeOutputDurable300`。
    private func skipUnlessPerfSample() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["AMBER_PERF_SAMPLE"] == nil, "仅在手动性能测量时运行")
    }

    func testMeasureConcurrency1() async throws {
        try skipUnlessPerfSample()
        _ = try await runConcurrency(1) // 预热：消除冷启动，结果丢弃
        let (samples, p95, max, over50) = try await runConcurrency(1)
        print(String(format: "[PERF-SUBAGENT-N1] samples=%d p95=%.2fms max=%.2fms over50ms=%d", samples, p95, max, over50))
        XCTAssertLessThanOrEqual(p95, framePacingP95ThresholdMs)
    }

    func testMeasureConcurrency2() async throws {
        try skipUnlessPerfSample()
        _ = try await runConcurrency(2)
        let (samples, p95, max, over50) = try await runConcurrency(2)
        print(String(format: "[PERF-SUBAGENT-N2] samples=%d p95=%.2fms max=%.2fms over50ms=%d", samples, p95, max, over50))
        XCTAssertLessThanOrEqual(p95, framePacingP95ThresholdMs)
    }

    func testMeasureConcurrency4() async throws {
        try skipUnlessPerfSample()
        _ = try await runConcurrency(4)
        let (samples, p95, max, over50) = try await runConcurrency(4)
        print(String(format: "[PERF-SUBAGENT-N4] samples=%d p95=%.2fms max=%.2fms over50ms=%d", samples, p95, max, over50))
        XCTAssertLessThanOrEqual(p95, framePacingP95ThresholdMs)
    }

    func testMeasureConcurrency8() async throws {
        try skipUnlessPerfSample()
        _ = try await runConcurrency(8)
        let (samples, p95, max, over50) = try await runConcurrency(8)
        print(String(format: "[PERF-SUBAGENT-N8] samples=%d p95=%.2fms max=%.2fms over50ms=%d", samples, p95, max, over50))
        XCTAssertLessThanOrEqual(p95, framePacingP95ThresholdMs)
    }

    func testMeasureConcurrency8LargeSynchronizedOutput() async throws {
        try skipUnlessPerfSample()
        _ = try await runConcurrencyLargeOutput(8, outputBytes: 8 * 1_024)
        let (samples, p95, max, over50) = try await runConcurrencyLargeOutput(8, outputBytes: 8 * 1_024)
        print(String(format: "[PERF-SUBAGENT-N8-8KB] samples=%d p95=%.2fms max=%.2fms over50ms=%d", samples, p95, max, over50))
        XCTAssertLessThanOrEqual(p95, framePacingP95ThresholdMs)
    }

    func testMeasureConcurrency8LargeOutputDurable300() async throws {
        _ = try await runConcurrencyDurable(8, outputBytes: 8 * 1_024, historicalRunCount: 300)
        let (samples, p95, max, over50) = try await runConcurrencyDurable(8, outputBytes: 8 * 1_024, historicalRunCount: 300)
        print(String(format: "[PERF-SUBAGENT-N8-8KB-DURABLE300] samples=%d p95=%.2fms max=%.2fms over50ms=%d", samples, p95, max, over50))
        XCTAssertLessThanOrEqual(p95, framePacingP95ThresholdMs)
    }
}
