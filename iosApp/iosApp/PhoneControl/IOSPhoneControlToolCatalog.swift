import Foundation
@preconcurrency import Shared

/// Native iPhone tools are exposed for user-started runs while the persistent switch is enabled.
enum IOSPhoneControlToolCatalog {
    static let toolNames: Set<String> = [
        "phone_status", "phone_apps", "phone_add_app", "phone_observe", "phone_act", "phone_run_goal", "phone_run_flow", "phone_scroll_until", "phone_collect_list", "phone_stop",
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
                description: "读取当前前台授权 App 的新鲜 UI tree，含文字、位置和最新 ref。优先复用上一工具返回的新观察和 ref；缺少新观察、页面仍在加载、需要新截图或 App 切换时再读取。默认不截图、不运行 OCR。树缺少可见文字时设置 include_screen_text=true：端侧 OCR 返回文字、置信度和本次截图的比例位置；无法确认按钮语义或只有图标时设置 include_screenshot=true。两者可同时请求。OCR 不提供原生 ref；坐标只绑定返回的 screenshot_observation_id，操作、切 App 或新观察后失效。当前观察可能带 alerts 和 alert_actions_supported，可用 tap_alert 精确选择弹窗按钮，不自动批准权限。首次会启动本机连接；启动失败停止并报告，不更换控制途径。",
                schema: #"{"type":"object","properties":{"max_nodes":{"type":"integer","minimum":1,"maximum":2000,"description":"最多返回的 UI 节点数，默认 500；若 truncated=true 且缺少目标控件，可提高到 2000 重新观察。"},"include_screenshot":{"type":"boolean","default":false,"description":"明确需要视觉判断时才请求 PNG 截图。"},"include_screen_text":{"type":"boolean","default":false,"description":"需要读取树缺少的可见文字时，对本次截图做端侧OCR；无需同时发送图像，图标仍需截图。"}},"required":[],"additionalProperties":false}"#,
                effect: "pure"
            ),
            declaration(
                name: "phone_act",
                description: "用于单个动作和最终提交（发送、发布、支付、删除、登录、授权）。多步导航、浏览、需要读到下一屏才能决定的作答，优先用 phone_run_goal 只给 goal、bundle_id、completion，一次调用内连续完成，不要逐步调用本工具。操作同一部 iPhone 的授权 App。目标尚未加入允许列表时，先 phone_apps 查询准确 ID，再 phone_add_app 添加。首次使用会按本任务授权启动控制连接，启动失败必须停止本次手机操作，不重试或换用其他控制途径。launch 需要 bundle_id；优先用 tap/type/swipe 操作最近一次工具返回的新界面 ref；若目标在截图中可见却没有可用 ref，使用 tap_point：observation_id 必须来自最近一次截图或 include_screen_text 结果的 screenshot_observation_id，x/y 是整张截图上的位置比例（左上角 0,0，中心 0.5,0.5，均须小于 1），不能传图片像素。以整张截图为坐标系，先确认目标可点击区域的边界，再取中心。不要用 tap 点击空容器代替具体目标。type 还需 text，向输入框追加文字；聊天发送键在键盘上、界面树里没有发送按钮时，用 type 加 submit=true 输入并按键盘发送键，不要去点树里找不到或被遮挡的「发送」；需要替换原内容时，先用 clear 清空最近观察中明确选定的非密码输入框，并附 value_equals 空字符串验收；只有新观察确认空值后才能用新 ref 输入，不要覆盖用户未要求改写的内容。clear 不接受 text；swipe 还需 direction，表示手指移动方向。swipe_point 使用截图上的起点 x/y 和终点 end_x/end_y，均为 0 到 1 之间的位置比例，滑动持续 300ms。long_press 使用最新 ref，long_press_point 使用最新截图比例位置；duration_ms 默认750、范围300到3000。tap_alert 使用本次 alerts 中的按钮 ref，绑定当时的弹窗身份；只支持当前授权 App 树内的弹窗，缺 runner 能力时不操作，不自动同意权限。仅对截图中明确可见的区域使用；顶部展开的系统进度卡挡住控件时，可从卡片中间文字区域上滑收起，避开 App 图标和取消按钮，随后重新观察确认。ref 动作会重新定位唯一元素；tap_point/swipe_point 只接受本次截图和匹配的前台 App、屏幕尺寸，不自动重试。completed 只表示执行回执；工具默认附动作后的新界面和耗时，可直接用其中的新 ref 继续定位，无需重复 phone_observe；业务效果仍须按新界面核验。fresh_observation_available=false 时先重新观察，不能重放已有回执的动作。界面未变化时，对照新截图检查点击位置是否落在目标内，不据此认定控制连接失效；如需修正点击，必须使用新截图重新定位，遵守本任务的动作限制，不重放旧 observation_id。可附 expectation 指定 visible、enabled、absent 或 value_equals 验收条件：动作后自动读取新界面，条件尚未满足时短暂等待并重读（最多 4 次观察，继续观察的时间预算 2 秒，不中断在途请求），分别返回执行回执与 verification；等待不会再次执行动作；enabled 要求新界面中唯一可见目标已启用，visible 只证明可见；absent 必须指定仍可见的 anchor，且之前观察确实出现过目标。验证不足时可能附截图交回主模型，不能把 completed 当作验收成功。unknown 表示可能已执行，必须停止任务并由用户核对，禁止重放。仅适用于用户已授权的手机自控任务。",
                schema: addingExpectation(to: #"{"type":"object","properties":{"action":{"type":"string","enum":["launch","tap","tap_point","type","clear","swipe","swipe_point","long_press","long_press_point","tap_alert"]},"bundle_id":{"type":"string","minLength":1,"description":"launch 的授权 App bundle ID。"},"ref":{"type":"string","minLength":1,"description":"tap/type/clear/swipe/long_press/tap_alert 的最新 UI tree 元素引用。"},"observation_id":{"type":"string","minLength":1,"description":"tap_point/swipe_point/long_press_point 必需：最新截图或 OCR 结果返回的 screenshot_observation_id。"},"x":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"点击位置或滑动起点占整张截图宽度的比例。"},"y":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"点击位置或滑动起点占整张截图高度的比例。"},"text":{"type":"string","minLength":1,"description":"type 追加输入的文字，不自动清空现有内容。"},"submit":{"type":"boolean","description":"type 输入后按键盘回车（聊天类 App 的键盘「发送」键）。发送按钮不在界面树中时用它发送；这是最终提交，只在用户要求发送时使用，不要同时附 value_equals 验收。"},"direction":{"type":"string","enum":["up","down","left","right"],"description":"swipe 的手指移动方向。"},"end_x":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"swipe_point 终点占整张截图宽度的比例。"},"end_y":{"type":"number","minimum":0,"exclusiveMaximum":1,"description":"swipe_point 终点占整张截图高度的比例。"},"duration_ms":{"type":"integer","minimum":300,"maximum":3000,"default":750,"description":"long_press/long_press_point的按住时长。"}},"required":["action"],"additionalProperties":false}"#),
                effect: "sideEffect"
            ),
            declaration(
                name: "phone_run_goal",
                description: "在当前已打开的授权 App 内连续完成多步目标：导航、浏览、按题面作答等需要读到下一屏才能决定的操作。默认只传 goal、bundle_id、completion（可加 max_steps），不要预先列出每个动作。本机每轮读取新界面，把可见的具名控件、主要滚动区域和 App 内弹窗按钮列为候选；同名控件附位置与上下文，由 Jev 选择下一步，动作后重新观察并核验 completion，直到满足或达到预算（默认 15 步、最多 30 步，总计 180 秒）。加载中、界面未变化或判断不清时会在调用内等待重读并换用其它候选，连续 3 轮无进展才交回。需要输入文字或已知准确顺序时可用 steps：每步 page_anchor（当前页面的具体内容，如完整题干）、actions（候选动作及准确文字）、expectation（证明本步效果的条件）；页面偏离计划时自动转为目标模式继续。completion 用能证明结果的唯一控件，示例：{\"kind\":\"visible\",\"target\":{\"identifier\":\"result\"}}；target.region 按当前树中的 rect 除以屏幕尺寸计算。硬规则：Jev 只在本机列出的候选中选择，不生成 ref、坐标或文字；发送消息、发布、支付、删除、登录和权限授权不会自动点击，会以 withheld_final_actions 交回，由你确认后用 phone_act 执行；只操作授权 App，前台切换即停止；不启动或添加 App；unknown 表示可能已执行，必须停止核对，禁止重放。completed 仅在新界面满足 completion 时出现；handback 附已执行步骤和最新界面，只规划剩余部分，不整体重放。",
                schema: goalSchema,
                effect: "sideEffect"
            ),
            declaration(
                name: "phone_run_flow",
                description: "不需要 Jev 判断、每步目标与核验条件都已确定的固定小流程（如已知答案的逐项点击、空输入框草稿）。需要读到下一屏才能决定时改用 phone_run_goal。遇到尚未显示的新题、未知页面或新的视觉判断时交回模型，不预猜后续答案。先打开目标 App 并观察实际控件，提供 1 到 12 个 steps，每步 operation 使用语义 label/identifier，expectation 指定动作后可核验的条件，completion 是最终条件。适合导航、搜索、空输入框草稿，以及用户已授权练习题中当前已确定答案的选择或填写。答案后用 enabled 核验 Check 已启用，点击 Check 后仅在已知的正确反馈标记核验成功时 Continue，到新题边界即结束；反馈标记必须来自已观察证据，不得预猜，答错、未知新题或歧义交回主模型。最终发送消息、发布、支付、删除和登录交回主模型。每次从新界面开始，当前步骤只有唯一可执行目标才派发一次；核验成功后直接用新界面定位下一步，不逐步请求 Jev。不能保存 ref 或坐标，type 只接受空的非敏感输入框。条件尚未满足时只短暂重读，不重做动作；最多 4 次观察和 2 秒继续观察预算，整流程继续执行预算 60 秒。全部步骤和 completion 核验成功才 completed。handback 保留已执行 steps 和最新证据，并中止同轮排队的后续工具，主模型须重新规划，禁止整体重放；unknown 必须停止核对。不会添加或启动 App，不改变当前任务授权。",
                schema: flowSchema,
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
                name: "phone_collect_list",
                description: "读取当前 App 唯一已观察列表容器中的可见行，逐屏滑动采集文字；仅按稳定 identifier 去除相邻页可确认的重叠。无稳定身份时保留逐屏项目，同一项可能重复；保留自然阅读顺序。direction 是手指移动方向，仅 up/down；max_swipes 默认3、最多8，0表示只读当前屏；max_items 默认50、最多200。coverage 始终仅代表已观察屏幕，不表示完整列表或没有漏项。截断、歧义、无进展、App变化或预算耗尽交回最新证据；swipe_count记实际派发次数，unknown停止核对，不能整体重放。不会点击列表项目。",
                schema: encodedSchema(["type": "object", "properties": [
                    "container": targetSchema,
                    "direction": ["type": "string", "enum": ["up", "down"]],
                    "max_swipes": ["type": "integer", "minimum": 0, "maximum": 8, "default": 3],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50],
                ], "required": ["container", "direction"], "additionalProperties": false]),
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
            "kind": ["type": "string", "enum": ["visible", "enabled", "absent", "value_equals"]],
            "target": targetSchema,
            "value": ["type": "string", "maxLength": 4000, "description": "value_equals 必需：输入框期望的完整文字。"],
            "anchor": targetSchema,
        ], "required": ["kind", "target"], "additionalProperties": false,
         "description": "visible=目标在最新界面可见，不要求 enabled，也不要求先执行动作；enabled=新界面中唯一可见目标 enabled 为 true，不接受 value/anchor；absent=原目标消失且指定 anchor 仍可见；value_equals=唯一非敏感输入框值精确一致。"]
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
            "max_steps": ["type": "integer", "minimum": 1, "maximum": 30, "description": "本次调用最多派发的动作数，默认 15（steps 模式至少为步骤数），最多 30。"],
        ], "required": ["goal", "bundle_id", "completion"], "additionalProperties": false])
    }

    private static var operationSchema: [String: Any] {
        ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["tap", "type", "swipe"]],
            "target": targetSchema,
            "text": ["type": "string", "minLength": 1, "maxLength": 4000],
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        ], "required": ["action", "target"], "additionalProperties": false]
    }

    private static var flowSchema: String {
        encodedSchema(["type": "object", "properties": [
            "goal": ["type": "string", "minLength": 1, "maxLength": 1000],
            "bundle_id": ["type": "string", "minLength": 1],
            "steps": ["type": "array", "minItems": 1, "maxItems": 12, "items": [
                "type": "object", "properties": [
                    "operation": operationSchema, "expectation": expectationSchema,
                ], "required": ["operation", "expectation"], "additionalProperties": false,
            ]],
            "completion": expectationSchema,
        ], "required": ["goal", "bundle_id", "steps", "completion"], "additionalProperties": false])
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
