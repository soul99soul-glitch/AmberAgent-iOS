import Darwin
import Foundation

public struct GatewayPaths: Sendable {
    public static let stateDirEnv = "AMBER_GATEWAY_STATE_DIR"

    public let stateDir: URL
    public var socket: URL { stateDir.appendingPathComponent("gateway.sock") }
    /// Served by the Amber Mac app while it runs; the daemon forwards phone requests about scheduled tasks here.
    public var amberSocket: URL { stateDir.appendingPathComponent("amber-app.sock") }
    public var spoolDir: URL { stateDir.appendingPathComponent("spool", isDirectory: true) }
    public var registry: URL { stateDir.appendingPathComponent("registry.json") }
    public var outbox: URL { stateDir.appendingPathComponent("outbox.jsonl") }
    public var pidFile: URL { stateDir.appendingPathComponent("daemon.pid") }
    public var config: URL { stateDir.appendingPathComponent("config.json") }
    public var log: URL { stateDir.appendingPathComponent("daemon.log") }
    public var devices: URL { stateDir.appendingPathComponent("devices.json") }
    public var pairing: URL { stateDir.appendingPathComponent("pairing.json") }
    public var identity: URL { stateDir.appendingPathComponent("gateway.json") }
    public var audit: URL { stateDir.appendingPathComponent("audit.jsonl") }
    public var secretsDir: URL { stateDir.appendingPathComponent("secrets", isDirectory: true) }
    public var tlsIdentity: URL { secretsDir.appendingPathComponent("tls.p12") }

    public init(stateDir: URL) {
        self.stateDir = stateDir
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> GatewayPaths {
        if let dir = environment[stateDirEnv], !dir.isEmpty {
            return GatewayPaths(stateDir: URL(fileURLWithPath: dir, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GatewayPaths(stateDir: home.appendingPathComponent("Library/Application Support/AmberAgent/Gateway", isDirectory: true))
    }

    /// The daemon holds an exclusive flock on its pid file for its whole lifetime.
    public var daemonRunning: Bool {
        let fd = open(pidFile.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    /// State dir is 700: the hook socket's only access control is filesystem permissions.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [stateDir, spoolDir, secretsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

public enum GatewayJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

public struct RegistryStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Registry {
        guard let data = try? Data(contentsOf: url),
              var registry = try? GatewayJSON.decoder().decode(Registry.self, from: data)
        else { return Registry() }
        // Titles recorded before host-injected turns were filtered out (see HookParser.summary).
        for key in registry.sessions.keys where registry.sessions[key]?.summary?.hasPrefix("<") == true {
            registry.sessions[key]?.summary = nil
            registry.sessions[key]?.opening = nil
        }
        return registry
    }

    public func save(_ registry: Registry) throws {
        let data = try GatewayJSON.encoder(pretty: true).encode(registry)
        try data.write(to: url, options: .atomic)
    }
}

/// Events the hook couldn't hand to the daemon within its time budget. One file per event,
/// written via rename so the daemon never reads a partial file.
public struct Spool: Sendable {
    public let dir: URL

    public init(dir: URL) {
        self.dir = dir
    }

    public func write(_ event: GatewayEvent) throws {
        let data = try GatewayJSON.encoder().encode(event)
        let name = String(format: "%.6f", event.timestamp.timeIntervalSince1970) + "-" + event.id + ".json"
        let tmp = dir.appendingPathComponent("." + name + ".tmp")
        try data.write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent(name))
    }

    public func isEmpty() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !names.contains { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
    }

    /// Hands spooled events to `handle` in timestamp order and deletes each one afterwards.
    public func drain(_ handle: (GatewayEvent) -> Void) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        let decoder = GatewayJSON.decoder()
        for name in names {
            let url = dir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let event = try? decoder.decode(GatewayEvent.self, from: data) {
                handle(event)
            }
            try? fm.removeItem(at: url)
        }
    }
}

public struct Outbox: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ intent: PushIntent) throws {
        var data = try GatewayJSON.encoder().encode(intent)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func recent(limit: Int) -> [PushIntent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = GatewayJSON.decoder()
        return text.split(separator: "\n").suffix(limit).compactMap {
            try? decoder.decode(PushIntent.self, from: Data($0.utf8))
        }
    }
}
