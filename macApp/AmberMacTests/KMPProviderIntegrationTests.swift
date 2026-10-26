import Foundation
import XCTest
@testable import AmberMac

@MainActor
final class KMPProviderIntegrationTests: XCTestCase {
    private let fixtureKey = "amber-mac-integration-only"

    func testEmptyInputIsRejectedBeforeEnteringKotlinAccumulator() throws {
        let configuration = DesktopProviderConfiguration(name: "Unused", kind: .openAI,
            baseURL: "https://example.com/v1", modelID: "unused")
        XCTAssertThrowsError(try DesktopKMPProvider().start(configuration: configuration, apiKey: "unused",
            messages: [], responseID: UUID()))
    }

    private func configuration(kind: DesktopProviderKind, model: String = "mock-success") throws -> DesktopProviderConfiguration {
        guard let base = ProcessInfo.processInfo.environment["AMBER_MAC_PROVIDER_TEST_URL"],
              base.hasPrefix("http://127.0.0.1:"), !base.contains("$(") else {
            throw XCTSkip("Run macApp/scripts/test-provider.sh to start the local provider fixture.")
        }
        return DesktopProviderConfiguration(name: "Local protocol fixture", kind: kind,
            baseURL: base + "/v1", modelID: model)
    }

    func testOpenAIStreamsOrderedSnapshotsThroughRealKMP() async throws {
        let provider = DesktopKMPProvider()
        let responseID = UUID()
        let run = try provider.start(configuration: configuration(kind: .openAI), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
        let events = try await collect(run)
        let snapshots = snapshots(events)
        XCTAssertEqual(snapshots.last?.text, "你好，Amber")
        XCTAssertEqual(snapshots.last?.reasoning, "先确认顺序。")
        assertOrderedPrefixes(snapshots.map(\.text))
        XCTAssertTrue(events.contains { if case .complete = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
        try assertCanonicalSnapshots(events, responseID: responseID)
    }

    func testClaudeStreamsOrderedSnapshotsThroughRealKMP() async throws {
        let provider = DesktopKMPProvider()
        let responseID = UUID()
        let run = try provider.start(configuration: configuration(kind: .claude), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: responseID)
        let events = try await collect(run)
        let values = snapshots(events)
        XCTAssertEqual(values.last?.text, "你好，Amber")
        assertOrderedPrefixes(values.map(\.text))
        XCTAssertTrue(events.contains { if case .complete = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .failed = $0 { true } else { false } })
        try assertCanonicalSnapshots(events, responseID: responseID)
    }

    func testHTTPFailureDoesNotExposeEchoedCredential() async throws {
        let provider = DesktopKMPProvider()
        let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-error"), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: UUID())
        let events = try await collect(run)
        let failures = events.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(failures.joined().contains(fixtureKey))
        XCTAssertFalse(failures.joined().contains("Authorization"))
        XCTAssertFalse(events.contains { if case .complete = $0 { true } else { false } })
    }

    func testCancellationPreservesAcceptedPartialAndRejectsLateChunks() async throws {
        let provider = DesktopKMPProvider()
        let run = try provider.start(configuration: configuration(kind: .openAI, model: "mock-cancel"), apiKey: fixtureKey,
            messages: [DesktopMessage(role: .user, text: "Say hello")], responseID: UUID())
        let events = try await collect(run, cancelAfterPartial: true)
        XCTAssertEqual(snapshots(events).last?.text, "partial")
        XCTAssertTrue(events.contains { if case .cancelled = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .complete = $0 { true } else { false } })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(run.drain().isEmpty)
    }

    private func collect(_ run: DesktopGeneration, cancelAfterPartial: Bool = false) async throws -> [DesktopProviderEvent] {
        var events: [DesktopProviderEvent] = []
        var finished = false
        let consumer = Task { @MainActor in
            for await _ in run.signals {
                events.append(contentsOf: run.drain())
                if cancelAfterPartial, snapshots(events).contains(where: { $0.text == "partial" }) {
                    run.cancel()
                }
            }
            events.append(contentsOf: run.drain())
            finished = true
        }
        defer { consumer.cancel(); run.cancel() }
        for _ in 0..<400 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(finished, "The KMP provider did not publish a terminal event within eight seconds.")
        return events
    }

    private func snapshots(_ events: [DesktopProviderEvent]) -> [(text: String, reasoning: String)] {
        events.compactMap { event in
            if case .snapshot(let text, let reasoning, _, _) = event { return (text, reasoning) }
            return nil
        }
    }

    private func assertCanonicalSnapshots(_ events: [DesktopProviderEvent], responseID: UUID) throws {
        var count = 0
        for event in events {
            guard case .snapshot(_, _, let payload, _) = event else { continue }
            let json = try XCTUnwrap(payload)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(root["id"] as? String, responseID.uuidString.lowercased())
            XCTAssertNotNil(root["parts"] as? [Any])
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
    }

    private func assertOrderedPrefixes(_ values: [String], file: StaticString = #filePath, line: UInt = #line) {
        for (before, after) in zip(values, values.dropFirst()) {
            XCTAssertTrue(after.hasPrefix(before), "A snapshot arrived out of order.", file: file, line: line)
        }
    }
}
