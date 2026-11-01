import Foundation

struct DesktopQueuedInstruction: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case pending, delivering, awaitingSave }
    enum Kind: String, Codable, Sendable {
        case supplement
        case newTask
    }

    let id: UUID
    let conversationID: UUID
    let runID: UUID
    var kind: Kind = .supplement
    var targetTitle: String? = nil
    let text: String
    var attachments: [DesktopMessageAttachment] = []
    var status: Status = .pending

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        runID: UUID,
        kind: Kind = .supplement,
        targetTitle: String? = nil,
        text: String,
        attachments: [DesktopMessageAttachment] = [],
        status: Status = .pending
    ) {
        self.id = id
        self.conversationID = conversationID
        self.runID = runID
        self.kind = kind
        self.targetTitle = targetTitle
        self.text = text
        self.attachments = attachments
        self.status = status
    }
}
