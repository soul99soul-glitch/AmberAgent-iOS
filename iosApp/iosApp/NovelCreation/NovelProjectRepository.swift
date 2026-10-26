import Foundation
import os

enum NovelRepositoryFailureStage: String, Hashable, Sendable {
    case afterTempWrite
    case afterTempValidation
    case beforePrimaryInstall
    case afterPrimaryInstallBeforeIndex
    case beforeIndexWrite
    case beforeRecoveryWrite
    case afterRecoveryWrite
    case beforeRecoveryDelete
    case beforeReplacementMarkerWrite
    case afterReplacementInstallBeforeCleanup
    case beforeDeletionTombstoneWrite
    case afterDeletionTombstoneWrite
    case beforeDeletionCleanup
}

actor NovelFileProjectRepository: NovelProjectPersisting {
    static let maximumProjectBytes = 100 * 1_024 * 1_024
    static let logger = Logger(
        subsystem: "app.amber.ios",
        category: "NovelProjectRepository"
    )
    private struct ProjectLifecycleMarkerV1: Codable, Equatable {
        enum Kind: String, Codable {
            case deletion
            case replacement
        }

        let schemaVersion: Int
        let projectID: NovelProjectID
        let kind: Kind
        let expectedRevision: Int64
    }

    private struct RecoveryFileIdentity: Hashable {
        let projectID: NovelProjectID
        let runID: NovelRunID
    }

    private struct RecoveryFileStamp: Equatable {
        let fileNumber: UInt64
        let byteCount: UInt64
        let modifiedAt: Date
    }

    private struct CachedRecoverySidecar {
        let sequence: Int64
        let partialSHA256: String
        let stamp: RecoveryFileStamp
    }

    private struct LifecycleFileIdentity: Equatable {
        let projectID: NovelProjectID
        let operationID: NovelOperationID
    }

    private let rootDirectory: URL
    let fileManager: FileManager
    let failingStages: Set<NovelRepositoryFailureStage>
    /// Opt-in legacy→workspace cutover on first open (contract D-E). The
    /// production composition enables it; legacy-chain contract tests keep it
    /// off so the transitional machinery stays covered.
    let automaticWorkspaceMigration: Bool
    /// Per-project encode cache so unchanged heavy sections (injection receipts,
    /// snapshots, …) are not re-encoded on every small tool write.
    var sectionCaches: [NovelProjectID: NovelProjectShardedStorage.SectionCache] = [:]
    /// Last published book-pointer fingerprint per workspace project
    /// (branch head checkpoint + working selections). The branches section
    /// also churns on activeRunID/updatedAt, which must NOT trigger a full
    /// tree publish.
    var pointerFingerprints: [NovelProjectID: String] = [:]
    /// The workspace marker is immutable during ordinary project operations.
    /// Cache its decoded mode per actor and invalidate it at marker lifecycle boundaries.
    var workspaceNativeByProject: [NovelProjectID: Bool] = [:]
    private var cachedRecoverySidecars: [RecoveryFileIdentity: CachedRecoverySidecar] = [:]
    private var directoriesEnsured = false

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        failingStages: Set<NovelRepositoryFailureStage> = [],
        automaticWorkspaceMigration: Bool = false
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.failingStages = failingStages
        self.automaticWorkspaceMigration = automaticWorkspaceMigration
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NovelError.storageUnavailable("Application Support directory is unavailable.")
        }
        return applicationSupport
            .appendingPathComponent("AmberAgent", isDirectory: true)
            .appendingPathComponent("NovelCreation", isDirectory: true)
    }

    func listProjects() async throws -> [NovelProjectSummary] {
        try ensureDirectories()
        finishDeletionTombstonesBestEffort()
        // Fast path: the on-disk index already holds lightweight summaries. Full
        // document decode of every project on every entry made large novels feel
        // like a multi-second "正在读取项目" stall. Prefer the index when its
        // project set still matches disk and no project file is newer than the
        // index itself; fall back to a full scan when anything looks stale.
        if let cached = try? loadCachedProjectSummariesIfFresh() {
            return cached
        }
        do {
            let summaries = try scanProjectSummaries()
            writeIndexBestEffort(summaries)
            return summaries
        } catch {
            if let index = try? readIndex() {
                let deleted = deletionTombstoneProjectIDs()
                return index.projects
                    .filter { !deleted.contains($0.id) }
                    .sorted(by: NovelProjectSummary.listOrder)
            }
            throw error
        }
    }

    func loadProject(id: NovelProjectID) async throws -> NovelLoadedProject {
        try ensureDirectories()
        if isDeletionTombstoned(id) {
            finishDeletionBestEffort(projectID: id)
            throw NovelError.projectNotFound(id)
        }
        let package = packageURL(for: id)
        let hasPackage = NovelProjectShardedStorage.isPackage(at: package, fileManager: fileManager)
        let hasMonofile = fileManager.fileExists(atPath: primaryURL(for: id).path)
        if isReplacementMarked(id), !hasPackage, !hasMonofile {
            throw NovelError.storageIndeterminate(id)
        }
        guard hasPackage || hasMonofile ||
                fileManager.fileExists(atPath: previousURL(for: id).path) ||
                fileManager.fileExists(
                    atPath: NovelProjectShardedStorage.previousLayoutURL(in: package).path
                ) || isWorkspaceNative(id) else {
            throw NovelError.projectNotFound(id)
        }
        do {
            let document = try readInstalledProjectDocument(projectID: id)
            finishReplacementBestEffort(projectID: id)
            return NovelLoadedProject(document: document, access: .readWrite)
        } catch let error as NovelError {
            if isReplacementMarked(id) {
                throw NovelError.storageIndeterminate(id)
            }
            switch error {
            case .unsupportedSchema, .storageUnavailable:
                throw error
            default:
                return try loadPreviousProject(id: id, primaryFailure: String(describing: error))
            }
        } catch {
            if isReplacementMarked(id) {
                throw NovelError.storageIndeterminate(id)
            }
            return try loadPreviousProject(id: id, primaryFailure: String(describing: error))
        }
    }

    func createProject(_ document: NovelProjectDocumentV1) async throws -> NovelLoadedProject {
        try ensureDirectories()
        try NovelDocumentValidator.validate(document)
        let projectID = document.project.id
        let isReinstallingDeletedProject = isDeletionTombstoned(projectID)
        if isReinstallingDeletedProject {
            try cleanupProjectFiles(projectID: projectID, includingPrimary: true)
        } else if isReplacementMarked(projectID) {
            throw NovelError.storageIndeterminate(projectID)
        }
        guard !projectExistsOnDisk(projectID) else {
            throw NovelError.projectAlreadyExists(projectID)
        }
        sectionCaches[projectID] = nil
        pointerFingerprints[projectID] = nil
        workspaceNativeByProject[projectID] = nil
        try failIfRequested(.beforePrimaryInstall)
        do {
            try writeShardedProject(document)
        } catch {
            if let installed = try? readInstalledProjectDocument(projectID: projectID),
               installed.project.revision == document.project.revision {
                // Install completed despite a late error.
            } else {
                throw NovelError.repositoryFailure("Could not create novel project: \(error)")
            }
        }
        if isReinstallingDeletedProject {
            do {
                try fileManager.removeItem(at: tombstoneURL(for: projectID))
            } catch {
                throw NovelError.storageIndeterminate(projectID)
            }
        }
        do {
            try failIfRequested(.afterPrimaryInstallBeforeIndex)
        } catch {
            throw NovelError.storageIndeterminate(projectID)
        }
        upsertIndexBestEffort(document: document)
        return NovelLoadedProject(document: document, access: .readWrite)
    }

    /// Workspace-native creation (contract D-E): engine sections into
    /// `.amber/engine`, book tree printed to `checkout/`, baseline commit and
    /// object library sealed in `.amber/`. No sharded package at the project
    /// root is ever created for this project.
    func createProject(
        _ document: NovelProjectDocumentV1,
        workspaceNative: Bool
    ) async throws -> NovelLoadedProject {
        guard workspaceNative else {
            return try await createProject(document)
        }
        try ensureDirectories()
        try NovelDocumentValidator.validate(document)
        let projectID = document.project.id
        let isReinstallingDeletedProject = isDeletionTombstoned(projectID)
        if isReinstallingDeletedProject {
            try cleanupProjectFiles(projectID: projectID, includingPrimary: true)
        } else if isReplacementMarked(projectID) {
            throw NovelError.storageIndeterminate(projectID)
        }
        guard !projectExistsOnDisk(projectID) else {
            throw NovelError.projectAlreadyExists(projectID)
        }
        sectionCaches[projectID] = nil
        pointerFingerprints[projectID] = nil
        workspaceNativeByProject[projectID] = nil
        let project = packageURL(for: projectID)
        do {
            sectionCaches[projectID] = try NovelWorkspaceProjectStore.writeEngineSections(
                document: document,
                projectDirectory: project,
                fileManager: fileManager
            )
            try NovelWorkspaceProjectStore.publishValidatedDocument(
                document: document,
                projectDirectory: project,
                fileManager: fileManager
            )
        } catch {
            throw NovelError.repositoryFailure(
                "Could not create workspace novel project: \(error)"
            )
        }
        workspaceNativeByProject[projectID] = true
        pointerFingerprints[projectID] = pointerFingerprint(document)
        if isReinstallingDeletedProject {
            do {
                try fileManager.removeItem(at: tombstoneURL(for: projectID))
            } catch {
                throw NovelError.storageIndeterminate(projectID)
            }
        }
        // Engine sections persist the pruned view; return it so callers and
        // disk agree from birth.
        let returned = NovelWorkspaceProjectStore.persistableAtRest(document)
        upsertIndexBestEffort(document: returned)
        return NovelLoadedProject(document: returned, access: .readWrite)
    }

    func commitProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64,
        authorization: NovelRepositoryCommitAuthorization?
    ) async throws -> NovelLoadedProject {
        try ensureDirectories()
        let projectID = document.project.id
        guard !isDeletionTombstoned(projectID), !isReplacementMarked(projectID) else {
            throw NovelError.projectNotFound(projectID)
        }
        let loaded = try await loadProject(id: projectID)
        guard loaded.access == .readWrite else {
            throw NovelError.degradedReadOnly(projectID: projectID)
        }
        guard loaded.document.project.revision == expectedRevision else {
            throw NovelError.staleProjectRevision(
                expected: expectedRevision,
                actual: loaded.document.project.revision
            )
        }
        guard document.project.revision == expectedRevision + 1 else {
            throw NovelError.invalidDocument(["A commit must advance project revision exactly once."])
        }
        try NovelDocumentValidator.validateTransition(from: loaded.document, to: document)
        return try installValidatedCommit(
            document,
            expectedRevision: expectedRevision,
            authorization: authorization
        )
    }

    func commitProject(
        _ transition: NovelValidatedProjectTransition,
        authorization: NovelRepositoryCommitAuthorization?
    ) async throws -> NovelLoadedProject {
        try ensureDirectories()
        let current = transition.current
        let document = transition.document
        let projectID = document.project.id
        guard current.project.id == projectID,
              !isDeletionTombstoned(projectID),
              !isReplacementMarked(projectID) else {
            throw NovelError.projectNotFound(projectID)
        }
        let expectedRevision = current.project.revision
        guard document.project.revision == expectedRevision + 1 else {
            throw NovelError.invalidDocument(["A commit must advance project revision exactly once."])
        }

        // The normal save path can reuse the exact, validated document that
        // populated the repository's section cache. A small layout check proves
        // the engine did not change behind that cache; checkout reconciliation
        // still protects out-of-band markdown edits. Any uncertainty falls back
        // to the original full load + transition validation path.
        guard canCommitValidatedTransitionFromCache(transition) else {
            return try await commitProject(
                document,
                expectedRevision: expectedRevision,
                authorization: authorization
            )
        }
        let reconciled = try NovelWorkspaceProjectStore.reconcileBookTree(
            document: current,
            projectDirectory: packageURL(for: projectID),
            fileManager: fileManager
        )
        guard reconciled.project.revision == expectedRevision else {
            sectionCaches[projectID] = nil
            throw NovelError.staleProjectRevision(
                expected: expectedRevision,
                actual: reconciled.project.revision
            )
        }
        // Reconciliation may have attempted to adopt an out-of-band chapter
        // edit. If it changed the engine before a later publish failure, the
        // returned document can still be `current`; re-check disk freshness so
        // this save cannot overwrite that adopted revision.
        guard let cache = sectionCaches[projectID],
              engineLayoutMatchesCache(
                  projectID: projectID,
                  revision: expectedRevision,
                  cache: cache
              ) else {
            return try await commitProject(
                document,
                expectedRevision: expectedRevision,
                authorization: authorization
            )
        }
        return try installValidatedCommit(
            document,
            expectedRevision: expectedRevision,
            authorization: authorization
        )
    }

    private func installValidatedCommit(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64,
        authorization: NovelRepositoryCommitAuthorization?
    ) throws -> NovelLoadedProject {
        let projectID = document.project.id
        try failIfRequested(.beforePrimaryInstall)
        try authorization?.claim()

        do {
            try writeShardedProject(document)
        } catch {
            if let installed = try? readInstalledProjectDocument(projectID: projectID),
               installed.project.revision == document.project.revision {
                // Treat an installed next revision as committed.
            } else if let stillCurrent = try? readInstalledProjectDocument(projectID: projectID),
                      stillCurrent.project.revision == expectedRevision {
                throw NovelError.repositoryFailure("Could not replace novel project: \(error)")
            } else {
                throw NovelError.storageIndeterminate(projectID)
            }
        }

        do {
            try failIfRequested(.afterPrimaryInstallBeforeIndex)
        } catch {
            throw NovelError.storageIndeterminate(projectID)
        }
        // At rest the persisted document is the PRUNED equivalent; return it
        // so callers continue from exactly what is on disk.
        let returned = isWorkspaceNative(projectID)
            ? NovelWorkspaceProjectStore.persistableAtRest(document)
            : document
        upsertIndexBestEffort(document: returned)
        return NovelLoadedProject(document: returned, access: .readWrite)
    }

    func replaceProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64
    ) async throws -> NovelLoadedProject {
        try ensureDirectories()
        try NovelDocumentValidator.validate(document)
        let projectID = document.project.id
        guard !isDeletionTombstoned(projectID) else {
            throw NovelError.projectNotFound(projectID)
        }
        let loaded = try await loadProject(id: projectID)
        guard loaded.document.project.revision == expectedRevision else {
            throw NovelError.staleProjectRevision(
                expected: expectedRevision,
                actual: loaded.document.project.revision
            )
        }
        guard !loaded.document.activeRuns.contains(where: { $0.status == .running }) else {
            throw NovelError.projectBusy(projectID)
        }

        try failIfRequested(.beforeReplacementMarkerWrite)
        do {
            try writeLifecycleMarker(ProjectLifecycleMarkerV1(
                schemaVersion: 1,
                projectID: projectID,
                kind: .replacement,
                expectedRevision: expectedRevision
            ), to: replacementMarkerURL(for: projectID))
        } catch {
            if isReplacementMarked(projectID) {
                throw NovelError.storageIndeterminate(projectID)
            }
            throw error
        }
        try failIfRequested(.beforePrimaryInstall)

        // Replacement can rewrite append-mostly sections under the same IDs;
        // those fingerprints are sound for reducer transitions, not imports.
        let expectedInstalledDocument = isWorkspaceNative(projectID)
            ? NovelWorkspaceProjectStore.persistableAtRest(document)
            : document
        sectionCaches[projectID] = nil
        pointerFingerprints[projectID] = nil
        workspaceNativeByProject[projectID] = nil

        do {
            try writeShardedProject(document)
        } catch {
            let installed = try? readInstalledProjectDocument(projectID: projectID)
            if installed == expectedInstalledDocument {
                // Continue cleanup after an indeterminate result.
            } else if installed == loaded.document {
                do {
                    try fileManager.removeItem(at: replacementMarkerURL(for: projectID))
                } catch {
                    throw NovelError.storageIndeterminate(projectID)
                }
                throw NovelError.repositoryFailure("Could not replace imported novel project: \(error)")
            } else {
                throw NovelError.storageIndeterminate(projectID)
            }
        }
        do {
            try failIfRequested(.afterReplacementInstallBeforeCleanup)
            try cleanupProjectFiles(projectID: projectID, includingPrimary: false)
            try fileManager.removeItem(at: replacementMarkerURL(for: projectID))
        } catch {
            throw NovelError.storageIndeterminate(projectID)
        }
        workspaceNativeByProject[projectID] = nil
        upsertIndexBestEffort(document: document)
        return NovelLoadedProject(document: document, access: .readWrite)
    }

    func deleteProject(id: NovelProjectID, expectedRevision: Int64) async throws {
        try ensureDirectories()
        if isDeletionTombstoned(id) {
            finishDeletionBestEffort(projectID: id)
            return
        }
        let loaded = try await loadProject(id: id)
        guard loaded.document.project.revision == expectedRevision else {
            throw NovelError.staleProjectRevision(
                expected: expectedRevision,
                actual: loaded.document.project.revision
            )
        }
        guard !loaded.document.activeRuns.contains(where: { $0.status == .running }) else {
            throw NovelError.projectBusy(id)
        }

        try deleteProjectArtifacts(id: id, expectedRevision: expectedRevision)
    }

    func discardUnavailableProject(id: NovelProjectID) async throws {
        try ensureDirectories()
        if isDeletionTombstoned(id) {
            finishDeletionBestEffort(projectID: id)
            return
        }
        guard let summary = try scanProjectSummaries().first(where: { $0.id == id }) else {
            throw NovelError.projectNotFound(id)
        }
        guard summary.loadError != nil else {
            throw NovelError.staleProjectRevision(expected: 0, actual: summary.revision)
        }

        try deleteProjectArtifacts(id: id, expectedRevision: 0)
    }

    private func deleteProjectArtifacts(id: NovelProjectID, expectedRevision: Int64) throws {
        try failIfRequested(.beforeDeletionTombstoneWrite)
        do {
            try writeLifecycleMarker(ProjectLifecycleMarkerV1(
                schemaVersion: 1,
                projectID: id,
                kind: .deletion,
                expectedRevision: expectedRevision
            ), to: tombstoneURL(for: id))
        } catch {
            if isDeletionTombstoned(id) {
                throw NovelError.storageIndeterminate(id)
            }
            throw error
        }
        do {
            try invalidateIndex()
            try failIfRequested(.afterDeletionTombstoneWrite)
            try failIfRequested(.beforeDeletionCleanup)
            try cleanupProjectFiles(projectID: id, includingPrimary: true)
        } catch {
            refreshIndexBestEffort()
            throw NovelError.storageIndeterminate(id)
        }
        refreshIndexBestEffort()
    }

    func lifecycleOperation(
        projectID: NovelProjectID,
        operationID: NovelOperationID
    ) async throws -> NovelProjectLifecycleOperationRecord? {
        try ensureDirectories()
        let url = lifecycleOperationURL(projectID: projectID, operationID: operationID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readLifecycleOperation(
            at: url,
            expected: LifecycleFileIdentity(projectID: projectID, operationID: operationID)
        )
    }

    func lifecycleOperationIDs(projectID: NovelProjectID) async throws -> Set<NovelOperationID> {
        try ensureDirectories()
        let urls = try fileManager.contentsOfDirectory(
            at: lifecycleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return Set(urls.compactMap { url in
            guard url.pathExtension == "json",
                  let identity = lifecycleFileIdentity(for: url),
                  identity.projectID == projectID else {
                return nil
            }
            return identity.operationID
        })
    }

    func listPendingLifecycleOperations() async throws -> [NovelProjectLifecycleOperationRecord] {
        try ensureDirectories()
        let urls = try fileManager.contentsOfDirectory(
            at: lifecycleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var records: [NovelProjectLifecycleOperationRecord] = []
        for url in urls where url.pathExtension == "json" {
            guard let identity = lifecycleFileIdentity(for: url) else {
                quarantineInvalidLifecycleOperation(at: url)
                continue
            }
            do {
                let record = try readLifecycleOperation(at: url, expected: identity)
                if record.state == .pending {
                    records.append(record)
                }
            } catch {
                // Keep the parseable filename as durable evidence. The blocked
                // project scan prevents any write from treating corruption as absence.
            }
        }
        return records.sorted {
            if $0.projectID != $1.projectID {
                return $0.projectID.description < $1.projectID.description
            }
            return $0.operationID.description < $1.operationID.description
        }
    }

    func blockedLifecycleProjectIDs() async throws -> Set<NovelProjectID> {
        try ensureDirectories()
        let urls = try fileManager.contentsOfDirectory(
            at: lifecycleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var blocked: Set<NovelProjectID> = []
        for url in urls where url.pathExtension == "json" {
            guard let identity = lifecycleFileIdentity(for: url) else {
                quarantineInvalidLifecycleOperation(at: url)
                continue
            }
            do {
                _ = try readLifecycleOperation(at: url, expected: identity)
            } catch {
                blocked.insert(identity.projectID)
            }
        }
        return blocked
    }

    func writeLifecycleOperation(_ record: NovelProjectLifecycleOperationRecord) async throws {
        try ensureDirectories()
        try record.validate()
        let url = lifecycleOperationURL(
            projectID: record.projectID,
            operationID: record.operationID
        )
        if fileManager.fileExists(atPath: url.path) {
            let current = try readLifecycleOperation(
                at: url,
                expected: LifecycleFileIdentity(
                    projectID: record.projectID,
                    operationID: record.operationID
                )
            )
            try current.validateTransition(to: record)
            if current == record { return }
        }
        let data = try makeEncoder().encode(record)
        try data.write(to: url, options: [.atomic])
        let installed = try readLifecycleOperation(
            at: url,
            expected: LifecycleFileIdentity(
                projectID: record.projectID,
                operationID: record.operationID
            )
        )
        guard installed == record else {
            throw NovelError.storageIndeterminate(record.projectID)
        }
    }

    func removeLifecycleOperation(_ record: NovelProjectLifecycleOperationRecord) async throws {
        try ensureDirectories()
        let url = lifecycleOperationURL(
            projectID: record.projectID,
            operationID: record.operationID
        )
        guard fileManager.fileExists(atPath: url.path) else { return }
        let current = try readLifecycleOperation(
            at: url,
            expected: LifecycleFileIdentity(
                projectID: record.projectID,
                operationID: record.operationID
            )
        )
        guard current == record, current.state == .pending else {
            throw NovelError.storageIndeterminate(record.projectID)
        }
        try fileManager.removeItem(at: url)
    }

    func restorePreviousProject(
        id: NovelProjectID,
        expectedDocumentSHA256: String
    ) async throws -> NovelLoadedProject {
        try ensureDirectories()
        guard !isDeletionTombstoned(id), !isReplacementMarked(id) else {
            throw NovelError.projectNotFound(id)
        }
        let restored = try readPreviousProjectDocument(projectID: id)
        guard try NovelProjectPackageCodec.encode(restored).projectSHA256 ==
            expectedDocumentSHA256 else {
            throw NovelError.storageIndeterminate(id)
        }
        try writeShardedProject(restored)
        let installed = try readInstalledProjectDocument(projectID: id)
        guard installed.project.revision == restored.project.revision else {
            throw NovelError.storageIndeterminate(id)
        }
        upsertIndexBestEffort(document: installed)
        return NovelLoadedProject(document: installed, access: .readWrite)
    }

    func listRecoverySidecars() async throws -> [NovelRecoverySidecarV1] {
        try ensureDirectories()
        let deleted = deletionTombstoneProjectIDs()
        let urls = try fileManager.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var sidecars: [NovelRecoverySidecarV1] = []
        for url in urls where url.pathExtension == "json" {
            guard let identity = recoveryFileIdentity(for: url) else {
                quarantineInvalidRecovery(at: url)
                continue
            }
            if deleted.contains(identity.projectID) {
                try? fileManager.removeItem(at: url)
                continue
            }
            do {
                let sidecar = try readRecoverySidecar(at: url, expected: identity)
                sidecars.append(sidecar)
            } catch {
                quarantineInvalidRecovery(at: url)
            }
        }
        return sidecars.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.runID.description < $1.runID.description
        }
    }

    func writeRecoverySidecar(_ sidecar: NovelRecoverySidecarV1) async throws {
        try ensureDirectories()
        guard !isDeletionTombstoned(sidecar.projectID),
              !isReplacementMarked(sidecar.projectID) else {
            throw NovelError.projectNotFound(sidecar.projectID)
        }
        try NovelDocumentValidator.validateRecovery(sidecar)
        let url = recoveryURL(projectID: sidecar.projectID, runID: sidecar.runID)
        let identity = RecoveryFileIdentity(projectID: sidecar.projectID, runID: sidecar.runID)
        if fileManager.fileExists(atPath: url.path) {
            let cached = cachedRecoverySidecars[identity]
            let stamp = recoveryFileStamp(at: url)
            if let cached, cached.stamp == stamp,
               cached.sequence > sidecar.sequence {
                throw NovelError.invalidRecovery("Recovery sequence cannot move backwards.")
            }
            if let cached, cached.stamp == stamp,
               cached.sequence == sidecar.sequence,
               cached.partialSHA256 != sidecar.partialSHA256 {
                throw NovelError.invalidRecovery(
                    "A recovery sequence cannot be reused with different content."
                )
            }
            if cached == nil || cached?.stamp != stamp || cached?.sequence == sidecar.sequence {
                cachedRecoverySidecars[identity] = nil
                let current: NovelRecoverySidecarV1?
                do {
                    current = try readRecoverySidecar(at: url, expected: identity)
                } catch {
                    quarantineInvalidRecovery(at: url)
                    current = nil
                }
                if let current {
                    if current.sequence > sidecar.sequence {
                        throw NovelError.invalidRecovery("Recovery sequence cannot move backwards.")
                    }
                    if current.sequence == sidecar.sequence {
                        guard current == sidecar else {
                            throw NovelError.invalidRecovery(
                                "A recovery sequence cannot be reused with different content."
                            )
                        }
                        if let stamp = recoveryFileStamp(at: url) {
                            cachedRecoverySidecars[identity] = CachedRecoverySidecar(
                                sequence: current.sequence,
                                partialSHA256: current.partialSHA256,
                                stamp: stamp
                            )
                        }
                        return
                    }
                }
            }
        } else {
            cachedRecoverySidecars[identity] = nil
        }
        try failIfRequested(.beforeRecoveryWrite)
        let data = try makeEncoder().encode(sidecar)
        try data.write(to: url, options: [.atomic])
        try failIfRequested(.afterRecoveryWrite)
        if let stamp = recoveryFileStamp(at: url) {
            cachedRecoverySidecars[identity] = CachedRecoverySidecar(
                sequence: sidecar.sequence,
                partialSHA256: sidecar.partialSHA256,
                stamp: stamp
            )
        }
    }

    func removeRecoverySidecar(projectID: NovelProjectID, runID: NovelRunID) async throws {
        try ensureDirectories()
        try failIfRequested(.beforeRecoveryDelete)
        let url = recoveryURL(projectID: projectID, runID: runID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        cachedRecoverySidecars[
            RecoveryFileIdentity(projectID: projectID, runID: runID)
        ] = nil
    }

    func loadGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelGhostwriteBatchProgressRecord? {
        try ensureDirectories()
        let url = ghostwriteProgressURL(projectID: projectID, branchID: branchID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let record = try makeDecoder().decode(NovelGhostwriteBatchProgressRecord.self, from: data)
        guard record.projectID == projectID, record.branchID == branchID else {
            return nil
        }
        return record
    }

    func saveGhostwriteBatchProgress(_ record: NovelGhostwriteBatchProgressRecord) async throws {
        try ensureDirectories()
        if isDeletionTombstoned(record.projectID) || isReplacementMarked(record.projectID) {
            throw NovelError.projectNotFound(record.projectID)
        }
        guard projectExistsOnDisk(record.projectID) else {
            throw NovelError.projectNotFound(record.projectID)
        }
        let url = ghostwriteProgressURL(
            projectID: record.projectID,
            branchID: record.branchID
        )
        let data = try makeEncoder().encode(record)
        try data.write(to: url, options: [.atomic])
    }

    func removeGhostwriteBatchProgress(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws {
        try ensureDirectories()
        let url = ghostwriteProgressURL(projectID: projectID, branchID: branchID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    var projectDirectory: URL {
        rootDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    /// Workspace-native mode (contract D-E): the book tree at `checkout/` is
    /// the runtime authority, engine sections live in `.amber/engine`, the
    /// ledger and object library in `.amber/`. Legacy projects keep the
    /// sharded package at the project root.
    func isWorkspaceNative(_ projectID: NovelProjectID) -> Bool {
        if let cached = workspaceNativeByProject[projectID] {
            return cached
        }
        let isNative = NovelWorkspaceProjectStore.isWorkspaceNative(
            projectDirectory: packageURL(for: projectID),
            fileManager: fileManager
        )
        workspaceNativeByProject[projectID] = isNative
        return isNative
    }

    func engineStorageDirectory(for projectID: NovelProjectID) -> URL {
        let project = packageURL(for: projectID)
        guard isWorkspaceNative(projectID) else { return project }
        return NovelWorkspaceProjectStore.engineDirectory(in: project)
    }

    private var recoveryDirectory: URL {
        rootDirectory.appendingPathComponent("recovery", isDirectory: true)
    }

    private var ghostwriteProgressDirectory: URL {
        rootDirectory.appendingPathComponent("ghostwrite-progress", isDirectory: true)
    }

    private var tombstoneDirectory: URL {
        rootDirectory.appendingPathComponent("tombstones", isDirectory: true)
    }

    private var replacementDirectory: URL {
        rootDirectory.appendingPathComponent("replacements", isDirectory: true)
    }

    private var lifecycleDirectory: URL {
        rootDirectory.appendingPathComponent("lifecycle", isDirectory: true)
    }

    var indexURL: URL {
        rootDirectory.appendingPathComponent("index.json")
    }

    var indexManifestURL: URL {
        rootDirectory.appendingPathComponent("index.manifest.json")
    }

    /// Legacy single-file primary (still readable; migrated away on next commit).
    func primaryURL(for projectID: NovelProjectID) -> URL {
        projectDirectory.appendingPathComponent("\(projectID.description).json")
    }

    /// Legacy single-file previous snapshot.
    func previousURL(for projectID: NovelProjectID) -> URL {
        projectDirectory.appendingPathComponent("\(projectID.description).previous.json")
    }

    /// Sharded package directory: `projects/{id}/layout.json` + content-addressed blobs.
    func packageURL(for projectID: NovelProjectID) -> URL {
        NovelProjectShardedStorage.packageDirectory(
            projectDirectory: projectDirectory,
            projectID: projectID
        )
    }

    private func projectExistsOnDisk(_ projectID: NovelProjectID) -> Bool {
        fileManager.fileExists(atPath: primaryURL(for: projectID).path)
            || NovelProjectShardedStorage.isPackage(
                at: packageURL(for: projectID),
                fileManager: fileManager
            )
            || fileManager.fileExists(atPath: previousURL(for: projectID).path)
            || fileManager.fileExists(
                atPath: NovelProjectShardedStorage.previousLayoutURL(
                    in: packageURL(for: projectID)
                ).path
            )
            || fileManager.fileExists(
                atPath: NovelWorkspaceProjectStore.markerURL(
                    in: packageURL(for: projectID)
                ).path
            )
    }

    private func tombstoneURL(for projectID: NovelProjectID) -> URL {
        tombstoneDirectory.appendingPathComponent("\(projectID.description).json")
    }

    private func replacementMarkerURL(for projectID: NovelProjectID) -> URL {
        replacementDirectory.appendingPathComponent("\(projectID.description).json")
    }

    private func recoveryURL(projectID: NovelProjectID, runID: NovelRunID) -> URL {
        recoveryDirectory.appendingPathComponent(
            "\(projectID.description)-\(runID.description).json"
        )
    }

    private func ghostwriteProgressURL(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> URL {
        ghostwriteProgressDirectory.appendingPathComponent(
            "\(projectID.description)-\(branchID.description).json"
        )
    }

    private func lifecycleOperationURL(
        projectID: NovelProjectID,
        operationID: NovelOperationID
    ) -> URL {
        lifecycleDirectory.appendingPathComponent(
            "\(projectID.description)-\(operationID.description).json"
        )
    }

    private func lifecycleFileIdentity(for url: URL) -> LifecycleFileIdentity? {
        let name = url.deletingPathExtension().lastPathComponent
        let bytes = Array(name.utf8)
        guard bytes.count == 73, bytes[36] == 45 else { return nil }
        let projectText = String(decoding: bytes[0..<36], as: UTF8.self)
        let operationText = String(decoding: bytes[37..<73], as: UTF8.self)
        guard let projectUUID = UUID(uuidString: projectText),
              let operationUUID = UUID(uuidString: operationText) else {
            return nil
        }
        let identity = LifecycleFileIdentity(
            projectID: NovelProjectID(projectUUID),
            operationID: NovelOperationID(operationUUID)
        )
        guard url.lastPathComponent == lifecycleOperationURL(
            projectID: identity.projectID,
            operationID: identity.operationID
        ).lastPathComponent else {
            return nil
        }
        return identity
    }

    private func readLifecycleOperation(
        at url: URL,
        expected identity: LifecycleFileIdentity
    ) throws -> NovelProjectLifecycleOperationRecord {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= 1_024 * 1_024 else {
            throw NovelError.repositoryFailure("Novel lifecycle operation file is invalid.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let record = try makeDecoder().decode(NovelProjectLifecycleOperationRecord.self, from: data)
        try record.validate()
        guard record.projectID == identity.projectID,
              record.operationID == identity.operationID else {
            throw NovelError.repositoryFailure(
                "Novel lifecycle operation filename does not match its contents."
            )
        }
        return record
    }

    private func quarantineInvalidLifecycleOperation(at url: URL) {
        let destination = lifecycleDirectory.appendingPathComponent(
            ".invalid-lifecycle-\(UUID().uuidString.lowercased()).record"
        )
        do {
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            try? fileManager.removeItem(at: url)
        }
    }

    private func recoveryFileIdentity(for url: URL) -> RecoveryFileIdentity? {
        let name = url.deletingPathExtension().lastPathComponent
        let bytes = Array(name.utf8)
        guard bytes.count == 73, bytes[36] == 45 else {
            return nil
        }
        let projectText = String(decoding: bytes[0..<36], as: UTF8.self)
        let runText = String(decoding: bytes[37..<73], as: UTF8.self)
        guard let projectUUID = UUID(uuidString: projectText),
              let runUUID = UUID(uuidString: runText) else {
            return nil
        }
        let identity = RecoveryFileIdentity(
            projectID: NovelProjectID(projectUUID),
            runID: NovelRunID(runUUID)
        )
        guard url.lastPathComponent == recoveryURL(
            projectID: identity.projectID,
            runID: identity.runID
        ).lastPathComponent else {
            return nil
        }
        return identity
    }

    private func readRecoverySidecar(
        at url: URL,
        expected identity: RecoveryFileIdentity
    ) throws -> NovelRecoverySidecarV1 {
        let data = try readData(at: url, projectID: nil)
        do {
            let sidecar = try makeDecoder().decode(NovelRecoverySidecarV1.self, from: data)
            try NovelDocumentValidator.validateRecovery(sidecar)
            guard sidecar.projectID == identity.projectID,
                  sidecar.runID == identity.runID else {
                throw NovelError.invalidRecovery(
                    "Recovery filename does not match its contents."
                )
            }
            return sidecar
        } catch let error as NovelError {
            throw error
        } catch {
            throw NovelError.invalidRecovery("\(url.lastPathComponent): \(error)")
        }
    }

    private func recoveryFileStamp(at url: URL) -> RecoveryFileStamp? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileNumber = attributes[.systemFileNumber] as? NSNumber,
              let byteCount = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return RecoveryFileStamp(
            fileNumber: fileNumber.uint64Value,
            byteCount: byteCount.uint64Value,
            modifiedAt: modifiedAt
        )
    }

    private func quarantineInvalidRecovery(at url: URL) {
        let destination = recoveryDirectory.appendingPathComponent(
            ".invalid-recovery-\(UUID().uuidString.lowercased()).sidecar"
        )
        do {
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            try? fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectories() throws {
        guard !directoriesEnsured else { return }
        do {
            try fileManager.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: tombstoneDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: replacementDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: lifecycleDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: ghostwriteProgressDirectory,
                withIntermediateDirectories: true
            )
            directoriesEnsured = true
        } catch {
            throw NovelError.storageUnavailable("Could not prepare novel storage: \(error)")
        }
    }

    private func isDeletionTombstoned(_ projectID: NovelProjectID) -> Bool {
        fileManager.fileExists(atPath: tombstoneURL(for: projectID).path)
    }

    func isReplacementMarked(_ projectID: NovelProjectID) -> Bool {
        fileManager.fileExists(atPath: replacementMarkerURL(for: projectID).path)
    }

    private func writeLifecycleMarker(
        _ marker: ProjectLifecycleMarkerV1,
        to url: URL
    ) throws {
        // .atomic 写失败本身会抛错；写后读回只防硬件故障，去掉这次读回校验。
        let data = try makeEncoder().encode(marker)
        try data.write(to: url, options: [.atomic])
    }

    func deletionTombstoneProjectIDs() -> Set<NovelProjectID> {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: tombstoneDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(urls.compactMap { url in
            guard url.pathExtension == "json",
                  let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return NovelProjectID(uuid)
        })
    }

    private func finishDeletionTombstonesBestEffort() {
        for projectID in deletionTombstoneProjectIDs() {
            finishDeletionBestEffort(projectID: projectID)
        }
    }

    private func finishDeletionBestEffort(projectID: NovelProjectID) {
        do {
            try cleanupProjectFiles(projectID: projectID, includingPrimary: true)
        } catch {
            // The durable tombstone keeps every read path fail closed until cleanup retries.
        }
    }

    func finishReplacementBestEffort(projectID: NovelProjectID) {
        guard isReplacementMarked(projectID) else { return }
        do {
            try cleanupProjectFiles(projectID: projectID, includingPrimary: false)
            try fileManager.removeItem(at: replacementMarkerURL(for: projectID))
        } catch {
            // A valid new primary remains readable while the marker blocks previous fallback.
        }
    }

    private func cleanupProjectFiles(
        projectID: NovelProjectID,
        includingPrimary: Bool
    ) throws {
        var urls = [previousURL(for: projectID)]
        if includingPrimary {
            urls.append(primaryURL(for: projectID))
            urls.append(packageURL(for: projectID))
            urls.append(replacementMarkerURL(for: projectID))
            sectionCaches[projectID] = nil
            pointerFingerprints[projectID] = nil
            workspaceNativeByProject[projectID] = nil
        } else {
            // Replacement cleanup keeps the new primary package; drop legacy previous monofile only.
        }
        let recoveryURLs = try fileManager.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("\(projectID.description)-")
        }
        urls.append(contentsOf: recoveryURLs)
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

}
