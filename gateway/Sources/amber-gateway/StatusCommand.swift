import Darwin
import Foundation
import GatewayCore

/// Reads the daemon's persisted state directly, so it also works over SSH and while the daemon is down.
enum StatusCommand {
    struct Report: Encodable {
        var daemonRunning: Bool
        var stateDir: String
        var health: HealthSnapshot?
        var sessions: [SessionRecord]
        var recentPushes: [PushIntent]
    }

    static func run(_ args: [String]) -> Int32 {
        let paths = GatewayPaths.resolve()
        let registry = RegistryStore(url: paths.registry).load()
        let report = Report(
            daemonRunning: daemonRunning(paths),
            stateDir: paths.stateDir.path,
            health: registry.health,
            sessions: registry.sessions.values.sorted { $0.updatedAt > $1.updatedAt },
            recentPushes: Outbox(url: paths.outbox).recent(limit: 10)
        )

        if args.contains("--json") {
            guard let data = try? GatewayJSON.encoder(pretty: true).encode(report) else { return 1 }
            FileHandle.standardOutput.write(data)
            print()
            return 0
        }

        print("daemon: \(report.daemonRunning ? "运行中" : "未运行（amber-gateway install 会注册开机自启并立即启动）")    状态目录: \(report.stateDir)")
        if let h = report.health {
            var parts: [String] = []
            if let bytes = h.diskFreeBytes { parts.append(String(format: "磁盘剩余 %.0f GB", Double(bytes) / 1_000_000_000)) }
            if let b = h.batteryPercent { parts.append("电量 \(b)%\(h.onBattery == true ? "" : "（接电源）")") }
            let memory = switch h.memoryPressure { case .normal: "正常"; case .warning: "偏高"; case .critical: "严重" }
            let thermal = switch h.thermal { case .nominal: "正常"; case .fair: "偏高"; case .serious: "过高"; case .critical: "严重" }
            parts.append("内存压力 \(memory)")
            parts.append("温度 \(thermal)")
            print("本机: \(parts.joined(separator: " · "))    更新于 \(relative(h.sampledAt))")
        }
        if report.sessions.isEmpty {
            print("\n（暂无任务）")
        } else {
            print("\n\(pad("状态", 26)) \(pad("代理", 12)) \(pad("来源", 6)) \(pad("任务", 28)) 更新")
            for s in report.sessions {
                var state = s.state.label(s.waitReason, abnormal: s.abnormal)
                if s.pendingPushSince != nil { state += "，待推送" }
                if !s.monitored { state += "，未监控" }
                print("\(pad(state, 26)) \(pad(s.agent.displayName, 12)) \(pad(originLabel(s.origin), 6)) \(pad(Registry.subject(for: s), 28)) \(relative(s.updatedAt))")
            }
        }
        if !report.recentPushes.isEmpty {
            print("\n最近推送:")
            for p in report.recentPushes.reversed() {
                let text = PushContent.render(p, gatewayName: "Mac")
                print("  \(pad(relative(p.createdAt), 10)) \(text.title) — \(text.body)")
            }
        }
        return 0
    }

    static func daemonRunning(_ paths: GatewayPaths) -> Bool {
        let fd = open(paths.pidFile.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func originLabel(_ origin: SessionOrigin) -> String {
        switch origin {
        case .interactive: "交互"
        case .headless: "后台"
        case .host: "宿主"
        }
    }

    /// Pads (or truncates with "…") to a terminal column width. CJK and fullwidth forms take two columns.
    static func pad(_ s: String, _ width: Int) -> String {
        func columns(_ c: Character) -> Int { (c.unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 2 : 1 }
        let total = s.reduce(0) { $0 + columns($1) }
        if total <= width { return s + String(repeating: " ", count: width - total) }
        var out = "", used = 0
        for c in s {
            guard used + columns(c) <= width - 1 else { break }
            out.append(c)
            used += columns(c)
        }
        return out + "…" + String(repeating: " ", count: width - 1 - used)
    }

    static func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "\(max(s, 0))秒前"
        case ..<3600: return "\(s / 60)分钟前"
        case ..<86400: return "\(s / 3600)小时前"
        default: return "\(s / 86400)天前"
        }
    }
}
