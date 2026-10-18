# Phase 6 — 测试拆分与严格门禁独立审查

状态：**Phase 6 运行链源码、映射与最终行为门禁独立审查通过。** Main r6 完整 5,089 项、5,073 通过、0 失败、16 项既有跳过；Novel r2 完整 1,048 项、1,045 通过、0 失败、3 项既有跳过。以下保留 r1–r5 的失败与诊断历史，不把中止轮次写成通过。本 reviewer 不修改生产、测试或配置，也不运行构建/测试或直接解包 xcresult。基线采用 `/tmp/amber-phase6-source-baseline/files`，保留本期开始前的工作树内容；审查不以 `HEAD` 替代它。

## 已冻结测试及 owner

`phase-6-parity-skill-test-moves.json` 将原 `IOSParityRedLightTests` 与 `IOSSkillMcpToolsTests` 的 **99 个** XCTest 方法逐一映到六个当前文件。独立检查映射 old/new 键均无重复，六文件当前 `func test…` 声明恰好 99 个，无映射外方法或缺失；两份基线和六份当前文件的 SHA-256 与清单相符。98 个测试体 SHA-256 完全相同。唯一例外 `test_releaseSensitiveLogsAreDebugGuarded` 保留原来两个断言调用，将七个日志 marker 的文件路径指向实际 `HotlistCore`/`DeepReadCore` owner；当前七个 marker 均在对应 `#if DEBUG` 段内。其余 21 个 helper 和六个测试类型由映射声明为原 body SHA，当前类仍是原 XCTestCase 身份，职责文件采用同类 extension。

Skill 测试的 `tempDirs`、异步 `tearDown`、`tempRoot` 都只在原 `IOSSkillMcpToolsTests` 类持有；Management/Consumption 两个 extension 复用该 owner，没有第二个目录 registry 或含测试方法的继承基类。五处 helper 可见性放宽对应跨文件 extension 调用，未把 fixture 状态改成全局共享。

Phone 最终 `phase-6-phone-test-moves.json` 和 `phase-6-phone-test-audit.json` 将三份原文件映到十份输出。独立逐文件核对三份基线、十份输出的完整 SHA-256 与物理行数均匹配；**228 个**原/新方法键各自唯一，十份当前源码恰有 228 个 `func test…` 声明，与新映射一一对应，228 个方法体 SHA 全等。审查同样核对审计中的 68 个 helper、18 个支持类型的前后 body SHA 均相同。`PhoneRunnerClientTests` 104 项、原同文件的 `RunnerPhaseTimingTests` 1 项、`IOSPhoneControlControllerTests` 46 项、`IOSPhoneGoalLoopTests` 77 项保留原 XCTestCase 类和方法名；没有新测试基类或方法副本。十份文件最高 1273 行。

Package 的 Runner client 测试仍由原 `PhoneRunnerClientTests` 的 `token`、`makeClient`、`assertUnsent` 和一份 `Fixture`/`ReplyGate` 服务三个同类 extension；SwiftPM target 依旧从 `Tests/AmberPhoneControlTests` 自动收录。App 的 Controller 原类持有唯一 `MemoryPairingStore` actor 与 `pairingData`，Readiness extension 复用它，`ReadinessSessionStub`/HTTP fixture 的 registry 只在支持文件里持有；GoalLoop 原 `@MainActor` 类继续持有一份嵌套 `Fixture` 与 request/observation/node builder，Recovery extension 复用。11 处可见性变化仅涉及这些跨文件测试调用或单一 fixture/actor 类型，未新增共享运行 owner。Xcode `iosAppTests` 源目录递归收录新文件；最终能否实际 discovery 仍以 Root 的构建与测试结果为准。

Phase 5 的 ConversationStore map **37→37**，Council map **89→89**，独立核对各自基线与全部输出文件 SHA、映射 old/new 唯一性、当前测试声明一一存在。ConversationStore 所有测试体 SHA 相同；Council 85 个相同，四个例外仅把源码文本 guard 对准迁移后的实际 owner，映射保留原断言调用数。两套 helper base 没有测试方法，原 XCTest 身份及单一 fixture owner 保留。这两份 map 与 Phase 6 两份 map 的叠加仍须 Root 用最终 discovery 判断实际执行一次，源码映射本身不能替代运行结果。

## 严格 CI 与门禁证据

`scripts/swift-file-length-baseline.json` 已删除；`.github/workflows/ios-shared-export-check.yml` 的 `swift-file-length-check` job 无条件先跑 checker 自测，再调用 `python3 scripts/check_swift_file_lengths.py`，没有传 `--baseline` 或使用 `continue-on-error`。脚本默认分支对每个 Git 可见 Swift 文件执行 1500 物理行 strict 限制。Root 归档的最终 strict 清单为 1318 文件、0 超限、0 problems；我未重复运行该门禁。保留 CLI 的显式 `--baseline` 迁移模式不构成 CI 豁免，因为 CI 没有调用它。

五份 Phase 6 原测试文件合计 **327→327** 个方法，另两份 Phase 5 测试 map 的 126 个方法均保持一一映射。Root 已完成实际 Main、Novel、DeepRead、GPL、Phone、Shared export、全局原方法 discovery 与最终 CI 严格行数门禁；具体结果见报告末段。本报告不把静态 `swiftc -parse`、清单数字或构建成功称为测试通过。

## 首轮实际结果与三处定点修正

归档的 `phase-6-coverage-final.md/json` 对 Root 导出的测试树和完整 Phone SwiftPM 日志做了 require-discovery 对照：5368 个原方法各有唯一当前声明；Main 的 1508 个映射原方法各发现一次，1505 通过、3 个既有性能采样跳过，所有 Phase 6 的 327 个原方法实际通过。首轮 Main **5089 total / 5057 passed / 15 failed / 17 skipped**，其中 12 项是 SavedTasks AX/视觉、三项是以下旧测试；当时全量门禁为红，最终 r6 已通过，见末段。另三消费者的独立结果是 Novel 1045/1048（3 跳过）、DeepRead 109/109、Phone SwiftPM 105/105，GPL 构建 exit 0。这里引用归档证据；本 reviewer 未重新运行这些门禁。

- StoreKit：`IOSStoreKitTests` 原字符串只匹配单行 `.task { await storeCoordinator.start() }`，而 `AppShell` 实际在 `.task` 下一行调用 `start()`。修正只更新这一段多行字符串，原六个正反源码断言保留；实际 `start`、scene refresh 和共享 store 注入路径均在产品源码。没有更改产品或弱化测试为单独搜索 `start()`。
- Memory pollution：后台 `search_web` 的真实 executor 标记传入的 run conversation ID 后返回 `.filledParts(result.parts)`，旧测试错误只接受 `.filled` 并在污染归属断言前退出。修正接受 `.filledParts`，额外要求确定性的标题、URL 与无 failure payload；原 run 被标记、foreground 未被标记的断言仍在。局部 DDG fixture 更新到现有 `result__a`/`result__snippet` parser 的形状，并在该测试显式关闭 Google WebView fallback、重置 aggregate cooldown，避免走非确定性的外部回退；没有产品兜底或第二个污染 writer。
- WebMount：`IOSWebMountSiteMemoryLayoutTests` 旧 helper 用反射猜 `conversationRuns` 存储形状，当前 `ChatViewModel` 的唯一 run owner 已是 `runRegistry`。helper 现在先要求当前 conversation ID，再用现有 `run(for:)` 非创建式查找并 `XCTUnwrap`，仍要求真实 run 存在，继续操纵同一 `run.state` 以测实际审批布局；没有把 nil 当作成功、也没有改产品 registry。

归档 `/tmp/amber-phase6-main-focused-r3-tests.json` 显示上述三项各自 `Passed`；同一轮聚焦 14 项中 12 通过、两项 SavedTasks AX 仍失败。这是当时的历史状态；最终 Main r6 全量结果另见末段，不能用这轮定点结果代替它。

## SavedTasks 全量顺序下的 AX 状态（未定因）

Main r2 再次在 `IOSPhoneControlSavedTasksTests` 首个渲染用例的控件查找处失败；独立 r6 的 16/16 通过不能覆盖这个顺序差异。Root 在失败时的外部 AX 查询为 screen `0×0 pt`、0 elements，故当前证据不能把失败等同于某个产品按钮消失。只读对照前序测试：`IOSJevSettingsVisualEvidenceTests` 在 06:30:05–06:31:55 反复创建窗口，每次 `defer` 均 hide window、清 root 并尝试恢复原 key；其后 `IOSMiniAppVisualEvidenceTests` 06:32:28–34 使用 foreground-active scene 并通过，`IOSNativeGenerationMotionTests` 06:32:34–38 的嵌套 replay window 前后有两条 UIKit `Unbalanced calls to begin/end appearance transitions` 日志，但同类日志在更早的测试也出现。SavedTasks fixture 自己用 `connectedScenes.first` 选 scene、`makeKeyAndVisible`，并在 `tearDown` hide/清 root/恢复 key；源码未见上述候选测试有不清理的临时 window，亦未见它们改写全局 AX 开关或 scene session。Jev/NativeMotion 与 0×0 AX 的因果链尚缺 scene/window 的失败现场数据；不把它们记录为已证实 defect，也不以单独 r6 绿替代全量重现。

针对完整 discovery 可能比筛选运行多实例化测试类的差异，另只读扫过 `iosAppTests` 的 XCTestCase 声明、八个 Swift Testing `@Suite`、`defaultTestSuite`/`testInvocations`/`init(name:|invocation:)` 和类级属性初始化。未发现测试类在实例化或 class/static 初始化时创建 `UIWindow`/`UIHostingController`、切换全局 AX/scene，或覆写 XCTest discovery；窗口创建都位于具体测试方法或显式 fixture initializer。此范围没有可达的 discovery-time UIKit 污染 finding。完整 r3 的 scene/window 诊断仍是决定下一步的证据，不能把普通 fixture 属性或先前 appearance warning 升格为根因。

## 最终源码收尾与待运行门禁

Main r3 的同一 hosted app 进程实际记录 `IOSIntelligentUIComponentInteractionTests` 1/1、`IOSPhoneControlSavedTasksTests` 12/12、`IOSPhoneControlSavedTasksVisualTests` 4/4 通过；SavedTasks 的临时现场诊断显示 app/scene active、测试 window 可见且为 key、SwiftUI hosting root 与 393×1800 bounds 存在。这推翻了“全量顺序必然导致这组 AX 用例失败”的判断，也没有形成必须拆独立测试进程的证据；先前红灯与 r3 绿灯的差异仍未定因。r3 随后在 `NovelCreationViewModelTests.testForegroundCancelsGatedInventoryBeforeOldCycleCanInterruptLaterProject` 停住，Root 以 exit 73 中止。原测试的 `waitUntilProjectListSnapshotRequested()` 是无超时的 checked continuation，仅 `SnapshotFailureNovelCreation.snapshot(.projects)` 可恢复；等待它之前 `expire()` 只排入 MainActor task。已确认这是一条 fixture 等待链，不能把 r3 中止或仅凭 CPU 活动记为产品 busy loop。

本次最终 fixture 修复只改这项测试：用原有 `eventually` 有界等待 actor 的 `didRequestGatedProjectListSnapshot`，先执行 `enterForeground()` 和 `releaseProjectListSnapshot()` 清理 cycle/gate，再断言背景过期确实请求了 inventory，保留旧轮次不得中断后续项目的 `backgroundInterruptionProjectIDs.isEmpty` 断言。`didRequestGatedProjectListSnapshot` 仅由 gated `snapshot(.projects)` 置位；VM 的 `interruptSessionForBackground` 在缓存项目循环后调用 `projectSummaries()`，后者明确走 `creation.snapshot(.projects)`，并在返回后复核 cancellation/deadline。`now = .distantFuture` 排除测试时钟提前到期，注入 `hasProtectedGenerationLease = { false }` 排除其他并发测试遗留 lease 对此协调器入口的干扰。actor 字段保持唯一 owner，仅 getter 为跨文件测试读取开放；未新增产品状态或吞错重试。即使 gate 未到达，测试现在明确失败并执行清理，不再无限挂住。就本次改动的职责、调用链和维护成本而言，无需进一步源码修改。

另一项 `NovelBatchPolishTests.testBindingChangeCancelsRunningBatchWithoutStartingNextChapter` 的 fixture 仅把原有 `activeRunID` 就绪判断补足为 `!session.isStarting && !workspace.isProjectSelectionBlocked`，并要求 `selectBranch` 明确返回 `.selected`。这与现有启动占位 tail、workspace 操作门禁和真实 UI 的分支选择禁用条件一致；原绑定切换、进度清理、不启动下一章及 durable run 停止断言全部保留。两项修复均未改生产 `NovelWorkspaceLifecycleCoordinator`、VM 的后台中断与分支选择、Session batch cancellation 调用链。`testScenePhaseCycleDoesNotCompeteWithAnActiveNovelGenerationLease` 和 `testLateProtectedLeaseSupersedesTheLegacySceneCycleBeforeExpiration` 继续覆盖被 inventory fixture 局部注入绕开的两条真实 protected-lease 守卫。

Root 导出的最终 `/tmp/amber-phase6-main-r6-tests.json` 与 `/tmp/amber-phase6-novel-r2-tests.json` 经独立只读遍历：Main 有 **5,089 个唯一 Test Case ID**（5,073 `Passed`、16 `Skipped`），Novel 有 **1,048 个唯一 ID**（1,045 `Passed`、3 `Skipped`），与各自归档 [Main r6](phase-6-main-r6-summary.json)、[Novel r2](phase-6-novel-r2-summary.json) 摘要一致。前述两项修复测试、两条 protected-lease 测试在 **Main r6 与 Novel r2 均为 `Passed`**；Main SavedTasks 12+4 项和 IUI component 1 项亦均为 `Passed`，没有靠转 target、漏 discovery 或新增 skip 变绿。Main r5 是 test daemon bootstrap 未就绪、0 个实际用例而受控停止，模拟器保留数据重启后 r6 完整执行；r3/r4 的失败现场仍作为原因诊断保留，不计入最终通过数。

其余 Root 归档门禁：DeepRead **109/109**、Phone SwiftPM **105/105**，GPL/Watch 等构建成功、六条真实 UI 导航 **6/6**。最终 Swift strict 清单为 1,318 文件、0 个超过 1,500 行；CI 无基线豁免。构建、模拟器 XCTest、UI 导航是不同证据；这些结果不替代真实 provider、SSH/系统权限、物理设备或后台系统调度验收。Phase 6 目标范围内没有未闭合的运行链源码 finding，独立行为签字完成。
