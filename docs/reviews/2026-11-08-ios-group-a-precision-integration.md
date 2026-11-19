# Amber iOS A 类修复精确集成报告（Pi Durable 第 1 项 + 1B + Task / Dialogue / Memory 三组合入）

- **日期**：2026-11-08
- **主工作树**：`/Users/arquiel/.synara/worktrees/ce201253131e`
- **基线状态**：
  - `HEAD`：`84176fde736d3056e7a30fb1df66e44b7d378f5c`
  - `MERGE_HEAD`：`6e89805b2667098e8ef523545915ca77c7b5f4a2`（完整保留 pending merge、staged/unstaged 及 `integrated-final.patch` 既有 WIP）
  - 集成基线补丁：`iosApp/build/ThreeTreeIntegration20261108/integrated-final.patch`（SHA-256: `0295dec165d00f4aba3b16b12cbf96a17df4ba94bb5c30d413e263c2d82c346b`）
- **状态声明**：28 项审查修复目前在各自 owner 侧交付完毕，主树 `ce201253131e` 的精确集成结论以本报告实测结果为准。

---

## 1. 实际应用顺序、源补丁校验与重叠接缝语义处理

### 1.1 源补丁指纹核验与合入顺序

按 `task → dialogue → memory` 顺序对三份相对 `integrated-final.patch` 的独立增量执行 `git apply --check` 与 `git apply`：

| 顺序 | 分组与覆盖项 | 源补丁路径 | SHA-256 | `git apply --check` / `git apply` |
|---:|---|---|---|---|
| 0 | **主树前置增量**：Pi Durable 第 1 项 + 1B（P1-07、P1-08、P2-07、P2-08） | 已在 `ce201253131e` 就地完成（快照备份于 `pre-3group-diff-head.patch`） | — | 已通过 32/32 前置定点验证 |
| 1 | **Task 组**（9 文件，覆盖 P2-06、P2-09、P2-10、P2-11） | `/Users/arquiel/.synara/worktrees/ebbcf0b4cffb/docs/reviews/2026-11-08-ios-task-ownership-only.patch` | `6d7b80f493e611937b814efb1075a2d8d40599612b4ad2b9d8d3bda11907e1f9` | `exit 0` / 直接无冲突应用 |
| 2 | **Dialogue 组**（9 文件，覆盖 P2-01、P2-02、P2-03、P2-04、P2-05、P1-10） | `/Users/arquiel/.synara/worktrees/d47bc146c629/docs/reviews/ios-dialogue-residuals-20261108/independent.patch` | `0aaf8408932eeaf013c2c3bed77696b8342c37054cb165fbd9ddcbec81d27b91` | `exit 0` / 直接无冲突应用 |
| 3 | **Memory 组**（19 文件，覆盖 P1-01、P1-02、P1-03、P2-12） | `/Users/arquiel/.synara/worktrees/1ceb6259d7c7/docs/reviews/2026-11-08-ios-memory-boundaries-only.patch` | `cc482f53d49e4cbdc31b7c9872c87e04d939390d1e01d43777a33bf3484a8076` | `exit 0` / 直接无冲突应用 |

### 1.2 重点重叠文件语义复核

1. **`iosApp/iosApp/MacGatewayCloudTasks.swift` 与 `iosApp/iosAppTests/MacGatewayTests.swift`（1B × Task 组）**：
   - `MacGatewayCloudTasks.swift`：第 278 行保留 Task 组的 `AmberUnifiedTaskBuilder.resultPreview(from: detail?.resultMarkdown)` 统一归档预览投影；第 395–660 行保留 1B 的 `persistCloudTasks(_:forceAsync:)` 持久化代际校验（P2-08）、`mergeCloudTaskSnapshot(at:workItem:detail:replayed:)` 版本单调性与终态防回退（P2-07）以及 `catch` 分支 `guard self.client === client`（P1-07）。
   - `MacGatewayTests.swift`：同时保留 Task 组的 `unifiedBoardKeepsDistinctRunsWithSameTitleAndMergesOnlyScheduleIdentity` + 面板 `.retry` 动作重放断言（P2-06 / P2-10）与 1B 的 `cloudTaskMergeRejectsOlderSnapshotsAndNonTerminalAfterTerminalInGetAndCancelRace`（P2-07）、`unpairSerializesWithQueuedPersistenceAndProtectsImmediateRepair`（P2-08）。
2. **`iosApp/iosApp/IOSSubAgentOutput.swift`（Task 组 × Dialogue 组）**：
   - 第 104–545、885–1015 行保留 Dialogue 组的 `summaryFromStoredResult`、`displaySnapshot`、`hasLeadingMarkdownLink`（保护 `[{"run_ended":true}](url)` 等合法 Markdown 链接，P2-02）与运行态/历史归档统一展示净化（P2-05）；
   - 第 546–785 行保留 Task 组的 `explicitDecision`（支持 `needs_user_decision` / `needs_decision`）、`linesOutsideCodeFences`（支持反引号、波浪线与更长外层围栏）及 `decisionSignal` 行首标记与否定词过滤（P2-11）。
3. **`iosApp/iosApp/Navigation/AmberHubStore.swift`（Task 组 × Memory 组）**：
   - 第 391–400 行保留 Memory 组的 `allowsGlobalMemory(conversationId:)` 与 `inheritConversationBinding(from:to:)` 运行会话级 Hub 记忆隔离（P1-01 / P1-03）；
   - 第 721–1290 行保留 Task 组的 `seenIdentities` 按来源/请求/执行身份去重、结构化决策优先与 `userFacingResultMarkdown` 归档剥离（P2-09 / P2-10 / P2-11）。

---

## 2. 导出的独立集成增量补丁

使用临时 Git index（未改动工作树真实 `.git/index`）导出以下两份可独立复核的二进制安全补丁，并通过 `git apply -R --check` 双向校验：

1. **[2026-11-08-ios-group-a-three-patches-only.patch](2026-11-08-ios-group-a-three-patches-only.patch)**：
   - 范围：仅本次合入的 `task + dialogue + memory` 三组增量（相对 1B 完成态快照）。
   - SHA-256：`f7f5c3d5db718e98de0f857addfecb87a36bbbd04ebc5908100816cf7f051c85`
2. **[2026-11-08-ios-group-a-integrated-delta.patch](2026-11-08-ios-group-a-integrated-delta.patch)**：
   - 范围：相对 `integrated-final.patch` 的完整本轮增量（含 `Pi Durable 第 1 项 + 1B + task + dialogue + memory`，共 45 个文件）。
   - SHA-256：`ff8241702f038e0035f3a8ead7ae3ec0eb91a97f068b9729f745a4106e33da31`

---

## 3. KMP 与 iOS 定点验证原始证据

### 3.1 KMP `ConversationForkTest` 与 `Shared.framework` 重链

- **执行命令**：
  ```bash
  /opt/homebrew/opt/openjdk@17/bin/java -classpath gradle/wrapper/gradle-wrapper.jar \
    org.gradle.wrapper.GradleWrapperMain :core:conversation-storage:jvmTest \
    --tests app.amber.core.storage.conversation.ConversationForkTest \
    :shared:linkDebugFrameworkIosSimulatorArm64 --console=plain
  ```
- **原始结果**：
  - `:core:conversation-storage:jvmTest`：`tests="11" skipped="0" failures="0" errors="0"`（含新增 `forkPreservesMemoryPolicyAndMarksInheritedUserSources`）。
  - `:shared:linkDebugFrameworkIosSimulatorArm64`：`BUILD SUCCESSFUL in 28s`（已重新编译 `:shared:compileKotlinIosSimulatorArm64` 并重链模拟器 `Shared.framework`）。

### 3.2 iOS 模拟器定点测试汇总（`IntegratedFocused20261108.xcresult`）

- **设备环境**：`iPhone 17 Pro`（UDID `F3D5299E-EEA6-4098-BF61-AB1C516933C0`，iOS 26.5 `23F77`）
- **总计**：**113 个测试用例（114 次运行），112 个用例通过（113 次运行通过），0 跳过，1 个已知基线失败**。

| 测试套件 / 范围 | 通过 / 总数 | 跳过 | 失败 | 说明 |
|---|---:|---:|---:|---|
| `MacGatewayCloudDialoguePollingTests` | 3 / 3（4 runs） | 0 | 0 | 覆盖第 1 项 `ack:` 先于 `WorkItem` 切回本机持续轮询与直接回答立即结束等待 |
| `MacGatewayCloudDialogueTests` | 10 / 10 | 0 | 0 | 覆盖第 1 项发送前落盘认领/补发、停止与完成竞态、重复事件页去重，以及 1B `P1-07`、`P1-08` |
| `MacGatewayTests` | 20 / 20 | 0 | 0 | 覆盖 Task 组 `P2-06` 面板精确重试、`P2-10` 看板同名身份去重，以及 1B `P2-07`、`P2-08` |
| `AmberDuetTaskRedesignTests` | 20 / 20 | 0 | 0 | 覆盖 Task 组 `P2-09` 归档投影、`P2-10` 跨 owner 同名任务、`P2-11` 否定/代码块/结构化待拍板 |
| `IOSDialogueTimelineResidualTests` | 2 / 2 | 0 | 0 | 覆盖 Dialogue 组 `P2-03` child 结果卡片标题边界、`P2-04` 流式尾行 facts 增量准备 |
| `IOSForegroundApprovalResumeTests` | 2 / 2 | 0 | 0 | 覆盖 Dialogue 组 `P1-10` 前台恢复保留待审批工具与待消费补充 |
| `ChatAsyncReActLoopTests`（保活接缝 2 项） | 2 / 2 | 0 | 0 | 覆盖 Dialogue 组 `P2-01` 同 ID 可见正文增长刷新保活而重复/空白/reasoning 不误刷 |
| `IOSSubAgentOutputTests` | 10 / 11 | 0 | 1（已知基线） | 覆盖 Dialogue 组 `P2-02` JSON-looking Markdown 链接、`P2-05` 快照/归档净化；唯一失败为已知基线格式断言 |
| `IOSAgentExperienceTests` | 13 / 13 | 0 | 0 | 覆盖 Memory 组 `P1-02` 凭据脱敏与旧记录过滤、`P2-12` 空候选保护 |
| `IOSMemoryExtractionTests` | 20 / 20 | 0 | 0 | 覆盖 Memory 组 `P1-01` 隔离 Hub 跳过提炼与运行中变更阻断、`P1-03` 继承消息不提炼、`P2-12` 仅重试经验写入 |
| `ChatMemoryContextToolTests` | 9 / 9 | 0 | 0 | 覆盖 Memory 组 `P1-01` 隔离 Hub 拒绝召回 override 与 13 项 `memory_tool` 动作 |
| `IOSOrchestrationToolTests`（spawn 2 项） | 2 / 2 | 0 | 0 | 覆盖 Memory 组 `P1-03` `spawn_agent` 继承隔离 Hub 绑定与 `polluted` 记忆模式 |

### 3.3 单列既有基线失败（未删改断言、未伪装绿灯）

- `IOSSubAgentOutputTests/testReportSummaryAcceptsOnlyCompletePublicFields()`：
  - 原始失败输出：
    ```text
    XCTAssertEqual failed: ("Optional("最终结论\n关键产出要点：\n• 发现一\n• 发现二")") is not equal to ("Optional("最终结论\n发现一\n发现二")")
    ```
  - 归因：已在修复前 `integrated-final.patch` 基线独立复现，系既有摘要格式化前缀差异，按要求单列保留原断言。

---

## 4. 最终 45 个集成增量文件清单与 SHA-256 指纹

| 文件路径 | 行数 | SHA-256 |
|---|---:|---|
| `core/conversation-storage/src/commonMain/kotlin/app/amber/core/storage/conversation/ConversationFork.kt` | 112 | `e5fbf63fad49b701c841c5475ce52a1630788e30e47e3159f105975e64065f5c` |
| `core/conversation-storage/src/jvmTest/kotlin/app/amber/core/storage/conversation/ConversationForkTest.kt` | 255 | `29ba8e2882971aceebcb80e0f090e44faf3b1f7ac34acee49843785086395b0e` |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatLocalToolOperations.swift` | 593 | `19811886ffe5af7f53a6e8319f9580e286aa1df4a11f9ed2b636c006cada57bd` |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatRecipeExecution.swift` | 1207 | `9bd4ba51a994ff56937bdfb24f3fb30793b8f5b20d2ebcee6b521677dacba9bc` |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatToolApprovalCompletion.swift` | 817 | `12435548dffd89f4f9131e0a255616aa16ff9b04346ac8f1aba155f0b7ac3042` |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatToolExecutorAdapters.swift` | 903 | `22e8df640118077ddbdcd7214b95585187d42df912d2c3a2b2aa6af0111556ec` |
| `iosApp/iosApp/AgentSoul/AgentSoulTools.swift` | 392 | `cec856306f5965e1a5fb1f3cd7e46a978b6cbd1bbc8dae781b124adca2df4d58` |
| `iosApp/iosApp/Chat/Composer/ChatViewComposer.swift` | 1159 | `3c44d6aab36cb524da06b9ae1ddacfad3843acbf23e257a3ba7a7c17874901ea` |
| `iosApp/iosApp/Chat/Generation/ChatGenerationRequestBuilder.swift` | 809 | `6d27f453e92d7f0a9f55f6ddc40d0d0ce1d174eb5f4fc733ec715b6da81d14f0` |
| `iosApp/iosApp/Chat/Presentation/ChatScreenLocalState.swift` | 166 | `a52b30f8c75255d3a31f7337143fc155f47818e792df05f78e13bee00cf41bc6` |
| `iosApp/iosApp/Chat/Session/ChatAsyncTaskIsolation.swift` | 1156 | `4c9c3a12dda1342bb09c5736c52bce695b04ee13534e33e2a4868b37528e7995` |
| `iosApp/iosApp/Chat/Session/ChatRunComposition.swift` | 707 | `b4e3e25d08a2495bb0ad72f65ae92e0e32b8bc74f0e73564b4938f4183d3ee63` |
| `iosApp/iosApp/Chat/Timeline/ChatTimelineUpdates.swift` | 186 | `892fb2a62e80a3c4665eb3f4524d8434110caef05d9931f6db79ec8d0b460b23` |
| `iosApp/iosApp/Chat/Timeline/NativeTimelineProjectionCache.swift` | 637 | `252a5e28aa40596b396f3f3a9352011b3a56cfa5ffff52e07937d165afbb304c` |
| `iosApp/iosApp/Chat/Timeline/Projection/NativeTimelineProjection.swift` | 1257 | `0bb5d26393bcb7262ff2cd21be64b01494a5a2393a59f2a356f1f977115f9143` |
| `iosApp/iosApp/ChatContextSupport.swift` | 811 | `ff2b18c823ffe4a89efb1f5959de4fa7f4ef33f8b37520e352111c0181abec64` |
| `iosApp/iosApp/ChatSubAgentResultCard.swift` | 515 | `9ec375dfea24715f82e482147c3afc76fac02418c29e9fb19bcacc1286339b50` |
| `iosApp/iosApp/CloudConfigStore.swift` | 141 | `1595bc9789abafbe1c8e9d8dc0dcef1a47bdf5566fd4f95850e4cb25ce8b3098` |
| `iosApp/iosApp/IOSAgentExperiences.swift` | 175 | `063947098cae6201d039c8adcfcfa38e0ae6645a5f27ca1e4568e5df75c0e73d` |
| `iosApp/iosApp/IOSMemoryCorrection.swift` | 145 | `c2736c78b21a10faf34e59f65f140b2d962a4759fbf82f8b913c66ce6ad0db69` |
| `iosApp/iosApp/IOSMemoryExtractionCoordinator.swift` | 706 | `bc874479d33c56d257c8b6bab9228ae217de32e0230c8bfeb093f1a6b3b75d32` |
| `iosApp/iosApp/IOSMemoryPersistence.swift` | 1320 | `8220b029bbd6414c1a574c99676c6ea74f503efcd3df92e029bed60b7a9fef6e` |
| `iosApp/iosApp/IOSSubAgentOutput.swift` | 1015 | `325e123b36d1e26458ceeaf83aa0fd0538f1565c9d49a15951dab76d6d3a4f48` |
| `iosApp/iosApp/IOSThreadOrchestrationToolService.swift` | 1319 | `d9f5530ed73b66bb73d2cf189afb999d9b305f02814ea971f00438d5eb8d7851` |
| `iosApp/iosApp/MacGatewayCloudDialogue.swift` | 1481 | `9a6ba998a21cd1633d0cd8d1115efe6f81b2f13726f6158fa3dbace2e5c82f0d` |
| `iosApp/iosApp/MacGatewayCloudSuggestions.swift` | 24 | `a5b3de0b3a6a0f3488fea9347929e884317246e9175ab7016581e6e595f61f31` |
| `iosApp/iosApp/MacGatewayCloudTaskViews.swift` | 367 | `4b64da4385611038414c2f4087ae4eb934def271cc134bd1354cd7ea2ae3ec7a` |
| `iosApp/iosApp/MacGatewayCloudTasks.swift` | 660 | `4ddbf8d4630e3d1987246cd5c0321f21ee86df3885a1241862a80a1448ac5cd3` |
| `iosApp/iosApp/MacGatewayStore.swift` | 627 | `e0a49a90bcb3dca215e16aca8c27e11ccd7a2ad0b9cba8284e4f0401c08c5dba` |
| `iosApp/iosApp/Navigation/AmberDuetChrome.swift` | 1528 | `1dfcc057657b69c643799236f9cbd470fcb06db4e5ee134e7f3f9c2a2884ff02` |
| `iosApp/iosApp/Navigation/AmberHostSwitcherPill.swift` | 767 | `724b8bf4093ffefa0f3be2a227c92605e34e3e324054111610f6675640ad51ac` |
| `iosApp/iosApp/Navigation/AmberHubStore.swift` | 1456 | `93a8fac98e6aa9c10aee3720001d5e0de37e987a24b6a5176f93ff61f6b28eec` |
| `iosApp/iosApp/Navigation/AmberUnifiedTaskBuilder+Summary.swift` | 299 | `06c40c1a0ac625ffc0d62aa45d57921b067cbeb9c75f85ddd56a894d9483076f` |
| `iosApp/iosAppTests/AmberDuetTaskRedesignTests.swift` | 1600 | `764d2d9b9959412862d7c72beb6ef353bb6bf1105664f964726e479c48381156` |
| `iosApp/iosAppTests/ChatAsyncReActLoopTests.swift` | 1305 | `b4c50d270d610b6de2c3cf796f2af19b0d8b4c97c29038a9e07fb205df308cd6` |
| `iosApp/iosAppTests/ChatMemoryContextToolTests.swift` | 656 | `e7032ba96bb13a697ef3f89752611074a068caa194edf30143a2b89f5edc2cbb` |
| `iosApp/iosAppTests/IOSAgentExperienceTests.swift` | 92 | `8c204e926fe97ba43cd764736316c235650dbe912a6777338709a30eb1b3a588` |
| `iosApp/iosAppTests/IOSChatKernelRunHostTests.swift` | 750 | `c5f43ae92e908058f0b9b9ddaf7e310cb2bee6d01da0dd27f299359512e51db1` |
| `iosApp/iosAppTests/IOSDialogueTimelineResidualTests.swift` | 83 | `f71fe2065567e1dc217ba1e09c184dd3c99adf3aed998f998cd121861b2063e8` |
| `iosApp/iosAppTests/IOSMemoryExtractionTests.swift` | 1024 | `0f6290c7455a2bddce1af4c507b07a2d64337020a407d1a3e907bb5461f32146` |
| `iosApp/iosAppTests/IOSOrchestrationToolTests.swift` | 836 | `a8a4b29f685e897fb2e3efb805facd743ef8ab4283a15e7ab93a87fb114569b5` |
| `iosApp/iosAppTests/IOSSubAgentOutputTests.swift` | 255 | `696fe471f46ad1ea12b4b3ccd69955b6b219b790b09f320cfb574d4efa41494c` |
| `iosApp/iosAppTests/MacGatewayCloudDialoguePollingTests.swift` | 219 | `38a66ce2e6dcd9a1bfc76c53a4a984c4640b093f3bf9f62a1a82eba97b0a8437` |
| `iosApp/iosAppTests/MacGatewayCloudDialogueTests.swift` | 1044 | `fafd92deb2657fd908e6720647a1891307a537d8d2be967320e8644f787eaf51` |
| `iosApp/iosAppTests/MacGatewayTests.swift` | 764 | `02948a283c141e69f59daedd7cb84e289e5dc65bed12770b1eeae215e5eb4be6` |

---

## 5. 未验证边界

- 本轮仅执行 KMP `ConversationForkTest`、模拟器 `Shared.framework` 重链及直接受影响的 iOS 定点测试集合（113 项测试用例），未运行全量测试或长回放。
- 未执行 `git reset`、`commit`、`push`、线上部署或真机重新安装，未调用真实 API Key / 付费模型 / 线上 provider。
- 真机交互手感、系统级前后台挂起恢复、真实 `amberd` 弱网/进程重启端到端表现仍待后续真机验收。
