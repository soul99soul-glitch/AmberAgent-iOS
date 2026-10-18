# Phase 7 MCP-1 独立 review

结论：**PASS，无已确认 blocking findings。** 本 reviewer 未参与实现，仅审查 mcp-queued-recovery-owned.diff、两个实际生产 owner、指定真实三调用回归及既有相关边界；未改生产/测试、未构建或运行测试。另请未参与实现的 audit_kmp 窄范围只读复核 reconnect 动态分派、FIFO/cancellation 与 owner 边界，结论同为 PASS。Root 当前构建和后续实际 green 仍为运行门禁。

## 失败证据与修复归属

`mcp-queued-real-red-summary.json` 记录真实 `IOSMcpClient + IOSMcpManager` 回归失败：`Read-only call c failed during recovery: invalidResponse`。它与先前全局 FIFO 响应脚本产生 plain HTTP404 的设施问题不同，不能相互替代或合并归因。

旧真实路径是 A 持请求 slot、B/C 已在 requestWaiters 中排队；A 过期后释放 B，Manager 在 slot 外 disconnect 清掉 config，而恢复 connect 又排在 C 后。B 释放后，C 从旧 continuation 继续，尚未经过重新握手就读取 nil config，产生真实工具失败。该路径不需要假设恢复 Task 抢在已唤醒 B 之前运行。

本轮实际改动只涉及 Client、Manager 和同一测试文件；原同 run/Chat/后台及其他 WIP 不在此次 diff 内。没有把 invalidResponse 泛化为 expiry、增加重试或引入 observed-generation 状态。

## 生产边界检查

1. **协议动态分派正确。** reconnect(config:) 是 IOSMcpClienting 的 requirement，而非仅 extension 方法；Manager 经 existential 调用会分派到真实 Client override。extension 默认 disconnect+connect 只保留现有非排队测试 fake 的行为。当前生产 conformance 仍只有真实 IOSMcpClient，未新增 alternate 生产实现。
2. **同一个 FIFO slot 内重建。** real reconnect 先执行既有 withRequestSlot，再调用私有 establishConnectionWithoutRequestSlot。已有 B/C 先完成旧 session 请求；随后才断旧 transport、设置 config/connecting、清 sessionID、initialize、initialized notification、置 connected。helper 内不再取得 slot，不存在嵌套等待同一队列。
3. **普通 connect 契约未变。** status connected 且 config 相同仍直接复用；其他情况调用提取后的同一握手实现。payload、session capture、notification、错误传播均沿原逻辑，无第二份握手或新配置缓存。
4. **Manager 保持单一恢复 owner。** 仅去掉 FIFO 外的提前 disconnect，将 recovery 中 connect 改为 reconnect；recovery registration、ID/generation/client/config 校验、目录刷新、readOnlyHint 重放以及第二次 expiry 失败行为均未放宽。

## 死锁、取消与归属

三条旧调用在抛 mcpSessionExpired 回到 Manager catch 前，都会通过 withRequestSlot 的 defer 释放自己的 slot；它们随后等待共享 recovery task，没有持有 Client slot。恢复 task 排在已有 waiter 后，轮到它时没有依赖哪个旧调用先收到恢复结果，因此没有等待环。Manager 在 recovery 已注册时阻挡后续新调用，避免新工作无限插入既有恢复之前。

queued reconnect 复用原 acquireRequestSlot 的 cancellation handler，取消时移除对应 waiter 并 resume CancellationError；取得 slot 后再次 checkCancellation，所有进入 operation 的退出仍经 defer 释放。网络握手继续使用既有超时/取消 gate。能力禁用或配置替换仍取消 recovery，并由原 pre/post owner 校验阻止旧任务发布目录和 connected 状态；本轮未删除这些检查。

显式撤销/换配置时的 disconnect 仍是既有授权失效行为，不等于本次“session 自恢复误伤有效排队请求”，没有据此扩大成新的 generation 或取消状态机修复。

## 测试同步调整与断言

修复后的正确实现要求 disconnect 等待 B/C 释放。如果测试仍在释放 B 前等待 disconnect，就会把正确的原子边界变成测试死锁。改为观察 recovery 请求已发生是必要同步调整：RecoveryObservingMcpClient 仅记录请求后转发到同一个真实 Client，不拦截/修改错误、session、slot 或 HTTP 顺序。

wrapper 同时在旧 Manager 的第二次 connect 与新 Manager 的 reconnect 入口发相同信号；恢复旧 Manager 的提前 disconnect+connect 两行时，测试仍建立 B held、C 排队、config 已清的原始失败交错。它没有把旧红路径从新 fixture 中排除。

以下有效证据均保留或增强：

- 一次 Mirror 实值检查真实 requestWaiters 恰有 B/C 两项，而非以 task entry 当作入队。
- A、B 的真实 HTTP continuation gates；B held 与 recovery request 同时成立后才释放 B。
- a/b/c 分别必须返回 fresh-a/fresh-b/fresh-c。
- initialize=2、list=2、call=6；session-1 和 session-2 各覆盖 a/b/c，initialize 不带 session。
- 真实 disconnect=1、HTTP 最大并发=1、Manager connected；额外 recoveryRequestCount=1。
- disconnect expectation 仅移到结果之后，未删除真实断开断言。

fixture setup 不满足时仍明确报错并 cancel/release/drain，不作为产品失败继续推演。原 default-fake 并发恢复、普通 connect 复用、串行多次 expiry、mutation/unknown safety 不重放、能力禁用/配置改变失效及真实 Client FIFO/handshake 测试仍保留，未弱化期望。

## 设计与验收边界

独立 reconnect 入口表达“替换会话”与普通 connect 复用的真实差异；私有握手提取避免两处协议字段漏改，沿用同一个已有 FIFO。test-only observer 只补 transport 无法观察的恢复请求信号，没有形成共享脚本框架。当前范围未见过度设计。

Root 应实际运行新三调用回归及 IOSMcpClientTests / IOSMcpManagerTests，并由构建验证全部 protocol conformer；本审查不把源码 PASS 或旧失败证据当新 green，也不代表真实 MCP 服务/网络或设备验收。
