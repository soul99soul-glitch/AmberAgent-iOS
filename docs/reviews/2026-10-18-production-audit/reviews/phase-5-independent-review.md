# Phase 5 独立 review

审查者未实施本 phase Tools/Web 生产改动。本报告只检查已冻结的本轮差异与相关调用契约，不把原有模块化 WIP 当成此轮新增。未修改实现/测试，未运行构建或测试。

整体结论：**PASS，无阻塞发现**。T1、T2 已完成独立审查；WM1–3 已整合 audit_kmp 的 scoped before-copy 独立专项 PASS。最终集成构建与 GREEN 结果由 Root 统一报告。

## T2 select 候选与映射 — ACCEPTED，无阻塞发现

已检查 IOSJevWebMountLoop.legalActionCandidates:714-745 的实际小diff、ChatWebGoalTool.webMountLoopActionCall:230-258 与新 IOSJevWebMountSelectCandidateTests。Root 的 pending-domains-red-summary.json 明确记录三项旧实现失败：无值select候选存在、nil映射为工具调用、明确值在payload丢失。

修复与问题匹配：当前 observation 没有 option values，planner 不再按 combobox/listbox/checkbox/radio 角色产无值select；没有新增猜值或错误控件路由。正常 link、textbox/searchbox、scroll 候选及原 allowedActions 收窄没有改变。直接 wm_select 工具不受此修复删除或禁用。

mapper 对 .select 同时要求 elementId 与非nil value，payload仍绑定原 session_id/snapshot_id/target；空串及空白值保留为字面选项，不把 nil 与空串混淆。缺值时 mapper 返回 nil，进入执行入口已有的 failed/handback 路径，未静默当成功。

也核对了 replay 与决策边界：旧 select replay 必须重新物化到当前 legal candidates（materialize:294-309），不存在的 select不能被缓存复活；Jev choice也只接受bounded candidates实际存在项（chooseAction:870-880）。不需要额外过滤/兜底。

新回归分别证明候选、nil和明确字面值（含空串/空白）语义，断言没有为实现弱化。现有 loop/contract suite的运行结果由Root补充；审查没有冒充已GREEN。

建议Root验证：IOSJevWebMountSelectCandidateTests、IOSJevWebMountContractTests、IOSJevWebMountLoopTests，配IOSWebMountAutomationContractTests中的直接select控制项。

## WM1–3

已整合 audit_kmp 的独立专项报告 /tmp/amber-audit-20261018-current/phase5-webmount-independent-review.md，结论 PASS，无阻塞发现；该 reviewer 使用 webmount-before 的任务前快照审查指定五个生产文件及三个新回归，本报告未重复审同一diff。

- WM1 保留local预留槽、总capacity限制，恢复多个持久local及有效current ID；owner/lease清理、needsReopen与不自动导航规则保持。
- WM3 仅typed text/value按字面读取，空串优先且合法；target、安全语义、remote schema、submit策略未改变。
- WM2 普通刷新走用户owner门禁后的原WKWebView.reload，编辑地址仍走typed navigation；完整query/hash留在WK请求，public snapshot/tab list继续脱敏。probe在目标请求发出前取消网络，证据边界是接线/请求目的地，不是外站加载成功。

实际GREEN待Root统一执行；无自动接管agent owner、新URL镜像或重试机制。

## T1 本轮终态报告归属 — PASS，无阻塞发现

检查了 phase5-t1-changedpaths.txt 所列的 service/control、Host 两个终态入口、foreground composition、background VM consumer 与新增职责测试；并在 Root 通知 Chat/KMP/T1 最终全冻结后，确认最终 runDisplayBaseline field 的 handoff、runtime hydration、codec 与 terminal writer 接线。未将同文件 C1/C2 和原模块化 WIP 误算为 T1。完整 baseline 持久化 owner 的独立检查由 Storage reviewer 承担，本报告聚焦报告投递边界。

服务/control 使用显式 displayBaseline 调用既有 generatedMessages 投影，只有本 run 的 assistant 可作为 FINAL_ANSWER 正文。长报告引用也从该 runMessages 范围选择同一 assistant message，conversation_id 仍是 child，message_id 不会退回旧轮历史。terminal_status、terminal_reason 随捕获的 runId 传递，短正文和无正文都携终态 JSON；原 final-<runId> enqueueIfAbsent 幂等保持。nil baseline 只保留已提供 scoped transcript 的直接调用兼容；两个真实生产 consumer 均明确传 baseline。

前台 Host 在 clearRunIdentity 前捕获 full terminalMessages 与原 displayBaseline，两者沿同一异步 callback 传出，避免 identity 清空及下一轮启动改变报告边界。composition 与 VM consumer 不读当前 UI 会话来推断归属；终态原因按捕获的 runId 查 durable snapshot。现有实际 consumer 测试在 UI 已切父会话时仍检查 child report/status/reason，覆盖真实接线。

后台最终使用单一 immutable job.runDisplayBaseline，与当前轮 displayMessages / uploadMessages 分开。Host 的 handoff builder 从原 displayBaseline 设置该 field；current-display 刷新、continue-after-response、payload 编解码与 runtime hydration 都保留它；显式空数组经 ?? 仍为空，只有旧 missing/null payload 使用原先 display checkpoint 的兼容边界。terminal writer 和 archive 在调用 callback 前都取 job.runDisplayBaseline，随后 VM/service 不再以交接时 display 长度裁掉本 run 已生成的 partial。

已读取 phase3-final-boundaries-red-summary.json 中真实 testCancellationAfterHandoffDeliversPartialGeneratedBeforeHandoff 失败：交接时 partial 被误算进旧 baseline。最终测试明确验证原 baseline 不含 partial、full transcript 仍含 partial、generatedMessages 恰为该 partial、父 mailbox 含当前 partial 且无旧报告、终态 cancelled、保存不重复。该回归与原无输出取消、正常完成、长报告/幂等控制共同覆盖本次真实边界；没有用字符串启发式或新增报告缓存代替身份信息。

Root 已提供原 foreground/background 各两项以及 service/实际 consumer 六项的 GREEN 证据；新增 handoff partial 回归及最终 field 接线仍以 Root 本轮集成构建和最终 GREEN 为准。本审查没有运行测试，也不声称真实 provider、跨进程恢复或物理设备验收。

建议最终重点 selectors：IOSOrchestrationTerminalOwnershipTests、IOSChatForegroundTerminalBoundaryTests、IOSChatBackgroundTerminalBoundaryTests、IOSOrchestrationListInterruptTerminalTests，并带既有 IOSChatKernelRunHostTests / IOSChatKernelRunHostHandoffTests / IOSChatBackgroundExecutionTests。
