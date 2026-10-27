import Foundation
import Observation

struct DesktopMCPOutcomeUnknown: LocalizedError, Sendable {
    var errorDescription: String? { "MCP 请求已发出，但未能确认执行结果。请先检查服务端状态，避免重复执行。" }
}

@MainActor @Observable
final class DesktopMCPManager {
    let store: DesktopMCPStore
    private(set) var statusByServer: [UUID: IOSMcpConnectionStatus] = [:]
    @ObservationIgnored private let transportFactory: (DesktopMCPServer) -> any IOSMcpHTTPTransport
    @ObservationIgnored private var clients: [UUID: IOSMcpClient] = [:]
    @ObservationIgnored private var transports: [UUID: any IOSMcpHTTPTransport] = [:]
    @ObservationIgnored private var closingProcesses: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var connectedConfigurations: [UUID: DesktopMCPServer] = [:]
    @ObservationIgnored private var connections: [UUID: Task<[IOSMcpTool], Error>] = [:]
    @ObservationIgnored private var calls: [UUID: [UUID: Task<String, Error>]] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]

    init(store: DesktopMCPStore, transportFactory: ((DesktopMCPServer) -> any IOSMcpHTTPTransport)? = nil) {
        self.store = store
        self.transportFactory = transportFactory ?? { server in
            if server.transport == .stdio { return DesktopMCPStdioTransport(configuration: server) }
            return URLSessionMcpHTTPTransport()
        }
    }

    func connect(id: UUID) async throws {
        let server = try store.runtimeServer(id: id)
        disconnect(id: id)
        let generation = UUID()
        generations[id] = generation
        let transport = transportFactory(server)
        transports[id] = transport
        let client = IOSMcpClient(transport: transport,
            preferredProtocolVersion: server.transport == .sse ? nil : "2025-11-25", clientName: "AmberAgent macOS")
        clients[id] = client
        statusByServer[id] = .connecting
        let task = Task {
            _ = try await client.connect(config: server.clientConfiguration)
            return try await client.listTools()
        }
        connections[id] = task
        do {
            let tools = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generations[id] == generation,
                  sameConnection(try store.runtimeServer(id: id), server) else { throw CancellationError() }
            try store.mergeTools(serverID: id, discovered: tools)
            connectedConfigurations[id] = server
            connections[id] = nil
            statusByServer[id] = .connected
        } catch {
            if generations[id] == generation {
                connections[id] = nil
                discardClient(id)
                connectedConfigurations[id] = nil
                statusByServer[id] = error is CancellationError ? .idle : .error(Self.message(error))
            }
            if error is CancellationError { throw CancellationError() }
            throw DesktopRuntimeError.message(Self.message(error))
        }
    }

    func disconnect(id: UUID) {
        generations[id] = nil
        connections.removeValue(forKey: id)?.cancel()
        calls.removeValue(forKey: id)?.values.forEach { $0.cancel() }
        discardClient(id)
        connectedConfigurations[id] = nil
        statusByServer[id] = .idle
    }

    func shutdown() async {
        for id in Set(clients.keys).union(connections.keys).union(calls.keys) { disconnect(id: id) }
        while !closingProcesses.isEmpty {
            let pending = closingProcesses
            for task in pending.values { await task.value }
            for id in pending.keys { closingProcesses[id] = nil }
        }
    }

    func perform(name: String, argumentsJSON: String) async throws -> String {
        guard let arguments = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            throw DesktopRuntimeError.message("MCP 工具参数必须是 JSON 对象。")
        }
        if name == "mcp_list" {
            return try json(store.servers.filter(\.enabled).map { server in
                ["id": server.id.uuidString, "name": server.name, "transport": server.transport.rawValue,
                 "tools": server.tools.filter(\.enabled).map { ["name": $0.name, "description": $0.description ?? ""] }] as [String: Any]
            })
        }
        guard let rawID = arguments["server_id"] as? String, let id = UUID(uuidString: rawID),
              let toolName = arguments["name"] as? String, !toolName.isEmpty else {
            throw DesktopRuntimeError.message("请提供有效的 MCP server_id 和工具 name。")
        }
        var server = try store.runtimeServer(id: id)
        if name == "mcp_describe_tool" {
            guard let tool = server.tools.first(where: { $0.name == toolName && $0.enabled }) else {
                throw DesktopRuntimeError.message("此 MCP 工具未启用或尚未发现，请先连接服务。")
            }
            let schema = tool.inputSchema.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? ["type": "object", "properties": [:]]
            return try json(["name": tool.name, "description": tool.description ?? "", "inputSchema": schema,
                             "readOnlyHint": tool.readOnlyHint == true])
        }
        guard name == "mcp_call_tool" else { throw DesktopRuntimeError.message("未知的 MCP 工具。") }
        if clients[id] == nil || connectedConfigurations[id].map({ !sameConnection($0, server) }) == true {
            try await connect(id: id)
        }
        server = try store.runtimeServer(id: id)
        guard server.tools.contains(where: { $0.name == toolName && $0.enabled }), let client = clients[id] else {
            throw DesktopRuntimeError.message("此 MCP 工具未启用或已被移除。")
        }
        let toolArguments: [String: Any]
        if let value = arguments["arguments"] {
            guard let object = value as? [String: Any] else { throw DesktopRuntimeError.message("MCP arguments 必须是 JSON 对象。") }
            toolArguments = object
        } else { toolArguments = [:] }
        let callID = UUID()
        let generation = generations[id]
        let task = Task {
            var dispatched = false
            let result: [String: Any]
            do {
                result = try await client.callToolResult(name: toolName, arguments: toolArguments, onDispatched: { dispatched = true })
            } catch {
                if dispatched && Self.outcomeIsUnknown(error) { throw DesktopMCPOutcomeUnknown() }
                throw error
            }
            guard result["isError"] as? Bool != true else { throw DesktopRuntimeError.message("MCP 工具返回错误；请检查工具参数后重试。") }
            return try self.json(result)
        }
        calls[id, default: [:]][callID] = task
        defer { calls[id]?[callID] = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            return result
        } catch {
            if generations[id] == generation {
                discardClient(id)
                connectedConfigurations[id] = nil
                statusByServer[id] = error is CancellationError ? .idle : .error(Self.message(error))
            }
            if error is DesktopMCPOutcomeUnknown { throw error }
            if error is CancellationError { throw CancellationError() }
            throw DesktopRuntimeError.message(Self.message(error))
        }
    }

    private func sameConnection(_ lhs: DesktopMCPServer, _ rhs: DesktopMCPServer) -> Bool {
        var lhs = lhs, rhs = rhs
        lhs.tools = []; rhs.tools = []
        return lhs == rhs
    }

    private func discardClient(_ id: UUID) {
        let transport = transports.removeValue(forKey: id)
        clients.removeValue(forKey: id)?.disconnect()
        if let task = (transport as? DesktopMCPStdioTransport)?.terminationTask {
            let cleanupID = UUID()
            closingProcesses[cleanupID] = task
            Task {
                await task.value
                closingProcesses[cleanupID] = nil
            }
        }
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? DesktopMCPOutcomeUnknown { return error.localizedDescription }
        if let error = error as? DesktopRuntimeError { return error.localizedDescription }
        if let error = error as? IOSMcpClientError {
            switch error {
            case .httpStatus(let code): return "MCP 服务返回 HTTP \(code)，请检查地址与认证。"
            case .mcpSessionExpired: return "MCP 会话已失效，请重新连接；工具未自动重试。"
            case .requestTimedOut: return "MCP 请求超时，请重新连接后重试。"
            default: return "MCP 连接或工具请求失败，请检查服务与参数后重试。"
            }
        }
        return "无法连接 MCP 服务，请检查进程、网络与配置。"
    }

    private static func outcomeIsUnknown(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError || error is DesktopMCPTransportError { return true }
        guard let error = error as? IOSMcpClientError else { return false }
        switch error {
        case .invalidResponse, .requestTimedOut: return true
        case .httpStatus(let status): return status == 408 || status >= 500
        default: return false
        }
    }

    nonisolated static let declarations: [DesktopToolDeclaration] = [
        declaration("mcp_list", "列出已启用的 MCP 服务 ID 和已发现的工具。", properties: [:], required: []),
        declaration("mcp_describe_tool", "读取 MCP 工具的真实输入 JSON Schema；调用前先检查该 schema。",
            properties: ["server_id": ["type": "string"], "name": ["type": "string"]], required: ["server_id", "name"]),
        declaration("mcp_call_tool", "调用已配置并启用的 MCP 工具，需要用户批准。调用不会在失败后自动重放。",
            properties: ["server_id": ["type": "string"], "name": ["type": "string"],
                         "arguments": ["type": "object", "additionalProperties": true]],
            required: ["server_id", "name", "arguments"], approval: true),
    ]

    nonisolated private static func declaration(_ name: String, _ description: String, properties: [String: Any], required: [String], approval: Bool = false) -> DesktopToolDeclaration {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "object", "properties": properties,
            "required": required, "additionalProperties": false], options: [.sortedKeys])
        return DesktopToolDeclaration(name: name, description: description, parametersJSON: String(decoding: data, as: UTF8.self), needsApproval: approval)
    }
}
