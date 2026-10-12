import Foundation
import AmberPhoneControl
import AmberIPhoneControl

enum IOSPhoneControlLoopbackRoute {
    // Amber's local tunnel peer. Native sockets bind to its 10.7.1.1 utun
    // interface; an inactive tunnel must never fall through to a LAN route.
    static let endpoint = "10.7.0.1:49152"
    // Legacy settings URL; unused after embedded-tunnel integration.
    static let appURL = URL(string: "localdevvpn://")!
}

/// Launch-argument-only diagnostic sharing the production route and greeting,
/// without credentials. Neither settings nor a model can invoke it.
enum IOSPhoneControlHandshakeInspection {
    static let diagnosticLaunchArgument = "-amber-phone-handshake-inspection-once"
    static let routedDiagnosticLaunchArgument = "-amber-phone-routed-handshake-inspection-once"

    @MainActor
    static func runOnce(source: String = "existing_local_tunnel", inspectCurrentRoute: Bool = false) async {
        IOSBackgroundLifecycleLog.record("phoneControlHandshakeInspectionStarted")
        guard !Task.isCancelled else { return }
        let endpoint = IOSPhoneControlLoopbackRoute.endpoint
        IOSBackgroundLifecycleLog.record("phoneControlHandshakeInspectionEndpoint", detail: "source=\(source) family=ipv4 port=49152")
        let detail = await Task.detached {
            let handle = endpoint.withCString {
                inspectCurrentRoute
                    ? amber_iphone_control_inspect_routed_handshake($0)
                    : amber_iphone_control_inspect_handshake($0)
            }
            guard let handle else { return "result=no_handle" }
            defer { amber_iphone_control_free(handle) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                guard let pointer = amber_iphone_control_status_json(handle) else { return "result=no_status" }
                let data = Data(String(cString: pointer).utf8)
                amber_iphone_control_string_free(pointer)
                guard let status = try? JSONDecoder().decode(PhoneControlLaunchStatus.self, from: data) else {
                    return "result=invalid_status"
                }
                if status.phase == "stopped" || status.phase == "failed" {
                    return "phase=\(status.phase) \(status.diagnosticSummary)"
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            amber_iphone_control_stop(handle)
            return "result=observation_timeout"
        }.value
        IOSBackgroundLifecycleLog.record("phoneControlHandshakeInspection", detail: detail)
    }
}

/// Explicit installation check: prepare Amber's own VPN configuration, verify
/// the same credential-free greeting, then release the tunnel after native join.
enum IOSPhoneControlEmbeddedTunnelInspection {
    static let diagnosticLaunchArgument = "-amber-phone-embedded-tunnel-inspection-once"

    @MainActor
    static func runOnce() async {
        let tunnel = IOSPhoneControlLocalTunnel()
        let owner = UUID()
        IOSBackgroundLifecycleLog.record("phoneControlEmbeddedTunnelInspection", detail: "stage=prepare")
        do {
            try await tunnel.prepare()
            try Task.checkCancellation()
            IOSBackgroundLifecycleLog.record("phoneControlEmbeddedTunnelInspection", detail: "stage=start")
            try await tunnel.start(owner: owner)
            try Task.checkCancellation()
            IOSBackgroundLifecycleLog.record("phoneControlEmbeddedTunnelInspection", detail: "stage=connected")
            await IOSPhoneControlHandshakeInspection.runOnce(source: "amber_embedded")
        } catch {
            let error = error as NSError
            IOSBackgroundLifecycleLog.record("phoneControlEmbeddedTunnelInspection",
                detail: "stage=failed domain=\(error.domain) code=\(error.code)")
        }
        let disconnected = await tunnel.stop(owner: owner)
        IOSBackgroundLifecycleLog.record("phoneControlEmbeddedTunnelInspection",
            detail: "stage=cleanup disconnected=\(disconnected)")
    }
}

/// Explicit delivery probes only. Each launch tests one discovered local
/// endpoint without pairing credentials or changing the production route.
enum IOSPhoneControlDirectConnectionInspection {
    enum Mode: String, Sendable {
        case remotePairingIPv6 = "ipv6"
        case lockdownIPv4 = "lockdown"

        var launchArgument: String { "-amber-phone-direct-\(rawValue)-inspection-once" }
    }

    @MainActor
    static func runOnce(mode: Mode) async {
        IOSBackgroundLifecycleLog.record("phoneControlDirectInspectionStarted", detail: "mode=\(mode.rawValue)")
        guard !Task.isCancelled else { return }
        // Keep the diagnosis independent of the already-working local VPN.
        // This tests address presence, not other apps' private VPN preferences.
        let localVPNAddress = IOSPhoneControlServiceAddress(family: "ipv4", normalizedAddress: "10.7.1.1")
        guard !IOSPhoneControlServiceAddressCodec.matches(
            localVPNAddress, localAddresses: IOSPhoneControlServiceAddressCodec.localAddresses()
        ) else {
            IOSBackgroundLifecycleLog.record("phoneControlDirectInspectionFinished",
                detail: "mode=\(mode.rawValue) result=not_tested localdevvpn_address_present=true")
            return
        }
        let summary = await IOSPhoneControlServiceInspection().inspectAndRecord(source: "direct_\(mode.rawValue)")
        guard !Task.isCancelled else { return }
        let endpoint: String
        do {
            switch mode {
            case .remotePairingIPv6: endpoint = try summary.uniqueLocalIPv6Endpoint
            case .lockdownIPv4: endpoint = try summary.uniqueLocalWiFiIPv4LockdownEndpoint()
            }
        } catch {
            IOSBackgroundLifecycleLog.record("phoneControlDirectInspectionFinished",
                detail: "mode=\(mode.rawValue) result=not_tested endpoint=unavailable services=\(summary.services.count)")
            return
        }
        IOSBackgroundLifecycleLog.record("phoneControlDirectInspectionEndpoint",
            detail: "mode=\(mode.rawValue) source=unique_self localdevvpn_address_present=false")
        let result = await Task.detached {
            let handle = endpoint.withCString {
                switch mode {
                case .remotePairingIPv6: amber_iphone_control_inspect_handshake($0)
                case .lockdownIPv4: amber_iphone_control_inspect_lockdown($0)
                }
            }
            guard let handle else { return "result=no_handle" }
            defer { amber_iphone_control_free(handle) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                guard let pointer = amber_iphone_control_status_json(handle) else { return "result=no_status" }
                let data = Data(String(cString: pointer).utf8)
                amber_iphone_control_string_free(pointer)
                guard let status = try? JSONDecoder().decode(PhoneControlLaunchStatus.self, from: data) else {
                    return "result=invalid_status"
                }
                if status.phase == "stopped" || status.phase == "failed" {
                    return "phase=\(status.phase) \(status.diagnosticSummary)"
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            amber_iphone_control_stop(handle)
            return "result=observation_timeout"
        }.value
        IOSBackgroundLifecycleLog.record("phoneControlDirectInspectionFinished", detail: "mode=\(mode.rawValue) \(result)")
    }
}

struct PhoneControlLaunchConfiguration: Sendable {
    let pairing: Data
    var endpoint = IOSPhoneControlLoopbackRoute.endpoint
    var runnerBundleID = "app.amber.selfcontrol.runner.xctrunner"
    var testModuleName = "iPhoneUse"
    var allowedBundleIDs: Set<String>
}

struct PhoneControlLaunchStatus: Decodable, Sendable {
    let phase: String
    let code: String?
    let message: String
    let native_error_code: Int?
    let native_error_subcode: Int?
    let native_io_kind: String?
    let native_transport_stage: String?
    let native_os_error_code: Int?
    let pair_verify_error: PhoneControlNativeDiagnostic?

    var diagnosticSummary: String {
        var parts = code.map { [$0] } ?? []
        if let native_error_code { parts.append("native=\(native_error_code)") }
        if let native_error_subcode { parts.append("subcode=\(native_error_subcode)") }
        if let native_transport_stage { parts.append("transport=\(native_transport_stage)") }
        if let native_io_kind { parts.append("io=\(native_io_kind)") }
        if let native_os_error_code { parts.append("os=\(native_os_error_code)") }
        if let pair_verify_error { parts.append("pair_verify=\(pair_verify_error.summary)") }
        return parts.joined(separator: ", ")
    }
}

struct PhoneControlNativeDiagnostic: Decodable, Sendable {
    let native_error_code: Int
    let native_error_subcode: Int
    let native_io_kind: String?
    let native_transport_stage: String?
    let native_os_error_code: Int?

    var summary: String {
        var parts = ["native=\(native_error_code)", "subcode=\(native_error_subcode)"]
        if let native_transport_stage { parts.append("transport=\(native_transport_stage)") }
        if let native_io_kind { parts.append("io=\(native_io_kind)") }
        if let native_os_error_code { parts.append("os=\(native_os_error_code)") }
        return parts.joined(separator: ", ")
    }
}

enum PhoneControlSessionError: LocalizedError {
    case occupied, stopped, launch(String), nativeLaunch(PhoneControlLaunchStatus), readinessTimeout(String)
    var errorDescription: String? {
        switch self {
        case .occupied: "已有本机控制任务正在运行。请先停止原任务。"
        case .stopped: "本次控制会话已停止。"
        case .launch(let message): "开发会话启动失败：\(message)"
        case .nativeLaunch(let status):
            "开发会话启动失败：\(status.message)（\(status.diagnosticSummary)）"
        case .readinessTimeout(let detail): "未在 60 秒内收到 runner 的有效签名响应。\(detail)"
        }
    }
}

/// The app owns this actor. A page observes it but never owns the native test connection.
actor PhoneControlSession {
    private var ownerRunID: UUID?
    private var native: NativePhoneControlHandle?
    private var client: PhoneRunnerClient?
    private var closing: Task<Bool, Never>?
    private var runnerReady = false
    private var lastLaunchStatus: PhoneControlLaunchStatus?
    private var lastStatusRunID: UUID?

    func start(runID: UUID, configuration: PhoneControlLaunchConfiguration) async throws -> PhoneRunnerStatus {
        // A revoke may cancel the task before its actor hop reaches this entry.
        try Task.checkCancellation()
        guard ownerRunID == nil else { throw PhoneControlSessionError.occupied }
        ownerRunID = runID
        lastStatusRunID = runID
        lastLaunchStatus = nil
        let token = PhoneRunnerClient.newSessionToken()
        do {
            let client = try PhoneRunnerClient(token: token, allowedBundleIDs: configuration.allowedBundleIDs)
            let handle = NativePhoneControlHandle(configuration: configuration, token: token)
            self.native = handle
            self.client = client
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            var readinessError = ""
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard ownerRunID == runID, native === handle else { throw PhoneControlSessionError.stopped }
                let status = try handle.status()
                lastLaunchStatus = status
                if status.phase == "failed" || status.phase == "stopped" {
                    throw PhoneControlSessionError.nativeLaunch(status)
                }
                if status.phase == "running" {
                    do {
                        let ready = try await client.status()
                        guard ownerRunID == runID, native === handle, closing == nil else {
                            throw PhoneControlSessionError.stopped
                        }
                        if ready.ready {
                            runnerReady = true
                            return ready
                        }
                    } catch { readinessError = error.localizedDescription }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw PhoneControlSessionError.readinessTimeout(readinessError)
        } catch {
            await stop(runID: runID)
            throw error
        }
    }

    func launchStatus(runID: UUID) throws -> PhoneControlLaunchStatus? {
        guard runID == lastStatusRunID else { return nil }
        if let native { lastLaunchStatus = try native.status() }
        return lastLaunchStatus
    }

    func cachedApplications(runID: UUID) throws -> [PhoneControlInstalledApp] {
        guard ownerRunID == runID, closing == nil, let native else {
            throw PhoneControlSessionError.stopped
        }
        return try native.applications()
    }

    func runner(runID: UUID) throws -> PhoneRunnerClient {
        guard ownerRunID == runID, let client else { throw PhoneControlSessionError.stopped }
        return client
    }

    func stop(runID: UUID) async {
        guard ownerRunID == runID else { return }
        if let closing {
            _ = await closing.value
            return
        }
        let handle = native
        let client = client
        let shouldShutdownRunner = runnerReady
        // Revoke first. A late readiness response cannot revive the old owner.
        native = nil
        self.client = nil
        runnerReady = false
        let closing = Task {
            await client?.stop()
            var shutdownSucceeded = true
            if shouldShutdownRunner, let client {
                // Closing DTX alone leaves the serving XCTest process alive.
                // End the authenticated runner while its development session is still open.
                do {
                    try await client.shutdownRunner()
                    await IOSBackgroundLifecycleLog.record("phoneControlRunnerShutdown", detail: "result=accepted")
                } catch {
                    shutdownSucceeded = false
                    await IOSBackgroundLifecycleLog.record("phoneControlRunnerShutdown", detail: "result=failed")
                }
            }
            handle?.stop()
            if let handle { await Task.detached { handle.close() }.value }
            return shutdownSucceeded
        }
        self.closing = closing
        let shutdownSucceeded = await closing.value
        // Keep the slot occupied until old DTX connections have actually closed.
        if ownerRunID == runID {
            ownerRunID = nil
            self.closing = nil
            lastLaunchStatus = PhoneControlLaunchStatus(phase: "stopped", code: shutdownSucceeded ? nil : "runner_shutdown_failed",
                                                       message: shutdownSucceeded ? "本轮测试连接已关闭" : "本轮测试连接已关闭，但未确认 runner 接受退出请求。", native_error_code: nil,
                                                       native_error_subcode: nil, native_io_kind: nil,
                                                       native_transport_stage: nil, native_os_error_code: nil, pair_verify_error: nil)
        }
    }
}

/// Calls are serialized by PhoneControlSession. close runs after that actor revokes the handle;
/// transferring this final owner to a worker prevents Rust runtime join from blocking SwiftUI.
private final class NativePhoneControlHandle: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(configuration: PhoneControlLaunchConfiguration, token: String) {
        handle = configuration.pairing.withUnsafeBytes { bytes in
            configuration.endpoint.withCString { endpoint in
                configuration.runnerBundleID.withCString { bundle in
                    configuration.testModuleName.withCString { module in
                        token.withCString { token in
                            amber_iphone_control_start(bytes.bindMemory(to: UInt8.self).baseAddress,
                                                       bytes.count, endpoint, bundle, module, token)
                        }
                    }
                }
            }
        }
    }

    func status() throws -> PhoneControlLaunchStatus {
        guard let handle, let text = amber_iphone_control_status_json(handle) else {
            throw PhoneControlSessionError.launch("无法取得启动状态")
        }
        defer { amber_iphone_control_string_free(text) }
        return try JSONDecoder().decode(PhoneControlLaunchStatus.self, from: Data(String(cString: text).utf8))
    }

    func stop() { if let handle { amber_iphone_control_stop(handle) } }

    func applications() throws -> [PhoneControlInstalledApp] {
        guard let handle else { throw PhoneControlSessionError.stopped }
        guard let applications = try PhoneControlApplications.cachedApplications(handle: handle) else {
            throw PhoneControlSessionError.launch("本机应用目录仍在读取，请等待连接完成。")
        }
        return applications
    }
    func close() {
        guard let handle else { return }
        self.handle = nil
        amber_iphone_control_free(handle)
    }
}
