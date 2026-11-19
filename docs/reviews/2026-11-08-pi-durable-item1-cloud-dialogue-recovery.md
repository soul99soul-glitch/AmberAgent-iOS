# Amber iOS Redesign 借鉴 Pi Durable 改进方案 — 第 1 项「云端发送、重连与停止」与 1B（P1-07 / P1-08 / P2-07 / P2-08）实施与验证报告

- **日期**：2026-11-08
- **工作树**：`/Users/arquiel/.synara/worktrees/ce201253131e`
- **基线状态**：`HEAD = 84176fde736d3056e7a30fb1df66e44b7d378f5c`，`MERGE_HEAD = 6e89805b2667098e8ef523545915ca77c7b5f4a2`（完整保留三树集成与 R1–R3 WIP）
- **本轮范围**：
  1. **第 1 项**：「1. 云端发送、重连与停止」闭环实现；
  2. **1B 阶段**：与 `MacGatewayStore` / `CloudDialogue` / `CloudTasks` 直接相邻的四项审查修复（**P1-07、P1-08、P2-07、P2-08**），未越界修改其他所有者负责项。

---

## 第一部分：第 1 项「云端发送、重连与停止」实现与证据

### 1.1 真实调用链与闭环逻辑

1. **发送意图先落盘（Persist-before-POST）**：
   - `ChatView.sendCloudDialogueFromComposer(text:)`（`iosApp/iosApp/Chat/Composer/ChatViewComposer.swift`）与 `MacGatewayCloudDialogueSheet.sendInput()`（`iosApp/iosApp/Navigation/AmberHostSwitcherPill.swift`）按 `(selectedCloudDialogueWorkItemId ?? "main") + "\0" + text` 指纹绑定固定 `requestId`；用户未改内容重试时复用原 `requestId`，修改内容后生成新 `requestId`。
   - `MacGatewayStore.sendCloudDialogueMessage(text:requestId:)`、`sendCloudWorkItemInput(workItemId:text:requestId:)`、`stopCloudWorkItem(workItemId:requestId:)`（`iosApp/iosApp/MacGatewayCloudDialogue.swift`）在调用 `client.postDialogueMessage` / `postWorkItemInput` / `stopWorkItem` **之前**，先将 `MacGatewayCloudDialoguePersistedSubmission`（含 `gatewayId`、`deviceId`、`kind`、`requestId`、`workItemId`、`text`、`updatedAt`、`isConfirmedNotExecuted = false`）通过 `persistCloudDialogueState(immediately: true)` 同步落盘。
2. **模糊失败认领与未受理补发（Receipt Recovery & Idempotent Replay）**：
   - `MacGatewayCloudDialoguePersistedSubmission.isAwaitingReceiptConfirmation` 仅在 `receipt == nil && !isConfirmedNotExecuted` 时为 `true`；对 `400 invalid_request`、`401 unauthorized`、`404 task_not_found`、`409 request_id_conflict` / `task_terminal` 等确定未执行错误立即标记 `isConfirmedNotExecuted = true` 并结算。
   - 冷启动或重连后，`pollCloudDialogueEvents()` 在拉取增量事件前自动调用 `reconcilePendingCloudDialogueSubmissionsIfNeeded()`：
     - 先查 `GET /v2/dialogue/receipts/{requestId}`；若服务端已受理（返回 `200 OK` 回执），调用 `applyReceipt(...)` 写入 `eventId` 与 `workItemIds`，随后事件流中的 `user_message` 通过 `unmergedCloudMainSubmissions` 自动与本地气泡合并为单条消息并接回原 `WorkItem`；
     - 若返回 `404 receipt_not_found`，自动使用同一配对身份、原 `requestId` 与原内容补发。
3. **普通直接回答与委托 `WorkItem` 等待分离**：
   - `MacGatewayCloudDialogueEvent.isUpfrontAcknowledgement` 识别 `amberd` 在 Router 规划前发出的自然确认（`ack:<inputId>` 或无 `workItemId`/`outcome` 的 `"收到，我来处理…"`），不提前将主消息回执标为 `.consumed`、不提前结束 `isAwaitingCloudMainReply`，也不触发建议词（`MacGatewayCloudSuggestions.updateCloudSuggestionTrigger`）。
   - 自然确认先于 `WorkItem` 到达且用户切回「本机」时，`isAwaitingCloudMainReply` 保持 `true` 使后台轮询持续运行直至接回 `WorkItem` 并完成 `task_result` 结算；若收到非自然确认的真实直接回答（无 `WorkItem`），`isAwaitingCloudMainReply` 立即结束，不被任务等待锁住。
4. **停止中间态「已请求停止」与执行端终态竞态保护**：
   - `MacGatewayCloudDialogueWorkItemProgress` 新增向后兼容字段 `isStopRequested: Bool`。提交停止或收到 `stop_requested` 时仅在 `outcome == nil` 下进入 `isStopRequested = true`、展示 `"已请求停止"` 中间态并隐藏重复的「补充 / 停止」按钮；最终 `outcome` 与 `statusLine` 由执行端 `task_result` 决定，若 `task_result(outcome: .completed)` 先到或与 `stop_requested` 交错，保留服务器成功终态。
5. **事件游标恢复与 `event.id` 幂等去重**：
   - `ingestCloudDialogueEventsPage(_:requestedAfter:)` 按稳定 `event.id` 去重，确保重复页或重叠页中同一事件最多应用一次（不重复累加 `processEventCount`、不回退终态），同时保留晚到未见事件的历史 `seq` 位置。

### 1.2 第 1 项 TDD 红绿灯原始证据

- **红灯（RED）**：
  ```text
  ✘ Test upfrontAcknowledgementBeforeWorkItemKeepsPollingAfterSwitchingToLocalAndDirectReplySettlesImmediately() recorded an issue at MacGatewayCloudDialoguePollingTests.swift:191:9: Expectation failed: store.isAwaitingCloudMainReply
  ✘ Test upfrontAcknowledgementBeforeWorkItemKeepsPollingAfterSwitchingToLocalAndDirectReplySettlesImmediately() recorded an issue at MacGatewayCloudDialoguePollingTests.swift:201:9: Expectation failed: store.cloudDialogueCursor == 3
  ✘ Test persistsSendIntentBeforeReceiptAndRecoversOnColdStartViaReceiptOrResend() recorded an issue at MacGatewayCloudDialogueTests.swift:738:46: Expectation failed: defaults.data(forKey: MacGatewayStore.cloudDialogueStateKey)
  ✘ Test stopRequestShowsIntermediateStateAndPreservesCompletedSettlementInRaceAndDuplicatePages() recorded an issue at MacGatewayCloudDialogueTests.swift:827:9: Expectation failed: stoppingProgress.displaySingleLine == "已请求停止"
  ✘ Test stopRequestShowsIntermediateStateAndPreservesCompletedSettlementInRaceAndDuplicatePages() recorded an issue at MacGatewayCloudDialogueTests.swift:851:9: Expectation failed: settledProgress.outcome == .completed
  ```
- **绿灯（GREEN）**：
  ```text
  ✔ Test upfrontAcknowledgementBeforeWorkItemKeepsPollingAfterSwitchingToLocalAndDirectReplySettlesImmediately() passed after 1.027 seconds.
  ✔ Test persistsSendIntentBeforeReceiptAndRecoversOnColdStartViaReceiptOrResend() passed after 0.017 seconds.
  ✔ Test stopRequestShowsIntermediateStateAndPreservesCompletedSettlementInRaceAndDuplicatePages() passed after 0.003 seconds.
  ```

---

## 第二部分：1B 阶段（P1-07 / P1-08 / P2-07 / P2-08）实现与证据

### 2.1 四项问题定位与真实调用链修复

1. **P1-07 — 旧连接迟到的 401 / 普通错误隔离**：
   - `MacGatewayStore.forgetIfRevoked(_:for:)`（`iosApp/iosApp/MacGatewayStore.swift`）新增 `expectedClient` 校验：当 `self.client !== expectedClient` 时直接返回 `false`。
   - `MacGatewayStore.swift`（`setMonitored`、`sendTestPush`、`decide`、`createSchedule`、`scheduleAction`、`uploadPushToken`）、`MacGatewayCloudDialogue.swift`（`sendCloudDialogueMessage`、`sendCloudWorkItemInput`、`stopCloudWorkItem`、`refreshCloudDialogueReceipt`、`pollCloudDialogueEvents`、`reconcilePendingCloudDialogueSubmissionsIfNeeded`）、`MacGatewayCloudTasks.swift`（`submitCloudTask`、`refreshCloudTask`、`cancelCloudTask`）、`CloudConfigStore.swift`（`refreshCloudConfig`、`applyCloudBundle`）及 `AgentSoulTools.swift`（`syncCloudSoulIfNeeded`、`pushCloudSoul`）的所有异步 `catch` 分支均先校验 `guard self.client === client`，阻止旧连接迟到的 401 解除新配对或普通错误污染新连接状态。
2. **P1-08 — 发送等待期间新编辑草稿与后改目标保护**：
   - `ChatComposerLocalState`（`iosApp/iosApp/Chat/Presentation/ChatScreenLocalState.swift`）新增 `cloudDialogueSubmitGeneration`、`beginCloudDialogueSubmit(text:targetWorkItemId:)` 与 `finishCloudDialogueSubmit(...)`，并接入 `ChatView.sendCloudDialogueFromComposer(text:)`（`iosApp/iosApp/Chat/Composer/ChatViewComposer.swift`）与 `MacGatewayCloudDialogueSheet.sendInput()`（`iosApp/iosApp/Navigation/AmberHostSwitcherPill.swift`）。
   - 当旧请求成功返回时：仅在 `currentInputText == submittedText` 时清空草稿，仅在 `selectedWorkItemId == submittedTargetWorkItemId` 时清空目标 `WorkItem`，仅在 `lastCloudDialogueFingerprint == submittedFingerprint` 时轮换 `activeCloudDialogueRequestId`；当旧请求迟到失败时：仅在 `generation == cloudDialogueSubmitGeneration && currentFingerprint == submittedFingerprint` 时写入 `cloudDialogueErrorMessage`，绝不清除新在途状态或误清/污染新草稿。
3. **P2-07 — 云任务合并拒绝更旧版本及已确定终态后的非终态**：
   - `MacGatewayStore.mergeCloudTaskSnapshot(at:workItem:detail:replayed:)`（`iosApp/iosApp/MacGatewayCloudTasks.swift`）统一收敛 `submitCloudTask`、`refreshCloudTask`、`cancelCloudTask` 的状态合并：
     - 若 `workItem.updatedAtMs < existingWorkItem.updatedAtMs`，拒绝更旧版本快照；
     - 若 `existingWorkItem.state.isTerminal && !workItem.state.isTerminal`，拒绝终态确立后的非终态回退；
     - 当 `detail == nil`（如 `submitTask` 重放回执）且已有 `existing.detail` 时保留已有详情并同步最新 `workItem`。
4. **P2-08 — 解除配对与缓存写入在同一持久化所有者序列化**：
   - `MacGatewayPersistenceCoordinator`（`iosApp/iosApp/MacGatewayStore.swift`）在每次连接变更（`init`、`configureForTesting`、`confirmPairing`、`forget`）时单调递增 `sessionEpoch` 并绑定当前 `activeIdentity`（`gatewayId + "\0" + deviceId`）。
   - `persistCloudTasks`、`persistCloudDialogueState`、`confirmPairing` 与 `forget()` 在捕获快照时同步记录 `(epoch, identity)`，并在写入或擦除及 `Self.persistenceQueue` 异步落盘前校验 `coordinator.canCommit(epoch:identity:)`：旧连接排队的异步快照无法跨过 `forget()` 重建已擦除的缓存，也不会擦除或污染随后立即配对的新连接。

### 2.2 1B 四项 TDD 红绿灯原始证据

- **红灯（RED）**：
  ```text
  ✘ Test staleClient401AndOrdinaryErrorsNeverUnpairOrPolluteReplacementConnection() recorded an issue at MacGatewayCloudDialogueTests.swift:975:9: Expectation failed: store.connection == newConnection
  ✘ Test editingDraftOrChangingTargetDuringCloudSendPreservesNewDraftAndTargetAndIgnoresStaleFailure() recorded an issue at MacGatewayCloudDialogueTests.swift:1013:9: Expectation failed: currentInputText == "等待期间新编辑的草稿 B"
  ✘ Test editingDraftOrChangingTargetDuringCloudSendPreservesNewDraftAndTargetAndIgnoresStaleFailure() recorded an issue at MacGatewayCloudDialogueTests.swift:1014:9: Expectation failed: selectedWorkItemId == "work:2"
  ✘ Test editingDraftOrChangingTargetDuringCloudSendPreservesNewDraftAndTargetAndIgnoresStaleFailure() recorded an issue at MacGatewayCloudDialogueTests.swift:1040:9: Expectation failed: composerState.isSubmittingCloudDialogue
  ✘ Test cloudTaskMergeRejectsOlderSnapshotsAndNonTerminalAfterTerminalInGetAndCancelRace() recorded an issue at MacGatewayTests.swift:569:9: Expectation failed: store.cloudTasks.first?.effectiveWorkItem?.updatedAtMs == 1793500002000
  ✘ Test cloudTaskMergeRejectsOlderSnapshotsAndNonTerminalAfterTerminalInGetAndCancelRace() recorded an issue at MacGatewayTests.swift:583:9: Expectation failed: store.cloudTasks.first?.state == .cancelled
  ✘ Test cloudTaskMergeRejectsOlderSnapshotsAndNonTerminalAfterTerminalInGetAndCancelRace() recorded an issue at MacGatewayTests.swift:595:9: Expectation failed: store.cloudTasks.first?.state == .completed
  ```
- **绿灯（GREEN）最终测试输出（3 个 Suite 共 32 项测试全部通过）**：
  ```text
  ✔ Test receivesDelayedResultsWithoutAnotherSend(switchToLocal:) with 2 test cases passed after 2.109 seconds.
  ✔ Test cancelledPollCannotClearItsReplacement() passed after 0.105 seconds.
  ✔ Test upfrontAcknowledgementBeforeWorkItemKeepsPollingAfterSwitchingToLocalAndDirectReplySettlesImmediately() passed after 1.027 seconds.
  ✔ Suite "Cloud dialogue idle delivery" passed after 3.248 seconds.
  ✔ Test standaloneResultNormalizesEveryDisplayConsumerAndPersistence() passed after 0.005 seconds.
  ✔ Test persistedLegacyEnvelopesNormalizeWithoutResettingCursorOrReceipts() passed after 0.005 seconds.
  ✔ Test inputAndStopRequestsEncodeStrictContractKeysAndValidate() passed after 0.003 seconds.
  ✔ Test cloudDialogueContractEndToEndFlowInPlaceProgressAndFollowupCancellation() passed after 0.020 seconds.
  ✔ Test cloudDialogueSessionHealthAndMainTurnPendingReplyLifecycle() passed after 0.014 seconds.
  ✔ Test cloudSessionHealthAndReplyStateReflectGatewayState() passed after 0.005 seconds.
  ✔ Test persistsSendIntentBeforeReceiptAndRecoversOnColdStartViaReceiptOrResend() passed after 0.017 seconds.
  ✔ Test stopRequestShowsIntermediateStateAndPreservesCompletedSettlementInRaceAndDuplicatePages() passed after 0.003 seconds.
  ✔ Test staleClient401AndOrdinaryErrorsNeverUnpairOrPolluteReplacementConnection() passed after 0.020 seconds.
  ✔ Test editingDraftOrChangingTargetDuringCloudSendPreservesNewDraftAndTargetAndIgnoresStaleFailure() passed after 0.001 seconds.
  ✔ Suite "Mac Gateway Cloud Dialogue v1" passed after 0.096 seconds.
  ✔ Test cloudTaskStorePersistsRequestRetriesSameIdPollsResultAndCancels() passed after 0.021 seconds.
  ✔ Test cloudTaskMergeRejectsOlderSnapshotsAndNonTerminalAfterTerminalInGetAndCancelRace() passed after 0.004 seconds.
  ✔ Test unpairSerializesWithQueuedPersistenceAndProtectsImmediateRepair() passed after 0.012 seconds.
  ✔ Suite "Mac Gateway" passed after 0.063 seconds.
  ✔ Test run with 32 tests in 3 suites passed after 3.417 seconds.
  ** TEST SUCCEEDED **
  ```

---

## 第三部分：实际修改文件与 SHA-256 指纹汇总

| 文件路径 | 行数 | SHA-256 | 涉及项 |
|---|---:|---|---|
| `iosApp/iosApp/MacGatewayStore.swift` | 627 | `e0a49a90bcb3dca215e16aca8c27e11ccd7a2ad0b9cba8284e4f0401c08c5dba` | P1-07、P2-08 |
| `iosApp/iosApp/MacGatewayCloudTasks.swift` | 664 | `bb0ac991b823ed3200b9c56669fb20aa4741794ac0b1a4cfcf3819927ecc285e` | P1-07、P2-07、P2-08 |
| `iosApp/iosApp/MacGatewayCloudDialogue.swift` | 1481 | `9a6ba998a21cd1633d0cd8d1115efe6f81b2f13726f6158fa3dbace2e5c82f0d` | 第 1 项、P1-07、P2-08 |
| `iosApp/iosApp/MacGatewayCloudSuggestions.swift` | 24 | `a5b3de0b3a6a0f3488fea9347929e884317246e9175ab7016581e6e595f61f31` | 第 1 项 |
| `iosApp/iosApp/CloudConfigStore.swift` | 141 | `1595bc9789abafbe1c8e9d8dc0dcef1a47bdf5566fd4f95850e4cb25ce8b3098` | P1-07 |
| `iosApp/iosApp/AgentSoul/AgentSoulTools.swift` | 392 | `cec856306f5965e1a5fb1f3cd7e46a978b6cbd1bbc8dae781b124adca2df4d58` | P1-07 |
| `iosApp/iosApp/Chat/Presentation/ChatScreenLocalState.swift` | 166 | `a52b30f8c75255d3a31f7337143fc155f47818e792df05f78e13bee00cf41bc6` | P1-08 |
| `iosApp/iosApp/Chat/Composer/ChatViewComposer.swift` | 1159 | `3c44d6aab36cb524da06b9ae1ddacfad3843acbf23e257a3ba7a7c17874901ea` | P1-08 |
| `iosApp/iosApp/Navigation/AmberHostSwitcherPill.swift` | 767 | `724b8bf4093ffefa0f3be2a227c92605e34e3e324054111610f6675640ad51ac` | 第 1 项、P1-08 |
| `iosApp/iosAppTests/MacGatewayCloudDialogueTests.swift` | 1044 | `fafd92deb2657fd908e6720647a1891307a537d8d2be967320e8644f787eaf51` | 第 1 项、P1-07、P1-08 |
| `iosApp/iosAppTests/MacGatewayCloudDialoguePollingTests.swift` | 219 | `38a66ce2e6dcd9a1bfc76c53a4a984c4640b093f3bf9f62a1a82eba97b0a8437` | 第 1 项 |
| `iosApp/iosAppTests/MacGatewayTests.swift` | 709 | `90819add076751c81129d47c359adeaf9a8f21768753dc514e849032b1df2f31` | P2-07、P2-08 |

---

## 第四部分：未验证边界

- 本轮仅运行直接受影响的模拟器定点测试（`MacGatewayCloudDialogueTests`、`MacGatewayCloudDialoguePollingTests`、`MacGatewayTests` 共 32 项测试），未跑全量测试套件、未部署线上或重装真机、未调用真实付费模型接口。
- 未触碰其他所有者负责的审查项（如 P2-06/09/10/11 及记忆/对话其他模块），工作树现有三树集成与 R1–R3 WIP 完整保留。
