import Foundation
import os

extension NovelFileProjectRepository {
    struct IndexV1: Codable, Sendable {
        let schemaVersion: Int
        let projects: [NovelProjectSummary]
    }

    /// Sidecar written next to `index.json` so inventory can skip full document
    /// decode only when every on-disk project file still matches the last scan.
    struct IndexManifestV1: Codable, Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable, Hashable {
            let projectID: NovelProjectID
            let primaryByteCount: Int?
            let primaryModifiedAt: TimeInterval?
            let previousByteCount: Int?
            let previousModifiedAt: TimeInterval?
        }

        let schemaVersion: Int
        let entries: [Entry]
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private enum FileReadFailure: Error {
        case missing
    }

    func writeShardedProject(_ document: NovelProjectDocumentV1) throws {
        try failIfRequested(.afterTempWrite)
        let projectID = document.project.id
        let workspaceNative = isWorkspaceNative(projectID)
        let cache = sectionCaches[projectID]
        // Receipt slimming at quiet rest — see
        // NovelWorkspaceProjectStore.persistableAtRest.
        let persistable = workspaceNative
            ? NovelWorkspaceProjectStore.persistableAtRest(document)
            : document
        let nextCache = try NovelProjectShardedStorage.writePackage(
            document: persistable,
            packageDirectory: engineStorageDirectory(for: projectID),
            encoder: makeEncoder(),
            fileManager: fileManager,
            cache: cache
        )
        try failIfRequested(.afterTempValidation)
        sectionCaches[projectID] = nextCache
        let package = packageURL(for: projectID)
        if workspaceNative {
            // Workspace-native: the tree IS the destination of the write —
            // objects retained, tree swapped, commit sealed. Engine sections
            // are host state beside it, never the book.
            if NovelProjectShardedStorage.checkoutSidecarNeedsRefresh(previous: cache, next: nextCache)
                || pointerFingerprints[projectID] != pointerFingerprint(document) {
                do {
                    try NovelWorkspaceProjectStore.publishValidatedDocument(
                        document: document,
                        projectDirectory: package,
                        fileManager: fileManager
                    )
                    pointerFingerprints[projectID] = pointerFingerprint(document)
                    NovelProjectShardedStorage.clearCheckoutWriteFailure(
                        in: package,
                        fileManager: fileManager
                    )
                } catch {
                    Self.logger.error(
                        "Workspace publish failed for \(projectID.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    NovelProjectShardedStorage.recordCheckoutWriteFailure(
                        error.localizedDescription,
                        in: package,
                        fileManager: fileManager
                    )
                    throw error
                }
            } else if NovelProjectShardedStorage.checkoutDraftsNeedRefresh(
                previous: cache,
                next: nextCache
            ) {
                do {
                    try NovelWorkspaceAuthority.publishDrafts(
                        document,
                        to: NovelWorkspaceAuthority.checkoutDirectory(in: package),
                        fileManager: fileManager
                    )
                } catch {
                    Self.logger.error(
                        "Workspace drafts publish failed for \(projectID.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    NovelProjectShardedStorage.recordCheckoutWriteFailure(
                        error.localizedDescription,
                        in: package,
                        fileManager: fileManager
                    )
                    throw error
                }
            }
            return
        }
        // Drop legacy monofiles after a successful sharded write so inventory and
        // loads prefer the incremental package.
        let mono = primaryURL(for: projectID)
        if fileManager.fileExists(atPath: mono.path) {
            try? fileManager.removeItem(at: mono)
        }
        let monoPrevious = previousURL(for: projectID)
        if fileManager.fileExists(atPath: monoPrevious.path) {
            try? fileManager.removeItem(at: monoPrevious)
        }
        let checkout = NovelWorkspaceAuthority.checkoutDirectory(in: package)
        if NovelProjectShardedStorage.checkoutSidecarNeedsRefresh(
            previous: cache,
            next: nextCache
        ) {
            do {
                try NovelWorkspaceAuthority.publish(
                    document,
                    to: checkout,
                    fileManager: fileManager
                )
                NovelProjectShardedStorage.clearCheckoutWriteFailure(
                    in: package,
                    fileManager: fileManager
                )
            } catch {
                Self.logger.error(
                    "Novel worktree publish failed for \(document.project.id.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                NovelProjectShardedStorage.recordCheckoutWriteFailure(
                    error.localizedDescription,
                    in: package,
                    fileManager: fileManager
                )
                throw error
            }
        } else if NovelProjectShardedStorage.checkoutDraftsNeedRefresh(
            previous: cache,
            next: nextCache
        ) {
            do {
                try NovelWorkspaceAuthority.publishDrafts(
                    document,
                    to: checkout,
                    fileManager: fileManager
                )
            } catch {
                Self.logger.error(
                    "Novel drafts publish failed for \(document.project.id.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                NovelProjectShardedStorage.recordCheckoutWriteFailure(
                    error.localizedDescription,
                    in: package,
                    fileManager: fileManager
                )
                throw error
            }
        }
    }

    func canCommitValidatedTransitionFromCache(
        _ transition: NovelValidatedProjectTransition
    ) -> Bool {
        let current = transition.current
        let projectID = current.project.id
        guard isWorkspaceNative(projectID),
              let cache = sectionCaches[projectID],
              NovelProjectShardedStorage.SectionKey.allCases.allSatisfy({ key in
                  cache[key.rawValue]?.fingerprint ==
                      NovelProjectShardedStorage.fingerprint(for: key, document: current)
              }),
              engineLayoutMatchesCache(
                  projectID: projectID,
                  revision: current.project.revision,
                  cache: cache
              ) else {
            return false
        }
        return true
    }

    func engineLayoutMatchesCache(
        projectID: NovelProjectID,
        revision: Int64,
        cache: NovelProjectShardedStorage.SectionCache
    ) -> Bool {
        let engine = engineStorageDirectory(for: projectID)
        guard let layoutData = try? Data(
            contentsOf: NovelProjectShardedStorage.layoutURL(in: engine),
            options: [.mappedIfSafe]
        ),
        let layout = try? makeDecoder().decode(
            NovelProjectShardedStorage.LayoutV2.self,
            from: layoutData
        ),
        layout.schemaVersion == NovelProjectShardedStorage.layoutSchemaVersion,
        layout.documentSchemaVersion == NovelProjectDocumentV1.currentSchemaVersion,
        layout.projectID == projectID,
        layout.revision == revision else {
            return false
        }

        return NovelProjectShardedStorage.SectionKey.allCases.allSatisfy { key in
            guard let ref = layout.sections[key.rawValue],
                  let entry = cache[key.rawValue] else {
                return false
            }
            return ref.digest == entry.digest && ref.byteCount == entry.data.count
        }
    }

    func readInstalledProjectDocument(projectID: NovelProjectID) throws -> NovelProjectDocumentV1 {
        if isWorkspaceNative(projectID) {
            let engine = engineStorageDirectory(for: projectID)
            let loaded = try NovelProjectShardedStorage.loadDocument(
                packageDirectory: engine,
                projectID: projectID,
                decoder: makeDecoder(),
                fileManager: fileManager
            )
            sectionCaches[projectID] = loaded.cache
            return try finalizeLoadedDocument(loaded.document, projectID: projectID)
        }
        let package = packageURL(for: projectID)
        let hasCurrentLayout = fileManager.fileExists(
            atPath: NovelProjectShardedStorage.layoutURL(in: package).path
        )
        let hasPreviousLayout = fileManager.fileExists(
            atPath: NovelProjectShardedStorage.previousLayoutURL(in: package).path
        )
        if hasCurrentLayout {
            do {
                let loaded = try NovelProjectShardedStorage.loadDocument(
                    packageDirectory: package,
                    projectID: projectID,
                    decoder: makeDecoder(),
                    fileManager: fileManager
                )
                sectionCaches[projectID] = loaded.cache
                return try finalizeLoadedDocument(loaded.document, projectID: projectID)
            } catch {
                // Migration left a monofile when package delete failed, or layout is
                // unreadable: prefer a still-valid monofile over falling to previous.
                let mono = primaryURL(for: projectID)
                if fileManager.fileExists(atPath: mono.path),
                   let monofile = try? readProjectDocument(at: mono, projectID: projectID) {
                    return monofile
                }
                throw error
            }
        }
        if hasPreviousLayout {
            // Previous-only package: surface as load via previous for degraded path.
            throw NovelError.corruptedProject(
                projectID: projectID,
                details: "Current package layout is missing."
            )
        }
        let mono = primaryURL(for: projectID)
        if fileManager.fileExists(atPath: mono.path) {
            // Monofile loads run the same finalize as package loads: the
            // worktree print/heal and the workspace cutover apply to them too
            // (they are the oldest rescue format, and their checkout tree may
            // exist from the worktree era).
            let monofile = try readProjectDocument(at: mono, projectID: projectID)
            return try finalizeLoadedDocument(monofile, projectID: projectID)
        }
        let checkout = package.appendingPathComponent("checkout", isDirectory: true)
        if fileManager.fileExists(atPath: checkout.appendingPathComponent("manifest.yaml").path) {
            let files = try NovelWorkspaceFolderDocument.files(
                fromDirectory: checkout,
                fileManager: fileManager
            )
            let imported = try NovelWorkspaceImporter.makeDocument(from: files)
            let remapped = try NovelProjectIdentityRemapper.remap(imported, to: projectID)
            return try finalizeLoadedDocument(remapped, projectID: projectID)
        }
        throw NovelError.projectNotFound(projectID)
    }

    func readPreviousProjectDocument(projectID: NovelProjectID) throws -> NovelProjectDocumentV1 {
        if isWorkspaceNative(projectID) {
            // Workspace safety net: the engine keeps rotating its own previous
            // layout inside `.amber/engine`, so degraded loads and explicit
            // restores keep working after the legacy package is sealed.
            let engine = engineStorageDirectory(for: projectID)
            if fileManager.fileExists(
                atPath: NovelProjectShardedStorage.previousLayoutURL(in: engine).path
            ) {
                let loaded = try NovelProjectShardedStorage.loadDocument(
                    packageDirectory: engine,
                    projectID: projectID,
                    decoder: makeDecoder(),
                    fileManager: fileManager,
                    layoutFileName: NovelProjectShardedStorage.previousLayoutFileName
                )
                return try finalizeLoadedDocument(
                    loaded.document,
                    projectID: projectID,
                    reconcileWorkspace: false
                )
            }
            throw NovelError.corruptedProject(
                projectID: projectID,
                details: "Workspace engine has no previous layout to fall back to."
            )
        }
        let package = packageURL(for: projectID)
        if fileManager.fileExists(
            atPath: NovelProjectShardedStorage.previousLayoutURL(in: package).path
        ) {
            let loaded = try NovelProjectShardedStorage.loadDocument(
                packageDirectory: package,
                projectID: projectID,
                decoder: makeDecoder(),
                fileManager: fileManager,
                layoutFileName: NovelProjectShardedStorage.previousLayoutFileName
            )
            return try finalizeLoadedDocument(loaded.document, projectID: projectID)
        }
        let monoPrevious = previousURL(for: projectID)
        return try readProjectDocument(at: monoPrevious, projectID: projectID)
    }

    private func finalizeLoadedDocument(
        _ document: NovelProjectDocumentV1,
        projectID: NovelProjectID,
        reconcileWorkspace: Bool = true
    ) throws -> NovelProjectDocumentV1 {
        let generationNormalized = NovelGenerationReducer
            .normalizingLegacyInterruptedProseCandidates(document)
        var normalized = NovelBranchSemantics.normalizingDecodedSyncStatus(generationNormalized)
        guard normalized.project.id == projectID else {
            throw NovelError.corruptedProject(
                projectID: projectID,
                details: "Document project ID does not match its filename."
            )
        }
        if isWorkspaceNative(projectID) {
            // Disk may still carry residues from an older prune that dropped
            // runs/receipts but left factAttempts. Load equals the quiet-rest
            // projection the next commit would persist.
            let persistable = NovelWorkspaceProjectStore.persistableAtRest(normalized)
            // Count-only: a full document == walks 12MB snapshots on this book.
            let droppedResidues =
                persistable.factAttempts.count != normalized.factAttempts.count ||
                persistable.activeRuns.count != normalized.activeRuns.count ||
                persistable.injectionReceipts.count != normalized.injectionReceipts.count ||
                persistable.generationReceipts.count != normalized.generationReceipts.count ||
                persistable.appliedOperations.count != normalized.appliedOperations.count
            normalized = persistable
            try NovelDocumentValidator.validate(normalized)
            if droppedResidues, reconcileWorkspace {
                // Keep the encode cache. Nilling it makes the next user commit
                // treat checkout as never published and rewrite all 37 chapters.
                if let cache = try? NovelWorkspaceProjectStore.writeEngineSections(
                    document: normalized,
                    projectDirectory: packageURL(for: projectID),
                    fileManager: fileManager,
                    cache: sectionCaches[projectID]
                ) {
                    sectionCaches[projectID] = cache
                }
            }
        } else {
            try NovelDocumentValidator.validate(normalized)
        }
        if isWorkspaceNative(projectID) {
            // The markdown tree is the runtime book. Reconcile decides which
            // side is ahead (a failed publish reprints from the engine; a
            // genuine hand edit on disk wins), then the ledger catches up.
            // Degraded (previous) loads skip this: a recovery read must not
            // mutate the tree.
            let project = packageURL(for: projectID)
            if reconcileWorkspace {
                // A prior fingerprint can no longer be trusted until this
                // load confirms that the checkout still represents the book.
                pointerFingerprints[projectID] = nil
                let reconciled = try NovelWorkspaceProjectStore.reconcileBookTree(
                    document: normalized,
                    projectDirectory: project,
                    fileManager: fileManager
                )
                let checkout = NovelWorkspaceAuthority.checkoutDirectory(in: project)
                if NovelWorkspaceProjectStore.isWorkspaceNative(
                    projectDirectory: project,
                    fileManager: fileManager
                ), NovelWorkspaceAuthority.worktreeCoversWorkingManuscript(
                    reconciled,
                    checkoutDirectory: checkout,
                    fileManager: fileManager
                ) {
                    // An unmarked or incomplete checkout keeps this nil for
                    // the next book write.
                    pointerFingerprints[projectID] = pointerFingerprint(reconciled)
                }
                NovelWorkspaceProjectStore.healLedgerIfNeeded(
                    document: reconciled,
                    projectDirectory: project,
                    fileManager: fileManager
                )
                // Complete a seal interrupted by a crash between marker and moves.
                if NovelWorkspaceProjectStore.hasUnsealedLegacyArtifacts(
                    projectDirectory: project,
                    fileManager: fileManager
                ) {
                    try? NovelWorkspaceProjectStore.sealLegacyPackage(
                        projectDirectory: project,
                        fileManager: fileManager
                    )
                    workspaceNativeByProject[projectID] = nil
                }
                return reconciled
            }
            return normalized
        }
        // Legacy chain cutover (contract D-E): a legacy project that already
        // has its book printed on disk migrates to workspace-native on first
        // open. Failure fails open back to the legacy chain and retries next
        // open; rollback keeps `legacy-package/` beside the workspace.
        if automaticWorkspaceMigration, shouldMigrateLegacyProject(projectID) {
            let project = packageURL(for: projectID)
            workspaceNativeByProject[projectID] = nil
            do {
                try NovelWorkspaceProjectStore.migrateLegacyProject(
                    document: normalized,
                    projectDirectory: project,
                    fileManager: fileManager
                )
                sectionCaches[projectID] = nil
                workspaceNativeByProject[projectID] = true
                pointerFingerprints[projectID] = pointerFingerprint(normalized)
                Self.logger.error(
                    "Legacy novel project migrated to workspace-native: \(projectID.description, privacy: .public)"
                )
            } catch {
                Self.logger.error(
                    "Legacy→workspace migration failed, staying on legacy chain: \(String(describing: error), privacy: .public)"
                )
                try publishWorktreeIfNeeded(normalized, projectID: projectID)
                // The failure may land AFTER the marker flipped (e.g. a seal
                // error): return whichever view matches the chain that now
                // owns the disk.
                if NovelWorkspaceProjectStore.isWorkspaceNative(
                    projectDirectory: packageURL(for: projectID),
                    fileManager: fileManager
                ) {
                    sectionCaches[projectID] = nil
                    workspaceNativeByProject[projectID] = true
                    pointerFingerprints[projectID] = pointerFingerprint(normalized)
                    return NovelWorkspaceProjectStore.persistableAtRest(normalized)
                }
                workspaceNativeByProject[projectID] = false
                // The legacy chain persists the FULL document — return it.
                return normalized
            }
            // The migration persisted the pruned projection — return it.
            return NovelWorkspaceProjectStore.persistableAtRest(normalized)
        }
        try publishWorktreeIfNeeded(normalized, projectID: projectID)
        return normalized
    }

    /// Book-affecting branch state only: branch name (its slug IS a tree
    /// path), head checkpoint + working chapter selections per active branch.
    /// activeRunID / updatedAt / syncStatus churn deliberately excluded.
    func pointerFingerprint(_ document: NovelProjectDocumentV1) -> String {
        document.branches
            .filter { $0.lifecycle == .active }
            .map {
                "\($0.name):\($0.id):\($0.headCheckpointID):\($0.workingChapterSelections.map { "\($0.chapterID)=\($0.versionID)" }.joined(separator: ","))"
            }
            .joined(separator: ";")
    }

    /// Every legacy project is migration-ready — the migrator prints the
    /// book tree itself, so no pre-existing checkout is required. Monofile
    /// rescue books included.
    private func shouldMigrateLegacyProject(_ projectID: NovelProjectID) -> Bool {
        true
    }

    /// First open after this cutover (and any later drift): print the ledger's
    /// working manuscript onto `checkout/` so ghostwrite / discussion / export
    /// all see the same markdown tree. Sessions stay in the JSON ledger.
    private func publishWorktreeIfNeeded(
        _ document: NovelProjectDocumentV1,
        projectID: NovelProjectID
    ) throws {
        let checkout = NovelWorkspaceAuthority.checkoutDirectory(in: packageURL(for: projectID))
        let covers = NovelWorkspaceAuthority.worktreeCoversWorkingManuscript(
            document,
            checkoutDirectory: checkout,
            fileManager: fileManager
        )
        let marked = NovelWorkspaceAuthority.isWorktreeBook(
            at: checkout,
            fileManager: fileManager
        )
        guard !covers || !marked else { return }
        do {
            try NovelWorkspaceAuthority.publish(
                document,
                to: checkout,
                fileManager: fileManager
            )
            NovelProjectShardedStorage.clearCheckoutWriteFailure(
                in: packageURL(for: projectID),
                fileManager: fileManager
            )
        } catch {
            Self.logger.error(
                "Novel worktree heal failed for \(projectID.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            NovelProjectShardedStorage.recordCheckoutWriteFailure(
                error.localizedDescription,
                in: packageURL(for: projectID),
                fileManager: fileManager
            )
        }
    }

    private func readProjectDocument(
        at url: URL,
        projectID: NovelProjectID
    ) throws -> NovelProjectDocumentV1 {
        let data = try readData(at: url, projectID: projectID)
        return try decodeProject(data, projectID: projectID)
    }

    private func decodeProject(
        _ data: Data,
        projectID: NovelProjectID,
        normalizesLegacySyncStatus: Bool = true
    ) throws -> NovelProjectDocumentV1 {
        do {
            let header = try makeDecoder().decode(SchemaHeader.self, from: data)
            guard header.schemaVersion == NovelProjectDocumentV1.currentSchemaVersion else {
                throw NovelError.unsupportedSchema(header.schemaVersion)
            }
            let decoded = try makeDecoder().decode(NovelProjectDocumentV1.self, from: data)
            let generationNormalized = NovelGenerationReducer
                .normalizingLegacyInterruptedProseCandidates(decoded)
            let document = normalizesLegacySyncStatus
                ? NovelBranchSemantics.normalizingDecodedSyncStatus(generationNormalized)
                : generationNormalized
            guard document.project.id == projectID else {
                throw NovelError.corruptedProject(
                    projectID: projectID,
                    details: "Document project ID does not match its filename."
                )
            }
            try NovelDocumentValidator.validate(document)
            return document
        } catch let error as NovelError {
            throw error
        } catch {
            throw NovelError.corruptedProject(
                projectID: projectID,
                details: "Decode failed: \(error)"
            )
        }
    }

    func readData(at url: URL, projectID: NovelProjectID?) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileReadFailure.missing
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw NovelError.storageUnavailable("Storage path is not a regular file: \(url.path)")
            }
            if let size = values.fileSize, size > Self.maximumProjectBytes {
                if let projectID {
                    throw NovelError.corruptedProject(
                        projectID: projectID,
                        details: "Project exceeds the 100 MB storage limit."
                    )
                }
                throw NovelError.invalidRecovery("Recovery payload exceeds the 100 MB limit.")
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as NovelError {
            throw error
        } catch {
            throw NovelError.storageUnavailable("Could not read \(url.lastPathComponent): \(error)")
        }
    }

    func readIndex() throws -> IndexV1 {
        let data = try readData(at: indexURL, projectID: nil)
        let index = try makeDecoder().decode(IndexV1.self, from: data)
        guard index.schemaVersion == 1 else {
            throw NovelError.repositoryFailure("Unsupported novel index schema.")
        }
        guard Set(index.projects.map(\.id)).count == index.projects.count else {
            throw NovelError.repositoryFailure("Novel index repeats a project ID.")
        }
        return index
    }

    /// Returns cached inventory summaries when the index + file signatures still match.
    func loadCachedProjectSummariesIfFresh() throws -> [NovelProjectSummary]? {
        guard fileManager.fileExists(atPath: indexURL.path),
              fileManager.fileExists(atPath: indexManifestURL.path) else { return nil }

        let diskInventory = try diskProjectInventory()
        let index = try readIndex()
        let manifest = try readIndexManifest()
        let deleted = deletionTombstoneProjectIDs()
        let cachedProjects = index.projects.filter { !deleted.contains($0.id) }
        let cachedIDs = Set(cachedProjects.map(\.id))
        guard cachedIDs == diskInventory.projectIDs else { return nil }

        let expectedEntries = Set(manifest.entries)
        let actualEntries = Set(diskInventory.entries)
        guard expectedEntries == actualEntries else { return nil }
        // A degraded row is last scan's failure. Signatures can stay
        // identical after a load-time heal, so never treat those as fresh.
        if cachedProjects.contains(where: \.isDegraded) { return nil }
        return cachedProjects.sorted(by: NovelProjectSummary.listOrder)
    }

    private struct DiskProjectInventory {
        let projectIDs: Set<NovelProjectID>
        let entries: [IndexManifestV1.Entry]
    }

    private func diskProjectInventory() throws -> DiskProjectInventory {
        let urls = try fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        )
        let deletedProjectIDs = deletionTombstoneProjectIDs()
        var projectIDs: Set<NovelProjectID> = []
        for url in urls {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                guard let uuid = UUID(uuidString: name),
                      NovelProjectShardedStorage.isPackage(at: url, fileManager: fileManager)
                          || NovelWorkspaceProjectStore.isWorkspaceNative(
                              projectDirectory: url,
                              fileManager: fileManager
                          ) else {
                    continue
                }
                let projectID = NovelProjectID(uuid)
                guard !deletedProjectIDs.contains(projectID) else { continue }
                projectIDs.insert(projectID)
                continue
            }
            let rawID: String
            if name.hasSuffix(".previous.json") {
                rawID = String(name.dropLast(".previous.json".count))
            } else {
                guard name.hasSuffix(".json"), !name.contains(".corrupt-") else {
                    continue
                }
                rawID = String(name.dropLast(".json".count))
            }
            guard let uuid = UUID(uuidString: rawID) else { continue }
            let projectID = NovelProjectID(uuid)
            guard !deletedProjectIDs.contains(projectID) else { continue }
            projectIDs.insert(projectID)
        }

        let entries = projectIDs.sorted(by: { $0.description < $1.description }).map { projectID in
            fileSignatureEntry(for: projectID)
        }
        return DiskProjectInventory(projectIDs: projectIDs, entries: entries)
    }

    private func fileSignatureEntry(for projectID: NovelProjectID) -> IndexManifestV1.Entry {
        let package = packageURL(for: projectID)
        // Workspace check first: a half-sealed migration may briefly leave the
        // legacy layout.json beside a live workspace — the workspace files are
        // the ones that keep changing.
        if isWorkspaceNative(projectID) {
            // Engine layout changes on every engine write; the external ledger
            // changes on every commit — together they detect out-of-band edits.
            let primary = fileSignature(
                at: NovelProjectShardedStorage.layoutURL(
                    in: engineStorageDirectory(for: projectID)
                )
            )
            let previous = fileSignature(
                at: package.appendingPathComponent(NovelWorkspaceLedger.directoryName, isDirectory: true)
                    .appendingPathComponent(NovelWorkspaceLedger.storeFileName)
            )
            return IndexManifestV1.Entry(
                projectID: projectID,
                primaryByteCount: primary.byteCount,
                primaryModifiedAt: primary.modifiedAt,
                previousByteCount: previous.byteCount,
                previousModifiedAt: previous.modifiedAt
            )
        }
        if NovelProjectShardedStorage.isPackage(at: package, fileManager: fileManager) {
            let primary = fileSignature(
                at: NovelProjectShardedStorage.layoutURL(in: package)
            )
            let previous = fileSignature(
                at: NovelProjectShardedStorage.previousLayoutURL(in: package)
            )
            return IndexManifestV1.Entry(
                projectID: projectID,
                primaryByteCount: primary.byteCount,
                primaryModifiedAt: primary.modifiedAt,
                previousByteCount: previous.byteCount,
                previousModifiedAt: previous.modifiedAt
            )
        }
        let primary = fileSignature(at: primaryURL(for: projectID))
        let previous = fileSignature(at: previousURL(for: projectID))
        return IndexManifestV1.Entry(
            projectID: projectID,
            primaryByteCount: primary.byteCount,
            primaryModifiedAt: primary.modifiedAt,
            previousByteCount: previous.byteCount,
            previousModifiedAt: previous.modifiedAt
        )
    }

    private func fileSignature(at url: URL) -> (byteCount: Int?, modifiedAt: TimeInterval?) {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                  .fileSizeKey,
                  .contentModificationDateKey,
                  .isRegularFileKey,
              ]),
              values.isRegularFile == true else {
            return (nil, nil)
        }
        return (
            values.fileSize,
            values.contentModificationDate?.timeIntervalSince1970
        )
    }

    func scanProjectSummaries() throws -> [NovelProjectSummary] {
        let inventory = try diskProjectInventory()
        var summaries: [NovelProjectSummary] = []
        for projectID in inventory.projectIDs.sorted(by: { $0.description < $1.description }) {
            do {
                let loaded = try loadProjectSynchronously(id: projectID)
                summaries.append(NovelProjectSummary(
                    document: loaded.document,
                    isDegraded: loaded.access != .readWrite
                ))
            } catch {
                summaries.append(NovelProjectSummary(
                    unavailableProjectID: projectID,
                    error: error
                ))
            }
        }
        return summaries.sorted(by: NovelProjectSummary.listOrder)
    }

    private func loadProjectSynchronously(id: NovelProjectID) throws -> NovelLoadedProject {
        let hasPackage = NovelProjectShardedStorage.isPackage(
            at: packageURL(for: id),
            fileManager: fileManager
        )
        let hasMonofile = fileManager.fileExists(atPath: primaryURL(for: id).path)
        if isReplacementMarked(id), !hasPackage, !hasMonofile {
            throw NovelError.storageIndeterminate(id)
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

    func writeIndexBestEffort(
        _ summaries: [NovelProjectSummary],
        manifestEntries: [IndexManifestV1.Entry]? = nil
    ) {
        do {
            try failIfRequested(.beforeIndexWrite)
            let sorted = summaries.sorted(by: NovelProjectSummary.listOrder)
            let index = IndexV1(schemaVersion: 1, projects: sorted)
            let manifest = IndexManifestV1(
                schemaVersion: 1,
                entries: manifestEntries ?? sorted.map { fileSignatureEntry(for: $0.id) }
            )
            try makeEncoder().encode(index).write(to: indexURL, options: [.atomic])
            try makeEncoder().encode(manifest).write(to: indexManifestURL, options: [.atomic])
        } catch {
            try? fileManager.removeItem(at: indexURL)
            try? fileManager.removeItem(at: indexManifestURL)
        }
    }

    private func readIndexManifest() throws -> IndexManifestV1 {
        let data = try readData(at: indexManifestURL, projectID: nil)
        let manifest = try makeDecoder().decode(IndexManifestV1.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw NovelError.repositoryFailure("Unsupported novel index manifest schema.")
        }
        return manifest
    }

    func refreshIndexBestEffort() {
        do {
            let summaries = try scanProjectSummaries()
            writeIndexBestEffort(summaries)
        } catch {
            try? fileManager.removeItem(at: indexURL)
            try? fileManager.removeItem(at: indexManifestURL)
        }
    }

    /// Patch one project into the lightweight index without reloading every package.
    /// Falls back to a full scan only when no usable index exists yet.
    func upsertIndexBestEffort(document: NovelProjectDocumentV1) {
        do {
            let summary = NovelProjectSummary(document: document, isDegraded: false)
            let deleted = deletionTombstoneProjectIDs()
            var projects: [NovelProjectSummary]
            if let index = try? readIndex() {
                projects = index.projects.filter { !deleted.contains($0.id) && $0.id != summary.id }
                projects.append(summary)
                if let manifest = try? readIndexManifest(),
                   Set(manifest.entries.map(\.projectID)).count == manifest.entries.count,
                   Set(manifest.entries.map(\.projectID)) == Set(index.projects.map(\.id)) {
                    let entriesByID = Dictionary(
                        uniqueKeysWithValues: manifest.entries.map { ($0.projectID, $0) }
                    )
                    let sortedProjects = projects.sorted(by: NovelProjectSummary.listOrder)
                    let patchedEntries = sortedProjects.map { project in
                        if project.id == summary.id {
                            return fileSignatureEntry(for: project.id)
                        }
                        return entriesByID[project.id] ?? fileSignatureEntry(for: project.id)
                    }
                    writeIndexBestEffort(sortedProjects, manifestEntries: patchedEntries)
                } else {
                    writeIndexBestEffort(projects)
                }
            } else {
                projects = try scanProjectSummaries()
                if let idx = projects.firstIndex(where: { $0.id == summary.id }) {
                    projects[idx] = summary
                } else if !deleted.contains(summary.id) {
                    projects.append(summary)
                }
                writeIndexBestEffort(projects)
            }
        } catch {
            try? fileManager.removeItem(at: indexURL)
            try? fileManager.removeItem(at: indexManifestURL)
        }
    }

    func invalidateIndex() throws {
        if fileManager.fileExists(atPath: indexManifestURL.path) {
            try? fileManager.removeItem(at: indexManifestURL)
        }
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            try fileManager.removeItem(at: indexURL)
        } catch {
            throw NovelError.repositoryFailure("Could not invalidate the novel index: \(error)")
        }
    }

    func failIfRequested(_ stage: NovelRepositoryFailureStage) throws {
        if failingStages.contains(stage) {
            throw NovelError.repositoryFailure("Injected repository failure at \(stage.rawValue).")
        }
    }

    func loadPreviousProject(
        id: NovelProjectID,
        primaryFailure: String
    ) throws -> NovelLoadedProject {
        do {
            let previous = try readPreviousProjectDocument(projectID: id)
            guard previous.project.id == id else {
                throw NovelError.corruptedProject(
                    projectID: id,
                    details: "Previous document belongs to another project."
                )
            }
            return NovelLoadedProject(
                document: previous,
                access: .degradedPrevious(primaryFailure: primaryFailure)
            )
        } catch let error as NovelError {
            switch error {
            case .unsupportedSchema, .storageUnavailable:
                throw error
            default:
                throw NovelError.corruptedProject(
                    projectID: id,
                    details: "Primary: \(primaryFailure); previous: \(error)"
                )
            }
        } catch {
            throw NovelError.corruptedProject(
                projectID: id,
                details: "Primary: \(primaryFailure); previous: \(error)"
            )
        }
    }

    func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
