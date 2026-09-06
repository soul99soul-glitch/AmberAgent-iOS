# AmberAgent iOS 动态插件实施计划

## 产品边界

- 支持声明式工作流、受限 JavaScript、远端 MCP/OpenAPI，以及用户显式授权的本地 command 工具。
- Agent 可在端内创建、校验和试运行候选包；`plugin_import(enable=true)` 经用户一次审批后安装并启用，不能自行批准或静默更新。
- JS/Recipe 宿主调用继续经过能力代理；command 授权明确覆盖整个指定运行环境，不用路径/域名范围假称限制任意命令。
- AmberShell 的 `.sh` 为受限命令管道，`.py` 使用已打包 CPython；iSH `.sh` 仅在 ExperimentalGPL guest 内执行。本机开发与导入不等于公开插件市场或下载原生 iOS 代码能力。
- 保持 `amber.recipe.v1`、`recipe_import`、`recipe__<name>` 向后兼容。

## Phase 1：本机生命周期（已完成）

交付：

- `recipes_list`、`recipe_validate`、`recipe_import`。
- `recipe_enable`、`recipe_disable`、`recipe_delete`，写操作沿用现有审批策略。
- 停用包仍可管理，但不进入动态工具目录；重新启用从下一模型轮生效。
- 生命周期操作使用包哈希 CAS；更新、回退和在途调用继续使用固定快照。
- Recipes 列表和详情页展示启用状态，并提供启用、停用、删除、回退入口。

验收：KMP 工具目录测试、`IOSRecipeIntegrationTests`、懒曝光回归、模拟器 UI 审查。

## Phase 2：插件包与能力代理（已完成）

交付：

- `amber.plugin.v1`：一个插件包可注册多个 Recipe 工具。
- Workspace 目录包：`plugin.json`、`recipes/*.json`、可选 README/assets；暂不引入 zip。
- 逐文件 SHA-256、规范路径、文件数/大小上限、工具名冲突检查。
- 插件安装默认停用；权限包络来自实际 primitive，不信任 manifest 自报风险。
- Capability Broker 统一校验插件可调用工具、文件范围、网络域名和 WebMount 动作。

验收：多工具注册、非法路径/冲突零写入、权限扩大重新审批、版本固定与回滚。

## Phase 3：受限脚本、签名和远端插件（已完成）

交付：

- 基于现有 JavaScriptCore 引擎的单次沙箱上下文；只开放 Capability Broker。
- 禁止直接 `fetch`、`eval`、`Function`、模块加载、DOM、文件系统和原生对象桥。
- 超时、取消、输出预算和结果 schema 校验；明确采用 abandon 而非伪称强杀。
- Ed25519 发布者签名、内置/已签名/本地未签名信任层级。
- `.amberplugin` 安全导入导出，以及 MCP/OpenAPI 远端适配。

验收：越权、篡改、错误密钥、路径穿越、超时取消、远端失败均结构化收口。

## Phase 4：生产运维与完整 UI（功能完成）

交付：

- 连续崩溃、超时或 schema 错误自动隔离；诊断日志有容量和保留上限。
- 更新、权限差异、回滚、隔离恢复与失败迁移闭环。
- 后台仅允许显式白名单的声明式/远端插件，Shell/Python/iSH 不自动进入后台。
- 插件中心、详情、导入预览、权限差异、信任状态、试运行和日志界面。
- 公开索引所需的元数据、链接、举报/屏蔽与年龄限制接口；没有服务端时不伪造市场。

验收：冷启动 fail-closed、审批恢复、前后台切换、在途更新/删除、自动隔离、动态字体与真机尺寸布局检查均已通过自动化、独立审查或模拟器实测。物理 iPhone 覆盖安装仍是发布门禁：当前设备在 CoreDevice 中离线，且本机没有与实验版 profile 团队匹配的有效开发签名；arm64 无签名完整包已构建通过。

## 端内工具开发闭环

- `plugin_sdk` 返回当前构建的运行环境、精确 manifest 契约，以及可直接写入 Workspace 的 JS/AmberShell 示例。
- `input_schema` / `output_schema` 支持结构化对象、数组、可选输入及有限 JSON Schema 校验；旧 `inputs` 格式、包哈希与签名保持兼容。
- `plugin_test` 通过正常运行时执行未安装候选工具，可用 `expected_result` 比较实际结果；副作用保留审批。审批固定候选代码和输入，试运行不注册插件，也不影响已安装版本的健康状态。
- 导入可携带试运行返回的 `expected_candidate_hash`，阻止测试后文件变化；`enable=true` 将安装与启用合并为一次明确审批。重新加载目录后，下一模型轮通过 `tool_search` 发现并调用工具。
- `command` 声明 runtime、固定 `scripts/` 入口和可选 `stdin_input`；权限需显式声明 `capabilities.localRuntimes`。AmberShell 以 stdin 传数据，iSH 用 `$1`，参数不拼入脚本源码。
- command 使用现有前台执行、权限、取消和超时路径（1–180 秒）；非零退出、超时、取消或截断不会作为成功结果。AmberShell 展开后命令限 4096 字符，stdin 限 64 KiB；iSH 命令含输入限 32000 字符，guest 文件与 Amber Workspace 隔离。
- 验证范围：定点测试覆盖候选创建、校验、试运行、审批安装启用、目录重新加载与实际调用；真实 provider 自主编写、物理 iPhone 和 guest 中第三方依赖仍需独立验收。

## 每阶段完成门槛

1. 受影响测试与静态构建通过。
2. subagent 独立审查调用链和数据安全。
3. subagent 独立审查 UI 的对齐、间距、触控尺寸、动态文字和状态表达。
4. 主 agent 修完确认的问题并补回归测试，再进入下一阶段。
