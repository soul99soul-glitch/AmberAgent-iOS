# Production Chat site-memory layout canary — read-only diagnosis

**结论：这次是测试设施仍反射旧状态存储名，不是已证实的产品审批卡布局失败。** `/tmp/amber-phase6-main-r1.xcresult` 的 test-details 把唯一失败定位在 `IOSWebMountSiteMemoryLayoutTests.swift:460`：`XCTUnwrap failed: expected non-nil value of type "Any"`。该行用 `Mirror(reflecting: model)` 查找 `ChatViewModel.conversationRuns`；P3 已把这个字典移入 `ChatConversationRunRegistry.runs`，VM 现只有 `runRegistry` 和 `currentRun`。所以第一层 Mirror 查找必为 nil，代码未运行到风险说明、320pt 短窗口或第二轮截图的几何断言。

## 证据

- 修复前，测试文件与 `/tmp/amber-swift-modularization-baseline-20261018-010059/files/iosApp/iosAppTests/IOSWebMountSiteMemoryLayoutTests.swift` **整文件一致**，SHA-256 都是 `e2162040974ee0c26339aa27a78a93c899953e72cfcfe78bf20f1076769f2425`；此测试方法体 SHA-256 均为 `8843c7c6a748dc7b9558ed970f1d357cea99fd412b08354f140037ae6a155e29`。是生产 owner 的职责拆分让原有私有成员反射失效，不是有人改了本测试断言。
- 初始备份 `ChatViewModel.swift:990-999` 持有私有 `conversationRuns` 字典，`currentRun` 在字典中按会话键懒取。当前 `ChatViewModel.swift:939-944` 持有 `runRegistry`，其 `ChatConversationRunRegistry.swift:16-32` 仍以相同会话键持有 `ChatConversationRun`，每个 run 的 `state` 在该文件第 5-10 行。`/tmp/amber-phase3-session-moves.json` 明确记录此状态归属。当前 `pendingWebMountApproval` 和 JEV 展示属性仍投影 `currentRun.state`；`ChatComposerApprovalCards.swift:35-86` 消费这些属性构造真实 `WebMountToolApprovalCard`。
- 测试在调用旧 helper 之前已确认当前会话 ID、pending approval，保存 `approval-production-chat-320-normal.png`，并执行了草稿和首屏 approval viewport/button 检查。该 PNG `/tmp/amber-webmount-stage2-shots/approval-production-chat-320-normal.png` 的修改时间为本次 r1 的 05:53:28、大小 900,773 字节；画面可见审批卡、活动条、附件卡和保留的草稿。`-jev` 与 `-short` 同名 PNG 仍是 01:57 的旧产物，不能算这次 r1 证据。xcresult `hasMediaAttachments: false` 与测试直接写 `/tmp` 的方式一致。

## 已 GO 的最小修复

Root GO 后已应用 `/tmp/amber-phase6-webmount-site-memory-reflection.patch`，只替换 `currentRunState(for:)` 的反射实现：先 `XCTUnwrap(model.currentConversationId)`，再 `XCTUnwrap(model.runRegistry.run(for: conversationID))`，返回现有 `run.state`。`run(for:)` 是 `ChatConversationRunRegistry` 当前真实 API，按会话 UUID 的 hex key **只查已有运行**，不存在则返回 nil；它不会像 `currentRun` 那样创建 run，因此保留了旧 helper “真实当前运行必须存在”的失败契约。`@testable import iosApp` 可见当前 internal 的 registry 方法与 state，不需要生产测试钩子或可选兜底，也不修改 UI/几何断言。

helper 函数体（从 `private func currentRunState` 到下一函数前，去除尾随空行）的 SHA-256 从 `17bc4fcbc1045e882c24d6e7188c3df21b20fb66795e53431955674ff1940787` 变为 `cd89a1b8a0eb4b7898200d39c414a79966db9939b509781c1892a1c29d333996`；修后整文件 SHA-256 为 `ef8390dc4a641d022b8a363f9d2ca95570680349397525d8f7f010968947149c`。原测试方法体和所有几何/状态断言未改。`swiftc -frontend -parse`、定向 `git diff --check` 均通过；未执行类型检查、构建、测试或 GUI。Root 后续应针对原测试重跑，只有跑到 JEV 风险说明与短窗口截图/断言后才能判断后续产品布局是否通过；现有 r1 不能替它们背书。
