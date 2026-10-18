import XCTest
@testable import iosApp

@MainActor
final class IOSWebMountLiteralDesktopInputTests: IOSWebMountDesktopTestCase {
    func testDesktopTypePreservesLeadingTrailingWhitespaceAndNewlines() async throws {
        try await assertTypedPayload("  first line\nsecond line\n  ")
    }

    func testDesktopTypeAcceptsEmptyTextToClearAnExistingField() async throws {
        try await assertTypedPayload("")
    }

    func testDesktopTypeAcceptsASingleLiteralSpace() async throws {
        try await assertTypedPayload(" ")
    }

    func testDesktopTypeValueAliasPreservesItsLiteralPayload() async throws {
        try await assertTypedPayload("\n  draft  \n", argument: "value")
    }

    private func assertTypedPayload(
        _ payload: String,
        argument: String = "text",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let client = DesktopMcpClientFake(tools: desktopTools)
        let adapter = makeAdapter(client)
        let sessionID = "literal-desktop-input"
        try await connect(adapter, sessionId: sessionID)
        defer { adapter.close(logicalSessionId: sessionID) }

        let found = try jsonObject(await adapter.execute(
            toolName: "wm_find",
            arguments: ["text": "Email"],
            logicalSessionId: sessionID
        ))
        let snapshotID = try XCTUnwrap(found["snapshot_id"] as? String)
        let result = try jsonObject(await adapter.execute(
            toolName: "wm_type",
            arguments: ["target": "wm:email", "snapshot_id": snapshotID, argument: payload],
            logicalSessionId: sessionID
        ))

        XCTAssertEqual(result["ok"] as? Bool, true, IOSWebMountController.json(result), file: file, line: line)
        let dispatch = try XCTUnwrap(client.calls.last { $0.name == "browser_type" }, file: file, line: line)
        XCTAssertEqual(dispatch.arguments["ref"] as? String, "wm:email", file: file, line: line)
        XCTAssertEqual(dispatch.arguments["text"] as? String, payload, file: file, line: line)
        XCTAssertNil(dispatch.arguments["submit"], file: file, line: line)
    }
}
