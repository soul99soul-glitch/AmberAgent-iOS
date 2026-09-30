import ActivityKit
import Foundation

struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var presentation: AgentActivityPresentation
        var updatedAt: Date
        /// 已解析的 App 语言代码。可选以兼容已有 ActivityKit 状态。
        var languageCode: String? = nil
    }

    let runId: String
    let conversationId: String?
    let startedAt: Date
    /// 会话标题，展开态主标题用。锁屏/灵动岛是系统共享表面，只放用户自己
    /// 创建的标题，不放模型名或提示词。
    let conversationTitle: String?
}

struct AgentActivityPresentation: Codable, Hashable, Sendable {
    var kind: AgentActivityKind
    var phase: AgentActivityPhase
    var stage: AgentActivityStage
    var metric: AgentActivityMetric
    var action: AgentActivityAction?
    /// `true` only after the matching durable run was committed as failed.
    /// `nil` keeps previously encoded ActivityKit states decodable and fail-closed.
    var retryable: Bool?
    /// 当前一步之前做完的步骤（最多保留两步）。
    /// 以下字段均可选，旧 ActivityKit 状态仍能解码。
    var recentSteps: [AgentActivityStep]?
    /// 当前一步的对象（搜索词、网站域名、文件名），取自工具参数并截短。
    /// 只在灵动岛展开态显示，锁屏只显示类别。
    var stepDetail: String?
    var failureReason: AgentActivityFailureReason?
    /// 待确认的审批请求。只有带请求 id 时岛上才出现「拒绝 / 允许一次」。
    var approval: AgentActivityApproval?

    init(
        kind: AgentActivityKind,
        phase: AgentActivityPhase,
        stage: AgentActivityStage,
        metric: AgentActivityMetric = .none,
        action: AgentActivityAction? = .openTask,
        retryable: Bool? = nil,
        approval: AgentActivityApproval? = nil
    ) {
        self.kind = kind
        self.phase = phase
        self.stage = stage
        self.metric = metric.validated
        self.action = action
        self.retryable = retryable
        self.approval = approval
    }
}

struct AgentActivityStep: Codable, Hashable, Sendable {
    var stage: AgentActivityStage
    var detail: String?
    /// 连续同类步骤合并后的次数，例如「读 3 个网页」。
    var count: Int

    init(stage: AgentActivityStage, detail: String? = nil, count: Int = 1) {
        self.stage = stage
        self.detail = detail
        self.count = count
    }
}

/// 步骤对象只从工具参数里取，不额外调用模型；截短以控制 ActivityKit 负载大小。
enum AgentActivityStepDetailPolicy {
    static let maxLength = 24
    static let detailedStages: [AgentActivityStage] = [.searching, .readingWeb, .readingDocument]
    static let countableStages: [AgentActivityStage] = [.searching, .readingWeb, .readingDocument, .generatingImage]
    /// 写入类工具不是"读"，也不取对象；其参数带整段文件内容，不在主线程解析。
    /// 须与 `IOSWorkspaceToolCatalog.writeToolNames` 一致（有测试守护）。
    static let writeToolNames: Set<String> = [
        "workspace_file_write", "workspace_artifact_delete", "workspace_file_edit", "workspace_file_move",
    ]
    /// 搜索词、网址、文件名的参数都很短；超长输入直接跳过，不做 JSON 解析。
    static let maxParsedInputBytes = 4_096

    static func detail(stage: AgentActivityStage, input: String?) -> String? {
        guard detailedStages.contains(stage),
              let input, input.utf8.count <= maxParsedInputBytes,
              let data = input.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func firstString(_ keys: [String]) -> String? {
            keys.lazy
                .compactMap { (object[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        let raw: String?
        switch stage {
        case .searching:
            raw = firstString(["query"])
        case .readingWeb:
            raw = firstString(["url", "link", "uri"]).map { value in
                guard let host = URL(string: value)?.host() else { return value }
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        case .readingDocument:
            raw = firstString(["path", "file_path", "filename"]).map { ($0 as NSString).lastPathComponent }
        default:
            raw = nil
        }
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > maxLength ? String(collapsed.prefix(maxLength - 1)) + "…" : collapsed
    }
}

struct AgentActivityApproval: Codable, Hashable, Sendable {
    let requestId: String
    /// 操作标题（如终端命令名）。仅在灵动岛展开态显示，锁屏只显示类别。
    let title: String
}

enum AgentActivityFailureReason: String, Codable, Hashable, Sendable {
    case network
    case quota
    case tool
}

enum AgentActivityKind: String, Codable, Hashable, Sendable {
    case research
    case response
    case imageGeneration
    case document
    case web
    case memory
    case command
    case workflow
}

enum AgentActivityPhase: String, Codable, Hashable, Sendable {
    case running
    case reconnecting
    case waitingForUser
    case stale
    case completed
    case failed
    case cancelled
}

public enum AgentActivityStage: String, Codable, Hashable, Sendable {
    case preparing
    case thinking
    case searching
    case readingSources
    case readingWeb
    case generating
    case generatingImage
    case organizing
    case readingDocument
    case updatingMemory
    case runningTool
    case waitingForConfirmation
    case reconnecting
    case stale
    case completed
    case failed
    case cancelled
}

enum AgentActivityMetricUnit: String, Codable, Hashable, Sendable {
    case source
    case file
    case image
    case item
}

enum AgentActivityMetric: Codable, Hashable, Sendable {
    case none
    case count(completed: Int, unit: AgentActivityMetricUnit)
    case progress(completed: Int, total: Int, unit: AgentActivityMetricUnit)

    static func validatedProgress(
        completed: Int,
        total: Int,
        unit: AgentActivityMetricUnit
    ) -> AgentActivityMetric {
        guard total > 0, completed >= 0, completed <= total else { return .none }
        return .progress(completed: completed, total: total, unit: unit)
    }

    var validated: AgentActivityMetric {
        switch self {
        case .none:
            .none
        case let .count(completed, unit):
            completed >= 0 ? .count(completed: completed, unit: unit) : .none
        case let .progress(completed, total, unit):
            Self.validatedProgress(completed: completed, total: total, unit: unit)
        }
    }
}

enum AgentActivityAction: String, Codable, Hashable, Sendable {
    case openTask
    case openConfirmation
    case viewResult
}

enum AgentActivityInlineControl: Equatable {
    case deny
    case approve
    case retry
}

enum AgentActivityInlineControlPolicy {
    static func controls(
        presentation: AgentActivityPresentation,
        isStale: Bool,
        hasConversation: Bool
    ) -> [AgentActivityInlineControl] {
        // 轻点整个岛/卡片即回到对话，按钮只留给确认和重试。
        guard hasConversation else { return [] }
        switch presentation.displayPhase(isStale: isStale) {
        case .waitingForUser:
            return presentation.approval == nil ? [] : [.deny, .approve]
        case .failed:
            return presentation.retryable == true ? [.retry] : []
        case .running, .reconnecting, .stale, .completed, .cancelled:
            return []
        }
    }
}

struct AgentActivityDurableRunIdentity: Equatable, Sendable {
    let runId: String
    let conversationId: String
    let status: String
}

enum AgentActivityRetryOwnershipPolicy {
    static func allows(
        sourceRunId: String,
        conversationId: String,
        latestRun: AgentActivityDurableRunIdentity?
    ) -> Bool {
        guard let latestRun else { return false }
        return latestRun.runId == sourceRunId
            && latestRun.conversationId.caseInsensitiveCompare(conversationId) == .orderedSame
            && latestRun.status == "failed"
    }
}

enum AgentActivityDeepLink {
    enum Focus: String, Codable, Hashable {
        case task
        case confirmation
        case result
    }

    struct Target: Equatable {
        let runId: String
        let conversationId: String
        let focus: Focus
    }

    static var scheme: String {
        scheme(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func scheme(forBundleIdentifier bundleIdentifier: String?) -> String {
        let bundleIdentifier = bundleIdentifier ?? ""
        return bundleIdentifier.contains(".experimental-gpl")
            ? "amber-experimental"
            : "amber"
    }

    static func makeURL(
        runId: String,
        conversationId: String,
        focus: Focus
    ) -> URL? {
        guard isValid(runId, maxLength: 128),
              isValid(conversationId, maxLength: 64) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "activity"
        components.path = "/\(runId)"
        components.queryItems = [
            URLQueryItem(name: "conversation", value: conversationId),
            URLQueryItem(name: "focus", value: focus.rawValue)
        ]
        return components.url
    }

    static func parse(_ url: URL) -> Target? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == "activity" else { return nil }

        let runId = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let queryItems = components.queryItems ?? []
        guard components.path == "/\(runId)",
              queryItems.count == 2,
              queryItems.filter({ $0.name == "conversation" }).count == 1,
              queryItems.filter({ $0.name == "focus" }).count == 1,
              let conversationId = queryItems.first(where: { $0.name == "conversation" })?.value,
              let focusValue = queryItems.first(where: { $0.name == "focus" })?.value,
              isValid(runId, maxLength: 128),
              isValid(conversationId, maxLength: 64),
              let focus = Focus(rawValue: focusValue) else { return nil }

        return Target(
            runId: runId,
            conversationId: conversationId,
            focus: focus
        )
    }

    private static func isValid(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

extension AgentActivityPresentation {
    static let defaultRunning = AgentActivityPresentation(
        kind: .research,
        phase: .running,
        stage: .readingSources
    )

    static func generatingResponse(modelName _: String) -> AgentActivityPresentation {
        response(stage: .generating)
    }

    static func response(stage: AgentActivityStage) -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: .response,
            phase: .running,
            stage: stage
        )
    }

    static func runningTool(toolName: String, input: String?) -> AgentActivityPresentation {
        var presentation = runningTool(toolName: toolName)
        presentation.stepDetail = AgentActivityStepDetailPolicy.detail(stage: presentation.stage, input: input)
        return presentation
    }

    static func runningTool(toolName: String) -> AgentActivityPresentation {
        if AgentActivityStepDetailPolicy.writeToolNames.contains(toolName) {
            return AgentActivityPresentation(
                kind: .document,
                phase: .running,
                stage: .runningTool
            )
        }
        if toolName.hasPrefix("wm_") {
            return AgentActivityPresentation(
                kind: .web,
                phase: .running,
                stage: .readingWeb
            )
        }

        switch toolName {
        case "search_web":
            return AgentActivityPresentation(
                kind: .research,
                phase: .running,
                stage: .searching
            )
        case "scrape_web":
            return AgentActivityPresentation(
                kind: .web,
                phase: .running,
                stage: .readingWeb
            )
        case "generate_image":
            return AgentActivityPresentation(
                kind: .imageGeneration,
                phase: .running,
                stage: .generatingImage
            )
        case "memory_tool":
            return AgentActivityPresentation(
                kind: .memory,
                phase: .running,
                stage: .updatingMemory
            )
        default:
            if toolName.hasPrefix("workspace_") ||
                toolName.contains("file") ||
                toolName.contains("workspace") {
                return AgentActivityPresentation(
                    kind: .document,
                    phase: .running,
                    stage: .readingDocument
                )
            } else {
                return AgentActivityPresentation(
                    kind: .workflow,
                    phase: .running,
                    stage: .runningTool
                )
            }
        }
    }

    static func waitingForUser(
        kind: AgentActivityKind = .command,
        approval: AgentActivityApproval? = nil
    ) -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: kind,
            phase: .waitingForUser,
            stage: .waitingForConfirmation,
            action: .openConfirmation,
            approval: approval
        )
    }

    static var readingSelectedFile: AgentActivityPresentation {
        AgentActivityPresentation(
            kind: .document,
            phase: .running,
            stage: .readingDocument
        )
    }

    static var selectedFileReadCompleted: AgentActivityPresentation {
        completed(toolTitle: "文档读取")
    }

    static var selectedFileReadFailed: AgentActivityPresentation {
        failed(toolTitle: "文档读取")
    }

    static func completed(toolTitle: String = "生成回复") -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: kind(forPublicToolTitle: toolTitle),
            phase: .completed,
            stage: .completed,
            action: .viewResult
        )
    }

    static func failed(
        toolTitle: String = "生成回复",
        retryable: Bool = false
    ) -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: kind(forPublicToolTitle: toolTitle),
            phase: .failed,
            stage: .failed,
            action: .openTask,
            retryable: retryable
        )
    }

    static func cancelled(toolTitle: String = "生成回复") -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: kind(forPublicToolTitle: toolTitle),
            phase: .cancelled,
            stage: .cancelled,
            action: nil
        )
    }

    static func measurablePreview(
        kind: AgentActivityKind,
        completed: Int,
        total: Int,
        unit: AgentActivityMetricUnit
    ) -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: kind,
            phase: .running,
            stage: .organizing,
            metric: .validatedProgress(
                completed: completed,
                total: total,
                unit: unit
            )
        )
    }

    static func reconnecting(
        kind: AgentActivityKind = .workflow
    ) -> AgentActivityPresentation {
        AgentActivityPresentation(
            kind: kind,
            phase: .reconnecting,
            stage: .reconnecting
        )
    }

    func preservingKind(from previous: AgentActivityPresentation?) -> AgentActivityPresentation {
        guard phase == .completed || phase == .failed || phase == .cancelled,
              let previous else { return self }
        var presentation = self
        presentation.kind = previous.kind
        return presentation
    }

    var progressFraction: Double? {
        guard case let .progress(completed, total, _) = metric, total > 0 else {
            return nil
        }
        return Double(completed) / Double(total)
    }

    var percentValue: Int? {
        progressFraction.map { Int(($0 * 100).rounded()) }
    }

    var showsProgressRing: Bool {
        phase == .running && progressFraction != nil
    }

    func displayPhase(isStale: Bool) -> AgentActivityPhase {
        if isStale, phase == .running || phase == .reconnecting {
            return .stale
        }
        return phase
    }

    /// 失联时保留最后一步动作文案，由 displayPhase 表达"后台暂停"。
    func displayStage(isStale: Bool) -> AgentActivityStage {
        stage
    }

    private static func kind(forPublicToolTitle title: String) -> AgentActivityKind {
        switch title {
        case "网页搜索":
            .research
        case "网页读取", "WebMount":
            .web
        case "图片生成":
            .imageGeneration
        case "记忆更新":
            .memory
        case "文档读取", "Workspace":
            .document
        case "终端命令":
            .command
        case "生成回复":
            .response
        default:
            .workflow
        }
    }
}

/// 灵动岛步骤行的历史：运行中工具步骤或对象切换时，把上一步记为"做完"，只保留最近两步。
/// 思考、生成只作为当前一步显示，不进历史，否则每轮工具之间都会插入一次"已思考"。
/// 连续同类步骤（中间隔着思考也算连续）合并计数；对象不同时不保留单个名字，改显示数量。
enum AgentActivityStepHistoryPolicy {
    static let maxFinishedSteps = 2

    static func history(
        after previous: AgentActivityPresentation?,
        current: [AgentActivityStep],
        next: AgentActivityPresentation
    ) -> [AgentActivityStep] {
        // 转入待确认也算上一步做完，否则批准后的完成卡片里会少掉审批前那一步。
        guard let previous,
              previous.phase == .running,
              next.phase == .running || next.phase == .waitingForUser,
              previous.stage != next.stage || previous.stepDetail != next.stepDetail else { return current }
        return appending(previous, to: current)
    }

    /// 任务结束时的历史：结束那一刻正在进行的工具步骤也算做完，完成卡片据此列出做过的事。
    static func closing(last: AgentActivityPresentation?, current: [AgentActivityStep]) -> [AgentActivityStep] {
        guard let last, last.phase == .running else { return current }
        return appending(last, to: current)
    }

    private static func appending(
        _ previous: AgentActivityPresentation,
        to current: [AgentActivityStep]
    ) -> [AgentActivityStep] {
        guard previous.stage.isToolStage else { return current }
        var steps = current
        if let last = steps.last, last.stage == previous.stage {
            steps[steps.count - 1] = AgentActivityStep(
                stage: last.stage,
                detail: last.detail == previous.stepDetail ? last.detail : nil,
                count: last.count + 1
            )
        } else {
            steps.append(AgentActivityStep(stage: previous.stage, detail: previous.stepDetail))
        }
        return Array(steps.suffix(maxFinishedSteps))
    }
}

extension AgentActivityStage {
    /// 由工具执行产生的步骤。只有这类步骤进历史，也只有这类静默步骤需要心跳续期。
    var isToolStage: Bool {
        switch self {
        case .searching, .readingSources, .readingWeb, .generatingImage,
             .readingDocument, .updatingMemory, .runningTool:
            true
        case .preparing, .thinking, .generating, .organizing, .waitingForConfirmation,
             .reconnecting, .stale, .completed, .failed, .cancelled:
            false
        }
    }
}

enum AgentActivityKeylineRole: Equatable {
    case attention
    case failure
}

extension AgentActivityPhase {
    /// 待确认用琥珀金、失败用淡红描边，其余状态保持系统默认。
    var keylineRole: AgentActivityKeylineRole? {
        switch self {
        case .waitingForUser: .attention
        case .failed: .failure
        case .running, .reconnecting, .stale, .completed, .cancelled: nil
        }
    }
}

enum AgentActivityResponseStagePolicy {
    static let initialStage = AgentActivityStage.preparing

    static func updatedStage(
        hasReasoningDelta: Bool,
        hasTextDelta: Bool
    ) -> AgentActivityStage? {
        if hasReasoningDelta { return .thinking }
        if hasTextDelta { return .generating }
        return nil
    }

    static func nextPublishedStage(
        current: AgentActivityStage?,
        candidate: AgentActivityStage
    ) -> AgentActivityStage? {
        guard current != candidate else { return nil }
        if current == .generating, candidate == .thinking { return nil }
        return candidate
    }
}

enum AgentActivityElapsedTimePolicy {
    static func frozenEndDate(
        for phase: AgentActivityPhase,
        updatedAt: Date,
        isStale: Bool = false
    ) -> Date? {
        if isStale { return updatedAt }
        switch phase {
        case .completed, .failed, .cancelled:
            return updatedAt
        case .running, .reconnecting, .waitingForUser, .stale:
            return nil
        }
    }
}

enum AgentActivityCopy {
    static func text(_ key: String, languageCode: String? = nil) -> String {
        let bundle: Bundle
        if let languageCode,
           let localizationPath = Bundle.main.path(
               forResource: languageCode,
               ofType: "lproj"
           ),
           let localizedBundle = Bundle(path: localizationPath) {
            bundle = localizedBundle
        } else {
            // Keep the pre-locale behavior for legacy states and for the base
            // AgentActivity.strings resource, which is not in an lproj folder.
            bundle = .main
        }
        return NSLocalizedString(
            key,
            tableName: "AgentActivity",
            bundle: bundle,
            value: key,
            comment: ""
        )
    }
}

extension AgentActivityKind {
    var title: String {
        localizedTitle(languageCode: nil)
    }

    func localizedTitle(languageCode: String?) -> String {
        AgentActivityCopy.text(
            "agent.activity.kind.\(rawValue)",
            languageCode: languageCode
        )
    }

    var symbolName: String {
        switch self {
        case .research:
            "magnifyingglass"
        case .response:
            "text.bubble"
        case .imageGeneration:
            "photo.on.rectangle"
        case .document:
            "doc.text"
        case .web:
            "globe"
        case .memory:
            "brain.head.profile"
        case .command:
            "terminal"
        case .workflow:
            "sparkles"
        }
    }
}

extension AgentActivityStage {
    var title: String {
        localizedTitle(languageCode: nil)
    }

    func localizedTitle(languageCode: String?) -> String {
        AgentActivityCopy.text(
            "agent.activity.stage.\(rawValue)",
            languageCode: languageCode
        )
    }

    var compactTitle: String {
        localizedCompactTitle(languageCode: nil)
    }

    func localizedCompactTitle(languageCode: String?) -> String {
        AgentActivityCopy.text(
            "agent.activity.compact.\(rawValue)",
            languageCode: languageCode
        )
    }
}

extension AgentActivityAction {
    var title: String {
        localizedTitle(languageCode: nil)
    }

    func localizedTitle(languageCode: String?) -> String {
        AgentActivityCopy.text(
            "agent.activity.action.\(rawValue)",
            languageCode: languageCode
        )
    }

    /// 整张 Live Activity 已通过 widgetURL 打开对话，普通运行态不再重复显示 CTA。
    var showsLockScreenLabel: Bool {
        switch self {
        case .openTask:
            false
        case .openConfirmation, .viewResult:
            true
        }
    }

    var deepLinkFocus: AgentActivityDeepLink.Focus {
        switch self {
        case .openTask:
            .task
        case .openConfirmation:
            .confirmation
        case .viewResult:
            .result
        }
    }
}

extension AgentActivityMetric {
    var shortText: String? {
        localizedShortText(languageCode: nil)
    }

    func localizedShortText(languageCode: String?) -> String? {
        switch validated {
        case .none:
            nil
        case let .count(completed, unit):
            String(
                format: AgentActivityCopy.text(
                    "agent.activity.metric.\(unit.rawValue).count",
                    languageCode: languageCode
                ),
                completed
            )
        case let .progress(completed, total, _):
            "\(Int((Double(completed) / Double(total) * 100).rounded()))%"
        }
    }

    var detailText: String? {
        localizedDetailText(languageCode: nil)
    }

    func localizedDetailText(languageCode: String?) -> String? {
        switch validated {
        case .none:
            nil
        case let .count(completed, unit):
            String(
                format: AgentActivityCopy.text(
                    "agent.activity.metric.\(unit.rawValue).count",
                    languageCode: languageCode
                ),
                completed
            )
        case let .progress(completed, total, unit):
            String(
                format: AgentActivityCopy.text(
                    "agent.activity.metric.\(unit.rawValue).progress",
                    languageCode: languageCode
                ),
                completed,
                total
            )
        }
    }
}

extension AgentActivityPresentation {
    func priorityFact(isStale: Bool) -> String? {
        switch displayPhase(isStale: isStale) {
        case .running:
            metric.shortText
        case .reconnecting:
            AgentActivityCopy.text("agent.activity.fact.reconnecting")
        case .waitingForUser:
            AgentActivityCopy.text("agent.activity.fact.waiting")
        case .stale:
            AgentActivityCopy.text("agent.activity.fact.stale")
        case .completed:
            AgentActivityCopy.text("agent.activity.fact.completed")
        case .failed:
            AgentActivityCopy.text("agent.activity.fact.failed")
        case .cancelled:
            AgentActivityCopy.text("agent.activity.fact.cancelled")
        }
    }

    func displaySymbolName(isStale: Bool) -> String {
        switch displayPhase(isStale: isStale) {
        case .running:
            kind.symbolName
        case .reconnecting:
            "wifi.exclamationmark"
        case .waitingForUser:
            "exclamationmark.circle.fill"
        case .stale:
            "clock.badge.exclamationmark"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .cancelled:
            "stop.circle.fill"
        }
    }

    // DEAD-CODE(待确认删除)：灵动岛最小态已改用 AgentActivityMinimalMark.accessibilityLabel，
    // 此处不再有调用方。
    func accessibilitySummary(isStale: Bool) -> String {
        [kind.title, priorityFact(isStale: isStale) ?? displayStage(isStale: isStale).title]
            .joined(separator: ", ")
    }
}

extension AgentActivityAttributes {
    func destinationURL(for action: AgentActivityAction?) -> URL? {
        guard let conversationId else { return nil }
        return AgentActivityDeepLink.makeURL(
            runId: runId,
            conversationId: conversationId,
            focus: action?.deepLinkFocus ?? .task
        )
    }
}

enum AgentActivityLifecyclePolicy {
    static func shouldRestore(
        runId: String,
        ownedRunIds: Set<String>,
        activityState: ActivityState
    ) -> Bool {
        guard ownedRunIds.contains(runId) else { return false }
        return activityState == .active || activityState == .stale
    }

    /// 同一步骤持续输出时，最迟隔这么久把过期时间往后推一次；须短于运行态的过期时长。
    static let progressRefreshInterval: TimeInterval = 60

    static func staleDate(for phase: AgentActivityPhase, now: Date) -> Date? {
        switch phase {
        case .running:
            now.addingTimeInterval(180)
        case .reconnecting:
            now.addingTimeInterval(60)
        case .waitingForUser, .stale, .completed, .failed, .cancelled:
            nil
        }
    }

    static func relevanceScore(for phase: AgentActivityPhase) -> Double {
        switch phase {
        case .waitingForUser:
            100
        case .reconnecting:
            80
        case .running:
            60
        // Terminal failures should not outrank ongoing work or pin a loud surface.
        case .failed, .stale:
            30
        case .completed:
            20
        case .cancelled:
            0
        }
    }

    /// 结束前在灵动岛上停留展示终态的时长。end 之后系统会立刻把活动撤出灵动岛，
    /// 不停留的话用户在岛上看不到「完成 / 中断」。须短于系统给的后台时间。
    static func islandLingerDuration(for phase: AgentActivityPhase) -> TimeInterval {
        switch phase {
        // 至少 20 秒让人看得到；系统给的后台时间约 30 秒，实际停留还会被剩余后台时间封顶。
        case .completed, .failed:
            25
        case .running, .reconnecting, .waitingForUser, .stale, .cancelled:
            0
        }
    }

    static func lockScreenDismissalDelay(for phase: AgentActivityPhase) -> TimeInterval {
        switch phase {
        // Keep a brief terminal glance, then clear — long hangs feel like a stuck banner.
        case .failed:
            30
        case .stale:
            8
        case .completed:
            12
        case .cancelled:
            4
        case .running, .reconnecting, .waitingForUser:
            0
        }
    }
}
