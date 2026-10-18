# MCP queued recovery 本轮改动独立只读复核

结论：**PASS，未发现需要修改的具体问题。**

范围固定为 `mcp-queued-recovery-owned.diff`：IOSMcpClient.swift 的 reconnect 协议要求、共享握手方法与两个入口；IOSMcpManager.swift 的 session recovery 调用；IOSMcpClientTests.swift 的 triple 回归观察器。对照旧红测试 `IOSMcpClientTests.queued-recovery-actual-red-before.swift`。没有改源码或测试，没有运行构建、测试、设备或调试命令；没有扩大审查。本文的 PASS 是源码与测试契约判断，实际运行结论由 Root 统一提供。

## Standards

0 项 actionable finding。

- 会话替换由持有 request slot 的真实 client 所有者完成，Manager 不再跨层清除正在服务排队请求的 client config。没有在 Manager 增加另一套请求队列、重试或新状态机。
- `establishConnectionWithoutRequestSlot` 从原 connect 握手局部提取，普通 connect 与显式 reconnect 两条路径共享相同的 reset/initialize/initialized notification；没有重复两份协议握手逻辑。
- 新的测试观察包装器仅保留恢复入口的观测，所有工具请求、握手和 transport 都仍由真实 IOSMcpClient 执行。Mirror 读取队列只用于建立 B/C 已真实排队的前置条件，不改变生产逻辑。
- owned diff 没有回退既有 WIP、删除现有有效断言、放宽超时或把失败改成 skip。

## Spec

0 项 actionable finding。

### 1. reconnect 是协议 requirement，真实 override 可动态分派

`IOSMcpClienting` 在 IOSMcpClient.swift:634 声明 reconnect requirement；extension:642 提供默认实现；真实 `IOSMcpClient` 在 :677 自己实现相同签名。Manager 的 existential `client: IOSMcpClienting` 在 IOSMcpManager.swift:435 调用 requirement，因此走 witness dispatch，真实 client 不会错误落到 extension 的 disconnect/connect 默认实现。

默认实现保留原 Manager 对简单 fake/conformer 的 disconnect→connect 行为。当前测试里的 ConcurrentExpiredMcpClient / SuspendingRecoveryMcpClient 不必新增生产式 slot 层，也能保留原 connect/disconnect 计数与挂起控制。不能因为默认实现没有真实 client 的队列就推断当前生产路径仍然提前 reset；真实 override 已由 requirement 分派闭合。

### 2. 真实 reconnect 的 slot 覆盖 reset、initialize 和 notification

IOSMcpClient.swift:680 在获取 slot 后才进入 establishConnectionWithoutRequestSlot。共享方法 :685-702 内依次执行旧 transport disconnect、status/config/sessionID reset、initialize、notifications/initialized 与 connected 状态更新；这些操作全部位于同一次 withRequestSlot 的 operation 中。调用的是 WithoutRequestSlot 方法，避免递归排队/死锁。等待中的 reconnect 尚未获得 slot 时，不会再把 B/C 使用的 config 清成 nil。

普通 connect :668-674 保留同 status/config 的早返回；显式 reconnect :677-682 故意绕过复用判断，确保过期但配置相同的 session 仍重新握手。这与 `testConnectReusesExistingConnectionForSameConfig` 的契约兼容。

Manager recovery 的 coalescing/owner validation/readOnlyHint 判定未被改动。本轮只用 client.reconnect 代替 Manager 的提前 disconnect+connect。

### 3. 新 triple 回归仍能覆盖旧 Manager 失败，不是只适配新实现的绿色测试

新测试 :394-404 仍以真实 requestWaiters 集合的两个条目确认 B/C 已入队；A/B 的 HTTP gate 与旧红测试相同。改变的是等待条件：修复后断开旧 session 应发生在 B/C 排队请求结束后，所以不能继续要求 B held 时已经 disconnect。

`RecoveryObservingMcpClient` 同时观测两个入口：

- 新 Manager 调 reconnect → wrapper:1202-1204 先记录恢复请求，再完整转发真实 client.reconnect。
- 旧 Manager 仍先调用 wrapper.disconnect（:1219，直接转发真实 disconnect 清 config），再调用 connect。wrapper:1194-1199 在第二次 connect 记录同一个恢复请求，然后转发真实 connect。因此，恢复旧 Manager 后，新测试等待 `recoveryRequested` 得到满足时，旧路径的提前 disconnect 已经实际发生。

随后释放 B，C 仍会在旧路径的 nil config 上失败；新测试 :417-420 要求三调用全部得到 fresh 输出，:425-430 还要求三个查询都各自发送一次旧 session 请求和一次新 session 请求，故 C 在 transport 前失败不能被隐藏。保留的单次 disconnect、单次 recovery request、两次 initialize/list、initialize 无旧 session header、最大并发请求为 1 等断言没有被删减。

这说明新 fixture 对旧 Manager mutation 仍有真实失败敏感性；本 reviewer 未执行该 mutation 运行，不将源码推演另称为一轮已运行 red。

## 交付边界

本轮源审 PASS；Root 已告知此前原真实 triple 测试取得 actual red。本 reviewer 没有独立重复构建/测试，最终 green、旧 Manager mutation 实测若执行，以及冷进程证据均以 Root 产物为准。没有新增待修问题。
