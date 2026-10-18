# MCP-1：queued calls 与 session recovery 原子边界修复（实现冻结）

## 真实失败与范围

Root 已运行真实 IOSMcpClient + IOSMcpManager 三调用回归并取得 exit65。`mcp-queued-real-red-summary.json` 中明确为：`Read-only call c failed during recovery: invalidResponse`。真实 failing 结果保留在 `/tmp/amber-audit-20261018-current/mcp-queued-real-red.xcresult`，未删除、覆盖或改动。

此问题正式记为 MCP-1；此前 fixed FIFO fake 引起的 plain HTTP404 属于独立 fixture 竞态，仍不计产品缺陷。

用 rg 确认实际生产路径仍为 `iosApp/iosApp/IOSMcpClient.swift` 与 `iosApp/iosApp/IOSMcpManager.swift`，并无 Services/MCP 迁移。只改这两个生产文件及已归本任务的 `iosApp/iosAppTests/IOSMcpClientTests.swift`，未改共享 Chat/Background 或其他 WIP，未构建、测试或操作设备。

修改前完整字节快照：

- `IOSMcpClient.swift.queued-recovery-task-before`（SHA256 f28b7012040d150ab8bad65ac44fdf4f37ff8ccc4a18e8247e6a90e8180b04c1）
- `IOSMcpManager.swift.queued-recovery-task-before`（115de993d0f2555c47b1d65634d0d692837f925754330130ca479ba56c76eefe）
- `IOSMcpClientTests.queued-recovery-actual-red-before.swift`（0aed0b754c5c669f48129888b6883709142e1537593ea0b865400b5e30019a51；正是实际失败时的原测试字节）

全部快照位于 `/tmp/amber-audit-20261018-current/`。精确本轮 diff：`mcp-queued-recovery-owned.diff`，以这些快照为基线，避免混入早先 fixture 修改或用户 WIP。

## 方案比较与选择

1. **Client 提供 owner 级 reconnect，将 reset + replacement handshake 放在同一现有请求 slot 内。采用。** 现有 B/C 可先完成旧 session 请求，随后 R 再重建会话；Manager 沿用 single-flight、目录刷新和只读重放规则。这直接修正原先跨越请求队列的副作用。
2. 让普通 connect 增加 force 参数：同样可表达，但会改变所有 conformer 的既有 connect 签名；或再保留 overload，增加接口歧义。独立 reconnect 语义更直接，并保持原 connect 的复用契约。
3. 对 invalidResponse 增加重试、把 config 读取结果猜成 expiry、在 Manager 等待队列 drain、增加 generation/延时/取消兜底：不采用。它们无法准确归属恢复的 reset，且扩大错误分类或新增重复状态。

## 精准实现

`IOSMcpClienting` 在 Client 文件中增加 **required** `reconnect(config:)`，并记录 queued request 契约。必须是 protocol requirement，才能让 Manager 持有的 existential 动态分派到真实 Client override；仅在 extension 增加同名方法会错误地调用默认实现。

协议 extension 默认 reconnect 仍是 `disconnect()` + `connect(config:)`，用于保留所有现有非排队 fake/alternate client 的原调用契约。所有其他 conformer 都是测试 fake，均无需改签名；原 ConcurrentExpiredMcpClient 的 connect2/list2/call4/disconnect1 断言继续覆盖默认行为。

真实 `IOSMcpClient.reconnect` 在 **一个** `withRequestSlot` 中调用 `establishConnectionWithoutRequestSlot`。它会先排在已有 B/C 后面，再断开旧 transport、设置 connecting/config、清旧 sessionID、initialize、notifications/initialized、设置 connected，全程持有同一个 slot。没有重入 withRequestSlot，也没有第二套锁/队列/恢复状态机。

普通 `connect` 保留原来 status connected 且 config 相同时立即 true 的语义；其他情况复用同一个私有 handshake 实现。这个提取只为避免 connect/reconnect 两处握手漏改，旧 handshake 的 payload、session capture、notification、错误传播与 status 行为均保留。

`IOSMcpManager.recoverExpiredSession` 仅移除 FIFO 外的提前 client.disconnect，将原 connect 调用换为 required reconnect。原 recovery owner 校验、single-flight、工具目录刷新、只读安全注解和仅对明确 mcpSessionExpired 重放的行为均保留。

## 测试 barrier 为何必须调整

实际旧红测试的顺序是：A HTTP held → B/C 确已排队 count2 → A404 → B HTTP held + recovery **已 disconnect** → 释放B。旧实现此时队列为 `[B active, C, R.connect]`，config 已 nil，C 必然失败。

正确修复后，disconnect 本应等 B/C 结束后才发生。如果仍要求 disconnect 先于释放 B，就会把正确互斥实现卡死。因此 Root 授权只将建立交错的第二信号从 observed-disconnect 改为 observed-recovery-request；不是删减行为断言。

新 `RecoveryObservingMcpClient` 是纯 test-only forwarding client，内部仍由同一个真实 IOSMcpClient 执行全部 slot、HTTP、握手、输出解析。它在旧 Manager 的第二次 connect 入口及新 Manager 的 reconnect 入口记录相同 recovery request 信号。等待该信号与 B HTTP held 成立后才释放 B。真实 Client 的 private queue 实值 count2、A/B transport continuation gates、method/session 动态响应、三调用分别 fresh-a/b/c、initialize2/list2/call6、旧新 session 各 abc headers、initialize 无 session header、disconnect1、最大并发HTTP1、最终connected全部保留；额外断言 recovery request1。disconnect expectation 移到调用结果之后，继续观察真实断开。

旧实现仍红的明确路径：保留新增 reconnect 协议/Client override以编译新测试，但恢复 **旧 Manager** 的两行（提前 disconnect + connect）时，observer 从第二 connect 发信号；B 仍 held，C 仍在真实队列中，config 同样已 nil，释放B后 C 仍进 invalidResponse。wrapper 没有拦截、转换、重试或重排任何真实请求。旧 failing test 的原字节及 .xcresult 已保留，未用改后的测试反推旧红。

## 有限维护性审查

已按 code-simplifier 对本轮 diff 做一次有限检查：重建 owner 明确位于真实 Client；唯一私有握手供两个语义明确入口复用；Manager 不再跨层分拆 reset/handshake；default implementation 保留现有 fake；observer 仅承担无法由 transport 观察的 recovery 请求同步，不介入恢复行为。没有与问题无关的重排、删除、fallback、retry 或性能改动。

同步等待的 fixture setup 失败仍明确报错并 cancel/release/drain 三任务，不把 setup 失败当产品红。

最终 `git diff --check` 无输出，文件长度均低于1500：

- Client 1198行，SHA256 `36ba2808ef264039b4e9e6f10756362eb936cfc19c328a37b48562ffe9e4a20a`
- Manager 660行，`72927d416aaa07677008ebf9af1de3b6fa7386de3703ff151e83f558ddb521cf`
- ClientTests 1341行，`7623267c489e7d7693e77b6fcb5cd528fed67f503cc0b40a0279aac807cfd401`

## Root 后续验证

本 agent 未自行 build/test，源码已冻结。建议 Root 先执行：

- `IOSMcpClientTests/testQueuedCallsRecoverWhenSessionExpiresAheadOfThem`：真实已确认回归应 green，完整 count/header 断言保留。
- `IOSMcpClientTests/testConnectReusesExistingConnectionForSameConfig`：普通 connect 复用契约。
- `IOSMcpClientTests/testExpiredSessionReconnectsAndRetriesExplicitReadOnlyToolExactlyOnce` 与 `testExpiredSessionReconnectsButNeverReplaysMutationOrUnknownSafetyTool`：只读/写/unknown safety 重放边界。
- `IOSMcpClientTests/testConcurrentExpiredCallsShareOneReconnectAndRefresh`、`testSequentialSessionExpiriesStartDistinctRecoveries`：协议默认 fake、合并与新一轮恢复。
- capability disable/config change recovery invalidation 两例、真实并发串行与握手不可交错两例。

这些均在 `IOSMcpClientTests`，再跑 `IOSMcpManagerTests` 覆盖普通 sync/目录/配置生命周期。其余协议消费者由 build 编译验证；未扩大到不相关测试。独立 source review 已委托 audit_miniapp 只读核对本轮 diff，报告将写 `mcp-queued-recovery-local-independent-review.md`，Root 另有独立 reviewer，实际测试结果由 Root 补充。
