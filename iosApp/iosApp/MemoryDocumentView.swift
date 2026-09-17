import SwiftUI
@preconcurrency import Shared

/// 单个记忆 Markdown 文档的只读视图。内容由记忆整理自动生成，源数据以
/// memories.json 为准；这里只负责渲染，不提供编辑。
struct MemoryDocumentView: View {
    let relativePath: String
    let displayTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var persistence = IOSMemoryPersistence.shared
    /// 初始值同步读取——push 过渡期间不再先闪现"文档已不存在"占位。
    @State private var content: String?

    init(relativePath: String, displayTitle: String) {
        self.relativePath = relativePath
        self.displayTitle = displayTitle
        _content = State(initialValue: IOSMemoryPersistence.shared.memoryDocumentText(relativePath: relativePath))
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    chrome

                    if let content {
                        AmberMarkdownView(markdown: content, style: .standard)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    } else {
                        VStack(spacing: 10) {
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
                        .padding(.top, 60)
                    }

                    Text("由记忆整理自动生成，源数据以 memories.json 为准。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
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
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回记忆", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            VStack(spacing: 2) {
                Text(displayTitle)
                    .font(.title2.weight(.bold))
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
        .padding(.bottom, 12)
    }

    private func reload() {
        content = persistence.memoryDocumentText(relativePath: relativePath)
    }
}
