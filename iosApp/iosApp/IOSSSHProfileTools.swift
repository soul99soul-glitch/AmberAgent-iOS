import Foundation
@preconcurrency import Shared

/// Agent-facing CRUD for the saved Remote SSH profiles.
///
/// The tools operate on the same `SettingsStore` the Remote Environment screen
/// edits, so an agent write is visible in settings (and vice versa) without any
/// extra refresh.
///
/// Credential contract (write-only):
/// - `password` / `private_key` / `passphrase` are accepted and written through
///   `SettingsStore` → `IOSSSHSecretStore` / `IOSSSHKeyStore` (Keychain).
///   No tool result ever contains them: outputs carry booleans (`has_password` /
///   `has_private_key`) and key metadata (`key_id` / `key_fingerprint`) only.
/// - `redactedArgumentsJSON(_:)` / `redactedApprovalMessages(_:)` strip those
///   fields before a call is persisted into the conversation or shown in the
///   approval card, so later turns never re-upload the secret.
///
/// Approval contract: `ssh_profile_list` is read-only and unapproved. The three
/// writers are high risk — ordinary auto-approve must not run them, and the
/// approval card is a foreground card that a lock-screen or phone push cannot
/// answer. An explicitly enabled high-risk auto-approve still runs them, exactly
/// like every other high-risk tool.
enum IOSSSHProfileToolCatalog {
    static let listToolName = "ssh_profile_list"
    static let createToolName = "ssh_profile_create"
    static let updateToolName = "ssh_profile_update"
    static let deleteToolName = "ssh_profile_delete"

    static let toolNames: Set<String> = [
        listToolName, createToolName, updateToolName, deleteToolName,
    ]
    /// Writes need a foreground approval card; they are never auto-approved by
    /// the ordinary (non high-risk) auto-approve switch.
    static let approvalRequiredToolNames: Set<String> = [
        createToolName, updateToolName, deleteToolName,
    ]
    static let highRiskToolNames: Set<String> = approvalRequiredToolNames
    static let mutatingToolNames: Set<String> = approvalRequiredToolNames
    /// Only the read-only listing may run during a background generation.
    static let backgroundAllowedToolNames: Set<String> = [listToolName]

    private static let secretArgumentKeys: Set<String> = ["password", "private_key", "passphrase"]

    static func contains(_ toolName: String) -> Bool { toolNames.contains(toolName) }

    /// Replaces credential arguments with a status marker while keeping the
    /// payload valid JSON. Used for persistence, re-upload and card previews.
    static func redactedArgumentsJSON(_ argumentsJSON: String) -> String {
        IOSSecretArgumentRedaction.redactedArgumentsJSON(argumentsJSON)
    }

    /// Approval snapshots are durable before the write runs. Keep the live call
    /// intact for the approved write; only the persisted copy is redacted.
    static func redactedApprovalMessages(_ messages: [UIMessage]) -> [UIMessage] {
        messages.map { message in
            var changed = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard let tool = part as? UIMessagePart.Tool,
                      toolNames.contains(tool.toolName) else {
                    return part
                }
                let redacted = redactedArgumentsJSON(tool.input)
                guard redacted != tool.input else { return part }
                changed = true
                return PromptTranscript.shared.doCopyTool(
                    tool: tool,
                    input: redacted,
                    output: tool.output
                )
            }
            guard changed else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
    }

    /// Human-readable approval card body. Replaces the JSON preview so the card
    /// states which profile and which fields change, and never shows a secret.
    static func approvalPreview(
        toolName: String,
        argumentsJSON: String,
        store: SettingsStore
    ) -> String {
        let args = ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:]
        let profileId = (args["profile_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = store.sshProfiles.first { $0.id == profileId }
        var lines: [String] = []

        switch toolName {
        case listToolName:
            lines.append("列出本机保存的 SSH Profile（只读）。")
        case createToolName:
            let name = nonEmpty(args["name"] as? String)
                ?? nonEmpty(args["host"] as? String).map { host in
                    let user = nonEmpty(args["username"] as? String) ?? ""
                    return user.isEmpty ? host : "\(user)@\(host)"
                }
                ?? "新 Profile"
            lines.append("新 Profile：\(String(name.prefix(80)))")
            lines.append(authLine(args: args, store: store))
            if let jumpLine = jumpLine(args: args, store: store) {
                lines.append(jumpLine)
            }
            lines.append(credentialLine(args: args, store: store))
        case updateToolName:
            if let target {
                lines.append("Profile：\(target.displayName)（\(target.username)@\(target.host):\(target.port)）")
            } else {
                lines.append("Profile（id \(String(profileId.prefix(8)))…）")
            }
            lines.append("改动字段：\(changedFieldNames(args: args, target: target))")
            if let jumpLine = jumpLine(args: args, store: store) {
                lines.append(jumpLine)
            }
            if let credential = optionalCredentialLine(args: args, store: store) { lines.append(credential) }
            // 改连接目标/认证方式会清掉旧凭证（与 SettingsStore 同一规则），
            // 必须提前告知，否则用户会以为旧密码还在。
            if let target, credentialClearedByEndpointChange(args: args, target: target) {
                lines.append(credentialClearedReason(args: args, target: target))
            }
            if let target, trustClearedByJumpChange(args: args, target: target) {
                lines.append("改动了跳板机：将清除已信任的主机指纹，经新路由首次连接需重新核对。")
            }
        case deleteToolName:
            if let target {
                lines.append("Profile：\(target.displayName)")
                lines.append("\(target.username)@\(target.host):\(target.port) · \(target.authMethod.displayName)")
            } else {
                lines.append("Profile（id \(String(profileId.prefix(8)))…）")
            }
            if target?.keyId != nil {
                lines.append("将解除本机密钥引用；密钥本身保留。")
            } else if let target, store.hasCredentialForSSHProfile(target) {
                lines.append("将一并清除本机已存凭证。")
            }
        default:
            lines.append(redactedArgumentsJSON(argumentsJSON))
        }
        return truncated(lines.joined(separator: "\n"), maxLength: 480)
    }

    static func approvalReason(toolName: String) -> String {
        switch toolName {
        case deleteToolName:
            return "将删除 SSH Profile；引用的本机密钥保留，需要你确认。"
        case createToolName:
            return "将往本机写入新的 SSH Profile 与凭证，需要你确认。"
        case updateToolName:
            return "将修改本机已保存的 SSH Profile，需要你确认。"
        default:
            return "SSH Profile 操作需要你确认。"
        }
    }

    private static func authLine(args: [String: Any], store: SettingsStore) -> String {
        let host = nonEmpty(args["host"] as? String) ?? "?"
        let port = (args["port"] as? Int) ?? Int(args["port"] as? String ?? "") ?? 22
        let user = nonEmpty(args["username"] as? String) ?? "?"
        let rawMethod = nonEmpty(args["auth_method"] as? String)
        let usesKey = rawMethod == "key" || rawMethod == "private_key" || rawMethod == "privateKey"
            || nonEmpty(args["key_id"] as? String) != nil
            || nonEmpty(args["private_key"] as? String) != nil
        return "\(user)@\(host):\(port) · \(usesKey ? "密钥认证" : "密码认证")"
    }

    private static func jumpLine(args: [String: Any], store: SettingsStore) -> String? {
        guard args.keys.contains("jump_profile_id") else { return nil }
        guard let jumpId = nonEmpty(args["jump_profile_id"] as? String) else {
            return "跳板机：直连（清除跳板）"
        }
        if let jump = store.sshProfiles.first(where: { $0.id == jumpId }) {
            return "跳板机：经 \(jump.displayName)（\(jump.username)@\(jump.host):\(jump.port)）"
        }
        return "跳板机：\(jumpId)"
    }

    private static func credentialLine(args: [String: Any], store: SettingsStore) -> String {
        if let credential = optionalCredentialLine(args: args, store: store) { return credential }
        return "未提供凭证：保存后需解锁设备并补存凭证才能连接。"
    }

    /// 空字符串等同于“清除已存凭证”（与 SettingsStore 的语义一致）。
    private static func optionalCredentialLine(args: [String: Any], store: SettingsStore) -> String? {
        if let keyId = args["key_id"] as? String {
            let trimmed = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "将解除绑定的本机 SSH 密钥。"
            }
            if let keyMeta = store.sshKeys.first(where: { $0.id == trimmed }) {
                return "将绑定本机密钥：\(keyMeta.name)（\(keyMeta.fingerprintSHA256)）。"
            }
            return "将绑定本机密钥 ID：\(trimmed)。"
        }
        if let password = args["password"] as? String {
            return password.isEmpty ? "将清除本机已存密码。" : "将设置/更换密码。"
        }
        if let key = args["private_key"] as? String {
            return key.isEmpty ? "将清除本机已存私钥。" : "将导入并绑定私钥。"
        }
        return nil
    }

    private static func changedFieldNames(
        args: [String: Any],
        target: IOSSSHProfile?
    ) -> String {
        var names: [String] = []
        if let name = args["name"] as? String, name != target?.name { names.append("名称") }
        if let host = args["host"] as? String, host != target?.host { names.append("Host") }
        if let raw = args["port"], let port = raw as? Int ?? Int(raw as? String ?? ""),
           port != (target?.port ?? 22) { names.append("端口") }
        if let user = args["username"] as? String, user != target?.username { names.append("用户名") }
        if let method = args["auth_method"] as? String,
           IOSSSHAuthMethod(rawValue: method) != target?.authMethod { names.append("认证方式") }
        if args.keys.contains("jump_profile_id") {
            let newJump = nonEmpty(args["jump_profile_id"] as? String)
            if newJump != target?.jumpProfileId {
                names.append("跳板机")
            }
        }
        if args.keys.contains("key_id") {
            let newKeyId = nonEmpty(args["key_id"] as? String)
            if newKeyId != target?.keyId {
                names.append("密钥")
            }
        }
        // 凭证变更本身也是“改动字段”：只改密码/私钥时不能显示“无”。
        if args["password"] != nil { names.append("密码") }
        if args["private_key"] != nil { names.append("私钥") }
        return names.isEmpty ? "无（仅核对现有配置）" : names.joined(separator: "、")
    }

    /// 未提供新凭证、但改动了连接目标或认证方式：`SettingsStore.upsertSSHProfile`
    /// 会删掉旧 Keychain 条目。审批卡必须显式告知。
    private static func credentialClearedByEndpointChange(
        args: [String: Any],
        target: IOSSSHProfile
    ) -> Bool {
        // 显式清空（传空字符串）已在 optionalCredentialLine 里说明，不重复提示。
        if args["password"] != nil || args["private_key"] != nil || args["key_id"] != nil { return false }
        let hostChanged = (args["host"] as? String).map { $0 != target.host } ?? false
        let portChanged = (args["port"]).map { raw in
            (raw as? Int ?? Int(raw as? String ?? "")) != target.port
        } ?? false
        let userChanged = (args["username"] as? String).map { $0 != target.username } ?? false
        let authChanged = (args["auth_method"] as? String)
            .flatMap(IOSSSHAuthMethod.init(rawValue:)).map { $0 != target.authMethod } ?? false
        return hostChanged || portChanged || userChanged || authChanged
    }

    private static func trustClearedByJumpChange(
        args: [String: Any],
        target: IOSSSHProfile
    ) -> Bool {
        guard target.knownHostSHA256?.isEmpty == false,
              args.keys.contains("jump_profile_id") else { return false }
        let newJump = nonEmpty(args["jump_profile_id"] as? String)
        return newJump != target.jumpProfileId
    }

    private static func credentialClearedReason(
        args: [String: Any],
        target: IOSSSHProfile
    ) -> String {
        var fields: [String] = []
        if let host = args["host"] as? String, host != target.host { fields.append("Host") }
        if let raw = args["port"], (raw as? Int ?? Int(raw as? String ?? "")) != target.port {
            fields.append("端口")
        }
        if let user = args["username"] as? String, user != target.username { fields.append("用户名") }
        if let method = args["auth_method"] as? String,
           IOSSSHAuthMethod(rawValue: method) != target.authMethod { fields.append("认证方式") }
        let changed = fields.isEmpty ? "连接目标或认证方式" : fields.joined(separator: "、")
        return "改动了 \(changed) 且未提供新凭证：批准后会清除本机已存的\(target.authMethod.displayName)。"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }
}

/// Executes the `ssh_profile_*` tools against the live settings store.
@MainActor
enum IOSSSHProfileToolExecutor {
    static func execute(
        toolName: String,
        argumentsJSON: String,
        settingsStore: SettingsStore
    ) -> String {
        guard IOSSSHProfileToolCatalog.contains(toolName) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolName,
                reason: "未知的 SSH Profile 工具。",
                status: "failed"
            )
        }
        guard let args = ChatToolCallParsing.jsonObject(argumentsJSON) else {
            return fail(toolName, "参数不是有效的 JSON 对象。")
        }
        do {
            switch toolName {
            case IOSSSHProfileToolCatalog.listToolName:
                return try list(arguments: args, store: settingsStore)
            case IOSSSHProfileToolCatalog.createToolName:
                return try create(arguments: args, store: settingsStore)
            case IOSSSHProfileToolCatalog.updateToolName:
                return try update(arguments: args, store: settingsStore)
            case IOSSSHProfileToolCatalog.deleteToolName:
                return try delete(arguments: args, store: settingsStore)
            default:
                return fail(toolName, "未知的 SSH Profile 工具。")
            }
        } catch let error as IOSSSHProfileToolError {
            return fail(toolName, error.message, status: error.status)
        } catch let error as IOSSSHRouteError {
            return fail(
                toolName,
                error.localizedDescription,
                status: error.status,
                extraFields: error.toToolFields()
            )
        } catch let error as IOSSSHPrivateKeyError {
            return fail(
                toolName,
                error.localizedDescription,
                status: statusForPrivateKeyError(error)
            )
        } catch let error as IOSSSHError {
            return fail(toolName, error.localizedDescription, status: "invalid_arguments")
        } catch {
            return fail(toolName, error.localizedDescription, status: "failed")
        }
    }

    // MARK: - Tools

    private static func list(arguments: [String: Any], store: SettingsStore) throws -> String {
        guard arguments.isEmpty else { throw IOSSSHProfileToolError.invalidArguments("ssh_profile_list 不接受参数。") }
        let profiles = store.sshProfiles.map { profile -> [String: Any] in
            profileSummaryDict(profile: profile, store: store)
        }
        let defaultProfile = store.defaultSSHProfile
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": IOSSSHProfileToolCatalog.listToolName,
            "profile_count": profiles.count,
            "default_profile_id": store.sshDefaultProfileId ?? "",
            "default_profile_name": defaultProfile?.displayName ?? "",
            "profiles": profiles,
        ])
    }

    private static func create(arguments: [String: Any], store: SettingsStore) throws -> String {
        for key in arguments.keys where !allowedCreateKeys.contains(key) {
            throw IOSSSHProfileToolError.invalidArguments("未知参数：\(key)")
        }
        let parsedCred = try parseCredentialArguments(from: arguments)
        var profile = IOSSSHProfile()
        profile.name = try optionalString(arguments, "name")
        profile.host = try requiredString(arguments, "host")
        profile.port = try port(arguments, default: 22)
        profile.username = try requiredString(arguments, "username")
        profile.jumpProfileId = try optionalNullableID(arguments, "jump_profile_id")
        profile.keyId = parsedCred.keyId
        profile.authMethod = try authMethod(
            arguments,
            parsedCred: parsedCred,
            fallbackProfile: nil
        )
        var validated = try profile.validated()
        try ensureUniqueName(validated, store: store)
        try validateAuthCombination(parsedCred: parsedCred, profile: validated, store: store, isCreate: true)

        // Validate before importing so a rejected route cannot leave an orphan key.
        _ = try IOSSSHRouteResolver.validateUpsert(candidate: validated, existingProfiles: store.sshProfiles)

        var importedKeyId: String?
        if let inlinePrivateKey = parsedCred.inlinePrivateKey {
            let keyName = store.uniqueSSHKeyName(base: "\(validated.displayName)-imported")
            let metadata = try store.importSSHKey(
                name: keyName,
                privateKey: inlinePrivateKey,
                passphrase: parsedCred.passphrase
            )
            importedKeyId = metadata.id
            validated.keyId = metadata.id
            validated.authMethod = .privateKey
        }

        do {
            try store.upsertSSHProfile(validated, credential: parsedCred.passwordCredential)
        } catch {
            if let importedKeyId {
                try? store.deleteSSHKey(id: importedKeyId)
            }
            throw error
        }
        let saved = store.sshProfiles.first(where: { $0.id == validated.id }) ?? validated
        return success(toolName: IOSSSHProfileToolCatalog.createToolName, profile: saved, store: store, action: "created")
    }

    private static func update(arguments: [String: Any], store: SettingsStore) throws -> String {
        for key in arguments.keys where !allowedUpdateKeys.contains(key) {
            throw IOSSSHProfileToolError.invalidArguments("未知参数：\(key)")
        }
        let profileId = try requiredString(arguments, "profile_id")
        guard let existing = store.sshProfiles.first(where: { $0.id == profileId }) else {
            throw IOSSSHProfileToolError.notFound(
                "未找到 id 为 \(profileId) 的 SSH Profile。请先调用 ssh_profile_list 获取最新列表。"
            )
        }
        let parsedCred = try parseCredentialArguments(from: arguments)
        var profile = existing
        if arguments.keys.contains("name") {
            profile.name = try optionalString(arguments, "name")
        }
        if arguments.keys.contains("host") {
            profile.host = try requiredString(arguments, "host")
        }
        if arguments.keys.contains("port") {
            profile.port = try port(arguments, default: existing.port)
        }
        if arguments.keys.contains("username") {
            profile.username = try requiredString(arguments, "username")
        }
        if arguments.keys.contains("jump_profile_id") {
            profile.jumpProfileId = try optionalNullableID(arguments, "jump_profile_id")
        }
        if arguments.keys.contains("key_id") {
            profile.keyId = parsedCred.keyId
        }
        if parsedCred.clearPrivateKey {
            profile.keyId = nil
        }
        if arguments.keys.contains("auth_method") || parsedCred.keyId != nil || parsedCred.inlinePrivateKey != nil {
            profile.authMethod = try authMethod(
                arguments,
                parsedCred: parsedCred,
                fallbackProfile: existing
            )
        }
        var validated = try profile.validated()
        try ensureUniqueName(validated, store: store)
        try validateAuthCombination(parsedCred: parsedCred, profile: validated, store: store, isCreate: false)

        _ = try IOSSSHRouteResolver.validateUpsert(candidate: validated, existingProfiles: store.sshProfiles)

        var importedKeyId: String?
        if let inlinePrivateKey = parsedCred.inlinePrivateKey {
            let keyName = store.uniqueSSHKeyName(base: "\(validated.displayName)-imported")
            let metadata = try store.importSSHKey(
                name: keyName,
                privateKey: inlinePrivateKey,
                passphrase: parsedCred.passphrase
            )
            importedKeyId = metadata.id
            validated.keyId = metadata.id
            validated.authMethod = .privateKey
        }

        do {
            try store.upsertSSHProfile(validated, credential: parsedCred.passwordCredential)
            if parsedCred.clearPassword || parsedCred.clearPrivateKey {
                try? IOSSSHSecretStore.deleteCredential(profileId: validated.id)
            }
        } catch {
            if let importedKeyId {
                try? store.deleteSSHKey(id: importedKeyId)
            }
            throw error
        }
        let saved = store.sshProfiles.first(where: { $0.id == validated.id }) ?? validated
        return success(toolName: IOSSSHProfileToolCatalog.updateToolName, profile: saved, store: store, action: "updated")
    }

    private static func delete(arguments: [String: Any], store: SettingsStore) throws -> String {
        for key in arguments.keys where !allowedDeleteKeys.contains(key) {
            throw IOSSSHProfileToolError.invalidArguments("未知参数：\(key)")
        }
        let profileId = try requiredString(arguments, "profile_id")
        guard let existing = store.sshProfiles.first(where: { $0.id == profileId }) else {
            throw IOSSSHProfileToolError.notFound(
                "未找到 id 为 \(profileId) 的 SSH Profile。请先调用 ssh_profile_list 获取最新列表。"
            )
        }
        // Mirrors the UI delete path, including jump dependency protection, Keychain cleanup,
        // and default reassignment.
        try store.deleteSSHProfile(id: profileId)
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": IOSSSHProfileToolCatalog.deleteToolName,
            "status": "deleted",
            "profile_id": existing.id,
            "name": existing.name,
            "display_name": existing.displayName,
            "credential_removed": true,
            "default_profile_id": store.sshDefaultProfileId ?? "",
        ])
    }

    // MARK: - Argument helpers

    private static let argumentKeys: Set<String> = [
        "profile_id", "name", "host", "port", "username", "auth_method",
        "password", "key_id", "private_key", "passphrase", "jump_profile_id",
    ]
    private static let allowedCreateKeys: Set<String> = [
        "name", "host", "port", "username", "auth_method",
        "password", "key_id", "private_key", "passphrase", "jump_profile_id",
    ]
    private static let allowedUpdateKeys: Set<String> = argumentKeys
    private static let allowedDeleteKeys: Set<String> = ["profile_id"]

    private struct ParsedCredentialArguments {
        var passwordCredential: IOSSSHCredential?
        var clearPassword: Bool = false
        var keyId: String?
        var inlinePrivateKey: String?
        var clearPrivateKey: Bool = false
        var passphrase: String?
    }

    private static func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw IOSSSHProfileToolError.invalidArguments("\(key) 不能为空。")
        }
        return value
    }

    private static func optionalString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let raw = arguments[key] else { return "" }
        guard let text = raw as? String else {
            throw IOSSSHProfileToolError.invalidArguments("\(key) 必须是字符串。")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalNullableID(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        guard let text = raw as? String else {
            throw IOSSSHProfileToolError.invalidArguments("\(key) 必须是字符串或 null。")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func port(_ arguments: [String: Any], default fallback: Int) throws -> Int {
        guard let raw = arguments["port"] else { return fallback }
        let value: Int
        switch raw {
        case let int as Int: value = int
        case let number as NSNumber: value = number.intValue
        case let text as String:
            guard let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw IOSSSHProfileToolError.invalidArguments("port 必须是 1-65535 的整数。")
            }
            value = parsed
        default:
            throw IOSSSHProfileToolError.invalidArguments("port 必须是 1-65535 的整数。")
        }
        guard (1...65_535).contains(value) else {
            throw IOSSSHProfileToolError.invalidArguments("port 必须是 1-65535 的整数。")
        }
        return value
    }

    private static func authMethod(
        _ arguments: [String: Any],
        parsedCred: ParsedCredentialArguments,
        fallbackProfile: IOSSSHProfile?
    ) throws -> IOSSSHAuthMethod {
        if let raw = arguments["auth_method"] {
            guard let text = raw as? String,
                  let method = IOSSSHAuthMethod(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw IOSSSHProfileToolError.invalidArguments("auth_method 只能是 \"password\"、\"key\" 或 \"private_key\"。")
            }
            return method
        }
        if parsedCred.keyId != nil || parsedCred.inlinePrivateKey != nil {
            return .privateKey
        }
        if parsedCred.passwordCredential != nil {
            return .password
        }
        return fallbackProfile?.authMethod ?? .password
    }

    private static func parseCredentialArguments(from arguments: [String: Any]) throws -> ParsedCredentialArguments {
        var result = ParsedCredentialArguments()
        let hasPasswordArg = arguments.keys.contains("password") && !(arguments["password"] is NSNull)
        let hasPrivateKeyArg = arguments.keys.contains("private_key") && !(arguments["private_key"] is NSNull)
        let hasKeyIdArg = arguments.keys.contains("key_id") && !(arguments["key_id"] is NSNull)

        if hasKeyIdArg {
            guard let text = arguments["key_id"] as? String else {
                throw IOSSSHProfileToolError.invalidArguments("key_id 必须是字符串。")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.keyId = trimmed.isEmpty ? nil : trimmed
        }

        if hasPasswordArg {
            guard let password = arguments["password"] as? String else {
                throw IOSSSHProfileToolError.invalidArguments("password 必须是字符串。")
            }
            if password.isEmpty {
                result.clearPassword = true
            } else {
                guard !IOSSecretArgumentRedaction.isRedactionPlaceholder(password) else {
                    throw IOSSSHProfileToolError.invalidArguments(
                        "password 是脱敏占位符而非真实凭证；待确认恢复后需要由用户重新确认，不能用占位符写入。"
                    )
                }
                result.passwordCredential = .password(password)
            }
        }

        if hasPrivateKeyArg {
            guard let privateKey = arguments["private_key"] as? String else {
                throw IOSSSHProfileToolError.invalidArguments("private_key 必须是字符串。")
            }
            if privateKey.isEmpty {
                result.clearPrivateKey = true
            } else {
                guard privateKey.utf8.count <= IOSSSHPrivateKey.maxArmoredBytes else {
                    throw IOSSSHProfileToolError.invalidArguments("private_key 不能超过 64 KB。")
                }
                guard !IOSSecretArgumentRedaction.isRedactionPlaceholder(privateKey) else {
                    throw IOSSSHProfileToolError.invalidArguments(
                        "private_key 是脱敏占位符而非真实凭证；待确认恢复后需要由用户重新确认，不能用占位符写入。"
                    )
                }
                result.inlinePrivateKey = privateKey
            }
        }

        if let rawPassphrase = arguments["passphrase"], !(rawPassphrase is NSNull) {
            guard let passText = rawPassphrase as? String else {
                throw IOSSSHProfileToolError.invalidArguments("passphrase 必须是字符串。")
            }
            if !passText.isEmpty {
                guard !IOSSecretArgumentRedaction.isRedactionPlaceholder(passText) else {
                    throw IOSSSHProfileToolError.invalidArguments(
                        "passphrase 是脱敏占位符而非真实口令；待确认恢复后需要由用户重新确认，不能用占位符写入。"
                    )
                }
                result.passphrase = passText
            }
        }

        // Mutual exclusions
        if hasPasswordArg && (hasPrivateKeyArg || result.keyId != nil) {
            throw IOSSSHProfileToolError.invalidArguments("password 与 key_id / private_key 只能提供一种。")
        }
        if result.keyId != nil && result.inlinePrivateKey != nil {
            throw IOSSSHProfileToolError.invalidArguments("key_id 与 private_key 不能同时提供；推荐使用 key_id 引用本机密钥。")
        }
        return result
    }

    private static func validateAuthCombination(
        parsedCred: ParsedCredentialArguments,
        profile: IOSSSHProfile,
        store: SettingsStore,
        isCreate: Bool
    ) throws {
        if let keyId = profile.keyId, !keyId.isEmpty {
            guard store.sshKeys.contains(where: { $0.id == keyId }) else {
                throw IOSSSHRouteError.keyNotFound(keyId: keyId)
            }
        }

        switch profile.authMethod {
        case .password:
            if parsedCred.keyId != nil || parsedCred.inlinePrivateKey != nil {
                throw IOSSSHProfileToolError.invalidArguments("auth_method=password 时不能提供 key_id 或 private_key。")
            }
            if isCreate && parsedCred.passwordCredential == nil {
                throw IOSSSHProfileToolError.invalidArguments(
                    "创建密码认证的 SSH Profile 需要同时提供 password。"
                )
            }
        case .privateKey:
            if parsedCred.passwordCredential != nil {
                throw IOSSSHProfileToolError.invalidArguments("密钥认证的 SSH Profile 不能提供 password。")
            }
            if isCreate && (profile.keyId ?? "").isEmpty && parsedCred.inlinePrivateKey == nil {
                throw IOSSSHProfileToolError.invalidArguments(
                    "创建密钥认证的 SSH Profile 需要提供 key_id（推荐先调用 ssh_key_generate 或 ssh_key_list）或 private_key。"
                )
            }
        }
    }

    private static func ensureUniqueName(_ profile: IOSSSHProfile, store: SettingsStore) throws {
        let candidate = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        let clash = store.sshProfiles.contains {
            $0.id != profile.id
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(candidate) == .orderedSame
        }
        guard !clash else {
            throw IOSSSHProfileToolError.invalidArguments(
                "已存在名为「\(candidate)」的 SSH Profile，请换一个名称。"
            )
        }
    }

    private static func credentialState(
        profile: IOSSSHProfile,
        store: SettingsStore
    ) -> (hasPassword: Bool, hasPrivateKey: Bool) {
        guard store.hasCredentialForSSHProfile(profile) else { return (false, false) }
        return (profile.authMethod == .password, profile.authMethod == .privateKey)
    }

    private static func profileSummaryDict(
        profile: IOSSSHProfile,
        store: SettingsStore
    ) -> [String: Any] {
        let credential = credentialState(profile: profile, store: store)
        let keyMeta = profile.keyId.flatMap { keyId in
            store.sshKeys.first(where: { $0.id == keyId })
        }
        let routeHops: [[String: Any]]
        if let resolved = try? store.resolveSSHRoute(for: profile) {
            routeHops = resolved.enumerated().map { index, hop in
                [
                    "hop_index": index + 1,
                    "profile_id": hop.id,
                    "display_name": hop.displayName,
                    "endpoint": "\(hop.username)@\(hop.host):\(hop.port)",
                    "host_key_trusted": hop.knownHostSHA256?.isEmpty == false,
                ]
            }
        } else {
            routeHops = []
        }
        return [
            "id": profile.id,
            "name": profile.name,
            "display_name": profile.displayName,
            "host": profile.host,
            "port": profile.port,
            "username": profile.username,
            "auth_method": profile.authMethod.rawValue,
            "auth_method_wire": profile.authMethod.wireName,
            "key_id": profile.keyId ?? NSNull(),
            "key_name": keyMeta?.name ?? NSNull(),
            "key_fingerprint": keyMeta?.fingerprintSHA256 ?? NSNull(),
            "jump_profile_id": profile.jumpProfileId ?? NSNull(),
            "has_password": credential.hasPassword,
            "has_private_key": credential.hasPrivateKey,
            "is_default": store.sshDefaultProfileId == profile.id,
            "host_key_trusted": profile.knownHostSHA256?.isEmpty == false,
            "route": routeHops,
            "route_ready": store.isSSHRouteReady(for: profile),
        ]
    }

    private static func success(
        toolName: String,
        profile: IOSSSHProfile,
        store: SettingsStore,
        action: String
    ) -> String {
        let credential = credentialState(profile: profile, store: store)
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": toolName,
            "status": action,
            "profile": profileSummaryDict(profile: profile, store: store),
            "credential_saved": credential.hasPassword || credential.hasPrivateKey,
            "note": "配置已写入本机。连接前仍需核对路由中每一跳的主机指纹并验证认证。",
        ])
    }

    private static func statusForPrivateKeyError(_ error: IOSSSHPrivateKeyError) -> String {
        switch error {
        case .passphraseRequired:
            return "passphrase_required"
        case .incorrectPassphrase:
            return "incorrect_passphrase"
        case .unsupportedAlgorithm:
            return "unsupported_algorithm"
        case .keyTooLarge:
            return "invalid_arguments"
        case .invalidFormat, .missingPrivateKey:
            return "invalid_private_key"
        case .secureEnclaveUnavailable:
            return "secure_enclave_unavailable"
        }
    }

    private static func fail(
        _ toolName: String,
        _ reason: String,
        status: String = "failed",
        extraFields: [String: Any] = [:]
    ) -> String {
        if extraFields.isEmpty {
            return ChatToolOutputFormatter.toolFailureJSON(toolName: toolName, reason: reason, status: status)
        }
        var payload: [String: Any] = [
            "ok": false,
            "tool": toolName,
            "status": status,
            "error_code": status,
            "reason": reason,
            "message": reason,
        ]
        for (key, value) in extraFields {
            payload[key] = value
        }
        return IOSWorkspaceStore.json(payload)
    }
}

enum IOSSSHProfileToolError: Error {
    case invalidArguments(String)
    case notFound(String)

    var message: String {
        switch self {
        case .invalidArguments(let text), .notFound(let text): text
        }
    }

    var status: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .notFound: "not_found"
        }
    }
}
