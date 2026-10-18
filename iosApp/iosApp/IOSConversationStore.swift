import Foundation
import Observation
@preconcurrency import Shared

// MARK: - IOSUserVisibleError

enum IOSUserVisibleErrorSeverity: String, Equatable {
    case info
    case warning
    case error
}

/// A user-facing error that can be surfaced through the app-level alert bus.
/// Keep it domain-neutral so storage, workspace sync, MCP, memory, and board
/// failures can share the same visible channel without inventing new alerts.
struct IOSUserVisibleError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let severity: IOSUserVisibleErrorSeverity
}

// MARK: - IOSConversationIOError

/// A storage I/O failure surfaced to the UI (disk full / write failed /
/// corruption). Bound to a top-level `.alert(item:)` so the user learns a
/// save/delete/rename failed instead of silently believing it succeeded.
struct IOSConversationIOError: Identifiable, Equatable {
    let id = UUID()
    let operation: String        // e.g. "save", "delete", "rename"
    let detail: String           // human-readable summary

    var message: String {
        IOSAppLocalization.formatted(
            "会话存储「%@」失败：%@。请检查存储空间后重试。",
            defaultValue: "会话存储「%@」失败：%@。请检查存储空间后重试。",
            arguments: [
                IOSAppLocalization.string(operation, defaultValue: operation),
                detail,
            ]
        )
    }

    var userVisibleError: IOSUserVisibleError {
        IOSUserVisibleError(
            title: IOSAppLocalization.string("会话存储出错", defaultValue: "会话存储出错"),
            message: message,
            severity: .error
        )
    }
}

private struct IOSConversationImportInProgressError: LocalizedError {
    var errorDescription: String? {
        "会话恢复正在进行，请等待完成后再试。"
    }
}

// MARK: - IOSConversationStore

struct IOSConversationWriteBaseline: Equatable {
    fileprivate let key: String
    fileprivate let sequence: UInt64
    /// A restore replaces persisted documents as a coherent user-visible snapshot.
    /// A run that captured its baseline before that replacement must not write
    /// its old transcript back after the import finishes.
    fileprivate let importEpoch: UInt64
}

/// iOS 端会话生命周期管理器。把 [JsonConversationStorage]（KMP 文件 JSON 存储）包成
/// SwiftUI 可观察的状态：持有当前会话 + 会话摘要列表。
///
/// 本类的可观察状态由 MainActor 持有；存储内部用 operationMutex 串行化文件与
/// index 的读改写。完整会话读取与解码在 KMP 后台 dispatcher 完成，再回主线程提交状态。
///
/// 设计参照 PLAN_CONVERSATION_PERSISTENCE.md Phase 2。
@MainActor
@Observable
final class IOSConversationStore {

    let artifactStore: IOSConversationArtifactStore
    let recapStore: IOSConversationRecapStore
    let intelligentUIStateStore: IOSIntelligentUIStateStore

    /// Shared by the foreground panel and background completion callbacks.
    /// The generator holds this store as unowned to keep ownership one-way.
    @ObservationIgnored lazy var recapGenerator: ConversationRecapGenerator = {
        ConversationRecapGenerator(
            conversationStore: self,
            recapStore: recapStore,
            textProvider: OpenAIKmpProviderAdapter()
        )
    }()

    // MARK: - Observable state

    /// 当前选中的会话。App 启动时由 [bootstrap] 选最近一条或新建。
    private(set) var currentConversation: Conversation?

    var currentRecapBranchID: String? {
        currentConversation.map { ConversationRecap.branchIdentifier(for: $0) }
    }

    /// 会话摘要列表（按 updateAt 倒序、置顶优先，由 KMP 层排序）。
    private(set) var summaries: [ConversationSummary] = []

    /// 全部已持久化会话摘要。子代理会话不进入 [summaries]，但仍保留在这里供
    /// 编排详情、存储统计和清理操作按明确目标访问。
    private(set) var allSummaries: [ConversationSummary] = []

    /// 首页列表 meta 用的 LLM 浓缩预览（会话 id 字符串 → 单行文案）。
    /// 与 KMP `ConversationSummary` 解耦：不改 index schema，落盘在 conversations/list-previews.json。
    private(set) var listPreviewsByConversationId: [String: String] = [:]

    /// 标题 LLM 一并选出的列表图标 key（`HomeConversationIcon.llmCatalog`）。
    /// 不改 conversation schema，落盘在 conversations/list-icons.json。
    private(set) var listIconsByConversationId: [String: String] = [:]

    /// 单调递增的修订号：每次 currentConversation 被替换（新建/切换/删除回退/落盘/分支）时 +1。
    /// 供需要感知「当前会话内容可能变了」的 UI 观察（如 island 标题）。
    /// 注意：它对「同会话落盘」也会 +1，因此不能用它判断「是否切到了别的会话」——
    /// 那是 conversationSwitchedRevision 的职责。把两者混淆会导致 viewport 误把落盘当切会话，
    /// 重建 ScrollView → 抖动 + 上滑看历史被甩回锚点。
    private(set) var currentRevision: Int = 0

    /// 单调递增的「切会话」修订号：**只在真正切换到另一个会话时** +1
    /// （newConversation / selectConversation / 删除当前后退到别的会话）。
    /// 同会话落盘、分支编辑、重命名、置顶**不** bump 它。
    /// 供 viewport/ChatView 观察以判断是否需要重灌历史 + 重新从底部实现落位。
    private(set) var conversationSwitchedRevision: Int = 0

    /// 后台生成/后台工具回填落盘完成的定向信号。只在后台路径 bump——
    /// 普通前台落盘绝不碰它,否则会复发"每次落盘重灌历史"的甩回老 bug。
    private(set) var backgroundContentRevision: Int = 0
    /// 待通知的后台内容落盘会话集合。集合(而非单值)天然免疫同 tick 多会话
    /// 落盘的观察合并;消费由 ChatView 显式调用 consume,门控跳过时不消费,
    /// 生成收尾事件会补查——两类丢通知(覆盖/消费无重试)都由此闭环。
    private(set) var pendingBackgroundContentConversationIds: Set<String> = []

    /// ChatView 在真正完成"上屏"处理后调用，把该会话从待通知集合里移除。
    /// 门控跳过（前台生成中）时不应调用——保留待通知状态，等收尾事件补查。
    func consumeBackgroundContentNotification(for conversationId: String) {
        pendingBackgroundContentConversationIds.remove(conversationId)
    }

    /// 最近一次存储 I/O 错误（磁盘满/写失败/损坏）。绑定到顶层 `.alert(item:)`
    /// 让用户看到失败，避免"以为保存了实际没保存"的静默丢数据。nil = 无未读错误。
    /// 成功刷新列表不会自动清空它；只有用户 dismiss alert 时才清空。
    private(set) var lastIOError: IOSConversationIOError?

    /// App-level visible error bus. `lastIOError` remains for compatibility and
    /// tests, while new domains should publish here directly.
    private(set) var lastUserVisibleError: IOSUserVisibleError?

    /// Dismiss the current IO error (called by the alert's OK action).
    func clearIOError() {
        clearUserVisibleError()
    }

    func clearUserVisibleError() {
        lastIOError = nil
        lastUserVisibleError = nil
    }

    func publishUserVisibleError(_ error: IOSUserVisibleError) {
        lastUserVisibleError = error
    }

    func publishIOError(operation: String, detail: String) {
        let error = IOSConversationIOError(operation: operation, detail: detail)
        lastIOError = error
        publishUserVisibleError(error.userVisibleError)
    }

    // MARK: - Private

    let storage: JsonConversationStorage
    private let listPreviewsFileURL: URL
    private let listIconsFileURL: URL
    private let subagentConversationIDsProvider: () async throws -> Set<String>
    private let threadEdgeDaoProvider: (() -> ThreadEdgeDao)?
    private var deletedConversationIds: Set<String> = []
    private var subagentConversationIDs: Set<String> = []
    private var didLoadSummaries = false
    private var writeSequences: [String: UInt64] = [:]
    @ObservationIgnored var branchMutationConversationIDs: Set<String> = []
    @ObservationIgnored var messageSnapshotWriteCounts: [String: Int] = [:]
    private(set) var importEpoch: UInt64 = 0
    /// A restore must first drain snapshot writers that have already crossed
    /// into the Store, then keep newly-started writers out until the restored
    /// document is selected into `currentConversation`.
    private(set) var isImportingConversationDocuments = false
    private var inFlightConversationWrites = 0
    private var conversationWriteDrainContinuations: [CheckedContinuation<Void, Never>] = []

#if DEBUG
    var beforePersistForTesting: ((Conversation) async -> Void)?
    var afterPersistReservationForTesting: ((Conversation) async -> Void)?
    var beforeDeleteForTesting: (() async throws -> Void)?
    var beforeMessageLoadForTesting: ((KotlinUuid) -> Void)?
#endif

    // MARK: - Init

    init(
        baseDirectory: URL? = nil,
        subagentConversationIDsProvider: (() async throws -> Set<String>)? = nil,
        threadEdgeDaoProvider: (() -> ThreadEdgeDao)? = nil
    ) {
        // Documents/conversations/ —— iOS Documents 目录会被 iTunes 文件共享暴露，
        // 第一版可接受（便于调试）；后续如要隐藏可换 Application Support。
        let baseDirPath: String
        let previewsURL: URL
        let iconsURL: URL
        if let baseDirectory {
            baseDirPath = baseDirectory.path
            previewsURL = baseDirectory.appendingPathComponent("list-previews.json")
            iconsURL = baseDirectory.appendingPathComponent("list-icons.json")
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let conversations = documents.appendingPathComponent("conversations")
            try? FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var privateConversations = conversations
            try? privateConversations.setResourceValues(resourceValues)
            baseDirPath = conversations.path
            previewsURL = conversations.appendingPathComponent("list-previews.json")
            iconsURL = conversations.appendingPathComponent("list-icons.json")
        }
        let baseDir = ConversationFile(path: baseDirPath)
        self.storage = JsonConversationStorage(baseDir: baseDir)
        self.artifactStore = IOSConversationArtifactStore(
            fileURL: URL(fileURLWithPath: baseDirPath).appendingPathComponent("artifact-shelf.json")
        )
        self.recapStore = IOSConversationRecapStore(
            fileURL: URL(fileURLWithPath: baseDirPath).appendingPathComponent("conversation-recaps.json")
        )
        self.intelligentUIStateStore = IOSIntelligentUIStateStore(
            fileURL: URL(fileURLWithPath: baseDirPath).appendingPathComponent("task-ui-drafts.json")
        )
        self.listPreviewsFileURL = previewsURL
        self.listIconsFileURL = iconsURL
        let edgeDao: (() -> ThreadEdgeDao)? = threadEdgeDaoProvider
            ?? (baseDirectory == nil ? { IosDatabaseFactory.shared.createDatabase().threadEdgeDao() } : nil)
        self.threadEdgeDaoProvider = edgeDao
        if let subagentConversationIDsProvider {
            self.subagentConversationIDsProvider = subagentConversationIDsProvider
        } else if let edgeDao {
            self.subagentConversationIDsProvider = {
                Set(try await edgeDao().allEdges().map { $0.childThreadId.lowercased() })
            }
        } else {
            // Isolated test stores must not read the app's production Room database.
            self.subagentConversationIDsProvider = { [] }
        }
        self.listPreviewsByConversationId = Self.loadListPreviews(from: previewsURL)
        self.listIconsByConversationId = Self.loadListPreviews(from: iconsURL)
        if let error = artifactStore.storageError {
            publishIOError(operation: "读取产物架", detail: error.localizedDescription)
        }
        if let error = recapStore.storageError {
            publishIOError(operation: "读取回顾", detail: error.localizedDescription)
        }
        if let error = intelligentUIStateStore.storageError {
            publishIOError(operation: "读取任务卡草稿", detail: error)
        }
    }

    /// Resolve the selected-variant fingerprint for a live or background-owned
    /// conversation without consulting the currently selected conversation.
    func branchIdentifier(for conversationID: KotlinUuid, messages: [UIMessage]? = nil) async -> String? {
        if let currentConversation, currentConversation.id == conversationID {
            return ConversationRecap.branchIdentifier(for: currentConversation, messages: messages)
        }
        guard let conversation = await conversationForMessageMutation(
            id: conversationID,
            operation: "读取回顾分支"
        ) else { return nil }
        return ConversationRecap.branchIdentifier(for: conversation, messages: messages)
    }

    /// Update the visible projection after the edge is durable and before the
    /// first child save, so the current list never briefly shows the child.
    func registerSubagentConversation(id: KotlinUuid) {
        subagentConversationIDs.insert(subagentConversationKey(for: id))
        applySummaryVisibility()
    }

    /// Re-read the durable `thread_edge` projection. The provider is injected by
    /// the composition root so isolated stores can remain independent of the
    /// production Room database.
    func refreshSubagentConversationVisibility() async throws {
        let discovered = try await subagentConversationIDsProvider()
        subagentConversationIDs.formUnion(discovered.map { $0.lowercased() })
        applySummaryVisibility()
    }

    // MARK: - Bootstrap

    /// App 启动时调用：加载摘要列表，选最近一条作为 current；无历史则新建空会话。
    func bootstrap(allowNewConversationDuringImport: Bool = false) async {
        didLoadSummaries = false
        listPreviewsByConversationId = Self.loadListPreviews(from: listPreviewsFileURL)
        listIconsByConversationId = Self.loadListPreviews(from: listIconsFileURL)
        _ = await loadSummaryProjectionIfNeeded()
        guard didLoadSummaries else { return }

        if let mostRecent = summaries.first {
            // summaries 已按 updateAt 倒序，第一条即最近。
            _ = await selectConversationIfAvailable(
                id: mostRecent.id,
                allowDuringImport: allowNewConversationDuringImport
            )
        } else {
            await newConversation(allowDuringImport: allowNewConversationDuringImport)
        }
    }

    /// 首页 meta 交错用的浓缩预览；无则返回空串。
    func listPreview(for id: KotlinUuid) -> String {
        listPreviewsByConversationId[sequenceKey(for: id)] ?? ""
    }

    /// 写入 LLM 浓缩预览（与标题生成同链路产出）。空串会清除该会话预览。
    /// 已删除会话的 tombstone 会拒绝迟到写入，避免 orphan key 复活。
    func setListPreview(id: KotlinUuid, preview: String) {
        let key = sequenceKey(for: id)
        guard !deletedConversationIds.contains(key) else { return }
        let cleaned = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            guard listPreviewsByConversationId.removeValue(forKey: key) != nil else { return }
        } else if listPreviewsByConversationId[key] == cleaned {
            return
        } else {
            listPreviewsByConversationId[key] = cleaned
        }
        persistListPreviews()
    }

    /// 标题 LLM 选出的列表图标 key；空串清除。
    func listIconKey(for id: KotlinUuid) -> String? {
        listIconsByConversationId[sequenceKey(for: id)]
    }

    func setListIconKey(id: KotlinUuid, key: String?) {
        let storageKey = sequenceKey(for: id)
        guard !deletedConversationIds.contains(storageKey) else { return }
        let cleaned = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty {
            guard listIconsByConversationId.removeValue(forKey: storageKey) != nil else { return }
        } else if listIconsByConversationId[storageKey] == cleaned {
            return
        } else {
            listIconsByConversationId[storageKey] = cleaned
        }
        persistListIcons()
    }

    /// Imports complete Conversation JSON documents through the storage owner.
    /// The KMP implementation validates the whole batch before taking any write
    /// and rebuilds index.json under the same operation mutex.
    @discardableResult
    func importConversationDocuments(
        _ documents: [String],
        threadEdges: [IOSConversationThreadEdge]? = nil
    ) async throws -> Int {
        guard !documents.isEmpty else { return 0 }
        guard !isImportingConversationDocuments else {
            throw IOSConversationImportInProgressError()
        }
        isImportingConversationDocuments = true
        defer { isImportingConversationDocuments = false }

        let restoredIds = Set(documents.compactMap { document -> String? in
            guard let data = document.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else { return nil }
            return id.lowercased()
        })
        let edgeDao = threadEdges == nil ? nil : threadEdgeDaoProvider?()
        let restoredEdges: [IOSConversationThreadEdge]?
        if let threadEdges {
            guard let edgeDao else {
                throw NSError(domain: "IOSConversationStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "编排关系存储不可用。"])
            }
            let existingEdges = try await edgeDao.allEdges().map(IOSConversationThreadEdge.init(entity:))
            restoredEdges = try IOSConversationThreadEdge.validated(
                threadEdges, documentIDs: restoredIds,
                existingEdges: existingEdges.filter { !restoredIds.contains($0.childThreadId) }
            )
        } else {
            restoredEdges = nil
        }
        await waitForConversationWritesToDrain()
        try await storage.importConversations(serializedConversations: documents)
        await clearIntelligentUIDrafts(for: restoredIds)
        // 被备份覆盖的会话，其消息 ID 与本机收藏不再对应；收藏不随备份恢复。
        recapGenerator.invalidate(
            conversationIDs: Array(restoredIds),
            reason: "对话已恢复，请重新生成回顾。"
        )
        do {
            for id in restoredIds { try artifactStore.removeConversation(id) }
        } catch {
            publishIOError(operation: "清理产物架", detail: error.localizedDescription)
        }
        do {
            for id in restoredIds { try recapStore.removeConversation(id) }
        } catch {
            publishIOError(operation: "清理回顾", detail: error.localizedDescription)
        }
        var relationRestoreError: Error?
        if let restoredEdges, let edgeDao {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    edgeDao.restoreEdges(conversationIds: Array(restoredIds), edges: restoredEdges.map { $0.toEntity() }) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                subagentConversationIDs.subtract(restoredIds)
                subagentConversationIDs.formUnion(restoredEdges.map(\.childThreadId))
            } catch {
                relationRestoreError = error
            }
        }
        deletedConversationIds.removeAll()
        writeSequences.removeAll()
        importEpoch &+= 1
        for id in restoredIds {
            listPreviewsByConversationId.removeValue(forKey: id)
            listIconsByConversationId.removeValue(forKey: id)
        }
        persistListPreviews()
        persistListIcons()
        // Keep the gate up through the reload. Otherwise a new run could
        // observe the new epoch while `currentConversation` still holds the
        // pre-restore document and write that old snapshot back.
        await bootstrap(allowNewConversationDuringImport: true)
        if let relationRestoreError {
            throw NSError(domain: "IOSConversationStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "会话文件已恢复，但子代理关系恢复失败，请重新导入备份：\(relationRestoreError.localizedDescription)"
            ])
        }
        return documents.count
    }

    func orchestrationEdgesForBackup() async throws -> [IOSConversationThreadEdge] {
        guard let dao = threadEdgeDaoProvider?() else { return [] }
        return try await dao.allEdges().map(IOSConversationThreadEdge.init(entity:))
    }

    // MARK: - CRUD

    /// 新建空会话：生成新 Conversation（assistantId = DEFAULT_ASSISTANT_ID），落盘，设为 current。
    @discardableResult
    func newConversation(
        commitIf: () -> Bool = { true },
        allowDuringImport: Bool = false,
        expectedImportEpoch: UInt64? = nil
    ) async -> Bool {
        let operationImportEpoch = expectedImportEpoch ?? importEpoch
        guard acceptsImportEpoch(operationImportEpoch, allowDuringImport: allowDuringImport) else {
            return false
        }
        let conversation = Conversation.companion.ofId(
            id: KotlinUuid.companion.random(),
            assistantId: AssistantKt.DEFAULT_ASSISTANT_ID,
            messages: [],
            newConversation: true
        )
        let persisted = await persist(
            conversation,
            expectedImportEpoch: operationImportEpoch,
            allowDuringImport: allowDuringImport
        )
        guard let persisted else {
            // Preserve the established in-memory fallback for a genuine disk
            // error, but never commit a document that was rejected by restore.
            guard acceptsImportEpoch(operationImportEpoch, allowDuringImport: allowDuringImport) else {
                return false
            }
            return await commitNewConversation(conversation, commitIf: commitIf)
        }
        return await commitNewConversation(persisted, commitIf: commitIf)
    }

    private func commitNewConversation(_ conversation: Conversation, commitIf: () -> Bool) async -> Bool {
        guard commitIf() else { return false }
        setCurrentAsSwitch(conversation)
        await refreshSummaries()
        return true
    }

    /// 用户入口的“新建对话”：优先复用当前或最近的空会话，避免连续点击新建制造垃圾空文件。
    /// 底层 `newConversation()` 保持强制新建语义，供测试、删除回退等内部场景使用。
    @discardableResult
    func startNewConversationReusingEmpty(commitIf: () -> Bool = { true }) async -> Bool {
        let operationImportEpoch = importEpoch
        guard acceptsImportEpoch(operationImportEpoch) else { return false }
        if let currentConversation, Self.isReusableEmptyConversation(currentConversation) {
            return true
        }

        let sourceSummaries: [ConversationSummary]
        sourceSummaries = await visibleSummariesForListing()
        guard acceptsImportEpoch(operationImportEpoch) else { return false }

        if let mostRecent = sourceSummaries.first,
           currentConversation?.id != mostRecent.id,
           !isDeletedConversation(mostRecent.id),
           let conversation = try? await storage.loadConversation(id: mostRecent.id),
           acceptsImportEpoch(operationImportEpoch),
           Self.isReusableEmptyConversation(conversation) {
            guard commitIf() else { return false }
            setCurrentAsSwitch(conversation)
            return true
        }

        return await newConversation(
            commitIf: commitIf,
            expectedImportEpoch: operationImportEpoch
        )
    }

    /// Read-only projection for App Entity queries. It deliberately avoids
    /// bootstrap so querying Shortcuts never creates or selects a conversation.
    func appIntentSummaries(limit: Int? = 20) async -> [ConversationSummary] {
        let source = await visibleSummariesForListing()
        guard let limit else { return source }
        let boundedLimit = max(0, min(limit, 50))
        return Array(source.prefix(boundedLimit))
    }

    /// 切换到指定会话：从磁盘 load 完整对象，设为 current。
    func selectConversation(id: KotlinUuid) async {
        _ = await selectConversationIfAvailable(id: id)
    }

    @discardableResult
    func selectConversationIfAvailable(
        id: KotlinUuid,
        commitIf: () -> Bool = { true },
        allowDuringImport: Bool = false
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        guard acceptsImportEpoch(operationImportEpoch, allowDuringImport: allowDuringImport) else {
            return false
        }
        guard !isDeletedConversation(id) else { return false }
        let loaded: Conversation?
        do {
            loaded = try await storage.loadConversation(id: id)
        } catch {
            publishIOError(operation: "加载会话", detail: "\(id): \(error)")
            loaded = nil
        }
        guard !isDeletedConversation(id),
              acceptsImportEpoch(operationImportEpoch, allowDuringImport: allowDuringImport) else {
            return false
        }
        if let loaded, commitIf() {
            setCurrentAsSwitch(loaded)
            return true
        }
        // load 失败时不切换 current，保留上一个；UI 层可提示。
        return false
    }

    /// 把当前内存里的 [messages] 回填进 currentConversation（节点合并），落盘，刷新 index。
    /// 流式结束后调用一次（不在每个 chunk 调，避免写盘抖动）。
    func saveCurrent(messages: [UIMessage]) async {
        guard let id = currentConversation?.id else { return }
        await save(messages: messages, to: id)
    }

    func writeBaseline(for id: KotlinUuid) -> IOSConversationWriteBaseline {
        let key = sequenceKey(for: id)
        return IOSConversationWriteBaseline(
            key: key,
            sequence: writeSequences[key, default: 0],
            importEpoch: importEpoch
        )
    }

    func canApplyAuxiliaryResult(since baseline: IOSConversationWriteBaseline) -> Bool {
        acceptsImportEpoch(baseline.importEpoch) && !deletedConversationIds.contains(baseline.key)
    }

    /// 把 [messages] 保存到指定会话 id。用于生成回调按 run 发起时的 conversation 归属落盘，
    /// 避免用户在流式生成期间切换/新建会话后把旧 run 写进当前新会话。
    @discardableResult
    func save(
        messages: [UIMessage],
        to id: KotlinUuid,
        ifUnchangedSince baseline: IOSConversationWriteBaseline? = nil,
        expectedImportEpoch: UInt64? = nil
    ) async -> Bool {
        let operationImportEpoch = expectedImportEpoch ?? importEpoch
        guard beginMessageSnapshotWrite(to: id) else { return false }
        defer { finishMessageSnapshotWrite(to: id) }
        guard !isDeletedConversation(id) else { return false }
        guard acceptsWrite(
            to: id,
            baseline: baseline,
            expectedImportEpoch: operationImportEpoch
        ) else { return false }
        let conversation: Conversation?
        if currentConversation?.id == id {
            conversation = currentConversation
        } else {
            do {
                conversation = try await storage.loadConversation(id: id)
            } catch {
                publishIOError(operation: "保存会话", detail: "目标 \(id): \(error)")
                conversation = nil
            }
        }
        guard let conversation, !isDeletedConversation(id) else { return false }
        guard acceptsWrite(
            to: id,
            baseline: baseline,
            expectedImportEpoch: operationImportEpoch
        ) else { return false }

        // updateCurrentMessages 已做 identity 短路：消息没变时返回同一引用，节省落盘。
        var updated = conversation.updateCurrentMessages(messages: messages)
        if updated !== conversation {
            updated = conversationWithNodes(updated, nodes: updated.messageNodes)
        }

        // 标题派生（PLAN 阶段4的简化版，放在这里因为这是最低成本的标题来源，且与 save 同一调用点）：
        // 首条 user message 后若标题仍空，取前 30 字。后续若需小模型总结再升级。
        if updated.title.isEmpty {
            let firstUserText = messages
                .first(where: { $0.role == MessageRole.user })?
                .toText()
            if let title = firstUserText, !title.isEmpty {
                updated = retitledCopy(of: updated, title: String(title.prefix(30)))
            }
        }

        guard let persisted = await persist(
            updated,
            ifUnchangedSince: baseline,
            expectedImportEpoch: operationImportEpoch
        ) else { return false }
        if currentConversation?.id == id {
            setCurrent(persisted)
        }
        await refreshSummaries()
        return acceptsImportEpoch(operationImportEpoch)
    }

    @discardableResult
    func saveBackgroundCompletion(
        baseMessages: [UIMessage],
        completedMessages: [UIMessage],
        to id: KotlinUuid
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        for _ in 0..<3 {
            guard !isDeletedConversation(id),
                  acceptsImportEpoch(operationImportEpoch) else { return false }
            let baseline = writeBaseline(for: id)
            let conversation: Conversation?
            if currentConversation?.id == id {
                conversation = currentConversation
            } else {
                do {
                    conversation = try await storage.loadConversation(id: id)
                } catch {
                    publishIOError(operation: "保存后台回复", detail: "目标 \(id): \(error)")
                    conversation = nil
                }
            }
            guard let conversation,
                  !isDeletedConversation(id),
                  acceptsImportEpoch(operationImportEpoch) else { return false }

            let current = conversation.currentMessages
            let nextMessages: [UIMessage]
            if Self.sameMessageIdentity(current, baseMessages) {
                nextMessages = completedMessages
            } else {
                // Drain envelopes keep their persisted identity. A generated assistant may
                // already be checkpointed with that same UUID, so its terminal projection
                // must replace the checkpoint rather than disappear as a duplicate.
                let generatedSuffix = Array(completedMessages.dropFirst(baseMessages.count))
                let baseIDs = Set(baseMessages.map { String(describing: $0.id) })
                let completedAssistants = generatedSuffix.reduce(into: [String: UIMessage]()) { result, message in
                    let messageID = String(describing: message.id)
                    if message.role == .assistant, !baseIDs.contains(messageID) {
                        result[messageID] = message
                    }
                }
                let baselineAssistants = baseMessages.reduce(into: [String: UIMessage]()) { result, message in
                    if message.role == .assistant { result[String(describing: message.id)] = message }
                }
                let terminalAssistants = completedMessages.reduce(into: [String: UIMessage]()) { result, message in
                    if message.role == .assistant { result[String(describing: message.id)] = message }
                }
                let mergedCurrent = current.map { message -> UIMessage in
                    guard message.role == .assistant else { return message }
                    let messageID = String(describing: message.id)
                    if let generated = completedAssistants[messageID] { return generated }
                    guard let checkpoint = baselineAssistants[messageID],
                          let terminal = terminalAssistants[messageID] else { return message }
                    return Self.messageByApplyingIntelligentUITerminalMetadata(
                        to: message, checkpoint: checkpoint, terminal: terminal
                    )
                }
                let currentIds = Set(current.map { String(describing: $0.id) })
                let freshSuffix = generatedSuffix.filter { !currentIds.contains(String(describing: $0.id)) }
                let completedIds = Set(completedMessages.map { String(describing: $0.id) })
                let differenceIsOnlyDrain = current.dropFirst(baseMessages.count).allSatisfy {
                    completedIds.contains(String(describing: $0.id))
                }
                if freshSuffix.isEmpty {
                    nextMessages = mergedCurrent
                } else if differenceIsOnlyDrain {
                    // 磁盘差异只是后台自己折入的信封：无用户侧新内容，不插 notice。
                    nextMessages = mergedCurrent + freshSuffix
                } else {
                    let notice = UIMessage.companion.assistant(prompt: IOSAppLocalization.string(
                        "后台生成已完成；当前会话期间已有新内容，以下是后台完成的结果。",
                        defaultValue: "后台生成已完成；当前会话期间已有新内容，以下是后台完成的结果。"
                    ))
                    nextMessages = mergedCurrent + [notice] + freshSuffix
                }
            }
            guard await save(
                messages: nextMessages,
                to: id,
                ifUnchangedSince: baseline,
                expectedImportEpoch: operationImportEpoch
            ) else {
                guard acceptsImportEpoch(operationImportEpoch) else { return false }
                continue
            }
            pendingBackgroundContentConversationIds.insert(String(describing: id))
            backgroundContentRevision &+= 1
            return true
        }
        print("[AA-STORE] background completion save skipped after retries id=\(sequenceKey(for: id))")
        return false
    }

    /// Replaces one background-owned message by id without replaying an old
    /// full conversation snapshot. This preserves messages or branches added
    /// while the background job was running.
    @discardableResult
    func replaceBackgroundMessage(_ replacement: UIMessage, in id: KotlinUuid) async -> Bool {
        let replacementId = String(describing: replacement.id)
        let operationImportEpoch = importEpoch
        for _ in 0..<3 {
            guard !isDeletedConversation(id),
                  acceptsImportEpoch(operationImportEpoch) else { return false }
            let baseline = writeBaseline(for: id)
            let conversation: Conversation?
            if currentConversation?.id == id {
                conversation = currentConversation
            } else {
                do {
                    conversation = try await storage.loadConversation(id: id)
                } catch {
                    publishIOError(operation: "更新后台回复", detail: "目标 \(id): \(error)")
                    conversation = nil
                }
            }
            guard let conversation,
                  !isDeletedConversation(id),
                  acceptsImportEpoch(operationImportEpoch) else { return false }
            var messages = conversation.currentMessages
            guard let index = messages.firstIndex(where: {
                String(describing: $0.id) == replacementId
            }) else {
                return false
            }
            messages[index] = replacement
            guard await save(
                messages: messages,
                to: id,
                ifUnchangedSince: baseline,
                expectedImportEpoch: operationImportEpoch
            ) else {
                guard acceptsImportEpoch(operationImportEpoch) else { return false }
                continue
            }
            pendingBackgroundContentConversationIds.insert(String(describing: id))
            backgroundContentRevision &+= 1
            return true
        }
        print("[AA-STORE] background message replacement skipped after retries id=\(sequenceKey(for: id))")
        return false
    }

    @discardableResult
    func saveBackgroundToolCompletion(
        baseMessages: [UIMessage],
        completedMessages: [UIMessage],
        to id: KotlinUuid
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        for _ in 0..<3 {
            guard !isDeletedConversation(id),
                  acceptsImportEpoch(operationImportEpoch) else { return false }
            let baseline = writeBaseline(for: id)
            let conversation: Conversation?
            if currentConversation?.id == id {
                conversation = currentConversation
            } else {
                do {
                    conversation = try await storage.loadConversation(id: id)
                } catch {
                    publishIOError(operation: "保存后台工具结果", detail: "目标 \(id): \(error)")
                    conversation = nil
                }
            }
            guard let conversation,
                  !isDeletedConversation(id),
                  acceptsImportEpoch(operationImportEpoch) else { return false }

            let current = conversation.currentMessages
            let nextMessages: [UIMessage]
            if Self.sameMessageIdentity(current, baseMessages) {
                nextMessages = completedMessages
            } else {
                let outputs = Self.completedToolOutputs(in: completedMessages)
                let patched = Self.messagesByApplyingToolOutputs(outputs, to: current)
                if patched.didApply {
                    nextMessages = patched.messages
                } else {
                    let notice = UIMessage.companion.assistant(prompt: IOSAppLocalization.string(
                        "后台工具执行已完成；当前会话期间已有新内容，以下是后台完成的结果。",
                        defaultValue: "后台工具执行已完成；当前会话期间已有新内容，以下是后台完成的结果。"
                    ))
                    let toolMessages = Self.messagesContainingToolOutputs(outputs, in: completedMessages)
                    nextMessages = current + [notice] + toolMessages
                }
            }
            guard await save(
                messages: nextMessages,
                to: id,
                ifUnchangedSince: baseline,
                expectedImportEpoch: operationImportEpoch
            ) else {
                guard acceptsImportEpoch(operationImportEpoch) else { return false }
                continue
            }
            pendingBackgroundContentConversationIds.insert(String(describing: id))
            backgroundContentRevision &+= 1
            return true
        }
        print("[AA-STORE] background tool completion save skipped after retries id=\(sequenceKey(for: id))")
        return false
    }

    // MARK: - P1-c 线程编排（fork 会话持久化）

    /// 保存一个已构造好的 Conversation（P1-c fork 结果）。与 [save] 不同：目标
    /// 会话文件尚不存在，没有「消息写保留 metadata owner 字段」语义，直接落盘
    /// 并刷新索引。仅当目标是当前会话时才切换 current（fork 目标是新会话，不会）。
    @discardableResult
    func saveForkedConversation(_ conversation: Conversation) async -> Bool {
        let operationImportEpoch = importEpoch
        guard !isDeletedConversation(conversation.id) else { return false }
        guard let persisted = await persist(
            conversation,
            expectedImportEpoch: operationImportEpoch
        ) else { return false }
        if currentConversation?.id == conversation.id {
            setCurrent(persisted)
        }
        await refreshSummaries()
        return acceptsImportEpoch(operationImportEpoch)
    }

    /// 按 id 读取完整 Conversation（P1-c fork 源读取；当前会话优先走内存）。
    func loadConversationForOrchestration(_ id: KotlinUuid) async throws -> Conversation? {
        let operationImportEpoch = importEpoch
        guard acceptsImportEpoch(operationImportEpoch) else { return nil }
        guard !isDeletedConversation(id) else { return nil }
        let conversation = try await storage.loadConversation(id: id)
        guard acceptsImportEpoch(operationImportEpoch) else { return nil }
        return conversation
    }

    // MARK: - P2-a 会话记忆污染（memoryMode）

    /// harness 置位：ENABLED→POLLUTED（KMP 层原子 RMW，幂等只升不降，不会被
    /// 并发消息写回滚）。失败记日志不抛——置位不得阻塞工具结果。
    @discardableResult
    func markConversationMemoryPolluted(_ id: KotlinUuid) async -> Bool {
        let operationImportEpoch = importEpoch
        guard beginConversationWrite(expectedImportEpoch: operationImportEpoch, allowDuringImport: false) else {
            return false
        }
        defer { finishConversationWrite() }
        do {
            return try await storage.updateMemoryMode(id: id, memoryMode: .polluted).boolValue
        } catch {
            publishIOError(operation: "标记会话记忆污染", detail: "目标 \(id): \(error)")
            return false
        }
    }

    /// 用户手动复位：POLLUTED→ENABLED（KMP 层唯一允许的降级路径）。
    @discardableResult
    func resetConversationMemoryPollution(_ id: KotlinUuid) async -> Bool {
        let operationImportEpoch = importEpoch
        guard beginConversationWrite(expectedImportEpoch: operationImportEpoch, allowDuringImport: false) else {
            return false
        }
        defer { finishConversationWrite() }
        do {
            let updated = try await storage.updateMemoryMode(id: id, memoryMode: .enabled).boolValue
            if updated {
                await refreshSummaries()
            }
            return updated
        } catch {
            publishIOError(operation: "恢复会话记忆", detail: "目标 \(id): \(error)")
            return false
        }
    }

    /// 只列出 POLLUTED 会话（设置页「受外部内容影响的会话」列表投影）。实时读盘，
    /// 不依赖内存 currentConversation。
    func pollutedConversationSummaries() async -> [ConversationSummary] {
        do {
            try await refreshSubagentConversationVisibility()
            await refreshSummaries()
        } catch {
            publishIOError(operation: "读取子代理关系", detail: "\(error)")
        }
        return summaries.filter { $0.memoryMode == .polluted }
    }

    /// 重建一个仅 title 不同的 Conversation（Swift 侧无 partial copy，用全字段构造器）。
    /// 所有其他字段保持原值；updateAt 刷新到当前时刻以反映「最近修改」。
    private func retitledCopy(of conversation: Conversation, title: String) -> Conversation {
        Conversation(
            id: conversation.id,
            assistantId: conversation.assistantId,
            title: title,
            messageNodes: conversation.messageNodes,
            chatSuggestions: conversation.chatSuggestions,
            isPinned: conversation.isPinned,
            autoApproveToolCalls: conversation.autoApproveToolCalls,
            memoryMode: conversation.memoryMode,
            createAt: conversation.createAt,
            updateAt: nowInstant(),
            newConversation: conversation.newConversation
        )
    }

    /// 当前时刻的 KotlinInstant。用 epoch 毫秒构造，避免 ISO 字符串 parse 的边界风险
    ///（不同平台对 fractional seconds / 时区偏移的容忍度不一致）。KotlinInstant companion
    /// 的 fromEpochMilliseconds 是无歧义的。
    func nowInstant() -> KotlinInstant {
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000)
        return KotlinInstant.companion.fromEpochMilliseconds(epochMilliseconds: epochMs)
    }

    /// 删除会话：只有磁盘删除确认后才执行 owner 清理并切换 current。
    @discardableResult
    func deleteConversation(
        id: KotlinUuid,
        onDeletionCommitted: ([KotlinUuid]) -> Void = { _ in }
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        let descendants: [KotlinUuid]
        do {
            if let dao = threadEdgeDaoProvider?() {
                descendants = try await dao.descendantsOf(rootThreadId: id.toHexDashString())
                    .map { KotlinUuid.companion.parse(uuidString: $0.childThreadId) }
            } else {
                descendants = []
            }
        } catch {
            publishIOError(operation: "读取关联子任务，删除未执行", detail: "\(error)")
            return false
        }
        guard beginConversationWrite(expectedImportEpoch: operationImportEpoch, allowDuringImport: false) else {
            return false
        }
        defer { finishConversationWrite() }
        markDeletedConversation(id)
        do {
#if DEBUG
            if let beforeDeleteForTesting {
                try await beforeDeleteForTesting()
            }
#endif
            try await storage.deleteConversation(id: id)
        } catch {
            let conversationStillExists: Bool
            do {
                conversationStillExists = try await storage.loadConversation(id: id) != nil
            } catch {
                conversationStillExists = true
            }
            guard !conversationStillExists else {
                unmarkDeletedConversation(id)
                publishIOError(operation: "删除会话", detail: "\(id): \(error)")
                return false
            }
            publishIOError(operation: "删除会话", detail: "\(id): \(error)")
        }

        onDeletionCommitted([id] + descendants)
        let deletedConversationKeys = ([id] + descendants).map { $0.toHexDashString() }
        recapGenerator.invalidate(conversationIDs: deletedConversationKeys)
        await clearIntelligentUIDrafts(for: Set(deletedConversationKeys))
        do {
            for deletedID in [id] + descendants {
                try artifactStore.removeConversation(deletedID.toHexDashString())
            }
        } catch {
            publishIOError(operation: "清理产物架", detail: error.localizedDescription)
        }
        do {
            for conversationID in deletedConversationKeys {
                try recapStore.removeConversation(conversationID)
            }
        } catch {
            publishIOError(operation: "清理回顾", detail: error.localizedDescription)
        }
        do {
            try IOSContextCompactionCoordinator.shared.removeCompacts(
                conversationIds: ([id] + descendants).map { String(describing: $0) }
            )
        } catch {
            publishIOError(operation: "清理上下文摘要", detail: error.localizedDescription)
        }
        pendingBackgroundContentConversationIds.remove(String(describing: id))
        if listPreviewsByConversationId.removeValue(forKey: sequenceKey(for: id)) != nil {
            persistListPreviews()
        }
        if listIconsByConversationId.removeValue(forKey: sequenceKey(for: id)) != nil {
            persistListIcons()
        }
        await refreshSummaries()

        if currentConversation?.id == id {
            if let next = summaries.first {
                await selectConversation(id: next.id)
            } else {
                await newConversation()
            }
        }
        return true
    }

    /// Local drafts do not follow restored documents or survive deletion of their source.
    private func clearIntelligentUIDrafts(for conversationIDs: Set<String>) async {
        intelligentUIStateStore.removeConversations(conversationIDs)
        do {
            try await intelligentUIStateStore.flush()
        } catch {
            publishIOError(operation: "清理任务卡草稿", detail: error.localizedDescription)
        }
    }

    /// 重命名：partial update，不改 messages。
    func renameConversation(id: KotlinUuid, title: String) async {
        _ = await updateConversationTitle(id: id, title: title, expectedCurrentTitle: nil)
    }

    /// 自动标题只能替换生成开始时看到的标题，避免迟到结果覆盖用户手工重命名。
    @discardableResult
    func renameConversation(
        id: KotlinUuid,
        title: String,
        ifCurrentTitleMatches expectedTitle: String
    ) async -> Bool {
        await updateConversationTitle(
            id: id,
            title: title,
            expectedCurrentTitle: expectedTitle
        )
    }

    private func updateConversationTitle(
        id: KotlinUuid,
        title: String,
        expectedCurrentTitle: String?
    ) async -> Bool {
        let operationImportEpoch = importEpoch
        guard beginConversationWrite(expectedImportEpoch: operationImportEpoch, allowDuringImport: false) else {
            return false
        }
        defer { finishConversationWrite() }
        do {
            if let expectedCurrentTitle {
                let didUpdate = try await storage.updateTitleIfCurrentTitleMatches(
                    id: id,
                    title: title,
                    expectedTitle: expectedCurrentTitle
                ).boolValue
                guard didUpdate else { return false }
            } else {
                try await storage.updateMetadata(id: id, title: title, isPinned: nil)
            }
            advanceWriteSequence(for: id)
        } catch {
            publishIOError(operation: "重命名", detail: "\(id): \(error)")
            return false
        }
        await refreshSummaries()
        if currentConversation?.id == id, let refreshed = try? await storage.loadConversation(id: id) {
            setCurrent(refreshed)
        }
        return true
    }

    /// 置顶/取消置顶切换。
    func togglePin(id: KotlinUuid) async {
        let operationImportEpoch = importEpoch
        guard beginConversationWrite(expectedImportEpoch: operationImportEpoch, allowDuringImport: false) else {
            return
        }
        defer { finishConversationWrite() }
        let currentPinned = allSummaries.first(where: { $0.id == id })?.isPinned ?? false
        let newPinned = KotlinBoolean(value: !currentPinned)
        do {
            try await storage.updateMetadata(id: id, title: nil, isPinned: newPinned)
            advanceWriteSequence(for: id)
        } catch {
            publishIOError(operation: "置顶", detail: "\(id): \(error)")
        }
        await refreshSummaries()
        if currentConversation?.id == id, let refreshed = try? await storage.loadConversation(id: id) {
            setCurrent(refreshed)
        }
    }

    // MARK: - Loading messages into ChatViewModel

    /// 当前会话的 messages，供 ChatViewModel 在切换会话时灌入。
    var currentMessages: [UIMessage] {
        currentConversation?.currentMessages as? [UIMessage] ?? []
    }

    func messages(for id: KotlinUuid) async -> [UIMessage]? {
        if currentConversation?.id == id {
            return currentMessages
        }
        guard !isDeletedConversation(id) else { return nil }
        do {
#if DEBUG
            beforeMessageLoadForTesting?(id)
#endif
            return try await storage.loadConversation(id: id)?.currentMessages as? [UIMessage]
        } catch {
            publishIOError(operation: "加载会话", detail: "\(id): \(error)")
            return nil
        }
    }

    private static func isReusableEmptyConversation(_ conversation: Conversation) -> Bool {
        !searchableMessages(in: conversation).contains { $0.role == MessageRole.user }
    }

    private static func sameMessageIdentity(_ lhs: [UIMessage], _ rhs: [UIMessage]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            String(describing: left.id) == String(describing: right.id)
        }
    }

    /// Recovery can advance the baseline past a pending card. Only finalize the same
    /// run's unchanged text part; retain current content and all unrelated metadata.
    private static func messageByApplyingIntelligentUITerminalMetadata(
        to current: UIMessage, checkpoint: UIMessage, terminal: UIMessage
    ) -> UIMessage {
        var changed = false
        let jsonBridge = IosToolOutputJsonBridge.shared
        let parts: [UIMessagePart] = current.parts.enumerated().map { index, part in
            guard index < checkpoint.parts.count, index < terminal.parts.count,
                  let currentText = part as? UIMessagePart.Text,
                  let checkpointText = checkpoint.parts[index] as? UIMessagePart.Text,
                  let terminalText = terminal.parts[index] as? UIMessagePart.Text,
                  let runID = jsonBridge.metadataString(part: checkpointText, key: IOSIntelligentUITerminal.runIDKey),
                  jsonBridge.metadataString(part: checkpointText, key: IOSIntelligentUITerminal.completedKey) == nil,
                  jsonBridge.metadataString(part: currentText, key: IOSIntelligentUITerminal.completedKey) == nil,
                  jsonBridge.metadataString(part: terminalText, key: IOSIntelligentUITerminal.completedKey) == "completed",
                  jsonBridge.metadataString(part: currentText, key: IOSIntelligentUITerminal.runIDKey) == runID,
                  jsonBridge.metadataString(part: terminalText, key: IOSIntelligentUITerminal.runIDKey) == runID,
                  jsonBridge.metadataString(part: checkpointText, key: MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY) == nil,
                  jsonBridge.metadataString(part: currentText, key: MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY) == nil,
                  jsonBridge.metadataString(part: terminalText, key: MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY) == nil,
                  checkpointText.text == terminalText.text, currentText.text == terminalText.text else { return part }
            changed = true
            // Keep nested JsonObject values in Kotlin; Swift collection bridges erase their type.
            return jsonBridge.mergeTextMetadata(part: currentText, updates: [
                IOSIntelligentUITerminal.completedKey: "completed",
                IOSIntelligentUITerminal.runIDKey: runID
            ])
        }
        guard changed else { return current }
        return UIMessage(
            id: current.id, role: current.role, parts: parts, annotations: current.annotations,
            createdAt: current.createdAt, finishedAt: current.finishedAt, modelId: current.modelId,
            usage: current.usage, translation: current.translation
        )
    }

    private static func completedToolOutputs(in messages: [UIMessage]) -> [String: UIMessagePart.Tool] {
        var outputs: [String: UIMessagePart.Tool] = [:]
        for message in messages where message.role == MessageRole.assistant {
            for case let tool as UIMessagePart.Tool in message.parts where !tool.output.isEmpty {
                outputs[chatToolCallKey(tool)] = tool
            }
        }
        return outputs
    }

    private static func messagesByApplyingToolOutputs(
        _ outputs: [String: UIMessagePart.Tool],
        to messages: [UIMessage]
    ) -> (messages: [UIMessage], didApply: Bool) {
        guard !outputs.isEmpty else { return (messages, false) }
        var didApply = false
        let updated = messages.map { message -> UIMessage in
            guard message.role == MessageRole.assistant else { return message }
            var changed = false
            let parts = message.parts.map { part -> UIMessagePart in
                guard let tool = part as? UIMessagePart.Tool,
                      tool.output.isEmpty,
                      let completed = outputs[chatToolCallKey(tool)] else {
                    return part
                }
                changed = true
                didApply = true
                return completed
            }
            guard changed else { return message }
            return UIMessage(
                id: message.id,
                role: message.role,
                parts: parts,
                annotations: message.annotations,
                createdAt: message.createdAt,
                finishedAt: message.finishedAt,
                modelId: message.modelId,
                usage: message.usage,
                translation: message.translation
            )
        }
        return (updated, didApply)
    }

    private static func messagesContainingToolOutputs(
        _ outputs: [String: UIMessagePart.Tool],
        in messages: [UIMessage]
    ) -> [UIMessage] {
        guard !outputs.isEmpty else { return [] }
        let keys = Set(outputs.keys)
        return messages.filter { message in
            guard message.role == MessageRole.assistant else { return false }
            return message.parts.contains { part in
                guard let tool = part as? UIMessagePart.Tool else { return false }
                return keys.contains(chatToolCallKey(tool))
            }
        }
    }


    /// 替换 currentConversation 并 bump currentRevision（驱动需要感知内容变化的 UI）。
    /// 不 bump conversationSwitchedRevision——调用方若代表「切到了别的会话」，
    /// 应改用 setCurrentAsSwitch。
    func setCurrent(_ conversation: Conversation?) {
        currentConversation = conversation
        currentRevision &+= 1
    }

    /// 切换到另一个会话时调用：同时 bump currentRevision 与 conversationSwitchedRevision，
    /// 让 viewport 能区分「真切换」与「同会话落盘/编辑」。
    private func setCurrentAsSwitch(_ conversation: Conversation?) {
        currentConversation = conversation
        currentRevision &+= 1
        conversationSwitchedRevision &+= 1
    }

    @discardableResult
    func persist(
        _ conversation: Conversation,
        ifUnchangedSince baseline: IOSConversationWriteBaseline? = nil,
        expectedImportEpoch: UInt64,
        allowDuringImport: Bool = false,
        ownsBranchMutation: Bool = false
    ) async -> Conversation? {
        guard beginConversationWrite(
            expectedImportEpoch: expectedImportEpoch,
            allowDuringImport: allowDuringImport
        ) else { return nil }
        defer { finishConversationWrite() }
        guard beginMessageSnapshotWrite(to: conversation.id, ownsBranchMutation: ownsBranchMutation) else { return nil }
        defer { finishMessageSnapshotWrite(to: conversation.id) }

        do {
            guard !isDeletedConversation(conversation.id) else { return nil }
            guard acceptsWrite(
                to: conversation.id,
                baseline: baseline,
                expectedImportEpoch: expectedImportEpoch,
                allowDuringImport: allowDuringImport
            ) else { return nil }
#if DEBUG
            if let beforePersistForTesting {
                await beforePersistForTesting(conversation)
            }
#endif
            guard !isDeletedConversation(conversation.id) else { return nil }
            guard acceptsWrite(
                to: conversation.id,
                baseline: baseline,
                expectedImportEpoch: expectedImportEpoch,
                allowDuringImport: allowDuringImport
            ) else { return nil }
            advanceWriteSequence(for: conversation.id)
            let reservedSequence = writeSequences[sequenceKey(for: conversation.id), default: 0]
#if DEBUG
            await afterPersistReservationForTesting?(conversation)
#endif
            let persisted = try await storage.saveConversation(conversation: conversation)
            let changedDuringSave = writeSequences[sequenceKey(for: conversation.id), default: 0] != reservedSequence
            // A concurrent metadata writer may finish before this continuation.
            // Preserve the existing read-back only when another local write ran.
            if changedDuringSave {
                return try await storage.loadConversation(id: conversation.id) ?? persisted
            }
            return persisted
        } catch {
            // 写盘失败：不丢内存会话（currentConversation 仍由调用方更新），
            // 但上抛给用户，避免"以为保存了实际没保存"的静默丢数据。
            publishIOError(operation: "保存会话", detail: "\(error)")
            return nil
        }
    }

    private func acceptsWrite(
        to id: KotlinUuid,
        baseline: IOSConversationWriteBaseline?,
        expectedImportEpoch: UInt64,
        allowDuringImport: Bool = false
    ) -> Bool {
        guard acceptsImportEpoch(expectedImportEpoch, allowDuringImport: allowDuringImport) else {
            return false
        }
        guard let baseline else { return true }
        let key = sequenceKey(for: id)
        guard key == baseline.key else { return false }
        guard baseline.importEpoch == importEpoch else {
            print("[AA-STORE] skip pre-import snapshot write id=\(key) baselineEpoch=\(baseline.importEpoch) currentEpoch=\(importEpoch)")
            return false
        }
        guard writeSequences[key, default: 0] == baseline.sequence else {
            print("[AA-STORE] skip stale snapshot write id=\(key) baseline=\(baseline.sequence) current=\(writeSequences[key, default: 0])")
            return false
        }
        return true
    }

    func acceptsImportEpoch(
        _ expectedImportEpoch: UInt64,
        allowDuringImport: Bool = false
    ) -> Bool {
        guard expectedImportEpoch == importEpoch else {
            print("[AA-STORE] skip pre-import operation expectedEpoch=\(expectedImportEpoch) currentEpoch=\(importEpoch)")
            return false
        }
        guard allowDuringImport || !isImportingConversationDocuments else {
            print("[AA-STORE] skip conversation write while restore is applying")
            return false
        }
        return true
    }

    private func beginConversationWrite(
        expectedImportEpoch: UInt64,
        allowDuringImport: Bool
    ) -> Bool {
        guard acceptsImportEpoch(expectedImportEpoch, allowDuringImport: allowDuringImport) else {
            return false
        }
        inFlightConversationWrites &+= 1
        return true
    }

    private func finishConversationWrite() {
        inFlightConversationWrites = max(0, inFlightConversationWrites - 1)
        guard inFlightConversationWrites == 0 else { return }
        let continuations = conversationWriteDrainContinuations
        conversationWriteDrainContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func waitForConversationWritesToDrain() async {
        guard inFlightConversationWrites > 0 else { return }
        await withCheckedContinuation { continuation in
            conversationWriteDrainContinuations.append(continuation)
        }
    }

    private func advanceWriteSequence(for id: KotlinUuid) {
        let key = sequenceKey(for: id)
        writeSequences[key, default: 0] &+= 1
    }

    private func sequenceKey(for id: KotlinUuid) -> String {
        String(describing: id)
    }

    private static func loadListPreviews(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded.filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func persistListPreviews() {
        do {
            let directory = listPreviewsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(listPreviewsByConversationId)
            try data.write(to: listPreviewsFileURL, options: .atomic)
        } catch {
            publishIOError(operation: "保存会话预览", detail: "\(error)")
        }
    }

    private func persistListIcons() {
        do {
            let directory = listIconsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(listIconsByConversationId)
            try data.write(to: listIconsFileURL, options: .atomic)
        } catch {
            publishIOError(operation: "保存会话图标", detail: "\(error)")
        }
    }

    func refreshSummaries() async {
        do {
            if !didLoadSummaries {
                try await refreshSubagentConversationVisibility()
            }
            allSummaries = try await storage.listSummaries()
                .filter { !isDeletedConversation($0.id) }
            didLoadSummaries = true
            applySummaryVisibility()
        } catch {
            publishIOError(operation: "读取会话列表及编排关系", detail: "\(error)")
        }
    }

    private func loadSummaryProjectionIfNeeded() async -> [ConversationSummary] {
        if !didLoadSummaries { await refreshSummaries() }
        return summaries
    }

    func visibleSummariesForListing() async -> [ConversationSummary] {
        await loadSummaryProjectionIfNeeded()
    }

    private func applySummaryVisibility() {
        summaries = allSummaries.filter { summary in
            !subagentConversationIDs.contains(subagentConversationKey(for: summary.id))
        }
    }

    private func subagentConversationKey(for id: KotlinUuid) -> String {
        id.toHexDashString().lowercased()
    }

    private func markDeletedConversation(_ id: KotlinUuid) {
        deletedConversationIds.insert(String(describing: id))
    }

    private func unmarkDeletedConversation(_ id: KotlinUuid) {
        deletedConversationIds.remove(String(describing: id))
    }

    func isDeletedConversation(_ id: KotlinUuid) -> Bool {
        deletedConversationIds.contains(String(describing: id))
    }
}

extension IOSConversationStore: IOSBoardConversationSignalSource {}
