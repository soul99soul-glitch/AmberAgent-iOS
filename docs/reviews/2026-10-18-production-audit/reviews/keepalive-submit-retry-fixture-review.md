# KeepAlive submit retry：最终全量测试时序修复

结论：现有失败属于测试 fixture 的固定等待竞态，未识别到本场景生产重试契约缺陷。只修改 `iosApp/iosAppTests/BackgroundGenerationKeepAliveTests.swift` 的 SystemSpy 观测钩子及 `testSubmitFailureRetryDoesNotLoopForever`；生产文件未改，其他异步测试未迁移。新的测试尚待 Root 构建并执行。

## 原始失败与保护

Root 在最终 whole 中报告 `BackgroundGenerationKeepAliveTests/testSubmitFailureRetryDoesNotLoopForever` 原行 358：`submit-fail` 实际 1、期望 2，case 耗时 1.703s；首轮 whole 此项通过。该测试与生产 KeepAlive 在本任务前均未修改，限定路径 `git status --short` 为空。

- 当前 HEAD：`b98bd6f0f2f82dd9492ff021e53d03bfe26d2dce`。
- 原始字节快照：`/tmp/amber-audit-20261018-current/BackgroundGenerationKeepAliveTests.submit-retry-before.swift`，34477 bytes。
- 原测试文件 SHA256：`945f9e468b37e9615627c7d0b229607bd71e14de32cbc0a0f34487ae28ce6719`。
- 修后 SHA256：`f53917ea4aaa3361d98f56a64ff54d004ffbe2046b97eada28fb980463fca8cb`。
- 生产 `BackgroundGenerationKeepAlive.swift` SHA256：`c354a724369b2a97c05bd383ae8a9d4061633d2fd082bb2947fbbe21b19dd129`，与 HEAD 无 diff。

## 二次判定与反证

原测试给生产重试注入 20ms 延迟，但自身 `begin` 后直接等待 100ms 就要求失败次数等于 2。生产 `BackgroundGenerationKeepAlive.swift:650` 首次提交失败后调用 `scheduleSystemSubmitRetryIfNeeded`；`:659` 先以 `systemSubmitRetryScheduled.insert(leaseId).inserted` 保证该 lease 只调度一次，再于 `:662` 创建 MainActor Task，只有 Task 获得执行权后才在 `:663` 开始它自己的 20ms sleep。

因此，100ms 并不是从“重试 Task 已启动”开始计时。MainActor 繁忙时，测试的计时已开始而生产 Task 尚未开始，测试恢复时仍只有第一次失败是具体可达的交错。本次失败符合该窗口；这里没有把未采集的 actor 调度 trace 描述成已直接测量的事实。

反证生产问题：测试使用始终前台的默认注入，持有本地 keepAlive，保留并最终断言 lease，未调用 end/取消，也未触发后台分支；重试第二次失败时仍保留集合标记，`:659` 拒绝再次调度。重试次数边界仍是第一次提交加一次重试，不能据本次 count1 升级为生产丢失或无限重试缺陷。

## 最小修复与断言保留

- SystemSpy `:28` 增加可选 `onSubmitAttemptFinished`；提交闭包 `:53` 用 defer 在成功或抛错之前完成事件记录后通知。其他测试不设置钩子，行为保持原样。
- 目标测试 `:353–367` 显式等待第二次真实 submit 完结，5s 是缺失重试的失败上限，不是每次固定等待。没有第二次仍会因 expectation timeout 和 exact2 断言失败。
- 第二次真实提交后，`:369` 用 inverted expectation 继续观察 100ms，即注入的五个 20ms 重试间隔。第三次提交会立即 fulfill inverted expectation 并失败；没有删掉无限重试的检测。
- `:371–374` 原断言全部保留：lease 仍在、成功请求为零、UIKit begin 恰好一次、`submit-fail` 恰好两次。钩子通知不代替生产调用、不修改次数、不吞掉错误。

## 验证与边界

已实际完成：只读追踪以上生产路径、原文件字节/SHA 快照、限定文件 diff 检查、`git diff --check -- iosApp/iosAppTests/BackgroundGenerationKeepAliveTests.swift` 通过。按 Root 要求未运行 Gradle、构建、测试或设备操作，未中断正在执行的 whole。

待 Root 执行 selector：`iosAppTests/BackgroundGenerationKeepAliveTests/testSubmitFailureRetryDoesNotLoopForever`，随后按集成验证计划处理本轮 whole。不能提前声明修后 green。

独立窄 peer `/root/review_standards` 已只读复核原始快照与当前 diff，结论 PASS、无 blocking：真实第二次提交是进入后续观察的前置条件，第三次仍触发 inverted expectation 失败，原四项断言完整保留。有限观察不能数学证明永不 loop，但观察起点比原固定等待更准确；peer 未构建、跑测或改码。本人按 code-simplifier 对本次差异做一次有限维护性检查：同步 defer 钩子与测试局部计数直接对应真实提交，没有增加生产状态、延迟兜底或跨测试工具框架。
