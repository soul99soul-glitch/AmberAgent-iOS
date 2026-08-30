import Foundation
import UIKit

/// 把「这一轮后台生成能不能活下来」的全部信号压成一行。
///
/// 后台没法下断点，事后只能靠日志定罪：所以每次生命周期变化、每次后台任务
/// 起止/到期都打一条同构的快照，包含 App 状态、剩余后台时间、以及协调器
/// 自己的在飞任务数。同时把最近若干条保存在诊断环形缓冲中，供下次启动排查。
@MainActor
enum IOSBackgroundLifecycleLog {
    struct Entry: Codable {
        let at: Date
        let line: String
    }

    private static let ringCapacity = 64
    private static let persistedRingKey = "app.amber.ios.backgroundLifecycle.recent"
    private static var ring: [Entry] = loadPersistedRing()

    /// 当前或上次进程最近一条快照；从未记录时为 nil。
    private(set) static var lastLine: String? = ring.last?.line

    /// 最近若干条快照，最新的在最后。诊断入口读取用。
    static var recentEntries: [Entry] { ring }

    static func record(_ transition: String, detail: String = "") {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        // backgroundTimeRemaining 在前台是一个极大的哨兵值，原样打出来只会是噪音。
        let remainingText = remaining > 99_999
            ? "unlimited"
            : String(format: "%.0fs", remaining)
        var line = "[BGLifecycle] → \(transition)"
            + " | app=\(applicationStateText)"
            + " bgRemaining=\(remainingText)"
        if !detail.isEmpty {
            line += " | \(detail)"
        }
        lastLine = line
        ring.append(Entry(at: Date(), line: line))
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        persistRing()
        NSLog("%@", line)
    }

    private static func loadPersistedRing() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: persistedRingKey),
              let entries = try? PropertyListDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return Array(entries.suffix(ringCapacity))
    }

    private static func persistRing() {
        guard let data = try? PropertyListEncoder().encode(ring) else { return }
        UserDefaults.standard.set(data, forKey: persistedRingKey)
    }

    private static var applicationStateText: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
