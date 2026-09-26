import Foundation

enum ChatArtifactContinuationSource {
    case image(ConversationArtifactIndex.Image)
    case file(path: String)
    case snippet(IOSPinnedSnippet)
    case webPage(ConversationArtifactIndex.WebPage)
}

enum ChatArtifactContinuation: Equatable {
    case image(url: String)
    case text(String)
}

/// 产物架的纯映射：基于它继续、多选标识与成果报告。
enum ChatArtifactActions {
    static func continuation(for source: ChatArtifactContinuationSource) -> ChatArtifactContinuation {
        switch source {
        case .image(let image):
            .image(url: image.url)
        case .file(let path):
            .text("/workspace/\(path)")
        case .snippet(let snippet):
            .text(quote(snippet.text))
        case .webPage(let page):
            .text(link(page))
        }
    }

    static func selectionID(for image: ConversationArtifactIndex.Image) -> String {
        "image:\(image.id)"
    }

    static func selectionID(for file: ConversationArtifactIndex.FileGroup) -> String {
        "file:\(file.path)"
    }

    static func selectionID(for page: ConversationArtifactIndex.WebPage) -> String {
        "web:\(page.id)"
    }

    static func selectionID(for snippet: IOSPinnedSnippet) -> String {
        "snippet:\(snippet.id)"
    }

    /// 只承认仍存在于当前版本列表中的采用记录；分支切换后失效的记录视为未采用。
    static func adoptedVersionID(
        for file: ConversationArtifactIndex.FileGroup,
        adoptedVersions: [String: String]
    ) -> String? {
        adoptedVersions[file.path].flatMap { id in file.versions.contains { $0.id == id } ? id : nil }
    }

    static func selectedVersion(
        for file: ConversationArtifactIndex.FileGroup,
        adoptedVersions: [String: String]
    ) -> ConversationArtifactIndex.FileVersion? {
        let adoptedID = adoptedVersionID(for: file, adoptedVersions: adoptedVersions)
        return file.versions.first { $0.id == adoptedID } ?? file.versions.last
    }

    /// 成果报告：文件取采用版本，未采用时取最新版本；每项都注明来源轮次。
    static func reportMarkdown(
        title: String,
        index: ConversationArtifactIndex,
        snippets: [IOSPinnedSnippet],
        adoptedVersions: [String: String],
        selectedIDs: Set<String>? = nil
    ) -> String {
        var sections: [String] = ["# \(title) · 成果报告"]

        let images = index.images.filter { isSelected(selectionID(for: $0), selectedIDs) }
        if !images.isEmpty {
            sections.append("## 图片\n\n" + images.map { image in
                let caption = inlineText(image.prompt?.nilIfBlank ?? "生成图片")
                // 本地文件与 data URL 离开 App 后不可用，只保留可公开访问的地址。
                if let url = URL(string: image.url), ["http", "https"].contains(url.scheme?.lowercased()) {
                    return "- 第 \(image.source.turn) 轮：\(caption)\n\n  ![\(caption)](<\(image.url)>)"
                }
                return "- 第 \(image.source.turn) 轮：\(caption)"
            }.joined(separator: "\n"))
        }

        let files = index.files.filter { isSelected(selectionID(for: $0), selectedIDs) }
        if !files.isEmpty {
            sections.append("## 文件\n\n" + files.compactMap { file -> String? in
                guard let version = selectedVersion(for: file, adoptedVersions: adoptedVersions),
                      let number = file.versions.firstIndex(of: version).map({ $0 + 1 }) else { return nil }
                let state = adoptedVersionID(for: file, adoptedVersions: adoptedVersions) == version.id ? "已采用" : "最新"
                let label = file.versions.count > 1 ? "\(state)版本 \(number)/\(file.versions.count)" : state
                let body = version.content.map {
                    fencedCode($0, language: URL(fileURLWithPath: file.path).pathExtension.nilIfBlank)
                } ?? "此版本未保留正文。"
                return "### `\(file.path)`\n\n\(label) · 来源：第 \(version.source.turn) 轮\n\n\(body)"
            }.joined(separator: "\n\n"))
        }

        let pages = index.webPages.filter { isSelected(selectionID(for: $0), selectedIDs) }
        if !pages.isEmpty {
            sections.append("## 网页\n\n" + pages.map { page in
                "- \(link(page))（第 \(page.source.turn) 轮）"
            }.joined(separator: "\n"))
        }

        let selectedSnippets = snippets.filter { isSelected(selectionID(for: $0), selectedIDs) }
        if !selectedSnippets.isEmpty {
            sections.append("## 收藏片段\n\n" + selectedSnippets.map { snippet in
                let body = snippet.kind == .code
                    ? fencedCode(snippet.text, language: snippet.codeLanguage)
                    : quote(snippet.text)
                return "### 第 \(snippet.turn) 轮\n\n\(body)"
            }.joined(separator: "\n\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func isSelected(_ id: String, _ selectedIDs: Set<String>?) -> Bool {
        selectedIDs?.contains(id) ?? true
    }

    private static func lines(_ text: String) -> [Substring] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func quote(_ text: String) -> String {
        lines(text).map { "> \($0)" }.joined(separator: "\n")
    }

    /// 链接文字折叠空白并转义 `]`，地址用尖括号包住，避免空格或括号截断链接。
    private static func link(_ page: ConversationArtifactIndex.WebPage) -> String {
        let title = inlineText(page.title)
        guard let url = page.url?.nilIfBlank else { return title }
        return "[\(title)](<\(url)>)"
    }

    private static func inlineText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// 围栏长度大于正文中可能闭合围栏的最长反引号串（行首最多 3 个空格）。
    private static func fencedCode(_ text: String, language: String? = nil) -> String {
        let body = lines(text)
        let longestRun = body.map { line in
            line.drop { $0 == " " }.count >= line.count - 3
                ? line.drop { $0 == " " }.prefix { $0 == "`" }.count
                : 0
        }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let trimmed = body.last?.isEmpty == true ? body.dropLast() : body[...]
        return "\(fence)\(language ?? "")\n\(trimmed.joined(separator: "\n"))\n\(fence)"
    }
}
