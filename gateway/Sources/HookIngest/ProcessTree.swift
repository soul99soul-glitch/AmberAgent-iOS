import Darwin
import Foundation
import GatewayCore

public struct ProcessSnapshot: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var parent: Int32
    public var path: String

    public var name: String { (path as NSString).lastPathComponent }
}

public enum ProcessTree {
    public static func snapshot(pid: Int32) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : withUnsafeBytes(of: info.pbi_comm) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startSec: Int64(info.pbi_start_tvsec), startUsec: Int64(info.pbi_start_tvusec)),
            parent: Int32(info.pbi_ppid),
            path: path
        )
    }

    /// Current identity of `pid`, used to reject a recycled PID before watching it.
    public static func identity(pid: Int32) -> ProcessIdentity? {
        snapshot(pid: pid)?.identity
    }

    /// Walks up from `pid` (inclusive) until `matches` accepts a process. Hooks are launched through
    /// `sh -c`, so the immediate parent is a short-lived shell, not the agent.
    public static func findAncestor(from pid: Int32, maxDepth: Int = 16, where matches: (ProcessSnapshot) -> Bool) -> ProcessSnapshot? {
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, let snap = snapshot(pid: current) else { return nil }
            if matches(snap) { return snap }
            current = snap.parent
        }
        return nil
    }

    public static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 } // exec path
        while index < size && buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        while args.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}

public enum AgentProcess {
    public static func isAgent(_ snap: ProcessSnapshot, source: AgentKind) -> Bool {
        switch source {
        case .claude:
            // Native installer: `~/.local/bin/claude` -> `~/.local/share/claude/versions/<version>`, and the
            // kernel reports the resolved path.
            if snap.name == "claude" || snap.path.contains("/claude/versions/") { return true }
            guard snap.name == "node" else { return false }
            return ProcessTree.arguments(pid: snap.identity.pid)?.contains { $0.contains("claude-code") } ?? false
        case .codex:
            return snap.name == "codex"
        case .run, .amber:
            return false
        }
    }

    public static func origin(source: AgentKind, arguments args: [String]) -> SessionOrigin {
        let rest = Array(args.dropFirst())
        switch source {
        case .codex:
            // The CLI's own managed daemon serves terminal (TUI) sessions, not an app host.
            if rest.contains("--managed-daemon") { return .interactive }
            if rest.contains("app-server") || rest.contains("mcp-server") { return .host }
            if rest.contains("exec") || rest.contains("e") { return .headless }
            return .interactive
        case .claude:
            if let i = rest.firstIndex(of: "--input-format"), rest.indices.contains(i + 1), rest[i + 1] == "stream-json" {
                return .host
            }
            if rest.contains("--input-format=stream-json") { return .host }
            if rest.contains("-p") || rest.contains("--print") { return .headless }
            return .interactive
        case .run, .amber:
            return .headless
        }
    }

    /// False for Codex's CLI-managed app-server daemon: every terminal session shares it and upgrades replace
    /// it, so its exit must not end (or push "stopped") any single session. Those sessions rely on hook events.
    public static func ownsSession(arguments args: [String]) -> Bool {
        !args.contains("--managed-daemon")
    }

    /// Outermost `.app` bundle in `path`, so a helper inside `Synara.app/Contents/Frameworks/...` still names Synara.
    public static func hostApp(path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    /// Finds the agent process above the hook and classifies how it was launched. Host sessions also
    /// report the app that spawned the agent (e.g. Synara).
    public static func locate(source: AgentKind, from pid: Int32 = getppid()) -> (ProcessIdentity?, SessionOrigin, String?)? {
        guard let snap = ProcessTree.findAncestor(from: pid, where: { isAgent($0, source: source) }) else { return nil }
        let args = ProcessTree.arguments(pid: snap.identity.pid) ?? []
        let origin = origin(source: source, arguments: args)
        guard ownsSession(arguments: args) else { return (nil, origin, nil) }
        guard origin == .host else { return (snap.identity, origin, nil) }
        let host = ProcessTree.findAncestor(from: snap.parent, where: { hostApp(path: $0.path) != nil }).flatMap { hostApp(path: $0.path) }
        return (snap.identity, origin, host)
    }
}
