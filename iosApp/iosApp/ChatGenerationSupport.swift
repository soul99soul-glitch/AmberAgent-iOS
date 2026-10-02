import CryptoKit
import Foundation
@preconcurrency import Shared
import UIKit

// Shared chat policies and value types consumed by the foreground Host,
// background coordinator, Council, and Novel flows.

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
    /// baseMessages 不含真实对话时（嵌套 exec 的合成消息）由调用方提供最近的用户消息。
    var recentUserTexts: [String]? = nil
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
    /// Exact title from the committed `IOSMiniAppRecord`; never inferred from
    /// the assistant's status text or arbitrary response content.
    let resultTitle: String?
    private let commitHandler: (@MainActor () -> Bool)?
    private let rollbackHandler: (@MainActor () -> Bool)?
    private let workspaceSyncHandler: (@MainActor () -> ChatMiniAppWorkspaceSyncFailure?)?

    init(
        messages: [UIMessage],
        rollbackMessages: [UIMessage]? = nil,
        outcome: Outcome = .applied,
        resultTitle: String? = nil,
        commit: (@MainActor () -> Bool)? = nil,
        rollback: (@MainActor () -> Bool)? = nil,
        syncWorkspace: (@MainActor () -> ChatMiniAppWorkspaceSyncFailure?)? = nil
    ) {
        self.messages = messages
        self.rollbackMessages = rollbackMessages ?? messages
        self.outcome = outcome
        self.resultTitle = resultTitle
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
    /// 第三个参数为 Jev 统一选中集合（本轮一次计算），注入与 usage marking 共用。
    var messagesByInjectingRuntimeContextForRun: (([UIMessage], Bool, ChatMemoryContextBuilder.RecallResult?) -> [UIMessage])? = nil
    var prepareImageAttachments: @MainActor ([UIMessage], Model, Settings, KotlinUuid?) async throws -> [UIMessage] = {
        messages, _, _, _ in messages
    }
    let userFacingGenerationError: (String, String?) -> String
    /// 第二个参数为 Jev 统一选中集合（本轮一次计算），与注入共用同一份。
    var memoryRecordIdsForRuntimeContext: ([UIMessage], ChatMemoryContextBuilder.RecallResult?) -> [Int32] = { _, _ in [] }
    /// Jev Phase 1: 每轮上传准备时计算记忆统一选中集合（active 应用 / shadow
    /// 后台观测 / off 零操作）。返回值由调用方显式传给注入与 usage marking，
    /// 禁止各自再算一次。第二参数为 runId（轮次预算/并发归属）。
    var prepareJevMemoryRecall: @MainActor ([UIMessage], String?) async -> ChatMemoryContextBuilder.RecallResult? = { _, _ in nil }
    /// P3a：Jev 关闭/未命中时的兜底记忆召回结果——`prepareUploadMessages` 在
    /// 一次请求准备内只调用一次，把结果经既有 override 通道复用给基线注入、
    /// 最终注入与 usage marking，避免同一轮内对全部记忆重复打分三次。
    var memoryRecallResultForRun: ([UIMessage]) -> ChatMemoryContextBuilder.RecallResult = { _ in
        ChatMemoryContextBuilder.RecallResult(prompt: nil, records: [])
    }
    /// 第二个 Bool 为 P2-c 修复 2 的 force 标记：模型显式引用（citation flush）
    /// 传 true 绕过 P2-b 同集去抖；召回标记传 false。
    var recordMemoryUsage: @MainActor ([Int32], Bool) -> Void = { _, _ in }
    var generationSucceeded: @MainActor () -> Void = {}
    var scheduleMemoryExtraction: @MainActor (KotlinUuid, [UIMessage], [UIMessage]) -> Void = { _, _, _ in }
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
    /// （conversationId、runId、durable 状态、终态消息快照）。默认空实现零开销。
    var onForegroundYield: (String) -> Void = { _ in }
    var onRunTerminal: @MainActor (KotlinUuid?, String, AgentRunStatus, [UIMessage]) async -> Void = { _, _, _, _ in }
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
        return executor.permissionPolicy(capabilityId: "ios.mcp.tool_call") != .disabled
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
