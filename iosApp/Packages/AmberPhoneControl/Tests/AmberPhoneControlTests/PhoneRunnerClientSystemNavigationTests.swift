import XCTest
@testable import AmberPhoneControl

private let springboardActive = Fixture.Reply.json(
    "GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"com.apple.springboard","pid":8}}"#
)

private var springboardObservation: [Fixture.Reply] {
    [springboardActive, .json("GET", "/source", Fixture.tree, headers: ["X-IPU-Pid": "8"]), springboardActive]
}

extension PhoneRunnerClientTests {
    func testLockStateQueryReturnsOnlyConfirmedStateAndHonorsStop() async throws {
        let fixture = Fixture([
            .json("GET", "/wda/locked", #"{"value":true}"#),
            .json("GET", "/wda/locked", #"{"value":false}"#),
        ])
        let client = try makeClient(fixture)
        let locked = try await client.screenLockState()
        let unlocked = try await client.screenLockState()
        XCTAssertTrue(locked)
        XCTAssertFalse(unlocked)
        let diagnostics = await client.latestOperationDiagnostics
        XCTAssertEqual(diagnostics?.requests.map(\.stage), [.lockState])
        await client.stop()
        do { _ = try await client.screenLockState(); XCTFail("Stopped clients cannot read lock state") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/locked", "/wda/locked"])
    }

    func testLockStateQueryRejectsMalformedStateWithoutTreatingItAsUnlocked() async throws {
        let fixture = Fixture([.json("GET", "/wda/locked", #"{"value":null}"#)])
        let client = try makeClient(fixture)
        do { _ = try await client.screenLockState(); XCTFail("Unknown lock state must not be reported as unlocked") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .malformedResponse) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testLockStateQuerySharesOperationGuardAndCannotPublishAfterStop() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("GET", "/wda/locked", #"{"value":false}"#, gate: gate)])
        let client = try makeClient(fixture)
        let query = Task { try await client.screenLockState() }
        await fulfillment(of: [gate.started], timeout: 2)
        do { _ = try await client.screenLockState(); XCTFail("Lock-state reads must not race other operations") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .busy) }
        await client.stop()
        gate.release()
        do { _ = try await query.value; XCTFail("A stopped query must not publish a stale state") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testDeviceActionsRequireExplicitSystemNavigationEvenWhenHomeWasAllowedAtInitialization() async throws {
        let fixture = Fixture([])
        let client = try PhoneRunnerClient(token: token, allowedBundleIDs: ["app.test"], port: fixture.port,
                                           allowHome: true, sessionConfiguration: fixture.configuration)
        for action in [PhoneAction.pressButton(.volumeUp), .pressButton(.volumeDown), .lockScreen, .unlockScreen] {
            assertUnsent(await client.act(action), kind: .appOutOfScope)
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testVolumeButtonsAndLockDispatchExactlyOnceAfterSystemNavigationPermission() async throws {
        let fixture = Fixture([
            .json("POST", "/wda/pressButton", #"{"value":null}"#),
            .json("POST", "/wda/pressButton", #"{"value":null}"#),
            .json("POST", "/wda/lock", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        for action in [PhoneAction.pressButton(.volumeUp), .pressButton(.volumeDown), .lockScreen] {
            let result = await client.act(action)
            XCTAssertEqual(result, .completed)
        }
        let buttonRequests = fixture.requests.filter { $0.path == "/wda/pressButton" }
        XCTAssertEqual(try buttonRequests.map { try JSONDecoder().decode(JSONValue.self, from: $0.body)["name"]?.string },
                       ["volumeUp", "volumeDown"])
        XCTAssertEqual(fixture.requests.filter { $0.method == "POST" }.count, 3)
    }

    func testExplicitSystemActionsCanRunAfterObservingAnAppOutsideScope() async throws {
        for (action, path) in [(PhoneAction.home, "/wda/homescreen"), (.pressButton(.volumeUp), "/wda/pressButton"),
                               (.lockScreen, "/wda/lock")] {
            let outside = Fixture.Reply.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"app.outside","pid":99}}"#)
            let fixture = Fixture([outside, .json("POST", path, #"{"value":null}"#), outside, outside])
            let client = try makeClient(fixture)
            do { _ = try await client.observe(); XCTFail("The foreground app must remain outside the app scope") }
            catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appOutOfScope) }
            try await client.allowSystemNavigation()
            let result = await client.act(action)
            XCTAssertEqual(result, .completed)
            do { _ = try await client.observe(); XCTFail("Global actions must not expand element observation scope") }
            catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appOutOfScope) }
            do { _ = try await client.screenshot(); XCTFail("Global actions must not expand screenshot scope") }
            catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appOutOfScope) }
            XCTAssertEqual(fixture.requests.filter { $0.method == "POST" }.map(\.path), [path])
        }
    }

    func testLegacyHomePermissionStillRequiresForegroundAppScope() async throws {
        let fixture = Fixture([.json("GET", "/wda/activeAppInfo", #"{"value":{"bundleId":"app.outside","pid":99}}"#)])
        let client = try PhoneRunnerClient(token: token, allowedBundleIDs: ["app.test"], port: fixture.port,
                                           allowHome: true, sessionConfiguration: fixture.configuration)
        assertUnsent(await client.act(.home), kind: .appOutOfScope)
        XCTAssertFalse(fixture.requests.contains { $0.method == "POST" })
    }

    func testUnlockReadsLockStateAndDoesNotDispatchWhenAlreadyUnlocked() async throws {
        let fixture = Fixture([.json("GET", "/wda/locked", #"{"value":false}"#)])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        let result = await client.act(.unlockScreen)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/locked"])
    }

    func testUnlockDispatchesOnlyAfterConfirmedLockedState() async throws {
        let fixture = Fixture([
            .json("GET", "/wda/locked", #"{"value":true}"#),
            .json("POST", "/wda/unlock", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        let result = await client.act(.unlockScreen)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/locked", "/wda/unlock"])
    }

    func testUnlockPasscodeRefusalIsUnsentAndDoesNotBlockNextExplicitAction() async throws {
        let fixture = Fixture([
            .json("GET", "/wda/locked", #"{"value":true}"#),
            .json("POST", "/wda/unlock", #"{"value":{"error":"unknown error","message":"passcode_required: unlock it in hand"}}"#,
                  status: 409, headers: ["X-IPU-Dropped": "1"]),
            .json("GET", "/wda/locked", #"{"value":false}"#),
        ])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        let result = await client.act(.unlockScreen)
        guard case .unsent(let problem) = result else { return XCTFail("Expected explicit pre-execution refusal") }
        XCTAssertEqual(problem.statusCode, 409)
        XCTAssertTrue(problem.message.contains("passcode_required"))
        XCTAssertTrue(problem.wasDroppedBeforeExecution)
        let afterManualUnlock = await client.act(.unlockScreen)
        XCTAssertEqual(afterManualUnlock, .completed)
        XCTAssertEqual(fixture.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testLostDeviceActionResponseBlocksFurtherDeviceActionsWithoutReplay() async throws {
        for action in [PhoneAction.pressButton(.volumeUp), .lockScreen, .unlockScreen] {
            let replies: [Fixture.Reply]
            switch action {
            case .pressButton: replies = [.failure("POST", "/wda/pressButton", .timedOut)]
            case .lockScreen: replies = [.failure("POST", "/wda/lock", .timedOut)]
            default: replies = [.json("GET", "/wda/locked", #"{"value":true}"#), .failure("POST", "/wda/unlock", .timedOut)]
            }
            let fixture = Fixture(replies)
            let client = try makeClient(fixture)
            try await client.allowSystemNavigation()
            guard case .unknown = await client.act(action) else { return XCTFail("Expected unknown after response loss") }
            assertUnsent(await client.act(.unlockScreen), kind: .previousOutcomeUnknown)
            XCTAssertEqual(fixture.requests.count, replies.count)
        }
    }

    func testUnlockPreflightCanBeStoppedAndCannotBeOvertakenByAnotherAction() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("GET", "/wda/locked", #"{"value":true}"#, gate: gate)])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        let unlock = Task { await client.act(.unlockScreen) }
        await fulfillment(of: [gate.started], timeout: 2)
        assertUnsent(await client.act(.lockScreen), kind: .busy)
        await client.stop()
        gate.release()
        assertUnsent(await unlock.value, kind: .stopped)
        assertUnsent(await client.act(.pressButton(.volumeDown)), kind: .stopped)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testUnlockWithUnreadableLockStateDoesNotDispatch() async throws {
        let fixture = Fixture([.json("GET", "/wda/locked", #"{"value":null}"#)])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        assertUnsent(await client.act(.unlockScreen), kind: .malformedResponse)
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/locked"])
    }

    func testSystemNavigationIsOutsideDefaultRunScope() async throws {
        let fixture = Fixture([springboardActive])
        let client = try makeClient(fixture)
        assertUnsent(await client.act(.home), kind: .appOutOfScope)
        do { _ = try await client.observe(); XCTFail("SpringBoard must require explicit scope") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .appOutOfScope) }
        XCTAssertEqual(fixture.requests.map(\.path), ["/wda/activeAppInfo"])
    }

    func testExplicitSystemNavigationAllowsHomeAndFreshTreeAndScreenshotActions() async throws {
        let fixture = Fixture([
            .json("POST", "/wda/homescreen", #"{"value":null}"#),
        ] + springboardObservation + [
            springboardActive, .json("POST", "/elements", Fixture.oneElement), springboardActive,
            .json("POST", "/element/FRESH/click", #"{"value":null}"#),
        ] + springboardObservation + [
            springboardActive, Fixture.screen, Fixture.image, Fixture.screen, springboardActive,
            springboardActive, Fixture.screen, springboardActive,
            .json("POST", "/tap", #"{"value":null}"#),
        ])
        let client = try makeClient(fixture)
        try await client.allowSystemNavigation()
        let home = await client.act(.home)
        XCTAssertEqual(home, .completed)
        let first = try await client.observe()
        XCTAssertEqual(first.bundleID, "com.apple.springboard")
        XCTAssertEqual(first.processID, 8)
        let tap = await client.act(.tap(ref: try XCTUnwrap(first.nodes[1].ref)))
        XCTAssertEqual(tap, .completed)

        let second = try await client.observe()
        XCTAssertNotEqual(second.observationID, first.observationID)
        let screenshot = try await client.screenshotObservation()
        XCTAssertEqual(screenshot.observationID, second.observationID)
        let visualTap = await client.act(.tapPoint(observationID: screenshot.observationID, x: 0.5, y: 0.5))
        XCTAssertEqual(visualTap, .completed)
        XCTAssertEqual(fixture.requests.filter { $0.method == "POST" }.map(\.path),
                       ["/wda/homescreen", "/elements", "/element/FRESH/click", "/tap"])
    }

    func testAllowingSystemNavigationDoesNotAuthorizeAnOldAppReferenceOnSpringBoard() async throws {
        let fixture = Fixture(Fixture.observation + [springboardActive] + springboardObservation)
        let client = try makeClient(fixture)
        let appObservation = try await client.observe()
        let oldRef = try XCTUnwrap(appObservation.nodes[1].ref)
        try await client.allowSystemNavigation()
        assertUnsent(await client.act(.tap(ref: oldRef)), kind: .appChanged)
        _ = try await client.observe()
        assertUnsent(await client.act(.tap(ref: oldRef)), kind: .staleObservation)
        XCTAssertFalse(fixture.requests.contains { $0.method == "POST" })
    }

    func testStoppedRunCannotAllowSystemNavigation() async throws {
        let fixture = Fixture([])
        let client = try makeClient(fixture)
        await client.stop()
        do { try await client.allowSystemNavigation(); XCTFail("Stopped scope must not be revived") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .stopped) }
        assertUnsent(await client.act(.home), kind: .stopped)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testUnknownOutcomeCannotAllowSystemNavigation() async throws {
        let fixture = Fixture([.failure("POST", "/wda/apps/activate", .timedOut)])
        let client = try makeClient(fixture)
        guard case .unknown = await client.act(.launch(bundleID: "app.test")) else {
            return XCTFail("Expected an unknown action outcome")
        }
        do { try await client.allowSystemNavigation(); XCTFail("Unknown outcome must prevent scope changes") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .previousOutcomeUnknown) }
        assertUnsent(await client.act(.home), kind: .previousOutcomeUnknown)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testSystemNavigationCannotBeAllowedDuringAnInFlightAction() async throws {
        let gate = ReplyGate()
        let fixture = Fixture([.json("POST", "/wda/apps/activate", #"{"value":null}"#, gate: gate)])
        let client = try makeClient(fixture)
        let action = Task { await client.act(.launch(bundleID: "app.test")) }
        await fulfillment(of: [gate.started], timeout: 2)
        do { try await client.allowSystemNavigation(); XCTFail("Scope must remain fixed during an operation") }
        catch let problem as PhoneControlProblem { XCTAssertEqual(problem.kind, .busy) }
        gate.release()
        let result = await action.value
        XCTAssertEqual(result, .completed)
        assertUnsent(await client.act(.home), kind: .appOutOfScope)
        XCTAssertEqual(fixture.requests.count, 1)
    }
}
