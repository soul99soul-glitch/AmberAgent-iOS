import Foundation

public enum RegistryEffect: Equatable, Sendable {
    case push(PushIntent)
    case watch(ProcessIdentity)
}

/// All session bookkeeping and push policy. Deterministic given (events, presence, now) so it can be
/// driven by golden vectors; the daemon only feeds it and executes the returned effects.
public struct Registry: Codable, Sendable, Equatable {
    public var sessions: [String: SessionRecord] = [:]
    public var recentEventIds: [String] = []
    public var health: HealthSnapshot?
    public var activeHealthAlerts: Set<String> = []

    static let recentEventCapacity = 512
    static let retention: TimeInterval = 7 * 24 * 3600
    static let orphanTimeout: TimeInterval = 24 * 3600

    public init() {}

    /// 60s heartbeat: records the sample, pushes on newly crossed thresholds, and flags stalled headless tasks.
    public mutating func heartbeat(_ sample: HealthSnapshot, config: GatewayConfig, now: Date) -> [RegistryEffect] {
        health = sample
        let problems = HealthPolicy.problems(sample, config: config)
        var effects: [RegistryEffect] = []
        for key in problems.keys.sorted() where !activeHealthAlerts.contains(key) {
            effects.append(.push(PushIntent(kind: .health, subject: key, detail: problems[key], createdAt: now)))
        }
        activeHealthAlerts = Set(problems.keys)

        if config.headlessStallMinutes > 0 {
            for key in sessions.keys.sorted() {
                // `run` children emit nothing between start and exit, and their exit is always observed.
                guard var rec = sessions[key], rec.state == .running, rec.origin == .headless, rec.agent != .run, rec.agent != .amber,
                      now.timeIntervalSince(rec.updatedAt) >= config.headlessStallMinutes * 60
                else { continue }
                let old = rec
                rec.state = .stalled
                sessions[key] = rec
                effects += decidePush(key: key, old: old, config: config, now: now, presence: { Presence(screenLocked: false, idleSeconds: 0) })
            }
        }
        return effects
    }

    public var hasPendingPushes: Bool {
        sessions.values.contains { $0.pendingPushSince != nil }
    }

    public var watchedProcesses: Set<ProcessIdentity> {
        Set(sessions.values.filter(\.isOpen).compactMap(\.process))
    }

    public mutating func ingest(
        _ event: GatewayEvent,
        config: GatewayConfig,
        now: Date,
        presence: () -> Presence
    ) -> [RegistryEffect] {
        // Hooks retry via spool when the daemon doesn't ack in time, so the same event can arrive twice.
        guard !recentEventIds.contains(event.id) else { return [] }
        recentEventIds.append(event.id)
        if recentEventIds.count > Self.recentEventCapacity {
            recentEventIds.removeFirst(recentEventIds.count - Self.recentEventCapacity)
        }

        let key = SessionRecord.key(event.agent, event.sessionId)
        // A title for a session that exists; it must not reorder, reopen or create anything.
        if event.kind == .retitle {
            if let title = event.title, !title.isEmpty, sessions[key] != nil { sessions[key]!.generatedTitle = title }
            return []
        }
        let old = sessions[key]
        if old == nil && config.isExcluded(cwd: event.cwd) { return [] }
        if let old, event.timestamp < old.updatedAt, event.kind != .runExit { return [] }

        var rec = old ?? SessionRecord(
            key: key,
            agent: event.agent,
            sessionId: event.sessionId,
            cwd: event.cwd,
            title: event.title,
            origin: event.origin ?? .interactive,
            state: .running,
            waitReason: nil,
            abnormal: false,
            sawTurnEnd: false,
            sawFailure: false,
            process: nil,
            startedAt: event.timestamp,
            updatedAt: event.timestamp,
            monitored: true,
            pendingPushSince: nil,
            lastPushAt: [:]
        )
        if rec.cwd == nil { rec.cwd = event.cwd }
        if let title = event.title { rec.title = title }
        // The first real prompt names the conversation, the way Synara titles its threads; later turns don't rename it.
        if rec.summary == nil || rec.summary?.hasPrefix("<") == true, let summary = event.summary {
            rec.summary = summary
            rec.opening = event.opening
        }
        if let origin = event.origin, rec.origin != .host { rec.origin = origin }
        if let host = event.host { rec.host = host }

        var effects: [RegistryEffect] = []
        if let process = event.process {
            rec.process = process
            effects.append(.watch(process))
        }

        SessionMachine.apply(event, to: &rec)
        rec.updatedAt = max(rec.updatedAt, event.timestamp)
        sessions[key] = rec

        effects += decidePush(key: key, old: old, config: config, now: now, presence: presence)
        return effects
    }

    public mutating func processExited(
        _ process: ProcessIdentity,
        config: GatewayConfig,
        now: Date
    ) -> [RegistryEffect] {
        let keys = sessions.filter { $0.value.process == process && $0.value.isOpen }.map(\.key).sorted()
        guard !keys.isEmpty else { return [] }

        // Host-ness comes from launch arguments only. Sharing a PID is not evidence: plain `codex` and
        // `codex exec` run auxiliary sessions (memory consolidation) inside the same process.
        let isHost = keys.contains { sessions[$0]?.origin == .host }
        var effects: [RegistryEffect] = []
        for key in keys {
            guard var rec = sessions[key] else { continue }
            let old = rec
            SessionMachine.applyProcessExit(to: &rec)
            rec.updatedAt = max(rec.updatedAt, now)
            sessions[key] = rec
            if !isHost {
                effects += decidePush(key: key, old: old, config: config, now: now, presence: { Presence(screenLocked: true, idleSeconds: .infinity) })
            }
        }
        // A dying host takes all its sessions with it: one push per process, not one per session.
        if isHost, let first = sessions[keys[0]], first.abnormal {
            var rec = first
            if let intent = makeIntent(&rec, subject: "宿主进程（\(keys.count) 个会话）", config: config, now: now) {
                sessions[keys[0]] = rec
                effects.append(.push(intent))
            }
        }
        return effects
    }

    /// Re-evaluates held-back "waiting" pushes. Only needs calling while `hasPendingPushes`.
    public mutating func tick(config: GatewayConfig, now: Date, presence: Presence) -> [RegistryEffect] {
        var effects: [RegistryEffect] = []
        for key in sessions.keys.sorted() {
            guard var rec = sessions[key], rec.pendingPushSince != nil else { continue }
            guard rec.state == .waiting, rec.origin == .interactive || rec.agent == .amber else {
                rec.pendingPushSince = nil
                sessions[key] = rec
                continue
            }
            if presence.isAway(threshold: threshold(for: rec, config)) {
                rec.pendingPushSince = nil
                if let intent = makeIntent(&rec, subject: nil, config: config, now: now) {
                    effects.append(.push(intent))
                }
                sessions[key] = rec
            }
        }
        return effects
    }

    public mutating func setMonitored(_ key: String, _ monitored: Bool) -> Bool {
        guard sessions[key] != nil else { return false }
        sessions[key]!.monitored = monitored
        if !monitored { sessions[key]!.pendingPushSince = nil }
        return true
    }

    public mutating func prune(now: Date) {
        sessions = sessions.filter { _, rec in
            let age = now.timeIntervalSince(rec.updatedAt)
            // Without a process there is no exit signal: a missed SessionEnd would keep it open forever.
            if rec.isOpen { return rec.process != nil || age < Self.orphanTimeout }
            return age < Self.retention
        }
    }

    // MARK: - Policy

    private mutating func decidePush(
        key: String,
        old: SessionRecord?,
        config: GatewayConfig,
        now: Date,
        presence: () -> Presence
    ) -> [RegistryEffect] {
        guard var rec = sessions[key] else { return [] }
        defer { sessions[key] = rec }

        if rec.state != .waiting { rec.pendingPushSince = nil }
        guard rec.monitored else { return [] }

        switch rec.state {
        case .running:
            return []
        case .waiting:
            // A permission wait ends on its tool's `toolDone`; without one it lasts until the turn ends,
            // and that switch to turnEnd is a new wait.
            let entered = old?.state != .waiting || old?.waitReason != rec.waitReason
            // D9: only interactive sessions get "waiting for you". Amber approvals are the exception: an
            // unattended task waiting on a tool call is exactly what the phone is for.
            let entered2 = entered || (rec.agent == .amber && old?.waitingToolCallId != rec.waitingToolCallId)
            guard entered2, rec.origin == .interactive || rec.agent == .amber else { return [] }
            if presence().isAway(threshold: threshold(for: rec, config)) {
                rec.pendingPushSince = nil
                return makeIntent(&rec, subject: nil, config: config, now: now).map { [.push($0)] } ?? []
            }
            rec.pendingPushSince = now
            return []
        case .stalled, .completed, .stopped:
            let entered = old?.state != rec.state || old?.abnormal != rec.abnormal
            guard entered, rec.state != .stopped || rec.abnormal else { return [] }
            // B6: an Amber run that finished with nothing new stays on the board but doesn't push.
            if rec.state == .completed, rec.agent == .amber, rec.quietCompletion == true { return [] }
            return makeIntent(&rec, subject: nil, config: config, now: now).map { [.push($0)] } ?? []
        }
    }

    private func threshold(for rec: SessionRecord, _ config: GatewayConfig) -> Double {
        rec.waitReason == .permission ? config.permissionPresenceThreshold : config.presenceThreshold
    }

    private func makeIntent(_ rec: inout SessionRecord, subject: String?, config: GatewayConfig, now: Date) -> PushIntent? {
        let dedupeKey = rec.state.rawValue + (rec.abnormal ? ".abnormal" : "")
        if rec.state != .waiting, let last = rec.lastPushAt[dedupeKey], now.timeIntervalSince(last) < config.dedupeWindow {
            return nil
        }
        rec.lastPushAt[dedupeKey] = now
        return PushIntent(
            kind: .task,
            sessionKey: rec.key,
            agent: rec.agent,
            subject: subject ?? Self.subject(for: rec),
            state: rec.state,
            waitReason: rec.waitReason,
            abnormal: rec.abnormal,
            toolCallId: rec.agent == .amber && rec.state == .waiting ? rec.waitingToolCallId : nil,
            highRisk: rec.agent == .amber && rec.state == .waiting ? rec.waitingHighRisk : nil,
            level: rec.state == .waiting ? .timeSensitive : .active,
            createdAt: now
        )
    }

    public static func subject(for rec: SessionRecord) -> String {
        if let title = rec.title, !title.isEmpty { return title }
        if let cwd = rec.cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return String(rec.sessionId.prefix(8))
    }
}
