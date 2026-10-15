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

    func testDisconnectedStartReportsProviderErrorBeforeCleanup() async {
        let driver = FakePhoneControlTunnelDriver()
        let providerError = NSError(domain: "AmberPhoneControlTunnel", code: 91,
            userInfo: [NSLocalizedDescriptionKey: "设置本机路由失败"])
        driver.disconnectError = providerError
        let tunnel = makeTunnel(driver)
        let start = Task { try await tunnel.start(owner: UUID()) }
        await waitUntil { driver.startCount == 1 }
        driver.status = .disconnected
        do {
            try await start.value
            XCTFail("A disconnected start must fail")
        } catch {
            let diagnostic = error as NSError
            XCTAssertTrue(diagnostic.localizedDescription.contains("等待 VPN 连接"))
            XCTAssertTrue(diagnostic.localizedDescription.contains("NEVPNStatus=disconnected"))
            XCTAssertTrue(diagnostic.localizedDescription.contains("AmberPhoneControlTunnel"))
            XCTAssertTrue(diagnostic.localizedDescription.contains("91"))
            XCTAssertTrue(diagnostic.localizedDescription.contains("设置本机路由失败"))
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError, providerError)
            XCTAssertEqual(tunnel.state, .failed(diagnostic.localizedDescription))
        }
        XCTAssertEqual(driver.disconnectErrorFetchCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertNil(driver.disconnectError)
    }

    func testSystemStartErrorIncludesItsStageAndOriginalCause() async {
        let driver = FakePhoneControlTunnelDriver()
        let systemError = NSError(domain: NEVPNErrorDomain, code: 1,
            userInfo: [NSLocalizedDescriptionKey: "配置不可用"])
        driver.startError = systemError
        let tunnel = makeTunnel(driver)
        do {
            try await tunnel.start(owner: UUID())
            XCTFail("A rejected VPN start must fail")
        } catch {
            let diagnostic = error as NSError
            XCTAssertTrue(diagnostic.localizedDescription.contains("启动 VPN 扩展"))
            XCTAssertTrue(diagnostic.localizedDescription.contains(NEVPNErrorDomain))
            XCTAssertEqual(diagnostic.domain, systemError.domain)
            XCTAssertEqual(diagnostic.code, systemError.code)
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError, systemError)
        }
        XCTAssertEqual(driver.disconnectErrorFetchCount, 0)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testDisconnectedStartWithoutSystemReasonStillReportsItsStatus() async {
        let driver = FakePhoneControlTunnelDriver()
        let tunnel = makeTunnel(driver)
        let start = Task { try await tunnel.start(owner: UUID()) }
        await waitUntil { driver.startCount == 1 }
        driver.status = .disconnected
        do {
            try await start.value
            XCTFail("A disconnected start must fail even without a provider reason")
        } catch {
            let diagnostic = error as NSError
            XCTAssertTrue(diagnostic.localizedDescription.contains("等待 VPN 连接"))
            XCTAssertTrue(diagnostic.localizedDescription.contains("NEVPNStatus=disconnected"))
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError,
                IOSPhoneControlLocalTunnelError.connectionFailed as NSError)
        }
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testCancellationDuringDisconnectDiagnosisRemainsCancellation() async {
        let driver = FakePhoneControlTunnelDriver()
        driver.pauseDisconnectError = true
        let tunnel = makeTunnel(driver)
        let start = Task { try await tunnel.start(owner: UUID()) }
        await waitUntil { driver.startCount == 1 }
        driver.status = .disconnected
        await waitUntil { driver.disconnectErrorContinuation != nil }
        start.cancel()
        driver.resumeDisconnectError()
        do {
            try await start.value
            XCTFail("Cancellation must not become a VPN error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(tunnel.state, .ready)
    }

    func testLoadFailureReportsConfigurationReadStageWithoutStarting() async {
        let driver = FakePhoneControlTunnelDriver()
        let systemError = NSError(domain: NEVPNErrorDomain, code: 5,
            userInfo: [NSLocalizedDescriptionKey: "无法读取配置"])
        driver.loadError = systemError
        let tunnel = makeTunnel(driver)
        do {
            try await tunnel.start(owner: UUID())
            XCTFail("Loading a rejected configuration must fail")
        } catch {
            let diagnostic = error as NSError
            XCTAssertTrue(diagnostic.localizedDescription.contains("读取 VPN 配置"))
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError, systemError)
        }
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
    }

    func testEnableFailureReportsConfigurationEnableStageWithoutStarting() async {
        let driver = FakePhoneControlTunnelDriver()
        driver.isEnabled = false
        let systemError = NSError(domain: NEVPNErrorDomain, code: 3,
            userInfo: [NSLocalizedDescriptionKey: "无法保存配置"])
        driver.enableError = systemError
        let tunnel = makeTunnel(driver)
        do {
            try await tunnel.start(owner: UUID())
            XCTFail("Enabling a rejected configuration must fail")
        } catch {
            let diagnostic = error as NSError
            XCTAssertTrue(diagnostic.localizedDescription.contains("启用 VPN 配置"))
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError, systemError)
        }
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.stopCount, 0)
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
            let diagnostic = error as NSError
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError,
                IOSPhoneControlLocalTunnelError.connectionTimedOut as NSError)
            XCTAssertTrue(diagnostic.localizedDescription.contains("等待 VPN 连接"))
            XCTAssertTrue(diagnostic.localizedDescription.contains("NEVPNStatus=connecting"))
        }
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(driver.disconnectErrorFetchCount, 0)
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
            let diagnostic = error as NSError
            XCTAssertEqual(diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError,
                IOSPhoneControlLocalTunnelError.connectionTimedOut as NSError)
            XCTAssertEqual(tunnel.state, .failed(diagnostic.localizedDescription))
        }
        let stoppedAgain = await tunnel.stop(owner: owner)
        XCTAssertFalse(stoppedAgain)
        XCTAssertEqual(driver.stopCount, 1)
        if case .failed = tunnel.state {} else { XCTFail("Startup failure must remain visible") }
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
    var loadError: NSError?
    var enableError: NSError?
    var startError: NSError?
    var disconnectError: NSError?
    var disconnectErrorFetchCount = 0
    var pauseLoad = false
    var pauseEnable = false
    var pauseDisconnectError = false
    var loadContinuation: CheckedContinuation<Void, Never>?
    var enableContinuation: CheckedContinuation<Void, Never>?
    var disconnectErrorContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> Bool {
        if pauseLoad { await withCheckedContinuation { loadContinuation = $0 } }
        if let loadError { throw loadError }
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
        if let enableError { throw enableError }
        isEnabled = true
    }
    func start() throws {
        startCount += 1
        if let startError { throw startError }
        status = startStatus
    }
    func stop() {
        stopCount += 1
        disconnectError = nil
        status = stopStatus
    }
    func lastDisconnectError() async -> NSError? {
        disconnectErrorFetchCount += 1
        if pauseDisconnectError { await withCheckedContinuation { disconnectErrorContinuation = $0 } }
        return disconnectError
    }
    func resumeDisconnectError() {
        pauseDisconnectError = false
        disconnectErrorContinuation?.resume()
        disconnectErrorContinuation = nil
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
