import Foundation
@preconcurrency import Shared

/// Silent, low-priority background pipeline triggered when a substantive Episode (`>= 2` Q&A turns) is sealed:
/// 1. Refines the Episode's 1-line high-density summary (`ChatEpisodeStore`).
/// 2. Distills `0~3` durable user facts, preferences, or active project topics, normalizes & semantically
///    deduplicates against `IosMemoryFactory`, persists via `IOSMemoryPersistence`, and refreshes the
///    Embodiment Home「记忆」3D portrait cache without appending raw dialogue logs or duplicate bloat.
@MainActor
final class ChatEpisodeDistiller {
    static let shared = ChatEpisodeDistiller()

    struct CandidateMemory: Codable, Equatable, Sendable {
        let scope: String?
        let kind: String?
        let content: String
    }

    struct ModelDistillationPayload: Codable, Equatable, Sendable {
        let title: String?
        let summary: String?
        let memories: [CandidateMemory]?
    }

    struct DeduplicationSummary: Equatable, Sendable {
        var addedCount = 0
        var reinforcedCount = 0
        var supersededCount = 0
        var skippedCount = 0

        var totalMutated: Int {
            addedCount + reinforcedCount + supersededCount
        }
    }

    private static let portraitCacheKey = "app.amber.ios.agentSoul.memoryPortrait.v1"

    private let episodeStore: ChatEpisodeStore
    private let memoryPersistence: IOSMemoryPersistence
    private let auditStore: IOSMemoryWriteAuditStore
    private let textProvider: any IOSAgentTextProvider
    private let defaults: UserDefaults
    private var inFlightEpisodeIds: Set<String> = []

    init(
        episodeStore: ChatEpisodeStore = .shared,
        memoryPersistence: IOSMemoryPersistence = .shared,
        auditStore: IOSMemoryWriteAuditStore = .shared,
        textProvider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        defaults: UserDefaults = .standard
    ) {
        self.episodeStore = episodeStore
        self.memoryPersistence = memoryPersistence
        self.auditStore = auditStore
        self.textProvider = textProvider
        self.defaults = defaults
    }

    /// Fires a non-blocking `.utility` background task for substantive Episodes (`turnCount >= 2`).
    func scheduleDistillationIfEligible(
        episode: ChatEpisodeRecord,
        episodeMessages: [UIMessage],
        sharedSettings: IOSSharedSettingsStore?,
        conversationMemoryMode: ConversationMemoryMode = .enabled,
        onDigestUpdated: (@MainActor () -> Void)? = nil
    ) {
        guard episode.minimumSubstantiveTurnsMet else { return }
        let flightKey = "\(episode.conversationId)::\(episode.id)"
        guard inFlightEpisodeIds.insert(flightKey).inserted else { return }

        nonisolated(unsafe) let capturedMessages = episodeMessages
        Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlightEpisodeIds.remove(flightKey) }
            await self.distill(
                episode: episode,
                episodeMessages: capturedMessages,
                sharedSettings: sharedSettings,
                conversationMemoryMode: conversationMemoryMode
            )
            onDigestUpdated?()
        }
    }

    /// Direct async entrypoint used by background tasks and deterministic unit tests.
    @discardableResult
    func distill(
        episode: ChatEpisodeRecord,
        episodeMessages: [UIMessage],
        sharedSettings: IOSSharedSettingsStore?,
        conversationMemoryMode: ConversationMemoryMode = .enabled,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) async -> DeduplicationSummary {
        guard episode.minimumSubstantiveTurnsMet else {
            episodeStore.updateEpisodeDigest(
                conversationId: episode.conversationId,
                episodeId: episode.id,
                title: nil,
                summary: nil,
                status: .skippedShort
            )
            return DeduplicationSummary()
        }

        let snapshot = sharedSettings?.snapshot
        let modelOutput = await requestModelDistillation(
            episode: episode,
            messages: episodeMessages,
            settings: snapshot
        )

        if let modelOutput {
            episodeStore.updateEpisodeDigest(
                conversationId: episode.conversationId,
                episodeId: episode.id,
                title: modelOutput.title,
                summary: modelOutput.summary,
                status: .completedModel
            )
        } else {
            episodeStore.updateEpisodeDigest(
                conversationId: episode.conversationId,
                episodeId: episode.id,
                title: nil,
                summary: nil,
                status: .completedDeterministic
            )
        }

        // Respect conversation privacy / memory switch before writing into long-term profile.
        guard conversationMemoryMode != .disabled else {
            return DeduplicationSummary()
        }
        if let runtime = snapshot?.agentRuntime,
           !runtime.enableCoreMemory && !runtime.enableLongTermMemory && !runtime.enableShortTermMemory {
            return DeduplicationSummary()
        }

        let rawCandidates: [CandidateMemory]
        if let modelMemories = modelOutput?.memories {
            rawCandidates = Array(modelMemories.prefix(3))
        } else {
            rawCandidates = Self.extractDeterministicCandidates(from: episodeMessages)
        }

        guard !rawCandidates.isEmpty else {
            return DeduplicationSummary()
        }

        return applyDeduplicatedCandidates(
            rawCandidates,
            conversationId: episode.conversationId,
            sourceMessageIds: Array(episode.messageIds.suffix(4)),
            runtime: snapshot?.agentRuntime,
            nowMillis: nowMillis
        )
    }

    // MARK: - Semantic Deduplication & Profile Persistence

    func applyDeduplicatedCandidates(
        _ candidates: [CandidateMemory],
        conversationId: String,
        sourceMessageIds: [String],
        runtime: AgentRuntimeSetting? = nil,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000.0)
    ) -> DeduplicationSummary {
        var outcome = DeduplicationSummary()
        let cappedCandidates = Array(candidates.prefix(3))
        guard !cappedCandidates.isEmpty else { return outcome }

        let previousRecords = memoryPersistence.records
        var liveRecords = IosMemoryFactory.shared.snapshotRecords().filter {
            !$0.archived && $0.kind != .topic
        }

        var reinforcedIds: [Int32] = []
        var addedRecords: [MemoryRecord] = []
        var supersededPairs: [(old: MemoryRecord, replacement: MemoryRecord)] = []
        var batchFingerprints: [String] = []

        for candidate in cappedCandidates {
            let cleaned = Self.normalizeMemorySentence(candidate.content)
            guard Self.isValidDurableCandidate(cleaned) else {
                outcome.skippedCount += 1
                continue
            }

            let candidateFp = AgentMemoryPortraitBuilder.fingerprint(cleaned)
            guard !candidateFp.isEmpty else {
                outcome.skippedCount += 1
                continue
            }

            // Dedup within the same 0~3 candidate batch first.
            if batchFingerprints.contains(where: { Self.isSameMeaning(fpA: $0, fpB: candidateFp, textA: $0, textB: cleaned) }) {
                outcome.skippedCount += 1
                continue
            }

            let resolvedScope = Self.resolveScope(candidate.scope, runtime: runtime)
            guard let scope = resolvedScope else {
                outcome.skippedCount += 1
                continue
            }
            let kind = Self.resolveKind(candidate.kind, content: cleaned)

            switch Self.matchExistingRecord(cleaned, candidateFingerprint: candidateFp, in: liveRecords) {
            case .exactOrNearDuplicate(let existing):
                if !reinforcedIds.contains(existing.id) {
                    reinforcedIds.append(existing.id)
                    outcome.reinforcedCount += 1
                }
                batchFingerprints.append(candidateFp)

            case .supersedeOutdated(let existing):
                if !existing.pinned,
                   existing.scope != .core,
                   IosMemoryFactory.shared.setArchived(id: existing.id, archived: true) != nil {
                    let replacement = IosMemoryFactory.shared.addDetailedMemory(
                        scope: existing.scope,
                        kind: kind,
                        content: cleaned,
                        assistantId: existing.assistantId,
                        sourceConversationId: conversationId,
                        sourceMessageIds: sourceMessageIds,
                        supersedesIds: [KotlinInt(value: existing.id)],
                        expiresAt: existing.expiresAt,
                        confidence: existing.confidence,
                        pinned: false,
                        archived: false
                    )
                    IosMemoryFactory.shared.replaceTopicMember(oldId: existing.id, newId: replacement.id)
                    liveRecords.removeAll { $0.id == existing.id }
                    liveRecords.append(replacement)
                    supersededPairs.append((existing, replacement))
                    outcome.supersededCount += 1
                    batchFingerprints.append(candidateFp)
                } else {
                    if !reinforcedIds.contains(existing.id) {
                        reinforcedIds.append(existing.id)
                        outcome.reinforcedCount += 1
                    }
                    batchFingerprints.append(candidateFp)
                }

            case .none:
                let assistantId: String
                switch scope {
                case .core:
                    assistantId = "core"
                case .shortTerm:
                    assistantId = IosMemoryFactory.shared.SHORT_TERM_MEMORY_ID
                default:
                    assistantId = IosMemoryFactory.shared.LONG_TERM_MEMORY_ID
                }
                let created = IosMemoryFactory.shared.addDetailedMemory(
                    scope: scope,
                    kind: kind,
                    content: cleaned,
                    assistantId: assistantId,
                    sourceConversationId: conversationId,
                    sourceMessageIds: sourceMessageIds,
                    supersedesIds: [],
                    expiresAt: nil,
                    confidence: 1,
                    pinned: false,
                    archived: false
                )
                liveRecords.append(created)
                addedRecords.append(created)
                outcome.addedCount += 1
                batchFingerprints.append(candidateFp)
            }
        }

        if !reinforcedIds.isEmpty {
            IosMemoryFactory.shared.reinforceMemories(
                ids: reinforcedIds.map { KotlinInt(value: $0) },
                timestamp: nowMillis
            )
        }

        guard outcome.totalMutated > 0 else { return outcome }
        guard memoryPersistence.persist(previousRecords: previousRecords) else {
            return DeduplicationSummary(skippedCount: cappedCandidates.count)
        }

        for (old, replacement) in supersededPairs {
            auditStore.record(
                action: "edit",
                status: "auto_saved",
                reason: "Episode 封存静默更新取代 #\(old.id)",
                memoryId: Int(replacement.id),
                scope: replacement.scope.wireName,
                kind: replacement.kind.wireName,
                contentPreview: IOSMemoryLibrary.preview(replacement.content)
            )
        }
        for added in addedRecords {
            auditStore.record(
                action: "create",
                status: "auto_saved",
                reason: "Episode 封存静默提纯",
                memoryId: Int(added.id),
                scope: added.scope.wireName,
                kind: added.kind.wireName,
                contentPreview: IOSMemoryLibrary.preview(added.content)
            )
        }

        // Refresh cached 3D portrait summary so Embodiment Home「记忆」Tab immediately reflects new insights.
        refreshCachedEmbodimentPortrait()
        return outcome
    }

    private func refreshCachedEmbodimentPortrait() {
        let active = memoryPersistence.records.filter { !$0.archived && $0.kind != .topic }
        guard !active.isEmpty else {
            defaults.removeObject(forKey: Self.portraitCacheKey)
            return
        }
        let deterministic = AgentMemoryPortraitBuilder.buildDeterministic(from: active)
        if let encoded = try? JSONEncoder().encode(deterministic) {
            defaults.set(encoded, forKey: Self.portraitCacheKey)
        }
    }

    // MARK: - Lightweight Background Model Call

    private func requestModelDistillation(
        episode: ChatEpisodeRecord,
        messages: [UIMessage],
        settings: Settings?
    ) async -> ModelDistillationPayload? {
        guard let settings else { return nil }
        let model = settings.findModelById(uuid: settings.compressModelId) ?? settings.getCurrentChatModel()
        guard let model,
              let provider = ChatProviderConfiguration.provider(for: model, providers: settings.providers),
              ChatProviderConfiguration.issue(for: model, provider: provider) == nil else {
            return nil
        }

        let transcriptExcerpt = Self.compactEpisodeExcerpt(from: messages, maxChars: 3_600)
        guard !transcriptExcerpt.isEmpty else { return nil }

        let assistant = settings.getCurrentAssistant()
        let baseParams = ChatViewModel.makeAuxiliaryTextGenerationParams(
            model: model,
            assistantHeaders: ChatProviderConfiguration.requestHeaders(
                for: provider,
                assistant: assistant.customHeaders,
                model: model.customHeaders,
                conversationId: nil
            ),
            assistantBodies: assistant.customBodies
        )
        let params = TextGenerationParams(
            model: baseParams.model,
            temperature: KotlinFloat(value: 0.1),
            topP: baseParams.topP,
            maxTokens: KotlinInt(value: 512),
            tools: [],
            reasoningLevel: .off,
            customHeaders: baseParams.customHeaders,
            customBody: baseParams.customBody
        )

        let prompt = """
        你是对话归档与用户画像提纯器。请阅读下面刚结束的一段话题对话，完成两件事：
        1. 生成高密度单行话题索引：`title`（不超过 14 字主题词）与 `summary`（不超过 48 字，保留核心实体、关键数字/金额/时间、明确结论或待办）。
        2. 提炼 0~3 条值得长期跨话题记住的「用户事实、明确偏好/禁忌、正在推进的重点项目/议题」放入 `memories`。
           - 严禁抄录原始对话流水账、临时寒暄、一次性指令、密码/Token/密钥等敏感信息。
           - 没有新增长期价值信息时，`memories` 必须返回空数组 `[]`。
           - 每条 `content` 必须是一句独立完整的陈述句（12~56 字）。
           - `scope` 取 `"LONG_TERM"` 或 `"SHORT_TERM"`；`kind` 取 `"USER"`、`"FEEDBACK"`、`"PROJECT"` 或 `"REFERENCE"`。

        对话片段：
        \(transcriptExcerpt)

        只输出严格 JSON 对象，不要任何解释或 Markdown 围栏：
        {"title":"...","summary":"...","memories":[{"scope":"LONG_TERM","kind":"PROJECT","content":"..."}]}
        """

        let providerAdapter = textProvider
        do {
            let chunk = try await withThrowingTaskGroup(of: MessageChunk.self) { group in
                group.addTask {
                    try await providerAdapter.generateText(
                        providerSetting: provider,
                        messages: [UIMessage.companion.user(prompt: prompt)],
                        params: params
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw CancellationError()
                }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }
            guard let rawText = chunk.choices.first?.message?.toText() else { return nil }
            return Self.decodePayload(from: rawText)
        } catch {
            return nil
        }
    }

    static func decodePayload(from rawText: String) -> ModelDistillationPayload? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        let jsonSlice = String(trimmed[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ModelDistillationPayload.self, from: data) else {
            return nil
        }
        return decoded
    }

    // MARK: - Similarity & Deterministic Fallback Helpers

    enum ExistingMatch {
        case none
        case exactOrNearDuplicate(MemoryRecord)
        case supersedeOutdated(MemoryRecord)
    }

    static func matchExistingRecord(
        _ candidateText: String,
        candidateFingerprint: String,
        in records: [MemoryRecord]
    ) -> ExistingMatch {
        let candidateNumbers = numericTokens(in: candidateText)
        var bestRecord: MemoryRecord?
        var bestSimilarity: Double = 0

        for record in records {
            let existingText = normalizeMemorySentence(record.content)
            let existingFp = AgentMemoryPortraitBuilder.fingerprint(existingText)
            guard !existingFp.isEmpty else { continue }

            if existingFp == candidateFingerprint {
                return .exactOrNearDuplicate(record)
            }
            if existingFp.count >= 10 && candidateFingerprint.count >= 10
                && (existingFp.contains(candidateFingerprint) || candidateFingerprint.contains(existingFp)) {
                let existingNumbers = numericTokens(in: existingText)
                if candidateNumbers == existingNumbers || candidateText.count <= existingText.count {
                    return .exactOrNearDuplicate(record)
                }
                return .supersedeOutdated(record)
            }

            let similarity = combinedSimilarity(
                fpA: existingFp,
                fpB: candidateFingerprint,
                textA: existingText,
                textB: candidateText
            )
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestRecord = record
            }
        }

        guard let matched = bestRecord else { return .none }
        let existingNumbers = numericTokens(in: matched.content)
        if bestSimilarity >= 0.56 {
            if !candidateNumbers.isEmpty && !existingNumbers.isEmpty && candidateNumbers != existingNumbers {
                return .supersedeOutdated(matched)
            }
            return .exactOrNearDuplicate(matched)
        }
        if bestSimilarity >= 0.44,
           !candidateNumbers.isEmpty,
           !existingNumbers.isEmpty,
           candidateNumbers != existingNumbers {
            return .supersedeOutdated(matched)
        }
        return .none
    }

    private static func isSameMeaning(fpA: String, fpB: String, textA: String, textB: String) -> Bool {
        if fpA == fpB { return true }
        if fpA.count >= 10 && fpB.count >= 10 && (fpA.contains(fpB) || fpB.contains(fpA)) {
            return true
        }
        return combinedSimilarity(fpA: fpA, fpB: fpB, textA: textA, textB: textB) >= 0.58
    }

    static func combinedSimilarity(fpA: String, fpB: String, textA: String, textB: String) -> Double {
        let bigram = bigramJaccard(fpA, fpB)
        let token = recallTokenJaccard(textA, textB)
        return max(bigram, (bigram * 0.55) + (token * 0.45))
    }

    private static func bigramJaccard(_ a: String, _ b: String) -> Double {
        let charsA = Array(a)
        let charsB = Array(b)
        guard charsA.count >= 2, charsB.count >= 2 else { return a == b ? 1.0 : 0.0 }
        var setA = Set<String>()
        for i in 0..<(charsA.count - 1) { setA.insert(String([charsA[i], charsA[i + 1]])) }
        var setB = Set<String>()
        for i in 0..<(charsB.count - 1) { setB.insert(String([charsB[i], charsB[i + 1]])) }
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        return Double(setA.intersection(setB).count) / Double(union)
    }

    private static func recallTokenJaccard(_ a: String, _ b: String) -> Double {
        let tokensA = ChatEpisodeTextNormalizer.searchTokens(in: a)
        let tokensB = ChatEpisodeTextNormalizer.searchTokens(in: b)
        let union = tokensA.union(tokensB).count
        guard union > 0 else { return 0 }
        return Double(tokensA.intersection(tokensB).count) / Double(union)
    }

    private static func numericTokens(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var tokens = Set<String>()
        for match in regex.matches(in: text, range: nsRange) {
            if let range = Range(match.range, in: text) {
                tokens.insert(text[range].replacingOccurrences(of: ",", with: ""))
            }
        }
        return tokens
    }

    static func normalizeMemorySentence(_ raw: String) -> String {
        let redacted = IOSContextCompactionFidelity.redactCredentials(raw)
        return AgentMemoryPortraitBuilder.cleanBulletText(redacted)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidDurableCandidate(_ text: String) -> Bool {
        guard text.count >= 8, text.count <= 80 else { return false }
        if text.contains("[REDACTED]") { return false }
        let lowered = text.lowercased()
        let sensitiveMarkers = [
            "api key", "apikey", "secret", "password", "passwd", "bearer ", "sk-",
            "助记词", "私钥", "验证码", "身份证号", "银行卡号", "cvv"
        ]
        if sensitiveMarkers.contains(where: { lowered.contains($0) }) {
            return false
        }
        return true
    }

    private static func resolveScope(_ rawScope: String?, runtime: AgentRuntimeSetting?) -> MemoryScope? {
        let upper = rawScope?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "LONG_TERM"
        let preferred: MemoryScope = upper == "SHORT_TERM" ? .shortTerm : .longTerm
        guard let runtime else { return preferred }
        if preferred == .longTerm && runtime.enableLongTermMemory { return .longTerm }
        if preferred == .shortTerm && runtime.enableShortTermMemory { return .shortTerm }
        if runtime.enableLongTermMemory { return .longTerm }
        if runtime.enableShortTermMemory { return .shortTerm }
        if runtime.enableCoreMemory { return .core }
        return nil
    }

    private static func resolveKind(_ rawKind: String?, content: String) -> MemoryKind {
        switch rawKind?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "USER": return .user
        case "FEEDBACK": return .feedback
        case "PROJECT": return .project
        case "REFERENCE": return .reference
        case "ROUTINE": return .routine
        default:
            let lowered = content.lowercased()
            let prefKeywords = [
                "偏好", "习惯", "喜欢", "讨厌", "严禁", "禁止", "不要", "不接受", "绝不",
                "铁律", "规则", "必须", "风格", "语气", "字号", "配色", "遵循"
            ]
            if prefKeywords.contains(where: { lowered.contains($0) }) {
                return .feedback
            }
            let focusKeywords = [
                "正在推进", "项目", "仓库", "工程", "开发", "我是", "身份", "负责", "主业",
                "架构", "部署", "服务器", "云端", "worktree", "分支", "四端"
            ]
            if focusKeywords.contains(where: { lowered.contains($0) }) {
                return .project
            }
            return .note
        }
    }

    /// Conservative offline fallback: only extracts explicit user self-statements / durable preferences.
    static func extractDeterministicCandidates(from messages: [UIMessage]) -> [CandidateMemory] {
        let explicitMarkers = [
            "记住", "我喜欢", "我不喜欢", "我偏好", "我的习惯", "不要用", "严禁", "禁止",
            "我正在开发", "我正在推进", "我负责", "我是"
        ]
        var found: [CandidateMemory] = []
        for message in messages where message.role == MessageRole.user && !ChatMessageProjector.isSubAgentResult(message) {
            let text = message.toText()
            let clauses = text.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n；;"))
            for clause in clauses {
                let trimmed = normalizeMemorySentence(clause)
                guard trimmed.count >= 8, trimmed.count <= 68 else { continue }
                if explicitMarkers.contains(where: { trimmed.contains($0) }) {
                    found.append(CandidateMemory(scope: "LONG_TERM", kind: nil, content: trimmed))
                    if found.count >= 2 { return found }
                }
            }
        }
        return found
    }

    private static func compactEpisodeExcerpt(from messages: [UIMessage], maxChars: Int) -> String {
        var chunks: [String] = []
        var used = 0
        for message in messages {
            guard message.role != MessageRole.system,
                  !IOSOrchestrationConfigurationCodec.isOrchestrationConfigurationMessage(message) else {
                continue
            }
            let role = message.role == MessageRole.user ? "用户" : "助手"
            let rawText = ChatMessageProjector.isSubAgentResult(message)
                ? (ChatEpisodeTextNormalizer.mailboxBody(of: message) ?? message.toText())
                : message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.joined(separator: " ")
            let clean = ChatEpisodeTextNormalizer.singleLine(rawText, maxChars: 420)
            guard !clean.isEmpty else { continue }
            let line = "\(role)：\(clean)"
            if used + line.count > maxChars { break }
            chunks.append(line)
            used += line.count + 1
        }
        return chunks.joined(separator: "\n")
    }
}
