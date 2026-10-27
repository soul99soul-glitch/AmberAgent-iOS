import Foundation

struct DesktopMessageAttachment: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case image, text }
    let name: String
    let mimeType: String
    let kind: Kind
    let dataURL: String?
    let text: String?

    init(_ document: DesktopImportedDocument) {
        name = document.name
        mimeType = document.image?.mimeType ?? "text/plain"
        kind = document.image == nil ? .text : .image
        dataURL = document.image?.dataURL
        text = document.image == nil ? document.text : nil
    }
}

extension DesktopTextProvider {
    func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
        guard !attachments.contains(where: { $0.kind == .image }) else {
            throw DesktopRuntimeError.message("界面预览无法发送图片，请在连接 Shared 的正式版中使用图片对话。")
        }
        let documents = attachments.map { "[附件：\($0.name)]\n\($0.text ?? "")\n[附件结束]" }
        return DesktopMessage(id: id, role: .user, text: ([text] + documents).filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
}
