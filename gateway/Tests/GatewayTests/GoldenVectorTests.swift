import Foundation
import Testing
@testable import GatewayCore

struct VectorCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Step: Decodable, Sendable {
        var at: Double
        var event: VectorEvent?
        var processExit: ProcessIdentity?
        var tick: VectorPresence?
        var presence: VectorPresence?
        var heartbeat: VectorHealth?
    }

    struct VectorHealth: Decodable, Sendable {
        var diskGB: Double?
        var battery: Int?
        var onBattery: Bool?
        var memory: HealthSnapshot.MemoryPressure?
        var thermal: HealthSnapshot.Thermal?

        func make(at date: Date) -> HealthSnapshot {
            HealthSnapshot(sampledAt: date, diskFreeBytes: Int64((diskGB ?? 500) * 1_000_000_000), batteryPercent: battery,
                           onBattery: onBattery, memoryPressure: memory ?? .normal, thermal: thermal ?? .nominal)
        }
    }

    struct VectorPresence: Decodable, Sendable {
        var locked: Bool
        var idle: Double
        var value: Presence { Presence(screenLocked: locked, idleSeconds: idle) }
    }

    struct VectorEvent: Decodable, Sendable {
        var id: String?
        var agent: AgentKind
        var kind: EventKind
        var sessionId: String
        var cwd: String?
        var process: ProcessIdentity?
        var origin: SessionOrigin?
        var title: String?
        var exitCode: Int32?
        var signal: Int32?
        var tool: String?

        func make(step: Int, at date: Date) -> GatewayEvent {
            GatewayEvent(
                id: id ?? "step-\(step)", agent: agent, kind: kind, sessionId: sessionId, cwd: cwd,
                timestamp: date, process: process, origin: origin, title: title, exitCode: exitCode, signal: signal, tool: tool
            )
        }
    }

    struct Expect: Decodable, Sendable {
        struct Session: Decodable, Sendable {
            var state: TaskState?
            var waitReason: WaitReason?
            var abnormal: Bool?
            var origin: SessionOrigin?
            var pending: Bool?
        }

        struct Push: Decodable, Sendable {
            var kind: PushIntent.Kind?
            var detail: String?
            var session: String?
            var state: TaskState?
            var waitReason: WaitReason?
            var abnormal: Bool?
            var level: PushIntent.Level?
            var subject: String?
            var atStep: Int?
        }

        var sessions: [String: Session]?
        var pushes: [Push]?
        var sessionCount: Int?
    }

    var name: String
    var config: GatewayConfig?
    var steps: [Step]
    var expect: Expect

    var testDescription: String { name }
}

private struct VectorFile: Decodable {
    var cases: [VectorCase]
}

private func loadVectors() throws -> [VectorCase] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/golden/state-vectors", withExtension: "json"))
    return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).cases
}

@Suite("Golden state vectors")
struct GoldenVectorTests {
    @Test(arguments: try loadVectors())
    func vector(_ c: VectorCase) throws {
        var registry = Registry()
        let config = c.config ?? GatewayConfig()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var pushes: [(step: Int, intent: PushIntent)] = []

        for (index, step) in c.steps.enumerated() {
            let now = base.addingTimeInterval(step.at)
            let presence = step.presence?.value ?? Presence(screenLocked: false, idleSeconds: 0)
            let effects: [RegistryEffect]
            if let event = step.event {
                effects = registry.ingest(event.make(step: index, at: now), config: config, now: now, presence: { presence })
            } else if let process = step.processExit {
                effects = registry.processExited(process, config: config, now: now)
            } else if let tick = step.tick {
                effects = registry.tick(config: config, now: now, presence: tick.value)
            } else if let health = step.heartbeat {
                effects = registry.heartbeat(health.make(at: now), config: config, now: now)
            } else {
                Issue.record("step \(index) has no action")
                continue
            }
            for case .push(let intent) in effects {
                pushes.append((index, intent))
            }
        }

        if let count = c.expect.sessionCount {
            #expect(registry.sessions.count == count)
        }
        for (key, want) in c.expect.sessions ?? [:] {
            let got = try #require(registry.sessions[key], "missing session \(key)")
            if let v = want.state { #expect(got.state == v, "\(key).state") }
            if let v = want.waitReason { #expect(got.waitReason == v, "\(key).waitReason") }
            if let v = want.abnormal { #expect(got.abnormal == v, "\(key).abnormal") }
            if let v = want.origin { #expect(got.origin == v, "\(key).origin") }
            if let v = want.pending { #expect((got.pendingPushSince != nil) == v, "\(key).pending") }
        }
        if let wantPushes = c.expect.pushes {
            try #require(pushes.count == wantPushes.count, "pushes: \(pushes.map { "\($0.step):\($0.intent.kind):\($0.intent.sessionKey ?? $0.intent.subject):\(String(describing: $0.intent.state))" })")
            for (i, want) in wantPushes.enumerated() {
                let (step, got) = pushes[i]
                #expect(got.kind == want.kind ?? .task, "push[\(i)].kind")
                if let v = want.detail { #expect(got.detail == v, "push[\(i)].detail") }
                if let v = want.session { #expect(got.sessionKey == v, "push[\(i)].session") }
                if let v = want.state { #expect(got.state == v, "push[\(i)].state") }
                if let v = want.waitReason { #expect(got.waitReason == v, "push[\(i)].waitReason") }
                if let v = want.abnormal { #expect(got.abnormal == v, "push[\(i)].abnormal") }
                if let v = want.level { #expect(got.level == v, "push[\(i)].level") }
                if let v = want.subject { #expect(got.subject == v, "push[\(i)].subject") }
                if let v = want.atStep { #expect(step == v, "push[\(i)].atStep") }
            }
        }
    }

    @Test func openSessionWithoutProcessIsPrunedAfterADayOfSilence() {
        var registry = Registry()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let present = { Presence(screenLocked: false, idleSeconds: 0) }
        _ = registry.ingest(GatewayEvent(agent: .claude, kind: .promptSubmit, sessionId: "orphan", cwd: "/w/a", timestamp: now, origin: .interactive),
                            config: GatewayConfig(), now: now, presence: present)
        _ = registry.ingest(GatewayEvent(agent: .claude, kind: .promptSubmit, sessionId: "tracked", cwd: "/w/b", timestamp: now,
                                         process: ProcessIdentity(pid: 9, startSec: 1, startUsec: 0), origin: .interactive),
                            config: GatewayConfig(), now: now, presence: present)
        registry.prune(now: now.addingTimeInterval(23 * 3600))
        #expect(registry.sessions.count == 2)
        registry.prune(now: now.addingTimeInterval(25 * 3600))
        #expect(registry.sessions.keys.sorted() == ["claude:tracked"])
    }

    @Test func hostAppIsKeptFromTheFirstEventThatCarriesIt() {
        var registry = Registry()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let present = { Presence(screenLocked: false, idleSeconds: 0) }
        var start = GatewayEvent(agent: .claude, kind: .sessionStart, sessionId: "s", cwd: "/w/a", timestamp: now, origin: .host)
        start.host = "Synara"
        _ = registry.ingest(start, config: GatewayConfig(), now: now, presence: present)
        _ = registry.ingest(GatewayEvent(agent: .claude, kind: .turnStop, sessionId: "s", cwd: "/w/a", timestamp: now.addingTimeInterval(1)),
                            config: GatewayConfig(), now: now, presence: present)
        #expect(registry.sessions["claude:s"]?.host == "Synara")
    }

    @Test func registryRoundTripsThroughStore() throws {
        var registry = Registry()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = registry.ingest(
            GatewayEvent(agent: .codex, kind: .turnStop, sessionId: "c1", cwd: "/w/x", timestamp: now,
                         process: ProcessIdentity(pid: 1, startSec: 2, startUsec: 3), origin: .interactive),
            config: GatewayConfig(), now: now, presence: { Presence(screenLocked: false, idleSeconds: 0) }
        )
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RegistryStore(url: dir.appendingPathComponent("registry.json"))
        try store.save(registry)
        #expect(store.load() == registry)
    }
}
