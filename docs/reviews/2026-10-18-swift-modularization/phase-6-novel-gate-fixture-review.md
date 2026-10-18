# Novel 前台取消测试 fixture 审阅

状态：冻结后的定点修复已通过独立源码复核、r13 focused、完整 Novel r2 与最终 clean Main r6；本 fixture 的模拟器行为验证签字。本轮只维护审阅文档，未修改 Swift、运行构建或解包 xcresult。

## 现象与归属

挂起前的 `NovelCreationViewModelTests.testForegroundCancelsGatedInventoryBeforeOldCycleCanInterruptLaterProject` 正文与原 `HEAD` 字节相同（SHA-256 `13c2166fb246e4e694961ed6ba20041993705d376535f8afc41809d863786af1`）；当前定点修复版正文 SHA-256 为 `ed277eeb8cf878e63aa412933f75548bebfdd3f473ce156d0f3b391f52b22441`。Main r2 与独立 Novel 对旧版分别以约 0.054、0.055 秒通过；Main r3 在该方法 `started` 后无完成记录。r3 日志在测试开始约 1 毫秒后结束一个此前持有的 `novel-run-...` 租约，又在约 4 毫秒后建立另一租约。采样主线程停在 XCTest 异步等待，活跃 CPU 线程位于 `IOSJsSandboxEngine` 的 JavaScriptCore 求值，并无 Novel gate 忙循环证据。

测试将下一次 `.projects` 快照闸住，触发背景到期后无界等待请求。`SnapshotFailureNovelCreation.waitUntilProjectListSnapshotRequested()` 在请求缺席时保存 `CheckedContinuation`，没有超时或取消路径。协调器的默认 `hasProtectedGenerationLease` 读取进程级 `BackgroundGenerationKeepAlive.shared.activeLeaseIds`：若其他测试的受保护 Novel 租约在 `enterBackground` 或 `expire` 时存在，本例不会进入 inventory 中断，而 `expirationHandler?()` 还会静默跳过缺失回调。另一可达路径是原 `now: Date()+5s`，产品在请求 `.projects` 前用同一 wall-clock `Date()` 检查截止时间；调度延迟超过五秒时不发请求。现有采样不能唯一确认哪条分支实际发生，不能据此认定产品回归。

## 定点修复的源码复核

- 本例现在显式注入 `hasProtectedGenerationLease: { false }`，只隔离目标为“旧背景周期回前台后不得处理新发现项目”的 fixture。真实守卫的进入背景与迟到租约两个分支分别由 `IOSNovelCreationWiringTests.testScenePhaseCycleDoesNotCompeteWithAnActiveNovelGenerationLease`、`testLateProtectedLeaseSupersedesTheLegacySceneCycleBeforeExpiration` 覆盖；二者在 Main r2 均通过。生产默认守卫未改。
- `now: { .distantFuture }` 消除本例不关心的五秒截止窗口。此 fixture 的 `viewModel.projects` 起初为空，不会先对缓存项目执行中断；第一步相关工作是 `projectSummaries()` 请求 `.projects`。产品 `NovelGenerationLifecycle` 即便遇到运行任务，也把后台等待限制在最多五秒，因此远期 deadline 不会解除内部等待上限。本例不承担 deadline 语义测试。
- `let expire = try XCTUnwrap(expirationHandler); expire()` 要求背景周期确实建立并拿到到期回调，不能把启动失败静默跳过。
- `SnapshotFailureNovelCreation` 只将既有请求标志改成 `private(set)`；本例用继承的 `eventually` 在默认两秒内读取该 actor 标志，避免该方法在缺少 `.projects` 请求时卡在无界 continuation。观察后先 `enterForeground()`，再 `releaseProjectListSnapshot()`，然后断言 `didRequest`。这样成功路径会在前台取消旧任务后释放真实 gate，失败路径也会先清理再报告。原 50 毫秒收尾与 `backgroundInterruptionProjectIDs.isEmpty` 行为断言保留。旧 `waitUntilProjectListSnapshotRequested()` 仍服务另一项直接启动 load 的测试，没有在本次改动中重写 helper 或更改该用例契约。

源码层面，该定点修改覆盖 r3 已见的共享租约竞态和短 deadline，并把本例的缺失请求变成有界测试失败；未发现需要进一步修改产品或 helper 的证据。`eventually` 的两秒期限若遇到极端调度延迟仍可能给出超时失败，但不会无限悬挂。

Root 的 r13 focused 在 iPhone 17 Pro / iOS 26.5 模拟器上完成，摘要为 **75/75 通过、0 失败、0 跳过**，包含完整 `NovelCreationViewModelTests` 和 `IOSNovelCreationWiringTests`。本例通过（0.058 秒）；两个真实 protected lease 分支也分别通过（0.001、0.012 秒）。原始统计见 [r13 focused summary](phase-6-main-savedtasks-r13-summary.json)，逐案状态来自 Root 已导出的 `/tmp/amber-phase6-main-savedtasks-r13-tests.json`。

同一修复版在完整 Novel r2 中再次通过：**1,048 项、1,045 通过、0 失败、3 项原跳过**；本例 0.058 秒，两条 protected lease 分支分别为 0.001、0.012 秒。摘要见 [Novel r2 summary](phase-6-novel-r2-summary.json)，逐案状态来自 `/tmp/amber-phase6-novel-r2-tests.json`。Main r4 的该 gate 用例也通过，但 Batch fixture 是那轮唯一失败；该历史结果不作为最终全 Main 签字。

最终 clean Main r6 在 iPhone 17 Pro / iOS 26.5 模拟器上 **5,089 项：5,073 通过、0 失败、16 项原跳过**；本 gate 用例通过（0.058 秒），两条真实 protected lease 分支分别通过（0.001、0.013 秒）。摘要见 [Main r6 summary](phase-6-main-r6-summary.json)，逐案状态来自 `/tmp/amber-phase6-main-r6-tests.json`。独立 Novel 与全 Main 都运行了修复后的真实断言，可以对本次 fixture 修复及其覆盖的前台取消/受保护租约模拟器行为签字；Main r3 挂起的具体 guard 时刻仍无法从历史日志唯一还原。这些结果不证明后台真机执行权或真实 provider 行为。
