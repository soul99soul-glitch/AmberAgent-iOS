import Foundation

struct ChatArtifactArrival: Equatable {
    let id: String
    let systemImage: String
}

struct ChatArtifactShelfState {
    private(set) var index = ConversationArtifactIndex(images: [], files: [], webPages: [])
    private(set) var arrival: ChatArtifactArrival?
    private var conversationID: String?
    private var hasLoaded = false

    mutating func update(
        _ next: ConversationArtifactIndex,
        conversationID: String?,
        isForegroundRunning: Bool,
        allowArrival: Bool
    ) {
        let previousIDs = Set(entries(index).map(\.id))
        if !hasLoaded || self.conversationID != conversationID || !allowArrival {
            arrival = nil
        } else if let added = entries(next).last(where: { !previousIDs.contains($0.id) }) {
            arrival = isForegroundRunning ? added : nil
        }
        index = next
        self.conversationID = conversationID
        hasLoaded = true
    }

    private func entries(_ index: ConversationArtifactIndex) -> [ChatArtifactArrival] {
        index.images.map { .init(id: $0.id, systemImage: "photo") }
            + index.files.map { .init(id: "file:\($0.path)", systemImage: "doc.text") }
            + index.webPages.map { .init(id: $0.id, systemImage: "globe") }
    }
}
