import Foundation

struct IOSPluginTestContext: Equatable, Sendable {
    let candidateHash: String
    let expectedResult: IOSRecipeJSONValue?

    @MainActor
    func resultJSON(_ output: String) -> String {
        guard var object = ChatToolCallParsing.jsonObject(output) else { return output }
        object["candidate_hash"] = candidateHash
        object["candidate_test"] = true
        object["registered"] = false
        if object["ok"] as? Bool == true, let expectedResult {
            let actual = object["result"] ?? object["outputs"] ?? NSNull()
            do {
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.fragmentsAllowed])
                let value = try JSONDecoder().decode(IOSRecipeJSONValue.self, from: data)
                let matched = value == expectedResult
                object["expected_match"] = matched
                if !matched {
                    object["ok"] = false
                    object["status"] = "test_failed"
                    object["error"] = "实际结果与 expected_result 不一致。"
                }
            } catch {
                object["ok"] = false
                object["status"] = "test_failed"
                object["error"] = "无法比较插件试运行结果：\(error.localizedDescription)"
            }
        }
        return IOSWorkspaceStore.json(object)
    }
}

struct IOSPreparedPluginTest: Equatable, Sendable {
    let descriptor: IOSDynamicRecipeToolDescriptor
    let argumentsJSON: String
    let context: IOSPluginTestContext
}

@MainActor
enum IOSPluginDevelopmentSDK {
    static func response() -> String {
        #if ENABLE_EXPERIMENTAL_TERMINAL_RUNTIMES
        let ishCompiled = true
        #else
        let ishCompiled = false
        #endif
        return IOSWorkspaceStore.json([
            "ok": true,
            "schema": IOSPluginManifest.schemaVersion,
            "workflow": [
                "先用 tool_search / plugins_list 检查已有工具。用户需要持久复用的小能力时，在 /workspace 下创建 plugin.json 和实现文件。",
                "优先使用受限 JavaScript 处理结构化数据；需要本地命令时选择当前可用的 command 运行环境。",
                "plugin_validate 校验包，再用 plugin_test 在样例数据上真实执行，带 expected_result 检查行为；失败后修改并重试。试运行不会安装、启用或隔离插件，但执行本身可以产生副作用。",
                "验证后调用 plugin_import，传 workspace_directory、expected_candidate_hash 和 enable=true。用户一次审批安装并启用；候选文件变化会拒绝导入。",
                "下一模型轮通过 tool_search 发现 plugin__<id>__<tool> 并调用，完成当前任务。安装的工具在 App 重启后仍可发现。",
                "更新时保持 id/工具名、增加 version，重新验证、试运行及导入；不要覆盖无关 Workspace 文件。",
            ],
            "contract": [
                "required_manifest_fields": ["schema", "id", "name", "version", "description", "tools", "capabilities", "backgroundAllowed"],
                "handlers": "每个 tools 成员恰好声明 recipe、script、remote、command 中的一种。script 引用 scripts/*.js；command 引用固定包内入口。",
                "input_contract": "旧 inputs 映射 string/number/boolean，全部必填。新 input_schema 使用 object 根，支持 properties、required、additionalProperties、array/items、string/number/integer/boolean/null、enum、description；不得与非空 inputs 混用。",
                "output_contract": "output 为 json/object/array/string/number/boolean；可用 output_schema 进一步约束结果。脚本返回结果值，宿主包装为 {ok,result,logs}。",
                "javascript": "脚本是接收 input 对象的同步函数体，使用 return 返回 JSON 可编码值。tools.<name>(args) 同步调用声明的 host_tools；无需 await，不支持 Promise。没有 fetch、require、import、eval、Function、DOM、Swift 或直接文件访问。",
                "host_tools": "JS/Recipe 仅支持按路径授权的 Workspace 工具、scrape_web、WebMount 及工具搜索。先用 tool_search 读取具体工具参数，再声明 host_tools 和 capabilities。",
                "local_commands": "command 必须在 capabilities.localRuntimes 声明 ambershell 或 ish。此授权覆盖该运行环境，不能用插件路径/域名范围声称限制任意命令。执行保留前台授权、超时与取消；timeout_ms 为 1000...180000，不提供持久后台任务。",
                "command_inputs": "默认将整个 inputs 对象编码为 JSON；stdin_input 可指定一个字符串字段。AmberShell 通过 stdin 接收，iSH 脚本通过 $1 接收。调用参数不会拼入脚本代码。",
                "command_outputs": "output=string 返回完整 stdout；其他类型要求 stdout 是完整 JSON。stderr 用于诊断；非零退出、超时、取消或输出截断不会视为成功。",
                "files": "plugin.json、README.md、recipes/*.json、scripts/*.js/*.sh/*.py、assets/**。只有声明的入口会执行；assets 不会自动挂载到 Shell 或 iSH。",
                "limits": ["max_files": IOSPluginLimits.maxFiles, "max_file_bytes": IOSPluginLimits.maxFileBytes, "max_package_bytes": IOSPluginLimits.maxPackageBytes],
            ] as [String: Any],
            "runtimes": [
                "javascript": ["compiled": true, "notes": "受限 JavaScriptCore；适合数据处理和已授权宿主工具组合。"],
                "ambershell": [
                    "compiled": true,
                    "commands": IOSAmberShellEngine.supportedCommands,
                    "python_compiled": IOSAmberShellEngine.supportedCommands.contains("python"),
                    "notes": ".sh 入口仅允许一个受限命令/最多三段管道，不是通用 shell。支持 Python 的构建可用 .py 入口；沿用受限 CPython 模块与语法（如 json/math/re 数据处理），不支持 sys/os、pip、直接文件或网络调用。默认 JSON 输入用 json.loads(input()) 读取。单条展开后的命令最多 4096 字符。stdin 最多 64 KiB。只访问 Amber Workspace。",
                ] as [String: Any],
                "ish": [
                    "compiled": ishCompiled,
                    "notes": "仅 ExperimentalGPL。需要可用的嵌入 iSH 资源及用户授权；scripts/*.sh 在 guest 执行，输入是 $1。guest /workspace 与 Amber Workspace 隔离，依赖包需在 guest 中实际安装，不能假定存在。",
                ] as [String: Any],
            ],
            "examples": [javascriptExample(), commandExample()],
        ])
    }

    static func javascriptExample() -> [String: Any] {
        [
            "workspace_directory": "/workspace/plugins/text_metrics",
            "files": [
                "plugin.json": [
                    "schema": IOSPluginManifest.schemaVersion, "id": "text_metrics", "name": "文本统计",
                    "version": "1.0.0", "description": "统计文本条目并返回去重结果。",
                    "backgroundAllowed": false, "capabilities": emptyCapabilities,
                    "tools": [[
                        "name": "summarize", "script": "scripts/summarize.js", "output": "object",
                        "input_schema": [
                            "type": "object",
                            "properties": [
                                "texts": ["type": "array", "items": ["type": "string"]],
                                "trim": ["type": "boolean", "description": "是否去除首尾空白，省略时为 true。"],
                            ],
                            "required": ["texts"], "additionalProperties": false,
                        ],
                        "output_schema": [
                            "type": "object",
                            "properties": [
                                "count": ["type": "integer"],
                                "unique": ["type": "array", "items": ["type": "string"]],
                            ],
                            "required": ["count", "unique"], "additionalProperties": false,
                        ],
                    ]],
                ],
                "scripts/summarize.js": "const values = input.texts.map(text => input.trim === false ? text : text.trim()); return {count: values.length, unique: [...new Set(values)]};",
            ] as [String: Any],
            "test": [
                "tool": "summarize", "inputs": ["texts": [" a ", "a", "b"]],
                "expected_result": ["count": 3, "unique": ["a", "b"]],
            ],
        ]
    }

    static func commandExample() -> [String: Any] {
        var capabilities = emptyCapabilities
        capabilities["localRuntimes"] = ["ambershell"]
        return [
            "workspace_directory": "/workspace/plugins/unique_lines",
            "files": [
                "plugin.json": [
                    "schema": IOSPluginManifest.schemaVersion, "id": "unique_lines", "name": "文本行去重",
                    "version": "1.0.0", "description": "对输入文本按行排序去重。",
                    "backgroundAllowed": false, "capabilities": capabilities,
                    "tools": [[
                        "name": "deduplicate", "inputs": ["text": "string"], "output": "string",
                        "command": ["runtime": "ambershell", "entry": "scripts/unique.sh", "stdin_input": "text"],
                    ]],
                ],
                "scripts/unique.sh": "sort | uniq",
            ] as [String: Any],
            "test": ["tool": "deduplicate", "inputs": ["text": "b\na\nb\n"], "expected_result": "a\nb\n"],
        ]
    }

    private static let emptyCapabilities: [String: Any] = [
        "workspaceReadPrefixes": [], "workspaceWritePrefixes": [], "networkDomains": [], "webMountActions": [],
    ]
}
