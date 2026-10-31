import Foundation
@preconcurrency import Shared

/// Agent-facing CRUD for local SSH keys stored in `SettingsStore` + `IOSSSHKeyStore`.
///
/// Security contract:
/// - `ssh_key_list` is read-only and returns metadata + OpenSSH public keys + SHA256
///   fingerprints only; private key material is never returned.
/// - `ssh_key_generate`, `ssh_key_import`, and `ssh_key_delete` are high-risk writes:
///   ordinary auto-approve must not run them, and remote surfaces (lock screen,
///   notifications, Dynamic Island, Watch) may only deny them.
/// - `private_key` and `passphrase` arguments on `ssh_key_import` are redacted before
///   entering persistent conversation history, compaction summaries, or approval cards.
enum IOSSSHKeyToolCatalog {
    static let listToolName = "ssh_key_list"
    static let generateToolName = "ssh_key_generate"
    static let importToolName = "ssh_key_import"
    static let deleteToolName = "ssh_key_delete"

    static let toolNames: Set<String> = [
        listToolName, generateToolName, importToolName, deleteToolName,
    ]
    static let approvalRequiredToolNames: Set<String> = [
        generateToolName, importToolName, deleteToolName,
    ]
    static let highRiskToolNames: Set<String> = approvalRequiredToolNames
    static let mutatingToolNames: Set<String> = approvalRequiredToolNames
    static let backgroundAllowedToolNames: Set<String> = [listToolName]

    static func contains(_ toolName: String) -> Bool { toolNames.contains(toolName) }

    static func redactedArgumentsJSON(_ argumentsJSON: String) -> String {
        IOSSecretArgumentRedaction.redactedArgumentsJSON(argumentsJSON)
    }

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

    static func approvalPreview(
        toolName: String,
        argumentsJSON: String,
        store: SettingsStore
    ) -> String {
        let args = ChatToolCallParsing.jsonObject(argumentsJSON) ?? [:]
        var lines: [String] = []

        switch toolName {
        case listToolName:
            lines.append("列出本机保存的 SSH 密钥（只读）。")
        case generateToolName:
            let name = nonEmpty(args["name"] as? String) ?? "未命名密钥"
            let rawType = nonEmpty(args["type"] as? String) ?? IOSSSHKeyType.ed25519.rawValue
            let keyType = IOSSSHKeyType(rawValue: rawType)
            let userPresence = (args["require_user_presence"] as? Bool) ?? false
            lines.append("生成新 SSH 密钥：\(String(name.prefix(64)))")
            lines.append("算法：\(keyType?.displayName ?? rawType)")
            lines.append("生物识别/解锁验证：\(userPresence ? "每次使用需验证" : "设备解锁期间可用")")
        case importToolName:
            let name = nonEmpty(args["name"] as? String) ?? "导入密钥"
            let hasPassphrase = nonEmpty(args["passphrase"] as? String) != nil
            lines.append("导入 SSH 私钥：\(String(name.prefix(64)))")
            lines.append("加密口令：\(hasPassphrase ? "已提供（将在导入时解密并仅保存私钥于本机钥匙串）" : "无")")
            lines.append("私钥内容已脱敏，不会显示在审批卡或聊天记录中。")
        case deleteToolName:
            let keyId = nonEmpty(args["key_id"] as? String) ?? ""
            if let existing = store.sshKeys.first(where: { $0.id == keyId }) {
                lines.append("删除 SSH 密钥：\(existing.name)（\(existing.algorithm)）")
                lines.append("指纹：\(existing.fingerprintSHA256)")
            } else {
                lines.append("删除 SSH 密钥（id \(String(keyId.prefix(12)))）")
            }
            lines.append("将从本机钥匙串永久清除该私钥。")
        default:
            lines.append(redactedArgumentsJSON(argumentsJSON))
        }
        return truncated(lines.joined(separator: "\n"), maxLength: 480)
    }

    static func approvalReason(toolName: String) -> String {
        switch toolName {
        case generateToolName:
            return "将在本机钥匙串生成新的 SSH 密钥对并返回公钥，需要你确认。"
        case importToolName:
            return "将把 SSH 私钥导入本机钥匙串，需要你确认。"
        case deleteToolName:
            return "将从本机钥匙串永久删除 SSH 密钥，需要你确认。"
        default:
            return "SSH 密钥操作需要你确认。"
        }
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

@MainActor
enum IOSSSHKeyToolExecutor {
    static func execute(
        toolName: String,
        argumentsJSON: String,
        settingsStore: SettingsStore
    ) -> String {
        guard IOSSSHKeyToolCatalog.contains(toolName) else {
            return ChatToolOutputFormatter.toolFailureJSON(
                toolName: toolName,
                reason: "未知的 SSH 密钥工具。",
                status: "failed"
            )
        }
        guard let args = ChatToolCallParsing.jsonObject(argumentsJSON) else {
            return fail(toolName, "参数不是有效的 JSON 对象。")
        }
        do {
            switch toolName {
            case IOSSSHKeyToolCatalog.listToolName:
                return try list(arguments: args, store: settingsStore)
            case IOSSSHKeyToolCatalog.generateToolName:
                return try generate(arguments: args, store: settingsStore)
            case IOSSSHKeyToolCatalog.importToolName:
                return try importKey(arguments: args, store: settingsStore)
            case IOSSSHKeyToolCatalog.deleteToolName:
                return try delete(arguments: args, store: settingsStore)
            default:
                return fail(toolName, "未知的 SSH 密钥工具。")
            }
        } catch let error as IOSSSHKeyToolError {
            return fail(
                toolName,
                error.message,
                status: error.status,
                extraFields: error.extraFields
            )
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
                error.asSSHError.localizedDescription,
                status: statusForPrivateKeyError(error)
            )
        } catch let error as IOSSSHError {
            return fail(toolName, error.localizedDescription, status: "invalid_arguments")
        } catch {
            return fail(toolName, "SSH 密钥操作失败，请解锁设备后重试。", status: "failed")
        }
    }

    // MARK: - Tool Implementations

    private static func list(arguments: [String: Any], store: SettingsStore) throws -> String {
        guard arguments.isEmpty else {
            throw IOSSSHKeyToolError.invalidArguments("ssh_key_list 不接受参数。")
        }
        let keys = store.sshKeys.map { metadata in
            keySummaryDict(metadata: metadata, store: store)
        }
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": IOSSSHKeyToolCatalog.listToolName,
            "key_count": keys.count,
            "keys": keys,
        ])
    }

    private static func generate(arguments: [String: Any], store: SettingsStore) throws -> String {
        let allowed: Set<String> = ["name", "type", "require_user_presence"]
        for key in arguments.keys where !allowed.contains(key) {
            throw IOSSSHKeyToolError.invalidArguments("未知参数：\(key)")
        }
        let name = try validatedKeyName(arguments["name"], store: store)
        let keyType: IOSSSHKeyType
        if let rawType = arguments["type"] {
            guard let text = rawType as? String,
                  let parsed = IOSSSHKeyType(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw IOSSSHKeyToolError.invalidArguments("type 只能是 \"ed25519\" 或 \"ecdsa-p256-se\"。")
            }
            keyType = parsed
        } else {
            keyType = .ed25519
        }
        let requireUserPresence: Bool
        if let rawPresence = arguments["require_user_presence"] {
            guard let flag = rawPresence as? Bool else {
                throw IOSSSHKeyToolError.invalidArguments("require_user_presence 必须是布尔值。")
            }
            requireUserPresence = flag
        } else {
            requireUserPresence = false
        }

        let metadata = try store.generateSSHKey(
            name: name,
            type: keyType,
            requireUserPresence: requireUserPresence
        )
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": IOSSSHKeyToolCatalog.generateToolName,
            "status": "generated",
            "key_id": metadata.id,
            "public_key": metadata.publicKeyOpenSSH,
            "fingerprint": metadata.fingerprintSHA256,
            "key": keySummaryDict(metadata: metadata, store: store),
            "note": "密钥已生成并存入本机钥匙串。请将 public_key 添加到目标服务器的 ~/.ssh/authorized_keys，随后使用 key_id 创建或更新 SSH Profile。",
        ])
    }

    private static func importKey(arguments: [String: Any], store: SettingsStore) throws -> String {
        let allowed: Set<String> = ["name", "private_key", "passphrase"]
        for key in arguments.keys where !allowed.contains(key) {
            throw IOSSSHKeyToolError.invalidArguments("未知参数：\(key)")
        }
        let name = try validatedKeyName(arguments["name"], store: store)
        guard let rawPrivateKey = arguments["private_key"] as? String else {
            throw IOSSSHKeyToolError.invalidArguments("private_key 不能为空。")
        }
        let trimmedKey = rawPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw IOSSSHKeyToolError.invalidArguments("private_key 不能为空。")
        }
        guard rawPrivateKey.utf8.count <= IOSSSHPrivateKey.maxArmoredBytes else {
            throw IOSSSHKeyToolError.invalidArguments("private_key 不能超过 64 KB。")
        }
        guard !IOSSecretArgumentRedaction.isRedactionPlaceholder(rawPrivateKey) else {
            throw IOSSSHKeyToolError.invalidArguments(
                "private_key 是脱敏占位符而非真实私钥；待确认恢复后需要由用户重新发起，不能用占位符写入。"
            )
        }

        var passphrase: String?
        if let rawPass = arguments["passphrase"] {
            guard let passText = rawPass as? String else {
                throw IOSSSHKeyToolError.invalidArguments("passphrase 必须是字符串。")
            }
            if !passText.isEmpty {
                guard !IOSSecretArgumentRedaction.isRedactionPlaceholder(passText) else {
                    throw IOSSSHKeyToolError.invalidArguments(
                        "passphrase 是脱敏占位符而非真实口令；待确认恢复后需要由用户重新发起，不能用占位符写入。"
                    )
                }
                passphrase = passText
            }
        }

        let metadata = try store.importSSHKey(
            name: name,
            privateKey: rawPrivateKey,
            passphrase: passphrase
        )
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": IOSSSHKeyToolCatalog.importToolName,
            "status": "imported",
            "key_id": metadata.id,
            "public_key": metadata.publicKeyOpenSSH,
            "fingerprint": metadata.fingerprintSHA256,
            "key": keySummaryDict(metadata: metadata, store: store),
            "note": "私钥已导入本机钥匙串（如带加密口令已在导入时解密，口令本身未持久化）。",
        ])
    }

    private static func delete(arguments: [String: Any], store: SettingsStore) throws -> String {
        let allowed: Set<String> = ["key_id"]
        for key in arguments.keys where !allowed.contains(key) {
            throw IOSSSHKeyToolError.invalidArguments("未知参数：\(key)")
        }
        guard let rawId = arguments["key_id"] as? String else {
            throw IOSSSHKeyToolError.invalidArguments("key_id 不能为空。")
        }
        let keyId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyId.isEmpty else {
            throw IOSSSHKeyToolError.invalidArguments("key_id 不能为空。")
        }
        guard let existing = store.sshKeys.first(where: { $0.id == keyId }) else {
            throw IOSSSHRouteError.keyNotFound(keyId: keyId)
        }
        try store.deleteSSHKey(id: keyId)
        return IOSWorkspaceStore.json([
            "ok": true,
            "tool": IOSSSHKeyToolCatalog.deleteToolName,
            "status": "deleted",
            "key_id": existing.id,
            "name": existing.name,
            "fingerprint": existing.fingerprintSHA256,
        ])
    }

    // MARK: - Helpers

    private static func validatedKeyName(_ raw: Any?, store: SettingsStore) throws -> String {
        guard let text = raw as? String else {
            throw IOSSSHKeyToolError.invalidArguments("name 不能为空。")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IOSSSHKeyToolError.invalidArguments("name 不能为空。")
        }
        guard trimmed.count <= 64 else {
            throw IOSSSHKeyToolError.invalidArguments("name 长度不能超过 64 个字符。")
        }
        let clash = store.sshKeys.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !clash else {
            throw IOSSSHKeyToolError.invalidArguments("已存在名为「\(trimmed)」的 SSH 密钥，请换一个名称。")
        }
        return trimmed
    }

    private static func keySummaryDict(
        metadata: IOSSSHKeyMetadata,
        store: SettingsStore
    ) -> [String: Any] {
        let usedBy = store.sshProfiles
            .filter { $0.keyId == metadata.id }
            .map(\.id)
        return [
            "id": metadata.id,
            "name": metadata.name,
            "type": metadata.algorithm,
            "algorithm": metadata.algorithm,
            "public_key": metadata.publicKeyOpenSSH,
            "public_key_openssh": metadata.publicKeyOpenSSH,
            "fingerprint": metadata.fingerprintSHA256,
            "fingerprint_sha256": metadata.fingerprintSHA256,
            "origin": metadata.origin.rawValue,
            "protection": metadata.protection.rawValue,
            "has_passphrase": metadata.hasPassphrase,
            "require_user_presence": metadata.requireUserPresence,
            "created_at": metadata.createdAt,
            "used_by_profile_ids": usedBy,
        ]
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

enum IOSSSHKeyToolError: Error {
    case invalidArguments(String)

    var message: String {
        switch self {
        case .invalidArguments(let text):
            return text
        }
    }

    var status: String {
        switch self {
        case .invalidArguments:
            return "invalid_arguments"
        }
    }

    var extraFields: [String: Any] {
        switch self {
        case .invalidArguments:
            return [:]
        }
    }
}
