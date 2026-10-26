import AppKit
import SwiftUI

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

    @MainActor static func capture<V: View>(_ name: String, _ view: V, _ width: CGFloat, _ height: CGFloat, _ dark: Bool) async throws {
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
        try await Task.sleep(for: .milliseconds(900))
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
