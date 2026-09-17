# Phase 2 — 上下文筛选

代码状态：完成
离线检查：passed
真实 API：blocked（无 TypeSafe API Key，沿用 Phase 1 缺口）
真实业务和真机：not_run
用途模式：上下文筛选 off（默认）；shadow/active 代码路径已实现，启用依赖真实凭据与验收
基线 commit 与工作区状态：基于 Phase 1 提交 `9150dc9`；另有用户并行修改（未触碰）

## 步骤完成情况

| 计划步骤 | 状态 | 说明 |
|---|---|---|
| 2.1 基线与可处理范围 | 完成 | 只处理**已完成**、> 8,000 字符的工具文本输出；系统/用户消息、权限、工具参数、待执行调用不筛；写入类工具（workspace_file_write 等）一律不筛；20 组代表性长输出样本（多页网页/代码+JSON 表格/错误日志/分页/审批/未知状态）内建于测试 |
| 2.2 可恢复的内容块 | 完成 | 按空行段落切分，围栏代码块（```）整块保留、超长段落不二次拆分；块携带 index/text/mustKeep/keepReason；恢复路径核实：iOS 无 conversation_expand 执行器（已核实全仓），恢复 = **原工具重读**（marker 内指示"用相同参数重新调用该工具"）；只允许可重读的只读检索类工具进入筛选 |
| 2.3 批量判断与请求投影 | 完成 | 程序先标记必须保留（ok:false / status:error、unknown_after_action/may_have_applied、needs_approval/需要确认、next_offset/page_token/cursor 等续取 token、用户明确要求全文——全文需求出现时整轮零外发）；剩余块逐块 Score（0-3 分量表），缺题=不确定=保留（不解码成 0 分）；仅低分块在请求副本中替换为省略标记+恢复引用；同一输出与任务版本只判断一次（marker 幂等 + 轮内 shadow 去重 + 协调器缓存） |
| 2.4 与压缩、记忆、账本接线 | 完成 | Host 顺序：输入硬策略（原有 limitContext/editPreparedContext 在压缩内部）→ 长工具结果筛选投影 → 记忆统一选中集合 → 预算估算 → 原有压缩 → 注入 → 快照；投影只改请求副本，canonical 历史/持久化/压缩摘要来源不受影响（测试断言原文不动）；ledger 快照记录的是投影后模型实际看到的请求（引擎快照在 prepareRequestMessages 钩子内，天然一致）；重复准备幂等 |
| 2.5 恢复与失败路径验证 | 完成 | 网络失败 → 保留全文（测试）；取消/预算耗尽 → 协调器统一回退（Phase 1 已覆盖，本轮复用）；marker 携带 toolCallId/工具名/块号与重读指示（测试）；不改变聊天 UI 历史原文、不回写数据库 |
| 2.6 对照验收 | 部分完成 | off/shadow/active 行为、失败回退、硬保留信号均有测试证据；真实任务 token 节省对比被 Key 阻塞 |

## 变更文件与理由

**新增**
- `iosApp/iosApp/IOSJevContextSelection.swift` — 筛选服务：候选发现（>8k 字符、已完成、可重读工具、marker 幂等）、结构块切分、必须保留信号、逐块 Score、请求副本投影。
- `iosApp/iosAppTests/IOSJevContextSelectionTests.swift` — 17 用例 + 20 组长输出样本工厂。

**修改**
- `iosApp/iosApp/IOSJevSettings.swift` — policy 增加 `contextSelectionMinScore`（解码健壮化沿用 Phase 1）。
- `iosApp/iosApp/ChatKernelRunHost.swift` — `prepareUploadMessages` 在压缩前调用筛选投影（顺序位：硬策略后、压缩前）；Phase 1 记忆准备改为基于投影后副本。
- 说明：无需改 ChatRunKernelAdapter / IOSAgentToolEngine——引擎 `prepareRequestMessages` 钩子 → Host `prepareUploadMessages` 链路使前台/后台/子任务共享同一准备路径（与 Phase 1 核实结论一致），投影自动生效于所有使用该准备器的 run；未使用同一准备器的子任务范围已在报告中如实标注（见下）。

## 已执行检查

| 命令 | 结果 |
|---|---|
| `IOSJevContextSelectionTests` 单独运行 | **17/17 通过**（/tmp/jev_phase2.xcresult） |
| 组合回归：ContextCompaction / AgentToolEngineKernelHook / RunSnapshot / ChatBackgroundExecution / MemoryCitation / ChatContextSnapshot + Phase 1 全部 5 套件 | **141/141 通过**（/tmp/jev_phase2_regression.xcresult） |
| `xcodegen generate` | 已执行 |

关键行为断言（测试覆盖）：
- 围栏代码块整块保留、超长段落不拆；>8,000 字符门槛；写入类工具不筛。
- ok:false / unknown_after_action / needs_approval / next_offset 等信号 → 必须保留；用户"全文/逐字"需求 → 整轮零外发。
- 缺题 = 保留（不解码为 0 分）；低分块隐藏、高分块保留。
- 投影后 toolCallId 不变、marker 携带恢复引用（toolCallId/工具名/块号/重读指示）、canonical 原文与持久化不动。
- 投影幂等：已投影输出不再被选中。
- off 零网络；shadow 返回原请求且后台观测；active 失败保留全文；范围未允许零网络。

## 对照结果

- 样本量：20 组长输出样本（10 组正常长文 + 10 组硬保留信号变体）。
- 模型/问题/策略版本：`jev-latest` 口径；`IOSJevPolicy(policyVersion=1)` 新增 `contextSelectionMinScore=1.0`（0-3 分量表）。
- **无法给出真实任务输入 token 中位数降幅（目标 ≥20%）与费用对比**：无 API Key，active 流量未发生。机制级证据（结构块完整性、硬保留、幂等、恢复引用、失败回退）已由测试锁定。
- 压缩摘要来源完整性：投影只发生在请求副本，压缩输入（compactConversation 读 historyMessages）仍为 canonical 消息——由接线位置与测试共同保证。

## 阻塞、回退与下一步

- **阻塞（真实 API 验证）**：token 节省、费用与任务正确性对照需真实凭据；当前上下文筛选保持 off。
- **范围声明**：投影经引擎 `prepareRequestMessages` 钩子生效于使用 Host 准备链的 run；未接入该准备器的子任务路径不在本阶段声称范围内（与 Phase 1 审查结论一致）。
- **回退**：设置页将该用途切 off 即完全回到原流程；请求副本投影不产生任何持久化痕迹，旧会话完整可读。
- **下一步（Phase 3）**：复用客户端/协调器/预算/身份契约，先做子任务模型调度，再做 WebMount 有界快速循环。
