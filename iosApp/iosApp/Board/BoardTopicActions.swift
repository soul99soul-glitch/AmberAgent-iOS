import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
@preconcurrency import WebKit
#endif
@preconcurrency import Network
@preconcurrency import Shared
// MARK: - 榜单条目操作面板(底部滑入)

struct TopicActionSheet: View {
    let title: String
    let sourceURL: URL?
    let canReadOriginal: Bool
    let onDeepRead: () -> Void
    let onCloseRead: (_ originalOnly: Bool) -> Void
    let onOpenSource: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmberTheme.foreground)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 16)

            VStack(spacing: 10) {
                TopicActionRow(icon: "book.pages", title: "深度阅读", prominent: true, action: onDeepRead)
                if canReadOriginal {
                    TopicActionRow(icon: "doc.text.magnifyingglass", title: "精读原文") { onCloseRead(false) }
                    TopicActionRow(icon: "doc.plaintext", title: "只读原文") { onCloseRead(true) }
                }
                if sourceURL != nil {
                    TopicActionRow(icon: "safari", title: "打开原文", action: onOpenSource)
                }
                TopicActionRow(icon: "arrow.clockwise", title: "重新生成", action: onRegenerate)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
    }
}

private struct TopicActionRow: View {
    let icon: String
    let title: LocalizedStringKey
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            rowLabel
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var rowLabel: some View {
        let base = HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22)
            Text(title)
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(prominent ? Color.white : AmberTheme.foreground)
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        if prominent {
            base.amberProminentGlass(cornerRadius: 16, tint: AmberTheme.accent)
        } else {
            base.amberGlass(cornerRadius: 16)
        }
    }
}
