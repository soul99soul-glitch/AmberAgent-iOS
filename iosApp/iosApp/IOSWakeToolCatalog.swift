import Foundation
@preconcurrency import Shared

enum IOSWakeToolCatalog {
    static let schedule = "wake_schedule"
    static let list = "wake_list"
    static let cancel = "wake_cancel"
    static let toolNames: Set<String> = [schedule, list, cancel]

    static var declarations: [Tool] {
        [
            declaration(
                name: schedule,
                description: "在当前用户已经授权的目标内，保存以后继续执行的任务。title 简述用途，prompt 写明续跑时要做的具体工作和验收条件。fire_at 为带时区的 ISO8601 时间；event 为约定的事件名，二者至少一项；同时提供时任一先到即触发。event 只在快捷指令或外部入口显式报告同名事件后触发，本工具不会监听任意 App、网页或 Bot。需要操作手机界面时 requires_foreground=true。任务绑定当前会话与原始用户授权，续跑不会扩大权限。成功只表示计划已保存，iOS 不保证准点执行、后台常驻或自动打开前台。不要用它代替需要用户新授权的工作。",
                schema: #"{"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":200},"prompt":{"type":"string","minLength":1,"maxLength":8000},"fire_at":{"type":"string","description":"带时区的 ISO8601 日期时间，如 2026-10-19T15:30:00+08:00。"},"event":{"type":"string","minLength":1,"maxLength":200,"description":"由快捷指令或外部入口显式报告的约定事件名。"},"requires_foreground":{"type":"boolean","default":false,"description":"手机界面操作或必须在前台执行的工作设为 true。"}},"required":["title","prompt"],"additionalProperties":false}"#,
                effect: "sideEffect"
            ),
            declaration(
                name: list,
                description: "读取当前会话保存的续跑任务、下一次触发条件与实际状态。不会触发任务，也不会读取其他会话。区分已保存、等待执行、运行和完成，不能把计划时间当成已经执行。",
                schema: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: cancel,
                description: "取消当前会话中指定的待续跑计划。task_id 必须来自 wake_schedule 或 wake_list；不能取消其他会话任务，也不能撤销已经发生的工作。",
                schema: #"{"type":"object","properties":{"task_id":{"type":"string","minLength":1}},"required":["task_id"],"additionalProperties":false}"#,
                effect: "sideEffect"
            ),
        ]
    }

    private static func declaration(name: String, description: String, schema: String, effect: String) -> Tool {
        let declaration = IosToolExposureBridgeKt.createDynamicWorkflowToolDeclaration(
            toolId: name,
            version: "1",
            description: description,
            inputsJson: schema,
            effectClass: effect
        )
        // Saving a local continuation within the current user's goal needs no
        // new approval. Its durable ledger class still records the write.
        return Tool(
            name: declaration.name,
            description: declaration.description_,
            parameters: declaration.parameters,
            systemPrompt: declaration.systemPrompt,
            needsApproval: false,
            allowsAutoApproval: true,
            mandatoryApproval: false,
            execute: declaration.execute
        )
    }
}
