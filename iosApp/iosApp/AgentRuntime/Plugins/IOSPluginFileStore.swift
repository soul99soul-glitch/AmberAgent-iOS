import CryptoKit
import Foundation

struct IOSPluginPackage: Equatable {
    let manifest: IOSPluginManifest
    let tools: [IOSPluginResolvedTool]
    let primitiveTools: Set<String>
    let permissionEnvelope: IOSToolEffectClass
    let hash: String
    let fileHashes: [String: String]
    /// Canonical bytes. JSON files are re-encoded before hashing and storage.
    let files: [String: Data]
}


struct IOSInstalledPlugin: Equatable {
    let package: IOSPluginPackage
    /// Durable lifecycle marker, independent of runtime quarantine.
    let isConfiguredEnabled: Bool
    let isEnabled: Bool
    let trust: IOSPluginTrustRecord
    let health: IOSPluginHealthSnapshot
}

struct IOSPluginPackagePreparation: Equatable {
    let base: IOSPluginPackage?
    let candidate: IOSPluginPackage
    let candidateTrust: IOSPluginTrustRecord
    let permissionExpanded: Bool
}

struct IOSPluginApplyReceipt: Equatable {
    let id: String
    let hash: String
    let changed: Bool
    let enabled: Bool
    let permissionExpanded: Bool
    let trust: IOSPluginTrustRecord
}

struct IOSPluginLifecycleReceipt: Equatable {
    let id: String
    let hash: String
    let changed: Bool
}

struct IOSPluginFileStore {
    private static let mutationLock = NSLock()

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let catalog: IOSRecipeCatalogLookup

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        catalog: @escaping IOSRecipeCatalogLookup = IOSDynamicToolRegistry.primitiveCatalogEntry
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.catalog = catalog
    }

    var pluginsDirectory: URL {
        baseDirectory.appendingPathComponent("plugins", isDirectory: true)
    }

    private var disabledDirectory: URL {
        pluginsDirectory.appendingPathComponent(".disabled", isDirectory: true)
    }

    private var previousDirectory: URL {
        pluginsDirectory.appendingPathComponent(".previous", isDirectory: true)
    }

    private var metadataDirectory: URL {
        pluginsDirectory.appendingPathComponent(".metadata", isDirectory: true)
    }

    func preparePlugin(
        files: [String: Data],
        trust: IOSPluginTrustRecord = .localUnsigned
    ) throws -> IOSPluginPackagePreparation {
        let candidate = try makePackage(files: files)
        guard IOSPluginArchiveCodec.isTrustValid(trust, packageHash: candidate.hash) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        let base = try installedPackage(id: candidate.manifest.id)
        let storedBaseTrust = base.flatMap { _ in storedTrustRecord(id: candidate.manifest.id) }
        let riskyTrustChange = base.map { _ in
            storedBaseTrust == nil
                || Self.trustChangeRequiresDisable(from: storedBaseTrust ?? .localUnsigned, to: trust)
        } ?? false
        return IOSPluginPackagePreparation(
            base: base,
            candidate: candidate,
            candidateTrust: trust,
            permissionExpanded: base.map { Self.permissionsExpanded(from: $0, to: candidate) || riskyTrustChange } ?? true
        )
    }

    func prepareArchive(data: Data) throws -> (preparation: IOSPluginPackagePreparation, files: [String: Data]) {
        let decoded = try IOSPluginArchiveCodec.decode(data) { files in
            try makePackage(files: files).hash
        }
        return (try preparePlugin(files: decoded.files, trust: decoded.trust), decoded.files)
    }

    func exportArchive(id: String) throws -> Data {
        let package = try readLivePlugin(id: id)
        guard let trust = storedTrustRecord(id: id) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        guard IOSPluginArchiveCodec.isTrustValid(trust, packageHash: package.hash) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        return try IOSPluginArchiveCodec.encode(
            files: package.files,
            packageHash: package.hash,
            preservedTrust: trust
        )
    }

    @discardableResult
    func applyPlugin(
        files: [String: Data],
        expectedBaseHash: String?,
        expectedCandidateHash: String,
        trust: IOSPluginTrustRecord = .localUnsigned
    ) throws -> IOSPluginApplyReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        let candidate = try makePackage(files: files)
        guard candidate.hash == expectedCandidateHash else {
            throw IOSPluginFileStoreError.candidateChanged
        }
        guard IOSPluginArchiveCodec.isTrustValid(trust, packageHash: candidate.hash) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        let base = try installedPackage(id: candidate.manifest.id)
        guard base?.hash == expectedBaseHash else {
            throw IOSPluginFileStoreError.baseChanged
        }
        let storedOldTrust = base.flatMap { _ in storedTrustRecord(id: candidate.manifest.id) }
        let oldTrust = storedOldTrust ?? .localUnsigned
        let riskyTrustChange = base.map { _ in
            storedOldTrust == nil || Self.trustChangeRequiresDisable(from: oldTrust, to: trust)
        } ?? false
        if base?.hash == candidate.hash {
            guard oldTrust != trust || storedOldTrust == nil else {
                return IOSPluginApplyReceipt(
                    id: candidate.manifest.id,
                    hash: candidate.hash,
                    changed: false,
                    enabled: isPluginEnabled(id: candidate.manifest.id),
                    permissionExpanded: false,
                    trust: trust
                )
            }
            if riskyTrustChange {
                try setDisabledMarker(id: candidate.manifest.id, disabled: true)
            }
            try setTrustRecord(id: candidate.manifest.id, trust: trust)
            return IOSPluginApplyReceipt(
                id: candidate.manifest.id,
                hash: candidate.hash,
                changed: true,
                enabled: isPluginEnabled(id: candidate.manifest.id),
                permissionExpanded: riskyTrustChange,
                trust: trust
            )
        }

        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let staging = pluginsDirectory.appendingPathComponent(
            ".\(candidate.manifest.id)-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try writePackage(candidate, to: staging)
        var removeStaging = true
        defer { if removeStaging { try? fileManager.removeItem(at: staging) } }

        let live = pluginDirectory(id: candidate.manifest.id)
        let wasEnabled = isPluginEnabled(id: candidate.manifest.id)
        let expanded = base.map {
            Self.permissionsExpanded(from: $0, to: candidate) || riskyTrustChange
        } ?? true
        if let base {
            try replacePreviousSlot(package: base, wasEnabled: wasEnabled, trust: oldTrust)
        } else {
            try? fileManager.removeItem(at: previousSlot(id: candidate.manifest.id))
        }

        // Permission-expanding candidates must be disabled before they can
        // become visible to the lock-free registry reader. Restore the prior
        // marker if the atomic publish itself fails.
        if expanded {
            try setDisabledMarker(id: candidate.manifest.id, disabled: true)
        }
        do {
            try setTrustRecord(id: candidate.manifest.id, trust: trust)
            if fileManager.fileExists(atPath: live.path) {
                _ = try fileManager.replaceItemAt(live, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: live)
            }
        } catch {
            if expanded {
                try? setDisabledMarker(id: candidate.manifest.id, disabled: !wasEnabled)
            }
            if base != nil {
                try? setTrustRecord(id: candidate.manifest.id, trust: oldTrust)
            } else {
                try? fileManager.removeItem(at: trustURL(id: candidate.manifest.id))
            }
            throw error
        }
        removeStaging = false

        return IOSPluginApplyReceipt(
            id: candidate.manifest.id,
            hash: candidate.hash,
            changed: true,
            enabled: isPluginEnabled(id: candidate.manifest.id),
            permissionExpanded: expanded,
            trust: trust
        )
    }

    func readLivePlugin(id: String) throws -> IOSPluginPackage {
        guard IOSRecipeNames.isValidRecipeName(id) else {
            throw IOSPluginFileStoreError.invalidPluginId
        }
        return try makePackage(files: readPackageFiles(at: pluginDirectory(id: id)))
    }

    func listInstalledPlugins() -> [IOSInstalledPlugin] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: pluginsDirectory.path) else {
            return []
        }
        return names.filter(IOSRecipeNames.isValidRecipeName).sorted().compactMap { id in
            guard let package = try? readLivePlugin(id: id) else { return nil }
            let storedTrust = storedTrustRecord(id: id)
            let trust = storedTrust ?? .localUnsigned
            let trustIsValid = storedTrust != nil
                && IOSPluginArchiveCodec.isTrustValid(trust, packageHash: package.hash)
            let configuredEnabled = isPluginEnabled(id: id)
            let health = IOSPluginHealthStore(baseDirectory: baseDirectory, fileManager: fileManager)
                .snapshot(pluginId: id, packageHash: package.hash)
            return IOSInstalledPlugin(
                package: package,
                isConfiguredEnabled: configuredEnabled,
                // Never publish a signed package whose installed bytes no
                // longer match the signature retained at import time.
                isEnabled: configuredEnabled && trustIsValid && !health.isQuarantined,
                trust: trust,
                health: health
            )
        }
    }

    func isPluginEnabled(id: String) -> Bool {
        IOSRecipeNames.isValidRecipeName(id)
            && !fileManager.fileExists(atPath: disabledMarker(id: id).path)
    }

    @discardableResult
    func setPluginEnabled(id: String, enabled: Bool, expectedHash: String) throws -> IOSPluginLifecycleReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let package = try readLivePlugin(id: id)
        guard package.hash == expectedHash else { throw IOSPluginFileStoreError.baseChanged }
        if enabled {
            guard let trust = storedTrustRecord(id: id),
                  IOSPluginArchiveCodec.isTrustValid(trust, packageHash: package.hash) else {
                throw IOSPluginFileStoreError.signatureInvalid
            }
        }
        let wasEnabled = isPluginEnabled(id: id)
        guard wasEnabled != enabled else {
            return IOSPluginLifecycleReceipt(id: id, hash: package.hash, changed: false)
        }
        try setDisabledMarker(id: id, disabled: !enabled)
        return IOSPluginLifecycleReceipt(id: id, hash: package.hash, changed: true)
    }

    @discardableResult
    func deletePlugin(id: String, expectedHash: String) throws -> IOSPluginLifecycleReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let package = try readLivePlugin(id: id)
        guard package.hash == expectedHash else { throw IOSPluginFileStoreError.baseChanged }
        try fileManager.removeItem(at: pluginDirectory(id: id))
        try? fileManager.removeItem(at: disabledMarker(id: id))
        try? fileManager.removeItem(at: previousSlot(id: id))
        try? fileManager.removeItem(at: trustURL(id: id))
        IOSPluginHealthStore(baseDirectory: baseDirectory, fileManager: fileManager).remove(pluginId: id)
        return IOSPluginLifecycleReceipt(id: id, hash: package.hash, changed: true)
    }

    @discardableResult
    func restorePlugin(id: String, expectedHash: String) throws -> IOSPluginLifecycleReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let package = try readLivePlugin(id: id)
        guard package.hash == expectedHash else { throw IOSPluginFileStoreError.baseChanged }
        guard let trust = storedTrustRecord(id: id),
              IOSPluginArchiveCodec.isTrustValid(trust, packageHash: package.hash) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        let healthStore = IOSPluginHealthStore(baseDirectory: baseDirectory, fileManager: fileManager)
        let before = healthStore.snapshot(pluginId: id, packageHash: package.hash)
        _ = healthStore.restore(pluginId: id, packageHash: package.hash)
        return IOSPluginLifecycleReceipt(id: id, hash: package.hash, changed: before.isQuarantined)
    }

    func canRollbackPlugin(id: String) -> Bool {
        IOSRecipeNames.isValidRecipeName(id)
            && fileManager.fileExists(
                atPath: previousSlot(id: id)
                    .appendingPathComponent("package", isDirectory: true)
                    .path
            )
    }

    @discardableResult
    func rollbackPlugin(id: String, expectedCurrentHash: String) throws -> IOSPluginApplyReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let current = try readLivePlugin(id: id)
        guard current.hash == expectedCurrentHash else { throw IOSPluginFileStoreError.baseChanged }
        let slot = previousSlot(id: id)
        let packageDirectory = slot.appendingPathComponent("package", isDirectory: true)
        guard fileManager.fileExists(atPath: packageDirectory.path) else {
            throw IOSPluginFileStoreError.rollbackUnavailable
        }
        let previous = try makePackage(files: readPackageFiles(at: packageDirectory))
        let enabledURL = slot.appendingPathComponent("enabled")
        let restoreEnabled = (try? String(contentsOf: enabledURL, encoding: .utf8)) == "true"
        let currentEnabled = isPluginEnabled(id: id)
        let currentTrust = trustRecord(id: id)
        let storedPreviousTrust = (try? Data(contentsOf: slot.appendingPathComponent("trust.json")))
            .flatMap { try? JSONDecoder().decode(IOSPluginTrustRecord.self, from: $0) }
        let previousTrust = storedPreviousTrust ?? .localUnsigned
        let staging = pluginsDirectory.appendingPathComponent(".\(id)-rollback-\(UUID().uuidString)")
        try fileManager.copyItem(at: packageDirectory, to: staging)
        defer { try? fileManager.removeItem(at: staging) }
        // Keep rollback fail-closed across the lock-free registry read path.
        try setDisabledMarker(id: id, disabled: true)
        do {
            try setTrustRecord(id: id, trust: previousTrust)
            _ = try fileManager.replaceItemAt(pluginDirectory(id: id), withItemAt: staging)
        } catch {
            try? setDisabledMarker(id: id, disabled: !currentEnabled)
            try? setTrustRecord(id: id, trust: currentTrust)
            throw error
        }
        let restoredTrustIsValid = storedPreviousTrust != nil
            && IOSPluginArchiveCodec.isTrustValid(previousTrust, packageHash: previous.hash)
        let restoredEnabled = restoreEnabled && restoredTrustIsValid
        try setDisabledMarker(id: id, disabled: !restoredEnabled)
        try? fileManager.removeItem(at: slot)
        return IOSPluginApplyReceipt(
            id: id,
            hash: previous.hash,
            changed: true,
            enabled: restoredEnabled,
            permissionExpanded: false,
            trust: previousTrust
        )
    }

    // MARK: Validation / hashing

    private func makePackage(files rawFiles: [String: Data]) throws -> IOSPluginPackage {
        guard !rawFiles.isEmpty, rawFiles.count <= IOSPluginLimits.maxFiles else {
            throw IOSPluginFileStoreError.fileBudgetExceeded
        }
        var files: [String: Data] = [:]
        for (path, data) in rawFiles {
            guard IOSPluginValidator.isCanonicalPackagePath(path), isAllowedPackagePath(path) else {
                throw IOSPluginFileStoreError.invalidPath(path)
            }
            guard data.count <= IOSPluginLimits.maxFileBytes else {
                throw IOSPluginFileStoreError.fileBudgetExceeded
            }
            files[path] = data
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= IOSPluginLimits.maxPackageBytes,
              let manifestData = files["plugin.json"] else {
            throw IOSPluginFileStoreError.fileBudgetExceeded
        }
        let manifest: IOSPluginManifest
        do { manifest = try IOSPluginManifest.decode(manifestData) }
        catch let error as DecodingError {
            let keys: [CodingKey]
            let message: String
            switch error {
            case .keyNotFound(let key, let context):
                keys = context.codingPath + [key]
                message = "缺少必填字段。"
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                keys = context.codingPath
                message = context.debugDescription
            @unknown default:
                keys = []
                message = error.localizedDescription
            }
            let path = keys.reduce("plugin.json") { path, key in
                key.intValue.map { "\(path)[\($0)]" } ?? "\(path).\(key.stringValue)"
            }
            throw IOSPluginFileStoreError.invalidManifest("\(path)：\(message)")
        } catch {
            throw IOSPluginFileStoreError.invalidManifest(error.localizedDescription)
        }
        guard IOSRecipeNames.isValidRecipeName(manifest.id) else {
            throw IOSPluginFileStoreError.invalidPluginId
        }
        files["plugin.json"] = try manifest.canonicalJSONData()

        var recipes: [String: IOSRecipeManifest] = [:]
        for path in files.keys.sorted() where path.hasPrefix("recipes/") {
            guard let data = files[path] else { continue }
            let recipe: IOSRecipeManifest
            do { recipe = try IOSRecipeManifest.decode(data) }
            catch { throw IOSPluginFileStoreError.invalidRecipe(path) }
            recipes[path] = recipe
            files[path] = try recipe.canonicalJSONData()
        }
        var scripts: [String: String] = [:]
        for path in files.keys.sorted() where path.hasPrefix("scripts/") {
            guard let data = files[path], let source = String(data: data, encoding: .utf8) else {
                throw IOSPluginFileStoreError.invalidScript(path)
            }
            scripts[path] = source
        }
        let validation = IOSPluginValidator.validate(
            manifest: manifest,
            recipes: recipes,
            scripts: scripts,
            catalog: catalog
        )
        guard validation.isValid, let envelope = validation.permissionEnvelope else {
            throw IOSPluginFileStoreError.validationFailed(validation.issues)
        }
        let fileHashes = Dictionary(uniqueKeysWithValues: files.map { path, data in
            (path, Self.sha256(data))
        })
        var hasher = SHA256()
        hasher.update(data: IOSPluginLimits.packageHashDomain)
        for path in files.keys.sorted() {
            guard let data = files[path] else { continue }
            hasher.update(data: Self.lengthData(path.utf8.count))
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Self.lengthData(data.count))
            hasher.update(data: data)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return IOSPluginPackage(
            manifest: manifest,
            tools: validation.tools,
            primitiveTools: validation.primitiveTools,
            permissionEnvelope: envelope,
            hash: hash,
            fileHashes: fileHashes,
            files: files
        )
    }

    private func readPackageFiles(at directory: URL) throws -> [String: Data] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw IOSPluginFileStoreError.missing
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw IOSPluginFileStoreError.missing }
        var files: [String: Data] = [:]
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw IOSPluginFileStoreError.invalidPath(url.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(directory.path.count + 1))
            files[path] = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        return files
    }

    private func writePackage(_ package: IOSPluginPackage, to directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in package.files.keys.sorted() {
            guard let data = package.files[path] else { continue }
            let url = directory.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }
    }

    private func replacePreviousSlot(
        package: IOSPluginPackage,
        wasEnabled: Bool,
        trust: IOSPluginTrustRecord
    ) throws {
        try fileManager.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
        let slot = previousSlot(id: package.manifest.id)
        let staging = previousDirectory.appendingPathComponent(".\(package.manifest.id)-\(UUID().uuidString)")
        try writePackage(package, to: staging.appendingPathComponent("package", isDirectory: true))
        try Data((wasEnabled ? "true" : "false").utf8)
            .write(to: staging.appendingPathComponent("enabled"), options: [.atomic])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(trust).write(
            to: staging.appendingPathComponent("trust.json"),
            options: [.atomic]
        )
        if fileManager.fileExists(atPath: slot.path) {
            _ = try fileManager.replaceItemAt(slot, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: slot)
        }
    }

    private func setDisabledMarker(id: String, disabled: Bool) throws {
        let marker = disabledMarker(id: id)
        if disabled {
            try fileManager.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)
            try Data("disabled\n".utf8).write(to: marker, options: [.atomic])
        } else if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
    }

    func trustRecord(id: String) -> IOSPluginTrustRecord {
        storedTrustRecord(id: id) ?? .localUnsigned
    }

    private func storedTrustRecord(id: String) -> IOSPluginTrustRecord? {
        guard IOSRecipeNames.isValidRecipeName(id),
              let data = try? Data(contentsOf: trustURL(id: id)),
              let record = try? JSONDecoder().decode(IOSPluginTrustRecord.self, from: data) else {
            return nil
        }
        return record
    }

    private func setTrustRecord(id: String, trust: IOSPluginTrustRecord) throws {
        try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(trust).write(to: trustURL(id: id), options: [.atomic])
    }

    private func installedPackage(id: String) throws -> IOSPluginPackage? {
        do { return try readLivePlugin(id: id) }
        catch IOSPluginFileStoreError.missing { return nil }
    }

    private func pluginDirectory(id: String) -> URL {
        pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func previousSlot(id: String) -> URL {
        previousDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func disabledMarker(id: String) -> URL {
        disabledDirectory.appendingPathComponent(id)
    }

    private func trustURL(id: String) -> URL {
        metadataDirectory.appendingPathComponent("\(id).json")
    }

    private func isAllowedPackagePath(_ path: String) -> Bool {
        path == "plugin.json" || path == "README.md"
            || (path.hasPrefix("recipes/") && path.hasSuffix(".json"))
            || (path.hasPrefix("scripts/") && ["js", "sh", "py"].contains(URL(fileURLWithPath: path).pathExtension))
            || path.hasPrefix("assets/")
    }

    private static func permissionsExpanded(from old: IOSPluginPackage, to new: IOSPluginPackage) -> Bool {
        let oldCaps = old.manifest.capabilities
        let newCaps = new.manifest.capabilities
        return !new.primitiveTools.isSubset(of: old.primitiveTools)
            || !Set(newCaps.workspaceReadPrefixes).isSubset(of: Set(oldCaps.workspaceReadPrefixes))
            || !Set(newCaps.workspaceWritePrefixes).isSubset(of: Set(oldCaps.workspaceWritePrefixes))
            || !Set(newCaps.networkDomains).isSubset(of: Set(oldCaps.networkDomains))
            || !Set(newCaps.webMountActions).isSubset(of: Set(oldCaps.webMountActions))
            || !Set(newCaps.localRuntimes).isSubset(of: Set(oldCaps.localRuntimes))
    }

    private static func trustChangeRequiresDisable(
        from old: IOSPluginTrustRecord,
        to new: IOSPluginTrustRecord
    ) -> Bool {
        new.tier.rank < old.tier.rank
            || (old.tier == .signed && new.tier == .signed && old.keyId != new.keyId)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func lengthData(_ length: Int) -> Data {
        var value = UInt64(length).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt64>.size)
    }
}

enum IOSPluginFileStoreError: LocalizedError, Equatable {
    case invalidManifest(String)
    case invalidPluginId
    case invalidRecipe(String)
    case invalidScript(String)
    case invalidPath(String)
    case fileBudgetExceeded
    case validationFailed([String])
    case missing
    case baseChanged
    case candidateChanged
    case rollbackUnavailable
    case archiveInvalid(String)
    case signatureInvalid

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let details): "plugin.json 不符合 amber.plugin.v1：\(details)"
        case .invalidPluginId: "插件 id 无效。"
        case .invalidRecipe(let path): "\(path) 不是合法的 amber.recipe.v1。"
        case .invalidScript(let path): "\(path) 不是合法的 UTF-8 JavaScript。"
        case .invalidPath(let path): "插件路径不安全或不受支持：\(path)。"
        case .fileBudgetExceeded: "插件包超过文件数、单文件或总大小上限。"
        case .validationFailed(let issues): issues.joined(separator: "；")
        case .missing: "插件不存在。"
        case .baseChanged: "插件已在预览后发生变化，请重新预览。"
        case .candidateChanged: "候选插件已在预览后发生变化，请重新预览。"
        case .rollbackUnavailable: "没有可回退的插件版本。"
        case .archiveInvalid(let reason): "插件归档无效：\(reason)"
        case .signatureInvalid: "插件签名无效或包内容已被篡改。"
        }
    }
}
