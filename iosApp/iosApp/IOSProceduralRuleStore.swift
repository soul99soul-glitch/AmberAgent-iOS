import Foundation
import Observation

// MARK: - Procedural Rule Card Models (Stage 3-A / 3-D Contract)

enum IOSProceduralRuleStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case proposed
    case active
    case archived
    case revoked

    var displayTitle: String {
        switch self {
        case .proposed: IOSAppLocalization.string("待确认", defaultValue: "待确认")
        case .active: IOSAppLocalization.string("生效中", defaultValue: "生效中")
        case .archived: IOSAppLocalization.string("已归档", defaultValue: "已归档")
        case .revoked: IOSAppLocalization.string("已撤销", defaultValue: "已撤销")
        }
    }

    var lifecycleStage: Int {
        switch self {
        case .proposed: 0
        case .active: 1
        case .archived, .revoked: 2
        }
    }

    var sortOrder: Int {
        switch self {
        case .proposed: 0
        case .active: 1
        case .archived: 2
        case .revoked: 3
        }
    }
}

struct IOSProceduralRule: Codable, Equatable, Identifiable, Sendable {
    static let scopeGlobal = "global"

    static func isLocalID(_ id: String) -> Bool {
        if id.hasPrefix("local_rule_") { return true }
        // The original iOS generator removed UUID separators. The daemon keeps the first hyphen.
        return id.range(of: #"^rule_[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    var id: String
    var title: String
    var instruction: String
    var scope: String
    var sourceEventId: String
    var status: IOSProceduralRuleStatus
    var hitCount: Int
    var createdAt: Int64
    var updatedAt: Int64

    init(
        id: String,
        title: String,
        instruction: String,
        scope: String = IOSProceduralRule.scopeGlobal,
        sourceEventId: String = "",
        status: IOSProceduralRuleStatus = .proposed,
        hitCount: Int = 0,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.scope = scope
        self.sourceEventId = sourceEventId
        self.status = status
        self.hitCount = hitCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, instruction, scope, sourceEventId, status, hitCount, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        instruction = try container.decode(String.self, forKey: .instruction)
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? Self.scopeGlobal
        sourceEventId = try container.decodeIfPresent(String.self, forKey: .sourceEventId) ?? ""
        status = try container.decodeIfPresent(IOSProceduralRuleStatus.self, forKey: .status) ?? .proposed
        hitCount = try container.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
    }
}

struct IOSProceduralRuleListResponse: Decodable, Equatable, Sendable {
    var rules: [IOSProceduralRule]
    var activeCount: Int
    var proposedCount: Int
}

struct IOSProceduralRuleResponse: Decodable, Equatable, Sendable {
    var rule: IOSProceduralRule
    var deduplicated: Bool?
}

struct IOSProceduralRuleRedirectResponse: Decodable, Equatable, Sendable {
    var error: String?
    var redirectToSoul: Bool?
    var target: String?
    var message: String?
}

enum IOSRuleProposalOutcome: Equatable, Sendable {
    case proposed(IOSProceduralRule, deduplicated: Bool)
    case redirectToSoul(target: String, message: String)
    case rejected(code: String, message: String)
}

enum IOSProceduralRuleStoreError: LocalizedError, Equatable, Sendable {
    case ruleNotFound
    case invalidStateTransition(String)
    case riskTableImmutable(String)

    var errorDescription: String? {
        switch self {
        case .ruleNotFound:
            return IOSAppLocalization.string("规则卡不存在", defaultValue: "规则卡不存在")
        case .invalidStateTransition(let message), .riskTableImmutable(let message):
            return message
        }
    }
}

// MARK: - Gateway Sync Transport

protocol IOSProceduralRulesSyncing: Sendable {
    func fetchProceduralRules(status: IOSProceduralRuleStatus?, scope: String?) async throws -> [IOSProceduralRule]
    func proposeProceduralRule(
        title: String?,
        instruction: String,
        scope: String,
        sourceEventId: String
    ) async throws -> IOSRuleProposalOutcome
    func confirmProceduralRule(id: String) async throws -> IOSProceduralRule
    func archiveProceduralRule(id: String) async throws -> IOSProceduralRule
    func revokeProceduralRule(id: String) async throws -> IOSProceduralRule
}

extension IOSProceduralRulesSyncing {
    func fetchProceduralRules() async throws -> [IOSProceduralRule] {
        try await fetchProceduralRules(status: nil, scope: nil)
    }
}

extension MacGatewayClient: IOSProceduralRulesSyncing {
    func fetchProceduralRules(status: IOSProceduralRuleStatus? = nil, scope: String? = nil) async throws -> [IOSProceduralRule] {
        var queryItems: [URLQueryItem] = []
        if let status {
            queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
        }
        if let scope, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: scope))
        }
        var path = "/v2/rules"
        if !queryItems.isEmpty {
            var components = URLComponents()
            components.queryItems = queryItems
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?\(query)"
            }
        }
        let data = try await send("GET", path)
        let decoded: IOSProceduralRuleListResponse = try decode(data)
        return decoded.rules
    }

    func proposeProceduralRule(
        title: String?,
        instruction: String,
        scope: String,
        sourceEventId: String = ""
    ) async throws -> IOSRuleProposalOutcome {
        var body: [String: Any] = [
            "instruction": instruction,
            "scope": scope,
        ]
        if let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedTitle.isEmpty {
            body["title"] = trimmedTitle
        }
        if !sourceEventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["sourceEventId"] = sourceEventId
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var response = try await requestData("POST", "/v2/rules/propose", bodyData: bodyData)
        if response.status == 404 {
            response = try await requestData("POST", "/v2/rules", bodyData: bodyData)
        }
        switch response.status {
        case 200, 201:
            let decoded: IOSProceduralRuleResponse = try decode(response.data)
            return .proposed(decoded.rule, deduplicated: decoded.deduplicated ?? false)
        case 422:
            if let redirect = try? JSONDecoder().decode(IOSProceduralRuleRedirectResponse.self, from: response.data) {
                if redirect.redirectToSoul == true || redirect.target == "C-SOUL-V1" {
                    let message = redirect.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .redirectToSoul(
                        target: redirect.target ?? "C-SOUL-V1",
                        message: (message?.isEmpty == false)
                            ? message!
                            : IOSAppLocalization.string(
                                "该内容属于形象人设或说话口吻，请前往「形象人设」编辑。",
                                defaultValue: "该内容属于形象人设或说话口吻，请前往「形象人设」编辑。"
                            )
                    )
                }
                let code = redirect.error ?? "rule_rejected"
                let fallback: String = (code == "risk_table_immutable")
                    ? IOSAppLocalization.string(
                        "静态风险表（L1–L3）不可被规则卡放宽或绕过。",
                        defaultValue: "静态风险表（L1–L3）不可被规则卡放宽或绕过。"
                    )
                    : IOSAppLocalization.string("规则提议被拒绝", defaultValue: "规则提议被拒绝")
                let message = redirect.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .rejected(code: code, message: (message?.isEmpty == false) ? message! : fallback)
            }
            return .rejected(code: "rule_rejected", message: IOSAppLocalization.string("规则提议被拒绝", defaultValue: "规则提议被拒绝"))
        case 401:
            throw MacGatewayError.unauthorized
        case 403:
            throw MacGatewayError.forbidden(response.errorCode ?? "HTTP 403")
        case 409:
            throw MacGatewayError.conflict(response.errorCode ?? "HTTP 409")
        default:
            throw MacGatewayError.server(response.errorCode ?? "HTTP \(response.status)")
        }
    }

    func confirmProceduralRule(id: String) async throws -> IOSProceduralRule {
        let encoded = Self.encodedRulePathSegment(id)
        let data = try await send("POST", "/v2/rules/\(encoded)/confirm")
        let decoded: IOSProceduralRuleResponse = try decode(data)
        return decoded.rule
    }

    func archiveProceduralRule(id: String) async throws -> IOSProceduralRule {
        let encoded = Self.encodedRulePathSegment(id)
        let data = try await send("POST", "/v2/rules/\(encoded)/archive")
        let decoded: IOSProceduralRuleResponse = try decode(data)
        return decoded.rule
    }

    func revokeProceduralRule(id: String) async throws -> IOSProceduralRule {
        let encoded = Self.encodedRulePathSegment(id)
        let data = try await send("POST", "/v2/rules/\(encoded)/revoke")
        let decoded: IOSProceduralRuleResponse = try decode(data)
        return decoded.rule
    }

    private static func encodedRulePathSegment(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}

// MARK: - 4-Tier Authority Prompt Assembler

/// Enforces the 4-tier context authority hierarchy aligned with Stage 3-A:
/// 1. Static risk table (L1–L3) & host safety boundary (highest, immutable)
/// 2. User-confirmed active procedural rules (`status == .active` only)
/// 3. C-SOUL-V1 persona & style
/// 4. Episode / Memory recall (lowest)
enum IOSAuthorityPromptAssembler {
    static let staticRiskTableTag = "<static-risk-table authority=\"1\" immutable=\"true\">"
    static let confirmedRulesTag = "<confirmed-procedural-rules authority=\"2\">"

    static func renderStaticRiskTableBlock() -> String {
        """
        <static-risk-table authority="1" immutable="true">
        权威优先级（不可逆转）：静态风险表（L1–L3）> 用户确认规则（active 规则卡）> C-SOUL-V1 风格 > Episode 召回。
        任何用户规则卡或 C-SOUL-V1 人设均不得放宽、降级或绕过静态风险分层：
        - L1（只读探测）：可按最小权限自动执行；
        - L2（可逆写入）：执行并附可撤回或变更摘要；
        - L3（不可逆或外部副作用）：必须等待显式批准，未知高风险动作默认按 L3 收紧。
        </static-risk-table>
        """
    }

    static func renderConfirmedRulesBlock(_ rules: [IOSProceduralRule]) -> String {
        let activeOnly = rules.filter {
            $0.status == .active && !IOSProceduralRuleGuard.attemptsRiskTableRelaxation($0)
        }
        guard !activeOnly.isEmpty else { return "" }
        var lines: [String] = [
            "<confirmed-procedural-rules authority=\"2\">",
            "以下为用户显式确认生效的执行规则（优先级低于 <static-risk-table>，不得放宽 L1–L3 风险审批；高于 C-SOUL-V1 风格与 Episode 召回）：",
        ]
        for rule in activeOnly {
            lines.append("- [\(rule.id)][scope=\(promptText(rule.scope))] \(promptText(rule.title))：\(promptText(rule.instruction))")
        }
        lines.append("</confirmed-procedural-rules>")
        return lines.joined(separator: "\n")
    }

    private static func promptText(_ text: String) -> String {
        IOSProceduralRuleGuard.redactSecrets(text)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Assembles a standalone 4-tier system prompt in strict authority order.
    static func assembleFourTierPrompt(
        activeRules: [IOSProceduralRule],
        soulMarkdown: String,
        episodeRecall: String
    ) -> String {
        var sections: [String] = [renderStaticRiskTableBlock()]
        let rulesBlock = renderConfirmedRulesBlock(activeRules)
        if !rulesBlock.isEmpty {
            sections.append(rulesBlock)
        }
        let trimmedSoul = soulMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSoul.isEmpty {
            sections.append(trimmedSoul)
        }
        let trimmedRecall = episodeRecall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRecall.isEmpty {
            sections.append(trimmedRecall)
        }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Guardrails (Aligned with Stage 3-A ProceduralRuleStore.kt)

enum IOSProceduralRuleGuard {
    static let maxTitleChars = 80
    static let maxInstructionChars = 1_000
    static let maxScopeChars = 141
    static let maxEventIdChars = 128

    private static let riskRelaxationPatterns: [NSRegularExpression] = compile([
        #"(跳过|忽略|取消|关闭|绕过|无需|不用|不需要).{0,10}(审批|确认|高风险|风险表|L3)"#,
        #"(自动批准|自动同意|直接放行|静默执行).{0,12}(L3|高风险|不可逆|删除|命令|外部发送)"#,
        #"(放宽|降低|覆盖|忽略).{0,8}(静态)?风险表"#,
        #"(skip|bypass|disable|ignore|relax|override).{0,16}(approval|confirm|risk\s*table|l3|high[\s-]*risk)"#,
        #"auto[\s-]*approve.{0,12}(l3|high[\s-]*risk|destructive|irreversible)"#,
    ])

    private static let prohibitedAction = try! NSRegularExpression(
        pattern: #"(不要|不准|禁止|不得|不能|不可|切勿|严禁|不允许|never|do not|must not|don't)(?:再|擅自|\s+ever)?\s*$"#,
        options: .caseInsensitive
    )
    private static let autoApproval = try! NSRegularExpression(
        pattern: #"(自动批准|自动同意|直接放行|auto[ -]?approve)"#, options: .caseInsensitive
    )
    private static let precedingHighRisk = try! NSRegularExpression(
        pattern: #"(L3|高风险|不可逆|high[ -]risk)[^。！？.!?；;，,\n]{0,18}$"#, options: .caseInsensitive
    )

    private static let personaSignalPatterns: [NSRegularExpression] = compile([
        #"(人设|性格|口吻|语气|声线|画风|角色扮演|扮演|自称|称呼|叫我|喊我)"#,
        #"(温柔|傲娇|幽默|毒舌|高冷|活泼|俏皮|可爱|搞笑|热情|冷淡|二次元|霸总|管家|猫娘|兄弟口吻)"#,
        #"\b(persona|personality|tone\s+of\s+voice|roleplay|act\s+like|call\s+me|speak\s+like|sound\s+more)\b"#,
    ])

    private static let executionActionPatterns: [NSRegularExpression] = compile([
        #"(提交|推送|git|commit|push|merge|分支|代码|单测|测试|构建|编译|部署|发布|文件|路径|目录|命令|脚本|格式|markdown|json|表格|语言|中文|英文|日志|备份|删除|修改|创建|发送|邮件|日历|日程|报告|总结|输出|附带|先.*再)"#,
        #"\b(git|commit|push|test|build|deploy|file|directory|command|script|json|markdown|table|format|output|include|avoid|never\s+run|always\s+run|before\s+editing)\b"#,
    ])

    private static let secretPatterns: [NSRegularExpression] = compile([
        #"sk-[A-Za-z0-9_-]{12,}"#,
        #"AIza[0-9A-Za-z_-]{20,}"#,
        #"ghp_[A-Za-z0-9]{20,}"#,
        #"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
    ])

    private static let placeholderCredentialPatterns: [NSRegularExpression] = compile([
        #"\b(your[_-]?api[_-]?key|replace[_-]?me|sk-xxx+|sk-placeholder|changeme)\b"#,
        #"\$\{[A-Z0-9_]{3,}\}"#,
    ])

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static func matchesAny(_ patterns: [NSRegularExpression], in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    static func attemptsRiskTableRelaxation(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        func matchesApproval(_ pattern: NSRegularExpression, requiresHighRiskPrefix: Bool) -> Bool {
            pattern.matches(in: text, range: range).contains { match in
                let prefix = NSRange(location: 0, length: match.range.location)
                guard prohibitedAction.firstMatch(in: text, range: prefix) == nil else { return false }
                return !requiresHighRiskPrefix || precedingHighRisk.firstMatch(in: text, range: prefix) != nil
            }
        }
        return riskRelaxationPatterns.contains { matchesApproval($0, requiresHighRiskPrefix: false) }
            || matchesApproval(autoApproval, requiresHighRiskPrefix: true)
    }

    static func attemptsRiskTableRelaxation(_ rule: IOSProceduralRule) -> Bool {
        attemptsRiskTableRelaxation(rule.title) || attemptsRiskTableRelaxation(rule.instruction)
    }

    static func isPurePersonaDescription(_ text: String) -> Bool {
        guard matchesAny(personaSignalPatterns, in: text) else { return false }
        return !matchesAny(executionActionPatterns, in: text)
    }

    static func isPlaceholderCredential(_ text: String) -> Bool {
        matchesAny(placeholderCredentialPatterns, in: text)
    }

    static func redactSecrets(_ text: String) -> String {
        var result = text
        for regex in secretPatterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED]")
        }
        return result
    }

    static func normalizeScope(_ raw: String?) -> String {
        let cleaned = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.caseInsensitiveCompare(IOSProceduralRule.scopeGlobal) == .orderedSame {
            return IOSProceduralRule.scopeGlobal
        }
        return cleaned
    }

    static func matchesScope(_ ruleScope: String, conversationId: String?, projectId: String?) -> Bool {
        if ruleScope.caseInsensitiveCompare(IOSProceduralRule.scopeGlobal) == .orderedSame {
            return true
        }
        if let conv = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines), !conv.isEmpty {
            if ruleScope == conv || ruleScope == "conversation:\(conv)" {
                return true
            }
        }
        if let proj = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !proj.isEmpty {
            if ruleScope == proj || ruleScope == "project:\(proj)" {
                return true
            }
        }
        return false
    }

    static func sanitizeSingleLine(_ raw: String?, maxChars: Int) -> String {
        guard let raw else { return "" }
        let single = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(redactSecrets(single).prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeMultiline(_ raw: String, maxChars: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(redactSecrets(trimmed).prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deriveTitle(from instruction: String) -> String {
        let firstLine = instruction.split(whereSeparator: \.isNewline).first.map(String.init) ?? instruction
        let trimSet = CharacterSet(charactersIn: "。.!！;； ")
        let cleaned = firstLine.trimmingCharacters(in: trimSet)
        if cleaned.count <= 28 {
            return cleaned
        }
        return String(cleaned.prefix(27)) + "…"
    }
}

// MARK: - Durable iOS Procedural Rule Store

/// Local + paired-gateway durable store for "correction -> procedural rule card" memory.
///
/// Invariants:
/// - New proposals ALWAYS enter `.proposed` and require explicit user confirmation to become `.active`.
/// - Archived/revoked rules are immediately excluded from injection on the next turn (100% excluded).
/// - Active rules injected into prompts increment `hitCount` and persist atomically.
/// - SwiftUI views only read in-memory `@Observable` properties; zero disk IO inside `body`.
@MainActor
@Observable
final class IOSProceduralRuleStore {
    static let shared = IOSProceduralRuleStore()

    private(set) var rules: [IOSProceduralRule] = []
    private(set) var isSyncing = false
    private(set) var lastSyncError: String?

    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private let clockMs: @Sendable () -> Int64
    @ObservationIgnored private static let persistenceQueue = DispatchQueue(
        label: "app.amber.ios.proceduralRules.persistence",
        qos: .utility
    )

    init(
        storageURL: URL? = IOSProceduralRuleStore.defaultStorageURL(),
        clockMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.storageURL = storageURL
        self.clockMs = clockMs
        self.rules = Self.loadFromDisk(storageURL)
    }

    var proposedRules: [IOSProceduralRule] {
        rules.filter { $0.status == .proposed }
    }

    var activeRules: [IOSProceduralRule] {
        rules.filter { $0.status == .active }
    }

    var archivedOrRevokedRules: [IOSProceduralRule] {
        rules.filter { $0.status == .archived || $0.status == .revoked }
    }

    var activeCount: Int { activeRules.count }
    var proposedCount: Int { proposedRules.count }

    // MARK: - Local Mutations

    @discardableResult
    func proposeLocal(
        title: String? = nil,
        instruction: String,
        scope: String? = nil,
        sourceEventId: String = ""
    ) -> IOSRuleProposalOutcome {
        if IOSProceduralRuleGuard.isPlaceholderCredential(instruction) ||
            (title.map(IOSProceduralRuleGuard.isPlaceholderCredential) ?? false) {
            return .rejected(
                code: "placeholder_credential_rejected",
                message: IOSAppLocalization.string("拒绝将占位符凭据写入规则卡", defaultValue: "拒绝将占位符凭据写入规则卡")
            )
        }

        let cleanInstruction = IOSProceduralRuleGuard.sanitizeMultiline(
            instruction,
            maxChars: IOSProceduralRuleGuard.maxInstructionChars
        )
        if cleanInstruction.isEmpty {
            return .rejected(
                code: "empty_instruction",
                message: IOSAppLocalization.string("规则内容不能为空", defaultValue: "规则内容不能为空")
            )
        }

        if IOSProceduralRuleGuard.attemptsRiskTableRelaxation(title ?? "") ||
            IOSProceduralRuleGuard.attemptsRiskTableRelaxation(cleanInstruction) {
            return .rejected(
                code: "risk_table_immutable",
                message: IOSAppLocalization.string(
                    "静态风险表（L1–L3）由系统强制保留，规则卡不得放宽审批或绕过高风险确认。",
                    defaultValue: "静态风险表（L1–L3）由系统强制保留，规则卡不得放宽审批或绕过高风险确认。"
                )
            )
        }

        if IOSProceduralRuleGuard.isPurePersonaDescription(cleanInstruction) {
            return .redirectToSoul(
                target: "C-SOUL-V1",
                message: IOSAppLocalization.string(
                    "该内容属于形象人设、称呼或说话口吻设定，请前往「形象人设 (C-SOUL-V1)」编辑，不混入执行规则卡。",
                    defaultValue: "该内容属于形象人设、称呼或说话口吻设定，请前往「形象人设 (C-SOUL-V1)」编辑，不混入执行规则卡。"
                )
            )
        }

        let resolvedScope = IOSProceduralRuleGuard.normalizeScope(scope)
        guard resolvedScope.utf16.count <= IOSProceduralRuleGuard.maxScopeChars,
              !resolvedScope.unicodeScalars.contains(where: { $0.value <= 31 || (127...159).contains($0.value) }) else {
            return .rejected(code: "invalid_scope", message: IOSAppLocalization.string(
                "作用域不可包含控制字符或超过 141 个字符", defaultValue: "作用域不可包含控制字符或超过 141 个字符"
            ))
        }
        let sanitizedTitle = IOSProceduralRuleGuard.sanitizeSingleLine(title, maxChars: IOSProceduralRuleGuard.maxTitleChars)
        let cleanTitle = sanitizedTitle.isEmpty ? IOSProceduralRuleGuard.deriveTitle(from: cleanInstruction) : sanitizedTitle
        let cleanSourceEventId = IOSProceduralRuleGuard.sanitizeSingleLine(
            sourceEventId,
            maxChars: IOSProceduralRuleGuard.maxEventIdChars
        )

        if let existing = rules.first(where: {
            ($0.status == .proposed || $0.status == .active) &&
                IOSProceduralRuleGuard.normalizeScope($0.scope) == resolvedScope &&
                $0.instruction.caseInsensitiveCompare(cleanInstruction) == .orderedSame
        }) {
            return .proposed(existing, deduplicated: true)
        }

        let now = clockMs()
        let record = IOSProceduralRule(
            id: "local_rule_\(UUID().uuidString.lowercased())",
            title: cleanTitle,
            instruction: cleanInstruction,
            scope: resolvedScope,
            sourceEventId: cleanSourceEventId,
            status: .proposed,
            hitCount: 0,
            createdAt: now,
            updatedAt: now
        )
        var next = rules
        next.append(record)
        commit(next)
        return .proposed(record, deduplicated: false)
    }

    @discardableResult
    func confirmLocal(id: String) throws -> IOSProceduralRule {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else {
            throw IOSProceduralRuleStoreError.ruleNotFound
        }
        let target = rules[idx]
        if target.status == .archived || target.status == .revoked {
            throw IOSProceduralRuleStoreError.invalidStateTransition(
                IOSAppLocalization.string("已归档或已撤销的规则卡不可直接重新生效，请重新提议。", defaultValue: "已归档或已撤销的规则卡不可直接重新生效，请重新提议。")
            )
        }
        if IOSProceduralRuleGuard.attemptsRiskTableRelaxation(target) {
            throw IOSProceduralRuleStoreError.riskTableImmutable(
                IOSAppLocalization.string("静态风险表（L1–L3）不可被规则卡放宽。", defaultValue: "静态风险表（L1–L3）不可被规则卡放宽。")
            )
        }
        if target.status == .active {
            return target
        }
        var updated = target
        updated.status = .active
        updated.updatedAt = max(clockMs(), target.updatedAt + 1)
        var next = rules
        next[idx] = updated
        commit(next)
        return updated
    }

    @discardableResult
    func archiveLocal(id: String) throws -> IOSProceduralRule {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else {
            throw IOSProceduralRuleStoreError.ruleNotFound
        }
        let target = rules[idx]
        if target.status == .archived {
            return target
        }
        var updated = target
        updated.status = .archived
        updated.updatedAt = max(clockMs(), target.updatedAt + 1)
        var next = rules
        next[idx] = updated
        commit(next)
        return updated
    }

    @discardableResult
    func revokeLocal(id: String) throws -> IOSProceduralRule {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else {
            throw IOSProceduralRuleStoreError.ruleNotFound
        }
        let target = rules[idx]
        if target.status == .revoked {
            return target
        }
        var updated = target
        updated.status = .revoked
        updated.updatedAt = max(clockMs(), target.updatedAt + 1)
        var next = rules
        next[idx] = updated
        commit(next)
        return updated
    }

    // MARK: - Gateway-Synced Operations

    func syncFromGateway(syncClient: (any IOSProceduralRulesSyncing)?) async {
        guard let syncClient, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote = try await syncClient.fetchProceduralRules()
            mergeRemoteRules(remote)
            lastSyncError = nil
        } catch is CancellationError {
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    @discardableResult
    func propose(
        title: String? = nil,
        instruction: String,
        scope: String = IOSProceduralRule.scopeGlobal,
        sourceEventId: String = "",
        syncClient: (any IOSProceduralRulesSyncing)? = nil
    ) async -> IOSRuleProposalOutcome {
        let resolvedScope = IOSProceduralRuleGuard.normalizeScope(scope)
        if let syncClient {
            do {
                let outcome = try await syncClient.proposeProceduralRule(
                    title: title,
                    instruction: instruction,
                    scope: resolvedScope,
                    sourceEventId: sourceEventId
                )
                lastSyncError = nil
                if case .proposed(let rule, _) = outcome {
                    upsertRule(rule)
                }
                return outcome
            } catch MacGatewayError.unreachable {
                lastSyncError = MacGatewayError.unreachable.localizedDescription
            } catch {
                lastSyncError = error.localizedDescription
                return .rejected(code: "gateway_request_failed", message: error.localizedDescription)
            }
        }
        return proposeLocal(title: title, instruction: instruction, scope: resolvedScope, sourceEventId: sourceEventId)
    }

    @discardableResult
    func confirm(
        id: String,
        syncClient: (any IOSProceduralRulesSyncing)? = nil
    ) async throws -> IOSProceduralRule {
        guard let syncClient, !IOSProceduralRule.isLocalID(id) else {
            return try confirmLocal(id: id)
        }
        do {
            let confirmed = try await syncClient.confirmProceduralRule(id: id)
            lastSyncError = nil
            return upsertRule(confirmed)
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func archive(
        id: String,
        syncClient: (any IOSProceduralRulesSyncing)? = nil
    ) async throws -> IOSProceduralRule {
        guard let syncClient, !IOSProceduralRule.isLocalID(id) else {
            return try archiveLocal(id: id)
        }
        do {
            let archived = try await syncClient.archiveProceduralRule(id: id)
            lastSyncError = nil
            return upsertRule(archived)
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func revoke(
        id: String,
        syncClient: (any IOSProceduralRulesSyncing)? = nil
    ) async throws -> IOSProceduralRule {
        guard let syncClient, !IOSProceduralRule.isLocalID(id) else {
            return try revokeLocal(id: id)
        }
        do {
            let revoked = try await syncClient.revokeProceduralRule(id: id)
            lastSyncError = nil
            return upsertRule(revoked)
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Prompt Injection Selection & Hit Counting

    /// Selects ONLY `.active` rules matching `global` or the given conversation/project scope.
    /// Proposed, archived, and revoked rules are 100% excluded.
    /// Increments `hitCount` and persists atomically when `recordHit == true`.
    func selectActiveForInjection(
        conversationId: String? = nil,
        projectId: String? = nil,
        recordHit: Bool = true
    ) -> [IOSProceduralRule] {
        let matched = rules
            .filter { $0.status == .active }
            .filter { !IOSProceduralRuleGuard.attemptsRiskTableRelaxation($0) }
            .filter { IOSProceduralRuleGuard.matchesScope($0.scope, conversationId: conversationId, projectId: projectId) }
            .sorted { lhs, rhs in
                let lhsGlobal = lhs.scope.caseInsensitiveCompare(IOSProceduralRule.scopeGlobal) == .orderedSame
                let rhsGlobal = rhs.scope.caseInsensitiveCompare(IOSProceduralRule.scopeGlobal) == .orderedSame
                if lhsGlobal != rhsGlobal { return lhsGlobal }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }

        guard !matched.isEmpty else { return [] }
        guard recordHit else { return matched }

        let matchedIds = Set(matched.map(\.id))
        let now = clockMs()
        var next = rules
        for index in next.indices where matchedIds.contains(next[index].id) {
            next[index].hitCount += 1
            next[index].updatedAt = max(now, next[index].updatedAt)
        }
        commit(next)

        let byId = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        return matched.compactMap { byId[$0.id] }
    }

    // MARK: - Bootstrap & Remote Merge

    /// Imports active rule snapshots returned during single-scan pairing bootstrap.
    /// Only accepts `.active` rules that do not attempt to relax the L1-L3 risk table.
    @discardableResult
    func applyBootstrapActiveRules(_ snapshotRules: [IOSProceduralRule]) -> Int {
        let validActive = snapshotRules.filter {
            $0.status == .active && !IOSProceduralRuleGuard.attemptsRiskTableRelaxation($0)
        }
        guard !validActive.isEmpty else { return 0 }
        var byId = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var importedCount = 0
        for remote in validActive {
            if let existing = byId[remote.id] {
                let merged = Self.merging(remote, into: existing)
                guard merged.status == .active else { continue }
                byId[remote.id] = merged
            } else {
                byId[remote.id] = remote
            }
            importedCount += 1
        }
        commit(Array(byId.values))
        return importedCount
    }

    func mergeRemoteRules(_ remoteRules: [IOSProceduralRule]) {
        var byId = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        for remote in remoteRules {
            if let local = byId[remote.id] {
                byId[remote.id] = Self.merging(remote, into: local)
            } else {
                byId[remote.id] = remote
            }
        }
        commit(Array(byId.values))
    }

    func replaceAllForTesting(_ newRules: [IOSProceduralRule]) {
        commit(newRules)
    }

    // MARK: - Persistence Helpers

    @discardableResult
    private func upsertRule(_ rule: IOSProceduralRule) -> IOSProceduralRule {
        var next = rules
        if let idx = next.firstIndex(where: { $0.id == rule.id }) {
            let merged = Self.merging(rule, into: next[idx])
            next[idx] = merged
            commit(next)
            return merged
        }
        next.append(rule)
        commit(next)
        return rule
    }

    private static func merging(_ incoming: IOSProceduralRule, into current: IOSProceduralRule) -> IOSProceduralRule {
        // Confirmation and retirement are one-way. Hit timestamps can come from either device's clock.
        let retainCurrent = current.status.lifecycleStage == incoming.status.lifecycleStage
            ? current.updatedAt > incoming.updatedAt
            : current.status.lifecycleStage > incoming.status.lifecycleStage
        var result = retainCurrent ? current : incoming
        result.hitCount = max(current.hitCount, incoming.hitCount)
        return result
    }

    private func commit(_ candidate: [IOSProceduralRule]) {
        let sorted = Self.sortedRules(candidate)
        guard sorted != rules else { return }
        rules = sorted
        persist(sorted)
    }

    private static func sortedRules(_ items: [IOSProceduralRule]) -> [IOSProceduralRule] {
        items.sorted { lhs, rhs in
            if lhs.status.sortOrder != rhs.status.sortOrder {
                return lhs.status.sortOrder < rhs.status.sortOrder
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func persist(_ snapshot: [IOSProceduralRule]) {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        Self.persistenceQueue.async {
            Self.atomicWrite(data: data, to: storageURL)
        }
    }

    /// Synchronous flush helper for tests verifying on-disk durability.
    func flushPersistenceForTesting() {
        Self.persistenceQueue.sync {}
    }

    private nonisolated static func atomicWrite(data: Data, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private static func loadFromDisk(_ url: URL?) -> [IOSProceduralRule] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([IOSProceduralRule].self, from: data) else {
            return []
        }
        return sortedRules(decoded)
    }

    private static func defaultStorageURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AmberAgent", isDirectory: true)
            .appendingPathComponent("procedural-rules.v1.json", isDirectory: false)
    }
}
