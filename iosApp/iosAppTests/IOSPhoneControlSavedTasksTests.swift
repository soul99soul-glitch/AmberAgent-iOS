import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneControlSavedTasksTests: XCTestCase {
    func testPlainTaskUsesOneShotPromptHandoff() throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "整理待办", prompt: "打开备忘录，整理本周待办，完成后报告待办数量。")
        let inbox = IOSDeepLinkInbox()
        try IOSPhoneControlSavedTaskLaunch.submit(id: action.id, input: nil, store: fixture.store, inbox: inbox)
        var submitted: [URL] = []
        inbox.installHandler { submitted.append($0) }
        XCTAssertEqual(submitted.count, 1)
        let destination = try XCTUnwrap(IOSAppDeepLink.parse(try XCTUnwrap(submitted.first)))
        guard case .agentPrompt(let id) = destination else { return XCTFail("Task must enter the existing prompt handoff path") }
        XCTAssertEqual(inbox.consumePromptHandoff(id: id), action.prompt)
        XCTAssertNil(inbox.consumePromptHandoff(id: id), "The prompt is consumed only once by the new-conversation path")
    }

    func testTemplatePreparationDoesNotSubmitAndPromptIsConsumedOnce() throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "查询记录", prompt: "查找 {输入}，核对 {輸入} 和 {input}，报告记录数。")
        let inbox = IOSDeepLinkInbox()
        var submitted: [URL] = []
        var resolved: String?
        inbox.installHandler { url in
            submitted.append(url)
            if case .agentPrompt(let id) = IOSAppDeepLink.parse(url) { resolved = inbox.consumePromptHandoff(id: id) }
        }
        let url = try IOSPhoneControlSavedTaskLaunch.prepare(id: action.id, input: "  本周  ", store: fixture.store, inbox: inbox)
        XCTAssertTrue(submitted.isEmpty, "Preparing an input handoff must not navigate while its sheet is presented")
        XCTAssertNil(resolved)
        inbox.submit(url)
        XCTAssertEqual(submitted, [url])
        XCTAssertEqual(resolved, "查找 本周，核对 本周 和 本周，报告记录数。")
        guard case .agentPrompt(let id) = IOSAppDeepLink.parse(url) else { return XCTFail("Expected opaque prompt handoff") }
        XCTAssertNil(inbox.consumePromptHandoff(id: id), "A prepared handoff must not replay its consumed prompt")
        XCTAssertEqual(fixture.store.savedQuickActions().first?.prompt, action.prompt, "Per-run input must not rewrite the template")
    }

    func testFailedPreparationProducesNoURLAndNeverSubmits() throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "查询记录", prompt: "查找 {输入}。")
        let inbox = IOSDeepLinkInbox()
        var submitted = false
        inbox.installHandler { _ in submitted = true }
        XCTAssertThrowsError(try IOSPhoneControlSavedTaskLaunch.prepare(id: action.id, input: " ", store: fixture.store, inbox: inbox)) {
            XCTAssertEqual($0 as? IOSSharedQuickActionError, .missingInput)
        }
        XCTAssertFalse(submitted)
        try fixture.store.deleteQuickAction(id: action.id)
        XCTAssertThrowsError(try IOSPhoneControlSavedTaskLaunch.prepare(id: action.id, input: "本周", store: fixture.store, inbox: inbox)) {
            XCTAssertEqual($0 as? IOSSharedQuickActionError, .missingAction)
        }
        XCTAssertFalse(submitted)
    }

    func testRenderedEditorSaveUpdatesExistingAction() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "旧任务", prompt: "旧内容")
        var draft = IOSPhoneControlSavedTaskDraft(action: action)
        draft.title = "整理新待办"
        draft.prompt = "打开备忘录，整理新待办，并报告新增条目数量。"
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskEditor(sharedSettings: fixture.store, draft: draft))
        defer { host.tearDown() }
        try await host.activate(label: "保存任务")
        XCTAssertEqual(fixture.store.savedQuickActions(), [.init(id: action.id, title: draft.title, prompt: draft.prompt)])
        let reloaded = IOSSharedSettingsStore(userDefaults: fixture.defaults)
        XCTAssertEqual(reloaded.savedQuickActions(), fixture.store.savedQuickActions())
    }

    func testRenderedSearchExamplePersistsAndParameterizedRunConsumesAllSteps() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        do {
            let editor = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskEditor(
                sharedSettings: fixture.store, draft: .init()))
            defer { editor.tearDown() }
            try await editor.activate(label: "填入搜索示例")
            XCTAssertEqual(editor.element(value: "备忘录搜索")?.accessibilityValue, "备忘录搜索")
            XCTAssertEqual(editor.element(value: IOSPhoneControlSavedTaskExample.prompt)?.accessibilityValue,
                           IOSPhoneControlSavedTaskExample.prompt)
            XCTAssertNil(editor.element(label: "填入搜索示例"), "A filled prompt must no longer offer replacement")
            try await editor.activate(label: "保存任务")
        }

        let reloaded = IOSSharedSettingsStore(userDefaults: fixture.defaults)
        let action = try XCTUnwrap(reloaded.savedQuickActions().first)
        XCTAssertEqual(action.title, "备忘录搜索")
        XCTAssertEqual(action.prompt, IOSPhoneControlSavedTaskExample.prompt)
        XCTAssertTrue(action.isTemplate)

        let inbox = IOSDeepLinkInbox()
        var prepared: [URL] = []
        var submitted: [URL] = []
        var receivedPrompt: String?
        inbox.installHandler { url in
            submitted.append(url)
            if case .agentPrompt(let id) = IOSAppDeepLink.parse(url) {
                receivedPrompt = inbox.consumePromptHandoff(id: id)
            }
        }
        do {
            let runInput = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskRunInput(
                sharedSettings: reloaded, action: action, inbox: inbox, input: "  跨部门会议  ",
                onPrepared: { prepared.append($0) }))
            defer { runInput.tearDown() }
            try await runInput.activate(label: "运行任务")
            XCTAssertEqual(prepared.count, 1)
            XCTAssertTrue(submitted.isEmpty, "The input sheet must prepare without navigating")
            XCTAssertNil(receivedPrompt)
        }
        let url = try XCTUnwrap(prepared.first)
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query,
                     "The URL carries only an opaque handoff identifier")
        inbox.submit(url)
        XCTAssertEqual(submitted, [url])
        XCTAssertEqual(receivedPrompt, """
        在备忘录中搜索 跨部门会议。
        1. 打开备忘录，确认已进入备忘录页面。
        2. 找到并点开搜索框，确认搜索框为空；若有旧内容，先清空并确认。
        3. 在空的搜索框中输入 跨部门会议，核对搜索框显示的完整内容与本次输入一致。
        4. 确认已经进入搜索结果页，停留在该页。不要打开、改写或删除笔记。
        每一步都根据当前画面重新定位并核验结果；遇到不匹配时停止并说明。
        """)
        guard case .agentPrompt(let id) = IOSAppDeepLink.parse(url) else {
            return XCTFail("Expected the existing opaque prompt handoff")
        }
        XCTAssertNil(inbox.consumePromptHandoff(id: id), "A submitted search must not replay")
        XCTAssertEqual(reloaded.savedQuickActions(), [action], "Per-run input must preserve the saved template")
    }

    func testRenderedSearchExampleKeepsEnteredTitle() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskEditor(
            sharedSettings: fixture.store, draft: .init(title: "我的记录查询")))
        defer { host.tearDown() }
        try await host.activate(label: "填入搜索示例")
        XCTAssertEqual(host.element(value: "我的记录查询")?.accessibilityValue, "我的记录查询")
        try await host.activate(label: "保存任务")
        XCTAssertEqual(fixture.store.savedQuickActions().first?.title, "我的记录查询")
        XCTAssertEqual(fixture.store.savedQuickActions().first?.prompt, IOSPhoneControlSavedTaskExample.prompt)
    }

    func testRenderedSearchExampleCannotReplaceNonemptyOrExistingTask() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "已有任务", prompt: "保留原目标。")
        for draft in [IOSPhoneControlSavedTaskDraft(title: "新目标", prompt: "保留新输入。"),
                      IOSPhoneControlSavedTaskDraft(action: action)] {
            let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskEditor(
                sharedSettings: fixture.store, draft: draft))
            defer { host.tearDown() }
            try await host.waitForElement(label: "保存任务")
            XCTAssertNil(host.element(label: "填入搜索示例"))
            XCTAssertEqual(host.element(value: draft.prompt)?.accessibilityValue, draft.prompt)
        }
        XCTAssertEqual(fixture.store.savedQuickActions(), [action])
    }

    func testRenderedEditorValidationLeavesFieldsAndErrorVisible() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let draft = IOSPhoneControlSavedTaskDraft(title: "", prompt: "打开备忘录，整理本周待办。")
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskEditor(sharedSettings: fixture.store, draft: draft))
        defer { host.tearDown() }
        try await host.activate(label: "保存任务")
        let error = IOSSharedQuickActionError.emptyTitle.localizedDescription
        try await host.waitForElement(label: error)
        XCTAssertEqual(host.element(label: error)?.accessibilityLabel, error)
        let promptField = try XCTUnwrap(host.element(value: draft.prompt))
        XCTAssertEqual(promptField.accessibilityValue, draft.prompt, "Save failure must preserve the entered goal")
        XCTAssertFalse(promptField.accessibilityTraits.contains(.notEnabled))
        XCTAssertNotNil(host.element(label: "保存任务"))
        XCTAssertTrue(fixture.store.savedQuickActions().isEmpty)
    }

    func testRenderedInputFailureDoesNotCloseOrSubmit() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "查询记录", prompt: "查找 {输入} 并报告数量。")
        let inbox = IOSDeepLinkInbox()
        var prepared: [URL] = []
        var submitted = false
        inbox.installHandler { _ in submitted = true }
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskRunInput(
            sharedSettings: fixture.store, action: action, inbox: inbox, onPrepared: { prepared.append($0) }))
        defer { host.tearDown() }
        try await host.activate(label: "运行任务")
        try await host.waitForElement(label: IOSSharedQuickActionError.missingInput.localizedDescription)
        XCTAssertTrue(prepared.isEmpty, "Failed validation must not ask the parent to close the sheet")
        XCTAssertFalse(submitted)
        let inputField = try XCTUnwrap(host.element(value: "填写任务中的 {输入}"))
        XCTAssertEqual(inputField.accessibilityValue, "填写任务中的 {输入}")
        XCTAssertFalse(inputField.accessibilityTraits.contains(.notEnabled))
    }

    func testRenderedInputPreparesLatestGoalOnceWithoutSubmitting() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "查询记录", prompt: "查找 {输入} 并报告数量。")
        let inbox = IOSDeepLinkInbox()
        var prepared: [URL] = []
        var submitted: [URL] = []
        inbox.installHandler { submitted.append($0) }
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTaskRunInput(
            sharedSettings: fixture.store, action: action, inbox: inbox, input: "本周待办", onPrepared: { prepared.append($0) }))
        defer { host.tearDown() }
        _ = try fixture.store.saveQuickAction(id: action.id, title: action.title, prompt: "核对 {输入} 并报告已完成数量。")
        try await host.activate(label: "运行任务")
        XCTAssertEqual(prepared.count, 1)
        XCTAssertTrue(submitted.isEmpty, "The input page only prepares; its parent submits after dismissal")
        let runButton = try XCTUnwrap(host.element(label: "运行任务"))
        XCTAssertTrue(runButton.accessibilityTraits.contains(.notEnabled))
        _ = runButton.accessibilityActivate()
        XCTAssertEqual(prepared.count, 1, "A second activation during dismissal must not prepare another handoff")
        let url = try XCTUnwrap(prepared.first)
        guard case .agentPrompt(let id) = IOSAppDeepLink.parse(url) else { return XCTFail("Expected opaque prompt handoff") }
        XCTAssertEqual(inbox.consumePromptHandoff(id: id), "核对 本周待办 并报告已完成数量。")
        XCTAssertNil(inbox.consumePromptHandoff(id: id))
        XCTAssertTrue(submitted.isEmpty)
    }

    func testRenderedListReloadsAfterRevisionAndRunsPlainTask() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let inbox = IOSDeepLinkInbox()
        var prompt: String?
        inbox.installHandler { url in
            if case .agentPrompt(let id) = IOSAppDeepLink.parse(url) { prompt = inbox.consumePromptHandoff(id: id) }
        }
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTasksView(sharedSettings: fixture.store, inbox: inbox))
        defer { host.tearDown() }
        try await host.waitForElement(label: "还没有常用任务")
        let action = try fixture.store.saveQuickAction(title: "检查待办", prompt: "打开备忘录并报告待办数量。")
        try await host.activate(label: "运行 \(action.title)")
        XCTAssertEqual(prompt, action.prompt)
        XCTAssertNil(host.element(label: "还没有常用任务"))
    }

    func testRenderedDeletePresentsConfirmationWithoutRemovingTask() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let action = try fixture.store.saveQuickAction(title: "待删除任务", prompt: "打开备忘录。")
        let host = try SavedTasksHostingFixture(root: IOSPhoneControlSavedTasksView(sharedSettings: fixture.store))
        defer { host.tearDown() }
        try await host.activate(label: "删除 \(action.title)")
        try await host.waitForElement(label: "删除“待删除任务”")
        let confirm = try XCTUnwrap(host.element(label: "删除“待删除任务”"))
        XCTAssertTrue(confirm.accessibilityTraits.contains(.button))
        XCTAssertFalse(confirm.accessibilityTraits.contains(.notEnabled))
        // The first tap only presents confirmation. The full system confirmation
        // and deletion flow is verified separately through the normal app UI.
        XCTAssertEqual(fixture.store.savedQuickActions(), [action], "Presenting confirmation must not delete the task")
    }
}

@MainActor
final class SavedTasksStoreFixture {
    let suite = "SavedTasks.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: IOSSharedSettingsStore

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = IOSSharedSettingsStore(userDefaults: defaults)
        for action in store.savedQuickActions() { try store.deleteQuickAction(id: action.id) }
    }

    func tearDown() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
final class SavedTasksHostingFixture {
    let window: UIWindow
    private let previous: UIWindow?

    init<Content: View>(root: Content, width: CGFloat = 393, height: CGFloat = 1_800,
                       type: DynamicTypeSize = .large, style: UIUserInterfaceStyle = .dark) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = UIHostingController(rootView: root
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, type))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }

    func activate(label: String) async throws {
        for _ in 0..<100 {
            window.layoutIfNeeded()
            if let button = elements().first(where: {
                $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label
            }) {
                XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
                XCTAssertGreaterThanOrEqual(button.accessibilityFrame.height, 44, "Task controls need a 44 pt tap target")
                guard button.accessibilityActivate() else {
                    XCTFail("Rendered task control did not activate: \(label)")
                    throw NSError(domain: "SavedTasksHostingFixture", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Task control did not activate: \(label)"])
                }
                try await Task.sleep(for: .milliseconds(150))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Rendered task control did not appear: \(label)")
        throw NSError(domain: "SavedTasksHostingFixture", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Task control did not appear: \(label)"])
    }

    func waitForElement(label: String) async throws {
        for _ in 0..<100 {
            window.layoutIfNeeded()
            if element(label: label) != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Rendered element did not appear: \(label)")
        throw NSError(domain: "SavedTasksHostingFixture", code: 1)
    }

    // SwiftUI virtual AX elements expose their labels in this unit-test host;
    // casting them to UIAccessibilityIdentification hides otherwise valid controls.
    func element(label: String) -> NSObject? {
        elements().first { $0.accessibilityLabel == label }
    }

    func element(value: String) -> NSObject? {
        elements().first { $0.accessibilityValue == value }
    }

    private func elements() -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object.isAccessibilityElement { result.append(object) }
            if let view = object as? UIView { view.subviews.forEach(visit) }
            if let children = object.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach(visit)
            } else {
                let count = object.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
        }
        visit(window)
        return result
    }
}
