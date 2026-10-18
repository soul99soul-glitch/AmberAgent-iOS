# MCP real Client queued recovery boundary — actual-red pending

## 当前判断

原 `testConcurrentExpiredCallsShareOneReconnectAndRefresh` 的 plain HTTP404 属于全局固定响应队列的 fixture 请求次序竞态，修复报告与本候选独立。新 Manager fake 测试只覆盖 single-flight recovery 合并，不宣称证明真实 Client 的 HTTP FIFO 生命周期。

“两调用时已 resume 的 B 会被 recovery R 抢先清 config”仍不足以确认：Client 整体是 MainActor，不能仅用普通 actor mailbox 非 FIFO 证明该重排。Swift 6.1 cancellation/continuation API 继承 isolation，continuation 恢复没有必经 generic executor 的规则；实际 Apple MainActor 实现提交到 main dispatch queue。因此不以 task priority、20ms 或 Task.yield 制造这个猜测。

同一边界的三调用路径可以从当前源码闭合，并已由 audit_miniapp 独立反证，但尚未运行新回归，故仍不计新增已确认产品缺陷。

## 三调用源码路径

1. A 已在真实 IOSMcpClient 的 HTTP transport 中持有 request slot。B、C 已通过 IOSMcpManager.callToolOutput 的 recovery 检查（IOSMcpManager.swift:241），并在该 Client 的 requestWaiters 中等待。
2. A 的旧 session 请求返回404，validate 在 IOSMcpClient.swift:916 抛 mcpSessionExpired。withRequestSlot 的 defer 在 :944/972 释放 B，原队列尚有 C。
3. B 获得 slot，sendWithoutRequestSlot 在 :846–858 捕获旧 config/requestConfig，随后等待 transport。
4. A 在 Manager :264 进入 recoverExpiredSession，创建 R。R 在 :427 同步 client.disconnect；Client :830–836 清 config/sessionID。R 的 connect 在 :662 也必须获取相同 slot，因此排在 C 后面。
5. B 的 HTTP 返回404并释放 C。C 从原 Client continuation 继续，不会重新经过 Manager :241。C 在 Client :846 读取 nil config，抛 invalidResponse；它释放 slot 后 R 才能开始 initialize。
6. Manager 仅对 mcpSessionExpired 恢复（:264），因此 C 直接失败，而 A/B 可在唯一恢复完成后只读重放成功。

此路径不需要假定 R 比已唤醒 B 更早运行。只要 B 在等待 HTTP 时 R 得到执行，C 在队列中就位于 R.connect 前。若 R 在 B 的 transport operationTask 之前运行，B 也已经捕获 requestConfig 并持有 slot，结论相同。

这不是用户取消：没有调用 Task.cancel、禁用能力或移除 server。URLSessionMcpHTTPTransport.disconnect (:317) 只关闭/移除 Legacy SSE 容器，不取消 streamable HTTP 的 B URLSession 请求。工具调用入口在 ChatLocalToolOperations.swift:487；共享 runtime 的子代理 MCP adapter 在 ChatAdvancedToolOperations.swift:355–429 使用同一个 self.mcpManager，子代理可并发运行（:41–50，上限10）。失败会在 ChatLocalToolOperations :494 转为用户可见 tool failed。

## 既有测试边界

- 真 Client 并发串行化测试 testConcurrentCallsAreSerializedPerClient 只验证 maximumConcurrentRequests=1。
- 真 Client 握手不可交错测试 testConnectHandshakeCannotBeInterleavedByToolRequest 不覆盖外部 disconnect 与已有 waiter。
- disconnect 测试无持有中 HTTP/queued waiter。
- 新 ConcurrentExpiredMcpClient 是 Manager boundary fake，无真实请求 slot。
- SuspendingRecoveryMcpClient 覆盖配置/能力改变时恢复 owner 失效，不覆盖真实 Client 队列。

## 新回归与唯一修改范围（已冻结）

文件：iosApp/iosAppTests/IOSMcpClientTests.swift。
Selector：iosAppTests/IOSMcpClientTests/testQueuedCallsRecoverWhenSessionExpiresAheadOfThem。
测试修改前完整快照：/tmp/amber-audit-20261018-current/IOSMcpClientTests.real-client-boundary-task-before.swift。

使用真实 IOSMcpClient + IOSMcpManager，现有 clientFactory 注入同一个真实 Client。新增一个专用 GatedExpiredMcpHTTPTransport，响应按 method/session 构造，JSON-RPC id 使用实际 request id；不使用全局响应 FIFO。

顺序是 A 真实 HTTP continuation gate → B entry expectation → C entry expectation → 一次 test-only Mirror 实值观察真实 private requestWaiters.collection.count==2，才释放 A。Root 已明确授权这个一次性私有同步观测；它不增加生产 API/access control。若字段改名、类型不是 collection 或 count 不是2，明确报 Fixture setup failed，cancel 三调用、释放 held continuation 并 await 所有 result；不会兜底成0后继续。

随后同时等待 B 真实 HTTP continuation 已持有、recovery disconnect 已发生，再复核 B 仍 held 且 disconnect count1，才释放 B；若 setup 未成立，同样清理退出。产品断言逐个检查 a/b/c 分别得到 fresh-a/fresh-b/fresh-c，再验证 initialize2、list2、call6、旧/新 session headers 各覆盖 a/b/c、initialize 不带旧 session、disconnect1、HTTP maximumConcurrentRequests1 和 Manager connected。用结果逐项断言，避免 C 失败时提前 throw 而遗漏计数/header 证据。

未引入 sleep/yield、宽松断言、retry 或生产保护。未改旧 fake 并发测试、真实 HTTP 串行/握手测试或任何生产代码。

## 有限维护性检查与验证

按 code-simplifier 只检查本次新增 test + dedicated transport：gate 状态都在专用 test transport，响应路由独立于请求完成次序；private Mirror 只作建立交错的同步证据，setup失败有明确诊断与资源清理。相较 task-before 文件只有两处插入（测试76行、fixture87行），原改动均保留。

当前文件1298行，sha256 0aed0b754c5c669f48129888b6883709142e1537593ea0b865400b5e30019a51；git diff --check 无输出。本 agent 未构建、未运行测试、未触碰模拟器/设备。Root 统一 build/run 取得 actual red 后才可确认此产品问题。

若 actual red 确认，最小修复职责应让同一 Client 的恢复 reset + initialize 都处于现有 request FIFO 内，沿用 Manager single-flight 与只读重放契约；不要把任意 invalidResponse 当 session expiry 泛重试。

## Swift 官方语义参考

- Swift 6.1 withTaskCancellationHandler isolation: https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/Concurrency/TaskCancellation.swift#L49
- Swift 6.1 withCheckedThrowingContinuation isolation: https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/Concurrency/CheckedContinuation.swift#L347
- continuation resume executor: https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/Concurrency/Task.cpp#L1513
- Apple MainActor dispatch enqueue: https://github.com/swiftlang/swift/blob/swift-6.1-RELEASE/stdlib/public/Concurrency/DispatchGlobalExecutor.cpp#L364
- global actor protocol inference: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md#global-actor-inference
