# Phase 5 测试入口

Council 与 ConversationStore 的两个原大文件共126个方法。下表列出拆分后全部实际 XCTestCase；基类仅共享 fixture，不含测试方法。旧/新selector和helper的逐项SHA见同目录两份`phase-5-*-test-moves.json`。

| XCTestCase | 原方法数 | 责任 |
| --- | ---: | --- |
| IOSCouncilRunnerMechanicsTests | 19 | 基础机制与源码契约 |
| IOSCouncilPlanningAndLiveTests | 27 | 规划与实时转录 |
| IOSCouncilRoomExecutionTests | 17 | 房间执行与上下文 |
| IOSCouncilRuntimeOwnershipTests | 18 | 取消、租约和终态所有权 |
| IOSCouncilRuntimeIntegrationTests | 8 | 运行集成和恢复 |
| IOSConversationStoreTests | 17 | 基础存储和元数据 |
| IOSConversationStorePersistenceTests | 11 | 持久化和恢复 |
| IOSConversationStoreConcurrencyTests | 9 | 并发写入与过期结果 |

`IOSCouncilMechanicsTestCase`、`IOSConversationStoreTestCase`均为0-test基类。运行一个原suite名称只覆盖表中第一组，选择相关责任时需同时选择对应拆出类。主App target递归收录所有新测试源；独立Novel/DeepRead未因此引入Council或主会话存储测试。

新增布局探针为`SwiftModularizationSettingsLayoutTests`与`SwiftModularizationCouncilMiniAppLayoutTests`，各3个方法，使用真实hosting与viewport几何并保留PNG；不代表AX激活、触控、provider或系统权限验收。实际入口导航由`SwiftModularizationNavigationUITests`的两个Phase5方法单独验证。

MiniApp 权限组件提取后，旧测试 `IOSMiniAppVisualEvidenceTests/testDisabledSystemPermissionRowsAtCompactWidths` 是唯一改变 body 的原有视觉测试：body SHA-256 从 `3c83522cdaf0198e29e8d031ea4eef030002fb3ba400c49676246537c1733e6c` 变为 `350dfec59638560329132e98faea3a0db638de79e9b69e806e1f250dee85556c`。它现在直接挂载读取动态字号环境的 `MiniAppPermissionGrantsSection`，沿用原来六项权限、临时 repository、全局设置恢复、宽度断言及 `miniapp-permissions-compact/accessibility` 截图名；其余两个原方法未改。这是测试 fixture 入口迁移，不表示菜单点击或系统授权已经验收。
