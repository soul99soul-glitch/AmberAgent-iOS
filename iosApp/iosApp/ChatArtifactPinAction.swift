import SwiftUI

enum ChatArtifactPinKind: String, Codable, Equatable {
    case message
    case code
}

typealias ChatArtifactPinAction = @MainActor (
    _ messageID: String, _ text: String, _ kind: ChatArtifactPinKind, _ codeLanguage: String?
) -> Void

/// 代码块头部“收进产物架”按钮使用的动作；由所在消息注入，其他 Markdown 场景为 nil。
typealias ChatArtifactCodeBlockPinAction = @MainActor (_ code: String, _ language: String?) -> Void

private struct ChatArtifactPinActionKey: EnvironmentKey {
    static let defaultValue: ChatArtifactPinAction? = nil
}

private struct ChatArtifactCodeBlockPinActionKey: EnvironmentKey {
    static let defaultValue: ChatArtifactCodeBlockPinAction? = nil
}

extension EnvironmentValues {
    var chatArtifactPinAction: ChatArtifactPinAction? {
        get { self[ChatArtifactPinActionKey.self] }
        set { self[ChatArtifactPinActionKey.self] = newValue }
    }

    var chatArtifactCodeBlockPinAction: ChatArtifactCodeBlockPinAction? {
        get { self[ChatArtifactCodeBlockPinActionKey.self] }
        set { self[ChatArtifactCodeBlockPinActionKey.self] = newValue }
    }
}

/// 代码块头部附件：沿用 vendor 的 headerAccessory 插槽，不给代码块另加 contextMenu，
/// 长按代码块仍弹出整条消息的菜单。
struct ChatCodeBlockHeaderAccessory: View {
    let code: String
    let language: String?
    let showsWidgetPreview: Bool
    @Environment(\.chatArtifactCodeBlockPinAction) private var pinAction

    /// vendor 在非隔离闭包里构造头部附件，初始化只保存值。
    nonisolated init(code: String, language: String?, showsWidgetPreview: Bool) {
        self.code = code
        self.language = language
        self.showsWidgetPreview = showsWidgetPreview
    }

    var body: some View {
        if showsWidgetPreview {
            WidgetCodePreviewButton(code: code)
        }
        if let pinAction {
            Button {
                pinAction(code, language)
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 44, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收进产物架")
        }
    }
}
