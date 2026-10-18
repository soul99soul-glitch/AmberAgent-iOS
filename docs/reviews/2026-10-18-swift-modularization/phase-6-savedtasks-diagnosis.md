# Phase 6 SavedTasks 渲染测试诊断

Main r1 的 15 个失败中，12 个来自 `IOSPhoneControlSavedTasksTests` 的 9 个方法和 `IOSPhoneControlSavedTasksVisualTests` 的 3 个方法。它们均在首次通过 `SavedTasksHostingFixture` 查找中文 AX 标签时超时，尚未执行保存、运行或删除动作。每例随后还报 `InvalidTransition { phase: idle; targetPhase: failed(removedFromContainer) }`；结果树中标签查找失败在先，不能据此把后一个错误认定为产品根因。

Main r2 再次执行 5089 项，5060 通过、12 项 SavedTasks AX 查找失败、17 项跳过；r6 的独立 16 项全绿因此没有解决完整执行路径。r2 失败期间 Root 的只读外部 AX 查询返回 `Screen 0×0 pt, 0 elements`，而更早的桌面查询曾正常返回元素。这说明单次先验查询不足以保证整轮执行期间 AX 始终可见，尚不能将失效归于特定测试或系统版本。

同轮 `IOSPhoneControlSavedTasksVisualTests/testListEmptyEditorAndInputAtNormalAndAccessibilityWidths()` 通过，截图分别能看到“还没有常用任务”和“保存任务”，但截图来自其他宿主实例，不能证明失败实例的 AX 状态。同轮 `IOSIntelligentUIComponentInteractionTests/testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission()` 因“unit hosting 未暴露可激活 SwiftUI AX”跳过，而该方法在 r10 独立顺序中通过；两者可能受共同的宿主 AX 状态影响，仍无因果证据。它们都不证明生产应用的 AX 不可用。

完整 Main r3 使用原选择集，仅在 SavedTasks fixture 加窗口日志。其 `IOSIntelligentUIComponentInteractionTests/testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission()` 已在到达任何 SavedTasks 窗口诊断前通过（0.199 秒），与 r2 同位置跳过不同；因此该差异不能归因于 SavedTasks 诊断 getter 已执行。r3 的 SavedTasks 原两套 16 项随后全部通过，没有首查失败；挂载日志显示一个 foreground-active scene，app key window 与临时 window 正常交接。随后 `NovelBatchPolishTests/testBindingChangeCancelsRunningBatchWithoutStartingNextChapter` 失败，`NovelCreationViewModelTests/testForegroundCancelsGatedInventoryBeforeOldCycleCanInterruptLaterProject` 又在未隔离全局 protected lease 的 fixture gate 等待中挂起，Root 保留 sample 后受控终止整轮；因此 r3 **没有**完整全绿结果。Root 随后精确移除 SavedTasks 的临时窗口日志，原测试文件 SHA-256 恢复为 `31e87e0c066331a9416a252f927bfb4e1ac8ae72d282034bdc7f5be822fce137`；r4 对照见下，当前不能认定 AX 根因已修。

clean Main r4 在 SavedTasks 原始源码、无窗口诊断的完整选择顺序中，`IOSPhoneControlSavedTasksTests` 12 项与 `IOSPhoneControlSavedTasksVisualTests` 4 项全部通过，首次 AX 查找未失败。整轮最终 5089 项中 5072 通过、1 项 BatchPolish fixture 时序失败、16 项跳过。r3 的 SavedTasks 通过因此不能简单归于临时日志，但 r1/r2 与 r4 的差异仍没有唯一可证实的触发条件。BatchPolish 后续窄修及 Novel 全量通过单独记录在 `phase-6-batch-polish-fixture-review.md`。

Main r5 在 test daemon bootstrap 未就绪时受控停止，0 项测试方法实际执行；停止后的 ResultKit Code 12 是结果包写入问题，不能当作启动挂起根因。Root 保留模拟器数据重启后，最终 clean Main r6 完整执行 5089 项，5073 通过、0 失败、16 项原有跳过；原始 SavedTasks 两套 16 项全部通过。r6 中 Novel 两项窄修用例也实际通过。r1/r2 的 AX 失效仍没有唯一可证实的触发条件，不把多轮通过改写为已经定位或修复系统 AX 根因。

## 聚焦对照

| 运行 | 条件 | 结果 | 可得结论 |
| --- | --- | --- | --- |
| focused-r3 | 原始元素遍历，加仅在超时处打印的临时库存 | 2/2 失败 | 两个宿主均 `key=true`、`hidden=false`、root 393×1800。编辑页原遍历 0 元素，扩大遍历访问 33 个对象仍为 0 标签；空列表分别为 0、11、0。单纯 `isAccessibilityElement` 过滤或 `accessibilityElements`/`accessibilityElementCount` 二选一遗漏不足以解释失败。 |
| savedtasks-r4 | 加公开 `automationElements` 读取；此前 Root 已对模拟器桌面做一次只读外部 AX 查询 | 2/2 通过，0.836 秒 | 与外部 AX 查询、候选读取同时发生，不能把通过归因于任一个变量。 |
| savedtasks-r5 | 移除所有 `automationElements` 读取，保留原始元素遍历与失败库存；同一已查询环境 | 2/2 通过，0.837 秒 | 当前已查询环境下不需要 `automationElements` 候选，故不保留该修改。不能排除外部查询或 r4 本身曾使 AX 服务进入持久可用状态。 |
| savedtasks-r6 | 保留数据重启模拟器；首次外部 AX 查询时 SpringBoard 尚未就绪，第二次只读查询得到桌面 13 元素；运行 HEAD/初始字节的原始两套测试 | 16/16 通过，0 失败、0 跳过 | 原有按钮激活、保存、一次性 handoff、删除确认、验证错误位置等断言在此条件下均完成。无需保留公开 API 候选或诊断代码；查询前的冷态尚未单独复现。 |
| savedtasks-r7 | 保留数据重启后运行 1 项 Chat UI 前序加 2 项 SavedTasks，Xcode 测试 bootstrap 停滞 | 0 项实际执行，运行中断 | 没有方法级 AX 或窗口证据，不计入红绿对照。 |
| savedtasks-r8 | 再次保留数据重启，桌面外部 AX 查询正常；临时窗口状态日志，先运行 `ChatPhoneToolGroupingTests/testCaptureTimelineCollapsedAndExpanded()` 再运行两个 SavedTasks 方法 | 3/3 通过 | 单独的 ChatPhoneToolGrouping 前序不足以复现 Main r2。SavedTasks 挂载前唯一 scene 为 foreground-active、402×874，原 app window 可见且为 key；挂载后 393×1800 临时 window 为 key，下一方法前原 app window 已恢复为 key，上一临时 window 隐藏且 root=nil。 |
| savedtasks-r9 | 13 组优先 Chat UI 前序加同两个 SavedTasks 方法，保留临时窗口状态日志 | 129 项实际执行、128 通过、1 项原有跳过、0 失败；两条 SavedTasks 均通过 | 与 r8 一样，SavedTasks 挂载前只有一个 foreground-active 的 402×874 scene，原 app window 可见且为 key；挂载后 393×1800 临时 window 为 key，下一方法前原 app window 已恢复为 key、前一临时 window 隐藏且 root=nil。这组前序在独立顺序中未复现 Main r2 的 AX 0×0。 |
| savedtasks-r10 | 7 组 IntelligentUI 前序加同两个 SavedTasks 方法，保留临时窗口状态日志 | 26/26 通过，0 失败、0 跳过；原本在 Main 跳过的 `testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission` 本轮通过 | 两条 SavedTasks 挂载前后仍只有一个 foreground-active scene，app key window 与临时 window 正常交接；本组独立顺序未复现 AX 失效。IntelligentUI 那项跳过也并非固定行为。 |
| savedtasks-r11 | 余下 7 组 Chat UI 前序、IntelligentUI 原 AX 控制方法，再运行同两个 SavedTasks 方法 | 55/55 通过，0 失败、0 跳过；IntelligentUI 控制方法也通过 | SavedTasks 挂载前后仍只有一个 foreground-active scene，app key window 与临时 window 正常交接。存在一个非 key、可见、level 1 的 `UITrackingElementWindowController`，但此时 AX 查找正常；本组独立顺序也未复现 Main 失效。 |
| savedtasks-r12 | 3 个 IOS 前缀窗口方法（AgentSettingsVisual、IOSChatBottomOverlay、CodexModelCatalog 截图）、IntelligentUI AX 控制方法和同两个 SavedTasks 方法 | 6/6 通过，0 失败、0 跳过 | SavedTasks 挂载前后仍只有一个 foreground-active scene，app key window 与临时 window 正常交接，上一 fixture 已隐藏且 root=nil；这组前序也未复现 Main 失效。 |

两个用例分别是 `testRenderedEditorSaveUpdatesExistingAction()`（按钮）和 `testRenderedListReloadsAfterRevisionAndRunsPlainTask()`（普通文本）。r3 的扩大遍历同时访问 UIKit 子视图、`accessibilityElements`、`accessibilityElementCount`，包括 `isAccessibilityElement == false` 的对象；未查到任何标签。1800 点窗口高于物理视口仍是未单独验证的变量，不能从该库存推定视口裁切。iOS SDK 公开 `automationElements`（iOS 17 起），但 r5 结果不支持将它作为本次必要修复。

生产 `IOSPhoneControlSavedTasksView.swift` 明确构造预期标签。Main r1/r2 和独立 r6 时，该文件及两个 SavedTasks 测试文件均与 HEAD、初始快照字节一致。测试文件原始 SHA-256 为 `31e87e0c066331a9416a252f927bfb4e1ac8ae72d282034bdc7f5be822fce137`；视觉测试为 `cfeb9b9542a533426ef7f99ba2ec348914dc134733e6ad8779ab21b638f51054`；生产视图为 `5c91a9e984dff1b1121b68f80490f600b7f2fbad787d65d762566995aa0aa524`。r7 后 Root 为调查 Main r2 临时加入只读窗口日志，r3 挂起受控终止后已精确清理并核对原 SHA；这些结果排除 Phase 6 源文件改动导致的回归，却不能确认全部执行顺序中的 AX 状态。

当前结论限定为：原始 SavedTasks 测试在独立 r6 全绿，在 Main r1/r2 全量顺序中均有 12 项 AX 查找失败；r8–r12 的五组分段前序均未复现，带临时日志的 Main r3 和清理后的 Main r4/r6 中 16 项也全过。公开 `automationElements` 读取没有必要性证据，未采纳。完整运行中 Root 曾观察到外部 AX 返回 0×0，但目前没有唯一可证实的触发条件；若再次失效，需重现时的进程内 scene/window 快照才能决定是否修某个测试宿主。不能把外部查询宣布为唯一根因，也不能声称 iOS 系统版本退化或生产应用 AX 已验收。真实应用辅助功能验收应走独立进程 `XCUIApplication`；仓库已有 `IOSIntelligentUIComponentAXAcceptanceTests` 可作架构参考，不应以跳过、放宽标签或增加轮询代替行为验证。

证据：`/tmp/amber-phase6-main-r1-{summary,tests}.json`、`/tmp/amber-phase6-main-r2-{summary,tests}.json`、`/tmp/amber-phase6-main-r3.log`、`/tmp/amber-phase6-main-r4-{summary,tests}.json`、`/tmp/amber-phase6-main-r5-bootstrap-diagnosis.json`、`/tmp/amber-phase6-main-r6-{summary,tests}.json`、`/tmp/amber-phase6-main-focused-r3.log`、`/tmp/amber-phase6-main-savedtasks-r4.log`、`/tmp/amber-phase6-main-savedtasks-r5.log`、`/tmp/amber-phase6-main-savedtasks-r6-{summary,tests}.json`、`/tmp/amber-phase6-main-savedtasks-r7.log`、`/tmp/amber-phase6-main-savedtasks-r8.log`、`/tmp/amber-phase6-main-savedtasks-r9.log`、`/tmp/amber-phase6-main-savedtasks-r10.log`、`/tmp/amber-phase6-main-savedtasks-r11.log`、`/tmp/amber-phase6-main-savedtasks-r12.log` 及 r6 截图清单 `/tmp/amber-phase6-main-savedtasks-r6-attachments/manifest.json`。r1 通过截图分别位于 `/tmp/amber-phase6-savedtasks-pass-attachments/33D6D720-4984-49D9-9A67-9D14370D64BE.png` 与 `/tmp/amber-phase6-savedtasks-pass-attachments/BA0D0C03-FD79-41BB-9658-4F2D4CECAB6C.png`。
