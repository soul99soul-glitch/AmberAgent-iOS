import Foundation
import XCTest
@testable import AmberMac

final class RuntimeCanonicalEnvelopeTests: XCTestCase {
    func testActualKMPSerializerEnvelopeRetainsOpaqueDocumentsAcrossSwiftCodable() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.messages.count, 2)
        XCTAssertEqual(fixture.messages.last?.unsupportedPartCount, 3)
        let canonical = try XCTUnwrap(fixture.canonicalJSON)
        let restored = try DesktopJSON.decode(DesktopConversation.self, from: DesktopJSON.encode(fixture))
        XCTAssertEqual(restored, fixture)
        XCTAssertEqual(restored.canonicalJSON, canonical)
        XCTAssertEqual(restored.messages.map(\.canonicalJSON), fixture.messages.map(\.canonicalJSON))
    }

    func testActualKMPFixtureCarriesVariantsPartsModelUsageAndAnnotations() throws {
        let fixture = try loadFixture()
        let canonical = try XCTUnwrap(fixture.canonicalJSON)
        // Inspect the fixture only; product Swift keeps these fields opaque.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
        let nodes = try XCTUnwrap(root["messageNodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[1]["selectIndex"] as? Int, 1)
        let variants = try XCTUnwrap(nodes[1]["messages"] as? [[String: Any]])
        XCTAssertEqual(variants.count, 2)
        for variant in variants {
            let parts = try XCTUnwrap(variant["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 6)
            XCTAssertNotNil(variant["modelId"] as? String)
            XCTAssertNotNil(variant["usage"] as? [String: Any])
            XCTAssertFalse((variant["annotations"] as? [Any])?.isEmpty ?? true)
        }
        XCTAssertEqual(fixture.messages.last?.id.uuidString.lowercased(), variants[1]["id"] as? String)
    }

    private func loadFixture() throws -> DesktopConversation {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: RuntimeCanonicalEnvelopeTests.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "CanonicalEnvelope", withExtension: "json"))
        return try DesktopJSON.decode(DesktopConversation.self, from: String(contentsOf: url, encoding: .utf8))
    }
}
