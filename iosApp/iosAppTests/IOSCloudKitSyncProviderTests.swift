import Foundation
import Shared
import XCTest
@testable import iosApp

private final class FakeCloudKitDatabase: IOSCloudKitDatabase, @unchecked Sendable {
    var isConfigured = true
    var records: [String: (IOSCloudKitBackupMetadata, Data)] = [:]
    var transientListFailures = 0
    var listCallCount = 0

    func testAccount() async throws {
        if !isConfigured { throw IOSCloudKitDatabaseError.notConfigured }
    }

    func listBackupMetadata() async throws -> [IOSCloudKitBackupMetadata] {
        listCallCount += 1
        if transientListFailures > 0 {
            transientListFailures -= 1
            throw IOSCloudKitDatabaseError.transient("offline")
        }
        return records.values.map(\.0)
    }

    func saveBackup(
        recordName: String,
        fileName: String,
        archive: Data,
        manifestData: Data
    ) async throws -> IOSCloudKitBackupMetadata {
        let metadata = IOSCloudKitBackupMetadata(
            recordName: recordName,
            fileName: fileName,
            manifestData: manifestData,
            modifiedAt: 2_000_000_000_000,
            sizeBytes: Int64(archive.count),
            revision: "ck-revision-1"
        )
        records[recordName] = (metadata, archive)
        return metadata
    }

    func fetchBackup(recordName: String) async throws -> Data {
        guard let value = records[recordName]?.1 else {
            throw IOSCloudKitDatabaseError.missingArchive
        }
        return value
    }

    func deleteBackup(recordName: String) async throws {
        records[recordName] = nil
    }

    func isRetryable(_ error: Error) -> Bool {
        if case IOSCloudKitDatabaseError.transient = error { return true }
        return false
    }
}

final class IOSCloudKitSyncProviderTests: XCTestCase {
    func testCloudKitProviderUploadListDownloadDeleteContract() async throws {
        let database = FakeCloudKitDatabase()
        let provider = IOSCloudKitSyncProvider(
            database: database,
            maxAttempts: 2,
            retryDelayNanoseconds: 0
        )
        let archive = try IOSSyncBackup.export(
            settings: IosSettingsDefaults.shared.defaultSeededSettings(),
            passphrase: "cloud"
        )
        let manifest = try IOSSyncBackup.inspectManifest(data: archive).manifest

        let uploaded = try await provider.uploadSnapshot(
            data: archive,
            fileName: "cloud.amberbackup",
            manifest: manifest
        )
        XCTAssertEqual(uploaded.provider, .cloudKit)
        XCTAssertEqual(uploaded.remoteRevision, "ck-revision-1")

        let listed = try await provider.listSnapshots()
        XCTAssertEqual(listed.map(\.fileName), ["cloud.amberbackup"])
        let downloaded = try await provider.downloadSnapshot(uploaded)
        XCTAssertEqual(downloaded, archive)

        try await provider.deleteSnapshot(uploaded)
        let remaining = try await provider.listSnapshots()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCloudKitProviderRetriesTransientOfflineFailure() async throws {
        let database = FakeCloudKitDatabase()
        database.transientListFailures = 1
        let provider = IOSCloudKitSyncProvider(
            database: database,
            maxAttempts: 2,
            retryDelayNanoseconds: 0
        )

        _ = try await provider.listSnapshots()

        XCTAssertEqual(database.listCallCount, 2)
    }

    func testCloudKitEntitlementMirrorFailsClosedForExperimentalTarget() {
        let info = [
            "AmberAgentConfiguredEntitlements": [
                "com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.icloud-services"
            ],
            "AmberAgentExperimentalConfiguredEntitlements": []
        ]
        XCTAssertTrue(IOSPrivateCloudKitDatabase.currentTargetHasCloudKitEntitlementMirror(
            bundleIdentifier: "app.amber.ios",
            infoDictionary: info
        ))
        XCTAssertFalse(IOSPrivateCloudKitDatabase.currentTargetHasCloudKitEntitlementMirror(
            bundleIdentifier: "app.amber.ios.experimental-gpl",
            infoDictionary: info
        ))
    }

    func testEncryptedArchiveDeclaresNoHealthKitDataset() throws {
        let archive = try IOSSyncBackup.export(
            settings: IosSettingsDefaults.shared.defaultSeededSettings(),
            passphrase: "privacy"
        )
        let restored = try IOSSyncBackup.import(data: archive, passphrase: "privacy")

        let datasetIDs = restored.preview.datasets.map { $0.id }
        XCTAssertEqual(datasetIDs, ["settings"])
        XCTAssertFalse(datasetIDs.contains("healthkit"))
    }

    func testCloudKitProviderRejectsPlaintextOrMismatchedArchive() async throws {
        let database = FakeCloudKitDatabase()
        let provider = IOSCloudKitSyncProvider(
            database: database,
            maxAttempts: 1,
            retryDelayNanoseconds: 0
        )
        let archive = try IOSSyncBackup.export(
            settings: IosSettingsDefaults.shared.defaultSeededSettings(),
            passphrase: "cloud"
        )
        let encryptedManifest = try IOSSyncBackup.inspectManifest(data: archive).manifest
        let plaintextManifest = IOSSyncManifest(
            archiveVersion: encryptedManifest.archiveVersion,
            appVersionName: encryptedManifest.appVersionName,
            appVersionCode: encryptedManifest.appVersionCode,
            createdAt: encryptedManifest.createdAt,
            deviceId: encryptedManifest.deviceId,
            deviceLabel: encryptedManifest.deviceLabel,
            mode: encryptedManifest.mode,
            remoteRevision: encryptedManifest.remoteRevision,
            encrypted: false,
            kdf: encryptedManifest.kdf,
            cipher: encryptedManifest.cipher,
            payloadSha256: encryptedManifest.payloadSha256,
            passphraseProtected: encryptedManifest.passphraseProtected
        )

        do {
            _ = try await provider.uploadSnapshot(
                data: archive,
                fileName: "plaintext.amberbackup",
                manifest: plaintextManifest
            )
            XCTFail("Expected unencrypted manifest to be rejected")
        } catch {
            XCTAssertTrue(database.records.isEmpty)
        }

        do {
            _ = try await provider.uploadSnapshot(
                data: Data("plaintext".utf8),
                fileName: "invalid.amberbackup",
                manifest: encryptedManifest
            )
            XCTFail("Expected non-archive data to be rejected")
        } catch {
            XCTAssertTrue(database.records.isEmpty)
        }
    }
}
