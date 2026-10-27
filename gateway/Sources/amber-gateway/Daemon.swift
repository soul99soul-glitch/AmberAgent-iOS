import Darwin
import Foundation
import GatewayCore
import GatewayPush
import GatewayTransport
import HookIngest
import SessionWatch

/// Single serial queue owns all state. Idle cost: the hook socket, the HTTPS listener, one kqueue, the
/// 60s heartbeat, and a 5s tick only while a "waiting" push is held back.
final class Daemon {
    static let pendingTickInterval: DispatchTimeInterval = .seconds(5)
    static let heartbeatInterval: DispatchTimeInterval = .seconds(60)
    /// How long system sleep is held back for the "about to sleep" push.
    static let sleepPushGrace: TimeInterval = 3

    let paths: GatewayPaths
    let queue = DispatchQueue(label: "amber-gateway.daemon")
    private let store: RegistryStore
    private let spool: Spool
    private let outbox: Outbox
    let devices: DeviceStore
    let audit: AuditLog
    private let dispatcher: PushDispatcher
    private(set) var identity = GatewayIdentity(id: "", name: "")
    private(set) var config = GatewayConfig()
    var registry = Registry()
    private var server: UnixSocketServer?
    private var httpServer: HTTPServer?
    private var watcher: ProcessWatcher?
    private var pendingTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressure: HealthSnapshot.MemoryPressure = .normal
    private var powerWatcher: PowerWatcher?
    private let sleepAssertion = IdleSleepAssertion()
    private var lastSleepPushAt: Date?
    private var signalSources: [DispatchSourceSignal] = []

    init(paths: GatewayPaths) {
        self.paths = paths
        store = RegistryStore(url: paths.registry)
        spool = Spool(dir: paths.spoolDir)
        outbox = Outbox(url: paths.outbox)
        devices = DeviceStore(url: paths.devices)
        audit = AuditLog(url: paths.audit)
        dispatcher = PushDispatcher(store: CredentialStore(dir: paths.secretsDir))
    }

    func run() -> Never {
        do {
            try paths.ensureDirectories()
        } catch {
            fail("无法创建状态目录 \(paths.stateDir.path): \(error)")
        }
        guard acquireSingleInstanceLock() else { fail("daemon 已在运行") }

        config = GatewayConfig.load(from: paths.config)
        registry = store.load()
        registry.prune(now: Date())
        identity = GatewayIdentity.loadOrCreate(at: paths.identity)

        do {
            // Anyone probing a public address can read the CN, so it carries no owner name. Trust is the SPKI pin.
            let tls = try TLSIdentity.loadOrCreate(at: paths.tlsIdentity, commonName: "Amber Gateway")
            let http = try HTTPServer(port: config.port, identity: tls.identity, queue: queue) { [weak self] request, respond in
                guard let self else { return respond(.error(500, "shutting down")) }
                handleAPI(request, respond: respond)
            }
            try http.start()
            httpServer = http
        } catch {
            fail("无法启动 HTTPS 服务（端口 \(config.port)）: \(error)")
        }

        queue.sync {
            watcher = ProcessWatcher(queue: queue, currentIdentity: ProcessTree.identity(pid:)) { [weak self] in
                self?.processExited($0)
            }
            for process in registry.watchedProcesses {
                watcher?.watch(process)
            }
            drainSpool()
            let server = UnixSocketServer(path: paths.socket.path, queue: queue) { [weak self] in
                self?.receive($0) ?? false
            }
            do {
                try server.start()
            } catch {
                fail("无法监听 \(paths.socket.path): \(error)")
            }
            self.server = server
            persist()
            updatePendingTimer()
            startHeartbeat()
            log("started pid=\(getpid()) port=\(httpServer?.port ?? 0) sessions=\(registry.sessions.count) watching=\(watcher?.watchedCount ?? 0)")
        }
        installSignalHandlers()
        dispatchMain()
    }

    // MARK: - Inputs

    private func receive(_ data: Data) -> Bool {
        guard let event = try? GatewayJSON.decoder().decode(GatewayEvent.self, from: data) else { return false }
        // Spooled events are older than anything arriving live; apply them first so ordering holds.
        drainSpool()
        handle(event)
        return true
    }

    private func handle(_ event: GatewayEvent) {
        let effects = registry.ingest(event, config: config, now: Date(), presence: PresenceProbe.current)
        apply(effects)
        persist()
    }

    private func processExited(_ process: ProcessIdentity) {
        let effects = registry.processExited(process, config: config, now: Date())
        apply(effects)
        persist()
    }

    private func drainSpool() {
        guard !spool.isEmpty() else { return }
        spool.drain { handle($0) }
    }

    // MARK: - Effects

    private func apply(_ effects: [RegistryEffect]) {
        for effect in effects {
            switch effect {
            case .watch(let process):
                watcher?.watch(process)
            case .push(let intent):
                push(intent)
            }
        }
        updatePendingTimer()
        if config.preventIdleSleepWhileRunning {
            sleepAssertion.set(registry.sessions.values.contains { $0.isOpen && $0.origin == .headless })
        }
    }

    private func push(_ intent: PushIntent, completion: (() -> Void)? = nil) {
        do {
            try outbox.append(intent)
        } catch {
            log("outbox write failed: \(error)")
        }
        log("push \(intent.kind.rawValue) \(intent.state?.rawValue ?? "-")\(intent.abnormal ? "(abnormal)" : "") \(intent.sessionKey ?? "-") [\(intent.subject)]")
        let targets = devices.load().filter { $0.pushToken != nil }
        guard !targets.isEmpty else {
            completion?()
            return
        }
        deliver(intent, to: targets) { _ in completion?() }
    }

    /// Delivery runs off-queue; results (and token invalidation) come back on the daemon queue.
    func deliver(_ intent: PushIntent, to targets: [PairedDevice],
                 completion: @escaping ([(device: PairedDevice, result: DeliveryResult)]) -> Void) {
        let message = PushMessage(intent, gatewayName: identity.name)
        let dispatcher = dispatcher
        Task {
            let results = await dispatcher.deliver(message, to: targets)
            queue.async { [self] in
                for (device, result) in results {
                    switch result {
                    case .delivered:
                        log("  → \(device.name): 已送达")
                    case .invalidToken(let reason):
                        log("  → \(device.name): token 失效（\(reason)），已移除")
                        updateDevice(device.id) { if $0.pushToken == device.pushToken { $0.pushToken = nil } }
                    case .failed(let reason):
                        log("  → \(device.name): 失败 \(reason)")
                    }
                }
                completion(results)
            }
        }
    }

    func persist() {
        do {
            try store.save(registry)
        } catch {
            log("registry save failed: \(error)")
        }
    }

    // MARK: - Timers

    func updatePendingTimer() {
        if registry.hasPendingPushes, pendingTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pendingTickInterval, repeating: Self.pendingTickInterval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            pendingTimer = timer
        } else if !registry.hasPendingPushes, let timer = pendingTimer {
            timer.cancel()
            pendingTimer = nil
        }
    }

    private func tick() {
        let before = registry
        let effects = registry.tick(config: config, now: Date(), presence: PresenceProbe.current())
        apply(effects)
        if registry != before { persist() }
    }

    private func startHeartbeat() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let event = pressure?.data else { return }
            memoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
        }
        pressure.resume()
        memoryPressureSource = pressure

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.heartbeatInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        timer.resume()
        heartbeatTimer = timer

        powerWatcher = PowerWatcher(queue: queue) { [weak self] allowSleep in
            self?.willSleep(allowSleep) ?? allowSleep()
        }
    }

    private func heartbeat() {
        drainSpool()
        let now = Date()
        registry.prune(now: now)
        apply(registry.heartbeat(HealthProbe.sample(memoryPressure: memoryPressure, now: now), config: config, now: now))
        persist()
    }

    /// Best effort (design doc 6): only worth a push when something is still running; the network may
    /// already be gone, so the push is allowed to fail. Sessions waiting for the user lose nothing by
    /// sleeping, and dark wakes re-enter sleep repeatedly, hence the running-only count and the dedupe.
    private func willSleep(_ allowSleep: @escaping () -> Void) {
        let now = Date()
        let running = registry.sessions.values.filter { $0.state == .running || $0.state == .stalled }.count
        guard running > 0, lastSleepPushAt.map({ now.timeIntervalSince($0) >= config.dedupeWindow }) ?? true else {
            return allowSleep()
        }
        lastSleepPushAt = now
        push(PushIntent(kind: .sleep, subject: "sleep", detail: "\(running) 个任务仍在运行", createdAt: now), completion: allowSleep)
        queue.asyncAfter(deadline: .now() + Self.sleepPushGrace, execute: allowSleep)
    }

    // MARK: - Process plumbing

    private func acquireSingleInstanceLock() -> Bool {
        let fd = open(paths.pidFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        // fd intentionally stays open for the process lifetime to hold the lock.
        return true
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                self?.server?.stop()
                self?.persist()
                self?.log("stopped by signal \(sig)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }
}
