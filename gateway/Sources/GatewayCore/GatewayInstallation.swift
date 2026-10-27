import Darwin
import Foundation

/// Where the gateway lives on disk and how it hooks into Claude Code / Codex. Shared by the CLI
/// (`amber-gateway install`) and the Amber Mac app, which embeds the binary and registers it with
/// `SMAppService` instead of writing a LaunchAgent itself.
public struct GatewayInstallation: Sendable {
    /// Label of the LaunchAgent the CLI writes. The Amber app migrates away from it on enable.
    public static let cliLaunchdLabel = "com.amberagent.gateway"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Hooks point at this stable symlink, so the hook definition Codex trusted in `/hooks` never changes.
    public var link: URL { home.appendingPathComponent(".local/bin/amber-gateway") }
    /// CLI deployment: the daemon runs from a private copy so `swift build` can't swap the binary under launchd.
    public var cliBinary: URL { home.appendingPathComponent(".local/share/amber-gateway/bin/amber-gateway") }
    public var cliPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.cliLaunchdLabel).plist") }
    public var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    public var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }

    public func hookCommand(_ source: String) -> String { "'\(link.path)' hook \(source)" }

    public struct FileChange: Sendable {
        public var url: URL
        public var events: Int
        public var changed: Bool
        public var backup: URL?
    }

    /// `each` runs right after its file is written, so a failure on the second file still reports the first.
    @discardableResult
    public func installHooks(dryRun: Bool = false, each: (FileChange) -> Void = { _ in }) throws -> [FileChange] {
        var changes: [FileChange] = []
        for (url, events, source) in [(claudeSettings, HookInstaller.claudeEvents, "claude"), (codexHooks, HookInstaller.codexEvents, "codex")] {
            let result = try HookInstaller.updateFile(at: url, dryRun: dryRun) {
                HookInstaller.installing(into: $0, events: events, command: hookCommand(source))
            }
            let change = FileChange(url: url, events: events.count, changed: result.changed, backup: result.backup)
            each(change)
            changes.append(change)
        }
        return changes
    }

    @discardableResult
    public func removeHooks(dryRun: Bool = false, each: (FileChange) -> Void = { _ in }) throws -> [FileChange] {
        var changes: [FileChange] = []
        for url in [claudeSettings, codexHooks] where FileManager.default.fileExists(atPath: url.path) {
            let result = try HookInstaller.updateFile(at: url, dryRun: dryRun, transform: HookInstaller.removing)
            let change = FileChange(url: url, events: 0, changed: result.changed, backup: result.backup)
            each(change)
            changes.append(change)
        }
        return changes
    }

    /// Where the symlink points now, if it is one.
    public var linkTarget: URL? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map {
            URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        }
    }

    /// Points the symlink at `binary`. A regular file in its place is never overwritten.
    public func linkBinary(_ binary: URL, dryRun: Bool = false) throws {
        let fm = FileManager.default
        if let existing = linkTarget {
            if existing.path == binary.path { return }
            if !dryRun { try fm.removeItem(at: link) }
        } else if fm.fileExists(atPath: link.path) {
            throw Failure("\(link.path) 已存在且不是软链，拒绝覆盖")
        }
        if dryRun { return }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: binary)
    }

    public func removeLink() throws {
        if linkTarget != nil { try FileManager.default.removeItem(at: link) }
    }

    /// Copies via rename so a running daemon's mapped image stays intact.
    public static func copyBinary(_ binary: URL, to target: URL, dryRun: Bool = false) throws {
        guard binary.path != target.path, !dryRun else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = target.appendingPathExtension("new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: binary, to: tmp)
        guard rename(tmp.path, target.path) == 0 else { throw Failure("无法替换 \(target.path): errno \(errno)") }
    }

    public var hasCLIDeployment: Bool {
        FileManager.default.fileExists(atPath: cliPlist.path) || FileManager.default.fileExists(atPath: cliBinary.path)
    }

    /// Stops and removes the CLI's LaunchAgent and private binary copy. The state directory is untouched.
    public func removeCLIDeployment(manageLaunchd: Bool = true) {
        if manageLaunchd { _ = Self.launchctl(["bootout", "gui/\(getuid())/\(Self.cliLaunchdLabel)"]) }
        try? FileManager.default.removeItem(at: cliPlist)
        try? FileManager.default.removeItem(at: cliBinary)
    }

    @discardableResult
    public static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
