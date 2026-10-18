import Foundation

enum IOSPluginDiagnosticKind: String, Codable, Equatable, Sendable {
    case timeout
    case schema
    case exception
    case remote
}

struct IOSPluginDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let toolId: String
    let kind: IOSPluginDiagnosticKind
    let detail: String
}

struct IOSPluginHealthSnapshot: Codable, Equatable, Sendable {
    static let quarantineThreshold = 3

    let pluginId: String
    let packageHash: String
    var consecutiveFailures: Int
    var quarantinedAt: Date?
    var quarantineReason: String?
    var diagnostics: [IOSPluginDiagnosticEvent]

    var isQuarantined: Bool { quarantinedAt != nil }

    static func healthy(pluginId: String, packageHash: String) -> Self {
        .init(
            pluginId: pluginId,
            packageHash: packageHash,
            consecutiveFailures: 0,
            quarantinedAt: nil,
            quarantineReason: nil,
            diagnostics: []
        )
    }
}

struct IOSPluginHealthTransition: Equatable, Sendable {
    let snapshot: IOSPluginHealthSnapshot
    let didQuarantine: Bool
}

/// Small, bounded runtime-health journal. The package hash is part of the
/// identity so an update or rollback never inherits another version's faults.
struct IOSPluginHealthStore {
    private final class VolatileState: @unchecked Sendable {
        var snapshots: [String: IOSPluginHealthSnapshot] = [:]
    }

    private static let mutationLock = NSLock()
    private static let volatileState = VolatileState()
    private static let maxDiagnostics = 50
    private static let maxDetailCharacters = 500

    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    private var healthDirectory: URL {
        baseDirectory
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(".health", isDirectory: true)
    }

    func snapshot(pluginId: String, packageHash: String) -> IOSPluginHealthSnapshot {
        Self.mutationLock.withLock {
            if let cached = Self.volatileState.snapshots[cacheKey(pluginId: pluginId)],
               cached.packageHash == packageHash {
                return cached
            }
            guard let stored = read(pluginId: pluginId), stored.packageHash == packageHash else {
                return .healthy(pluginId: pluginId, packageHash: packageHash)
            }
            Self.volatileState.snapshots[cacheKey(pluginId: pluginId)] = stored
            return stored
        }
    }

    @discardableResult
    func recordSuccess(pluginId: String, packageHash: String) -> IOSPluginHealthTransition {
        Self.mutationLock.withLock {
            var value = current(pluginId: pluginId, packageHash: packageHash)
            value.consecutiveFailures = 0
            retainAndPersist(value)
            return IOSPluginHealthTransition(snapshot: value, didQuarantine: false)
        }
    }

    @discardableResult
    func recordFailure(
        pluginId: String,
        packageHash: String,
        toolId: String,
        kind: IOSPluginDiagnosticKind,
        detail: String
    ) -> IOSPluginHealthTransition {
        Self.mutationLock.withLock {
            var value = current(pluginId: pluginId, packageHash: packageHash)
            let wasQuarantined = value.isQuarantined
            value.consecutiveFailures += 1
            value.diagnostics.append(IOSPluginDiagnosticEvent(
                id: UUID(),
                date: Date(),
                toolId: String(toolId.prefix(160)),
                kind: kind,
                detail: String(detail.prefix(Self.maxDetailCharacters))
            ))
            value.diagnostics = Array(value.diagnostics.suffix(Self.maxDiagnostics))
            if value.consecutiveFailures >= IOSPluginHealthSnapshot.quarantineThreshold,
               !value.isQuarantined {
                value.quarantinedAt = Date()
                value.quarantineReason = "连续 \(value.consecutiveFailures) 次 \(kind.rawValue) 故障"
            }
            retainAndPersist(value)
            return IOSPluginHealthTransition(
                snapshot: value,
                didQuarantine: !wasQuarantined && value.isQuarantined
            )
        }
    }

    @discardableResult
    func restore(pluginId: String, packageHash: String) -> IOSPluginHealthSnapshot {
        Self.mutationLock.withLock {
            var value = current(pluginId: pluginId, packageHash: packageHash)
            value.consecutiveFailures = 0
            value.quarantinedAt = nil
            value.quarantineReason = nil
            retainAndPersist(value)
            return value
        }
    }

    func remove(pluginId: String) {
        Self.mutationLock.withLock {
            Self.volatileState.snapshots.removeValue(forKey: cacheKey(pluginId: pluginId))
            try? fileManager.removeItem(at: healthURL(pluginId: pluginId))
        }
    }

    private func current(pluginId: String, packageHash: String) -> IOSPluginHealthSnapshot {
        if let cached = Self.volatileState.snapshots[cacheKey(pluginId: pluginId)],
           cached.packageHash == packageHash {
            return cached
        }
        guard let stored = read(pluginId: pluginId), stored.packageHash == packageHash else {
            return .healthy(pluginId: pluginId, packageHash: packageHash)
        }
        Self.volatileState.snapshots[cacheKey(pluginId: pluginId)] = stored
        return stored
    }

    private func retainAndPersist(_ value: IOSPluginHealthSnapshot) {
        Self.volatileState.snapshots[cacheKey(pluginId: value.pluginId)] = value
        do {
            try write(value)
        } catch {
            // Keep the current process fail-closed even when storage is
            // temporarily unavailable; the next successful mutation retries.
            NSLog("[AmberPluginHealth] Failed to persist \(value.pluginId): \(error)")
        }
    }

    private func read(pluginId: String) -> IOSPluginHealthSnapshot? {
        guard IOSRecipeNames.isValidRecipeName(pluginId),
              let data = try? Data(contentsOf: healthURL(pluginId: pluginId)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(IOSPluginHealthSnapshot.self, from: data)
    }

    private func write(_ value: IOSPluginHealthSnapshot) throws {
        try fileManager.createDirectory(at: healthDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: healthURL(pluginId: value.pluginId), options: [.atomic])
    }

    private func healthURL(pluginId: String) -> URL {
        healthDirectory.appendingPathComponent("\(pluginId).json")
    }

    private func cacheKey(pluginId: String) -> String {
        healthURL(pluginId: pluginId).standardizedFileURL.path
    }
}

