# MCP concurrent expiry 全量失败只读诊断

结论：**本次 `httpStatus(404)` 的具体失败机制属于测试fixture的全局响应顺序假设，不能据此认定生产Manager的合并恢复失败。** 单独原样重跑仍有价值；若要确定本次实际请求顺序，需在失败时保存 `transport.sentMethods` / `sentRequestHeaders`，现有日志未包含它们。没有构建、运行测试、修改源码或触碰设备。

## 已核查证据

- 全量日志 `final-main-green.xcresult/Staging/.../StandardOutputAndStandardError.txt:6780-6782`：`testConcurrentExpiredCallsShareOneReconnectAndRefresh` 在测试:368等待两个Task结果时抛 `httpStatus(404)`，耗时0.044秒。失败发生在后面的请求计数断言之前，日志没有sentMethods序列。
- `IOSMcpClientTests.swift:336-362` 使用全局响应数组：初始化、list、**两个tools/call 404**、再次初始化、list、fresh-a/fresh-b；tools/call延迟20ms。
- `FakeMcpHTTPTransport.sendJSONRPC` :1012-1018 在请求进入transport时立即 `responses.removeFirst()`，随后才delay。它只保证“已发出的请求与响应绑定”，**不保证下一次请求的method**，也没有根据method/session做routing或显式并发barrier。
- 生产 `IOSMcpClient` :942-977 每client FIFO串行。`connect` :661-683 也在同一slot内，initialize与initialized notification不可被工具调用穿插。已有 `testConcurrentCallsAreSerializedPerClient` 明确要求最大并发请求为1。
- `IOSMcpManager.callToolOutput` :235-243 在进入client之前可能await sync；若已存在session recovery，则等该task。恢复error仅捕获 `.mcpSessionExpired`（:264）。
- `IOSMcpClient.validate` :913-919 的404分类是决定性区别：**发出请求携带Mcp-Session-Id时只能抛mcpSessionExpired；不带session的404才抛httpStatus(404)**。initialize不带旧session（connect :671先清sessionID），普通已初始化tools/call则带server-issued session。

## 一条完全符合当前实现的失败时序

1. `syncAll` 已完成session-1 initialize/list。
2. first Task进入client，发tools/call，fake取第3响应（404），20ms后返回。
3. second Task尚未过Manager的await/尚未排入client slot。创建两个Task不承诺它们会在20ms内都到达client；MainActor在全量运行中的负载也不能作为同步机制。
4. first收到携session-1的404，正确转mcpSessionExpired。Manager注册唯一recovery task，disconnect后重新connect。
5. 新initialize是下一个到达fake的请求，因此取走全局第4响应——测试原本预留的第二个tools/call 404。initialize不带session ID，故正确抛出**httpStatus(404)**。
6. second若此时进入Manager，会等同一recovery task，并得到同一初始化失败。`:368` first.value抛错即结束测试。

如果第二个工具调用先已在transport发出，两次404都有session-1，才能消费fixture设定的两个过期响应。当前20ms sleep没有证明这个前置条件。把delay加长只降低概率，不修正契约。

## 真实影响与设计判断

- 在真实server上，initialize会获得自己的真实响应，不会从某个未发出的tools/call预设响应中取404。因此上述“初始化消费第二工具404”是fake产生的失败。
- 生产Manager在后发调用看到已有recovery时等待，是正确行为。该调度下第二调用可能直接使用新session，合理请求数为一个过期call加两个成功call；测试却固定要求两个原始call均已失败。不能仅因调用者创建Task相近就要求它们都使用旧session。
- 本诊断**没有**证明所有可能的排队/断开/旧session异常代次组合都正确；它只将本次plain404与确切fixture错配区分。也不建议基于这一日志给生产新增404重试、延时、兜底或改变readOnly replay限制。

## 最小后续方案（待Root原样复现后决定）

保留原来的业务断言强度：两次明确的旧session失败、一次恢复initialize/list、两次成功readOnly replay、一次disconnect。让这条“Manager合并恢复”测试用显式可挂起的 `IOSMcpClienting` fake：先确认两次原始调用均已进入，释放第一过期error并等待recovery connect开始，再释放第二过期error，最后释放connect/list。这样测试的是已定义的两个旧session失败共享一个恢复，而不是依赖20ms调度。

真实client的FIFO与handshake不可穿插继续由现有 `testConcurrentCallsAreSerializedPerClient` / `testConnectHandshakeCannotBeInterleavedByToolRequest` 验证；不要为迁就fake去改生产串行策略。如果保留HTTP集成fake，至少按method/session分配响应，并用明确的排队进入证据安排两个旧session请求，不能只把全局状态数组换顺序或增加sleep。

上述为方案，没有修改测试、放宽断言或添加retry。
