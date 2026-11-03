import SwiftUI
import EventKit

/// 一张点子卡片。
struct AgentSoulIdea: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var reason: String
    /// 点进去时直接发进主对话的开场话术。
    var prompt: String
}

/// 「灵感」栏：汇总 Soul + 记忆 + 近期会话 + 已授权日程，生成 3–4 张可点的点子。
///
/// 取舍：
/// - 生成结果本地缓存，打开不重复调用模型；「换一批」才重算。
/// - 日程未授权时优雅降级（直接不带日程上下文），绝不弹权限框或报错。
/// - 生成失败保留上一批缓存，不把错误做成红字噪声。
struct AgentSoulIdeasSection: View {
    var onPick: (AgentSoulIdea) -> Void

    @State private var ideas: [AgentSoulIdea] = []
    @State private var isGenerating = false
    @State private var didLoadCache = false

    private static let cacheKey = "app.amber.ios.agentSoul.ideas.v1"

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(IOSAppLocalization.string("现在可以聊聊", defaultValue: "现在可以聊聊"))
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 3) {
                        if isGenerating {
                            ProgressView().controlSize(.mini)
                        }
                        Text(isGenerating
                             ? IOSAppLocalization.string("生成中", defaultValue: "生成中")
                             : IOSAppLocalization.string("换一批", defaultValue: "换一批"))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AmberTheme.accent)
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
                ForEach(ideas) { idea in
                    Button {
                        onPick(idea)
                    } label: {
                        ideaCard(idea)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("embodiment.ideas.card")
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
                .font(.footnote)
                .foregroundStyle(AmberTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(AmberTheme.muted2)
            Text(IOSAppLocalization.string(
                "还没有点子。配好模型后点「换一批」，或直接在对话里问我在想什么。",
                defaultValue: "还没有点子。配好模型后点「换一批」，或直接在对话里问我在想什么。"
            ))
            .font(.footnote)
            .foregroundStyle(AmberTheme.muted)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
    }

    private func ideaCard(_ idea: AgentSoulIdea) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(idea.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AmberTheme.foreground)
                .multilineTextAlignment(.leading)
            if !idea.reason.isEmpty {
                Text(idea.reason)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AmberTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AmberTheme.borderSoft, lineWidth: 0.7)
        }
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
            // 失败保留旧缓存，不打扰用户。
            return
        }
        ideas = generated
        saveCache()
    }

    /// 汇总：Soul + 记忆 + 近期会话摘要 + 近期日程（未授权则跳过）。
    private func buildContext() async -> String {
        var parts: [String] = []

        let soul = AgentSoulStore.shared
        if !soul.soulPrompt.isEmpty || soul.displayName != AgentSoulStore.defaultDisplayName {
            parts.append("角色设定：\(soul.displayName)。\(soul.tagline)")
            if !soul.soulPrompt.isEmpty {
                parts.append("性格与语气：\(String(soul.soulPrompt.prefix(600)))")
            }
        }

        let memories = IOSMemoryPersistence.shared.records
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
