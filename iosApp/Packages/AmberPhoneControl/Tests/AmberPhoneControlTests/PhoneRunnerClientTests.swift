import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import AmberPhoneControl

final class PhoneRunnerClientTests: XCTestCase, @unchecked Sendable {
    let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    func testSigningMatchesPinnedRunnerKnownAnswer() {
        XCTAssertEqual(RunnerSigning.authorization(
            token: token, method: "post", target: "/session/S/actions?x=1",
            body: Data(#"{"a":1}"#.utf8), timestamp: 1_700_000_000,
            nonce: "0123456789abcdef0123456789abcdef"
        ), "IPU-HMAC-SHA256 ts=1700000000, nonce=0123456789abcdef0123456789abcdef, sig=d45cade8fef49833329384ea5669106fce22a98fcc182db1ff3dc0eb946e6e11")
    }

    func testSignatureCoversExactlyEncodedQueryAndSortedBody() async throws {
        let fixture = Fixture([.json("POST", "/custom", #"{"value":null}"#)])
        let http = RunnerHTTP(token: token, port: fixture.port, configuration: fixture.configuration)
        _ = try await http.request(method: "POST", path: "/custom", query: ["z": "x/y", "a": "two words"],
                                   body: .object(["z": .number(1), "a": .string("/hello")]))
        let request = try XCTUnwrap(fixture.requests.first)
        let body = request.body
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"a":"/hello","z":1}"#)
        XCTAssertEqual(request.url.query, "a=two%20words&z=x/y")
        let authorization = try XCTUnwrap(request.authorization)
        let pieces = authorization.replacingOccurrences(of: "IPU-HMAC-SHA256 ", with: "")
            .components(separatedBy: ", ")
        let timestamp = try XCTUnwrap(Int64(pieces[0].dropFirst(3)))
        let nonce = String(pieces[1].dropFirst(6))
        XCTAssertEqual(authorization, RunnerSigning.authorization(
            token: token, method: "POST", target: "/custom?a=two%20words&z=x/y",
            body: body, timestamp: timestamp, nonce: nonce
        ))
        XCTAssertFalse(authorization.contains(token))
    }

    func testTreeObservationDoesNotTakeScreenshotAndRefsAreLocal() async throws {
        let fixture = Fixture(Fixture.observation)
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let latest = await client.latestObservation
        XCTAssertEqual(latest, observation)
        XCTAssertNil(observation.screenBounds)
        XCTAssertEqual(observation.bundleID, "app.test")
        XCTAssertEqual(observation.backend, "private-ax")
        XCTAssertEqual(observation.nodes.count, 2)
        XCTAssertNil(observation.nodes[0].ref)
        XCTAssertTrue(try XCTUnwrap(observation.nodes[1].ref).hasPrefix(observation.observationID + ":"))
        XCTAssertEqual(observation.nodes[1].identifier, "submit-button")
        XCTAssertTrue(observation.compactText.contains("Button id=\"submit-button\" label=\"Submit\""))
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/source", "/wda/activeAppInfo"])
    }

    func testCoveredPageNodesGetNoRefAndStayOutOfTheModelTree() async throws {
        let source = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":402,"height":874},"children":[{"type":"XCUIElementTypeOther","isCovered":"1","rect":{"x":0,"y":0,"width":402,"height":874},"children":[{"type":"XCUIElementTypeOther","label":"发送","isCovered":"1","rect":{"x":317,"y":229,"width":80,"height":46}}]},{"type":"XCUIElementTypeCell","label":"群成员","rect":{"x":16,"y":200,"width":370,"height":98}}]}}"#
        let fixture = Fixture([Fixture.active, .json("GET", "/source", source, headers: [
            "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0", "X-IPU-Covered": "2",
        ]), Fixture.active])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let send = try XCTUnwrap(observation.nodes.first { $0.label == "发送" })
        XCTAssertTrue(send.covered)
        XCTAssertNil(send.ref, "a covered node can never be targeted")
        let row = try XCTUnwrap(observation.nodes.first { $0.label == "群成员" })
        XCTAssertFalse(row.covered)
        XCTAssertNotNil(row.ref)
        XCTAssertFalse(observation.compactText.contains("发送"))
        XCTAssertTrue(observation.compactText.contains("群成员"))
        XCTAssertTrue(observation.compactText.contains("covered=2"))
    }

    func testInterceptedClickIsUnsentWithItsRunnerCode() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click",
                  #"{"value":{"error":"element click intercepted","message":"element FRESH is covered by Cell \"群成员\" [16,200,370,98] at its centre; nothing was sent."}}"#,
                  status: 400, headers: ["X-IPU-Dropped": "1"]),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let result = await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref)))
        guard case .unsent(let problem) = result else { return XCTFail("expected unsent, got \(result)") }
        XCTAssertEqual(problem.runnerCode, "element click intercepted")
        XCTAssertTrue(problem.wasDroppedBeforeExecution)
    }

    func testFreshUniqueLookupPrecedesOneMutationAndConsumesRef() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let ref = try XCTUnwrap(observation.nodes[1].ref)
        let result = await client.act(.tap(ref: ref))
        XCTAssertEqual(result, .completed)
        let latestDiagnostics = await client.latestOperationDiagnostics
        let diagnostics = try XCTUnwrap(latestDiagnostics)
        XCTAssertEqual(diagnostics.operation, .action)
        XCTAssertEqual(diagnostics.httpRequestCount, 4)
        XCTAssertEqual(diagnostics.requests.map(\.stage), [.activeApp, .elementLookup, .activeApp, .action])
        XCTAssertTrue(diagnostics.durationMs >= diagnostics.requests.reduce(0) { $0 + $1.durationMs })
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        let lookup = try XCTUnwrap(fixture.requests.first { $0.path == "/elements" })
        let lookupJSON = try JSONDecoder().decode(JSONValue.self, from: lookup.body)
        XCTAssertEqual(lookupJSON["using"]?.string, "predicate string")
        XCTAssertTrue(lookupJSON["value"]?.string?.contains("rawIdentifier == 'submit-button'") == true)
        XCTAssertTrue(lookupJSON["value"]?.string?.contains("rect.y == 100.0") == true)
        let count = fixture.requests.count
        assertUnsent(await client.act(.tap(ref: ref)), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, count)
    }

    func testObservedMultilineLabelsProduceExactRunnerPredicates() async throws {
        for label in ["覆写\n内置-覆写", "覆写\r内置-覆写", "literal \\n and 'quotes'",
                      "覆写\n'内置' \\n覆写"] {
            let rect = ["x": 44, "y": 733, "width": 314, "height": 46]
            let node: [String: Any] = [
                "type": "XCUIElementTypeOther", "label": label, "isEnabled": "1",
                "rect": rect, "children": [],
            ]
            let tree = try JSONSerialization.data(withJSONObject: ["value": [
                "type": "XCUIElementTypeApplication", "rect": rect, "children": [node],
            ]])
            let fixture = Fixture([
                Fixture.active, .json("GET", "/source", String(decoding: tree, as: UTF8.self),
                                      headers: ["X-IPU-Pid": "42"]), Fixture.active,
                Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
                .json("POST", "/element/FRESH/click", #"{"value":null}"#),
            ])
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let result = await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref)))
            XCTAssertEqual(result, .completed)
            let lookup = try XCTUnwrap(fixture.requests.first { $0.path == "/elements" })
            let body = try JSONDecoder().decode(JSONValue.self, from: lookup.body)
            let format = try XCTUnwrap(body["value"]?.string)
            // Use the runner's real Foundation parser, not an expected escaped string.
            let predicate = NSPredicate(format: format)
            var candidate: [String: Any] = [
                "type": "XCUIElementTypeOther", "enabled": true, "label": label, "rect": rect,
            ]
            XCTAssertTrue(predicate.evaluate(with: candidate), label.debugDescription)
            for differentLabel in [label + "changed", label.replacingOccurrences(of: "\n", with: "\\n")]
                where differentLabel != label {
                candidate["label"] = differentLabel
                XCTAssertFalse(predicate.evaluate(with: candidate), label.debugDescription)
            }
            XCTAssertEqual(fixture.requests.filter { $0.path.hasSuffix("/click") }.count, 1)
        }
    }

    func testElementLongPressUsesFreshLookupAndBoundedSecondsThenConsumesReference() async throws {
        for duration in [300, 750, 3_000] {
            let fixture = Fixture(Fixture.observation + [
                Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
                .json("POST", "/wda/element/FRESH/touchAndHold", #"{"value":null}"#),
            ])
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let ref = try XCTUnwrap(observation.nodes[1].ref)
            let result = await client.act(.longPress(ref: ref, durationMs: duration))
            XCTAssertEqual(result, .completed)
            let request = try XCTUnwrap(fixture.requests.last)
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
            XCTAssertEqual(body["duration"]?.number, Double(duration) / 1_000)
            XCTAssertEqual(fixture.requests.dropFirst(3).map(\.path), ["/wda/activeAppInfo", "/elements", "/wda/activeAppInfo", "/wda/element/FRESH/touchAndHold"])
            assertUnsent(await client.act(.longPress(ref: ref, durationMs: duration)), kind: .staleObservation)
            XCTAssertEqual(fixture.requests.count, 7)
        }
    }

    func testLongPressRejectsInvalidDurationStaleReferenceAndDisabledTargetsWithoutLookup() async throws {
        for duration in [Int.min, 0, 299, 3_001, Int.max] {
            let fixture = Fixture(Fixture.observation)
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            assertUnsent(await client.act(.longPress(ref: try XCTUnwrap(observation.nodes[1].ref), durationMs: duration)), kind: .invalidAction)
            XCTAssertEqual(fixture.requests.count, 3)
        }
        let fixture = Fixture(Fixture.observation + Fixture.observation)
        let client = try makeClient(fixture)
        let stale = try await client.observe()
        _ = try await client.observe()
        assertUnsent(await client.act(.longPress(ref: try XCTUnwrap(stale.nodes[1].ref), durationMs: 750)), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 6)
        let disabled = Fixture(Fixture.inputObservation(type: "XCUIElementTypeButton", enabled: false))
        let disabledClient = try makeClient(disabled)
        let disabledObservation = try await disabledClient.observe()
        assertUnsent(await disabledClient.act(.longPress(ref: try XCTUnwrap(disabledObservation.nodes[1].ref), durationMs: 750)), kind: .unsupportedNode)
        XCTAssertEqual(disabled.requests.count, 3)
    }

    func testVisualLongPressUsesCurrentScreenshotGeometryAndW3CHold() async throws {
        let fixture = Fixture(Fixture.popupObservation + Fixture.screenshot + Fixture.pointPreflight + [
            .json("POST", "/actions", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let result = await client.act(.longPressPoint(observationID: screenshot.observationID, x: 0.5, y: 0.25, durationMs: 750))
        XCTAssertEqual(result, .completed)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(fixture.requests.last).body)
        let source = try XCTUnwrap(body["actions"]?.array?.first)
        XCTAssertEqual(source["type"]?.string, "pointer")
        XCTAssertEqual(source["parameters"]?["pointerType"]?.string, "touch")
        let actions = try XCTUnwrap(source["actions"]?.array)
        XCTAssertEqual(actions.map { $0["type"]?.string }, ["pointerMove", "pointerDown", "pause", "pointerUp"])
        XCTAssertEqual(actions[0]["x"]?.number, 201)
        XCTAssertEqual(actions[0]["y"]?.number, 218.5)
        XCTAssertEqual(actions[2]["duration"]?.number, 750)
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        assertUnsent(await client.act(.longPressPoint(observationID: screenshot.observationID, x: 0.5, y: 0.25, durationMs: 750)), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/actions" }.count, 1)
    }

    func testVisualLongPressRejectsMissingEvidenceInvalidPointsAndRotationWithoutSending() async throws {
        let missing = Fixture(Fixture.observation)
        let missingClient = try makeClient(missing)
        let observed = try await missingClient.observe()
        assertUnsent(await missingClient.act(.longPressPoint(observationID: observed.observationID, x: 0.5, y: 0.5, durationMs: 750)), kind: .staleObservation)
        XCTAssertEqual(missing.requests.count, 3)
        for (x, y, duration) in [(Double.nan, 0.5, 750), (0.5, 1.0, 750), (0.5, 0.5, 299)] {
            let fixture = Fixture(Fixture.observation + Fixture.screenshot)
            let client = try makeClient(fixture)
            _ = try await client.observe()
            let screen = try await client.screenshotObservation()
            assertUnsent(await client.act(.longPressPoint(observationID: screen.observationID, x: x, y: y, durationMs: duration)), kind: .invalidAction)
            XCTAssertEqual(fixture.requests.count, 8)
        }
        let rotated = Fixture(Fixture.observation + Fixture.screenshot + [Fixture.active, Fixture.landscapeScreen])
        let rotatedClient = try makeClient(rotated)
        _ = try await rotatedClient.observe()
        let screenshot = try await rotatedClient.screenshotObservation()
        assertUnsent(await rotatedClient.act(.longPressPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5, durationMs: 750)), kind: .staleObservation)
        XCTAssertFalse(rotated.requests.contains { $0.path == "/actions" })
    }

    func testVisualLongPressDowngradedToTapIsUnknownAndCannotReplay() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot + Fixture.pointPreflight + [
            .json("POST", "/actions", #"{"value":null}"#, headers: ["X-IPU-Gesture": "xcui-coordinate"]),
        ])
        let client = try makeClient(fixture)
        _ = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let result = await client.act(.longPressPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5, durationMs: 750))
        guard case .unknown(let problem) = result else { return XCTFail("Downgraded hold must not complete") }
        XCTAssertEqual(problem.kind, .runner)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/actions" }.count, 1)
    }

    func testLongPressResponseLossBlocksAnotherGestureAfterFreshObservation() async throws {
        let fixture = Fixture(Fixture.observation + [
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .failure("POST", "/wda/element/FRESH/touchAndHold", .networkConnectionLost),
        ] + Fixture.observation)
        let client = try makeClient(fixture)
        let initial = try await client.observe()
        let result = await client.act(.longPress(ref: try XCTUnwrap(initial.nodes[1].ref), durationMs: 750))
        guard case .unknown = result else { return XCTFail("Expected unknown") }
        let latest = try await client.observe()
        assertUnsent(await client.act(.longPress(ref: try XCTUnwrap(latest.nodes[1].ref), durationMs: 750)), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 10)
    }

    func testCompactTextFoldsOnlyEmptyContainersAndKeepsLocalReferencesAndExceptionalState() {
        let bounds = PhoneElementRect(x: 0, y: 0, width: 400, height: 800)
        func node(_ index: Int, _ type: String, label: String? = nil, enabled: Bool = true, focused: Bool = false) -> PhoneObservationNode {
            PhoneObservationNode(ref: "observed:\(index)", depth: index, type: "XCUIElementType" + type,
                                 identifier: nil, label: label, value: nil, rect: bounds, enabled: enabled, focused: focused)
        }
        let nodes = [node(0, "Application"), node(1, "Window"), node(2, "Other"),
                     node(3, "Button"), node(4, "ScrollView"), node(5, "Other", label: "card\nnew row"),
                     node(6, "Other", enabled: false), node(7, "Other", focused: true)]
        let observation = PhoneObservation(observationID: "observed", bundleID: "app.test", processID: 42,
                                           backend: "private-ax", truncated: true, nodes: nodes)
        let text = observation.compactText
        XCTAssertTrue(text.contains("truncated=true nodes=8 displayed=5 omitted=3"))
        XCTAssertFalse(text.contains("observed:1 Window"))
        XCTAssertTrue(text.contains("observed:3 Button"))
        XCTAssertTrue(text.contains("observed:4 ScrollView"))
        XCTAssertTrue(text.contains(#"label="card\nnew row""#))
        XCTAssertTrue(text.contains("observed:6 Other enabled=false"))
        XCTAssertTrue(text.contains("observed:7 Other focused=true"))
        XCTAssertFalse(text.contains("enabled=true"))
        XCTAssertFalse(text.contains("focused=false"))
        XCTAssertEqual(observation.nodes, nodes)
    }

    func testAlertTapUsesLatestObservedContextAndExactNameWithoutIndependentAlertRead() async throws {
        let fixture = Fixture(try Fixture.alertObservation() + [
            Fixture.active, .json("POST", "/alert/accept", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        XCTAssertTrue(observation.alertActionsSupported)
        let alert = try XCTUnwrap(observation.alerts.first)
        XCTAssertEqual(alert.text, "Allow access?\nOnly while using the app")
        XCTAssertEqual(alert.processID, 42)
        XCTAssertEqual(alert.buttons.map(\.name), ["Cancel", "Allow"])
        let button = try XCTUnwrap(alert.buttons.last)
        let ref = try XCTUnwrap(button.ref)
        let result = await client.act(.tapAlert(ref: ref))
        XCTAssertEqual(result, .completed)
        let request = try XCTUnwrap(fixture.requests.last)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
        XCTAssertEqual(body["name"]?.string, "Allow")
        XCTAssertEqual(body["exact_name"]?.bool, true)
        XCTAssertEqual(body["expected_text"]?.string, alert.text)
        XCTAssertEqual(body["expected_pid"]?.number, 42)
        XCTAssertEqual(body["expected_buttons"]?.array, [.string("Cancel"), .string("Allow")])
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/source", "/wda/activeAppInfo", "/wda/activeAppInfo", "/alert/accept"])
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        assertUnsent(await client.act(.tapAlert(ref: ref)), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testOrdinaryAndExplicitAlertTapSendIdenticalGuardedRequest() async throws {
        var bodies: [Data] = []
        for explicit in [false, true] {
            let fixture = Fixture(try Fixture.alertObservation() + [Fixture.active, .json("POST", "/alert/accept", #"{"value":null}"#)])
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let ref = try XCTUnwrap(observation.alerts.first?.buttons.last?.ref)
            let result = await client.act(explicit ? .tapAlert(ref: ref) : .tap(ref: ref))
            XCTAssertEqual(result, .completed)
            bodies.append(try XCTUnwrap(fixture.requests.last).body)
            XCTAssertEqual(fixture.requests.count, 5)
            XCTAssertFalse(fixture.requests.contains { $0.path == "/elements" || $0.path.hasSuffix("/click") })
        }
        XCTAssertEqual(bodies[0], bodies[1])
    }

    func testOrdinaryAlertTapOldArtifactOrMissingContextIsUnsentAndLongPressIsUnsupported() async throws {
        let old = Fixture(try Fixture.alertObservation(supported: false))
        let oldClient = try makeClient(old)
        let oldObservation = try await oldClient.observe()
        assertUnsent(await oldClient.act(.tap(ref: try XCTUnwrap(oldObservation.alerts.first?.buttons.last?.ref))), kind: .unsupportedNode)
        XCTAssertEqual(old.requests.count, 3)

        let stale = Fixture(try Fixture.alertObservation() + Fixture.observation)
        let staleClient = try makeClient(stale)
        let prior = try await staleClient.observe()
        _ = try await staleClient.observe()
        assertUnsent(await staleClient.act(.tap(ref: try XCTUnwrap(prior.alerts.first?.buttons.last?.ref))), kind: .staleObservation)
        XCTAssertEqual(stale.requests.count, 6)

        let holding = Fixture(try Fixture.alertObservation())
        let holdingClient = try makeClient(holding)
        let alert = try await holdingClient.observe()
        assertUnsent(await holdingClient.act(.longPress(ref: try XCTUnwrap(alert.alerts.first?.buttons.last?.ref), durationMs: 750)), kind: .unsupportedNode)
        XCTAssertEqual(holding.requests.count, 3)
    }

    func testAlertTapCannotBypassPageAnchorOrUnchangedObservationGuardAfterRouting() async throws {
        for explicit in [false, true] {
            for guardKind in ["anchor", "unchanged"] {
                let fixture = Fixture(try Fixture.alertObservation())
                let client = try makeClient(fixture)
                let observed = try await client.observe()
                let ref = try XCTUnwrap(observed.alerts.first?.buttons.last?.ref)
                let action: PhoneAction = explicit ? .tapAlert(ref: ref) : .tap(ref: ref)
                let result = await client.act(action,
                    pageAnchorRef: guardKind == "anchor" ? ref : nil,
                    requireUnchangedObservation: guardKind == "unchanged")
                assertUnsent(result, kind: .invalidAction)
                XCTAssertEqual(fixture.requests.count, 3)
                XCTAssertFalse(fixture.requests.contains { $0.method == "POST" })
            }
        }
    }

    func testUnnamedAlertButtonCannotBypassContextWithOrdinaryTapOrLongPress() async throws {
        for holding in [false, true] {
            let fixture = Fixture(try Fixture.alertObservation(names: [""]))
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            XCTAssertEqual(observation.alerts.first?.buttons.count, 0)
            let ref = try XCTUnwrap(observation.nodes.last?.ref)
            let result = await client.act(holding ? .longPress(ref: ref, durationMs: 750) : .tap(ref: ref))
            assertUnsent(result, kind: holding ? .unsupportedNode : .staleObservation)
            XCTAssertEqual(fixture.requests.count, 3)
        }
    }

    func testOrdinaryAlertTapChangedContextRefusalAndLostReplyCannotBypassGuard() async throws {
        let changed = Fixture(try Fixture.alertObservation() + [
            Fixture.active, .json("POST", "/alert/accept", #"{"value":{"error":"invalid argument","message":"alert context changed; nothing was sent"}}"#,
                                  status: 409, headers: ["X-IPU-Dropped": "1"]),
        ])
        let changedClient = try makeClient(changed)
        let observation = try await changedClient.observe()
        assertUnsent(await changedClient.act(.tap(ref: try XCTUnwrap(observation.alerts.first?.buttons.last?.ref))), kind: .runner)
        XCTAssertEqual(changed.requests.count, 5)
        XCTAssertFalse(changed.requests.contains { $0.path.hasSuffix("/click") })

        let lost = Fixture(try Fixture.alertObservation() + [Fixture.active, .failure("POST", "/alert/accept", .networkConnectionLost)])
        let lostClient = try makeClient(lost)
        let visible = try await lostClient.observe()
        guard case .unknown = await lostClient.act(.tap(ref: try XCTUnwrap(visible.alerts.first?.buttons.last?.ref))) else {
            return XCTFail("Expected unknown")
        }
        assertUnsent(await lostClient.act(.launch(bundleID: "app.test")), kind: .previousOutcomeUnknown)
        XCTAssertEqual(lost.requests.count, 5)
    }

    func testEveryObservedAlertSubtreeRoutesOrdinaryTapThroughItsOwnContext() async throws {
        let initial = try Fixture.alertObservation()
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: initial[1].data) as? [String: Any])
        var app = try XCTUnwrap(envelope["value"] as? [String: Any])
        let first = try XCTUnwrap((app["children"] as? [[String: Any]])?.first)
        var second = first
        var children = try XCTUnwrap(second["children"] as? [[String: Any]])
        children[0]["label"] = "Second prompt"
        second["children"] = children
        app["children"] = [first, second]
        let data = try JSONSerialization.data(withJSONObject: ["value": app])
        let fixture = Fixture([
            Fixture.active, .json("GET", "/source", String(decoding: data, as: UTF8.self), headers: initial[1].headers), Fixture.active,
            Fixture.active, .json("POST", "/alert/accept", #"{"value":{"error":"invalid argument","message":"different presented alert"}}"#,
                                  status: 409, headers: ["X-IPU-Dropped": "1"]),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        XCTAssertEqual(observation.alerts.count, 2)
        let secondRef = try XCTUnwrap(observation.alerts[1].buttons.last?.ref)
        assertUnsent(await client.act(.tap(ref: secondRef)), kind: .runner)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(fixture.requests.last).body)
        XCTAssertEqual(body["expected_text"]?.string, "Second prompt\nOnly while using the app")
        XCTAssertFalse(fixture.requests.contains { $0.path == "/elements" || $0.path.hasSuffix("/click") })
    }

    func testAlertDescriptionPreservesNameAndValueFallbacksWithoutChangingNativeLabels() async throws {
        let source = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeAlert","name":"Fallback title","rect":{"x":0,"y":0,"width":0,"height":0},"children":[{"type":"XCUIElementTypeButton","name":"Confirm","rect":{"x":0,"y":0,"width":0,"height":0},"children":[{"type":"XCUIElementTypeStaticText","label":"button child is ignored","rect":{"x":0,"y":0,"width":10,"height":10}}]},{"type":"XCUIElementTypeStaticText","name":"Title","rect":{"x":0,"y":0,"width":10,"height":10}},{"type":"XCUIElementTypeTextView","value":"Body","rect":{"x":0,"y":0,"width":10,"height":10}},{"type":"XCUIElementTypeStaticText","label":"Title","rect":{"x":0,"y":0,"width":10,"height":10}},{"type":"XCUIElementTypeButton","label":"Later","rect":{"x":20,"y":300,"width":90,"height":44}}]}]}}"#
        let fixture = Fixture([Fixture.active, .json("GET", "/source", source, headers: [
            "X-IPU-Pid": "42", "X-IPU-Alert-Guard": "context-v1",
        ]), Fixture.active])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let alert = try XCTUnwrap(observation.alerts.first)
        XCTAssertNil(alert.ref)
        XCTAssertEqual(alert.text, "Title\nBody")
        XCTAssertEqual(alert.buttons.map(\.name), ["Confirm", "Later"])
        XCTAssertNil(alert.buttons[0].ref)
        XCTAssertNotNil(alert.buttons[1].ref)
        XCTAssertNil(observation.nodes[2].label)
        XCTAssertNil(observation.nodes[4].label)
    }

    func testAlertTapRejectsOldRunnerDuplicateNamesAndNonAlertTargetsWithoutRequest() async throws {
        for (supported, names, expected) in [(false, ["Allow"], PhoneControlProblem.Kind.unsupportedNode),
                                             (true, ["OK", "OK"], .ambiguousElement)] {
            let fixture = Fixture(try Fixture.alertObservation(names: names, supported: supported))
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let button = try XCTUnwrap(observation.alerts.first?.buttons.first?.ref)
            assertUnsent(await client.act(.tapAlert(ref: button)), kind: expected)
            XCTAssertEqual(fixture.requests.count, 3)
        }
        let ordinary = Fixture(Fixture.observation)
        let ordinaryClient = try makeClient(ordinary)
        let ordinaryObservation = try await ordinaryClient.observe()
        assertUnsent(await ordinaryClient.act(.tapAlert(ref: try XCTUnwrap(ordinaryObservation.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(ordinary.requests.count, 3)
    }

    func testAlertTapRejectsOldObservationAndSpringBoardForegroundWithoutExpandingScope() async throws {
        let stale = Fixture(try Fixture.alertObservation() + Fixture.alertObservation())
        let staleClient = try makeClient(stale)
        let old = try await staleClient.observe()
        _ = try await staleClient.observe()
        assertUnsent(await staleClient.act(.tapAlert(ref: try XCTUnwrap(old.alerts.first?.buttons.last?.ref))), kind: .staleObservation)
        XCTAssertEqual(stale.requests.count, 6)

        let system = Fixture(try Fixture.alertObservation() + [
            .json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"com.apple.springboard","pid":9}}"#),
        ])
        let systemClient = try makeClient(system)
        let observed = try await systemClient.observe()
        assertUnsent(await systemClient.act(.tapAlert(ref: try XCTUnwrap(observed.alerts.first?.buttons.last?.ref))), kind: .appChanged)
        XCTAssertEqual(system.requests.count, 4)
        XCTAssertFalse(system.requests.contains { $0.method == "POST" })
    }

    func testChangedAlertGuardRefusalIsUnsentButLostReplyLocksFurtherActions() async throws {
        let refused = Fixture(try Fixture.alertObservation() + [
            Fixture.active, .json("POST", "/alert/accept", #"{"value":{"error":"invalid argument","message":"alert context changed; nothing was sent"}}"#,
                                  status: 409, headers: ["X-IPU-Dropped": "1"]),
        ] + Fixture.alertObservation() + [Fixture.active, .json("POST", "/alert/accept", #"{"value":null}"#)])
        let refusedClient = try makeClient(refused)
        let first = try await refusedClient.observe()
        assertUnsent(await refusedClient.act(.tapAlert(ref: try XCTUnwrap(first.alerts.first?.buttons.last?.ref))), kind: .runner)
        let fresh = try await refusedClient.observe()
        let freshResult = await refusedClient.act(.tapAlert(ref: try XCTUnwrap(fresh.alerts.first?.buttons.last?.ref)))
        XCTAssertEqual(freshResult, .completed)
        XCTAssertEqual(refused.requests.filter { $0.path == "/alert/accept" }.count, 2)

        let lost = Fixture(try Fixture.alertObservation() + [
            Fixture.active, .failure("POST", "/alert/accept", .networkConnectionLost),
        ] + Fixture.alertObservation())
        let lostClient = try makeClient(lost)
        let previous = try await lostClient.observe()
        guard case .unknown = await lostClient.act(.tapAlert(ref: try XCTUnwrap(previous.alerts.first?.buttons.last?.ref))) else {
            return XCTFail("Expected unknown alert tap outcome")
        }
        let reconciled = try await lostClient.observe()
        assertUnsent(await lostClient.act(.tapAlert(ref: try XCTUnwrap(reconciled.alerts.first?.buttons.last?.ref))), kind: .previousOutcomeUnknown)
        XCTAssertEqual(lost.requests.filter { $0.path == "/alert/accept" }.count, 1)
    }

    func testWiderObservationReachesComposerAfterTruncatedHistoryAndTypesOnce() async throws {
        func source(historyCount: Int, includeComposer: Bool) throws -> Fixture.Reply {
            let rect = ["x": 0, "y": 0, "width": 400, "height": 800]
            let history: [[String: Any]] = (0..<historyCount).map { index in
                ["type": "XCUIElementTypeStaticText", "label": "History \(index)", "rect": rect, "children": []]
            }
            var children: [[String: Any]] = [["type": "XCUIElementTypeTable", "rect": rect, "children": history]]
            if includeComposer {
                children.append(["type": "XCUIElementTypeTextView", "rawIdentifier": "composer",
                                 "isEnabled": "1", "rect": ["x": 20, "y": 700, "width": 300, "height": 44],
                                 "children": []])
            }
            let data = try JSONSerialization.data(withJSONObject: ["value": [
                "type": "XCUIElementTypeApplication", "rect": rect, "children": children,
            ]])
            return .json("GET", "/source", String(decoding: data, as: UTF8.self), headers: [
                "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": includeComposer ? "0" : "1",
            ])
        }
        let fixture = Fixture([
            Fixture.active, try source(historyCount: 498, includeComposer: false), Fixture.active,
            Fixture.active, try source(historyCount: 600, includeComposer: true), Fixture.active,
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/value", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let partial = try await client.observe(maxNodes: 500)
        XCTAssertTrue(partial.truncated)
        XCTAssertFalse(partial.nodes.contains { $0.type == "XCUIElementTypeTextView" })

        let wider = try await client.observe(maxNodes: 2000)
        XCTAssertFalse(wider.truncated)
        let composer = try XCTUnwrap(wider.nodes.first { $0.identifier == "composer" })
        let ref = try XCTUnwrap(composer.ref)
        let result = await client.act(.type(ref: ref, text: "test draft"))
        XCTAssertEqual(result, .completed)
        assertUnsent(await client.act(.type(ref: ref, text: "test draft")), kind: .staleObservation)

        let sourceQueries = fixture.requests.filter { $0.path == "/source" }.map { $0.url.query }
        XCTAssertEqual(sourceQueries, ["format=json&max_nodes=500", "format=json&max_nodes=2000"])
        let lookup = try XCTUnwrap(fixture.requests.first { $0.path == "/elements" })
        let lookupBody = try JSONDecoder().decode(JSONValue.self, from: lookup.body)
        XCTAssertTrue(lookupBody["value"]?.string?.contains("rawIdentifier == 'composer'") == true)
        let mutations = fixture.requests.filter { $0.path.hasSuffix("/value") }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(String(data: try XCTUnwrap(mutations.first).body, encoding: .utf8), #"{"text":"test draft"}"#)
    }

    func testClearResolvesFreshInputAndConsumesReference() async throws {
        for type in ["XCUIElementTypeTextField", "XCUIElementTypeTextView", "XCUIElementTypeSearchField"] {
            let fixture = Fixture(Fixture.inputObservation(type: type) + [
                Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
                .json("POST", "/element/FRESH/clear", #"{"value":null}"#),
            ])
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let ref = try XCTUnwrap(observation.nodes[1].ref)
            let result = await client.act(.clear(ref: ref))
            XCTAssertEqual(result, .completed)
            let latest = await client.latestObservation
            XCTAssertNil(latest)
            let lookup = try XCTUnwrap(fixture.requests.first { $0.path == "/elements" })
            let predicate = try JSONDecoder().decode(JSONValue.self, from: lookup.body)["value"]?.string
            XCTAssertTrue(predicate?.contains("type == '\(type)'") == true)
            XCTAssertTrue(predicate?.contains("rawIdentifier == 'query'") == true)
            XCTAssertTrue(predicate?.contains("value == 'existing'") == true)
            let mutation = try XCTUnwrap(fixture.requests.last)
            XCTAssertEqual(mutation.method, "POST")
            XCTAssertEqual(mutation.path, "/element/FRESH/clear")
            XCTAssertEqual(String(decoding: mutation.body, as: UTF8.self), "{}")
            let count = fixture.requests.count
            assertUnsent(await client.act(.clear(ref: ref)), kind: .staleObservation)
            assertUnsent(await client.act(.type(ref: ref, text: "replacement")), kind: .staleObservation)
            XCTAssertEqual(fixture.requests.count, count)
        }
    }

    func testTypeKeepsAppendSemanticsAndSecureSupportWithoutImplicitClear() async throws {
        for type in ["XCUIElementTypeTextField", "XCUIElementTypeSecureTextField"] {
            let fixture = Fixture(Fixture.inputObservation(type: type) + [
                Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
                .json("POST", "/element/FRESH/value", #"{"value":null}"#),
            ])
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let result = await client.act(.type(ref: try XCTUnwrap(observation.nodes[1].ref), text: " appended"))
            XCTAssertEqual(result, .completed)
            XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/clear") })
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(fixture.requests.last).body)
            XCTAssertEqual(body["text"]?.string, " appended")
        }
    }

    func testClearRejectsReferenceFromPreviousObservationWithoutRequest() async throws {
        let fixture = Fixture(Fixture.inputObservation() + Fixture.inputObservation())
        let client = try makeClient(fixture)
        let previous = try await client.observe()
        _ = try await client.observe()
        let count = fixture.requests.count
        assertUnsent(await client.act(.clear(ref: try XCTUnwrap(previous.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, count)
        let latest = await client.latestObservation
        XCTAssertNil(latest)
    }

    func testClearRejectsSecureNonInputAndDisabledNodesBeforeLookup() async throws {
        for (type, enabled) in [("XCUIElementTypeSecureTextField", true),
                                ("XCUIElementTypeButton", true), ("XCUIElementTypeTextField", false)] {
            let fixture = Fixture(Fixture.inputObservation(type: type, enabled: enabled))
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let ref = try XCTUnwrap(observation.nodes[1].ref)
            assertUnsent(await client.act(.clear(ref: ref)), kind: .unsupportedNode)
            XCTAssertEqual(fixture.requests.count, 3)
            let latest = await client.latestObservation
            XCTAssertNil(latest)
        }
    }

    func testClearRequiresUniqueFreshTargetAndConsumesRefOnLookupRefusal() async throws {
        for (matches, kind) in [(#"{"value":[]}"#, PhoneControlProblem.Kind.elementNotFound),
                                (#"{"value":[{"ELEMENT":"A"},{"ELEMENT":"B"}]}"#, .ambiguousElement)] {
            let fixture = Fixture(Fixture.inputObservation() + [Fixture.active, .json("POST", "/elements", matches)])
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            let ref = try XCTUnwrap(observation.nodes[1].ref)
            assertUnsent(await client.act(.clear(ref: ref)), kind: kind)
            assertUnsent(await client.act(.clear(ref: ref)), kind: .staleObservation)
            XCTAssertEqual(fixture.requests.count, 5)
            XCTAssertFalse(fixture.requests.contains { $0.path.hasSuffix("/clear") })
        }
    }

    func testUncertainClearBlocksReplayEvenAfterFreshObservation() async throws {
        let uncertainReplies: [(Fixture.Reply, PhoneControlProblem.Kind)] = [
            (.failure("POST", "/element/FRESH/clear", .networkConnectionLost), .transport),
            (.json("POST", "/element/FRESH/clear", "not JSON"), .malformedResponse),
            (.json("POST", "/element/FRESH/clear",
                   #"{"value":{"error":"stale element reference","message":"focus changed"}}"#, status: 404), .runner),
        ]
        for (reply, kind) in uncertainReplies {
            let fixture = Fixture(Fixture.inputObservation() + [
                Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active, reply,
            ] + Fixture.inputObservation())
            let client = try makeClient(fixture)
            let observation = try await client.observe()
            guard case .unknown(let problem) = await client.act(.clear(ref: try XCTUnwrap(observation.nodes[1].ref))) else {
                return XCTFail("Clear may have executed; its uncertainty must be retained")
            }
            XCTAssertEqual(problem.kind, kind)
            let latest = await client.latestObservation
            XCTAssertNil(latest)
            let fresh = try await client.observe()
            let freshRef = try XCTUnwrap(fresh.nodes[1].ref)
            assertUnsent(await client.act(.clear(ref: freshRef)), kind: .previousOutcomeUnknown)
            assertUnsent(await client.act(.type(ref: freshRef, text: "replacement")), kind: .previousOutcomeUnknown)
            XCTAssertEqual(fixture.requests.filter { $0.path.hasSuffix("/clear") }.count, 1)
            XCTAssertEqual(fixture.requests.filter { $0.path == "/elements" }.count, 1)
        }
    }

    func testRunnerDroppedClearRemainsUnsentAndAllowsFreshAction() async throws {
        let fixture = Fixture(Fixture.inputObservation() + [
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/clear", #"{"value":{"error":"unknown error","message":"dropped"}}"#,
                  status: 503, headers: ["X-IPU-Dropped": "1"]),
        ] + Fixture.inputObservation() + [
            Fixture.active, .json("POST", "/elements", Fixture.oneElement), Fixture.active,
            .json("POST", "/element/FRESH/clear", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        assertUnsent(await client.act(.clear(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .runner)
        let fresh = try await client.observe()
        let result = await client.act(.clear(ref: try XCTUnwrap(fresh.nodes[1].ref)))
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.filter { $0.path.hasSuffix("/clear") }.count, 2)
    }

    func testSessionTokensAreRandomAndValid() {
        let first = PhoneRunnerClient.newSessionToken()
        let second = PhoneRunnerClient.newSessionToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(RunnerSigning.validToken(first))
        XCTAssertNotEqual(first, second)
    }

    func makeClient(_ fixture: Fixture) throws -> PhoneRunnerClient {
        try PhoneRunnerClient(token: token, allowedBundleIDs: ["app.test"], port: fixture.port,
                              sessionConfiguration: fixture.configuration)
    }

    func assertUnsent(_ result: PhoneActionResult, kind: PhoneControlProblem.Kind,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .unsent(let problem) = result else {
            return XCTFail("Expected unsent, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(problem.kind, kind, file: file, line: line)
    }
}

final class RunnerPhaseTimingTests: XCTestCase {
    func testOnlySlowRunnerPhasesAreReported() {
        let phases = PhoneRunnerClient.runnerPhases(headers: [
            "X-IPU-Island-Ms": "812.4", "X-IPU-Covered-Ms": "35.06", "X-IPU-HitTest-Ms": "4.0",
            "X-IPU-Ms": "1200", "X-IPU-Queued-Ms": "300", "X-IPU-Synth-Wait-Ms": "90", "X-IPU-Pid": "42",
        ])
        XCTAssertEqual(phases, ["Island": 812.4, "Covered": 35.1])
        XCTAssertNil(PhoneRunnerClient.runnerPhases(headers: ["X-IPU-HitTest-Ms": "3"]))
    }
}
