import Foundation
@preconcurrency import Shared

/// Native iPhone controls are discovered only for a user-authorized, bounded run.
enum IOSPhoneControlToolCatalog {
    static let toolNames: Set<String> = [
        "phone_status", "phone_observe", "phone_act", "phone_stop",
    ]

    static func isPhoneTool(name: String) -> Bool {
        toolNames.contains(name)
    }

    static var declarations: [Tool] {
        [
            declaration(
                name: "phone_status",
                description: "查询手机本机 iPhone 自控任务状态和当前运行授权。只读，不启动或重新配对控制服务。仅适用于用户已授权的有界任务。",
                schema: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: "phone_observe",
                description: "读取同一部 iPhone 前台授权 App 的新鲜 UI tree，包含文字、元素 ref 和位置。默认不截图；仅在 UI 树不足以判断时显式设置 include_screenshot=true。ref 只属于最近一次观察，执行动作或切换 App 后必须重新观察。仅适用于用户已授权的有界手机自控任务。",
                schema: #"{"type":"object","properties":{"max_nodes":{"type":"integer","minimum":1,"maximum":500,"description":"最多返回的 UI 节点数，默认 500。"},"include_screenshot":{"type":"boolean","default":false,"description":"明确需要视觉判断时才请求 PNG 截图。"}},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: "phone_act",
                description: "操作同一部 iPhone 的授权 App。launch 需要 bundle_id；tap/type/swipe 需要最近一次 phone_observe 的 ref；type 还需 text，向输入框追加文字；swipe 还需 direction，表示手指移动方向。每次动作都重新定位唯一元素，不自动重试。completed 只表示执行回执，须再次观察验证业务效果；unknown 表示可能已执行，必须停止任务并由用户核对，禁止重放。仅适用于用户已授权的有界手机自控任务。",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["launch","tap","type","swipe"]},"bundle_id":{"type":"string","minLength":1,"description":"launch 的授权 App bundle ID。"},"ref":{"type":"string","minLength":1,"description":"tap/type/swipe 的最新 UI tree 元素引用。"},"text":{"type":"string","minLength":1,"description":"type 追加输入的文字，不自动清空现有内容。"},"direction":{"type":"string","enum":["up","down","left","right"],"description":"swipe 的手指移动方向。"}},"required":["action"],"additionalProperties":false}"#,
                effect: "sideEffect"
            ),
            declaration(
                name: "phone_stop",
                description: "结束当前有界 iPhone 手机自控会话并释放本机启动器，停止接受后续动作。不能撤销已经发送给系统的点击、输入或滑动；仅结束当前 run 的控制权限。",
                schema: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
                effect: "sideEffect"
            ),
        ]
    }

    private static func declaration(name: String, description: String, schema: String, effect: String) -> Tool {
        IosToolExposureBridgeKt.createDynamicWorkflowToolDeclaration(
            toolId: name,
            version: "1",
            description: description,
            inputsJson: schema,
            effectClass: effect
        )
    }
}
