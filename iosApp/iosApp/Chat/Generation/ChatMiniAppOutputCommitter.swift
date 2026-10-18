import Foundation
import CryptoKit
import Observation
import OSLog
import SwiftUI
@preconcurrency import Shared

extension ChatViewModel {

    func applyMiniAppOutputIfPresentPublic(
        to messages: [UIMessage],
        conversationId: KotlinUuid?
    ) -> ChatMiniAppOutputApplication? {
        applyMiniAppOutputIfPresent(to: messages, conversationId: conversationId)
    }

    /// Returns a full replaced message list when MiniApp output is applied; nil means unchanged.
    private func applyMiniAppOutputIfPresent(
        to messages: [UIMessage],
        conversationId: KotlinUuid?
    ) -> ChatMiniAppOutputApplication? {
        guard isMiniAppRuntimeEnabled else { return nil }
        guard let turn = ChatRuntimeContextBuilder.miniAppTurnContext(in: messages) else {
            return nil
        }
        let currentTurn = messages.index(after: turn.currentUserIndex)..<messages.endIndex
        guard !messages[currentTurn].contains(where: { message in
            message.role == MessageRole.assistant && message.parts.contains { $0 is UIMessagePart.MiniApp }
        }) else {
            return nil
        }
        guard let assistantIndex = IOSMiniAppChatMessageFactory.assistantCandidateIndex(
                in: messages,
                afterUserIndex: turn.currentUserIndex
              ) ?? messages[currentTurn].lastIndex(where: { $0.role == MessageRole.assistant }) else {
            return nil
        }
        let assistant = messages[assistantIndex]
        guard let textPartIndex = assistant.parts.lastIndex(where: { $0 is UIMessagePart.Text }),
              let textPart = assistant.parts[textPartIndex] as? UIMessagePart.Text else {
            return nil
        }
        let userText = turn.requestText
        guard IOSMiniAppChatMessageFactory.mightContainMiniApp(textPart.text) else {
            if let targetAppId = ChatRuntimeContextBuilder.revisionAppId(in: userText) {
                let current = miniAppRepository.get(targetAppId)
                let requestedVersion = ChatRuntimeContextBuilder.revisionVersion(in: userText)
                if current == nil || requestedVersion.map({ $0 != current?.version }) == true {
                    // The injected revision instruction explicitly asks for a short
                    // explanation (and no JSON) when the target is missing or stale.
                    return nil
                }
            }
            var updated = messages
            updated[assistantIndex] = IOSMiniAppChatMessageFactory.parseFailureAssistant(
                assistant,
                textPartIndex: textPartIndex,
                reason: IOSAppLocalization.string(
                    "模型没有返回完整的 MiniApp JSON 或 HTML。请重试，或调高最大输出长度后重新生成。",
                    defaultValue: "模型没有返回完整的 MiniApp JSON 或 HTML。请重试，或调高最大输出长度后重新生成。"
                )
            )
            return ChatMiniAppOutputApplication(messages: updated, outcome: .failed)
        }

        let parser = IOSMiniAppOutputParser()
        let output: IOSMiniAppGeneratedOutput
        do {
            output = try parser.parse(textPart.text)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var updated = messages
            updated[assistantIndex] = IOSMiniAppChatMessageFactory.parseFailureAssistant(
                assistant,
                textPartIndex: textPartIndex,
                reason: reason
            )
            return ChatMiniAppOutputApplication(messages: updated, outcome: .failed)
        }

        let sourceConversationId = conversationId.map { String(describing: $0) }
        let sourceMessageId = String(describing: assistant.id)
        let revisionAppId = ChatRuntimeContextBuilder.revisionAppId(in: userText)

        do {
            let mutation: IOSMiniAppRepository.Mutation
            if let targetAppId = revisionAppId {
                guard let revision = try miniAppRepository.saveRevisionMutation(
                    appId: targetAppId,
                    output: output,
                    expectedBaseVersion: ChatRuntimeContextBuilder.revisionVersion(in: userText),
                    sourceMessageId: sourceMessageId,
                    changeNote: IOSMiniAppChatMessageFactory.revisionChangeNote(from: userText)
                ) else {
                    var updated = messages
                    updated[assistantIndex] = IOSMiniAppChatMessageFactory.revisionFailedAssistant(
                        assistant,
                        textPartIndex: textPartIndex
                    )
                    return ChatMiniAppOutputApplication(messages: updated, outcome: .failed)
                }
                mutation = revision
            } else {
                mutation = try miniAppRepository.saveGeneratedMutation(
                    output,
                    sourceConversationId: sourceConversationId,
                    sourceMessageId: sourceMessageId
                )
            }
            let record = mutation.record
            let statusText = revisionAppId != nil
                ? IOSAppLocalization.formatted(
                    "已更新小应用：%@ v%lld",
                    defaultValue: "已更新小应用：%@ v%lld",
                    arguments: [record.title, Int64(record.version)]
                )
                : IOSAppLocalization.formatted(
                    "已生成小应用：%@",
                    defaultValue: "已生成小应用：%@",
                    arguments: [record.title]
                )
            var updated = messages
            updated[assistantIndex] = IOSMiniAppChatMessageFactory.updatedAssistant(
                assistant,
                textPartIndex: textPartIndex,
                statusText: statusText,
                record: record
            )
            var rollbackMessages = messages
            rollbackMessages[assistantIndex] = IOSMiniAppChatMessageFactory.parseFailureAssistant(
                assistant,
                textPartIndex: textPartIndex,
                reason: IOSAppLocalization.string(
                    "会话保存失败，因此此次小应用生成未保留。请检查存储空间后重试。",
                    defaultValue: "会话保存失败，因此此次小应用生成未保留。请检查存储空间后重试。"
                )
            )
            return ChatMiniAppOutputApplication(
                messages: updated,
                rollbackMessages: rollbackMessages,
                resultTitle: record.title,
                commit: { [miniAppRepository, mutation] in
                    do {
                        return try miniAppRepository.commit(mutation)
                    } catch {
                        NSLog("[AmberChat] Failed to commit MiniApp transaction: \(error)")
                        return false
                    }
                },
                rollback: { [miniAppRepository, mutation] in
                    do {
                        return try miniAppRepository.rollback(mutation)
                    } catch {
                        NSLog("[AmberChat] Failed to roll back MiniApp mutation: \(error)")
                        return false
                    }
                },
                syncWorkspace: { [workspaceStore, updated, assistant, assistantIndex, textPartIndex, statusText, record] in
                    do {
                        _ = try workspaceStore.saveArtifact(
                            title: record.title,
                            content: record.htmlContent,
                            type: .miniApp,
                            sourceKind: "miniapp",
                            sourceId: record.id
                        )
                        return nil
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        var failedMessages = updated
                        failedMessages[assistantIndex] = IOSMiniAppChatMessageFactory.updatedAssistant(
                            assistant,
                            textPartIndex: textPartIndex,
                            statusText: statusText + "\n" + IOSAppLocalization.formatted(
                                "Workspace 同步失败：%@",
                                defaultValue: "Workspace 同步失败：%@",
                                arguments: [message]
                            ),
                            record: record
                        )
                        return ChatMiniAppWorkspaceSyncFailure(
                            messages: failedMessages,
                            replacementMessage: failedMessages[assistantIndex]
                        )
                    }
                }
            )
        } catch IOSMiniAppStoreError.notFound {
            var updated = messages
            updated[assistantIndex] = IOSMiniAppChatMessageFactory.revisionFailedAssistant(
                assistant,
                textPartIndex: textPartIndex
            )
            return ChatMiniAppOutputApplication(messages: updated, outcome: .failed)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var updated = messages
            updated[assistantIndex] = IOSMiniAppChatMessageFactory.parseFailureAssistant(
                assistant,
                textPartIndex: textPartIndex,
                reason: reason
            )
            return ChatMiniAppOutputApplication(messages: updated, outcome: .failed)
        }
    }

}
