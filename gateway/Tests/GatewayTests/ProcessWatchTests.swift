import Foundation
import Testing
@testable import GatewayCore
@testable import HookIngest
@testable import SessionWatch

private final class ExitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProcessIdentity] = []
    func add(_ id: ProcessIdentity) { lock.lock(); items.append(id); lock.unlock() }
    var all: [ProcessIdentity] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite("Process identity and exit watching", .serialized)
struct ProcessWatchTests {
    func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    @Test func identityOfSelf() throws {
        let me = try #require(ProcessTree.snapshot(pid: getpid()))
        #expect(me.identity.startSec > 0)
        #expect(me.parent > 0)
        #expect(try #require(ProcessTree.arguments(pid: getpid())).count >= 1)
    }

    @Test func killNineIsReportedWithinSeconds() throws {
        let sleeper = try spawnSleeper()
        let id = try #require(ProcessTree.identity(pid: sleeper.processIdentifier))
        let queue = DispatchQueue(label: "test.watch")
        let log = ExitLog()
        let watcher = ProcessWatcher(queue: queue, currentIdentity: ProcessTree.identity(pid:)) { log.add($0) }
        queue.sync { watcher.watch(id) }

        usleep(300_000)
        #expect(log.all.isEmpty, "control: alive process must not be reported")

        let killedAt = Date()
        kill(sleeper.processIdentifier, SIGKILL)
        #expect(TestSupport.eventually(timeout: 3) { log.all == [id] })
        #expect(Date().timeIntervalSince(killedAt) < 1.0)
        sleeper.waitUntilExit()
    }

    @Test func recycledPidIsTreatedAsGone() throws {
        let sleeper = try spawnSleeper()
        defer { sleeper.terminate() }
        let real = try #require(ProcessTree.identity(pid: sleeper.processIdentifier))
        // Same PID, different start time: what a registry entry looks like after the PID was reused.
        let stale = ProcessIdentity(pid: real.pid, startSec: real.startSec - 100, startUsec: real.startUsec)
        let queue = DispatchQueue(label: "test.watch")
        let log = ExitLog()
        let watcher = ProcessWatcher(queue: queue, currentIdentity: ProcessTree.identity(pid:)) { log.add($0) }
        queue.sync { watcher.watch(stale) }
        #expect(TestSupport.eventually(timeout: 1) { log.all == [stale] })
        #expect(watcher.watchedCount == 0)
    }

    @Test func alreadyExitedProcessIsReportedGone() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        let id = ProcessTree.identity(pid: p.processIdentifier) ?? ProcessIdentity(pid: p.processIdentifier, startSec: 1, startUsec: 0)
        p.waitUntilExit()
        let queue = DispatchQueue(label: "test.watch")
        let log = ExitLog()
        let watcher = ProcessWatcher(queue: queue, currentIdentity: ProcessTree.identity(pid:)) { log.add($0) }
        queue.sync { watcher.watch(id) }
        #expect(TestSupport.eventually(timeout: 1) { log.all == [id] })
    }
}
