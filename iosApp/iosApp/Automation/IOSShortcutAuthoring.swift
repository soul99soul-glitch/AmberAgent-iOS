import Foundation
@preconcurrency import Shared

enum IOSShortcutAuthoringToolCatalog {
    static let compose = "shortcut_compose"
    static let toolNames: Set<String> = [compose]
    static let runtimeGuidance = """
    When asked to create or modify an iPhone Shortcut or personal automation, discover shortcut_compose with tool_search. It validates Amber's real actions and produces a workflow for the system editor. If phone control is available and creation is authorized, continue with fresh observations in the Shortcuts app, save the workflow, run an authorized test, verify the task/event/result receipt, then return to Amber and report the evidence. The planning tool alone never installs a Shortcut. On iOS 26, configure personal automation triggers in the actual system UI; do not invent an installation API or present an unsigned .shortcut file as runnable. A background action can return a started/waiting summary; read the answer only after the task actually completes. For a result from this specific execution, keep the task entity returned by IOSScheduleWakeTaskIntent, run that task, pass the same entity to IOSWaitForWakeTaskIntent, then IOSReadWakeTaskResultIntent. The bounded wait may time out with a pending state. Never substitute IOSReadLatestAnswerIntent for this receipt: it may return an earlier answer from the conversation.
    """

    static var declarations: [Tool] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string", "minLength": 1, "maxLength": 200],
                "goal": ["type": "string", "minLength": 1, "maxLength": 4000],
                "actions": ["type": "array", "minItems": 1, "maxItems": 30, "items": [
                    "type": "object", "properties": [
                        "action": [
                            "type": "string", "enum": IOSShortcutAuthoringRegistry.actions.map(\.id),
                            "description": IOSShortcutAuthoringRegistry.actions.map { action in
                                let parameters = action.parameters.map {
                                    "\($0.name):\($0.kind.rawValue)\($0.required ? "" : "?")"
                                }.joined(separator: ", ")
                                return "\(action.id)（\(action.title)）参数：\(parameters.isEmpty ? "无" : parameters)；输出：\(action.output)"
                            }.joined(separator: "\n"),
                        ],
                        "parameters": ["type": "object", "description": "使用 Amber intent 的准确参数名；快捷指令变量用 {{变量名}} 标记，并在系统编辑器中绑定真实变量，不能直接输入占位文字。"],
                    ], "required": ["action", "parameters"], "additionalProperties": false,
                ]],
                "trigger": ["type": "string", "minLength": 1, "maxLength": 2000, "description": "可选个人自动化触发条件说明；实际可用条件和立即运行选项须在这部 iPhone 的快捷指令界面核对。"],
            ],
            "required": ["title", "goal", "actions"], "additionalProperties": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let declaration = IosToolExposureBridgeKt.createDynamicWorkflowToolDeclaration(
            toolId: compose, version: "1",
            description: "编写、创建或修改 iPhone 快捷指令与个人自动化前，校验 Amber 动作及参数并生成真实手机界面的实施步骤。支持定时/事件续跑、读写指定对话、读取回答及快捷消息；action 使用 IOSRunDueWakeTasksIntent 等准确类型标识。快捷指令变量用 {{变量名}}。这是本地规划工具，返回不表示已创建、安装或验证；用户已授权创建时，接着用 phone_apps/phone_add_app/phone_observe/phone_run_goal 在系统快捷指令 App 编写、保存和测试，完成后 phone_return_to_amber 呈现真实回执。公开 create-shortcut URL 仅打开空编辑器，不会导入本工具的 JSON；个人自动化触发器需在系统 UI 配置和验收。不生成未签名 .shortcut 文件、不把工具 JSON 当作可安装产物，不重复索要已有授权。",
            inputsJson: String(decoding: data, as: UTF8.self), effectClass: "pure"
        )
        return [Tool(
            name: declaration.name, description: declaration.description_, parameters: declaration.parameters,
            systemPrompt: declaration.systemPrompt, needsApproval: false, allowsAutoApproval: true,
            mandatoryApproval: false, execute: declaration.execute
        )]
    }
}

struct IOSShortcutAuthoringAction: Sendable {
    struct Parameter: Sendable {
        enum Kind: String, Sendable { case text, date, boolean, integer, entity }
        let name: String
        let title: String
        let kind: Kind
        let required: Bool
        let maximumLength: Int?
        let minimum: Int?
        let maximum: Int?

        init(_ name: String, _ title: String, _ kind: Kind = .text, required: Bool = true, maximumLength: Int? = nil, minimum: Int? = nil, maximum: Int? = nil) {
            self.name = name
            self.title = title
            self.kind = kind
            self.required = required
            self.maximumLength = maximumLength
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    let id: String
    let title: String
    let parameters: [Parameter]
    let output: String

    var json: [String: Any] {
        ["action": id, "name": title, "parameters": parameters.map { parameter in
            var value: [String: Any] = [
                "name": parameter.name, "label": parameter.title,
                "type": parameter.kind.rawValue, "required": parameter.required,
            ]
            if let limit = parameter.maximumLength { value["max_length"] = limit }
            if let minimum = parameter.minimum { value["minimum"] = minimum }
            if let maximum = parameter.maximum { value["maximum"] = maximum }
            return value
        }, "output": output]
    }
}

enum IOSShortcutAuthoringRegistry {
    private typealias Parameter = IOSShortcutAuthoringAction.Parameter
    private static let conversation = Parameter("conversation", "对话", .entity, required: false)
    private static let foreground = Parameter("requiresForeground", "需要前台执行", .boolean, required: false)
    private static let taskTitle = Parameter("taskTitle", "任务标题", maximumLength: 200)
    private static let prompt = Parameter("prompt", "要做的工作", maximumLength: 8000)
    private static let event = Parameter("event", "事件名", maximumLength: 200)
    private static let action = Parameter("action", "快捷消息", .entity)
    private static let input = Parameter("input", "输入", required: false, maximumLength: 8000)
    private static let task = Parameter("task", "续跑任务", .entity)

    static let actions: [IOSShortcutAuthoringAction] = [
        .init(id: "IOSAskAmberIntent", title: "询问 Amber", parameters: [Parameter("question", "问题", maximumLength: 2000)], output: "打开 Amber 并发送问题；不直接输出回答"),
        .init(id: "IOSDailyBriefIntent", title: "生成每日简报", parameters: [], output: "打开 Amber 并开始生成简报"),
        .init(id: "IOSNewConversationIntent", title: "新建 Amber 对话", parameters: [], output: "打开新对话"),
        .init(id: "IOSResumeLatestConversationIntent", title: "继续 Amber 对话", parameters: [], output: "打开最近更新的对话"),
        .init(id: "IOSOpenActiveTaskIntent", title: "打开 Amber 当前任务", parameters: [], output: "打开当前任务"),
        .init(id: "IOSContinueConversationIntent", title: "继续指定对话", parameters: [Parameter("conversation", "对话", .entity)], output: "打开指定对话"),
        .init(id: "IOSRunSavedActionIntent", title: "运行快捷消息", parameters: [action, input], output: "打开 Amber 并运行快捷消息；不直接输出回答"),
        .init(id: "IOSRunDueWakeTasksIntent", title: "执行 Amber 到期任务", parameters: [], output: "执行摘要文字；需要前台的任务可能继续等待"),
        .init(id: "IOSSignalWakeEventIntent", title: "发送 Amber 自动化事件", parameters: [event, Parameter("content", "事件资料", required: false, maximumLength: 8000)], output: "事件处理及任务执行摘要；不代表开始监听外部 App"),
        .init(id: "IOSOpenAndRunDueWakeTasksIntent", title: "打开 Amber 并执行到期任务", parameters: [], output: "打开 Amber 并执行到期任务"),
        .init(id: "IOSScheduleWakeTaskIntent", title: "安排 Amber 稍后任务", parameters: [taskTitle, prompt, Parameter("date", "最早执行时间", .date), conversation, foreground], output: "Amber 续跑任务实体；保存成功不保证准点执行"),
        .init(id: "IOSScheduleEventWakeTaskIntent", title: "安排 Amber 事件任务", parameters: [taskTitle, prompt, event, conversation, foreground], output: "Amber 续跑任务实体；等待同名事件显式上报"),
        .init(id: "IOSListWakeTasksIntent", title: "列出 Amber 待续跑任务", parameters: [conversation], output: "Amber 续跑任务实体列表及数量"),
        .init(id: "IOSCancelWakeTaskIntent", title: "取消 Amber 续跑任务", parameters: [task], output: "取消摘要文字；保留原对话"),
        .init(id: "IOSRunWakeTaskIntent", title: "立即执行 Amber 续跑任务", parameters: [task], output: "执行摘要文字；已完成和取消的任务不重放"),
        .init(id: "IOSWaitForWakeTaskIntent", title: "等待 Amber 续跑任务", parameters: [task, Parameter("timeoutSeconds", "最长等待秒数", .integer, required: false, minimum: 1, maximum: 25)], output: "同一任务的最新实体；默认等 20 秒，最多 25 秒，超时可能仍未完成"),
        .init(id: "IOSReadWakeTaskResultIntent", title: "读取 Amber 续跑任务结果", parameters: [task], output: "该任务实际完成后保存的文字结果；未完成或失败时明确报错，不返回旧对话回答"),
        .init(id: "IOSReadLatestAnswerIntent", title: "读取 Amber 最新回答", parameters: [conversation], output: "最新助手文字回答，可作为后续动作输入"),
        .init(id: "IOSSendConversationMessageIntent", title: "向 Amber 对话发送文字", parameters: [Parameter("text", "文字", maximumLength: 8000), conversation, foreground], output: "执行摘要文字；回答保存在原对话，不作为本动作直接输出"),
        .init(id: "IOSRunSavedActionInBackgroundIntent", title: "后台运行 Amber 快捷消息", parameters: [action, input, conversation], output: "执行摘要文字；回答保存在原对话"),
    ]
}

enum IOSShortcutAuthoringToolExecutor {
    static func execute(input: String) async -> String {
        do {
            let data = Data(input.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AuthoringError.invalid("参数必须是 JSON 对象。")
            }
            try validateKeys(object, allowed: ["title", "goal", "actions", "trigger"], context: "快捷指令")
            let title = try text(object["title"], name: "title", maximum: 200)
            let goal = try text(object["goal"], name: "goal", maximum: 4000)
            let trigger: String? = try object["trigger"].map { try text($0, name: "trigger", maximum: 2000) }
            guard let rawActions = object["actions"] as? [[String: Any]], (1...30).contains(rawActions.count) else {
                throw AuthoringError.invalid("actions 必须包含 1–30 个动作。")
            }
            let actions = try rawActions.enumerated().map { index, raw -> [String: Any] in
                try validateKeys(raw, allowed: ["action", "parameters"], context: "第 \(index + 1) 个动作")
                guard let id = raw["action"] as? String,
                      let definition = IOSShortcutAuthoringRegistry.actions.first(where: { $0.id == id }) else {
                    throw AuthoringError.invalid("第 \(index + 1) 个 action 不是已支持的 Amber 动作；使用 supported_actions 中的准确标识。")
                }
                guard let parameters = raw["parameters"] as? [String: Any] else {
                    throw AuthoringError.invalid("\(id).parameters 必须是对象；无参数时传 {}。")
                }
                try validate(parameters, for: definition)
                var result = definition.json
                result["position"] = index + 1
                result["parameter_guide"] = result["parameters"]
                result["parameters"] = parameters
                return result
            }
            var workflow: [String: Any] = ["title": title, "goal": goal, "actions": actions]
            if let trigger { workflow["trigger"] = trigger }
            return json([
                "ok": true, "tool": IOSShortcutAuthoringToolCatalog.compose, "status": "plan_ready",
                "installed": false, "verified": false, "execution_required": true,
                "workflow": workflow,
                "urls": [
                    "create": try shortcutURL(command: "create-shortcut"),
                    "open": try shortcutURL(command: "open-shortcut", title: title),
                    "run": try shortcutURL(command: "run-shortcut", title: title),
                ],
                "variable_binding": "{{变量名}} 是规划标记。创建时从系统变量选择器绑定对应输入、日期、实体或上一步输出；不能把占位符文本直接填进最终动作。实体参数必须选择实际存在的 Amber 对话、快捷消息或续跑任务，并核对身份。",
                "phone_ui_steps": phoneSteps(hasTrigger: trigger != nil),
                "acceptance": [
                    "保存后重新打开同名快捷指令，核对真实名称、动作顺序、参数和变量绑定；只有看到保存结果，才能报告已创建。",
                    "在用户已授权范围内运行一次并读取真实回执；打开 run URL 只表示请求运行，不能当作业务成功。结果未知时停止核对，禁止重复发送或重放。",
                    "续跑类动作还须核对 Amber 对应任务状态和原对话结果；事件动作须核对实际同名事件及匹配任务，不能把计划或上报摘要当作外部事件监听已经建立。",
                    trigger == nil
                        ? "取得实际运行回执后，才可报告已验证。"
                        : "在自动化界面核对触发器、条件和运行方式，并实际触发一次，核对 Amber 回执；只手动运行快捷指令不能证明自动化触发成功。",
                ],
                "continuation": "本工具只完成规划。用户已授权创建或修改时，继续执行手机 UI 创建、保存及测试，不停在计划，也不再次索要同范围授权；遇到锁屏或实际系统确认时按当前界面交接。",
                "platform_notes": [
                    "create URL 只打开空白快捷指令编辑器，不携带或导入本工作流。",
                    "个人自动化触发器由系统快捷指令界面配置；以设备实际可用选项为准。",
                    "本 JSON 不是可安装的 .shortcut 文件；此工具没有签名、安装或修改系统自动化。",
                ],
                "sources": [
                    "https://support.apple.com/guide/shortcuts/apd84c576f8c/ios",
                    "https://support.apple.com/guide/shortcuts/apda283236d7/ios",
                    "https://support.apple.com/guide/shortcuts/apd624386f42/ios",
                    "https://support.apple.com/guide/shortcuts/apdfbdbd7123/ios",
                ],
            ])
        } catch {
            return json([
                "ok": false, "tool": IOSShortcutAuthoringToolCatalog.compose, "status": "invalid_plan",
                "installed": false, "verified": false,
                "reason": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                "supported_actions": IOSShortcutAuthoringRegistry.actions.map(\.json),
            ])
        }
    }

    static func shortcutURL(command: String, title: String? = nil) throws -> String {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = command
        if let title { components.queryItems = [URLQueryItem(name: "name", value: title)] }
        guard let url = components.url else { throw AuthoringError.invalid("无法生成快捷指令系统地址。") }
        return url.absoluteString
    }

    private static func validate(_ values: [String: Any], for action: IOSShortcutAuthoringAction) throws {
        try validateKeys(values, allowed: Set(action.parameters.map(\.name)), context: action.id)
        for parameter in action.parameters {
            guard let value = values[parameter.name] else {
                if parameter.required { throw AuthoringError.invalid("\(action.id) 缺少必填参数 \(parameter.name)。") }
                continue
            }
            if let value = value as? String, isVariable(value) { continue }
            switch parameter.kind {
            case .text, .entity:
                _ = try text(value, name: "\(action.id).\(parameter.name)", maximum: parameter.maximumLength ?? 8000)
            case .boolean:
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw AuthoringError.invalid("\(action.id).\(parameter.name) 必须是布尔值或 {{变量名}}。")
                }
            case .integer:
                guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
                      parameter.minimum.map({ value.doubleValue >= Double($0) }) ?? true,
                      parameter.maximum.map({ value.doubleValue <= Double($0) }) ?? true else {
                    throw AuthoringError.invalid("\(action.id).\(parameter.name) 必须是范围内的整数或 {{变量名}}；等待秒数须为 1–25。")
                }
            case .date:
                let value = try text(value, name: "\(action.id).\(parameter.name)", maximum: 200)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard formatter.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil else {
                    throw AuthoringError.invalid("\(action.id).\(parameter.name) 请使用带时区的 ISO8601 时间或 {{变量名}}。")
                }
            }
        }
    }

    private static func isVariable(_ value: String) -> Bool {
        guard value.count <= 200, value.hasPrefix("{{"), value.hasSuffix("}}") else { return false }
        let body = value.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty && !body.contains("{") && !body.contains("}")
    }

    private static func validateKeys(_ object: [String: Any], allowed: Set<String>, context: String) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else { throw AuthoringError.invalid("\(context) 不接受参数：\(unknown.joined(separator: ", "))。") }
    }

    private static func text(_ value: Any?, name: String, maximum: Int) throws -> String {
        guard let text = value as? String else { throw AuthoringError.invalid("\(name) 必须是文字。") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum else {
            throw AuthoringError.invalid("\(name) 须为 1–\(maximum) 个字符。")
        }
        return trimmed
    }

    private static func phoneSteps(hasTrigger: Bool) -> [[String: String]] {
        var steps = [
            ["tool": "phone_apps", "instruction": "查询 Shortcuts／快捷指令，取得这部 iPhone 上的准确 Bundle ID；不猜 ID。"],
            ["tool": "phone_add_app", "instruction": "若目标尚未在允许控制列表，使用实际查询到的 Bundle ID 添加当前任务需要的应用范围。"],
            ["tool": "phone_act", "instruction": "以查到的 Bundle ID launch 系统快捷指令 App，再读取新观察；若已有同名快捷指令，核对其身份和用户授权后编辑，不能覆盖无关内容。"],
            ["tool": "phone_observe", "instruction": "从当前界面取得新 ref；树缺少控件时读取截图或屏幕文字。所有后续导航、输入和参数选择都以实际观察为准，不复用切 App 前的 ref，不预编节点或坐标。"],
            ["tool": "phone_run_goal", "instruction": "按 workflow 在实际编辑器逐项添加准确中文名称的 Amber 动作，填写参数并绑定系统变量。动作搜索不到时确认已安装的 Amber 版本及可用动作，不能用相近名称冒充。保存前核对标题、顺序和实体身份。"],
            ["tool": "phone_observe", "instruction": "保存后返回列表并重新打开目标，取得能证明实际保存及参数正确的界面证据。create URL 只能辅助打开空编辑器，不会创建此工作流。"],
        ]
        if hasTrigger {
            steps.append(["tool": "phone_run_goal", "instruction": "在系统个人自动化界面，根据用户授权的 trigger 创建或修改实际触发条件，并选择刚保存的快捷指令或等价动作；核对这台设备可用的立即运行或确认选项。遇到真实系统授权、锁屏或必须人工确认时说明当前阻点，不绕过。保存后重新查看条件，再实际触发一次验收。"])
        }
        steps.append(contentsOf: [
            ["tool": "phone_act", "instruction": "在用户授权范围内运行保存的快捷指令进行测试；需最终发送、发布或其他提交时使用新观察核对具体动作，不能擅自测试授权外副作用。run URL 仅可用于已保存的普通快捷指令，也须读取真实执行回执。"],
            ["tool": "phone_return_to_amber", "instruction": "切回本轮 Amber 对话，核对返回的 verified，再展示保存、运行和实际触发证据；需要时查看对应任务及原对话结果。分别报告已保存、手动运行、自动化实触和未验证项。"],
        ])
        return steps
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return #"{"ok":false,"tool":"shortcut_compose","status":"invalid_plan","reason":"无法编码快捷指令计划。","installed":false,"verified":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private enum AuthoringError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): message } }
    }
}
