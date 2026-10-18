# Tools 候选独立二次复核

2026-10-18。基于当前源码；只复核给定候选，无重扫、改码、测试或构建。读取 audit-tools.md、audit-webmount.md 后逐项追到生产 owner。MiniApp 由其他审查包负责，本次不声称完成 MiniApp 六项的独立复核。

## T1 Child FINAL_ANSWER 冒用旧轮 — ACCEPTED / P1

复核了 IOSOrchestrationControlCommands.notifyRunTerminal:548-629、IOSThreadOrchestrationToolService:1198-1214、IOSChatBackgroundTerminalWriter:767-794、IOSChatBackgroundGenerationCoordinator:708-762、ChatViewModel:1147-1160，以及前台 ChatRunComposition:283-298。

- 取消路径保存 full transcript 是正确且真实可达的：已有 child followup 的 job.displayMessages 含旧 assistant 报告，新一轮 provider 尚未发 assistant 时 cancel，latestMessages/cancelledMessages 原样含旧报告。
- mailbox owner 直接 lastAssistantText(finalMessages)，其选择没有 run boundary；terminalStatus/terminalReason 进入 service 后只用于 model routing，不进入 controlCommands 的 payload。所以 parent 收到新 runId 对应的旧报告，并且没有 cancelled 状态。
- 与其相邻的 archiveTerminalOutput 已通过 IOSSubAgentOutputProjection.generatedMessages(finalMessages:displayMessages:)（实作为 dropFirst(displayMessages.count)）只选择本轮产出。这是既有 seam，无需另建身份状态机。
- 前台 callback 同样交 full finalMessages 给相同 owner，故两条接线都需传本轮 baseline/boundary；不能仅在 background 修一下。
- by design 排除：保留历史 transcript 不等于把上一轮最后 assistant 标为新 run 的 FINAL_ANSWER；历史可读并不能替代 terminal status。

最小方案：owner 明确接收本轮生成消息（或 baseline 并复用既有 projection）与 terminalStatus/reason。无本轮 assistant 时发送当前终态简短结构化结果；有本轮 partial 仍带 cancelled/interrupted 状态。长报告引用从本轮生成消息选，不从 full transcript 选。保持现有 runId enqueueIfAbsent 幂等和 session_read 正文存储。

必需回归：旧 assistant + 新 user + cancelled，无新 assistant 时不含旧报告；有新 partial 时只含 partial 且标 cancelled；长本轮报告引用其新 messageId；前后台各验证边界接线。

## WM-1 多 local session 恢复丢失 — ACCEPTED / P1

复核了 IOSWebMountSessionStore init:247-258、newSession:411-437、persistSessions:820-846 与 init current ID 恢复:284-288。

- 创建与持久化允许多 local，默认容量3，持久化按 ID 确定排序。
- init 只恢复首个 local，剩余容量明确过滤 backend != local；第二个 local 既不进入 runtimes 也不进入 metadata。下一次普通 persistSessions 仅从内存 metadata 写回，因此不仅“本次没打开”，已持久化的第二个 local 元数据会被删掉。
- 同时 persistedCurrent 若指向被丢 local 失效，退到 ID 排序首个 local。
- by design 排除：注释的意图是 reserve one local slot 防 remote 挤掉唯一WKWebView；不是最多一个 local。现有 creation/switch/persist 接口没有 singleton 限制。

最小方案：先保留一个 local 预留，剩余容量从所有尚未选中的 persisted 项选取，不限定 remote。沿用静止恢复/needsReopen 规则，不自动导航，不改持久化格式。不在本次为未来容量缩小设计迁移策略。

必需回归：两个 persistent local，第二个为 current，重建 store 后两个 ID/current 保留且无 navigate；保留 remote-only 恢复时至少一个 local 的既有测试。

## T2 Jev select 无 value 且错误控件类型 — ACCEPTED / P2

复核了 IOSJevWebMountLoop.legalActionCandidates:714-734、ChatWebGoalTool.webMountLoopActionCall:229-258、local bridge:946-959、desktop mapping:260-268 以及 loop failed handback:686-689。

- 每个 combobox/listbox/checkbox/radio 都被生成 select(value:nil) 候选，且 action mapper 完全不读取 action.value、不给 wm_select 加 text/value。
- local 仅接受真实 SELECT，checkbox/radio 必然 target_not_selectable；SELECT 无 text 时默认空串，非空 options 匹配失败或意外选空占位。
- desktop 缺 values/value/text 必然 invalidArguments；loop failure 立即 handback，所以问题是可执行候选的语义错误，不是主模型能自动补值。
- by design 排除：直接 wm_select 本来支持确定值；fast loop 不能凭控件角色决定要选哪项。readonly/approval 边界不造成这个缺失。

最小方案：当前 observation 无可靠 option values，停产出 select 候选，把这类需要值/正确控件语义的动作交回主模型现有 wm_select/wm_click 路径；映射层不能为 nil value 产 wm_select。若保留 PlannedAction.select，应仅在有确定 value 的明确入口映射 text/value，不猜值、不扩展表单框架。候选“无可执行select”本身属正确保守收口，不需设计新的恢复机制。

必需回归：checkbox/radio 不变成 select；nil select 无工具调用；直接 wm_select 现有 value 行为保持。若方案是支持非nil select，断言值原样进入 payload。

## WM-2 刷新导航到 redacted URL — ACCEPTED / P2

额外复核了 WebMountSiteView:478-483、openTypedURL:1229、IOSWebMountRedactor:111-123。未聚焦时按钮文案是重新加载当前页面，但同样走 typed URL navigation；snapshot/address 来自有意去 query/fragment 的 redactedURL，故普通 search?q 丢查询。路径敏感redaction会变 /redacted。

最小方案：未聚焦按钮调用当前 runtime/网页原生 reload seam；聚焦时仍提交用户编辑地址。不要往模型snapshot/持久化补raw URL。回归实际请求/URL query+fragment保持与地址编辑导航。

## WM-3 Desktop type trim payload — ACCEPTED / P2

额外复核 IOSWebMountDesktopMapping:228-242，当前 string helper 经 nilIfBlank 将内容按标识符清理。wm_type 是内容payload，空串应能清空，本地 bridge 精确写入的既有语义与之矛盾。

最小方案：只在 type text/value 读 as? String，nil代表缺值、空串合法，保留其它标识符helper。回归空串、前后空格/换行、value alias实际remote参数一致。

## 复核结论边界

上述五项 ACCEPTED 均为当前源码可达、owner契约内的真实问题；未获得运行测试复现，Root应先用既有seam建立失败证据再修复。没有REJECTED或UNCERTAIN项需要追加探索。MiniApp与权限的独立复核不在此文档完成范围。
