import AppIntents
import Foundation

private enum AgentActivityControlIntentError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(
            localized: "当前任务已结束或暂时无法处理，请打开 Amber 查看。",
            table: "AppIntents"
        )
    }
}

struct IOSCancelAgentRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "取消任务"
    static let description = IntentDescription("取消这条 Amber 运行。")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "运行 ID")
    var runId: String

    @Parameter(title: "对话 ID")
    var conversationId: String

    init() {
        runId = ""
        conversationId = ""
    }

    init(runId: String, conversationId: String) {
        self.runId = runId
        self.conversationId = conversationId
    }

    func perform() async throws -> some IntentResult {
        #if !ACTIVITY_WIDGET_EXTENSION
        guard await AgentActivityControlCenter.shared.cancel(
            runId: runId,
            conversationId: conversationId
        ) else {
            throw AgentActivityControlIntentError.unavailable
        }
        #endif
        return .result()
    }
}

struct IOSRetryAgentRunIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "重试"
    static let description = IntentDescription("重试这条失败的 Amber 运行。")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "运行 ID")
    var runId: String

    @Parameter(title: "对话 ID")
    var conversationId: String

    init() {
        runId = ""
        conversationId = ""
    }

    init(runId: String, conversationId: String) {
        self.runId = runId
        self.conversationId = conversationId
    }

    func perform() async throws -> some IntentResult {
        #if !ACTIVITY_WIDGET_EXTENSION
        guard await AgentActivityControlCenter.shared.retry(
            runId: runId,
            conversationId: conversationId
        ) else {
            throw AgentActivityControlIntentError.unavailable
        }
        #endif
        return .result()
    }
}
