import AmberIPhoneControl
import Foundation

enum PhoneControlPairingError: LocalizedError {
    case unavailable, invalidResult, failed(PhoneControlLaunchStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法创建本机配对任务。"
        case .invalidResult: "系统返回配对完成，但未提供有效配对材料。"
        case .failed(let status):
            "\(status.message)（\(status.diagnosticSummary)）"
        }
    }
}

/// Owns exactly one explicit first-pair operation, independent from the XCTest runner session.
actor PhoneControlPairingSession {
    private var operationID: UUID?
    private var native: NativePhonePairingHandle?
    private var closing: Task<Void, Never>?

    func prepare(id: UUID, progress: @Sendable (PhoneControlLaunchStatus) async -> Void) async throws -> Data {
        try Task.checkCancellation()
        guard operationID == nil else { throw PhoneControlSessionError.occupied }
        let handle = try NativePhonePairingHandle()
        operationID = id
        native = handle
        do {
            var previousPhase: String?
            while true {
                try Task.checkCancellation()
                guard operationID == id, native === handle else { throw CancellationError() }
                let status = try handle.status()
                if previousPhase != status.phase {
                    previousPhase = status.phase
                    await progress(status)
                }
                // A progress callback is an actor suspension. Cancellation may close the handle there.
                try Task.checkCancellation()
                guard operationID == id, native === handle else { throw CancellationError() }
                switch status.phase {
                case "paired":
                    let result = try handle.pairingData()
                    await finish(id: id)
                    return result
                case "failed", "stopped":
                    throw PhoneControlPairingError.failed(status)
                default:
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            await finish(id: id)
            throw error
        }
    }

    func cancel(id: UUID) async { await finish(id: id) }

    private func finish(id: UUID) async {
        guard operationID == id else { return }
        if let closing {
            await closing.value
            return
        }
        let handle = native
        native = nil
        handle?.stop()
        let closing = Task.detached { if let handle { handle.close() } }
        self.closing = closing
        await closing.value
        if operationID == id {
            operationID = nil
            self.closing = nil
        }
    }
}

/// Serialized by PhoneControlPairingSession. The final close/join is transferred off the UI executor.
private final class NativePhonePairingHandle: @unchecked Sendable {
    private var handle: OpaquePointer?

    init() throws {
        handle = "127.0.0.1:49152".withCString { amber_iphone_control_pairing_start($0) }
        guard handle != nil else { throw PhoneControlPairingError.unavailable }
    }

    func status() throws -> PhoneControlLaunchStatus {
        guard let handle, let raw = amber_iphone_control_status_json(handle) else {
            throw PhoneControlPairingError.unavailable
        }
        defer { amber_iphone_control_string_free(raw) }
        return try JSONDecoder().decode(PhoneControlLaunchStatus.self, from: Data(String(cString: raw).utf8))
    }

    func pairingData() throws -> Data {
        guard let handle, let raw = amber_iphone_control_pairing_copy_plist(handle) else {
            throw PhoneControlPairingError.invalidResult
        }
        defer { amber_iphone_control_string_free(raw) }
        return Data(String(cString: raw).utf8)
    }

    func stop() { if let handle { amber_iphone_control_stop(handle) } }
    func close() {
        guard let handle else { return }
        self.handle = nil
        amber_iphone_control_free(handle)
    }
}
