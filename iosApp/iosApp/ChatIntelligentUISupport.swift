import Foundation
import Observation
import SwiftUI
@preconcurrency import Shared

struct IOSIntelligentUISubmission: Codable, Equatable, Sendable {
    struct Input: Codable, Equatable, Sendable {
        let id: String
        let label: String
        let value: String
    }
    static let metadataKey = "amber_task_ui_submission"
    let id: String
    let source: IOSIntelligentUISource
    let definitionFingerprint: String
    let draftRevision: Int
    let goal: String
    let question: String
    let option: IOSIntelligentUICardDefinition.Option?
    let inputs: [Input]
    /// Optional fields keep persisted decision receipts from v1 readable.
    let taskKind: String?
    let studySummary: IOSIntelligentUIStudySession.Summary?

    init(source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition,
         draft: IOSIntelligentUIDraft) throws {
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
        id = UUID().uuidString
        self.source = source
        definitionFingerprint = draft.definitionFingerprint
        draftRevision = draft.revision
        goal = definition.goal
        question = definition.question
        self.option = option
        taskKind = definition.kind == "decision" ? nil : definition.kind
        if definition.kind == "study", let study = definition.study {
            let session = try IOSIntelligentUIStudySession.restore(draft.values[IOSIntelligentUIStudySession.storageKey], definition: study)
            studySummary = session.summary(definition: study)
        } else {
            studySummary = nil
        }
        inputs = definition.submissionFields.compactMap { field in
            let value = (draft.values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : Input(id: field.id, label: field.label, value: definition.fieldValueSummary(value, for: field))
        }
    }

    func prompt(request: String? = nil) -> String {
        var lines: [String]
        if let option {
            lines = ["【任务卡选择】", "任务：\(goal)", "待决问题：\(question)",
                     "所选方案：\(option.title)", "方案内容：\(option.summary)"]
            if let tradeoffs = option.tradeoffs, !tradeoffs.isEmpty {
                lines.append("方案取舍：\(tradeoffs.joined(separator: "；"))")
            }
        } else {
            lines = ["【任务卡交互结果】", "任务：\(goal)", "交互类型：\(taskKind ?? "form")"]
            if !question.isEmpty { lines.append("任务问题：\(question)") }
            if let studySummary { lines.append("学习进度：\(studySummary.promptSummary)") }
        }
        for input in inputs { lines.append("\(input.label)：\(input.value)") }
        lines.append("来源：\(source.messageID) / \(source.cardID)")
        let defaultRequest = option != nil ? "基于以上用户选择和补充约束继续当前任务。" : "基于以上用户输入和交互结果继续当前任务。"
        lines.append("请求：\(request ?? defaultRequest)")
        return lines.joined(separator: "\n")
    }

    var metadata: [String: Kotlinx_serialization_jsonJsonElement] {
        get throws {
            let snapshot = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
            return [Self.metadataKey: try Self.jsonString(snapshot)]
        }
    }

    static func jsonString(_ value: String) throws -> Kotlinx_serialization_jsonJsonElement {
        let literal = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return Kotlinx_serialization_jsonJson.companion.parseToJsonElement(string: literal)
    }

    func matches(_ draft: IOSIntelligentUIDraft) -> Bool {
        definitionFingerprint == draft.definitionFingerprint && draftRevision == draft.revision
    }
}

enum IOSIntelligentUISubmitResult: Equatable {
    case started
    case saved
    case failure(String)
}

/// Stable environment identity. Durable receipts are decoded at lifecycle events, not in body.
@MainActor
@Observable
final class IOSIntelligentUIHost {
    let stateStore: IOSIntelligentUIStateStore
    private(set) var receipts: [IOSIntelligentUISource: IOSIntelligentUISubmission] = [:]
    private(set) var pending: Set<IOSIntelligentUISource> = []
    @ObservationIgnored private let action: (IOSIntelligentUISubmission) async -> IOSIntelligentUISubmitResult

    init(stateStore: IOSIntelligentUIStateStore,
         action: @escaping (IOSIntelligentUISubmission) async -> IOSIntelligentUISubmitResult) {
        self.stateStore = stateStore
        self.action = action
    }

    func refreshReceipts(messages: [UIMessage], conversationID: String) {
        var next = receipts.filter { $0.key.conversationID != conversationID }
        for message in messages where message.role == .user {
            for part in message.parts {
                guard let text = part as? UIMessagePart.Text,
                      let raw = IosToolOutputJsonBridge.shared.metadataString(part: text, key: IOSIntelligentUISubmission.metadataKey),
                      let submission = try? JSONDecoder().decode(IOSIntelligentUISubmission.self, from: Data(raw.utf8)),
                      submission.source.conversationID == conversationID else { continue }
                next[submission.source] = submission
            }
        }
        if next != receipts { receipts = next }
    }

    func submit(source: IOSIntelligentUISource, definition: IOSIntelligentUICardDefinition) async -> IOSIntelligentUISubmitResult {
        guard !pending.contains(source) else { return .failure("这张任务卡正在提交。") }
        stateStore.register(source: source, definition: definition)
        let draft = stateStore.draft(for: source, definition: definition)
        guard receipts[source]?.matches(draft) != true else { return .failure("此选择已经提交；修改后可以再提交。") }
        let submission: IOSIntelligentUISubmission
        do { submission = try IOSIntelligentUISubmission(source: source, definition: definition, draft: draft) }
        catch { return .failure(error.localizedDescription) }
        pending.insert(source)
        defer { pending.remove(source) }
        let result = await action(submission)
        switch result {
        case .started, .saved: receipts[source] = submission
        case .failure: break
        }
        return result
    }
}

private struct IntelligentUIHostKey: EnvironmentKey {
    static let defaultValue: IOSIntelligentUIHost? = nil
}
private struct IntelligentUIBusyKey: EnvironmentKey {
    static let defaultValue = false
}
private struct IntelligentUIConversationKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var intelligentUIBusy: Bool {
        get { self[IntelligentUIBusyKey.self] }
        set { self[IntelligentUIBusyKey.self] = newValue }
    }
    var intelligentUIHost: IOSIntelligentUIHost? {
        get { self[IntelligentUIHostKey.self] }
        set { self[IntelligentUIHostKey.self] = newValue }
    }
    var intelligentUIConversationID: String? {
        get { self[IntelligentUIConversationKey.self] }
        set { self[IntelligentUIConversationKey.self] = newValue }
    }
}

enum IOSIntelligentUITerminal {
    static let completedKey = "amber_task_ui_source_terminal"
    static let runIDKey = "amber_task_ui_source_run_id"

    /// The display baseline advances at handoff/checkpoint boundaries. Preserve
    /// the originating run before advancing it, without enabling unfinished cards.
    static func markSourcesPending(_ messages: [UIMessage], baseline: [UIMessage], runID: String) -> [UIMessage] {
        markSources(messages, baseline: baseline, runID: runID, completed: false)
    }

    static func markCompleted(_ messages: [UIMessage], baseline: [UIMessage], runID: String) -> [UIMessage] {
        markSources(messages, baseline: baseline, runID: runID, completed: true)
    }

    private static func markSources(_ messages: [UIMessage], baseline: [UIMessage], runID: String, completed: Bool) -> [UIMessage] {
        let originalIDs = Set(baseline.map { $0.id.toHexDashString() })
        return messages.map { message in
            guard message.role == .assistant else { return message }
            let isNewSource = !originalIDs.contains(message.id.toHexDashString())
            var changed = false
            let parts: [UIMessagePart] = message.parts.map { part in
                guard let text = part as? UIMessagePart.Text,
                      text.text.contains("```task-ui") || text.text.contains("~~~task-ui"),
                      IosToolOutputJsonBridge.shared.metadataString(part: text, key: MessageKt.LOCAL_GENERATION_ERROR_METADATA_KEY) == nil else { return part }
                let existingRunID = IosToolOutputJsonBridge.shared.metadataString(part: text, key: runIDKey)
                let sameRunSource = existingRunID == runID
                guard isNewSource || (completed && sameRunSource) else { return part }
                let alreadyCompleted = IosToolOutputJsonBridge.shared.metadataString(part: text, key: completedKey) == "completed"
                guard !sameRunSource || (completed && !alreadyCompleted) else { return part }
                var updates = [runIDKey: runID]
                if completed { updates[completedKey] = "completed" }
                changed = true
                return IosToolOutputJsonBridge.shared.mergeTextMetadata(part: text, updates: updates)
            }
            guard changed else { return message }
            return UIMessage(id: message.id, role: message.role, parts: parts, annotations: message.annotations,
                             createdAt: message.createdAt, finishedAt: message.finishedAt, modelId: message.modelId,
                             usage: message.usage, translation: message.translation)
        }
    }
}
