import Foundation

public struct GatewayConfig: Codable, Sendable, Equatable {
    /// Seconds of keyboard/mouse idleness after which the user counts as away.
    public var presenceThreshold: Double = 60
    /// Permission prompts block the agent, so they escalate sooner.
    public var permissionPresenceThreshold: Double = 20
    /// Same (session, state) is not pushed twice within this window. "Waiting" is exempt.
    public var dedupeWindow: Double = 600
    /// Sessions whose cwd starts with any of these prefixes are ignored entirely. Default: Codex's internal
    /// memory-consolidation sessions, which run alongside real sessions and are not user tasks.
    public var excludeCwdPrefixes: [String] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/memories").path,
    ]

    /// A headless task with no event for this long becomes "stalled". 0 disables.
    public var headlessStallMinutes: Double = 60
    public var diskFreeThresholdGB: Double = 20
    public var batteryThresholdPercent: Int = 20
    /// Hold an idle-sleep assertion while a headless task runs. Does not stop lid-close sleep on battery.
    public var preventIdleSleepWhileRunning = false
    /// HTTPS control API port (design doc 5.1).
    public var port: UInt16 = 47821
    /// Extra hosts that reach this Mac from outside the LAN on the same port (e.g. a VPS reverse tunnel).
    /// They go into the pairing QR after the `.local`/Tailscale names and before LAN IPs.
    public var publicAddresses: [String] = []
    /// Synara web address reachable from the phone (e.g. behind the VPS). Tasks hosted by Synara are
    /// answered there; the phone opens it in the browser.
    public var synaraURL: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GatewayConfig()
        presenceThreshold = try c.decodeIfPresent(Double.self, forKey: .presenceThreshold) ?? d.presenceThreshold
        permissionPresenceThreshold = try c.decodeIfPresent(Double.self, forKey: .permissionPresenceThreshold) ?? d.permissionPresenceThreshold
        dedupeWindow = try c.decodeIfPresent(Double.self, forKey: .dedupeWindow) ?? d.dedupeWindow
        excludeCwdPrefixes = try c.decodeIfPresent([String].self, forKey: .excludeCwdPrefixes) ?? d.excludeCwdPrefixes
        headlessStallMinutes = try c.decodeIfPresent(Double.self, forKey: .headlessStallMinutes) ?? d.headlessStallMinutes
        diskFreeThresholdGB = try c.decodeIfPresent(Double.self, forKey: .diskFreeThresholdGB) ?? d.diskFreeThresholdGB
        batteryThresholdPercent = try c.decodeIfPresent(Int.self, forKey: .batteryThresholdPercent) ?? d.batteryThresholdPercent
        preventIdleSleepWhileRunning = try c.decodeIfPresent(Bool.self, forKey: .preventIdleSleepWhileRunning) ?? d.preventIdleSleepWhileRunning
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        publicAddresses = try c.decodeIfPresent([String].self, forKey: .publicAddresses) ?? d.publicAddresses
        synaraURL = try c.decodeIfPresent(String.self, forKey: .synaraURL)
    }

    public static func load(from url: URL) -> GatewayConfig {
        guard let data = try? Data(contentsOf: url) else { return GatewayConfig() }
        do {
            return try JSONDecoder().decode(GatewayConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("\(url.path) 无法解析，全部使用默认配置: \(error)\n".utf8))
            return GatewayConfig()
        }
    }

    /// Prefixes match whole path components: `/w/secret` excludes `/w/secret/x` but not `/w/secretive`.
    public func isExcluded(cwd: String?) -> Bool {
        guard let cwd else { return false }
        return excludeCwdPrefixes.contains { prefix in
            cwd == prefix || cwd.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
        }
    }
}
