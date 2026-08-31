import AppIntents
import Foundation

protocol IOSAmberNavigationIntent: AppIntent {}

extension IOSAmberNavigationIntent {
    static var supportedModes: IntentModes { [.foreground(.immediate)] }

    func open(_ destination: IOSAppDeepLink.Destination) throws -> some IntentResult & OpensIntent {
        guard let url = IOSAppDeepLink.url(for: destination) else {
            throw IOSAppIntentError.invalidDestination
        }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

struct IOSNewConversationIntent: IOSAmberNavigationIntent {
    static let title: LocalizedStringResource = "新建 Amber 对话"
    static let description = IntentDescription("打开 Amber 并开始一段新对话。")

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.newConversation)
    }
}

struct IOSResumeLatestConversationIntent: IOSAmberNavigationIntent {
    static let title: LocalizedStringResource = "继续 Amber 对话"
    static let description = IntentDescription("打开 Amber 最近更新的对话。")

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.latestConversation)
    }
}

struct IOSOpenActiveTaskIntent: IOSAmberNavigationIntent {
    static let title: LocalizedStringResource = "打开 Amber 当前任务"
    static let description = IntentDescription("打开 Amber 当前正在运行或最近更新的任务。")

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.activeTask)
    }
}

struct IOSAmberAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IOSNewConversationIntent(),
            phrases: ["用 \(.applicationName) 新建对话", "在 \(.applicationName) 开始对话"],
            shortTitle: "新建对话",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: IOSResumeLatestConversationIntent(),
            phrases: ["继续 \(.applicationName) 对话", "打开 \(.applicationName) 最近对话"],
            shortTitle: "继续对话",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: IOSOpenActiveTaskIntent(),
            phrases: ["打开 \(.applicationName) 当前任务", "查看 \(.applicationName) 任务"],
            shortTitle: "当前任务",
            systemImageName: "bolt.horizontal.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

private enum IOSAppIntentError: LocalizedError {
    case invalidDestination

    var errorDescription: String? { "无法生成 Amber 导航地址。" }
}
