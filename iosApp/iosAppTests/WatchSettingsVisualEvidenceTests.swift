import SwiftUI
import XCTest
@testable import iosApp

/// Production SwiftUI rendered with isolated data. Inspect the attachments;
/// passing these bounds checks alone does not establish visual correctness.
@MainActor
final class WatchSettingsVisualEvidenceTests: XCTestCase {
    func testSettingsFamilyAndWatchStatesLayoutEvidence() async throws {
        let suite = "WatchSettingsVisual.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("zh-Hans", forKey: IOSAppLanguagePreference.defaultsKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let service = IOSWatchCompanionService(baseDirectory: root.appendingPathComponent("watch"), defaults: defaults)
        let conversations = IOSConversationStore(baseDirectory: root.appendingPathComponent("conversations"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func capture(_ view: AnyView, name: String, size: CGSize = CGSize(width: 430, height: 932),
                     type: DynamicTypeSize = .large, style: UIUserInterfaceStyle = .light,
                     bottom: Bool = false, allScrollPositions: Bool = false) async throws {
            let host = UIHostingController(rootView: view
                .defaultAppStorage(defaults)
                .environment(\.dynamicTypeSize, type)
                .environment(\.locale, Locale(identifier: "zh_Hans")))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = style
            host.overrideUserInterfaceStyle = style
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(350))
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 1)
            if bottom {
                let scroll = try XCTUnwrap(findScrollView(in: host.view))
                scroll.setContentOffset(CGPoint(x: 0, y: max(0,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
            }
            func saveFrame(_ frameName: String) throws {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = frameName
                attachment.lifetime = .keepAlways
                add(attachment)
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(frameName).png")
                try XCTUnwrap(image.pngData()).write(to: output)
                print("WATCH_LAYOUT_EVIDENCE \(output.path)")
            }
            try saveFrame(name)
            if allScrollPositions {
                let scroll = try XCTUnwrap(findScrollView(in: host.view))
                let last = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                var offset: CGFloat = 0
                var index = 0
                while offset < last {
                    offset = min(last, offset + scroll.bounds.height)
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    index += 1
                    try saveFrame("\(name)-scroll-\(index)")
                }
            }
        }
        let watchView = AnyView(IOSWatchSettingsView(sharedSettings: settings, conversationStore: conversations, service: service))
        try await capture(AnyView(SettingsHomeView(settingsStore: SettingsStore(userDefaults: defaults), sharedSettings: settings)
            .environment(RouterPath())), name: "phone-settings-home")
        try await capture(AnyView(LanguageSettingsView()), name: "phone-settings-language-reference")
        try await capture(watchView, name: "phone-watch-empty")
        try await capture(watchView, name: "phone-watch-empty-dark", style: .dark)
        _ = service.saveQuickAction(title: "为下周准备一份可执行的阅读和写作计划", prompt: "根据每天三十分钟的空闲时间，帮我设计一周阅读与写作的安排，并给出第一天可以立即开始的步骤。", sharedSettings: settings)
        _ = service.saveNote(WatchNote(id: "layout-note", text: "一条用于检查多行文字和操作区域的手表记事。原文需要完整保留，并且可以打开查看。", createdAt: Date(), syncedAt: Date()))
        try await capture(watchView, name: "phone-watch-populated")
        let expandedWatchView = AnyView(IOSWatchSettingsView(sharedSettings: settings, conversationStore: conversations,
            service: service, initiallyShowsNotes: true))
        try await capture(expandedWatchView, name: "phone-watch-notes-expanded")
        try await capture(watchView, name: "phone-watch-populated-bottom", bottom: true)
        for (name, type) in [("phone-watch-compact", DynamicTypeSize.large), ("phone-watch-accessibility", .accessibility3)] {
            let size = CGSize(width: 320, height: 568)
            try await capture(watchView, name: name, size: size, type: type)
            try await capture(watchView, name: name + "-bottom", size: size, type: type, bottom: true)
        }
        try await capture(expandedWatchView, name: "phone-watch-accessibility-expanded",
            size: CGSize(width: 320, height: 568), type: .accessibility3, allScrollPositions: true)
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
