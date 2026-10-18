import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import AmberPhoneControl

extension PhoneRunnerClientTests {
    func testScreenshotRejectsRotationAfterBoundedTreeWithoutRelabelingOldNodes() async throws {
        var replies = Fixture.observation
        replies.insert(Fixture.screen, at: 2)
        let fixture = Fixture(replies + [Fixture.active, Fixture.landscapeScreen])
        let client = try makeClient(fixture)
        let observation = try await client.observe(includeScreenSize: true)
        do { _ = try await client.screenshotObservation(); XCTFail("Expected stale tree after rotation") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .staleObservation) }
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/screenshot" })
        let count = fixture.requests.count
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, count)
    }

    func testVisualTapUsesFullScreenPointsForUntargetablePopupAndConsumesEvidence() async throws {
        let fixture = Fixture(Fixture.popupObservation + Fixture.screenshot + Fixture.pointPreflight + [
            .json("POST", "/tap", #"{"value":null}"#),
        ] + Fixture.observation)
        let client = try makeClient(fixture)
        let observed = try await client.observe()
        XCTAssertEqual(observed.nodes.map(\.type), ["XCUIElementTypeApplication", "XCUIElementTypeWindow",
                                                     "XCUIElementTypeOther", "XCUIElementTypeOther"])
        XCTAssertEqual(observed.nodes[0].rect.height, 139)
        let screenshot = try await client.screenshotObservation()
        XCTAssertEqual(screenshot.observationID, observed.observationID)
        XCTAssertEqual(screenshot.width, 402)
        XCTAssertEqual(screenshot.height, 874)
        XCTAssertEqual(screenshot.data, Fixture.png)
        let result = await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.75))
        XCTAssertEqual(result, .completed)
        let request = try XCTUnwrap(fixture.requests.first { $0.path == "/tap" })
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
        XCTAssertEqual(body["x"]?.number, 201)
        XCTAssertEqual(body["y"]?.number, 655.5)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/elements" })
        assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.75)),
                     kind: .staleObservation)
        let verified = try await client.observe()
        XCTAssertNotEqual(verified.observationID, observed.observationID)
        XCTAssertEqual(verified.nodes.last?.identifier, "submit-button")
        XCTAssertEqual(fixture.requests.filter { $0.path == "/tap" }.count, 1)
    }

    func testVisualSwipeUsesFullScreenPointsAndConsumesScreenshotEvidence() async throws {
        let fixture = Fixture(Fixture.popupObservation + Fixture.screenshot + Fixture.pointPreflight + [
            .json("POST", "/swipe", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let result = await client.act(.swipePoint(observationID: screenshot.observationID,
                                                  startX: 0.75, startY: 0.1, endX: 0.25, endY: 0.1))
        XCTAssertEqual(result, .completed)
        let request = try XCTUnwrap(fixture.requests.first { $0.path == "/swipe" })
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
        XCTAssertEqual(body["x1"]?.number, 301.5)
        XCTAssertEqual(body["x2"]?.number, 100.5)
        XCTAssertEqual(try XCTUnwrap(body["y1"]?.number), 87.4, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(body["y2"]?.number), 87.4, accuracy: 0.000001)
        XCTAssertEqual(body["duration_ms"]?.number, 300)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/elements" })
        let before = fixture.requests.count
        assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.1)),
                     kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, before)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/swipe" }.count, 1)
    }

    func testVisualSwipeRejectsMissingOrStaleScreenshotWithoutSending() async throws {
        for mode in ["missing", "wrongID", "newObservation"] {
            let fixture = Fixture(Fixture.observation + (mode == "missing" ? [] : Fixture.screenshot)
                                  + (mode == "newObservation" ? Fixture.observation : []))
            let client = try makeClient(fixture)
            let observed = try await client.observe()
            if mode != "missing" { _ = try await client.screenshotObservation() }
            if mode == "newObservation" { _ = try await client.observe() }
            let before = fixture.requests.count
            assertUnsent(await client.act(.swipePoint(observationID: mode == "wrongID" ? "wrong" : observed.observationID,
                                                      startX: 0.75, startY: 0.1, endX: 0.25, endY: 0.1)),
                         kind: .staleObservation)
            XCTAssertEqual(fixture.requests.count, before)
        }
    }

    func testVisualSwipeRejectsInvalidOrIdenticalEndpointsWithoutSending() async throws {
        for point in [(Double.nan, 0.1, 0.25, 0.1), (0.75, Double.infinity, 0.25, 0.1),
                      (0.75, 0.1, -0.01, 0.1), (0.75, 0.1, 0.25, 1.0),
                      (1.0, 0.1, 0.25, 0.1), (0.75, -0.01, 0.25, 0.1),
                      (0.75, 0.1, Double.infinity, 0.1), (0.75, 0.1, 0.25, Double.nan),
                      (0.75, 0.1, 0.75, 0.1)] {
            let fixture = Fixture(Fixture.observation + Fixture.screenshot)
            let client = try makeClient(fixture)
            _ = try await client.observe()
            let screenshot = try await client.screenshotObservation()
            let before = fixture.requests.count
            assertUnsent(await client.act(.swipePoint(observationID: screenshot.observationID,
                                                      startX: point.0, startY: point.1, endX: point.2, endY: point.3)),
                         kind: .invalidAction)
            XCTAssertEqual(fixture.requests.count, before)
        }
    }

    func testVisualSwipeRejectsForegroundChangeBeforeAndAfterGeometryCheck() async throws {
        for foreground in [#"{"value":{"bundleId":"other.app","pid":42}}"#,
                           #"{"value":{"bundleId":"app.test","pid":43}}"#] {
            for changesAfterGeometry in [false, true] {
                let fixture = Fixture(Fixture.observation + Fixture.screenshot
                                      + (changesAfterGeometry ? [Fixture.active, Fixture.screen] : []) + [
                    .json("GET", "/wda/activeAppInfo", foreground),
                ])
                let client = try makeClient(fixture)
                _ = try await client.observe()
                let screenshot = try await client.screenshotObservation()
                assertUnsent(await client.act(.swipePoint(observationID: screenshot.observationID,
                                                          startX: 0.75, startY: 0.1, endX: 0.25, endY: 0.1)),
                             kind: .appChanged)
                XCTAssertFalse(fixture.requests.contains { $0.path == "/swipe" })
            }
        }
    }

    func testVisualSwipeRejectsRotationBeforeSending() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + [Fixture.active, Fixture.landscapeScreen])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        assertUnsent(await client.act(.swipePoint(observationID: screenshot.observationID,
                                                  startX: 0.75, startY: 0.1, endX: 0.25, endY: 0.1)),
                     kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/swipe" })
    }

    func testVisualSwipeResponseLossBlocksReplayEvenAfterFreshScreenshot() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + Fixture.pointPreflight + [
            .failure("POST", "/swipe", .networkConnectionLost),
        ] + Fixture.observation + Fixture.screenshot)
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let action = PhoneAction.swipePoint(observationID: screenshot.observationID,
                                            startX: 0.75, startY: 0.1, endX: 0.25, endY: 0.1)
        guard case .unknown(let problem) = await client.act(action) else {
            return XCTFail("A lost swipe response must leave its outcome unknown.")
        }
        XCTAssertEqual(problem.kind, .transport)
        assertUnsent(await client.act(action), kind: .previousOutcomeUnknown)
        _ = try await client.observe()
        let fresh = try await client.screenshotObservation()
        let before = fixture.requests.count
        assertUnsent(await client.act(.swipePoint(observationID: fresh.observationID,
                                                  startX: 0.75, startY: 0.1, endX: 0.25, endY: 0.1)),
                     kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, before)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/swipe" }.count, 1)
    }

    func testVisualTapRequiresScreenshotOfLatestObservation() async throws {
        let fixture = Fixture(Fixture.observation)
        let client = try makeClient(fixture)
        let observed = try await client.observe()
        assertUnsent(await client.act(.tapPoint(observationID: observed.observationID, x: 0.5, y: 0.5)),
                     kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 3)

        let noObservation = try makeClient(Fixture([]))
        do { _ = try await noObservation.screenshotObservation(); XCTFail("Expected an observation first") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .staleObservation) }
    }

    func testVisualTapRejectsStaleScreenshotIDAndNewObservationInvalidatesEvidence() async throws {
        for newObservation in [false, true] {
            let fixture = Fixture(Fixture.observation + Fixture.screenshot + (newObservation ? Fixture.observation : []))
            let client = try makeClient(fixture)
            _ = try await client.observe()
            let screenshot = try await client.screenshotObservation()
            if newObservation { _ = try await client.observe() }
            let before = fixture.requests.count
            assertUnsent(await client.act(.tapPoint(observationID: newObservation ? screenshot.observationID : "wrong-id",
                                                    x: 0.5, y: 0.5)), kind: .staleObservation)
            XCTAssertEqual(fixture.requests.count, before)
        }
    }

    func testVisualTapRejectsNonFiniteAndOutOfRangeCoordinatesWithoutSending() async throws {
        for point in [(Double.nan, 0.5), (0.5, Double.infinity), (-0.001, 0.5), (0.5, -0.001),
                      (1.0, 0.5), (0.5, 1.0), (1.1, 0.5)] {
            let fixture = Fixture(Fixture.observation + Fixture.screenshot)
            let client = try makeClient(fixture)
            _ = try await client.observe()
            let screenshot = try await client.screenshotObservation()
            let before = fixture.requests.count
            assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: point.0, y: point.1)),
                         kind: .invalidAction)
            XCTAssertEqual(fixture.requests.count, before)
        }
    }

    func testVisualTapAcceptsScreenOriginAndInteriorFarEdge() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + Fixture.pointPreflight + [
            .json("POST", "/tap", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let result = await client.act(.tapPoint(observationID: screenshot.observationID, x: 0, y: 0.999))
        XCTAssertEqual(result, .completed)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(fixture.requests.last).body)
        XCTAssertEqual(body["x"]?.number, 0)
        XCTAssertEqual(try XCTUnwrap(body["y"]?.number), 873.126, accuracy: 0.000001)
    }

    func testVisualTapRejectsChangedForegroundBundleOrProcessBeforeSending() async throws {
        for foreground in [#"{"value":{"bundleId":"other.app","pid":42}}"#,
                           #"{"value":{"bundleId":"app.test","pid":43}}"#] {
            let fixture = Fixture(Fixture.observation + Fixture.screenshot + [
                .json("GET", "/wda/activeAppInfo", foreground),
            ])
            let client = try makeClient(fixture)
            _ = try await client.observe()
            let screenshot = try await client.screenshotObservation()
            assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5)),
                         kind: .appChanged)
            XCTAssertFalse(fixture.requests.contains { $0.path == "/tap" })
        }
    }

    func testVisualTapRejectsRotatedScreenBeforeSending() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + [Fixture.active, Fixture.landscapeScreen])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5)),
                     kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/tap" })
    }

    func testScreenshotRejectsForegroundOrOrientationChangeAndInvalidatesTargets() async throws {
        for changesApp in [false, true] {
            let replies = [Fixture.active, Fixture.screen, Fixture.image,
                           changesApp ? Fixture.screen : Fixture.landscapeScreen,
                           changesApp ? .json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"other.app","pid":7}}"#)
                                      : Fixture.active]
            let fixture = Fixture(Fixture.observation + replies)
            let client = try makeClient(fixture)
            let observed = try await client.observe()
            do { _ = try await client.screenshotObservation(); XCTFail("Expected changing screenshot to be rejected") }
            catch let problem as PhoneControlProblem {
                XCTAssertEqual(problem.kind, changesApp ? .appChanged : .staleObservation)
            }
            assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observed.nodes[1].ref))), kind: .staleObservation)
            XCTAssertFalse(fixture.requests.contains { $0.path == "/tap" })
        }
    }

    func testScreenshotRequiresPixelGeometryToMatchScreenPoints() async throws {
        let rotatedPNG = Fixture.makePNG(width: 2622, height: 1206)
        let fixture = Fixture(Fixture.observation + [Fixture.active, Fixture.screen,
            .json("GET", "/screenshot", "{\"value\":\"\(rotatedPNG.base64EncodedString())\"}"),
            Fixture.screen, Fixture.active,
        ])
        let client = try makeClient(fixture)
        let observed = try await client.observe()
        do { _ = try await client.screenshotObservation(); XCTFail("Expected inconsistent screenshot geometry") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .malformedResponse) }
        assertUnsent(await client.act(.tapPoint(observationID: observed.observationID, x: 0.5, y: 0.5)),
                     kind: .staleObservation)
    }

    func testAnotherActionConsumesVisualTapEvidence() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + [
            .json("POST", "/wda/apps/activate", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let result = await client.act(.launch(bundleID: "app.test"))
        XCTAssertEqual(result, .completed)
        assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5)),
                     kind: .staleObservation)
    }

    func testFailedReplacementScreenshotInvalidatesPreviousVisualEvidence() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + [Fixture.active, Fixture.screen,
            .failure("GET", "/screenshot", .networkConnectionLost),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        do { _ = try await client.screenshotObservation(); XCTFail("Expected replacement screenshot failure") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        assertUnsent(await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5)),
                     kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/tap" })
    }

    func testVisualTapResponseLossBlocksReplayEvenAfterFreshObservation() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + Fixture.pointPreflight + [
            .failure("POST", "/tap", .networkConnectionLost),
        ] + Fixture.observation + Fixture.screenshot)
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        guard case .unknown = await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5)) else {
            return XCTFail("Lost tap receipt must preserve uncertainty")
        }
        _ = try await client.observe()
        let freshScreenshot = try await client.screenshotObservation()
        assertUnsent(await client.act(.tapPoint(observationID: freshScreenshot.observationID, x: 0.5, y: 0.5)),
                     kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/tap" }.count, 1)
    }

    func testStoppingDuringPointPreflightPreventsTap() async throws {
        let gate = ReplyGate()
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + [Fixture.active,
            .json("GET", "/window/size", #"{"value":{"width":402,"height":874}}"#, gate: gate),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let action = Task { await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5)) }
        await fulfillment(of: [gate.started], timeout: 2)
        await client.stop()
        gate.release()
        assertUnsent(await action.value, kind: .stopped)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/tap" })
    }

}
