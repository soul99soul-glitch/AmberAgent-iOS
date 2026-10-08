import Foundation
import Observation

enum IOSDeepReadStoreError: LocalizedError {
    case persistenceFailed

    var errorDescription: String? {
        IOSAppLocalization.string(
            "深度阅读保存失败，请检查设备存储后重试。",
            defaultValue: "深度阅读保存失败，请检查设备存储后重试。"
        )
    }
}

@MainActor
@Observable
final class IOSDeepReadStore {
    static let shared = IOSDeepReadStore()

    private(set) var tasks: [IOSDeepReadTask]
    private(set) var persistenceErrorsByTaskId: [String: String] = [:]
    /// Ephemeral in-memory stage labels for the detail skeleton (not persisted).
    private(set) var progressLabelsByTaskId: [String: String] = [:]

    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = root.appendingPathComponent("deep_read", isDirectory: true)
        fileURL = directory.appendingPathComponent("tasks.json", isDirectory: false)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        tasks = Self.loadTasks(from: fileURL, decoder: decoder)
    }

    func progressLabel(for id: String) -> String? {
        progressLabelsByTaskId[id]
    }

    func setProgressLabel(id: String, _ label: String?) {
        let cleaned = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty {
            progressLabelsByTaskId.removeValue(forKey: id)
        } else {
            progressLabelsByTaskId[id] = cleaned
        }
    }

    func clearProgressLabel(id: String) {
        progressLabelsByTaskId.removeValue(forKey: id)
    }

    var history: [IOSDeepReadTask] {
        tasks.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.createdAt > $1.createdAt }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func task(id: String) -> IOSDeepReadTask? {
        tasks.first { $0.id == id }
    }

    @discardableResult
    func createTask(
        title rawTitle: String,
        sources: [IOSDeepReadSource],
        templateId: String = IOSDeepReadTemplate.defaultId,
        now: Int64 = IOSDeepReadClock.currentEpochMs()
    ) throws -> IOSDeepReadTask {
        let validSources = sources.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validSources.isEmpty else {
            throw IOSDeepReadSourceNormalizationError.emptySource(.manualText)
        }
        let title = IOSDeepReadSourceNormalizer.clean(rawTitle)
            .deepReadIfEmpty(validSources.first?.title ?? "深度阅读")
        let task = IOSDeepReadTask(
            id: UUID().uuidString,
            title: title.deepReadPrefixString(160),
            status: .queued,
            templateId: IOSDeepReadTemplate.normalizedTemplateId(templateId),
            sources: validSources,
            resultMarkdown: "",
            failureMessage: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            retryCount: 0
        )
        var proposed = tasks
        proposed.append(task)
        do {
            try persist(proposed)
        } catch {
            throw IOSDeepReadStoreError.persistenceFailed
        }
        if tasks != proposed { tasks = proposed }
        return task
    }

    @discardableResult
    func markRunning(id: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        return update(id: id) { task in
            task.status = .running
            task.failureMessage = nil
            task.updatedAt = now
        }
    }

    /// Replaces a provisional title (e.g. a link's host) once the real article title is known.
    @discardableResult
    func updateTitle(id: String, title rawTitle: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        let title = IOSDeepReadSourceNormalizer.clean(rawTitle).deepReadPrefixString(160)
        guard !title.isEmpty else { return false }
        return update(id: id) { task in
            task.title = title
            task.updatedAt = now
        }
    }

    @discardableResult
    func replaceSources(id: String, sources: [IOSDeepReadSource], now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        return update(id: id) { task in
            task.sources = sources
            task.updatedAt = now
        }
    }

    @discardableResult
    func complete(id: String, markdown: String, structuredJSON: String? = nil, missingSections: [String]? = nil, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        clearProgressLabel(id: id)
        return update(id: id) { task in
            task.status = .succeeded
            task.resultMarkdown = markdown
            task.structuredJSON = structuredJSON
            task.missingSections = (missingSections?.isEmpty == false) ? missingSections : nil
            task.failureMessage = nil
            task.workspaceSyncFailed = nil
            task.updatedAt = now
            task.completedAt = now
        }
    }

    @discardableResult
    func markWorkspaceSyncFailed(id: String, message: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        let saved = update(id: id) { task in
            task.workspaceSyncFailed = message.deepReadPrefixString(500)
            task.updatedAt = now
        }
        if !saved, let index = tasks.firstIndex(where: { $0.id == id }) {
            // Keep the Workspace-only retry available even if its warning cannot
            // be persisted. The completed article remains intact.
            var proposed = tasks
            proposed[index].workspaceSyncFailed = message.deepReadPrefixString(500)
            if tasks != proposed { tasks = proposed }
        }
        return saved
    }

    @discardableResult
    func clearWorkspaceSyncFailure(id: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        let saved = update(id: id) { task in
            task.workspaceSyncFailed = nil
            task.updatedAt = now
        }
        if !saved, let index = tasks.firstIndex(where: { $0.id == id }) {
            // The artifact is already saved. A failed metadata write must not
            // invite the user to send the same payload again.
            var proposed = tasks
            proposed[index].workspaceSyncFailed = nil
            if tasks != proposed { tasks = proposed }
            persistenceErrorsByTaskId[id] = IOSAppLocalization.string(
                "已保存到 Workspace，但深度阅读状态保存失败。",
                defaultValue: "已保存到 Workspace，但深度阅读状态保存失败。"
            )
        }
        return saved
    }

    @discardableResult
    func fail(id: String, message: String, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        clearProgressLabel(id: id)
        return update(id: id) { task in
            task.status = .failed
            task.failureMessage = message.deepReadPrefixString(500)
            task.updatedAt = now
        }
    }

    @discardableResult
    func prepareRetry(id: String, preservingResult: Bool = false, now: Int64 = IOSDeepReadClock.currentEpochMs()) -> Bool {
        clearProgressLabel(id: id)
        return update(id: id) { task in
            task.status = .queued
            if !preservingResult {
                task.resultMarkdown = ""
                task.structuredJSON = nil
                task.missingSections = nil
            }
            task.failureMessage = nil
            task.workspaceSyncFailed = nil
            task.completedAt = nil
            task.retryCount += 1
            task.updatedAt = now
        }
    }

    @discardableResult
    func recoverInterruptedRuns(
        excluding activeTaskIds: Set<String> = [],
        staleAfterMs: Int64 = 30 * 60 * 1000,
        now: Int64 = IOSDeepReadClock.currentEpochMs()
    ) -> Bool {
        var proposed = tasks
        var changedIds: [String] = []
        for index in proposed.indices {
            guard proposed[index].status == .running || proposed[index].status == .queued else { continue }
            if activeTaskIds.contains(proposed[index].id),
               now - proposed[index].updatedAt < staleAfterMs {
                continue
            }
            proposed[index].status = .failed
            proposed[index].failureMessage = "上次深度阅读生成被中断，可重试。"
            proposed[index].updatedAt = now
            changedIds.append(proposed[index].id)
        }
        guard !changedIds.isEmpty else { return true }
        do {
            try persist(proposed)
            if tasks != proposed { tasks = proposed }
            for id in changedIds { persistenceErrorsByTaskId.removeValue(forKey: id) }
            return true
        } catch {
            for id in changedIds { recordPersistenceFailure(id: id) }
            return false
        }
    }

    func persistenceError(for id: String) -> String? {
        persistenceErrorsByTaskId[id]
    }

    private func update(id: String, mutate: (inout IOSDeepReadTask) -> Void) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        var proposed = tasks
        mutate(&proposed[index])
        do {
            try persist(proposed)
            if tasks != proposed { tasks = proposed }
            persistenceErrorsByTaskId.removeValue(forKey: id)
            return true
        } catch {
            recordPersistenceFailure(id: id)
            return false
        }
    }

    /// The failure is visible in this process even when the disk cannot accept
    /// a terminal state. Preserve the last article and stop the running UI.
    private func recordPersistenceFailure(id: String) {
        let message = IOSDeepReadStoreError.persistenceFailed.localizedDescription
        persistenceErrorsByTaskId[id] = message
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].status == .queued || tasks[index].status == .running else { return }
        var proposed = tasks
        proposed[index].status = .failed
        proposed[index].failureMessage = message
        if tasks != proposed { tasks = proposed }
    }

    private func persist(_ proposed: [IOSDeepReadTask]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(proposed.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func loadTasks(from fileURL: URL, decoder: JSONDecoder) -> [IOSDeepReadTask] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([IOSDeepReadTask].self, from: data) else {
            return []
        }
        return decoded
    }
}

