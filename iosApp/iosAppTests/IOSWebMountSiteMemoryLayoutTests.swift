import XCTest
import SwiftUI
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountSiteMemoryLayoutTests: XCTestCase {
    func testApprovalKeepsBothButtonsVisibleWhileEightLongChangesScroll() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let approval = WebMountToolApprovalRequest(
            id: "long-site-memory-approval", toolName: "wm_site_memory", siteId: "github",
            siteName: "项目订单查询与管理站点", host: "github.com", backend: "local", mcpServerName: nil,
            redactedURL: "https://github.com", snapshotId: nil, target: nil,
            action: "修改站点记忆", consequence: "将变更保存到本机。", screenshotRetentionWarning: nil,
            siteMemoryChanges: (0..<8).map { index in
                "修改 [actions] 变更 \(index + 1)：" + String(repeating: "先定位当前页面的项目筛选控件，再核对操作结果；旧说明 → 新说明。", count: 8)
            },
            siteMemoryBaseline: "layout-fixture", requiresHumanHandoff: false,
            reason: "确认变更", sessionId: nil, runId: nil
        )
        for width in [320.0, 393.0] {
            for textSize in [DynamicTypeSize.large, .accessibility5] {
                var cardSize = CGSize.zero
                var approvals = 0
                var denials = 0
                let probe = DecisionButtonProbe()
                let controller = UIHostingController(rootView:
                    WebMountToolApprovalCard(request: approval, onOpenSession: nil,
                                            onApprove: { approvals += 1 }, onDeny: { denials += 1 })
                        .buttonStyle(RecordingDecisionButtonStyle(probe: probe))
                        .environment(\.dynamicTypeSize, textSize)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(12)
                )
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 650)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKey()
                }
                controller.view.frame = window.bounds
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(350))
                window.layoutIfNeeded()

                XCTAssertGreaterThan(cardSize.height, 44)
                XCTAssertLessThanOrEqual(cardSize.height, textSize.isAccessibilitySize ? 520 : 420)
                XCTAssertEqual(cardSize.width, width - 24, accuracy: 1)
                let suffix = "\(Int(width))-\(textSize.isAccessibilitySize ? "ax5" : "normal")"
                try saveScreenshot(window: window, name: "approval-eight-changes-\(suffix)")

                let scroll = try XCTUnwrap(scrollViews(in: controller.view).first)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                let screenBounds = window.convert(window.bounds, to: nil)
                let buttons = probe.buttons.sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(buttons.count, 2, "Both rendered decision buttons must be measured")
                guard buttons.count == 2 else { continue }
                let originalFrames = buttons.map(\.frame)
                XCTAssertEqual(originalFrames[0].minY, originalFrames[1].minY, accuracy: 1)
                XCTAssertEqual(originalFrames[0].height, originalFrames[1].height, accuracy: 1, "Decision buttons must share their natural row height")
                for frame in originalFrames {
                    XCTAssertGreaterThanOrEqual(frame.height, 44)
                    XCTAssertGreaterThan(frame.width, 44)
                    XCTAssertTrue(screenBounds.contains(frame), "Button must remain inside the visible card: \(frame)")
                    XCTAssertGreaterThanOrEqual(frame.minY, scroll.convert(scroll.bounds, to: nil).maxY)
                    let point = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: nil)
                    let hitView = try XCTUnwrap(window.hitTest(point, with: nil))
                    XCTAssertTrue(hitView.isDescendant(of: controller.view))
                }
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                scroll.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertGreaterThan(scroll.contentOffset.y, 0)
                XCTAssertEqual(probe.buttons.sorted { $0.frame.minX < $1.frame.minX }.map(\.frame), originalFrames, "Scrolling changes must not move the decision buttons")
                try saveScreenshot(window: window, name: "approval-eight-changes-\(suffix)-bottom")
                buttons[0].activate()
                buttons[1].activate()
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(denials, 1)
                XCTAssertEqual(approvals, 1)
            }
        }
    }

    func testShortParentKeepsApprovalAndComposerInsideAvailableHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 320)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let approval = WebMountToolApprovalRequest(
            id: "short-parent-approval", toolName: "wm_site_memory", siteId: "github", siteName: "GitHub",
            host: "github.com", backend: "local", mcpServerName: nil, redactedURL: "https://github.com",
            snapshotId: nil, target: nil, action: "修改站点记忆", consequence: "保存到本机。",
            screenshotRetentionWarning: nil,
            siteMemoryChanges: (0..<8).map { "修改 [actions] \($0)：" + String(repeating: "核对页面操作结果。", count: 30) },
            siteMemoryBaseline: "layout-fixture", requiresHumanHandoff: false, reason: "确认变更", sessionId: nil, runId: nil)
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            var cardFrame = CGRect.zero
            var composerFrame = CGRect.zero
            let probe = DecisionButtonProbe()
            var approvals = 0
            var denials = 0
            let state = ShortApprovalFixtureState()
            let host = UIHostingController(rootView: ShortParentApprovalFixture(
                state: state, approval: approval, textSize: textSize, probe: probe,
                onApprove: { approvals += 1 }, onDeny: { denials += 1 },
                onCardFrame: { cardFrame = $0 }, onComposerFrame: { composerFrame = $0 }))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            let availableFrame = window.safeAreaLayoutGuide.layoutFrame
            XCTAssertEqual(probe.buttons.count, 2)
            for button in probe.buttons {
                XCTAssertTrue(availableFrame.contains(button.frame), "Decision button must be visible inside the actual window")
            }
            XCTAssertGreaterThan(cardFrame.height, 44)
            XCTAssertGreaterThanOrEqual(cardFrame.minY, availableFrame.minY + ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension - 1, "Approval must fit above composer in the actual parent")
            XCTAssertLessThanOrEqual(cardFrame.maxY, composerFrame.minY)
            XCTAssertLessThanOrEqual(composerFrame.maxY, availableFrame.maxY + 1)
            XCTAssertLessThanOrEqual(cardFrame.height, availableFrame.height - ChatTopBarLayout.controlsHeight - ChatTopBarLayout.softEdgeExtension - (state.collapsed ? 22 : 76) + 1)
            try saveScreenshot(window: window, name: "approval-short-parent-\(textSize.isAccessibilitySize ? "ax5" : "normal")")
            let buttons = probe.buttons.sorted { $0.frame.minX < $1.frame.minX }
            let frames = buttons.map(\.frame)
            let scroll = try XCTUnwrap(scrollViews(in: host.view).first)
            let category: UIContentSizeCategory = textSize.isAccessibilitySize ? .accessibilityExtraExtraExtraLarge : .large
            let baseFont = UIFont.preferredFont(forTextStyle: .subheadline,
                                                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
            let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: baseFont, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            if textSize.isAccessibilitySize { XCTAssertGreaterThan(font.pointSize, baseFont.pointSize) }
            // The SwiftUI frame can clip a larger UIKit scroll view; use the actual card and
            // decision-label frames for the visible region above the footer's 12pt top inset.
            let previewHeight = try XCTUnwrap(frames.map(\.minY).min()) - 12 - 1 - cardFrame.minY
            XCTAssertGreaterThanOrEqual(previewHeight, font.lineHeight + 28,
                                        "The visible preview must show a whole line including its existing 14pt content padding")
            let metrics = "\(textSize): card=\(cardFrame), buttons=\(frames), UIKitScroll=\(scroll.bounds), preview=\(previewHeight), font=\(font.pointSize)/\(font.lineHeight)"
            let attachment = XCTAttachment(string: metrics)
            attachment.name = "approval-short-parent-metrics"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            scroll.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThan(scroll.contentOffset.y, 0)
            XCTAssertEqual(probe.buttons.sorted { $0.frame.minX < $1.frame.minX }.map(\.frame), frames)
            for button in buttons {
                let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
                XCTAssertNotNil(window.hitTest(point, with: nil))
                button.activate()
            }
            XCTAssertEqual(approvals, 1)
            XCTAssertEqual(denials, 1)
            try saveScreenshot(window: window, name: "approval-short-parent-\(textSize.isAccessibilitySize ? "ax5" : "normal")-bottom")
            XCTAssertEqual(state.collapsed, textSize.isAccessibilitySize)
            let mountedTextView = try XCTUnwrap(textViews(in: host.view).first)
            XCTAssertEqual(mountedTextView.text, "保留草稿")
            state.requestId = "second-same-height-approval"
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(state.collapsed, textSize.isAccessibilitySize,
                           "A consecutive request with the same measured height must make its own space decision")
            XCTAssertNotNil(state.minimumHeights[state.requestId])
            XCTAssertTrue(textViews(in: host.view).first === mountedTextView)
            state.pending = false
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(state.collapsed, "Finishing the approval must restore the composer")
            XCTAssertTrue(textViews(in: host.view).first === mountedTextView, "The UIKit draft view must remain mounted")
            XCTAssertEqual(mountedTextView.text, "保留草稿")
            XCTAssertEqual(state.draft, "保留草稿")
            XCTAssertGreaterThanOrEqual(composerFrame.height, 54)

        }
    }

    func testProductionChatApprovalWithAttachmentActivityAndPinnedArtifact() async throws {
        let suite = "SiteMemoryFullChat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let conversations = IOSConversationStore(baseDirectory: directory, subagentConversationIDsProvider: { [] })
        await conversations.bootstrap()
        let conversationID = try XCTUnwrap(conversations.currentConversation?.id)
        let answer = UIMessage.companion.assistant(prompt: "站点页面说明与操作步骤。")
        let messages = [UIMessage.companion.user(prompt: "保存这批站点记忆。"), answer]
        await conversations.saveCurrent(messages: messages)
        let snippet = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: ChatMessageProjector.messageId(for: answer), text: answer.toText(), kind: .message, messages: messages))
        try conversations.artifactStore.pin(snippet, for: conversationID.toHexDashString())
        let settings = SettingsStore(userDefaults: defaults)
        let shared = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "界面测试", apiKey: "fixture-key", baseUrl: "https://example.invalid/v1", modelName: "测试模型", modelId: "gpt-4o")
        let addedProvider = shared.addProvider(provider)
        let model = try XCTUnwrap(addedProvider.models.first { $0.type == ModelType.chat })
        shared.setCurrentChatModelId(model.id.toHexDashString())
        let tasks = IOSAdvancedTaskStore(userDefaults: defaults)
        let activity = IOSSubAgentActivityStore(tasks: tasks, defaults: defaults, launchedAt: Date(), loadRuns: { [] })
        activity.autoDismissDelay = .never
        _ = tasks.startTask(kind: .subAgent, title: "核对站点修改", objective: "fixture",
                            metadata: ["role_name": "核对", "source_conversation_id": conversationID.toHexDashString()])
        await activity.refresh()
        XCTAssertEqual(activity.items.count, 1)
        let center = ConversationActivityCenter(conversationStore: conversations,
            dao: IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runs.db").path).agentRuntimeDao())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func request(_ id: String) -> WebMountToolApprovalRequest {
            .init(id: id, toolName: "wm_site_memory", siteId: "github", siteName: "GitHub", host: "github.com",
                  backend: "local", mcpServerName: nil, redactedURL: "https://github.com", snapshotId: nil, target: nil,
                  action: "修改站点记忆", consequence: "保存到本机。", screenshotRetentionWarning: nil,
                  siteMemoryChanges: (0..<8).map { "修改 [actions] \($0)：" + String(repeating: "核对页面操作结果。", count: 30) },
                  siteMemoryBaseline: "layout-fixture", requiresHumanHandoff: false, reason: "确认变更", sessionId: nil, runId: nil)
        }
        for width in [320.0, 393.0] {
            for size in [DynamicTypeSize.large, .accessibility5] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 650)
                let vm = ChatViewModel(settingsStore: settings, sharedSettings: shared, autoGenerateResponses: false)
                let host = UIHostingController(rootView: NavigationStack {
                    ChatView(settingsStore: settings, sharedSettings: shared,
                             workspaceStore: IOSWorkspaceStore(baseDirectory: directory.appendingPathComponent("workspace")),
                             viewModel: vm, activityStore: activity)
                }.environment(conversations).environment(center).environment(RouterPath())
                    .environment(\.dynamicTypeSize, size).environment(\.locale, Locale(identifier: "zh_Hans")))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                for _ in 0..<50 where vm.conversationStore == nil || vm.currentConversationId != conversationID {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(vm.currentConversationId, conversationID)
                XCTAssertNotNil(vm.conversationStore)
                vm.inputText = "保留完整聊天草稿"
                vm.pendingSelectedFilePreview = .init(fileName: "操作说明.txt", fileType: "txt", totalBytes: 120,
                    bytesRead: 120, characterCount: 50, preview: "站点说明", isTruncated: false, note: nil)
                vm.pendingWebMountApproval = request("full-chat-first")
                try await Task.sleep(for: .milliseconds(650))
                window.layoutIfNeeded()
                XCTAssertEqual(vm.pendingWebMountApproval?.id, "full-chat-first")
                XCTAssertEqual(host.view.bounds.height, window.bounds.height, accuracy: 0.5)
                let suffix = "\(Int(width))-\(size.isAccessibilitySize ? "ax5" : "normal")"
                let screenshot = try saveScreenshot(window: window, name: "approval-production-chat-\(suffix)")
                let input = try XCTUnwrap(textViews(in: host.view).first)
                XCTAssertEqual(input.text, "保留完整聊天草稿")
                let scroll = try approvalScroll(in: host.view)
                let scrollFrame = scroll.convert(scroll.bounds, to: window)
                let safeArea = window.safeAreaLayoutGuide.layoutFrame
                let buttonFrame = try approvalButtonFrame(in: screenshot, traits: window.traitCollection,
                                                         below: scrollFrame.maxY)
                XCTAssertGreaterThanOrEqual(buttonFrame.height, 43, "Actual rendered approval button must retain its 44pt hit height")
                XCTAssertGreaterThanOrEqual(buttonFrame.minY, scrollFrame.maxY, "Button must be below the actual preview")
                XCTAssertLessThanOrEqual(buttonFrame.maxY, safeArea.maxY - 12 + 1,
                                         "Actual decision button must retain the footer's existing 12pt inset")
                let inputFrame = input.convert(input.bounds, to: window)
                if !safeArea.contains(inputFrame) {
                    XCTAssertGreaterThanOrEqual(buttonFrame.maxY, safeArea.maxY - (12 + 8 + 6) - 2,
                        "A hidden dock must make room by collapsing the whole auxiliary area, rather than leaving a partial file card")
                }
                XCTAssertGreaterThanOrEqual(scrollFrame.minY, safeArea.minY + ChatTopBarLayout.controlsHeight,
                                            "Approval preview must remain below actual chat controls")
                XCTAssertLessThanOrEqual(scrollFrame.maxY, safeArea.maxY, "Approval viewport must remain inside the actual window")
                XCTAssertGreaterThanOrEqual(scroll.bounds.height, 44, "Full production composition must leave a readable approval viewport")
                let metrics = "\(suffix): scroll=\(scrollFrame), safe=\(safeArea), approve=\(buttonFrame), input=\(input.convert(input.bounds, to: window))"
                print("SITE_MEMORY_FULL_CHAT \(metrics)")
                vm.pendingWebMountApproval = request("full-chat-second")
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertTrue(textViews(in: host.view).first === input)
                XCTAssertEqual(input.text, "保留完整聊天草稿")
                let runState = try currentRunState(for: vm)
                runState.jevAutoApprovalEscalation = ["外发数据"]
                runState.jevApprovalTriage = .init(requestId: "full-chat-second", readonly: .no,
                                                  reversible: .yes, goalAligned: .unknown)
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(vm.pendingWebMountApproval?.id, "full-chat-second")
                let reviewScroll = try approvalScroll(in: host.view)
                let reviewShot = try saveScreenshot(window: window, name: "approval-production-chat-\(suffix)-jev")
                let reviewButton = try approvalButtonFrame(in: reviewShot, traits: window.traitCollection,
                    below: reviewScroll.convert(reviewScroll.bounds, to: window).maxY)
                XCTAssertLessThanOrEqual(reviewButton.maxY, safeArea.maxY - 12 + 1)
                XCTAssertGreaterThanOrEqual(reviewScroll.bounds.height, max(44, reviewButton.height) + 28,
                                            "Risk explanation must leave a whole readable line and its content padding")
                window.frame.size.height = 320
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(450))
                window.layoutIfNeeded()
                XCTAssertEqual(vm.currentConversationId, conversationID)
                XCTAssertEqual(vm.pendingWebMountApproval?.id, "full-chat-second")
                XCTAssertEqual(host.view.bounds.height, window.bounds.height, accuracy: 0.5)
                let shortSafeArea = window.safeAreaLayoutGuide.layoutFrame
                let shortScroll = try approvalScroll(in: host.view)
                print("SITE_MEMORY_SHORT_BOUNDS \(suffix): host=\(host.view.bounds), scroll=\(shortScroll.convert(shortScroll.bounds, to: window)), input=\(input.convert(input.bounds, to: window)), pending=\(vm.pendingWebMountApproval?.id ?? "nil")")
                let shortShot = try saveScreenshot(window: window, name: "approval-production-chat-\(suffix)-short")
                let shortButton = try approvalButtonFrame(in: shortShot, traits: window.traitCollection,
                    below: shortScroll.convert(shortScroll.bounds, to: window).maxY)
                XCTAssertLessThanOrEqual(shortButton.maxY, shortSafeArea.maxY - 12 + 1)
                XCTAssertGreaterThanOrEqual(shortScroll.bounds.height, max(44, shortButton.height) + 28,
                                            "The actual short parent must show a whole line and its existing 14pt content padding")
                XCTAssertGreaterThanOrEqual(shortScroll.convert(shortScroll.bounds, to: window).minY,
                    shortSafeArea.minY + ChatTopBarLayout.controlsHeight,
                    "Actual short parent approval must not overlap the top controls")
                print("SITE_MEMORY_SHORT_CHAT \(suffix): scroll=\(shortScroll.convert(shortScroll.bounds, to: window)), approve=\(shortButton), safe=\(shortSafeArea)")
                runState.jevAutoApprovalEscalation = nil
                runState.jevApprovalTriage = nil
                window.frame.size.height = 650
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                vm.pendingWebMountApproval = nil
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertTrue(textViews(in: host.view).first === input)
                XCTAssertEqual(vm.pendingSelectedFilePreview?.fileName, "操作说明.txt")
                XCTAssertEqual(vm.inputText, "保留完整聊天草稿")
                XCTAssertGreaterThan(input.convert(input.bounds, to: window).height, 30)
                window.rootViewController = nil
            }
        }
    }

    func testOneShortChangeUsesNaturalHeightInsteadOfFillingThePreviewLimit() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 650)
        window.overrideUserInterfaceStyle = .light
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        func measure(_ changes: [String], name: String) async throws -> CGFloat {
            let approval = WebMountToolApprovalRequest(
                id: "natural-height-approval", toolName: "wm_site_memory", siteId: "github",
                siteName: "GitHub", host: "github.com", backend: "local", mcpServerName: nil,
                redactedURL: "https://github.com", snapshotId: nil, target: nil,
                action: "修改站点记忆", consequence: "将变更保存到本机。", screenshotRetentionWarning: nil,
                siteMemoryChanges: changes, siteMemoryBaseline: "layout-fixture", requiresHumanHandoff: false,
                reason: "确认变更", sessionId: nil, runId: nil
            )
            var measured = CGFloat.zero
            let host = UIHostingController(rootView:
                WebMountToolApprovalCard(request: approval, onOpenSession: nil, onApprove: {}, onDeny: {})
                    .buttonStyle(.plain)
                    .environment(\.dynamicTypeSize, .large)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(12)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            try saveScreenshot(window: window, name: name)
            return measured
        }
        let short = try await measure(["新增 [pages] 订单页：查看订单状态。"], name: "approval-one-short-change")
        let long = try await measure((0..<8).map { index in
            "修改 [actions] \(index)：" + String(repeating: "先定位控件，再核对操作结果。", count: 8)
        }, name: "approval-eight-long-changes-natural-height")
        XCTAssertGreaterThan(short, 44)
        XCTAssertLessThan(short, 320)
        XCTAssertGreaterThan(long - short, 40, "短变更应自然收缩，不能同样占满详情区上限")
        XCTAssertLessThanOrEqual(long, 420)
    }

    func testSiteMemorySheetAndApprovalCardRenderAcrossAppearanceAndTextSize() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "site-memory-layout-\(UUID().uuidString)"))
        let registry = IOSWebMountRegistry(userDefaults: defaults)
        registry.replaceSiteMemory(host: "github.com", entries: [
            .init(id: "page", kind: .pages, name: "很长的项目订单查询页面名称，需要在较大字号下完整换行",
                  detail: "用于查看订单与最新处理状态。页面内容变化时以实际页面为准。",
                  urlPattern: "https://github.com/example/project/orders/history/very-long-path",
                  locatorJSON: nil, updatedAtMillis: 1_790_000_000_000, source: .agent),
            .init(id: "action", kind: .actions, name: "打开筛选菜单",
                  detail: "先用 locator 找到当前 ref，再执行点击。",
                  urlPattern: nil,
                  locatorJSON: #"{"role":"button","name":"筛选","url_pattern":"https://github.com/example/project/orders","stable_attributes":{"aria-label":"按订单状态筛选项目结果","data-testid":"project-order-status-filter","name":"order_status","placeholder":"选择需要查看的项目订单状态"},"landmarks":[{"role":"navigation","name":"项目侧边导航"},{"role":"main","name":"项目订单列表"}],"same_role_index":2}"#,
                  updatedAtMillis: 1_790_000_000_000, source: .user)
        ])
        let approval = WebMountToolApprovalRequest(
            id: "site-memory-approval", toolName: "wm_site_memory", siteId: "github",
            siteName: "GitHub", host: "github.com", backend: "local", mcpServerName: nil,
            redactedURL: "https://github.com", snapshotId: nil, target: nil,
            action: "修改站点记忆", consequence: "批准后会将卡片列出的条目变更保存到本机站点记忆。",
            screenshotRetentionWarning: nil,
            siteMemoryChanges: [
                "新增 [pages] 项目订单查询页面：用于查看最新处理状态 · https://github.com/example/project/orders",
                "修改 [actions] 打开筛选菜单：旧说明 → [actions] 打开筛选菜单：先用 locator 找到当前 ref"
            ],
            siteMemoryBaseline: "layout-fixture",
            requiresHumanHandoff: false, reason: "站点记忆修改需要逐次用户确认。",
            sessionId: nil, runId: nil
        )
        for style in [UIUserInterfaceStyle.light, .dark] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                let suffix = "\(style == .dark ? "dark" : "light")-\(category == .large ? "normal" : "large")"
                try await render(WebMountSiteMemorySheet(host: "github.com", registry: registry, onClose: {}),
                           name: "site-memory-\(suffix)", style: style, category: category)
                try await render(WebMountToolApprovalCard(request: approval, onOpenSession: nil,
                                                    onApprove: {}, onDeny: {}),
                           name: "approval-\(suffix)", style: style, category: category)
            }
        }
    }

    private func render<V: View>(_ view: V, name: String, style: UIUserInterfaceStyle,
                                 category: UIContentSizeCategory) async throws {
        let controller = UIHostingController(rootView: view
            .buttonStyle(.plain)
            .environment(\.colorScheme, style == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, category == .large ? .large : .accessibility5))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        window.overrideUserInterfaceStyle = style
        window.traitOverrides.preferredContentSizeCategory = category
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 10_000, name)
        let directory = URL(fileURLWithPath: "/tmp/amber-webmount-stage2-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        if category != .large {
            let scroll = try XCTUnwrap(scrollViews(in: controller.view).max(by: {
                $0.contentSize.height - $0.bounds.height < $1.contentSize.height - $1.bounds.height
            }))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, name)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            scroll.layoutIfNeeded()
            let bottom = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(bottom.pngData()).write(to: directory.appendingPathComponent("\(name)-bottom.png"))
        }
        window.isHidden = true
    }

    /// Fixture-only access to the existing observed run state; no production setter or network.
    private func currentRunState(for model: ChatViewModel) throws -> ChatConversationRunState {
        let runs = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == "conversationRuns" }?.value)
        for entry in Mirror(reflecting: runs).children {
            guard let run = Mirror(reflecting: entry.value).children.first(where: { $0.label == "value" })?.value,
                  let state = Mirror(reflecting: run).children.first(where: { $0.label == "state" })?.value as? ChatConversationRunState,
                  state.conversationId?.toHexDashString() == model.currentConversationId?.toHexDashString() else { continue }
            return state
        }
        XCTFail("The actual current conversation run must exist")
        throw CocoaError(.coderInvalidValue)
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    private func approvalScroll(in view: UIView) throws -> UIScrollView {
        try XCTUnwrap(scrollViews(in: view).filter { !($0 is UITextView) }
            .max { $0.contentSize.height < $1.contentSize.height })
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews(in:))
    }

    @discardableResult
    private func saveScreenshot(window: UIWindow, name: String) throws -> UIImage {
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let directory = URL(fileURLWithPath: "/tmp/amber-webmount-stage2-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        return image
    }

    /// Finds the broad solid accent button in the actual rendered window, excluding small badges.
    private func approvalButtonFrame(in image: UIImage, traits: UITraitCollection, below minimumY: CGFloat = 0) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var red = CGFloat.zero, green = CGFloat.zero, blue = CGFloat.zero, alpha = CGFloat.zero
        XCTAssertTrue(UIColor(AmberTheme.accent).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let target = [red, green, blue].map { Int(($0 * 255).rounded()) }
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in mask.indices {
            let offset = index * 4
            if (0..<3).allSatisfy({ abs(Int(pixels[offset + $0]) - target[$0]) <= 20 }) { mask[index] = 1 }
        }
        var components: [CGRect] = []
        for start in mask.indices where mask[start] == 1 {
            var queue = [start]
            mask[start] = 2
            var minX = width, maxX = 0, minY = height, maxY = 0
            while let index = queue.popLast() {
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for neighbor in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                                 y > 0 ? index - width : -1, y + 1 < height ? index + width : -1] {
                    if neighbor >= 0, mask[neighbor] == 1 { mask[neighbor] = 2; queue.append(neighbor) }
                }
            }
            let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            if rect.width / image.scale >= 44, rect.height / image.scale >= 42,
               rect.minY / image.scale >= minimumY - 1 { components.append(rect) }
        }
        // The footer is the lowest broad solid component; a user message can share its accent.
        let bounds = try XCTUnwrap(components.max { $0.maxY < $1.maxY })
        XCTAssertFalse(bounds.isNull, "The actual approval button must be visible in the rendered window")
        return CGRect(x: bounds.minX / image.scale, y: bounds.minY / image.scale,
                      width: bounds.width / image.scale, height: bounds.height / image.scale)
    }

}

/// Records the real SwiftUI button labels while retaining the production plain button rendering.
/// Invoking the primitive configuration exercises the action attached to each rendered button.
@MainActor
private final class DecisionButtonProbe {
    struct Entry {
        let frame: CGRect
        let activate: () -> Void
    }
    private var entries: [CGFloat: Entry] = [:]
    var buttons: [Entry] { Array(entries.values) }
    func record(frame: CGRect, activate: @escaping () -> Void) {
        entries[frame.minX] = Entry(frame: frame, activate: activate)
    }
}

private struct RecordingDecisionButtonStyle: PrimitiveButtonStyle {
    let probe: DecisionButtonProbe
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.plain)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                probe.record(frame: frame, activate: configuration.trigger)
            }
    }
}


@MainActor
private final class ShortApprovalFixtureState: ObservableObject {
    @Published var pending = true
    @Published var requestId = "short-parent-approval"
    @Published var minimumHeights: [String: CGFloat] = [:]
    @Published var collapsed = false
    @Published var draft = "保留草稿"
    @Published var inputHeight: CGFloat = 40
    @Published var focused = false
    let controller = ComposerInputController()
}

private struct ShortParentApprovalFixture: View {
    @ObservedObject var state: ShortApprovalFixtureState
    let approval: WebMountToolApprovalRequest
    let textSize: DynamicTypeSize
    let probe: DecisionButtonProbe
    let onApprove: () -> Void
    let onDeny: () -> Void
    let onCardFrame: (CGRect) -> Void
    let onComposerFrame: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let topHeight = ChatTopBarLayout.controlsHeight + ChatTopBarLayout.softEdgeExtension
            let request = WebMountToolApprovalRequest(
                id: state.requestId, toolName: approval.toolName, siteId: approval.siteId,
                siteName: approval.siteName, host: approval.host, backend: approval.backend,
                mcpServerName: approval.mcpServerName, redactedURL: approval.redactedURL,
                snapshotId: approval.snapshotId, target: approval.target, action: approval.action,
                consequence: approval.consequence, screenshotRetentionWarning: approval.screenshotRetentionWarning,
                siteMemoryChanges: approval.siteMemoryChanges, siteMemoryBaseline: approval.siteMemoryBaseline,
                requiresHumanHandoff: approval.requiresHumanHandoff, reason: approval.reason,
                sessionId: approval.sessionId, runId: approval.runId)
            let composerHeight: CGFloat = state.collapsed ? 0 : 54
            let budget = max(0, proxy.size.height - topHeight - composerHeight - 16 - 6)
            Color.clear
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 6) {
                        if state.pending {
                            WebMountToolApprovalCard(request: request, onOpenSession: nil,
                                                     onApprove: onApprove, onDeny: onDeny, maximumHeight: budget)
                                .buttonStyle(RecordingDecisionButtonStyle(probe: probe))
                                .id(request.id)
                                .transition(.opacity)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCardFrame($0) }
                        }
                        ComposerInputTextView(text: $state.draft, height: $state.inputHeight,
                                              isFocused: $state.focused, isEnabled: !state.pending,
                                              sendOnEnter: false, controller: state.controller, onSubmit: {})
                            .frame(height: 40)
                            .padding(.vertical, 7)
                            .frame(height: composerHeight, alignment: .top)
                            .opacity(state.collapsed ? 0 : 1)
                            .allowsHitTesting(!state.collapsed)
                            .accessibilityHidden(state.collapsed)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onComposerFrame($0) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .overlay(alignment: .top) {
                    Text("聊天顶栏 · 可停止运行")
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity)
                        .frame(height: topHeight)
                        .background(Color.gray.opacity(0.1))
                }
                .animation(.easeOut(duration: 0.16), value: state.requestId)
                .onPreferenceChange(WebMountSiteMemoryApprovalMinimumHeightKey.self) { heights in
                    if state.minimumHeights != heights { state.minimumHeights = heights }
                    collapseIfNeeded(budget: budget)
                }
                .onChange(of: budget) { _, budget in collapseIfNeeded(budget: budget) }
                .onChange(of: state.requestId) { _, _ in
                    collapseIfNeeded(budget: budget)
                }
                .onChange(of: state.pending) { _, pending in
                    if !pending { state.collapsed = false }
                }
        }
        .environment(\.dynamicTypeSize, textSize)
    }

    private func collapseIfNeeded(budget: CGFloat) {
        if state.pending, textSize.isAccessibilitySize, let minimumHeight = state.minimumHeights[state.requestId],
           !state.collapsed, budget + 1 < minimumHeight {
            state.collapsed = true
        }
    }
}
