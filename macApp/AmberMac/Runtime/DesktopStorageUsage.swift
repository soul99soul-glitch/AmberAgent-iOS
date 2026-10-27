import Foundation

enum DesktopStorageUsage {
    struct Source: Identifiable, Sendable {
        let id: String
        let title: String
        let directories: [URL]?
        var note: String? = nil
    }
    struct Area: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let byteCount: Int64?
        let fileCount: Int?
        let note: String?
    }
    struct Snapshot: Equatable, Sendable {
        let areas: [Area]
        let totalBytes: Int64
        let totalFileCount: Int
        let scannedAt: Date
    }

    static func sources(amberRoot: URL, knowledgeDirectory: URL, conversationsOnDisk: Bool = true) -> [Source] {
        [Source(id: "conversations", title: "会话与辅助记录",
                directories: conversationsOnDisk ? [amberRoot.appendingPathComponent("conversations"), amberRoot.appendingPathComponent("conversation-insights")] : [],
                note: conversationsOnDisk ? nil : "会话保存在内存中，不计为磁盘文件。"),
         Source(id: "workspaces", title: "会话文件与成果", directories: [amberRoot.appendingPathComponent("workspaces"), amberRoot.appendingPathComponent("image-staging")]),
         Source(id: "knowledge", title: "知识资料与记忆", directories: [knowledgeDirectory]),
         Source(id: "tasks", title: "工具任务记录", directories: [amberRoot.appendingPathComponent("agent-runs")]),
         Source(id: "collaborations", title: "协作记录", directories: [amberRoot.appendingPathComponent("collaborations")]),
         Source(id: "recipes", title: "Recipe", directories: [amberRoot.appendingPathComponent("recipes")])]
    }

    static func measure(_ sources: [Source]) async throws -> Snapshot {
        let task = Task.detached(priority: .utility) { try measureSynchronously(sources) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func measureSynchronously(_ sources: [Source]) throws -> Snapshot {
        try Task.checkCancellation()
        let manager = FileManager.default
        var counted = Set<String>()
        func size(_ url: URL) throws -> (Int64, Int, Int) {
            try Task.checkCancellation()
            let attributes: [FileAttributeKey: Any]
            do { attributes = try manager.attributesOfItem(atPath: url.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                return (0, 0, 0)
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return (0, 0, 1) }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values.isDirectory == true {
                var bytes: Int64 = 0, files = 0, links = 0
                for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let result = try size(child)
                    bytes += result.0; files += result.1; links += result.2
                }
                return (bytes, files, links)
            }
            guard values.isRegularFile == true, counted.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { return (0, 0, 0) }
            return (Int64(values.fileSize ?? 0), 1, 0)
        }
        let areas = try sources.map { source -> Area in
            guard let directories = source.directories else {
                return Area(id: source.id, title: source.title, byteCount: nil, fileCount: nil, note: source.note ?? "未统计此位置。")
            }
            var bytes: Int64 = 0, files = 0, links = 0
            for directory in directories {
                let result = try size(directory)
                bytes += result.0; files += result.1; links += result.2
            }
            let skipped = links > 0 ? "跳过 \(links) 个符号链接。" : nil
            let note = [source.note, skipped].compactMap { $0 }.joined(separator: " ")
            return Area(id: source.id, title: source.title, byteCount: bytes, fileCount: files,
                note: note.isEmpty ? nil : note)
        }
        try Task.checkCancellation()
        return Snapshot(areas: areas, totalBytes: areas.reduce(0) { $0 + ($1.byteCount ?? 0) },
            totalFileCount: areas.reduce(0) { $0 + ($1.fileCount ?? 0) }, scannedAt: Date())
    }
}

