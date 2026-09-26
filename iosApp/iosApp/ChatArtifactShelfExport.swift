import Foundation

/// 产物架多选后准备好的分享文件与成果报告。
struct ChatArtifactShelfExport: Equatable {
    let shareURLs: [URL]
    let reportURL: URL
    /// 未保留正文的文件版本只写进报告，不生成分享文件。
    let reportOnlyCount: Int
    /// 读取或写入失败而跳过的项（例如本地图片已被删除）。
    let skippedCount: Int
}

/// 面板持有的导出状态：准备期间不暴露上一批结果；临时目录在面板关闭时统一删除，
/// 避免新一批覆盖时删掉仍在分享面板中使用的文件。
struct ChatArtifactShelfExportState {
    private(set) var export: ChatArtifactShelfExport?
    private(set) var isPreparing = false
    private(set) var directories: [URL] = []
    private var lastFailure: String?

    mutating func begin() {
        export = nil
        isPreparing = true
    }

    mutating func finish(_ export: ChatArtifactShelfExport, directory: URL) {
        self.export = export
        directories.append(directory)
        isPreparing = false
        lastFailure = nil
    }

    /// 返回是否需要弹窗：同一失败在选择变化时不重复打扰。
    mutating func fail(_ message: String) -> Bool {
        export = nil
        isPreparing = false
        defer { lastFailure = message }
        return lastFailure != message
    }

    mutating func reset() {
        export = nil
        isPreparing = false
    }

    mutating func removeDirectories() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }
}

/// 在后台线程读取图片、写临时文件；每次导出使用独立目录。单项失败只跳过该项。
enum ChatArtifactShelfExporter {
    static func prepare(
        index: ConversationArtifactIndex,
        snippets: [IOSPinnedSnippet],
        adoptedVersions: [String: String],
        selectedIDs: Set<String>,
        title: String
    ) async throws -> (export: ChatArtifactShelfExport, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmberAgentShelfExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let export = try await Task.detached(priority: .userInitiated) {
            try write(
                index: index, snippets: snippets, adoptedVersions: adoptedVersions,
                selectedIDs: selectedIDs, title: title, directory: directory
            )
        }.value
        return (export, directory)
    }

    nonisolated static func write(
        index: ConversationArtifactIndex,
        snippets: [IOSPinnedSnippet],
        adoptedVersions: [String: String],
        selectedIDs: Set<String>,
        title: String,
        directory: URL
    ) throws -> ChatArtifactShelfExport {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try writeItems(
                index: index, snippets: snippets, adoptedVersions: adoptedVersions,
                selectedIDs: selectedIDs, title: title, directory: directory
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private nonisolated static func writeItems(
        index: ConversationArtifactIndex,
        snippets: [IOSPinnedSnippet],
        adoptedVersions: [String: String],
        selectedIDs: Set<String>,
        title: String,
        directory: URL
    ) throws -> ChatArtifactShelfExport {
        var names = Set<String>()
        var urls: [URL] = []
        var reportOnlyCount = 0
        var skippedCount = 0

        func writeFile(_ data: @autoclosure () throws -> Data, name: String) {
            do {
                let data = try data()
                let url = directory.appendingPathComponent(uniqueName(name, taken: &names))
                try data.write(to: url, options: [.atomic])
                urls.append(url)
            } catch {
                skippedCount += 1
            }
        }

        for (offset, image) in index.images.enumerated()
        where selectedIDs.contains(ChatArtifactActions.selectionID(for: image)) {
            if let url = IOSImageGenerationRepository.resolvedImageURL(from: image.url), !url.isFileURL {
                urls.append(url)
                continue
            }
            do {
                let data = try IOSImageGenerationRepository.imageData(from: image.url)
                writeFile(data, name: "图片-第\(image.source.turn)轮-\(offset + 1).\(imageExtension(for: data))")
            } catch {
                skippedCount += 1
            }
        }

        for file in index.files where selectedIDs.contains(ChatArtifactActions.selectionID(for: file)) {
            guard let content = ChatArtifactActions.selectedVersion(for: file, adoptedVersions: adoptedVersions)?.content else {
                reportOnlyCount += 1
                continue
            }
            writeFile(Data(content.utf8), name: URL(fileURLWithPath: file.path).lastPathComponent)
        }

        for page in index.webPages where selectedIDs.contains(ChatArtifactActions.selectionID(for: page)) {
            if let url = page.url.flatMap(ChatMarkdownOpenURLPolicy.url(from:)) {
                urls.append(url)
            } else {
                writeFile(Data(([page.title] + [page.preview].compactMap { $0 }).joined(separator: "\n\n").utf8),
                              name: "\(page.title).txt")
            }
        }

        for snippet in snippets where selectedIDs.contains(ChatArtifactActions.selectionID(for: snippet)) {
            writeFile(Data(snippet.text.utf8), name: "片段-第\(snippet.turn)轮.md")
        }

        let markdown = ChatArtifactActions.reportMarkdown(
            title: title, index: index, snippets: snippets,
            adoptedVersions: adoptedVersions, selectedIDs: selectedIDs
        )
        let reportURL = directory.appendingPathComponent(uniqueName("\(title)-成果报告.md", taken: &names))
        try Data(markdown.utf8).write(to: reportURL, options: [.atomic])
        return ChatArtifactShelfExport(
            shareURLs: urls, reportURL: reportURL, reportOnlyCount: reportOnlyCount, skippedCount: skippedCount
        )
    }

    /// 文件名去掉路径分隔符与换行，主名按 UTF-8 截到 180 字节以内（文件系统上限 255 字节）；
    /// 同名时追加序号，保证同一批分享不互相覆盖。
    nonisolated static func uniqueName(_ raw: String, taken: inout Set<String>) -> String {
        let cleaned = raw.map { "/\\:".contains($0) || $0.isNewline ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        while base.utf8.count > 180 { base.removeLast() }
        if base.isEmpty { base = "成果" }
        let limited = ext.isEmpty ? base : "\(base).\(ext)"
        var candidate = limited
        var counter = 2
        while !taken.insert(candidate).inserted {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private nonisolated static func imageExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if data.count >= 12, data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return "webp" }
        return "png"
    }
}
