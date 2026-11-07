import SwiftUI
@preconcurrency import Shared

// MARK: - 3 维记忆画像摘要模型与提炼器（方案 A）

struct AgentMemoryPortraitSummary: Codable, Equatable {
    var identityAndFocus: [String]
    var preferencesAndTaboos: [String]
    var recentTopics: [String]
    var updatedAtMs: Int64
}

enum AgentMemoryPortraitBuilder {
    enum Bucket: String, CaseIterable, Identifiable {
        case all = "全部"
        case identityAndFocus = "身份与项目"
        case preferencesAndTaboos = "偏好与禁区"
        case recentTopics = "近期议题"
        case archived = "已归档"

        var id: String { rawValue }
    }

    static func classify(_ record: MemoryRecord) -> Bucket {
        let text = record.content.lowercased()
        let kind = record.kind.wireName

        let tabooOrPrefKeywords = [
            "偏好", "习惯", "喜欢", "讨厌", "严禁", "禁止", "不要", "不接受", "绝不",
            "铁律", "规则", "必须", "风格", "语气", "字号", "配色", "遵循"
        ]
        if kind == "feedback" || kind == "routine" || tabooOrPrefKeywords.contains(where: { text.contains($0) }) {
            return .preferencesAndTaboos
        }

        let identityOrProjectKeywords = [
            "正在推进", "项目", "仓库", "工程", "开发", "我是", "身份", "负责", "主业",
            "架构", "部署", "服务器", "云端", "worktree", "分支", "四端"
        ]
        if kind == "user" || kind == "project" || identityOrProjectKeywords.contains(where: { text.contains($0) }) {
            return .identityAndFocus
        }

        if record.scope == .core {
            return .preferencesAndTaboos
        }
        return .recentTopics
    }

    /// 确定性本地提炼：即使未调模型或离线，也能将散乱记忆聚合成 3 组清爽要点。
    static func buildDeterministic(from records: [MemoryRecord]) -> AgentMemoryPortraitSummary {
        var identityItems: [String] = []
        var preferenceItems: [String] = []
        var recentItems: [String] = []

        let sorted = records.sorted {
            let lhsTime = $0.updatedAt > 0 ? $0.updatedAt : $0.createdAt
            let rhsTime = $1.updatedAt > 0 ? $1.updatedAt : $1.createdAt
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            return $0.id > $1.id
        }

        for record in sorted {
            let cleaned = cleanBulletText(record.content)
            guard !cleaned.isEmpty else { continue }
            switch classify(record) {
            case .identityAndFocus:
                if identityItems.count < 3, !containsNearDuplicate(cleaned, in: identityItems) {
                    identityItems.append(cleaned)
                }
            case .preferencesAndTaboos:
                if preferenceItems.count < 3, !containsNearDuplicate(cleaned, in: preferenceItems) {
                    preferenceItems.append(cleaned)
                }
            case .recentTopics, .all, .archived:
                if recentItems.count < 3, !containsNearDuplicate(cleaned, in: recentItems) {
                    recentItems.append(cleaned)
                }
            }
        }

        // 若某分栏为空而其他分栏充裕，将尚未展示的高优条目自然补位，避免空洞
        if recentItems.isEmpty {
            for record in sorted.prefix(6) {
                let cleaned = cleanBulletText(record.content)
                if !cleaned.isEmpty,
                   !identityItems.contains(cleaned),
                   !preferenceItems.contains(cleaned),
                   !recentItems.contains(cleaned) {
                    recentItems.append(cleaned)
                    if recentItems.count == 2 { break }
                }
            }
        }

        return AgentMemoryPortraitSummary(
            identityAndFocus: identityItems,
            preferencesAndTaboos: preferenceItems,
            recentTopics: recentItems,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// 找出重复或被新条目完整覆盖的冗余记忆 ID（保留更新或更完整的一条）。
    static func redundantRecordIds(in records: [MemoryRecord]) -> [Int32] {
        let sorted = records.sorted {
            let lhsTime = $0.updatedAt > 0 ? $0.updatedAt : $0.createdAt
            let rhsTime = $1.updatedAt > 0 ? $1.updatedAt : $1.createdAt
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            return $0.content.count > $1.content.count
        }

        var keptFingerprints: [String] = []
        var redundantIds: [Int32] = []

        for record in sorted {
            let fp = fingerprint(record.content)
            guard !fp.isEmpty else {
                redundantIds.append(record.id)
                continue
            }
            let isDuplicate = keptFingerprints.contains { kept in
                if kept == fp { return true }
                if kept.count >= 10 && fp.count >= 10 && (kept.contains(fp) || fp.contains(kept)) {
                    return true
                }
                return bigramSimilarity(kept, fp) >= 0.82
            }
            if isDuplicate {
                redundantIds.append(record.id)
            } else {
                keptFingerprints.append(fp)
            }
        }
        return redundantIds
    }

    static func cleanBulletText(_ raw: String) -> String {
        let oneLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
            .replacingOccurrences(of: #"^[-*•\d\.\)\s]+"#, with: "", options: .regularExpression)
        if oneLine.count <= 72 { return oneLine }
        return String(oneLine.prefix(70)) + "…"
    }

    static func fingerprint(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func containsNearDuplicate(_ candidate: String, in existing: [String]) -> Bool {
        let fp = fingerprint(candidate)
        guard !fp.isEmpty else { return true }
        return existing.contains { item in
            let itemFp = fingerprint(item)
            return itemFp == fp || bigramSimilarity(itemFp, fp) >= 0.78
        }
    }

    private static func bigramSimilarity(_ a: String, _ b: String) -> Double {
        let charsA = Array(a)
        let charsB = Array(b)
        guard charsA.count >= 4, charsB.count >= 4 else { return a == b ? 1.0 : 0.0 }
        var setA = Set<String>()
        for i in 0..<(charsA.count - 1) { setA.insert(String([charsA[i], charsA[i + 1]])) }
        var setB = Set<String>()
        for i in 0..<(charsB.count - 1) { setB.insert(String([charsB[i], charsB[i + 1]])) }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    @MainActor
    static func refineWithModelIfAvailable(records: [MemoryRecord]) async -> AgentMemoryPortraitSummary? {
        guard !records.isEmpty else { return nil }
        let settings = IOSSharedSettingsStore()
        let snapshot = settings.snapshot
        guard let model = snapshot.getCurrentChatModel(),
              let provider = ChatProviderConfiguration.provider(for: model, providers: snapshot.providers),
              ChatProviderConfiguration.issue(for: model, provider: provider) == nil else {
            return nil
        }

        let assistant = snapshot.getCurrentAssistant()
        let params = ChatViewModel.makeAuxiliaryTextGenerationParams(
            model: model,
            assistantHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider,
                assistant: assistant.customHeaders,
                model: model.customHeaders,
                conversationId: nil
            ),
            assistantBodies: assistant.customBodies
        )

        let digest = records.prefix(24).map { "- \($0.content)" }.joined(separator: "\n")
        let prompt = """
        请将以下零散的用户记忆条目整理提炼为 3 组简明、去重的核心画像认知：
        1. identityAndFocus：身份、角色与手头重点项目（1~3 条，每条不超过 38 字）
        2. preferencesAndTaboos：沟通偏好、设计审美与明确禁区（1~3 条，每条不超过 38 字）
        3. recentTopics：近期常聊或持续跟进的议题（1~3 条，每条不超过 38 字）

        原始记忆：
        \(digest)

        只输出严格 JSON 对象，不要任何解释或代码围栏：
        {"identityAndFocus":["..."],"preferencesAndTaboos":["..."],"recentTopics":["..."]}
        """

        let textProvider = OpenAIKmpProviderAdapter()
        do {
            let chunk = try await textProvider.generateText(
                providerSetting: provider,
                messages: [UIMessage.companion.user(prompt: prompt)],
                params: params
            )
            guard let rawText = chunk.choices.first?.message?.toText() else { return nil }
            var raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = raw.firstIndex(of: "{"),
                  let end = raw.lastIndex(of: "}"),
                  start < end else { return nil }
            raw = String(raw[start...end])
            struct Payload: Decodable {
                let identityAndFocus: [String]?
                let preferencesAndTaboos: [String]?
                let recentTopics: [String]?
            }
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            let idList = (decoded.identityAndFocus ?? []).map { cleanBulletText($0) }.filter { !$0.isEmpty }
            let prefList = (decoded.preferencesAndTaboos ?? []).map { cleanBulletText($0) }.filter { !$0.isEmpty }
            let recentList = (decoded.recentTopics ?? []).map { cleanBulletText($0) }.filter { !$0.isEmpty }
            guard !idList.isEmpty || !prefList.isEmpty || !recentList.isEmpty else { return nil }
            return AgentMemoryPortraitSummary(
                identityAndFocus: Array(idList.prefix(3)),
                preferencesAndTaboos: Array(prefList.prefix(3)),
                recentTopics: Array(recentList.prefix(3)),
                updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        } catch {
            return nil
        }
    }
}

// MARK: - 「记忆 Memory」栏视图（方案 A：3 维画像摘要 + AI 一键整理去重 + 原始记忆默认折叠）

struct AgentSoulMemorySection: View {
    var healthSnapshot: MemoryHealthCheckSnapshot = .empty

    @State private var persistence = IOSMemoryPersistence.shared
    @State private var isAdding = false
    @State private var editingRecord: MemoryRecord?
    @State private var draft = ""
    @State private var errorText: String?
    @State private var consolidationFeedback: String?
    @State private var isConsolidating = false
    @State private var aiRefinedPortrait: AgentMemoryPortraitSummary?
    @State private var isRawListExpanded = false
    @State private var selectedBucket: AgentMemoryPortraitBuilder.Bucket = .all
    @State private var searchQuery = ""
    @State private var swipedRecordId: Int32?
    @State private var recentlyArchivedRecord: MemoryRecord?

    private static let portraitCacheKey = "app.amber.ios.agentSoul.memoryPortrait.v1"

    private var records: [MemoryRecord] {
        persistence.records.filter { !$0.archived && $0.kind != .topic }
    }

    private var archivedRecords: [MemoryRecord] {
        persistence.records.filter { $0.archived && $0.kind != .topic }
    }

    private var filteredRecords: [MemoryRecord] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = (selectedBucket == .archived) ? archivedRecords : records
        return pool.filter { record in
            if selectedBucket != .all && selectedBucket != .archived && AgentMemoryPortraitBuilder.classify(record) != selectedBucket {
                return false
            }
            guard !trimmedQuery.isEmpty else { return true }
            return record.content.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var activePortrait: AgentMemoryPortraitSummary {
        if let aiRefinedPortrait,
           !aiRefinedPortrait.identityAndFocus.isEmpty || !aiRefinedPortrait.preferencesAndTaboos.isEmpty || !aiRefinedPortrait.recentTopics.isEmpty {
            return aiRefinedPortrait
        }
        return AgentMemoryPortraitBuilder.buildDeterministic(from: records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topActionRow
                .padding(.horizontal, 2)

            MemoryHealthCheckCard(snapshot: healthSnapshot)

            if let archived = recentlyArchivedRecord {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AmberTheme.accentAmber)
                    Text("已归档「\(IOSMemoryLibrary.preview(archived.content, limit: 20))」")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AgentEmbodimentPalette.ink)
                        .lineLimit(1)
                    Spacer()
                    Button("撤销") {
                        restore(archived)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                .overlay {
                    Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                }
            }

            if records.isEmpty && archivedRecords.isEmpty {
                emptyState
            } else {
                if !records.isEmpty {
                    portraitSummaryCard
                }

                if let consolidationFeedback {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentEmbodimentPalette.accent)
                        Text(consolidationFeedback)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))
                }

                rawMemoriesCollapsibleSection
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(AgentEmbodimentPalette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            loadCachedPortrait()
        }
        .sheet(isPresented: $isAdding) {
            addMemorySheet
        }
        .sheet(isPresented: Binding(
            get: { editingRecord != nil },
            set: { if !$0 { editingRecord = nil } }
        )) {
            if let record = editingRecord {
                MemoryEditView(
                    recordId: Int(record.id),
                    initialText: record.content,
                    initialScope: IOSMemoryLibrary.scopeTitle(record.scope),
                    initialPinned: record.pinned
                )
            }
        }
    }

    // MARK: - 顶栏：计数 + 「整理去重」+ 「+ 记一条」

    private var topActionRow: some View {
        HStack(spacing: 8) {
            Text("已记住的偏好与背景 · \(records.count) 条")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentEmbodimentPalette.inkSecondary)

            Spacer(minLength: 4)

            if !records.isEmpty {
                Button {
                    Task { await consolidateAndDeduplicate() }
                } label: {
                    HStack(spacing: 4) {
                        if isConsolidating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(isConsolidating ? "整理中" : "整理去重")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                    .overlay {
                        Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isConsolidating)
                .accessibilityIdentifier("embodiment.memory.consolidate")
            }

            Button {
                draft = ""
                isAdding = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text(IOSAppLocalization.string("记一条", defaultValue: "记一条"))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(AgentEmbodimentPalette.accent)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                .overlay {
                    Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.accentBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("embodiment.memory.add")
        }
    }

    // MARK: - 顶部「关于你的画像摘要」卡（3 组核心认知）

    private var portraitSummaryCard: some View {
        let portrait = activePortrait
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(IOSAppLocalization.string("关于你的画像摘要", defaultValue: "关于你的画像摘要"))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(AgentEmbodimentPalette.ink)

                HStack(spacing: 4) {
                    Image(systemName: "person.text.rectangle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("3 维核心认知")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(AgentEmbodimentPalette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))

                Spacer()
            }

            portraitDimensionGroup(
                icon: "briefcase.fill",
                title: "身份与手头重点",
                isAccent: true,
                items: portrait.identityAndFocus,
                emptyHint: "暂未记录身份或重点项目，聊到正在做的事会自动归入此处"
            )

            Divider().overlay(AgentEmbodimentPalette.hairline)

            portraitDimensionGroup(
                icon: "slider.horizontal.3",
                title: "偏好与禁区",
                isAccent: false,
                items: portrait.preferencesAndTaboos,
                emptyHint: "暂未记录偏好或禁区，可在对话中直接叮嘱习惯与不喜欢的做法"
            )

            Divider().overlay(AgentEmbodimentPalette.hairline)

            portraitDimensionGroup(
                icon: "sparkle.magnifyingglass",
                title: "近期关注议题",
                isAccent: false,
                items: portrait.recentTopics,
                emptyHint: "暂无近期跟进议题，日常沟通中的关键背景会自动沉淀"
            )
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
        .accessibilityIdentifier("embodiment.memory.portraitCard")
    }

    private func portraitDimensionGroup(
        icon: String,
        title: String,
        isAccent: Bool,
        items: [String],
        emptyHint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isAccent ? AgentEmbodimentPalette.accent : AgentEmbodimentPalette.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(isAccent ? AgentEmbodimentPalette.accentSoftBg : AgentEmbodimentPalette.cardElevated)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(isAccent ? Color.clear : AgentEmbodimentPalette.hairline, lineWidth: 1)
            }

            if items.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items, id: \.self) { line in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(isAccent ? AgentEmbodimentPalette.accent : AgentEmbodimentPalette.inkMuted)
                                .frame(width: 4.5, height: 4.5)
                                .padding(.top, 6)
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundStyle(AgentEmbodimentPalette.ink)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 原始零散记忆默认折叠区

    private var rawMemoriesCollapsibleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isRawListExpanded.toggle()
                    if !isRawListExpanded {
                        swipedRecordId = nil
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AgentEmbodimentPalette.inkSecondary)

                    Text(
                        isRawListExpanded
                            ? "收起全部 \(records.count) 条原始记忆"
                            : "查看全部 \(records.count) 条原始记忆"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentEmbodimentPalette.ink)

                    Spacer()

                    Text(isRawListExpanded ? "支持筛选与左滑删除" : "已按画像收拢")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AgentEmbodimentPalette.inkMuted)

                    Image(systemName: isRawListExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("embodiment.memory.toggleRawList")

            if isRawListExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    bucketFilterBar

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                        TextField("搜索原始记忆…", text: $searchQuery)
                            .font(.system(size: 13))
                            .foregroundStyle(AgentEmbodimentPalette.ink)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                    .overlay {
                        Capsule(style: .continuous).strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                    }

                    if filteredRecords.isEmpty {
                        Text(selectedBucket == .archived ? "没有已归档的记忆" : "当前筛选下没有匹配的原始记忆")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 9) {
                            ForEach(filteredRecords, id: \.id) { record in
                                MemorySwipeItemCard(
                                    record: record,
                                    isSwipedOpen: swipedRecordId == record.id,
                                    onSetSwiped: { isOpen in
                                        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                            swipedRecordId = isOpen ? record.id : nil
                                        }
                                    },
                                    onEdit: {
                                        editingRecord = record
                                    },
                                    onArchive: {
                                        archive(record)
                                    },
                                    onRestore: {
                                        restore(record)
                                    },
                                    onDelete: {
                                        delete(record)
                                    }
                                )
                            }
                        }
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 11))
                        Text("左滑任意条目可快速删除，或在主对话直接吩咐\(AgentSoulStore.shared.displayName)记住新习惯")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var bucketFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AgentMemoryPortraitBuilder.Bucket.allCases) { bucket in
                    let isSelected = (selectedBucket == bucket)
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedBucket = bucket
                        }
                    } label: {
                        Text(bucket.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? AgentEmbodimentPalette.accent : AgentEmbodimentPalette.inkSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? AgentEmbodimentPalette.accentSoftBg : AgentEmbodimentPalette.cardElevated)
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(isSelected ? AgentEmbodimentPalette.accentBorder : AgentEmbodimentPalette.hairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 22))
                .foregroundStyle(AgentEmbodimentPalette.inkMuted)
            Text(IOSAppLocalization.string(
                "还没有记住任何事。聊过的事我会自己记下来，也可以点右上角「+ 记一条」。",
                defaultValue: "还没有记住任何事。聊过的事我会自己记下来，也可以点右上角「+ 记一条」。"
            ))
            .font(.system(size: 13))
            .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
        }
    }

    private var addMemorySheet: some View {
        NavigationStack {
            Form {
                Section(IOSAppLocalization.string("记一条", defaultValue: "记一条")) {
                    TextEditor(text: $draft)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("embodiment.memory.draft")
                }
            }
            .navigationTitle(IOSAppLocalization.string("新增记忆", defaultValue: "新增记忆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IOSAppLocalization.string("取消", defaultValue: "取消")) { isAdding = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IOSAppLocalization.string("保存", defaultValue: "保存")) {
                        addMemory()
                        isAdding = false
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 增删与一键整理去重

    private func consolidateAndDeduplicate() async {
        guard !isConsolidating else { return }
        isConsolidating = true
        defer { isConsolidating = false }

        let currentRecords = records
        let redundantIds = AgentMemoryPortraitBuilder.redundantRecordIds(in: currentRecords)
        var removedCount = 0

        if !redundantIds.isEmpty {
            let previous = persistence.records
            for id in redundantIds {
                IosMemoryFactory.shared.deleteMemory(id: id)
            }
            if persistence.persist(previousRecords: previous) {
                removedCount = redundantIds.count
                errorText = nil
            } else {
                errorText = persistence.lastErrorMessage ?? "去重保存失败，请重试。"
            }
        }

        let remainingRecords = persistence.records.filter { !$0.archived && $0.kind != .topic }
        let deterministic = AgentMemoryPortraitBuilder.buildDeterministic(from: remainingRecords)
        aiRefinedPortrait = deterministic
        saveCachedPortrait(deterministic)

        if let refined = await AgentMemoryPortraitBuilder.refineWithModelIfAvailable(records: remainingRecords) {
            aiRefinedPortrait = refined
            saveCachedPortrait(refined)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            if removedCount > 0 {
                consolidationFeedback = "已合并清理 \(removedCount) 条重复记忆，画像摘要已更新"
            } else {
                consolidationFeedback = "记忆库无重复项（共 \(remainingRecords.count) 条），画像摘要已刷新"
            }
        }
    }

    private func loadCachedPortrait() {
        guard let data = UserDefaults.standard.data(forKey: Self.portraitCacheKey),
              let cached = try? JSONDecoder().decode(AgentMemoryPortraitSummary.self, from: data) else { return }
        aiRefinedPortrait = cached
    }

    private func saveCachedPortrait(_ summary: AgentMemoryPortraitSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: Self.portraitCacheKey)
    }

    private func addMemory() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let previous = persistence.records
        _ = IosMemoryFactory.shared.addDetailedMemory(
            scope: MemoryScope.core,
            kind: MemoryKind.note,
            content: text,
            assistantId: "core",
            sourceConversationId: nil,
            sourceMessageIds: [],
            supersedesIds: [],
            expiresAt: nil,
            confidence: 1,
            pinned: false,
            archived: false
        )
        if !persistence.persist(previousRecords: previous) {
            errorText = persistence.lastErrorMessage ?? "保存失败，请重试。"
        } else {
            errorText = nil
            aiRefinedPortrait = nil
        }
    }

    private func archive(_ record: MemoryRecord) {
        if swipedRecordId == record.id { swipedRecordId = nil }
        let previous = persistence.records
        guard let archived = IosMemoryFactory.shared.setArchived(id: record.id, archived: true),
              persistence.persist(previousRecords: previous) else {
            errorText = persistence.lastErrorMessage ?? "归档失败，请重试。"
            return
        }
        errorText = nil
        aiRefinedPortrait = nil
        recentlyArchivedRecord = archived
    }

    private func restore(_ record: MemoryRecord) {
        if swipedRecordId == record.id { swipedRecordId = nil }
        let previous = persistence.records
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard IosMemoryFactory.shared.restoreMemory(id: record.id, now: now) != nil,
              persistence.persist(previousRecords: previous) else {
            errorText = persistence.lastErrorMessage ?? "恢复失败，请重试。"
            return
        }
        errorText = nil
        aiRefinedPortrait = nil
        if recentlyArchivedRecord?.id == record.id {
            recentlyArchivedRecord = nil
        }
    }

    private func delete(_ record: MemoryRecord) {
        if swipedRecordId == record.id {
            swipedRecordId = nil
        }
        let previous = persistence.records
        IosMemoryFactory.shared.deleteMemory(id: record.id)
        if !persistence.persist(previousRecords: previous) {
            errorText = persistence.lastErrorMessage ?? "删除失败，请重试。"
        } else {
            errorText = nil
            aiRefinedPortrait = nil
            if recentlyArchivedRecord?.id == record.id {
                recentlyArchivedRecord = nil
            }
        }
    }
}

// MARK: - 单条记忆卡片（展示类型、内容、来源对话、最近使用，支持编辑、归档/恢复与左滑删除）

private struct MemorySwipeItemCard: View {
    let record: MemoryRecord
    let isSwipedOpen: Bool
    let onSetSwiped: (Bool) -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    @State private var dragTranslationX: CGFloat = 0

    private static let deleteActionWidth: CGFloat = 68

    private var categoryInfo: (title: String, isAccent: Bool) {
        switch AgentMemoryPortraitBuilder.classify(record) {
        case .identityAndFocus:
            return ("近期项目", true)
        case .preferencesAndTaboos:
            return ("偏好习惯", false)
        case .recentTopics, .all, .archived:
            return ("近期议题", false)
        }
    }

    private var primaryTypeText: String {
        IOSMemoryLibrary.primaryTypeTitle(for: record)
    }

    private var effectiveTrailingInset: CGFloat {
        let base: CGFloat = isSwipedOpen ? Self.deleteActionWidth : 0
        let combined = base - dragTranslationX
        return min(max(0, combined), Self.deleteActionWidth + 14)
    }

    var body: some View {
        let category = categoryInfo
        let revealDelete = isSwipedOpen || dragTranslationX < -6
        let lastUsed = IOSMemoryLibrary.lastUsedDisplay(for: record)

        ZStack(alignment: .trailing) {
            if revealDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        VStack(spacing: 3) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(IOSAppLocalization.string("删除", defaultValue: "删除"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 64)
                    }
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgentEmbodimentPalette.danger))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("embodiment.memory.swipeDelete")
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(primaryTypeText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentEmbodimentPalette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))

                    Text(category.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentEmbodimentPalette.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.cardElevated))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(AgentEmbodimentPalette.hairline, lineWidth: 1)
                        }

                    Spacer(minLength: 4)

                    if record.archived {
                        Button(action: onRestore) {
                            Text("恢复")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AgentEmbodimentPalette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule(style: .continuous).fill(AgentEmbodimentPalette.accentSoftBg))
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        if !record.archived {
                            Button {
                                onEdit()
                            } label: {
                                Label("编辑记忆", systemImage: "pencil")
                            }
                            Button {
                                onArchive()
                            } label: {
                                Label("归档此条记忆", systemImage: "archivebox")
                            }
                        } else {
                            Button {
                                onRestore()
                            } label: {
                                Label("恢复此条记忆", systemImage: "arrow.uturn.backward")
                            }
                        }
                        if isSwipedOpen {
                            Button(IOSAppLocalization.string("收起操作", defaultValue: "收起操作")) { onSetSwiped(false) }
                        } else {
                            Button(IOSAppLocalization.string("显示删除按钮", defaultValue: "显示删除按钮")) { onSetSwiped(true) }
                        }
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label(IOSAppLocalization.string("删除此条记忆", defaultValue: "删除此条记忆"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentEmbodimentPalette.inkMuted)
                            .frame(width: 24, height: 20, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("embodiment.memory.delete")
                }

                Text(record.content)
                    .font(.system(size: 13))
                    .foregroundStyle(AgentEmbodimentPalette.ink)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(IOSMemoryLibrary.sourceDisplay(for: record))
                        .lineLimit(1)
                    Text("·")
                    Text(lastUsed.text)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(AgentEmbodimentPalette.inkMuted)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgentEmbodimentPalette.cardBg))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AgentEmbodimentPalette.cardStroke, lineWidth: 1)
            }
            .padding(.trailing, effectiveTrailingInset)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                if isSwipedOpen {
                    onSetSwiped(false)
                } else if !record.archived {
                    onEdit()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 18, coordinateSpace: .local)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.25 else { return }
                        dragTranslationX = value.translation.width
                    }
                    .onEnded { value in
                        defer { dragTranslationX = 0 }
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -28 {
                            onSetSwiped(true)
                        } else if value.translation.width > 20 {
                            onSetSwiped(false)
                        }
                    }
            )
        }
    }
}
