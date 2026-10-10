import Foundation
import AmberPhoneControl
import AmberIPhoneControl

struct PhoneControlLaunchConfiguration: Sendable {
    let pairing: Data
    var endpoint = "127.0.0.1:49152"
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
    case occupied, stopped, launch(String), readinessTimeout(String)
    var errorDescription: String? {
        switch self {
        case .occupied: "已有本机控制任务正在运行。请先停止原任务。"
        case .stopped: "本次控制会话已停止。"
        case .launch(let message): "开发会话启动失败：\(message)"
        case .readinessTimeout(let detail): "未在 60 秒内收到 runner 的有效签名响应。\(detail)"
        }
    }
}

/// The app owns this actor. A page observes it but never owns the native test connection.
actor PhoneControlSession {
    private var ownerRunID: UUID?
    private var native: NativePhoneControlHandle?
    private var client: PhoneRunnerClient?
    private var closing: Task<Void, Never>?
    private var lastLaunchStatus: PhoneControlLaunchStatus?

    func start(runID: UUID, configuration: PhoneControlLaunchConfiguration) async throws -> PhoneRunnerStatus {
        // A revoke may cancel the task before its actor hop reaches this entry.
        try Task.checkCancellation()
        guard ownerRunID == nil else { throw PhoneControlSessionError.occupied }
        ownerRunID = runID
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
                    let diagnostic = status.diagnosticSummary
                    let detail = diagnostic.isEmpty ? status.message : "\(status.message)（\(diagnostic)）"
                    throw PhoneControlSessionError.launch(detail)
                }
                if status.phase == "running" {
                    do {
                        let ready = try await client.status()
                        guard ownerRunID == runID, native === handle, closing == nil else {
                            throw PhoneControlSessionError.stopped
                        }
                        if ready.ready { return ready }
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

    func launchStatus() throws -> PhoneControlLaunchStatus? {
        if let native { lastLaunchStatus = try native.status() }
        return lastLaunchStatus
    }

    func runner(runID: UUID) throws -> PhoneRunnerClient {
        guard ownerRunID == runID, let client else { throw PhoneControlSessionError.stopped }
        return client
    }

    func stop(runID: UUID) async {
        guard ownerRunID == runID else { return }
        if let closing {
            await closing.value
            return
        }
        let handle = native
        let client = client
        // Revoke first. A late readiness response cannot revive the old owner.
        native = nil
        self.client = nil
        handle?.stop()
        let closing = Task {
            await client?.stop()
            if let handle { await Task.detached { handle.close() }.value }
        }
        self.closing = closing
        await closing.value
        // Keep the slot occupied until old DTX connections have actually closed.
        if ownerRunID == runID {
            ownerRunID = nil
            self.closing = nil
            lastLaunchStatus = PhoneControlLaunchStatus(phase: "stopped", code: nil,
                                                       message: "本轮测试连接已关闭", native_error_code: nil,
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
    func close() {
        guard let handle else { return }
        self.handle = nil
        amber_iphone_control_free(handle)
    }
}
