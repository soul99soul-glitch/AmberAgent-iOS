import Foundation

extension MacGatewayStore {
    var suggestionHostKey: String {
        guard isCloudMainDialogueSelected, let connection else { return "local" }
        return "cloud:\(connection.gatewayId):\(connection.deviceId)"
    }

    func updateCloudSuggestionTrigger(_ event: MacGatewayCloudDialogueEvent) {
        guard event.seq > cloudSuggestionSequence else { return }
        let reply: String?
        switch event.kind {
        case .userMessage, .followup, .stopRequested: reply = nil
        case .assistantReply, .taskResult:
            reply = event.role == "assistant" && !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && event.outcome != .failed && event.outcome != .cancelled ? event.id : nil
        default: return
        }
        cloudSuggestionSequence = event.seq
        if cloudSuggestionReplyID != reply { cloudSuggestionReplyID = reply }
    }
}
