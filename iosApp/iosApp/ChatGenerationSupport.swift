import CryptoKit
import Foundation
@preconcurrency import Shared
import UIKit

// Shared chat policies and value types consumed by the foreground Host,
// background coordinator, Council, and Novel flows.

func chatInputDigest(for text: String) -> String {
    let hash = SHA256.hash(data: Data(text.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
}

func chatNowLocalDateTime() -> Kotlinx_datetimeLocalDateTime {
    let now = Date()
    let cal = Calendar.current
    return Kotlinx_datetimeLocalDateTime(
        year: Int32(cal.component(.year, from: now)),
        month: Int32(cal.component(.month, from: now)),
        day: Int32(cal.component(.day, from: now)),
        hour: Int32(cal.component(.hour, from: now)),
        minute: Int32(cal.component(.minute, from: now)),
        second: Int32(cal.component(.second, from: now)),
        nanosecond: Int32(cal.component(.nanosecond, from: now))
    )
}

final class ChatStreamEvent: @unchecked Sendable {
    enum Payload {
        case chunk(MessageChunk)
        case complete
        case error(KotlinThrowable)
    }

    let payload: Payload

    private init(_ payload: Payload) {
        self.payload = payload
    }

    static func chunk(_ chunk: MessageChunk) -> ChatStreamEvent {
        ChatStreamEvent(.chunk(chunk))
    }

    static func complete() -> ChatStreamEvent {
        ChatStreamEvent(.complete)
    }

    static func error(_ error: KotlinThrowable) -> ChatStreamEvent {
        ChatStreamEvent(.error(error))
    }
}

final class ChatStreamEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ChatStreamEvent>.Continuation?
    private var pendingEvents: [ChatStreamEvent] = []
    private var pendingEventHead = 0
    private var isFinished = false

    func bind(_ continuation: AsyncStream<ChatStreamEvent>.Continuation) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.finish()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ event: ChatStreamEvent) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        pendingEvents.append(event)
        // `yield` 也放在锁内，确保不同 provider 回调线程看到同一 FIFO 次序。
        continuation.yield(event)
        lock.unlock()
    }

    func claim(_ event: ChatStreamEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingEventHead < pendingEvents.count,
              pendingEvents[pendingEventHead] === event else {
            return false
        }
        pendingEventHead += 1
        compactClaimedPrefixIfNeeded()
        return true
    }

    func takePendingChunks() -> [MessageChunk] {
        lock.lock()
        defer { lock.unlock() }
        var chunks: [MessageChunk] = []
        var retained: [ChatStreamEvent] = []
        if pendingEventHead < pendingEvents.count {
            retained.reserveCapacity(pendingEvents.count - pendingEventHead)
            for event in pendingEvents[pendingEventHead...] {
                if case .chunk(let chunk) = event.payload {
                    chunks.append(chunk)
                } else {
                    retained.append(event)
                }
            }
        }
        pendingEvents = retained
        pendingEventHead = 0
        return chunks
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        isFinished = true
        lock.unlock()
        continuation?.finish()
    }

    /// Atomically chooses background ownership against a racing provider terminal callback.
    /// Accepted chunks remain drainable; a queued complete/error keeps foreground ownership.
    @MainActor
    func transitionToBackgroundIfNoTerminal(_ startBackground: () -> Bool) -> Bool {
        lock.lock()
        guard !isFinished,
              !pendingEvents[pendingEventHead...].contains(where: { event in
                switch event.payload {
                case .complete, .error:
                    return true
                case .chunk:
                    return false
                }
              }) else {
            lock.unlock()
            return false
        }
        let didStart = startBackground()
        let continuation = didStart ? continuation : nil
        if didStart {
            self.continuation = nil
            isFinished = true
        }
        lock.unlock()
        continuation?.finish()
        return didStart
    }

    private func compactClaimedPrefixIfNeeded() {
        guard pendingEventHead >= 64,
              pendingEventHead * 2 >= pendingEvents.count else { return }
        pendingEvents.removeFirst(pendingEventHead)
        pendingEventHead = 0
    }

#if DEBUG
    var pendingEventCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingEvents.count - pendingEventHead
    }
#endif
}

/// 流式「呈现节奏」策略：需要渐进发布文本的消费者共用同一份字符推进口径。
/// 这里只保留与具体消息形状无关的步长和终态排空公式。
enum StreamPresentationPacingPolicy {
    /// 轻积压时的下限:一拍推进不到一行手机宽度的中文,保留既有 48ms 发布时钟。
    static let minimumTextAdvance = 12
    /// 每拍硬上限:约一到两行中文。64 字会在手机宽度下一次放出约三行，
    /// TextKit 高度与底部跟随只能在下一帧追上，表现为偶发的大幅跳变。
    static let maximumTextAdvance = 36
    /// 尽量在这么多拍内清空*当前*积压。
    static let preferredDrainTicks = 16
    /// 24K-char terminal bursts are the observed worst normal reply; drain
    /// that backlog within the existing 16 ticks without changing live pacing.
    /// Shared by the novel and council presentation sessions.
    static let terminalMaximumTextAdvance = 24 * 1_024 / preferredDrainTicks

    /// 按积压自适应的每拍推进量。
    ///
    /// 固定 12 字符/拍意味着显示速率恒为 250 字符/秒。模型快于这个速率时
    /// 积压会持续累积,且终态排空仍按同一节奏逐拍追平——4000 字的回复要 334 拍
    /// (≈16s)才显示完,期间 `isLoading` 保持 true,用户看着"停止"按钮等一段
    /// 早已生成完的文本。
    static func textAdvance(backlogCount: Int) -> Int {
        guard backlogCount > 0 else { return 0 }
        let adaptive = (backlogCount + preferredDrainTicks - 1) / preferredDrainTicks
        return min(maximumTextAdvance, max(minimumTextAdvance, adaptive))
    }

    /// 终态排空的节奏锚：整轮由完成时积压一次决定，不逐拍衰减。
    /// 连续于积压、无阈值断点——小积压（几十字）≈12 字/拍 × 48ms；大积压
    /// 趋近 1500 字/拍 × 8ms，约 16 拍 whoosh。小说与 Council 共用。
    static func terminalDrainAdvance(backlogCount: Int) -> Int {
        guard backlogCount > 0 else { return 0 }
        let adaptive = (backlogCount + preferredDrainTicks - 1) / preferredDrainTicks
        return min(terminalMaximumTextAdvance, max(minimumTextAdvance, adaptive))
    }

    /// 排空拍间隔：由整轮节奏锚决定。advance≤36 保持 48ms 流式节拍；
    /// advance 1500 时 8ms（120Hz 逐帧）。
    static func terminalDrainDelayNanos(advance: Int) -> UInt64 {
        let intervalMs = min(48.0, max(8.0, 48.0 * Double(maximumTextAdvance) / Double(max(advance, 1))))
        return UInt64(intervalMs * 1_000_000)
    }

    /// 收尾减速的除数：末段拍速 = max(12, 剩余/8)，与锚速取小。
    /// 大积压中段保持 whoosh，最后 ~锚速×8 字连续减速，末拍回到打字节奏
    /// （12 字/拍 × 48ms），配合按拍缩放的淡入自动恢复完整 0.5s——
    /// 「最后一个字优雅地逐字淡入结束」的产品契约。
    static let gracefulTailDivisor = 8

    /// 终态单拍推进量；`fixedAdvance` 为完成时定锚的整轮节奏上限，
    /// 实际每拍随剩余积压连续收敛（graceful tail），不再整轮恒速。
    static func terminalTextAdvance(
        backlogCount: Int,
        fixedAdvance: Int? = nil
    ) -> Int {
        guard backlogCount > 0 else { return 0 }
        let anchor = fixedAdvance ?? (backlogCount + preferredDrainTicks - 1) / preferredDrainTicks
        let anchorClamped = min(terminalMaximumTextAdvance, max(minimumTextAdvance, anchor))
        let gracefulTail = max(minimumTextAdvance, (backlogCount + gracefulTailDivisor - 1) / gracefulTailDivisor)
        return min(anchorClamped, gracefulTail)
    }

    /// 滚动跟随的滞后允许度（1=流式期，→0=排空收尾）。排空期间它随剩余积压
    /// 连续衰减，跟随器的时间常数随之收紧（τ_eff = τ × allowance），视口在
    /// 最后一拍落定前贴回底部——完成瞬间的钉底不再需要一次性清掉跟随滞后。
    static func lagAllowance(remainingBacklog: Int, drainStartBacklog: Int) -> CGFloat {
        guard drainStartBacklog > 0, remainingBacklog > 0 else { return 0 }
        return CGFloat(min(1, Double(remainingBacklog) / Double(drainStartBacklog)))
    }
}

struct ChatPendingToolApproval {
    let toolCall: UIMessagePart.Tool
    let providerSetting: ProviderSetting
    let params: TextGenerationParams
    let runId: String
    let startedAt: Int64
    let inputDigest: String
    let conversationId: KotlinUuid?
    let baseMessages: [UIMessage]
    var executionPolicy: IOSExecutionPolicySnapshot? = nil
}

struct ChatGenerationDependencies {
    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let localToolExecutor: IOSLocalToolExecutor?
    let searchTransport: any IOSSearchHTTPTransport
    let liveActivityController: AgentLiveActivityController
    let autoGenerateResponses: Bool
    let mcpManager: IOSMcpManager
    /// P1-c: 线程编排工具执行体（nil 时编排工具返回结构化不可用）。
    let orchestrationToolService: IOSThreadOrchestrationToolService?
    /// P2-a: 记忆污染置位回调（conversationId, toolName）。nil = 不置位。
    let memoryPollutionMarker: ((KotlinUuid, String) -> Void)?
    /// 跨会话读取工具（session_search/session_read）的会话存储源。var 带默认值，
    /// 成员构造器给默认参数——既有调用点零改动；nil = 工具返回结构化不可用。
    var conversationStoreProvider: (() -> IOSConversationStore?)? = nil
}

struct ChatMiniAppOutputApplication {
    enum Outcome: Equatable {
        case applied
        case failed
    }

    let messages: [UIMessage]
    let rollbackMessages: [UIMessage]
    let outcome: Outcome
    private let commitHandler: (@MainActor () -> Bool)?
    private let rollbackHandler: (@MainActor () -> Bool)?
    private let workspaceSyncHandler: (@MainActor () -> ChatMiniAppWorkspaceSyncFailure?)?

    init(
        messages: [UIMessage],
        rollbackMessages: [UIMessage]? = nil,
        outcome: Outcome = .applied,
        commit: (@MainActor () -> Bool)? = nil,
        rollback: (@MainActor () -> Bool)? = nil,
        syncWorkspace: (@MainActor () -> ChatMiniAppWorkspaceSyncFailure?)? = nil
    ) {
        self.messages = messages
        self.rollbackMessages = rollbackMessages ?? messages
        self.outcome = outcome
        self.commitHandler = commit
        self.rollbackHandler = rollback
        self.workspaceSyncHandler = syncWorkspace
    }

    @MainActor
    func commit() -> Bool {
        commitHandler?() ?? true
    }

    @MainActor
    func rollback() -> Bool {
        rollbackHandler?() ?? false
    }

    @MainActor
    func syncWorkspaceAfterConversationPersistence() -> ChatMiniAppWorkspaceSyncFailure? {
        workspaceSyncHandler?()
    }
}

struct ChatMiniAppWorkspaceSyncFailure {
    let messages: [UIMessage]
    let replacementMessage: UIMessage
}

struct ChatGenerationBindings {
    let getMessages: () -> [UIMessage]
    let setMessages: ([UIMessage]) -> Void
    let bumpMessageRevision: (ChatMessageUpdateReason, CGFloat) -> Void
    let setIsLoading: (Bool) -> Void
    let setPendingMemoryApproval: (MemoryToolApprovalRequest?) -> Void
    let setPendingSearchApproval: (SearchToolApprovalRequest?) -> Void
    let setPendingWebMountApproval: (WebMountToolApprovalRequest?) -> Void
    let setPendingWorkspaceApproval: (WorkspaceToolApprovalRequest?) -> Void
    let setPendingIshHandoffApproval: (IshHandoffToolApprovalRequest?) -> Void
    let setPendingMcpApproval: (McpToolApprovalRequest?) -> Void
    let setPendingCouncilApproval: (CouncilToolApprovalRequest?) -> Void
    let setPendingAskUser: (ChatAskUserRequest?) -> Void
    /// Wave B2: recipe 审批卡（mutation step / recipe_import）。
    var setPendingRecipeApproval: (RecipeToolApprovalRequest?) -> Void = { _ in }
    let setContextCompactState: (ChatContextCompactState) -> Void
    let persistMessages: @MainActor (KotlinUuid?) async -> Bool
    let capturePersistMessagesBaseline: (KotlinUuid?) -> IOSConversationWriteBaseline?
    let persistMessagesSnapshot: @MainActor ([UIMessage], KotlinUuid?, IOSConversationWriteBaseline?) async -> Bool
    let recordRun: (String, Int64, AgentRunStatus, String, String?, AgentRunProtocolContext?) async -> Bool
    var markRunAwaitingPermission: @MainActor (String, String) async -> Bool = { _, _ in true }
    var resumeRunAfterPermission: @MainActor (String) async -> Bool = { _ in true }
    let startLiveActivity: (String, KotlinUuid?, AgentActivityPresentation) -> Void
    let saveMiniAppIfPresent: ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?
    let messagesByInjectingRuntimeContext: ([UIMessage]) -> [UIMessage]
    var messagesByInjectingRuntimeContextForRun: (([UIMessage], Bool) -> [UIMessage])? = nil
    let userFacingGenerationError: (String, String?) -> String
    var memoryRecordIdsForRuntimeContext: ([UIMessage]) -> [Int32] = { _ in [] }
    /// 第二个 Bool 为 P2-c 修复 2 的 force 标记：模型显式引用（citation flush）
    /// 传 true 绕过 P2-b 同集去抖；召回标记传 false。
    var recordMemoryUsage: @MainActor ([Int32], Bool) -> Void = { _, _ in }
    var generationSucceeded: @MainActor () -> Void = {}
    /// P1-a: 工具循环边界消费 steer 队列——出队全部排队消息（owner 内部负责
    /// 上屏 + 持久化），返回生成的 user 消息供下一轮 upload 折入。空队列零操作。
    var drainSteerQueue: (KotlinUuid?) -> [UIMessage] = { _ in [] }
    /// P1-b: 工具循环/新 run 首轮边界消费 mailbox——Room 事务 drain 未投递信封
    /// （owner 内部渲染为带结构头的 user 消息上屏 + 持久化），返回生成的消息供
    /// 下一轮 upload 折入（先于 steer）。空队列零操作；消费顺序由调用方保证。
    /// @MainActor：async 闭包跨 actor 调用会 send 非 Sendable 的 KotlinUuid，
    /// 消费点（coordinator/ViewModel）本身都在 MainActor，隔离到主线程无跳变。
    var drainMailbox: @MainActor (KotlinUuid?) async -> [UIMessage] = { _ in [] }
    /// P1-a: run 终态处理 leftover。`autoContinue == true`（成功收尾）时出队头一条并
    /// 自动开下一轮；取消/失败时回填 composer（含附件条目留队）。
    var handleSteerQueueAtTerminal: (KotlinUuid?, Bool) -> Void = { _, _ in }
    /// 兼容旧绑定名：等价于 `handleSteerQueueAtTerminal(id, false)`。
    var restoreSteerQueueLeftover: (KotlinUuid?) -> Void = { _ in }
    /// P1-c: run 终态回传钩子——编排服务据此向父线程 mailbox 投递 FINAL_ANSWER
    /// （conversationId、runId、终态消息快照）。默认空实现零开销。
    var onRunTerminal: @MainActor (KotlinUuid?, String, [UIMessage]) async -> Void = { _, _, _ in }
    /// Surfaces the existing reconciliation card for a live side effect whose
    /// executor could not determine whether it applied.
    var setToolOutcomeUnknown: @MainActor (IOSToolOutcomeUnknownDescriptor) -> Void = { _ in }
    /// 管线闭环修复：每轮组装前刷新编排链接缓存（spawn 发生在 run 中途、邮件
    /// 在边界到达——只在会话切换时刷新会让这些轮次漏掉编排语境注入）。
    /// 默认空实现零影响。
    var refreshOrchestrationLinks: @MainActor () async -> Void = {}
}

struct IOSGenerativeUiRequirement: Equatable {
    let required: Bool
    let expectSlides: Bool
    let expectFullHtmlDeck: Bool

    static let none = IOSGenerativeUiRequirement(
        required: false,
        expectSlides: false,
        expectFullHtmlDeck: false
    )

    init(required: Bool, expectSlides: Bool, expectFullHtmlDeck: Bool) {
        self.required = required
        self.expectSlides = expectSlides
        self.expectFullHtmlDeck = expectFullHtmlDeck
    }

    init(_ shared: GenerativeUiWidgetRequirement) {
        self.init(
            required: shared.required,
            expectSlides: shared.expectSlides,
            expectFullHtmlDeck: shared.expectFullHtmlDeck
        )
    }

    var sharedValue: GenerativeUiWidgetRequirement {
        GenerativeUiWidgetRequirement(
            required: required,
            expectSlides: expectSlides,
            expectFullHtmlDeck: expectFullHtmlDeck
        )
    }
}

struct IOSGenerativeUiRequestPlan {
    let params: TextGenerationParams
    let uploadMessages: [UIMessage]
    let requirement: IOSGenerativeUiRequirement
}

enum IOSGenerativeUiRequestPolicy {
    static func plan(
        setting: GenerativeUiSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        suppressForMiniApp: Bool = false
    ) -> IOSGenerativeUiRequestPlan {
        if suppressForMiniApp {
            return IOSGenerativeUiRequestPlan(
                params: params,
                uploadMessages: messages,
                requirement: .none
            )
        }
        let hasImageGenTool = params.tools.contains(where: { $0.name == "generate_image" })
        let sharedRequirement = GenerativeUiPlanner.shared.widgetRequirement(
            setting: setting,
            messages: messages
        )
        // G6: keyword routing only injects prompt guidance — it never clears
        // the tool catalog. Whether the model uses tools is its own choice.
        let basePrompt = GenerativeUiPromptCatalog.shared.build(setting: setting, model: params.model)
        let routePrompt = GenerativeUiPlanner.shared.buildPrompt(
            setting: setting,
            messages: messages,
            hasImageGenTool: hasImageGenTool
        )
        let prompt = [basePrompt, routePrompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        return IOSGenerativeUiRequestPlan(
            params: params,
            uploadMessages: prompt.isEmpty ? messages : [systemMessage(prompt)] + messages,
            requirement: IOSGenerativeUiRequirement(sharedRequirement)
        )
    }

    /// G6: the repair round is a normal continuation — tools stay declared and
    /// the reasoning level is untouched, so the model can research missing
    /// facts before drawing instead of streaming blind.
    static func retryParams(_ params: TextGenerationParams) -> TextGenerationParams {
        params
    }

    /// G6: the repair round appends instead of deleting — the user's visible
    /// draft is kept verbatim and a short "repairing" notice is appended after
    /// it. The second round streams in as a NEW assistant message, so a second
    /// failure leaves the real (draft + failed attempt) transcript behind.
    static func retryBaseMessages(_ messages: [UIMessage]) -> [UIMessage] {
        messages + [generativeUiRepairNotice()]
    }

    /// 用户可见的「补绘」状态标记：可视化未生成完整时，在保留原草稿的
    /// 前提下追加这条短消息，复用 emptyResponseNotice 同款 assistant 通知形态。
    static func generativeUiRepairNotice() -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(
                text: generativeUiRepairNoticeText,
                metadata: nil
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static let generativeUiRepairNoticeText = "可视化未生成完整，正在补绘，请稍候…"
    static let generativeUiRepairFailedText = "可视化未能生成，已保留原始回答"

    /// G6: 补绘轮二次失败的终态收口——把「正在补绘，请稍候…」notice 替换为
    /// 中性失败说明，不残留 pending 语义。最多一次重试，不再发起第三轮。
    /// 找不到 notice（baseline 边界不符或文本不匹配）时原样返回，不误伤。
    static func terminalRepairFailureMessages(
        _ messages: [UIMessage],
        afterDisplayMessageCount baselineCount: Int
    ) -> [UIMessage] {
        let noticeIndex = min(max(baselineCount, 0), messages.count) - 1
        guard noticeIndex >= 0, noticeIndex < messages.count else { return messages }
        let notice = messages[noticeIndex]
        guard isGeneratedRepairNotice(notice) else { return messages }
        var updated = messages
        updated[noticeIndex] = UIMessage(
            id: notice.id,
            role: notice.role,
            parts: [UIMessagePart.Text(text: generativeUiRepairFailedText, metadata: nil)],
            annotations: notice.annotations,
            createdAt: notice.createdAt,
            finishedAt: notice.finishedAt,
            modelId: notice.modelId,
            usage: notice.usage,
            translation: notice.translation
        )
        return updated
    }

    /// Background retries may be restored from a checkpoint whose display
    /// prefix is different from the upload prefix. Locate the durable repair
    /// notice by identity instead of guessing its index from the upload count.
    static func terminalRepairFailureMessages(_ messages: [UIMessage]) -> [UIMessage] {
        guard let noticeIndex = messages.indices.reversed().first(where: {
            isGeneratedRepairNotice(messages[$0])
        }) else {
            return messages
        }
        return terminalRepairFailureMessages(
            messages,
            afterDisplayMessageCount: noticeIndex + 1
        )
    }

    /// 补绘成功后移除瞬时状态 notice；否则会话历史会永久显示“正在补绘”。
    /// 仅按本策略生成的 notice 形状匹配，避免删除模型自己的同文案内容。
    static func terminalRepairSuccessMessages(_ messages: [UIMessage]) -> [UIMessage] {
        guard let noticeIndex = messages.indices.reversed().first(where: {
            isGeneratedRepairNotice(messages[$0])
        }) else {
            return messages
        }
        var updated = messages
        updated.remove(at: noticeIndex)
        return updated
    }

    private static func isGeneratedRepairNotice(_ message: UIMessage) -> Bool {
        guard message.role == MessageRole.assistant,
              message.parts.count == 1,
              let text = message.parts.first as? UIMessagePart.Text else {
            return false
        }
        return text.text == generativeUiRepairNoticeText
            && message.modelId == nil
            && message.usage == nil
    }

    static func retryMessages(
        _ messages: [UIMessage],
        requirement: IOSGenerativeUiRequirement,
        issue: String
    ) -> [UIMessage] {
        let prompt = GenerativeUiPromptCatalog.shared.buildRetry(
            requirement: requirement.sharedValue,
            previousIssue: issue
        )
        let repair = systemMessage(prompt)
        if messages.first?.role == MessageRole.system {
            return [messages[0], repair] + Array(messages.dropFirst())
        }
        return [repair] + messages
    }

    static func widgetIssue(
        in messages: [UIMessage],
        afterDisplayMessageCount baselineCount: Int,
        requirement: IOSGenerativeUiRequirement
    ) -> String? {
        guard requirement.required else { return nil }
        let start = min(max(baselineCount, 0), messages.count)
        let text = messages[start...]
            .reversed()
            .first(where: { $0.role == MessageRole.assistant })?
            .parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined(separator: "\n") ?? ""
        let widgets = IOSGenerativeWidgetParser.parse(text, streaming: false).compactMap { segment -> IOSGenerativeWidget? in
            guard case .widget(let widget) = segment, widget.complete else { return nil }
            return widget
        }
        guard !widgets.isEmpty else { return "missing required complete show-widget" }
        if requirement.expectFullHtmlDeck,
           !widgets.contains(where: { $0.renderer == IOSGuizangHtmlDeckValidator.renderer }) {
            return "expected renderer \"\(IOSGuizangHtmlDeckValidator.renderer)\""
        }
        if requirement.expectSlides {
            let hasDeckWidget = widgets.contains(where: {
                $0.renderer == "slides" || $0.renderer == IOSGuizangHtmlDeckValidator.renderer
            })
            if !hasDeckWidget {
                return "expected a slides or full_html deck widget"
            }
            // G6: 单页海报放宽后（完整 HTML 即可），SLIDES 路由仍要求
            // full_html 里真的有 slide 结构，而不是一张无分页的海报。
            if let deckWidget = widgets.first(where: { $0.renderer == IOSGuizangHtmlDeckValidator.renderer }),
               let spec = deckWidget.specJson.flatMap(IOSGuizangHtmlDeckValidator.normalizeSpecJson),
               !IOSGuizangHtmlDeckValidator.hasSlideLikeContent(spec.html) {
                return "expected slide sections in full_html deck"
            }
        }
        return nil
    }

    fileprivate static func systemMessage(_ prompt: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.system,
            parts: [UIMessagePart.Text(text: prompt, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }
}

@MainActor
enum ChatGenerationSupport {
    static func isMcpNetworkAllowed(executor: IOSLocalToolExecutor?) -> Bool {
        guard let executor else { return true }
        return executor.permissionsStatus().capabilities
            .first { $0.id == "ios.mcp.tool_call" }?.policy != IOSAgentPermissionPolicy.disabled.title
    }

    static func outputLimitNotice() -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [MessageKt.localOutputLimitNoticeTextPart(
                text: "⚠️ 回复已达到模型输出上限，上面的内容并不完整。可以让我「继续」，或在助手设置里调高最大输出长度后重试。"
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static func isEmptyAssistantResponse(_ messages: [UIMessage]) -> Bool {
        guard let last = messages.last, last.role == MessageRole.assistant else { return false }
        return !last.parts.contains { part in
            if let text = part as? UIMessagePart.Text {
                return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return part is UIMessagePart.Tool || part is UIMessagePart.Image
        }
    }

    static func emptyResponseNotice() -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [MessageKt.localGenerationErrorTextPart(
                text: "模型没有返回任何内容。这可能是服务商的临时问题——请重新发送，或换一个模型试试。"
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static func emptyMiniAppResponseNotice() -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [MessageKt.localGenerationErrorTextPart(
                text: "小应用生成失败：模型没有返回任何内容。请重试，或换一个模型后重新生成。"
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static func reachedOutputLimit(_ chunk: MessageChunk) -> Bool {
        let reasons = Set(chunk.choices.compactMap { $0.finishReason?.lowercased() })
        return !reasons.isDisjoint(with: ["length", "max_tokens", "max_output_tokens"])
    }

    static func continuationMessagesAfterToolBudgetExhaustion(
        _ messages: [UIMessage],
        resumeCount: Int,
        maxResumeCount: Int
    ) -> [UIMessage] {
        guard resumeCount >= maxResumeCount else { return messages }
        return [
            IOSGenerativeUiRequestPolicy.systemMessage(
                toolBudgetExhaustionPrompt(maxResumeCount: maxResumeCount)
            ),
        ] + messages
    }

    private static func toolBudgetExhaustionPrompt(maxResumeCount: Int) -> String {
        """
        工具调用预算已用完（本轮最多 \(maxResumeCount) 次工具调用）。
        请用现有信息总结收尾，并向用户说明哪些步骤未完成、为什么未完成。
        不要再发起新的工具调用。
        """
    }

    static func watchSummary(from messages: [UIMessage]) -> String? {
        guard let lastAssistant = messages.last(where: { $0.role == MessageRole.assistant }) else {
            return nil
        }
        let text = lastAssistant.parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchTaskText.clipped(text, maxLength: 280)
    }
}

extension TextGenerationParams {
    /// P0-a: a copy of these params carrying a different tool declaration list.
    /// Kotlin data-class default args don't bridge to Swift, so rebuild all
    /// fields explicitly (same shape makeTextGenerationParams uses).
    func replacingTools(_ tools: [Tool]) -> TextGenerationParams {
        TextGenerationParams(
            model: model,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            tools: tools,
            reasoningLevel: reasoningLevel,
            customHeaders: customHeaders,
            customBody: customBody
        )
    }
}
