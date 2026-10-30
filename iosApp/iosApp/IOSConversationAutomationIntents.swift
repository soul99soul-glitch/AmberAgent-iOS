import AppIntents
import Foundation
@preconcurrency import Shared

struct IOSReadLatestAnswerIntent: AppIntent {
    static let title = LocalizedStringResource("读取 Amber 最新回答", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "读取指定对话的最新文字回答，供后续快捷指令使用。未指定时读取最近更新的对话。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await IOSConversationAutomationResolver.latestAnswer(conversationID: conversation?.id))
    }
}

struct IOSSendConversationMessageIntent: AppIntent {
    static let title = LocalizedStringResource("向 Amber 对话发送文字", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "在指定对话中启动任务，结果留在该对话，不切换当前页面。未指定时使用最近更新的对话。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("文字", table: "AppIntents"))
    var text: String

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity?

    @Parameter(title: LocalizedStringResource("需要前台执行", table: "AppIntents"), default: false)
    var requiresForeground: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("向 Amber 发送 \(\.$text)") {
            \.$conversation
            \.$requiresForeground
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let prompt = try IOSWakeIntentResolver.validatedTaskPrompt(text)
        let task = try await IOSConversationAutomationResolver.schedule(
            title: String(prompt.prefix(80)), prompt: prompt, conversationID: conversation?.id,
            fireAt: Date(), requiresForeground: requiresForeground
        )
        return .result(value: await IOSWakeScheduler.shared.runTask(id: task.id).summary)
    }
}

struct IOSRunSavedActionInBackgroundIntent: AppIntent {
    static let title = LocalizedStringResource("后台运行 Amber 快捷消息", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "在指定对话中运行已保存的快捷消息，结果写回该对话。需要手机界面操作时请打开 Amber。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("快捷消息", table: "AppIntents"))
    var action: IOSSavedActionEntity

    @Parameter(title: LocalizedStringResource("输入", table: "AppIntents"))
    var input: String?

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let prompt = try await IOSSavedActionIntentResolver.resolve(id: action.id, input: input) {
            try await $input.requestValue(IntentDialog(LocalizedStringResource(
                "这条常用任务需要什么输入？", table: "AppIntents"
            )))
        }
        let task = try await IOSConversationAutomationResolver.schedule(
            title: action.title, prompt: prompt, conversationID: conversation?.id,
            fireAt: Date(), requiresForeground: false
        )
        return .result(value: await IOSWakeScheduler.shared.runTask(id: task.id).summary)
    }
}

@MainActor
enum IOSConversationAutomationResolver {
    static func conversation(
        id: String?, store: IOSConversationStore = IOSConversationStore()
    ) async throws -> ConversationSummary {
        let summaries = await store.appIntentSummaries(limit: nil)
        if let id {
            guard let summary = summaries.first(where: { $0.id.toHexDashString().caseInsensitiveCompare(id) == .orderedSame }) else {
                throw IOSAppIntentError.missingConversation
            }
            return summary
        }
        guard let summary = summaries.first else { throw IOSAppIntentError.missingConversation }
        return summary
    }

    static func latestAnswer(
        conversationID: String?, store: IOSConversationStore = IOSConversationStore()
    ) async throws -> String {
        let summary = try await conversation(id: conversationID, store: store)
        guard let messages = await store.messages(for: summary.id) else { throw IOSAppIntentError.missingConversation }
        guard let answer = latestAnswer(in: messages) else { throw IOSAppIntentError.missingAnswer }
        return answer
    }

    static func latestAnswer(in messages: [UIMessage]) -> String? {
        messages.reversed().lazy.compactMap { message -> String? in
            guard message.role == MessageRole.assistant else { return nil }
            let text = message.parts.compactMap { ($0 as? UIMessagePart.Text)?.text }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.first
    }

    static func schedule(
        title: String, prompt: String, conversationID: String?,
        fireAt: Date? = nil, event: String? = nil, requiresForeground: Bool
    ) async throws -> IOSWakeTask {
        let prompt = try IOSWakeIntentResolver.validatedTaskPrompt(prompt)
        let summary = try await conversation(id: conversationID)
        let requestID = UUID().uuidString
        return try await IOSWakeScheduler.shared.schedule(
            conversationID: summary.id.toHexDashString(), sourceRunID: "shortcuts-\(requestID)",
            origin: IOSWakeOrigin(userMessageID: "shortcuts-\(requestID)", userText: prompt),
            title: title, prompt: prompt, fireAt: fireAt, event: event,
            requiresForeground: requiresForeground, requestID: requestID
        )
    }
}
