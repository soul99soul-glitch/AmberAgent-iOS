import CryptoKit
import Foundation

// MARK: - IOSRecipeFileStore
//
// Independent, deliberately small store for declarative Recipe packages
// (§10.4: do NOT generalize `IOSSkillFileStore` into a generic artifact store
// yet — a second artifact kind that needs the same machinery has not
// appeared). A recipe package is a single `recipe.json` (the canonical bytes
// produced by `IOSRecipeManifest.canonicalJSONData()`).
//
// Mirrors the skill store's verified safety principles:
// - canonical package bytes + stable domain-separated hash (invariant 5:
//   executed = stored = hashed);
// - read-only preview (`prepareRecipe` never touches disk state);
// - base/candidate hash CAS on apply — a changed live base or changed
//   candidate fails closed with zero writes (§13.1);
// - same-volume staging + atomic `replaceItemAt` publish (a crash between the
//   slot and live renames can still leave a backup/stale slot; rollback
//   availability fails closed there);
// - active + single-slot previous (§18.1);
// - rollback re-validates the exact manifest the caller saw AND the live hash
//   against the slot's promoted hash, so a newer import cannot replace the
//   confirmed rollback target;

enum IOSRecipeMutationKind: String, Codable, Equatable {
    case new
    case update
}

/// A recipe package as the store hashes it: canonical bytes + stable hash.
struct IOSRecipePackage: Equatable {
    let name: String
    let version: String
    let hash: String
    let canonicalJSON: Data
}

/// What a preview shows; applying must reproduce this exact candidate hash.
struct IOSRecipePackagePreparation: Equatable {
    let kind: IOSRecipeMutationKind
    let base: IOSRecipePackage?
    let candidate: IOSRecipePackage
}

/// Durable rollback slot manifest (`.previous/<name>/manifest.json`).
struct IOSRecipePreviousManifest: Codable, Equatable {
    let schemaVersion: Int
    let hashFormatVersion: Int
    let name: String
    let kind: IOSRecipeMutationKind
    let baseHash: String?
    let promotedHash: String
}

enum IOSRecipeApplyOutcome: Equatable {
    case applied
    case unchanged
}

struct IOSRecipeApplyReceipt: Equatable {
    let name: String
    let promotedHash: String
    let outcome: IOSRecipeApplyOutcome
}

struct IOSInstalledRecipe: Equatable {
    let package: IOSRecipePackage
    let manifest: IOSRecipeManifest
    let isEnabled: Bool
}

struct IOSRecipeLifecycleReceipt: Equatable {
    let name: String
    let hash: String
    let changed: Bool
}

enum IOSRecipeRollbackAvailability: Equatable {
    case available(IOSRecipePreviousManifest)
    case unavailable(String)
    case stale(String)

    var canRollback: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .available(let manifest):
            manifest.kind == .new
                ? "回退后会移除这个新导入的 Recipe。"
                : "可恢复上一次导入前的 Recipe 包。"
        case .unavailable(let reason), .stale(let reason):
            reason
        }
    }
}

struct IOSRecipeRollbackReceipt: Equatable {
    let manifest: IOSRecipePreviousManifest
}

struct IOSRecipeFileStore {
    // All in-process writers share the CAS critical section, even when callers
    // construct separate value-type store instances for the same directory.
    private static let mutationLock = NSLock()

    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
    }

    var recipesDirectory: URL {
        baseDirectory.appendingPathComponent("recipes", isDirectory: true)
    }

    private var previousDirectory: URL {
        recipesDirectory.appendingPathComponent(".previous", isDirectory: true)
    }

    /// Disabled recipes remain installed and inspectable, but are excluded
    /// from the dynamic tool catalog. Absence means enabled so existing
    /// installs keep their pre-lifecycle behavior.
    private var disabledDirectory: URL {
        recipesDirectory.appendingPathComponent(".disabled", isDirectory: true)
    }

    // MARK: Preview — zero writes

    /// Builds the exact package a later approved apply would promote. Only
    /// reads; never creates directories, staging or previous slots.
    func prepareRecipe(recipeJSON: Data) throws -> IOSRecipePackagePreparation {
        let candidate = try makePackage(recipeJSON: recipeJSON)
        let base = try installedPackage(name: candidate.name)
        return IOSRecipePackagePreparation(
            kind: base == nil ? .new : .update,
            base: base,
            candidate: candidate
        )
    }

    // MARK: Apply — base/candidate CAS + atomic publish

    /// Promotes a previously previewed candidate after re-checking both sides
    /// of the CAS contract. The candidate is fully staged before the previous
    /// slot changes; synchronous publication failures restore the prior slot.
    /// A process crash mid-publish can still leave a backup or stale slot;
    /// `rollbackAvailability` fails closed there.
    @discardableResult
    func applyRecipe(
        name: String,
        recipeJSON: Data,
        expectedBaseHash: String?,
        expectedCandidateHash: String
    ) throws -> IOSRecipeApplyReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        let candidate = try makePackage(recipeJSON: recipeJSON)
        guard candidate.name == name else {
            throw IOSRecipeFileStoreError.recipeNameMismatch(expected: name, actual: candidate.name)
        }
        guard candidate.hash == expectedCandidateHash else {
            throw IOSRecipeFileStoreError.recipePackageCandidateChanged(
                expected: expectedCandidateHash,
                actual: candidate.hash
            )
        }

        let base = try installedPackage(name: name)
        guard base?.hash == expectedBaseHash else {
            throw IOSRecipeFileStoreError.recipePackageBaseChanged(
                expected: expectedBaseHash,
                actual: base?.hash
            )
        }
        if base?.hash == candidate.hash {
            return IOSRecipeApplyReceipt(name: name, promotedHash: candidate.hash, outcome: .unchanged)
        }

        let kind: IOSRecipeMutationKind = base == nil ? .new : .update
        let manifest = IOSRecipePreviousManifest(
            schemaVersion: Self.previousManifestSchemaVersion,
            hashFormatVersion: Self.packageHashFormatVersion,
            name: name,
            kind: kind,
            baseHash: base?.hash,
            promotedHash: candidate.hash
        )
        let liveStagingDirectory = try stageLivePackage(candidate)
        var shouldRemoveLiveStaging = true
        defer {
            if shouldRemoveLiveStaging {
                try? fileManager.removeItem(at: liveStagingDirectory)
            }
        }

        let previousBackup = try backupPreviousSlotIfPresent(name: name)
        do {
            try publishPreviousSlot(manifest: manifest, base: base)
            try promoteStagedLivePackage(liveStagingDirectory, name: name)
            shouldRemoveLiveStaging = false
        } catch {
            let publicationError = error
            try restorePreviousSlot(name: name, from: previousBackup)
            throw publicationError
        }
        if let previousBackup {
            try? fileManager.removeItem(at: previousBackup)
        }
        return IOSRecipeApplyReceipt(name: name, promotedHash: candidate.hash, outcome: .applied)
    }

    // MARK: Rollback — re-validated against the seen manifest

    func rollbackAvailability(name: String) throws -> IOSRecipeRollbackAvailability {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try inspectRollback(name: name).availability
    }

    /// Restores the package captured by the last apply, or removes a newly
    /// imported recipe. Both the displayed manifest and the live hash are
    /// re-validated here so a newer import cannot replace the confirmed
    /// rollback target.
    func rollbackRecipe(
        name: String,
        expectedManifest: IOSRecipePreviousManifest
    ) throws -> IOSRecipeRollbackReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let inspection = try inspectRollback(name: name)
        guard case .available(let manifest) = inspection.availability else {
            throw IOSRecipeFileStoreError.recipeRollbackUnavailable(inspection.availability.reason)
        }
        guard manifest == expectedManifest else {
            throw IOSRecipeFileStoreError.recipeRollbackUnavailable(
                "可回退版本已变化，请刷新后重试。"
            )
        }

        switch manifest.kind {
        case .update:
            guard let previousPackage = inspection.previousPackage else {
                throw IOSRecipeFileStoreError.recipeRollbackUnavailable("上一次 Recipe 包不可用。")
            }
            try publishLivePackage(previousPackage)
        case .new:
            let liveDirectory = try resolveRecipeDirectory(name: name)
            let discardedDirectory = recipesDirectory.appendingPathComponent(
                ".\(name)-rollback-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: liveDirectory, to: discardedDirectory)
            try? fileManager.removeItem(at: discardedDirectory)
            try? fileManager.removeItem(at: disabledMarkerURL(name: name))
        }

        // Live state is already complete at this point; best-effort slot
        // cleanup so a failed cleanup cannot report a failed rollback.
        try? fileManager.removeItem(at: previousSlotDirectory(name: name))
        return IOSRecipeRollbackReceipt(manifest: manifest)
    }

    /// Reads the active recipe package (canonical bytes + hash) — used by
    /// tests and by later waves to load the live manifest for execution.
    func readLiveRecipe(name: String) throws -> IOSRecipePackage {
        let directory = try resolveRecipeDirectory(name: name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IOSRecipeFileStoreError.recipeMissing(name)
        }
        let jsonURL = directory.appendingPathComponent("recipe.json")
        guard fileManager.fileExists(atPath: jsonURL.path) else {
            throw IOSRecipeFileStoreError.recipeMissing(name)
        }
        return try package(at: directory, expectedName: name)
    }

    func listInstalledRecipes() -> [IOSInstalledRecipe] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: recipesDirectory.path) else {
            return []
        }
        return names
            .filter(IOSRecipeNames.isValidRecipeName)
            .sorted()
            .compactMap { name in
                guard let package = try? readLiveRecipe(name: name),
                      let manifest = try? IOSRecipeManifest.decode(package.canonicalJSON) else {
                    return nil
                }
                return IOSInstalledRecipe(
                    package: package,
                    manifest: manifest,
                    isEnabled: isRecipeEnabled(name: name)
                )
            }
    }

    func isRecipeEnabled(name: String) -> Bool {
        guard IOSRecipeNames.isValidRecipeName(name) else { return false }
        return !fileManager.fileExists(atPath: disabledMarkerURL(name: name).path)
    }

    @discardableResult
    func setRecipeEnabled(
        name: String,
        enabled: Bool,
        expectedHash: String? = nil
    ) throws -> IOSRecipeLifecycleReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        guard let package = try installedPackage(name: name) else {
            throw IOSRecipeFileStoreError.recipeMissing(name)
        }
        if let expectedHash, package.hash != expectedHash {
            throw IOSRecipeFileStoreError.recipePackageBaseChanged(
                expected: expectedHash,
                actual: package.hash
            )
        }

        let marker = disabledMarkerURL(name: name)
        let wasEnabled = !fileManager.fileExists(atPath: marker.path)
        guard wasEnabled != enabled else {
            return IOSRecipeLifecycleReceipt(name: name, hash: package.hash, changed: false)
        }
        if enabled {
            try fileManager.removeItem(at: marker)
        } else {
            try fileManager.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)
            try Data("disabled\n".utf8).write(to: marker, options: .atomic)
        }
        return IOSRecipeLifecycleReceipt(name: name, hash: package.hash, changed: true)
    }

    @discardableResult
    func deleteRecipe(
        name: String,
        expectedHash: String? = nil
    ) throws -> IOSRecipeLifecycleReceipt {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        guard let package = try installedPackage(name: name) else {
            throw IOSRecipeFileStoreError.recipeMissing(name)
        }
        if let expectedHash, package.hash != expectedHash {
            throw IOSRecipeFileStoreError.recipePackageBaseChanged(
                expected: expectedHash,
                actual: package.hash
            )
        }

        try fileManager.removeItem(at: resolveRecipeDirectory(name: name))
        try? fileManager.removeItem(at: previousSlotDirectory(name: name))
        try? fileManager.removeItem(at: disabledMarkerURL(name: name))
        return IOSRecipeLifecycleReceipt(name: name, hash: package.hash, changed: true)
    }

    // MARK: Private

    private static let previousManifestSchemaVersion = 1
    private static let packageHashFormatVersion = 1

    private struct RollbackInspection {
        let availability: IOSRecipeRollbackAvailability
        let previousPackage: IOSRecipePackage?
    }

    private func makePackage(recipeJSON: Data) throws -> IOSRecipePackage {
        guard let manifest = try? IOSRecipeManifest.decode(recipeJSON) else {
            throw IOSRecipeFileStoreError.invalidRecipeJSON
        }
        let name = Self.normalizedRecipeName(manifest.name)
        guard IOSRecipeNames.isValidRecipeName(name) else {
            throw IOSRecipeFileStoreError.invalidRecipeName
        }
        // Canonical bytes are the stored + hashed bytes (invariant 5).
        let canonicalJSON = try manifest.canonicalJSONData()
        return IOSRecipePackage(
            name: name,
            version: manifest.version,
            hash: Self.canonicalPackageHash(canonicalJSON),
            canonicalJSON: canonicalJSON
        )
    }

    private func installedPackage(name: String) throws -> IOSRecipePackage? {
        let directory = try resolveRecipeDirectory(name: name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard isDirectory.boolValue else {
            throw IOSRecipeFileStoreError.invalidRecipeName
        }
        return try package(at: directory, expectedName: name)
    }

    private func package(at directory: URL, expectedName: String) throws -> IOSRecipePackage {
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw IOSRecipeFileStoreError.invalidRecipeName
        }
        let jsonURL = directory.appendingPathComponent("recipe.json")
        let data = try Data(contentsOf: jsonURL)
        let package = try makePackage(recipeJSON: data)
        guard package.name == expectedName else {
            throw IOSRecipeFileStoreError.recipeNameMismatch(expected: expectedName, actual: package.name)
        }
        return package
    }

    private func publishLivePackage(_ package: IOSRecipePackage) throws {
        let stagingDirectory = try stageLivePackage(package)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }
        try promoteStagedLivePackage(stagingDirectory, name: package.name)
        shouldRemoveStaging = false
    }

    private func stageLivePackage(_ package: IOSRecipePackage) throws -> URL {
        try fileManager.createDirectory(at: recipesDirectory, withIntermediateDirectories: true)
        let stagingDirectory = recipesDirectory.appendingPathComponent(
            ".\(package.name)-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try package.canonicalJSON.write(
            to: stagingDirectory.appendingPathComponent("recipe.json"),
            options: .atomic
        )
        return stagingDirectory
    }

    private func promoteStagedLivePackage(_ stagingDirectory: URL, name: String) throws {
        let liveDirectory = try resolveRecipeDirectory(name: name)
        if fileManager.fileExists(atPath: liveDirectory.path) {
            // 原子替换：失败或进程强杀时原目录始终在位（replaceItemAt 先把
            // 新目录就位再移除旧的），没有「旧目录已移成 backup 后被杀」的窗口。
            _ = try fileManager.replaceItemAt(
                liveDirectory,
                withItemAt: stagingDirectory,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingDirectory, to: liveDirectory)
        }
    }

    private func backupPreviousSlotIfPresent(name: String) throws -> URL? {
        let slotDirectory = previousSlotDirectory(name: name)
        guard fileManager.fileExists(atPath: slotDirectory.path) else { return nil }
        try fileManager.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
        let backupDirectory = previousDirectory.appendingPathComponent(
            ".\(name)-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: slotDirectory, to: backupDirectory)
        return backupDirectory
    }

    private func restorePreviousSlot(name: String, from backupDirectory: URL?) throws {
        let slotDirectory = previousSlotDirectory(name: name)
        if let backupDirectory {
            if fileManager.fileExists(atPath: slotDirectory.path) {
                _ = try fileManager.replaceItemAt(
                    slotDirectory,
                    withItemAt: backupDirectory,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: backupDirectory, to: slotDirectory)
            }
        } else if fileManager.fileExists(atPath: slotDirectory.path) {
            try fileManager.removeItem(at: slotDirectory)
        }
    }

    private func publishPreviousSlot(
        manifest: IOSRecipePreviousManifest,
        base: IOSRecipePackage?
    ) throws {
        try fileManager.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
        let slotDirectory = previousSlotDirectory(name: manifest.name)
        let stagingDirectory = previousDirectory.appendingPathComponent(
            ".\(manifest.name)-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }

        if let base {
            let packageDirectory = stagingDirectory.appendingPathComponent("package", isDirectory: true)
            try fileManager.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
            try base.canonicalJSON.write(
                to: packageDirectory.appendingPathComponent("recipe.json"),
                options: .atomic
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: stagingDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        if fileManager.fileExists(atPath: slotDirectory.path) {
            _ = try fileManager.replaceItemAt(
                slotDirectory,
                withItemAt: stagingDirectory,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingDirectory, to: slotDirectory)
        }
        shouldRemoveStaging = false
    }

    private func previousSlotDirectory(name: String) -> URL {
        previousDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func disabledMarkerURL(name: String) -> URL {
        disabledDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func inspectRollback(name: String) throws -> RollbackInspection {
        _ = try resolveRecipeDirectory(name: name)
        let slotDirectory = previousSlotDirectory(name: name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: slotDirectory.path, isDirectory: &isDirectory) else {
            return RollbackInspection(
                availability: .unavailable("没有可回退的上一次导入。"),
                previousPackage: nil
            )
        }
        guard isDirectory.boolValue else {
            return RollbackInspection(
                availability: .stale("上一次导入记录已损坏，不能回退。"),
                previousPackage: nil
            )
        }

        let manifest: IOSRecipePreviousManifest
        do {
            let data = try Data(contentsOf: slotDirectory.appendingPathComponent("manifest.json"))
            manifest = try JSONDecoder().decode(IOSRecipePreviousManifest.self, from: data)
        } catch {
            return RollbackInspection(
                availability: .stale("上一次导入记录已损坏，不能回退。"),
                previousPackage: nil
            )
        }
        guard manifest.schemaVersion == Self.previousManifestSchemaVersion,
              manifest.hashFormatVersion == Self.packageHashFormatVersion,
              manifest.name == name else {
            return RollbackInspection(
                availability: .stale("上一次导入记录版本或 Recipe 名称不匹配。"),
                previousPackage: nil
            )
        }

        let livePackage: IOSRecipePackage
        do {
            guard let installed = try installedPackage(name: name) else {
                return RollbackInspection(
                    availability: .stale("当前 Recipe 已经不存在，不能回退。"),
                    previousPackage: nil
                )
            }
            livePackage = installed
        } catch {
            return RollbackInspection(
                availability: .stale("当前 Recipe 包无法读取，不能回退。"),
                previousPackage: nil
            )
        }
        guard livePackage.hash == manifest.promotedHash else {
            return RollbackInspection(
                availability: .stale("当前 Recipe 已在导入后发生变化，不能回退。"),
                previousPackage: nil
            )
        }

        switch manifest.kind {
        case .new:
            guard manifest.baseHash == nil,
                  !fileManager.fileExists(
                    atPath: slotDirectory.appendingPathComponent("package", isDirectory: true).path
                  ) else {
                return RollbackInspection(
                    availability: .stale("新 Recipe 的回退记录不一致，不能回退。"),
                    previousPackage: nil
                )
            }
            return RollbackInspection(availability: .available(manifest), previousPackage: nil)
        case .update:
            guard let baseHash = manifest.baseHash else {
                return RollbackInspection(
                    availability: .stale("旧 Recipe 包哈希缺失，不能回退。"),
                    previousPackage: nil
                )
            }
            do {
                let previousPackage = try package(
                    at: slotDirectory.appendingPathComponent("package", isDirectory: true),
                    expectedName: name
                )
                guard previousPackage.hash == baseHash else {
                    return RollbackInspection(
                        availability: .stale("旧 Recipe 包已损坏，不能回退。"),
                        previousPackage: nil
                    )
                }
                return RollbackInspection(
                    availability: .available(manifest),
                    previousPackage: previousPackage
                )
            } catch {
                return RollbackInspection(
                    availability: .stale("旧 Recipe 包无法读取，不能回退。"),
                    previousPackage: nil
                )
            }
        }
    }

    private func resolveRecipeDirectory(name: String) throws -> URL {
        guard IOSRecipeNames.isValidRecipeName(name) else {
            throw IOSRecipeFileStoreError.invalidRecipeName
        }
        let root = recipesDirectory.standardizedFileURL
        let directory = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent().path == root.path else {
            throw IOSRecipeFileStoreError.invalidRecipeName
        }
        return directory
    }

    private static func normalizedRecipeName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Stable, domain-separated hash of the canonical recipe bytes (same
    /// length-prefix style as the skill store's package hash).
    private static func canonicalPackageHash(_ canonicalJSON: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: IOSRecipeLimits.packageHashDomain)
        hasher.update(data: encodedLength(canonicalJSON.count))
        hasher.update(data: canonicalJSON)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func encodedLength(_ length: Int) -> Data {
        var value = UInt64(length).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt64>.size)
    }
}

enum IOSRecipeFileStoreError: LocalizedError, Equatable {
    case invalidRecipeJSON
    case invalidRecipeName
    case recipeNameMismatch(expected: String, actual: String)
    case recipeMissing(String)
    case recipePackageBaseChanged(expected: String?, actual: String?)
    case recipePackageCandidateChanged(expected: String, actual: String)
    case recipeRollbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecipeJSON:
            "recipe.json 不是合法的 amber.recipe.v1 JSON。"
        case .invalidRecipeName:
            "Recipe 名称必须匹配 ^[a-z][a-z0-9_]{1,31}$。"
        case .recipeNameMismatch(let expected, let actual):
            "Recipe 包名称不匹配（预期 \(expected)，实际 \(actual)）。"
        case .recipeMissing(let name):
            "Recipe \(name) 不存在。"
        case .recipePackageBaseChanged(let expected, let actual):
            "Recipe 已在预览后发生变化（预期 \(expected ?? "不存在")，实际 \(actual ?? "不存在")）。"
        case .recipePackageCandidateChanged(let expected, let actual):
            "候选 Recipe 已在预览后发生变化（预期 \(expected)，实际 \(actual)）。"
        case .recipeRollbackUnavailable(let reason):
            reason
        }
    }
}

// MARK: - amber.plugin.v1 directory packages

enum IOSPluginTrustTier: String, Codable, Equatable, Sendable {
    case builtIn = "built_in"
    case signed
    case localUnsigned = "local_unsigned"

    fileprivate var rank: Int {
        switch self {
        case .builtIn: 3
        case .signed: 2
        case .localUnsigned: 1
        }
    }
}

struct IOSPluginTrustRecord: Codable, Equatable, Sendable {
    let tier: IOSPluginTrustTier
    let keyId: String?
    /// Retained so a verified archive can be exported without silently
    /// stripping its provenance. These bytes never affect runtime authority.
    let publicKeyBase64: String?
    let signatureBase64: String?

    static let localUnsigned = IOSPluginTrustRecord(
        tier: .localUnsigned,
        keyId: nil,
        publicKeyBase64: nil,
        signatureBase64: nil
    )
}

private struct IOSPluginArchiveFile: Codable, Equatable {
    let path: String
    let dataBase64: String
}

private struct IOSPluginArchiveSignature: Codable, Equatable {
    let algorithm: String
    let keyId: String
    let publicKeyBase64: String
    let signatureBase64: String
}

private struct IOSPluginArchiveEnvelope: Codable, Equatable {
    let schema: String
    let files: [IOSPluginArchiveFile]
    let signature: IOSPluginArchiveSignature?
}

enum IOSPluginArchiveCodec {
    static let schema = "amber.plugin.archive.v1"
    private static let signatureDomain = Data("amber.plugin.signature.v1\0".utf8)

    static func decode(
        _ data: Data,
        packageHashForFiles: ([String: Data]) throws -> String
    ) throws -> (files: [String: Data], trust: IOSPluginTrustRecord) {
        guard data.count <= IOSPluginLimits.maxPackageBytes * 2 else {
            throw IOSPluginFileStoreError.archiveInvalid("归档超过大小上限。")
        }
        let envelope: IOSPluginArchiveEnvelope
        do { envelope = try JSONDecoder().decode(IOSPluginArchiveEnvelope.self, from: data) }
        catch { throw IOSPluginFileStoreError.archiveInvalid("归档 JSON 无效。") }
        guard envelope.schema == schema, !envelope.files.isEmpty,
              envelope.files.count <= IOSPluginLimits.maxFiles else {
            throw IOSPluginFileStoreError.archiveInvalid("归档 schema 或文件数量无效。")
        }
        var files: [String: Data] = [:]
        for member in envelope.files {
            guard IOSPluginValidator.isCanonicalPackagePath(member.path), files[member.path] == nil,
                  let bytes = Data(base64Encoded: member.dataBase64),
                  bytes.count <= IOSPluginLimits.maxFileBytes else {
                throw IOSPluginFileStoreError.archiveInvalid("归档包含重复、不安全或无效文件。")
            }
            files[member.path] = bytes
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= IOSPluginLimits.maxPackageBytes else {
            throw IOSPluginFileStoreError.fileBudgetExceeded
        }
        guard let signature = envelope.signature else { return (files, .localUnsigned) }
        let packageHash = try packageHashForFiles(files)
        guard signature.algorithm == "ed25519",
              let publicKeyData = Data(base64Encoded: signature.publicKeyBase64),
              let signatureData = Data(base64Encoded: signature.signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        let keyId = String(Self.sha256(publicKeyData).prefix(16))
        guard signature.keyId == keyId,
              publicKey.isValidSignature(signatureData, for: signedMessage(packageHash: packageHash)) else {
            throw IOSPluginFileStoreError.signatureInvalid
        }
        return (files, IOSPluginTrustRecord(
            tier: .signed,
            keyId: keyId,
            publicKeyBase64: signature.publicKeyBase64,
            signatureBase64: signature.signatureBase64
        ))
    }

    static func encode(
        files: [String: Data],
        packageHash: String,
        signingKey: Curve25519.Signing.PrivateKey? = nil,
        preservedTrust: IOSPluginTrustRecord? = nil
    ) throws -> Data {
        let members = try files.keys.sorted().map { path -> IOSPluginArchiveFile in
            guard IOSPluginValidator.isCanonicalPackagePath(path), let data = files[path] else {
                throw IOSPluginFileStoreError.invalidPath(path)
            }
            return IOSPluginArchiveFile(path: path, dataBase64: data.base64EncodedString())
        }
        let signature: IOSPluginArchiveSignature?
        if let signingKey {
            let publicKey = signingKey.publicKey.rawRepresentation
            signature = IOSPluginArchiveSignature(
                algorithm: "ed25519",
                keyId: String(Self.sha256(publicKey).prefix(16)),
                publicKeyBase64: publicKey.base64EncodedString(),
                signatureBase64: try signingKey.signature(for: signedMessage(packageHash: packageHash)).base64EncodedString()
            )
        } else if let trust = preservedTrust,
                  trust.tier == .signed,
                  let keyId = trust.keyId,
                  let publicKey = trust.publicKeyBase64,
                  let signatureBytes = trust.signatureBase64 {
            signature = IOSPluginArchiveSignature(
                algorithm: "ed25519",
                keyId: keyId,
                publicKeyBase64: publicKey,
                signatureBase64: signatureBytes
            )
        } else {
            signature = nil
        }
        let envelope = IOSPluginArchiveEnvelope(schema: schema, files: members, signature: signature)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func isTrustValid(_ trust: IOSPluginTrustRecord, packageHash: String) -> Bool {
        switch trust.tier {
        case .builtIn, .localUnsigned:
            return true
        case .signed:
            guard let keyId = trust.keyId,
                  let publicKeyBase64 = trust.publicKeyBase64,
                  let signatureBase64 = trust.signatureBase64,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64),
                  let signatureData = Data(base64Encoded: signatureBase64),
                  String(Self.sha256(publicKeyData).prefix(16)) == keyId,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
                return false
            }
            return publicKey.isValidSignature(signatureData, for: signedMessage(packageHash: packageHash))
        }
    }

    private static func signedMessage(packageHash: String) -> Data {
        signatureDomain + Data(packageHash.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

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
        catch { throw IOSPluginFileStoreError.invalidManifest }
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
            || (path.hasPrefix("scripts/") && path.hasSuffix(".js"))
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
    case invalidManifest
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
        case .invalidManifest: "plugin.json 不是合法的 amber.plugin.v1。"
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
