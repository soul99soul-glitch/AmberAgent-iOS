# AmberAgent iOS 动态插件实施计划

## 产品边界

- 正式版主路径：声明式工作流、受限 JavaScript、远端 MCP/OpenAPI。
- Agent 可以生成候选包和测试，但不能批准、启用或静默更新自己的插件。
- 插件不能直接访问 Swift/Objective-C 对象、Cookie、系统权限或任意文件；宿主能力统一经过权限代理。
- Python、pip、iSH 与下载的原生代码不进入公开插件生态，只保留开发者模式。
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

## 每阶段完成门槛

1. 受影响测试与静态构建通过。
2. subagent 独立审查调用链和数据安全。
3. subagent 独立审查 UI 的对齐、间距、触控尺寸、动态文字和状态表达。
4. 主 agent 修完确认的问题并补回归测试，再进入下一阶段。
