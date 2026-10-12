import AmberPhoneControl
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneActionVerificationTests: XCTestCase {
    private let expected = IOSPhoneGoalExpectation(kind: .valueEquals, target: .init(identifier: "query"), value: "")

    func testWaitsForClearEffectAndReturnsNewestReference() async throws {
        var reads = 0
        var waits = 0
        let result = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
            expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                observe: {
                    reads += 1
                    return self.observation(reads < 3 ? "old" : "", id: "after-\(reads)")
                }, isCurrent: { true }, reportWaiting: {}, now: { 0 }, wait: { waits += 1 }))
        XCTAssertEqual(result.verification.status, .satisfied)
        XCTAssertEqual(result.observation.observationID, "after-3")
        XCTAssertEqual(result.observations, 3)
        XCTAssertEqual(waits, 2)
    }

    func testImmediatelySatisfiedEffectDoesNotWait() async throws {
        var waits = 0
        let result = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
            expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                observe: { self.observation("") }, isCurrent: { true }, reportWaiting: {},
                wait: { waits += 1 }))
        XCTAssertEqual(result.verification.status, .satisfied)
        XCTAssertEqual(result.observations, 1)
        XCTAssertEqual(waits, 0)
    }

    func testUnmetEffectHasBoundedReadsAndKeepsOriginalBeforeEvidence() async throws {
        var reads = 0
        let result = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
            expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                observe: { reads += 1; return self.observation("old", id: "after-\(reads)") },
                isCurrent: { true }, reportWaiting: {}, now: { 0 }, wait: {}))
        XCTAssertEqual(result.verification.status, .unmet)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(result.observations, 4)
    }

    func testIncompleteEvidenceDoesNotPoll() async throws {
        var reads = 0
        let result = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
            expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                observe: { reads += 1; return self.observation("old", truncated: true) },
                isCurrent: { true }, reportWaiting: {}, wait: { XCTFail("Incomplete trees require handback") }))
        XCTAssertEqual(result.verification.reason, "truncated_tree")
        XCTAssertEqual(reads, 1)
    }

    func testOwnershipLossDuringWaitingDoesNotReadOrActAgain() async throws {
        var active = true
        var reads = 0
        do {
            _ = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
                expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                    observe: { reads += 1; return self.observation("old") }, isCurrent: { active },
                    reportWaiting: {}, wait: { active = false }))
            XCTFail("Must stop after ownership is lost")
        } catch is CancellationError { } catch { XCTFail("\(error)") }
        XCTAssertEqual(reads, 1)
    }

    func testLaunchPollingDoesNotAcceptReplacementProcess() async throws {
        var reads = 0
        let result = try await IOSPhoneActionVerification.check(action: .launch(bundleID: "app.test"),
            expectation: expected, before: nil, dependencies: .init(
                observe: {
                    reads += 1
                    return self.observation(reads == 1 ? "old" : "", id: "after-\(reads)", pid: reads == 1 ? 42 : 43)
                }, isCurrent: { true }, reportWaiting: {}, now: { 0 }, wait: {}))
        XCTAssertEqual(result.verification.status, .insufficient)
        XCTAssertEqual(result.verification.reason, "foreground_app_changed")
        XCTAssertEqual(reads, 2)
    }

    func testSlowInitialObservationUsesUpContinuationBudget() async throws {
        var time: TimeInterval = 0
        let result = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
            expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                observe: { time = 3; return self.observation("old") }, isCurrent: { true },
                reportWaiting: {}, now: { time }, wait: { XCTFail("Budget is exhausted") }))
        XCTAssertEqual(result.observations, 1)
        XCTAssertEqual(result.verification.status, .unmet)
    }

    func testBudgetExpiringDuringWaitDoesNotStartAnotherObservation() async throws {
        var time: TimeInterval = 0
        var reads = 0
        let result = try await IOSPhoneActionVerification.check(action: .clear(ref: "before:1"),
            expectation: expected, before: observation("old", id: "before"), dependencies: .init(
                observe: { reads += 1; time = 1.9; return self.observation("old") },
                isCurrent: { true }, reportWaiting: {}, now: { time }, wait: { time += 0.3 }))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.observations, 1)
        XCTAssertEqual(result.verification.status, .unmet)
    }

    private func observation(_ value: String, id: String = "after", pid: Int = 42,
                             truncated: Bool = false) -> PhoneObservation {
        .init(observationID: id, bundleID: "app.test", processID: pid, backend: "test", truncated: truncated,
              nodes: [.init(ref: "\(id):1", depth: 1, type: "XCUIElementTypeSearchField", identifier: "query",
                            label: "搜索", value: value, rect: .init(x: 0, y: 80, width: 300, height: 44),
                            enabled: true, focused: true)], screenBounds: .init(x: 0, y: 0, width: 402, height: 874))
    }
}
