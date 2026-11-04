import SwiftUI
import PhotosUI

/// Composer focus, approval geometry, and panel presentation.
struct ChatComposerLocalState {
    var activeComposerPanel: ComposerPanel?
    var isModelSheetPresented = false
    var isAttachExpanded = false
    var isInputFocused = false
    var gateHighlightRequest: UUID?
    var composerInputHeight: CGFloat = 40
    var approvalContainerHeight: CGFloat = 0
    var composerAuxiliaryHeight: CGFloat = 0
    var subAgentActivityBarHeight: CGFloat = 0
    var siteMemoryApprovalMinimumHeights: [String: CGFloat] = [:]
    var collapsedSiteMemoryComposerRequestId: String?
    var isSubAgentBarVisible = false

    // Argon 3+1 Mode & In-Place Background Handoff State
    var activeDuetTab: AmberDuetModeTab = .chat
    var inlineDuetPanelDragOffsetY: CGFloat = 0
    var isBackgroundHandoffMode = false
    var handoffExecutionTarget: AmberHandoffExecutionTarget = .cloud
    var handoffSelectedCloudAgentId: String = "main"
    var activeHandoffRequestId: String?
    var activeHandoffCloudTaskId: UUID?
    var lastHandoffFingerprint: String?
    var isSubmittingHandoff = false
    var handoffNeedsRetry = false
    var handoffErrorMessage: String?
    var handoffFollowupTask: AmberUnifiedTaskItem?
    var isSubmittingCloudDialogue = false
    var cloudDialogueErrorMessage: String?
    var activeCloudDialogueRequestId = UUID().uuidString.lowercased()
    var lastCloudDialogueFingerprint: String?

    mutating func enterBackgroundHandoffMode(followupTask: AmberUnifiedTaskItem? = nil) {
        activeDuetTab = .chat
        isBackgroundHandoffMode = true
        handoffErrorMessage = nil
        if let followupTask {
            handoffFollowupTask = followupTask
        }
    }

    mutating func exitBackgroundHandoffModePreservingDraft() {
        isBackgroundHandoffMode = false
        isSubmittingHandoff = false
        handoffNeedsRetry = false
        handoffErrorMessage = nil
        handoffFollowupTask = nil
    }

    mutating func prepareHandoffRequestId(
        for prompt: String,
        target: AmberHandoffExecutionTarget,
        hubId: String?,
        followupTaskId: String? = nil
    ) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = "\(target.rawValue)|\(hubId ?? "")|\(followupTaskId ?? "")|\(trimmed)"
        if lastHandoffFingerprint == fingerprint, let existing = activeHandoffRequestId {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        lastHandoffFingerprint = fingerprint
        activeHandoffRequestId = fresh
        activeHandoffCloudTaskId = nil
        return fresh
    }

    mutating func markHandoffSubmissionFailed(_ message: String) {
        isSubmittingHandoff = false
        handoffNeedsRetry = true
        handoffErrorMessage = message
    }

    mutating func completeHandoffSubmission() {
        isSubmittingHandoff = false
        handoffNeedsRetry = false
        handoffErrorMessage = nil
        activeHandoffRequestId = nil
        activeHandoffCloudTaskId = nil
        lastHandoffFingerprint = nil
        handoffFollowupTask = nil
        isBackgroundHandoffMode = false
    }
}

/// Picker presentations and the in-flight media import task.
struct ChatAttachmentPickerState {
    var isImportingSelectedFile = false
    var isCameraPresented = false
    var cameraPickerConversationId: String?
    var imageAttachmentTask: Task<Void, Never>?
    var isPhotoPickerPresented = false
    var photoPickerItems: [PhotosPickerItem] = []
    var fileImporterConversationId: String?
    var isProcessingSelectedFile = false
    var photoPickerConversationId: String?
}

/// Browser card and desktop presentation.
struct ChatBrowserLocalState {
    var showWebMountDesktopBackends = false
    var focusedRemoteWebMountSessionId: String?
    var collapsedWebMountSessionId: String?
    var expandedWebMountSessionId: String?
}

