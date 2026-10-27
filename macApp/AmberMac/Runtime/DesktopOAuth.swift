import Foundation
import Observation

struct DesktopDeviceAuthorization: Equatable, Sendable {
    let verificationURL: URL
    let userCode: String
    let deviceAuthID: String
    let intervalSeconds: Int
}

struct DesktopOAuthAccount: Equatable, Sendable {
    let email: String?
    let plan: String?
}

@MainActor protocol DesktopCodexAuthorizer {
    func account(providerID: UUID) -> DesktopOAuthAccount?
    func requestCode(providerID: UUID) async throws -> DesktopDeviceAuthorization
    func poll(providerID: UUID, code: DesktopDeviceAuthorization) async throws -> DesktopOAuthAccount
    func logout(providerID: UUID) async throws
}

@MainActor @Observable final class DesktopCodexLogin {
    private(set) var providerID: UUID?
    private(set) var authorization: DesktopDeviceAuthorization?
    private(set) var account: DesktopOAuthAccount?
    private(set) var isBusy = false
    private(set) var status: String?
    private(set) var failed = false
    @ObservationIgnored private let authorizer: any DesktopCodexAuthorizer
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var pending: [UUID: (providerID: UUID, task: Task<Void, Never>)] = [:]

    init(authorizer: any DesktopCodexAuthorizer) { self.authorizer = authorizer }

    func selectProvider(_ id: UUID?) {
        cancel()
        providerID = id
        account = id.flatMap { authorizer.account(providerID: $0) }
        status = nil; failed = false
    }

    func cancel() {
        token = nil; task?.cancel(); task = nil
        authorization = nil; isBusy = false
    }

    func login(_ id: UUID) {
        cancel()
        providerID = id
        let request = UUID()
        token = request; isBusy = true; status = nil; failed = false
        task = Task {
            defer {
                pending[request] = nil
                if token == request { task = nil; isBusy = false }
            }
            do {
                let code = try await authorizer.requestCode(providerID: id)
                guard token == request else { return }
                authorization = code
                status = "在浏览器完成登录后，此处会自动更新。"
                let result = try await authorizer.poll(providerID: id, code: code)
                guard token == request else { return }
                account = result; authorization = nil
                status = "已登录，凭证已保存到系统钥匙串。"
            } catch is CancellationError {
            } catch {
                guard token == request else { return }
                authorization = nil; failed = true
                status = "登录失败，请检查网络或钥匙串后重试。"
            }
        }
        pending[request] = (id, task!)
    }

    func logout(_ id: UUID) {
        let previous = pending.values.filter { $0.providerID == id }.map(\.task)
        for task in previous { task.cancel() }
        cancel()
        providerID = id
        let request = UUID()
        token = request; isBusy = true; status = nil; failed = false
        task = Task {
            defer {
                pending[request] = nil
                if token == request { task = nil; isBusy = false }
            }
            for task in previous { await task.value }
            do {
                try await authorizer.logout(providerID: id)
                guard token == request else { return }
                account = nil; status = "已退出登录，服务商和模型配置已保留。"
            } catch {
                guard token == request else { return }
                failed = true; status = "退出登录失败，请解锁钥匙串后重试。"
            }
        }
        pending[request] = (id, task!)
    }

    func waitUntilIdle() async { await task?.value }

    func removeCredentials(_ id: UUID) async throws {
        let previous = pending.values.filter { $0.providerID == id }.map(\.task)
        for task in previous { task.cancel() }
        cancel()
        for task in previous { await task.value }
        try await authorizer.logout(providerID: id)
    }
}
