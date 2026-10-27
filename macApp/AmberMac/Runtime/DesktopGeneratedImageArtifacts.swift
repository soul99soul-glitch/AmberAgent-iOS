import Foundation

struct DesktopGeneratedImageArtifact: Sendable {
    let file: DesktopWorkspaceFile
    let document: DesktopImportedDocument
}

extension DesktopWorkspaceFiles {
    func importGeneratedImage(conversationID: UUID, from source: URL) async throws -> DesktopGeneratedImageArtifact {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= DesktopDocumentImport.maximumFileBytes else {
            throw DesktopRuntimeError.message("生成的图片文件不可读，或超过 32 MB。")
        }
        let document = try await DesktopDocumentImport.readImageData(Data(contentsOf: source), name: source.lastPathComponent)
        try Task.checkCancellation()
        guard let dataURL = document.image?.dataURL, let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            throw DesktopRuntimeError.message("生成的图片数据无法解码。")
        }
        let file = try importData(conversationID: conversationID, name: document.name, data: data)
        let imported = DesktopImportedDocument(id: document.id, name: file.name, sourceURL: nil,
            kind: .image, byteCount: file.byteCount, text: "", image: document.image, pageCount: nil, note: nil)
        return DesktopGeneratedImageArtifact(file: file, document: imported)
    }
}
