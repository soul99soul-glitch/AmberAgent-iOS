# MCP concurrent expiry fixture 精确修复（冻结）

生产结论与证据见 `mcp-concurrent-expiry-diagnosis.md`。Root独立复核同意本次plain HTTP404由fixture固定全局响应顺序导致，未授权也未修改生产client/manager恢复逻辑。

## 所有权与保护

仅修改 `iosApp/iosAppTests/IOSMcpClientTests.swift`。修改前完整原文件已保存为：

`/tmp/amber-audit-20261018-current/IOSMcpClientTests.concurrent-expiry-task-before.swift`

对task-before与当前文件逐项比较，本轮仅替换一条并发恢复测试fixture和增加一个该测试专用private IOSMcpClienting fake；其他WIP、HTTP fake、真实client序列化/handshake测试均未动。未构建、运行测试或触碰设备。

## 改动

`testConcurrentExpiredCallsShareOneReconnectAndRefresh` 使用现有manager `clientFactory` 注入 `ConcurrentExpiredMcpClient`。两个原session调用各进入checked continuation，**只有两个调用都已实际进入**才一起释放 `.mcpSessionExpired`；不靠20ms延迟、Task.yield或全局HTTP响应顺序。

恢复后的重放按原q返回fresh-a/fresh-b。原有效语义断言全部保留在对应client边界：

- outputs sorted = fresh-a/fresh-b；
- connect=2（初连+唯一恢复）；
- listTools=2（初次目录+唯一刷新）；
- callTool=4（两个真实进入的过期调用+两次只读重放）；
- disconnect=1；
- Manager最终connected。

额外显式断言 initialExpiredCallCount=2，避免测试在只有一个旧session请求时仍声称覆盖并发过期。

没有更小的现成fixture可直接复用：已有 `RecordingMcpClient` 只录调用、`SuspendingRecoveryMcpClient` 永远抛expiry且服务能力关闭/配置改变测试依赖其独立connect gate。为了不改变这些既有契约，新增一个窄private fake，而不是给共享HTTP fake新增method/session脚本框架。

## 有限维护性检查

按code-simplifier完成一次本轮有限检查：barrier状态仅在test fake内、初次两个调用与后续重放分界清楚，无sleep/yield/retry或断言放宽。task-before diff只含预定范围，`git diff --check` 无输出，文件当前1135行（低于1500）。

Root后续先原样或定点运行 `iosAppTests/IOSMcpClientTests/testConcurrentExpiredCallsShareOneReconnectAndRefresh`，再跑 `IOSMcpClientTests` / `IOSMcpManagerTests`；本组未自行执行，不宣称green。
