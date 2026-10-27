import Foundation
@preconcurrency import Shared

@MainActor final class DesktopKMPConversationStorage: DesktopConversationStorage {
    private let repository: DesktopConversationRepository

    init(directory: URL) {
        repository = DesktopConversationRepository(directory: directory.path)
    }

    func loadAll() async throws -> [DesktopConversation] {
        try DesktopJSON.decode([DesktopConversation].self, from: await repository.loadAll())
    }

    func listSummaries() async throws -> [DesktopConversationSummary] {
        try DesktopJSON.decode([DesktopConversationSummary].self, from: await repository.listSummaries())
    }

    func search(_ query: String) async throws -> [DesktopConversationSearchResult] {
        try DesktopJSON.decode([DesktopStoredConversationSearchHit].self, from: await repository.search(query: query))
            .map { $0.presentation(query: query) }
    }

    func load(_ id: UUID) async throws -> DesktopConversation? {
        guard let json = try await repository.load(id: id.uuidString) else { return nil }
        return try DesktopJSON.decode(DesktopConversation.self, from: json)
    }

    func save(_ conversation: DesktopConversation) async throws -> DesktopConversation {
        try DesktopJSON.decode(DesktopConversation.self,
            from: await repository.save(json: DesktopJSON.encode(conversation)))
    }

    func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws {
        try await repository.updateMetadata(id: id.uuidString,
            title: title, pinned: isPinned.map { KotlinBoolean(bool: $0) })
    }

    func normalizeImport(_ document: String) async throws -> DesktopConversation {
        try DesktopJSON.decode(DesktopConversation.self, from: await repository.normalizeImport(document: document))
    }

    func remapMemoryCitations(_ conversation: DesktopConversation, mapping: [Int: Int]) async throws -> DesktopConversation {
        let values = Dictionary(uniqueKeysWithValues: mapping.map { (String($0.key), $0.value) })
        return try DesktopJSON.decode(DesktopConversation.self, from: await repository.remapMemoryCitations(
            json: DesktopJSON.encode(conversation), mappingJSON: DesktopJSON.encode(values)))
    }

    func exportDocument(_ conversation: DesktopConversation) async throws -> String {
        try await repository.exportDocument(json: DesktopJSON.encode(conversation))
    }

    func regenerate(_ conversation: DesktopConversation, messageID: UUID, responseID: UUID) async throws -> DesktopConversation {
        try DesktopJSON.decode(DesktopConversation.self, from: await repository.regenerate(
            json: DesktopJSON.encode(conversation), messageId: messageID.uuidString, responseId: responseID.uuidString))
    }

    func editMessage(_ conversation: DesktopConversation, messageID: UUID, textPartIndex: Int, text: String, responseID: UUID) async throws -> DesktopConversation {
        try DesktopJSON.decode(DesktopConversation.self, from: await repository.editMessage(
            json: DesktopJSON.encode(conversation), messageId: messageID.uuidString,
            textPartIndex: Int32(textPartIndex), text: text, responseId: responseID.uuidString))
    }

    func deleteMessage(_ conversation: DesktopConversation, messageID: UUID) async throws -> DesktopConversation {
        try DesktopJSON.decode(DesktopConversation.self, from: await repository.deleteMessage(
            json: DesktopJSON.encode(conversation), messageId: messageID.uuidString))
    }

    func selectVariant(_ conversation: DesktopConversation, messageID: UUID, variantID: UUID) async throws -> DesktopConversation {
        try DesktopJSON.decode(DesktopConversation.self, from: await repository.selectVariant(
            json: DesktopJSON.encode(conversation), messageId: messageID.uuidString, variantId: variantID.uuidString))
    }

    func delete(_ id: UUID) async throws { try await repository.delete(id: id.uuidString) }
}

