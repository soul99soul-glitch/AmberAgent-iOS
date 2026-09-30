import AppIntents
import Foundation
#if !ACTIVITY_WIDGET_EXTENSION
import UIKit
#endif

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

struct IOSResolveAgentApprovalIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "处理待确认操作"
    static let description = IntentDescription("允许或拒绝 Amber 当前等待确认的操作。")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "运行 ID")
    var runId: String

    @Parameter(title: "对话 ID")
    var conversationId: String

    @Parameter(title: "请求 ID")
    var requestId: String

    @Parameter(title: "允许")
    var allow: Bool

    init() {
        runId = ""
        conversationId = ""
        requestId = ""
        allow = false
    }

    init(runId: String, conversationId: String, requestId: String, allow: Bool) {
        self.runId = runId
        self.conversationId = conversationId
        self.requestId = requestId
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        #if !ACTIVITY_WIDGET_EXTENSION
        guard await AgentActivityControlCenter.shared.resolveApproval(
            runId: runId,
            conversationId: conversationId,
            requestId: requestId,
            allow: allow
        ) else {
            // 确认已失效：任务已结束，或 App 被系统关闭过、内存里的待确认已丢失。
            // 按钮已经把 App 打开，直接进到这条对话看真实状态，
            // 而不是停在上次的页面、只留一条不一定会显示的错误。
            if let url = AgentActivityDeepLink.makeURL(
                runId: runId,
                conversationId: conversationId,
                focus: .confirmation
            ) {
                await MainActor.run { UIApplication.shared.open(url) }
                return .result()
            }
            throw AgentActivityControlIntentError.unavailable
        }
        #endif
        return .result()
    }
}
