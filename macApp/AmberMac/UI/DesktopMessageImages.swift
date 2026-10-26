import AppKit
import SwiftUI

struct DesktopMessageImageView: View {
    let source: DesktopMessageImage
    @State private var previewPresented = false

    var body: some View {
        Button { previewPresented = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                DesktopMessageImageContent(source: source)
                    .frame(maxWidth: 360, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let name = source.name, !name.isEmpty {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("查看图片")
        .accessibilityLabel(source.name.map { "查看图片 \($0)" } ?? "查看消息图片")
        .sheet(isPresented: $previewPresented) {
            VStack(spacing: 16) {
                HStack {
                    Text(source.name ?? "消息图片").font(.headline).lineLimit(1)
                    Spacer()
                    Button("完成") { previewPresented = false }.keyboardShortcut(.cancelAction)
                }
                DesktopMessageImageContent(source: source)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(22)
            .frame(width: 680, height: 540)
        }
    }
}

private struct DesktopMessageImageContent: View {
    let source: DesktopMessageImage
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if source.url.hasPrefix("data:") {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
                } else if failed {
                    unavailable
                } else {
                    ProgressView("正在读取图片…")
                }
            } else if let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView("正在读取图片…")
                    case .success(let image): image.resizable().scaledToFit().accessibilityHidden(true)
                    case .failure: unavailable
                    @unknown default: unavailable
                    }
                }
            } else {
                unavailable
            }
        }
        .task(id: source.url) {
            guard source.url.hasPrefix("data:") else { return }
            image = nil
            failed = false
            if let separator = source.url.firstIndex(of: ","),
               let data = Data(base64Encoded: String(source.url[source.url.index(after: separator)...])) {
                image = NSImage(data: data)
            }
            failed = image == nil
        }
    }

    private var unavailable: some View {
        Label("图片暂时无法读取，原始数据已保留。", systemImage: "photo.badge.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
    }
}
