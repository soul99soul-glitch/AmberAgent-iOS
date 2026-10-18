import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import AmberPhoneControl

extension PhoneRunnerClientTests {
    func testDismissKeyboardRejectsForegroundAppOutsideRunScope() async throws {
        let fixture = Fixture([
            .json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"other.app","pid":9}}"#),
        ])
        let client = try makeClient(fixture)

        assertUnsent(await client.act(.dismissKeyboard), kind: .appOutOfScope)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/wda/keyboard/dismiss" })
    }

    func testDismissKeyboardDispatchesForAllowedForegroundApp() async throws {
        let fixture = Fixture([
            Fixture.active,
            .json("POST", "/wda/keyboard/dismiss", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)

        let result = await client.act(.dismissKeyboard)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/wda/keyboard/dismiss"])
    }

    func testNewObservationInvalidatesPreviousRefs() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.observation)
        let client = try makeClient(fixture)
        let first = try await client.observe()
        let second = try await client.observe()
        let latest = await client.latestObservation
        XCTAssertEqual(latest, second)
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(first.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testAppSwitchBeforeActionRejectsWithoutLookupOrMutation() async throws {
        let fixture = Fixture(Fixture.observation + [.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"other.app","pid":9}}"#)])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .appChanged)
        XCTAssertFalse(fixture.requests.contains { $0.path == "/elements" || $0.path.hasSuffix("/click") })
    }

    func testAmbiguousFreshLookupNeverClicks() async throws {
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", #"{"value":[{"ELEMENT":"A"},{"ELEMENT":"B"}]}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .ambiguousElement)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
    }

    func testPageAnchorStopsSameTargetAfterPageChanges() async throws {
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("POST", "/elements", #"{"value":[]}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(
            .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
            pageAnchorRef: try XCTUnwrap(observation.nodes.first { $0.identifier == "question" }?.ref)
        )
        assertUnsent(result, kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
        XCTAssertEqual(fixture.requests.filter { $0.path == "/elements" }.count, 2)
    }

    func testPageAnchorUsesTextIdentityWithoutEnabledOrFrame() async throws {
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("POST", "/elements", Fixture.oneElement),
            Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(
            .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
            pageAnchorRef: try XCTUnwrap(observation.nodes.first { $0.identifier == "question" }?.ref)
        )
        XCTAssertEqual(result, .completed)
        let anchorLookup = try XCTUnwrap(fixture.requests.filter { $0.path == "/elements" }.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: anchorLookup.body)
        let predicate = try XCTUnwrap(body["value"]?.string)
        XCTAssertTrue(predicate.contains("type == 'XCUIElementTypeStaticText'"))
        XCTAssertTrue(predicate.contains("rawIdentifier == 'question'"))
        XCTAssertTrue(predicate.contains("label == 'Q1'"))
        XCTAssertTrue(predicate.contains("value == 'Q1'"))
        XCTAssertTrue(predicate.contains("visible == true"))
        XCTAssertFalse(predicate.contains("enabled =="))
        XCTAssertFalse(predicate.contains("rect."))
        let matcher = NSPredicate(format: predicate)
        var candidate: [String: Any] = [
            "type": "XCUIElementTypeStaticText", "rawIdentifier": "question",
            "label": "Q1", "value": "Q1", "visible": true, "enabled": false,
            "rect": ["x": 900, "y": 900, "width": 80, "height": 24],
        ]
        XCTAssertTrue(matcher.evaluate(with: candidate))
        candidate["visible"] = false
        XCTAssertFalse(matcher.evaluate(with: candidate))
    }

    func testRequireUnchangedObservationStopsSameTargetAfterTextChanges() async throws {
        let changedTree = Fixture.anchoredTree.replacingOccurrences(of: "Q1", with: "Q2")
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("GET", "/source", changedTree, headers: [
                "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
            ]),
            Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(
            .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
            requireUnchangedObservation: true
        )
        assertUnsent(result, kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
        XCTAssertEqual(fixture.requests.filter { $0.path == "/source" }.count, 2)
    }

    func testRequireUnchangedObservationIgnoresTargetFrameAnimation() async throws {
        let movedTree = Fixture.anchoredTree.replacingOccurrences(of: #""y":100"#, with: #""y":120"#)
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("GET", "/source", movedTree, headers: [
                "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
            ]),
            Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(
            .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
            requireUnchangedObservation: true
        )
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.filter { $0.path.hasSuffix("/click") }.count, 1)
    }

    func testPageAnchorRegionConstrainsAnchorCenter() async throws {
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("POST", "/elements", Fixture.oneElement),
            Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(
            .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
            pageAnchorRef: try XCTUnwrap(observation.nodes.first { $0.identifier == "question" }?.ref),
            pageAnchorRegion: PhoneElementRect(x: 0, y: 0, width: 80, height: 40)
        )
        XCTAssertEqual(result, .completed)
        let anchorLookup = try XCTUnwrap(fixture.requests.filter { $0.path == "/elements" }.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: anchorLookup.body)
        let predicate = try XCTUnwrap(body["value"]?.string)
        XCTAssertTrue(predicate.contains("rect.x + rect.width / 2.0 >= 0.0"))
        XCTAssertTrue(predicate.contains("rect.y + rect.height / 2.0 <= 40.0"))
        let matcher = NSPredicate(format: predicate)
        let inside: [String: Any] = [
            "type": "XCUIElementTypeStaticText", "rawIdentifier": "question",
            "label": "Q1", "value": "Q1", "visible": true,
            "rect": ["x": 20, "y": 20, "width": 80, "height": 24],
        ]
        var outside = inside
        outside["rect"] = ["x": 100, "y": 20, "width": 80, "height": 24]
        XCTAssertTrue(matcher.evaluate(with: inside))
        XCTAssertFalse(matcher.evaluate(with: outside))
    }

    func testPageAnchorRegionRejectsNonPositiveOrNonFiniteSize() async throws {
        for region in [
            PhoneElementRect(x: 0, y: 0, width: 0, height: 40),
            PhoneElementRect(x: 0, y: 0, width: 80, height: 0),
            PhoneElementRect(x: 0, y: 0, width: Double.nan, height: 40),
        ] {
            let fixture = Fixture(Fixture.anchoredObservation)
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let before = fixture.requests.count
            let result = await client.act(
                .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
                pageAnchorRef: try XCTUnwrap(observation.nodes.first { $0.identifier == "question" }?.ref),
                pageAnchorRegion: region
            )
            assertUnsent(result, kind: .invalidAction)
            XCTAssertEqual(fixture.requests.count, before)
        }
    }

    func testMultiplePageAnchorsStopBeforeMutation() async throws {
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("POST", "/elements", #"{"value":[{"ELEMENT":"A"},{"ELEMENT":"B"}]}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(
            .tap(ref: try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)),
            pageAnchorRef: try XCTUnwrap(observation.nodes.first { $0.identifier == "question" }?.ref)
        )
        assertUnsent(result, kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
    }

    func testStoppingWhilePageAnchorLookupIsInFlightDoesNotMutate() async throws {
        let gate = ReplyGate()
        let fixture = Fixture(Fixture.anchoredObservation + [
            Fixture.active,
            .json("POST", "/elements", Fixture.oneElement),
            .json("POST", "/elements", Fixture.oneElement, gate: gate),
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let targetRef = try XCTUnwrap(observation.nodes.first { $0.identifier == "submit-button" }?.ref)
        let anchorRef = try XCTUnwrap(observation.nodes.first { $0.identifier == "question" }?.ref)
        let action = Task {
            await client.act(.tap(ref: targetRef), pageAnchorRef: anchorRef)
        }
        await fulfillment(of: [gate.started], timeout: 2)
        await client.stop()
        gate.release()
        assertUnsent(await action.value, kind: .stopped)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
    }

    func testPageAnchorRefFromPreviousObservationIsStaleWithoutRequests() async throws {
        let fixture = Fixture(Fixture.anchoredObservation + Fixture.anchoredObservation)
        let client = try makeClient(fixture)
        let first = try await client.observe()
        let second = try await client.observe()
        let count = fixture.requests.count
        let result = await client.act(
            .tap(ref: try XCTUnwrap(second.nodes.first { $0.identifier == "submit-button" }?.ref)),
            pageAnchorRef: try XCTUnwrap(first.nodes.first { $0.identifier == "question" }?.ref)
        )
        assertUnsent(result, kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, count)
    }

    func testPageAnchorIsInvalidForVisualAndLifecycleActions() async throws {
        for action in [
            PhoneAction.launch(bundleID: "app.test"),
            .home,
            .tapPoint(observationID: "observation", x: 0.5, y: 0.5),
            .swipePoint(observationID: "observation", startX: 0.1, startY: 0.1, endX: 0.2, endY: 0.2),
        ] {
            let fixture = Fixture([])
            let client = try makeClient(fixture)
            assertUnsent(await client.act(action, pageAnchorRef: "anchor"), kind: .invalidAction)
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testResponseLossMakesOutcomeUnknownAndNeverRetries() async throws {
        let fixture = Fixture([.failure("POST", "/wda/apps/activate", .networkConnectionLost)])
        let client = try makeClient(fixture)
        let result = await client.act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown, got \(result)") }
        XCTAssertEqual(problem.kind, .transport)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMutationCancellationIsUnknownAndDoesNotReplay() async throws {
        let fixture = Fixture([.failure("POST", "/wda/apps/activate", .cancelled)])
        let client = try makeClient(fixture)
        let result = await client.act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown") }
        XCTAssertEqual(problem.kind, .cancelled)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testHTTP200WithWebDriverErrorIsNotSuccess() async throws {
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":{"error":"unknown error","message":"activation failed"}}"#)])
        let result = await (try makeClient(fixture)).act(.launch(bundleID: "app.test"))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown") }
        XCTAssertEqual(problem.statusCode, 200)
        XCTAssertEqual(problem.runnerCode, "unknown error")
        XCTAssertEqual(problem.message, "activation failed")
    }

    func testDroppedAndAuthenticationRefusalsAreUnsent() async throws {
        for (status, headers) in [(401, [:]), (503, ["X-IPU-Dropped": "1"])] {
            let fixture = Fixture([.json("POST", "/wda/apps/activate",
                                        #"{"value":{"error":"unknown error","message":"refused"}}"#,
                                        status: status, headers: headers)])
            let result = await (try makeClient(fixture)).act(.launch(bundleID: "app.test"))
            guard case .unsent(let problem) = result else { return XCTFail("Expected unsent") }
            XCTAssertEqual(problem.statusCode, status)
        }
    }

    func testDroppedStaleClickAllowsReplanningOnlyAfterFreshObservation() async throws {
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click",
                  #"{"value":{"error":"stale element reference","message":"gone before any gesture"}}"#,
                  status: 404, headers: ["X-IPU-Dropped": "1"]),
        ] + Fixture.observation + [Fixture.active,
            .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let oldRef = try XCTUnwrap(observation.nodes[1].ref)
        let result = await client.act(.tap(ref: oldRef))
        guard case .unsent(let problem) = result else { return XCTFail("Expected a pre-gesture refusal") }
        XCTAssertEqual(problem.runnerCode, "stale element reference")
        XCTAssertTrue(problem.wasDroppedBeforeExecution)
        assertUnsent(await client.act(.tap(ref: oldRef)), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/element/FRESH/click" }.count, 1)

        let fresh = try await client.observe()
        let replanned = await client.act(.tap(ref: try XCTUnwrap(fresh.nodes[1].ref)))
        XCTAssertEqual(replanned, .completed)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/element/FRESH/click" }.count, 2)
    }

    func testStaleElementAfterMutationDispatchDoesNotPromiseNoSideEffect() async throws {
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click",
                  #"{"value":{"error":"stale element reference","message":"gone after scrolling"}}"#, status: 404),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref)))
        guard case .unknown(let problem) = result else { return XCTFail("Expected unknown") }
        XCTAssertEqual(problem.runnerCode, "stale element reference")
    }

    func testStopBlocksActionsAndObservations() async throws {
        let fixture = Fixture([])
        let client = try makeClient(fixture)
        await client.stop()
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .stopped)
        do { _ = try await client.observe(); XCTFail("Expected stopped") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testRefusedStartDoesNotReusePreviousOperationDiagnostics() async throws {
        let fixture = Fixture(Fixture.observation)
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let observedDiagnostics = await client.latestOperationDiagnostics
        XCTAssertEqual(observedDiagnostics?.operation, .observe)
        await client.stop()
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .stopped)
        let refusedDiagnostics = await client.latestOperationDiagnostics
        XCTAssertNil(refusedDiagnostics)
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testShutdownSignsOneShortRequestAndStopsWorkBeforeReply() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("POST", "/shutdown", #"{"value":{"shutdown":true}}"#, gate: gate)])
        let client = try makeClient(fixture)
        let shutdown = Task { try await client.shutdownRunner() }
        await fulfillment(of: [gate.started], timeout: 2)
        defer { gate.release() }
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .stopped)
        do { _ = try await client.observe(); XCTFail("Expected stopped") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        XCTAssertEqual(fixture.requests.count, 1)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/shutdown")
        XCTAssertEqual(request.url.host, "127.0.0.1")
        XCTAssertNil(request.url.query)
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(request.timeoutInterval, 2)
        let authorization = try XCTUnwrap(request.authorization)
        let pieces = authorization.replacingOccurrences(of: "IPU-HMAC-SHA256 ", with: "")
            .components(separatedBy: ", ")
        let timestamp = try XCTUnwrap(Int64(pieces[0].dropFirst(3)))
        let nonce = String(pieces[1].dropFirst(6))
        XCTAssertEqual(authorization, RunnerSigning.authorization(
            token: token, method: "POST", target: "/shutdown", body: Data(),
            timestamp: timestamp, nonce: nonce
        ))
        gate.release()
        try await shutdown.value
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testShutdownRejectsMissingFalseOrWronglyTypedConfirmation() async throws {
        for response in [#"{"value":null}"#, #"{"value":{"shutdown":false}}"#,
                         #"{"value":{"shutdown":"true"}}"#, #"{"value":{"shutdown":1}}"#] {
            let fixture = Fixture([.json("POST", "/shutdown", response)])
            let client = try makeClient(fixture)
            do { try await client.shutdownRunner(); XCTFail("Expected unconfirmed shutdown") }
            catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .malformedResponse) }
            assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .stopped)
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testShutdownPropagatesRefusalAndTransportFailureWithoutRetry() async throws {
        let refused = Fixture([.json("POST", "/shutdown", #"{"value":{"shutdown":true}}"#, status: 401)])
        let refusedClient = try makeClient(refused)
        do { try await refusedClient.shutdownRunner(); XCTFail("Expected authentication refusal") }
        catch let problem as PhoneControlProblem {
            XCTAssertEqual(problem.kind, .runner)
            XCTAssertEqual(problem.statusCode, 401)
        }
        assertUnsent(await refusedClient.act(.launch(bundleID: "app.test")), kind: .stopped)
        XCTAssertEqual(refused.requests.count, 1)

        let timedOut = Fixture([.failure("POST", "/shutdown", .timedOut)])
        let timedOutClient = try makeClient(timedOut)
        do { try await timedOutClient.shutdownRunner(); XCTFail("Expected timeout") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        assertUnsent(await timedOutClient.act(.launch(bundleID: "app.test")), kind: .stopped)
        XCTAssertEqual(timedOut.requests.count, 1)
    }

    func testRequestTimeoutOverridePreservesNormalRequestDefaults() async throws {
        let fixture = Fixture([.json("GET", "/custom", #"{"value":null}"#),
                               .json("GET", "/custom", #"{"value":null}"#)])
        let http = RunnerHTTP(token: token, port: fixture.port, configuration: fixture.configuration)
        _ = try await http.request(path: "/custom", timeoutInterval: 2)
        _ = try await http.request(path: "/custom")
        XCTAssertEqual(fixture.requests[0].timeoutInterval, 2)
        XCTAssertEqual(fixture.requests[1].timeoutInterval, URLRequest(url: fixture.requests[1].url).timeoutInterval)
        XCTAssertEqual(http.session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(http.session.configuration.timeoutIntervalForResource, 35)
    }

    func testWaitForStabilitySignsRequestAndInvalidatesObservation() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active,
            .json("GET", "/wda/settle", #"{"value":{"stable":true,"waited_ms":245,"frames":9,"blank":false,"changed_px":0,"capture_ms":4,"budget_ms":2000}}"#),
            Fixture.active,
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let stability = try await client.waitForStability()

        XCTAssertEqual(stability, PhoneScreenStability(stable: true, blank: false, waitedMs: 245, frames: 9,
                                                            changedPixels: 0, captureMs: 4, budgetMs: 2000))
        let settle = try XCTUnwrap(fixture.requests.first { $0.path == "/wda/settle" })
        XCTAssertEqual(settle.method, "GET")
        XCTAssertEqual(settle.url.query, "budget_ms=2000&quiet_ms=150")
        XCTAssertEqual(settle.timeoutInterval, URLRequest(url: settle.url).timeoutInterval)
        let authorization = try XCTUnwrap(settle.authorization)
        let pieces = authorization.replacingOccurrences(of: "IPU-HMAC-SHA256 ", with: "")
            .components(separatedBy: ", ")
        let timestamp = try XCTUnwrap(Int64(pieces[0].dropFirst(3)))
        let nonce = String(pieces[1].dropFirst(6))
        XCTAssertEqual(authorization, RunnerSigning.authorization(
            token: token, method: "GET", target: "/wda/settle?budget_ms=2000&quiet_ms=150", body: Data(),
            timestamp: timestamp, nonce: nonce
        ))
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testWaitForStabilityPreservesUnstableAndBlankFlags() async throws {
        for response in [
            #"{"stable":false,"waited_ms":2000,"frames":64,"blank":false,"changed_px":0,"capture_ms":4,"budget_ms":2000}"#,
            #"{"stable":true,"waited_ms":150,"frames":2,"blank":true,"changed_px":0,"capture_ms":4,"budget_ms":2000}"#,
        ] {
            let settleJSON = #"{"value":"# + response + #"}"#
            let fixture = Fixture([
                Fixture.active,
                .json("GET", "/wda/settle", settleJSON),
                Fixture.active,
            ])
            let stability = try await makeClient(fixture).waitForStability()
            XCTAssertEqual(stability.stable, response.contains(#""stable":true"#))
            XCTAssertEqual(stability.blank, response.contains(#""blank":true"#))
        }
    }

    func testWaitForStabilityRejectsForegroundChangeAndDoesNotKeepSnapshot() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active,
            .json("GET", "/wda/settle", #"{"value":{"stable":true,"waited_ms":20,"frames":2,"blank":false,"changed_px":0,"capture_ms":4,"budget_ms":2000}}"#),
            .json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"app.test","pid":43}}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        do { _ = try await client.waitForStability(); XCTFail("Expected foreground change") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appChanged) }
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testWaitForStabilityPropagatesRunnerErrorWithoutRetryOrSnapshot() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active,
            .json("GET", "/wda/settle", #"{"value":{"error":"capture failed","message":"screen unavailable"}}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        do { _ = try await client.waitForStability(); XCTFail("Expected settle error") }
        catch let problem as PhoneControlProblem {
            XCTAssertEqual(problem.kind, .runner)
            XCTAssertEqual(problem.runnerCode, "capture failed")
        }
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testStopDuringWaitForStabilityPreventsPublishingAndReleasesLock() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([
            Fixture.active,
            .json("GET", "/wda/settle", #"{"value":{"stable":true,"waited_ms":20,"frames":2,"blank":false,"changed_px":0,"capture_ms":4,"budget_ms":2000}}"#, gate: gate),
        ])
        let client = try makeClient(fixture)
        let wait = Task { try await client.waitForStability() }
        await fulfillment(of: [gate.started], timeout: 2)
        await client.stop()
        gate.release()
        do { _ = try await wait.value; XCTFail("Expected stop") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testStopDuringElementLookupPreventsMutation() async throws {
        let gate = ReplyGate()
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .json("POST", "/elements", Fixture.oneElement, gate: gate),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let ref = try XCTUnwrap(observation.nodes[1].ref)
        let action = Task { await client.act(.tap(ref: ref)) }
        await fulfillment(of: [gate.started], timeout: 2)
        await client.stop()
        gate.release()
        assertUnsent(await action.value, kind: .stopped)
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/click") })
    }

    func testConcurrentActionCannotOvertakeInFlightMutation() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":null}"#, gate: gate)])
        let client = try makeClient(fixture)
        let first = Task { await client.act(.launch(bundleID: "app.test")) }
        await fulfillment(of: [gate.started], timeout: 2)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .busy)
        gate.release()
        let result = await first.value
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testVerifiedApplicationCanBeAddedToLiveScopeButStopCannotBeUndone() async throws {
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":null}"#)])
        let client = try makeClient(fixture)
        assertUnsent(await client.act(.launch(bundleID: "app.added")), kind: .appOutOfScope)
        try await client.allowApplication("app.added")
        let result = await client.act(.launch(bundleID: "app.added"))
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.count, 1)
        await client.stop()
        do { try await client.allowApplication("app.another"); XCTFail("Stopped scope must not be revived") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        assertUnsent(await client.act(.launch(bundleID: "app.added")), kind: .stopped)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testUnknownActionOutcomeRejectsApplicationAdditionWithoutReplay() async throws {
        let fixture = Fixture([.failure("POST", "/wda/apps/activate", .timedOut)])
        let client = try makeClient(fixture)
        guard case .unknown = await client.act(.launch(bundleID: "app.test")) else {
            return XCTFail("Expected an unknown action outcome")
        }
        do { try await client.allowApplication("app.added"); XCTFail("Unknown outcome must keep the current run blocked") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .previousOutcomeUnknown) }
        assertUnsent(await client.act(.launch(bundleID: "app.added")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testApplicationAdditionCannotRaceInFlightMutation() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":null}"#, gate: gate)])
        let client = try makeClient(fixture)
        let action = Task { await client.act(.launch(bundleID: "app.test")) }
        await fulfillment(of: [gate.started], timeout: 2)
        do { try await client.allowApplication("app.added"); XCTFail("Scope must not change during an in-flight operation") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .busy) }
        gate.release()
        let result = await action.value
        XCTAssertEqual(result, .completed)
        assertUnsent(await client.act(.launch(bundleID: "app.added")), kind: .appOutOfScope)
        XCTAssertEqual(fixture.requests.count, 1)
    }

}
