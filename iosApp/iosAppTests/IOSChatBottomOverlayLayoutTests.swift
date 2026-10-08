import XCTest
import SwiftUI
import WebKit
import Shared
@testable import iosApp

@MainActor
final class IOSChatBottomOverlayLayoutTests: XCTestCase {
    func testCompactBrowserStaysImmediatelyAboveSingleAndMultilineComposer() async throws {
        let suite = "ChatBottomOverlay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let conversations = IOSConversationStore(baseDirectory: directory, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()
        let conversationID = try XCTUnwrap(conversations.currentConversation?.id)
        await conversations.saveCurrent(messages: [UIMessage.companion.user(prompt: "读取这个网页。")])
        let settings = SettingsStore(userDefaults: defaults)
        let shared = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "界面测试", apiKey: "fixture-key", baseUrl: "https://example.invalid/v1",
            modelName: "测试模型", modelId: "gpt-4o")
        let added = shared.addProvider(provider)
        let model = try XCTUnwrap(added.models.first { $0.type == ModelType.chat })
        shared.setCurrentChatModelId(model.id.toHexDashString())
        let browser = IOSWebMountController(
            registry: IOSWebMountRegistry(userDefaults: defaults),
            settings: IOSWebMountSettings(userDefaults: defaults),
            cookieStore: IOSWebMountCookieStore(dataStore: .nonPersistent()),
            runtime: IOSWebMountRemotePlaceholderRuntime(),
            runtimeFactory: { IOSWebMountRemotePlaceholderRuntime() },
            sessionDefaults: defaults, mcpServerProvider: { [] })
        let runtime = IOSWebMountRemotePlaceholderRuntime()
        runtime.apply(resultText: "{\"ok\":true,\"current_url\":\"https://example.invalid/page\"}", toolName: "wm_find")
        let session = try browser.sessionStore.newSession(makeCurrent: false, backend: .playwright_mcp, runtime: runtime)
        _ = try browser.sessionStore.bindAgentSession(sessionId: session.id, runId: "layout-run",
            conversationId: conversationID.toHexDashString(), requiresControl: true)
        browser.releaseAgentOwnership(runId: "layout-run")
        XCTAssertNil(browser.sessionStore.record(sessionId: session.id)?.ownerRunId)
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activity = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: Date(), loadRuns: { [] })
        let center = ConversationActivityCenter(conversationStore: conversations,
            dao: IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runs.db").path).agentRuntimeDao())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        for width in [320.0, 393.0] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            let vm = ChatViewModel(settingsStore: settings, sharedSettings: shared, autoGenerateResponses: false)
            let host = UIHostingController(rootView: NavigationStack {
                ChatView(settingsStore: settings, sharedSettings: shared,
                    workspaceStore: IOSWorkspaceStore(baseDirectory: directory.appendingPathComponent("workspace")),
                    viewModel: vm, activityStore: activity, webMountController: browser)
            }.environment(conversations).environment(center).environment(RouterPath())
                .environment(\.dynamicTypeSize, .large).environment(\.locale, Locale(identifier: "zh_Hans")))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            for _ in 0..<50 where vm.conversationStore == nil || vm.currentConversationId != conversationID {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(vm.currentConversationId, conversationID)
            for (name, draft) in [("single", "网页查询"), ("multiline", "网页查询第一行\n网页查询第二行\n网页查询第三行")] {
                vm.inputText = draft
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                let input = try XCTUnwrap(textViews(in: host.view).first)
                XCTAssertEqual(input.text, draft)
                let inputFrame = input.convert(input.bounds, to: window)
                let screenshot = try saveScreenshot(window, name: "compact-browser-\(Int(width))-\(name)")
                let compactFrame = try compactBrowserFrame(in: screenshot, above: inputFrame.minY)
                let gap = inputFrame.minY - compactFrame.maxY
                let metrics = "\(Int(width))-\(name): compact=\(compactFrame), input=\(inputFrame), gap=\(gap)"
                let attachment = XCTAttachment(string: metrics)
                attachment.name = "compact-browser-composer-bounds"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThanOrEqual(compactFrame.height, 30, metrics)
                XCTAssertLessThanOrEqual(compactFrame.height, 44, metrics)
                XCTAssertTrue(window.safeAreaLayoutGuide.layoutFrame.contains(compactFrame), metrics)
                XCTAssertGreaterThanOrEqual(gap, 0, "Compact browser must not overlap the input: \(metrics)")
                XCTAssertLessThanOrEqual(gap, 30, "Compact browser must remain adjacent to the actual input, including when the draft grows: \(metrics)")
            }
            window.rootViewController = nil
        }
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private func compactBrowserFrame(in image: UIImage, above inputTop: CGFloat) throws -> CGRect {
        // SwiftUI virtual accessibility elements are not exposed by this unit-test host.
        // The real compact browser is the only broad tinted glass surface in the lower
        // half above the input. Restrict by width to exclude the circular send button.
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        for y in (cg.height / 2)..<min(cg.height, Int(inputTop * image.scale)) {
            let count = (0..<cg.width).reduce(0) { total, x in
                let offset = (y * cg.width + x) * 4
                let channels = pixels[offset...offset + 2]
                return total + (Int(channels.max()!) - Int(channels.min()!) >= 18 ? 1 : 0)
            }
            if count > cg.width / 2 {
                if start == nil { start = y }
            } else if let first = start {
                bands.append(first...(y - 1))
                start = nil
            }
        }
        let band = try XCTUnwrap(bands.max { $0.count < $1.count }, "Actual compact browser glass must be present in the screenshot")
        return CGRect(x: ChatLayout.contentHorizontalInset, y: CGFloat(band.lowerBound) / image.scale,
            width: image.size.width - 2 * ChatLayout.contentHorizontalInset, height: CGFloat(band.count) / image.scale)
    }

    private func saveScreenshot(_ window: UIWindow, name: String) throws -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amber-bottom-overlay-shots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        return image
    }
}
