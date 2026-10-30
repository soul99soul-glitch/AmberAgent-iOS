import AppKit
import SwiftUI

struct DesktopArtifactShelfView: View {
    @Bindable var workspace: DesktopWorkspace
    var embedded = false
    let onLocate: (UUID) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var copiedID: UUID?

    private var conversation: DesktopConversation? { workspace.selectedConversation }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { Text("产物架").font(DesktopTheme.serif(size: 18, weight: .semibold)) }
            if let error = workspace.artifactShelf.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(DesktopTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let conversation, !workspace.artifactShelf.pins(for: conversation.id).isEmpty {
                let messageIDs = Set(conversation.messages.map(\.id))
                let list = VStack(alignment: .leading, spacing: 12) {
                    ForEach(workspace.artifactShelf.pins(for: conversation.id)) { pin in
                        row(pin, conversationID: conversation.id, available: messageIDs.contains(pin.messageID))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if embedded { list } else { ScrollView { list }.frame(maxHeight: 400) }
            } else {
                Text(embedded ? "在消息或代码块上点「固定」即可收入此处" : "在消息菜单或代码块上选择“固定”，常用的回答与代码会保存在这里。")
                    .font(.system(size: embedded ? 12 : 13))
                    .foregroundStyle(DesktopTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 420)
    }

    private func row(_ pin: DesktopPinnedSnippet, conversationID: UUID, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: pin.kind == .code ? "chevron.left.forwardslash.chevron.right" : "text.bubble")
                    .foregroundStyle(DesktopTheme.accent)
                Text(pin.kind == .code ? (pin.codeLanguage ?? "代码") : "消息")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(pin.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 12)).foregroundStyle(DesktopTheme.inkTertiary)
            }
            Text(pin.text)
                .font(pin.kind == .code ? .system(size: 12, design: .monospaced) : .callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(pin.text)
            HStack(spacing: 12) {
                Button(copiedID == pin.id ? "已复制" : "复制", systemImage: copiedID == pin.id ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pin.text, forType: .string)
                    copiedID = pin.id
                }
                Button("定位原消息", systemImage: "scope") { onLocate(pin.messageID) }
                    .disabled(!available)
                    .help(available ? "在会话中滚动到原消息" : "原消息已不在当前会话中")
                Spacer()
                Button("取消固定", systemImage: "pin.slash") { workspace.artifactShelf.unpin(pin.id, in: conversationID) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(DesktopTheme.inkTertiary)
        }
        .padding(12)
        .background(DesktopTheme.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopTheme.border(scheme)))
    }
}

/// Holds the AppKit view a message's actions menu is drawn in, so the system share picker can anchor to it.
@MainActor final class DesktopShareAnchor {
    fileprivate weak var view: NSView?

    func share(_ text: String) {
        guard let view else { return }
        NSSharingServicePicker(items: [text]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

struct DesktopShareAnchorView: NSViewRepresentable {
    let anchor: DesktopShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
