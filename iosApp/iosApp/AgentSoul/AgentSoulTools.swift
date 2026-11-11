import Foundation

/// `agent_soul_get` / `agent_soul_update` 的工具目录。
enum AgentSoulToolCatalog {
    static let getToolName = "agent_soul_get"
    static let updateToolName = "agent_soul_update"

    static let toolNames: Set<String> = [getToolName, updateToolName]
    /// 读工具免审批；更新工具按产品决定免审批直通，便于对话中自然演进人设。
    static let mutatingToolNames: Set<String> = [updateToolName]
}

/// 对话内自塑人设的执行器。
///
/// 产品取舍：`agent_soul_update` 刻意**不**走高风险审批——用户会在对话里直接说
/// 「你给自己写个赵大哥人设吧」，此时弹一次审批会把体验打断。代价是写操作无确认，
/// 因此每次更新都会把旧版压入快照栈，可一键回退。
@MainActor
struct AgentSoulToolService {
    let store: AgentSoulStore

    func execute(toolName: String, arguments: String) -> String {
        let args = ChatToolCallParsing.jsonObject(arguments) ?? [:]
        switch toolName {
        case AgentSoulToolCatalog.getToolName:
            return soulJSON()
        case AgentSoulToolCatalog.updateToolName:
            return update(args)
        default:
            return Self.errorJSON("unknown_tool", "未知的 soul 工具：\(toolName)")
        }
    }

    private func soulJSON() -> String {
        let payload: [String: Any] = [
            "status": "ok",
            "displayName": store.displayName,
            "tagline": store.tagline,
            "soulPrompt": store.soulPrompt,
            "updatedAtMs": store.updatedAtMs,
            "source": store.source.rawValue,
            "isDefault": store.isDefault,
            "snapshotCount": store.snapshots.count,
            "snapshotDigest": store.snapshotDigest,
        ]
        return Self.jsonString(payload)
    }

    private func update(_ args: [String: Any]) -> String {
        let displayName = (args["displayName"] as? String) ?? ""
        let tagline = args["tagline"] as? String
        let soulPrompt = (args["soulPrompt"] as? String) ?? ""
        let summary = args["summary"] as? String

        // 允许只传 soulPrompt：称呼回退到当前值，避免调用方漏参把名字清空。
        let resolvedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.displayName
            : displayName

        guard soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || resolvedName != store.displayName
            || (tagline?.isEmpty == false) else {
            return Self.errorJSON("empty_update", "soulPrompt 与 displayName 不能同时为空。")
        }

        let changed = store.update(
            displayName: resolvedName,
            tagline: tagline ?? store.tagline,
            soulPrompt: soulPrompt.isEmpty ? store.soulPrompt : soulPrompt,
            summary: summary,
            source: .conversation
        )

        let payload: [String: Any] = [
            "status": "ok",
            "changed": changed,
            "displayName": store.displayName,
            "tagline": store.tagline,
            "soulPrompt": store.soulPrompt,
            "snapshotCount": store.snapshots.count,
        ]
        return Self.jsonString(payload)
    }

    // MARK: - JSON

    private static func errorJSON(_ code: String, _ message: String) -> String {
        jsonString(["status": "error", "error_code": code, "message": message])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return #"{"status":"error","error_code":"encoding_failed"}"#
        }
        return text
    }
}

/// 跨「本机对话兜底」与「已配对云主对话（MacGatewayCloudDialogue）」的形象人设同步桥。
///
/// 解决两条断路：
/// 1. 云主对话运行在远端 `amberd`，当远端已更新 `/v2/soul` 时通过 `C-SOUL-V1` 权威拉取；
/// 2. 少数模型或历史已跑偏的会话可能在回复里口头答应“从下一句起按赵匡胤/赵大哥的性子来”，
///    但漏调 `agent_soul_update` 工具（或输出了 `<amber_soul_update>{...}</amber_soul_update>` 指令块）。
@MainActor
enum AgentSoulCloudBridge {
    nonisolated private static let startTag = "<amber_soul_update>"
    nonisolated private static let endTag = "</amber_soul_update>"

    /// 判断用户本轮输入是否在明确要求设置/修改/写入 Agent 的人设（Soul）。
    nonisolated static func isExplicitSoulUpdateRequest(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let lower = normalized.lowercased()

        if lower.contains(startTag) { return true }

        let targetKeywords = ["人设", "soul", "形象人设", "角色设定", "性格设定", "自我设定"]
        let actionKeywords = [
            "换", "改", "弄个", "弄一个", "写个", "写一个", "设定", "变成", "换成",
            "写进", "写入", "存进", "存入", "保存", "更新", "给自己", "当我的", "认了", "就这么来"
        ]
        let hasTarget = targetKeywords.contains { lower.contains($0) }
        let hasAction = actionKeywords.contains { lower.contains($0) }
        if hasTarget && hasAction { return true }

        // 追认场景：用户在建议气泡点按「认，就这么来，性格归性格，底线归底线」
        if normalized.contains("性格归性格") && normalized.contains("底线归底线") {
            return true
        }
        return false
    }

    /// 解析 `<amber_soul_update>{"displayName":...}</amber_soul_update>` 结构化块。
    nonisolated static func extractStructuredDirective(from text: String) -> (cleanedText: String, payload: [String: Any])? {
        guard let startRange = text.range(of: startTag),
              let endRange = text.range(of: endTag, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        let jsonSlice = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = ChatToolCallParsing.jsonObject(jsonSlice) else {
            return nil
        }
        var cleaned = text
        cleaned.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, payload)
    }

    /// 在一轮对话结束（或收到云主对话回复）且尚未通过 `agent_soul_update` 工具落盘时，
    /// 自动将用户要求的人设同步进 `AgentSoulStore`。
    @discardableResult
    static func syncFromTurnIfNeeded(
        userText: String,
        assistantText: String,
        recentConversationContext: String = "",
        store: AgentSoulStore = .shared
    ) -> Bool {
        // 1. 优先识别显式结构化指令块 `<amber_soul_update>{...}</amber_soul_update>`
        for candidate in [assistantText, userText] {
            if let (_, payload) = extractStructuredDirective(from: candidate),
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                let result = AgentSoulToolService(store: store).execute(
                    toolName: AgentSoulToolCatalog.updateToolName,
                    arguments: json
                )
                if result.contains("\"changed\":true") || result.contains("\"status\":\"ok\"") {
                    return true
                }
            }
        }

        // 2. 若用户本轮明确提出改人设/写入 soul（或追认上一轮人设），则从双端文本提取人设并落盘
        guard isExplicitSoulUpdateRequest(userText) else { return false }
        let combinedContext = [recentConversationContext, userText, assistantText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        guard let inferred = inferPersona(userText: userText, assistantText: assistantText, combinedContext: combinedContext, currentStore: store) else {
            return false
        }
        return store.update(
            displayName: inferred.displayName,
            tagline: inferred.tagline,
            soulPrompt: inferred.soulPrompt,
            summary: inferred.summary,
            source: .conversation
        )
    }

    private static func inferPersona(
        userText: String,
        assistantText: String,
        combinedContext: String,
        currentStore: AgentSoulStore
    ) -> (displayName: String, tagline: String, soulPrompt: String, summary: String)? {
        let extractedName = extractDisplayName(from: userText)
            ?? extractDisplayName(from: assistantText)
            ?? extractDisplayName(from: combinedContext)
            ?? currentStore.displayName

        let extractedTagline = extractTagline(from: userText, displayName: extractedName)
            ?? (currentStore.tagline.isEmpty ? "对话自塑专属人设" : currentStore.tagline)

        let cleanedUserRequirement = userText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var promptLines: [String] = []
        if extractedName != AgentSoulStore.defaultDisplayName {
            promptLines.append("你在对话中的自称与身份是「\(extractedName)」。")
        }
        if !extractedTagline.isEmpty {
            promptLines.append("核心气质与定位：\(extractedTagline)。")
        }
        promptLines.append("用户定制人设要求：\(cleanedUserRequirement)")
        if let styleCommitment = extractAssistantStyleCommitment(from: assistantText) {
            promptLines.append("说话风格与相处方式：\(styleCommitment)")
        }

        let soulPrompt = promptLines.joined(separator: "\n")
        guard !soulPrompt.isEmpty else { return nil }
        let summary = extractedName != AgentSoulStore.defaultDisplayName
            ? "对话设定：\(extractedName)"
            : "对话内更新人设"
        return (extractedName, extractedTagline, soulPrompt, summary)
    }

    private static func extractDisplayName(from text: String) -> String? {
        if text.contains("赵大哥") { return "赵大哥" }
        if text.contains("赵匡胤") { return "赵大哥" }

        let patterns = [
            #"自称[「“"']?([^」”"'\s，。！？,!\?]{1,10})[」”"']?"#,
            #"叫自己[「“"']?([^」”"'\s，。！？,!\?]{1,10})[」”"']?"#,
            #"称呼(?:改成|设为|为)[「“"']?([^」”"'\s，。！？,!\?]{1,10})[」”"']?"#,
            #"(?:弄个|弄一个|写个|写一个|换成|变成|设定为|作为)([^，。！？\n]{1,16}?)人设"#,
            #"按([^，。！？\n]{1,10}?)的性子来"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            var candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果包含“的”，取最后一个“的”之后的称呼核心词（如“逗逼一点的赵大哥” -> “赵大哥”）
            if let lastDe = candidate.range(of: "的", options: .backwards) {
                let suffix = String(candidate[lastDe.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    candidate = suffix
                }
            }
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "「」“”\"' "))
            if !candidate.isEmpty, candidate.count <= 12, candidate != "新", candidate != "一个", candidate != "这个" {
                return candidate
            }
        }
        return nil
    }

    private static func extractTagline(from userText: String, displayName: String) -> String? {
        let pattern = #"(?:弄个|弄一个|写个|写一个|换成|变成)([^，。！？\n]{2,24}?)人设"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: userText, range: NSRange(userText.startIndex..., in: userText)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: userText) {
            let desc = String(userText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                return desc
            }
        }
        if userText.contains("赵匡胤") || displayName == "赵大哥" {
            return "豪爽逗趣、重情重义又靠得住的赵大哥"
        }
        return nil
    }

    private static func extractAssistantStyleCommitment(from assistantText: String) -> String? {
        let lines = assistantText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.contains("没法改自己的 SOUL")
                    && !line.contains("去动那份文件")
                    && !line.contains("最后由你按")
            }
        guard let firstGood = lines.first else { return nil }
        return String(firstGood.prefix(180))
    }
}

// MARK: - C-SOUL-V1 (`/v2/soul`) Gateway Client & Store Sync

extension MacGatewayClient {
    /// `GET /v2/soul` — 获取全平台唯一权威人设状态与最近 8 条历史快照。
    func fetchCloudSoul() async throws -> CloudSoulSnapshotPayload {
        try decode(await sendData("GET", "/v2/soul"))
    }

    /// `PUT /v2/soul` — 更新全平台唯一权威人设（自动将旧状态压入服务端 history 栈并递增 revision）。
    func putCloudSoul(_ request: CloudSoulPutRequestPayload) async throws -> CloudSoulSnapshotPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData = try encoder.encode(request)
        return try decode(await sendData("PUT", "/v2/soul", bodyData: bodyData))
    }
}

extension MacGatewayStore {
    /// 绑定本地 `AgentSoulStore` 的主动变更回调，使 iOS 手动编辑、快照回退、恢复默认或本地工具更新自动上云。
    func bindCloudSoulStoreIfNeeded(_ soulStore: AgentSoulStore = .shared) {
        soulStore.localMutationHandler = { [weak self] updatedStore, cloudSource in
            guard let self else { return }
            Task { @MainActor in
                await self.pushCloudSoul(from: updatedStore, source: cloudSource)
            }
        }
    }

    /// 按需同步远端 `/v2/soul`：
    /// - 当 `forcePull == true`（打开「形象人设」面板或首次连接）或 `observedRevision > soulStore.lastSyncedRevision` 时拉取 `GET /v2/soul`。
    /// - 若远端 `revision == 0` 且本地已有非默认自定义人设，自动执行一次 `PUT /v2/soul` 将本地人设上云。
    /// - 若远端返回 404（旧版网关）或网络不可达，静默降级保留本地缓存，不报错、不重试循环。
    @discardableResult
    func syncCloudSoulIfNeeded(
        observedRevision: Int64? = nil,
        forcePull: Bool = false,
        soulStore: AgentSoulStore = .shared
    ) async -> Bool {
        bindCloudSoulStoreIfNeeded(soulStore)
        guard let client else { return false }

        if !forcePull {
            guard let observedRevision else { return false }
            let needsBootstrap = (observedRevision == 0 && !soulStore.isDefault && soulStore.lastSyncedRevision == 0)
            guard observedRevision > soulStore.lastSyncedRevision || needsBootstrap else {
                return false
            }
        }

        do {
            let remote = try await client.fetchCloudSoul()
            guard self.client === client else { return false }
            if remote.revision == 0 {
                if !soulStore.isDefault,
                   !soulStore.soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let bootstrapSource = (soulStore.source == .conversation) ? "chat_self_update" : "ios_ui"
                    return await pushCloudSoul(from: soulStore, source: bootstrapSource)
                }
                return false
            }
            if forcePull || remote.revision > soulStore.lastSyncedRevision {
                return soulStore.applyCloudSoulSnapshot(remote)
            }
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard self.client === client else { return false }
            _ = forgetIfRevoked(error, for: client)
            return false
        }
    }

    /// 将本地 `AgentSoulStore` 状态异步推送至 `PUT /v2/soul`，并用返回的最新权威状态（含新 revision 与 history）更新本地。
    @discardableResult
    func pushCloudSoul(
        from soulStore: AgentSoulStore = .shared,
        source: String = "ios_ui"
    ) async -> Bool {
        guard let client else { return false }
        let request = soulStore.makeCloudPutRequest(source: source)
        do {
            let updated = try await client.putCloudSoul(request)
            guard self.client === client else { return false }
            _ = soulStore.applyCloudSoulSnapshot(updated)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard self.client === client else { return false }
            _ = forgetIfRevoked(error, for: client)
            return false
        }
    }
}
