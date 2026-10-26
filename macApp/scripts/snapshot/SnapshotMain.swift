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
                print("SNAPSHOT COMPLETE"); exit(0)
            } catch { print("SNAPSHOT FAILED", error); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func capture<V: View>(_ name: String, _ view: V, _ width: CGFloat, _ height: CGFloat, _ dark: Bool) async throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view.frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(DesktopTheme.accent)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(700))
        hosting.layoutSubtreeIfNeeded()
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { throw DesktopRuntimeError.message("bitmap") }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let out = ProcessInfo.processInfo.environment["AMBER_SNAPSHOT_OUT"] ?? "/tmp"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
        print("CAPTURE", name)
        window.orderOut(nil)
    }
}
