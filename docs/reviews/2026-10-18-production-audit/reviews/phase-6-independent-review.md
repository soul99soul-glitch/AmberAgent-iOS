# Phase 6 独立实现复核

## 完整实现审查：PASS（SYS1–3 与 PLAT-1）

**无 blocking findings。** 本次只读核对了指定SYS生产文件/新增测试、phase6-system-before基线和Search冻结增量；未修改源/测试，未构建或运行测试。SYS新回归与standalone consumer已有Root实际green，PLAT-1实现审查通过、实际UI green待Root执行。

### SYS-1 Watch 决策所有权

`WatchTaskCoordinator.swift:489–524`只在publish返回accepted后清理相反类型字段并保存本类型prompt/request。被run排序拒绝的旧run不再修改当前run的pendingAskUser/currentApprovalPrompt；现有publish排序、卡片projection和handleWatchAction确认链保留，无新状态机。

新增两项回归从真实Host分别暂停于ask_user和search approval，再发布旧run相反类型决策，最后执行Watch真实动作并断言原Host第二轮provider调用及工具结果。覆盖了原始失败所需的内部字段与实际行为，而非仅检查快照未变。

### SYS-2 同文章恢复保留Workspace失败标记

`IOSDeepReadPriorCompletion`唯一生产构造点在retry时携带current.workspaceSyncFailed；所有failRun/system interruption恢复继续共用restorePriorCompletion。该函数将原正文/JSON/missingSections和原marker一并交给store.complete，在同一次update→persist内恢复。

complete参数默认nil，普通新文章完成仍清旧同步失败状态，Workspace的新保存流程未改变。没有第二次metadata保存、自动补存或新重试策略。

新增回归走未配置模型的真实runExistingTask失败路径，确认Workspace生成保存闭包未调用；重启store后检查原文章和marker，随后真实retryWorkspaceSync建立原文章artifact并清marker。边界与原问题一致。

### SYS-3 损坏历史不再被空快照覆盖

`IOSDeepReadStore.loadTasks`只捕获CocoaError.fileReadNoSuchFile为首次空库；其他读取错误与JSON解码错误向init传播。init保存observable loadError，且不修改磁盘。createTask在任何新任务创建/目录/编码前抛historyUnavailable；persist边界也有同一read-error门，因此不会通过其他写入口覆盖原tasks.json。

Board历史与standalone阅读库在loadError存在时优先显示具体错误，不把它呈现成首次空库；新建已有catch链继续显示localized错误，且只在create成功后才清draft/跳转。缺失文件仍可正常首次create。没有删除原文件、重建空库、忽略坏记录或新增通用恢复架构。

新增回归明确断言loadError、create抛可见错误，以及tasks.json字节保持不变。既有IOSDeepReadPipelineTests与standalone DeepReadRuntimeTests继续覆盖正常创建/写失败等消费者路径；本review不替代root待跑green或standalone编译验证。

### Root 已有 red 证据

已读取pending-domains-red-summary.json，四个SYS selectors分别因“未抛错”、workspace marker为nil、Watch无等待问题/不支持审批而失败，符合预期根因；没有将Search fixture失败计入SYS红证据。

### 审查内容 SHA256（已独立读取当前文件核对，与冻结清单一致）

| 文件 | SHA256 |
| --- | --- |
| iosApp/iosApp/WatchTaskCoordinator.swift | 8e0b47eb5d68308a0836e652b8be207f4b2f742e99db6ea3f218a04e371f04f0 |
| iosApp/iosApp/DeepReadCore/IOSDeepReadStore.swift | 6a39c9c3ccc74246495b99459951edaf1fc566a420c3bcc5e272f837c9dafdb2 |
| iosApp/iosApp/DeepReadCreateView.swift | 1d636fdb71d78c1d6ee3116c4ade332f612ee8e688b16986607e8ec29f07d994 |
| iosApp/iosApp/Board/BoardView.swift | e4266758fd2cbb5b7c1c4f4bedd609622403407aa23ae9db00bdeda325720421 |
| iosApp/DeepReadApp/Sources/UI/DeepReadLibraryView.swift | 11fc33a78eb482809624c7d943b9c90cde5424ea886cdf30a172c410b46bbc1f |
| iosApp/iosAppTests/DeepReadPersistenceRecoveryRegressionTests.swift | 6aad95025fec1ea8aa9d240ff6757bbbdac484ba301b055e76ce8f58059a8acd |
| iosApp/iosAppTests/WatchCoordinatorDecisionOwnershipTests.swift | f74edc31d10d25be4d9d3ae6d0addf5b9637af2be95583f2b4fbb1cda95a81fc |

### SYS 实际验证与待补边界

- 已读取boundary-red-and-independent-greens-r2-tests.json：WatchCoordinatorDecisionOwnershipTests两个新用例、DeepReadPersistenceRecoveryRegressionTests两个新用例均Passed。该批其他域仍有red，不把整批描述为通过。
- 已读取deepread-consumer-green-summary.json：standalone consumer 109 Passed、0 Failed、0 Skipped。
- 受影响既有iosAppTests/WatchTaskSnapshotTests、iosAppTests/IOSDeepReadPipelineTests及最终组合验证由Root统一汇报。
- 无真机/Watch配对或真实provider验收证据。


## PLAT-1 Search 冻结实现：PASS

审查文件：`iosApp/iosApp/Search/SearchView.swift`。已与`search-before-fix.swift`逐项比较；当前SHA256为`0ff5df75cf6e673083d664019e9c211fb9fa98859fbed97f30aeb60ef093f26e`，与phase6-search-implementation.md冻结清单一致。

- 普通title/message/recent按钮仍共同走openConversation；已经选中目标时保留直接打开行为，未选中时只在selectConversationIfAvailable成功后导航。最终再次确认current ID等于目标，失败不会误开旧会话。
- 单一@State Task是选择请求owner。新选择同步cancel旧Task；取消按钮在dismiss之前cancel；route变化和onDisappear取消离场请求。Task开始与select之后都核对cancellation，Store的commitIf在KMP load返回、setCurrent前同步检查同一Task cancellation，因此已取消的旧load不能再提交选择。
- prepareForConversationChange失败沿现有可见错误反馈；目标不存在/文件无法读取则显示“无法打开会话”alert。失败不清query/results、不改router，不消费重试所需结果；alert关闭后同一hit可再次调用原入口。取消后的silent return只抛弃失效请求，不吞用户仍在等待的失败。
- 没有新coordinator、fallback选择、重试队列或修改Store/Router职责。

### PLAT-1 复现与验证边界

已读`search-real-ui/reproduction.md`：普通安装App的有效target control打开目标标题/正文；在保留target hit的情况下仅损坏task-owned target文件，点击后实际打开旧ORIGINAL，构成真实UI red。未将inprocess AX空树失败当业务导航证据。

本轮新增但无法枚举AX的`SearchNavigationTests.swift`尝试已按Root授权原样归档；已核对归档SHA256为`9926da159c693931608403514f2501692b3d08848fd266924864ce0b1301ab1a`，当前测试源目录无该文件。未删除用户旧测试或有效业务断言。该归档不计green证据。

**待Root完成实际UI green**：有效target控制、损坏target保留Search/显示失败且ORIGINAL current不变、修复原文件后同一hit重试成功。快速取消/离场目前为源码所有权审查证据，尚无稳定UI时序验收，不声称已实测。

Store层建议复用现有suite，尤其：

- iosAppTests/IOSConversationStoreTests/testSelectingMissingConversationFailsWithoutChangingCurrentConversation
- iosAppTests/IOSConversationStoreTests/testConditionalSelectionDoesNotCommitAfterItsOwnerBecomesStale

完整Phase6实现review通过；上述Search UI green与现有Store suite仍是Root后续验证事项。
