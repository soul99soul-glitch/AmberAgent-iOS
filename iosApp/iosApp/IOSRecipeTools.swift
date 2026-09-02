import Foundation
@preconcurrency import Shared

// MARK: - Recipe approval request types (Wave B2; §14.2)
//
// One approval prompt type for the whole recipe surface, discriminated by
// payload:
// - `.step`:  a mutation STEP of an in-flight `recipe__<name>` call needs the
//   existing per-step approval (invariant 11 — a recipe never gets blanket
//   approval; §10.3.5). The card shows which step, which primitive and the
//   step's arguments.
// - `.import`: a `recipe_import` promotion of a Workspace `recipe.json`
//   candidate needs explicit approval (§13.1 / §14.2). The card shows the
//   manifest summary, permission envelope, base/candidate short hashes, the
//   step list (scrollable when long) and the "批准后从下一模型轮生效" copy.
//
// These are deliberately NOT slotted into `McpToolApprovalRequest`: the skill
// card's shape (file changes / server chips) does not fit a recipe's
// envelope/steps/hashes, and the finisher semantics differ (recipe step
// approval continues the recipe; recipe import approval applies a package).

struct RecipeStepApprovalPayload: Equatable {
    let stepId: String
    let tool: String
    let argumentsPreview: String
    let effectClass: IOSToolEffectClass
}

struct PluginInvocationApprovalPayload: Equatable {
    let toolId: String
    let handler: String
    let argumentsPreview: String
    let effectClass: IOSToolEffectClass
    let capabilities: [String]
}

struct RecipeImportApprovalPayload: Equatable {
    let artifactKindTitle: String
    let displayName: String?
    let mutationKind: IOSRecipeMutationKind
    let baseHash: String?
    let candidateHash: String
    let description: String
    let permissionSummary: String
    let effectClassRawValue: String
    let inputsSummary: String
    /// One row per step: `"<stepId> → <tool>"` (card renders them in a
    /// scrollable list when long, §14.2).
    let stepsSummary: [String]
    let outputsSummary: String
    let trustSummary: String?
    let capabilityScopes: [String]
    let fileHashes: [String]
    let activationNotice: String
}

struct RecipeToolApprovalRequest: Identifiable, Equatable {
    enum Payload: Equatable {
        case step(RecipeStepApprovalPayload)
        case pluginInvocation(PluginInvocationApprovalPayload)
        case recipeImport(RecipeImportApprovalPayload)
    }

    let id: String
    let recipeName: String
    let recipeVersion: String
    let payload: Payload
    let reason: String

    var title: String {
        switch payload {
        case .step: "执行 Recipe 步骤"
        case .pluginInvocation: "执行插件工具"
        case .recipeImport(let payload): payload.artifactKindTitle == "插件" ? "导入插件" : "导入 Recipe"
        }
    }

    var activityKind: AgentActivityKind {
        switch payload {
        case .step, .pluginInvocation: .workflow
        case .recipeImport: .workflow
        }
    }

    var isPluginImport: Bool {
        if case .recipeImport(let payload) = payload {
            return payload.artifactKindTitle == "插件"
        }
        return false
    }
}

// MARK: - Recipe import preview / prepared context (mirrors skill_import)

/// Read-only preview of a Workspace `recipe.json` candidate. Applying must
/// reproduce this exact candidate hash (§13.1: base/candidate CAS).
struct IOSRecipeImportPreview: Equatable {
    let name: String
    let version: String
    let kind: IOSRecipeMutationKind
    let baseHash: String?
    let candidateHash: String
    let description: String
    let effectClassRawValue: String
    let permissionSummary: String
    let inputsSummary: String
    let stepsSummary: [String]
    let outputsSummary: String

    var approvalSummary: String {
        let action = kind == .new ? "新增" : "更新"
        return "\(action) Recipe \(name) v\(version)"
    }
}

/// Small, in-memory approval context (same lifecycle as
/// `IOSPreparedSkillImport`). The candidate bytes stay in Workspace and are
/// read again when approval is granted, so stale candidates cannot be applied.
struct IOSPreparedRecipeImport: Equatable {
    let workspacePath: String
    let preview: IOSRecipeImportPreview
}

enum IOSRecipeToolCatalog {
    static let toolNames: Set<String> = [
        "recipes_list",
        "recipe_validate",
        "recipe_import",
        "recipe_enable",
        "recipe_disable",
        "recipe_delete",
    ]
    static let mutatingToolNames: Set<String> = [
        "recipe_import",
        "recipe_enable",
        "recipe_disable",
        "recipe_delete",
    ]
    static let highRiskToolNames: Set<String> = ["recipe_import", "recipe_delete"]
}

// MARK: - Execution checkpoint (durable pending-approval state, §13.2 / W1)

/// One paused `recipe__<name>` execution, mirrored to disk before the pause
/// becomes durable (`markRunAwaitingPermission`), so the in-flight recipe
/// state (inputs, completed step outputs, next step index) is never lost to a
/// process death between "card shown" and "card answered". The Room
/// awaiting-permission marker + persisted baseMessages are the SAME durable
/// domain the existing approvals use; the checkpoint file lives next to the
/// recipe store (`<base>/recipes/.checkpoints/`) because it pins that store's
/// catalog revision. Cold-start recovery terminates the approval fail-closed
/// (never resumes), so the file's only reader is the in-process finisher; a
/// sweep at the next recipe execution start removes any orphan (at most one
/// recipe pause can be live per process).
struct IOSRecipeExecutionCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let toolCallId: String
    let recipeName: String
    let recipeVersion: String
    let catalogRevision: Int64?
    let inputs: [String: IOSRecipeJSONValue]
    let stepOutputs: [String: String]
    let completedSteps: [String]
    let nextStepIndex: Int
    let executionId: String
}

struct IOSRecipeExecutionCheckpointStore {
    static let schemaVersion = 1

    private let directory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = baseDirectory
            .appendingPathComponent("recipes", isDirectory: true)
            .appendingPathComponent(".checkpoints", isDirectory: true)
    }

    /// Atomic write; the parent directory is created on demand. Approval must
    /// not be published unless this durable resume contract exists on disk.
    @discardableResult
    func save(_ checkpoint: IOSRecipeExecutionCheckpoint) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(checkpoint).write(to: fileURL(toolCallId: checkpoint.toolCallId), options: .atomic)
            return true
        } catch {
            NSLog("[IOSRecipeTools] checkpoint write failed toolCallId=\(checkpoint.toolCallId): \(error.localizedDescription)")
            return false
        }
    }

    func remove(toolCallId: String) {
        try? fileManager.removeItem(at: fileURL(toolCallId: toolCallId))
    }

    /// Removes every checkpoint file. Safe: at most one recipe pause can be
    /// live in the process (a paused run holds `currentRunId`; a new run
    /// cancels it and clears the checkpoint first), so any file on disk at
    /// the start of a new recipe execution is an orphan from a crash.
    func sweepOrphans() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileURL(toolCallId: String) -> URL {
        // toolCallId is model-supplied text; the filename is its digest so an
        // arbitrary id cannot escape the checkpoints directory.
        directory.appendingPathComponent("\(chatInputDigest(for: toolCallId)).json")
    }
}

// MARK: - recipe_import service (mirrors IOSSkillMcpToolService.skill_import)

/// `recipe_import` service: read-only preview of the Workspace candidate →
/// explicit approval → re-read + base/candidate CAS + semantic validation
/// (the registry's own catalog oracle) → `applyRecipe` → registry refresh so
/// the next model round sees the promoted recipe (§13.1 / §16.1).
@MainActor
struct IOSRecipeToolService {
    private static let maximumRecipeReadBytes = 256 * 1024

    let workspaceStore: IOSWorkspaceStore
    let recipeStore: IOSRecipeFileStore
    /// The same catalog oracle the registry uses (`IOSDynamicToolRegistry
    /// .primitiveCatalogEntry`), so promotion validation and execution-time
    /// availability can never disagree (§16.1).
    let catalog: IOSRecipeCatalogLookup
    /// Round-boundary publish: after a successful apply the registry is
    /// refreshed so the next model round acquires the new revision. Returns
    /// the published snapshot (its revision goes into the receipt).
    let refreshRegistry: @MainActor () async -> IOSDynamicToolCatalogSnapshot?

    init(
        workspaceStore: IOSWorkspaceStore,
        recipeStore: IOSRecipeFileStore,
        catalog: @escaping IOSRecipeCatalogLookup,
        refreshRegistry: @escaping @MainActor () async -> IOSDynamicToolCatalogSnapshot?
    ) {
        self.workspaceStore = workspaceStore
        self.recipeStore = recipeStore
        self.catalog = catalog
        self.refreshRegistry = refreshRegistry
    }

    func execute(toolName: String, arguments: String) async -> String {
        let args = ChatToolCallParsing.jsonObject(arguments) ?? [:]
        do {
            switch toolName {
            case "recipes_list":
                return recipesListJSON()
            case "recipe_validate":
                return try recipeValidateJSON(args)
            case "recipe_enable":
                return try await setRecipeEnabledJSON(args, enabled: true)
            case "recipe_disable":
                return try await setRecipeEnabledJSON(args, enabled: false)
            case "recipe_delete":
                return try await deleteRecipeJSON(args)
            default:
                return Self.json(["ok": false, "error": "Unknown tool: \(toolName)"])
            }
        } catch {
            return Self.json([
                "ok": false,
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            ])
        }
    }

    /// Read-only preview — zero writes (never creates directories).
    func prepareRecipeImport(arguments: String) throws -> IOSPreparedRecipeImport {
        guard let args = ChatToolCallParsing.jsonObject(arguments) else {
            throw IOSRecipeToolError.invalidArguments
        }
        let workspacePath = (args["workspace_path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !workspacePath.isEmpty else {
            throw IOSRecipeToolError.missingArgument("workspace_path")
        }
        let resolved = try resolveWorkspacePath(workspacePath)
        let data = try readWorkspaceRecipeData(workspacePath: resolved)
        let preview = try makeImportPreview(recipeJSON: data)
        return IOSPreparedRecipeImport(workspacePath: resolved, preview: preview)
    }

    /// Applies a previously previewed candidate after re-checking both sides
    /// of the CAS contract AND re-validating the manifest against the catalog
    /// oracle. Any stale change fails closed with a structured error — zero
    /// writes (§13.1: "任一变化，批准必须 fail closed，重新 preview").
    func applyPreparedRecipeImport(_ prepared: IOSPreparedRecipeImport) async throws -> String {
        let data: Data
        do {
            data = try readWorkspaceRecipeData(workspacePath: prepared.workspacePath)
        } catch {
            return Self.importErrorJSON(
                code: "stale_candidate",
                message: "Workspace 候选包已无法读取，请重新生成并预览。"
            )
        }
        let reread: IOSRecipeImportPreview
        do {
            reread = try makeImportPreview(recipeJSON: data)
        } catch {
            return Self.importErrorJSON(
                code: "stale_candidate",
                message: (error as? LocalizedError)?.errorDescription
                    ?? "Workspace 候选包已无法验证，请重新生成并预览。"
            )
        }
        guard reread.candidateHash == prepared.preview.candidateHash else {
            return Self.importErrorJSON(
                code: "stale_candidate",
                message: "Workspace 候选包在批准前发生变化，请重新预览。"
            )
        }
        guard reread.baseHash == prepared.preview.baseHash else {
            return Self.importErrorJSON(
                code: "stale_base",
                message: "已安装 Recipe 在批准前发生变化，请重新预览。"
            )
        }

        let receipt: IOSRecipeApplyReceipt
        do {
            receipt = try recipeStore.applyRecipe(
                name: prepared.preview.name,
                recipeJSON: data,
                expectedBaseHash: prepared.preview.baseHash,
                expectedCandidateHash: prepared.preview.candidateHash
            )
        } catch let error as IOSRecipeFileStoreError {
            switch error {
            case .recipePackageBaseChanged:
                return Self.importErrorJSON(
                    code: "stale_base",
                    message: error.errorDescription ?? "已安装 Recipe 在批准前发生变化，请重新预览。"
                )
            case .recipePackageCandidateChanged:
                return Self.importErrorJSON(
                    code: "stale_candidate",
                    message: error.errorDescription ?? "Workspace 候选包在批准前发生变化，请重新预览。"
                )
            default:
                throw error
            }
        }

        // §13.2.3 / §16.1: publish the new revision so the NEXT model round
        // acquires the promoted recipe (the round-boundary seam refreshes on
        // its own; this makes the receipt carry the actual revision).
        let snapshot = await refreshRegistry()
        return Self.json([
            "success": true,
            "status": receipt.outcome == .applied ? "applied" : "unchanged",
            "name": receipt.name,
            "hash": receipt.promotedHash,
            "version": reread.version,
            "description": reread.description,
            "permission_envelope": reread.effectClassRawValue,
            "permission_summary": reread.permissionSummary,
            "enabled": recipeStore.isRecipeEnabled(name: receipt.name),
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    /// Model-facing preview payload for `recipe_import` (mirrors the skill
    /// import preview shape: `requires_approval` + hashes + summaries).
    func recipeImportPreviewJSON(_ prepared: IOSPreparedRecipeImport) -> String {
        let preview = prepared.preview
        return Self.json([
            "ok": true,
            "status": "preview",
            "requires_approval": true,
            "name": preview.name,
            "version": preview.version,
            "kind": preview.kind.rawValue,
            "base_hash": preview.baseHash as Any? ?? NSNull(),
            "candidate_hash": preview.candidateHash,
            "description": preview.description,
            "permission_envelope": preview.effectClassRawValue,
            "permission_summary": preview.permissionSummary,
            "inputs": preview.inputsSummary,
            "steps": preview.stepsSummary,
            "outputs": preview.outputsSummary,
        ])
    }

    // MARK: Private

    private func recipesListJSON() -> String {
        let installed = recipeStore.listInstalledRecipes()
        let entries: [[String: Any]] = installed.map { recipe in
            let validation = IOSRecipeValidator.validate(
                manifest: recipe.manifest,
                catalog: catalog
            )
            return [
                "name": recipe.package.name,
                "version": recipe.package.version,
                "description": recipe.manifest.description,
                "hash": recipe.package.hash,
                "enabled": recipe.isEnabled,
                "valid": validation.isValid,
                "permission_summary": validation.permissionEnvelope
                    .map(IOSDynamicToolRegistry.permissionSummary(for:)) ?? "validation failed",
                "tools": ["recipe__\(recipe.package.name)"],
            ]
        }
        return Self.json([
            "ok": true,
            "installed_count": installed.count,
            "enabled_count": installed.filter(\.isEnabled).count,
            "recipes": entries,
        ])
    }

    private func recipeValidateJSON(_ args: [String: Any]) throws -> String {
        let data: Data
        if let name = normalizedName(args["name"]) {
            data = try recipeStore.readLiveRecipe(name: name).canonicalJSON
        } else if let workspacePath = normalizedString(args["workspace_path"]) {
            data = try readWorkspaceRecipeData(workspacePath: resolveWorkspacePath(workspacePath))
        } else {
            throw IOSRecipeToolError.missingArgument("name or workspace_path")
        }

        let manifest = try IOSRecipeManifest.decode(data)
        let validation = IOSRecipeValidator.validate(manifest: manifest, catalog: catalog)
        return Self.json([
            "ok": true,
            "valid": validation.isValid,
            "name": manifest.name,
            "version": manifest.version,
            "permission_envelope": validation.permissionEnvelope?.rawValue as Any? ?? NSNull(),
            "permission_summary": validation.permissionEnvelope
                .map(IOSDynamicToolRegistry.permissionSummary(for:)) as Any? ?? NSNull(),
            "issues": validation.issues.map { issue in
                [
                    "code": issue.code.rawValue,
                    "path": issue.path as Any? ?? NSNull(),
                    "message": issue.message,
                ]
            },
        ])
    }

    private func setRecipeEnabledJSON(_ args: [String: Any], enabled: Bool) async throws -> String {
        let (name, expectedHash) = try lifecycleTarget(args)
        let receipt = try recipeStore.setRecipeEnabled(
            name: name,
            enabled: enabled,
            expectedHash: expectedHash
        )
        let snapshot = await refreshRegistry()
        return Self.json([
            "ok": true,
            "status": receipt.changed ? (enabled ? "enabled" : "disabled") : "unchanged",
            "name": receipt.name,
            "hash": receipt.hash,
            "enabled": enabled,
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    private func deleteRecipeJSON(_ args: [String: Any]) async throws -> String {
        let (name, expectedHash) = try lifecycleTarget(args)
        let receipt = try recipeStore.deleteRecipe(name: name, expectedHash: expectedHash)
        let snapshot = await refreshRegistry()
        return Self.json([
            "ok": true,
            "status": "deleted",
            "name": receipt.name,
            "hash": receipt.hash,
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    private func lifecycleTarget(_ args: [String: Any]) throws -> (String, String) {
        guard let name = normalizedName(args["name"]) else {
            throw IOSRecipeToolError.missingArgument("name")
        }
        guard let expectedHash = normalizedString(args["expected_hash"]) else {
            throw IOSRecipeToolError.missingArgument("expected_hash")
        }
        return (name, expectedHash)
    }

    private func normalizedName(_ value: Any?) -> String? {
        guard let name = normalizedString(value)?.lowercased(),
              IOSRecipeNames.isValidRecipeName(name) else {
            return nil
        }
        return name
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeImportPreview(recipeJSON: Data) throws -> IOSRecipeImportPreview {
        let preparation = try recipeStore.prepareRecipe(recipeJSON: recipeJSON)
        let manifest = try IOSRecipeManifest.decode(recipeJSON)
        let validation = IOSRecipeValidator.validate(manifest: manifest, catalog: catalog)
        guard validation.isValid, let envelope = validation.permissionEnvelope else {
            throw IOSRecipeToolError.invalidRecipePackage(
                validation.issues.map(\.message)
            )
        }
        let permissionSummary = IOSDynamicToolRegistry.permissionSummary(for: envelope)
        let inputsSummary = manifest.inputs.sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value.rawValue)" }
            .joined(separator: ", ")
        let stepsSummary = manifest.steps.map { "\($0.id) → \($0.tool)" }
        let outputsSummary = manifest.outputs.sorted(by: { $0.key < $1.key })
            .map { name, value in
                if case .binding(let binding) = value { return "\(name)=\(binding.text)" }
                return name
            }
            .joined(separator: ", ")
        return IOSRecipeImportPreview(
            name: preparation.candidate.name,
            version: preparation.candidate.version,
            kind: preparation.kind,
            baseHash: preparation.base?.hash,
            candidateHash: preparation.candidate.hash,
            description: manifest.description,
            effectClassRawValue: envelope.rawValue,
            permissionSummary: permissionSummary,
            inputsSummary: inputsSummary,
            stepsSummary: stepsSummary,
            outputsSummary: outputsSummary
        )
    }

    /// Normalizes `workspace_path` (accepts `/workspace/...`, bare paths and
    /// record ids) and returns the canonical workspace-relative path.
    private func resolveWorkspacePath(_ raw: String) throws -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\\") else {
            throw IOSRecipeToolError.invalidWorkspacePath(raw)
        }
        if path == "/workspace" || path == "/workspace/" {
            throw IOSRecipeToolError.missingArgument("workspace_path")
        }
        if path.hasPrefix("/workspace/") {
            path.removeFirst("/workspace/".count)
        } else if path.hasPrefix("/") {
            throw IOSRecipeToolError.invalidWorkspacePath(raw)
        }
        while path.hasSuffix("/") { path.removeLast() }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IOSRecipeToolError.invalidWorkspacePath(raw)
        }
        return components.map(String.init).joined(separator: "/")
    }

    private func readWorkspaceRecipeData(workspacePath: String) throws -> Data {
        let record = workspaceStore.fileRecord(idOrPath: workspacePath)
            ?? workspaceStore.fileRecord(idOrPath: "/workspace/\(workspacePath)")
        guard let record else {
            throw IOSRecipeToolError.workspacePathMissing(workspacePath)
        }
        let url = workspaceStore.fileURL(for: record)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw IOSRecipeToolError.invalidWorkspacePath(workspacePath)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumRecipeReadBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecipeReadBytes else {
            throw IOSRecipeToolError.recipeFileTooLarge(workspacePath, Self.maximumRecipeReadBytes)
        }
        return data
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"JSON encoding failed"}"#
        }
        return text
    }

    static func importErrorJSON(code: String, message: String) -> String {
        json([
            "ok": false,
            "success": false,
            "status": "stale",
            "code": code,
            "error": message,
        ])
    }
}

// MARK: - Approval request builders

enum RecipeToolApprovalRequestBuilder {
    /// Card for one mutation step of an in-flight recipe execution.
    /// Slice B（B2）：id 必须是「外层 toolCallId + executionId + stepId」的
    /// 复合 id——同一 recipe 执行里的不同 step 卡 id 互不相同，旧 step 卡的
    /// approve/deny 不能消费当前暂停的另一个 step。
    static func stepRequest(
        for toolCall: UIMessagePart.Tool,
        recipeName: String,
        recipeVersion: String,
        payload: RecipeStepApprovalPayload,
        reason: String,
        executionId: String
    ) -> RecipeToolApprovalRequest {
        RecipeToolApprovalRequest(
            id: "\(ChatToolCallParsing.requestId(for: toolCall)):\(executionId):\(payload.stepId)",
            recipeName: recipeName,
            recipeVersion: recipeVersion,
            payload: .step(payload),
            reason: reason
        )
    }

    static func pluginInvocationRequest(
        for toolCall: UIMessagePart.Tool,
        pluginId: String,
        pluginVersion: String,
        payload: PluginInvocationApprovalPayload
    ) -> RecipeToolApprovalRequest {
        RecipeToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            recipeName: pluginId,
            recipeVersion: pluginVersion,
            payload: .pluginInvocation(payload),
            reason: "该插件将使用声明的主机或远端能力，请核对本次参数后继续。"
        )
    }

    /// Card for a `recipe_import` promotion (§14.2: manifest summary +
    /// permission envelope + short hashes + step list + next-round copy).
    static func importRequest(
        for toolCall: UIMessagePart.Tool,
        prepared: IOSPreparedRecipeImport
    ) -> RecipeToolApprovalRequest {
        let preview = prepared.preview
        return RecipeToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            recipeName: preview.name,
            recipeVersion: preview.version,
            payload: .recipeImport(RecipeImportApprovalPayload(
                artifactKindTitle: "Recipe",
                displayName: nil,
                mutationKind: preview.kind,
                baseHash: preview.baseHash,
                candidateHash: preview.candidateHash,
                description: preview.description,
                permissionSummary: preview.permissionSummary,
                effectClassRawValue: preview.effectClassRawValue,
                inputsSummary: preview.inputsSummary,
                stepsSummary: preview.stepsSummary,
                outputsSummary: preview.outputsSummary,
                trustSummary: nil,
                capabilityScopes: [],
                fileHashes: [],
                activationNotice: "批准后从下一模型轮生效。"
            )),
            reason: "请核对候选 Recipe 的 manifest 摘要与权限包络；批准后会复核 base/candidate 哈希并原子替换 Recipe 包。"
        )
    }

    static func pluginImportRequest(
        for toolCall: UIMessagePart.Tool,
        prepared: IOSPreparedPluginImport
    ) -> RecipeToolApprovalRequest {
        let preview = prepared.preview
        return RecipeToolApprovalRequest(
            id: ChatToolCallParsing.requestId(for: toolCall),
            recipeName: preview.id,
            recipeVersion: preview.version,
            payload: .recipeImport(RecipeImportApprovalPayload(
                artifactKindTitle: "插件",
                displayName: preview.displayName,
                mutationKind: preview.mutationKind,
                baseHash: preview.baseHash,
                candidateHash: preview.candidateHash,
                description: preview.description,
                permissionSummary: preview.permissionSummary,
                effectClassRawValue: preview.effectClassRawValue,
                inputsSummary: "",
                stepsSummary: preview.toolsSummary,
                outputsSummary: preview.mutationKind == .new
                    ? "新插件默认停用"
                    : (preview.permissionExpanded ? "权限范围扩大" : "权限范围未扩大"),
                trustSummary: IOSPluginToolService.trustSummary(preview.trust),
                capabilityScopes: preview.capabilityScopes,
                fileHashes: preview.fileHashes,
                activationNotice: preview.willRemainDisabled
                    ? "仅安装并保持停用；手动启用后从下一模型轮生效。"
                    : "安装后保持当前启用状态；目录变更从下一模型轮生效。"
            )),
            reason: "请核对插件工具、逐文件哈希与能力范围；批准后会重新读取 Workspace 并复核 base/candidate 哈希。"
        )
    }
}

// MARK: - amber.plugin.v1 management tools

struct IOSPluginImportPreview: Equatable {
    let id: String
    let displayName: String
    let version: String
    let mutationKind: IOSRecipeMutationKind
    let baseHash: String?
    let candidateHash: String
    let description: String
    let effectClassRawValue: String
    let permissionSummary: String
    let permissionExpanded: Bool
    let willRemainDisabled: Bool
    let toolsSummary: [String]
    let capabilityScopes: [String]
    let fileHashes: [String]
    let trust: IOSPluginTrustRecord
}

enum IOSPluginImportSource: Equatable {
    case directory(String)
    case archive(String)
}

struct IOSPreparedPluginImport: Equatable {
    let source: IOSPluginImportSource
    let preview: IOSPluginImportPreview
}

enum IOSPluginToolCatalog {
    static let toolNames: Set<String> = [
        "plugins_list", "plugin_validate", "plugin_import",
        "plugin_enable", "plugin_disable", "plugin_delete", "plugin_rollback", "plugin_restore", "plugin_export",
    ]
    static let mutatingToolNames: Set<String> = [
        "plugin_import", "plugin_enable", "plugin_disable", "plugin_delete", "plugin_rollback", "plugin_restore", "plugin_export",
    ]
    static let highRiskToolNames: Set<String> = ["plugin_import", "plugin_delete", "plugin_rollback", "plugin_restore", "plugin_export"]
}

@MainActor
struct IOSPluginToolService {
    let workspaceStore: IOSWorkspaceStore
    let pluginStore: IOSPluginFileStore
    let refreshRegistry: @MainActor () async -> IOSDynamicToolCatalogSnapshot?

    func execute(toolName: String, arguments: String) async -> String {
        let args = ChatToolCallParsing.jsonObject(arguments) ?? [:]
        do {
            switch toolName {
            case "plugins_list":
                return listJSON()
            case "plugin_validate":
                return try validateJSON(args)
            case "plugin_enable", "plugin_disable":
                return try await setEnabledJSON(args, enabled: toolName == "plugin_enable")
            case "plugin_delete":
                return try await deleteJSON(args)
            case "plugin_rollback":
                return try await rollbackJSON(args)
            case "plugin_restore":
                return try await restoreJSON(args)
            case "plugin_export":
                return try await exportJSON(args)
            default:
                return IOSWorkspaceStore.json(["ok": false, "error": "Unknown tool: \(toolName)"])
            }
        } catch {
            return IOSWorkspaceStore.json([
                "ok": false,
                "status": "failed",
                "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            ])
        }
    }

    func preparePluginImport(arguments: String) throws -> IOSPreparedPluginImport {
        guard let args = ChatToolCallParsing.jsonObject(arguments) else {
            throw IOSPluginToolError.missingArgument("workspace_directory or workspace_path")
        }
        if let raw = args["workspace_path"] as? String {
            return try prepared(source: .archive(try normalizeWorkspaceArchivePath(raw)))
        }
        guard let raw = args["workspace_directory"] as? String else {
            throw IOSPluginToolError.missingArgument("workspace_directory or workspace_path")
        }
        let directory = try normalizeWorkspaceDirectory(raw)
        return try prepared(source: .directory(directory))
    }

    func applyPreparedPluginImport(_ prepared: IOSPreparedPluginImport) async throws -> String {
        let reread = try self.prepared(source: prepared.source)
        guard reread.preview.candidateHash == prepared.preview.candidateHash else {
            throw IOSPluginFileStoreError.candidateChanged
        }
        guard reread.preview.baseHash == prepared.preview.baseHash else {
            throw IOSPluginFileStoreError.baseChanged
        }
        let candidate = try candidate(from: prepared.source)
        let receipt = try pluginStore.applyPlugin(
            files: candidate.files,
            expectedBaseHash: prepared.preview.baseHash,
            expectedCandidateHash: prepared.preview.candidateHash,
            trust: candidate.preparation.candidateTrust
        )
        let snapshot = await refreshRegistry()
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": receipt.changed ? "applied" : "unchanged",
            "id": receipt.id,
            "hash": receipt.hash,
            "enabled": receipt.enabled,
            "permission_expanded": receipt.permissionExpanded,
            "trust": receipt.trust.tier.rawValue,
            "signer": receipt.trust.keyId as Any? ?? NSNull(),
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    func importPreviewJSON(_ prepared: IOSPreparedPluginImport) -> String {
        let preview = prepared.preview
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": "preview",
            "requires_approval": true,
            "id": preview.id,
            "version": preview.version,
            "base_hash": preview.baseHash as Any? ?? NSNull(),
            "candidate_hash": preview.candidateHash,
            "permission_summary": preview.permissionSummary,
            "permission_expanded": preview.permissionExpanded,
            "will_remain_disabled": preview.willRemainDisabled,
            "tools": preview.toolsSummary,
            "files": preview.fileHashes,
            "trust": preview.trust.tier.rawValue,
            "signer": preview.trust.keyId as Any? ?? NSNull(),
        ])
    }

    private func prepared(source: IOSPluginImportSource) throws -> IOSPreparedPluginImport {
        let preparation = try candidate(from: source).preparation
        let package = preparation.candidate
        return IOSPreparedPluginImport(
            source: source,
            preview: IOSPluginImportPreview(
                id: package.manifest.id,
                displayName: package.manifest.name,
                version: package.manifest.version,
                mutationKind: preparation.base == nil ? .new : .update,
                baseHash: preparation.base?.hash,
                candidateHash: package.hash,
                description: package.manifest.description,
                effectClassRawValue: package.permissionEnvelope.rawValue,
                permissionSummary: IOSDynamicToolRegistry.permissionSummary(for: package.permissionEnvelope),
                permissionExpanded: preparation.permissionExpanded,
                willRemainDisabled: preparation.base == nil
                    || preparation.permissionExpanded
                    || !pluginStore.isPluginEnabled(id: package.manifest.id),
                toolsSummary: package.tools.map { "\($0.toolId) → \(implementationSummary($0.implementation))" },
                capabilityScopes: capabilityScopeSummary(package.manifest.capabilities),
                fileHashes: package.fileHashes.keys.sorted().map {
                    "\($0):\(package.fileHashes[$0]!)"
                },
                trust: preparation.candidateTrust
            )
        )
    }

    private func capabilityScopeSummary(_ capabilities: IOSPluginCapabilities) -> [String] {
        var rows: [String] = []
        rows += capabilities.workspaceReadPrefixes.map { "Workspace 读取：\($0)" }
        rows += capabilities.workspaceWritePrefixes.map { "Workspace 写入：\($0)" }
        rows += capabilities.networkDomains.map { "网络域名：\($0)" }
        rows += capabilities.webMountActions.map { "WebMount：\($0)" }
        return rows.isEmpty ? ["无额外能力范围"] : rows
    }

    fileprivate nonisolated static func trustSummary(_ trust: IOSPluginTrustRecord) -> String {
        switch trust.tier {
        case .builtIn: "信任：内置"
        case .signed: "信任：已签名（\(trust.keyId ?? "未知签名者")）"
        case .localUnsigned: "信任：本地未签名"
        }
    }

    private func implementationSummary(_ implementation: IOSPluginToolImplementation) -> String {
        switch implementation {
        case .recipe: "Recipe"
        case .javascript(_, let hostTools):
            hostTools.isEmpty ? "受限 JS" : "受限 JS（\(hostTools.sorted().joined(separator: "、"))）"
        case .remote(let remote):
            switch remote.kind {
            case .mcp: "MCP \(remote.server ?? "?")/\(remote.tool ?? "?")"
            case .openapi: "\(remote.method ?? "GET") \(remote.url ?? "?")"
            }
        }
    }

    private func listJSON() -> String {
        let installed = pluginStore.listInstalledPlugins()
        return IOSWorkspaceStore.json([
            "ok": true,
            "installed_count": installed.count,
            "enabled_count": installed.filter(\.isEnabled).count,
            "plugins": installed.map { item in
                [
                    "id": item.package.manifest.id,
                    "name": item.package.manifest.name,
                    "version": item.package.manifest.version,
                    "description": item.package.manifest.description,
                    "hash": item.package.hash,
                    "enabled": item.isEnabled,
                    "configured_enabled": item.isConfiguredEnabled,
                    "quarantined": item.health.isQuarantined,
                    "quarantine_reason": item.health.quarantineReason as Any? ?? NSNull(),
                    "consecutive_failures": item.health.consecutiveFailures,
                    "trust": item.trust.tier.rawValue,
                    "signer": item.trust.keyId as Any? ?? NSNull(),
                    "tools": item.package.tools.map(\.toolId),
                    "permission_summary": IOSDynamicToolRegistry.permissionSummary(for: item.package.permissionEnvelope),
                    "background_allowed": item.package.manifest.backgroundAllowed,
                    "background_eligible_tools": item.package.tools.filter { tool in
                        guard item.package.manifest.backgroundAllowed,
                              tool.effectClass == .pure || tool.effectClass == .networkRead else { return false }
                        switch tool.implementation {
                        case .recipe, .remote: return true
                        case .javascript: return false
                        }
                    }.map(\.toolId),
                    "publisher": item.package.manifest.directory?.publisher as Any? ?? NSNull(),
                    "minimum_age": item.package.manifest.directory?.minimumAge as Any? ?? NSNull(),
                ] as [String: Any]
            },
        ])
    }

    private func validateJSON(_ args: [String: Any]) throws -> String {
        let package: IOSPluginPackage
        if let id = normalized(args["id"]), IOSRecipeNames.isValidRecipeName(id) {
            package = try pluginStore.readLivePlugin(id: id)
        } else if let raw = normalizedText(args["workspace_directory"]) {
            package = try pluginStore.preparePlugin(
                files: workspacePackageFiles(directory: normalizeWorkspaceDirectory(raw))
            ).candidate
        } else if let raw = normalizedText(args["workspace_path"]) {
            package = try candidate(from: .archive(normalizeWorkspaceArchivePath(raw))).preparation.candidate
        } else {
            throw IOSPluginToolError.missingArgument("id, workspace_directory or workspace_path")
        }
        return IOSWorkspaceStore.json([
            "ok": true,
            "valid": true,
            "id": package.manifest.id,
            "version": package.manifest.version,
            "hash": package.hash,
            "tools": package.tools.map(\.toolId),
            "file_hashes": package.fileHashes,
        ])
    }

    private func setEnabledJSON(_ args: [String: Any], enabled: Bool) async throws -> String {
        let (id, hash) = try target(args)
        let receipt = try pluginStore.setPluginEnabled(id: id, enabled: enabled, expectedHash: hash)
        let snapshot = await refreshRegistry()
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": receipt.changed ? (enabled ? "enabled" : "disabled") : "unchanged",
            "id": id,
            "hash": receipt.hash,
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    private func deleteJSON(_ args: [String: Any]) async throws -> String {
        let (id, hash) = try target(args)
        _ = try pluginStore.deletePlugin(id: id, expectedHash: hash)
        let snapshot = await refreshRegistry()
        return IOSWorkspaceStore.json([
            "ok": true, "status": "deleted", "id": id,
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    private func rollbackJSON(_ args: [String: Any]) async throws -> String {
        let (id, hash) = try target(args)
        let receipt = try pluginStore.rollbackPlugin(id: id, expectedCurrentHash: hash)
        let snapshot = await refreshRegistry()
        return IOSWorkspaceStore.json([
            "ok": true, "status": "rolled_back", "id": id,
            "hash": receipt.hash, "enabled": receipt.enabled,
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    private func restoreJSON(_ args: [String: Any]) async throws -> String {
        let (id, hash) = try target(args)
        let receipt = try pluginStore.restorePlugin(id: id, expectedHash: hash)
        let snapshot = await refreshRegistry()
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": receipt.changed ? "restored" : "unchanged",
            "id": id,
            "hash": receipt.hash,
            "catalog_revision": snapshot?.revision as Any? ?? NSNull(),
        ])
    }

    private func exportJSON(_ args: [String: Any]) async throws -> String {
        let (id, hash) = try target(args)
        let package = try pluginStore.readLivePlugin(id: id)
        guard package.hash == hash else { throw IOSPluginFileStoreError.baseChanged }
        let rawPath = normalizedText(args["workspace_path"]) ?? "/workspace/plugins/\(id).amberplugin"
        let path = try normalizeWorkspaceArchivePath(rawPath)
        let archive = try pluginStore.exportArchive(id: id)
        guard let content = String(data: archive, encoding: .utf8) else {
            throw IOSPluginToolError.packageMissing
        }
        let inputData = try JSONSerialization.data(withJSONObject: [
            "path": "/workspace/\(path)",
            "content": content,
            "overwrite": true,
        ], options: [.sortedKeys])
        let result = await workspaceStore.executeTool(
            toolName: "workspace_file_write",
            input: String(data: inputData, encoding: .utf8) ?? "{}"
        )
        if let reason = ChatToolOutputFormatter.workspaceFailureReason(inOutputJSON: result) {
            throw IOSPluginToolError.exportFailed(reason)
        }
        return IOSWorkspaceStore.json([
            "ok": true,
            "status": "exported",
            "id": id,
            "hash": hash,
            "workspace_path": "/workspace/\(path)",
            "trust": pluginStore.trustRecord(id: id).tier.rawValue,
        ])
    }

    private func target(_ args: [String: Any]) throws -> (String, String) {
        guard let id = normalized(args["id"]), IOSRecipeNames.isValidRecipeName(id) else {
            throw IOSPluginToolError.missingArgument("id")
        }
        guard let hash = normalized(args["expected_hash"]) else {
            throw IOSPluginToolError.missingArgument("expected_hash")
        }
        return (id, hash)
    }

    private func workspacePackageFiles(directory: String) throws -> [String: Data] {
        let prefix = directory.isEmpty ? "" : "\(directory)/"
        let records = workspaceStore.files.filter { $0.workspacePath.hasPrefix(prefix) }
        var files: [String: Data] = [:]
        for record in records {
            let relative = String(record.workspacePath.dropFirst(prefix.count))
            guard IOSPluginValidator.isCanonicalPackagePath(relative) else {
                throw IOSPluginFileStoreError.invalidPath(relative)
            }
            let url = workspaceStore.fileURL(for: record)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw IOSPluginFileStoreError.invalidPath(relative)
            }
            files[relative] = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard files["plugin.json"] != nil else { throw IOSPluginToolError.packageMissing }
        return files
    }

    private func candidate(
        from source: IOSPluginImportSource
    ) throws -> (preparation: IOSPluginPackagePreparation, files: [String: Data]) {
        switch source {
        case .directory(let directory):
            let files = try workspacePackageFiles(directory: directory)
            return (try pluginStore.preparePlugin(files: files), files)
        case .archive(let path):
            guard let record = workspaceStore.fileRecord(idOrPath: "/workspace/\(path)") else {
                throw IOSPluginToolError.packageMissing
            }
            let url = workspaceStore.fileURL(for: record)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw IOSPluginFileStoreError.invalidPath(path)
            }
            return try pluginStore.prepareArchive(data: Data(contentsOf: url, options: [.mappedIfSafe]))
        }
    }

    private func normalizeWorkspaceDirectory(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/workspace/") { value.removeFirst("/workspace/".count) }
        else if value == "/workspace" { value = "" }
        else if value.hasPrefix("/") { throw IOSPluginToolError.invalidWorkspaceDirectory }
        while value.hasSuffix("/") { value.removeLast() }
        if !value.isEmpty && !IOSPluginValidator.isCanonicalPackagePath(value) {
            throw IOSPluginToolError.invalidWorkspaceDirectory
        }
        return value
    }

    private func normalizeWorkspaceArchivePath(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/workspace/") { value.removeFirst("/workspace/".count) }
        guard value.hasSuffix(".amberplugin"), IOSPluginValidator.isCanonicalPackagePath(value) else {
            throw IOSPluginToolError.invalidWorkspaceArchive
        }
        return value
    }

    private func normalized(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return result.isEmpty ? nil : result
    }

    private func normalizedText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

private enum IOSPluginToolError: LocalizedError {
    case missingArgument(String)
    case invalidWorkspaceDirectory
    case invalidWorkspaceArchive
    case packageMissing
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "Missing required argument: \(name)."
        case .invalidWorkspaceDirectory: "workspace_directory 必须是 /workspace 下的规范目录。"
        case .invalidWorkspaceArchive: "workspace_path 必须是 /workspace 下的规范 .amberplugin 文件。"
        case .packageMissing: "Workspace 中找不到插件包或 plugin.json。"
        case .exportFailed(let reason): "插件导出失败：\(reason)"
        }
    }
}

private enum IOSRecipeToolError: LocalizedError {
    case invalidArguments
    case missingArgument(String)
    case workspacePathMissing(String)
    case invalidWorkspacePath(String)
    case recipeFileTooLarge(String, Int)
    case invalidRecipePackage([String])

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Tool arguments must be a JSON object."
        case .missingArgument(let name):
            "\(name) is required"
        case .workspacePathMissing(let path):
            "Workspace path not found: \(path)"
        case .invalidWorkspacePath(let path):
            "Recipe 候选路径非法：\(path)"
        case .recipeFileTooLarge(let path, let limit):
            "Recipe 候选文件 \(path) 超过上限 \(limit) 字节。"
        case .invalidRecipePackage(let issues):
            issues.joined(separator: "；")
        }
    }
}
