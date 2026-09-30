import SwiftUI

enum ChatArtifactPinKind: String, Codable, Equatable {
    case message
    case code
}

typealias ChatArtifactPinAction = @MainActor (
    _ messageID: String, _ text: String, _ kind: ChatArtifactPinKind, _ codeLanguage: String?
) -> Void

/// 环境里传递的是身份稳定的容器，而不是闭包本身：闭包无法判等，ChatView
/// 每次重算都会让读取该环境值的全部消息气泡失效重建（滑动/流式时逐帧整页重算）。
/// 容器随 ChatView 的 @State 存活，渲染时只刷新其中的回调，不触发视图更新。
@MainActor
final class ChatArtifactPinHandler {
    var action: ChatArtifactPinAction?

    func callAsFunction(
        _ messageID: String, _ text: String, _ kind: ChatArtifactPinKind, _ codeLanguage: String?
    ) {
        action?(messageID, text, kind, codeLanguage)
    }
}

private struct ChatArtifactPinActionKey: EnvironmentKey {
    static let defaultValue: ChatArtifactPinHandler? = nil
}

/// 代码块所在消息的 ID，由消息气泡注入；其他 Markdown 场景为 nil。
private struct ChatArtifactMessageIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var chatArtifactPinAction: ChatArtifactPinHandler? {
        get { self[ChatArtifactPinActionKey.self] }
        set { self[ChatArtifactPinActionKey.self] = newValue }
    }

    var chatArtifactMessageID: String? {
        get { self[ChatArtifactMessageIDKey.self] }
        set { self[ChatArtifactMessageIDKey.self] = newValue }
    }
}

/// 代码块头部附件：沿用 vendor 的 headerAccessory 插槽，不给代码块另加 contextMenu，
/// 长按代码块仍弹出整条消息的菜单。
/// 收藏动作在点击时由稳定的 handler 与消息 ID 组合，不经环境传闭包：
/// 每次气泡重算新建的闭包无法判等，会让整段 Markdown 失效重建。
struct ChatCodeBlockHeaderAccessory: View {
    let code: String
    let language: String?
    let showsWidgetPreview: Bool
    @Environment(\.chatArtifactPinAction) private var pinAction
    @Environment(\.chatArtifactMessageID) private var messageID
    /// vendor 头部文字按 UIFontMetrics.default（body）缩放；图标字号与行高跟随同一曲线，大字号下仍与文字对齐。
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 20

    /// 流式 block 渲染路径的头部附件提供者。常量闭包保证每次注入的环境值相同。
    static let streamingHeaderProvider: (_ code: String, _ language: String?) -> AnyView? = { code, language in
        AnyView(ChatCodeBlockHeaderAccessory(code: code, language: language, showsWidgetPreview: false))
    }

    /// vendor 在非隔离闭包里构造头部附件，初始化只保存值。
    nonisolated init(code: String, language: String?, showsWidgetPreview: Bool) {
        self.code = code
        self.language = language
        self.showsWidgetPreview = showsWidgetPreview
    }

    var body: some View {
        // 间距 0：图标之间的可见间距由热区宽度决定。热区 44pt；
        // 带「预览」按钮时头部空间紧，图标热区收窄到 32，并与预览按钮留 4pt。
        let iconWidth: CGFloat = showsWidgetPreview ? 32 : 44
        HStack(spacing: 0) {
            if showsWidgetPreview {
                WidgetCodePreviewButton(code: code)
                    .padding(.trailing, 4)
            }
            ShareLink(item: code) {
                headerIcon("square.and.arrow.up", width: iconWidth)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("分享代码")
            if let pinAction, let messageID {
                Button {
                    pinAction(messageID, code, .code, language)
                } label: {
                    headerIcon("pin", width: iconWidth)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收进产物架")
            }
        }
        // 预览按钮（.bordered .small）约 28pt 高；负 padding 让整组布局仍按 20pt 行高参与头部 .top 对齐，
        // 不撑高头部、不与语言名错位。按钮视觉上下各溢出 4pt，仍在头部 12pt 内边距内。
        .padding(.vertical, showsWidgetPreview ? -4 : 0)
    }

    /// 热区至少 44pt 高；负 padding 让布局高度等于头部文字行高，与语言名/「复制」对齐，不撑高代码块头部。
    private func headerIcon(_ systemImage: String, width: CGFloat) -> some View {
        let hitHeight = max(44, lineHeight)
        return Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .medium))
            .frame(width: width, height: hitHeight)
            .contentShape(Rectangle())
            .padding(.vertical, -(hitHeight - lineHeight) / 2)
    }
}
