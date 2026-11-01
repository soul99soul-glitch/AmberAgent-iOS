import CryptoKit
import Foundation
import Observation

extension IOSIntelligentUIPayloadDetector {
    static func mayContainTaskUI(in text: String) -> Bool {
        IOSIntelligentUIPayloadDetector(text: text).mayContainPayload
    }
}

/// Validated snapshot of a user's interaction with a `task-ui` card on macOS.
/// Shares the exact protocol, validation, and prompt format with iOS (`IOSIntelligentUISubmission`).
struct DesktopIntelligentUISubmission: Codable, Equatable, Sendable {
    static let metadataKey = "amber_task_ui_submission"

    struct Input: Codable, Equatable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    let id: String
    let source: IOSIntelligentUISource
    let definitionFingerprint: String
    let draftRevision: Int
    let goal: String
    let question: String
    let option: IOSIntelligentUICardDefinition.Option?
    let inputs: [Input]
    let taskKind: String?
    let studySummary: IOSIntelligentUIStudySession.Summary?

    init(
        source: IOSIntelligentUISource,
        definition: IOSIntelligentUICardDefinition,
        draft: IOSIntelligentUIDraft
    ) throws {
        let option = definition.options.first(where: { $0.id == draft.selectedOptionID })
        if definition.kind == "decision", option == nil {
            throw IOSIntelligentUIProtocolError(reason: "请先选择一个方案。")
        }
        if definition.kind != "decision", draft.selectedOptionID != nil {
            throw IOSIntelligentUIProtocolError(reason: "当前任务不需要选择方案。")
        }
        try IOSIntelligentUIComponentCatalog.validateDraftValues(draft.values, components: definition.components)
        for field in definition.submissionFields where field.required {
            guard definition.requiredFieldHasValue(field, values: draft.values) else {
                throw IOSIntelligentUIProtocolError(reason: "请填写「\(field.label)」。")
            }
        }
        self.id = UUID().uuidString
        self.source = source
        self.definitionFingerprint = draft.definitionFingerprint
        self.draftRevision = draft.revision
        self.goal = definition.goal
        self.question = definition.question
        self.option = option
        self.taskKind = definition.kind == "decision" ? nil : definition.kind
        if definition.kind == "study", let study = definition.study {
            let session = try IOSIntelligentUIStudySession.restore(
                draft.values[IOSIntelligentUIStudySession.storageKey],
                definition: study
            )
            self.studySummary = session.summary(definition: study)
        } else {
            self.studySummary = nil
        }
        self.inputs = definition.submissionFields.compactMap { field in
            let value = (draft.values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let summary = definition.fieldValueSummary(value, for: field)
            return summary.isEmpty ? nil : Input(id: field.id, label: field.label, value: String(summary.prefix(2_000)))
        }
    }

    func matches(_ draft: IOSIntelligentUIDraft) -> Bool {
        definitionFingerprint == draft.definitionFingerprint && draftRevision == draft.revision
    }

    func prompt(request: String? = nil) -> String {
        var lines: [String]
        if let option {
            lines = [
                "【任务卡选择】",
                "任务：\(goal)",
                "待决问题：\(question)",
                "所选方案：\(option.title)",
                "方案内容：\(option.summary)"
            ]
            if let tradeoffs = option.tradeoffs, !tradeoffs.isEmpty {
                lines.append("方案取舍：\(tradeoffs.joined(separator: "；"))")
            }
        } else {
            lines = [
                "【任务卡交互结果】",
                "任务：\(goal)",
                "交互类型：\(taskKind ?? "form")"
            ]
            if !question.isEmpty { lines.append("任务问题：\(question)") }
            if let studySummary { lines.append("学习进度：\(studySummary.promptSummary)") }
        }
        for input in inputs {
            lines.append("\(input.label)：\(input.value)")
        }
        lines.append("来源：\(source.messageID) / \(source.cardID)")
        let defaultRequest = option != nil
            ? "基于以上用户选择和补充约束继续当前任务。"
            : "基于以上用户输入和交互结果继续当前任务。"
        let trimmedRequest = request?.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("请求：\(trimmedRequest?.isEmpty == false ? trimmedRequest! : defaultRequest)")
        return lines.joined(separator: "\n")
    }

    /// Extracts an embedded iOS submission receipt from a message's `canonicalJSON`, if present.
    static func decodeFromCanonicalJSON(_ canonicalJSON: String?) -> DesktopIntelligentUISubmission? {
        guard let canonicalJSON,
              canonicalJSON.contains(metadataKey),
              let data = canonicalJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = root["parts"] as? [[String: Any]] else { return nil }
        for part in parts {
            guard let metadata = part["metadata"] as? [String: Any],
                  let raw = metadata[metadataKey] as? String,
                  let submissionData = raw.data(using: .utf8),
                  let submission = try? JSONDecoder().decode(DesktopIntelligentUISubmission.self, from: submissionData) else {
                continue
            }
            return submission
        }
        return nil
    }
}

enum DesktopIntelligentUISubmitResult: Equatable, Sendable {
    case started
    case saved
    case draftInserted
    case failure(String)
}

enum DesktopIntelligentUIRequestPolicy {
    static let continuationIntents: Set<String> = ["按这个继续", "基于选择继续", "按当前选择继续"]

    static func systemPrompt(enabled: Bool) -> String {
        guard enabled else { return "" }
        return IOSIntelligentUIProtocol.capabilityPrompt
    }

    static func isExplicitContinuationRequest(_ text: String) -> Bool {
        let intent = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        return continuationIntents.contains(intent)
    }
}

private struct DesktopIntelligentUIStoredReceipts: Codable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let userMessageID: String
        let submission: DesktopIntelligentUISubmission
    }

    var entries: [Entry] = []
}

/// Coordinates `task-ui` card drafts, submission receipts, and composer draft insertion on macOS.
@MainActor
@Observable
final class DesktopIntelligentUIHost {
    let stateStore: IOSIntelligentUIStateStore
    private(set) var receipts: [IOSIntelligentUISource: DesktopIntelligentUISubmission] = [:]
    private(set) var pending: Set<IOSIntelligentUISource> = []

    @ObservationIgnored private let receiptsFileURL: URL?
    @ObservationIgnored private var recordedEntries: [DesktopIntelligentUIStoredReceipts.Entry] = []
    @ObservationIgnored private let submitAction: @MainActor (DesktopIntelligentUISubmission) async -> DesktopIntelligentUISubmitResult
    @ObservationIgnored private let insertDraftAction: @MainActor (DesktopIntelligentUISubmission) -> DesktopIntelligentUISubmitResult

    init(
        stateStore: IOSIntelligentUIStateStore,
        receiptsFileURL: URL? = nil,
        submitAction: @escaping @MainActor (DesktopIntelligentUISubmission) async -> DesktopIntelligentUISubmitResult,
        insertDraftAction: @escaping @MainActor (DesktopIntelligentUISubmission) -> DesktopIntelligentUISubmitResult = { _ in
            .failure("当前环境不支持填入输入框草稿。")
        }
    ) {
        self.stateStore = stateStore
        self.receiptsFileURL = receiptsFileURL
        self.submitAction = submitAction
        self.insertDraftAction = insertDraftAction
        if let receiptsFileURL,
           FileManager.default.fileExists(atPath: receiptsFileURL.path),
           let data = try? Data(contentsOf: receiptsFileURL),
           let decoded = try? JSONDecoder().decode(DesktopIntelligentUIStoredReceipts.self, from: data) {
            self.recordedEntries = decoded.entries
        }
    }

    func submit(
        source: IOSIntelligentUISource,
        definition: IOSIntelligentUICardDefinition
    ) async -> DesktopIntelligentUISubmitResult {
        guard !pending.contains(source) else { return .failure("这张任务卡正在提交。") }
        stateStore.register(source: source, definition: definition)
        let draft = stateStore.draft(for: source, definition: definition)
        let submission: DesktopIntelligentUISubmission
        do {
            submission = try DesktopIntelligentUISubmission(source: source, definition: definition, draft: draft)
            try await stateStore.flush()
        } catch {
            return .failure(error.localizedDescription)
        }
        guard receipts[source]?.matches(draft) != true else {
            return .failure("此选择已经提交；修改后可以再提交。")
        }
        pending.insert(source)
        defer { pending.remove(source) }
        let result = await submitAction(submission)
        if result == .started || result == .saved {
            receipts[source] = submission
        }
        return result
    }

    func insertIntoDraft(
        source: IOSIntelligentUISource,
        definition: IOSIntelligentUICardDefinition
    ) -> DesktopIntelligentUISubmitResult {
        stateStore.register(source: source, definition: definition)
        let draft = stateStore.draft(for: source, definition: definition)
        let submission: DesktopIntelligentUISubmission
        do {
            submission = try DesktopIntelligentUISubmission(source: source, definition: definition, draft: draft)
        } catch {
            return .failure(error.localizedDescription)
        }
        return insertDraftAction(submission)
    }

    func recordReceipt(_ submission: DesktopIntelligentUISubmission, userMessageID: UUID) {
        let key = userMessageID.uuidString.lowercased()
        recordedEntries.removeAll {
            $0.userMessageID.lowercased() == key || $0.submission.source == submission.source
        }
        recordedEntries.append(.init(userMessageID: key, submission: submission))
        receipts[submission.source] = submission
        persistReceipts()
    }

    /// Reconciles active receipts for a conversation against its current message branch.
    /// Deleting the user reply, regenerating the assistant reply, or switching branches clears stale receipts.
    func refreshReceipts(messages: [DesktopMessage], conversationID: UUID) {
        let conversationKey = conversationID.uuidString.lowercased()
        var messageIndices: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            messageIndices[message.id.uuidString.lowercased()] = index
        }
        var next = receipts.filter { $0.key.conversationID.lowercased() != conversationKey }
        let entriesByMessageID = Dictionary(
            recordedEntries
                .filter { $0.submission.source.conversationID.lowercased() == conversationKey }
                .map { ($0.userMessageID.lowercased(), $0.submission) },
            uniquingKeysWith: { _, latest in latest }
        )

        for (userIndex, message) in messages.enumerated() where message.role == .user {
            let candidate = entriesByMessageID[message.id.uuidString.lowercased()]
                ?? DesktopIntelligentUISubmission.decodeFromCanonicalJSON(message.canonicalJSON)
            guard let submission = candidate,
                  submission.source.conversationID.lowercased() == conversationKey,
                  let sourceIndex = messageIndices[submission.source.messageID.lowercased()],
                  sourceIndex < userIndex else { continue }
            let sourceMessage = messages[sourceIndex]
            guard sourceMessage.role == .assistant, sourceMessage.state == .complete else { continue }
            let textContent = Self.sourceText(in: sourceMessage, textPartIndex: submission.source.textPartIndex)
            let cards = IOSIntelligentUIProtocol.parse(textContent, isStreaming: false).compactMap { segment -> IOSIntelligentUICardDefinition? in
                if case .card(let card) = segment { return card }
                return nil
            }
            guard let definition = cards.first(where: { $0.cardID == submission.source.cardID }),
                  IOSIntelligentUIStateStore.definitionFingerprint(definition) == submission.definitionFingerprint else {
                continue
            }
            next[submission.source] = submission
        }
        if next != receipts {
            receipts = next
        }
    }

    func removeConversation(_ id: UUID) {
        let raw = id.uuidString
        let lower = raw.lowercased()
        stateStore.removeConversations([raw, lower, raw.uppercased()])
        receipts = receipts.filter { $0.key.conversationID.lowercased() != lower }
        pending = pending.filter { $0.conversationID.lowercased() != lower }
        let before = recordedEntries.count
        recordedEntries.removeAll { $0.submission.source.conversationID.lowercased() == lower }
        if recordedEntries.count != before {
            persistReceipts()
        }
    }

    static func sourceText(in message: DesktopMessage, textPartIndex: Int) -> String {
        let blocks = message.orderedDisplayBlocks(streaming: false)
        var textIndex = 0
        for block in blocks {
            if case .text(let segment) = block {
                if textIndex == textPartIndex { return segment }
                textIndex += 1
            }
        }
        if blocks.indices.contains(textPartIndex), case .text(let segment) = blocks[textPartIndex] {
            return segment
        }
        return textPartIndex == 0 ? message.text : ""
    }

    private func persistReceipts() {
        guard let receiptsFileURL else { return }
        let snapshot = DesktopIntelligentUIStoredReceipts(entries: recordedEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: receiptsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: receiptsFileURL, options: [.atomic])
    }
}

@MainActor
extension DesktopWorkspace {
    func refreshIntelligentUIReceipts(for conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        intelligentUIHost.refreshReceipts(messages: conversation.messages, conversationID: conversationID)
    }

    func resolveIntelligentUIContinuation(
        for text: String,
        conversationID: UUID
    ) throws -> DesktopIntelligentUISubmission? {
        guard DesktopIntelligentUIRequestPolicy.isExplicitContinuationRequest(text) else { return nil }
        let rawID = conversationID.uuidString
        guard let source = intelligentUIStateStore.activeSource(for: rawID)
            ?? intelligentUIStateStore.activeSource(for: rawID.lowercased()) else {
            return nil
        }
        guard settings.intelligentUIEnabled else {
            throw IOSIntelligentUIProtocolError(reason: "原生智能 UI 已在设置中关闭，请启用后再按任务卡选择继续。")
        }
        guard !generatingConversationIDs.contains(conversationID), !isLoading else {
            throw IOSIntelligentUIProtocolError(reason: "当前回复结束后可按任务卡选择继续。")
        }
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let message = conversation.messages.first(where: { $0.id.uuidString.caseInsensitiveCompare(source.messageID) == .orderedSame }),
              message.role == .assistant,
              message.state == .complete else {
            throw IOSIntelligentUIProtocolError(reason: "最近操作的任务卡不在当前分支或尚未完成，请重新选择当前方案。")
        }
        let partText = DesktopIntelligentUIHost.sourceText(in: message, textPartIndex: source.textPartIndex)
        let definition = IOSIntelligentUIProtocol.parse(partText, isStreaming: false).compactMap { segment -> IOSIntelligentUICardDefinition? in
            if case .card(let card) = segment, card.cardID == source.cardID { return card }
            return nil
        }.first
        guard let definition else {
            throw IOSIntelligentUIProtocolError(reason: "任务卡内容已变更，请重新选择。")
        }
        intelligentUIStateStore.register(source: source, definition: definition)
        let draft = intelligentUIStateStore.draft(for: source, definition: definition)
        return try DesktopIntelligentUISubmission(source: source, definition: definition, draft: draft)
    }

    /// Appends the formatted card submission into the conversation's composer draft without clobbering existing text or attachments.
    @discardableResult
    func insertIntelligentUIDraft(_ submission: DesktopIntelligentUISubmission) -> DesktopIntelligentUISubmitResult {
        guard settings.intelligentUIEnabled else {
            return .failure("原生智能 UI 已在设置中关闭，请启用后使用。")
        }
        guard let conversationID = UUID(uuidString: submission.source.conversationID),
              let conversation = conversations.first(where: { $0.id == conversationID }) else {
            return .failure("任务卡所属会话不存在或尚未加载。")
        }
        guard let sourceMessage = conversation.messages.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(submission.source.messageID) == .orderedSame
        }), sourceMessage.role == .assistant, sourceMessage.state == .complete else {
            return .failure("任务卡所在回复尚未完成或已不在当前分支。")
        }
        let prompt = submission.prompt()
        let existing = (selectedID == conversationID ? draft : drafts[conversationID] ?? "")
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextDraft: String
        if trimmedExisting.isEmpty {
            nextDraft = prompt
        } else if trimmedExisting.hasSuffix(prompt) {
            nextDraft = existing
        } else {
            nextDraft = existing + (existing.hasSuffix("\n") ? "\n" : "\n\n") + prompt
        }
        drafts[conversationID] = nextDraft
        if selectedID == conversationID {
            draft = nextDraft
        }
        return .draftInserted
    }

    /// Directly submits a card interaction as a new user message in its conversation and starts the continuation turn.
    /// Never overwrites the composer's `draft` or `pendingAttachments`.
    func submitIntelligentUI(_ submission: DesktopIntelligentUISubmission) async -> DesktopIntelligentUISubmitResult {
        guard settings.intelligentUIEnabled else {
            return .failure("原生智能 UI 已在设置中关闭，请在设置中启用后提交。")
        }
        guard let conversationID = UUID(uuidString: submission.source.conversationID),
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return .failure("任务卡不属于已加载的会话，请返回原会话后提交。")
        }
        guard !isLoading, !isManagingBackup else {
            return .failure("正在加载或管理备份，请稍候再提交。")
        }
        guard !mutatingBranchConversationIDs.contains(conversationID) else {
            return .failure("正在保存消息更改，请稍候再提交。")
        }
        guard !scheduledRunConversationIDs.contains(conversationID) else {
            return .failure("定时任务正在这条会话中运行，请等它结束后再提交。")
        }
        guard !generatingConversationIDs.contains(conversationID) else {
            return .failure("当前回复结束后可提交；你也可以先点击「填入输入框草稿」。")
        }
        guard let sourceMessage = conversations[index].messages.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(submission.source.messageID) == .orderedSame
        }), sourceMessage.role == .assistant else {
            return .failure("任务卡来源已不在当前分支，请使用当前方案。")
        }
        guard sourceMessage.state == .complete else {
            return .failure("任务卡所在回复尚未成功完成，请重新生成后选择。")
        }
        let partText = DesktopIntelligentUIHost.sourceText(in: sourceMessage, textPartIndex: submission.source.textPartIndex)
        let cards = IOSIntelligentUIProtocol.parse(partText, isStreaming: false).compactMap { segment -> IOSIntelligentUICardDefinition? in
            if case .card(let card) = segment { return card }
            return nil
        }
        guard let definition = cards.first(where: { $0.cardID == submission.source.cardID }) else {
            return .failure("任务卡内容已变更，请重新选择。")
        }
        intelligentUIStateStore.register(source: submission.source, definition: definition)
        let currentDraft = intelligentUIStateStore.draft(for: submission.source, definition: definition)
        guard submission.matches(currentDraft) else {
            return .failure("任务卡选择已变更，请按当前选择重新提交。")
        }
        do {
            let expected = try DesktopIntelligentUISubmission(
                source: submission.source,
                definition: definition,
                draft: currentDraft
            )
            guard expected.goal == submission.goal,
                  expected.question == submission.question,
                  expected.option == submission.option,
                  expected.inputs == submission.inputs,
                  expected.taskKind == submission.taskKind,
                  expected.studySummary == submission.studySummary,
                  submission.inputs.allSatisfy({ $0.value.count <= 2_000 }) else {
                return .failure("提交内容与当前任务卡选择不一致，请重新提交。")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
        refreshIntelligentUIReceipts(for: conversationID)
        guard intelligentUIHost.receipts[submission.source]?.matches(currentDraft) != true else {
            return .failure("此选择已经提交；修改后可以再提交。")
        }

        let userMessage: DesktopMessage
        do {
            userMessage = try provider.userMessage(id: UUID(), text: submission.prompt(), attachments: [])
        } catch {
            return .failure(error.localizedDescription)
        }
        conversations[index].messages.append(userMessage)
        conversations[index].updatedAt = Date()
        intelligentUIHost.recordReceipt(submission, userMessageID: userMessage.id)
        persist(conversations[index])
        let writer = persistence
        await writer?.value
        guard !unsavedConversationIDs.contains(conversationID),
              let durableIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[durableIndex].messages.contains(where: { $0.id == userMessage.id }) else {
            return .failure("任务卡选择未能保存，请重试。")
        }
        refreshIntelligentUIReceipts(for: conversationID)
        guard let request = try? requestConfiguration(conversationID: conversationID),
              !generatingConversationIDs.contains(conversationID),
              !mutatingBranchConversationIDs.contains(conversationID),
              !scheduledRunConversationIDs.contains(conversationID),
              settings.intelligentUIEnabled else {
            return .saved
        }
        startGeneration(conversationID: conversationID, configuration: request.0, apiKey: request.1)
        return .started
    }
}
