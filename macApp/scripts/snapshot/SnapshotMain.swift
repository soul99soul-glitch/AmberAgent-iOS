import AppKit
import SwiftUI
import ServiceManagement
@preconcurrency import GatewayCore
@preconcurrency import GatewayPush

// Offscreen snapshots of the real workspace view; not a production entry point.
@main struct AmberSnapshotMain {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                // `AMBER_SNAPSHOT_ONLY` renders just the named extra views: the full transcript matrix crashes inside
                // SwiftUI's sidebar grouping on this macOS build (reproduced on an unmodified HEAD checkout), and a
                // settings-only capture does not need it.
                let onlyExtras = ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_ONLY"] != nil
                var chat: DesktopWorkspace?
                if !onlyExtras {
                    let workspace = DesktopWorkspace.uiFixture()
                    chat = workspace
                    await workspace.agentTasks.waitUntilLoaded()
                    for (w, h) in [(1440.0, 900.0), (1180.0, 800.0), (860.0, 600.0), (1920.0, 1080.0)] {
                        for dark in [false, true] {
                            try await capture("chat-\(Int(w))-\(dark ? "dark" : "light")", DesktopWorkspaceView(workspace: workspace, searchRequest: 0), w, h, dark)
                        }
                    }
                    let empty = DesktopWorkspace.uiFixture()
                    empty.createConversation()
                    try await capture("empty-1440-light", DesktopWorkspaceView(workspace: empty, searchRequest: 0), 1440, 900, false)
                    try await capture("empty-1440-dark", DesktopWorkspaceView(workspace: empty, searchRequest: 0), 1440, 900, true)
                }
                if let chat, ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_PANELS"] != nil { try await panels(chat) }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_CONTEXT_PANEL"] != nil { try await contextPanel() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_PLUGIN_CAPABILITIES"] != nil {
                    let workspace = DesktopWorkspace.uiFixture()
                    await workspace.agentTasks.waitUntilLoaded()
                    for dark in [false, true] {
                        try await capture("plugin-capabilities-\(dark ? "dark" : "light")",
                            DesktopPluginsSettingsView(plugins: workspace.plugins, workspace: workspace)
                                .frame(width: 880, height: 1500), 880, 1500, dark)
                    }
                }
                // P3 M3.4/M3.2: the host-native calendar plugin's capability matrix, in both appearances.
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_APPLE_SCHEDULE"] != nil {
                    let workspace = DesktopWorkspace.uiFixture()
                    await workspace.agentTasks.waitUntilLoaded()
                    for dark in [false, true] {
                        try await capture("plugin-apple-schedule-\(dark ? "dark" : "light")",
                            DesktopPluginsSettingsView(plugins: workspace.plugins, workspace: workspace,
                                initialSelection: .ext("apple_schedule"),
                                initialTechnicalDetailsExpanded: true)
                                .frame(width: 880, height: 1180), 880, 1180, dark)
                    }
                }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_PLUGIN_INSPECTOR"] != nil {
                    let workspace = DesktopWorkspace.uiFixture()
                    await workspace.agentTasks.waitUntilLoaded()
                    let tempPkg = FileManager.default.temporaryDirectory
                        .appendingPathComponent("amber-snap-plugin-\(UUID().uuidString)", isDirectory: true)
                        .appendingPathComponent("note_helper", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempPkg, withIntermediateDirectories: true)
                    let manifest = """
                    {
                      "schema": "amber.plugin.v2",
                      "id": "note_helper",
                      "name": "会议纪要助手",
                      "version": "1.0.0",
                      "description": "统计纪要字数、附加统一前缀并归档到当前会话工作区。",
                      "icon": "doc.text.magnifyingglass",
                      "capabilities": { "networkDomains": [], "workspaceReadPrefixes": ["notes/"], "workspaceWritePrefixes": ["notes/"] },
                      "settings_schema": [{ "key": "prefix", "title": "纪要标题前缀", "kind": "string", "defaultValue": "【项目纪要】" }],
                      "tools": [{ "name": "format_note", "description": "格式化会议纪要文本", "effect": "pure", "entry": "formatNote", "input_schema": { "type": "object", "properties": { "text": { "type": "string" } } } }],
                      "ui": {
                        "inspectorCards": [{ "id": "note_summary", "title": "纪要助手状态", "symbol": "doc.text.magnifyingglass", "entry": "renderNoteInspector" }],
                        "workspaceViews": [{ "id": "note_board", "title": "纪要工作台", "symbol": "doc.text", "subtitle": "查看已格式化的纪要统计与快捷整理命令。" }]
                      }
                    }
                    """
                    let script = """
                    function formatNote(input) {
                      const prefix = amber.settings.get("prefix") || "【纪要】";
                      const rawText = String((input && input.text) || "").trim();
                      const runs = Number(amber.storage.get("runs") || "0") + 1;
                      const formatted = prefix + rawText;
                      amber.storage.set("runs", String(runs));
                      amber.storage.set("last_note", formatted);
                      return { ok: true, formatted: formatted, run_count: runs };
                    }
                    function renderNoteInspector() {
                      const runs = Number(amber.storage.get("runs") || "0");
                      const lastNote = amber.storage.get("last_note");
                      return {
                        statusBadge: "已处理 " + runs + " 次",
                        emptyMessage: "暂无纪要记录",
                        items: [{
                          id: "latest_note",
                          badge: "最近纪要",
                          title: lastNote || "【项目纪要】确认周五上线 macOS 插件 v2",
                          subtitle: "累计执行 " + runs + " 次 · 工作区前缀 notes/",
                          actionTitle: "继续润色",
                          prompt: "请基于以下纪要继续提炼行动项"
                        }]
                      };
                    }
                    """
                    try Data(manifest.utf8).write(to: tempPkg.appendingPathComponent("plugin.json"))
                    try Data(script.utf8).write(to: tempPkg.appendingPathComponent("main.js"))
                    _ = try workspace.plugins.importPlugin(from: tempPkg)
                    _ = try await workspace.plugins.executeTool(
                        qualifiedName: "plugin__note_helper__format_note",
                        argumentsJSON: #"{"text":"确认周五上线 macOS 插件 v2 与内置开发技能"}"#
                    )
                    for dark in [false, true] {
                        try await capture("plugin-inspector-\(dark ? "dark" : "light")",
                            DesktopInspector(workspace: workspace, onLocate: { _ in }, onOpenFiles: {}, onOpenTasks: {})
                                .frame(width: 340, height: 820)
                                .background(DesktopTheme.paper),
                            340, 820, dark)
                    }
                }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REVIEW_RECOVERY"] != nil { try await reviewRecovery() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REVIEW_PHASE3_UI"] != nil { try await reviewPhase3UI() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REVIEW_PERF3_CACHE"] != nil { try await reviewPerf3Cache() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_SCHEDULES"] != nil { try await schedules() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_GATEWAY"] != nil { try await gatewaySettings() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_PHASE5"] != nil { try await phase5ChangedPages() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_COMPOSER"] != nil { try await composerThinkingSnapshots() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_STREAM"] != nil { try await streaming() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REPLAY"] != nil { try await replay() }
                print("SNAPSHOT COMPLETE"); exit(0)
            } catch { print("SNAPSHOT FAILED", error); exit(1) }
        }
        NSApp.run()
    }

    /// Frames of the streaming fade from one live window: settled text stays solid, only the new tail fades.
    @MainActor static func streaming() async throws {
        let first = "Amber 会把已经出现的文字保持不动，只让新到的这一段慢慢浮现出来，"
        let host = StreamHost(text: first)
        let controller = NSHostingController(rootView: StreamPreview(host: host).environment(\.colorScheme, .light))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 560, height: 200))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        func shot(_ name: String) throws {
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let out = ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_OUT"] ?? "/tmp"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
            print("CAPTURE", name)
        }
        try await Task.sleep(for: .milliseconds(600))
        try shot("stream-0-settled")
        host.text = first + "就像墨水在纸上洇开一样，一行接着一行平稳地向上推。"
        try await Task.sleep(for: .milliseconds(90))
        try shot("stream-1-mid")
        try await Task.sleep(for: .milliseconds(600))
        try shot("stream-2-done")
        window.orderOut(nil)
    }

    /// Stream replay in the real transcript: 60 chunks at 30ms, sampling the reply's bottom edge each frame.
    /// Stable = the bottom edge moves monotonically toward its resting place with no reversals or >40pt jumps.
    @MainActor static func replay() async throws {
        for scenario in ["plain", "reasoning", "regenerate"] { try await replay(scenario) }
    }

    /// Streams into the real transcript and samples (distance-from-bottom, content height) every 8ms.
    @MainActor static func replay(_ scenario: String) async throws {
        let provider = ReplayProvider()
        let settings = DesktopSettings(defaults: UserDefaults(suiteName: "amber.replay.\(UUID().uuidString)")!, credentials: DesktopMemoryCredentials())
        var config = settings.selectedProvider!; config.modelID = "replay"; try settings.saveProvider(config, apiKey: "k")
        var seed = (0..<6).map { i in DesktopMessage(role: i % 2 == 0 ? .user : .assistant, text: String(repeating: "历史消息内容，用来撑出可滚动的高度。", count: 6)) }
        if scenario == "regenerate" { seed.append(DesktopMessage(role: .user, text: "再写一遍")); seed.append(DesktopMessage(role: .assistant, text: "旧回答")) }
        let conversation = DesktopConversation(title: "replay", messages: seed)
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider, initialConversations: [conversation])
        workspace.select(conversation.id)
        let controller = NSHostingController(rootView: DesktopWorkspaceView(workspace: workspace, searchRequest: 0).frame(width: 1180, height: 760))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(800))
        if scenario == "regenerate" { await workspace.regenerate(seed.last!.id)?.value }
        else { workspace.draft = "请写一段长文"; workspace.send() }
        while provider.run == nil { try await Task.sleep(for: .milliseconds(5)) }
        var samples: [CGFloat] = [], heights: [CGFloat] = [], variants: [Int] = []
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let scroll = allViews(controller.view).compactMap({ $0 as? NSScrollView }).max(by: { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }) {
                    samples.append((scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY)
                    heights.append(scroll.documentView?.frame.height ?? 0)
                    variants.append(workspace.selectedConversation?.messages.last?.variantCount ?? 0)
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        var text = "", reasoning = ""
        for i in 0..<60 {
            if scenario == "reasoning", i < 25 { reasoning += "先分析第\(i)个要点，再权衡取舍。" }
            else { text += "第\(i)段：流式生成的内容逐步到达，需要稳定地向上推移，不能前后跳动。"; if i % 7 == 6 { text += "\n\n" } }
            provider.run?.yield(.snapshot(text: text, reasoning: reasoning))
            try await Task.sleep(for: .milliseconds(30))
        }
        provider.run?.yield(.complete)
        try await Task.sleep(for: .milliseconds(900))
        sampler.cancel()
        var reversals = 0, maxJump: CGFloat = 0, heightDrops = 0
        for i in 12..<samples.count {
            let d1 = samples[i - 1] - samples[i - 2], d2 = samples[i] - samples[i - 1]
            if d1 < -1, d2 > 1 { reversals += 1 }
            maxJump = max(maxJump, abs(d2))
            if heights[i] < heights[i - 1] - 1 { heightDrops += 1 }
        }
        let variantDrops = zip(variants, variants.dropFirst()).filter { $0 > 1 && $1 < $0 }.count
        print("REPLAY \(scenario) samples=\(samples.count) maxDistance=\(Int(samples.dropFirst(12).max() ?? 0)) final=\(Int(samples.last ?? -1)) reversals=\(reversals) maxFrameJump=\(Int(maxJump)) heightDrops=\(heightDrops) variantDrops=\(variantDrops)")
        window.orderOut(nil)
    }

    @MainActor static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    @MainActor static func panels(_ workspace: DesktopWorkspace) async throws {
        await workspace.collaborations.waitUntilLoaded()
        let owner = workspace.selectedID!
        let shots: [(String, AnyView, CGFloat, CGFloat)] = [
            ("panel-settings", AnyView(PreviewSettingsView(workspace: workspace)), 880, 700),
            ("panel-plugins", AnyView(DesktopPluginsSettingsView(plugins: workspace.plugins, workspace: workspace).frame(width: 880, height: 640)), 880, 640),
            ("panel-knowledge", AnyView(DesktopKnowledgeView(store: workspace.knowledge, conversationIDs: [owner], onOpenSource: { _, _ in })), 860, 680),
            ("panel-tasks", AnyView(DesktopAgentTasksView(workspace: workspace)), 860, 640),
            ("panel-collaboration", AnyView(DesktopCollaborationsView(workspace: workspace, onOpenSavedResult: { _, _ in })), 860, 760),
            ("panel-recipes", AnyView(DesktopRecipesView(workspace: workspace)), 860, 720),
            ("panel-files", AnyView(DesktopWorkspaceFilesView(workspace: workspace)), 760, 560),
            ("panel-backup", AnyView(DesktopBackupView(workspace: workspace)), 760, 560),
            ("panel-insights", AnyView(DesktopConversationInsightsView(workspace: workspace)), 440, 560),
            ("panel-shelf", AnyView(DesktopArtifactShelfView(workspace: workspace, onLocate: { _ in })), 440, 480),
            ("panel-image", AnyView(DesktopImageGenerationView(workspace: workspace, ownerID: owner)), 760, 640),
            ("panel-storage", AnyView(DesktopStorageUsageView(sources: workspace.storageUsageSources, conversationCount: workspace.summaries.count)), 760, 560),
            ("panel-search", AnyView(DesktopSearchSettingsView(settings: workspace.searchSettings)), 560, 420),
            ("panel-presets", AnyView(DesktopProviderPresetPicker { _, _ in }), 620, 600),
        ]
        for (name, view, w, h) in shots {
            for dark in [false, true] { try await capture("\(name)-\(dark ? "dark" : "light")", view.background(DesktopTheme.paper), w, h, dark) }
        }
        let pluginWS = DesktopWorkspace.uiFixture()
        await pluginWS.agentTasks.waitUntilLoaded()
        pluginWS.openPluginView(pluginID: "feishu_calendar", viewID: "calendar_board")
        for dark in [false, true] {
            try await capture("plugin-feishu-board-\(dark ? "dark" : "light")", DesktopWorkspaceView(workspace: pluginWS, searchRequest: 0), 1440, 900, dark)
        }
        pluginWS.openChatSurface()
        pluginWS.draft = "/feishu"
        for dark in [false, true] {
            try await capture("plugin-slash-composer-\(dark ? "dark" : "light")", DesktopWorkspaceView(workspace: pluginWS, searchRequest: 0), 1440, 900, dark)
            try await capture("plugin-command-palette-\(dark ? "dark" : "light")",
                DesktopCommandPaletteView(workspace: pluginWS, onDismiss: {}).background(DesktopTheme.paper), 540, 520, dark)
        }
    }

    /// Context panel: provider-reported cache usage, then the budget-fit notice after a turn is sent at a 6k
    /// window. Captures both the standalone panel and the docked inspector inside the real workspace window.
    @MainActor static func contextPanel() async throws {
        // Dock the inspector beside the transcript (it needs a detail column of at least 1080pt).
        UserDefaults.standard.set(true, forKey: "desktop.inspector.visible")
        let idle = DesktopWorkspace.uiContextFixture()
        await idle.agentTasks.waitUntilLoaded()
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            try await capture("panel-insights-usage-\(scheme)",
                DesktopConversationInsightsView(workspace: idle).background(DesktopTheme.paper), 440, 520, dark)
            try await capture("workspace-inspector-\(scheme)", DesktopWorkspaceView(workspace: idle, searchRequest: 0), 1440, 900, dark)
        }

        let trimmed = DesktopWorkspace.uiContextFixture()
        await trimmed.agentTasks.waitUntilLoaded()
        trimmed.draft = "继续整理"
        trimmed.send()
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            try await capture("panel-insights-trimmed-\(scheme)",
                DesktopConversationInsightsView(workspace: trimmed).background(DesktopTheme.paper), 440, 520, dark)
            try await capture("workspace-inspector-trimmed-\(scheme)",
                DesktopWorkspaceView(workspace: trimmed, searchRequest: 0), 1440, 900, dark)
            try await capture("workspace-inspector-trimmed-1180-\(scheme)",
                DesktopWorkspaceView(workspace: trimmed, searchRequest: 0), 1180, 800, dark)
        }
        trimmed.stop()
        _ = await trimmed.flush()
    }

    /// 定时任务 page with a few representative tasks (editing, high-risk badge, history, failures).
    @MainActor static func schedules() async throws {
        let workspace = DesktopWorkspace.uiFixture()
        let scheduler = DesktopScheduler(store: DesktopScheduleStore(directory: nil),
            defaults: UserDefaults(suiteName: "amber.snapshot.schedules.\(UUID().uuidString)")!,
            runner: { _, slot in DesktopScheduleRunRecord(scheduledFor: slot, startedAt: Date(), status: .completed) }, timerEnabled: false)
        workspace.scheduler = scheduler
        await scheduler.waitUntilLoaded()
        let owner = workspace.selectedID
        var daily = DesktopScheduledTask(name: "每日汇总", prompt: "列出会话文件夹里昨天以来新增的文件，按类型分组并写一段两三句的概述。",
            schedule: .daily(hour: 9, minute: 0))
        daily.approval.autoApproveOrdinary = true
        daily.approval.allowedTools = ["workspace_file_list", "workspace_file_read"]
        var weekly = DesktopScheduledTask(name: "周报草稿", prompt: "根据本周对话整理周报草稿。", schedule: .weekly(days: [2, 6], hour: 17, minute: 30))
        if let owner { weekly.output = .appendTo(owner) }
        var cleanup = DesktopScheduledTask(name: "清理构建产物", prompt: "删除 build 目录下超过 7 天的文件。", schedule: .interval(minutes: 360, anchor: Date()))
        cleanup.approval.autoApproveHighRisk = true
        let off = DesktopScheduledTask(name: "季度回顾", prompt: "回顾。", schedule: .weekdays(hour: 8, minute: 15))
        for task in [daily, weekly, cleanup, off] { _ = await scheduler.save(task: task) }
        await scheduler.setEnabled(off.id, false)
        // Seed history through the public run path so the list shows last results.
        _ = scheduler.runNow(daily.id)
        try await Task.sleep(for: .milliseconds(100))
        let view = DesktopScheduledTasksView(workspace: workspace, scheduler: scheduler)
        let board = DesktopBoardView(workspace: workspace, scheduler: scheduler, onOpenConversation: { _ in })
        workspace.showsTaskBoard = true
        for dark in [false, true] {
            try await capture("board-window-\(dark ? "dark" : "light")", DesktopWorkspaceView(workspace: workspace, searchRequest: 0), 1440, 860, dark, settle: .milliseconds(1600))
        }
        for dark in [false, true] {
            try await capture("board-wide-\(dark ? "dark" : "light")", board, 1280, 720, dark, settle: .milliseconds(1400))
            try await capture("board-narrow-\(dark ? "dark" : "light")", board, 760, 900, dark, settle: .milliseconds(1400))
            try await capture("schedules-\(dark ? "dark" : "light")", view.background(DesktopTheme.paper), 900, 700, dark)
            // Full-height editor so the approval section and run history are visible too.
            try await capture("schedules-full-\(dark ? "dark" : "light")", view.frame(height: 1500).background(DesktopTheme.paper), 900, 1500, dark)
        }
        var folder = DesktopScheduledTask(name: "整理下载", prompt: "把新下载的文件按类型归档，并列出它们。", schedule: .daily(hour: 9, minute: 0))
        folder.trigger = .folder(path: NSHomeDirectory() + "/Downloads")
        var agent = DesktopScheduledTask(name: "会话复盘", prompt: "总结这个会话做了什么、还剩什么。", schedule: .daily(hour: 9, minute: 0))
        agent.trigger = .agentSession(.ended)
        for task in [folder, agent] { _ = await scheduler.save(task: task) }
        for dark in [false, true] {
            try await capture("schedules-event-\(dark ? "dark" : "light")",
                DesktopScheduledTasksView(workspace: workspace, scheduler: scheduler, initialSelection: folder.id).background(DesktopTheme.paper), 900, 760, dark)
        }
        try await capture("schedules-event-session-light",
            DesktopScheduledTasksView(workspace: workspace, scheduler: scheduler, initialSelection: agent.id).background(DesktopTheme.paper), 900, 760, false)
    }

    /// Mac Gateway settings tab and pairing sheet against a throwaway state dir (the SMAppService is not registered).
    @MainActor static func gatewaySettings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-snapshot-gateway-\(UUID().uuidString)")
        let paths = GatewayPaths(stateDir: dir)
        try paths.ensureDirectories()
        var phone = PairedDevice(id: "a1b2c3d4-0000", name: "iPhone 17 Pro", platform: .ios, tokenHash: "x", pairedAt: Date().addingTimeInterval(-86_400 * 3))
        phone.pushToken = "token"; phone.lastSeenAt = Date().addingTimeInterval(-120)
        let pad = PairedDevice(id: "e5f6-0000", name: "iPad Air", platform: .ios, tokenHash: "y", pairedAt: Date().addingTimeInterval(-86_400 * 20))
        try DeviceStore(url: paths.devices).update { $0 = [phone, pad] }
        try CredentialStore(dir: paths.secretsDir).save(["x": 1], as: .apns)
        let gateway = DesktopGateway(paths: paths, installation: GatewayInstallation(home: dir), service: SMAppService.agent(plistName: "snapshot.plist"),
            bundledBinary: dir.appendingPathComponent("amber-gateway"))
        gateway.snapshotStatus(.running)
        for dark in [false, true] {
            try await capture("gateway-\(dark ? "dark" : "light")", DesktopGatewaySettingsView(gateway: gateway).background(DesktopTheme.paper), 880, 640, dark)
        }
        gateway.snapshotPairing(DesktopGateway.PairingSession(url: "amber://gateway/pair?p=" + String(repeating: "eyJhZGRycyI6WyJNSWRlaU1hYy5sb2NhbCJd", count: 8),
            fingerprint: "dRYQr6unJIiHVKILDj8xsjVhbVkkP56Zh+fdphYGReg=", addresses: ["MIdeiMac.local", "192.168.31.49"],
            expiresAt: Date().addingTimeInterval(272), knownDeviceIds: []))
        for dark in [false, true] {
            try await capture("gateway-pair-\(dark ? "dark" : "light")", DesktopGatewayPairingSheet(gateway: gateway), 420, 600, dark)
        }
        gateway.snapshotStatus(.off)
        try await capture("gateway-off-light", DesktopGatewaySettingsView(gateway: gateway).background(DesktopTheme.paper), 880, 640, false)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Phase 5: Light & dark pairs for the UI pages modified in P2–P4 not already covered by phase1/phase3 folders.
    @MainActor static func phase5ChangedPages() async throws {
        let workspace = DesktopWorkspace.uiFixture()
        await workspace.agentTasks.waitUntilLoaded()

        // 1. Provider settings showing Claude promptCaching toggle
        let claudeModel = DesktopModelConfiguration(modelID: "claude-sonnet-4-5", contextWindowTokens: 200_000, maxOutputTokens: 8_192)
        var claudeProvider = DesktopProviderConfiguration(
            name: "Anthropic Claude",
            kind: .claude,
            baseURL: "https://api.anthropic.com/v1",
            models: [claudeModel],
            selectedModelID: claudeModel.id
        )
        claudeProvider.promptCaching = true
        try? workspace.settings.saveProvider(claudeProvider, apiKey: "sk-ant-fixture")
        workspace.settings.selectedProviderID = claudeProvider.id
        for dark in [false, true] {
            workspace.settings.appearance = dark ? "dark" : "light"
            try await capture("settings-claude-caching-\(dark ? "dark" : "light")",
                PreviewSettingsView(workspace: workspace).frame(width: 880, height: 760), 880, 760, dark)
        }

        // 2. Scheduled tasks view with unattended approval section & run history
        let scheduler = DesktopScheduler(store: DesktopScheduleStore(directory: nil),
            defaults: UserDefaults(suiteName: "amber.snapshot.phase5.schedules.\(UUID().uuidString)")!,
            runner: { _, slot in DesktopScheduleRunRecord(scheduledFor: slot, startedAt: Date(), status: .completed) }, timerEnabled: false)
        workspace.scheduler = scheduler
        await scheduler.waitUntilLoaded()
        var daily = DesktopScheduledTask(name: "每日晨间日程与待办汇总", prompt: "读取今日 Apple 日历与提醒事项，生成三行重点摘要。",
            schedule: .daily(hour: 9, minute: 0))
        daily.approval.autoApproveOrdinary = true
        daily.approval.allowedTools = ["plugin__apple_schedule__list_events", "plugin__apple_schedule__list_reminders"]
        _ = await scheduler.save(task: daily)
        _ = scheduler.runNow(daily.id)
        try await Task.sleep(for: .milliseconds(100))
        for dark in [false, true] {
            workspace.settings.appearance = dark ? "dark" : "light"
            try await capture("scheduled-tasks-approval-\(dark ? "dark" : "light")",
                DesktopScheduledTasksView(workspace: workspace, scheduler: scheduler, initialSelection: daily.id)
                    .frame(width: 900, height: 980).background(DesktopTheme.paper), 900, 980, dark)
        }

        // 3. Feishu Calendar / Bot plugin workspace surface
        for dark in [false, true] {
            workspace.settings.appearance = dark ? "dark" : "light"
            try await capture("plugin-feishu-workspace-\(dark ? "dark" : "light")",
                DesktopPluginWorkspaceView(workspace: workspace, pluginID: "feishu_calendar", viewID: "calendar_board")
                    .frame(width: 1080, height: 760).background(DesktopTheme.paper), 1080, 760, dark)
        }

        // 4. Expanded tool call card with apple_schedule summary badge
        let sampleTool = DesktopToolCall(
            id: "call_apple_1",
            name: "plugin__apple_schedule__list_events",
            input: #"{"start_at":"2026-10-31T09:00","end_at":"2026-10-31T18:00"}"#,
            output: #"{"ok":true,"count":2,"events":[{"id":"evt_1","title":"产品周会","start_at":"2026-10-31T10:00"}]}"#,
            status: .complete
        )
        for dark in [false, true] {
            try await capture("tool-call-card-schedule-\(dark ? "dark" : "light")",
                DesktopToolCallCard(tool: sampleTool, expanded: .constant(true))
                    .padding(24)
                    .frame(width: 640, height: 340, alignment: .topLeading)
                    .background(DesktopTheme.paper), 640, 340, dark)
        }
    }

    /// Phase 1 UI review states. This is opt-in so the normal snapshot set is unchanged.
    @MainActor static func reviewRecovery() async throws {
        let defaults = UserDefaults(suiteName: "amber.review.recovery.\(UUID().uuidString)")!
        let raw = Data("{\"broken_settings\":true}".utf8)
        defaults.set(raw, forKey: "desktop.settings.v1")
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        let conversation = DesktopConversation(title: "恢复提示示例", messages: [DesktopMessage(role: .assistant, text: "用于产物架保存失败状态的示例消息。")])
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: ReplayProvider(), initialConversations: [conversation])
        await workspace.agentTasks.waitUntilLoaded()
        for dark in [false, true] {
            try await capture("review-recovery-settings-\(dark ? "dark" : "light")",
                AnyView(PreviewSettingsView(workspace: workspace)), 880, 760, dark)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amber-review-shelf-\(UUID().uuidString)", isDirectory: true)
        let shelfDirectory = root.appendingPathComponent("shelf", isDirectory: true)
        let shelfURL = shelfDirectory.appendingPathComponent("artifact-shelf.json")
        try FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: shelfURL)
        let shelf = DesktopArtifactShelf(fileURL: shelfURL)
        try FileManager.default.removeItem(at: shelfDirectory)
        try Data("blocked".utf8).write(to: shelfDirectory)
        shelf.pin(messageID: conversation.messages[0].id, kind: .message, text: "保存失败后仍保留在本次运行", in: conversation.id)
        let shelfWorkspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: ReplayProvider(), initialConversations: [conversation], artifactShelf: shelf)
        for dark in [false, true] {
            try await capture("review-shelf-save-error-\(dark ? "dark" : "light")",
                AnyView(DesktopArtifactShelfView(workspace: shelfWorkspace, onLocate: { _ in })), 440, 480, dark)
        }
    }

    /// Phase 3 UI states. This is opt-in and uses isolated fixture workspaces only.
    @MainActor static func reviewPhase3UI() async throws {
        UserDefaults.standard.set(true, forKey: "desktop.inspector.visible")
        UserDefaults.standard.set("", forKey: "desktop.inspector.collapsed")

        let fixture = DesktopWorkspace.uiFixture()
        await fixture.agentTasks.waitUntilLoaded()
        guard let conversation = fixture.selectedConversation else { throw DesktopRuntimeError.message("fixture conversation") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amber-review-phase3-\(UUID().uuidString)", isDirectory: true)
        let attachmentURL = root.appendingPathComponent("budget.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "待发送附件文字，用于核对上下文预算。", count: 120).utf8).write(to: attachmentURL)
        await fixture.addAttachments([attachmentURL])?.value
        for dark in [false, true] {
            try await capture("review-inspector-attachment-1440-\(dark ? "dark" : "light")",
                DesktopWorkspaceView(workspace: fixture, searchRequest: 0), 1440, 900, dark)
            try await capture("review-inspector-attachment-860-\(dark ? "dark" : "light")",
                DesktopWorkspaceView(workspace: fixture, searchRequest: 0), 860, 600, dark)
        }

        func workspace(files: DesktopWorkspaceFiles? = nil, tasks: DesktopAgentTasks? = nil) -> DesktopWorkspace {
            DesktopWorkspace(settings: fixture.settings, storage: DesktopMemoryConversationStorage([conversation]),
                provider: ReplayProvider(), initialConversations: [conversation], files: files ?? DesktopWorkspaceFiles(),
                agentTasks: tasks ?? DesktopAgentTasks(defaults: UserDefaults(suiteName: "amber.review.phase3.tasks.\(UUID().uuidString)")!))
        }

        let loadingRoot = root.appendingPathComponent("loading-files", isDirectory: true)
        try FileManager.default.createDirectory(at: loadingRoot, withIntermediateDirectories: true)
        for index in 0..<3_000 {
            FileManager.default.createFile(atPath: loadingRoot.appendingPathComponent("file-\(index).txt").path,
                contents: Data("loading".utf8))
        }
        let loading = workspace(files: DesktopWorkspaceFiles(directory: loadingRoot))
        for dark in [false, true] {
            let inspector = DesktopInspector(workspace: loading, onLocate: { _ in }, onOpenFiles: {}, onOpenTasks: {})
            try await capture("review-inspector-files-loading-1440-\(dark ? "dark" : "light")",
                inspector.frame(width: 300, height: 760), 300, 760, dark, settle: .milliseconds(5))
        }

        let fileErrorTarget = root.appendingPathComponent("file-error-target", isDirectory: true)
        let fileErrorLink = root.appendingPathComponent("file-error-link", isDirectory: true)
        try FileManager.default.createDirectory(at: fileErrorTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileErrorLink, withDestinationURL: fileErrorTarget)
        let fileErrorWorkspace = workspace(files: DesktopWorkspaceFiles(directory: fileErrorLink))
        await fileErrorWorkspace.reloadFiles()?.value
        for dark in [false, true] {
            try await capture("review-inspector-files-error-1440-\(dark ? "dark" : "light")",
                DesktopWorkspaceView(workspace: fileErrorWorkspace, searchRequest: 0), 1440, 900, dark)
            try await capture("review-files-error-760-\(dark ? "dark" : "light")",
                AnyView(DesktopWorkspaceFilesView(workspace: fileErrorWorkspace)), 760, 560, dark)
        }

        let blockedTasks = root.appendingPathComponent("blocked-tasks")
        try Data("blocked".utf8).write(to: blockedTasks)
        let taskJournal = DesktopAgentTasks(directory: blockedTasks,
            defaults: UserDefaults(suiteName: "amber.review.phase3.task-error.\(UUID().uuidString)")!)
        await taskJournal.waitUntilLoaded()
        let taskErrorWorkspace = workspace(tasks: taskJournal)
        for dark in [false, true] {
            try await capture("review-inspector-task-error-1440-\(dark ? "dark" : "light")",
                DesktopWorkspaceView(workspace: taskErrorWorkspace, searchRequest: 0), 1440, 900, dark)
        }

        UserDefaults.standard.set("context,files,tasks", forKey: "desktop.inspector.collapsed")
        for dark in [false, true] {
            try await capture("review-inspector-collapsed-1440-\(dark ? "dark" : "light")",
                DesktopWorkspaceView(workspace: fixture, searchRequest: 0), 1440, 900, dark)
        }
        fixture.settings.sendShortcut = .returnKey
        for dark in [false, true] {
            try await capture("review-composer-shortcut-860-\(dark ? "dark" : "light")",
                DesktopWorkspaceView(workspace: fixture, searchRequest: 0), 860, 600, dark)
        }
        UserDefaults.standard.set("", forKey: "desktop.inspector.collapsed")
    }

    /// Reuses one live Markdown view while changing font, appearance and source to exercise cache invalidation.
    @MainActor static func reviewPerf3Cache() async throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let host = Perf3MarkdownHost(text: """
        # Cache review

        ```swift
        let answer = 42
        return answer
        ```

        Inline math $E=mc^2$ and $\\frac{a+b}{c}$ should remain readable.

        $$
        \\frac{a+b}{c}
        $$
        """, fontSize: 15, dark: false)
        let controller = NSHostingController(rootView: Perf3MarkdownPreview(host: host))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 760, height: 520))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)

        func shot(_ name: String) throws {
            controller.view.layoutSubtreeIfNeeded()
            guard let frameView = window.contentView?.superview,
                  let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { throw DesktopRuntimeError.message("bitmap") }
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            let out = ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_OUT"] ?? "/tmp"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
            print("CAPTURE", name)
        }

        try await Task.sleep(for: .milliseconds(900))
        try shot("review-perf3-cache-stable-light")
        host.fontSize = 17
        try await Task.sleep(for: .milliseconds(200))
        try shot("review-perf3-cache-font-light")
        host.dark = true
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(200))
        try shot("review-perf3-cache-appearance-dark")
        host.text = host.text
            .replacingOccurrences(of: "let answer = 42", with: "let answer = 43")
            .replacingOccurrences(of: "$E=mc^2$", with: "$E=mc^3$")
            .replacingOccurrences(of: "\\frac{a+b}{c}", with: "\\frac{a-b}{c}")
        try await Task.sleep(for: .milliseconds(200))
        try shot("review-perf3-cache-content-dark")
        window.orderOut(nil)
    }

    @MainActor static func composerThinkingSnapshots() async throws {
        func makeWorkspace(kind: DesktopProviderKind, baseURL: String, modelID: String, level: DesktopReasoningLevel) -> DesktopWorkspace {
            let suiteName = "amber.snap.composer.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
            if var provider = settings.selectedProvider {
                provider.name = kind == .claude ? "Anthropic" : "OpenAI"
                provider.kind = kind
                provider.baseURL = baseURL
                let model = DesktopModelConfiguration(modelID: modelID, reasoning: level)
                provider.models = [model]
                provider.selectedModelID = model.id
                try? settings.saveProvider(provider, apiKey: "snap-key")
            }
            let conv = DesktopConversation(title: "思考等级验收", messages: [
                DesktopMessage(role: .user, text: "帮我梳理架构演进方案并评估风险。")
            ])
            let ws = DesktopWorkspace(
                settings: settings,
                storage: DesktopMemoryConversationStorage([conv]),
                provider: ReplayProvider(),
                initialConversations: [conv],
                agentTasks: DesktopAgentTasks(defaults: defaults)
            )
            ws.select(conv.id)
            ws.setThinkingLevel(level)
            return ws
        }

        let wsHigh = makeWorkspace(
            kind: .claude,
            baseURL: "https://api.anthropic.com",
            modelID: "claude-sonnet-4-6",
            level: .high
        )
        let wsOff = makeWorkspace(
            kind: .claude,
            baseURL: "https://api.anthropic.com",
            modelID: "claude-sonnet-4-6",
            level: .off
        )
        let wsUnsupported = makeWorkspace(
            kind: .openAI,
            baseURL: "https://api.openai.com/v1",
            modelID: "gpt-4.1-mini",
            level: .off
        )
        await wsHigh.agentTasks.waitUntilLoaded()
        await wsOff.agentTasks.waitUntilLoaded()
        await wsUnsupported.agentTasks.waitUntilLoaded()

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await capture(
                "composer-thinking-\(suffix)",
                VStack(spacing: 0) {
                    Spacer(minLength: 16)
                    DesktopComposer(workspace: wsHigh)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
                .frame(width: 780, height: 168)
                .background(DesktopTheme.paper),
                780, 168, dark
            )
            try await capture(
                "composer-thinking-states-\(suffix)",
                VStack(alignment: .leading, spacing: 14) {
                    DesktopComposer(workspace: wsHigh)
                    DesktopComposer(workspace: wsOff)
                    DesktopComposer(workspace: wsUnsupported)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(width: 780, height: 420)
                .background(DesktopTheme.paper),
                780, 420, dark
            )
        }
    }

    @MainActor static func capture<V: View>(_ name: String, _ view: V, _ width: CGFloat, _ height: CGFloat, _ dark: Bool,
                                            settle: Duration = .milliseconds(900)) async throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view.frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(DesktopTheme.accent)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        try await Task.sleep(for: settle)
        controller.view.layoutSubtreeIfNeeded()
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { throw DesktopRuntimeError.message("bitmap") }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let out = ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_OUT"] ?? "/tmp"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
        print("CAPTURE", name)
        window.orderOut(nil)
    }
}

@MainActor @Observable final class Perf3MarkdownHost {
    var text: String
    var fontSize: Double
    var dark: Bool

    init(text: String, fontSize: Double, dark: Bool) {
        self.text = text
        self.fontSize = fontSize
        self.dark = dark
    }
}

struct Perf3MarkdownPreview: View {
    let host: Perf3MarkdownHost

    var body: some View {
        ScrollView {
            DesktopMarkdown(text: host.text, fontSize: host.fontSize)
                .padding(28)
        }
        .environment(\.colorScheme, host.dark ? .dark : .light)
        .background(DesktopTheme.paper)
    }
}

@MainActor @Observable final class StreamHost { var text: String; init(text: String) { self.text = text } }

struct StreamPreview: View {
    let host: StreamHost
    var body: some View {
        DesktopMarkdown(text: host.text, fontSize: 15, streaming: true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24).frame(width: 560, height: 200, alignment: .topLeading).background(DesktopTheme.paper)
    }
}

@MainActor final class ReplayProvider: DesktopTextProvider {
    var run: DesktopGeneration?
    func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
        let generation = DesktopGeneration(); run = generation; return generation
    }
}
