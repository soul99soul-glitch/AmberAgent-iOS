# 阶段 7：最终组合暴露的 MCP 排队恢复边界

## MCP-1：真实故障与修复边界

三个并发只读工具调用共享同一真实 `IOSMcpClient`。A 已发请求，B/C 确认进入现有 FIFO；A 返回会话过期后，B 进入 HTTP 并被显式门闩保持。原 Manager 的恢复先在 FIFO 外 `disconnect()`，清空 Client 配置，再排队连接。C 排在连接之前，取到 slot 后读取到空配置，直接抛出 `invalidResponse`。它没有到达 HTTP，也不属于用户取消。

实际模拟器 RED 为 `testQueuedCallsRecoverWhenSessionExpiresAheadOfThem`：`Read-only call c failed during recovery: invalidResponse`。完整旧测试字节、生产文件及失败 `.xcresult` 保存在 `/tmp/amber-audit-20261018-current`，没有把先前的 FIFO fixture 假阳性混为同一个产品问题。

修复为 Client 协议增加 required `reconnect(config:)`，真实实现等待取得原请求 slot 后，在同一 slot 内重置 transport/session、initialize 并发送 initialized notification。普通 `connect` 的已连同配置复用语义保留；协议默认实现只保留既有 fake 的断开/连接契约。Manager 恢复只改为调用原子 reconnect，继续采用既有恢复合并、目录刷新与显式只读重放规则。未增加通用 invalidResponse 重试、时间等待或恢复代际状态。

修复后断开会正确等待 B/C 释放 slot，测试不能再以“提前断开发生”作为释放 B 的条件。同步点改为纯 forwarding observer 观察恢复请求；实际 queue2、A/B HTTP gates 和全部三个输出、initialize/list/call 次数、两个 session 的 headers、一次断开、最大并发 1、最终 connected 断言保留。独立审查确认旧 Manager 路径在同一观察点下仍会使 C 失败。

## 独立复核与验证

- [实际可达性与确定性反例](reviews/mcp-real-client-queued-recovery-candidate.md)。
- [修复取舍和精确 diff 范围](reviews/mcp-queued-recovery-fix.md)。
- [Root 委托的独立 review](reviews/phase7-mcp-independent-review.md) 及补充 peer 均 PASS；检查了协议 witness、完整 slot 范围、取消/owner 失效和测试敏感性。
- [实际构建](mcp-atomic-reconnect-build.status.json) exit 0；真实 Client/Manager 两组 [51/51 通过](mcp-atomic-reconnect-green-summary.json)，零失败、零跳过。三调用 RED 已转 GREEN，完整请求及恢复次数断言实际执行。

表格帧耗时项另保留真实失败与诊断，未把尚待测量的优化实验预先写成确认根因。
