import SwiftUI
import UIKit
@preconcurrency import WebKit
import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Local rendering evidence for the production Council, MiniApp, and system-permission pages.
/// Navigation gestures and physical touch behavior have separate UI/device gates.
@MainActor
final class SwiftModularizationCouncilMiniAppLayoutTests: XCTestCase {
    private let viewportHeight: CGFloat = 780

    func testCouncilTranscriptAndMembersAtCompactWidths() async throws {
        for layout in layouts {
            let suite = "app.amber.ios.council.layout.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let archiveDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CouncilLayout.\(UUID().uuidString)", isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: archiveDirectory)
            }

            let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
            let permissionStore = IOSPermissionStore(
                userDefaults: defaults,
                storageKey: "policies",
                approvalStorageKey: "approvals",
                taskStore: taskStore
            )
            let settingsStore = SettingsStore(
                userDefaults: defaults,
                storageKey: "settings",
                apiKeyStore: CouncilLayoutAPIKeyStore()
            )
            let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
            let provider = IosSettingsMutations.shared.buildOpenAIProvider(
                name: "Council Layout Provider",
                apiKey: "test-key",
                baseUrl: "https://example.com/v1",
                modelName: "Council Layout Model",
                modelId: "gpt-layout"
            )
            _ = sharedSettings.addProvider(provider)
            let model = try XCTUnwrap(sharedSettings.availableChatModels().first {
                $0.providerName == "Council Layout Provider"
            })
            sharedSettings.setCurrentChatModelId(model.id)
            let roomSettings = IOSCouncilRoomSettingsStore(
                userDefaults: defaults,
                storageKey: "room-settings",
                currentModelId: "gpt-layout"
            )
            let viewModel = CouncilChatViewModel(
                settingsStore: settingsStore,
                sharedSettings: sharedSettings,
                providerRegistry: nil,
                permissionStore: permissionStore,
                roomSettingsStore: roomSettings,
                runner: IOSCouncilRoomRunner(taskStore: taskStore, permissionStore: permissionStore),
                transcriptDefaults: defaults,
                archiveStore: CouncilRoomArchiveStore(baseDirectory: archiveDirectory)
            )
            viewModel.participants = councilParticipants
            viewModel.failedSpeakerIds = ["risk"]
            viewModel.messages = councilMessages
            viewModel.inputText = "还需要核对窄屏和大字下的成员信息。"

            let fixture = try SwiftModularizationHostingFixture(
                root: NavigationStack {
                    CouncilChatRuntimeView(
                        settingsStore: settingsStore,
                        sharedSettings: sharedSettings,
                        permissionStore: permissionStore,
                        viewModel: viewModel
                    )
                }
                .defaultAppStorage(defaults),
                width: layout.width,
                height: viewportHeight,
                type: layout.type
            )
            defer { fixture.close() }
            try await fixture.settle()

            let transcript = try XCTUnwrap(fixture.mainScrollView(), "Council transcript scroll missing")
            assertViewport(transcript, in: fixture)
            XCTAssertGreaterThan(transcript.contentSize.height, transcript.bounds.height + 20,
                                 "Seeded long transcript must exercise scrolling")
            fixture.assertNoHorizontalOverflow(transcript)
            transcript.scrollRectToVisible(
                CGRect(x: 0, y: 0, width: transcript.bounds.width, height: 1), animated: false
            )
            try fixture.capturePNG("council-transcript-top-\(layout.name)", in: self)
            fixture.scrollToBottom(transcript)
            try await fixture.settle()
            XCTAssertGreaterThan(transcript.contentOffset.y, 0)
            fixture.assertNoHorizontalOverflow(transcript)
            try fixture.capturePNG("council-transcript-bottom-\(layout.name)", in: self)

            viewModel.showMembers()
            try await fixture.settle()
            XCTAssertNotNil(fixture.window.rootViewController?.presentedViewController,
                            "showMembers must present the production sheet")
            let members = try XCTUnwrap(fixture.mainScrollView(), "Council members list missing")
            assertViewport(members, in: fixture)
            XCTAssertGreaterThan(members.contentSize.height, members.bounds.height + 10,
                                 "Long member list must exercise sheet scrolling")
            fixture.assertNoHorizontalOverflow(members)
            try fixture.capturePNG("council-members-top-\(layout.name)", in: self)
            fixture.scrollToBottom(members)
            try await fixture.settle()
            XCTAssertGreaterThan(members.contentOffset.y, 0)
            fixture.assertNoHorizontalOverflow(members)
            try fixture.capturePNG("council-members-scrolled-\(layout.name)", in: self)
        }
    }

    func testMiniAppLocalRunnerAndGrantStatesAtCompactWidths() async throws {
        for layout in layouts {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiniAppLayout.\(UUID().uuidString)", isDirectory: true)
            let suite = "app.amber.ios.miniapp.layout.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            defaults.set(false, forKey: IOSMiniAppBridgePolicy.systemCapabilitiesPreferenceKey)
            let repository = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
            let output = IOSMiniAppGeneratedOutput(
                title: "本地权限与管理布局检查小应用",
                description: "仅使用本地 HTML，检查长说明、授权状态与窄屏布局。",
                permissions: ["storage", "haptics", "device", "screen", "speech", "share", "openURL"],
                html: """
                <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
                <body style="margin:0;font:16px -apple-system;padding:16px"><h1>本地小应用</h1><p>无外部资源和系统请求。</p></body></html>
                """
            )
            let app = try repository.saveGenerated(output)
            let runnerFixture = try SwiftModularizationHostingFixture(
                root: NavigationStack {
                    MiniAppRunnerView(appId: app.id, repository: repository)
                        .environment(RouterPath())
                }
                .defaultAppStorage(defaults),
                width: layout.width,
                height: viewportHeight,
                type: layout.type
            )
            defer { runnerFixture.close() }
            try await waitForLocalHTML(in: runnerFixture)
            try await runnerFixture.settle()
            XCTAssertEqual(repository.get(app.id)?.runCount, 1)
            XCTAssertEqual(repository.get(app.id)?.permissions, output.permissions)
            let webView = try XCTUnwrap(runnerFixture.webViews().first)
            assertViewport(webView.scrollView, in: runnerFixture)
            XCTAssertLessThanOrEqual(webView.scrollView.contentSize.width,
                                     webView.scrollView.bounds.width + 1,
                                     "Local HTML must fit the WebView viewport")
            try runnerFixture.capturePNG("miniapp-runner-\(layout.name)", in: self)

            for decision in [IOSMiniAppGrantDecision.allow, .deny] {
                try repository.setGrant(appId: app.id, permission: "storage", decision: decision)
                XCTAssertEqual(repository.grantDecision(appId: app.id, permission: "storage"), decision)
                let grantsFixture = try SwiftModularizationHostingFixture(
                    root: ScrollView {
                        MiniAppPermissionGrantsSection(
                            app: app,
                            systemCapabilitiesEnabled: false,
                            grants: repository.grants(appId: app.id),
                            onDecision: { _, _ in }
                        )
                    }
                    .background(AmberTheme.background),
                    width: layout.width,
                    height: 568,
                    type: layout.type
                )
                defer { grantsFixture.close() }
                try await grantsFixture.settle()
                let grants = try XCTUnwrap(grantsFixture.mainScrollView(), "MiniApp grants scroll missing")
                assertViewport(grants, in: grantsFixture)
                XCTAssertGreaterThan(grants.contentSize.height, 250,
                                     "The real permission rows must be rendered")
                grantsFixture.assertNoHorizontalOverflow(grants)
                try grantsFixture.capturePNG("miniapp-grants-\(decision.rawValue)-top-\(layout.name)", in: self)
                let needsScroll = grants.contentSize.height > grants.bounds.height + 1
                if needsScroll {
                    let initialOffset = grants.contentOffset.y
                    grantsFixture.scrollToBottom(grants)
                    try await grantsFixture.settle()
                    XCTAssertGreaterThan(grants.contentOffset.y, initialOffset + 1,
                                         "Overflowing permission rows must move within the real scroll view")
                }
                grantsFixture.assertNoHorizontalOverflow(grants)
                let position = needsScroll ? "scrolled" : "fits"
                try grantsFixture.capturePNG("miniapp-grants-\(decision.rawValue)-\(position)-\(layout.name)", in: self)
            }
        }
    }

    func testToolPermissionsPageAtCompactWidths() async throws {
        XCTAssertTrue(IOSCapabilityRegistry.capabilities.contains { $0.id == "ios.network.local" })
        XCTAssertTrue(IOSCapabilityRegistry.capabilities.contains { $0.id == "ios.webmount.browser" })
        for layout in layouts {
            let suite = "app.amber.ios.permission.layout.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let permissionStore = IOSPermissionStore(userDefaults: defaults, taskStore: nil)
            let documentStore = DocumentAccessStore()
            let coordinator = IOSSystemPermissionCoordinator()
            let executor = IOSLocalToolExecutor(
                permissionStore: permissionStore,
                documentStore: documentStore,
                systemPermissionCoordinator: coordinator
            )
            let fixture = try SwiftModularizationHostingFixture(
                root: NavigationStack {
                    ToolPermissionsView(
                        permissionStore: permissionStore,
                        documentStore: documentStore,
                        systemPermissionCoordinator: coordinator,
                        localToolExecutor: executor
                    )
                },
                width: layout.width,
                height: viewportHeight,
                type: layout.type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let page = try XCTUnwrap(fixture.mainScrollView(), "ToolPermissions scroll missing")
            assertViewport(page, in: fixture)
            XCTAssertGreaterThan(page.contentSize.height, page.bounds.height + 20,
                                 "The lower network rows must require actual scrolling")
            fixture.assertNoHorizontalOverflow(page)
            try fixture.capturePNG("tool-permissions-top-\(layout.name)", in: self)
            fixture.scrollToBottom(page)
            try await fixture.settle()
            XCTAssertGreaterThan(page.contentOffset.y, 0)
            fixture.assertNoHorizontalOverflow(page)
            try fixture.capturePNG("tool-permissions-network-\(layout.name)", in: self)
        }
    }

    private var layouts: [(width: CGFloat, type: DynamicTypeSize, name: String)] {
        [
            (320, .large, "320-large"),
            (393, .large, "393-large"),
            (320, .accessibility3, "320-ax3"),
            (393, .accessibility3, "393-ax3")
        ]
    }

    private var councilParticipants: [CouncilParticipant] {
        let core = [
            CouncilParticipant(
                id: "host", handle: "host", displayName: "Host · 超长主持模型名称 gpt-layout-reasoning",
                roleDescription: "主持、串联、追问并综合全部成员的不同意见",
                shortLens: "主持与综合", systemImage: "crown", tint: AmberTheme.accent,
                isHost: true, modelHint: "主模型", modelId: "gpt-layout"
            ),
            CouncilParticipant(
                id: "engineering", handle: "engineering", displayName: "工程实现与维护成本评审成员",
                roleDescription: "检查可实现性、维护成本、失败恢复与跨端一致性",
                shortLens: "工程", systemImage: "wrench", tint: AmberTheme.accentGreen,
                isHost: false, modelHint: "工程模型", modelId: "gpt-layout"
            ),
            CouncilParticipant(
                id: "risk", handle: "risk", displayName: "安全、隐私和真实设备风险评审成员",
                roleDescription: "逐项核对权限、数据边界和设备差异",
                shortLens: "风险", systemImage: "shield", tint: AmberTheme.accentAmber,
                isHost: false, modelHint: "风险模型", modelId: "gpt-layout"
            )
        ]
        let additional = (1...5).map { index in
            CouncilParticipant(
                id: "review-\(index)", handle: "review-\(index)",
                displayName: "第 \(index) 位长名称交叉评审成员",
                roleDescription: "核对页面长文本、滚动可达性与状态说明",
                shortLens: "交叉评审", systemImage: "person.2", tint: AmberTheme.accent,
                isHost: false, modelHint: "布局模型", modelId: "gpt-layout"
            )
        }
        return core + additional
    }

    private var councilMessages: [CouncilChatMessage] {
        let longBody = "## 布局复核\n\n" + String(
            repeating: "窄屏和辅助功能字号下，长段落必须完整换行，成员状态与输入栏也应保持可见。\n\n",
            count: 24
        )
        return [
            CouncilChatMessage(kind: .user, author: "你", body: "请评估本地布局。",
                               systemImage: "person", tint: AmberTheme.accent, subtitle: nil),
            CouncilChatMessage(kind: .host, author: "Host · 超长主持模型名称", body: longBody,
                               systemImage: "crown", tint: AmberTheme.accent,
                               subtitle: "第 1 轮 · 主持", status: .completed),
            CouncilChatMessage(kind: .guest, author: "工程实现与维护成本评审成员", body: longBody,
                               systemImage: "wrench", tint: AmberTheme.accentGreen,
                               subtitle: "第 1 轮 · 工程", status: .completed),
            CouncilChatMessage(kind: .system, author: "议会", body: "请继续核对最终布局。",
                               systemImage: "info.circle", tint: AmberTheme.muted,
                               subtitle: nil, status: .completed)
        ]
    }

    private func assertViewport(
        _ scroll: UIScrollView,
        in fixture: SwiftModularizationHostingFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = scroll.convert(scroll.bounds, to: fixture.window)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, fixture.windowBounds.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, fixture.windowBounds.maxX + 1, file: file, line: line)
    }

    private func waitForLocalHTML(in fixture: SwiftModularizationHostingFixture) async throws {
        for _ in 0..<120 {
            if let webView = fixture.webViews().first,
               (try? await webView.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("MiniApp local WKWebView did not finish loading")
    }
}

private final class CouncilLayoutAPIKeyStore: SettingsAPIKeyStore {
    func loadApiKey() -> String? { "test-key" }
    func saveApiKey(_ key: String) -> Bool { true }
}
