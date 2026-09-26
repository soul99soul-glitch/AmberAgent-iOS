import SwiftUI

struct ChatRecapPanel: View {
    let recap: ConversationRecap?
    let isLoading: Bool
    let failure: String?
    let isStale: Bool
    let maxHeight: CGFloat
    let onRefresh: () -> Void
    let onLocate: (ConversationRecap.Node) -> Void
    let onNextStep: (String) -> Void

    @State private var contentHeight: CGFloat?
    @State private var headerHeight: CGFloat = 0
    @State private var canScrollDown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 24)
                    .foregroundStyle(AmberTheme.accent)
                    .accessibilityHidden(true)
                Text("回顾").font(.headline)
            }
            .padding(.horizontal, 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            ScrollView {
                contents
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight ?? availableHeight, availableHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.visibleRect.maxY + 1
            } action: { _, hasMore in
                canScrollDown = hasMore
            }
            .overlay(alignment: .bottom) {
                if canScrollDown {
                    LinearGradient(
                        colors: [AmberTheme.background.opacity(0), AmberTheme.background],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 36)
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(.vertical, 16)
        .foregroundStyle(AmberTheme.foreground)
        .accessibilityIdentifier("chat-recap-panel")
    }

    private var availableHeight: CGFloat { max(0, maxHeight - headerHeight - 14 - 32) }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isStale {
                Button(action: onRefresh) {
                    Label("有新内容 · 刷新", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AmberTheme.accent)
                .disabled(isLoading)
            }
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(recap == nil ? "正在整理回顾…" : "正在更新回顾…")
                        .font(.subheadline)
                        .foregroundStyle(AmberTheme.muted)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
            if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label("回顾生成失败", systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AmberTheme.accentRed)
                    Text(failure).font(.subheadline).foregroundStyle(AmberTheme.muted)
                    Button(action: onRefresh) {
                        Text("重试")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(isLoading)
                }
            }
            if let recap {
                Text(recap.overview).font(.subheadline)
                VStack(spacing: 0) {
                    ForEach(Array(recap.nodes.enumerated()), id: \.offset) { _, node in
                        let available = node.messageID != nil
                        Button { onLocate(node) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: node.kind.systemImage)
                                    .frame(width: 24)
                                    .foregroundStyle(node.kind == .failure ? AmberTheme.accentRed : AmberTheme.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(node.title).font(.subheadline)
                                        .foregroundStyle(node.kind == .failure ? AmberTheme.accentRed : AmberTheme.foreground)
                                    if !available {
                                        Text("原消息不在当前分支").font(.caption).foregroundStyle(AmberTheme.muted)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(node.kind.title)：\(node.title)")
                        .accessibilityHint(available ? "定位到原消息" : "原消息不在当前分支")
                        .opacity(available ? 1 : 0.6)
                    }
                }
                if !recap.nextSteps.isEmpty {
                    Text("接下来").font(.caption.weight(.semibold)).foregroundStyle(AmberTheme.muted)
                    VStack(spacing: 4) {
                        ForEach(Array(recap.nextSteps.enumerated()), id: \.offset) { _, step in
                            Button { onNextStep(step) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "plus.bubble")
                                        .frame(width: 24)
                                        .accessibilityHidden(true)
                                    Text(step)
                                }
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AmberTheme.accent)
                            .accessibilityHint("填入输入框，不会自动发送")
                        }
                    }
                }
            }
        }
    }
}

private extension ConversationRecap.Node.Kind {
    var title: String {
        switch self {
        case .decision: "决策"
        case .milestone: "里程碑"
        case .failure: "失败"
        case .artifact: "产物"
        }
    }

    var systemImage: String {
        switch self {
        case .decision: "checkmark.seal"
        case .milestone: "flag"
        case .failure: "exclamationmark.circle"
        case .artifact: "tray.full"
        }
    }
}
