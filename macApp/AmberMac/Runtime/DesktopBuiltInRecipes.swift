import Foundation

/// The two P3 workflows, shipped as `amber.recipe.v1` manifests rather than hidden host code.
///
/// A Recipe is installable, inspectable and editable by the user, and every step still goes through the ordinary
/// tool approval card. Installing these on first launch is what makes the workflows real: without them the plugins
/// exist but nothing ever runs them.
@MainActor enum DesktopBuiltInRecipes {
    /// `watchtower` + the host's `scrape_web`. The result JSON carries `changed`, which the scheduler reads to
    /// stay silent when a page has not moved.
    static let watchPageName = "watch_page"
    /// Feishu read → (the model writes the minutes) → one approved closeout call. `meeting_closeout` is idempotent
    /// by key, so re-running this after a review cannot post twice.
    static let meetingLoopName = "feishu_meeting_loop"

    static func manifests(hasFeishu: Bool) -> [DesktopRecipeManifest] {
        [watchPage].compactMap { $0 } + (hasFeishu ? [meetingLoop] : [])
    }

    /// `scrape_web` returns `{status, url, title, content}`; the snapshot tool wants `content` and `url` separately.
    static let watchPage = DesktopRecipeManifest(
        name: watchPageName,
        version: "1.0.0",
        description: "抓取一个网页并与上次快照比较；只有内容变化时才在任务记录里标为本轮有新内容。",
        inputs: ["url": .string],
        steps: [
            DesktopRecipeStep(id: "fetch", tool: "scrape_web",
                arguments: ["url": DesktopRecipeJSONValue.string("${input.url}")], timeoutSeconds: 90),
            DesktopRecipeStep(id: "compare", tool: "plugin__watchtower__snapshot",
                arguments: [
                    "url": DesktopRecipeJSONValue.string("${input.url}"),
                    "title": DesktopRecipeJSONValue.string("${step.fetch.output.title}"),
                    "content": DesktopRecipeJSONValue.string("${step.fetch.output.content}"),
                ], timeoutSeconds: 30),
        ],
        outputs: [
            "changed": .string("${step.compare.output.changed}"),
            "quiet": .string("${step.compare.output.quiet}"),
            "added": .string("${step.compare.output.added}"),
        ]
    )

    /// The gaps in a meeting are filled by the model; this Recipe covers the two writes that must be reproducible.
    /// `title` and `minutes` are the reviewed text the user already saw in the conversation.
    static let meetingLoop = DesktopRecipeManifest(
        name: meetingLoopName,
        version: "1.0.0",
        description: "把已确认的会议纪要建成飞书云文档并发出群回执；同一个会议重复执行不会重复发送。",
        inputs: ["title": .string, "minutes": .string],
        steps: [
            DesktopRecipeStep(id: "closeout", tool: "plugin__feishu_calendar__meeting_closeout",
                arguments: [
                    "title": DesktopRecipeJSONValue.string("${input.title}"),
                    "minutes": DesktopRecipeJSONValue.string("${input.minutes}"),
                ], timeoutSeconds: 120),
        ],
        outputs: [
            "document_id": .string("${step.closeout.output.document_id}"),
            "url": .string("${step.closeout.output.url}"),
            "replayed": .string("${step.closeout.output.replayed}"),
        ]
    )

    /// Writes any missing built-in recipe folder. Existing user edits are never overwritten.
    @discardableResult
    static func install(into directory: URL, hasFeishu: Bool) -> [String] {
        let root = directory.appendingPathComponent("recipes", isDirectory: true)
        var installed: [String] = []
        for manifest in manifests(hasFeishu: hasFeishu) {
            let folder = root.appendingPathComponent(manifest.name, isDirectory: true)
            let file = folder.appendingPathComponent("recipe.json")
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let json = try? manifest.canonicalJSON() else { continue }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(json.utf8).write(to: file, options: .atomic)
                // Enabled on arrival: the workflow is the point, and every write step still asks for approval.
                try Data().write(to: folder.appendingPathComponent(".enabled"), options: .atomic)
                installed.append(manifest.name)
            } catch {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        return installed
    }
}
