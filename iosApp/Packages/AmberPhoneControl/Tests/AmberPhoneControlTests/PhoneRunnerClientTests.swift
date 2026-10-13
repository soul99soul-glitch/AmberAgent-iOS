import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import AmberPhoneControl

final class PhoneRunnerClientTests: XCTestCase, @unchecked Sendable {
    private let token = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

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
            .json("GET", "/wda/settle", #"{"value":{"stable":true,"waited_ms":245,"frames":9,"blank":false}}"#),
            Fixture.active,
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let stability = try await client.waitForStability()

        XCTAssertEqual(stability, PhoneScreenStability(stable: true, waitedMs: 245, frames: 9, blank: false))
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
            #"{"stable":false,"waited_ms":2000,"frames":64,"blank":false}"#,
            #"{"stable":true,"waited_ms":150,"frames":2,"blank":true}"#,
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
            .json("GET", "/wda/settle", #"{"value":{"stable":true,"waited_ms":20,"frames":2,"blank":false}}"#),
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
            .json("GET", "/wda/settle", #"{"value":{"stable":true,"waited_ms":20,"frames":2,"blank":false}}"#, gate: gate),
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

    func testOutOfScopeObservationDoesNotReadTree() async throws {
        let fixture = Fixture([.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"personal.app","pid":77}}"#)])
        let client = try makeClient(fixture)
        do { _ = try await client.observe(); XCTFail("Expected scope refusal") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appOutOfScope) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testScreenshotDecodesBase64OnlyWhenExplicitlyRequested() async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2])
        let fixture = Fixture([Fixture.active,
            .json("GET", "/screenshot", "{\"value\":\"\(png.base64EncodedString())\"}"), Fixture.active,
        ])
        let screenshot = try await makeClient(fixture).screenshot()
        XCTAssertEqual(screenshot, png)
    }

    func testFailedScreenshotInvalidatesPreviouslyObservedTargets() async throws {
        let fixture = Fixture(Fixture.observation + [Fixture.active,
            .failure("GET", "/screenshot", .networkConnectionLost),
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        do { _ = try await client.screenshot(); XCTFail("Expected screenshot failure") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .staleObservation)
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testLatestObservationInvalidatesOnFailedObserveAndStop() async throws {
        let fixture = Fixture(Fixture.observation + [.failure("GET", "/wda/activeAppInfo", .networkConnectionLost)]
                              + Fixture.observation)
        let client = try makeClient(fixture)
        let initial = await client.latestObservation
        XCTAssertNil(initial)
        _ = try await client.observe()
        do { _ = try await client.observe(); XCTFail("Expected observation failure") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        let failed = await client.latestObservation
        XCTAssertNil(failed)
        _ = try await client.observe()
        await client.stop()
        let stopped = await client.latestObservation
        XCTAssertNil(stopped)
    }

    func testSuccessfulScreenshotPreservesItsExactTreeObservation() async throws {
        let fixture = Fixture(Fixture.observation + Fixture.screenshot)
        let client = try makeClient(fixture)
        let observation = try await client.observe()
        let screenshot = try await client.screenshotObservation()
        let latest = await client.latestObservation
        XCTAssertEqual(latest?.nodes, observation.nodes)
        XCTAssertEqual(latest?.backend, observation.backend)
        XCTAssertEqual(latest?.screenBounds, .init(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(latest?.observationID, screenshot.observationID)
    }

    func testObservationCanCollectActualScreenSizeWithoutUsingRootBoundsOrTakingScreenshot() async throws {
        var replies = Fixture.popupObservation
        replies.insert(Fixture.screen, at: 2)
        let fixture = Fixture(replies)
        let client = try makeClient(fixture)
        let observation = try await client.observe(includeScreenSize: true)
        XCTAssertEqual(observation.nodes.first?.rect.height, 139)
        XCTAssertEqual(observation.screenBounds, .init(x: 0, y: 0, width: 402, height: 874))
        let latest = await client.latestObservation
        XCTAssertEqual(latest, observation)
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/source", "/window/size", "/wda/activeAppInfo"])
    }

    func testScreenSizeFailureCannotPublishFreshObservationOrKeepOldSnapshot() async throws {
        var replies = Fixture.observation
        replies.removeLast()
        replies.append(.failure("GET", "/window/size", .networkConnectionLost))
        let fixture = Fixture(Fixture.observation + replies)
        let client = try makeClient(fixture)
        _ = try await client.observe()
        do { _ = try await client.observe(includeScreenSize: true); XCTFail("Expected screen-size failure") }
        catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        let latest = await client.latestObservation
        XCTAssertNil(latest)
    }

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

    func testSessionTokensAreRandomAndValid() {
        let first = PhoneRunnerClient.newSessionToken()
        let second = PhoneRunnerClient.newSessionToken()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(RunnerSigning.validToken(first))
        XCTAssertNotEqual(first, second)
    }

    private func makeClient(_ fixture: Fixture) throws -> PhoneRunnerClient {
        try PhoneRunnerClient(token: token, allowedBundleIDs: ["app.test"], port: fixture.port,
                              sessionConfiguration: fixture.configuration)
    }

    private func assertUnsent(_ result: PhoneActionResult, kind: PhoneControlProblem.Kind,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .unsent(let problem) = result else {
            return XCTFail("Expected unsent, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(problem.kind, kind, file: file, line: line)
    }
}

private final class Fixture: @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let method: String
        let authorization: String?
        let body: Data
        let timeoutInterval: TimeInterval
        var path: String { url.path }
    }

    struct Reply: Sendable {
        let method: String
        let path: String
        let data: Data
        let status: Int
        let headers: [String: String]
        let error: URLError.Code?
        let gate: ReplyGate?

        static func json(_ method: String, _ path: String, _ json: String,
                         status: Int = 200, headers: [String: String] = [:], gate: ReplyGate? = nil) -> Reply {
            Reply(method: method, path: path, data: Data(json.utf8), status: status, headers: headers, error: nil, gate: gate)
        }
        static func failure(_ method: String, _ path: String, _ error: URLError.Code) -> Reply {
            Reply(method: method, path: path, data: Data(), status: 0, headers: [:], error: error, gate: nil)
        }
    }

    static let active = Reply.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"app.test","pid":42}}"#)
    static let oneElement = #"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#
    static var observation: [Reply] { [active, .json("GET", "/source", tree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let tree = #"{"value":{"type":"XCUIElementTypeApplication","isEnabled":"1","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"submit-button","label":"Submit","isEnabled":"1","isFocused":"0","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]}]}}"#
    static var anchoredObservation: [Reply] { [active, .json("GET", "/source", anchoredTree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let anchoredTree = #"{"value":{"type":"XCUIElementTypeApplication","isEnabled":"1","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"XCUIElementTypeButton","rawIdentifier":"submit-button","label":"Submit","isEnabled":"1","isFocused":"0","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]},{"type":"XCUIElementTypeStaticText","rawIdentifier":"question","label":"Q1","value":"Q1","isEnabled":"0","isFocused":"0","rect":{"x":20,"y":20,"width":80,"height":24},"children":[]}]}}"#
    static func inputObservation(type: String = "XCUIElementTypeTextField", enabled: Bool = true) -> [Reply] {
        let source = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":400,"height":800},"children":[{"type":"\#(type)","rawIdentifier":"query","value":"existing","isEnabled":\#(enabled),"rect":{"x":20,"y":100,"width":300,"height":44},"children":[]}]}}"#
        return [active, .json("GET", "/source", source, headers: ["X-IPU-Pid": "42"]), active]
    }
    static let popupTree = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":402,"height":139},"children":[{"type":"XCUIElementTypeWindow","rect":{"x":0,"y":0,"width":402,"height":139},"children":[{"type":"XCUIElementTypeOther","rect":{"x":0,"y":0,"width":402,"height":139},"children":[{"type":"XCUIElementTypeOther","rect":{"x":0,"y":0,"width":402,"height":139},"children":[]}]}]}]}}"#
    static var popupObservation: [Reply] { [active, .json("GET", "/source", popupTree, headers: [
        "X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0",
    ]), active] }
    static let screen = Reply.json("GET", "/window/size", #"{"value":{"width":402,"height":874}}"#)
    static let landscapeScreen = Reply.json("GET", "/window/size", #"{"value":{"width":874,"height":402}}"#)
    static let png = makePNG(width: 1206, height: 2622)
    static let image = Reply.json("GET", "/screenshot", "{\"value\":\"\(png.base64EncodedString())\"}")
    static var screenshot: [Reply] { [active, screen, image, screen, active] }
    static var pointPreflight: [Reply] { [active, screen, active] }

    static func makePNG(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    let port: UInt16
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [Request] = []
    var requests: [Request] { lock.withLock { recorded } }
    var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return config
    }

    init(_ replies: [Reply]) {
        self.replies = replies
        port = FixtureProtocol.nextPort()
        FixtureProtocol.register(self)
    }

    func reply(to request: URLRequest) -> Reply {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&bytes, maxLength: bytes.count)
                if read <= 0 { break }
                body.append(contentsOf: bytes.prefix(read))
            }
        }
        return lock.withLock {
            let item = Request(url: request.url!, method: request.httpMethod!,
                               authorization: request.value(forHTTPHeaderField: "Authorization"), body: body,
                               timeoutInterval: request.timeoutInterval)
            recorded.append(item)
            guard !replies.isEmpty else {
                XCTFail("Unexpected request \(item.method) \(item.path)")
                return .failure(item.method, item.path, .badServerResponse)
            }
            let next = replies.removeFirst()
            XCTAssertEqual(item.method, next.method)
            XCTAssertEqual(item.path, next.path)
            return next
        }
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var fixtures: [UInt16: Fixture] = [:]
        var port: UInt16 = 20_000
    }
    private static let registry = Registry()

    static func nextPort() -> UInt16 {
        registry.lock.withLock { registry.port += 1; return registry.port }
    }
    static func register(_ fixture: Fixture) {
        registry.lock.withLock { registry.fixtures[fixture.port] = fixture }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.registry.lock.withLock {
            request.url?.port.flatMap { Self.registry.fixtures[UInt16($0)] }
        }
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = fixture.reply(to: request)
        let send: @Sendable () -> Void = { [self] in
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = reply.gate { gate.enqueue(send) } else { send() }
    }
    override func stopLoading() {}
}

private final class ReplyGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Request entered fixture")
    private let lock = NSLock()
    private var send: (@Sendable () -> Void)?

    func enqueue(_ send: @escaping @Sendable () -> Void) {
        lock.withLock { self.send = send }
        started.fulfill()
    }

    func release() {
        let pending = lock.withLock { let pending = send; send = nil; return pending }
        pending?()
    }
}
