import Foundation
import Observation

struct DesktopMCPServer: Codable, Equatable, Identifiable {
    enum Transport: String, Codable, CaseIterable { case streamableHTTP = "streamable_http", sse, stdio }
    var id = UUID()
    var name = ""
    var transport: Transport = .streamableHTTP
    var url = ""
    var command = ""
    var arguments: [String] = []
    var headers: [String: String] = [:]
    var environment: [String: String] = [:]
    var enabled = true
    var tools: [IOSMcpTool] = []

    var clientConfiguration: IOSMcpServerConfig {
        if transport == .sse { return .sse(name: name, url: url, headers: headers) }
        return .streamableHTTP(name: name, url: transport == .stdio ? "stdio://\(id.uuidString)" : url, headers: headers)
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopRuntimeError.message("请填写 MCP 服务名称。")
        }
        if transport == .stdio {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DesktopRuntimeError.message("请填写 MCP 启动命令。")
            }
        } else {
            guard let endpoint = URL(string: url), ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
                  endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else {
                throw DesktopRuntimeError.message("MCP 地址需要是有效的 HTTP 或 HTTPS URL；认证请填写在请求头中。")
            }
        }
    }
}

@MainActor @Observable
final class DesktopMCPStore {
    private struct Secrets: Codable { var headers: [String: String]; var environment: [String: String] }
    private struct Stored: Codable { var server: DesktopMCPServer; var hasCredentials: Bool }
    private(set) var servers: [DesktopMCPServer] = []
    private(set) var loadError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any DesktopCredentialStore
    @ObservationIgnored private var missingCredentials = Set<UUID>()
    @ObservationIgnored private var loadFailed = false
    private static let key = "app.amber.macos.mcpServers"

    init(defaults: UserDefaults = .standard, credentials: any DesktopCredentialStore = DesktopKeychain(service: "app.amber.macos.mcp.credentials")) {
        self.defaults = defaults
        self.credentials = credentials
        guard let data = defaults.data(forKey: Self.key) else { return }
        do {
            servers = try JSONDecoder().decode([Stored].self, from: data).map { stored in
                var server = stored.server
                if stored.hasCredentials {
                    if let raw = try? credentials.load(id: server.id), !raw.isEmpty,
                       let secret = try? JSONDecoder().decode(Secrets.self, from: Data(raw.utf8)) {
                        server.headers = secret.headers
                        server.environment = secret.environment
                    } else { missingCredentials.insert(server.id) }
                }
                return server
            }
            if !missingCredentials.isEmpty { loadError = "部分 MCP 凭据无法从钥匙串读取，请重新保存对应服务。" }
        } catch {
            loadFailed = true
            loadError = "无法读取保存的 MCP 配置，原始记录已保留；请先恢复该配置再进行修改。"
        }
    }

    func runtimeServer(id: UUID) throws -> DesktopMCPServer {
        guard let server = servers.first(where: { $0.id == id }) else { throw DesktopRuntimeError.message("MCP 服务已被移除。") }
        guard !missingCredentials.contains(id) else { throw DesktopRuntimeError.message("无法读取此 MCP 服务的凭据，请重新保存请求头或环境变量。") }
        guard server.enabled else { throw DesktopRuntimeError.message("此 MCP 服务已停用。") }
        try server.validate()
        return server
    }

    func upsert(_ server: DesktopMCPServer) throws {
        try requireWritable()
        try server.validate()
        guard !servers.contains(where: { $0.id != server.id && $0.name == server.name }) else {
            throw DesktopRuntimeError.message("已有同名 MCP 服务，请使用其他名称。")
        }
        var next = servers
        if let index = next.firstIndex(where: { $0.id == server.id }) { next[index] = server }
        else { next.append(server) }
        let secret = Secrets(headers: server.headers, environment: server.environment)
        let raw = try JSONEncoder().encode(secret)
        try credentials.save(String(decoding: raw, as: UTF8.self), id: server.id)
        try persist(next, knownCredentialsID: server.id)
        missingCredentials.remove(server.id)
        refreshCredentialError()
    }

    func remove(id: UUID) throws {
        try requireWritable()
        try credentials.delete(id: id)
        try persist(servers.filter { $0.id != id })
        missingCredentials.remove(id)
        refreshCredentialError()
    }

    func setEnabled(id: UUID, enabled: Bool) throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { throw DesktopRuntimeError.message("MCP 服务已被移除。") }
        var next = servers
        next[index].enabled = enabled
        try persist(next)
    }

    func setToolEnabled(serverID: UUID, toolName: String, enabled: Bool) throws {
        guard let index = servers.firstIndex(where: { $0.id == serverID }),
              let toolIndex = servers[index].tools.firstIndex(where: { $0.name == toolName }) else {
            throw DesktopRuntimeError.message("MCP 工具已被移除，请重新连接服务。")
        }
        var next = servers
        next[index].tools[toolIndex] = next[index].tools[toolIndex].withEnabled(enabled)
        try persist(next)
    }

    func mergeTools(serverID: UUID, discovered: [IOSMcpTool]) throws {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { throw DesktopRuntimeError.message("MCP 服务已被移除。") }
        let previous = Dictionary(servers[index].tools.map { ($0.name, $0.enabled) }, uniquingKeysWith: { _, latest in latest })
        var next = servers
        var seen = Set<String>()
        next[index].tools = discovered.filter { seen.insert($0.name).inserted }.map { $0.withEnabled(previous[$0.name] ?? $0.enabled) }
        try persist(next)
    }

    func importJSON(_ json: String) throws {
        try requireWritable()
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let entries = object["mcpServers"] as? [String: [String: Any]], !entries.isEmpty else {
            throw DesktopRuntimeError.message("配置需要包含非空的 mcpServers 对象。")
        }
        var incoming: [DesktopMCPServer] = []
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            func field<Value>(_ key: String, default fallback: Value) throws -> Value {
                guard let raw = entry[key] else { return fallback }
                guard let value = raw as? Value else { throw DesktopRuntimeError.message("MCP 服务 \(name) 的 \(key) 格式不正确。") }
                return value
            }
            var server = DesktopMCPServer()
            server.name = name
            if let command = entry["command"] as? String {
                guard entry["url"] == nil else { throw DesktopRuntimeError.message("MCP 服务 \(name) 同时配置了 command 和 url。") }
                server.transport = .stdio
                server.command = command
                server.arguments = try field("args", default: [String]())
                server.environment = try field("env", default: [String: String]())
            } else {
                guard entry["command"] == nil else { throw DesktopRuntimeError.message("MCP 服务 \(name) 的 command 格式不正确。") }
                let type: String = try field("type", default: "streamable_http")
                guard ["sse", "http", "streamable_http", "streamable-http"].contains(type) else {
                    throw DesktopRuntimeError.message("MCP 服务 \(name) 的传输类型不支持。")
                }
                server.transport = type == "sse" ? .sse : .streamableHTTP
                server.url = try field("url", default: "")
                server.headers = try field("headers", default: [String: String]())
            }
            server.enabled = try field("enabled", default: true)
            try server.validate()
            guard !servers.contains(where: { $0.name == name }) else { throw DesktopRuntimeError.message("已有同名 MCP 服务：\(name)。") }
            incoming.append(server)
        }
        // Validate the complete import before writing either settings or credentials.
        var saved = [UUID]()
        do {
            for server in incoming {
                let secret = Secrets(headers: server.headers, environment: server.environment)
                try credentials.save(String(decoding: JSONEncoder().encode(secret), as: UTF8.self), id: server.id)
                saved.append(server.id)
            }
            try persist(servers + incoming)
        } catch {
            for id in saved { try? credentials.delete(id: id) }
            throw error
        }
    }

    private func persist(_ values: [DesktopMCPServer], knownCredentialsID: UUID? = nil) throws {
        try requireWritable()
        let stored = values.map { value in
            var redacted = value
            redacted.headers = [:]
            redacted.environment = [:]
            return Stored(server: redacted, hasCredentials: !value.headers.isEmpty || !value.environment.isEmpty || (missingCredentials.contains(value.id) && value.id != knownCredentialsID))
        }
        let data = try JSONEncoder().encode(stored)
        defaults.set(data, forKey: Self.key)
        if servers != values { servers = values }
    }

    private func requireWritable() throws {
        guard !loadFailed else { throw DesktopRuntimeError.message(loadError ?? "无法读取原 MCP 配置，已阻止覆盖。") }
    }

    private func refreshCredentialError() {
        guard !loadFailed else { return }
        loadError = missingCredentials.isEmpty ? nil : "部分 MCP 凭据无法从钥匙串读取，请重新保存对应服务。"
    }
}
