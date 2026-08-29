import XCTest
import UIKit
@preconcurrency import Shared
@testable import iosApp

// MARK: - 消息/chunk 构造(与 IOSAgentToolEngineTests 同形)

enum IOSChatForegroundFixtures {
    static func makeProviderSetting() -> ProviderSetting.OpenAI {
        // KMP 桥不暴露 Kotlin 默认参数,全参构造(同 IOSAgentToolEngineTests)。
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: "foreground-loop-test",
            models: [],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    /// - parameter tools: 直接指定声明列表(生产走 `bridge.visibleTools()`);
    ///   nil 时退回 `ToolKt.iosToolDeclarations(names:)`(注意该表不含
    ///   tool_search——需要它可见的用例必须改走桥装配,见具装 init)。
    static func makeParams(toolNames: [String], tools: [Tool]? = nil) -> TextGenerationParams {
        let model = Model(
            modelId: "test-model",
            displayName: "test-model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        return TextGenerationParams(
            model: model,
            temperature: KotlinFloat(value: 0.7),
            topP: nil,
            maxTokens: nil,
            tools: tools ?? ToolKt.iosToolDeclarations(names: toolNames.sorted()),
            reasoningLevel: .off,
            customHeaders: [],
            customBody: []
        )
    }

    static func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        let now = Kotlinx_datetimeLocalDateTime(
            year: 2026, month: 8, day: 27, hour: 0, minute: 0, second: 0, nanosecond: 0
        )
        return UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: now,
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static func userMessage(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.user, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    static func assistantText(_ text: String) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: [UIMessagePart.Text(text: text, metadata: nil)])
    }

    static func assistantMessage(parts: [UIMessagePart]) -> UIMessage {
        makeMessage(role: MessageRole.assistant, parts: parts)
    }

    static func chunk(with message: UIMessage?, finishReason: String = "stop") -> MessageChunk {
        MessageChunk(
            id: "chunk-\(UUID().uuidString)",
            model: "test-model",
            choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: finishReason)],
            usage: nil
        )
    }

    /// 流式 delta chunk(生产形状)。
    static func streamChunk(delta: UIMessage, finishReason: String = "stop") -> MessageChunk {
        MessageChunk(
            id: "chunk-\(UUID().uuidString)",
            model: "test-model",
            choices: [UIMessageChoice(index: 0, delta: delta, message: nil, finishReason: finishReason)],
            usage: nil
        )
    }

    /// 在 upload 消息里找某个 toolCallId 的 Tool part(断言结果回填用)。
    static func toolPart(toolCallId: String, in messages: [UIMessage]) -> UIMessagePart.Tool? {
        for message in messages {
            for part in message.parts {
                if let tool = part as? UIMessagePart.Tool, tool.toolCallId == toolCallId {
                    return tool
                }
            }
        }
        return nil
    }

    static func toolOutputText(toolCallId: String, in messages: [UIMessage]) -> String {
        guard let tool = toolPart(toolCallId: toolCallId, in: messages) else { return "" }
        return tool.output.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined()
    }
}

/// UI replay tests feed bounded prefix snapshots, matching the Kernel projection's
/// observable contract without retaining the deleted foreground Coordinator pacer.
struct IOSChatStreamSnapshotStep {
    let snapshot: [UIMessage]
    let isCaughtUp: Bool
}

enum IOSChatStreamSnapshotStepper {
    static func step(current: [UIMessage], target: [UIMessage]) -> IOSChatStreamSnapshotStep {
        guard let targetAssistant = target.last,
              targetAssistant.role == MessageRole.assistant else {
            return IOSChatStreamSnapshotStep(snapshot: target, isCaughtUp: true)
        }

        let currentAssistant: UIMessage?
        let currentPrefix: ArraySlice<UIMessage>
        if current.count == target.count,
           let last = current.last,
           last.role == MessageRole.assistant,
           last.id == targetAssistant.id {
            currentAssistant = last
            currentPrefix = current.dropLast()
        } else if current.count + 1 == target.count {
            currentAssistant = nil
            currentPrefix = current[...]
        } else {
            return IOSChatStreamSnapshotStep(snapshot: target, isCaughtUp: true)
        }

        let targetPrefix = target.dropLast()
        guard currentPrefix.count == targetPrefix.count,
              zip(currentPrefix, targetPrefix).allSatisfy({ $0.id == $1.id }) else {
            return IOSChatStreamSnapshotStep(snapshot: target, isCaughtUp: true)
        }

        let currentParts = currentAssistant?.parts ?? []
        var backlog = 0
        for (index, targetPart) in targetAssistant.parts.enumerated() {
            guard let targetText = targetPart as? UIMessagePart.Text else { continue }
            let currentCount = (index < currentParts.count ? currentParts[index] as? UIMessagePart.Text : nil)?
                .text.count ?? 0
            backlog += max(0, targetText.text.count - currentCount)
        }
        var remainingBudget = StreamPresentationPacingPolicy.textAdvance(backlogCount: backlog)
        var caughtUp = true
        var parts: [UIMessagePart] = []
        parts.reserveCapacity(targetAssistant.parts.count)

        for (index, targetPart) in targetAssistant.parts.enumerated() {
            guard let targetText = targetPart as? UIMessagePart.Text else {
                parts.append(targetPart)
                continue
            }
            let currentText = (index < currentParts.count ? currentParts[index] as? UIMessagePart.Text : nil)?
                .text ?? ""
            guard targetText.text.hasPrefix(currentText) else {
                return IOSChatStreamSnapshotStep(snapshot: target, isCaughtUp: true)
            }
            let suffix = targetText.text.dropFirst(currentText.count)
            let advance = min(remainingBudget, suffix.count)
            remainingBudget -= advance
            if advance < suffix.count { caughtUp = false }
            parts.append(UIMessagePart.Text(
                text: currentText + suffix.prefix(advance),
                metadata: targetText.metadata
            ))
        }

        let assistant = UIMessage(
            id: targetAssistant.id,
            role: targetAssistant.role,
            parts: parts,
            annotations: targetAssistant.annotations,
            createdAt: targetAssistant.createdAt,
            finishedAt: caughtUp ? targetAssistant.finishedAt : currentAssistant?.finishedAt,
            modelId: targetAssistant.modelId,
            usage: caughtUp ? targetAssistant.usage : currentAssistant?.usage,
            translation: targetAssistant.translation
        )
        return IOSChatStreamSnapshotStep(
            snapshot: Array(targetPrefix) + [assistant],
            isCaughtUp: caughtUp
        )
    }
}

// MARK: - 日志账本(IOSAgentRunLedgering spy)

/// 把账本调用按序写进共享日志的 spy。`toolCallFinished` 只带 toolCallId,
/// 这里留存 toolCallId→toolName 映射以产出可读的归一化事件。
final class IOSRunEventLogLedger: IOSAgentRunLedgering, @unchecked Sendable {
    struct RecoveryTransition: Equatable {
        let expected: IOSToolTransactionState
        let state: IOSToolTransactionState
        let outcome: String
    }

    private let log: IOSRunEventLog
    private let lock = NSLock()
    private var toolNamesByCallId: [String: String] = [:]
    private var recordedRecoveryTransitions: [RecoveryTransition] = []
    /// 强制 Started 写失败,验证 I-1 fail-closed(账本写不成 → 工具绝不执行)。
    var failStarts = false
    var preparationResult = IOSToolTransactionPreparation.ready

    var recoveryTransitions: [RecoveryTransition] {
        lock.withLock { recordedRecoveryTransitions }
    }

    init(log: IOSRunEventLog) {
        self.log = log
    }

    func recordToolCallPrepared(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> IOSToolTransactionPreparation {
        lock.withLock { toolNamesByCallId[toolCallId] = toolName }
        return preparationResult
    }

    func recordToolCallStarted(
        runId: String,
        toolCallId: String,
        toolName: String,
        argsDigest: String,
        effectClass: IOSToolEffectClass
    ) async -> Bool {
        lock.withLock { toolNamesByCallId[toolCallId] = toolName }
        if failStarts { return false }
        log.append(.toolCallStarted(tool: toolName))
        return true
    }

    func recordToolCallFinished(runId: String, toolCallId: String, outcome: String) async {
        let name = lock.withLock { toolNamesByCallId[toolCallId] ?? toolCallId }
        log.append(.toolCallFinished(tool: name, outcome: outcome))
    }

    func recordToolCallFinished(
        runId: String,
        toolCallId: String,
        outcome: String,
        artifactId: String?,
        artifactVersion: String?,
        outcomeKind: String?,
        errorCode: String?,
        sourceRef: String?
    ) async {
        let name = lock.withLock { toolNamesByCallId[toolCallId] ?? toolCallId }
        log.append(.toolCallFinished(tool: name, outcome: outcome))
    }

    func recordApprovalDenied(
        runId: String,
        toolCallId: String,
        toolName: String,
        reason: String,
        capabilityId: String?
    ) async {
        log.append(.approvalDenied(tool: toolName))
    }

    func recordToolCallRecoveryTransition(
        runId: String,
        toolCallId: String,
        expected: IOSToolTransactionState,
        to state: IOSToolTransactionState,
        outcome: String
    ) async -> Bool {
        lock.withLock {
            recordedRecoveryTransitions.append(RecoveryTransition(
                expected: expected,
                state: state,
                outcome: outcome
            ))
        }
        return true
    }
}

// MARK: - 可控搜索传输

/// 立即返回 200 + 一条最小结果的传输(搜索工具走完执行路径但不触网)。
/// DDG Lite 解析器认 `class="result-link"` 的 <a>;空体会让工具产出空输出,
/// 「批准后真实执行并回填」类断言无从区分「没回填」与「回填了空串」。
final class IOSForegroundNoopSearchTransport: IOSSearchHTTPTransport, @unchecked Sendable {
    static let resultHTML = """
    <html><body><a class="result-link" href="https://example.test/amber">Amber Result</a></body></html>
    """

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        (Self.okResponse(for: request), Data(Self.resultHTML.utf8))
    }

    static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
    }
}

// MARK: - Harness

/// Kernel Host 测试 harness:装配依赖与可观察 bindings。
/// 每个测试用例一份实例(isolated UserDefaults、独立 runId)。
@MainActor
final class IOSChatForegroundHarness {
    let log = IOSRunEventLog()
    let ledger: IOSRunEventLogLedger
    let conversationId = KotlinUuid.companion.random()
    let providerSetting: ProviderSetting.OpenAI
    let params: TextGenerationParams
    /// 全目录曝光桥(生产同款:ChatViewModel 装配、start 注入)。params.tools
    /// 只是首轮可见集;全目录决定 soft-fail 与 tool_search 扩展语义。
    let toolExposureBridge: IosToolExposureBridge
    /// `bindings` 可变，测试可在 Host 构造前追加录制槽位。
    private(set) var dependencies: ChatGenerationDependencies!
    var bindings: ChatGenerationBindings!
    private(set) var keepAlive: BackgroundGenerationKeepAlive!
    /// Host 测试覆写口:bindings 的 messagesByInjectingRuntimeContext 是 let,
    /// 装配后只能经此间接路由(默认恒等,即原行为)。
    var runtimeContextInjector: ([UIMessage]) -> [UIMessage] = { $0 }

    private(set) var messages: [UIMessage]
    private(set) var revisions: [ChatMessageUpdateReason] = []
    private(set) var persistedSnapshots: [[UIMessage]] = []
    private(set) var isLoading = false

    // Host 生命周期测试只需要搜索审批卡。
    private(set) var pendingSearchApproval: SearchToolApprovalRequest?

    /// run 终态时 steer leftover 的处理记录(autoContinue 标志)。
    private(set) var terminalSteerAutoContinue: [Bool] = []

    /// recordRun 捕获的 runId。
    private(set) var capturedRunId: String?
    private(set) var capturedRunProtocolContext: AgentRunProtocolContext?

    /// - parameter toolNames: 全目录声明名单(经 `ToolKt.iosToolDeclarations`)。
    ///   默认 = 生产全目录(75 个声明,越过 40 的 lazy 阈值),resident 工具自动
    ///   可见、deferred 工具(如 session_search)需经 `exposedToolNames` 预曝光——
    ///   与生产 tool_search 扩展同机制。小目录会关掉 lazy 模式(≤40 全可见),
    ///   曝光语义失真,仅在专门构造曝光场景时才缩目录。
    init(
        toolNames: [String] = ToolKt.iosToolDeclarationNames(),
        exposedToolNames: [String] = [],
        seedMessages: [UIMessage]? = nil,
        searchTransport: any IOSSearchHTTPTransport = IOSForegroundNoopSearchTransport(),
        chatMaxToolResumeCount: Int? = nil
    ) {
        let suite = "app.amber.ios.tests.foreground.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settingsStore = SettingsStore(userDefaults: defaults, storageKey: "settings-\(UUID().uuidString)")
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        if let chatMaxToolResumeCount {
            settingsStore.chatMaxToolResumeCount = chatMaxToolResumeCount
        }
        let seeded = seedMessages ?? [IOSChatForegroundFixtures.userMessage("你好")]
        self.messages = seeded
        self.providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        // 生产装配(ChatViewModel:3583 同款):全目录声明进桥,params.tools 只取
        // 首轮可见集(resident + 预曝光 + 桥自动追加的 tool_search/tools_list)。
        // 直接 iosToolDeclarations 当 params 会丢 tool_search 声明,导致工具
        // 检测/软失败分类全部失真。
        let bridge = IosToolExposureBridge(
            tools: ToolKt.iosToolDeclarations(names: toolNames.sorted())
        )
        if !exposedToolNames.isEmpty {
            bridge.exposeToolNames(names: exposedToolNames)
        }
        self.toolExposureBridge = bridge
        self.params = IOSChatForegroundFixtures.makeParams(toolNames: [], tools: bridge.visibleTools())

        let log = self.log
        let spyLedger = IOSRunEventLogLedger(log: log)
        self.ledger = spyLedger

        let keepAlive = BackgroundGenerationKeepAlive(
            beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 901) },
            endBackgroundTask: { _ in },
            submitTaskRequest: { _ in },
            cancelTaskRequest: { _ in },
            registerLaunchHandler: { _, _ in true }
        )

        let dependencies = ChatGenerationDependencies(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: searchTransport,
            liveActivityController: .shared,
            // 生产为 true:审批恢复后要续跑到下一轮模型(resumeAfterApproval
            // :4556 的唯一读取点)。false 会让审批恢复直接收尾,扭曲审批场景。
            autoGenerateResponses: true,
            mcpManager: IOSMcpManager(sharedSettings: sharedSettings, configStore: .shared),
            orchestrationToolService: nil,
            memoryPollutionMarker: nil
        )

        // 绑定全部录制进共享日志;主 actor 状态经 weak self 写回。
        var bindings = ChatGenerationBindings(
            getMessages: { [weak self] in self?.messages ?? [] },
            setMessages: { [weak self] in self?.messages = $0 },
            bumpMessageRevision: { [weak self] reason, _ in self?.revisions.append(reason) },
            setIsLoading: { [weak self] in self?.isLoading = $0 },
            setPendingMemoryApproval: { _ in },
            setPendingSearchApproval: { [weak self] in
                self?.pendingSearchApproval = $0
                if $0 != nil { log.append(.approvalRequested(kind: "search")) }
            },
            setPendingWebMountApproval: { _ in },
            setPendingWorkspaceApproval: { _ in },
            setPendingIshHandoffApproval: { _ in },
            setPendingMcpApproval: { _ in },
            setPendingCouncilApproval: { _ in },
            setPendingAskUser: { _ in },
            setContextCompactState: { _ in },
            persistMessages: { _ in true },
            capturePersistMessagesBaseline: { _ in nil },
            persistMessagesSnapshot: { [weak self] snapshot, _, _ in
                self?.persistedSnapshots.append(snapshot)
                return true
            },
            recordRun: { [weak self] runId, startedAt, status, inputDigest, conversationHex, protocolContext in
                self?.capturedRunId = runId
                if status == .running {
                    self?.capturedRunProtocolContext = protocolContext
                    log.append(.runStarted)
                } else if status == .completed || status == .failed
                            || status == .cancelled || status == .interrupted {
                    log.append(.runTerminal(status: status.wireName))
                }
                return true
            },
            startLiveActivity: { _, _, _ in },
            saveMiniAppIfPresent: { _, _ in nil },
            messagesByInjectingRuntimeContext: { [weak self] messages in
                self?.runtimeContextInjector(messages) ?? messages
            },
            userFacingGenerationError: { rawMessage, _ in rawMessage }
        )
        bindings.setPendingRecipeApproval = { _ in }
        bindings.markRunAwaitingPermission = { runId, toolCallId in
            log.append(.runAwaitingPermission(toolCallId: toolCallId))
            return true
        }
        bindings.resumeRunAfterPermission = { runId in
            log.append(.runResumed)
            return true
        }
        bindings.drainSteerQueue = { _ in [] }
        bindings.handleSteerQueueAtTerminal = { [weak self] _, autoContinue in
            self?.terminalSteerAutoContinue.append(autoContinue)
        }

        self.dependencies = dependencies
        self.bindings = bindings
        self.keepAlive = keepAlive

    }

    // MARK: 等待器(MainActor 轮询;协调器的续跑 Task 也在 MainActor,sleep 即让行)

    func waitForTerminal(timeoutSeconds: Double = 10) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let terminal = log.terminalStatus() { return terminal }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func waitForPendingSearchApproval(timeoutSeconds: Double = 10) async -> SearchToolApprovalRequest? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let pendingSearchApproval { return pendingSearchApproval }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

}
