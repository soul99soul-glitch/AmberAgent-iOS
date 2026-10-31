import Foundation
@preconcurrency import Shared

/// Agent-facing CRUD for the saved Remote SSH profiles.
///
/// The tools operate on the same `SettingsStore` the Remote Environment screen
/// edits, so an agent write is visible in settings (and vice versa) without any
/// extra refresh.
///
/// Credential contract (write-only):
/// - `password` / `private_key` are accepted and written through the existing
///   `SettingsStore.upsertSSHProfile(_:credential:)` → `IOSSSHSecretStore`
///   (Keychain) path. No tool result ever contains them: outputs carry booleans
///   (`has_password` / `has_private_key`) only.
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

    private static let secretArgumentKeys: Set<String> = ["password", "private_key"]

    static func contains(_ toolName: String) -> Bool { toolNames.contains(toolName) }

    /// Replaces credential arguments with a status marker while keeping the
    /// payload valid JSON. Used for persistence, re-upload and card previews.
    static func redactedArgumentsJSON(_ argumentsJSON: String) -> String {
        guard var args = ChatToolCallParsing.jsonObject(argumentsJSON) else { return argumentsJSON }
        var changed = false
        for key in secretArgumentKeys where args.keys.contains(key) {
            let raw = (args[key] as? String) ?? ""
            args[key] = raw.isEmpty ? "(empty)" : IOSSSHOutputRedactor.replacement
            changed = true
        }
        guard changed else { return argumentsJSON }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
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
            lines.append(authLine(args: args))
            lines.append(credentialLine(args: args))
        case updateToolName:
            if let target {
                lines.append("Profile：\(target.displayName)（\(target.username)@\(target.host):\(target.port)）")
            } else {
                lines.append("Profile（id \(String(profileId.prefix(8)))…）")
            }
            lines.append("改动字段：\(changedFieldNames(args: args, target: target))")
            if let credential = optionalCredentialLine(args: args) { lines.append(credential) }
            // 改连接目标/认证方式会清掉旧凭证（与 SettingsStore 同一规则），
            // 必须提前告知，否则用户会以为旧密码还在。
            if let target, credentialClearedByEndpointChange(args: args, target: target) {
                lines.append(credentialClearedReason(args: args, target: target))
            }
        case deleteToolName:
            if let target {
                lines.append("Profile：\(target.displayName)")
                lines.append("\(target.username)@\(target.host):\(target.port) · \(target.authMethod.displayName)")
            } else {
                lines.append("Profile（id \(String(profileId.prefix(8)))…）")
            }
            if let target, store.hasCredentialForSSHProfile(target) {
                lines.append("将一并清除本机已存凭证。")
            }
        default:
            lines.append(argumentsJSON)
        }
        return truncated(lines.joined(separator: "\n"), maxLength: 480)
    }

    static func approvalReason(toolName: String) -> String {
        switch toolName {
        case deleteToolName:
            return "删除 SSH Profile 会同时清除本机钥匙串中的凭证，需要你确认。"
        case createToolName:
            return "将往本机写入新的 SSH Profile 与凭证，需要你确认。"
        case updateToolName:
            return "将修改本机已保存的 SSH Profile，需要你确认。"
        default:
            return "SSH Profile 操作需要你确认。"
        }
    }

    private static func authLine(args: [String: Any]) -> String {
        let host = nonEmpty(args["host"] as? String) ?? "?"
        let port = (args["port"] as? Int) ?? Int(args["port"] as? String ?? "") ?? 22
        let user = nonEmpty(args["username"] as? String) ?? "?"
        let method = nonEmpty(args["auth_method"] as? String) ?? "password"
        return "\(user)@\(host):\(port) · \(method == "private_key" ? "私钥认证" : "密码认证")"
    }

    private static func credentialLine(args: [String: Any]) -> String {
        if let credential = optionalCredentialLine(args: args) { return credential }
        return "未提供凭证：保存后需解锁设备并补存凭证才能连接。"
    }

    /// 空字符串等同于“清除已存凭证”（与 SettingsStore 的语义一致）。
    private static func optionalCredentialLine(args: [String: Any]) -> String? {
        if let password = args["password"] as? String {
            return password.isEmpty ? "将清除本机已存密码。" : "将设置/更换密码。"
        }
        if let key = args["private_key"] as? String {
            return key.isEmpty ? "将清除本机已存私钥。" : "将设置/更换私钥。"
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
        if args["password"] != nil || args["private_key"] != nil { return false }
        let hostChanged = (args["host"] as? String).map { $0 != target.host } ?? false
        let portChanged = (args["port"]).map { raw in
            (raw as? Int ?? Int(raw as? String ?? "")) != target.port
        } ?? false
        let userChanged = (args["username"] as? String).map { $0 != target.username } ?? false
        let authChanged = (args["auth_method"] as? String)
            .flatMap(IOSSSHAuthMethod.init(rawValue:)).map { $0 != target.authMethod } ?? false
        return hostChanged || portChanged || userChanged || authChanged
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
            let credential = credentialState(profile: profile, store: store)
            return [
                "id": profile.id,
                "name": profile.name,
                "display_name": profile.displayName,
                "host": profile.host,
                "port": profile.port,
                "username": profile.username,
                "auth_method": profile.authMethod.rawValue,
                "has_password": credential.hasPassword,
                "has_private_key": credential.hasPrivateKey,
                "is_default": store.sshDefaultProfileId == profile.id,
                "host_key_trusted": profile.knownHostSHA256?.isEmpty == false,
            ]
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
        let credential = try credential(from: arguments)
        var profile = IOSSSHProfile()
        profile.name = try optionalString(arguments, "name")
        profile.host = try requiredString(arguments, "host")
        profile.port = try port(arguments, default: 22)
        profile.username = try requiredString(arguments, "username")
        profile.authMethod = try authMethod(arguments, credential: credential, fallbackProfile: nil)
        let validated = try profile.validated()
        try ensureUniqueName(validated, store: store)
        try validateCredential(credential, profile: validated, required: true)
        try store.upsertSSHProfile(validated, credential: credential)
        return success(toolName: IOSSSHProfileToolCatalog.createToolName, profile: validated, store: store, action: "created")
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
        let credential = try credential(from: arguments)
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
        if arguments.keys.contains("auth_method") {
            profile.authMethod = try authMethod(arguments, credential: credential, fallbackProfile: existing)
        }
        let validated = try profile.validated()
        try ensureUniqueName(validated, store: store)
        try validateCredential(credential, profile: validated, required: false)
        // Same retention rule as the settings editor: an omitted credential on
        // an unchanged endpoint keeps the stored Keychain item.
        try store.upsertSSHProfile(validated, credential: credential)
        return success(toolName: IOSSSHProfileToolCatalog.updateToolName, profile: validated, store: store, action: "updated")
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
        // Mirrors the UI delete path, including Keychain cleanup and default
        // reassignment. Running terminal jobs that still reference the profile
        // fail with profile_not_found on their next step instead of being killed.
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
        "profile_id", "name", "host", "port", "username", "auth_method", "password", "private_key",
    ]
    private static let allowedCreateKeys: Set<String> = [
        "name", "host", "port", "username", "auth_method", "password", "private_key",
    ]
    private static let allowedUpdateKeys: Set<String> = argumentKeys
    private static let allowedDeleteKeys: Set<String> = ["profile_id"]

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
        credential: IOSSSHCredential?,
        fallbackProfile: IOSSSHProfile?
    ) throws -> IOSSSHAuthMethod {
        if let raw = arguments["auth_method"] {
            guard let text = raw as? String,
                  let method = IOSSSHAuthMethod(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw IOSSSHProfileToolError.invalidArguments("auth_method 只能是 \"password\" 或 \"private_key\"。")
            }
            return method
        }
        if let credential { return credential.authMethod }
        return fallbackProfile?.authMethod ?? .password
    }

    private static func credential(from arguments: [String: Any]) throws -> IOSSSHCredential? {
        let password = arguments["password"] as? String
        let privateKey = arguments["private_key"] as? String
        guard password == nil || privateKey == nil else {
            throw IOSSSHProfileToolError.invalidArguments("password 与 private_key 只能提供一个。")
        }
        if let password {
            guard !password.isEmpty else { return nil }
            guard !isRedactionPlaceholder(password) else {
                throw IOSSSHProfileToolError.invalidArguments(
                    "password 是脱敏占位符而非真实凭证；待确认恢复后需要由用户重新确认，不能用占位符写入。"
                )
            }
            return .password(password)
        }
        if let privateKey {
            guard !privateKey.isEmpty else { return nil }
            guard privateKey.utf8.count <= 64 * 1024 else {
                throw IOSSSHProfileToolError.invalidArguments("private_key 不能超过 64 KB。")
            }
            guard !isRedactionPlaceholder(privateKey) else {
                throw IOSSSHProfileToolError.invalidArguments(
                    "private_key 是脱敏占位符而非真实凭证；待确认恢复后需要由用户重新确认，不能用占位符写入。"
                )
            }
            return .privateKey(privateKey)
        }
        return nil
    }

    /// A resumed call may carry the redaction marker written into the durable
    /// approval snapshot. Storing that marker as a credential would silently
    /// persist a useless secret, so fail closed with an actionable message
    /// instead.
    private static func isRedactionPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "(empty)" || trimmed == IOSSSHOutputRedactor.replacement
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

    /// A supplied credential must match the profile's auth method. `saveCredential`
    /// already fails closed on a mismatch; validating here keeps the failure a
    /// readable argument error instead of a Keychain error after a partial write.
    private static func validateCredential(
        _ credential: IOSSSHCredential?,
        profile: IOSSSHProfile,
        required: Bool
    ) throws {
        guard let credential else {
            guard !required else {
                throw IOSSSHProfileToolError.invalidArguments(
                    "创建 SSH Profile 需要同时提供 password 或 private_key；只有修改已有 Profile 时才能省略凭证。"
                )
            }
            return
        }
        guard credential.authMethod == profile.authMethod else {
            throw IOSSSHProfileToolError.invalidArguments(
                "password 与 private_key 必须与 auth_method=\(profile.authMethod.rawValue) 一致。"
            )
        }
    }

    private static func credentialState(
        profile: IOSSSHProfile,
        store: SettingsStore
    ) -> (hasPassword: Bool, hasPrivateKey: Bool) {
        // Setting summaries use the metadata-only Keychain probe: the payload is
        // never loaded here.
        guard store.hasCredentialForSSHProfile(profile) else { return (false, false) }
        return (profile.authMethod == .password, profile.authMethod == .privateKey)
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
            "profile": [
                "id": profile.id,
                "name": profile.name,
                "display_name": profile.displayName,
                "host": profile.host,
                "port": profile.port,
                "username": profile.username,
                "auth_method": profile.authMethod.rawValue,
                "has_password": credential.hasPassword,
                "has_private_key": credential.hasPrivateKey,
                "is_default": store.sshDefaultProfileId == profile.id,
                "host_key_trusted": profile.knownHostSHA256?.isEmpty == false,
            ] as [String: Any],
            "credential_saved": credential.hasPassword || credential.hasPrivateKey,
            // A profile write cannot succeed the host-key probe: the settings
            // page still needs an explicit fingerprint check + auth test.
            "note": "凭证已写入本机钥匙串。连接前仍需在远程运行环境里核对主机指纹并验证认证。",
        ])
    }

    private static func fail(_ toolName: String, _ reason: String, status: String = "failed") -> String {
        ChatToolOutputFormatter.toolFailureJSON(toolName: toolName, reason: reason, status: status)
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
