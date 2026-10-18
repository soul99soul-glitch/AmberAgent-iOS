import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import AmberPhoneControl

extension PhoneRunnerClientTests {
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
        XCTAssertNil(observation.screenStability)
        XCTAssertEqual(observation.diagnostics?.httpRequestCount, 4)
        XCTAssertEqual(observation.diagnostics?.requests.map(\.stage), [.activeApp, .source, .screenSize, .activeApp])
    }

    func testSettledObservationUsesOneExtraRequestAndKeepsStabilitySeparateFromContent() async throws {
        let fixture = Fixture([
            Fixture.active, Fixture.settle(stable: true, blank: true),
            .json("GET", "/source", Fixture.tree, headers: [
                "X-IPU-Pid": "42", "X-IPU-Ms": "12", "X-IPU-Queued-Ms": "3",
            ]), Fixture.screen, Fixture.active,
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe(includeScreenSize: true, settleBudgetMs: 800)
        XCTAssertEqual(observation.screenStability, PhoneScreenStability(
            stable: true, blank: true, waitedMs: 180, frames: 6,
            changedPixels: 0, captureMs: 4, budgetMs: 800
        ))
        XCTAssertEqual(observation.nodes[1].label, "Submit")
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/wda/settle", "/source", "/window/size", "/wda/activeAppInfo"])
        let settle = try XCTUnwrap(fixture.requests.first { $0.path == "/wda/settle" })
        XCTAssertEqual(settle.url.query, "budget_ms=800")
        XCTAssertEqual(settle.timeoutInterval, 2.8, accuracy: 0.001)
        let diagnostics = try XCTUnwrap(observation.diagnostics)
        XCTAssertEqual(diagnostics.httpRequestCount, 5)
        XCTAssertEqual(diagnostics.requests.map(\.stage), [.activeApp, .settle, .source, .screenSize, .activeApp])
        XCTAssertEqual(diagnostics.requests[1].runnerMs, 182.5)
        XCTAssertEqual(diagnostics.requests[2].runnerMs, 12)
        XCTAssertEqual(diagnostics.requests[2].queuedMs, 3)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(diagnostics))
        XCTAssertEqual(encoded["httpRequestCount"]?.number, 5)
        XCTAssertEqual(encoded["operation"]?.string, "observe")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self).contains("Submit"))
        let latestDiagnostics = await client.latestOperationDiagnostics
        XCTAssertEqual(latestDiagnostics?.requests, diagnostics.requests)
    }

    func testUnstableObservationStillReadsFreshTreeWithoutRetryingOrChangingActionResult() async throws {
        let fixture = Fixture([
            Fixture.active, Fixture.settle(stable: false, blank: false),
            .json("GET", "/source", Fixture.tree, headers: ["X-IPU-Pid": "42"]), Fixture.active,
        ])
        let client = try makeClient(fixture)
        let observation = try await client.observe(settleBudgetMs: 800)
        XCTAssertEqual(observation.screenStability?.stable, false)
        XCTAssertEqual(observation.screenStability?.blank, false)
        XCTAssertEqual(observation.diagnostics?.httpRequestCount, 4)
        XCTAssertEqual(fixture.requests.filter { $0.path == "/wda/settle" }.count, 1)
        XCTAssertFalse(fixture.requests.contains { $0.method == "POST" })
    }

    func testInvalidSettleBudgetRejectsWithoutReadingAndInvalidatesOldReferences() async throws {
        for budget in [-1, 0, 49, 15_001, Int.max] {
            let fixture = Fixture(Fixture.observation)
            let client = try makeClient(fixture)
            _ = try await client.observe()
            do {
                _ = try await client.observe(settleBudgetMs: budget)
                XCTFail("Invalid settle budget should fail")
            } catch let problem as PhoneControlProblem {
                XCTAssertEqual(problem.kind, .invalidConfiguration)
            }
            XCTAssertEqual(fixture.requests.count, 3)
            let latest = await client.latestObservation
            XCTAssertNil(latest)
            let diagnostics = await client.latestOperationDiagnostics
            XCTAssertEqual(diagnostics?.httpRequestCount, 0)
        }
    }

    func testSettleStopAndConcurrentOperationDoNotReadSourceOrOvertakeWait() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([
            Fixture.active, Fixture.settle(gate: gate),
        ])
        let client = try makeClient(fixture)
        let waiting = Task { try await client.observe(settleBudgetMs: 800) }
        await fulfillment(of: [gate.started], timeout: 2)
        assertUnsent(await client.act(.launch(bundleID: "app.test")), kind: .busy)
        await client.stop()
        gate.release()
        do {
            _ = try await waiting.value
            XCTFail("Stopped settle should fail")
        } catch let problem as PhoneControlProblem {
            XCTAssertEqual(problem.kind, .stopped)
        }
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo", "/wda/settle"])
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        let diagnostics = await client.latestOperationDiagnostics
        XCTAssertEqual(diagnostics?.httpRequestCount, 2)
    }

    func testCancellationDuringSettlePreventsSourceAndKeepsClientReusable() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([Fixture.active, Fixture.settle(gate: gate)] + Fixture.observation)
        let client = try makeClient(fixture)
        let waiting = Task { try await client.observe(settleBudgetMs: 800) }
        await fulfillment(of: [gate.started], timeout: 2)
        waiting.cancel()
        gate.release()
        do {
            _ = try await waiting.value
            XCTFail("Cancelled settle should fail")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(fixture.requests.count, 2)
        let latest = await client.latestObservation
        XCTAssertNil(latest)
        _ = try await client.observe()
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testSettledObservationRejectsOutOfScopeAndChangedForeground() async throws {
        let outside = Fixture([.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"other.app","pid":9}}"#)])
        let outsideClient = try makeClient(outside)
        do {
            _ = try await outsideClient.observe(settleBudgetMs: 800)
            XCTFail("Out-of-scope settle should fail")
        } catch let problem as PhoneControlProblem {
            XCTAssertEqual(problem.kind, .appOutOfScope)
        }
        XCTAssertEqual(outside.requests.count, 1)

        let changed = Fixture([
            Fixture.active, Fixture.settle(),
            .json("GET", "/source", Fixture.tree, headers: ["X-IPU-Pid": "43"]),
        ])
        let changedClient = try makeClient(changed)
        do {
            _ = try await changedClient.observe(settleBudgetMs: 800)
            XCTFail("Changed foreground should fail")
        } catch let problem as PhoneControlProblem {
            XCTAssertEqual(problem.kind, .appChanged)
        }
        let latest = await changedClient.latestObservation
        XCTAssertNil(latest)
        XCTAssertEqual(changed.requests.count, 3)
    }

    func testSettleReadCannotClearUnknownActionOutcome() async throws {
        let fixture = Fixture([
            .failure("POST", "/wda/apps/activate", .networkConnectionLost),
            Fixture.active, Fixture.settle(),
            .json("GET", "/source", Fixture.tree, headers: ["X-IPU-Pid": "42"]), Fixture.active,
        ])
        let client = try makeClient(fixture)
        guard case .unknown = await client.act(.launch(bundleID: "app.test")) else { return XCTFail("Expected unknown") }
        let observation = try await client.observe(settleBudgetMs: 800)
        XCTAssertEqual(observation.screenStability?.stable, true)
        assertUnsent(await client.act(.tap(ref: try XCTUnwrap(observation.nodes[1].ref))), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testMalformedOrFailedSettleDoesNotFallBackToTreeOrRetainReferences() async throws {
        let replies: [Fixture.Reply] = [
            .json("GET", "/wda/settle", #"{"value":{"stable":true}}"#),
            .json("GET", "/wda/settle", #"{"value":{"error":"capture unavailable"}}"#),
            .failure("GET", "/wda/settle", .timedOut),
        ]
        for reply in replies {
            let fixture = Fixture(Fixture.observation + [Fixture.active, reply])
            let client = try makeClient(fixture)
            _ = try await client.observe()
            do {
                _ = try await client.observe(settleBudgetMs: 800)
                XCTFail("Invalid settle should fail")
            } catch {}
            XCTAssertEqual(fixture.requests.count, 5)
            let latest = await client.latestObservation
            XCTAssertNil(latest)
            let diagnostics = await client.latestOperationDiagnostics
            XCTAssertEqual(diagnostics?.httpRequestCount, 2)
        }
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

}
