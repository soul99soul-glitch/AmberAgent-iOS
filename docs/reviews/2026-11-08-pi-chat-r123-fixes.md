# Pi：iOS 对话复核 R1–R3 定点修复

## 结果

本轮仅修复 Codex xhigh 复核报告中的 R1、R2、R3。最终 **22 个测试通过，23 次参数化/普通运行通过，0 失败、0 跳过**；`xcodebuild` exit 0，包含当前源码的 Swift 编译与链接。

相邻 continuation 标题失败不在本轮范围，没有修改或重跑；此前关闭的 F1/F2/F3/F4/S1/S2/S3 不返工。没有自行发起复审、集成或装机。

## 工作区及实际增量

唯一源码/测试工作区：`/Users/arquiel/.synara/worktrees/ce201253131e`。

- HEAD 保持 `84176fde736d3056e7a30fb1df66e44b7d378f5c`。
- MERGE_HEAD 保持 `6e89805b2667098e8ef523545915ca77c7b5f4a2`。
- 原两个 UU 保留：`MessageBubbleView.swift`、`ChatTimelineReviewRegressionTests.swift`。未执行 git add、commit、push、reset 或 merge 收尾。
- 接手时完整 tracked WIP `git diff HEAD --binary` SHA-256 为 `1eed58365b3dae41a7d0c3cbd06c0210bdc364085cfb331f1e527be15edfc3e2`，与本次复核固定快照一致。
- 本轮结束完整 tracked WIP SHA-256：`9c94318e8191e8a8e8e6b905e81fb511358b5c14655809164b43881ef3fee4bc`。此摘要包含所有既有 WIP，不包含 untracked 文档。
- staged diff SHA-1 前后一致：`4501a53110ba2b38230804f88037d8b6fd30cfd9`。
- unmerged stage 1/2/3 列表 SHA-1 前后一致：`17ad4fc4e9af9f7d617516ad1f85a8db904d1f59`。

接手时先保存了下列 8 个文件的精确本轮基线，增量不是相对 HEAD 的全部历史 WIP：

- [本轮独立增量 diff](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-r123-only.diff)
- [逐文件 before/after SHA-256](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-r123-changed-files.json)

4 个生产文件合计 **+41 / -13 行**；4 个已有测试文件新增 **184 行**。另新增本报告，上一轮报告保留。

## R1：真实子会话加载/刷新没有发布 owner

根因：`SubAgentConversationView.loadMessages` 只改 messages 与 signal；Native 无 timelineUpdates，无法取得预先准备的展示正文，安全 fallback 因而将 FINAL_ANSWER 留空。

修改：

- `iosApp/iosApp/SubAgentConversationView.swift`（+9/-3）：视图以 `@State` 持有自己的 `ChatTimelineUpdates`。默认构造独立 owner；初始化参数只为明确注入/测试提供接缝，生产调用没有借用主会话 owner。
- `loadMessages` 在发布 messages/signal 前先调用同一 owner 的 `publish(nextSignal, messages: next)`，再把它传给 Native timeline。
- 既有加载、重试、存储/后台刷新及追加任务后的刷新继续汇入同一 loadMessages，没有增加第二条解析或缓存路径，body 不解码。

验证：`ChatMessagePresentationTests.testSubAgentRoutePublishesReadableResultsOnLoadAndRefresh` 真实挂载 `SubAgentConversationView` 到 UIHostingController，使用临时 IOSConversationStore 落盘后加载，再实际 saveCurrent 触发存储刷新。加载和刷新后均断言：普通 FINAL_ANSWER、mailbox 内嵌 host trailer 的 Markdown、assistant JSON envelope 三种正文正确；底层消息仍保留协议。不是只对 fallback/helper 的模拟输入做断言。

`PerformanceHygieneTests.testChildTimelineAndCopyActionsUseTheirDisplayBoundaries` 补充锁住 load 发布点与 Native 同一 owner 的接线，不读取主会话事件 owner。

## R2：assistant 复制/分享/整段导出绕过展示规则

根因：净化后的气泡与原始 UIMessage 分离，复制仍用原始 toText，shareText 的 assistant 分支也提前返回原文；entries、Markdown、PDF 因此继承泄漏。

修改：

- `iosApp/iosApp/IOSShareSupport.swift`（+6/-1）：assistant 的 shareText 在用户动作/导出边界调用已有 `IOSSubAgentOutputProjection.displayTexts`，保留普通消息原有 toText 的换行与非文本空位语义。用户分支和其他角色保持原逻辑。
- `iosApp/iosApp/Chat/Message/MessageBubbleView.swift`（+6/-1）：复制按钮调用可测试的 copyText；仅 assistant 复用 exporter 的展示规则，普通 user 复制仍保持原文。
- 不修改 message.parts，不把解码放回 body；分享文本、分享图片输入以及整段 entries → Markdown/PDF HTML 共用该入口。

验证：`IOSShareSupportTests.assistantEnvelopeCopyShareAndExportsMatchPublishedDisplayText` 将同一个 assistant 输入同时送进真实消息发布快照、复制文本函数、shareText 和 entries，断言一致；覆盖普通文本、已知 JSON、方括号 Markdown + host trailer、无可读字段的内部包。Markdown 与 PDF HTML 输入均断言没有 host marker、run_ended 或 session_read。额外保留原始 UIMessage 不变及 user 复制不变断言。

本轮没有触发真实系统剪贴板或分享面板，也没有实际生成 PDF/图片；测试覆盖这些动作的实际文本生产函数及共享导出输入。既有 entries、Markdown 角色标签及空导出/Markdown 文件用例也通过。

## R3：云端入站消费者分叉与旧缓存恢复遗漏

根因：入站只净化事件列表使用的局部副本，progress/suggestion 仍接收原始 newEvents；恢复直接还原旧 events/progress，非零 cursor 又使旧事件不会重新到达。

修改：

- `iosApp/iosApp/MacGatewayCloudDialogue.swift`（+20/-8）：增加同一 `cloudDialogueDisplayEvent` 规范化入口，对 assistantReply、taskResult 和 processEvent 中的已知 envelope 复用现有 sanitizer；普通文本不变。
- newEvents 在分发前规范化一次，事件列表、progress、suggestion/终态消费者使用同一份规范化事件。排序、去重、cursor 与终态逻辑不变。
- 恢复时对旧 events 用同一入口，对已有 progress.statusLine 复用相同净化规则；保留 cursor、receipt、followup、submissions、processEventCount、lastEventSeq 等字段。
- 只有旧 events/progress 内容实际变化时才保存迁移结果；再次恢复幂等。不清零 cursor，不要求重拉历史或重新配对。

验证：

- `MacGatewayCloudDialogueTests.standaloneResultNormalizesEveryDisplayConsumerAndPersistence`：无前序 processEvent 的独立 taskResult，断言 visible event、progress、单行展示与持久化结果均可读；收到的原 transport page 值不变。
- `MacGatewayCloudDialogueTests.persistedLegacyEnvelopesNormalizeWithoutResettingCursorOrReceipts`：实际编码旧 assistantReply/taskResult、旧 progress 与 cursor=11 到隔离 defaults；通过 configureForTesting 的真实恢复入口，断言显示与迁移落盘均净化，cursor、选中状态、回执、待消费 followup、进度计数/seq 保留，并再次恢复验证幂等。
- 相关 cloud dialogue 合同、回执/取消、健康状态与 polling 用例通过。只使用本地 mock transport 和隔离 defaults，不联网、不读真实 token/Key。

## 红灯证据

先为真实子会话 owner 注入和复制函数增加不改变原行为的测试接缝，再执行回归，尚未修复 publish/复制/导出/云端逻辑。

第一次命令使用最终命令相同的工程/模拟器/DerivedData 参数，resultBundlePath 为 `iosApp/build/ReviewR123Red.xcresult`；选择了 R1 hosted 用例与 source 接缝用例，两者实际执行且失败。另 3 个 Swift Testing 方法当时因过滤器缺少 `()` 未匹配，未将它们计作已执行。

随后在同一已构建、尚未修复的测试宿主上执行以下精确命令，补齐 R2/R3 红灯：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/ReviewTargetedTests \
  -clonedSourcePackagesDirPath iosApp/build/ExperimentalDeviceBuild/SourcePackages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath iosApp/build/ReviewR23Red.xcresult \
  '-only-testing:iosAppTests/IOSShareSupportTests/assistantEnvelopeCopyShareAndExportsMatchPublishedDisplayText()' \
  '-only-testing:iosAppTests/MacGatewayCloudDialogueTests/standaloneResultNormalizesEveryDisplayConsumerAndPersistence()' \
  '-only-testing:iosAppTests/MacGatewayCloudDialogueTests/persistedLegacyEnvelopesNormalizeWithoutResettingCursorOrReceipts()' \
  test-without-building > iosApp/build/review-r23-red.log 2>&1
```

结果：exit **65**；R1/source 为 **2 failed / 0 passed**，补跑 R2/R3 为 **3 failed / 0 passed**。红灯具体表现为未发布加载结果、复制等于原包、独立结果 progress 仍为原包、恢复后旧 events/progress 仍为原包。

- [R1/source 红灯摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-r123-red-summary.json)
- [R2/R3 红灯摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-r23-red-summary.json)

## 最终精确验证命令

使用 `device_list` 确认的已 booted iPhone 17 Pro / iOS 26.5 / arm64 Simulator；没有创建/启动新模拟器或真机安装。

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/ReviewTargetedTests \
  -clonedSourcePackagesDirPath iosApp/build/ExperimentalDeviceBuild/SourcePackages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath iosApp/build/ReviewR123Final.xcresult \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testSubAgentRoutePublishesReadableResultsOnLoadAndRefresh \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testBracketLeadingMarkdownSurvivesMailboxCardAndExportBoundaries \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testDisplayTextSnapshotsKeepRawProtocolAndInvalidateOnExactBodyChanges \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testSubAgentResultExtractionStripsHostEnvelopePreservesMarkdownAndNeverFallsBackToRawJSON \
  -only-testing:iosAppTests/ChatTimelineUpdatesTests \
  '-only-testing:iosAppTests/IOSShareSupportTests/assistantEnvelopeCopyShareAndExportsMatchPublishedDisplayText()' \
  '-only-testing:iosAppTests/IOSShareSupportTests/entriesKeepOnlyUserAndAssistantWithDisplayText()' \
  '-only-testing:iosAppTests/IOSShareSupportTests/conversationMarkdownLabelsRolesAndImages()' \
  '-only-testing:iosAppTests/IOSShareSupportTests/exportRejectsEmptyConversationAndFallsBackToDefaultTitle()' \
  -only-testing:iosAppTests/MacGatewayCloudDialogueTests \
  -only-testing:iosAppTests/MacGatewayCloudDialoguePollingTests \
  -only-testing:iosAppTests/PerformanceHygieneTests/testChildTimelineAndCopyActionsUseTheirDisplayBoundaries \
  -only-testing:iosAppTests/PerformanceHygieneTests/testMessageBubbleDoesNotDecodeOrSanitizeProtocolEnvelopesDuringRendering \
  test > iosApp/build/review-r123-final.log 2>&1

xcrun xcresulttool get test-results summary \
  --path iosApp/build/ReviewR123Final.xcresult --format json \
  > iosApp/build/review-r123-final-summary.json
```

结果：xcodebuild exit **0**，summary **Passed / totalTestCount 22 / passedTests 22 / failedTests 0 / skippedTests 0**；设备维度共 **23 次成功运行**，因为一个 polling 用例有两个动态参数。action 总时间约 **38.8 秒**。以上为最终 8 文件快照的结果，不以函数抽取探针替代 App 测试宿主。

复跑时给 resultBundlePath 换一个尚不存在的路径，保留本次证据。

- [最终原始测试摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-r123-final-summary.json)
- [最终 xcresult](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ReviewR123Final.xcresult)
- [最终日志](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/review-r123-final.log)

## 其他检查及未验证边界

- 本轮 8 个源码/测试文件的 `git diff --check` 通过。整个既有 WIP 仍有 `ChatAsyncTaskIsolation.swift` EOF 空行警告；该文件本轮未动，没有顺手清理。
- SourceKit LSP 对 4 个生产文件的检查均超时，不能将空诊断宣称为 clean；以实际 Xcode 编译/链接和运行结果为准。
- 测试夹具全部为明确 Synthetic 文本、example.invalid、临时目录/隔离 defaults；不复述真实会话正文。
- 没有执行全量、长流式回放、真实 provider、线上云端、真实系统分享/剪贴板或真机测试；UIHosting 验证的是实际加载/刷新与展示正文快照，不是间距、像素对齐、键盘/安全区或手感验收。
- 没有修改记忆树、面板树、主仓库、KMP provider/runtime/storage；没有迁移或结束既有 merge。
- 未接事件 owner 的非默认 renderer/preview 边界仍维持上一轮状态；本轮明确接通了实际生产子会话 Native 路由，不能再将它混称为 preview。
- Library 工具上一轮已因调用线程的宿主 workspace 与指定 worktree 不同而拒绝归档。本轮不绕过边界向主仓复制或直接写 Library；报告和增量 diff 均留在唯一授权 worktree，可供协调者读取。

下一步交由协调者：在本快照组织原 Codex xhigh 最后定点复核，通过后再执行其负责的集成与保数据覆盖安装。本线程未自行调度复审或装机。
