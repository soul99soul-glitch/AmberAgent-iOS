import SwiftUI

private func localized(_ key: String) -> String {
    IOSAppLocalization.string(key, defaultValue: key)
}

/// Presentation-only window for long novel replies. The row keeps the complete
/// content so collect/revise/persistence continue to receive the authoritative text;
/// only the markdown view is capped while it is attached to the timeline.
struct NovelSessionWindowedMarkdown: View {
    let fullText: String
    let messageID: NovelMessageID
    let isStreaming: Bool
    let hasEverStreamed: Bool
    let showsFullTextEntry: Bool
    let fullTextTitle: String

    @State private var window: ChatTextWindow
    @State private var isFullTextPresented = false

    init(
        fullText: String,
        messageID: NovelMessageID,
        isStreaming: Bool,
        hasEverStreamed: Bool,
        showsFullTextEntry: Bool,
        fullTextTitle: String
    ) {
        self.fullText = fullText
        self.messageID = messageID
        self.isStreaming = isStreaming
        self.hasEverStreamed = hasEverStreamed
        self.showsFullTextEntry = showsFullTextEntry
        self.fullTextTitle = fullTextTitle
        // A live tail is rebuilt for every paced delta. Seed its bounded window
        // from the visible suffix so the first frame already contains the reply,
        // without counting the accumulated chapter on each view instance.
        let initialWindow: ChatTextWindow
        if isStreaming {
            initialWindow = ChatTextWindow(String(fullText.suffix(ChatTextWindow.limit)))
        } else {
            initialWindow = ChatTextWindow(fullText)
        }
        _window = State(initialValue: initialWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let omissionNotice = window.omissionNotice {
                Text(omissionNotice)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
            }

            ChatAssistantMarkdownView(
                // Keep the notice outside Markdown. A suffix may begin inside a
                // code fence/list/table; injecting the notice into it would alter
                // the parser's boundary and produce a misleading first block.
                markdown: window.text,
                // The bounded text becomes a replacement once the window moves.
                // ChatAssistantMarkdownView already rejects stale cache entries
                // unless the new text is equal or keeps the old prefix, so keep
                // one stable identity and let its single-flight parser catch up.
                renderCacheNamespace: "novel:session:\(messageID):window",
                isStreaming: isStreaming,
                hasEverStreamed: hasEverStreamed
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsFullTextEntry, window.omittedCount > 0 {
                Button {
                    isFullTextPresented = true
                } label: {
                    Label(
                        IOSAppLocalization.formatted(
                            "查看全文（%@ 字）",
                            defaultValue: "查看全文（%@ 字）",
                            arguments: [novelSessionLocalizedNumber(fullText.count)]
                        ),
                        systemImage: "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(localized("按页阅读完整内容"))
            }
        }
        .onAppear {
            window.update(fullText)
        }
        .onChange(of: fullText) { _, newValue in
            window.update(newValue)
        }
        .sheet(isPresented: $isFullTextPresented) {
            NovelSessionFullTextSheet(title: fullTextTitle, text: fullText)
        }
    }
}

/// Grapheme-safe pages shared by the lightweight full-text reader and its tests.
enum NovelSessionFullTextPagination {
    static func pages(_ text: String) -> [String] {
        makePages(text, shouldContinue: { true })
    }

    /// The reader calls this from a detached task so a dismissed/replaced sheet
    /// can stop a large pagination pass between pages.
    static func cancellablePages(_ text: String) -> [String] {
        makePages(text, shouldContinue: { !Task.isCancelled })
    }

    private static func makePages(
        _ text: String,
        shouldContinue: @Sendable () -> Bool
    ) -> [String] {
        guard !text.isEmpty else { return [""] }
        var pages: [String] = []
        pages.reserveCapacity((text.count + ChatTextWindow.limit - 1) / ChatTextWindow.limit)
        var start = text.startIndex
        while start < text.endIndex {
            guard shouldContinue() else { return [] }
            let end = text.index(
                start,
                offsetBy: ChatTextWindow.limit,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            pages.append(String(text[start..<end]))
            start = end
        }
        return pages
    }
}

/// A deliberately plain, paged reader for the source text. It keeps the timeline
/// light even when the user explicitly asks to inspect a whole chapter-sized reply.
private struct NovelSessionFullTextSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let text: String
    @State private var loadedPages: [String]? = nil
    @State private var pageIndex = 0

    init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let pages = loadedPages, !pages.isEmpty {
                    pageReader(pages)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(AmberTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("关闭")) { dismiss() }
                }
            }
        }
        .task(id: text) {
            loadedPages = nil
            pageIndex = 0

            let worker = Task.detached(priority: .userInitiated) {
                NovelSessionFullTextPagination.cancellablePages(text)
            }
            await withTaskCancellationHandler(operation: {
                let pages = await worker.value
                guard !Task.isCancelled, !pages.isEmpty else { return }
                loadedPages = pages
            }, onCancel: {
                worker.cancel()
            })
        }
    }

    @ViewBuilder
    private func pageReader(_ pages: [String]) -> some View {
        ScrollView {
            Text(pages[pageIndex])
                .font(.body)
                .foregroundStyle(AmberTheme.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .scrollIndicators(.hidden)
        // Recreate the scroll view for each page so a long previous page
        // cannot leave the new page scrolled near its old bottom.
        .id(pageIndex)

        Divider()
            .overlay(AmberTheme.borderSoft)

        HStack {
            Button {
                pageIndex = max(0, pageIndex - 1)
            } label: {
                Label(localized("上一页"), systemImage: "chevron.left")
            }
            .disabled(pageIndex == 0)

            Spacer()

            Text(IOSAppLocalization.formatted(
                "第 %@ / %@ 页",
                defaultValue: "第 %@ / %@ 页",
                arguments: [
                    novelSessionLocalizedNumber(pageIndex + 1),
                    novelSessionLocalizedNumber(pages.count)
                ]
            ))
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)

            Spacer()

            Button {
                pageIndex = min(pages.count - 1, pageIndex + 1)
            } label: {
                Label(localized("下一页"), systemImage: "chevron.right")
            }
            .disabled(pageIndex >= pages.count - 1)
        }
        .buttonStyle(.bordered)
        .padding(16)
    }

}
