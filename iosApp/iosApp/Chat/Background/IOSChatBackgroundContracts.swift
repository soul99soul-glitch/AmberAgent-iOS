@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

let backgroundRunLedgerLogger = Logger(subsystem: "app.amber.ios", category: "chat-bg-ledger")
let backgroundToolExposureLogger = Logger(subsystem: "app.amber.ios", category: "chat-bg-tools")
let backgroundMailboxLogger = Logger(subsystem: "app.amber.ios", category: "chat-bg-mailbox")

/// Mailbox messages may be observed by the terminal-resume bootstrap and by
/// the first round of the newly accepted background job. Derive their UI id
/// from the durable envelope id so that either observer can safely collapse
/// the same envelope instead of rendering it twice.
func amberStableMailboxMessageId(envelopeId: String) -> KotlinUuid {
    let digest = Array(chatInputDigest(for: "amber-mailbox-message:\(envelopeId)"))
    let uuidString = [
        String(digest[0..<8]),
        String(digest[8..<12]),
        String(digest[12..<16]),
        String(digest[16..<20]),
        String(digest[20..<32])
    ].joined(separator: "-")
    return KotlinUuid.companion.parse(uuidString: uuidString)
}

func amberMailboxMessage(
    envelopeId: String,
    authorThreadId: String,
    type: String,
    payload: String
) -> UIMessage {
    let rendered = IosMailboxMessageBridge.shared.makeMessage(
        authorThreadId: authorThreadId,
        type: type,
        payload: payload
    )
    return UIMessage(
        id: amberStableMailboxMessageId(envelopeId: envelopeId),
        role: rendered.role,
        parts: rendered.parts,
        annotations: rendered.annotations,
        createdAt: rendered.createdAt,
        finishedAt: rendered.finishedAt,
        modelId: rendered.modelId,
        usage: rendered.usage,
        translation: rendered.translation
    )
}

struct IOSChatBackgroundRuntimeJob {
    let runId: String
    let startedAt: Int64
    let inputDigest: String
    let conversationId: KotlinUuid
    let providerSetting: ProviderSetting
    let params: TextGenerationParams
    let uploadMessages: [UIMessage]
    let displayMessages: [UIMessage]
    let runDisplayBaseline: [UIMessage]
    let mode: IOSChatBackgroundHandoffMode
    let fullToolNames: [String]
    let dynamicToolSnapshot: IOSDynamicToolCatalogSnapshot?
    let responseId: String?
    let responseSequenceNumber: Int64?
    let generativeUiRequirement: IOSGenerativeUiRequirement
    let generativeUiFallbackAttempted: Bool
    let executionPolicy: IOSExecutionPolicySnapshot?
    let subAgentTimeoutSeconds: TimeInterval?
    let phoneAutomaticReasoning: Bool
    let conversationStore: IOSConversationStore
    let toolRuntime: ChatToolRuntime
    let liveActivityController: AgentLiveActivityController
    let saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
    let messagesSnapshot: IOSChatBackgroundMessagesSnapshot
    /// P0-a: background-owned tool exposure bridge (rebuilt from the handoff's
    /// visible declarations — the exposed set at handoff — since the persisted
    /// payload cannot carry Kotlin Tool lists). Powers the background
    /// `tool_search` executor.
    let toolExposureBridge: IosToolExposureBridge
}

/// KMP message objects are not declared `Sendable`, but this retry snapshot is
/// immutable after construction and the engine copies its array before mutation.
struct IOSChatBackgroundRetryMessages: @unchecked Sendable {
    let values: [UIMessage]
}

/// 后台续轮的逐轮窗口预算：交接后新增的工具结果 / mailbox 消息不断变长，每轮
/// 按模型窗口裁剪（带可见截断提示）并做超窗校验。这里不做摘要压缩：上传已是
/// 前台加工过的请求视图，拿它做摘要会用残缺内容永久替换原文。engine 的 working
/// 仍是权威，这里只改本轮上传。KMP 实体非 Sendable，装盒后在 MainActor 上执行。
struct IOSChatBackgroundUploadPreparer: @unchecked Sendable {
    let settings: Settings
    let params: TextGenerationParams

    func prepare(_ messages: [UIMessage]) async throws -> [UIMessage] {
        let inbox = IOSChatBackgroundRetryMessages(values: messages)
        return try await MainActor.run {
            IOSChatBackgroundRetryMessages(
                values: try IOSContextCompactionCoordinator.shared.finalizedMessagesForRequest(
                    IOSToolImageRequestBudget.apply(inbox.values),
                    settings: settings,
                    params: params
                )
            )
        }.values
    }
}

struct IOSChatBackgroundDependencies {
    let conversationStore: IOSConversationStore
    let toolRuntime: ChatToolRuntime
    let sharedSettings: IOSSharedSettingsStore
    let liveActivityController: AgentLiveActivityController
    let saveMiniAppIfPresent: (@MainActor ([UIMessage], KotlinUuid?) -> ChatMiniAppOutputApplication?)?
}

/// Composition created before SwiftUI/AppShell exists when a Watch request
/// cold-starts the process. AppShell can adopt this exact object graph once a
/// window appears, so the live kernel host and its stores have one owner.
struct IOSChatHeadlessComposition {
    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    let conversationStore: IOSConversationStore
    let permissionStore: IOSPermissionStore
    let documentStore: DocumentAccessStore
    let systemPermissionCoordinator: IOSSystemPermissionCoordinator
    let localToolExecutor: IOSLocalToolExecutor
    let chatViewModel: ChatViewModel
}

struct IOSChatBackgroundHandoff {
    let runId: String
    let startedAt: Int64
    let inputDigest: String
    let conversationId: KotlinUuid
    let providerId: String
    let providerSetting: ProviderSetting
    let params: TextGenerationParams
    let uploadMessages: [UIMessage]
    let displayMessages: [UIMessage]
    var mode: IOSChatBackgroundHandoffMode
    var responseId: String? = nil
    var responseSequenceNumber: Int64? = nil
    let generativeUiRequirement: IOSGenerativeUiRequirement
    let generativeUiFallbackAttempted: Bool
    /// P0-a Fix C: the FULL catalog tool names of the run (params.tools only
    /// carries the visible subset, which would silently disable lazy mode in
    /// the background bridge). Empty for legacy payloads → fall back to
    /// params.tools.
    let fullToolNames: [String]
    /// Process-local immutable descriptors. Durable rehydration intentionally
    /// drops them so a changed/deleted package cannot be retargeted by name.
    var dynamicToolSnapshot: IOSDynamicToolCatalogSnapshot? = nil
    var executionPolicy: IOSExecutionPolicySnapshot? = nil
    var subAgentTimeoutSeconds: TimeInterval? = nil
    /// Process-local eligibility only. Cold restoration cannot restore phone ownership.
    var phoneAutomaticReasoning: Bool = false
    /// Immutable conversation baseline for this run's merge and terminal report.
    /// Nil restores legacy payloads using their display checkpoint; an empty array is explicit.
    var runDisplayBaseline: [UIMessage]? = nil
}

enum IOSChatBackgroundHandoffMode: String {
    case continueModel = "continue_model"
    case singleToolOnly = "single_tool_only"
    case resumeResponse = "resume_response"
}

struct IOSChatBackgroundProvider: IOSAgentTextProvider, IOSAgentStreamingProvider {
    private let openAIProvider = OpenAIKmpProvider()
    private let claudeProvider = ClaudeKmpProvider()

    func supportsStreaming(providerSetting: ProviderSetting) -> Bool {
        !(providerSetting is ProviderSetting.Google)
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        if let openAI = providerSetting as? ProviderSetting.OpenAI {
            return try await openAIProvider.generateText(providerSetting: openAI, messages: messages, params: params)
        }
        if let claude = providerSetting as? ProviderSetting.Claude {
            return try await claudeProvider.generateText(providerSetting: claude, messages: messages, params: params)
        }
        if providerSetting is ProviderSetting.Google {
            return try await OpenAIKmpProviderAdapter().generateText(
                providerSetting: providerSetting, messages: messages, params: params
            )
        }
        throw NSError(
            domain: "AmberAgent.ChatBackgroundGeneration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: IOSAppLocalization.string(
                "当前服务商类型暂不支持后台生成",
                defaultValue: "当前服务商类型暂不支持后台生成"
            )]
        )
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping @Sendable (MessageChunk) -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        if let openAI = providerSetting as? ProviderSetting.OpenAI {
            return openAIProvider.streamTextCancellable(
                providerSetting: openAI,
                messages: messages,
                params: params,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError
            )
        }
        if let claude = providerSetting as? ProviderSetting.Claude {
            return claudeProvider.streamTextCancellable(
                providerSetting: claude,
                messages: messages,
                params: params,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError
            )
        }
        onError(KotlinThrowable(message: IOSAppLocalization.string(
            "当前服务商类型暂不支持后台生成",
            defaultValue: "当前服务商类型暂不支持后台生成"
        )))
        return nil
    }
}

struct IOSChatBackgroundJobTerminalEvent: Equatable, Sendable {
    let conversationId: String
}

struct IOSChatBackgroundJobStateEvent: Equatable, Sendable {
    let conversationId: String
}

extension Notification.Name {
    static let amberChatBackgroundJobDidTerminate = Notification.Name(
        "app.amber.ios.chat.backgroundJobDidTerminate"
    )
    static let amberChatBackgroundJobStateDidChange = Notification.Name(
        "app.amber.ios.chat.backgroundJobStateDidChange"
    )
}

