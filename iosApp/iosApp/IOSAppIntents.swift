import AppIntents
import Foundation
@preconcurrency import Shared

protocol IOSAmberNavigationIntent: AppIntent {}

extension IOSAmberNavigationIntent {
    static var supportedModes: IntentModes { [.foreground(.immediate)] }

    func open(_ destination: IOSAppDeepLink.Destination) throws -> some IntentResult & OpensIntent {
        guard let url = IOSAppDeepLink.url(for: destination) else {
            throw IOSAppIntentError.invalidDestination
        }
        return .result(opensIntent: OpenURLIntent(url))
    }

    func open(
        _ destination: IOSAppDeepLink.Destination,
        dialog: IntentDialog
    ) throws -> some IntentResult & OpensIntent & ProvidesDialog {
        guard let url = IOSAppDeepLink.url(for: destination) else {
            throw IOSAppIntentError.invalidDestination
        }
        return .result(opensIntent: OpenURLIntent(url), dialog: dialog)
    }

    func openPrompt(
        _ prompt: String,
        dialog: IntentDialog
    ) async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        let destination = await IOSDeepLinkInbox.shared.preparePromptHandoff(prompt)
        guard let destination else { throw IOSAppIntentError.invalidDestination }
        return try open(destination, dialog: dialog)
    }
}

struct IOSAskAmberIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("询问 Amber", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "把问题交给 Amber，并在 App 中继续需要授权的操作。",
        table: "AppIntents"
    ))

    @Parameter(
        title: LocalizedStringResource("问题", table: "AppIntents"),
        requestValueDialog: IntentDialog(LocalizedStringResource("你想问 Amber 什么？", table: "AppIntents"))
    )
    var question: String

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        let prompt = try IOSAppIntentError.validatedPrompt(question)
        return try await openPrompt(
            prompt,
            dialog: IntentDialog(LocalizedStringResource("正在 Amber 中处理。", table: "AppIntents"))
        )
    }
}

struct IOSDailyBriefIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("生成每日简报", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "让 Amber 汇总今天的重要安排与个人状态。",
        table: "AppIntents"
    ))

    static var prompt: String {
        String(
            localized: "生成我的今日简报。按需使用日历、提醒事项、天气和 HealthKit 工具；只读取完成简报所需的数据，涉及授权或敏感操作时先征得我的同意。输出今天最重要的事项、时间冲突、天气提示和一条可执行建议。",
            table: "AppIntents"
        )
    }

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        try await openPrompt(
            Self.prompt,
            dialog: IntentDialog(LocalizedStringResource("正在 Amber 中生成今日简报。", table: "AppIntents"))
        )
    }
}

struct IOSNewConversationIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("新建 Amber 对话", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "打开 Amber 并开始一段新对话。",
        table: "AppIntents"
    ))

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.newConversation)
    }
}

struct IOSResumeLatestConversationIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("继续 Amber 对话", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "打开 Amber 最近更新的对话。",
        table: "AppIntents"
    ))

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.latestConversation)
    }
}

struct IOSOpenActiveTaskIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("打开 Amber 当前任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "打开 Amber 当前正在运行或最近更新的任务。",
        table: "AppIntents"
    ))

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.activeTask)
    }
}

struct IOSConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Amber 对话", table: "AppIntents")
    )
    static let defaultQuery = IOSConversationEntityQuery()

    let id: String
    let title: String
    let messageCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: LocalizedStringResource("\(messageCount) 条消息", table: "AppIntents")
        )
    }

    init(summary: ConversationSummary) {
        id = summary.id.toHexDashString()
        let trimmedTitle = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmedTitle.isEmpty
            ? String(localized: "新对话", table: "AppIntents")
            : trimmedTitle
        messageCount = Int(summary.messageCount)
    }
}

struct IOSConversationEntityQuery: EntityQuery {
    func entities(for identifiers: [IOSConversationEntity.ID]) async throws -> [IOSConversationEntity] {
        let wanted = Set(identifiers)
        return await IOSAppIntentDataSource.conversations(limit: nil).filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [IOSConversationEntity] {
        await IOSAppIntentDataSource.conversations()
    }
}

struct IOSContinueConversationIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("继续指定对话", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "打开一段已有的 Amber 对话。",
        table: "AppIntents"
    ))

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        guard await IOSAppIntentDataSource.conversationExists(id: conversation.id) else {
            throw IOSAppIntentError.missingConversation
        }
        return try open(.conversation(id: conversation.id))
    }
}

struct IOSSavedActionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Amber 快捷消息", table: "AppIntents")
    )
    static let defaultQuery = IOSSavedActionEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String) {
        self.id = id
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle.isEmpty
            ? String(localized: "未命名快捷消息", table: "AppIntents")
            : trimmedTitle
    }
}

struct IOSSavedActionEntityQuery: EntityQuery {
    func entities(for identifiers: [IOSSavedActionEntity.ID]) async throws -> [IOSSavedActionEntity] {
        let wanted = Set(identifiers)
        return await IOSAppIntentDataSource.savedActions().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [IOSSavedActionEntity] {
        let actions = await IOSAppIntentDataSource.savedActions()
        return Array(actions.prefix(20))
    }
}

struct IOSRunSavedActionIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("运行快捷消息", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "运行一条已保存在 Amber 中的快捷消息。",
        table: "AppIntents"
    ))

    @Parameter(title: LocalizedStringResource("快捷消息", table: "AppIntents"))
    var action: IOSSavedActionEntity

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        guard let content = await IOSAppIntentDataSource.savedActionContent(id: action.id) else {
            throw IOSAppIntentError.missingSavedAction
        }
        let prompt = try IOSAppIntentError.validatedPrompt(content)
        return try await openPrompt(
            prompt,
            dialog: IntentDialog(LocalizedStringResource(
                "正在 Amber 中运行“\(action.title)”。",
                table: "AppIntents"
            ))
        )
    }
}

@MainActor
private enum IOSAppIntentDataSource {
    static func conversations(limit: Int? = 20) async -> [IOSConversationEntity] {
        let summaries = await IOSConversationStore().appIntentSummaries(limit: limit)
        return summaries.map(IOSConversationEntity.init)
    }

    static func conversationExists(id: String) async -> Bool {
        await conversations(limit: nil).contains {
            $0.id.caseInsensitiveCompare(id) == .orderedSame
        }
    }

    static func savedActions() -> [IOSSavedActionEntity] {
        IOSSharedSettingsStore().snapshot.quickMessages.map {
            IOSSavedActionEntity(id: $0.id.toHexDashString(), title: $0.title)
        }
    }

    static func savedActionContent(id: String) -> String? {
        IOSSharedSettingsStore().snapshot.quickMessages.first {
            $0.id.toHexDashString().caseInsensitiveCompare(id) == .orderedSame
        }?.content
    }
}

struct IOSAmberAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IOSAskAmberIntent(),
            phrases: ["询问 \(.applicationName)", "让 \(.applicationName) 帮我"],
            shortTitle: LocalizedStringResource("询问 Amber", table: "AppIntents"),
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: IOSDailyBriefIntent(),
            phrases: ["用 \(.applicationName) 生成每日简报", "让 \(.applicationName) 总结今天"],
            shortTitle: LocalizedStringResource("每日简报", table: "AppIntents"),
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: IOSRunSavedActionIntent(),
            phrases: ["运行 \(.applicationName) 快捷消息"],
            shortTitle: LocalizedStringResource("快捷消息", table: "AppIntents"),
            systemImageName: "text.badge.checkmark"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

private enum IOSAppIntentError: LocalizedError {
    case invalidDestination
    case emptyPrompt
    case promptTooLong
    case missingSavedAction
    case missingConversation

    static func validatedPrompt(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSAppIntentError.emptyPrompt }
        guard trimmed.count <= IOSAppDeepLink.maximumPromptLength else {
            throw IOSAppIntentError.promptTooLong
        }
        return trimmed
    }

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            String(localized: "无法生成 Amber 导航地址。", table: "AppIntents")
        case .emptyPrompt:
            String(localized: "问题不能为空。", table: "AppIntents")
        case .promptTooLong:
            String(
                localized: "问题不能超过 \(IOSAppDeepLink.maximumPromptLength) 个字符。",
                table: "AppIntents"
            )
        case .missingSavedAction:
            String(localized: "这条快捷消息已被删除，请重新选择。", table: "AppIntents")
        case .missingConversation:
            String(localized: "这段对话已被删除，请重新选择。", table: "AppIntents")
        }
    }
}
