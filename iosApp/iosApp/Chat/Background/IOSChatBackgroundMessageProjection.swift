@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit
@preconcurrency import Shared

@MainActor
extension IOSChatBackgroundGenerationCoordinator {
    /// P1-d: 后台 job 的 mailbox drain（引擎每轮批量执行后调用）。Room drain
    /// （事务化 exactly-once）+ 渲染 + 会话持久化全部在 MainActor 内完成；
    /// 返回渲染出的 user 消息（@unchecked Sendable 盒，KMP UIMessage 非
    /// Sendable 不外传）。无信封时返回空盒（引擎零追加）。
    func drainMailboxForBackgroundJob(
        store: IOSConversationStore,
        mailboxStore: IOSMailboxStore,
        conversationId: KotlinUuid
    ) async -> IOSMailboxDrainResult {
        let snapshots = await mailboxStore.drainPending(forConversationId: conversationId)
        guard !snapshots.isEmpty else { return IOSMailboxDrainResult(values: []) }
        let drained = snapshots.map { envelope in
            amberMailboxMessage(
                envelopeId: envelope.id,
                authorThreadId: envelope.authorThreadId,
                type: envelope.type,
                payload: envelope.payload
            )
        }
        // 持久化：会话既有消息 + 渲染信封（复用既有写路径与 operationMutex，
        // 不在 Swift 侧另建写通道；drain 事务保证信封不会重复落盘）。
        let current: [UIMessage]
        if store.currentConversation?.id == conversationId {
            current = store.currentConversation?.currentMessages ?? []
        } else {
            current = (try? await store.loadConversationForOrchestration(conversationId))?.currentMessages ?? []
        }
        // `resumePendingTasks` writes the same stable envelope message before
        // accepting the new BG task. If that task starts quickly enough to
        // drain the still-pending Room row before the post-accept ack, the
        // transaction has already claimed it; avoid adding a second copy.
        let existingIds = Set(current.map { $0.id.toHexDashString().lowercased() })
        let uniqueDrained = drained.filter {
            !existingIds.contains($0.id.toHexDashString().lowercased())
        }
        guard !uniqueDrained.isEmpty else {
            return IOSMailboxDrainResult(values: [])
        }
        let baseline = store.writeBaseline(for: conversationId)
        let persisted = await store.save(messages: current + uniqueDrained, to: conversationId, ifUnchangedSince: baseline)
        if !persisted {
            // 信封已标 delivered，持久化失败时由终态 persist（working 含 drained）兜底；
            // 只记录日志便于诊断，不回滚 drain（会丢投递记录）。
            backgroundMailboxLogger.error(
                "mailbox drain persist failed for \(conversationId) — terminal persist is the fallback"
            )
        }
        return IOSMailboxDrainResult(values: uniqueDrained)
    }

    static func assistantMessage(_ text: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: text, metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    private static func assistantErrorMessage(_ text: String) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [MessageKt.localGenerationErrorTextPart(text: text)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    static func resumePresentationStage(
        for chunk: MessageChunk
    ) -> AgentActivityStage? {
        var hasReasoningDelta = false
        var hasTextDelta = false
        for choice in chunk.choices {
            let parts = choice.delta?.parts ?? choice.message?.parts ?? []
            hasReasoningDelta = hasReasoningDelta || parts.contains { part in
                guard let reasoning = part as? UIMessagePart.Reasoning else { return false }
                return !reasoning.reasoning.isEmpty
            }
            hasTextDelta = hasTextDelta || parts.contains { part in
                guard let text = part as? UIMessagePart.Text else { return false }
                return !text.text.isEmpty
            }
        }
        return AgentActivityResponseStagePolicy.updatedStage(
            hasReasoningDelta: hasReasoningDelta,
            hasTextDelta: hasTextDelta
        )
    }

    static func failedMessages(
        displayMessages: [UIMessage],
        preservedGeneratedSuffix: [UIMessage] = [],
        partialAssistantText: String?,
        rawMessage: String,
        modelId: String
    ) -> [UIMessage] {
        var finalMessages = displayMessages + preservedGeneratedSuffix
        let partial = partialAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = ChatViewModel.userFacingGenerationError(rawMessage, modelId: modelId)
        if partial.isEmpty {
            finalMessages.append(assistantErrorMessage(errorText))
        } else {
            finalMessages.append(assistantErrorMessage("\(partial)\n\n\(errorText)"))
        }
        return finalMessages
    }

    static func reconciledDisplayPrefix(
        resultMessages: [UIMessage],
        uploadMessageCount: Int,
        displayMessages: [UIMessage]
    ) -> [UIMessage] {
        var completedTools: [String: UIMessagePart.Tool] = [:]
        for message in resultMessages.prefix(uploadMessageCount)
            where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts where !tool.output.isEmpty {
                completedTools[chatToolCallKey(tool)] = tool
            }
        }
        guard !completedTools.isEmpty else { return displayMessages }

        return displayMessages.map { message in
            guard message.role == MessageRole.assistant else { return message }
            var didChange = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard let tool = part as? UIMessagePart.Tool,
                      tool.output.isEmpty,
                      let completed = completedTools[chatToolCallKey(tool)] else {
                    return part
                }
                didChange = true
                return completed
            }
            guard didChange else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    static func reconciledMessages(
        resultMessages: [UIMessage],
        uploadMessageCount: Int,
        displayMessages: [UIMessage]
    ) -> [UIMessage] {
        reconciledDisplayPrefix(
            resultMessages: resultMessages,
            uploadMessageCount: uploadMessageCount,
            displayMessages: displayMessages
        ) + Array(resultMessages.dropFirst(uploadMessageCount))
    }

}
