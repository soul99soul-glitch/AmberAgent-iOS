import SwiftUI
@preconcurrency import Shared

enum CouncilRuntimeSheet: Identifiable {
    case detail(CouncilDiscussionDetail)
    case members
    case settings
    case history

    var id: String {
        switch self {
        case .detail(let detail): "detail-\(detail.id)"
        case .members: "members"
        case .settings: "settings"
        case .history: "history"
        }
    }
}

struct CouncilHomeResumeContext: Equatable {
    let id: String
    let title: String
    let status: IOSAdvancedTaskStatus
    let updatedAt: Date
    let canContinue: Bool
}


enum CouncilDiscussionMode: String, CaseIterable, Identifiable {
    case freeChat = "free_chat"
    case debate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeChat: "自由群聊"
        case .debate: "辩论"
        }
    }

    var localizedTitle: String {
        IOSAppLocalization.string(title, defaultValue: title)
    }

    var accessibilityLabel: String {
        switch self {
        case .freeChat: "自由群聊模式"
        case .debate: "辩论模式"
        }
    }

    var localizedAccessibilityLabel: String {
        IOSAppLocalization.string(accessibilityLabel, defaultValue: accessibilityLabel)
    }

    var intent: String {
        switch self {
        case .freeChat: "扩展信息面、发现选项、形成早期方向"
        case .debate: "挑战假设、发现盲区、降低决策风险"
        }
    }

    var localizedIntent: String {
        IOSAppLocalization.string(intent, defaultValue: intent)
    }

    var runningState: String {
        switch self {
        case .freeChat: "群聊中"
        case .debate: "辩论中"
        }
    }

    var localizedRunningState: String {
        IOSAppLocalization.string(runningState, defaultValue: runningState)
    }

    var openingDivider: String {
        switch self {
        case .freeChat: "自由群聊 · 开场"
        case .debate: "辩论 · 交叉回应"
        }
    }

    var localizedOpeningDivider: String {
        IOSAppLocalization.string(openingDivider, defaultValue: openingDivider)
    }

    var systemImage: String {
        switch self {
        case .freeChat: "bubble.left.and.bubble.right"
        case .debate: "scale.3d"
        }
    }

    var tint: Color {
        switch self {
        case .freeChat: AmberTheme.accentCyan
        case .debate: AmberTheme.accentRed
        }
    }

    var runMode: IOSCouncilRoomRunMode {
        switch self {
        case .freeChat: .freeChat
        case .debate: .debate
        }
    }
}

struct CouncilParticipant: Identifiable {
    let id: String
    let handle: String
    let displayName: String
    let roleDescription: String
    let shortLens: String
    let systemImage: String
    let tint: Color
    let isHost: Bool
    let modelHint: String
    let modelId: String?
    let providerId: String?

    init(
        id: String,
        handle: String,
        displayName: String,
        roleDescription: String,
        shortLens: String,
        systemImage: String,
        tint: Color,
        isHost: Bool,
        modelHint: String,
        modelId: String? = nil,
        providerId: String? = nil
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.roleDescription = roleDescription
        self.shortLens = shortLens
        self.systemImage = systemImage
        self.tint = tint
        self.isHost = isHost
        self.modelHint = modelHint
        self.modelId = modelId?.trimmedNilIfBlank
        self.providerId = providerId?.trimmedNilIfBlank
    }

    init(speaker: IOSCouncilRoomSpeaker) {
        self.init(
            id: speaker.id,
            handle: Self.makeHandle(from: speaker.name, fallback: speaker.isHost ? "host" : speaker.id),
            displayName: speaker.isHost ? "Host · \(speaker.modelId)" : speaker.name,
            roleDescription: speaker.rolePrompt,
            shortLens: speaker.shortLens,
            systemImage: speaker.isHost ? "crown" : Self.icon(for: speaker.id),
            tint: speaker.isHost ? AmberTheme.accent : Self.tint(for: speaker.id),
            isHost: speaker.isHost,
            modelHint: speaker.modelId,
            modelId: speaker.modelId,
            providerId: speaker.providerId
        )
    }

    var displayNameForDisplay: String {
        CouncilDisplayCopy.participantName(self)
    }

    static func defaults(hostName: String) -> [CouncilParticipant] {
        [
            CouncilParticipant(
                id: "host",
                handle: "host",
                displayName: "Host · \(hostName)",
                roleDescription: "主持、串联、追问和综合",
                shortLens: "主持与综合",
                systemImage: "crown",
                tint: AmberTheme.accent,
                isHost: true,
                modelHint: "主模型"
            ),
            CouncilParticipant(
                id: "deepseek",
                handle: "DeepSeek",
                displayName: "DeepSeek",
                roleDescription: "结构化推理、假设拆解和第一性原理分析",
                shortLens: "结构化推理",
                systemImage: "brain.head.profile",
                tint: AmberTheme.accentIndigo,
                isHost: false,
                modelHint: "推理视角"
            ),
            CouncilParticipant(
                id: "glm",
                handle: "GLM",
                displayName: "GLM",
                roleDescription: "中文用户直觉、表达和产品叙事",
                shortLens: "中文用户心智",
                systemImage: "text.bubble",
                tint: AmberTheme.accentGreen,
                isHost: false,
                modelHint: "语言视角"
            ),
            CouncilParticipant(
                id: "gemini",
                handle: "Gemini",
                displayName: "Gemini",
                roleDescription: "多模态、用户体验和移动端交互视角",
                shortLens: "多模态与交互",
                systemImage: "camera.metering.matrix",
                tint: AmberTheme.accentCyan,
                isHost: false,
                modelHint: "多模态视角"
            ),
            CouncilParticipant(
                id: "risk",
                handle: "Risk",
                displayName: "Risk",
                roleDescription: "风险复核、失败模式、隐私、成本、循环和安全边界",
                shortLens: "风险与边界",
                systemImage: "exclamationmark.shield",
                tint: AmberTheme.accentRed,
                isHost: false,
                modelHint: "风险视角"
            ),
            CouncilParticipant(
                id: "opponent",
                handle: "Opponent",
                displayName: "Opponent",
                roleDescription: "反方质询、反例和取舍压力测试",
                shortLens: "反方质询",
                systemImage: "hand.raised",
                tint: AmberTheme.accentAmber,
                isHost: false,
                modelHint: "质询视角"
            )
        ]
    }

    private static func makeHandle(from name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSpaces = trimmed.filter { !$0.isWhitespace }
        return withoutSpaces.isEmpty ? fallback : withoutSpaces
    }

    private static func icon(for id: String) -> String {
        if id.contains("risk") { return "exclamationmark.shield" }
        if id.contains("opponent") { return "hand.raised" }
        if id.contains("product") { return "rectangle.3.group.bubble" }
        if id.contains("engineering") { return "hammer" }
        return "person.crop.circle.badge.checkmark"
    }

    private static func tint(for id: String) -> Color {
        let palette = [
            AmberTheme.accentCyan,
            AmberTheme.accentGreen,
            AmberTheme.accentAmber,
            AmberTheme.accentIndigo,
            AmberTheme.accentRed
        ]
        let value = abs(id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return palette[value % palette.count]
    }
}

enum CouncilParticipantState: String {
    case idle
    case invited
    case speaking
    case failed

    var label: String {
        switch self {
        case .idle: "待命"
        case .invited: "已邀请"
        case .speaking: "发言中"
        case .failed: "失败"
        }
    }

    var localizedLabel: String {
        IOSAppLocalization.string(label, defaultValue: label)
    }
}

enum CouncilDisplayCopy {
    static func localized(_ value: String) -> String {
        IOSAppLocalization.string(value, defaultValue: value)
    }

    static func formatted(_ key: String, arguments: [CVarArg]) -> String {
        IOSAppLocalization.formatted(key, defaultValue: key, arguments: arguments)
    }

    static func participantName(_ participant: CouncilParticipant) -> String {
        guard participant.isHost else {
            return localized(participant.displayName)
        }
        if let modelId = participant.modelId?.trimmedNilIfBlank {
            return formatted("主持 · %@", arguments: [modelId])
        }
        let legacyHostPrefix = "Host · "
        if participant.displayName.hasPrefix(legacyHostPrefix) {
            return formatted(
                "主持 · %@",
                arguments: [String(participant.displayName.dropFirst(legacyHostPrefix.count))]
            )
        }
        return localized(participant.displayName)
    }

    static func status(_ value: String) -> String {
        let speakingSuffix = " 发言中"
        guard value.hasSuffix(speakingSuffix) else { return localized(value) }
        let name = String(value.dropLast(speakingSuffix.count))
        guard !name.isEmpty else { return localized(value) }
        return formatted("%@ 发言中", arguments: [name])
    }

    static func subtitle(_ value: String) -> String {
        if value.hasPrefix("主持 · ") {
            return formatted("主持 · %@", arguments: [String(value.dropFirst("主持 · ".count))])
        }
        if value.hasPrefix("总结 · ") {
            return formatted("总结 · %@", arguments: [String(value.dropFirst("总结 · ".count))])
        }
        let reviewMarker = " 轮点评 · "
        if value.hasPrefix("第 "), let marker = value.range(of: reviewMarker) {
            let roundText = String(value[value.index(value.startIndex, offsetBy: 2)..<marker.lowerBound])
            let modelId = String(value[marker.upperBound...])
            if let round = Int64(roundText), !modelId.isEmpty {
                return formatted("第 %lld 轮点评 · %@", arguments: [round, modelId])
            }
        }
        let followUpPrefix = "追问 · 第 "
        if value.hasPrefix(followUpPrefix), value.hasSuffix(" 轮") {
            let roundText = value.dropFirst(followUpPrefix.count).dropLast(2)
            if let round = Int64(roundText) {
                return formatted("追问 · 第 %lld 轮", arguments: [round])
            }
        }
        if let separator = value.range(of: " · ", options: .backwards) {
            let modelId = String(value[..<separator.lowerBound])
            let reasoning = String(value[separator.upperBound...])
            if !modelId.isEmpty,
               IOSCouncilReasoningPreset.allCases.contains(where: { $0.title == reasoning }) {
                return IOSAppLocalization.formatted(
                    "%@ · %@",
                    defaultValue: "%@ · %@",
                    arguments: [modelId, localized(reasoning)]
                )
            }
        }
        return localized(value)
    }

    static func messageBody(
        _ body: String,
        status: CouncilMessageStatus,
        pendingPhaseLabels: Set<String>
    ) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == .speaking && trimmed.isEmpty {
            return localized("思考中...")
        }
        if pendingPhaseLabels.contains(trimmed) {
            return status == .speaking ? localized(trimmed) : localized("未生成内容")
        }

        switch trimmed {
        case "主持调研", "自由群聊开始", "辩论开始", "主持人轮末点评", "主持总结",
             "主持人未返回议题。", "主持人未返回总结。", "已停止", "就绪",
             "配置阻塞", "启动失败", "已取消", "已超时", "运行失败",
             "上次讨论已中断，可以继续补充或重新发起。", "本轮议会已停止。",
             "无法保存运行状态，本轮议会未启动。", "模型议会已取消。",
             "发言未完成（应用中断）":
            return localized(trimmed)
        case "自由群聊 · 开场", "辩论 · 交叉回应":
            return CouncilDiscussionMode.allCases.first(where: { $0.openingDivider == trimmed })?
                .localizedOpeningDivider ?? localized(trimmed)
        default:
            break
        }

        let roundPrefix = "第 "
        if trimmed.hasPrefix(roundPrefix), trimmed.hasSuffix(" 轮") {
            let roundText = trimmed.dropFirst(roundPrefix.count).dropLast(2)
            if let round = Int64(roundText) {
                return formatted("第 %lld 轮", arguments: [round])
            }
        }

        let followUpPrefix = "追问 · 第 "
        if trimmed.hasPrefix(followUpPrefix), trimmed.hasSuffix(" 轮") {
            let roundText = trimmed.dropFirst(followUpPrefix.count).dropLast(2)
            if let round = Int64(roundText) {
                return formatted("追问 · 第 %lld 轮", arguments: [round])
            }
        }

        if let counted = countedList(
            trimmed,
            prefix: "已组建 ",
            marker: " 位议员："
        ) {
            return formatted("已组建 %lld 位议员：%@", arguments: [counted.count, counted.items])
        }
        if trimmed.hasPrefix("本轮议员（已添加席位）：") {
            let names = String(trimmed.dropFirst("本轮议员（已添加席位）：".count))
            return formatted("本轮议员（已添加席位）：%@", arguments: [names])
        }
        if trimmed.hasPrefix("模型联通检查已替换不可用模型：") {
            let names = String(trimmed.dropFirst("模型联通检查已替换不可用模型：".count))
            return formatted("模型联通检查已替换不可用模型：%@", arguments: [names])
        }
        if trimmed.hasPrefix("沿用本议会席位：") {
            let names = String(trimmed.dropFirst("沿用本议会席位：".count))
            return formatted("沿用本议会席位：%@", arguments: [names])
        }
        if trimmed.hasPrefix("动态组席未返回有效席位，已沿用默认席位：") {
            let names = String(trimmed.dropFirst("动态组席未返回有效席位，已沿用默认席位：".count))
            return formatted("动态组席未返回有效席位，已沿用默认席位：%@", arguments: [names])
        }
        for (prefix, key) in [
            ("席位失败：", "席位失败：%@"),
            ("点评失败：", "点评失败：%@")
        ] where trimmed.hasPrefix(prefix) {
            return formatted(key, arguments: [String(trimmed.dropFirst(prefix.count))])
        }
        return body
    }

    private static func countedList(
        _ value: String,
        prefix: String,
        marker: String
    ) -> (count: Int64, items: String)? {
        guard value.hasPrefix(prefix),
              let markerRange = value.range(of: marker),
              markerRange.lowerBound > value.index(value.startIndex, offsetBy: prefix.count),
              let count = Int64(value[value.index(value.startIndex, offsetBy: prefix.count)..<markerRange.lowerBound]) else {
            return nil
        }
        return (count, String(value[markerRange.upperBound...]))
    }
}

struct CouncilChatMessage: Identifiable {
    private static let pendingPhaseLabels: Set<String> = [
        "思考中...", "调研和完善议题中...", "点评中...", "总结中...",
    ]

    let id: UUID
    let kind: CouncilMessageKind
    let author: String
    var body: String
    let systemImage: String
    let tint: Color
    let subtitle: String?
    var status: CouncilMessageStatus

    init(
        id: UUID = UUID(),
        kind: CouncilMessageKind,
        author: String,
        body: String,
        systemImage: String,
        tint: Color,
        subtitle: String?,
        status: CouncilMessageStatus = .completed
    ) {
        self.id = id
        self.kind = kind
        self.author = author
        self.body = body
        self.systemImage = systemImage
        self.tint = tint
        self.subtitle = subtitle
        self.status = status
    }

    var displayBody: String {
        guard kind != .user else { return body }
        let localizedBody = CouncilDisplayCopy.messageBody(
            body,
            status: status,
            pendingPhaseLabels: Self.pendingPhaseLabels
        )
        return kind == .system
            ? CouncilDisplayCopy.localized(localizedBody)
            : localizedBody
    }

    var displayAuthor: String {
        switch author {
        case "你", "议会", "主持人":
            return CouncilDisplayCopy.localized(author)
        default:
            return author
        }
    }

    var displaySubtitle: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return CouncilDisplayCopy.subtitle(subtitle)
    }

    /// Runner phase labels are UI chrome, not generated Markdown. Keeping them
    /// outside the incremental renderer makes the first model text an initial
    /// document instead of a non-prefix replacement of "思考中..." / "总结中...".
    var streamingMarkdownBody: String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.pendingPhaseLabels.contains(trimmed) || (status == .speaking && trimmed.isEmpty) {
            return nil
        }
        return displayBody
    }

    var usesStreamingMarkdown: Bool {
        kind == .host || kind == .guest
    }

    var isStreamingMarkdown: Bool {
        usesStreamingMarkdown && status == .speaking
    }

    /// Every host/guest message enters through a `.speaking` runner event, so this
    /// remains true after completion and after archive restoration without adding a
    /// persistence field or changing the generation protocol.
    var hasEverStreamedMarkdown: Bool {
        usesStreamingMarkdown
    }

    var markdownRenderCacheNamespace: String {
        "council:\(id.uuidString)"
    }

    var backgroundColor: Color {
        if status == .failed {
            return AmberTheme.accentRed.opacity(0.08)
        }
        switch kind {
        case .user: return AmberTheme.accent
        case .host: return AmberTheme.surface
        case .guest: return AmberTheme.surface2
        case .system: return AmberTheme.surface2.opacity(0.65)
        case .divider: return .clear
        }
    }

    var foregroundColor: Color {
        kind == .user ? .white : AmberTheme.foreground
    }

    var borderColor: Color {
        if status == .failed {
            return AmberTheme.accentRed.opacity(0.42)
        }
        switch kind {
        case .host: return AmberTheme.accent.opacity(0.24)
        case .guest: return AmberTheme.borderSoft
        case .system: return AmberTheme.borderSoft
        default: return .clear
        }
    }
}

enum CouncilMessageKind {
    case user
    case host
    case guest
    case system
    case divider

    init(_ kind: IOSCouncilRoomMessageKind) {
        switch kind {
        case .host: self = .host
        case .seat: self = .guest
        case .system: self = .system
        case .divider: self = .divider
        }
    }

    var rawKey: String {
        switch self {
        case .user: "user"; case .host: "host"; case .guest: "guest"; case .system: "system"; case .divider: "divider"
        }
    }

    init(rawKey: String) {
        switch rawKey {
        case "host": self = .host
        case "guest": self = .guest
        case "system": self = .system
        case "divider": self = .divider
        default: self = .user
        }
    }
}

enum CouncilMessageStatus {
    case speaking
    case completed
    case failed

    init(_ status: IOSCouncilRoomMessageStatus) {
        switch status {
        case .speaking: self = .speaking
        case .completed: self = .completed
        case .failed: self = .failed
        }
    }

    var rawKey: String {
        switch self {
        case .speaking: "speaking"; case .completed: "completed"; case .failed: "failed"
        }
    }

    init(rawKey: String) {
        switch rawKey {
        case "failed": self = .failed
        case "speaking": self = .failed
        default: self = .completed
        }
    }
}


struct CouncilDiscussionDetail: Identifiable {
    let id = UUID()
    let statusLine: String
    let objective: String
    let participantSummary: String
    let budgetSummary: String
    let transcript: String
}


private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var trimmedNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

