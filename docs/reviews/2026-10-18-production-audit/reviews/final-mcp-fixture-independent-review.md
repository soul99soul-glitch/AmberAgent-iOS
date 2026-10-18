# MCP 并发过期 fixture 独立二次 review

结论：**PASS，无已确认 blocking findings。** 本 reviewer 未参与该修改；对照 `IOSMcpClientTests.concurrent-expiry-task-before.swift` 与当前文件，读取冻结实现/诊断说明和必要的 Manager/Client 实际入口；未修改源码或测试，未构建、运行测试或操作设备。另请 audit_kmp 做同范围只读 peer，结论一致。Root 后续实际定点与 suite 结果仍是运行门禁。

## 改动归属与原失败判定

相对 task-before，本轮只有一条并发过期测试改为既有 clientFactory 注入，以及一个该测试专用 private `IOSMcpClienting` fake；没有修改生产 Manager/Client、共享 HTTP fake 或其余测试。

原 HTTP fixture 按全局请求进入顺序取 response，并为两个 tools/call 404 预留固定位置。20ms 延时不能证明第二 Task 已进入 client：如果第二调用尚未抵达，第一次恢复的 initialize 会消费原本给第二 tools/call 的 404。实际 Client 的 validate 对携 session 请求的 404 抛 mcpSessionExpired，对不带 session 的 initialize 404 才抛 httpStatus(404)。因此现有 plain404 证据与 fixture 的请求/响应错配机制一致，不能据此给生产新增 404 重试或修改 readOnly replay 策略。诊断未保存原失败请求顺序，对那一次运行的精确时序仍是代码支持的解释，不应写成已逐请求观测的事实。

## 新 fixture 的有效覆盖

`ConcurrentExpiredMcpClient` 使用现有 MainActor-isolated 协议；计数和 continuation 集合在同一 actor 上访问。前两个 callTool 各挂起；只有两者都已实际进入时才清空集合并各 resume 一次 mcpSessionExpired。因此不再用 Task 创建时间或 sleep 猜测“两个旧调用都过期”。初始 syncAll 已完成后才创建两个 Task，首次挂起不会注册 recovery，第二调用可进入同一 fake；当前依赖图没有互相等待的环。

全部原业务断言保留在相应客户端边界：

- outputs 排序后必须为 fresh-a/fresh-b，恢复重放仍使用各自 q 参数。
- connect=2：初连加一次恢复；listTools=2：初次目录加一次刷新。
- callTool=4：两个过期调用加两次只读重放。
- disconnect=1，Manager 最终状态 connected。
- 额外 initialExpiredCallCount=2 明确证明两个原始调用均走过期分支。

fake 返回的工具继续显式 readOnlyHint=true，实际经过 Manager 的恢复及只读 replay 逻辑；没有直接生成 Manager 状态、跳过恢复、吞错误或放宽计数。单一 server/docs 对应单一注入 client，因此 disconnectCount 与原 docs client 断开断言的归属一致。

## 调度边界的二次反证

当前 Manager 没有捕获调用开始时 observed session generation 的快路径：callToolOutput 的 catch 只传 server/client，recoverExpiredSession 通过已注册 task 共享恢复；sessionRecoveryGenerationByServer 用于当前恢复 owner 校验与失效。

新 fake 同时释放两个 expiry，但 connect/listTools 不人为挂起恢复。若一个 catch 极晚处理、越过第一次恢复 registration 的注销，第二次恢复会使 connect/list/disconnect 计数失败。**这不会形成假绿或掩盖缺少第二次过期调用；通过时当前严格计数能证明本次只发生一次恢复。** 当前没有该新 fixture 实际出现此失败的证据，仅凭理论 job 重排不足以要求新增 gate、状态或生产修复；如 Root 定点/全 suite 真出现该问题，先核对实际请求顺序与生产 Client 可达性，再判断是否需要收紧 fixture，不能预先把失败归为假红或直接改 Manager。静态 review 不声称验证所有调度下的稳定性。

## 保留的真实 Client 集成证据与设计范围

task-before 对照确认下列真实 Client + HTTP transport 测试未动：

- testConcurrentCallsAreSerializedPerClient：maximumConcurrentRequests 必须为 1。
- testConnectHandshakeCannotBeInterleavedByToolRequest：initialize、initialized notification、tools/list 顺序严格匹配。
- session header 捕获/清理、携 session 404 分类、只读恰好重放一次、mutation/unknown-safety 不重放及串行多次 session expiry 的测试仍保留。

新增约 40 行 private fake 只表达该 Manager 测试的进入屏障与结果计数，未增加共享脚本框架、sleep/yield/retry 或依赖，不属于过度设计。它验证 Manager 合并恢复，不替代真实 HTTP/FIFO/handshake 测试，更不构成真实 MCP 服务或物理设备验收。
