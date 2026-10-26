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
                print("SNAPSHOT COMPLETE"); exit(0)
            } catch { print("SNAPSHOT FAILED", error); exit(1) }
        }
        NSApp.run()
    }

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
