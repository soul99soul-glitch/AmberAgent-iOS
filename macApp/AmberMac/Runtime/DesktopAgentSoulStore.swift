import Foundation
import Observation
@preconcurrency import GatewayCore

/// Authoritative macOS C-SOUL-V1 persona store («形象人设»).
///
/// Decouples immutable `<host-core-discipline>` from mutable `<agent-soul>` role persona,
/// maintains an 8-snapshot rollback stack, mirrors one-way to `SOUL.md`, and distinguishes
/// local mutations from remote sync adoption so two-way `/v2/soul` sync never loops.
@MainActor @Observable
final class DesktopAgentSoulStore {
    static let defaultDisplayName = "Amber"
    static let maxHistory = 8
    static let maxDisplayNameChars = 64
    static let maxTaglineChars = 200
    static let maxMarkdownChars = 32_000

    static let immutableHostDisciplinePrompt = """
    <host-core-discipline>
    宿主底层执行守则（系统自动保留，与角色人设互不冲突）：
    - 诚实执行：凡涉及现实操作、外部查询或后台任务，必须依赖真实工具与任务回执，绝不捏造未发生的执行过程或结果。
    - 凭据红线：严禁泄露、复述或回显任何密钥、令牌、密码或隐私凭据。
    - 审批与沙箱边界：遵守工具域隔离；需审批或高风险操作必须等待用户在应用内确认批准。
    </host-core-discipline>
    """

    static let selfUpdateToolGuidance = """
    形象人设自更新规则：
    - 当用户要求更换人设、性格、称呼、角色扮演身份或口吻（或要求恢复默认人设）时，你拥有且必须直接调用 `agent_soul_update` 持久更新全端共享的形象人设（更新前可按需调用 `agent_soul_get` 读取当前设定）。
    - 底层诚实执行守则由系统自动保留，与角色人设调整互不冲突，绝不要声称无法修改 `SOUL.md`。
    """

    private(set) var state: AmberControl.SoulState

    var revision: Int64 { state.revision }
    var updatedAtMs: Int64 { state.updatedAtMs }
    var displayName: String { state.displayName }
    var tagline: String { state.tagline }
    var soulMarkdown: String { state.soulMarkdown }
    var isDefault: Bool { state.isDefault }
    var source: String { state.source }
    var history: [AmberControl.SoulSnapshot] { state.history }

    @ObservationIgnored let directory: URL
    @ObservationIgnored let gatewayRevisionFile: URL?
    @ObservationIgnored weak var knowledge: DesktopKnowledgeStore?
    @ObservationIgnored private let clockMs: () -> Int64
    /// Fired strictly on local mutations (UI, `agent_soul_update`, or local gateway `PUT /v2/soul`),
    /// never on `applyRemote(_:)`.
    @ObservationIgnored var onLocalMutation: ((AmberControl.SoulState) -> Void)?

    private var stateFile: URL { directory.appendingPathComponent("agent_soul.json") }

    init(
        knowledge: DesktopKnowledgeStore? = nil,
        directory: URL? = nil,
        gatewayRevisionFile: URL? = nil,
        clockMs: @escaping () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
    ) {
        let resolvedDirectory = directory ?? knowledge?.directory ?? DesktopKnowledgeStore.defaultDirectory
        self.directory = resolvedDirectory
        self.gatewayRevisionFile = gatewayRevisionFile
        self.knowledge = knowledge
        self.clockMs = clockMs
        self.state = AmberControl.SoulState()
        knowledge?.soulStore = self
        self.state = loadOrInitialize()
    }

    @discardableResult
    func update(
        displayName: String? = nil,
        tagline: String? = nil,
        soulMarkdown: String? = nil,
        source: String = "macos_ui"
    ) throws -> AmberControl.SoulState {
        try put(
            AmberControl.SoulPutRequest(
                displayName: displayName,
                tagline: tagline,
                soulMarkdown: soulMarkdown,
                isDefault: nil,
                source: source
            ),
            emitLocalMutation: true
        )
    }

    @discardableResult
    func resetToDefault(source: String = "macos_ui") throws -> AmberControl.SoulState {
        try put(
            AmberControl.SoulPutRequest(isDefault: true, source: source),
            emitLocalMutation: true
        )
    }

    @discardableResult
    func restore(snapshotID: String, source: String = "macos_rollback") throws -> AmberControl.SoulState {
        guard let snap = state.history.first(where: { $0.id == snapshotID }) else {
            throw DesktopRuntimeError.message("找不到对应的历史形象人设快照。")
        }
        let targetIsDefault = snap.displayName == Self.defaultDisplayName
            && snap.tagline.isEmpty
            && snap.soulMarkdown.isEmpty
        return try put(
            AmberControl.SoulPutRequest(
                displayName: snap.displayName,
                tagline: snap.tagline,
                soulMarkdown: snap.soulMarkdown,
                isDefault: targetIsDefault,
                source: source
            ),
            emitLocalMutation: true
        )
    }

    @discardableResult
    func importMarkdown(from url: URL) throws -> AmberControl.SoulState {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 256_000 else {
            throw DesktopRuntimeError.message("请选择不超过 250 KB 的普通文本文件。")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 256_000, let text = String(data: data, encoding: .utf8) else {
            throw DesktopRuntimeError.message("文件必须是有效 UTF-8 文本。")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DesktopRuntimeError.message("导入的形象人设 Markdown 不能为空。")
        }
        return try update(soulMarkdown: trimmed, source: url.lastPathComponent)
    }

    @discardableResult
    func put(_ request: AmberControl.SoulPutRequest, emitLocalMutation: Bool = true) throws -> AmberControl.SoulState {
        try Self.rejectPlaceholderIfPresent(request.displayName, field: "displayName")
        try Self.rejectPlaceholderIfPresent(request.tagline, field: "tagline")
        try Self.rejectPlaceholderIfPresent(request.soulMarkdown, field: "soulMarkdown")

        let current = state
        let cleanSource = Self.sanitizeSingleLine(request.source, maxChars: 48)
        let resolvedSource = cleanSource.isEmpty ? "macos_manual" : cleanSource
        let resetRequested = request.isDefault == true

        let nextDisplayName: String
        let nextTagline: String
        let nextMarkdown: String
        let nextIsDefault: Bool

        if resetRequested {
            nextDisplayName = Self.defaultDisplayName
            nextTagline = ""
            nextMarkdown = ""
            nextIsDefault = true
        } else {
            let rawName = request.displayName.map { Self.sanitizeSingleLine($0, maxChars: Self.maxDisplayNameChars) }
            nextDisplayName = (rawName?.isEmpty == false ? rawName : nil) ?? current.displayName
            nextTagline = request.tagline.map { Self.sanitizeSingleLine($0, maxChars: Self.maxTaglineChars) } ?? current.tagline
            nextMarkdown = request.soulMarkdown.map { Self.sanitizeMultiline($0, maxChars: Self.maxMarkdownChars) } ?? current.soulMarkdown
            nextIsDefault = request.isDefault
                ?? (nextDisplayName == Self.defaultDisplayName && nextTagline.isEmpty && nextMarkdown.isEmpty)
        }

        let changed = nextDisplayName != current.displayName
            || nextTagline != current.tagline
            || nextMarkdown != current.soulMarkdown
            || nextIsDefault != current.isDefault
        guard changed else { return current }

        let now = clockMs()
        let resolvedUpdatedAt = max(now, max(request.updatedAtMs ?? now, current.updatedAtMs + 1))
        let snapTime = max(0, current.updatedAtMs > 0 ? current.updatedAtMs : resolvedUpdatedAt - 1)
        let snapshot = AmberControl.SoulSnapshot(
            id: Self.uniqueSnapshotID(timestampMs: snapTime, existing: current.history),
            displayName: current.displayName,
            tagline: current.tagline,
            soulMarkdown: current.soulMarkdown,
            updatedAtMs: snapTime,
            source: current.source
        )
        let updated = AmberControl.SoulState(
            revision: current.revision + 1,
            updatedAtMs: resolvedUpdatedAt,
            displayName: nextIsDefault ? Self.defaultDisplayName : nextDisplayName,
            tagline: nextIsDefault ? "" : nextTagline,
            soulMarkdown: nextIsDefault ? "" : nextMarkdown,
            isDefault: nextIsDefault,
            source: resolvedSource,
            history: Array(([snapshot] + current.history).prefix(Self.maxHistory))
        )
        try persist(updated)
        if emitLocalMutation {
            onLocalMutation?(updated)
        }
        return updated
    }

    /// Adopts an authoritative remote C-SOUL-V1 state from `amberd` without triggering outbound push.
    func applyRemote(_ remote: AmberControl.SoulState) {
        guard remote != state else {
            writeGatewayRevision(remote.revision)
            return
        }
        try? persist(remote)
    }

    func systemPromptContext() -> String {
        [
            Self.immutableHostDisciplinePrompt,
            rolePersonaBlock(),
            Self.selfUpdateToolGuidance
        ].joined(separator: "\n\n")
    }

    func rolePersonaBlock() -> String {
        if state.isDefault {
            return """
            <agent-soul is_default="true" revision="\(state.revision)">
            当前形象人设：你是 Amber，主人的跨端个人 AI 智能体与常驻伙伴。保持自然、简洁、可靠、实事求是。
            </agent-soul>
            """
        }
        var lines = [
            #"<agent-soul is_default="false" revision="\#(state.revision)">"#,
            "当前全端共享形象人设（请全程以此身份、称呼与口吻和主人自然交流）：",
            "- 名字/自称：\(state.displayName)"
        ]
        if !state.tagline.isEmpty {
            lines.append("- 一句话签名：\(state.tagline)")
        }
        if !state.soulMarkdown.isEmpty {
            lines.append(state.soulMarkdown)
        }
        lines.append("</agent-soul>")
        return lines.joined(separator: "\n")
    }

    func executeTool(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "agent_soul_get":
            let historyObjects: [[String: Any]] = state.history.map {
                [
                    "id": $0.id,
                    "displayName": $0.displayName,
                    "tagline": $0.tagline,
                    "soulMarkdown": $0.soulMarkdown,
                    "updatedAtMs": $0.updatedAtMs,
                    "source": $0.source
                ]
            }
            return try Self.encodeJSON([
                "ok": true,
                "revision": state.revision,
                "updatedAtMs": state.updatedAtMs,
                "displayName": state.displayName,
                "tagline": state.tagline,
                "soulMarkdown": state.soulMarkdown,
                "isDefault": state.isDefault,
                "source": state.source,
                "history": historyObjects
            ])
        case "agent_soul_update":
            let reset = Self.boolArg(arguments, keys: ["reset_to_default", "resetToDefault"]) ?? false
            let displayName = Self.stringArg(arguments, keys: ["display_name", "displayName"])
            let tagline = Self.stringArg(arguments, keys: ["tagline"])
            let soulMarkdown = Self.stringArg(arguments, keys: ["soul_markdown", "soulMarkdown", "soulPrompt"])
            if !reset && displayName == nil && tagline == nil && soulMarkdown == nil {
                throw DesktopRuntimeError.message("请提供 display_name、tagline、soul_markdown 之一，或设置 reset_to_default=true。")
            }
            let beforeRevision = state.revision
            let updated = try put(
                AmberControl.SoulPutRequest(
                    displayName: displayName,
                    tagline: tagline,
                    soulMarkdown: soulMarkdown,
                    isDefault: reset ? true : nil,
                    source: "macos_chat_self_update"
                ),
                emitLocalMutation: true
            )
            return try Self.encodeJSON([
                "ok": true,
                "changed": updated.revision != beforeRevision,
                "revision": updated.revision,
                "updatedAtMs": updated.updatedAtMs,
                "displayName": updated.displayName,
                "tagline": updated.tagline,
                "soulMarkdown": updated.soulMarkdown,
                "isDefault": updated.isDefault,
                "source": updated.source,
                "note": "形象人设已持久更新，请立即以新的身份与口吻回复主人。"
            ])
        default:
            throw DesktopRuntimeError.message("不支持的形象人设工具：\(name)。")
        }
    }

    // MARK: - Persistence & Helpers

    private func loadOrInitialize() -> AmberControl.SoulState {
        let fm = FileManager.default
        if fm.fileExists(atPath: stateFile.path),
           let data = try? Data(contentsOf: stateFile),
           let decoded = try? JSONDecoder().decode(AmberControl.SoulState.self, from: data) {
            writeGatewayRevision(decoded.revision)
            knowledge?.mirrorFromSoulStore(decoded)
            return decoded
        }
        let legacyRaw = (knowledge?.soulMarkdown ?? (try? String(contentsOf: directory.appendingPathComponent("SOUL.md"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultMirror = Self.renderMirrorMarkdown(AmberControl.SoulState()).trimmingCharacters(in: .whitespacesAndNewlines)
        let initial: AmberControl.SoulState
        if !legacyRaw.isEmpty, legacyRaw != defaultMirror {
            initial = AmberControl.SoulState(
                revision: 1,
                updatedAtMs: clockMs(),
                displayName: Self.defaultDisplayName,
                tagline: "",
                soulMarkdown: Self.sanitizeMultiline(legacyRaw, maxChars: Self.maxMarkdownChars),
                isDefault: false,
                source: "legacy_migration",
                history: []
            )
        } else {
            initial = AmberControl.SoulState()
        }
        try? persist(initial)
        return initial
    }

    private func persist(_ next: AmberControl.SoulState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(next)
        try encoded.write(to: stateFile, options: .atomic)
        state = next
        writeGatewayRevision(next.revision)
        if let knowledge {
            knowledge.mirrorFromSoulStore(next)
        } else {
            let mirror = Self.renderMirrorMarkdown(next)
            try? Data(mirror.utf8).write(to: directory.appendingPathComponent("SOUL.md"), options: .atomic)
        }
    }

    private func writeGatewayRevision(_ revision: Int64) {
        guard let gatewayRevisionFile else { return }
        let fm = FileManager.default
        let dir = gatewayRevisionFile.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? Data("\(revision)\n".utf8).write(to: gatewayRevisionFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: gatewayRevisionFile.path)
    }

    static func renderMirrorMarkdown(_ state: AmberControl.SoulState) -> String {
        if state.isDefault {
            return ""
        }
        var parts: [String] = []
        if state.displayName != defaultDisplayName {
            parts.append("# \(state.displayName)")
        }
        if !state.tagline.isEmpty {
            parts.append("> \(state.tagline)")
        }
        if !state.soulMarkdown.isEmpty {
            parts.append(state.soulMarkdown)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func uniqueSnapshotID(timestampMs: Int64, existing: [AmberControl.SoulSnapshot]) -> String {
        let base = "snap_\(max(0, timestampMs))"
        if !existing.contains(where: { $0.id == base }) { return base }
        var suffix = 2
        while existing.contains(where: { $0.id == "\(base)_\(suffix)" }) { suffix += 1 }
        return "\(base)_\(suffix)"
    }

    private static func rejectPlaceholderIfPresent(_ value: String?, field: String) throws {
        if let value, DesktopHistoryRedaction.isPlaceholderCredential(value) {
            throw DesktopRuntimeError.message("不能将脱敏占位符写入形象人设字段（\(field)）。")
        }
    }

    private static func sanitizeSingleLine(_ raw: String?, maxChars: Int) -> String {
        guard let raw else { return "" }
        let single = raw.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(DesktopHistoryRedaction.redact(single).prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeMultiline(_ raw: String, maxChars: Int) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(DesktopHistoryRedaction.redact(normalized).prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringArg(_ args: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = args[key] as? String { return value }
        }
        return nil
    }

    private static func boolArg(_ args: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = args[key] as? Bool { return value }
        }
        return nil
    }

    private static func encodeJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
