import Foundation

/// `watchtower`: a pure-JavaScript plugin that stores a page snapshot and reports what changed.
///
/// The sandbox has no HTTP client, so the page text always arrives as a tool argument: a Recipe (or a scheduled
/// task) calls the host's `scrape_web` first and binds `${step.fetch.output.content}` into `plugin__watchtower__snapshot`.
/// Nothing here opens a socket, which is why this plugin is safe to enable by default.
@MainActor enum DesktopWatchtower {
    static let pluginID = "watchtower"
    /// How many lines of each page are kept. Snapshots live in the plugin's own storage.json.
    static let storedLines = 400
    /// Lines quoted back to the model; a diff is a hint, not a copy of the page.
    static let reportedLines = 8

    /// Reads a run's tool calls and answers: did watchtower run, and did every snapshot see nothing new?
    /// nil = watchtower never ran (or a snapshot call failed), so the run keeps its normal notification behaviour.
    static func quietVerdict(tools: [DesktopToolCall]) -> Bool? {
        let calls = tools.filter { $0.name == "plugin__\(pluginID)__snapshot" }
        guard !calls.isEmpty else { return nil }
        var anyChanged = false
        for call in calls {
            guard call.status == .complete,
                  let data = call.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["ok"] as? Bool) == true,
                  let changed = object["changed"] as? Bool else {
                return nil
            }
            if changed { anyChanged = true }
        }
        return !anyChanged
    }

    static func makeBuiltInPlugin(enabled: Bool) -> DesktopInstalledPlugin {
        let manifest = DesktopPluginManifest(
            schema: DesktopPluginManifest.schemaV2,
            id: pluginID,
            name: "网页监控",
            version: "1.0.0",
            description: "保存网页正文快照并与上次比较；只有内容变化时才提醒。抓取由宿主的 scrape_web 完成，沙箱本身不联网。",
            icon: "binoculars",
            // No domains: the sandbox cannot send requests, and saying otherwise would be a lie in the settings page.
            capabilities: DesktopPluginCapabilities(),
            settingsSchema: [],
            tools: [
                DesktopPluginToolManifest(
                    name: "snapshot",
                    description: "保存或比较一页网页正文的快照；没有变化时返回 changed=false，供定时任务保持安静。",
                    effect: .pure,
                    entry: "watchPage",
                    parametersJSON: #"{"type":"object","properties":{"url":{"type":"string","description":"要监控的页面地址"},"content":{"type":"string","description":"scrape_web 返回的正文"},"title":{"type":"string"}},"required":["url","content"],"additionalProperties":false}"#
                ),
                DesktopPluginToolManifest(
                    name: "status",
                    description: "查看已保存快照的页面清单与最近一次检查日期。",
                    effect: .pure,
                    entry: "watchStatus",
                    parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#
                ),
            ],
            ui: DesktopPluginUIManifest(
                commands: [
                    DesktopPluginCommandManifest(id: "watch_page", title: "开始监控一个网页",
                        slash: "/watch", symbol: "binoculars",
                        promptTemplate: "请先用 scrape_web 抓取这个网页，再把正文交给 plugin__watchtower__snapshot 建立基线快照，然后告诉我监控已开始：\n")
                ]
            )
        )
        return DesktopInstalledPlugin(manifest: manifest, scriptSource: script, enabled: enabled, isBuiltIn: true)
    }

    /// Kept as a string (not a resource file) so the built-in plugin behaves exactly like an imported one:
    /// the same `JSContext`, the same `amber.settings` / `amber.storage` surface, no extra host hooks.
    static let script = #"""
    function _stableHash(text) {
        var hash = 2166136261;
        for (var i = 0; i < text.length; i++) {
            hash ^= text.charCodeAt(i);
            hash = (hash * 16777619) >>> 0;
        }
        return hash.toString(16);
    }

    function _lines(text) {
        var raw = String(text || "").split(/\r\n|\r|\n/);
        var out = [];
        for (var i = 0; i < raw.length && out.length < 400; i++) {
            var line = raw[i].replace(/\s+/g, " ").trim();
            if (line.length > 0) { out.push(line.slice(0, 300)); }
        }
        return out;
    }

    function _read(url) {
        var raw = amber.storage.get("snap:" + url);
        if (!raw) { return null; }
        try {
            var parsed = JSON.parse(raw);
            if (!parsed || typeof parsed.hash !== "string" || !Array.isArray(parsed.lines)) { return null; }
            return parsed;
        } catch (e) {
            return null;
        }
    }

    function watchPage(input) {
        var url = String((input && input.url) || "").trim();
        var content = String((input && input.content) || "");
        if (!url) { return { ok: false, error: "需要 url。" }; }
        if (!content.trim()) { return { ok: false, error: "正文为空，先确认 scrape_web 拿到了页面内容。" }; }

        var lines = _lines(content);
        var hash = _stableHash(lines.join("\n"));
        var previous = _read(url);
        var today = amber.settings.get("today");

        if (previous && previous.hash === hash) {
            amber.storage.set("snap:" + url, JSON.stringify({
                hash: hash, lines: previous.lines, count: previous.count, updated: today
            }));
            return {
                ok: true, url: url, changed: false, quiet: true, first_seen: false,
                checked_on: today, snapshots: previous.count, line_count: lines.length, hash: hash
            };
        }

        var seenBefore = previous ? previous.lines : [];
        var added = [];
        var removed = [];
        var index;
        var present = {};
        for (index = 0; index < lines.length; index++) { present[lines[index]] = true; }
        var previousPresent = {};
        for (index = 0; index < seenBefore.length; index++) { previousPresent[seenBefore[index]] = true; }
        for (index = 0; index < lines.length && added.length < 8; index++) {
            if (!previousPresent[lines[index]]) { added.push(lines[index]); }
        }
        for (index = 0; index < seenBefore.length && removed.length < 8; index++) {
            if (!present[seenBefore[index]]) { removed.push(seenBefore[index]); }
        }

        amber.storage.set("snap:" + url, JSON.stringify({
            hash: hash, lines: lines, count: previous ? previous.count + 1 : 1, updated: today
        }));
        var order = [];
        try { order = JSON.parse(amber.storage.get("watched") || "[]"); } catch (e) { order = []; }
        if (order.indexOf(url) < 0) {
            order.push(url);
            amber.storage.set("watched", JSON.stringify(order.slice(-50)));
        }

        return {
            ok: true, url: url, changed: true, quiet: false, first_seen: previous === null,
            checked_on: today, snapshots: previous ? previous.count + 1 : 1, line_count: lines.length,
            hash: hash, added: added, removed: removed,
            added_count: added.length, removed_count: removed.length
        };
    }

    function watchStatus() {
        var order = [];
        try { order = JSON.parse(amber.storage.get("watched") || "[]"); } catch (e) { order = []; }
        var pages = [];
        for (var i = 0; i < order.length; i++) {
            var snap = _read(order[i]);
            pages.push({
                url: order[i],
                snapshots: snap ? snap.count : 0,
                last_checked: snap ? snap.updated : "",
                line_count: snap ? snap.lines.length : 0
            });
        }
        return { ok: true, count: pages.length, pages: pages };
    }
    """#
}
