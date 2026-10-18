# Native reasoning-collapse canary: read-only evidence review

**判断：r6 的 28.6667 pt > 25 pt 是一次真实门禁失败，但现有证据不支持将它归为 Phase5 新引入的回归。** 同一测试体在 Phase3 迁前 baseline 已以相同断言失败（26.0 pt）；Phase3 迁后和 Phase4 又有通过。当前没有逐帧样本或有效的同二进制定点复跑来判明 r6 多出的漂移来自哪一帧、哪一层。不能把失败记作通过，也不能直接称作环境噪音。保留原 25 pt 阈值和生产代码，等待 Root 的实际 P5 final 结果。

| 现有结果包 | 此方法结果 | 可核对证据 |
|---|---|---|
| `/tmp/amber-phase3-baseline.xcresult` | **失败：26.0 > 25.0 pt** | 迁前 `ChatSwiftUIStreamReplayTests`，iPhone 17 Pro / iOS 26.5，方法耗时 3.241 s；`/tmp/amber-phase3-baseline-summary.json` 同一断言 |
| `/tmp/amber-phase3-integration-r10.xcresult` | 通过 | 迁后 `ChatNativeTimelineReplayCompletionTests`，3.237 s |
| `/tmp/amber-phase3-scroll-overlay.xcresult` | 通过 | 迁后同一方法，3.225 s |
| `/tmp/amber-phase3-scroll-final.xcresult` | 通过 | 迁后同一方法，3.206 s；97 项运行另有其他 case 失败 |
| `/tmp/amber-phase4-main-r3-tests.json` | 通过 | 同一方法，3.228 s |
| `/tmp/amber-phase5-primary-r6.xcresult` | **失败：28.666666666666515 > 25.0 pt** | 893 项结果中 889 pass、2 fail、2 skip；同一断言，方法耗时 4.037 s |

`/tmp/amber-phase3-focused.xcresult` 的 3 项结果没有包含此方法，不能把整包通过算作本 canary 通过。Root 随后取消的 `test-without-building` 尝试也没有运行此方法：启动日志无 Test Suite，采样中没有 XCTest/iosAppTests image；xcresult 的 `totalTestCount: 1, failedTests: 1` 是 `iosApp (23409) encountered an error` / `Testing was canceled` 的 harness 条目，实际 XCTest 方法数为 **0**。它既不是一次 canary 失败，也不是一次通过。

## 测试体与可达路径

`iosApp/iosAppTests/ChatNativeTimelineReplayCompletionTests.swift:493-637` 与迁前快照 `/tmp/amber-phase3-source-baseline/files/iosApp/iosAppTests/ChatSwiftUIStreamReplayTests.swift:2381-2525` 的**完整方法体逐字相同**，SHA-256 都是 `05552c0649d2d7155de9234cc9e499220ae2d4032defd04a81ecd6fc4214243f`，含 25 pt 和 2 pt/1 pt 尾段门槛。Phase3 support audit `/tmp/amber-phase3-render-session-support-hashes.json` 记录 `HarnessModel`、`ScrollFrameProbe`、`makeFixture`、`longConversation`、`pump`、`pumpUntil` 的归一化 body SHA 在搬迁时不变，只有访问级别变化。当前测试使用本地 `UIWindow`/`UIHostingController`，经 `HarnessModel.send` 推送 `NativeChatTimelineView` 的用户追加、流式文本、`assistantStreamClosed` 和 `generationCompleted`，同时让 reasoning `finishedAt` 落地。`ScrollFrameProbe` 按最终正文长度筛选每帧，以 `contentHeight - contentOffsetY` 到最终值的最大差测试终态收敛。

可达的 `MessageBubbleView` 前 737 行（包括 reasoning 卡和文本分支）与迁前快照逐字相同，SHA-256 均为 `1144ee9c347760f69f009c570bbbc041236bfe6f2f37d5dedd7a686b65b4d102`；其后差异是其他组件搬出。`NativeTimelineScrollDriver.swift` 与 `NativeTimelineScrollCore.swift` 当前内容和 HEAD 相同（各 SHA-256 `fcdcdffe106f5a68d505fb40c3c09edd1c46f40988e6f6823ffcc9a274c44816`、`27d086cf7957a5d44e4d6231344da3da97076b1e5f3c78125847b566fe1dbdee`）。`NativeChatTimelineView.swift` 相对 `/tmp/amber-phase3-native-before-empty-overlay.swift` 的差异只有欢迎页空状态 overlay 和 `.emptyState` 行改为 `EmptyView`；本方法已有 6 轮历史和用户/助手行，空状态分支不可达。

`ChatReasoningCard` 是此方法可达组件；工作树相对 HEAD 有 `autoExpandThinking` 参数和相关状态更新差异，不能声称整条生产路径 SHA 完全不变。迁前测试快照的 `MessageBubbleView` 已向该卡传入 `autoExpandThinking`，说明该调用不是 r6 才出现；当前默认值为 `true`，但缺少与迁前同一时点的整卡源码快照，无法仅靠现有材料证明卡内部逐字相同或排除它对个别帧的影响。这一限制不改变“迁前同一断言已失败”的事实。

## 证据边界

r6 结果只保存最大锚点漂移断言消息，没有每帧 `contentHeight`、`offsetY`、发生时间或 reasoning 卡高度。`XCTAssertLessThanOrEqual` 失败会继续运行后续断言；结果包只报告这一条失败，因此尾段 2 pt、backjump 1 pt 和最终贴底断言没有另报失败，但没有保存它们的数值。不能从 28.6667 pt 单值断言是持续缓动、一次布局残差、主线程调度还是新逻辑。P5 finalr1 正在由 Root 运行，只有实际 XCTest 方法进入并产生结果才可补充本判定。本审计没有修改源码、阈值，也没有启动构建、测试或 GUI。
