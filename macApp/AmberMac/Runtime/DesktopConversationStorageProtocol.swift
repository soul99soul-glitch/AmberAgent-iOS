import Foundation

@MainActor protocol DesktopConversationStorage {
    func loadAll() async throws -> [DesktopConversation]
    func listSummaries() async throws -> [DesktopConversationSummary]
    func search(_ query: String) async throws -> [DesktopConversationSearchResult]
    func load(_ id: UUID) async throws -> DesktopConversation?
    func save(_ conversation: DesktopConversation) async throws -> DesktopConversation
    func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws
    func normalizeImport(_ document: String) async throws -> DesktopConversation
    func remapMemoryCitations(_ conversation: DesktopConversation, mapping: [Int: Int]) async throws -> DesktopConversation
    func exportDocument(_ conversation: DesktopConversation) async throws -> String
    func regenerate(_ conversation: DesktopConversation, messageID: UUID, responseID: UUID) async throws -> DesktopConversation
    func editMessage(_ conversation: DesktopConversation, messageID: UUID, textPartIndex: Int, text: String, responseID: UUID) async throws -> DesktopConversation
    func deleteMessage(_ conversation: DesktopConversation, messageID: UUID) async throws -> DesktopConversation
    func selectVariant(_ conversation: DesktopConversation, messageID: UUID, variantID: UUID) async throws -> DesktopConversation
    func delete(_ id: UUID) async throws
}

extension DesktopConversationStorage {
    func listSummaries() async throws -> [DesktopConversationSummary] {
        DesktopConversationSummary.ordered(try await loadAll().map(DesktopConversationSummary.init))
    }

    func search(_ query: String) async throws -> [DesktopConversationSearchResult] {
        Array(DesktopConversationPresentation.search(try await loadAll(), query: query).prefix(200))
    }

    func load(_ id: UUID) async throws -> DesktopConversation? {
        try await loadAll().first { $0.id == id }
    }

    func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {
        throw DesktopRuntimeError.message("当前存储不支持更新会话信息。")
    }

    func normalizeImport(_ document: String) async throws -> DesktopConversation {
        let exported = try DesktopJSON.decode(DesktopConversationExport.self, from: document)
        guard exported.format == "amber.mac.conversation.v1" else {
            throw DesktopRuntimeError.message("界面预览仅支持旧版会话导入。")
        }
        return exported.conversation
    }

    func remapMemoryCitations(_ conversation: DesktopConversation, mapping: [Int: Int]) async throws -> DesktopConversation {
        func hasCitations(_ text: String?) -> Bool {
            text?.contains("amber_memory_record_ids") == true || text?.contains("<amber-mem-cite>") == true
        }
        guard !hasCitations(conversation.canonicalJSON), !conversation.messages.contains(where: {
            hasCitations($0.canonicalJSON) || $0.text.contains("<amber-mem-cite>")
        }) else {
            throw DesktopRuntimeError.message("此备份含结构化记忆引用，请使用连接 Shared 的正式版恢复。")
        }
        return conversation
    }

    func exportDocument(_ conversation: DesktopConversation) async throws -> String {
        try DesktopJSON.encode(DesktopConversationExport(conversation: conversation))
    }

    func regenerate(_ conversation: DesktopConversation, messageID: UUID, responseID: UUID) async throws -> DesktopConversation {
        throw DesktopRuntimeError.message("当前存储不支持消息分支。")
    }
    func editMessage(_ conversation: DesktopConversation, messageID: UUID, textPartIndex: Int, text: String, responseID: UUID) async throws -> DesktopConversation {
        throw DesktopRuntimeError.message("当前存储不支持消息分支。")
    }
    func deleteMessage(_ conversation: DesktopConversation, messageID: UUID) async throws -> DesktopConversation {
        throw DesktopRuntimeError.message("当前存储不支持消息分支。")
    }
    func selectVariant(_ conversation: DesktopConversation, messageID: UUID, variantID: UUID) async throws -> DesktopConversation {
        throw DesktopRuntimeError.message("当前存储不支持消息分支。")
    }
}

@MainActor final class DesktopMemoryConversationStorage: DesktopConversationStorage {
    var values: [DesktopConversation]
    private var candidates: [UUID: [UUID: DesktopMessage]] = [:]
    init(_ values: [DesktopConversation] = []) {
        self.values = values
        for value in values { remember(value) }
    }
    private func remember(_ conversation: DesktopConversation) {
        for message in conversation.messages { candidates[conversation.id, default: [:]][message.id] = message }
    }
    func loadAll() async throws -> [DesktopConversation] { values }
    func save(_ conversation: DesktopConversation) async throws -> DesktopConversation {
        var saved = conversation
        if let index = values.firstIndex(where: { $0.id == conversation.id }) {
            saved.title = values[index].title
            saved.isPinned = values[index].isPinned
            values[index] = saved
        } else { values.append(saved) }
        remember(saved)
        return saved
    }
    func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        if let title { values[index].title = title }
        if let isPinned { values[index].isPinned = isPinned }
    }
    func regenerate(_ conversation: DesktopConversation, messageID: UUID, responseID: UUID) async throws -> DesktopConversation {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }), conversation.messages[index].role == .assistant else {
            throw DesktopRuntimeError.message("找不到要重新生成的回复。")
        }
        guard conversation.messages.prefix(index).contains(where: { $0.role == .user }) else {
            throw DesktopRuntimeError.message("这条回复之前没有用户消息，无法重新生成。")
        }
        var updated = conversation
        let original = conversation.messages[index]
        let ids = original.variantIDs.isEmpty ? [original.id] : original.variantIDs
        let reply = DesktopMessage(id: responseID, role: .assistant, text: "", state: .streaming, variantIDs: ids + [responseID])
        updated.messages = Array(conversation.messages.prefix(index)) + [reply]
        updated.updatedAt = Date()
        return try await save(updated)
    }

    func editMessage(_ conversation: DesktopConversation, messageID: UUID, textPartIndex: Int, text: String, responseID: UUID) async throws -> DesktopConversation {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }), conversation.messages[index].role == .user else {
            throw DesktopRuntimeError.message("找不到要编辑的用户消息。")
        }
        var edited = conversation.messages[index]
        // Preview never rewrites opaque structured payloads; the live adapter uses the KMP part mutation.
        guard edited.canonicalJSON == nil else { throw DesktopRuntimeError.message("界面预览不支持编辑结构化消息，请在正式版使用此操作。") }
        let ids = edited.variantIDs.isEmpty ? [edited.id] : edited.variantIDs
        edited.id = UUID()
        edited.text = text
        edited.editableText = text
        edited.editableTextPartIndex = textPartIndex
        edited.estimatedTokens = nil
        edited.variantIDs = ids + [edited.id]
        var updated = conversation
        updated.messages = Array(conversation.messages.prefix(index)) + [edited,
            DesktopMessage(id: responseID, role: .assistant, text: "", state: .streaming)]
        updated.updatedAt = Date()
        return try await save(updated)
    }

    func deleteMessage(_ conversation: DesktopConversation, messageID: UUID) async throws -> DesktopConversation {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { throw DesktopRuntimeError.message("找不到要删除的消息。") }
        var updated = conversation
        updated.messages.remove(at: index)
        updated.updatedAt = Date()
        return try await save(updated)
    }

    func selectVariant(_ conversation: DesktopConversation, messageID: UUID, variantID: UUID) async throws -> DesktopConversation {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].variantIDs.contains(variantID),
              var selected = candidates[conversation.id]?[variantID] else { throw DesktopRuntimeError.message("找不到要切换的消息版本。") }
        selected.variantIDs = conversation.messages[index].variantIDs
        var updated = conversation
        updated.messages[index] = selected
        updated.updatedAt = Date()
        return try await save(updated)
    }

    func delete(_ id: UUID) async throws {
        values.removeAll { $0.id == id }
        candidates[id] = nil
    }
}
