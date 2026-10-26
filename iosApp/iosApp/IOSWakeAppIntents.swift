import AppIntents
import Foundation

struct IOSWakeTaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Amber 续跑任务", table: "AppIntents")
    )
    static let defaultQuery = IOSWakeTaskEntityQuery()

    let id: String
    let title: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    init(task: IOSWakeTask) {
        id = task.id
        title = task.title
        let trigger = task.fireAt?.formatted(date: .abbreviated, time: .shortened) ?? task.event ?? ""
        detail = [Self.statusTitle(task.status), trigger].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func statusTitle(_ status: IOSWakeTask.Status) -> String {
        switch status {
        case .scheduled: String(localized: "等待触发", table: "AppIntents")
        case .running: String(localized: "执行中", table: "AppIntents")
        case .completed: String(localized: "已完成", table: "AppIntents")
        case .failed: String(localized: "执行失败", table: "AppIntents")
        case .cancelled: String(localized: "已取消", table: "AppIntents")
        case .interrupted: String(localized: "等待重试", table: "AppIntents")
        }
    }
}

struct IOSWakeTaskEntityQuery: EntityQuery {
    func entities(for identifiers: [IOSWakeTaskEntity.ID]) async throws -> [IOSWakeTaskEntity] {
        let wanted = Set(identifiers)
        return await MainActor.run {
            IOSWakeScheduler.shared.store.tasks.filter { wanted.contains($0.id) }.map(IOSWakeTaskEntity.init)
        }
    }

    func suggestedEntities() async throws -> [IOSWakeTaskEntity] {
        await MainActor.run {
            IOSWakeIntentResolver.pendingTasks(IOSWakeScheduler.shared.store.tasks).map(IOSWakeTaskEntity.init)
        }
    }
}

struct IOSRunDueWakeTasksIntent: AppIntent {
    static let title = LocalizedStringResource("执行 Amber 到期任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "在后台检查并执行已到期的 Amber 任务，结果写回各自原对话。需要前台的任务会继续等待。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await IOSWakeScheduler.shared.runDueTasks().summary)
    }
}

struct IOSSignalWakeEventIntent: AppIntent {
    static let title = LocalizedStringResource("发送 Amber 自动化事件", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "从快捷指令向 Amber 发送命名事件和可选资料，触发等待同名事件的任务。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("事件名", table: "AppIntents"))
    var event: String

    @Parameter(title: LocalizedStringResource("事件资料", table: "AppIntents"))
    var content: String?

    static var parameterSummary: some ParameterSummary {
        Summary("发送事件 \(\.$event)") { \.$content }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let event = try IOSWakeIntentResolver.validatedEvent(event)
        let content = try IOSWakeIntentResolver.validatedEventContent(content)
        return .result(value: await IOSWakeScheduler.shared.runDueTasks(event: event, content: content).summary)
    }
}

struct IOSOpenAndRunDueWakeTasksIntent: IOSAmberNavigationIntent {
    static let title = LocalizedStringResource("打开 Amber 并执行到期任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "打开 Amber，检查到期任务，并在原对话中继续执行。", table: "AppIntents"
    ))

    func perform() async throws -> some IntentResult & OpensIntent {
        try open(.wakeDueTasks)
    }
}

struct IOSScheduleWakeTaskIntent: AppIntent {
    static let title = LocalizedStringResource("安排 Amber 稍后任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "为已有对话安排稍后执行的工作。系统后台调度不保证准点；也可用快捷指令自动化触发到期任务。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("任务标题", table: "AppIntents"))
    var taskTitle: String

    @Parameter(title: LocalizedStringResource("要做的工作", table: "AppIntents"))
    var prompt: String

    @Parameter(title: LocalizedStringResource("最早执行时间", table: "AppIntents"))
    var date: Date

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity?

    @Parameter(title: LocalizedStringResource("需要前台执行", table: "AppIntents"), default: false)
    var requiresForeground: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("在 \(\.$date) 安排 \(\.$taskTitle)") {
            \.$prompt
            \.$conversation
            \.$requiresForeground
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IOSWakeTaskEntity> {
        let task = try await IOSConversationAutomationResolver.schedule(
            title: taskTitle, prompt: prompt, conversationID: conversation?.id,
            fireAt: date, requiresForeground: requiresForeground
        )
        return .result(value: IOSWakeTaskEntity(task: task))
    }
}

struct IOSScheduleEventWakeTaskIntent: AppIntent {
    static let title = LocalizedStringResource("安排 Amber 事件任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "保存等待命名事件的任务。由快捷指令或其他入口发送同名事件时，再继续原对话。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("任务标题", table: "AppIntents"))
    var taskTitle: String

    @Parameter(title: LocalizedStringResource("要做的工作", table: "AppIntents"))
    var prompt: String

    @Parameter(title: LocalizedStringResource("事件名", table: "AppIntents"))
    var event: String

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity?

    @Parameter(title: LocalizedStringResource("需要前台执行", table: "AppIntents"), default: false)
    var requiresForeground: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("等待事件 \(\.$event) 后执行 \(\.$taskTitle)") {
            \.$prompt
            \.$conversation
            \.$requiresForeground
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IOSWakeTaskEntity> {
        let task = try await IOSConversationAutomationResolver.schedule(
            title: taskTitle, prompt: prompt, conversationID: conversation?.id,
            event: IOSWakeIntentResolver.validatedEvent(event), requiresForeground: requiresForeground
        )
        return .result(value: IOSWakeTaskEntity(task: task))
    }
}

struct IOSListWakeTasksIntent: AppIntent {
    static let title = LocalizedStringResource("列出 Amber 待续跑任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "返回尚未完成的任务列表，可继续连接执行或取消任务动作。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("对话", table: "AppIntents"))
    var conversation: IOSConversationEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IOSWakeTaskEntity]> & ProvidesDialog {
        if let conversation {
            _ = try await IOSConversationAutomationResolver.conversation(id: conversation.id)
        }
        let tasks = IOSWakeScheduler.shared.store.tasks.filter { task in
            guard let conversation else { return true }
            return task.conversationID.caseInsensitiveCompare(conversation.id) == .orderedSame
        }
        let entities = IOSWakeIntentResolver.pendingTasks(tasks).map(IOSWakeTaskEntity.init)
        return .result(
            value: entities,
            dialog: IntentDialog(LocalizedStringResource("有 \(entities.count) 项待续跑任务。", table: "AppIntents"))
        )
    }
}

struct IOSCancelWakeTaskIntent: AppIntent {
    static let title = LocalizedStringResource("取消 Amber 续跑任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "取消指定的续跑任务，保留原对话。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("续跑任务", table: "AppIntents"))
    var task: IOSWakeTaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let current = try await IOSWakeScheduler.shared.cancel(id: task.id)
        let message = current.status == .cancelled
            ? String(localized: "已取消任务：\(task.title)", table: "AppIntents")
            : "\(current.title)：\(current.status.title)"
        return .result(value: message)
    }
}

struct IOSRunWakeTaskIntent: AppIntent {
    static let title = LocalizedStringResource("立即执行 Amber 续跑任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "执行选定任务，或重试失败、中断的任务。已完成或取消的任务不会重复执行。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("续跑任务", table: "AppIntents"))
    var task: IOSWakeTaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await IOSWakeScheduler.shared.runTask(id: task.id).summary)
    }
}

struct IOSReadWakeTaskResultIntent: AppIntent {
    static let title = LocalizedStringResource("读取 Amber 续跑任务结果", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "读取指定续跑任务实际完成后保存的文字结果。任务尚未完成时明确报错，不读取原对话中的旧回答。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("续跑任务", table: "AppIntents"))
    var task: IOSWakeTaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try IOSWakeTaskResultResolver.result(task: IOSWakeTaskResultResolver.task(id: task.id)))
    }
}

struct IOSWaitForWakeTaskIntent: AppIntent {
    static let title = LocalizedStringResource("等待 Amber 续跑任务", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource(
        "最多等待 25 秒，返回这项任务的最新状态。不启动新请求；超时后仍可继续等待，完成后再读取任务结果。", table: "AppIntents"
    ))
    static let supportedModes: IntentModes = .background

    @Parameter(title: LocalizedStringResource("续跑任务", table: "AppIntents"))
    var task: IOSWakeTaskEntity

    @Parameter(title: LocalizedStringResource("最长等待秒数", table: "AppIntents"), default: 20, inclusiveRange: (1, 25))
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("等待任务 \(\.$task)，最多 \(\.$timeoutSeconds) 秒")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IOSWakeTaskEntity> {
        let current = try await IOSWakeTaskResultResolver.wait(timeoutSeconds: timeoutSeconds) {
            try IOSWakeTaskResultResolver.task(id: task.id)
        }
        return .result(value: IOSWakeTaskEntity(task: current))
    }
}

@MainActor
enum IOSWakeTaskResultResolver {
    static func task(id: String, store: IOSWakeTaskStore = .shared) throws -> IOSWakeTask? {
        if let error = store.loadError { throw IOSWakeError.unreadable(error) }
        return store.task(id: id)
    }

    static func result(task: IOSWakeTask?) throws -> String {
        guard let task else { throw IOSWakeTaskResultError.missingTask }
        guard task.status == .completed else {
            throw IOSWakeTaskResultError.notCompleted(
                status: IOSWakeTaskEntity.statusTitle(task.status), message: task.lastMessage
            )
        }
        guard let text = task.resultText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IOSWakeTaskResultError.missingResult
        }
        return text
    }

    static func wait(
        timeoutSeconds: Int, lookup: @MainActor () throws -> IOSWakeTask?
    ) async throws -> IOSWakeTask {
        guard (1...25).contains(timeoutSeconds) else { throw IOSWakeTaskResultError.invalidTimeout }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while true {
            try Task.checkCancellation()
            guard let task = try lookup() else { throw IOSWakeTaskResultError.missingTask }
            if [.completed, .failed, .cancelled, .interrupted].contains(task.status) || clock.now >= deadline {
                return task
            }
            try await clock.sleep(for: min(.milliseconds(250), clock.now.duration(to: deadline)))
        }
    }
}

enum IOSWakeTaskResultError: LocalizedError {
    case missingTask
    case missingResult
    case invalidTimeout
    case notCompleted(status: String, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingTask:
            String(localized: "找不到这项续跑任务，请重新选择。", table: "AppIntents")
        case .missingResult:
            String(localized: "这项任务已完成，但没有保存可读取的文字结果。请打开原对话查看。", table: "AppIntents")
        case .invalidTimeout:
            String(localized: "等待时间须为 1–25 秒。", table: "AppIntents")
        case .notCompleted(let status, let message):
            [String(localized: "任务当前状态：\(status)。只有完成后才能读取本次结果。", table: "AppIntents"), message]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }
}

enum IOSWakeIntentResolver {
    static func validatedTaskPrompt(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IOSAppIntentError.emptyPrompt }
        guard trimmed.count <= 8_000 else { throw IOSAppIntentError.taskPromptTooLong }
        return trimmed
    }

    static func pendingTasks(_ tasks: [IOSWakeTask]) -> [IOSWakeTask] {
        tasks.filter { $0.status != .completed && $0.status != .cancelled }
    }

    static func validatedEvent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw IOSAppIntentError.invalidEvent }
        return trimmed
    }

    static func validatedEventContent(_ value: String?) throws -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.count <= 8_000 else { throw IOSAppIntentError.eventContentTooLong }
        return trimmed
    }
}
