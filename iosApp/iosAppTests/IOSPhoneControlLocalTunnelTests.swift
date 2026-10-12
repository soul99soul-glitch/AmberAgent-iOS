import Foundation
import NetworkExtension
import XCTest
@testable import iosApp

@MainActor
final class IOSPhoneControlLocalTunnelTests: XCTestCase {
    func testPreparationDoesNotConnect() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.hasConfiguration = false
        let tunnel = makeTunnel(driver)
        try await tunnel.prepare()
        XCTAssertTrue(tunnel.isPrepared)
        XCTAssertEqual(tunnel.state, .ready)
        XCTAssertEqual(driver.prepareCount, 1)
        XCTAssertEqual(driver.startCount, 0)
    }

    func testMissingConfigurationDoesNotCreateOrConnect() async {
        let driver = FakePhoneControlTunnelDriver()
        driver.hasConfiguration = false
        let tunnel = makeTunnel(driver)
        do {
            try await tunnel.start(owner: UUID())
            XCTFail("A missing configuration must require explicit preparation")
        } catch {
            XCTAssertTrue(error is IOSPhoneControlLocalTunnelError)
        }
        XCTAssertFalse(tunnel.isPrepared)
        XCTAssertEqual(driver.prepareCount, 0)
        XCTAssertEqual(driver.enableCount, 0)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
    }

    func testExistingDisabledConfigurationIsEnabledWithoutCreatingOne() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.isEnabled = false
        driver.startStatus = .connected
        let tunnel = makeTunnel(driver)
        let owner = UUID()
        try await tunnel.start(owner: owner)
        XCTAssertEqual(driver.enableCount, 1)
        XCTAssertEqual(driver.prepareCount, 0)
        XCTAssertEqual(tunnel.state, .connected)
        let stopped = await tunnel.stop(owner: owner)
        XCTAssertTrue(stopped)
    }

    func testStartWaitsForActualConnectedStatus() async throws {
        let driver = FakePhoneControlTunnelDriver()
        let tunnel = makeTunnel(driver)
        let owner = UUID()
        let start = Task { try await tunnel.start(owner: owner) }
        await waitUntil { driver.startCount == 1 }
        XCTAssertEqual(tunnel.state, .connecting)
        driver.status = .connected
        try await start.value
        XCTAssertEqual(tunnel.state, .connected)
        let stopped = await tunnel.stop(owner: owner)
        XCTAssertTrue(stopped)
    }

    func testStartWaitsForInFlightSettingsRefresh() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.pauseLoad = true
        driver.startStatus = .connected
        let tunnel = makeTunnel(driver)
        let refresh = Task { await tunnel.refresh() }
        await waitUntil { driver.loadContinuation != nil }
        let owner = UUID()
        let start = Task { try await tunnel.start(owner: owner) }
        await Task.yield()
        XCTAssertEqual(driver.startCount, 0)
        driver.resumeLoad()
        await refresh.value
        try await start.value
        XCTAssertEqual(tunnel.state, .connected)
        _ = await tunnel.stop(owner: owner)
    }

    func testCancellationDuringLoadCannotStartLate() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.pauseLoad = true
        let tunnel = makeTunnel(driver)
        let owner = UUID()
        let start = Task { try await tunnel.start(owner: owner) }
        await waitUntil { driver.loadContinuation != nil }
        start.cancel()
        driver.resumeLoad()
        do {
            try await start.value
            XCTFail("Cancelled loading must not start the tunnel")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
        driver.startStatus = .connected
        let next = UUID()
        try await tunnel.start(owner: next)
        let stopped = await tunnel.stop(owner: next)
        XCTAssertTrue(stopped)
    }

    func testCancellationDuringEnableCannotStartLate() async {
        let driver = FakePhoneControlTunnelDriver()
        driver.isEnabled = false
        driver.pauseEnable = true
        let tunnel = makeTunnel(driver)
        let start = Task { try await tunnel.start(owner: UUID()) }
        await waitUntil { driver.enableContinuation != nil }
        start.cancel()
        driver.resumeEnable()
        do {
            try await start.value
            XCTFail("Cancellation must be checked again after preferences finish saving")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.enableCount, 1)
        XCTAssertEqual(driver.prepareCount, 0)
        XCTAssertEqual(driver.startCount, 0)
    }

    func testCancellationWhileConnectingDisconnects() async {
        let driver = FakePhoneControlTunnelDriver()
        let tunnel = makeTunnel(driver)
        let start = Task { try await tunnel.start(owner: UUID()) }
        await waitUntil { driver.startCount == 1 }
        start.cancel()
        do {
            try await start.value
            XCTFail("Cancelled connection must not finish successfully")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(tunnel.state, .ready)
    }

    func testStaleOwnerCannotStopNewConnection() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.startStatus = .connected
        let tunnel = makeTunnel(driver)
        let oldOwner = UUID()
        try await tunnel.start(owner: oldOwner)
        _ = await tunnel.stop(owner: oldOwner)
        let newOwner = UUID()
        try await tunnel.start(owner: newOwner)
        let oldOwnerStopped = await tunnel.stop(owner: oldOwner)
        XCTAssertFalse(oldOwnerStopped)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(tunnel.state, .connected)
        _ = await tunnel.stop(owner: newOwner)
        XCTAssertEqual(driver.stopCount, 2)
    }

    func testStopWaitsForActualDisconnectAndBlocksAnotherOwner() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.startStatus = .connected
        driver.stopStatus = .disconnecting
        let tunnel = makeTunnel(driver)
        let owner = UUID()
        try await tunnel.start(owner: owner)
        let stop = Task { await tunnel.stop(owner: owner) }
        await waitUntil { driver.stopCount == 1 }
        XCTAssertEqual(tunnel.state, .disconnecting)
        do {
            try await tunnel.start(owner: UUID())
            XCTFail("Another owner must wait for teardown")
        } catch {
            XCTAssertTrue(error is IOSPhoneControlLocalTunnelError)
        }
        driver.status = .disconnected
        let stopped = await stop.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(tunnel.state, .ready)
    }

    func testConnectionTimeoutStopsInsteadOfReportingConnected() async {
        let driver = FakePhoneControlTunnelDriver()
        let tunnel = IOSPhoneControlLocalTunnel(driver: driver,
            connectionTimeout: .milliseconds(30), pollInterval: .milliseconds(1))
        do {
            try await tunnel.start(owner: UUID())
            XCTFail("An indefinitely connecting tunnel must time out")
        } catch {
            XCTAssertEqual(error as? IOSPhoneControlLocalTunnelError, .connectionTimedOut)
        }
        XCTAssertEqual(driver.stopCount, 1)
        if case .failed = tunnel.state {} else { XCTFail("Timeout must remain visible") }
    }

    func testDisconnectionTimeoutIsReported() async throws {
        let driver = FakePhoneControlTunnelDriver()
        driver.startStatus = .connected
        driver.stopStatus = .disconnecting
        let tunnel = IOSPhoneControlLocalTunnel(driver: driver,
            connectionTimeout: .milliseconds(30), pollInterval: .milliseconds(1))
        let owner = UUID()
        try await tunnel.start(owner: owner)
        let stopped = await tunnel.stop(owner: owner)
        XCTAssertFalse(stopped)
        let stoppedAgain = await tunnel.stop(owner: owner)
        XCTAssertFalse(stoppedAgain)
        XCTAssertEqual(driver.stopCount, 1)
        if case .failed = tunnel.state {} else { XCTFail("Incomplete teardown must remain visible") }
    }

    func testStartFailureCleanupTimeoutCannotReportDisconnected() async {
        let driver = FakePhoneControlTunnelDriver()
        driver.stopStatus = .disconnecting
        let tunnel = IOSPhoneControlLocalTunnel(driver: driver,
            connectionTimeout: .milliseconds(30), pollInterval: .milliseconds(1))
        let owner = UUID()
        do {
            try await tunnel.start(owner: owner)
            XCTFail("Connection must time out")
        } catch {
            XCTAssertEqual(error as? IOSPhoneControlLocalTunnelError, .connectionTimedOut)
        }
        let stoppedAgain = await tunnel.stop(owner: owner)
        XCTAssertFalse(stoppedAgain)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(tunnel.state, .failed(IOSPhoneControlLocalTunnelError.connectionTimedOut.localizedDescription))
    }

    func testUnclaimedTransitionCannotBeReportedAsDisconnected() async {
        for status in [NEVPNStatus.connecting, .reasserting, .disconnecting] {
            let driver = FakePhoneControlTunnelDriver()
            driver.status = status
            let tunnel = makeTunnel(driver)
            let owner = UUID()
            do {
                try await tunnel.start(owner: owner)
                XCTFail("An existing transition cannot be claimed")
            } catch {
                XCTAssertEqual(error as? IOSPhoneControlLocalTunnelError, .connectionBusy)
            }
            let stopped = await tunnel.stop(owner: owner)
            XCTAssertFalse(stopped)
            XCTAssertEqual(driver.startCount, 0)
            XCTAssertEqual(driver.stopCount, 0)
            XCTAssertEqual(tunnel.state, .failed(IOSPhoneControlLocalTunnelError.connectionBusy.localizedDescription))
        }
    }

    private func makeTunnel(_ driver: FakePhoneControlTunnelDriver) -> IOSPhoneControlLocalTunnel {
        IOSPhoneControlLocalTunnel(driver: driver, connectionTimeout: .seconds(1), pollInterval: .milliseconds(1))
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "Expected operation did not begin", file: file, line: line)
    }
}

@MainActor
private final class FakePhoneControlTunnelDriver: IOSPhoneControlTunnelDriver {
    var status: NEVPNStatus = .disconnected
    var isEnabled = true
    var hasConfiguration = true
    var startStatus: NEVPNStatus = .connecting
    var stopStatus: NEVPNStatus = .disconnected
    var prepareCount = 0
    var enableCount = 0
    var startCount = 0
    var stopCount = 0
    var pauseLoad = false
    var pauseEnable = false
    var loadContinuation: CheckedContinuation<Void, Never>?
    var enableContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> Bool {
        if pauseLoad { await withCheckedContinuation { loadContinuation = $0 } }
        return hasConfiguration
    }
    func prepare() async throws {
        prepareCount += 1
        hasConfiguration = true
        isEnabled = true
    }
    func enableExisting() async throws {
        enableCount += 1
        if pauseEnable { await withCheckedContinuation { enableContinuation = $0 } }
        isEnabled = true
    }
    func start() throws {
        startCount += 1
        status = startStatus
    }
    func stop() {
        stopCount += 1
        status = stopStatus
    }
    func resumeLoad() {
        pauseLoad = false
        loadContinuation?.resume()
        loadContinuation = nil
    }
    func resumeEnable() {
        pauseEnable = false
        enableContinuation?.resume()
        enableContinuation = nil
    }
}
