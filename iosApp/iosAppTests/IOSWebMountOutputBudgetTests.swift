import XCTest
import Shared
@testable import iosApp

@MainActor
final class IOSWebMountOutputBudgetTests: XCTestCase {
    func testWebMountCapPreservesMachineFieldsAndReportsDroppedEvidence() throws {
        let sessionID = "session-1234567890"
        let snapshotID = "document-1234567890:revision-42"
        let currentURL = "https://bbs.example.com/search/results/PS5"
        let interactive = (0..<12).map { index in
            [
                "ref": snapshotID + ":element-" + String(index),
                "selector": "[data-result='\(index)']",
                "name": String(repeating: "Search result description ", count: 8)
            ] as [String: Any]
        }
        let visual = (0..<20).map { index in
            ["ref": "visual-" + String(index), "text": String(repeating: "decorative candidate ", count: 8)] as [String: Any]
        }
        let links = (0..<20).map { index in
            [
                "ref": "link-" + String(index),
                "url": "https://bbs.example.com/thread/\(index)",
                "title": String(repeating: "related result title ", count: 6)
            ] as [String: Any]
        }
        let rawObject: [String: Any] = [
            "ok": true,
            "tool": "wm_observe",
            "session_id": sessionID,
            "snapshot_id": snapshotID,
            "current_url": currentURL,
            "title": String(repeating: "Search results for PS5 ", count: 20),
            "visible_text": String(repeating: "Found matching forum result. ", count: 100),
            "interactive_elements": interactive,
            "visual_candidates": visual,
            "links": links,
            "redacted": true
        ]
        let raw = String(data: try JSONSerialization.data(withJSONObject: rawObject), encoding: .utf8)!
        let maxChars = 5_500
        let parts = ChatToolOutputFormatter.cappedToolOutputParts(
            [UIMessagePart.Text(text: raw, metadata: nil)],
            maxChars: maxChars
        )
        let text = try XCTUnwrap((parts.first as? UIMessagePart.Text)?.text)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        XCTAssertLessThanOrEqual(text.count, maxChars)
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(payload["redacted"] as? Bool, true)
        XCTAssertEqual(payload["session_id"] as? String, sessionID)
        XCTAssertEqual(payload["snapshot_id"] as? String, snapshotID)
        XCTAssertEqual(payload["current_url"] as? String, currentURL)
        XCTAssertGreaterThanOrEqual((payload["title"] as? String)?.count ?? 0, 160)
        XCTAssertGreaterThanOrEqual((payload["visible_text"] as? String)?.count ?? 0, 512)

        let returnedInteractive = try XCTUnwrap(payload["interactive_elements"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(returnedInteractive.count, 6)
        for node in returnedInteractive {
            let ref = try XCTUnwrap(node["ref"] as? String)
            XCTAssertTrue(interactive.contains { $0["ref"] as? String == ref })
        }
        let returnedLinks = try XCTUnwrap(payload["links"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(returnedLinks.count, 3)

        let truncation = try XCTUnwrap(payload["truncation"] as? [String: Any])
        XCTAssertFalse((truncation["read_more"] as? String ?? "").isEmpty)
        let fields = try XCTUnwrap(truncation["fields"] as? [String: Any])
        let visualMetadata = try XCTUnwrap(fields["visual_candidates"] as? [String: Any])
        XCTAssertEqual(visualMetadata["original_count"] as? Int, visual.count)
        XCTAssertLessThan(visualMetadata["returned_count"] as? Int ?? visual.count, visual.count)
        let linkMetadata = try XCTUnwrap(fields["links"] as? [String: Any])
        XCTAssertEqual(linkMetadata["original_count"] as? Int, links.count)
        let visibleMetadata = try XCTUnwrap(fields["visible_text"] as? [String: Any])
        XCTAssertEqual(visibleMetadata["original_chars"] as? Int, 2_900)
        XCTAssertLessThan(visibleMetadata["returned_chars"] as? Int ?? 2_900, 2_900)
        let titleMetadata = try XCTUnwrap(fields["title"] as? [String: Any])
        XCTAssertEqual(titleMetadata["original_chars"] as? Int, 460)
    }

    func testNestedWebMountSignatureIsCappedWithoutToolField() throws {
        let rawObject: [String: Any] = [
            "ok": true,
            "session_id": "session-nested",
            "snapshot_id": "snapshot-nested",
            "current_url": "https://example.com/after-navigation",
            "result": [
                "links": (0..<12).map { ["ref": "link-\($0)", "url": "https://example.com/\($0)"] },
                "interactive_elements": (0..<4).map { ["ref": "target-\($0)", "name": String(repeating: "target ", count: 80)] }
            ]
        ]
        let raw = String(data: try JSONSerialization.data(withJSONObject: rawObject), encoding: .utf8)!
        let parts = ChatToolOutputFormatter.cappedToolOutputParts(
            [UIMessagePart.Text(text: raw, metadata: nil)],
            maxChars: 900
        )
        let text = try XCTUnwrap((parts.first as? UIMessagePart.Text)?.text)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["current_url"] as? String, rawObject["current_url"] as? String)
        let truncation = try XCTUnwrap(payload["truncation"] as? [String: Any])
        let fields = try XCTUnwrap(truncation["fields"] as? [String: Any])
        XCTAssertNotNil(fields["result.links"])
    }

    func testSearchPayloadWithLinksKeepsGenericCapPath() throws {
        let raw = String(data: try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "tool": "search_web",
            "links": ["https://example.com"],
            "text": String(repeating: "search result ", count: 2_000)
        ]), encoding: .utf8)!
        let parts = ChatToolOutputFormatter.cappedToolOutputParts(
            [UIMessagePart.Text(text: raw, metadata: nil)],
            maxChars: 700
        )
        let text = try XCTUnwrap((parts.first as? UIMessagePart.Text)?.text)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertNil(payload["truncation"])
    }
}
