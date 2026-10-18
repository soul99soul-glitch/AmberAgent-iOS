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

