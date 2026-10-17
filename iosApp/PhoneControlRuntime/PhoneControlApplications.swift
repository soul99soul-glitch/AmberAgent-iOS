import AmberIPhoneControl
import Foundation

struct PhoneControlInstalledApp: Decodable, Equatable, Identifiable, Sendable {
    let bundleID: String
    let name: String
    let isSystem: Bool?

    var id: String { bundleID }

    init(bundleID: String, name: String, isSystem: Bool? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.isSystem = isSystem
    }
}

protocol PhoneControlApplicationDiscovering: Sendable {
    func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) async throws -> [PhoneControlInstalledApp]
}

enum PhoneControlApplicationsError: LocalizedError {
    case unavailable, invalidResult, failed(PhoneControlLaunchStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法创建本机应用查询任务。"
        case .invalidResult: "本机应用查询返回了无法读取的结果。"
        case .failed(let status):
            "\(status.message)（\(status.diagnosticSummary)）"
        }
    }
}

/// Standalone discovery before a control session exists. During control, the
/// session owner reads its native handle's cache instead of opening a new tunnel.
actor PhoneControlApplications: PhoneControlApplicationDiscovering {
    private var operationID: UUID?
    private var native: NativePhoneApplicationsHandle?
    private var closing: Task<Void, Never>?

    func installedApplications(pairing: Data, connectionMode: IOSPhoneControlConnectionMode = .embedded) async throws -> [PhoneControlInstalledApp] {
        try Task.checkCancellation()
        guard operationID == nil else { throw PhoneControlSessionError.occupied }
        let id = UUID()
        let handle = try NativePhoneApplicationsHandle(pairing: pairing, connectionMode: connectionMode)
        operationID = id
        native = handle
        return try await withTaskCancellationHandler {
            do {
                while true {
                    try Task.checkCancellation()
                    guard operationID == id, native === handle else { throw CancellationError() }
                    if let apps = try handle.applications() {
                        await finish(id: id)
                        try Task.checkCancellation()
                        return apps
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                await finish(id: id)
                throw error
            }
        } onCancel: {
            Task { await self.finish(id: id) }
        }
    }

    /// Call only while the owning actor holds a live handle. nil means that the
    /// startup query is pending; an empty array is a successful empty catalog.
    /// This function copies cached metadata and never starts a network request.
    nonisolated static func cachedApplications(handle: OpaquePointer) throws -> [PhoneControlInstalledApp]? {
        guard let raw = amber_iphone_control_apps_copy_json(handle) else {
            throw PhoneControlApplicationsError.invalidResult
        }
        defer { amber_iphone_control_string_free(raw) }
        let result: CatalogResult
        do {
            result = try JSONDecoder().decode(CatalogResult.self, from: Data(String(cString: raw).utf8))
        } catch {
            throw PhoneControlApplicationsError.invalidResult
        }
        switch result.state {
        case "pending": return nil
        case "ready":
            guard let apps = result.apps else { throw PhoneControlApplicationsError.invalidResult }
            return apps
        case "failed":
            guard let error = result.error else { throw PhoneControlApplicationsError.invalidResult }
            throw PhoneControlApplicationsError.failed(error)
        default: throw PhoneControlApplicationsError.invalidResult
        }
    }

    private struct CatalogResult: Decodable {
        let state: String
        let apps: [PhoneControlInstalledApp]?
        let error: PhoneControlLaunchStatus?
    }

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

/// Calls are serialized by PhoneControlApplications. Its final close/join
/// moves off the actor only after the live reference has been revoked.
private final class NativePhoneApplicationsHandle: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(pairing: Data, connectionMode: IOSPhoneControlConnectionMode) throws {
        handle = pairing.withUnsafeBytes { bytes in
            IOSPhoneControlLoopbackRoute.endpoint.withCString { endpoint in
                amber_iphone_control_apps_start(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, endpoint,
                                               connectionMode.nativeRouteMode)
            }
        }
        guard handle != nil else { throw PhoneControlApplicationsError.unavailable }
    }

    func applications() throws -> [PhoneControlInstalledApp]? {
        guard let handle else { throw PhoneControlApplicationsError.unavailable }
        return try PhoneControlApplications.cachedApplications(handle: handle)
    }

    func stop() { if let handle { amber_iphone_control_stop(handle) } }

    func close() {
        guard let handle else { return }
        self.handle = nil
        amber_iphone_control_free(handle)
    }
}
