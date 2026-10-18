# Batch Polish 分支切换测试 fixture 独立审阅

状态：冻结后的定点测试 diff 已独立复核通过，完整 Novel r2 与最终 clean Main r6 均通过；本 fixture 的模拟器行为验证签字。Main r4 的旧版失败保留在下文作为诊断记录。本轮只更新审阅文档，未修改 Swift、运行构建或解包 xcresult。

修复前的 `NovelBatchPolishTests.testBindingChangeCancelsRunningBatchWithoutStartingNextChapter` 正文与 `HEAD` 完全一致（SHA-256 `ac5284ce9bbe8dfd475b7e69131d6b92859aba885786096cef11805fff5e3585`）；当前冻结修复版正文 SHA-256 为 `1828622a3980c4b3f16dc5ef86cbd3b7ffa3c25443a89a648cf2c71f4d28861c`。Main r2 通过（0.076 秒），独立 Novel 通过（0.031 秒）；Main r4 的旧版在 5,089 项中 5,072 通过、1 项本案失败、16 原跳过，本案首个失败是切换后 `session.binding` 仍为源分支。运行中进度未清与持久化 run 仍为 `.running` 是同一未完成分支切换的后续状态，不能独立算作三处产品缺陷。原测试丢弃了 `workspace.selectBranch(forkID)` 的返回值，因此没有观察 `.selected` 与 `.failed` 的分界。Main r4 的 Foreground gate 案和两条 protected lease 案通过；这些属于旧版 Batch fixture 同一次广域运行结果。

## 触发时序与真实 UI

现有等待只要求 `session.activeRunID != nil`。`NovelSessionRunLifecycle.start` 在获取 `workspace.acquireSessionOperation` 后，先安装 `.waitingForFirstToken` 占位 tail 并设置 `sessionStartingRunID`；此时 `activeRunID` 已可从 transient tail 返回，但 `startSessionRun` 仍在 await，workspace 操作锁尚未由 defer 释放。若测试立即切分支，`NovelCreationViewModel.selectBranch` 的首个 `isProjectSelectionBlocked` 守卫（包含 `isPerforming`）会返回 `.failed`，并保留源分支。这是当前 fixture 的可达竞态；r4 日志没有 `selectBranch` 返回值，尚不能断言当次确切命中该守卫。

真实 UI 在 `NovelProjectSettingsDetailView` 把 `viewModel.isProjectSelectionBlocked` 传给 `NovelBranchesView.isSelectionDisabled`，分支行按钮据此 `.disabled(...)`。可点时先以 `stoppingActiveRun: false` 请求并提示确认，确认后才以 `true` 执行实际停止与切换。因此测试直接以默认 `true` 调用相当于确认后的步骤；它必须等同一门禁解除，否则测试能触发 UI 此刻不允许的动作。真实产品若在可点后仍返回 `.failed`，才需要按错误与运行状态追产品链。

## 冻结修复版的源码复核

修复版在原有有界 `eventually` 内同时要求 `activeRunID != nil`、`!session.isStarting` 和 `!workspace.isProjectSelectionBlocked`，是精确的就绪条件。`isStarting` 由 `sessionStartingRunID` 或 quick-start 启动状态派生；本例 `start` 的 defer 在 `workspace.startSessionRun` 返回后才清除它并释放 workspace 操作。领域 `startGenerationCore` 在返回前已提交 `.running` active run，`resumeDurablyStartedRun` 又在返回前调用本 fixture 的脚本 adapter `start`。因此本 fixture 的 `!isStarting` 加活跃 run 足以表明首章真实启动已完成；不需要再轮询仓库状态或 `adapter.requests.count`。`!isProjectSelectionBlocked` 另覆盖并发剧情同步等 UI 同样禁用选择的状态，且条件在 MainActor 同次求值，不插入固定 sleep。

修复版保存 `selectBranch(forkID)` 返回值并断言 `.selected`，失败时把 `workspace.errorMessage` 作为诊断文字，能把“切换失败”与后续取消行为分开定位；成功返回时产品本身会清空错误，故无需再加镜像的 nil 断言。原 `binding == forkID`、批次进度清空、adapter 总请求数仍为一、持久化 owned run 不再 `.running` 四类断言全部保留；它们分别证明绑定迁移、报告隔离、未启动下一章及 durable 终态。等待失败会记录 `didStart` 断言失败；若占位 ID 仍在，后续可能追加失败，但不会把未就绪当作通过。

该定点修改修复了已证明可达的 fixture 竞态，不放宽产品行为。Main r4 当次是否确为 `isPerforming` 守卫返回，静态日志仍不能唯一证明。Root 的完整 Novel r2 在 iPhone 17 Pro / iOS 26.5 模拟器上 **1,048 项：1,045 通过、0 失败、3 项原跳过**；本案修复版通过（0.034 秒），`NovelBatchPolishTests` 整类随套件运行。摘要已归档为 [Novel r2 summary](phase-6-novel-r2-summary.json)，逐案状态来自 Root 已导出的 `/tmp/amber-phase6-novel-r2-tests.json`。

最终 clean Main r6 在同一型号与系统版本模拟器上 **5,089 项：5,073 通过、0 失败、16 项原跳过**；本案修复版通过（0.080 秒），明确走过新增的 `.selected` 断言和全部原有 binding/progress/request/durable 断言。摘要见 [Main r6 summary](phase-6-main-r6-summary.json)，逐案状态来自 `/tmp/amber-phase6-main-r6-tests.json`。这使本 fixture 在独立 Novel 与全 Main 两套实际运行中完成验证，可以对本次测试修复及其覆盖的分支切换/批次收口模拟器行为签字；不能由此倒推出 Main r4 的确切 guard 分支，也不把模拟器测试扩大为真实 provider 或真机验收。Main r4 数据源为 Root 已导出的 `/tmp/amber-phase6-main-r4-summary.json` 与 `/tmp/amber-phase6-main-r4-tests.json`，未并发解包原结果。
