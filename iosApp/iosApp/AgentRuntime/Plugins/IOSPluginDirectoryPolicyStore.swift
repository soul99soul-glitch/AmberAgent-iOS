import Foundation

struct IOSPluginDirectoryReport: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let pluginId: String
    let reason: String
    let date: Date
}

struct IOSPluginDirectoryPolicySnapshot: Codable, Equatable, Sendable {
    var blockedPluginIds: Set<String> = []
    var reports: [IOSPluginDirectoryReport] = []
}

/// Local policy seam for a future public index. It persists block/report
/// intent without pretending that a server accepted or published anything.
struct IOSPluginDirectoryPolicyStore {
    private static let mutationLock = NSLock()
    private static let maxReports = 40

    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func snapshot() -> IOSPluginDirectoryPolicySnapshot {
        Self.mutationLock.withLock { read() }
    }

    func setBlocked(pluginId: String, blocked: Bool) throws {
        try Self.mutationLock.withLock {
            var value = read()
            if blocked { value.blockedPluginIds.insert(pluginId) }
            else { value.blockedPluginIds.remove(pluginId) }
            try write(value)
        }
    }

    func recordLocalReport(pluginId: String, reason: String) throws {
        try Self.mutationLock.withLock {
            var value = read()
            value.reports.append(IOSPluginDirectoryReport(
                id: UUID(),
                pluginId: pluginId,
                reason: String(reason.prefix(240)),
                date: Date()
            ))
            value.reports = Array(value.reports.suffix(Self.maxReports))
            try write(value)
        }
    }

    private var policyURL: URL {
        baseDirectory
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(".directory", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    private func read() -> IOSPluginDirectoryPolicySnapshot {
        guard let data = try? Data(contentsOf: policyURL) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(IOSPluginDirectoryPolicySnapshot.self, from: data)) ?? .init()
    }

    private func write(_ value: IOSPluginDirectoryPolicySnapshot) throws {
        try fileManager.createDirectory(
            at: policyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: policyURL, options: [.atomic])
    }
}

