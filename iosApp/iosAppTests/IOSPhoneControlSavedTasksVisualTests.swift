import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneControlSavedTasksVisualTests: XCTestCase {
    func testValidationErrorsAreVisibleWhenActionsAreActivatedFromBottomOfAccessibilityForm() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let template = try fixture.store.saveQuickAction(title: IOSPhoneControlSavedTaskExample.title,
                                                         prompt: IOSPhoneControlSavedTaskExample.prompt)
        try await assertValidationVisibleFromBottom(
            IOSPhoneControlSavedTaskEditor(sharedSettings: fixture.store,
                                          draft: .init(prompt: IOSPhoneControlSavedTaskExample.prompt)),
            actionLabel: "保存任务", errorLabel: IOSSharedQuickActionError.emptyTitle.localizedDescription,
            name: "phone-saved-task-empty-title-error-from-bottom-accessibility")
        let inbox = IOSDeepLinkInbox()
        var didPrepare = false
        var didSubmit = false
        inbox.installHandler { _ in didSubmit = true }
        try await assertValidationVisibleFromBottom(
            IOSPhoneControlSavedTaskRunInput(sharedSettings: fixture.store, action: template, inbox: inbox,
                                            onPrepared: { _ in didPrepare = true }),
            actionLabel: "运行任务", errorLabel: IOSSharedQuickActionError.missingInput.localizedDescription,
            name: "phone-saved-task-missing-input-error-from-bottom-accessibility")
        XCTAssertFalse(didPrepare)
        XCTAssertFalse(didSubmit)
        XCTAssertEqual(fixture.store.savedQuickActions(), [template])
    }

    func testSaveAndRunValidationFailuresAtNormalAndAccessibilityWidths() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let template = try fixture.store.saveQuickAction(title: IOSPhoneControlSavedTaskExample.title,
                                                         prompt: IOSPhoneControlSavedTaskExample.prompt)
        let inbox = IOSDeepLinkInbox()
        var prepared: [URL] = []
        var submitted: [URL] = []
        inbox.installHandler { submitted.append($0) }
        for (suffix, width, type, style) in [
            ("normal", 393.0, DynamicTypeSize.large, UIUserInterfaceStyle.dark),
            ("accessibility", 320.0, .accessibility3, .light)
        ] {
            try await render(IOSPhoneControlSavedTaskEditor(
                sharedSettings: fixture.store, draft: .init(prompt: IOSPhoneControlSavedTaskExample.prompt)),
                             name: "phone-saved-task-empty-title-error-\(suffix)",
                             width: width, type: type, style: style, interaction: { host in
                try await host.activate(label: "保存任务")
                try await host.waitForElement(label: IOSSharedQuickActionError.emptyTitle.localizedDescription)
                XCTAssertEqual(host.element(value: IOSPhoneControlSavedTaskExample.prompt)?.accessibilityValue,
                               IOSPhoneControlSavedTaskExample.prompt, "Save failure must preserve all entered steps")
                XCTAssertEqual(fixture.store.savedQuickActions(), [template], "Invalid edits must not create a task")
            })
            try await render(IOSPhoneControlSavedTaskRunInput(
                sharedSettings: fixture.store, action: template, inbox: inbox,
                onPrepared: { prepared.append($0) }),
                             name: "phone-saved-task-missing-input-error-\(suffix)",
                             width: width, type: type, style: style, interaction: { host in
                try await host.activate(label: "运行任务")
                try await host.waitForElement(label: IOSSharedQuickActionError.missingInput.localizedDescription)
                let runButton = try XCTUnwrap(host.element(label: "运行任务"))
                XCTAssertFalse(runButton.accessibilityTraits.contains(.notEnabled), "Validation failure must allow correction")
                XCTAssertNotNil(host.element(value: "填写任务中的 {输入}"))
                XCTAssertTrue(prepared.isEmpty, "Missing input must not prepare a handoff or request dismissal")
                XCTAssertTrue(submitted.isEmpty, "Missing input must not navigate")
                XCTAssertEqual(fixture.store.savedQuickActions(), [template])
            })
        }
    }

    func testSearchExampleCreationAndLongStepInputAtNormalAndAccessibilityWidths() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        let example = try fixture.store.saveQuickAction(title: IOSPhoneControlSavedTaskExample.title,
                                                        prompt: IOSPhoneControlSavedTaskExample.prompt)
        for (suffix, width, type, style) in [
            ("normal", 393.0, DynamicTypeSize.large, UIUserInterfaceStyle.dark),
            ("accessibility", 320.0, .accessibility3, .light)
        ] {
            try await render(IOSPhoneControlSavedTaskEditor(sharedSettings: fixture.store, draft: .init()),
                             name: "phone-search-example-create-\(suffix)", width: width, type: type, style: style)
            try await render(IOSPhoneControlSavedTaskEditor(sharedSettings: fixture.store, draft: .init()),
                             name: "phone-search-example-filled-\(suffix)", width: width, type: type, style: style,
                             interaction: { try await $0.activate(label: "填入搜索示例") })
            try await render(IOSPhoneControlSavedTaskRunInput(
                sharedSettings: fixture.store, action: example,
                input: "本周跨部门协作会议中，与移动端自动化测试、发布检查及客户反馈相关的所有未完成事项"),
                             name: "phone-search-example-step-input-\(suffix)", width: width, type: type, style: style)
            try await render(IOSPhoneControlSavedTasksView(sharedSettings: fixture.store),
                             name: "phone-search-example-saved-\(suffix)", width: width, type: type, style: style)
        }
    }

    func testListEmptyEditorAndInputAtNormalAndAccessibilityWidths() async throws {
        let fixture = try SavedTasksStoreFixture()
        defer { fixture.tearDown() }
        for (suffix, width, type, style) in [
            ("normal", 393.0, DynamicTypeSize.large, UIUserInterfaceStyle.dark),
            ("accessibility", 320.0, .accessibility3, .light)
        ] {
            try await render(IOSPhoneControlSavedTasksView(sharedSettings: fixture.store),
                             name: "phone-saved-tasks-empty-\(suffix)", width: width, type: type, style: style)
        }
        let plain = try fixture.store.saveQuickAction(
            title: "整理本周备忘录并检查每项待办的截止时间",
            prompt: "打开备忘录，整理本周的工作待办。保留原有内容，将重复条目合并，最后报告待办数量和缺少截止时间的条目。")
        let template = try fixture.store.saveQuickAction(
            title: "查找指定主题的记录并核对每条记录的处理结果",
            prompt: "在备忘录中查找 {输入} 相关记录。逐条核对记录是否已处理，完成后报告记录数量和仍未完成的项目。")
        for (suffix, width, type, style) in [
            ("normal", 393.0, DynamicTypeSize.large, UIUserInterfaceStyle.dark),
            ("accessibility", 320.0, .accessibility3, .light)
        ] {
            try await render(IOSPhoneControlSavedTasksView(sharedSettings: fixture.store),
                             name: "phone-saved-tasks-list-\(suffix)", width: width, type: type, style: style)
            try await render(IOSPhoneControlSavedTaskEditor(sharedSettings: fixture.store, draft: .init(action: plain)),
                             name: "phone-saved-tasks-editor-\(suffix)", width: width, type: type, style: style)
            try await render(IOSPhoneControlSavedTaskRunInput(sharedSettings: fixture.store, action: template,
                                                             input: "本周跨部门协作会议中仍未处理的待办事项"),
                             name: "phone-saved-tasks-input-\(suffix)", width: width, type: type, style: style)
        }
    }

    private func assertValidationVisibleFromBottom<Content: View>(
        _ view: Content, actionLabel: String, errorLabel: String, name: String
    ) async throws {
        let host = try SavedTasksHostingFixture(root: view, width: 320, height: 900,
                                               type: .accessibility3, style: .light)
        defer { host.tearDown() }
        try await Task.sleep(for: .milliseconds(400))
        host.window.layoutIfNeeded()
        let scroll = try XCTUnwrap(firstScrollView(in: host.window))
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "This regression requires a scrolling form")
        scroll.scrollRectToVisible(CGRect(x: 0, y: scroll.contentSize.height - 1,
                                         width: scroll.bounds.width, height: 1), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        host.window.layoutIfNeeded()
        XCTAssertGreaterThan(scroll.contentOffset.y, 0, "The action must be triggered after actually scrolling")
        let viewport = scroll.convert(scroll.bounds, to: nil).intersection(host.window.convert(host.window.bounds, to: nil))
        try capture(host.window, name: "\(name)-before-action")
        try await host.waitForElement(label: actionLabel)
        let button = try XCTUnwrap(host.element(label: actionLabel))
        XCTAssertTrue(button.accessibilityFrame.intersects(viewport), "The action must be visible before activation")
        let offsetBeforeAction = scroll.contentOffset.y
        try await host.activate(label: actionLabel)
        try await Task.sleep(for: .milliseconds(400))
        host.window.layoutIfNeeded()
        // Preserve the resulting scroll position; a top-of-form capture would hide the regression.
        try capture(host.window, name: name)
        let errorFrame = host.element(label: errorLabel)?.accessibilityFrame ?? .null
        let resultingViewport = scroll.convert(scroll.bounds, to: nil)
            .intersection(host.window.convert(host.window.bounds, to: nil))
        print("PHONE_SAVED_TASK_ERROR_POSITION \(name) offset_before=\(offsetBeforeAction) offset_after=\(scroll.contentOffset.y) error=\(errorFrame) viewport=\(resultingViewport)")
        XCTAssertTrue(resultingViewport.contains(errorFrame),
                      "The full validation message must be readable from the position where the user triggered the action")
    }

    private func render<Content: View>(_ view: Content, name: String, width: CGFloat,
                                      type: DynamicTypeSize, style: UIUserInterfaceStyle,
                                      interaction: ((SavedTasksHostingFixture) async throws -> Void)? = nil) async throws {
        let host = try SavedTasksHostingFixture(root: view, width: width, height: 900, type: type, style: style)
        defer { host.tearDown() }
        try await Task.sleep(for: .milliseconds(400))
        try await interaction?(host)
        host.window.layoutIfNeeded()
        let scroll = try XCTUnwrap(firstScrollView(in: host.window))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                 "Multiline task content must fit the viewport width")
        try capture(host.window, name: name)
        let pageHeight = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        XCTAssertGreaterThan(pageHeight, 0)
        guard pageHeight > 0 else { return }
        var page = 2
        while scroll.contentOffset.y + pageHeight < scroll.contentSize.height - 1 {
            let previousOffset = scroll.contentOffset.y
            scroll.scrollRectToVisible(CGRect(x: 0, y: previousOffset + pageHeight,
                                             width: scroll.bounds.width, height: pageHeight), animated: false)
            try await Task.sleep(for: .milliseconds(120))
            host.window.layoutIfNeeded()
            guard scroll.contentOffset.y > previousOffset else { break }
            try capture(host.window, name: "\(name)-page-\(page)")
            page += 1
        }
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PHONE_SAVED_TASKS_EVIDENCE \(url.path)")
    }
}
