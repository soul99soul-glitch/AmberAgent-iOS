import SwiftUI
import UIKit
import XCTest
@testable import iosApp

/// Renders the bubble and collection sheet entry points used by NovelSessionView.
/// These unit-host probes measure scrolling and viewport geometry; screenshots
/// retain the rendered controls for separate visual review.
@MainActor
final class NovelModularizationLayoutTests: XCTestCase {
    private let viewportHeight: CGFloat = 740

    func testLongCandidateRendersWithinNarrowScrollViewport() async throws {
        let content = "# 第十二章 · 风雨夜\n\n"
            + String(repeating: "破庙里的风裹着雨气，众人压低声音商议下一步。\n\n", count: 100)
            + "- 城门的线索仍需核对\n- 明早再查守卫的说法"

        for (width, type) in layoutCases {
            let candidateID = NovelCandidateID()
            let bubble = makeBubble(
                kind: .proseCandidate,
                granularity: .wholeChapter,
                content: content,
                actions: [.init(action: .collectProse(candidateID), blocker: nil)]
            )
            let fixture = try HostingFixture(
                root: ScrollView { bubble.padding(.horizontal, ChatLayout.contentHorizontalInset) },
                width: width, height: viewportHeight, type: type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let scroll = try XCTUnwrap(fixture.mainScrollView())
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 20,
                                 "Long candidate must exercise actual scrolling")
            assertScrollFitsHorizontally(fixture, scroll: scroll)
            fixture.scrollToBottom(scroll)
            try await fixture.settle()
            XCTAssertGreaterThan(scroll.contentOffset.y, 0,
                                 "The long candidate must reach a scrolled position")
            try attachPNG(fixture.window, name: "novel-candidate-\(suffix(width, type))")
        }
    }

    func testAskUserCardRendersAtTopAndBottomOfViewport() async throws {
        let prompt = NovelAskUserPrompt(
            question: "城门守卫要求当场决定，主角要如何解释那封来历不明的密信？",
            options: [
                "公开密信内容，并请守卫逐项核对其中涉及的时间、人物和地点。",
                "暂时封存密信，先向同行者说明风险，再一起决定是否继续调查。"
            ]
        )
        for (width, type) in layoutCases {
            let bubble = makeBubble(
                kind: .discussion,
                content: "我需要你确认下一步，选项会影响后续讨论。",
                askUser: .init(prompt: prompt, response: nil)
            )
            let fixture = try HostingFixture(
                root: ScrollView { bubble.padding(.horizontal, ChatLayout.contentHorizontalInset) },
                width: width, height: viewportHeight, type: type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let scroll = try XCTUnwrap(fixture.mainScrollView())
            assertScrollFitsHorizontally(fixture, scroll: scroll)
            try attachPNG(fixture.window, name: "novel-ask-user-top-\(suffix(width, type))")
            fixture.scrollToBottom(scroll)
            try await fixture.settle()
            assertScrollFitsHorizontally(fixture, scroll: scroll)
            try attachPNG(fixture.window, name: "novel-ask-user-bottom-\(suffix(width, type))")
        }
    }

    func testCollectionSheetRendersEditablePreviewWithinViewport() async throws {
        let paragraphs = (0..<4).map { index in
            NovelParagraphRecord(
                id: NovelParagraphID(rawValue: "layout-paragraph-\(index)"),
                text: "第\(index + 1)段：" + String(repeating: "雨声盖过了脚步，线索仍要保留在候选稿里。", count: 14)
            )
        }
        for (width, type) in layoutCases {
            let sheet = NovelCollectCandidateSheet(
                paragraphs: paragraphs,
                chapters: [],
                nextChapterOrdinal: 1,
                suggestedGranularity: .wholeChapter,
                onCollect: { _, _ in .completed }
            )
            let fixture = try HostingFixture(
                root: sheet, width: width, height: viewportHeight, type: type
            )
            defer { fixture.close() }
            try await fixture.settle()
            let scroll = try XCTUnwrap(fixture.outerScrollView(), fixture.scrollSummary())
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 20,
                                 "Collection form must exercise actual scrolling")
            assertScrollFitsHorizontally(fixture, scroll: scroll)
            let editor = try await fixture.scrollUntilEditorVisible(in: scroll)
            try attachPNG(fixture.window, name: "novel-collect-sheet-editor-\(suffix(width, type))")

            let editorFrame = editor.convert(editor.bounds, to: nil)
            let viewport = fixture.visibleBounds(of: scroll)
            XCTAssertTrue(editorFrame.intersects(viewport), "The editable preview must be reachable by scrolling")
            XCTAssertGreaterThanOrEqual(editorFrame.minX, fixture.windowBounds.minX - 1)
            XCTAssertLessThanOrEqual(editorFrame.maxX, fixture.windowBounds.maxX + 1)
            let reachedBottom = try await fixture.scrollToActualBottom(scroll)
            XCTAssertTrue(reachedBottom,
                          "Collection form did not reach stable bottom: \(fixture.scrollSummary())")
            let chapterTitleField = try XCTUnwrap(fixture.textFields().first,
                                                  "Bottom chapter title field did not mount: \(fixture.scrollSummary())")
            let titleFrame = chapterTitleField.convert(chapterTitleField.bounds, to: nil)
            XCTAssertTrue(titleFrame.intersects(fixture.visibleBounds(of: scroll)),
                          "Bottom chapter title field must be visible: \(fixture.scrollSummary())")
            XCTAssertGreaterThanOrEqual(titleFrame.minX, fixture.windowBounds.minX - 1)
            XCTAssertLessThanOrEqual(titleFrame.maxX, fixture.windowBounds.maxX + 1)
            assertScrollFitsHorizontally(fixture, scroll: scroll)
            try attachPNG(fixture.window, name: "novel-collect-sheet-bottom-\(suffix(width, type))")
        }
    }

    private var layoutCases: [(CGFloat, DynamicTypeSize)] {
        [(320, .large), (393, .large), (320, .accessibility3), (393, .accessibility3)]
    }

    private func suffix(_ width: CGFloat, _ type: DynamicTypeSize) -> String {
        "\(Int(width))-\(type.isAccessibilitySize ? "ax3" : "normal")"
    }

    private func makeBubble(
        kind: NovelSessionMessageKind,
        granularity: NovelGenerationGranularity? = nil,
        content: String,
        askUser: NovelAskUserPresentation? = nil,
        actions: [NovelSessionRowActionAvailability] = []
    ) -> NovelSessionBubble {
        NovelSessionBubble(
            messageID: NovelMessageID(),
            role: .assistant,
            kind: kind,
            granularity: granularity,
            content: content,
            isStreaming: false,
            transientPhase: nil,
            hasEverStreamed: false,
            runStatus: nil,
            candidateStatus: kind == .proseCandidate ? .available : nil,
            isRegeneration: false,
            polishTransactionStatus: nil,
            isAdoptingPolish: false,
            committedChange: nil,
            askUser: askUser,
            actions: actions,
            onAction: { _ in },
            onAnswerAskUser: { _, _ in }
        )
    }

    private func assertScrollFitsHorizontally(
        _ fixture: HostingFixture, scroll: UIScrollView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertGreaterThan(frame.width, 0, "Scroll viewport must be rendered", file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, "Scroll viewport must be rendered", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, fixture.windowBounds.minX - 1,
                                    "Scroll viewport clips at the left edge", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, fixture.windowBounds.maxX + 1,
                                 "Scroll viewport clips at the right edge", file: file, line: line)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                 "Scrolled content must not require horizontal panning", file: file, line: line)
    }

    private func attachPNG(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true),
                          "Hosted view must be composited for the PNG")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-phase4-layout-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(
            to: directory.appendingPathComponent("\(name).png"), options: .atomic
        )
    }
}

@MainActor
private final class HostingFixture {
    let window: UIWindow
    private let host: UIViewController
    private let previousKeyWindow: UIWindow?

    var windowBounds: CGRect { window.convert(window.bounds, to: nil) }

    init<Content: View>(root: Content, width: CGFloat, height: CGFloat, type: DynamicTypeSize) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        window.traitOverrides.preferredContentSizeCategory = type.isAccessibilitySize
            ? .accessibilityExtraLarge : .large
        host = UIHostingController(rootView: root
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .environment(\.dynamicTypeSize, type))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(450))
        window.layoutIfNeeded()
    }

    func mainScrollView() -> UIScrollView? {
        scrollViews(in: host.view)
            .filter { !($0 is UITextView) }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    // Form rows are lazy. Select its outer scroll container by view-tree order,
    // before comparing content sizes that can change as lower rows mount.
    func outerScrollView() -> UIScrollView? {
        scrollViews(in: host.view).first {
            !($0 is UITextView) && $0.window === window && !$0.bounds.isEmpty
        }
    }

    func scrollSummary() -> String {
        scrollViews(in: host.view).map { scroll in
            "\(type(of: scroll)) frame=\(scroll.convert(scroll.bounds, to: nil)) "
                + "content=\(scroll.contentSize) offset=\(scroll.contentOffset)"
        }.joined(separator: "; ")
    }

    func scrollUntilEditorVisible(in scroll: UIScrollView) async throws -> UITextView {
        for _ in 0..<24 {
            if let editor = textViews().first(where: {
                $0.convert($0.bounds, to: nil).intersects(visibleBounds(of: scroll))
            }) {
                return editor
            }
            let nextOffset = min(maxScrollOffset(of: scroll),
                                 scroll.contentOffset.y + scroll.bounds.height * 0.75)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: nextOffset), animated: false)
            try await settle()
        }
        return try XCTUnwrap(textViews().first(where: {
            $0.convert($0.bounds, to: nil).intersects(visibleBounds(of: scroll))
        }), "Editable preview did not mount in the viewport after 24 scroll steps: \(scrollSummary())")
    }

    func scrollToActualBottom(_ scroll: UIScrollView) async throws -> Bool {
        var stableBottomPasses = 0
        for _ in 0..<24 {
            let contentHeightBefore = scroll.contentSize.height
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: maxScrollOffset(of: scroll)),
                                    animated: false)
            try await settle()
            let actualMaxOffset = maxScrollOffset(of: scroll)
            let contentStable = abs(scroll.contentSize.height - contentHeightBefore) <= 1
            let atBottom = abs(scroll.contentOffset.y - actualMaxOffset) <= 1
            stableBottomPasses = contentStable && atBottom ? stableBottomPasses + 1 : 0
            if stableBottomPasses == 2 { return true }
        }
        return false
    }

    private func maxScrollOffset(of scroll: UIScrollView) -> CGFloat {
        max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    }

    func scrollToBottom(_ scroll: UIScrollView) {
        scroll.scrollRectToVisible(CGRect(
            x: 0, y: max(0, scroll.contentSize.height - 1),
            width: scroll.bounds.width, height: 1
        ), animated: false)
        window.layoutIfNeeded()
    }

    func visibleBounds(of scroll: UIScrollView) -> CGRect {
        scroll.convert(scroll.bounds, to: nil).intersection(windowBounds)
    }

    func textViews() -> [UITextView] {
        views(in: host.view).compactMap { $0 as? UITextView }
    }

    func textFields() -> [UITextField] {
        views(in: host.view).compactMap { $0 as? UITextField }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        views(in: view).compactMap { $0 as? UIScrollView }
    }

    private func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }
}
