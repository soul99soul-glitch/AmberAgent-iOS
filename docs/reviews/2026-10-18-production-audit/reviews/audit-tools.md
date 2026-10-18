# 工具执行与编排审查（current working tree，2026-10-18）

本包只读审查；未运行构建或测试，未修改生产/测试文件。已读取 `iosApp/AGENTS.md`。模块拆分后的 tracked/untracked 源码均作为现状。MiniApp/permissions、WebMount 的窄范围子审报告分别在同目录 `audit-miniapp.md` 与 `audit-webmount.md`。

## 确认候选 T1 / P1-P2：child 取消早于本轮 assistant 输出时，把旧轮报告投递为新 run 的 FINAL_ANSWER

- 真实入口：已有子线程完成一轮后，父调用 `followup_task` 再派新任务；新 run 启动后、provider 尚未产生新 assistant 时，父调用 `interrupt_agent` 或用户取消。`IOSChatBackgroundGenerationCoordinator.swift:708-725` 从该 job 的 messagesSnapshot 重建 latestMessages；没有未决 tool 时直接原样使用，:729-748 保存并记 cancelled，:761-762 调 `notifyRunTerminal`。
- 调用链：background terminal callback（`Chat/Background/IOSChatBackgroundTerminalWriter.swift:767-781`）传整份 `finalMessages` → `ChatViewModel.swift:1147-1160` 读本 run status → `IOSThreadOrchestrationToolService.swift:1198-1214` 只用 status 做模型路由记录，再把 full history 交给 control commands → `AgentRuntime/Orchestration/IOSOrchestrationControlCommands.swift:573-579,622-629` 无 run 边界地取最后一个 assistant 文本并组 FINAL_ANSWER。
- 可观测影响：父线程看到新 runId 的 FINAL_ANSWER，正文实际是上一轮报告（首次 spawn fork=all 时还可能来自父线程 fork 历史）。它没有 cancelled 状态，父会把旧结论误认为新任务结果；长文本还会给出旧 message_id 作为本轮全文引用。
- 二次复核：这不是“用户取消本来就保留历史”的设计问题，保留 transcript 正确，错在把历史重新标作新 run 的结果。对照 `IOSChatBackgroundTerminalWriter.swift:791-794`，archive 已正确用 `IOSSubAgentOutputProjection.generatedMessages(finalMessages:displayMessages:)` 隔离本轮；mailbox 投递没有采用该边界。`terminalStatus` 已传到 orchestration service，但没有传到投递 owner。
- 最小修复 owner：终态发送处以本 run 的基线 displayMessages/已知生成边界选正文，且无本轮 assistant 时投递真实 terminalStatus/terminalReason 的短结构化结果。复用现有 output projection，避免新增 run 状态机；保留完整会话与 session_read 引用。前后台均把本轮边界传入同一投递 owner。
- 测试 seam：扩展 `IOSOrchestrationListInterruptTerminalTests` 现有取消终态、空转录终态、长报告引用测试：历史 old assistant + new user（无新 assistant）+ cancelled 必须投递一次 cancelled，且不得含 old report；追加新 partial assistant 后取消则只回传本轮 partial，并保留 cancelled 标记。背景 cancellation fixture 验证 callback 接收到的边界。

## 确认候选 T2 / P2：wm_run_goal 提出缺少值且控件类型不受支持的 select 动作

- 真实入口：Jev webActions active 且用户已授权时，模型调用 `wm_run_goal`，allowed_actions 含 `select`，观察页含 combobox/listbox/checkbox/radio；`IOSJevWebMountLoopService.legalActionCandidates` 将 select 放入 Jev 可选动作。
- 调用链/精确行：`IOSJevWebMountLoop.swift:731-733` 对上述四类角色产 `PlannedAction(kind:.select,value:nil)`；`AgentRuntime/Tools/Runtime/ChatWebGoalTool.swift:244-247` 映射 wm_select 只有 session/snapshot/target，完全不传 text/value。local `WebMount/IOSWebMountBridgeScripts.swift:946-957` 只接受 tagName SELECT 并要求 `option.value === text`；desktop `WebMount/Desktop/IOSWebMountDesktopMapping.swift:260-268` 缺 value/text 直接 `invalidArguments("wm_select requires a value.")`。
- 可观测影响：checkbox/radio 永远 target_not_selectable；有非空选项值的原生 SELECT 返回 option_not_found；desktop 总是缺值错误。若本地 select 有空占位 option，缺省空文本可能选中占位值，偏离 goal。循环浪费一次决策后 handback，原本宣传的快速选择不可完成。
- 二次复核：直接 wm_select 工具已有正常用值的真实测试（`IOSWebMountAutomationContractTests.swift:346-353`）。问题仅在 fast-loop action construction，不能归为后端不支持或审批 by design。`.select` 在 actionWhitelist 内且候选真实提交给 Jev，因此不是不可达死代码。
- 最小修复 owner：在 fast-loop legal candidate/映射入口只允许具有确定选项值、且后端真正支持的 SELECT 动作；当前 observation 不提供选项值时，不提出可执行 select 候选并明确交回主模型。不要猜值，不要为了该修复扩展通用表单框架；保留直接 wm_select。Root 可根据 peer review 决定是否本轮实施或采用较窄候选禁用。
- 测试 seam：`IOSJevWebMountContractTests`/`IOSJevWebMountLoopTests` 的 legal candidates、`webMountLoopActionCall`；覆盖 checkbox/radio 不进入错误 select 路由、nil value 不生成 wm_select、明确支持的 value（若实现）原样保留。复用现有 WebMount local select smoke fixture验证一次实际选择。

## 已二次排除 / 不作为修复项

- 引擎输出达到 length 时暂时保留未决工具：单看 `IOSAgentToolEngine.swift:438-450` 容易认为后续 run 会误执行；真实前后台 terminal owner 会将未决调用失败化。后台明确在 `IOSChatBackgroundTerminalWriter.swift:85-99` 处理，因此不以引擎内部暂态报缺陷。
- `honorApprovalPause=false` 文档说 approval 当 denial，但 batch 本身只跳过并留下空 output：真实 background executor 对需审批工具已转换 `.denied`（`ChatToolExecutorAdapters.swift` workspace/terminal/webmount/memory 等），当前没有证明可达生产调用违反此假设。不给通用额外 fallback。
- agentPath 查找用全量 allEdges.first：当前 uniqueTaskName 同样全量按 parent path 避冲突，未证明正常串行 spawn 能形成重复路径。跨服务/并发或导入异常数据仅是进一步调查点，不按已证实 bug 修。
- Recipe 逐步执行 `isUserInitiated=true`：每步执行之前另有 step gate，批准只跳过刚批准的一步，后续恢复 gate；不能据此认定绕过审批。

## 建议阶段（供 Root 合并全局计划）

1. 先修 MiniApp crash/freeze、WebMount session/URL/data semantic 问题（由各子审最终报告给出确认结论），每条以现有测试 seam 做最小回归。
2. 修 T1 的终态正文归属与状态，保持原 mailbox envelope、runId 幂等和存储 owner；前后台各有一条行为回归。
3. 修 T2 fast-loop 不可执行动作候选（若 peer 复核采纳）。
4. 各 phase 交独立 subagent 复查本 phase diff；Root 统一执行适用构建/测试并报告模拟器与真实 provider/设备未验证边界。
