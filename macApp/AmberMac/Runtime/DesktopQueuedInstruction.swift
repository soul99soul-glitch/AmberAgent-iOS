import Foundation

struct DesktopQueuedInstruction: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case pending, delivering, awaitingSave }
    let id: UUID
    let conversationID: UUID
    let runID: UUID
    let text: String
    var status: Status = .pending
}
