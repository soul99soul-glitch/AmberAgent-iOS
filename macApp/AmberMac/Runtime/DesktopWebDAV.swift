import Foundation
import Observation

struct DesktopWebDAVConfiguration: Codable, Equatable, Sendable {
    var baseURL = ""
    var path = "AmberAgentMac"
    var username = ""

    func validate() throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else {
            throw DesktopRuntimeError.message("请填写有效的 WebDAV HTTP/HTTPS 地址，账号和密码请分别填写。")
        }
    }
}

@MainActor @Observable
final class DesktopWebDAVManager {
    private struct Stored: Codable { let configuration: DesktopWebDAVConfiguration; let hasPassword: Bool }
    private(set) var configuration = DesktopWebDAVConfiguration()
    private(set) var snapshots: [IOSWebDAVResource] = []
    private(set) var isBusy = false
    private(set) var status = "尚未连接"
    private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DesktopCredentialStore
    @ObservationIgnored private let transport: any IOSWebDAVTransport
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var hasPassword = false
    @ObservationIgnored private var cancellation: (() -> Void)?
    private static let key = "app.amber.macos.webdav"
    private static let credentialID = UUID(uuidString: "56f5a5de-bcf7-4276-839c-f2fda4ba4a7c")!

    init(defaults: UserDefaults = .standard,
         credentials: any DesktopCredentialStore = DesktopKeychain(service: "app.amber.macos.webdav.credentials"),
         transport: any IOSWebDAVTransport = IOSURLSessionWebDAVTransport()) {
        self.defaults = defaults; self.credentials = credentials; self.transport = transport
        guard let data = defaults.data(forKey: Self.key) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            configuration = stored.configuration
            hasPassword = stored.hasPassword
        } catch {
            loadFailed = true
            self.error = "无法读取保存的 WebDAV 配置，原始记录已保留；请先恢复该配置再修改。"
        }
    }

    func storedPassword() throws -> String {
        let password = try credentials.load(id: Self.credentialID)
        guard !hasPassword || !password.isEmpty else { throw DesktopRuntimeError.message("WebDAV 密码无法从钥匙串读取，请重新填写并保存。") }
        return password
    }

    func save(configuration: DesktopWebDAVConfiguration, password: String) throws {
        guard !loadFailed else { throw DesktopRuntimeError.message(error ?? "无法读取原 WebDAV 配置，已阻止覆盖。") }
        guard !isBusy else { throw DesktopRuntimeError.message("请先等待或取消当前 WebDAV 操作。") }
        try configuration.validate()
        if !configuration.username.isEmpty || !password.isEmpty {
            guard URL(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() == "https" else {
                throw DesktopRuntimeError.message("WebDAV Basic 认证只允许使用 HTTPS。")
            }
        }
        let stored = Stored(configuration: configuration, hasPassword: !password.isEmpty)
        let data = try JSONEncoder().encode(stored)
        try credentials.save(password, id: Self.credentialID)
        defaults.set(data, forKey: Self.key)
        self.configuration = configuration
        hasPassword = stored.hasPassword
        snapshots = []
        error = nil
        status = "配置已保存，尚未连接"
    }

    func testConnection() async throws {
        let client = try client()
        try await perform(status: "正在检查连接…") { try await client.testConnection() }
        status = "连接成功"
    }

    func list() async throws {
        let client = try client()
        let resources = try await perform(status: "正在读取远端快照…") { try await client.listResources() }
        snapshots = resources.filter { !$0.isCollection && $0.remoteFileName.hasSuffix(".\(DesktopBackup.fileExtension)") }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        status = "已读取 \(snapshots.count) 个快照"
    }

    @discardableResult
    func push(data: Data) async throws -> IOSWebDAVResource {
        try Task.checkCancellation()
        guard !data.isEmpty else { throw DesktopRuntimeError.message("备份内容为空，未上传。") }
        try DesktopBackup.validateRemoteArchive(data)
        let client = try client()
        let fileName = "amber-mac-\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased()).\(DesktopBackup.fileExtension)"
        let revision = try await perform(status: "正在上传新快照…", remoteMutation: true) {
            try await client.upload(data: data, fileName: fileName, mimeType: "application/vnd.amberagent.mac.backup+json", createOnly: true)
        }
        let resource = IOSWebDAVResource(href: try client.makeRequest(method: "GET", fileName: fileName).url!.absoluteString,
            displayName: fileName, sizeBytes: Int64(data.count), modifiedAt: Int64(Date().timeIntervalSince1970 * 1000),
            etag: revision ?? "", isCollection: false)
        snapshots.insert(resource, at: 0)
        status = "新快照已上传"
        return resource
    }

    func download(_ resource: IOSWebDAVResource) async throws -> Data {
        try validateSnapshot(resource)
        let client = try client()
        let data = try await perform(status: "正在下载快照…") { try await client.download(fileName: resource.remoteFileName) }
        status = "下载完成，请先预览备份内容再导入副本"
        return data
    }

    func delete(_ resource: IOSWebDAVResource) async throws {
        try validateSnapshot(resource)
        let client = try client()
        try await perform(status: "正在移除远端快照…", remoteMutation: true) { try await client.delete(fileName: resource.remoteFileName) }
        snapshots.removeAll { $0 == resource }
        status = "远端快照已移除"
    }

    func cancel() { cancellation?() }

    private func client() throws -> IOSWebDAVClient {
        guard !loadFailed else { throw DesktopRuntimeError.message(error ?? "无法读取 WebDAV 配置。") }
        try configuration.validate()
        return IOSWebDAVClient(config: IOSWebDAVConfig(baseURL: configuration.baseURL,
            path: configuration.path, username: configuration.username, password: try storedPassword()), transport: transport)
    }

    private func validateSnapshot(_ resource: IOSWebDAVResource) throws {
        guard snapshots.contains(resource), !resource.isCollection,
              resource.remoteFileName.hasSuffix(".\(DesktopBackup.fileExtension)") else {
            throw DesktopRuntimeError.message("此快照不属于当前 WebDAV 列表，请刷新后重试。")
        }
    }

    private func perform<Value: Sendable>(status: String, remoteMutation: Bool = false, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !isBusy else { throw DesktopRuntimeError.message("已有 WebDAV 操作正在执行。") }
        isBusy = true
        self.status = status
        error = nil
        let task = Task { try await operation() }
        cancellation = { task.cancel() }
        defer { isBusy = false; cancellation = nil }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.status = remoteMutation ? "操作已取消；请求可能已在远端完成，可刷新列表确认" : "操作已取消"
                throw CancellationError()
            }
            let message: String
            if let known = error as? IOSSyncBackupError { message = known.localizedDescription }
            else if let known = error as? DesktopRuntimeError { message = known.localizedDescription }
            else { message = "WebDAV 请求失败，请检查网络、地址和认证后重试。" }
            self.error = message
            self.status = "操作未完成"
            throw DesktopRuntimeError.message(message)
        }
    }
}
