# Phase 3 — 模型调度与网页自动化

代码状态：模型调度完成；网页自动化服务层完成（dry-run/shadow 语义，真实工具入口未接线——见"边界与缺口"）
离线检查：passed
真实 API：blocked（无 TypeSafe API Key，沿用 Phase 1/2 缺口）
真实业务和真机：not_run
用途模式：模型调度 off（默认）/ 网页操作 off（默认）；shadow/active 代码路径已实现
基线 commit 与工作区状态：基于 Phase 2 提交（5dca044 + 95703b4）

## 步骤完成情况

### 模型调度（3.3）

| 步骤 | 状态 | 说明 |
|---|---|---|
| 1 锁定现有优先级 | 完成 | 显式 model_id 直接命中池内候选（拒绝非法），配置/继承/池的优先级代码原样保留；Jev 只在"自动选池"分支生效，**不覆盖用户或既有配置的明确选择**（测试覆盖显式路径与调度互不干扰的结构边界） |
| 2 构建合法候选 | 完成 | 候选完全来自 `IOSSubAgentModelPool.candidates`（enabled/配置有效性硬过滤后）；能力描述只带 contextWindowTokens（nil → "unknown"），不按名称推断强弱；未知能力如实上送 |
| 3 接入启动并保护并发 | 完成 | spawn/followup 调用 `resolveAgentLaunch` 前预计算 `jevPreferredModelIds`（async，等待期间不占任何名额）；返回后 `resolveAgentLaunch` 内重新验证候选（refreshedPoolCandidates）与负载，`select+reserve` 仍在无 await 的同步临界段完成；reserve/release 沿原路径，不泄漏预留；显式思考深度优先级原样保留 |
| 4 真实执行效果 | blocked | 无 Key 无法做 baseline/Jev 对照（费用/耗时/质量） |

实现细节：Jev 返回"适配"排序后，程序取 Jev 首选集合（适配分 ≥ modelRoutingMinScore=2.0，0-3 量表）与非空时**在其内部**用现有 `modelPool.select`（provider 负载 → model 负载 → 轮转）选择——能力排序与负载均衡组合；Jev 首选为空（失败/低分/off）→ 现有选择原样兜底。

### 网页自动化（3.4）

| 步骤 | 状态 | 说明 |
|---|---|---|
| 5 有界工具契约 | 完成 | `IOSJevWebMountLoopService`：输入带 sessionId/goal/draftValue/allowedActions/更小预算；运行时预算=默认 6 次动作决策、15 秒、3 次无进展，**输入只能缩小不能放大**（min 取合）；输出五种结构化终态（completed/handback/needs_user_action/cancelled/outcome_unknown）。dry-run 只产出决策轨迹。真实工具声明（wm_run_goal 通过 discovery 暴露）未接线——见边界 |
| 6 从真实快照生成候选 | 完成 | 每轮观察（注入 Observer）；候选=白名单 ∩ 输入允许 ∩ 快照控件角色契约：click_nav 仅 link、select 仅 combobox/listbox/checkbox/radio、type_draft 仅 textbox 且必须有主模型提供的草稿值、submit_readonly_search 仅 searchbox；Jev Choice 一次选定，执行只消费所选目标 |
| 7 现有校验与账本执行 | 部分 | 动作经注入 Executor（真实接线点为 ChatToolRuntime 的 WebMount 执行链——内层审批/账本由现有链负责，属后续接线工作）；未知结果 → outcome_unknown 且禁止重放（测试）；失效快照每轮重观察 |
| 8 循环限制与独立完成验证 | 完成 | 一次原地等待（revision 未变）计无进展；完成必须由注入的 isComplete（页面/业务状态）核验，"点击成功"不算完成（测试：executor applied 后 revision≥2 且 isComplete 才 completed）；取消→cancelled；时间/决策/无进展任一超限→handback 并带轨迹与最新观察 |

## 变更文件与理由

**新增**
- `iosApp/iosApp/IOSJevModelRouting.swift` — 子任务模型调度服务（排序 + 首选集提取）。
- `iosApp/iosApp/IOSJevWebMountLoop.swift` — 有界快速循环（观察/决策/执行端口注入、白名单、终态语义）。
- `iosApp/iosAppTests/IOSJevSubAgentModelRoutingTests.swift`（7 用例）、`iosApp/iosAppTests/IOSJevWebMountLoopTests.swift`（10 用例）。

**修改**
- `iosApp/iosApp/IOSJevSettings.swift` — policy.modelRoutingMinScore（解码健壮化口径一致）。
- `iosApp/iosApp/IOSThreadOrchestrationToolService.swift` — `resolveAgentLaunch` 增加 `jevPreferredModelIds` 预计算参数；spawn/followup 两个调用点在 resolve 前 await 预计算；邮箱恢复路径（无 task 文本）显式走现有选择。

## 已执行检查

| 命令 | 结果 |
|---|---|
| `IOSJevSubAgentModelRoutingTests` + `IOSJevWebMountLoopTests` | **17/17 通过**（/tmp/jev_phase3.xcresult） |
| 全 Jev 套件 + SubAgentModelPool / OrchestrationTool / SharedSettingsStoreSubAgentOverride / ChatBackgroundExecution / AgentToolEngine 回归 | **178/179**（/tmp/jev_phase3_regression.xcresult） |

唯一失败（**既有失败，单列**）：`IOSOrchestrationToolTests.testSpawnUsesConfiguredPoolModelsReasoningAndTimeout` —— `list_agents` 的 `default_reasoning` 显示 `ReasoningLevel.name`（Kotlin 枚举常量名，恒为大写 "LOW"/"HIGH"），测试期望小写。已核实：该显示代码在我改动前后完全一致（HEAD 与工作区 diff 仅含本任务 Jev 增量），off 模式下我的选择路径与原逻辑完全等价，与本失败无关。按计划要求单列，不掩盖；可作为独立小修（显示层映射小写）。

## 对照结果

- 模型调度样本：测试内 3 模型池（适配分排序/阈值淘汰/缺题保守/off 零网络/失败回退/交集验证）；**真实 20 任务样本 baseline/Jev 对照被 Key 阻塞**。
- 网页样本：受控 fake 页面（link/searchbox/textbox + 白名单边界 + 预算边界）；**受控本地页面真实操作与真实站点验证被 Key + 真机阻塞**。
- 模型调度费用中位数降 10% / 端到端 15% / 网页 15% 的门槛：**无法评估**（无真实流量）；对应用途保持 off。

## 阻塞、回退与下一步

- **边界与缺口（如实声明）**：
  1. `wm_run_goal` 模型可见工具入口未接线（需 KMP 目录声明 + 框架重建 + ChatToolRuntime 执行链挂接）；当前循环服务以注入端口运行，dry-run/shadow 语义已完整，active 执行等待接线与验收。
  2. 模型调度只作用于 spawn/followup 的自动选池分支（计划口径）；邮箱恢复路径不调度。
- **回退**：两个用途独立开关，off 即完全回到现有 spawn 选择与主模型网页流程；无持久化状态需要迁移。
- **全链路验收（3.5）**：组合场景 1-6 的真实运行全部依赖真实凭据；机制级不变量（预算隔离、身份核对、失败回退、白名单、终态语义、无重放）已由 116 个 Jev 套件用例锁定（62+21+17+16 组合）。
