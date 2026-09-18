# Jev 集成最终报告（Phase 1–3）

日期：2026-09-17/18（本地）
基线：`4104daf`（执行开始时拉取远端）；实施提交：`9150dc9`（Phase 1）→ `5dca044`（Phase 2）→ `95703b4`（Phase 2 审查修复）→ `c2d46f7`（Phase 3）

## 实现范围（按计划三阶段）

| 阶段 | 交付 | 提交 | 用例数 |
|---|---|---|---|
| Phase 1 工具发现与记忆召回 | Jev 客户端（/v1/systemone，官方契约核对 2026-09-17）、独立版本化设置 + Keychain 凭据、决策协调器（预算/并发/冷却/认证暂停/身份核对）、设置页 UI、三条 tool_search 路径统一的语义发现、记忆统一选中集合（一次计算） | 9150dc9 | 62 |
| Phase 2 上下文筛选 | 长工具输出（>8k 字符、已完成、可安全重读）结构块切分、硬保留信号、逐块 Score、请求副本投影 + 可恢复省略标记、与压缩/记忆/账本接线（投影在压缩后——保证压缩摘要源为 canonical） | 5dca044 + 95703b4 | 21 |
| Phase 3 模型调度 + 网页自动化 | spawn/followup 自动选池分支的 Jev 适配排序（await 不占名额、select+reserve 原子）、有界网页循环服务（白名单/预算/终态/无重放，dry-run/shadow 语义） | c2d46f7 | 17 |

## 逐用途启用状态

| 用途 | 默认模式 | shadow | active | 结论 |
|---|---|---|---|---|
| 工具发现 | off | 代码路径 + 测试就绪 | 代码就绪，启用待真实凭据验收 | off |
| 记忆召回 | off | 同上 | 同上 | off |
| 上下文筛选 | off | 同上 | 同上 | off |
| 模型调度 | off | 同上（设置页已开放开关） | 同上 | off |
| 网页操作 | off | dry-run/shadow 决策轨迹就绪 | **服务层就绪、模型可见工具入口未接线** | off |

**没有任何用途被启用**。全部保持 off：真实 API 流量为零（无 Key），收益门槛（Recall@5、token 降幅、费用降幅）无法评估。未用 mock 冒充任何真实效果。

## 已执行检查（累计证据）

- 基线（改动前）：8 套件 99/99 通过（4104daf）。
- Jev 全部套件（xcresult 实测）：IOSJevClientTests 15 / IOSJevDecisionCoordinatorTests 13 / IOSJevSettingsTests 12 / IOSJevToolDiscoveryTests 10 / IOSJevMemoryRecallTests 12 / IOSJevContextSelectionTests 21 / IOSJevSubAgentModelRoutingTests 6 / IOSJevWebMountLoopTests 11，合计 100（存档 /tmp/jev_phase*.xcresult 与 /tmp/jev_final_regression.xcresult）。
- 回归：Phase 1 十套件 145/145；Phase 2 组合 145/145；最终全量组合（Jev 8 套件 + SubAgentModelPool/OrchestrationTool/ChatBackgroundExecution/AgentToolEngine/MemoryCitation/ContextCompaction/ChatContextSnapshot）**214/215**，唯一失败为既有失败 testSpawnUsesConfiguredPoolModelsReasoningAndTimeout（list_agents 的 ReasoningLevel.name 大小写显示，已核实与本任务无关，单列）。
- Gradle：`./gradlew :feature:tools:api:jvmTest :shared:jvmTest` 通过；Shared.framework（simulator debug）重建后 Swift 消费验证通过。
- 独立对抗审查：Phase 1（P0×1/P1×2/P2×10 → 全部修复或如实声明）、Phase 2（P0×1/P1×4/P2 多项 → 全部修复，含压缩摘要源 P0）、Phase 3 与总体（见下）。

## 关键不变量（测试锁定，与真实 Key 无关）

- off = 零网络、零缓存写入、零指标足迹；范围未全允许 = 零网络。
- 轮次/日预算、每 run/App 并发、冷却、认证暂停按契约执行；失败与超时全部回退原流程。
- 判断身份（run/轮/配置 revision/输入哈希）核对：旧结果不串轮次/会话；在途配置变化丢弃结果。
- 记忆：一次计算选中集合贯穿注入/标记/引用白名单；pinned/core 强保留；归档/过期永不外发。
- 工具发现：精确名零 Jev；暴露只经 bridge；排序覆写逐名重验证。
- 上下文筛选：压缩摘要源为 canonical（投影在压缩后）；只改请求副本；marker 幂等且带恢复引用；写入类与 MCP/http 工具不筛。
- 网页循环：白名单不可被输入放大；缺草稿值不出候选；未知结果不重放；完成由页面状态核验。

## 真实验证缺口（必须保留的事实）

1. **TypeSafe API Key 缺失**：连接测试、shadow 冻结集评估、active 对照全部 blocked；wire format 已按官方文档实现但未经真实响应验证。
2. **真机证据**：移动网络/弱网/锁屏/后台的延迟 p50/p95 与行为未验证（仅模拟器测试）。
3. **收益门槛**：工具/记忆 Recall@5 改善 ≥10pp、长文本输入 token 中位降 ≥20%、调度费用降 ≥10%/耗时降 ≥15%、网页耗时降 ≥15%——全部未评估。
4. **~~wm_run_goal 工具入口接线~~：已完成**（独立会话补充实现，详见下文「wm_run_goal 接线与审查修复记录」）。
5. ~~既有失败~~：**已修复**。`testSpawnUsesConfiguredPoolModelsReasoningAndTimeout` 因 `list_agents` 输出使用 Kotlin 枚举 `.name`（大写）与输入契约（小写）不对称；已将 `IOSThreadOrchestrationToolService` 的 `supported_reasoning` / `default_reasoning` 输出统一 `.lowercased()`，用例通过。

## 补充验证（2026-09-18 上午，独立会话复核）

- **联合树验收**：14 个测试类 **184/184 通过**（8 个 Jev 套件 100 用例 + 设置/记忆/工具暴露/上下文快照 6 个回归套件），TEST SUCCEEDED。覆盖本报告全部三个 phase 的提交（9150dc9..1a9f061）与后续修复同树共存。
- **Phase 1 复核修复**（另一会话的独立对抗审查发现，已全部落地并随 9150dc9 提交）：归档/过期记忆硬筛选单入口 `hardEligible`（外发与注入共用）、连接测试成功解除认证暂停、认证/冷却检查先于预算扣减、config_changed 补记账并清缓存、保存 Key 失效缓存、shadow 同轮去重、ranking 稳定 tie-break、指标存储加锁、设置页 NavigationStack + 本地化。
- **KMP 补测**：`IosToolExposureBridgeTest` 新增 3 用例（快照只读、exact_match 标记、rankingOverride 丢未知名与 tool_search），`jvmTest` 通过；涉及 `IosToolExposureBridge.candidateSnapshot` 的空候选容错（`candidates ?: buildJsonArray {}`）。
- **UI 证据**：设置页渲染截图（`jev-settings-evidence.png`）+ 像素级视觉审查通过；状态卡分隔线缩进已由 58 修为 14（对齐本卡内容列）。
- **Phase 2/3 修复后回归**：7 套件 115/115 通过（OrchestrationTool / SubAgentModelPool / WebMountLoop / SubAgentModelRouting / ContextSelection / SettingsWiring / JevSettings），Gradle `:ai-core:jvmTest` 通过。
- **审查方式记录**：Phase 1/2/3 各有独立 checker/vision 子代理对抗审查；一次全量运行曾因 `/tmp` DerivedData 构建产物损坏出现 8 个假失败，清理重建后稳定复现全绿；测试宿主一次启动期崩溃为模拟器长时闲置所致，重跑消失。

## 独立审查修复记录（Phase 2/3 对抗审查，2026-09-18 上午）

审查结论：无 P0；5×P1 + 7×P2，处理情况：

- **P1-1 网页循环零生产接线**：已修复（wm_run_goal 接线，见下节）。
- **P1-2 Executor 端口缺快照身份**：已修复——`PlannedAction.snapshotRevision` 随候选生成，绑定层执行前重观察比对 revision，不一致返回 `.stale`，循环回到顶部重观察（不计失败，时间预算兜底）。
- **P1-3 模型调度缺已知能力硬过滤**：已修复——`rankedPreferredModelIds` 送 Jev 前淘汰"声明了能力但不含 TOOL"的候选（未声明 = unknown，保留）。
- **P1-4 contextSelection 无设置开关**：已修复——`activeUseCases` 加入 `.contextSelection`。
- **P1-5 契约不变量测试缺口**：部分补齐（快照失效、白名单收窄、unknown 契约、缺值不出候选）；显式 model_id 与 routing 的集成级用例仍待补（现由 guard 代码路径保证）。
- **P2 处理**：submit_readonly_search 缺值不出候选；decide 取消映射 `.cancelled` 终态；search_web 移出可重读白名单（活网非确定性，"重读恢复原文"不成立）；Jev 预计算移到 spawn/followup 占槽之前（等网络不占 bootstrap 槽）；scroll 作为基线观察权已注释；设置页状态卡分隔线缩进 58→14。
- **遗留（明确声明）**：`resolveAgentLaunch` 与预计算的"是否走池"谓词口径不一致（后果只是多/漏一次 Jev 判断，无正确性影响）；`urlChanged` 死参数未删。

## wm_run_goal 接线说明（已实现）

- **目录声明**：`IOSWebMountToolCatalog.descriptors` 增加 `wm_run_goal`（`requiresUserAction: false`——外层入口不替代内层每步审批）。
- **分发**：`ChatToolRuntime.webMountToolExecutionOutput` 顶部按 `toolName == "wm_run_goal"` 分支，先于 localToolExecutor 的后端映射（它是本地编排工具，不是远端后端操作）。
- **输入**：`session_id`、`goal`、`allowed_actions`（动作名集合，只小于白名单）、`draft_value`（type_draft 用）、`completion_text`（完成核验标记）、可选 `max_action_decisions/max_seconds/max_no_progress`（运行时上限取 min，不可被输入放大）。
- **Dependencies 绑定**：`observe` = 调既有 `wm_observe` 路径（`observe(maxChars:maxLinks:)` 的 JSON：`snapshot_id`/`page_revision`/`url`/`interactive_elements`）映射 `PageObservation`；`execute` = 按动作映射到既有具体工具（`wm_click`/`wm_type`（text=draft_value，缺值不出候选）/`wm_scroll`/`wm_select`）并经 `webMountToolExecutionOutput` 执行——内层审批与账本免费继承；`isComplete` = `observation.url` 或元素文本包含 `completion_text`（缺省 false → 走预算/handback 边界，安全）。
- **输出**：`LoopOutcome` 五态映射为工具 JSON（completed/handback/needs_user_action/cancelled/outcome_unknown），steps 与最新观察引用随行。
- **验收**：绑定层 4 个纯函数单测 + 15 个循环护栏用例全绿；真实动作执行仍须 Key + active + 真机证据后才可启用。

## 收尾审查（逻辑闭环 + 调用链 + UI）

提交 1a9f061 后追加两路独立审查并修复：

**逻辑/调用链（无 P0）**：
- P1 上下文筛选无启用入口（Host 已接线但设置页无行、范围恒空）→ 设置页补"上下文筛选"行（模式 + 任务文本/工具输出两项范围）。
- P2 四项修复：工具发现 shadow 改为后台观测（最后一个违反"shadow 不阻塞主路径"的用途）；轮次预算键统一为 runId（原 conv#user 与 runId 两本账使单轮上限实际可达 12 次）；记忆/调度补真实 runId（每 run 1 并发上限生效）；模型调度预计算门控与 resolveAgentLaunch 完全对齐（角色保存覆盖配模型时不再白跑外发）。
- 设置页状态/开销增加 1s 节流刷新（停留页面时冷却/暂停/日开销可见变化）。
- 网页操作（webActions）已完成 wm_run_goal 工具入口接线（core 声明 + 目录注册 + 分发绑定，详见下文「wm_run_goal 接线说明」）；六条调用链（设置、工具发现、记忆、上下文筛选、模型调度、网页操作）均完整，真实动作执行仍需 Key + active + 真机证据后才可启用。

**UI（vision 逐像素，4 张渲染证据）**：
- 默认字号与 AX1 未发现实质布局问题（行高/图标列/右缘对齐像素级一致）。
- 修复 320pt+AX3 下"保存"按钮竖排折行：按钮文字 fixedSize + 辅助功能字号时按钮换至第二行（渲染证据复验通过）。
- 入口行副标题括号与相邻行统一为半角。
- 视觉证据测试 `IOSJevSettingsVisualEvidenceTests`（4 张 PNG 附件）入库，可重复回归。

**最终回归**：15 套件 **208/208 全部通过**（含此前的既有失败用例，其修复来自并行工作区的其他改动）。

## 回退与运维

- 每用途独立开关（设置页"快速判断"）；off 即回到原流程，无数据迁移。
- 清 Key / 收紧范围 / 改配置 → revision 递增 + 缓存失效 + 认证状态重置。
- 指标仅存用途/大小/耗时/用量/建议 top1（无业务原文），7 天/5MiB 上限，可清除。
