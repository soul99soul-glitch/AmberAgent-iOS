import SwiftUI
import Shared
import UIKit
import UniformTypeIdentifiers
import PhotosUI

extension ChatView {

    func handleSelectedFileImport(_ result: Result<[URL], Error>) {
        let selectionConversationId = attachmentPickerState.fileImporterConversationId
        attachmentPickerState.fileImporterConversationId = nil
        guard selectionConversationId == currentConversationIdString else { return }
        guard let documentStore else {
            viewModel.selectedFileContextError = IOSAppLocalization.string(
                "文件选择器未连接。",
                defaultValue: "文件选择器未连接。"
            )
            return
        }

        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                let message = IOSAppLocalization.string("没有选择文件。", defaultValue: "没有选择文件。")
                documentStore.recordSelectionError(message)
                viewModel.selectedFileContextError = message
                return
            }
            // A selected-file grant is singleton state. Keep this whole path
            // (grant -> Workspace copy -> preview attach) exclusive so a
            // second picker result cannot replace the grant mid-import.
            guard !attachmentPickerState.isProcessingSelectedFile else { return }
            attachmentPickerState.isProcessingSelectedFile = true
            let selectedGrant = documentStore.registerPickedFile(url)
            Task { @MainActor in
                defer { attachmentPickerState.isProcessingSelectedFile = false }
                var workspaceImportError: String?
                do {
                    _ = try await workspaceStore.importFile(url: url, source: "chat_picker")
                } catch {
                    workspaceImportError = error.localizedDescription
                }
                guard selectionConversationId == currentConversationIdString else { return }
                await viewModel.attachSelectedFilePreviewToNextMessage(
                    expectedConversationId: selectionConversationId,
                    expectedFileScopeDigest: selectedGrant.scopeDigest
                )
                if let workspaceImportError, viewModel.selectedFileContextError == nil {
                    viewModel.selectedFileContextError = IOSAppLocalization.formatted(
                        "已附加到本条消息，但未保存到 Workspace：%@",
                        defaultValue: "已附加到本条消息，但未保存到 Workspace：%@",
                        arguments: [workspaceImportError]
                    )
                }
            }
        case .failure(let error):
            let message = IOSAppLocalization.formatted(
                "文件选择失败：%@",
                defaultValue: "文件选择失败：%@",
                arguments: [error.localizedDescription]
            )
            documentStore.recordSelectionError(message)
            viewModel.selectedFileContextError = message
        }
    }

    // MARK: - Attachment panel actions

    func presentFileImporter() {
        guard !attachmentPickerState.isProcessingSelectedFile else {
            viewModel.selectedFileContextError = "正在读取已选文件，请完成后再选择。"
            return
        }
        let selectionConversationId = currentConversationIdString
        if documentStore != nil {
            attachmentPickerState.fileImporterConversationId = selectionConversationId
            attachmentPickerState.isImportingSelectedFile = true
        } else {
            Task {
                await viewModel.attachSelectedFilePreviewToNextMessage(
                    expectedConversationId: selectionConversationId
                )
            }
        }
    }

    func presentPhotosPicker() {
        attachmentPickerState.photoPickerConversationId = currentConversationIdString
        attachmentPickerState.isPhotoPickerPresented = true
    }

    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            viewModel.selectedFileContextError = IOSAppLocalization.string(
                "此设备不支持相机。",
                defaultValue: "此设备不支持相机。"
            )
            return
        }
        attachmentPickerState.cameraPickerConversationId = currentConversationIdString
        attachmentPickerState.isCameraPresented = true
    }

    func handlePhotoPickerSelection(_ items: [PhotosPickerItem]) {
        let selectionConversationId = attachmentPickerState.photoPickerConversationId
        attachmentPickerState.photoPickerConversationId = nil
        guard !items.isEmpty else { return }
        let previousTask = attachmentPickerState.imageAttachmentTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            guard selectionConversationId == currentConversationIdString else {
                attachmentPickerState.photoPickerItems = []
                return
            }
            var failedImageCount = 0
            for item in items {
                let encoded: (dataUrl: String, previewData: Data)?
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        encoded = await ChatImageEncoder.decodeAndEncodeOffMain(data)
                    } else {
                        encoded = nil
                    }
                } catch {
                    encoded = nil
                }
                guard selectionConversationId == currentConversationIdString else {
                    attachmentPickerState.photoPickerItems = []
                    return
                }
                guard let encoded else {
                    failedImageCount += 1
                    continue
                }
                viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
            }
            attachmentPickerState.photoPickerItems = []
            guard selectionConversationId == currentConversationIdString else { return }
            if failedImageCount > 0 {
                viewModel.selectedFileContextError = IOSAppLocalization.formatted(
                    "有 %lld 张图片处理失败。",
                    defaultValue: "有 %lld 张图片处理失败。",
                    arguments: [Int64(failedImageCount)]
                )
            }
        }
        attachmentPickerState.imageAttachmentTask = task
    }

    func handleCameraImageSelection(_ image: UIImage) {
        let selectionConversationId = attachmentPickerState.cameraPickerConversationId
        attachmentPickerState.cameraPickerConversationId = nil
        let previousTask = attachmentPickerState.imageAttachmentTask
        let task = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled,
                  selectionConversationId == currentConversationIdString else { return }
            let encoded = await ChatImageEncoder.encodeOffMain(image)
            guard selectionConversationId == currentConversationIdString else { return }
            guard let encoded else {
                viewModel.selectedFileContextError = IOSAppLocalization.string(
                    "图片处理失败。",
                    defaultValue: "图片处理失败。"
                )
                return
            }
            viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
        }
        attachmentPickerState.imageAttachmentTask = task
    }

}
