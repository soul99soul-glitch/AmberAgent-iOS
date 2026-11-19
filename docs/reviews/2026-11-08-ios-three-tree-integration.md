# iOS 三树实际集成与真机安装阻断

## 当前结论

- 面板、记忆实际 WIP 已精确应用到对话 worktree，不是只做 apply-check。
- 当前三树源码已进入同一 Xcode 编译/链接快照：**Swift 接缝 9/9 通过，KMP provider 39/39 通过**。
- 新 OpenAI iOS provider 已编译，`Shared.framework` 已重新 link，并被本次 Swift 测试宿主消费。
- 原两个 UU 已仅在 index 标记解决，文件内容未为收尾而修改；其余 index entries 完全保持原值。
- **真机安装/启动未完成。** 构建通过后 `device_list(includeShutdown: true)` 只返回两台 `ios-simulator`，没有可选真机目标。按要求停在这一阻断点，没有猜历史 UDID、没有使用替代设备工具、没有把模拟器包当作真机包。
- 未 commit/push；因禁止提交，`MERGE_HEAD` 保留，不能宣称 merge transaction 已完全结束。相邻 continuation 标题失败仍单列，未修改或复跑。

## 三树基线与保留证据

唯一集成/构建根：`/Users/arquiel/.synara/worktrees/ce201253131e`。另外两树只读，不在那里修改、构建或提交。

对话树：

- HEAD `84176fde736d3056e7a30fb1df66e44b7d378f5c`。
- MERGE_HEAD `6e89805b2667098e8ef523545915ca77c7b5f4a2`。
- 集成前完整 tracked WIP SHA-256：`9c94318e8191e8a8e8e6b905e81fb511358b5c14655809164b43881ef3fee4bc`，与 Codex 最后 PASS 快照一致。

面板树 `/Users/arquiel/.synara/worktrees/cdc6ffe4dc5f`：

- HEAD `6e89805b2667098e8ef523545915ca77c7b5f4a2`，无 MERGE_HEAD；7 个 unstaged 文件。
- 实际 WIP SHA-256：`5f731a016912c430361359d056b4ae980fe9319c51f23bb4854413aaab470dfb`。

记忆树 `/Users/arquiel/.synara/worktrees/74b538d173c7`：

- HEAD `6e89805b2667098e8ef523545915ca77c7b5f4a2`，无 MERGE_HEAD；4 个 unstaged 文件。
- 实际 WIP SHA-256：`99fe02cba4fa486b755cef293c5ad83481958dae760305a33ebd6d53b671988c`。

三树 status、HEAD、MERGE_HEAD、完整/staged/unstaged 补丁和逐文件 SHA 均已保存。对话原 index 二进制、原两个 UU 的 stage 1/2/3 blob 也备份在同一证据目录。没有删除既有 untracked 报告。

- [完整基线指纹](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/baseline.json)
- [应用后精确性检查](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/applied-verification.json)
- [构建后最终保留检查](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/final-verification.json)

## 实际集成路径与冲突处理

原样应用面板 7 路径：

```text
iosApp/iosApp/AmberDesignSystem.swift
iosApp/iosApp/Chat/Composer/ChatViewComposer.swift
iosApp/iosApp/CouncilRunner.swift
iosApp/iosApp/Navigation/AmberDuetChrome.swift
iosApp/iosApp/Navigation/AmberHubStore.swift
iosApp/iosAppTests/AmberDuetTaskRedesignTests.swift
iosApp/iosAppTests/IOSCouncilRoomExecutionTests.swift
```

原样应用记忆 4 路径：

```text
ai-provider-openai/src/commonMain/kotlin/app/amber/ai/provider/openai/OpenAIKmpProvider.kt
ai-provider-openai/src/jvmTest/kotlin/app/amber/ai/provider/openai/OpenAIResponsesGenerationTest.kt
iosApp/iosApp/IOSMemoryExtractionCoordinator.swift
iosApp/iosAppTests/IOSMemoryExtractionTests.swift
```

执行顺序：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
base=iosApp/build/ThreeTreeIntegration20261108
git apply --check "$base/memory/full.patch"
git apply --check "$base/panel/full.patch"
git apply "$base/memory/full.patch"
git apply "$base/panel/full.patch"
```

没有新文本冲突，未采用整文件覆盖、ours/theirs 或降弱测试的解决方式。唯一与既有对话 WIP 重叠的是 `AmberDesignSystem.swift`；面板 policy hunk 与对话回复呈现设置 hunk 均保留。其余 10 个 donor 文件在集成树中逐字匹配来源树 SHA；原对话已改文件除该明确共享文件外全部保持原 SHA。两个 donor 树收尾 status 与补丁指纹也均不变。

原两个 UU 的 worktree 文件已无冲突标记，按本轮新授权执行：

```bash
git add -- iosApp/iosApp/Chat/Message/MessageBubbleView.swift \
  iosApp/iosAppTests/ChatTimelineReviewRegressionTests.swift
```

标记前后 `git diff HEAD --binary` 逐字相同，证明没有为 index 收尾修改源码。读取备份 index 与当前 index，对这两路径之外的全部 entries 逐字比较相同；原冲突 blobs 留在基线备份。当前 `git ls-files -u` 为空，但 HEAD 和 MERGE_HEAD 均维持原值，没有 commit。

没有修改顶栏或产物架，也没有额外手工修复任何集成代码；本轮源码变化仅为上述 donor 原补丁。

集成后完整 tracked WIP SHA-256：`0295dec165d00f4aba3b16b12cbf96a17df4ba94bb5c30d413e263c2d82c346b`。

- [集成后的完整 tracked patch](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/integrated-final.patch)

## KMP 定点验证

普通非登录 shell 没有默认 Java Runtime，最初 `./gradlew` 调用 exit 1；给 shell 工具设置 JAVA_HOME 也被该工具的保护规则忽略。没有安装 Java 或修改系统配置，最终直接用已存在的 JDK 17 执行同一 Gradle wrapper：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
/opt/homebrew/opt/openjdk@17/bin/java \
  -classpath gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain \
  :ai-provider-openai:jvmTest \
  --tests 'app.amber.ai.provider.openai.OpenAIResponsesGenerationTest' \
  --tests 'app.amber.ai.provider.openai.OpenAIKmpProviderRequestTest' \
  --tests 'app.amber.ai.provider.openai.OpenAIRefusalGenerationTest' \
  > iosApp/build/ThreeTreeIntegration20261108/gradle-provider-tests-explicit-jdk17.log 2>&1
```

实际 exit **0**。直接解析当前 `jvmTest` XML：

- `OpenAIResponsesGenerationTest`：6 tests，0 failures/errors。
- `OpenAIKmpProviderRequestTest`：28 tests，0 failures/errors。
- `OpenAIRefusalGenerationTest`：5 tests，0 failures/errors。

合计 **39/39**。Mock HTTP 输入，无真实 provider、Key 或付费模型调用。

- [Gradle 原始日志](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/gradle-provider-tests-explicit-jdk17.log)
- [当前 XML 汇总与指纹](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/gradle-test-summary.json)

## 同一集成快照的 Xcode 构建与定点测试

精确命令：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/ReviewTargetedTests \
  -clonedSourcePackagesDirPath iosApp/build/ExperimentalDeviceBuild/SourcePackages \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath iosApp/build/ThreeTreeIntegration20261108/IntegratedSeams.xcresult \
  -only-testing:iosAppTests/IOSMemoryExtractionTests/testExtractionOmitsHardcodedMaxTokensBudgetAndFailsHonestlyOnEmptyOrReasoningOnlyResponse \
  -only-testing:iosAppTests/AmberDuetTaskRedesignTests/testFloatingSheetSwipeDownSmoothnessPolicyAndScrollBridge \
  -only-testing:iosAppTests/AmberDuetTaskRedesignTests/testNeedsDecisionClassificationAndStructuredDeliverableExtraction \
  -only-testing:iosAppTests/IOSCouncilRoomExecutionTests/testEmptyOpeningTopicFailureIsNotMarkedRetryableAndNewRunSettlesPriorRetryableCouncil \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testSubAgentRoutePublishesReadableResultsOnLoadAndRefresh \
  '-only-testing:iosAppTests/IOSShareSupportTests/assistantEnvelopeCopyShareAndExportsMatchPublishedDisplayText()' \
  '-only-testing:iosAppTests/MacGatewayCloudDialogueTests/standaloneResultNormalizesEveryDisplayConsumerAndPersistence()' \
  '-only-testing:iosAppTests/MacGatewayCloudDialogueTests/persistedLegacyEnvelopesNormalizeWithoutResettingCursorOrReceipts()' \
  -only-testing:iosAppTests/ChatTimelineReviewRegressionTests/testP1IncrementalProjectionMatchesFullBuildAndSkipsHistoricalBridging \
  test > iosApp/build/ThreeTreeIntegration20261108/xcode-integrated-seams.log 2>&1

xcrun xcresulttool get test-results summary \
  --path iosApp/build/ThreeTreeIntegration20261108/IntegratedSeams.xcresult --format json \
  > iosApp/build/ThreeTreeIntegration20261108/xcode-integrated-seams-summary.json
```

实际 xcodebuild exit **0**；xcresult **9 tests passed / 0 failed / 0 skipped**，总 action 约 180.5 秒，包含构建/链接和测试。

不是 `test-without-building`：原始日志明确含 `:ai-provider-openai:compileKotlinIosSimulatorArm64`、`:shared:compileKotlinIosSimulatorArm64`、`:shared:linkDebugFrameworkIosSimulatorArm64`，Gradle 子构建 `BUILD SUCCESSFUL in 24s`。因此没有仅消费集成前旧 Shared.framework。Swift 编译/链接包括面板、记忆、对话当前源码。

- [Xcode 原始日志](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/xcode-integrated-seams.log)
- [Xcode 原始结果摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/xcode-integrated-seams-summary.json)
- [集成 xcresult](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/IntegratedSeams.xcresult)
- [App/Shared 产物元数据](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ThreeTreeIntegration20261108/integrated-build-metadata.json)

本轮只选了受影响的三树接缝，没有全量、长回放或重复上一轮整套 22/33 项。相邻 continuation 标题已知失败不在本轮验证集，未据此宣称全聊天回归通过。

## 构建产物和真机阻断

已实际生成：

- 平台：iOS Simulator arm64，scheme `iosApp` / Debug。
- bundle：`app.amber.ios`，版本 `1.0.0`，build `1`。
- App：`/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ReviewTargetedTests/Build/Products/Debug-iphonesimulator/iosApp.app`。
- executable SHA-256：`e8710a0551e20fc2a4d5cf14732612aa5b27b78c90e24d588b850a3106276269`。
- 本次 Shared 输入 SHA-256：`cdc5b7e071769300f33ad37d9a2e751f6275aa2a3d2fc96b8374280bd746d545`。

Xcode 成功后调用 `device_list({includeShutdown: true})`，宿主工具只暴露：

1. iPhone 17 Pro，iOS 26.5，booted，platform=`ios-simulator`，UDID=`F3D5299E-EEA6-4098-BF61-AB1C516933C0`。
2. 一台 shutdown 的 iOS 26.5 Simulator，同样不是物理设备。

**没有可选真机目标。** 这只能说明当前 Synara 设备控制面未暴露真机，不能据此断言 USB 真机一定未连接。没有尝试用脚本中的历史 UDID、simulator UDID 或 devicectl/其他替代工具进行真机操作。

按“设备不可用则停止”要求：

- 未构建本轮已签名的 iphoneos 包；当前 Simulator 包不可用于真机。
- 未调用真机 `device_install`，未卸载、未清数据、未覆盖安装。
- 未调用真机 `device_launch`，没有本轮真机启动结果或运行/手感证据。
- 不把 Xcode 运行 Simulator 测试宿主当作用户要求的真机安装。

下一步需要先让真机在 Synara 设备面板/`device_list` 中成为可选目标；再确认其既有 bundle/team/构建变体，构建匹配的签名 iphoneos 包，以同 bundle 保数据覆盖安装并拉起。该步骤尚未完成，不能从本报告推断已装机。

## 其余限制

- 没有触发真实 Key、付费模型、线上 provider 或云端服务；仅构建、受控 fixture、隔离存储和 mock HTTP。
- 没有重新做全屏视觉、动态字号、键盘/安全区、真实拖动/120Hz、后台系统行为或 Reduce Motion 验收；不宣称真机手感通过。
- donor 源码及其 Git 状态保持原状；所有实际集成与构建都在指定对话 worktree。
- `git diff --check` 仍报告既有 `ChatAsyncTaskIsolation.swift` EOF 空行，本轮没有顺手删除。
- 原 index 冲突已标记解决，但 pending merge 仍需后续被授权提交时才能真正结束。本轮不生成提交。
- 报告留在唯一指定 worktree；不为绕过此前 Library workspace 限制复制到主仓或直接写 Library。
