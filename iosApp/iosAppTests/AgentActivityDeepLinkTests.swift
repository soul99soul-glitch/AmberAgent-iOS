import XCTest
import UIKit
@testable import iosApp

final class AgentActivityDeepLinkTests: XCTestCase {
    func testRoundTripKeepsOnlyTaskIdentifiersAndFocus() throws {
        let url = try XCTUnwrap(AgentActivityDeepLink.makeURL(
            runId: "run-123",
            conversationId: "01234567-89ab-cdef-0123-456789abcdef",
            focus: .confirmation
        ))

        XCTAssertEqual(url.scheme, AgentActivityDeepLink.scheme)
        XCTAssertEqual(
            AgentActivityDeepLink.parse(url),
            AgentActivityDeepLink.Target(
                runId: "run-123",
                conversationId: "01234567-89ab-cdef-0123-456789abcdef",
                focus: .confirmation
            )
        )
        XCTAssertFalse(url.absoluteString.contains("prompt"))
        XCTAssertFalse(url.absoluteString.contains("command"))
    }

    func testParserRejectsAnythingOutsideTheActivityContract() {
        XCTAssertNil(AgentActivityDeepLink.parse(URL(string: "https://activity/run?conversation=abc&focus=task")!))
        let otherScheme = AgentActivityDeepLink.scheme == "amber" ? "amber-experimental" : "amber"
        XCTAssertNil(AgentActivityDeepLink.parse(URL(string: "\(otherScheme)://activity/run?conversation=abc&focus=task")!))
        XCTAssertNil(AgentActivityDeepLink.parse(URL(string: "amber://settings/run?conversation=abc&focus=task")!))
        XCTAssertNil(AgentActivityDeepLink.parse(URL(string: "amber://activity//run?conversation=abc&focus=task")!))
        XCTAssertNil(AgentActivityDeepLink.parse(URL(string: "amber://activity/run?conversation=abc&focus=approve")!))
        XCTAssertNil(AgentActivityDeepLink.parse(URL(string: "amber://activity/run?focus=task")!))
        XCTAssertNil(AgentActivityDeepLink.parse(
            URL(string: "amber://activity/run?conversation=abc&focus=task&approve=true")!
        ))
        XCTAssertNil(AgentActivityDeepLink.makeURL(
            runId: String(repeating: "r", count: 129),
            conversationId: "01234567-89ab-cdef-0123-456789abcdef",
            focus: .task
        ))
    }

    func testSchemeMatchesBothAppAndWidgetBundleFamilies() {
        XCTAssertEqual(
            AgentActivityDeepLink.scheme(forBundleIdentifier: "app.amber.ios"),
            "amber"
        )
        XCTAssertEqual(
            AgentActivityDeepLink.scheme(forBundleIdentifier: "app.amber.ios.activity"),
            "amber"
        )
        XCTAssertEqual(
            AgentActivityDeepLink.scheme(
                forBundleIdentifier: "app.amber.ios.experimental-gpl"
            ),
            "amber-experimental"
        )
        XCTAssertEqual(
            AgentActivityDeepLink.scheme(
                forBundleIdentifier: "app.amber.ios.experimental-gpl.activity"
            ),
            "amber-experimental"
        )
    }

    func testAttributesWithoutConversationOwnershipExposeNoDestination() {
        let attributes = AgentActivityAttributes(
            runId: "run-123",
            conversationId: nil,
            startedAt: .now,
            conversationTitle: nil
        )

        XCTAssertNil(attributes.destinationURL(for: .openTask))
    }

    func testDeepReadAttributesOpenTheDeepReadTask() throws {
        let attributes = AgentActivityAttributes(
            runId: "TASK-1:GEN-1",
            conversationId: nil,
            startedAt: .now,
            conversationTitle: "某个热点",
            deepReadTaskId: "6F1C2A4B-0D2E-4F3A-9B8C-1234567890AB"
        )

        let url = try XCTUnwrap(attributes.destinationURL(for: .openTask))
        XCTAssertNil(AgentActivityDeepLink.parse(url))
        XCTAssertEqual(
            IOSAppDeepLink.parse(url),
            .deepReadTask(id: "6F1C2A4B-0D2E-4F3A-9B8C-1234567890AB")
        )
        XCTAssertEqual(IOSAppDeepLink.url(for: .deepReadTask(id: "6F1C2A4B-0D2E-4F3A-9B8C-1234567890AB")), url)
        XCTAssertNil(IOSAppDeepLink.parse(URL(string: "\(AgentActivityDeepLink.scheme)://deep-read/a/b")!))
    }

    func testWebDetailUsesHostWithoutWWW() {
        XCTAssertEqual(AgentActivityStepDetailPolicy.webDetail(url: "https://www.nytimes.com/2026/10/02/x.html"), "nytimes.com")
        XCTAssertNil(AgentActivityStepDetailPolicy.webDetail(url: nil))
        XCTAssertNil(AgentActivityStepDetailPolicy.webDetail(url: "  "))
    }

    func testOpenTaskAttributesRoundTripToOwnedConversation() throws {
        let attributes = AgentActivityAttributes(
            runId: "run-123",
            conversationId: "01234567-89ab-cdef-0123-456789abcdef",
            startedAt: .now,
            conversationTitle: "赵匡胤的打仗风格是什么？"
        )

        let url = try XCTUnwrap(attributes.destinationURL(for: .openTask))
        XCTAssertEqual(
            AgentActivityDeepLink.parse(url),
            AgentActivityDeepLink.Target(
                runId: "run-123",
                conversationId: "01234567-89ab-cdef-0123-456789abcdef",
                focus: .task
            )
        )
    }

    // 延后起步窗口内，Watch/深链的归属判定仍要认这轮 run；终态后撤销。
    @MainActor
    func testPendingLiveActivityStartOwnsRunUntilEnded() async throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active)
        let controller = AgentLiveActivityController.shared
        let runId = "pending-\(UUID().uuidString)"
        let conversationId = UUID().uuidString

        controller.start(
            runId: runId,
            conversationId: conversationId.lowercased(),
            presentation: .response(stage: .generating)
        )
        XCTAssertTrue(controller.ownsActivity(runId: runId, conversationId: conversationId.uppercased()))
        XCTAssertFalse(controller.ownsActivity(runId: runId, conversationId: UUID().uuidString))

        await controller.end(runId: runId, presentation: .failed())
        XCTAssertFalse(controller.ownsActivity(runId: runId, conversationId: conversationId))
    }

    @MainActor
    func testStopCurrentDiscardsPendingLiveActivityStart() async throws {
        try XCTSkipUnless(UIApplication.shared.applicationState == .active)
        let controller = AgentLiveActivityController.shared
        let runId = "pending-\(UUID().uuidString)"
        let conversationId = UUID().uuidString

        controller.start(runId: runId, conversationId: conversationId, presentation: .response(stage: .generating))
        await controller.stopCurrent()

        XCTAssertFalse(controller.ownsActivity(runId: runId, conversationId: conversationId))
    }
}
