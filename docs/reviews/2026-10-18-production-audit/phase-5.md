# 第 5 阶段：工具编排与 WebMount

T1、T2、WM1–3 的修复与独立源码复核已完成，结论为 **PASS，无阻塞发现**。[整体独立 review](reviews/phase-5-independent-review.md) 包含 T1/T2 的逐项检查，并整合了基于任务前快照完成的 [WebMount 专项复核](reviews/phase5-webmount-independent-review.md)。未将原有模块化 WIP 当作本轮改动。

T1 修复子代理终态报告的归属：新一轮尚未输出便取消时，父线程收到真实终态，不再把上一轮 assistant 报告标为新 run 的 `FINAL_ANSWER`；本轮已有 partial 时保留该 partial。短报告、无输出和长报告均传递终态状态；长报告的 `session_read` 引用指向本轮 child message，投递仍按 runId 幂等。

这要求保留**原始 run 基线**，不能使用交接后台时的当前轮消息作为边界。交接前生成的 partial 已在当前 display 中，却仍属于同一 run；若按交接时 display 的长度裁剪，它就会被错误排除。Host 从既有 `displayBaseline` 捕获原始边界，handoff、KMP payload 编解码和后台 runtime 以独立的 `runDisplayBaseline` 携带它，当前轮 display/upload 继续负责请求与流式累积。显式空基线保持为空；旧 payload 缺少该字段时保留原有 checkpoint 兼容行为。

前台终态在清除 run identity 前捕获基线与完整 transcript；后台 writer/archive 使用同一原始基线。两个真实 consumer 按捕获的 child/runId 转发消息与 durable 状态、原因，mailbox owner 再据此选择本轮输出，不依赖当前 UI 会话、最后一条 user 消息或字符串前缀推断。共享层的字段契约与 Swift 消费入口一起验证，未将 KMP 测试当作原生接线的替代。

其余修复保持在原职责内：

| 问题 | 最终行为与复核重点 |
| --- | --- |
| T2：Jev 提出无值或错误控件类型的 select | 缺少确定选项值的观察不再提出 select；mapper 拒绝 nil，原样保留空串、空白等明确值。直接 `wm_select` 保留，旧 replay 与模型选择仍须匹配当前合法候选。 |
| WM1：重启丢失多个持久 local session | 在总容量内恢复多个 local 及有效 current ID，保留至少一个 local 的槽位规则。旧 owner/lease 清理、`needsReopen` 与不自动导航规则保持。 |
| WM2：刷新使用脱敏 URL | 普通刷新经用户控制权检查调用当前 WKWebView 原生 reload，保留实际 query/hash；编辑地址仍提交用户输入。公开 snapshot/tab list 继续脱敏，不抢占 agent owner。 |
| WM3：desktop 输入被 trim，空串无法清空 | 仅 text/value 按字面传递，保留前后空白、换行和空串；target、安全门、remote schema 与提交策略保持。 |

实际验证已覆盖服务、前台 Host、后台 coordinator/writer 和两个真实 consumer，包括：无新输出取消、本轮 partial 取消、交接前 partial 后台取消、正常完成、长报告引用、重复回调幂等，以及 UI 已切换到父会话时仍将结果归到原 child。T2 与 WebMount 的候选、会话重启、字面输入和实际 WK reload 目的地回归也已通过。

[本轮聚焦测试摘要](phase3-phase5-focused-green-summary.json) 记录 304 项执行、302 项通过、2 项失败、零跳过。T1/T2/WM 相关测试在该轮实际通过；两项失败分别为 Chat 的冷启动 unknown-ledger 恢复与 cached continuation handoff，由 Chat 阶段继续收口，因此该摘要的整体结果仍为 Failed，不能称全轮绿色。原缺陷的失败证据保留在 [工具边界 RED](pending-domains-red-summary.json)、[持久会话与输入 RED](future-domain-red-summary.json) 和 [handoff partial RED](phase3-final-boundaries-red-summary.json)。KMP payload 基线的独立值、显式空值与旧格式解码控制见 [共享层验证摘要](shared-baseline-green-summary.json)。

最终消费方与主 App 组合的实际结果统一见 [verification.md](verification.md)。WK reload 测试证明接线及请求目的地，未声称外网站点加载成功；上述测试与源码复核也不替代真实 provider、进程终止恢复或物理设备验收。
