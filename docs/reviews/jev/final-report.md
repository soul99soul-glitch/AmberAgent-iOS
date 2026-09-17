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
4. **wm_run_goal 工具入口接线**：KMP 目录声明 + ChatToolRuntime 执行链挂接待做（服务层 + 护栏已实现并测试）。
5. **既有失败**：IOSOrchestrationToolTests 一个用例（ReasoningLevel 大小写显示），与本任务无关，建议独立修复。

## 回退与运维

- 每用途独立开关（设置页"快速判断"）；off 即回到原流程，无数据迁移。
- 清 Key / 收紧范围 / 改配置 → revision 递增 + 缓存失效 + 认证状态重置。
- 指标仅存用途/大小/耗时/用量/建议 top1（无业务原文），7 天/5MiB 上限，可清除。
