# Phase 6 Watch / DeepRead 实施

状态：生产改动完成并冻结，等待 Root 统一构建、测试与独立 review。未运行构建或测试；Root 提供的 red 证据是实施前确认依据。

## 交付

- WatchTaskCoordinator：仅在 publish 接受该 run 后清理另一类决策并保存本 prompt/request。旧 run 被排序拒绝时不改当前 owner 决策数据。
- IOSDeepReadStore：加载只对真正不存在的文件返回空库，读取/解码失败写 observable loadError；createTask明确抛 historyUnavailable，持久化边界也禁止覆盖原文件。无自动删文件、重建空库或后台重试。
- BoardView深度阅读历史、standalone DeepReadLibraryView：现有空库入口优先展示 loadError，避免把读取失败显示成首次空库；新建已有catch链显示错误。
- IOSDeepReadPriorCompletion：快照原文章的 workspaceSyncFailed。失败/系统中断恢复调用 store.complete 一次原子保存文章和原同步标记，正常新文章 complete 默认清标记的行为不变。
- 新增的 DeepRead 回归测试已补 loadError 可观察断言，并在 prior快照中携带原 marker。Watch 两个真实动作回归测试保持 Root 已运行 red 的版本。

## API 变化

- 新增 IOSDeepReadStore.loadError: String?（外部只读、Observation可观察）。
- 新增 IOSDeepReadStoreError.historyUnavailable（已有 LocalizedError 显示链消费）。
- IOSDeepReadStore.complete 新增 workspaceSyncFailed: String? = nil，现有调用源兼容；只在恢复原完成文章时传入旧值。
- IOSDeepReadPriorCompletion initializer 新增 workspaceSyncFailed: String? = nil，旧测试构造仍兼容；生产唯一快照构造和本回归测试显式传入。

## Root 验证 selectors

- iosAppTests/WatchCoordinatorDecisionOwnershipTests/testOlderApprovalDoesNotPreventAnsweringCurrentRun
- iosAppTests/WatchCoordinatorDecisionOwnershipTests/testOlderQuestionDoesNotPreventApprovingCurrentRun
- iosAppTests/DeepReadPersistenceRecoveryRegressionTests/testCorruptedHistoryRejectsNewTaskAndPreservesOriginalBytes
- iosAppTests/DeepReadPersistenceRecoveryRegressionTests/testFailedSectionRetryRestoresWorkspaceWarningAndAllowsWorkspaceOnlyRetry
- 受影响既有套件：iosAppTests/IOSDeepReadPipelineTests、iosAppTests/WatchTaskSnapshotTests；共享 Store 另由 standalone DeepReadTests/DeepReadRuntimeTests 和 DeepRead 构建确认消费者。
- 无新增 standalone 测试文件或 membership需求；主App两个新测试仍由 Root 统一 XcodeGen。未改任一project.yml或project.pbxproj。

## 一次有限维护性审查

已应用 /Users/arquiel/.codex/skills/code-simplifier/SKILL.md，只对 /tmp/amber-audit-20261018-current/phase6-system-before 保存的本轮 baseline 增量审查一次，并阅读 Swift/SwiftUI 规则。确认决策所有权变更集中在 wrappers，读取错误与写入门属于 Store，UI只消费loadError；原同步标记随原完成快照一次保存，没有第二次元数据写入或通用恢复框架。没有追加整理或触碰既有WIP。owned增量 whitespace检查无输出。

## 冻结文件与 SHA256

- `iosApp/DeepReadApp/Sources/UI/DeepReadLibraryView.swift`: `11fc33a78eb482809624c7d943b9c90cde5424ea886cdf30a172c410b46bbc1f`
- `iosApp/iosApp/Board/BoardView.swift`: `e4266758fd2cbb5b7c1c4f4bedd609622403407aa23ae9db00bdeda325720421`
- `iosApp/iosApp/DeepReadCore/IOSDeepReadStore.swift`: `6a39c9c3ccc74246495b99459951edaf1fc566a420c3bcc5e272f837c9dafdb2`
- `iosApp/iosApp/DeepReadCreateView.swift`: `1d636fdb71d78c1d6ee3116c4ade332f612ee8e688b16986607e8ec29f07d994`
- `iosApp/iosApp/WatchTaskCoordinator.swift`: `8e0b47eb5d68308a0836e652b8be207f4b2f742e99db6ea3f218a04e371f04f0`
- `iosApp/iosAppTests/DeepReadPersistenceRecoveryRegressionTests.swift`: `6aad95025fec1ea8aa9d240ff6757bbbdac484ba301b055e76ce8f58059a8acd`
- `iosApp/iosAppTests/WatchCoordinatorDecisionOwnershipTests.swift`: `f74edc31d10d25be4d9d3ae6d0addf5b9637af2be95583f2b4fbb1cda95a81fc`
