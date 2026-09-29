import Foundation
import UIKit

/// 把「这一轮后台生成能不能活下来」的全部信号压成一行，同构快照存进诊断
/// 环形缓冲供下次启动排查。
///
/// - 内存态（`ring`/`lastLine`）在 `record()` 调用时同步更新，立刻可见；
///   落盘/读盘挪到后台串行队列，避免 `record()` 的高频主线程调用点
///   （`AppShell.handleScenePhaseChange` 等）被 `UserDefaults` 读写
///   （测试沙盒约 0.3～2ms，真机可达数百毫秒，见
///   docs/reviews/2026-09-29-ios-performance-program.md P7-2）阻塞。
/// - 落盘队列严格 FIFO 且每次全量覆盖写，磁盘上任何时刻都是某个自洽快照，
///   不会有半条目或错序。
@MainActor
enum IOSBackgroundLifecycleLog {
    struct Entry: Codable {
        let at: Date
        let line: String
    }

    nonisolated private static let ringCapacity = 64
    nonisolated private static let persistedRingKey = "app.amber.ios.backgroundLifecycle.recent"

    /// 落盘/读盘专用串行队列：不占用 MainActor，且严格保序。
    private static let persistenceQueue = DispatchQueue(
        label: "app.amber.ios.backgroundLifecycleLog.persistence",
        qos: .utility
    )

    private static var ring: [Entry] = []
    /// `bootstrap()` idempotency guard: only the first call actually reads
    /// disk and merges history.
    private static var hasBootstrapped = false

    /// 当前或上次进程最近一条快照；从未记录时为 nil。`record()` 永远同步
    /// 更新它；上一进程的历史行在 `bootstrap()` 异步补齐前不会出现在这里，
    /// 但本进程新记的每一条都是即时可见的。
    private(set) static var lastLine: String?

    /// 最近若干条快照，最新的在最后。诊断入口读取用。
    static var recentEntries: [Entry] { ring }

    /// 从磁盘补齐上一进程的历史。建议在 App 启动早期调用一次（例如
    /// `didFinishLaunchingWithOptions`）；不调用也不影响 `record()` 的正确性，
    /// 只是诊断环形缓冲会缺少上一进程的行。
    ///
    /// 读盘的 `persistenceQueue.async` 在本方法的调用栈内同步入队——不是
    /// 从某个稍后才启动的 Task 里——这样它必定排在此刻之后才会发生的任何
    /// `record()`（及其 `persistRingAsync`）写入之前，补齐的历史不会被
    /// 新记录污染成「历史」。合并结果回到主线程后按「历史在前、补齐期间
    /// 新记录在后」拼接，再按容量裁剪。
    static func bootstrap(completion: (@Sendable () -> Void)? = nil) {
        guard !hasBootstrapped else {
            completion?()
            return
        }
        hasBootstrapped = true
        persistenceQueue.async {
            let loaded = loadPersistedRingFromDisk()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ring = Array((loaded + ring).suffix(ringCapacity))
                    if lastLine == nil {
                        lastLine = ring.last?.line
                    }
                    // 补齐前的 record() 已用不含历史的 ring 覆盖了磁盘，合并后重写一次。
                    if !loaded.isEmpty { persistRingAsync() }
                    completion?()
                }
            }
        }
    }

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
        persistRingAsync()
        NSLog("%@", line)
    }

    /// 捕获调用时的快照（值类型，跨线程安全）后转到后台串行队列全量覆盖写。
    private static func persistRingAsync() {
        let snapshot = ring
        persistenceQueue.async {
            guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: persistedRingKey)
        }
    }

    nonisolated private static func loadPersistedRingFromDisk() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: persistedRingKey),
              let entries = try? PropertyListDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return Array(entries.suffix(ringCapacity))
    }

    /// Test-only: blocks until every write enqueued on the persistence queue
    /// so far (`persistRingAsync`) has run. Does not wait on `bootstrap()`;
    /// use `bootstrapForTesting()` for that.
    static func flushPendingPersistenceForTesting() async {
        await withCheckedContinuation { continuation in
            persistenceQueue.async {
                continuation.resume()
            }
        }
    }

    /// Test-only: async-await wrapper around `bootstrap(completion:)` for
    /// tests that just need to wait for the merge, with no interleaving.
    static func bootstrapForTesting() async {
        await withCheckedContinuation { continuation in
            bootstrap { continuation.resume() }
        }
    }

    /// Test-only: resets all static state (including the persisted disk copy)
    /// so tests don't leak into each other.
    static func resetForTesting() {
        ring = []
        lastLine = nil
        hasBootstrapped = false
        UserDefaults.standard.removeObject(forKey: persistedRingKey)
    }

    /// Test-only: resets in-memory state but leaves whatever is already on
    /// disk untouched, so a following `bootstrap()` call has something to
    /// reload (simulates a fresh process after a real one persisted data).
    static func resetForTestingKeepingDisk() {
        ring = []
        lastLine = nil
        hasBootstrapped = false
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
