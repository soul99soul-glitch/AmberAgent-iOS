import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneControlSavedTasksVisualTests: XCTestCase {
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

    private func render<Content: View>(_ view: Content, name: String, width: CGFloat,
                                      type: DynamicTypeSize, style: UIUserInterfaceStyle) async throws {
        let host = try SavedTasksHostingFixture(root: view, width: width, height: 900, type: type, style: style)
        defer { host.tearDown() }
        try await Task.sleep(for: .milliseconds(400))
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
