import AppIntents

/// Siri and Shortcuts entry points. Every intent reuses the app's own draft,
/// note and quick-action paths; nothing here sends to the phone by itself.
struct AskAmberIntent: AppIntent {
    static let title: LocalizedStringResource = "问 Amber"
    static let description = IntentDescription("打开提问页，检查后发送。")
    static let openAppWhenRun = true

    @Parameter(title: "问题")
    var question: String?

    @Dependency private var model: WatchTaskViewModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.startAsk(prefill: question)
        return .result()
    }
}

struct TakeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "随手记"
    static let description = IntentDescription("把一段文字保存为手表记事，稍后同步到 iPhone。")

    @Parameter(title: "内容")
    var text: String

    @Dependency private var model: WatchTaskViewModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2_000 else {
            throw $text.needsValueError(IntentDialog(stringLiteral: model.localized("请输入 1–2000 个字符")))
        }
        if let error = model.saveNote(text: text) { throw WatchIntentError(message: error) }
        return .result(dialog: IntentDialog(stringLiteral: model.localized("已存手表，待同步")))
    }
}

struct WatchIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

struct RunQuickActionIntent: AppIntent {
    static let title: LocalizedStringResource = "快捷动作"
    static let description = IntentDescription("打开 iPhone 设置的快捷动作，确认后发送。")
    static let openAppWhenRun = true

    @Parameter(title: "快捷动作")
    var action: WatchQuickActionEntity

    @Dependency private var model: WatchTaskViewModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.startQuickAction(id: action.id)
        return .result()
    }
}

struct WatchQuickActionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "快捷动作"
    static let defaultQuery = WatchQuickActionQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct WatchQuickActionQuery: EntityQuery {
    @Dependency private var model: WatchTaskViewModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [WatchQuickActionEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [WatchQuickActionEntity] { all }

    @MainActor
    private var all: [WatchQuickActionEntity] {
        (model.library?.quickActions ?? []).map { WatchQuickActionEntity(id: $0.id, title: $0.title) }
    }
}

struct AmberWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAmberIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "问 Amber",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: TakeNoteIntent(),
            phrases: ["Take a note in \(.applicationName)"],
            shortTitle: "随手记",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: RunQuickActionIntent(),
            phrases: ["Run \(\.$action) in \(.applicationName)", "Run a quick action in \(.applicationName)"],
            shortTitle: "快捷动作",
            systemImageName: "bolt.fill"
        )
    }
}
