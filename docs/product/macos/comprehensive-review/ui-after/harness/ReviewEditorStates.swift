import AppKit
import SwiftUI

@MainActor private final class ReviewEditorSubmission: ObservableObject {
    @Published var isPresented = false
    private(set) var calls: [String] = []
    private var pending: CheckedContinuation<String?, Never>?

    func submit(_ text: String) async -> String? {
        calls.append(text)
        return await withCheckedContinuation { pending = $0 }
    }

    func finish(_ error: String?) {
        let callback = pending
        pending = nil
        callback?.resume(returning: error)
    }
}

private struct ReviewEditorHost: View {
    @ObservedObject var submission: ReviewEditorSubmission
    let draft: String
    var body: some View {
        Color.clear.frame(width: 760, height: 620)
            .sheet(isPresented: $submission.isPresented) {
                DesktopMessageEditor(initialText: draft, followingCount: 3, canSubmit: true,
                    onSubmit: submission.submit)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light)
                    .tint(DesktopTheme.accent)
            }
    }
}

extension AmberOffscreenMain {
    @MainActor static func captureEditorStates() async throws {
        if let filter = ProcessInfo.processInfo.environment["AMBER_OFFSCREEN_FILTER"], !"phase3-editor".hasPrefix(filter) { return }
        let draft = "这是修改后的消息草稿。\n保存失败后必须完整保留；修复配置或磁盘后可以直接重试。"
        NSApp.setActivationPolicy(.accessory)
        let state = ReviewEditorSubmission()
        let controller = NSHostingController(rootView: ReviewEditorHost(submission: state, draft: draft).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 760, height: 620),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        state.isPresented = true
        try await waitForEditor { window.attachedSheet != nil || NSApp.windows.contains { $0 !== window && $0.isVisible && $0.contentView != nil } }
        guard let sheet = window.attachedSheet ?? NSApp.windows.first(where: { $0 !== window && $0.isVisible }), let content = sheet.contentView else {
            throw DesktopRuntimeError.message("Real Editor sheet did not appear.")
        }
        try await Task.sleep(for: .milliseconds(450))
        try captureEditorContent(content, name: "phase3-editor-ready")
        assert(pressEditorShortcut(sheet, commandReturn: true))
        try await waitForEditor { state.calls.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        assert(state.calls == [draft])
        _ = pressEditorShortcut(sheet, commandReturn: true)
        _ = pressEditorShortcut(sheet, commandReturn: false)
        try await Task.sleep(for: .milliseconds(150))
        print("EDITOR BUSY STATE", state.calls.count, "presented", state.isPresented, "sheetVisible", sheet.isVisible, "attached", window.attachedSheet != nil)
        assert(state.calls.count == 1 && state.isPresented && sheet.isVisible)
        try captureEditorContent(content, name: "phase3-editor-busy")
        let failure = String(repeating: "消息修改未保存，原分支已保留。请检查磁盘空间和原会话配置后重试。", count: 4)
        state.finish(failure)
        try await Task.sleep(for: .milliseconds(250))
        assert(state.isPresented && sheet.isVisible)
        assert(state.calls == [draft])
        try captureEditorContent(content, name: "phase3-editor-failure")
        assert(pressEditorShortcut(sheet, commandReturn: true))
        try await waitForEditor { state.calls.count == 2 }
        assert(state.calls == [draft, draft])
        state.finish(nil)
        try await waitForEditor { !state.isPresented && !sheet.isVisible }
        print("PHASE3 REAL EDITOR COMPLETE: busy disabled; duplicate blocked; failure preserved exact draft; retry success dismissed")
        window.orderOut(nil)
    }

    @MainActor private static func pressEditorShortcut(_ window: NSWindow, commandReturn: Bool) -> Bool {
        let key = commandReturn ? "\r" : "\u{1b}"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: commandReturn ? [.command] : [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: commandReturn ? 36 : 53)!
        return window.performKeyEquivalent(with: event)
    }

    @MainActor private static func waitForEditor(_ condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw DesktopRuntimeError.message("Timed out waiting for real Editor state.")
    }

    @MainActor private static func editorElements(_ root: Any) -> [any NSAccessibilityProtocol] {
        var pending: [Any] = [root]
        var seen: Set<ObjectIdentifier> = []
        var result: [any NSAccessibilityProtocol] = []
        while let item = pending.popLast() {
            if let view = item as? NSView { pending.append(contentsOf: view.subviews) }
            guard let element = item as? any NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
        }
        return result
    }

    @MainActor private static func editorLabel(_ element: any NSAccessibilityProtocol) -> String {
        element.accessibilityLabel() ?? element.accessibilityTitle() ?? ""
    }

    @MainActor private static func captureEditorContent(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DesktopRuntimeError.message("Cannot render real Editor content.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw DesktopRuntimeError.message("Cannot encode real Editor capture.")
        }
        try png.write(to: URL(fileURLWithPath: "/Users/mi/Downloads/AI/AmberAgent/ios/docs/product/macos/comprehensive-review/ui-after/components/" + name + ".png"))
        print("EDITOR CAPTURE", name, view.bounds)
    }
}
