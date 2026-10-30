import CommonCrypto
import CryptoKit
import Foundation
import Security
import Shared
import UIKit

struct IOSSyncBackup {
    static let fileExtension = "amberbackup"
    static let mimeType = "application/vnd.amberagent.backup+zip"

    private static let currentArchiveVersion = 1
    private static let pbkdf2Iterations = 210_000
    private static let keySizeBytes = 32
    private static let saltBytes = 16
    private static let ivBytes = 12
    private static let tagBytes = 16
    private static let noPassphraseFallback = "AmberAgent-NoPassphrase-v1"

    private static let manifestEntry = "manifest.json"
    private static let payloadEntry = "payload.enc"
    private static let settingsEntry = "settings.json"
    private static let payloadManifestEntry = "payload_manifest.json"
    private static let conversationsEntry = "conversations.zip"
    private static let threadEdgesEntry = "thread-edges.json"
    private static let conversationMetadataEntries: Set<String> = [
        "index.json",
        "list-previews.json",
        "list-icons.json",
        // 产物架收藏按设备保存，不进入备份。
        "artifact-shelf.json",
        "task-ui-drafts.json",
        "conversation-recaps.json",
        threadEdgesEntry,
    ]
    private static let healthToolName = "health_summary_read"

    /// Exports an encrypted backup archive. Includes settings (always) plus an
    /// optional conversations bundle (Android SyncArchiveManager parity — iOS
    /// was settings-only before, so iOS→iOS conversation continuity was
    /// impossible). The conversations bundle is a zip of the on-disk
    /// `conversations/` directory passed by the caller.
    static func export(
        settings: Settings,
        passphrase: String?,
        remoteRevision: String? = nil,
        conversationsZip: Data? = nil
    ) throws -> Data {
        // Scheme B: redact credentials before capturing into the backup payload
        // (parity with Android BackupSettingsRedactor; iOS uses
        // IOSCredentialRedactor). Encryption is not a substitute for redaction —
        // a passphrase-protected backup decrypts back to plaintext credentials.
        let settingsJson = IOSCredentialRedactor.redact(
            IosSettingsJsonBridge.shared.encode(settings: settings)
        )
        let settingsData = Data(settingsJson.utf8)
        var datasets: [IOSSyncDatasetSummary] = [
            IOSSyncDatasetSummary(id: "settings", recordCount: 1, byteCount: Int64(settingsData.count))
        ]
        var zipEntries: [IOSStoredZipArchive.Entry] = [
            .init(name: settingsEntry, data: settingsData)
        ]
        if let conversationsZip {
            zipEntries.append(.init(name: conversationsEntry, data: conversationsZip))
            datasets.append(IOSSyncDatasetSummary(
                id: "conversations",
                recordCount: -1, // count unknown without parsing; -1 = "all"
                byteCount: Int64(conversationsZip.count)
            ))
        }
        let payloadManifest = IOSSyncPayloadManifest(datasets: datasets)
        let payloadManifestData = try JSONEncoder().encode(payloadManifest)
        zipEntries.append(.init(name: payloadManifestEntry, data: payloadManifestData))
        let payloadZip = try IOSStoredZipArchive.write(entries: zipEntries)

        let salt = Data.secureRandom(count: saltBytes)
        let iv = Data.secureRandom(count: ivBytes)
        let effectivePassphrase = try normalizedPassphrase(passphrase)
        let key = try deriveKey(passphrase: effectivePassphrase, salt: salt)
        let sealedBox = try AES.GCM.seal(payloadZip, using: key, nonce: AES.GCM.Nonce(data: iv))
        let encryptedPayload = sealedBox.ciphertext + sealedBox.tag
        let sha256 = SHA256.hash(data: encryptedPayload).map { String(format: "%02x", $0) }.joined()

        let manifest = IOSSyncManifest(
            archiveVersion: currentArchiveVersion,
            appVersionName: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            appVersionCode: Int64((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 1),
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            deviceId: settings.syncSettings.deviceId,
            deviceLabel: IOSDeviceLabel.current,
            mode: String(describing: settings.syncSettings.mode),
            remoteRevision: remoteRevision ?? settings.syncSettings.lastRemoteRevision,
            encrypted: true,
            kdf: IOSSyncKdfInfo(iterations: pbkdf2Iterations, saltBase64: salt.base64EncodedString()),
            cipher: IOSSyncCipherInfo(ivBase64: iv.base64EncodedString()),
            payloadSha256: sha256,
            passphraseProtected: !(passphrase?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
        let manifestData = try JSONEncoder().encode(manifest)

        return try IOSStoredZipArchive.write(entries: [
            .init(name: manifestEntry, data: manifestData),
            .init(name: payloadEntry, data: encryptedPayload),
        ])
    }

    static func `import`(data: Data, passphrase: String?) throws -> IOSSyncImportResult {
        try decodeArchive(data: data, passphrase: passphrase, fileName: nil)
    }

    /// Bundles every `{id}.json` conversation file in the given directory into a
    /// zip for inclusion in the backup payload. Returns nil if the directory
    /// is missing or empty (the caller then exports settings-only, honestly).
    static func conversationsZip(
        fromDirectory directoryURL: URL,
        threadEdges: [IOSConversationThreadEdge]? = nil
    ) throws -> Data? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return nil }
        let entries = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        let jsonFiles = entries.filter {
            isConversationDocumentName($0.lastPathComponent)
        }
        guard !jsonFiles.isEmpty else { return nil }
        // One conversation at a time: inlined screenshots can make a single document tens
        // of MB, so each is appended to the archive and released before reading the next.
        var archive = IOSStoredZipArchive.Writer()
        var exportedConversationIDs = Set<String>()
        for file in jsonFiles {
            try autoreleasepool {
                let data = try Data(contentsOf: file)
                // HealthKit data must never enter Amber's local export or remote
                // CloudKit/WebDAV snapshot. A health tool call makes the whole
                // conversation private because later assistant text may summarize it.
                guard !containsHealthToolCall(data) else { return }
                if let id = conversationID(from: data) { exportedConversationIDs.insert(id) }
                archive.append(
                    name: file.lastPathComponent,
                    data: try selfContainedConversationData(data, fileURL: file)
                )
            }
        }
        guard archive.entryCount > 0 else { return nil }

        if let threadEdges {
            let storedConversationIDs = Set(jsonFiles.map {
                $0.deletingPathExtension().lastPathComponent.lowercased()
            })
            let eligibleEdges = threadEdges.filter { edge in
                guard let child = canonicalConversationID(edge.childThreadId),
                      let parent = canonicalConversationID(edge.parentThreadId) else {
                    return false
                }
                return exportedConversationIDs.contains(child)
                    && (exportedConversationIDs.contains(parent) || !storedConversationIDs.contains(parent))
            }
            archive.append(name: threadEdgesEntry, data: try JSONEncoder().encode(eligibleEdges))
        }
        return archive.finish()
    }

    /// Extracts a conversations bundle (from a restored backup) into the given
    /// directory. Returns the number of conversation files written. Used by the
    /// restore path to rehydrate conversation history.
    @discardableResult
    static func restoreConversations(zipData: Data, intoDirectory directoryURL: URL) throws -> Int {
        let entries = try IOSStoredZipArchive.read(data: zipData)
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var written = 0
        for (name, data) in entries {
            // Sanitize the name to a single component (no path traversal).
            let safeName = (name as NSString).lastPathComponent
            guard isConversationDocumentName(safeName) else { continue }
            try data.write(to: directoryURL.appendingPathComponent(safeName), options: [.atomic])
            written += 1
        }
        return written
    }

    /// Reads full Conversation JSON documents from a restored bundle without
    /// writing around JsonConversationStorage's mutex/index ownership.
    static func conversationDocuments(zipData: Data) throws -> [String] {
        let entries = try IOSStoredZipArchive.read(data: zipData)
        return try entries
            .filter { name, _ in
                let component = (name as NSString).lastPathComponent
                return isConversationDocumentName(component)
            }
            .sorted { $0.key < $1.key }
            .map { name, data in
                guard let document = String(data: data, encoding: .utf8) else {
                    throw IOSSyncBackupError.invalidArchive("会话文件不是 UTF-8：\(name)")
                }
                return document
            }
    }

    /// Reads the optional relationship sidecar. Older conversation bundles do
    /// not contain it and intentionally return nil.
    static func conversationThreadEdges(zipData: Data) throws -> [IOSConversationThreadEdge]? {
        let entries = try IOSStoredZipArchive.read(data: zipData)
        guard let sidecar = entries[threadEdgesEntry] else { return nil }
        do {
            return try JSONDecoder().decode([IOSConversationThreadEdge].self, from: sidecar)
        } catch {
            throw IOSSyncBackupError.invalidArchive("线程关系 sidecar 无效：\(error.localizedDescription)")
        }
    }

    /// Conversation files keep large screenshots as `amber-blob://` references into
    /// the sibling `<id>.blobs/` directory. Backups must stay self-contained and
    /// restorable by app versions without blob storage, so inline the references
    /// back to `data:` URLs before zipping. Files without references pass through.
    /// Throws (failing the whole backup visibly) rather than exporting a document whose
    /// readable screenshots could not be inlined.
    private static func selfContainedConversationData(_ data: Data, fileURL: URL) throws -> Data {
        guard data.range(of: Data("amber-blob://".utf8)) != nil else { return data }
        guard let text = String(data: data, encoding: .utf8) else {
            throw IOSSyncBackupError.invalidArchive("会话文件不是 UTF-8：\(fileURL.lastPathComponent)")
        }
        let inlined = try ConversationBlobsKt.inlineConversationBlobsForExport(
            conversationFilePath: fileURL.path,
            documentText: text
        )
        return Data(inlined.utf8)
    }

    private static func isConversationDocumentName(_ name: String) -> Bool {
        let component = (name as NSString).lastPathComponent.lowercased()
        return (component as NSString).pathExtension == "json"
            && !conversationMetadataEntries.contains(component)
    }

    private static func conversationID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["id"] as? String else {
            return nil
        }
        return canonicalConversationID(rawID)
    }

    private static func canonicalConversationID(_ raw: String) -> String? {
        UUID(uuidString: raw)?.uuidString.lowercased()
    }

    private static func containsHealthToolCall(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return false }
        return containsHealthToolCall(root)
    }

    private static func containsHealthToolCall(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object["toolName"] as? String == healthToolName
                || object["tool_name"] as? String == healthToolName {
                return true
            }
            return object.values.contains(where: containsHealthToolCall)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsHealthToolCall)
        }
        return false
    }

    static func restorePreview(data: Data, passphrase: String?, fileName: String? = nil) throws -> IOSSyncPreview {
        try decodeArchive(data: data, passphrase: passphrase, fileName: fileName).preview
    }

    static func inspectManifest(data: Data, fileName: String? = nil) throws -> IOSSyncPreview {
        let archiveEntries = try IOSStoredZipArchive.read(data: data)
        guard let manifestData = archiveEntries[manifestEntry] else {
            throw IOSSyncBackupError.invalidArchive("同步备份缺少 manifest.json")
        }
        guard let encryptedPayload = archiveEntries[payloadEntry] else {
            throw IOSSyncBackupError.invalidArchive("同步备份缺少 payload.enc")
        }
        let manifest = try JSONDecoder().decode(IOSSyncManifest.self, from: manifestData)
        try validate(manifest: manifest)

        guard encryptedPayload.count > tagBytes else {
            throw IOSSyncBackupError.emptyPayload
        }
        let actualSha256 = SHA256.hash(data: encryptedPayload).map { String(format: "%02x", $0) }.joined()
        guard actualSha256 == manifest.payloadSha256 else {
            throw IOSSyncBackupError.invalidArchive("同步备份 payload 校验失败")
        }
        return IOSSyncPreview(manifest: manifest, fileName: fileName, sizeBytes: Int64(data.count), datasets: [])
    }

    private static func decodeArchive(
        data: Data,
        passphrase: String?,
        fileName: String?
    ) throws -> IOSSyncImportResult {
        let manifestPreview = try inspectManifest(data: data, fileName: fileName)
        let archiveEntries = try IOSStoredZipArchive.read(data: data)
        let manifest = manifestPreview.manifest
        guard let encryptedPayload = archiveEntries[payloadEntry] else {
            throw IOSSyncBackupError.invalidArchive("同步备份缺少 payload.enc")
        }

        let salt = try Data(base64: manifest.kdf.saltBase64, field: "saltBase64")
        let iv = try Data(base64: manifest.cipher.ivBase64, field: "ivBase64")
        let key = try deriveKey(passphrase: normalizedPassphrase(passphrase, protected: manifest.passphraseProtected), salt: salt)
        let ciphertext = encryptedPayload.prefix(encryptedPayload.count - tagBytes)
        let tag = encryptedPayload.suffix(tagBytes)
        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        let payloadZip = try AES.GCM.open(sealedBox, using: key)
        let payloadEntries = try IOSStoredZipArchive.read(data: payloadZip)
        guard let settingsData = payloadEntries[settingsEntry],
              let settingsJson = String(data: settingsData, encoding: .utf8) else {
            throw IOSSyncBackupError.invalidArchive("同步备份缺少 settings.json")
        }
        let payloadManifest = try payloadEntries[payloadManifestEntry].map {
            try JSONDecoder().decode(IOSSyncPayloadManifest.self, from: $0)
        } ?? IOSSyncPayloadManifest()
        // decode 声明了 @Throws：备份内 settings.json 损坏时作为失败抛出，
        // 由调用方报告导入失败，而不是在 Kotlin/Native 边界终止进程。
        let settings = try IosSettingsJsonBridge.shared.decode(json: settingsJson)
        let preview = IOSSyncPreview(
            manifest: manifest,
            fileName: fileName,
            sizeBytes: Int64(data.count),
            datasets: payloadManifest.datasets
        )
        return IOSSyncImportResult(
            settings: settings,
            preview: preview,
            conversationsZip: payloadEntries[conversationsEntry]
        )
    }

    private static func normalizedPassphrase(_ passphrase: String?, protected: Bool = false) throws -> String {
        let trimmed = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if protected { throw IOSSyncBackupError.invalidPassphrase }
            return noPassphraseFallback
        }
        return trimmed
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        guard let passphraseData = passphrase.data(using: .utf8) else {
            throw IOSSyncBackupError.invalidPassphrase
        }
        var key = Data(repeating: 0, count: keySizeBytes)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                passphraseData.withUnsafeBytes { passphraseBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBytes.bindMemory(to: Int8.self).baseAddress,
                        passphraseData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Iterations),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keySizeBytes
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw IOSSyncBackupError.unsupportedCrypto("PBKDF2-HMAC-SHA256 派生失败：\(status)")
        }
        return SymmetricKey(data: key)
    }

    private static func validate(manifest: IOSSyncManifest) throws {
        guard manifest.archiveVersion == currentArchiveVersion else {
            throw IOSSyncBackupError.invalidArchive("不支持的同步备份版本：\(manifest.archiveVersion)")
        }
        guard manifest.kdf.name == "PBKDF2WithHmacSHA256",
              manifest.kdf.iterations == pbkdf2Iterations,
              manifest.kdf.keySizeBits == 256 else {
            throw IOSSyncBackupError.unsupportedCrypto("Unsupported KDF: \(manifest.kdf.name)")
        }
        guard manifest.cipher.name == "AES/GCM/NoPadding",
              manifest.cipher.tagSizeBits == 128 else {
            throw IOSSyncBackupError.unsupportedCrypto("Unsupported cipher: \(manifest.cipher.name)")
        }
    }
}

struct IOSSyncImportResult {
    let settings: Settings
    let preview: IOSSyncPreview
    let conversationsZip: Data?
}

struct IOSSyncPreview: Equatable, Sendable {
    let manifest: IOSSyncManifest
    let fileName: String?
    let sizeBytes: Int64
    let datasets: [IOSSyncDatasetSummary]
}

struct IOSSyncManifest: Codable, Equatable, Sendable {
    let archiveVersion: Int
    let appVersionName: String
    let appVersionCode: Int64
    let createdAt: Int64
    let deviceId: String
    let deviceLabel: String
    let mode: String
    let remoteRevision: String
    let encrypted: Bool
    let kdf: IOSSyncKdfInfo
    let cipher: IOSSyncCipherInfo
    let payloadSha256: String
    let passphraseProtected: Bool

    init(
        archiveVersion: Int = 1,
        appVersionName: String,
        appVersionCode: Int64,
        createdAt: Int64,
        deviceId: String,
        deviceLabel: String = "",
        mode: String,
        remoteRevision: String = "",
        encrypted: Bool = true,
        kdf: IOSSyncKdfInfo,
        cipher: IOSSyncCipherInfo,
        payloadSha256: String,
        passphraseProtected: Bool = true
    ) {
        self.archiveVersion = archiveVersion
        self.appVersionName = appVersionName
        self.appVersionCode = appVersionCode
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.deviceLabel = deviceLabel
        self.mode = mode
        self.remoteRevision = remoteRevision
        self.encrypted = encrypted
        self.kdf = kdf
        self.cipher = cipher
        self.payloadSha256 = payloadSha256
        self.passphraseProtected = passphraseProtected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.archiveVersion = try container.decodeIfPresent(Int.self, forKey: .archiveVersion) ?? 1
        self.appVersionName = try container.decode(String.self, forKey: .appVersionName)
        self.appVersionCode = try container.decode(Int64.self, forKey: .appVersionCode)
        self.createdAt = try container.decode(Int64.self, forKey: .createdAt)
        self.deviceId = try container.decode(String.self, forKey: .deviceId)
        self.deviceLabel = try container.decodeIfPresent(String.self, forKey: .deviceLabel) ?? ""
        self.mode = try container.decode(String.self, forKey: .mode)
        self.remoteRevision = try container.decodeIfPresent(String.self, forKey: .remoteRevision) ?? ""
        self.encrypted = try container.decodeIfPresent(Bool.self, forKey: .encrypted) ?? true
        self.kdf = try container.decode(IOSSyncKdfInfo.self, forKey: .kdf)
        self.cipher = try container.decode(IOSSyncCipherInfo.self, forKey: .cipher)
        self.payloadSha256 = try container.decode(String.self, forKey: .payloadSha256)
        self.passphraseProtected = try container.decodeIfPresent(Bool.self, forKey: .passphraseProtected) ?? true
    }
}

struct IOSSyncKdfInfo: Codable, Equatable, Sendable {
    var name: String
    let iterations: Int
    let saltBase64: String
    var keySizeBits: Int

    init(
        name: String = "PBKDF2WithHmacSHA256",
        iterations: Int,
        saltBase64: String,
        keySizeBits: Int = 256
    ) {
        self.name = name
        self.iterations = iterations
        self.saltBase64 = saltBase64
        self.keySizeBits = keySizeBits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "PBKDF2WithHmacSHA256"
        self.iterations = try container.decode(Int.self, forKey: .iterations)
        self.saltBase64 = try container.decode(String.self, forKey: .saltBase64)
        self.keySizeBits = try container.decodeIfPresent(Int.self, forKey: .keySizeBits) ?? 256
    }
}

struct IOSSyncCipherInfo: Codable, Equatable, Sendable {
    var name: String
    let ivBase64: String
    var tagSizeBits: Int

    init(
        name: String = "AES/GCM/NoPadding",
        ivBase64: String,
        tagSizeBits: Int = 128
    ) {
        self.name = name
        self.ivBase64 = ivBase64
        self.tagSizeBits = tagSizeBits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "AES/GCM/NoPadding"
        self.ivBase64 = try container.decode(String.self, forKey: .ivBase64)
        self.tagSizeBits = try container.decodeIfPresent(Int.self, forKey: .tagSizeBits) ?? 128
    }
}

struct IOSSyncPayloadManifest: Codable, Equatable, Sendable {
    var datasets: [IOSSyncDatasetSummary] = []
}

struct IOSSyncDatasetSummary: Codable, Equatable, Sendable {
    let id: String
    let recordCount: Int
    let byteCount: Int64
}

private enum IOSDeviceLabel {
    static var current: String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                let device = UIDevice.current
                return [device.systemName, device.model].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return "iOS Device"
    }
}

enum IOSRemoteProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case localFolder
    case cloudKit
    case webDAV
    case googleDrive
    case s3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localFolder:
            return "本机文件夹"
        case .cloudKit:
            return "iCloud"
        case .webDAV:
            return "WebDAV"
        case .googleDrive:
            return "Google Drive"
        case .s3:
            return "S3"
        }
    }
}

struct IOSRemoteSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let fileName: String
    let provider: IOSRemoteProviderKind
    let createdAt: Int64
    let modifiedAt: Int64
    let sizeBytes: Int64
    let remoteRevision: String
    let deviceId: String
    let deviceLabel: String
    let appVersionName: String
    let appVersionCode: Int64
    let mode: String
    let encrypted: Bool
    let passphraseProtected: Bool
    let payloadSha256: String

    static func fileName(for manifest: IOSSyncManifest) -> String {
        "amber-sync-\(manifest.createdAt).\(IOSSyncBackup.fileExtension)"
    }

    init(
        id: String? = nil,
        fileName: String,
        provider: IOSRemoteProviderKind,
        createdAt: Int64,
        modifiedAt: Int64,
        sizeBytes: Int64,
        remoteRevision: String,
        deviceId: String,
        deviceLabel: String,
        appVersionName: String,
        appVersionCode: Int64,
        mode: String,
        encrypted: Bool,
        passphraseProtected: Bool,
        payloadSha256: String
    ) {
        self.id = id ?? "\(provider.rawValue):\(fileName):\(remoteRevision)"
        self.fileName = fileName
        self.provider = provider
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.remoteRevision = remoteRevision
        self.deviceId = deviceId
        self.deviceLabel = deviceLabel
        self.appVersionName = appVersionName
        self.appVersionCode = appVersionCode
        self.mode = mode
        self.encrypted = encrypted
        self.passphraseProtected = passphraseProtected
        self.payloadSha256 = payloadSha256
    }

    init(
        fileName: String,
        provider: IOSRemoteProviderKind,
        manifest: IOSSyncManifest,
        modifiedAt: Int64,
        sizeBytes: Int64,
        remoteRevision: String
    ) {
        self.init(
            fileName: fileName,
            provider: provider,
            createdAt: manifest.createdAt,
            modifiedAt: modifiedAt,
            sizeBytes: sizeBytes,
            remoteRevision: remoteRevision,
            deviceId: manifest.deviceId,
            deviceLabel: manifest.deviceLabel,
            appVersionName: manifest.appVersionName,
            appVersionCode: manifest.appVersionCode,
            mode: manifest.mode,
            encrypted: manifest.encrypted,
            passphraseProtected: manifest.passphraseProtected,
            payloadSha256: manifest.payloadSha256
        )
    }
}

protocol IOSRemoteSyncProvider: Sendable {
    var kind: IOSRemoteProviderKind { get }
    var displayName: String { get }
    var isConfigured: Bool { get }

    func testConnection() async throws
    func listSnapshots() async throws -> [IOSRemoteSnapshot]
    func uploadSnapshot(data: Data, fileName: String, manifest: IOSSyncManifest) async throws -> IOSRemoteSnapshot
    func downloadSnapshot(_ snapshot: IOSRemoteSnapshot) async throws -> Data
    func deleteSnapshot(_ snapshot: IOSRemoteSnapshot) async throws
}

extension IOSRemoteSyncProvider {
    var displayName: String { kind.displayName }

    func latestSnapshot() async throws -> IOSRemoteSnapshot? {
        try await listSnapshots().sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.createdAt > rhs.createdAt
        }.first
    }
}

struct IOSLocalFolderSyncProvider: IOSRemoteSyncProvider {
    let folderURL: URL

    var kind: IOSRemoteProviderKind { .localFolder }
    var isConfigured: Bool { true }

    init(folderURL: URL = IOSLocalFolderSyncProvider.defaultFolderURL()) {
        self.folderURL = folderURL
    }

    static func defaultFolderURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("AmberRemoteSyncLocal", isDirectory: true)
    }

    func testConnection() async throws {
        try ensureFolder()
    }

    func listSnapshots() async throws -> [IOSRemoteSnapshot] {
        try ensureFolder()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == IOSSyncBackup.fileExtension }
            .compactMap { try? snapshot(from: $0) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func uploadSnapshot(data: Data, fileName: String, manifest: IOSSyncManifest) async throws -> IOSRemoteSnapshot {
        try ensureFolder()
        let safeName = try safeSnapshotFileName(fileName)
        let targetURL = folderURL.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: targetURL, options: [.atomic])
        return try snapshot(from: targetURL, fallbackManifest: manifest, data: data)
    }

    func downloadSnapshot(_ snapshot: IOSRemoteSnapshot) async throws -> Data {
        let safeName = try safeSnapshotFileName(snapshot.fileName)
        return try Data(contentsOf: folderURL.appendingPathComponent(safeName, isDirectory: false))
    }

    func deleteSnapshot(_ snapshot: IOSRemoteSnapshot) async throws {
        let safeName = try safeSnapshotFileName(snapshot.fileName)
        let url = folderURL.appendingPathComponent(safeName, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
    }

    private func snapshot(from url: URL) throws -> IOSRemoteSnapshot {
        try snapshot(from: url, fallbackManifest: nil, data: nil)
    }

    private func snapshot(from url: URL, fallbackManifest: IOSSyncManifest?, data cachedData: Data?) throws -> IOSRemoteSnapshot {
        let data: Data
        if let cachedData {
            data = cachedData
        } else {
            data = try Data(contentsOf: url)
        }
        let preview = try IOSSyncBackup.inspectManifest(data: data, fileName: url.lastPathComponent)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: TimeInterval(preview.manifest.createdAt) / 1000)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        let manifest = fallbackManifest ?? preview.manifest
        return IOSRemoteSnapshot(
            fileName: url.lastPathComponent,
            provider: kind,
            manifest: manifest,
            modifiedAt: Int64(modified.timeIntervalSince1970 * 1000),
            sizeBytes: size,
            remoteRevision: data.sha256Hex()
        )
    }
}

struct IOSWebDAVSyncProvider: IOSRemoteSyncProvider {
    let config: IOSWebDAVConfig
    let transport: any IOSWebDAVTransport
    private var client: IOSWebDAVClient { IOSWebDAVClient(config: config, transport: transport) }

    var kind: IOSRemoteProviderKind { .webDAV }
    var isConfigured: Bool { config.isConfigured }

    init(config: IOSWebDAVConfig, transport: any IOSWebDAVTransport = IOSURLSessionWebDAVTransport()) {
        self.config = config
        self.transport = transport
    }

    func testConnection() async throws { try await client.testConnection() }

    func listSnapshots() async throws -> [IOSRemoteSnapshot] {
        try await client.listResources()
            .filter { !$0.isCollection && $0.fileName.hasSuffix(".\(IOSSyncBackup.fileExtension)") }
            .map { resource in
                IOSRemoteSnapshot(fileName: resource.fileName, provider: kind,
                    createdAt: resource.modifiedAt, modifiedAt: resource.modifiedAt,
                    sizeBytes: resource.sizeBytes, remoteRevision: resource.remoteRevision,
                    deviceId: "", deviceLabel: "", appVersionName: "", appVersionCode: 0,
                    mode: "", encrypted: true, passphraseProtected: true, payloadSha256: "")
            }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func uploadSnapshot(data: Data, fileName: String, manifest: IOSSyncManifest) async throws -> IOSRemoteSnapshot {
        let safeName = try safeSnapshotFileName(fileName)
        let revision = try await client.upload(data: data, fileName: safeName, mimeType: IOSSyncBackup.mimeType)
        return IOSRemoteSnapshot(fileName: safeName, provider: kind, manifest: manifest,
            modifiedAt: Int64(Date().timeIntervalSince1970 * 1000), sizeBytes: Int64(data.count),
            remoteRevision: revision)
    }

    func downloadSnapshot(_ snapshot: IOSRemoteSnapshot) async throws -> Data {
        try await client.download(fileName: safeSnapshotFileName(snapshot.fileName))
    }

    func deleteSnapshot(_ snapshot: IOSRemoteSnapshot) async throws {
        try await client.delete(fileName: safeSnapshotFileName(snapshot.fileName))
    }

    func makeRequest(method: String, fileName: String? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        try client.makeRequest(method: method, fileName: fileName, headers: headers)
    }
}

struct IOSUnavailableRemoteSyncProvider: IOSRemoteSyncProvider {
    let kind: IOSRemoteProviderKind
    let reason: String

    var isConfigured: Bool { false }

    func testConnection() async throws { throw unavailableError() }
    func listSnapshots() async throws -> [IOSRemoteSnapshot] { throw unavailableError() }
    func uploadSnapshot(data: Data, fileName: String, manifest: IOSSyncManifest) async throws -> IOSRemoteSnapshot {
        throw unavailableError()
    }
    func downloadSnapshot(_ snapshot: IOSRemoteSnapshot) async throws -> Data { throw unavailableError() }
    func deleteSnapshot(_ snapshot: IOSRemoteSnapshot) async throws { throw unavailableError() }

    private func unavailableError() -> IOSSyncBackupError {
        .remoteProviderUnavailable("\(kind.displayName) 尚未配置：\(reason)")
    }
}

struct IOSSyncConflict: Equatable {
    let localRevision: String
    let remoteSnapshot: IOSRemoteSnapshot
}

enum IOSSyncConflictResolver {
    static func conflict(status: IOSRemoteSyncStatus, remoteSnapshots: [IOSRemoteSnapshot]) -> IOSSyncConflict? {
        guard !status.remoteRevision.isEmpty,
              let latest = remoteSnapshots.filter({ $0.provider == status.provider }).sorted(by: { lhs, rhs in
                  if lhs.createdAt == rhs.createdAt {
                      return lhs.modifiedAt > rhs.modifiedAt
                  }
                  return lhs.createdAt > rhs.createdAt
              }).first,
              latest.remoteRevision != status.remoteRevision else {
            return nil
        }
        return IOSSyncConflict(localRevision: status.remoteRevision, remoteSnapshot: latest)
    }
}

private func safeSnapshotFileName(_ fileName: String) throws -> String {
    guard !fileName.isEmpty, fileName == URL(fileURLWithPath: fileName).lastPathComponent,
          !fileName.contains("\\"),
          fileName.hasSuffix(".\(IOSSyncBackup.fileExtension)") else {
        throw IOSSyncBackupError.invalidArchive("Invalid snapshot file name: \(fileName)")
    }
    return fileName
}

private struct IOSStoredZipArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    static func write(entries: [Entry]) throws -> Data {
        var writer = Writer()
        for entry in entries { writer.append(name: entry.name, data: entry.data) }
        return writer.finish()
    }

    /// Incremental stored-zip writer: each entry's bytes are copied into the output as
    /// it is appended, so callers can release the source data right away.
    struct Writer {
        private var output = Data()
        private var records: [(name: String, size: UInt32, crc: UInt32, offset: UInt32)] = []

        var entryCount: Int { records.count }

        mutating func append(name: String, data: Data) {
            guard let nameData = name.data(using: .utf8) else { return }
            let offset = UInt32(output.count)
            let crc = data.crc32()
            output.appendUInt32LE(0x04034b50)
            output.appendUInt16LE(20)
            output.appendUInt16LE(0x0800)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt32LE(crc)
            output.appendUInt32LE(UInt32(data.count))
            output.appendUInt32LE(UInt32(data.count))
            output.appendUInt16LE(UInt16(nameData.count))
            output.appendUInt16LE(0)
            output.append(nameData)
            output.append(data)
            records.append((name, UInt32(data.count), crc, offset))
        }

        mutating func finish() -> Data {
            var central = Data()
            let centralOffset = UInt32(output.count)
            for record in records {
                let nameData = Data(record.name.utf8)
                central.appendUInt32LE(0x02014b50)
                central.appendUInt16LE(20)
                central.appendUInt16LE(20)
                central.appendUInt16LE(0x0800)
                central.appendUInt16LE(0)
                central.appendUInt16LE(0)
                central.appendUInt16LE(0)
                central.appendUInt32LE(record.crc)
                central.appendUInt32LE(record.size)
                central.appendUInt32LE(record.size)
                central.appendUInt16LE(UInt16(nameData.count))
                central.appendUInt16LE(0)
                central.appendUInt16LE(0)
                central.appendUInt16LE(0)
                central.appendUInt16LE(0)
                central.appendUInt32LE(0)
                central.appendUInt32LE(record.offset)
                central.append(nameData)
            }
            output.append(central)
            output.appendUInt32LE(0x06054b50)
            output.appendUInt16LE(0)
            output.appendUInt16LE(0)
            output.appendUInt16LE(UInt16(records.count))
            output.appendUInt16LE(UInt16(records.count))
            output.appendUInt32LE(UInt32(central.count))
            output.appendUInt32LE(centralOffset)
            output.appendUInt16LE(0)
            let result = output
            output = Data()
            records = []
            return result
        }
    }

    static func read(data: Data) throws -> [String: Data] {
        guard let eocd = data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else {
            throw IOSSyncBackupError.invalidArchive("Invalid ZIP: missing central directory")
        }
        let entryCount = Int(try data.uint16LE(at: eocd + 10))
        let centralOffset = Int(try data.uint32LE(at: eocd + 16))
        var cursor = centralOffset
        var result: [String: Data] = [:]

        for _ in 0..<entryCount {
            guard try data.uint32LE(at: cursor) == 0x02014b50 else {
                throw IOSSyncBackupError.invalidArchive("Invalid ZIP central directory")
            }
            let method = try data.uint16LE(at: cursor + 10)
            guard method == 0 else {
                throw IOSSyncBackupError.invalidArchive("Unsupported ZIP compression method: \(method)")
            }
            let compressedSize = Int(try data.uint32LE(at: cursor + 20))
            let nameLength = Int(try data.uint16LE(at: cursor + 28))
            let extraLength = Int(try data.uint16LE(at: cursor + 30))
            let commentLength = Int(try data.uint16LE(at: cursor + 32))
            let localOffset = Int(try data.uint32LE(at: cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw IOSSyncBackupError.invalidArchive("Invalid ZIP entry name")
            }
            try requireSafeRelativePath(name)
            guard try data.uint32LE(at: localOffset) == 0x04034b50 else {
                throw IOSSyncBackupError.invalidArchive("Invalid ZIP local header")
            }
            let localNameLength = Int(try data.uint16LE(at: localOffset + 26))
            let localExtraLength = Int(try data.uint16LE(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else {
                throw IOSSyncBackupError.invalidArchive("Invalid ZIP entry size")
            }
            result[name] = Data(data[dataStart..<dataEnd])
            cursor = nameEnd + extraLength + commentLength
        }
        return result
    }

    private static func requireSafeRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.contains("\\"),
              !path.hasPrefix("/"),
              !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw IOSSyncBackupError.invalidArchive("Invalid archive path: \(path)")
        }
    }
}

private extension Data {
    static func secureRandom(count: Int) -> Data {
        var bytes = Data(repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    init(base64: String, field: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw IOSSyncBackupError.invalidArchive("Invalid base64 field: \(field)")
        }
        self = data
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset + 2 <= count else { throw IOSSyncBackupError.invalidArchive("Unexpected ZIP EOF") }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset + 4 <= count else { throw IOSSyncBackupError.invalidArchive("Unexpected ZIP EOF") }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }

    func crc32() -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in self {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ IOSCRC32.table[index]
        }
        return crc ^ 0xffffffff
    }

    func sha256Hex() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}

private enum IOSCRC32 {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xedb88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }
}
