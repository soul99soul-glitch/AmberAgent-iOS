import Foundation
@preconcurrency import Shared

@MainActor
enum IOSOrchestrationPersistence {
    /// Sendable 投影：Kotlin `ThreadEdgeEntity` 导出为非 Sendable，跨隔离边界只传
    /// 字符串字段（转换在 DAO 回调内完成，遵循 IOSMailboxStore 既有模式）。
    struct ThreadEdgeSnapshot: Sendable {
        let childThreadId: String
        let parentThreadId: String
        let agentPath: String
        let nickname: String?
        let roleAssistantId: String?
        let forkTurns: String
        let status: String

        init(_ entity: ThreadEdgeEntity) {
            self.childThreadId = entity.childThreadId
            self.parentThreadId = entity.parentThreadId
            self.agentPath = entity.agentPath
            self.nickname = entity.nickname
            self.roleAssistantId = entity.roleAssistantId
            self.forkTurns = entity.forkTurns
            self.status = entity.status
        }
    }

    /// A pending NEW_TASK projected out of Room so the terminal-resume path
    /// never carries Kotlin entities across an async boundary.
    struct PendingTaskSnapshot: Sendable {
        let id: String
        let authorThreadId: String
        let payload: String
        let parentTurnId: String?
    }

    static func persistTargetMessages(
        store: IOSConversationStore,
        conversationId: KotlinUuid,
        messages: [UIMessage]
    ) async -> Bool {
        let baseline = store.writeBaseline(for: conversationId)
        return await store.save(messages: messages, to: conversationId, ifUnchangedSince: baseline)
    }

    /// P1-d 抽取（自 spawn (g) 段）：把「记账（agent_run running）+ durable
    /// handoff → BGTask」收口为一个助手，spawn_agent 与 followup_task 共用。
    /// start 失败时回收 running 行（避免孤儿行计入并发限额，保留 failed 审计
    /// 事实），返回 nil；成功返回 handoff。

    static func pendingTaskSnapshots(
        mailboxDao: MailboxDao,
        recipientId: String
    ) async -> [PendingTaskSnapshot] {
        await withCheckedContinuation { continuation in
            mailboxDao.pendingForRecipient(recipientId: recipientId) { result, _ in
                let snapshots = (result ?? []).compactMap { envelope -> PendingTaskSnapshot? in
                    guard envelope.type == MailboxEnvelopeType.theNewTask.name,
                          envelope.triggerTurn else {
                        return nil
                    }
                    return PendingTaskSnapshot(
                        id: envelope.id,
                        authorThreadId: envelope.authorThreadId,
                        payload: envelope.payload,
                        parentTurnId: envelope.parentTurnId
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    static func markDelivered(
        mailboxDao: MailboxDao,
        ids: [String],
        deliveredAt: Int64
    ) async -> Int {
        guard !ids.isEmpty else { return 0 }
        return await withCheckedContinuation { continuation in
            mailboxDao.markDelivered(ids: ids, deliveredAt: deliveredAt) { result, _ in
                continuation.resume(returning: result?.intValue ?? 0)
            }
        }
    }

    static func pendingCount(mailboxDao: MailboxDao, recipientId: String) async -> Int {
        await withCheckedContinuation { cont in
            mailboxDao.pendingForRecipient(recipientId: recipientId) { result, _ in
                cont.resume(returning: result?.count ?? 0)
            }
        }
    }

    /// P1-d wait_agent 竞速：mailbox 活动事件 vs 超时 vs Task 取消。
    /// 取消传播：父任务取消会取消 group 子任务；三个子任务全部以
    /// CancellationError 收口 → 确定性返回 `.cancelled`（不吞、不等超时）。

    /// Stable English aliases used when the model reuses a sibling task name.
    /// These are route segments, so they stay lowercase and satisfy the same
    /// task-name grammar as the caller supplied name. The primary name comes
    /// from the current parent model; this table is a local no-network fallback.
    private static let collisionTaskNames = [
        "nova", "leo", "nora", "sam", "milo", "iris", "theo", "luna",
        "sage", "aria", "orion", "atlas", "ember", "quinn", "riley", "hazel",
        "sora", "kai", "ivy", "remy", "zane", "cleo", "juno", "piper",
        "wren", "finn", "skye", "mira", "evan", "rhea", "odin", "maven",
        "echo", "kira", "vera", "axel", "lina", "miko", "tess", "niko",
        "yuki", "zora", "cora", "navi", "elio", "nina", "otto", "ravi",
        "uma", "yara", "basil", "cato", "dara", "elara", "faye", "gala",
        "hugo", "jace", "kian", "lyra", "maia", "nate", "pax", "rory",
        "selene", "talia", "una", "vito", "willa", "xena", "yves"
    ]

    /// Resolve a sibling task name without renaming existing edges. A repeated
    /// model name first receives an unused stable English alias; numeric
    /// suffixes are only the last fallback after the alias pool is exhausted.
    static func uniqueTaskName(
        _ taskName: String,
        parentAgentPath: String,
        threadEdgeDao: ThreadEdgeDao
    ) async -> String {
        let children = await Self.children(of: parentAgentPath, threadEdgeDao: threadEdgeDao)
        let existingNames = Set<String>(children.compactMap { edge in
            guard edge.agentPath.hasPrefix(parentAgentPath + "/") else { return nil }
            return edge.agentPath.dropFirst(parentAgentPath.count + 1)
                .split(separator: "/").first.map(String.init)
        })
        guard existingNames.contains(taskName) else { return taskName }

        if let alias = Self.collisionTaskNames.first(where: { !existingNames.contains($0) }) {
            return alias
        }

        var suffix = 2
        while existingNames.contains("\(taskName)_\(suffix)") {
            suffix += 1
        }
        return "\(taskName)_\(suffix)"
    }

    /// 沿 edge 链向上数父深度：root 深度 0，其子深度 1，孙深度 2。
    static func depth(of threadHex: String, threadEdgeDao: ThreadEdgeDao) async -> Int {
        var current = threadHex
        var depth = 0
        while let edge = await Self.edgeFor(childThreadId: current, threadEdgeDao: threadEdgeDao) {
            depth += 1
            current = edge.parentThreadId
        }
        return depth
    }

    /// 沿 edge 链向上走到根：root 会话的 hex（无 edge 的顶层会话就是 root）。
    static func rootHex(of threadHex: String, threadEdgeDao: ThreadEdgeDao) async -> String {
        var current = threadHex
        while let edge = await Self.edgeFor(childThreadId: current, threadEdgeDao: threadEdgeDao) {
            current = edge.parentThreadId
        }
        return current
    }

    static func agentPath(of threadHex: String, threadEdgeDao: ThreadEdgeDao) async -> String {
        if let edge = await Self.edgeFor(childThreadId: threadHex, threadEdgeDao: threadEdgeDao) {
            return edge.agentPath
        }
        return "/root"
    }

    // MARK: - DAO 桥（suspend → withCheckedContinuation，回调内归约成 Sendable 值）

    static func enqueue(mailboxDao: MailboxDao, envelope: MailboxEnvelopeEntity) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            mailboxDao.enqueue(envelope: envelope) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    /// 幂等入队（终态信封去重用）：IGNORE 冲突策略，同 id 重复入队静默跳过。
    static func enqueueIfAbsent(mailboxDao: MailboxDao, envelope: MailboxEnvelopeEntity) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            mailboxDao.enqueueIfAbsent(envelope: envelope) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    static func edgeFor(childThreadId: String, threadEdgeDao: ThreadEdgeDao) async -> ThreadEdgeSnapshot? {
        await withCheckedContinuation { cont in
            threadEdgeDao.edgeFor(childThreadId: childThreadId) { result, _ in
                cont.resume(returning: result.map(ThreadEdgeSnapshot.init))
            }
        }
    }

    /// 取某个 agentPath 下的直接子边（uniqueTaskName 冲突判定用；按 parent hex 存）。
    static func children(of parentAgentPath: String, threadEdgeDao: ThreadEdgeDao) async -> [ThreadEdgeSnapshot] {
        let all = await allEdges(threadEdgeDao: threadEdgeDao)
        let parentPath = parentAgentPath
        return all.filter { edge in
            // 直接子级：路径 = parentPath/单段
            edge.agentPath.hasPrefix(parentPath + "/") &&
                edge.agentPath.dropFirst(parentPath.count + 1).split(separator: "/").count == 1
        }
    }

    static func allEdges(threadEdgeDao: ThreadEdgeDao) async -> [ThreadEdgeSnapshot] {
        await withCheckedContinuation { cont in
            threadEdgeDao.allEdges() { result, _ in
                cont.resume(returning: (result ?? []).map(ThreadEdgeSnapshot.init))
            }
        }
    }

    static func descendants(of rootThreadId: String, threadEdgeDao: ThreadEdgeDao) async -> [ThreadEdgeSnapshot] {
        await withCheckedContinuation { cont in
            threadEdgeDao.descendantsOf(rootThreadId: rootThreadId) { result, _ in
                cont.resume(returning: (result ?? []).map(ThreadEdgeSnapshot.init))
            }
        }
    }

    static func countUnfinishedRuns(agentRuntimeDao: AgentRuntimeDao) async -> Int {
        let store = IOSDurableRunStore(dao: agentRuntimeDao)
        return (try? await store.recoverableRuns().count) ?? 0
    }

    static func latestRunStatusByConversation(agentRuntimeDao: AgentRuntimeDao) async -> [String: String] {
        await withCheckedContinuation { cont in
            agentRuntimeDao.listAllRuns() { result, _ in
                let runs = result ?? []
                var latestByConversation: [String: AgentRunEntity] = [:]
                for run in runs {
                    guard IOSDurableRunStore.Descriptor.chatRecoveryAliases.contains(run.agentDescriptorId),
                          let conversationId = run.conversationId else { continue }
                    if let existing = latestByConversation[conversationId], existing.startedAt > run.startedAt {
                        continue
                    }
                    latestByConversation[conversationId] = run
                }
                cont.resume(returning: latestByConversation.mapValues { $0.status })
            }
        }
    }

    static func recordRunningRun(
        agentRuntimeDao: AgentRuntimeDao,
        runId: String,
        conversationId: String,
        startedAt: Int64,
        inputDigest: String,
        protocolContext: AgentRunProtocolContext
    ) async -> Bool {
        let store = IOSDurableRunStore(dao: agentRuntimeDao)
        return (try? await store.startChatRun(
            runId: runId,
            startedAt: startedAt,
            inputDigest: inputDigest,
            conversationId: conversationId,
            protocolContext: protocolContext
        )) == true
    }

    /// 以 CAS 把活跃 run 收口为 failed（spawn start 失败回收）。
    static func markRunFailed(
        agentRuntimeDao: AgentRuntimeDao,
        runId: String,
        now: Int64
    ) async {
        let store = IOSDurableRunStore(dao: agentRuntimeDao)
        _ = try? await store.transition(
            runId: runId,
            expected: .running,
            to: .failed,
            at: now
        )
    }
}
