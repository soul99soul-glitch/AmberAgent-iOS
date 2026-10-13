import Foundation
@preconcurrency import Shared

/// Native iPhone tools are exposed for user-started runs while the persistent switch is enabled.
enum IOSPhoneControlToolCatalog {
    static let toolNames: Set<String> = [
        "phone_status", "phone_apps", "phone_add_app", "phone_observe", "phone_act", "phone_run_goal", "phone_scroll_until", "phone_stop",
    ]

    static func isPhoneTool(name: String) -> Bool {
        toolNames.contains(name)
    }

    static var declarations: [Tool] {
        [
            declaration(
                name: "phone_status",
                description: "查询手机本机 iPhone 自控状态、准备情况和当前应用范围。只读，不启动或重新配对控制服务。总开关开启后，由用户发起的任务即可使用；no_scope 时先 phone_apps 查询，再 phone_add_app 添加目标应用。",
                schema: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: "phone_apps",
                description: "从同一部 iPhone 的开发服务查询已安装应用的名称和准确 Bundle ID，不依赖电脑，不启动目标 App 或控制 runner。query 可按名称或 ID 搜索，名称可能是英文；查不到中文名时尝试英文或留空分页浏览，不要猜 ID。结果含 selected、total 和 has_more；需要控制未选应用时，使用返回的准确 ID 调用 phone_add_app。查询失败会明确报错，不表示手机没有应用。",
                schema: #"{"type":"object","properties":{"query":{"type":"string","description":"可选的名称或 Bundle ID 关键词；留空列出应用。"},"offset":{"type":"integer","minimum":0,"default":0},"limit":{"type":"integer","minimum":1,"maximum":100,"default":50}},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: "phone_add_app",
                description: "把 phone_apps 查到的准确 Bundle ID 加入允许控制列表，并在当前任务立即生效，后续任务也保留。仅为当前用户任务需要的应用添加；重名时先结合 ID 确认目标，不猜测。此工具不打开应用、不执行点击或输入；添加后再用 phone_act launch。",
                schema: #"{"type":"object","properties":{"bundle_id":{"type":"string","minLength":1,"description":"phone_apps 返回的准确 Bundle ID。"}},"required":["bundle_id"],"additionalProperties":false}"#,
                effect: "sideEffect"
            ),
            declaration(
                name: "phone_observe",
                description: "读取同一部 iPhone 前台授权 App 的新鲜 UI tree，包含文字、元素 ref 和位置。首次使用会按本任务授权启动控制连接，启动失败必须停止本次手机操作，不重试或换用其他控制途径。默认不截图；UI 树缺少弹窗关闭按钮、只有空容器或无法定位目标时，设置 include_screenshot=true 获取图像。截图会附带 screenshot_observation_id，可用 phone_act tap_point 点击图中明确可见的目标，不要靠滑动空容器猜测关闭。优先复用上一个工具已返回的新观察和 ref；缺少新观察、页面仍在加载、需要新截图或 App 切换时再读取。仅适用于用户已授权的手机自控任务。",
                schema: #"{"type":"object","properties":{"max_nodes":{"type":"integer","minimum":1,"maximum":2000,"description":"最多返回的 UI 节点数，默认 500；若 truncated=true 且缺少目标控件，可提高到 2000 重新观察。"},"include_screenshot":{"type":"boolean","default":false,"description":"明确需要视觉判断时才请求 PNG 截图。"}},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: "phone_act",
                description: "单个明确动作使用本工具；连续操作交给 phone_run_goal：给小目标让 Jev 连续选择，已知顺序则提供 steps。成功动作会返回新界面和 ref，可直接供下一步使用；不要无条件再调用 phone_observe。操作同一部 iPhone 的授权 App。目标尚未加入允许列表时，先 phone_apps 查询准确 ID，再 phone_add_app 添加。首次使用会按本任务授权启动控制连接，启动失败必须停止本次手机操作，不重试或换用其他控制途径。launch 需要 bundle_id；优先用 tap/type/swipe 操作最近一次工具返回的新界面 ref；若目标在截图中可见却没有可用 ref，使用 tap_point：observation_id 必须来自最近一次 include_screenshot=true 返回的 screenshot_observation_id，x/y 是整张截图上的位置比例（左上角 0,0，中心 0.5,0.5，均须小于 1），不能传图片像素。以整张截图为坐标系，先确认目标可点击区域的边界，再取中心。不要用 tap 点击空容器代替具体目标。type 还需 text，向输入框追加文字；需要替换原内容时，先用 clear 清空最近观察中明确选定的非密码输入框，并附 value_equals 空字符串验收；只有新观察确认空值后才能用新 ref 输入，不要覆盖用户未要求改写的内容。clear 不接受 text；swipe 还需 direction，表示手指移动方向。swipe_point 使用截图上的起点 x/y 和终点 end_x/end_y，均为 0 到 1 之间的位置比例，滑动持续 300ms。仅对截图中明确可见的区域使用；顶部展开的系统进度卡挡住控件时，可从卡片中间文字区域上滑收起，避开 App 图标和取消按钮，随后重新观察确认。ref 动作会重新定位唯一元素；tap_point/swipe_point 只接受本次截图和匹配的前台 App、屏幕尺寸，不自动重试。completed 只表示执行回执，业务效果须依据返回的新观察或 verification 判断；仅未返回新观察时再调用 phone_observe。界面未变化时，对照新截图检查点击位置是否落在目标内，不据此认定控制连接失效；如需修正点击，必须使用新截图重新定位，遵守本任务的动作限制，不重放旧 observation_id。可附 expectation 指定 visible、absent 或 value_equals 验收条件：动作后自动读取新界面，条件尚未满足时短暂等待并重读（最多 4 次观察，继续观察的时间预算 2 秒，不中断在途请求），分别返回执行回执与 verification；等待不会再次执行动作；absent 必须指定仍可见的 anchor，且之前观察确实出现过目标。验证不足时可能附截图交回主模型，不能把 completed 当作验收成功。unknown 表示可能已执行，必须停止任务并由用户核对，禁止重放。仅适用于用户已授权的手机自控任务。",
                schema: addingExpectation(to: #"{"type":"object","properties":{"action":{"type":"string","enum":["launch","tap","tap_point","type","clear","swipe","swipe_point"]},"bundle_id":{"type":"string","minLength":1,"description":"launch 的授权 App bundle ID。"},"ref":{"type":"string","minLength":1,"description":"tap/type/clear/swipe 的最新 UI tree 元素引用。"},"observation_id":{"type":"string","minLength":1,"description":"tap_point/swipe_point 必需：最新截图返回的 screenshot_observation_id。"},"x":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"点击位置或滑动起点占整张截图宽度的比例。"},"y":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"点击位置或滑动起点占整张截图高度的比例。"},"text":{"type":"string","minLength":1,"description":"type 追加输入的文字，不自动清空现有内容。"},"direction":{"type":"string","enum":["up","down","left","right"],"description":"swipe 的手指移动方向。"},"end_x":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"swipe_point 终点占整张截图宽度的比例。"},"end_y":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"swipe_point 终点占整张截图高度的比例。"}},"required":["action"],"additionalProperties":false}"#),
                effect: "sideEffect"
            ),
            declaration(
                name: "phone_run_goal",
                description: "连续界面操作首选本工具。默认只提供 goal、bundle_id、completion（可加 max_steps），根据每轮最新界面定位有名可点击控件，唯一可执行候选本地执行，多个候选由 Jev 选择下一步，在一次工具调用内连续点击、读屏并核对完成条件，无需主模型列出全部动作。适合导航、选择选项、按已确定内容逐项选择；需要输入文字或已知准确顺序时用 steps，在每步的 actions 中填写候选动作与准确输入文字；每步还需 page_anchor 和 expectation，Jev 不生成输入或坐标。唯一可执行候选直接执行，分支才由 Jev 选择。page_anchor 必须是当前页面的具体内容，如完整题干或项目名称，不能用重复的题型标题或继续按钮。中间验收要证明本步效果，不能只检查原本可见的文字；对象移入指定区域时用 target.region，类型重名时加完整 type。只在页面切换时开启 wait_for_stability，连续选择保持默认 false。每步 actions 表示该步的候选分支，顺序由 steps 表达。completion 描述目标状态；visible 表示目标在最新界面可见，disabled 也可满足；目标模式初始已满足时允许零动作完成。若目标需要操作后才完成，请使用能证明结果的唯一控件，避免把始终存在的通用按钮当成业务完成；region 必须用当前树中的 rect 除以屏幕尺寸计算，不能把“上方”猜成固定屏幕比例。completion 格式示例：{\"kind\":\"visible\",\"target\":{\"identifier\":\"result\"}}，identifier/label 只放在 target 内。每轮复用动作后的新观察；停止时返回已执行记录与最新界面，不重放已执行项。上限 12 步/60 秒，默认 6 步（steps 默认其长度）。不启动或添加 App；只操作授权 App。发送消息、发布、支付、删除、登录等最终提交交回主模型。Jev 未启用、需截图、无进展、目标歧义或超预算时 handback；unknown 必须停止核对。completed 仅在新界面满足 completion 时出现。",
                schema: goalSchema,
                effect: "sideEffect"
            ),
            declaration(
                name: "phone_scroll_until",
                description: "在当前 App 已观察到的唯一滚动容器里，逐次滑动寻找指定文字或 identifier。container 必须来自最新界面树，target 可是用户要求查找但尚未显示的精确文字。每次滑动后重新观察，目标唯一可见即停止；不会点击目标。最多 max_swipes 次，默认3，上限8，继续执行预算60秒；截断、歧义、App变化、无进展或失败立即交回最新证据。swipe_count 表示已派发的次数，不能把 handback 当作未执行并整体重放；unknown 必须停止核对。若弹窗或目标只有图像，请用 phone_observe 截图判断。",
                schema: encodedSchema(["type": "object", "properties": [
                    "target": targetSchema, "container": targetSchema,
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "max_swipes": ["type": "integer", "minimum": 1, "maximum": 8, "default": 3],
                ], "required": ["target", "container", "direction"], "additionalProperties": false]),
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

    private static var targetSchema: [String: Any] {
        ["type": "object", "properties": [
            "label": ["type": "string", "minLength": 1, "maxLength": 512],
            "identifier": ["type": "string", "minLength": 1, "maxLength": 512],
            "type": ["type": "string", "description": "可选完整元素类型，如 XCUIElementTypeButton。可用于区分实际重名的控件；普通文字或自定义控件不要求显式指定。"],
            "region": ["type": "object", "properties": [
                "x": ["type": "number", "minimum": 0, "exclusiveMaximum": 1],
                "y": ["type": "number", "minimum": 0, "exclusiveMaximum": 1],
                "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
                "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
            ], "required": ["x", "y", "width", "height"], "additionalProperties": false,
                "description": "可选的屏幕比例矩形，不能超出屏幕；仅匹配中心落在该区域的元素。依据当前观察的 rect 和屏幕尺寸填写，用于区分源区域与目标区域中的同名内容。"],
        ], "description": "label/identifier 至少一个，均精确匹配；type 和 region 可消除重名，不能单独作为目标；不得用过期 ref 或猜测。", "additionalProperties": false]
    }

    private static var expectationSchema: [String: Any] {
        ["type": "object", "properties": [
            "kind": ["type": "string", "enum": ["visible", "absent", "value_equals"]],
            "target": targetSchema,
            "value": ["type": "string", "maxLength": 4000, "description": "value_equals 必需：输入框期望的完整文字。"],
            "anchor": targetSchema,
        ], "required": ["kind", "target"], "additionalProperties": false,
         "description": "visible=目标在最新界面可见，不要求 enabled，也不要求先执行动作；absent=原目标消失且指定 anchor 仍可见；value_equals=唯一非敏感输入框值精确一致。"]
    }

    private static var goalSchema: String {
        encodedSchema(["type": "object", "properties": [
            "goal": ["type": "string", "minLength": 1, "maxLength": 1000],
            "bundle_id": ["type": "string", "description": "当前已打开的授权 App 的准确 ID。"],
            "steps": ["type": "array", "minItems": 1, "maxItems": 12, "description": "已知顺序时使用的有序步骤；每步 actions 表示候选分支，并需具体页面锚点和本步验收条件。不提供 steps 时使用目标模式。", "items": [
                "type": "object", "properties": [
                    "page_anchor": targetSchema,
                    "actions": ["type": "array", "minItems": 1, "maxItems": 12, "items": [
                        "type": "object", "properties": [
                            "action": ["type": "string", "enum": ["tap", "type", "swipe"]],
                            "target": targetSchema,
                            "text": ["type": "string", "minLength": 1, "maxLength": 4000],
                            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                        ], "required": ["action", "target"], "additionalProperties": false,
                    ]],
                    "expectation": expectationSchema,
                    "wait_for_stability": ["type": "boolean", "default": false],
                ], "required": ["page_anchor", "actions", "expectation"], "additionalProperties": false,
            ]],
            "completion": expectationSchema,
            "max_steps": ["type": "integer", "minimum": 1, "maximum": 12, "description": "steps 默认步骤数；目标模式默认 6。"],
        ], "required": ["goal", "bundle_id", "completion"], "additionalProperties": false])
    }

    private static func addingExpectation(to schema: String) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(schema.utf8)) as! [String: Any]
        var properties = object["properties"] as! [String: Any]
        properties["expectation"] = expectationSchema
        object["properties"] = properties
        return encodedSchema(object)
    }

    private static func encodedSchema(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
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
