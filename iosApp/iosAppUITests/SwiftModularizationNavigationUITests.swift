import XCTest

/// Exercises the installed app's ordinary navigation while retaining its existing data.
final class SwiftModularizationNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeSettingsWorkspaceAndDeepReadingLayout() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()

        let newChat = button(["新建聊天", "New chat"], in: app)
        if !newChat.waitForExistence(timeout: 25) {
            let chatBack = app.buttons["topbar-back"]
            XCTAssertTrue(chatBack.waitForExistence(timeout: 10) && chatBack.isHittable,
                          "Expected the home screen or the existing conversation's back button.")
            chatBack.tap()
        }
        XCTAssertTrue(newChat.waitForExistence(timeout: 15) && newChat.isHittable)
        let homeSearch = button(["搜索", "Search"], in: app)
        let homeSettings = button(["设置", "Settings"], in: app)
        XCTAssertTrue(homeSettings.waitForExistence(timeout: 10) && homeSettings.isHittable)
        capture(app, page: "home")
        assertHeaderLayout([("search", homeSearch), ("settings", homeSettings)], in: app)

        homeSettings.tap()
        let settingsTitle = text(["设置", "Settings"], in: app)
        let settingsBack = button(["返回", "Back"], in: app)
        let account = button(["我的账户", "My account"], in: app)
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(settingsBack.isHittable && account.isHittable)
        capture(app, page: "settings")
        assertHeaderLayout([("back", settingsBack), ("title", settingsTitle), ("account", account)], in: app)

        let workspaceEntry = button(["Workspace"], in: app)
        reveal(workspaceEntry, in: app)
        workspaceEntry.tap()
        let workspaceTitle = text(["Workspace"], in: app)
        let workspaceBack = button(["返回", "Back"], in: app)
        let importFile = button(["导入文件", "Import file"], in: app)
        XCTAssertTrue(workspaceTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(workspaceBack.isHittable && importFile.isHittable)
        capture(app, page: "workspace")
        assertHeaderLayout([("back", workspaceBack), ("title", workspaceTitle), ("import", importFile)], in: app)

        workspaceBack.tap()
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 10), "Workspace did not return to Settings.")
        let boardEntry = button(["深度阅读", "Deep reading"], in: app)
        reveal(boardEntry, in: app)
        boardEntry.tap()
        let boardTitle = text(["深度阅读", "Deep reading"], in: app)
        let boardBack = button(["返回", "Back"], in: app)
        let history = button(["深度阅读历史", "Deep reading history"], in: app)
        let boardSettings = button(["深度阅读设置", "Deep reading settings"], in: app)
        XCTAssertTrue(boardTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(boardBack.isHittable && history.isHittable && boardSettings.isHittable)
        capture(app, page: "board")
        assertHeaderLayout([
            ("back", boardBack), ("title", boardTitle),
            ("history", history), ("settings", boardSettings)
        ], in: app)
    }

    func testWebMountSettingsNavigationAndSiteListLayout() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()

        let newChat = button(["新建聊天", "New chat"], in: app)
        if !newChat.waitForExistence(timeout: 25) {
            let chatBack = app.buttons["topbar-back"]
            XCTAssertTrue(chatBack.waitForExistence(timeout: 10) && chatBack.isHittable)
            chatBack.tap()
        }
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        let homeSettings = button(["设置", "Settings"], in: app)
        XCTAssertTrue(homeSettings.waitForExistence(timeout: 10) && homeSettings.isHittable)
        homeSettings.tap()
        XCTAssertTrue(text(["设置", "Settings"], in: app).waitForExistence(timeout: 10))

        let webMountEntry = button(["WebMount", "站点"], in: app)
        reveal(webMountEntry, in: app)
        webMountEntry.tap()

        let back = button(["返回设置", "Back to settings"], in: app)
        let addSite = button(["添加 WebMount 站点", "添加站点", "Add WebMount site"], in: app)
        let siteCount = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "^[0-9]+ (个站点|sites)$")
        ).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
        XCTAssertTrue(addSite.isHittable && siteCount.exists)
        let title = text(["WebMount", "站点"], in: app)
        capture(app, page: "webmount")
        assertHeaderLayout([("back", back), ("title", title), ("add", addSite)], in: app)
        XCTAssertLessThan(title.frame.midY, addSite.frame.maxY, "Expected the WebMount header title.")
        XCTAssertLessThan(siteCount.frame.midY, addSite.frame.maxY, "Site count must stay in the header.")

        let restore = button(["恢复内置站点", "Restore built-in sites"], in: app)
        reveal(restore, in: app)
        capture(app, page: "webmount-sites")
        let count = try XCTUnwrap(Int(siteCount.label.split(separator: " ").first ?? ""))
        if count == 0 {
            XCTAssertTrue(text([
                "还没有 WebMount 站点。添加一个 http(s) 网站，或恢复内置站点。",
                "还没有站点。添加一个 http(s) 网站，或恢复内置站点。",
                "No WebMount sites yet. Add an http(s) website or restore the built-in sites."
            ], in: app).exists, "The zero-site state is missing its explanation.")
        } else {
            let siteSwitch = app.switches.matching(
                NSPredicate(format: "label BEGINSWITH %@", "启用 ")
            ).firstMatch
            XCTAssertTrue(siteSwitch.exists, "The site count is nonzero but no site row is exposed.")
        }
    }

    func testChatComposerKeyboardAndAttachmentLayout() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = button(["新建聊天", "New chat"], in: app)
        if !newChat.waitForExistence(timeout: 25) {
            let back = app.buttons["topbar-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(newChat.waitForExistence(timeout: 15) && newChat.isHittable)
        newChat.tap()

        let input = app.textViews.firstMatch
        let send = button(["发送消息", "Send message"], in: app)
        let attach = button(["添加附件", "Add attachment"], in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 15) && input.isHittable)
        XCTAssertTrue(send.exists && attach.isHittable)
        assertHeaderLayout([("input", input), ("send", send)], in: app)
        XCTAssertGreaterThanOrEqual(attach.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attach.frame.height, 44)
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        capture(app, page: "chat-composer")

        input.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let draft = "Phase 3 composer layout"
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1,
                                 "Send control must remain above the keyboard.")
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 1,
                                 "Composer input must remain above the keyboard.")
        assertHeaderLayout([("input", input), ("send", send)], in: app)
        let welcomeMark = app.descendants(matching: .any)["chat-empty-state-mark"].firstMatch
        let title = app.buttons["topbar-island"]
        XCTAssertTrue(welcomeMark.exists && title.exists)
        XCTAssertGreaterThanOrEqual(welcomeMark.frame.minY, title.frame.maxY,
                                    "The empty conversation mark must stay below the header when the keyboard opens.")
        capture(app, page: "chat-keyboard")
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draft.count))
        XCTAssertEqual(input.value as? String, "")

        attach.tap()
        let close = button(["关闭附件", "Close attachment"], in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5) && close.isHittable)
        let files = button(["文件", "Files"], in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 5) && files.isHittable)
        if welcomeMark.exists {
            XCTAssertGreaterThanOrEqual(welcomeMark.frame.minY, title.frame.maxY,
                                        "The welcome mark must stay below the header with attachments open.")
            XCTAssertLessThanOrEqual(welcomeMark.frame.maxY, files.frame.minY,
                                     "The welcome mark must stay above the attachment menu.")
        }
        capture(app, page: "chat-attachments")
        assertHeaderLayout([("close attachments", close), ("files", files)], in: app)
        close.tap()
    }

    func testNovelLocalProjectThreeSectionsAndContextControls() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = button(["新建聊天", "New chat"], in: app)
        if !newChat.waitForExistence(timeout: 25) {
            let back = app.buttons["topbar-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        let novel = button(["小说创作"], in: app)
        XCTAssertTrue(novel.waitForExistence(timeout: 10) && novel.isHittable)
        novel.tap()

        let create = button(["新建项目", "新建小说项目"], in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 15) && create.isHittable)
        capture(app, page: "novel-projects")
        let projectName = "Modularization UI Review"
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectName)).firstMatch
        if project.exists {
            XCTAssertTrue(project.isHittable)
            project.tap()
        } else {
            create.tap()
            let name = app.textFields["小说名称"]
            XCTAssertTrue(name.waitForExistence(timeout: 10) && name.isHittable)
            name.tap()
            name.typeText(projectName)
            let confirm = button(["创建"], in: app)
            XCTAssertTrue(confirm.exists && confirm.isHittable && confirm.isEnabled)
            confirm.tap()
        }

        let tabs = ["创作", "正文", "设定"].map { button([$0], in: app) }
        let workspaceReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: tabs[0]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [workspaceReady], timeout: 20), .completed)
        capture(app, page: "novel-workspace")
        for (index, tab) in tabs.enumerated() {
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
            for offset: CGFloat in [-21, 21] {
                tabs[(index + 1) % tabs.count].tap()
                tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: 0, dy: offset)).tap()
                XCTAssertTrue(tab.isSelected, "The tab must accept a touch throughout its 44pt target.")
            }
            capture(app, page: "novel-section-\(index)")
            assertHeaderLayout(Array(zip(["writing", "manuscript", "settings"], tabs)), in: app)
        }

        let controls = app.buttons["项目控制"]
        XCTAssertTrue(controls.exists && controls.isHittable)
        controls.tap()
        let preferences = button(["模式与偏好"], in: app)
        let injection = button(["上下文注入"], in: app)
        XCTAssertTrue(preferences.waitForExistence(timeout: 10) && preferences.isHittable)
        capture(app, page: "novel-project-controls")
        XCTAssertTrue(injection.isHittable)
        injection.tap()
        capture(app, page: "novel-context-injection")
        assertHeaderLayout([("preferences", preferences), ("injection", injection)], in: app)
    }

    func testProviderConfigurationModelsAndManualEditorNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = button(["新建聊天", "New chat"], in: app)
        if !newChat.waitForExistence(timeout: 25) {
            let back = app.buttons["topbar-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        let homeSettings = button(["设置", "Settings"], in: app)
        XCTAssertTrue(homeSettings.waitForExistence(timeout: 10) && homeSettings.isHittable)
        capture(app, page: "provider-home")
        homeSettings.tap()

        let providersEntry = button(["服务商"], in: app)
        XCTAssertTrue(text(["设置", "Settings"], in: app).waitForExistence(timeout: 10))
        reveal(providersEntry, in: app)
        capture(app, page: "provider-settings")
        providersEntry.tap()

        let providersBack = button(["返回设置"], in: app)
        let addProvider = button(["添加服务商"], in: app)
        XCTAssertTrue(providersBack.waitForExistence(timeout: 10) && providersBack.isHittable)
        XCTAssertTrue(addProvider.isHittable)
        assertHeaderLayout([
            ("back", providersBack), ("title", text(["服务商"], in: app)),
            ("add", addProvider)
        ], in: app)
        capture(app, page: "provider-list")

        let provider = app.buttons.matching(NSPredicate(
            format: "label != %@ AND label != %@ AND label != %@",
            "返回设置", "添加服务商", "清除搜索"
        )).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10) && provider.isHittable,
                      "Expected an existing local provider row.")
        provider.tap()

        let detailBack = button(["返回服务商"], in: app)
        let saveProvider = button(["保存服务商"], in: app)
        let configTab = button(["配置"], in: app)
        let modelsTab = button(["模型"], in: app)
        XCTAssertTrue(detailBack.waitForExistence(timeout: 10) && detailBack.isHittable)
        XCTAssertTrue(saveProvider.isHittable && configTab.isHittable && modelsTab.isHittable)
        capture(app, page: "provider-config")
        assertHeaderLayout([("back", detailBack), ("save", saveProvider)], in: app)
        modelsTab.tap()

        let manualAdd = button(["手动添加"], in: app)
        reveal(manualAdd, in: app)
        XCTAssertTrue(text(["已启用模型"], in: app).exists)
        XCTAssertTrue(manualAdd.isHittable)
        capture(app, page: "provider-models")
        manualAdd.tap()

        let editorTitle = app.navigationBars["添加模型"]
        let cancel = button(["取消"], in: app)
        let saveModel = button(["保存"], in: app)
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.isHittable && saveModel.exists)
        capture(app, page: "provider-manual-editor")
        cancel.tap()
        XCTAssertTrue(manualAdd.waitForExistence(timeout: 10) && manualAdd.isHittable,
                      "Cancelling the editor must return to the model list.")
    }

    func testRuntimeCouncilAndMiniAppLocalNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "app.amber.ios")
        app.launch()
        let newChat = button(["新建聊天", "New chat"], in: app)
        if !newChat.waitForExistence(timeout: 25) {
            let back = app.buttons["topbar-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable)
            back.tap()
        }
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        let homeSettings = button(["设置", "Settings"], in: app)
        XCTAssertTrue(homeSettings.waitForExistence(timeout: 10) && homeSettings.isHittable)
        capture(app, page: "local-pages-home")
        homeSettings.tap()
        let settingsTitle = text(["设置", "Settings"], in: app)
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 10))

        let runtimeEntry = button(["运行环境"], in: app)
        reveal(runtimeEntry, in: app)
        capture(app, page: "local-pages-settings")
        runtimeEntry.tap()
        let runtimeAndTasks = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "Runtime 与任务"
        )).firstMatch
        XCTAssertTrue(runtimeAndTasks.waitForExistence(timeout: 10) && runtimeAndTasks.isHittable)
        capture(app, page: "runtime-settings")
        runtimeAndTasks.tap()

        let sshProfile = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "SSH Profile、"
        )).firstMatch
        reveal(sshProfile, in: app)
        XCTAssertTrue(text(["连接配置"], in: app).exists)
        capture(app, page: "runtime-overview")
        sshProfile.tap()
        let sheetScroll = app.scrollViews.containing(NSPredicate(
            format: "label == %@", "Profile 名称"
        )).firstMatch
        XCTAssertTrue(sheetScroll.waitForExistence(timeout: 10))
        let sheetTitle = sheetScroll.staticTexts["SSH Profile"]
        let closeSSH = button(["关闭"], in: app)
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10) && closeSSH.isHittable)
        XCTAssertTrue(text(["Profile 名称"], in: app).exists)
        XCTAssertTrue(text(["Host"], in: app).exists)
        assertHeaderLayout([("title", sheetTitle), ("close", closeSSH)], in: app)
        capture(app, page: "runtime-ssh-profile-top")

        let fingerprint = sheetScroll.staticTexts["尚未验证 Host 指纹"]
        for _ in 0..<10 where !fingerprint.isHittable { sheetScroll.swipeUp() }
        XCTAssertTrue(fingerprint.isHittable, "The idle fingerprint card must be reachable by scrolling.")
        capture(app, page: "runtime-ssh-fingerprint-idle")
        let probe = button(["检查 Host 指纹"], in: app)
        for _ in 0..<10 where !probe.isHittable { sheetScroll.swipeUp() }
        XCTAssertTrue(probe.isHittable, "The fingerprint probe control must be reachable by scrolling.")
        capture(app, page: "runtime-ssh-probe-control")
        for _ in 0..<10 where !closeSSH.isHittable { sheetScroll.swipeDown() }
        XCTAssertTrue(closeSSH.isHittable)
        closeSSH.tap()
        let runtimeBack = button(["返回设置"], in: app)
        XCTAssertTrue(runtimeBack.waitForExistence(timeout: 10) && runtimeBack.isHittable)
        runtimeBack.tap()
        let executionBack = button(["返回设置"], in: app)
        XCTAssertTrue(executionBack.waitForExistence(timeout: 10) && executionBack.isHittable)
        executionBack.tap()
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 10))

        let miniAppsEntry = button(["小应用"], in: app)
        reveal(miniAppsEntry, in: app)
        miniAppsEntry.tap()
        let miniAppsSettings = button(["小应用设置"], in: app)
        let miniAppsBack = button(["返回"], in: app)
        XCTAssertTrue(miniAppsSettings.waitForExistence(timeout: 10) && miniAppsSettings.isHittable)
        XCTAssertTrue(miniAppsBack.isHittable)
        assertHeaderLayout([
            ("back", miniAppsBack), ("title", text(["小应用"], in: app)),
            ("settings", miniAppsSettings)
        ], in: app)
        let emptyMiniApps = text(["还没有小应用"], in: app)
        if emptyMiniApps.exists {
            XCTAssertTrue(text(["在聊天里说「做一个番茄钟小应用」，生成后会保存在这里。"], in: app).exists)
        } else {
            XCTAssertTrue(text(["我的小应用"], in: app).exists,
                          "Expected either saved local apps or the empty state.")
        }
        capture(app, page: "miniapp-list")
        miniAppsSettings.tap()
        let miniAppsSettingsBack = button(["返回小应用"], in: app)
        XCTAssertTrue(miniAppsSettingsBack.waitForExistence(timeout: 10) && miniAppsSettingsBack.isHittable)
        XCTAssertTrue(text(["小应用设置"], in: app).exists)
        XCTAssertTrue(text(["小应用总开关"], in: app).exists)
        capture(app, page: "miniapp-settings")
        miniAppsSettingsBack.tap()
        XCTAssertTrue(miniAppsSettings.waitForExistence(timeout: 10) && miniAppsSettings.isHittable)
        miniAppsBack.tap()
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 10))

        let councilEntry = button(["模型议会"], in: app)
        reveal(councilEntry, in: app)
        councilEntry.tap()
        let councilSettings = button(["议会设置"], in: app)
        let members = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "位成员，第"
        )).firstMatch
        XCTAssertTrue(councilSettings.waitForExistence(timeout: 10) && councilSettings.isHittable)
        XCTAssertTrue(members.isHittable)
        capture(app, page: "council-room")
        members.tap()
        let doneMembers = button(["完成"], in: app)
        let seatSection = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "席位成员（"
        )).firstMatch
        XCTAssertTrue(doneMembers.waitForExistence(timeout: 10) && doneMembers.isHittable)
        XCTAssertTrue(text(["模式"], in: app).exists && seatSection.exists)
        capture(app, page: "council-members")
        doneMembers.tap()
        XCTAssertTrue(councilSettings.waitForExistence(timeout: 10) && councilSettings.isHittable)
        councilSettings.tap()
        XCTAssertTrue(text(["议会设置"], in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(text(["模型连通性"], in: app).exists)
        capture(app, page: "council-settings")
    }

    private func button(_ labels: [String], in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func text(_ labels: [String], in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists, "Settings scroll view is unavailable.")
        for _ in 0..<10 where !element.isHittable { scroll.swipeUp() }
        for _ in 0..<10 where !element.isHittable { scroll.swipeDown() }
        XCTAssertTrue(element.isHittable, "Settings entry is not reachable: \(element.label)")
    }

    private func capture(_ app: XCUIApplication, page: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "page-\(page)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "page-\(page)-ax-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func assertHeaderLayout(_ elements: [(String, XCUIElement)], in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
        XCTAssertFalse(screen.isEmpty, "App window has no measurable frame.")
        for (name, element) in elements {
            XCTAssertTrue(element.exists, "Missing visible header element: \(name)")
            XCTAssertFalse(element.frame.isEmpty, "Header element has no frame: \(name)")
            XCTAssertTrue(screen.contains(element.frame), "Header element is outside the screen: \(name), \(element.frame)")
        }
        for (index, first) in elements.enumerated() {
            for second in elements.dropFirst(index + 1) {
                XCTAssertFalse(first.1.frame.intersects(second.1.frame),
                               "Header elements overlap: \(first.0) and \(second.0)")
            }
        }
    }
}
