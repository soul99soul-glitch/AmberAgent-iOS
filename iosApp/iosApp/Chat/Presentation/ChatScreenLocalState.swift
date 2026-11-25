import Observation
import SwiftUI
import PhotosUI

/// Leaf-owned drag offset for inline Duet panels (`任务` / `中心`) so 60–120Hz
/// vertical drag updates only invalidate the offset modifier instead of `ChatView.body`.
@MainActor
@Observable
final class InlineDuetPanelDragState {
    var offsetY: CGFloat = 0

    func update(translation: CGSize) {
        let updated = ChatSheetDismissSmoothnessPolicy.updatedInlineDuetPanelDragOffsetY(
            currentOffsetY: offsetY,
            translation: translation
        )
        if updated != offsetY {
            offsetY = updated
        }
    }

    func end(
        translationY: CGFloat,
        predictedEndTranslationY: CGFloat,
        onDismiss: () -> Void
    ) {
        let shouldDismiss = ChatSheetDismissSmoothnessPolicy.shouldDismissInlineDuetPanel(
            translationY: translationY,
            predictedEndTranslationY: predictedEndTranslationY
        )
        withAnimation(.snappy(duration: 0.22)) {
            offsetY = 0
            if shouldDismiss {
                onDismiss()
            }
        }
    }

    func cancel() {
        withAnimation(.snappy(duration: 0.22)) {
            offsetY = 0
        }
    }
}

struct InlineDuetPanelDragOffsetModifier: ViewModifier {
    let dragState: InlineDuetPanelDragState

    func body(content: Content) -> some View {
        content.offset(y: max(0, dragState.offsetY))
    }
}

struct InlineDuetPanelDragScope<Content: View>: View {
    @State private var dragState: InlineDuetPanelDragState
    private let content: (InlineDuetPanelDragState) -> Content

    init(
        dragState: InlineDuetPanelDragState = InlineDuetPanelDragState(),
        @ViewBuilder content: @escaping (InlineDuetPanelDragState) -> Content
    ) {
        self._dragState = State(initialValue: dragState)
        self.content = content
    }

    var body: some View {
        content(dragState)
            .modifier(InlineDuetPanelDragOffsetModifier(dragState: dragState))
    }
}

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
    var cloudDialogueTaskNotice: String?
    var cloudDialogueBypassedAutoTargetWorkItemId: String?
    var activeCloudDialogueRequestId = UUID().uuidString.lowercased()
    var lastCloudDialogueFingerprint: String?
    var cloudDialogueSubmitGeneration = 0

    struct CloudDialogueComposerTarget: Equatable {
        var workItemId: String
        var isAutoSelected: Bool
    }

    /// Resolves the effective cloud dialogue follow-up / stop target:
    /// 1. Explicit selection wins while that work item still accepts input.
    /// 2. Otherwise, when exactly 1 active work item exists and it wasn't explicitly bypassed
    ///    ("改为新消息" or rejected as terminal/cancelled), default to it.
    /// 3. When 0 or >= 2 active work items exist without an explicit selection, return nil (new message).
    func resolvedCloudDialogueTarget(
        explicitSelectedWorkItemId: String?,
        activeWorkItemIds: [String],
        explicitSelectionAcceptsInput: Bool = true
    ) -> CloudDialogueComposerTarget? {
        if let explicit = explicitSelectedWorkItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           activeWorkItemIds.contains(explicit) || explicitSelectionAcceptsInput {
            return CloudDialogueComposerTarget(workItemId: explicit, isAutoSelected: false)
        }
        guard activeWorkItemIds.count == 1,
              let soleId = activeWorkItemIds.first,
              soleId != cloudDialogueBypassedAutoTargetWorkItemId else {
            return nil
        }
        return CloudDialogueComposerTarget(workItemId: soleId, isAutoSelected: true)
    }

    mutating func switchCloudDialogueToNewMessage(
        currentTargetWorkItemId: String?,
        selectedWorkItemId: inout String?
    ) {
        if let target = currentTargetWorkItemId ?? selectedWorkItemId {
            cloudDialogueBypassedAutoTargetWorkItemId = target
        }
        selectedWorkItemId = nil
        cloudDialogueErrorMessage = nil
    }

    // Plan 2: Unified Main-Timeline 3-Way Execution Target (本机 / 云端 / Mac) & Targeted Follow-up
    var unifiedMacFollowupWorkItemId: String? = nil
    var unifiedFollowupTargetRole: MacGatewayEndpointRole? = nil
    var sharePrefillNotice: String? = nil

    /// Consumes an explicit card follow-up target (if armed) while keeping the user's selected
    /// bottom-bar execution target intact for subsequent sends.
    mutating func takeUnifiedRemoteTarget(executionTarget: AmberComposerExecutionTarget = .local) -> (workItemId: String?, role: MacGatewayEndpointRole?) {
        let targetWorkItemId = unifiedMacFollowupWorkItemId
        let targetRole = unifiedFollowupTargetRole ?? executionTarget.endpointRole
        unifiedMacFollowupWorkItemId = nil
        unifiedFollowupTargetRole = nil
        cloudDialogueErrorMessage = nil
        sharePrefillNotice = nil
        return (targetWorkItemId, targetRole)
    }

    /// Legacy compatibility helper used on conversation switch / share prefill reset.
    mutating func takeUnifiedMacTarget() -> String? {
        takeUnifiedRemoteTarget().workItemId
    }

    static func cloudDialogueFingerprint(text: String, targetWorkItemId: String?) -> String {
        "\(targetWorkItemId ?? "main")\u{0000}\(text)"
    }

    mutating func beginCloudDialogueSubmit(
        text: String,
        targetWorkItemId: String?
    ) -> (requestId: String, generation: Int, fingerprint: String) {
        let fingerprint = Self.cloudDialogueFingerprint(text: text, targetWorkItemId: targetWorkItemId)
        if let last = lastCloudDialogueFingerprint, last != fingerprint {
            activeCloudDialogueRequestId = UUID().uuidString.lowercased()
        }
        lastCloudDialogueFingerprint = fingerprint
        cloudDialogueSubmitGeneration += 1
        isSubmittingCloudDialogue = true
        cloudDialogueErrorMessage = nil
        return (activeCloudDialogueRequestId, cloudDialogueSubmitGeneration, fingerprint)
    }

    mutating func finishCloudDialogueSubmit(
        generation: Int,
        submittedText: String,
        submittedTargetWorkItemId: String?,
        submittedFingerprint: String,
        isSubmittedTargetStillActive: Bool = true,
        currentInputText: inout String,
        selectedWorkItemId: inout String?,
        result: Result<MacGatewayCloudDialogueReceipt, Error>
    ) {
        if generation == cloudDialogueSubmitGeneration {
            isSubmittingCloudDialogue = false
        }
        switch result {
        case .success(let receipt):
            if receipt.state == .cancelled {
                let currentFingerprint = Self.cloudDialogueFingerprint(
                    text: currentInputText,
                    targetWorkItemId: selectedWorkItemId
                )
                if generation == cloudDialogueSubmitGeneration && currentFingerprint == submittedFingerprint {
                    cloudDialogueErrorMessage = "补充未被接收：原任务已结束。"
                    cloudDialogueTaskNotice = "草稿已保留；再次发送将作为新的云端请求。"
                    if let submittedTargetWorkItemId {
                        cloudDialogueBypassedAutoTargetWorkItemId = submittedTargetWorkItemId
                    }
                    selectedWorkItemId = nil
                    activeCloudDialogueRequestId = UUID().uuidString.lowercased()
                    lastCloudDialogueFingerprint = nil
                } else if let submittedTargetWorkItemId, selectedWorkItemId == submittedTargetWorkItemId {
                    cloudDialogueBypassedAutoTargetWorkItemId = submittedTargetWorkItemId
                    selectedWorkItemId = nil
                }
                return
            }
            if currentInputText == submittedText {
                currentInputText = ""
            }
            if submittedTargetWorkItemId != nil,
               selectedWorkItemId == submittedTargetWorkItemId,
               !isSubmittedTargetStillActive {
                selectedWorkItemId = nil
            }
            if lastCloudDialogueFingerprint == submittedFingerprint {
                activeCloudDialogueRequestId = UUID().uuidString.lowercased()
                lastCloudDialogueFingerprint = nil
                cloudDialogueErrorMessage = nil
            }
        case .failure(let error):
            let currentFingerprint = Self.cloudDialogueFingerprint(
                text: currentInputText,
                targetWorkItemId: selectedWorkItemId
            )
            if generation == cloudDialogueSubmitGeneration && currentFingerprint == submittedFingerprint {
                if case MacGatewayError.conflict("task_terminal") = error {
                    cloudDialogueErrorMessage = "补充未被接收：原任务已结束。"
                    cloudDialogueTaskNotice = "草稿已保留；再次发送将作为新的云端请求。"
                    if let submittedTargetWorkItemId {
                        cloudDialogueBypassedAutoTargetWorkItemId = submittedTargetWorkItemId
                    }
                    selectedWorkItemId = nil
                } else {
                    cloudDialogueErrorMessage = error.localizedDescription
                }
            }
        }
    }

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

