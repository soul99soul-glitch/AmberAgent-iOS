import AmberPhoneControl
import Foundation
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneListCollectionTests: XCTestCase {
    func testAdjacentOverlapCollectsThreeScreensUsingFreshContainerReferences() async {
        let fixture = Fixture([
            page("first", [row("A", id: "a"), row("B", id: "b", y: 160)]),
            page("second", [row("B", id: "b"), row("C", id: "c", y: 160)]),
            page("third", [row("C", id: "c"), row("D", id: "d", y: 160)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 2))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.reason, "swipe_budget_exhausted")
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(result.items.map(\.identifier), ["a", "b", "c", "d"])
        XCTAssertEqual(result.coverage, .observedScreensOnly)
        XCTAssertEqual(result.deduplication, .stableIdentityOnly)
        XCTAssertEqual(result.screenCount, 3)
        XCTAssertEqual(result.swipeCount, 2)
        XCTAssertEqual(result.observation?.observationID, "third")
        XCTAssertFalse(result.reachedItemLimit)
        XCTAssertEqual(fixture.actions, [.swipe(ref: "first:list", direction: .up),
                                         .swipe(ref: "second:list", direction: .up)])
    }

    func testDownSwipesPrependEarlierRowsWithoutReversingReadingOrder() async {
        let fixture = Fixture([
            page("first", [row("C", id: "c"), row("D", id: "d", y: 160)]),
            page("second", [row("B", id: "b"), row("C", id: "c", y: 160)]),
            page("third", [row("A", id: "a"), row("B", id: "b", y: 160)]),
        ])
        let result = await fixture.collect().run(request(direction: .down, maxSwipes: 2))
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(fixture.actions, [.swipe(ref: "first:list", direction: .down),
                                         .swipe(ref: "second:list", direction: .down)])
    }

    func testSameNamedRealRowsRemainSeparateAcrossScreens() async {
        for identifiers in [true, false] {
            let fixture = Fixture([
                page("first", [row("Alice", id: identifiers ? "alice-one" : nil),
                               row("Bob", id: identifiers ? "bob" : nil, y: 160)]),
                page("second", [row("Bob", id: identifiers ? "bob" : nil),
                                row("Alice", id: identifiers ? "alice-two" : nil, y: 160)]),
            ])
            let result = await fixture.collect().run(request(maxSwipes: 1))
            XCTAssertEqual(result.items.map(\.text), identifiers
                ? ["Alice", "Bob", "Alice"] : ["Alice", "Bob", "Bob", "Alice"])
            XCTAssertEqual(result.status, .completed)
        }
    }

    func testAnonymousAdjacentEqualNamesAreRetainedWithoutAssumingTheyAreOneItem() async {
        let fixture = Fixture([
            page("first", [row("A"), row("B", y: 160)]),
            page("second", [row("B"), row("C", y: 160)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 1))
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "B", "C"])
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.coverage, .observedScreensOnly)
        XCTAssertEqual(result.observation?.observationID, "second")
    }

    func testAnonymousRepeatedNamesAreRetainedWithoutClaimingAnIdentityOverlap() async {
        let fixture = Fixture([
            page("first", [row("A"), row("B", y: 160), row("B", y: 220)]),
            page("second", [row("B"), row("B", y: 160), row("C", y: 220)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 1))
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "B", "B", "B", "C"])
        XCTAssertEqual(result.status, .completed)
    }

    func testPartlyIdentifiedOverlapRetainsEveryObservedRow() async {
        let fixture = Fixture([
            page("first", [row("A", id: "a"), row("B", y: 160), row("C", id: "c", y: 220)]),
            page("second", [row("B"), row("C", id: "c", y: 160), row("D", id: "d", y: 220)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 1))
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "C", "B", "C", "D"])
        XCTAssertEqual(result.status, .completed)
    }

    func testReusedIdentifierCannotEstablishAStableSingleRowOverlap() async {
        let fixture = Fixture([
            page("first", [row("A", id: "a"), row("B", id: "reused", y: 160)]),
            page("second", [row("B", id: "reused"), row("C", id: "reused", y: 160)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 3))
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "ambiguous_overlap")
        XCTAssertEqual(result.items.map(\.text), ["A", "B"])
        XCTAssertEqual(result.observation?.observationID, "second")
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testDistinctIdentifiersDisambiguateAdjacentSameNamedRows() async {
        let fixture = Fixture([
            page("first", [row("Same", id: "one"), row("Same", id: "two", y: 160)]),
            page("second", [row("Same", id: "two"), row("Same", id: "three", y: 160)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 1))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.items.map(\.identifier), ["one", "two", "three"])
        XCTAssertEqual(result.items.map(\.text), ["Same", "Same", "Same"])
    }

    func testNonoverlappingScreensAreCollectedWithPartialCoverage() async {
        let fixture = Fixture([
            page("first", [row("A"), row("B", y: 160)]),
            page("second", [row("C"), row("D", y: 160)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 1))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "C", "D"])
        XCTAssertEqual(result.coverage, .observedScreensOnly)
    }

    func testAmbiguousRepeatedOverlapReturnsLatestEvidenceWithoutGuessing() async {
        let fixture = Fixture([
            page("first", [row("A", id: "a"), row("B", id: "b", y: 160), row("B", id: "b", y: 220)]),
            page("second", [row("B", id: "b"), row("B", id: "b", y: 160), row("C", id: "c", y: 220)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 3))
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.reason, "ambiguous_overlap")
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "B"])
        XCTAssertEqual(result.observation?.observationID, "second")
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testOnlyVisibleContainerSubtreeIsCollectedAndRowTextCombinesLabelsAndValues() async {
        let children = [
            row("Alice", id: "alice"),
            node("duplicate", depth: 3, type: "XCUIElementTypeStaticText", label: "Alice", y: 100),
            node("subtitle", depth: 3, type: "XCUIElementTypeStaticText", label: "Engineer", y: 125),
            node("value", depth: 3, type: "XCUIElementTypeStaticText", value: "Online", y: 145),
            row("Below container", y: 740),
            row("Outside subtree", y: 800, depth: 1),
        ]
        let fixture = Fixture([page("only", children, trailing: [
            node("toolbar", depth: 1, type: "XCUIElementTypeButton", label: "Toolbar", y: 750),
        ])])
        let result = await fixture.collect().run(request(maxSwipes: 0))
        XCTAssertEqual(result.items, [.init(text: "Alice\nEngineer\nOnline", identifier: "alice")])
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testDirectScrollViewRowsWithoutCellWrappersAreReadable() async {
        let fixture = Fixture([page("only", [
            node("one", depth: 2, type: "XCUIElementTypeOther", y: 100),
            node("name", depth: 3, type: "XCUIElementTypeStaticText", label: "Alice", y: 105),
            node("two", depth: 2, type: "XCUIElementTypeButton", label: "Bob", y: 170),
        ], containerType: "XCUIElementTypeScrollView")])
        let result = await fixture.collect().run(request(maxSwipes: 0))
        XCTAssertEqual(result.items.map(\.text), ["Alice", "Bob"])
        XCTAssertEqual(result.status, .completed)
    }

    func testEqualTextInDistinctColumnsOfOneRowIsPreserved() async {
        let fixture = Fixture([page("only", [
            row("Alice", id: "alice"),
            node("name", depth: 3, type: "XCUIElementTypeStaticText", label: "Alice", y: 100),
            node("quantity", depth: 3, type: "XCUIElementTypeStaticText", label: "10", y: 120),
            node("price", depth: 3, type: "XCUIElementTypeStaticText", label: "10", y: 140),
        ])])
        let result = await fixture.collect().run(request(maxSwipes: 0))
        XCTAssertEqual(result.items.map(\.text), ["Alice\n10\n10"])
    }

    func testItemLimitReturnsLatestEvidenceAndNeverAddsAnExtraSwipe() async {
        let fixture = Fixture([
            page("first", [row("A", id: "a"), row("B", id: "b", y: 160)]),
            page("second", [row("B", id: "b"), row("C", id: "c", y: 160), row("D", id: "d", y: 220)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 8, maxItems: 3))
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(result.reason, "item_limit_reached")
        XCTAssertTrue(result.reachedItemLimit)
        XCTAssertEqual(result.observation?.observationID, "second")
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testDownItemLimitKeepsNaturalOrderNearestTheStartingScreen() async {
        let fixture = Fixture([
            page("first", [row("D", id: "d"), row("E", id: "e", y: 160)]),
            page("second", [row("A", id: "a"), row("B", id: "b", y: 160),
                            row("C", id: "c", y: 220), row("D", id: "d", y: 280)]),
        ])
        let result = await fixture.collect().run(request(direction: .down, maxSwipes: 2, maxItems: 3))
        XCTAssertEqual(result.items.map(\.text), ["C", "D", "E"])
        XCTAssertTrue(result.reachedItemLimit)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testUnchangedRowsHandBackEvenWhenRefsAndOutsideToolbarChange() async {
        let fixture = Fixture([
            page("before", [row("A"), row("B", y: 160)]),
            page("after", [row("A"), row("B", y: 160)], trailing: [
                node("toolbar", depth: 1, type: "XCUIElementTypeButton", label: "New toolbar", y: 750),
            ]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 8))
        XCTAssertEqual(result.reason, "screen_unchanged")
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.items.map(\.text), ["A", "B"])
        XCTAssertEqual(result.observation?.observationID, "after")
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testTruncatedOrMissingGeometryNeverProducesCollectionOrMutation() async {
        for observation in [page("partial", [row("A")], truncated: true),
                            page("no-bounds", [row("A")], bounds: nil),
                            page("invalid-bounds", [row("A")], bounds: .init(x: 0, y: 0, width: .nan, height: 874))] {
            let fixture = Fixture([observation])
            let result = await fixture.collect().run(request())
            XCTAssertEqual(result.status, .handback)
            XCTAssertTrue(result.items.isEmpty)
            XCTAssertEqual(result.observation?.observationID, observation.observationID)
            XCTAssertTrue(fixture.actions.isEmpty)
        }
    }

    func testAmbiguousContainerDoesNotMixRowsFromTwoLists() async {
        let fixture = Fixture([page("two", [row("A")], trailing: [
            container("two:other"), row("B", y: 160),
        ])])
        let result = await fixture.collect().run(request())
        XCTAssertEqual(result.reason, "ambiguous_container")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testLastBudgetedSwipeStillReadsNewScreenBeforeReturning() async {
        let fixture = Fixture([
            page("before", [row("A", id: "a"), row("B", id: "b", y: 160)]),
            page("after", [row("B", id: "b"), row("C", id: "c", y: 160)]),
        ])
        let result = await fixture.collect().run(request(maxSwipes: 1))
        XCTAssertEqual(result.reason, "swipe_budget_exhausted")
        XCTAssertEqual(result.items.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(result.observation?.observationID, "after")
        XCTAssertEqual(fixture.observeCount, 2)
    }

    func testKnownReceiptUsesSettledObservationWithoutAnotherRead() async {
        let fixture = Fixture([page("before", [row("A")]), page("after", [row("B")])])
        let result = await fixture.collect(settle: true).run(request(maxSwipes: 1))
        XCTAssertEqual(result.items.map(\.text), ["A", "B"])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.settledObserveCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testFreshSnapshotAndSameAppProcessBackendBoundsAreRequiredAcrossScreens() async {
        let scenarios = [
            page("before", [row("B")]),
            page("changed-pid", [row("B")], pid: 99),
            page("changed-app", [row("B")], bundleID: "app.other"),
            page("changed-backend", [row("B")], backend: "other"),
            page("changed-bounds", [row("B")], bounds: .init(x: 0, y: 0, width: 874, height: 402)),
        ]
        for after in scenarios {
            let fixture = Fixture([page("before", [row("A")]), after])
            let result = await fixture.collect().run(request(maxSwipes: 8))
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(result.items.map(\.text), ["A"])
            XCTAssertEqual(fixture.actions.count, 1)
            XCTAssertEqual(fixture.observeCount, 2)
        }
    }

    func testCancellationDuringActivityPreventsSwipe() async {
        let fixture = Fixture([page("before", [row("A")])])
        fixture.onActivity = { phase in if phase == .swiping { withUnsafeCurrentTask { $0?.cancel() } } }
        let task = Task { await fixture.collect().run(self.request()) }
        let result = await task.value
        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.observeCount, 1)
    }

    func testOwnerRevokedAfterReceiptPreventsReadAndReplay() async {
        let fixture = Fixture([page("before", [row("A")])])
        fixture.onAct = { fixture.current = false }
        let result = await fixture.collect().run(request())
        XCTAssertEqual(result.reason, "task_stopped")
        XCTAssertEqual(result.swipeCount, 1)
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testUnknownReceiptKeepsTypedProblemAndNeverReadsOrReplays() async {
        let problem = PhoneControlProblem(.transport, "receipt lost after dispatch")
        let fixture = Fixture([page("before", [row("A")])])
        fixture.receipts = [.unknown(problem)]
        let result = await fixture.collect().run(request())
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.unknownProblem, problem)
        XCTAssertEqual(result.swipeCount, 1)
        XCTAssertNil(result.observation)
        XCTAssertEqual(result.items.map(\.text), ["A"])
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testUnsentReceiptDoesNotConsumeSwipeBudgetOrContinueReading() async {
        let fixture = Fixture([page("before", [row("A")])])
        fixture.receipts = [.unsent(.init(.staleObservation, "snapshot expired"))]
        let result = await fixture.collect().run(request())
        XCTAssertEqual(result.status, .handback)
        XCTAssertEqual(result.swipeCount, 0)
        XCTAssertNil(result.observation)
        XCTAssertEqual(fixture.observeCount, 1)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testSixtySecondBudgetExhaustedDuringActivityPreventsSwipe() async {
        let fixture = Fixture([page("before", [row("A")])])
        fixture.onActivity = { phase in if phase == .swiping { fixture.time += 60 } }
        let result = await fixture.collect().run(request())
        XCTAssertEqual(result.reason, "time_budget_exhausted")
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testRequestDefaultsAndInvalidLimitsAreCheckedBeforeReading() async throws {
        let decoded = try JSONDecoder().decode(IOSPhoneListCollectionRequest.self, from: Data(
            #"{"container":{"identifier":"contacts"},"direction":"up"}"#.utf8))
        XCTAssertEqual(decoded.maxItems, 50)
        XCTAssertEqual(decoded.maxSwipes, 3)
        try decoded.validate()
        for invalid in [request(maxSwipes: -1), request(maxSwipes: 9), request(maxItems: 0),
                        request(maxItems: 201), request(direction: .left),
                        IOSPhoneListCollectionRequest(container: .init(type: "XCUIElementTypeTable"), direction: .up)] {
            let fixture = Fixture([])
            let result = await fixture.collect().run(invalid)
            XCTAssertEqual(result.status, .handback)
            XCTAssertEqual(fixture.observeCount, 0)
        }
    }

    private func request(direction: IOSPhoneGoalActionSpec.Direction = .up,
                         maxSwipes: Int = 3, maxItems: Int = 50) -> IOSPhoneListCollectionRequest {
        .init(container: .init(identifier: "contacts"), direction: direction,
              maxSwipes: maxSwipes, maxItems: maxItems)
    }

    private func page(_ id: String, _ rows: [PhoneObservationNode], trailing: [PhoneObservationNode] = [],
                      containerType: String = "XCUIElementTypeTable", pid: Int = 42,
                      bundleID: String = "app.test", backend: String = "test", truncated: Bool = false,
                      bounds: PhoneElementRect? = .init(x: 0, y: 0, width: 402, height: 874)) -> PhoneObservation {
        var rows = rows
        for index in rows.indices {
            let old = rows[index]
            rows[index] = .init(ref: "\(id):\(index)", depth: old.depth, type: old.type, identifier: old.identifier,
                                label: old.label, value: old.value, rect: old.rect,
                                enabled: old.enabled, focused: old.focused)
        }
        return .init(observationID: id, bundleID: bundleID, processID: pid, backend: backend,
                     truncated: truncated, nodes: [container("\(id):list", type: containerType)] + rows + trailing,
                     screenBounds: bounds)
    }

    private func container(_ ref: String, type: String = "XCUIElementTypeTable") -> PhoneObservationNode {
        .init(ref: ref, depth: 1, type: type, identifier: "contacts", label: nil, value: nil,
              rect: .init(x: 0, y: 20, width: 402, height: 700), enabled: true, focused: false)
    }

    private func row(_ label: String, id: String? = nil, y: Double = 100, depth: Int = 2) -> PhoneObservationNode {
        .init(ref: label, depth: depth, type: "XCUIElementTypeCell", identifier: id, label: label, value: nil,
              rect: .init(x: 20, y: y, width: 300, height: 50), enabled: true, focused: false)
    }

    private func node(_ ref: String, depth: Int, type: String, label: String? = nil,
                      value: String? = nil, y: Double) -> PhoneObservationNode {
        .init(ref: ref, depth: depth, type: type, identifier: nil, label: label, value: value,
              rect: .init(x: 20, y: y, width: 300, height: 25), enabled: true, focused: false)
    }

    @MainActor
    private final class Fixture {
        var observations: [PhoneObservation]
        var actions: [PhoneAction] = []
        var receipts: [PhoneActionResult] = []
        var observeCount = 0
        var settledObserveCount = 0
        var current = true
        var time: TimeInterval = 0
        var onActivity: ((AgentPhoneControlActivityPhase) -> Void)?
        var onAct: (() -> Void)?

        init(_ observations: [PhoneObservation]) { self.observations = observations }

        func read() throws -> PhoneObservation {
            guard !observations.isEmpty else { throw NSError(domain: "Unexpected observation", code: 1) }
            return observations.removeFirst()
        }

        func collect(settle: Bool = false) -> IOSPhoneListCollection {
            let settled: (() async throws -> PhoneObservation)? = settle ? {
                self.settledObserveCount += 1
                return try self.read()
            } : nil
            return .init(deps: .init(observe: {
                self.observeCount += 1
                return try self.read()
            }, act: { action in
                self.actions.append(action)
                self.onAct?()
                return self.receipts.isEmpty ? .completed : self.receipts.removeFirst()
            }, isCurrent: { self.current }, reportActivity: { self.onActivity?($0) },
               observeAfterAction: settled, now: { Date(timeIntervalSince1970: self.time) }))
        }
    }
}
