import Foundation
import Darwin

struct DesktopMCPTransportError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

// The shared JSON-RPC client owns handshake, request ordering, IDs and deadlines.
@MainActor final class DesktopMCPStdioTransport: IOSMcpHTTPTransport {
    private let configuration: DesktopMCPServer
    private var process: Process?
    private var ownedGroup: pid_t?
    private(set) var terminationTask: Task<Void, Never>?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var generation: UUID?
    private var pending: [Int: CheckedContinuation<IOSMcpHTTPResponse, Error>] = [:]
    private let writer = DispatchQueue(label: "app.amber.mcp.stdin")

    init(configuration: DesktopMCPServer) { self.configuration = configuration }

    func sendJSONRPC(_ payload: [String: Any], to config: IOSMcpServerConfig) async throws -> IOSMcpHTTPResponse {
        try startIfNeeded(initializing: payload["method"] as? String == "initialize")
        let generation = self.generation
        guard let id = payload["id"] as? Int else { throw IOSMcpClientError.invalidResponse }
        let data = try frame(payload)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                write(data) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard self?.generation == generation else { return }
                        self?.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                self?.close(error: CancellationError())
            }
        }
    }

    func sendJSONRPCNotification(_ payload: [String: Any], to config: IOSMcpServerConfig) async throws -> IOSMcpHTTPResponse {
        try startIfNeeded(initializing: false)
        let data = try frame(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            write(data) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return IOSMcpHTTPResponse(status: 202)
    }

    func disconnect(config: IOSMcpServerConfig) { close(error: CancellationError()) }

    private func startIfNeeded(initializing: Bool) throws {
        if let process, process.isRunning { return }
        guard initializing else { throw DesktopRuntimeError.message("MCP 进程已断开，请先重新连接服务。") }
        try configuration.validate()
        let child = Process()
        let generation = UUID()
        self.generation = generation
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        if configuration.command.hasPrefix("/") {
            child.executableURL = URL(fileURLWithPath: configuration.command)
            child.arguments = configuration.arguments
        } else {
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = [configuration.command] + configuration.arguments
        }
        child.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, configured in configured }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let reads = DesktopMCPReadQueue()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard reads.append(data) else { return }
            Task { @MainActor in
                for chunk in reads.drain() {
                    guard self?.generation == generation else { return }
                    self?.receive(chunk)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        do {
            try child.run()
            let pid = child.processIdentifier
            if pid > 1, getpgid(pid) == pid, pid != getpgrp() { ownedGroup = pid }
        }
        catch {
            close(error: DesktopRuntimeError.message("无法启动 MCP 命令，请检查可执行文件和参数。"))
            throw DesktopRuntimeError.message("无法启动 MCP 命令，请检查可执行文件和参数。")
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            close(error: DesktopMCPTransportError(message: "MCP 标准输出已关闭，请重新连接。"))
            return
        }
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else {
            close(error: DesktopMCPTransportError(message: "MCP 响应超过 16 MB，请缩小工具结果后重试。"))
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                close(error: IOSMcpClientError.invalidResponse)
                return
            }
            if let id = object["id"] as? Int, object["result"] != nil || object["error"] != nil {
                pending.removeValue(forKey: id)?.resume(returning: IOSMcpHTTPResponse(status: 200, body: line))
            } else if let id = object["id"], let method = object["method"] as? String {
                let response: [String: Any] = method == "ping"
                    ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                    : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Client method is not supported"]]
                if let data = try? frame(response) { write(data) { _ in } }
            }
        }
    }

    private func frame(_ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func write(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        guard let input else { completion(CancellationError()); return }
        writer.async {
            do { try input.write(contentsOf: data); completion(nil) }
            catch { completion(DesktopMCPTransportError(message: "无法向 MCP 进程写入请求，请重新连接。")) }
        }
    }

    private func close(error: Error) {
        let child = process
        let group = ownedGroup
        process = nil
        ownedGroup = nil
        generation = nil
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil; output = nil; errors = nil
        buffer.removeAll(keepingCapacity: false)
        let waiting = Array(pending.values)
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
        if let child, child.isRunning || group.map({ Darwin.kill(-$0, 0) == 0 }) == true {
            if let group { _ = Darwin.kill(-group, SIGTERM) }
            else { child.terminate() }
            terminationTask = Task.detached {
                try? await Task.sleep(for: .milliseconds(500))
                if let group, Darwin.kill(-group, 0) == 0 { _ = Darwin.kill(-group, SIGKILL) }
                else if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                if child.isRunning { child.waitUntilExit() }
            }
        }
    }
}

// One actor drain preserves pipe byte order across independent callback tasks.
private final class DesktopMCPReadQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var scheduled = false

    func append(_ data: Data) -> Bool {
        lock.withLock {
            chunks.append(data)
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }

    func drain() -> [Data] {
        lock.withLock {
            let result = chunks
            chunks.removeAll(keepingCapacity: true)
            scheduled = false
            return result
        }
    }
}
