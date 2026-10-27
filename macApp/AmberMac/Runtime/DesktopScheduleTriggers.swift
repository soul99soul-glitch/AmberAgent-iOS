import Foundation
@preconcurrency import GatewayCore

/// Watches what event-triggered scheduled tasks wait for and calls `DesktopScheduler.fire`:
/// - folder: one DispatchSource per enabled folder task; after `debounce` of quiet, files new since the last
///   listing (hidden ones and in-progress downloads ignored) fire the task.
/// - agentSession: the gateway's state directory (registry.json is replaced by rename); a Claude Code / Codex session
///   newly entering ended / waiting fires matching tasks, once per (session, event).
/// The scheduler applies pause, overlap, the global cap and the 15-minute gap.
@MainActor final class DesktopScheduleTriggers {
    typealias Fire = @MainActor (UUID, String) -> Void

    static let listedFileLimit = 10
    /// Browser and Finder partial downloads; the finished file shows up under its final name.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part"]

    private struct FolderWatch {
        var path: String
        var source: any DispatchSourceFileSystemObject
        var listing: [String: Date]
        var pending: Task<Void, Never>?
    }

    private let scheduler: DesktopScheduler
    private let registryURL: URL
    private let debounce: Duration
    private let registryDebounce: Duration
    private let fire: Fire
    private var folders: [UUID: FolderWatch] = [:]
    private var registrySource: (any DispatchSourceFileSystemObject)?
    private var registryPending: Task<Void, Never>?
    private var registryModified: Date?
    /// nil until the first read: sessions already ended or waiting when Amber starts do not fire.
    private var sessionStates: [String: TaskState]?
    private var firedSessions: Set<String> = []
    private var poll: Task<Void, Never>?

    init(scheduler: DesktopScheduler, registryURL: URL = GatewayPaths.resolve().registry,
         debounce: Duration = .seconds(30), registryDebounce: Duration = .milliseconds(500), fire: Fire? = nil) {
        self.scheduler = scheduler; self.registryURL = registryURL
        self.debounce = debounce; self.registryDebounce = registryDebounce
        self.fire = fire ?? { [weak scheduler] in scheduler?.fire($0, context: $1) }
    }

    /// Arms the watchers and keeps them in step with task edits; a 30s pass re-opens folders that were missing.
    func start() {
        guard poll == nil else { return }
        reconcile()
        observeTasks()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.reconcile()
            }
        }
    }

    func stop() {
        poll?.cancel(); poll = nil
        for id in Array(folders.keys) { unwatch(id) }
        registryPending?.cancel()
        registrySource?.cancel(); registrySource = nil
    }

    private func observeTasks() {
        withObservationTracking { _ = scheduler.tasks } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.poll != nil else { return }
                self.reconcile(); self.observeTasks()
            }
        }
    }

    /// Opens and closes folder watchers to match the enabled folder tasks; opens the registry watcher if needed.
    func reconcile() {
        var wanted: [UUID: String] = [:]
        for task in scheduler.tasks where task.enabled {
            if case .folder(let path) = task.trigger { wanted[task.id] = path }
        }
        for (id, watch) in folders where wanted[id] != watch.path { unwatch(id) }
        for (id, path) in wanted where folders[id] == nil { watch(id, path: path) }
        if registrySource == nil, scheduler.tasks.contains(where: { task in
            if task.enabled, case .agentSession = task.trigger { true } else { false }
        }) { watchRegistry() }
    }

    // MARK: folder

    private func watch(_ id: UUID, path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let gone = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            MainActor.assumeIsolated {
                // The folder itself moved away; the next reconcile re-opens whatever is at the path then.
                if gone { self?.unwatch(id) } else { self?.folderChanged(id) }
            }
        }
        source.setCancelHandler { close(descriptor) }
        folders[id] = FolderWatch(path: path, source: source, listing: Self.listing(URL(fileURLWithPath: path)))
        source.resume()
    }

    private func unwatch(_ id: UUID) {
        guard let watch = folders.removeValue(forKey: id) else { return }
        watch.pending?.cancel()
        watch.source.cancel()
    }

    /// Restarts the quiet period; a burst of copies becomes one run.
    private func folderChanged(_ id: UUID) {
        folders[id]?.pending?.cancel()
        folders[id]?.pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.scan(id)
        }
    }

    private func scan(_ id: UUID) {
        guard var watch = folders[id] else { return }
        let current = Self.listing(URL(fileURLWithPath: watch.path))
        let added = Self.newFiles(before: watch.listing, after: current)
        watch.listing = current; watch.pending = nil
        folders[id] = watch
        if !added.isEmpty { fire(id, Self.folderContext(added)) }
    }

    /// Visible entries and their creation dates.
    static func listing(_ directory: URL) -> [String: Date] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var result: [String: Date] = [:]
        for url in urls where !partialExtensions.contains(url.pathExtension.lowercased()) {
            result[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        }
        return result
    }

    /// Names that are new, or were replaced by a newer file of the same name; deletions and edits are not.
    static func newFiles(before: [String: Date], after: [String: Date]) -> [String] {
        after.filter { name, created in before[name].map { $0 != created } ?? true }
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
    }

    static func folderContext(_ names: [String]) -> String {
        let shown = names.prefix(listedFileLimit).joined(separator: "、")
        return "新文件：" + shown + (names.count > listedFileLimit ? " 等 \(names.count) 个" : "")
    }

    // MARK: agent sessions

    private func watchRegistry() {
        let directory = registryURL.deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let gone = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if gone { self.registrySource?.cancel(); self.registrySource = nil; return }
                self.registryPending?.cancel()
                self.registryPending = Task { [weak self, registryDebounce = self.registryDebounce] in
                    try? await Task.sleep(for: registryDebounce)
                    guard !Task.isCancelled else { return }
                    self?.registryChanged()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        registrySource = source
        source.resume()
        registryChanged()
    }

    /// Re-reads registry.json when it changed and fires tasks for sessions that newly ended or wait for the user.
    func registryChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: registryURL.path))?[.modificationDate] as? Date
        guard modified != registryModified || sessionStates == nil else { return }
        registryModified = modified
        let sessions = Array(RegistryStore(url: registryURL).load().sessions.values)
        defer { sessionStates = Dictionary(sessions.map { ($0.key, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard let previous = sessionStates else { return }
        // The registry drops old sessions; so can the record of what they already fired.
        let keys = Set(sessions.map(\.key))
        firedSessions = firedSessions.filter { keys.contains(String($0.prefix { $0 != "|" })) }
        for (session, event) in Self.sessionEvents(previous: previous, sessions: sessions)
            where firedSessions.insert("\(session.key)|\(event.rawValue)").inserted {
            let context = Self.sessionContext(session, event)
            for task in scheduler.tasks where task.enabled && task.trigger == .agentSession(event) { fire(task.id, context) }
        }
    }

    static func event(_ state: TaskState) -> DesktopAgentSessionEvent? {
        switch state {
        case .stopped, .completed: .ended
        case .waiting: .needsYou
        case .running, .stalled: nil
        }
    }

    /// Claude Code / Codex sessions whose state maps to an event they were not already in.
    static func sessionEvents(previous: [String: TaskState], sessions: [SessionRecord]) -> [(SessionRecord, DesktopAgentSessionEvent)] {
        sessions.filter { $0.agent == .claude || $0.agent == .codex }.sorted { $0.updatedAt < $1.updatedAt }.compactMap { session in
            guard let event = event(session.state), previous[session.key].flatMap(Self.event) != event else { return nil }
            return (session, event)
        }
    }

    static func sessionContext(_ session: SessionRecord, _ event: DesktopAgentSessionEvent) -> String {
        let title = session.generatedTitle ?? session.summary ?? Registry.subject(for: session)
        let source = [session.agent.displayName, session.host].compactMap { $0 }.joined(separator: " · ")
        var lines = ["\(source) 会话\(event == .ended ? "已结束" : "在等你处理")：「\(title)」"]
        if let cwd = session.cwd { lines.append("目录：" + cwd) }
        return lines.joined(separator: "\n")
    }
}
