#if DEBUG
extension ChatRenderProbe {
    /// Only evaluate diagnostic comparisons after production equality rejected a
    /// row. Labels record which input changed, never message content.
    @MainActor
    static func recordRowDifferences(_ lhs: NativeTimelineMessageBubble, _ rhs: NativeTimelineMessageBubble) {
        guard enabled else { return }
        let differences = [
            ("entryID", lhs.entryID != rhs.entryID),
            ("messageID", lhs.model.row.messageId != rhs.model.row.messageId),
            ("role", lhs.model.row.role != rhs.model.row.role),
            ("index", lhs.model.row.index != rhs.model.row.index),
            ("continuation", lhs.model.row.isAssistantContinuation != rhs.model.row.isAssistantContinuation),
            ("isLast", lhs.model.row.isLast != rhs.model.row.isLast),
            ("hasEverStreamed", lhs.model.row.hasEverStreamed != rhs.model.row.hasEverStreamed),
            ("insertion", lhs.model.row.canAnimateInsertion != rhs.model.row.canAnimateInsertion),
            ("variant", lhs.model.variantInfo != rhs.model.variantInfo),
            ("renderState", lhs.model.renderState != rhs.model.renderState),
            ("renderIdentity", lhs.model.renderIdentity != rhs.model.renderIdentity),
            ("phoneGroup", lhs.model.phoneToolGroup?.signature != rhs.model.phoneToolGroup?.signature),
            ("assistantTurn", lhs.model.assistantTurn != rhs.model.assistantTurn),
            ("taskLive", lhs.model.isTaskLive != rhs.model.isTaskLive),
            ("independentTasks", lhs.model.usesIndependentTasks != rhs.model.usesIndependentTasks),
            ("displaySignature", lhs.displaySettingSignature != rhs.displaySettingSignature),
            ("generativeSignature", lhs.generativeUiSettingSignature != rhs.generativeUiSettingSignature),
            ("imageFocus", lhs.imageAccessibilityFocusToolCallID != rhs.imageAccessibilityFocusToolCallID),
            ("digest", lhs.renderDigest != rhs.renderDigest),
            ("generationActive", lhs.model.isGenerationActive != rhs.model.isGenerationActive)
        ]
        for (name, changed) in differences where changed {
            record("row-diff-" + name, id: lhs.model.row.messageId)
        }
    }
}
#endif
