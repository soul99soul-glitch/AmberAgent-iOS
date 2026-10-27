import AppKit
import SwiftUI

struct DesktopAttachmentThumbnail: View {
    let document: DesktopImportedDocument

    var body: some View {
        Group {
            if let data = document.image?.thumbnailData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: document.symbolName).foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

struct DesktopAttachmentPreview: View {
    let document: DesktopImportedDocument
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                DesktopAttachmentThumbnail(document: document)
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.name).font(.headline).lineLimit(2)
                    Text(document.details).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let note = document.note {
                Label(note, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if document.kind == .image {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView("正在读取图片…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        Text(document.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            if let url = document.sourceURL {
                HStack {
                    Text("来源：\(url.lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(22)
        .frame(width: 680, height: 540)
        .onAppear {
            guard let source = document.image else { return }
            if let separator = source.dataURL.firstIndex(of: ","),
               let data = Data(base64Encoded: String(source.dataURL[source.dataURL.index(after: separator)...])) {
                image = NSImage(data: data)
            }
        }
    }
}

private extension DesktopImportedDocument {
    var symbolName: String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .presentation: "rectangle.stack"
        case .document: "doc.richtext"
        case .text: "doc.text"
        }
    }

    var details: String {
        var values = [ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)]
        if let image { values.append("\(image.pixelWidth) × \(image.pixelHeight)") }
        if let pageCount { values.append("\(pageCount) 页") }
        if image == nil { values.append("\(text.count) 字符，将作为文字上下文发送") }
        return values.joined(separator: " · ")
    }
}
