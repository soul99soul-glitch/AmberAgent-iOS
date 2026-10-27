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
                let chat = DesktopWorkspace.uiFixture()
                await chat.agentTasks.waitUntilLoaded()
                for (w, h) in [(1440.0, 900.0), (1180.0, 800.0), (860.0, 600.0), (1920.0, 1080.0)] {
                    for dark in [false, true] {
                        try await capture("chat-\(Int(w))-\(dark ? "dark" : "light")", DesktopWorkspaceView(workspace: chat, searchRequest: 0), w, h, dark)
                    }
                }
                let empty = DesktopWorkspace.uiFixture()
                empty.createConversation()
                try await capture("empty-1440-light", DesktopWorkspaceView(workspace: empty, searchRequest: 0), 1440, 900, false)
                try await capture("empty-1440-dark", DesktopWorkspaceView(workspace: empty, searchRequest: 0), 1440, 900, true)
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_PANELS"] != nil { try await panels(chat) }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REVIEW_RECOVERY"] != nil { try await reviewRecovery() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REVIEW_PHASE3_UI"] != nil { try await reviewPhase3UI() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_REVIEW_PERF3_CACHE"] != nil { try await reviewPerf3Cache() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_SCHEDULES"] != nil { try await schedules() }
                if ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_GATEWAY"] != nil { try await gatewaySettings() }
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
