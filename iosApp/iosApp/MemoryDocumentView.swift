import SwiftUI
@preconcurrency import Shared

/// 单个记忆 Markdown 文档的只读视图。内容由记忆整理自动生成，源数据以
/// memories.json 为准；这里只负责渲染，不提供编辑。
struct MemoryDocumentView: View {
    let relativePath: String
    let displayTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(RouterPath.self) private var router
    @State private var persistence = IOSMemoryPersistence.shared
    /// 初始值同步读取——push 过渡期间不再先闪现"文档已不存在"占位。
    @State private var content: String?

    init(relativePath: String, displayTitle: String) {
        self.relativePath = relativePath
        self.displayTitle = displayTitle
        _content = State(initialValue: IOSMemoryPersistence.shared.memoryDocumentText(relativePath: relativePath))
    }

    private var isSubpage: Bool {
        relativePath != "index.md"
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    chrome

                    if isSubpage {
                        breadcrumbBar
                            .padding(.horizontal, 16)
                    }

                    if let content {
                        VStack(alignment: .leading, spacing: 14) {
                            AmberMarkdownView(markdown: content, style: .standard)
                                .environment(\.openURL, OpenURLAction { url in
                                    handleMarkdownURL(url)
                                })
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            AmberTheme.surface,
                            in: RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AmberTheme.radiusLarge, style: .continuous)
                                .stroke(AmberTheme.borderSoft, lineWidth: 0.75)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        AmberFormGroup {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.questionmark")
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundStyle(AmberTheme.muted2)
                                    .accessibilityHidden(true)
                                Text("文档已不存在")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(AmberTheme.foreground)
                                Text("记忆整理已重新生成文档，返回后刷新列表。")
                                    .font(.subheadline)
                                    .foregroundStyle(AmberTheme.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 36)
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AmberTheme.muted)
                            .accessibilityHidden(true)
                        Text("由记忆整理自动生成，点击页内相对链接可直接跳转专题或返回索引。")
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: reload)
        .onChange(of: persistence.revision) { _, _ in reload() }
    }

    private var chrome: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回上一页", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text(displayTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AmberTheme.foreground)
                    .lineLimit(1)
                Text(relativePath)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AmberTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "book.closed")
                        .font(.caption.weight(.semibold))
                    Text("记忆索引")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(AmberTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AmberTheme.accent.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AmberTheme.muted2)
                .accessibilityHidden(true)

            Text(displayTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(AmberTheme.foreground2)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func handleMarkdownURL(_ url: URL) -> OpenURLAction.Result {
        if let target = MemoryWikiLinkResolver.resolveTarget(from: url, currentRelativePath: relativePath) {
            if target.relativePath == "index.md" && isSubpage {
                dismiss()
            } else if target.relativePath != relativePath {
                router.navigate(to: .memoryDocument(relativePath: target.relativePath, title: target.title))
            }
            return .handled
        }
        return .systemAction
    }

    private func reload() {
        content = persistence.memoryDocumentText(relativePath: relativePath)
    }
}
