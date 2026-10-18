import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSJevWebMountSelectCandidateTests: IOSJevWebMountLoopTestCase {
    func testObservationWithoutOptionValuesDoesNotOfferSelectActions() {
        var page = observation()
        page.elements = ["combobox", "listbox", "checkbox", "radio"].enumerated().map { index, role in
            IOSJevWebMountLoopService.PageElement(id: "select-\(index)", role: role, label: role)
        }

        let candidates = IOSJevWebMountLoopService.legalActionCandidates(
            input: input(allowed: ["select"]),
            observation: page
        )

        XCTAssertFalse(candidates.contains { $0.kind == .select }, "没有确定 option value 的观察不能提出可执行选择。")
        XCTAssertEqual(candidates.map(\.kind), [.scroll])
    }

    func testSelectWithoutValueDoesNotProduceToolCall() {
        let action = IOSJevWebMountLoopService.PlannedAction(
            kind: .select,
            elementId: "select-ref",
            value: nil,
            snapshotRevision: 4,
            snapshotId: "snapshot-4"
        )

        XCTAssertNil(ChatToolRuntime.webMountLoopActionCall(sessionId: "session-1", action: action))
    }

    func testExplicitSelectValueReachesToolPayloadUnchanged() throws {
        for value in ["option-1", "", "  padded\n"] {
            let action = IOSJevWebMountLoopService.PlannedAction(
                kind: .select,
                elementId: "select-ref",
                value: value,
                snapshotRevision: 4,
                snapshotId: "snapshot-4"
            )
            let call = try XCTUnwrap(ChatToolRuntime.webMountLoopActionCall(sessionId: "session-1", action: action))
            XCTAssertEqual(call.0, "wm_select")
            let data = try XCTUnwrap(call.1.data(using: .utf8))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(payload["target"] as? String, "select-ref")
            XCTAssertEqual(payload["session_id"] as? String, "session-1")
            XCTAssertEqual(payload["snapshot_id"] as? String, "snapshot-4")
            XCTAssertEqual(payload["value"] as? String, value)
        }
    }
}
