import SwiftUI
import EventKit

/// 一张点子卡片。
struct AgentSoulIdea: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var reason: String
    /// 点进去时直接发进主对话的开场话术。
    var prompt: String
    /// 可选来源短标（如「结合日程 · 明早 10:00」或「结合近期进展」），向后兼容旧缓存。
    var sourceBadge: String? = nil
}

/// 「灵感」栏：汇总 Soul + 记忆 + 近期会话 + 已授权日程，生成 3–4 张可点的点子。
///
/// 对齐 `ios-agent-embodiment-v1` 屏 3 视觉规范：
/// - 顶栏左副标「结合记忆、近期工作与日程按需生成」+ 右「↻ 换一批」胶囊
/// - 点子卡片顶部带来源微胶囊（首张或日程类采用赤陶浅底微标）、加粗标题、温和引述体建议正文与右下「展开聊聊 ›」
struct AgentSoulIdeasSection: View {
    var onPick: (AgentSoulIdea) -> Void

    @State private var ideas: [AgentSoulIdea] = []
    @State private var isGenerating = false
    @State private var didLoadCache = false

    private static let cacheKey = "app.amber.ios.agentSoul.ideas.v1"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(
                    IOSAppLocalization.string(
                        "结合记忆、近期工作与日程按需生成",
                        defaultValue: "结合记忆、近期工作与日程按需生成"
                    )
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentEmbodimentPalette.inkSecondary)

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 4) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(
                            isGenerating
                                ? IOSAppLocalization.string("生成中", defaultValue: "生成中")
                                : IOSAppLocalization.string("换一批", defaultValue: "换一批")
                        )
                        .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
                .accessibilityIdentifier("embodiment.ideas.refresh")
            }
            .padding(.horizontal, 2)

            if ideas.isEmpty, isGenerating {
                placeholder
            } else if ideas.isEmpty {
                emptyState
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                        Button {
                            onPick(idea)
                        } label: {
                            ideaCard(idea, index: index)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("embodiment.ideas.card")
                    }
                }
            }
        }
        .task(id: didLoadCache) {
            guard !didLoadCache else { return }
            didLoadCache = true
            loadCache()
            if ideas.isEmpty { await refresh() }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(IOSAppLocalization.string("正在结合你的近况想点子…", defaultValue: "正在结合你的近况想点子…"))
                .font(.system(size: 13))
                .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AgentEmbodimentPalette.cardBg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(AgentEmbodimentPalette.inkMuted)
            Text(IOSAppLocalization.string(
                "还没有点子。配好模型后点「换一批」，或直接在对话里问我在想什么。",
                defaultValue: "还没有点子。配好模型后点「换一批」，或直接在对话里问我在想什么。"
            ))
            .font(.system(size: 13))
            .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AgentEmbodimentPalette.cardBg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }

    private func ideaCard(_ idea: AgentSoulIdea, index: Int) -> some View {
        let badgeMeta = Self.resolveSourceBadge(for: idea, index: index)
        let suggestionBody = Self.formattedQuoteText(for: idea)

        return VStack(alignment: .leading, spacing: 5.5) {
            HStack(spacing: 4) {
                Image(systemName: badgeMeta.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(badgeMeta.text)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(
                badgeMeta.isAccent
                    ? AgentEmbodimentPalette.accent
                    : AgentEmbodimentPalette.inkSecondary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        badgeMeta.isAccent
                            ? AgentEmbodimentPalette.accentSoftBg
                            : AgentEmbodimentPalette.cardElevated
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        badgeMeta.isAccent
                            ? Color.clear
                            : AgentEmbodimentPalette.hairline,
                        lineWidth: 1
                    )
            }

            Text(idea.title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(AgentEmbodimentPalette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !suggestionBody.isEmpty {
                Text(suggestionBody)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                    .lineSpacing(1.8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(
                    index == 0
                        ? IOSAppLocalization.string("可带回主对话或直接交办", defaultValue: "可带回主对话或直接交办")
                        : IOSAppLocalization.string("点击带入主对话开聊", defaultValue: "点击带入主对话开聊")
                )
                .font(.system(size: 11))
                .foregroundStyle(AgentEmbodimentPalette.inkMuted)

                Spacer()

                HStack(spacing: 3) {
                    Text(IOSAppLocalization.string("展开聊聊", defaultValue: "展开聊聊"))
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(AgentEmbodimentPalette.accent)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AgentEmbodimentPalette.cardBg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }

    static func resolveSourceBadge(for idea: AgentSoulIdea, index: Int) -> (icon: String, text: String, isAccent: Bool) {
        let combined = "\(idea.sourceBadge ?? "") \(idea.title) \(idea.reason)"
        let customSource = idea.sourceBadge?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if combined.contains("日程") || combined.contains("日历") || combined.contains("会") || combined.contains("明早") {
            return (
                icon: "calendar",
                text: customSource.isEmpty ? "结合日程与近期安排" : customSource,
                isAccent: true
            )
        }
        if combined.contains("提醒") || combined.contains("习惯") || combined.contains("偏好") || combined.contains("记忆") {
            return (
                icon: "checklist",
                text: customSource.isEmpty ? "结合记忆与偏好" : customSource,
                isAccent: index == 0
            )
        }
        return (
            icon: "sparkles.rectangle.stack",
            text: customSource.isEmpty ? "结合近期进展" : customSource,
            isAccent: index == 0
        )
    }

    private static func formattedQuoteText(for idea: AgentSoulIdea) -> String {
        let raw = idea.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? idea.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            : idea.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentSoulPresentation.formatQuoted(raw)
    }

    // MARK: - 缓存

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode([AgentSoulIdea].self, from: data) else { return }
        ideas = cached
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(ideas) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    // MARK: - 生成

    private func refresh() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        let context = await buildContext()
        guard let generated = await AgentSoulIdeaGenerator.generate(context: context), !generated.isEmpty else {
            return
        }
        ideas = generated
        saveCache()
    }

    /// 汇总：Soul + 记忆 + 近期日程（未授权则跳过）。
    private func buildContext() async -> String {
        var parts: [String] = []

        let soul = AgentSoulStore.shared
        if !soul.soulPrompt.isEmpty || soul.displayName != AgentSoulStore.defaultDisplayName {
            parts.append("角色设定：\(soul.displayName)。\(soul.tagline)")
            if !soul.soulPrompt.isEmpty {
                parts.append("性格与语气：\(String(soul.soulPrompt.prefix(600)))")
            }
        }

        let memories = IOSMemoryPersistence.shared.records.filter { !$0.archived && $0.kind != .topic }
        if !memories.isEmpty {
            let digest = memories.prefix(8).map { "- \($0.content)" }.joined(separator: "\n")
            parts.append("我记住的事：\n\(digest)")
        }

        let upcoming = await Self.upcomingEventsDigest()
        if !upcoming.isEmpty {
            parts.append("近期日程：\n\(upcoming)")
        }

        return parts.joined(separator: "\n\n")
    }

    /// 只读最近日程；未授权直接返回空字符串，绝不弹权限框。
    private static func upcomingEventsDigest() async -> String {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .authorized else { return "" }
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return "" }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).prefix(5)
        guard !events.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return events.map { event in
            "- \(formatter.string(from: event.startDate)) \(event.title ?? "")"
        }.joined(separator: "\n")
    }
}
