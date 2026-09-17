import Foundation
import Observation
import UIKit
@preconcurrency import Shared

/// Deterministic memory maintenance ("dream" maintenance pass): merges exact
/// duplicates, archives expired records, promotes durable short-term records to
/// long_term and prunes dead topic member ids. Everything here is local and
/// reversible-by-inspection; model-driven rewrites (topic suggestions) are a
/// separate gated pass layered on top.
@Observable
@MainActor
final class IOSMemoryConsolidationCoordinator {
    static let shared = IOSMemoryConsolidationCoordinator()

    private(set) var isRunning = false
    private(set) var statusMessage: String
    private(set) var lastOutcome: MaintenanceOutcome?

    private let defaults: UserDefaults
    private let persistence: IOSMemoryPersistence
    private let audit: IOSMemoryWriteAuditStore
    private let provider: any IOSAgentTextProvider
    private let environment: () -> (foreground: Bool, idle: Bool, charging: Bool)
    private let now: () -> Date
    private weak var settings: IOSSharedSettingsStore?
    private var writesEnabled: () -> Bool = { true }
    private static let statusKey = "app.amber.ios.memoryConsolidation.status.v1"
    private static let budgetKey = "app.amber.ios.memoryConsolidation.dailyRuns.v1"
    /// short_term records untouched for this long have proven durable.
    private static let promotionAgeMillis: Int64 = 14 * 24 * 60 * 60 * 1_000

    struct MaintenanceOutcome {
        var mergedDuplicates = 0
        var archivedExpired = 0
        var promotedToLongTerm = 0
        var cleanedTopics = 0
        var droppedMemberIds = 0
        var retiredTopics = 0
        var previousRecords: [MemoryRecord] = []

        var changed: Bool {
            mergedDuplicates + archivedExpired + promotedToLongTerm + droppedMemberIds + retiredTopics > 0
        }

        var summary: String {
            [
                mergedDuplicates > 0 ? "合并重复 \(mergedDuplicates) 条" : nil,
                archivedExpired > 0 ? "归档过期 \(archivedExpired) 条" : nil,
                promotedToLongTerm > 0 ? "短期转长期 \(promotedToLongTerm) 条" : nil,
                droppedMemberIds > 0 ? "清理主题成员 \(droppedMemberIds) 条" : nil,
                retiredTopics > 0 ? "收起空主题 \(retiredTopics) 个" : nil,
            ].compactMap { $0 }.joined(separator: "，")
        }
    }

    init(
        defaults: UserDefaults = .standard,
        persistence: IOSMemoryPersistence = .shared,
        audit: IOSMemoryWriteAuditStore = .shared,
        provider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        environment: @escaping () -> (foreground: Bool, idle: Bool, charging: Bool) = {
            (UIApplication.shared.applicationState == .active,
             BackgroundGenerationKeepAlive.shared.activeLeaseIds.isEmpty,
             UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.persistence = persistence
        self.audit = audit
        self.provider = provider
        self.environment = environment
        self.now = now
        statusMessage = defaults.string(forKey: Self.statusKey) ?? "定期合并重复、归档过期并整理主题。"
    }

    func configure(settings: IOSSharedSettingsStore, writesEnabled: @escaping () -> Bool = { true }) {
        self.settings = settings
        self.writesEnabled = writesEnabled
    }

    /// Scheduled entry point: honors worker switch, environment constraints and
    /// the daily budget. Safe to call often — every gate is cheap.
    func resume() {
        Task { await runIfDue() }
    }

    /// Manual entry point from the memory settings UI: skips environment and
    /// budget gates but still requires the feature switches.
    func runNow() {
        Task { await run() }
    }

    private func runIfDue() async {
        guard !isRunning, let settings else { return }
        let worker = settings.agentRuntime.memoryWorker
        // Dream passes key off their own toggles, not worker.enabled — the
        // 提炼 toggle in the UI writes worker.enabled/extractionEnabled and
        // must not silently disable 整理.
        guard MemoryWorkerDreamGate.shared.isAnyDreamEnabled(worker: worker) else { return }
        let state = environment()
        guard state.foreground else { return }
        guard !worker.runOnlyOnIdle || state.idle else { return }
        guard !worker.runOnlyOnCharging || state.charging else { return }
        guard persistence.loadState == .loaded || persistence.loadState == .missing else { return }
        let day = Calendar.current.startOfDay(for: now()).timeIntervalSince1970
        let budget = defaults.dictionary(forKey: Self.budgetKey) ?? [:]
        let runs = (budget["day"] as? Double) == day ? (budget["count"] as? Int ?? 0) : 0
        guard runs < Int(worker.dreamMaxDailyRuns) else { return }
        defaults.set(["day": day, "count": runs + 1], forKey: Self.budgetKey)
        await run()
    }

    /// Internal (not private) so tests can await a full pass directly.
    func run() async {
        guard !isRunning, let settings else { return }
        let worker = settings.agentRuntime.memoryWorker
        guard MemoryWorkerDreamGate.shared.isAnyDreamEnabled(worker: worker) else { return }
        guard persistence.loadState == .loaded || persistence.loadState == .missing else {
            report("记忆尚未就绪，稍后自动整理。")
            return
        }
        isRunning = true
        defer { isRunning = false }

        if MemoryWorkerDreamGate.shared.isMaintenanceEnabled(worker: worker) {
            let outcome = performMaintenance(nowMillis: Int64(now().timeIntervalSince1970 * 1_000))
            lastOutcome = outcome
            if outcome.changed {
                guard persistence.persist(previousRecords: outcome.previousRecords) else {
                    let reason = persistence.lastErrorMessage ?? "整理结果无法写入记忆。"
                    audit.record(action: "consolidate", status: "failed", reason: reason)
                    report(reason)
                    return
                }
                audit.record(
                    action: "consolidate",
                    status: "auto_saved",
                    reason: outcome.summary
                )
                report("已整理记忆：\(outcome.summary)。")
            } else {
                report("记忆库已整洁，无需整理。")
            }
        }

        guard MemoryWorkerDreamGate.shared.isModelDreamEnabled(worker: worker) else { return }
        await runTopicPass(settings: settings, worker: worker)
    }

    /// Model pass: asks the daydream model to group the live (non-topic,
    /// non-core) records into a small set of topics. Applies results through
    /// the idempotent `upsertTopicRecord`; merge/archive suggestions are not
    /// applied — destructive consolidation stays deterministic.
    private func runTopicPass(settings: IOSSharedSettingsStore, worker: MemoryWorkerSetting) async {
        guard writesEnabled() else {
            report("记忆写入权限已关闭，跳过主题整理。")
            return
        }
        let snapshot = IosMemoryFactory.shared.snapshotRecords()
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let members = snapshot.filter { record in
            !record.archived && record.kind != .topic && record.scope != .core &&
                (record.expiresAt?.int64Value ?? Int64.max) > nowMs
        }
        let existingTopics = snapshot.filter { $0.kind == .topic && !$0.archived }
        guard members.count >= 2 else { return }

        report("正在整理记忆主题…")
        do {
            let request = try makeTopicRequest(
                settings: settings.snapshot, worker: worker,
                members: members, existingTopics: existingTopics
            )
            let text = try await Self.generate(request, timeoutMillis: worker.timeoutMs)
            let output = try Self.decodeTopics(text)

            // The model call suspends; recheck the switch and permission, then
            // rebuild the live id set from a fresh snapshot so members deleted
            // or archived mid-flight can't be written into a topic.
            let runtime = settings.agentRuntime.memoryWorker
            guard MemoryWorkerDreamGate.shared.isModelDreamEnabled(worker: runtime), writesEnabled() else {
                report("主题聚合已关闭，本次结果未写入。")
                return
            }
            let nowMs2 = Int64(now().timeIntervalSince1970 * 1_000)
            let liveIds = Set(IosMemoryFactory.shared.snapshotRecords().filter { record in
                !record.archived && record.kind != .topic && record.scope != .core &&
                    (record.expiresAt?.int64Value ?? Int64.max) > nowMs2
            }.map { Int($0.id) })
            var upserted: [MemoryRecord] = []
            let previous = IosMemoryFactory.shared.snapshotRecords()
            for suggestion in output.topics {
                let memberIds = suggestion.memberIds.filter { liveIds.contains($0) }
                guard memberIds.count >= 2 else { continue }
                if let record = IosMemoryFactory.shared.upsertTopicRecord(
                    title: suggestion.title,
                    summary: suggestion.summary,
                    memberIds: memberIds.map { KotlinInt(value: Int32($0)) }
                ) {
                    upserted.append(record)
                }
            }
            guard !upserted.isEmpty else {
                report("主题整理完成，没有新的分组。")
                return
            }
            guard persistence.persist(previousRecords: previous) else {
                let reason = persistence.lastErrorMessage ?? "主题结果无法写入记忆。"
                audit.record(action: "topic", status: "failed", reason: reason)
                report(reason)
                return
            }
            audit.record(
                action: "topic",
                status: "auto_saved",
                reason: "聚合/更新 \(upserted.count) 个主题"
            )
            report("已聚合 \(upserted.count) 个记忆主题。")
        } catch is CancellationError {
            report("主题整理已中断。")
        } catch {
            let reason = "主题整理失败：\(error.localizedDescription)"
            audit.record(action: "topic", status: "failed", reason: reason)
            report(reason)
        }
    }

    /// Pure deterministic pass over the current snapshot. Applies mutations via
    /// IosMemoryFactory so every write goes through the same path as other
    /// owners; persists once at the end through the caller.
    func performMaintenance(nowMillis: Int64) -> MaintenanceOutcome {
        let previous = IosMemoryFactory.shared.snapshotRecords()
        var outcome = MaintenanceOutcome()
        var current = previous

        // 1. Expired records become archived (never deleted — audit trail keeps
        //    provenance; recall and prompts already exclude archived rows).
        for record in current where !record.archived {
            guard let expiresAt = record.expiresAt?.int64Value, expiresAt <= nowMillis else { continue }
            if IosMemoryFactory.shared.setArchived(id: record.id, archived: true) != nil {
                outcome.archivedExpired += 1
            }
        }
        current = IosMemoryFactory.shared.snapshotRecords()

        // 2. Exact duplicate merge within the same scope. Topic rows are never
        //    merge candidates; losers are deleted and their provenance folds
        //    into the winner.
        var groups: [String: [MemoryRecord]] = [:]
        for record in current where !record.archived && record.kind != .topic {
            let key = "\(record.scope.wireName)\u{1F}\(record.content.trimmingCharacters(in: .whitespacesAndNewlines))"
            groups[key, default: []].append(record)
        }
        for (_, group) in groups where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            guard let winner = ordered.first else { continue }
            let losers = ordered.dropFirst()
            var sourceMessageIds = winner.sourceMessageIds
            var supersedesIds = winner.supersedesIds.map { Int(truncating: $0) }
            var sourceConversationId = winner.sourceConversationId
            for loser in losers {
                for messageId in loser.sourceMessageIds where !sourceMessageIds.contains(messageId) {
                    sourceMessageIds.append(messageId)
                }
                supersedesIds.append(Int(loser.id))
                supersedesIds.append(contentsOf: loser.supersedesIds.map { Int(truncating: $0) })
                if sourceConversationId == nil { sourceConversationId = loser.sourceConversationId }
            }
            let merged = MemoryRecord(
                id: winner.id,
                content: winner.content,
                scope: winner.scope,
                kind: winner.kind,
                assistantId: winner.assistantId,
                sourceConversationId: sourceConversationId,
                sourceMessageIds: sourceMessageIds,
                supersedesIds: Array(Set(supersedesIds)).sorted().map { KotlinInt(value: Int32($0)) },
                expiresAt: winner.expiresAt,
                confidence: winner.confidence,
                pinned: winner.pinned,
                archived: winner.archived,
                createdAt: winner.createdAt,
                updatedAt: nowMillis,
                lastUsedAt: winner.lastUsedAt,
                topicTitle: winner.topicTitle,
                memberIds: winner.memberIds
            )
            if IosMemoryFactory.shared.updateRecord(record: merged) != nil {
                // Topic member references to a loser are remapped to the winner
                // before deletion so the grouping survives the merge.
                let loserIds = Set(losers.map { Int($0.id) })
                for topic in IosMemoryFactory.shared.snapshotRecords() where topic.kind == .topic {
                    let memberIds = topic.memberIds.map { Int(truncating: $0) }
                    guard memberIds.contains(where: { loserIds.contains($0) }) else { continue }
                    var remapped: [Int] = []
                    for id in memberIds {
                        let mapped = loserIds.contains(id) ? Int(winner.id) : id
                        if !remapped.contains(mapped) { remapped.append(mapped) }
                    }
                    _ = IosMemoryFactory.shared.updateRecord(record: MemoryRecord(
                        id: topic.id, content: topic.content, scope: topic.scope, kind: topic.kind,
                        assistantId: topic.assistantId, sourceConversationId: topic.sourceConversationId,
                        sourceMessageIds: topic.sourceMessageIds, supersedesIds: topic.supersedesIds,
                        expiresAt: topic.expiresAt, confidence: topic.confidence, pinned: topic.pinned,
                        archived: topic.archived, createdAt: topic.createdAt, updatedAt: nowMillis,
                        lastUsedAt: topic.lastUsedAt, topicTitle: topic.topicTitle,
                        memberIds: remapped.map { KotlinInt(value: Int32($0)) }
                    ))
                }
                for loser in losers {
                    IosMemoryFactory.shared.deleteMemory(id: loser.id)
                }
                outcome.mergedDuplicates += losers.count
            }
        }
        current = IosMemoryFactory.shared.snapshotRecords()

        // 3. Durable short-term records promote to long_term.
        for record in current where !record.archived && record.kind != .topic && record.scope == .shortTerm {
            guard nowMillis - record.updatedAt >= Self.promotionAgeMillis else { continue }
            let promoted = MemoryRecord(
                id: record.id,
                content: record.content,
                scope: .longTerm,
                kind: record.kind,
                assistantId: IosMemoryFactory.shared.LONG_TERM_MEMORY_ID,
                sourceConversationId: record.sourceConversationId,
                sourceMessageIds: record.sourceMessageIds,
                supersedesIds: record.supersedesIds,
                expiresAt: record.expiresAt,
                confidence: record.confidence,
                pinned: record.pinned,
                archived: record.archived,
                createdAt: record.createdAt,
                updatedAt: nowMillis,
                lastUsedAt: record.lastUsedAt,
                topicTitle: record.topicTitle,
                memberIds: record.memberIds
            )
            if IosMemoryFactory.shared.updateRecord(record: promoted) != nil {
                outcome.promotedToLongTerm += 1
            }
        }
        current = IosMemoryFactory.shared.snapshotRecords()

        // 4. Topic member lists drop ids that no longer point at live,
        //    non-topic, non-core members (deleted, archived or merged away).
        //    A live topic that shrinks below 2 members is retired (archived) —
        //    a later model pass can revive it through upsertTopicRecord.
        let liveById = Dictionary(uniqueKeysWithValues: current.map { (Int($0.id), $0) })
        for topic in current where topic.kind == .topic && !topic.archived {
            let kept = topic.memberIds.map { Int(truncating: $0) }.filter { id in
                guard let member = liveById[id] else { return false }
                return !member.archived && member.kind != .topic && member.scope != .core
            }
            let pruned = kept != topic.memberIds.map({ Int(truncating: $0) })
            guard pruned || kept.count < 2 else { continue }
            let updated = MemoryRecord(
                id: topic.id,
                content: topic.content,
                scope: topic.scope,
                kind: topic.kind,
                assistantId: topic.assistantId,
                sourceConversationId: topic.sourceConversationId,
                sourceMessageIds: topic.sourceMessageIds,
                supersedesIds: topic.supersedesIds,
                expiresAt: topic.expiresAt,
                confidence: topic.confidence,
                pinned: topic.pinned,
                archived: kept.count < 2,
                createdAt: topic.createdAt,
                updatedAt: nowMillis,
                lastUsedAt: topic.lastUsedAt,
                topicTitle: topic.topicTitle,
                memberIds: kept.map { KotlinInt(value: Int32($0)) }
            )
            if IosMemoryFactory.shared.updateRecord(record: updated) != nil {
                outcome.cleanedTopics += 1
                outcome.droppedMemberIds += topic.memberIds.count - kept.count
                if kept.count < 2 { outcome.retiredTopics += 1 }
            }
        }

        return MaintenanceOutcome(
            mergedDuplicates: outcome.mergedDuplicates,
            archivedExpired: outcome.archivedExpired,
            promotedToLongTerm: outcome.promotedToLongTerm,
            cleanedTopics: outcome.cleanedTopics,
            droppedMemberIds: outcome.droppedMemberIds,
            retiredTopics: outcome.retiredTopics,
            previousRecords: previous
        )
    }

    private struct DreamOutput: Decodable {
        struct TopicSuggestion: Decodable {
            let title: String
            let summary: String
            let memberIds: [Int]
        }
        let topics: [TopicSuggestion]
    }

    private static func decodeTopics(_ text: String) throws -> DreamOutput {
        guard let json = IOSDeepReadDraftGenerator.extractJSONObject(text),
              let result = try? JSONDecoder().decode(DreamOutput.self, from: Data(json.utf8)) else {
            throw Failure("主题整理模型没有返回有效结果。")
        }
        return result
    }

    private func makeTopicRequest(
        settings: Settings,
        worker: MemoryWorkerSetting,
        members: [MemoryRecord],
        existingTopics: [MemoryRecord]
    ) throws -> Request {
        let model = worker.daydreamFollowCompressModel
            ? (settings.findModelById(uuid: settings.compressModelId) ?? settings.getCurrentChatModel())
            : settings.findModelById(uuid: worker.daydreamModelId)
        guard let model,
              let providerSetting = ChatProviderConfiguration.provider(for: model, providers: settings.providers),
              ChatProviderConfiguration.issue(for: model, provider: providerSetting) == nil else {
            throw Failure("请配置可用的主题整理模型（默认使用压缩模型）。")
        }
        let membersJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: members.map { [
                "id": Int($0.id),
                "content": IOSMemoryLibrary.preview($0.content, limit: 120),
                "scope": $0.scope.wireName,
                "kind": $0.kind.wireName,
            ] },
            options: [.sortedKeys]
        ), as: UTF8.self)
        let topicsJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: existingTopics.map { [
                "id": Int($0.id),
                "title": $0.topicTitle ?? "",
                "memberIds": $0.memberIds.map { Int(truncating: $0) },
            ] },
            options: [.sortedKeys]
        ), as: UTF8.self)
        let prompt = """
        你负责把已保存的记忆条目整理成少量主题分组。memories 是 {id, content, scope, kind} 列表，existing_topics 是已有分组。
        只把语义上确实同类的条目归入同一主题；每条记忆最多属于一个主题；一个主题至少包含 2 条成员。
        title 用不超过 12 个字的短语，summary 用一句话概括组内共性。已有主题可继续吸收新成员——沿用其 title 即可在原地更新。
        不要虚构成员 id，不要输出 memories 之外的解释。没有合理分组时输出 {"topics":[]}。
        只输出 JSON：{"topics":[{"title":"主题名","summary":"一句话摘要","memberIds":[1,2]}]}。
        memories：
        \(membersJSON)
        existing_topics：
        \(topicsJSON)
        """
        let assistant = settings.getCurrentAssistant()
        // maxTokens 置 nil：请求体不带 max_tokens，服务端用模型自身的输出上限。
        // 与压缩路径同约定——部分网关会校验 max_tokens 范围（如 [1,131072]），
        // 写死的数值既可能太小（推理烧光预算产出空 content）也可能超校验上限。
        let params = TextGenerationParams(
            model: model, temperature: nil, topP: nil, maxTokens: nil, tools: [],
            reasoningLevel: worker.daydreamReasoningLevel,
            customHeaders: ChatProviderConfiguration.requestHeaders(
                for: providerSetting,
                assistant: assistant.customHeaders,
                model: model.customHeaders,
                conversationId: nil
            ),
            customBody: assistant.customBodies + model.customBodies
        )
        return Request(provider: provider, setting: providerSetting, messages: [UIMessage.companion.user(prompt: prompt)], params: params)
    }

    /// Immutable KMP request values cross into the same provider boundary used by
    /// the extraction coordinator; only the returned String crosses back.
    private struct Request: @unchecked Sendable {
        let provider: any IOSAgentTextProvider
        let setting: ProviderSetting
        let messages: [UIMessage]
        let params: TextGenerationParams
    }

    private static func generate(_ request: Request, timeoutMillis: Int64) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let chunk = try await request.provider.generateText(providerSetting: request.setting, messages: request.messages, params: request.params)
                guard let text = chunk.choices.first?.message?.toText(), !text.isEmpty else {
                    throw Failure("主题整理模型返回了空内容。")
                }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeoutMillis, 1)) * 1_000_000)
                throw Failure("主题整理超时。")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func report(_ message: String) {
        statusMessage = message
        defaults.set(message, forKey: Self.statusKey)
    }
}
