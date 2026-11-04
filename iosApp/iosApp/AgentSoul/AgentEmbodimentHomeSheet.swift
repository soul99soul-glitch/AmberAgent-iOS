import SwiftUI
import UIKit

// MARK: - Arquiel Design v2.5 · Agent 形象人设视觉令牌（自适应暖纸与深浅色主题）

enum AgentEmbodimentPalette {
    private static var isDefaultPaper: Bool {
        AmberThemeRuntime.shared.paper == .paper && AmberThemeRuntime.shared.design == nil
    }

    private static func dynamic(
        dark: @escaping () -> UIColor,
        paperHex: UInt32,
        otherLight: @escaping () -> UIColor
    ) -> Color {
        Color(uiColor: UIColor { trait in
            if trait.userInterfaceStyle == .dark { return dark() }
            return isDefaultPaper ? UIColor(hex: paperHex) : otherLight()
        })
    }

    static var sheetBg: Color { dynamic(dark: { UIColor(AmberTheme.background) }, paperHex: 0xF6F2EA, otherLight: { UIColor(AmberTheme.background) }) }
    static var cardBg: Color { dynamic(dark: { UIColor(AmberTheme.surface) }, paperHex: 0xECE6DC, otherLight: { UIColor(AmberTheme.surface) }) }
    static var cardElevated: Color { dynamic(dark: { UIColor(AmberTheme.surface2) }, paperHex: 0xF5F1E9, otherLight: { UIColor(AmberTheme.surfaceElevated) }) }
    static var segmentTrack: Color { dynamic(dark: { UIColor(AmberTheme.surface2) }, paperHex: 0xDED8CE, otherLight: { UIColor(AmberTheme.surface2) }) }
    static var segmentSelectedBg: Color { dynamic(dark: { UIColor(AmberTheme.surface) }, paperHex: 0xFFFFFF, otherLight: { UIColor(AmberTheme.surfaceElevated) }) }
    static var hairline: Color { dynamic(dark: { UIColor(AmberTheme.border) }, paperHex: 0xD8D0C5, otherLight: { UIColor(AmberTheme.border) }) }
    static var ink: Color { dynamic(dark: { UIColor(AmberTheme.foreground) }, paperHex: 0x1E1B18, otherLight: { UIColor(AmberTheme.foreground) }) }
    static var inkSecondary: Color { dynamic(dark: { UIColor(AmberTheme.foreground2) }, paperHex: 0x5A534A, otherLight: { UIColor(AmberTheme.foreground2) }) }
    static var inkMuted: Color { dynamic(dark: { UIColor(AmberTheme.muted) }, paperHex: 0x857D72, otherLight: { UIColor(AmberTheme.muted) }) }
    static var danger: Color { dynamic(dark: { UIColor(AmberTheme.accentRed) }, paperHex: 0xB83B2A, otherLight: { UIColor(AmberTheme.accentRed) }) }

    static var cardStroke: Color {
        Color(uiColor: UIColor { trait in
            UIColor.white.withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.08 : 0.65)
        })
    }

    static var accent: Color {
        Color(uiColor: UIColor { trait in
            if trait.userInterfaceStyle != .dark && isDefaultPaper && AmberThemeRuntime.shared.accentHex == 0xD98324 {
                return UIColor(hex: 0x9C3D2D)
            }
            return UIColor(AmberTheme.accent)
        })
    }

    static var accentSoftBg: Color {
        dynamic(
            dark: { UIColor(AmberTheme.accent).withAlphaComponent(0.22) },
            paperHex: 0xEFE0DC,
            otherLight: { UIColor(AmberTheme.accent).withAlphaComponent(0.12) }
        )
    }

    static var accentBorder: Color {
        dynamic(
            dark: { UIColor(AmberTheme.accent).withAlphaComponent(0.45) },
            paperHex: 0xCFA096,
            otherLight: { UIColor(AmberTheme.accent).withAlphaComponent(0.36) }
        )
    }
}

// MARK: - 人设文本结构化提炼（仅从真实设定提取，无则自然隐藏，绝不硬造假数据）

struct AgentSoulPresentation: Equatable {
    var traits: [String]
    var bodyText: String
    var voiceSample: String?

    private static let leadingBulletRegex = try? NSRegularExpression(pattern: #"^[-*•\d\.\)\s]+"#)
    private static let dialogueRegexes: [NSRegularExpression] = [
        #"“([^”]{10,88}[。！？!?～~])”"#,
        #"\"([^\"]{10,88}[。！？!?～~])\""#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let shortTagSeparators = CharacterSet(charactersIn: "、，,·/｜|；;。！？!?\n")
    private static let shortTagForbidden = ["自称", "管你叫", "平时", "遇到", "说话", "我是", "你是", "可以", "或者", "如果"]

    static func parse(soulPrompt: String, tagline: String) -> AgentSoulPresentation {
        let trimmedSoul = soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSoul.isEmpty else {
            return AgentSoulPresentation(traits: [], bodyText: "", voiceSample: nil)
        }

        var bodyLines: [String] = []
        var explicitTraits: [String] = []
        var extractedVoice: String?

        for line in trimmedSoul.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cleanLine: String
            if let regex = leadingBulletRegex {
                let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
                cleanLine = regex.stringByReplacingMatches(in: trimmed, range: nsRange, withTemplate: "")
            } else {
                cleanLine = trimmed
            }
            if let match = extractPrefixedValue(from: cleanLine, prefixes: ["标签：", "标签:", "性格标签：", "性格标签:", "关键词：", "关键词:"]) {
                explicitTraits.append(contentsOf: splitShortTags(match))
                continue
            }
            if extractedVoice == nil,
               let match = extractPrefixedValue(from: cleanLine, prefixes: ["口吻：", "口吻:", "口吻示例：", "口吻示例:", "语气示例：", "语气示例:", "示例台词：", "示例台词:"]),
               !match.isEmpty {
                extractedVoice = formatQuoted(match)
                continue
            }
            bodyLines.append(cleanLine)
        }

        let joinedBody = bodyLines.isEmpty ? trimmedSoul : bodyLines.joined(separator: "\n")
        if extractedVoice == nil {
            extractedVoice = extractQuotedDialogue(from: joinedBody)
        }

        let candidateSource = tagline.isEmpty ? joinedBody : "\(tagline)，\(joinedBody)"
        let rawTraits = explicitTraits.isEmpty ? splitShortTags(candidateSource) : explicitTraits
        var uniqueTraits: [String] = []
        for item in rawTraits where !uniqueTraits.contains(item) {
            uniqueTraits.append(item)
            if uniqueTraits.count == 4 { break }
        }
        if uniqueTraits.count < 2 { uniqueTraits = [] }

        return AgentSoulPresentation(traits: uniqueTraits, bodyText: joinedBody, voiceSample: extractedVoice)
    }

    static func formatQuoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"'「」"))
        return trimmed.isEmpty ? "" : "“\(trimmed)”"
    }

    private static func extractPrefixedValue(from line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func splitShortTags(_ text: String) -> [String] {
        return text
            .components(separatedBy: shortTagSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                token.count >= 2 && token.count <= 6
                    && !shortTagForbidden.contains(where: { token.contains($0) })
                    && !token.contains("「") && !token.contains("」")
                    && !token.contains("“") && !token.contains("”")
            }
    }

    private static func extractQuotedDialogue(from text: String) -> String? {
        let nsRange = NSRange(text.startIndex..., in: text)
        for regex in dialogueRegexes {
            if let match = regex.firstMatch(in: text, range: nsRange),
               let range = Range(match.range(at: 1), in: text) {
                return "“\(text[range])”"
            }
        }
        return nil
    }
}

// MARK: - 3-Tab 方向感知过渡动效（无高度突跳、实时读取最新方向）

@MainActor
final class EmbodimentTransitionDirectionBox {
    var movingForward: Bool = true
}

private struct EmbodimentDirectionalSlideModifier: ViewModifier {
    let isActive: Bool
    let isInsertion: Bool
    let directionBox: EmbodimentTransitionDirectionBox

    func body(content: Content) -> some View {
        let forward = directionBox.movingForward
        let offsetX: CGFloat = isInsertion ? (forward ? 22 : -22) : (forward ? -16 : 16)
        content
            .offset(x: isActive ? offsetX : 0)
            .opacity(isActive ? 0 : 1)
    }
}

extension AnyTransition {
    @MainActor
    static func embodimentDirectionalSlide(
        directionBox: EmbodimentTransitionDirectionBox,
        reduceMotion: Bool
    ) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: EmbodimentDirectionalSlideModifier(isActive: true, isInsertion: true, directionBox: directionBox),
                identity: EmbodimentDirectionalSlideModifier(isActive: false, isInsertion: true, directionBox: directionBox)
            ),
            removal: .modifier(
                active: EmbodimentDirectionalSlideModifier(isActive: true, isInsertion: false, directionBox: directionBox),
                identity: EmbodimentDirectionalSlideModifier(isActive: false, isInsertion: false, directionBox: directionBox)
            )
        )
    }
}

// MARK: - Agent 形象人设 Sheet

/// Agent 形象人设：顶部角色头卡 + 人设 / 记忆 / 灵感 三栏。
struct AgentEmbodimentHomeSheet: View {
    let sharedSettings: IOSSharedSettingsStore
    var onStartConversation: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var soul = AgentSoulStore.shared
    @State private var tab: Tab = .soul
    @State private var directionBox = EmbodimentTransitionDirectionBox()
    /// 形象编辑态：与外层同面板、同滚动容器，不再 present 第二层 sheet。
    @State private var isEditingAvatar = false
    @State private var avatarPreviewMood: AmberAgentPersonaMood = .idle
    @State private var isEditingSoul = false

    @Namespace private var tabNamespace

    enum Tab: Int, CaseIterable, Identifiable {
        case soul = 0
        case memory = 1
        case ideas = 2

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .soul: return IOSAppLocalization.string("人设 Soul", defaultValue: "人设 Soul")
            case .memory: return IOSAppLocalization.string("记忆 Memory", defaultValue: "记忆 Memory")
            case .ideas: return IOSAppLocalization.string("灵感 点子", defaultValue: "灵感 点子")
            }
        }
    }

    static let tabSpring = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let avatarEditorScrollID = "embodiment.avatarEditor"

    /// 克制的原位切换动效：180–240ms；Reduce Motion 下退为简单淡变。
    private var avatarModeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22)
    }

    /// 进入 / 退出形象编辑态：同一面板内切换内容，不 present 第二层 sheet。
    /// 方向盒子复用现有滑入滑出机制，进入为前进、返回为后退。
    private func transitionAvatarMode(to editing: Bool) {
        guard editing != isEditingAvatar else { return }
        directionBox.movingForward = editing
        withAnimation(avatarModeAnimation) {
            isEditingAvatar = editing
        }
    }

    /// 整个面板只维这一个头像：编辑态复用同一几何来源，并随暂存预览实时反映。
    private var sharedAvatarMood: AmberAgentPersonaMood {
        let store = AmberPersonaStore.shared
        return isEditingAvatar && store.pendingPreviewKind == .multiFrameAnimation
            ? avatarPreviewMood
            : .idle
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                personaHeroHeader

                ZStack(alignment: .top) {
                    Group {
                        if isEditingAvatar {
                            AmberPersonaStudioContent(
                                sharedSettings: sharedSettings,
                                previewMood: $avatarPreviewMood,
                                showsAvatar: false,
                                showsInlineReset: true
                            )
                        } else {
                            switch tab {
                            case .soul:
                                soulSection
                            case .memory:
                                AgentSoulMemorySection()
                            case .ideas:
                                AgentSoulIdeasSection(onPick: handleIdeaPicked)
                            }
                        }
                    }
                    .id(isEditingAvatar ? Self.avatarEditorScrollID : "embodiment.tab.\(tab.rawValue)")
                    .transition(.embodimentDirectionalSlide(directionBox: directionBox, reduceMotion: reduceMotion))
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, isEditingAvatar ? 34 : 28)
            .amberSmoothSheetScrollDismiss()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            topNavigationBar
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .background(AgentEmbodimentPalette.sheetBg)
        }
        .background(AgentEmbodimentPalette.sheetBg.ignoresSafeArea())
        .sheet(isPresented: $isEditingSoul) {
            AgentSoulEditorSheet(store: soul)
                .presentationDetents([.large])
        }
        .task {
            await MacGatewayStore.shared.syncCloudSoulIfNeeded(forcePull: true, soulStore: soul)
        }
    }

    // MARK: - 顶部导航栏

    private var topNavigationBar: some View {
        ZStack {
            Text(IOSAppLocalization.string("形象人设", defaultValue: "形象人设"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AgentEmbodimentPalette.ink)

            HStack {
                if isEditingAvatar {
                    Button {
                        transitionAvatarMode(to: false)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text(IOSAppLocalization.string("人设", defaultValue: "人设"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                        .overlay {
                            Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("embodiment.avatarBackButton")
                }

                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(IOSAppLocalization.string("完成", defaultValue: "完成"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AgentEmbodimentPalette.accent)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                        .overlay {
                            Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.accentBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.doneButton")
            }
        }
    }

    // MARK: - 共享角色头卡 + 3-Tab 分段胶囊条

    private var personaHeroHeader: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    Button {
                        transitionAvatarMode(to: true)
                    } label: {
                        AmberAgentPersonaMedallionView(
                            mood: sharedAvatarMood,
                            diameter: isEditingAvatar ? 96 : 112,
                            storeOverride: AmberPersonaStore.shared,
                            showStagedPreview: isEditingAvatar
                        )
                            .overlay {
                                Circle().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.95), lineWidth: 3)
                            }
                            .overlay {
                                Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                            }
                            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("embodiment.avatar")

                    if !isEditingAvatar {
                        Button {
                            transitionAvatarMode(to: true)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(IOSAppLocalization.string("更换形象", defaultValue: "更换形象"))
                                    .font(.system(size: 11.5, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9.5, weight: .bold))
                            }
                            .foregroundStyle(AgentEmbodimentPalette.ink)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                            .overlay {
                                Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                            }
                            .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(y: 8)
                        .accessibilityIdentifier("embodiment.changeAvatarButton")
                    }
                }
                .padding(.bottom, 6)

                VStack(spacing: 4) {
                    Text(soul.displayName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AgentEmbodimentPalette.ink)

                    if let signature = resolvedSignatureText {
                        Text(signature)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !isEditingAvatar {
                segmentedTabBar
            }
        }
    }

    private var resolvedSignatureText: String? {
        let trimmed = soul.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return AgentSoulPresentation.formatQuoted(trimmed) }
        if soul.isDefault {
            return IOSAppLocalization.string("“温和克制的全能效率搭档”", defaultValue: "“温和克制的全能效率搭档”")
        }
        return nil
    }

    private var segmentedTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                let isSelected = (tab == item)
                Button {
                    selectTab(item)
                } label: {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AgentEmbodimentPalette.ink : AgentEmbodimentPalette.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Capsule(style: .continuous))
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(AgentEmbodimentPalette.segmentSelectedBg)
                                    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "embodimentActiveTab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.tab.\(item.rawValue)")
            }
        }
        .padding(2)
        .frame(height: 38)
        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.segmentTrack))
        .accessibilityIdentifier("embodiment.tabPicker")
    }

    private func selectTab(_ newTab: Tab) {
        guard newTab != tab else { return }
        directionBox.movingForward = newTab.rawValue > tab.rawValue
        if !reduceMotion {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(Self.tabSpring) { tab = newTab }
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { tab = newTab }
        }
    }

    // MARK: - 屏 1：人设 Soul

    private var soulSection: some View {
        let presentation = AgentSoulPresentation.parse(soulPrompt: soul.soulPrompt, tagline: soul.tagline)
        return VStack(spacing: 14) {
            soulMainCard(presentation: presentation)
            snapshotSectionCard
        }
    }

    private func soulMainCard(presentation: AgentSoulPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(IOSAppLocalization.string("灵魂设定", defaultValue: "灵魂设定"))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(AgentEmbodimentPalette.ink)

                sourceBadgeView

                Spacer(minLength: 4)

                Button {
                    isEditingSoul = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(IOSAppLocalization.string("编辑", defaultValue: "编辑"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AgentEmbodimentPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.editSoulButton")
            }

            if !presentation.traits.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presentation.traits, id: \.self) { trait in
                            Text(trait)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                                .overlay {
                                    Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                                }
                        }
                    }
                }
            }

            Text(
                presentation.bodyText.isEmpty
                    ? IOSAppLocalization.string(
                        "还没有专门设定。可以在主对话直接说「你给自己写个人设」，或点右上角编辑。",
                        defaultValue: "还没有专门设定。可以在主对话直接说「你给自己写个人设」，或点右上角编辑。"
                    )
                    : presentation.bodyText
            )
            .font(.system(size: 13.5))
            .foregroundStyle(presentation.bodyText.isEmpty ? AgentEmbodimentPalette.inkSecondary : AgentEmbodimentPalette.ink)
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            if let voiceSample = presentation.voiceSample {
                HStack(alignment: .top, spacing: 8) {
                    Text(IOSAppLocalization.string("口吻", defaultValue: "口吻"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentEmbodimentPalette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))
                        .padding(.top, 1)

                    Text(voiceSample)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                }
            }

            Divider().overlay(AgentEmbodimentPalette.hairline)

            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                Text(IOSAppLocalization.string("在主对话直接说「换个性格 / 改称呼」，人设即自动更新", defaultValue: "在主对话直接说「换个性格 / 改称呼」，人设即自动更新"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }

    private var sourceBadgeView: some View {
        let isConversation = (soul.source == .conversation && !soul.isDefault)
        let iconName = isConversation ? "bubble.left.and.sparkles.fill" : "slider.horizontal.3"
        let baseLabel: String = {
            if soul.isDefault { return IOSAppLocalization.string("默认设定", defaultValue: "默认设定") }
            return isConversation
                ? IOSAppLocalization.string("来自对话自塑", defaultValue: "来自对话自塑")
                : IOSAppLocalization.string("手动设定", defaultValue: "手动设定")
        }()
        let timeSuffix: String = {
            guard !soul.isDefault, soul.updatedAtMs > 0 else { return "" }
            return " · \(Self.relativeTime(Date(timeIntervalSince1970: Double(soul.updatedAtMs) / 1000)))"
        }()

        return HStack(spacing: 4) {
            Image(systemName: iconName).font(.system(size: 10, weight: .semibold))
            Text(baseLabel + timeSuffix).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(AgentEmbodimentPalette.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))
    }

    // MARK: - 历史人设快照

    private var snapshotSectionCard: some View {
        let hasDefaultInSnapshots = soul.snapshots.contains {
            $0.displayName == AgentSoulStore.defaultDisplayName && $0.soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let showDefaultFallbackRow = !soul.isDefault && !hasDefaultInSnapshots

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(IOSAppLocalization.string("历史人设快照", defaultValue: "历史人设快照"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                Spacer()
                Text(IOSAppLocalization.string("全局统一形象人设 · 一键回退", defaultValue: "全局统一形象人设 · 一键回退"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                currentActiveSnapshotRow

                ForEach(soul.snapshots) { snapshot in
                    Divider().overlay(AgentEmbodimentPalette.hairline).padding(.leading, 60)
                    historicalSnapshotRow(snapshot)
                }

                if showDefaultFallbackRow {
                    Divider().overlay(AgentEmbodimentPalette.hairline).padding(.leading, 60)
                    defaultAmberFallbackRow
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
            }
        }
    }

    private var currentActiveSnapshotRow: some View {
        let timeText = soul.updatedAtMs > 0
            ? Self.relativeTime(Date(timeIntervalSince1970: Double(soul.updatedAtMs) / 1000))
            : "当前生效"
        let summaryText: String = {
            let trimmedTag = soul.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTag.isEmpty { return trimmedTag }
            let trimmedSoul = soul.soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSoul.isEmpty { return String(trimmedSoul.prefix(24)) }
            return IOSAppLocalization.string("温和克制的全能效率搭档", defaultValue: "温和克制的全能效率搭档")
        }()

        return HStack(spacing: 10) {
            SnapshotMiniAvatar(name: soul.displayName, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(soul.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AgentEmbodimentPalette.ink)
                    Text(IOSAppLocalization.string("当前", defaultValue: "当前"))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(AgentEmbodimentPalette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))
                }
                Text("\(timeText) · \(summaryText)")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(AgentEmbodimentPalette.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func historicalSnapshotRow(_ snapshot: AgentSoulSnapshot) -> some View {
        let subtitle: String = {
            let dateStr = Self.shortDate(snapshot.savedAt)
            let desc = snapshot.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty { return "\(dateStr) · \(desc)" }
            if let summary = snapshot.summary, !summary.isEmpty { return "\(dateStr) · \(summary)" }
            let promptPreview = snapshot.soulPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return promptPreview.isEmpty ? dateStr : "\(dateStr) · \(String(promptPreview.prefix(22)))"
        }()

        return HStack(spacing: 10) {
            SnapshotMiniAvatar(name: snapshot.displayName, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                soul.restore(snapshotID: snapshot.id)
            } label: {
                Text(IOSAppLocalization.string("切回", defaultValue: "切回"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                    .overlay {
                        Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var defaultAmberFallbackRow: some View {
        HStack(spacing: 10) {
            SnapshotMiniAvatar(name: AgentSoulStore.defaultDisplayName, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(IOSAppLocalization.string("默认 Amber", defaultValue: "默认 Amber"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                Text(IOSAppLocalization.string("温和克制的全能效率搭档", defaultValue: "温和克制的全能效率搭档"))
                    .font(.system(size: 12))
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                soul.resetToDefault()
            } label: {
                Text(IOSAppLocalization.string("切回", defaultValue: "切回"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                    .overlay {
                        Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("embodiment.resetToDefault")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func handleIdeaPicked(_ idea: AgentSoulIdea) {
        dismiss()
        onStartConversation(idea.prompt)
    }

    static func relativeTime(_ date: Date) -> String {
        if Int(Date().timeIntervalSince(date)) < 90 {
            return IOSAppLocalization.string("刚刚", defaultValue: "刚刚")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M月d日"
        return formatter.string(from: date)
    }
}

// MARK: - 快照微缩头像与附属视图

private struct SnapshotMiniAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        let isDefault = (name == AgentSoulStore.defaultDisplayName || name == "默认 Amber")
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0xE8D5C4), Color(hex: 0xD5B89F)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if isDefault {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.accent)
            } else {
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(AgentEmbodimentPalette.accent)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
        .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
    }
}

struct AgentSoulCard: View {
    let title: String
    let text: String
    var isPlaceholder: Bool = false
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                Spacer(minLength: 4)
                if let onEdit {
                    Button(IOSAppLocalization.string("编辑", defaultValue: "编辑"), action: onEdit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AgentEmbodimentPalette.accent)
                        .buttonStyle(.plain)
                }
            }
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(isPlaceholder ? AgentEmbodimentPalette.inkMuted : AgentEmbodimentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }
}

struct AgentSoulEditorSheet: View {
    let store: AgentSoulStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var tagline = ""
    @State private var soulText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(IOSAppLocalization.string("称呼", defaultValue: "称呼")) {
                    TextField("Amber", text: $name)
                        .accessibilityIdentifier("soulEditor.name")
                }
                Section(IOSAppLocalization.string("一句话签名", defaultValue: "一句话签名")) {
                    TextField(IOSAppLocalization.string("可选", defaultValue: "可选"), text: $tagline)
                        .accessibilityIdentifier("soulEditor.tagline")
                }
                Section(IOSAppLocalization.string("灵魂设定", defaultValue: "灵魂设定")) {
                    TextEditor(text: $soulText)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier("soulEditor.soul")
                }
            }
            .navigationTitle(IOSAppLocalization.string("编辑人设", defaultValue: "编辑人设"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSAppLocalization.string("取消", defaultValue: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSAppLocalization.string("保存", defaultValue: "保存")) {
                        store.update(
                            displayName: name,
                            tagline: tagline,
                            soulPrompt: soulText,
                            summary: IOSAppLocalization.string("手动编辑", defaultValue: "手动编辑"),
                            source: .manual
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("soulEditor.save")
                }
            }
            .onAppear {
                name = store.displayName
                tagline = store.tagline
                soulText = store.soulPrompt
            }
        }
    }
}
