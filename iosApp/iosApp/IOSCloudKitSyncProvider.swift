@preconcurrency import CloudKit
import Foundation

struct IOSCloudKitBackupMetadata: Equatable, Sendable {
    let recordName: String
    let fileName: String
    let manifestData: Data
    let modifiedAt: Int64
    let sizeBytes: Int64
    let revision: String
}

protocol IOSCloudKitDatabase: Sendable {
    var isConfigured: Bool { get }

    func testAccount() async throws
    func listBackupMetadata() async throws -> [IOSCloudKitBackupMetadata]
    func saveBackup(
        recordName: String,
        fileName: String,
        archive: Data,
        manifestData: Data
    ) async throws -> IOSCloudKitBackupMetadata
    func fetchBackup(recordName: String) async throws -> Data
    func deleteBackup(recordName: String) async throws
    func isRetryable(_ error: Error) -> Bool
}

enum IOSCloudKitDatabaseError: LocalizedError, Equatable {
    case notConfigured
    case accountUnavailable
    case missingArchive
    case transient(String)
    case permanent(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "此构建未配置 CloudKit。"
        case .accountUnavailable:
            "iCloud 账户当前不可用。请在系统设置中登录 iCloud 后重试。"
        case .missingArchive:
            "CloudKit 快照缺少加密备份文件。"
        case .transient(let message), .permanent(let message):
            message
        }
    }
}

final class IOSPrivateCloudKitDatabase: IOSCloudKitDatabase, @unchecked Sendable {
    static let containerIdentifier = "iCloud.app.amber.ios"

    private enum Field {
        static let fileName = "fileName"
        static let manifest = "manifest"
        static let archive = "archive"
        static let sizeBytes = "sizeBytes"
    }

    private static let recordType = "AmberEncryptedBackup"

    private let container: CKContainer
    private let database: CKDatabase
    let isConfigured: Bool

    init(
        container: CKContainer = CKContainer(identifier: IOSPrivateCloudKitDatabase.containerIdentifier),
        isConfigured: Bool? = nil
    ) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.isConfigured = isConfigured ?? Self.currentTargetHasCloudKitEntitlementMirror()
    }

    func testAccount() async throws {
        try ensureConfigured()
        let status: CKAccountStatus = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CKAccountStatus, Error>) in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
        guard status == .available else { throw IOSCloudKitDatabaseError.accountUnavailable }
    }

    func listBackupMetadata() async throws -> [IOSCloudKitBackupMetadata] {
        try ensureConfigured()
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        var page = try await database.records(
            matching: query,
            desiredKeys: [Field.fileName, Field.manifest, Field.sizeBytes]
        )
        records.append(contentsOf: try page.matchResults.map { try $0.1.get() })
        while let cursor = page.queryCursor {
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: [Field.fileName, Field.manifest, Field.sizeBytes]
            )
            records.append(contentsOf: try page.matchResults.map { try $0.1.get() })
        }
        return records.compactMap(metadata(from:))
    }

    func saveBackup(
        recordName: String,
        fileName: String,
        archive: Data,
        manifestData: Data
    ) async throws -> IOSCloudKitBackupMetadata {
        try ensureConfigured()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-cloudkit-\(UUID().uuidString).\(IOSSyncBackup.fileExtension)")
        try archive.write(to: temporaryURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: recordName)
        )
        record[Field.fileName] = fileName as CKRecordValue
        record[Field.manifest] = manifestData as CKRecordValue
        record[Field.sizeBytes] = NSNumber(value: archive.count)
        record[Field.archive] = CKAsset(fileURL: temporaryURL)
        let saved = try await database.save(record)
        guard let result = metadata(from: saved) else {
            throw IOSCloudKitDatabaseError.permanent("CloudKit 返回的快照元数据不完整。")
        }
        return result
    }

    func fetchBackup(recordName: String) async throws -> Data {
        try ensureConfigured()
        let record = try await database.record(for: CKRecord.ID(recordName: recordName))
        guard let asset = record[Field.archive] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw IOSCloudKitDatabaseError.missingArchive
        }
        return try Data(contentsOf: fileURL)
    }

    func deleteBackup(recordName: String) async throws {
        try ensureConfigured()
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
    }

    func isRetryable(_ error: Error) -> Bool {
        if case IOSCloudKitDatabaseError.transient = error { return true }
        guard let cloudError = error as? CKError else { return false }
        return [
            .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy
        ].contains(cloudError.code)
    }

    private func ensureConfigured() throws {
        guard isConfigured else { throw IOSCloudKitDatabaseError.notConfigured }
    }

    private func metadata(from record: CKRecord) -> IOSCloudKitBackupMetadata? {
        guard let fileName = record[Field.fileName] as? String,
              let manifestData = record[Field.manifest] as? Data else { return nil }
        let modifiedAt = Int64((record.modificationDate ?? record.creationDate ?? Date()).timeIntervalSince1970 * 1000)
        let size = (record[Field.sizeBytes] as? NSNumber)?.int64Value ?? 0
        return IOSCloudKitBackupMetadata(
            recordName: record.recordID.recordName,
            fileName: fileName,
            manifestData: manifestData,
            modifiedAt: modifiedAt,
            sizeBytes: size,
            revision: record.recordChangeTag ?? "\(modifiedAt)"
        )
    }

    static func currentTargetHasCloudKitEntitlementMirror(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        let key = bundleIdentifier?.hasSuffix(".experimental-gpl") == true
            ? "AmberAgentExperimentalConfiguredEntitlements"
            : "AmberAgentConfiguredEntitlements"
        let configured = infoDictionary?[key] as? [String] ?? []
        return configured.contains("com.apple.developer.icloud-services")
            && configured.contains("com.apple.developer.icloud-container-identifiers")
    }
}

struct IOSCloudKitSyncProvider: IOSRemoteSyncProvider {
    let database: any IOSCloudKitDatabase
    let maxAttempts: Int
    let retryDelayNanoseconds: UInt64

    var kind: IOSRemoteProviderKind { .cloudKit }
    var isConfigured: Bool { database.isConfigured }

    init(
        database: any IOSCloudKitDatabase = IOSPrivateCloudKitDatabase(),
        maxAttempts: Int = 3,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) {
        self.database = database
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    func testConnection() async throws {
        try await withRetry { try await database.testAccount() }
    }

    func listSnapshots() async throws -> [IOSRemoteSnapshot] {
        try await withRetry { try await database.listBackupMetadata() }
            .compactMap(snapshot(from:))
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt
                    ? lhs.modifiedAt > rhs.modifiedAt
                    : lhs.createdAt > rhs.createdAt
            }
    }

    func uploadSnapshot(
        data: Data,
        fileName: String,
        manifest: IOSSyncManifest
    ) async throws -> IOSRemoteSnapshot {
        let inspected = try IOSSyncBackup.inspectManifest(data: data, fileName: fileName)
        guard manifest.encrypted, inspected.manifest.encrypted else {
            throw IOSCloudKitDatabaseError.permanent("CloudKit 只接受加密备份。")
        }
        guard inspected.manifest == manifest else {
            throw IOSCloudKitDatabaseError.permanent("CloudKit 备份清单与归档内容不一致。")
        }
        let safeName = try cloudSafeSnapshotFileName(fileName)
        let manifestData = try JSONEncoder().encode(manifest)
        let metadata = try await withRetry {
            try await database.saveBackup(
                recordName: safeName,
                fileName: safeName,
                archive: data,
                manifestData: manifestData
            )
        }
        guard let snapshot = snapshot(from: metadata) else {
            throw IOSCloudKitDatabaseError.permanent("CloudKit 快照清单无法解析。")
        }
        return snapshot
    }

    func downloadSnapshot(_ snapshot: IOSRemoteSnapshot) async throws -> Data {
        let recordName = try cloudSafeSnapshotFileName(snapshot.fileName)
        return try await withRetry { try await database.fetchBackup(recordName: recordName) }
    }

    func deleteSnapshot(_ snapshot: IOSRemoteSnapshot) async throws {
        let recordName = try cloudSafeSnapshotFileName(snapshot.fileName)
        try await withRetry { try await database.deleteBackup(recordName: recordName) }
    }

    private func snapshot(from metadata: IOSCloudKitBackupMetadata) -> IOSRemoteSnapshot? {
        guard let manifest = try? JSONDecoder().decode(IOSSyncManifest.self, from: metadata.manifestData) else {
            return nil
        }
        return IOSRemoteSnapshot(
            fileName: metadata.fileName,
            provider: kind,
            manifest: manifest,
            modifiedAt: metadata.modifiedAt,
            sizeBytes: metadata.sizeBytes,
            remoteRevision: metadata.revision
        )
    }

    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, database.isRetryable(error) else { throw error }
                attempt += 1
                if retryDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
        }
    }

    private func cloudSafeSnapshotFileName(_ fileName: String) throws -> String {
        let component = (fileName as NSString).lastPathComponent
        guard component == fileName,
              component.count <= 180,
              component.hasSuffix(".\(IOSSyncBackup.fileExtension)") else {
            throw IOSSyncBackupError.invalidArchive("远端快照文件名无效")
        }
        return component
    }
}
