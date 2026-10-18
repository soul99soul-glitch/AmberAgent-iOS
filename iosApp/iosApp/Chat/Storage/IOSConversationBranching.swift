import Foundation
@preconcurrency import Shared

extension IOSConversationStore {
    static var messageMutationPendingMessage: String {
        IOSAppLocalization.string("正在保存消息更改，请稍后重试。", defaultValue: "正在保存消息更改，请稍后重试。")
    }

    func isMessageMutationInProgress(for id: KotlinUuid) -> Bool {
        branchMutationConversationIDs.contains(id.toHexDashString())
    }

    private func publishMessageMutationBusy() {
        publishUserVisibleError(IOSUserVisibleError(
            title: "消息更改尚未完成",
            message: Self.messageMutationPendingMessage,
            severity: .info
        ))
    }

    // A branch owns its read, snapshot write and current-state publication. Reject
    // competing user actions so an old numeric index is never queued for replay.
    private func beginBranchMutation(for id: KotlinUuid) -> Bool {
        let key = id.toHexDashString()
        guard !branchMutationConversationIDs.contains(key), messageSnapshotWriteCounts[key, default: 0] == 0 else {
            publishMessageMutationBusy()
            return false
        }
        branchMutationConversationIDs.insert(key)
        return true
    }

    private func finishBranchMutation(for id: KotlinUuid) {
        branchMutationConversationIDs.remove(id.toHexDashString())
    }

    func beginMessageSnapshotWrite(to id: KotlinUuid, ownsBranchMutation: Bool = false) -> Bool {
        let key = id.toHexDashString()
        guard branchMutationConversationIDs.contains(key) == ownsBranchMutation else {
            publishMessageMutationBusy()
            return false
        }
        messageSnapshotWriteCounts[key, default: 0] += 1
        return true
    }

    func finishMessageSnapshotWrite(to id: KotlinUuid) {
        let key = id.toHexDashString()
        if messageSnapshotWriteCounts[key] == 1 {
            messageSnapshotWriteCounts.removeValue(forKey: key)
        } else {
            messageSnapshotWriteCounts[key, default: 0] -= 1
        }
    }

    // MARK: - Message branching (Android ChatService parity)
    //
    // The KMP `Conversation` already carries a `List<MessageNode>` tree where
    // each node holds sibling `UIMessage` variants + a `selectIndex`. iOS loads
    // and persists this tree today; it just never creates or navigates
    // branches. These operations mirror Android's `ChatService` semantics
    // (selectMessageNode / editMessage / regenerateAtMessage / deleteMessage):
    //
    //   - flat message index == node index (currentMessages = messageNodes.map
    //     { node.messages[selectIndex] }), so callers address a branch by the
    //     index of the message it shows in the flat chat list.
    //   - edit/regenerate = APPEND a new variant to the node + select it (the
    //     original is retained and reachable via selectVariant).
    //   - delete = remove the message from its node; drop the node if it
    //     becomes empty.

    /// Variant info for a node, exposed so the UI can show `< 2/3 >` only when
    /// a node actually carries more than one sibling.
    struct VariantInfo: Equatable {
        let variantCount: Int
        let selectedIndex: Int
        var hasMultipleVariants: Bool { variantCount > 1 }
    }

    func variantInfo(forMessageIndex index: Int) -> VariantInfo? {
        guard let conversation = currentConversation,
              index >= 0, index < conversation.messageNodes.count else {
            return nil
        }
        let node = conversation.messageNodes[index]
        // selectIndex bridges as Int32 (Kotlin Int → Obj-C Int32).
        return VariantInfo(variantCount: node.messages.count, selectedIndex: Int(node.selectIndex))
    }

    /// Loads the conversation that a branch action was started for. The caller
    /// may switch conversations while file I/O is suspended, so branch actions
    /// must never re-read the mutable current selection after their first await.
    func conversationForMessageMutation(
        id: KotlinUuid,
        operation: String
    ) async -> Conversation? {
        guard !isDeletedConversation(id) else { return nil }
        if currentConversation?.id == id {
            return currentConversation
        }
        do {
            return try await storage.loadConversation(id: id)
        } catch {
            publishIOError(operation: operation, detail: "\(id): \(error)")
            return nil
        }
    }

    /// Switch the selected variant of a node (cheap, no generation). Mirrors
    /// `ChatService.selectMessageNode`.
    @discardableResult
    func selectVariant(
        messageIndex: Int,
        variantIndex: Int,
        conversationId: KotlinUuid? = nil
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        guard let targetConversationId = conversationId ?? currentConversation?.id,
              beginBranchMutation(for: targetConversationId) else { return false }
        defer { finishBranchMutation(for: targetConversationId) }
        guard acceptsImportEpoch(operationImportEpoch),
              let conversation = await conversationForMessageMutation(
                  id: targetConversationId,
                  operation: "切换消息分支"
              ),
              acceptsImportEpoch(operationImportEpoch),
              messageIndex >= 0, messageIndex < conversation.messageNodes.count else {
            return false
        }
        var nodes = conversation.messageNodes
        let node = nodes[messageIndex]
        guard variantIndex >= 0, variantIndex < node.messages.count, variantIndex != node.selectIndex else {
            return false
        }
        nodes[messageIndex] = MessageNode(
            id: node.id,
            messages: node.messages,
            selectIndex: Int32(variantIndex),
            isFavorite: node.isFavorite
        )
        let updated = conversationWithNodes(conversation, nodes: nodes)
        guard let persisted = await persist(
            updated,
            expectedImportEpoch: operationImportEpoch,
            ownsBranchMutation: true
        ) else { return false }
        if currentConversation?.id == targetConversationId {
            setCurrent(persisted)
        }
        return true
    }

    /// Append a new variant to a node and select it. This is the shared
    /// primitive for edit-message and regenerate-assistant. Mirrors
    /// `ChatService.editMessage` / the append path of `mergeGeneratedMessagesByIndex`.
    /// Returns the node index so the caller (e.g. ChatViewModel) can target
    /// generation at it.
    @discardableResult
    func appendVariant(
        messageIndex: Int,
        message: UIMessage,
        conversationId: KotlinUuid? = nil
    ) async -> Int? {
        let operationImportEpoch = importEpoch
        guard let targetConversationId = conversationId ?? currentConversation?.id,
              beginBranchMutation(for: targetConversationId) else { return nil }
        defer { finishBranchMutation(for: targetConversationId) }
        guard acceptsImportEpoch(operationImportEpoch),
              let conversation = await conversationForMessageMutation(
                  id: targetConversationId,
                  operation: "保存消息分支"
              ),
              acceptsImportEpoch(operationImportEpoch),
              messageIndex >= 0, messageIndex < conversation.messageNodes.count else {
            return nil
        }
        var nodes = conversation.messageNodes
        let node = nodes[messageIndex]
        var newMessages = node.messages
        newMessages.append(message)
        // Kotlin List bridges to NSArray-ish; use count-1 instead of lastIndex
        // to avoid ambiguity. selectIndex is Int32 (Kotlin Int → Obj-C Int32).
        nodes[messageIndex] = MessageNode(
            id: node.id,
            messages: newMessages,
            selectIndex: Int32(newMessages.count - 1),
            isFavorite: node.isFavorite
        )
        let updated = conversationWithNodes(conversation, nodes: nodes)
        guard let persisted = await persist(
            updated,
            expectedImportEpoch: operationImportEpoch,
            ownsBranchMutation: true
        ) else { return nil }
        if currentConversation?.id == targetConversationId {
            setCurrent(persisted)
        }
        return messageIndex
    }

    /// Append an assistant regeneration as a sibling variant of the original
    /// assistant node, select it, and drop stale nodes after that reply.
    @discardableResult
    func appendVariantAndTruncateAfter(
        messageIndex: Int,
        message: UIMessage,
        trailingMessages: [UIMessage] = [],
        conversationId: KotlinUuid
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        guard beginBranchMutation(for: conversationId) else { return false }
        defer { finishBranchMutation(for: conversationId) }
        guard let conversation = await conversationForMessageMutation(
            id: conversationId,
            operation: "保存重新生成分支"
        ),
              acceptsImportEpoch(operationImportEpoch),
              messageIndex >= 0,
              messageIndex < conversation.messageNodes.count else {
            return false
        }
        var nodes = Array(conversation.messageNodes.prefix(messageIndex + 1))
        let node = nodes[messageIndex]
        var variants = node.messages
        variants.append(message)
        nodes[messageIndex] = MessageNode(
            id: node.id,
            messages: variants,
            selectIndex: Int32(variants.count - 1),
            isFavorite: node.isFavorite
        )
        nodes.append(contentsOf: trailingMessages.map { trailingMessage in
            MessageNode(
                id: KotlinUuid.companion.random(),
                messages: [trailingMessage],
                selectIndex: 0,
                isFavorite: false
            )
        })
        let updated = conversationWithNodes(conversation, nodes: nodes)
        guard let persisted = await persist(
            updated,
            expectedImportEpoch: operationImportEpoch,
            ownsBranchMutation: true
        ) else { return false }
        if currentConversation?.id == conversationId {
            setCurrent(persisted)
        }
        await refreshSummaries()
        return acceptsImportEpoch(operationImportEpoch)
    }

    /// Remove a message from its node. If the node becomes empty it is removed
    /// (and selectIndex clamped). Mirrors `ChatService.deleteMessage`.
    @discardableResult
    func deleteMessage(
        messageIndex: Int,
        conversationId: KotlinUuid? = nil
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        guard let targetConversationId = conversationId ?? currentConversation?.id,
              beginBranchMutation(for: targetConversationId) else { return false }
        defer { finishBranchMutation(for: targetConversationId) }
        guard acceptsImportEpoch(operationImportEpoch),
              let conversation = await conversationForMessageMutation(
                  id: targetConversationId,
                  operation: "删除消息"
              ),
              acceptsImportEpoch(operationImportEpoch),
              messageIndex >= 0, messageIndex < conversation.messageNodes.count else {
            return false
        }
        var nodes = conversation.messageNodes
        // A node only ever holds the currently-selected variant for deletion
        // purposes on iOS (the flat list shows the selected variant); drop the
        // whole node. If we later support per-variant delete, this is where the
        // `node.messages.remove(at:)` + clamp logic would go.
        nodes.remove(at: messageIndex)
        let updated = conversationWithNodes(conversation, nodes: nodes)
        guard let persisted = await persist(
            updated,
            expectedImportEpoch: operationImportEpoch,
            ownsBranchMutation: true
        ) else { return false }
        if currentConversation?.id == targetConversationId {
            setCurrent(persisted)
        }
        await refreshSummaries()
        return acceptsImportEpoch(operationImportEpoch)
    }

    /// Truncate the conversation to end at (and include) the given node index.
    /// Used by regenerate-from-USER-message: Android drops everything after the
    /// user turn, then re-runs generation. Mirrors `ChatService.regenerateAtMessage`
    /// (role == USER branch).
    @discardableResult
    func truncateAfter(
        messageIndex: Int,
        conversationId: KotlinUuid? = nil
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        guard let targetConversationId = conversationId ?? currentConversation?.id,
              beginBranchMutation(for: targetConversationId) else { return false }
        defer { finishBranchMutation(for: targetConversationId) }
        guard acceptsImportEpoch(operationImportEpoch),
              let conversation = await conversationForMessageMutation(
                  id: targetConversationId,
                  operation: "截断消息分支"
              ),
              acceptsImportEpoch(operationImportEpoch),
              messageIndex >= 0, messageIndex < conversation.messageNodes.count else {
            return false
        }
        let kept = Array(conversation.messageNodes.prefix(messageIndex + 1))
        guard kept.count != conversation.messageNodes.count else { return false }
        let updated = conversationWithNodes(conversation, nodes: kept)
        guard let persisted = await persist(
            updated,
            expectedImportEpoch: operationImportEpoch,
            ownsBranchMutation: true
        ) else { return false }
        if currentConversation?.id == targetConversationId {
            setCurrent(persisted)
        }
        return true
    }

    /// Rebuild a Conversation with a different `messageNodes` list (full-field
    /// constructor, same pattern as `retitledCopy`). updateAt refreshed.
    func conversationWithNodes(_ conversation: Conversation, nodes: [MessageNode]) -> Conversation {
        Conversation(
            id: conversation.id,
            assistantId: conversation.assistantId,
            title: conversation.title,
            messageNodes: nodes,
            chatSuggestions: conversation.chatSuggestions,
            isPinned: conversation.isPinned,
            autoApproveToolCalls: conversation.autoApproveToolCalls,
            memoryMode: conversation.memoryMode,
            createAt: conversation.createAt,
            updateAt: nowInstant(),
            newConversation: conversation.newConversation
        )
    }

}
