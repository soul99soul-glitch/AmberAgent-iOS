import Foundation

/// 把“基于它继续”写入输入框：文本追加在现有草稿之后，图片走待发送图片路径。
@MainActor
enum ChatArtifactComposerSupport {
    enum ContinuationError: LocalizedError {
        case conversationChanged

        var errorDescription: String? { "已切换对话，未附加图片。" }
    }

    /// 图片超过单条上限时 `addPendingImage` 会写入输入区错误提示，这里不重复报错。
    static func apply(
        _ continuation: ChatArtifactContinuation,
        to viewModel: ChatViewModel
    ) async throws {
        switch continuation {
        case .text(let text):
            let separator = viewModel.inputText.isEmpty ? "" : "\n\n"
            viewModel.inputText += separator + text
        case .image(let url):
            let conversationID = viewModel.currentConversationId
            let data = try await Task.detached(priority: .userInitiated) {
                try IOSImageGenerationRepository.imageData(from: url)
            }.value
            guard let encoded = await ChatImageEncoder.decodeAndEncodeOffMain(data) else {
                throw IOSImageGenerationError.invalidImageData
            }
            // 图片处理期间切换会话时，不把旧会话附件送进新会话。
            guard viewModel.currentConversationId == conversationID else {
                throw ContinuationError.conversationChanged
            }
            viewModel.addPendingImage(dataUrl: encoded.dataUrl, previewData: encoded.previewData)
        }
    }
}
