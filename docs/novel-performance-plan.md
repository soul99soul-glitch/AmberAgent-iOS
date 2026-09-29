# 小说创作性能与交互手感优化计划（2026-09-27）

范围：`iosApp/iosApp/NovelCreation/`。先遵守 `AGENTS.md`、`iosApp/AGENTS.md`、`iosApp/iosApp/NovelCreation/AGENTS.md`。
原则：精准下手，只修确认存在的问题；不过度防御、不过度兜底、不过度设计；不伪造 durable 成功（领域提交只给即时 in-progress 反馈，UI 本地态可乐观并在失败时回滚）。

## Phase 0（已完成）
- `NovelSessionView.send()`：发送时同步清空输入框，启动失败且用户未重新输入时回填原文。
- `NovelSessionViewModel.answerAskUser`：卡片乐观标记已回答（`locallyResolvedAskUser`），失败撤回并清 `projectionCache` 以重投影。

## Phase 1 — 提交 / 刷新热路径（发送、回答、保存的等待时间）
1. 每次 commit 都从磁盘全量 reload + 多次全量 validate：`NovelProjectRepository.commitProject(_:expectedRevision:)`（~278-307）被 `NovelGenerationLifecycle.swift` run start（~287）、terminal/cancel（~2264）、`NovelCreation.swift` 通用 mutation（~876）调用。已有快路径 `commitProject(_ transition:)`（~309-372，`canCommitValidatedTransitionFromCache` / `engineLayoutMatchesCache` 守门，失配回落全路径）。在这三个调用点用 `NovelDocumentValidator.validateTransitionFromValidatedCurrent(from:to:)` 构造 transition 走快路径；reducer 内 `validateTransition`（`NovelGenerationReducer.swift` ~242/387/464/652/722/784）当前文档已验证时改为 `validateTransitionFromValidatedCurrent`，避免 next 被重复验证。receipt 校验里的 revision→sha256 在单次 validate 内建字典（`NovelGenerationDocumentValidator.swift` ~239-248）。
2. 启动后第一次 commit 全书重印：`Repository` ~1196 `pointerFingerprints` 初始为空。`finalizeLoadedDocument` 中 `reconcileBookTree` 未重印时 seed 指纹。
3. `refreshCurrentSelection`（`NovelCreationViewModel.swift` ~1537）每次都 `projectSummaries()` 扫目录并无条件赋值 `projects`。会话内刷新（`NovelSessionViewModel.refreshDurable`、session/workspace `perform` 后的 reload、批量润色 300ms 轮询）不刷项目列表；仍刷新时仅在值变化时赋值。
4. `.started` 事件在 `for await` 里 await `refreshDurable`（`NovelSessionViewModel` ~2974）阻塞后续 delta：改为独立 Task（校验 token/runID），完成后 `adoptDurableRunRecord`。
5. actor 内 `updateBackgroundLease` 等 MainActor 调用（`NovelGenerationLifecycle.swift` ~1116、1541-1565）无返回值需求的改 fire-and-forget；`generationRuntimes[runID]?.partialContent.append` 原地追加。
6. `checkoutSidecarFailure`（`NovelCreationViewModel.swift` ~3169）在 view body 同步读文件：改为 refresh/commit 后更新的存储属性。
7. `stateSyncActivity` 每秒无条件赋值（~3453）：仅变化时赋值。
8. 身份卡关联/忽略/澄清（`NovelSessionViewModel` ~1474-1524）`saveMaterial` 已 reload 后又 `refreshDurable`：去掉重复刷新。
9. repository 元数据开销：`isWorkspaceNative` marker 每次 commit 多次读解码 → actor 内按 project 缓存（migrate/seal/delete/replace 失效）；`ensureDirectories` 只做一次。

## Phase 2 — 主线程投影与流式
1. `projectedListModel`（`NovelSessionViewModel` ~726-779）每个 send→complete 周期在主线程全量 `NovelSessionPresentation.project()` 约 6 次。缓存拆两层：durable rows + 索引（按 durable revisions、expandedArchiveIDs、tail runID/messageID 为键），tail 行单独；tail phase / startingUserContent 变化只重建 tail 行（`updatingTransientTail` 不要因 phase 变化返回 nil，NovelSessionPresentation ~815）。`refreshDurable` 后的全量投影放到 detached（仿 `warmProjectionCache`），完成后再装缓存，期间沿用旧缓存 + tail patch。
2. 缓存命中时若 tail renderRevision/reasoning revision 未变，直接返回 cached model（~739-759）。
3. 投影内部：加 `messageByID`，clone/undo 检查用 `checkpointByID`（`NovelSessionPresentation.swift` ~1391/1650/1840）；`"\(availability.action)"`（~2038）改显式 switch token。
4. `normalizedCandidateProse`（`NovelPromptCatalog.swift` ~1678）先做首行 fence 早退；durable 行的 display content 在投影时算好；非流式行 `ChatTextWindow` 不在 init 全量计数（`NovelSessionBubble.swift` ~441，只改 Novel 调用点）。
5. pacer（`NovelSessionPresentationPacer.step` ~158-192，terminal drain ~3660-3712）每 tick 多次全串 count/hasPrefix：在 buffer 里增量维护已显示/目标字符数与 index。
6. Quick Start / 角色提案结构化流（~3550-3609）每个 delta 全量重解析 JSON：原地 append + dirty 标记，markdown 在 48ms flush 时生成一次。

## Phase 3 — SwiftUI 失效范围（打字与 tick）
1. `NovelSessionView` body 读 `inputText`（~666/1490-1496/1557），每次按键重算整屏：把输入行、placeholder、发送按钮、meta 开关拆成只读 `inputText` 的子 View；父 View 只传 binding。
2. `transcriptRow` 每行调用 `IOSAppLanguagePreference.selected().resolvedLanguage()`、`askUserBlocker`、`runtimeActionBlocker`：在 `transcript()` 顶部算一次传入。
3. 身份卡 `identityCardsSection`（~1380-1446）每 tick 计算 `recommendedCharacterIdentityChoice`（mentions×characters×revisions）等：并入现有 identity cache（按 project revision/configRevision/state），并拆为独立 View。
4. composer meta（`composerModelLabel` ×3、`contextRingSnapshot`、`latestContextReceipt` 过滤全部 receipts、`hasArchivableDiscussion` 扫全部消息）：拆为值输入子 View；latestContextReceipt/hasArchivable 在 VM 按 revision 记忆。
5. `NovelWritingContextSheet`（`NovelSessionSheets.swift` ~968）打字重算整张表含 `ghostwriteSwitchBlockers`：计划/弧字段拆子 View；readiness issues 按 project revision+branch 缓存。
6. 收录 sheet（`NovelProjectWorkspaceView.swift` ~561-571）每次 body 重算段落 SHA 与 `currentChapterVersions` 字典三次：打开时算一次按 candidateID+revision 缓存。

## Phase 4 — 交互即时反馈
1. Stop（`NovelSessionView` ~1700，VM `interruptBoundRun` ~3846-3912）：点击即冻结 tail（停 pacer、phase .interrupted、terminalAwaitingRefresh）、按钮显示“正在停止…”；成功后走 `retireTerminalTransientTail` 而非 `clearTransientTail`（当前先清 tail 再 refresh 会让 partial 消失/跳动，违反 AGENTS 终态契约）。
2. 重试生成（~1713/1042，VM ~1630-1652）：先 refresh 再 start 且无 busy 标记可双击。同步设置 in-flight，纳入 isBusy/blocker；尽量直接 start，仅 revision 失配时 refresh 重试一次。
3. 撤销收录/润色（`NovelSessionView` ~302-312，`NovelBranchesView` ~62-68）：pending 状态 + 行/横幅 spinner。
4. 克隆已收录正文（~1724）：`cloningCandidateID` 仿 `adoptingPolishCandidateID`。
5. 共创/代笔切换（`NovelSessionSheets` ~1227/2203）：保存期间布局按 `selectedMode`，内联 spinner 替代整表 overlay。
6. 全部拒绝提案（`NovelMaterialsView` ~98、`NovelCompendiumView` ~743，VM ~1859）：循环里只在最后一次 reload；本地 pending ID 集合让卡片变暗+spinner。单条拒绝/删除资料（Materials ~37/114、Compendium ~186/352/450/767、CharacterPages ~108）同样 pending 变暗。
7. `acceptStalePlot`（VM ~3181）未 acquireOperation 可双击：包进 acquire/release 并在按钮显示 spinner。
8. 分支选择（`NovelProjectSettingsDetailView` ~373）：点击即显示 pending 勾选/spinner，失败回滚。
9. 项目列表重命名/删除（`NovelProjectListView` ~414-440）：立即弹 sheet/确认，selectProject 并行，确认按钮等快照匹配。新建项目（~698）：isSubmitting + “正在创建”。
10. 阅读器整章润色/重写（`NovelChapterReaderView` ~601-626）：同步前置条件通过后立即 dismiss。
11. 本章计划/弧保存（`NovelSessionSheets` ~1631/1642/1701/2213-2340）：本地 isSaving，只锁按钮不锁 IME 字段、不盖整表 overlay。
12. `sessionViewModel.isPerformingAction` 不再禁用 tab bar / 项目标题（`NovelProjectWorkspaceView` ~201/221/759），只有 binding 切换才锁。
13. 导出（`NovelProjectSettingsDetailView` ~392-418）：`exportingKind` in-flight。模型“跟随默认/全局”：选中项 spinner，commit 返回即 dismiss。

## Phase 5 — 持久化余项
1. 恢复 sidecar flush（`NovelGenerationLifecycle.swift` ~1567/1583/2188-2236，`Repository` ~736-761）：actor 内记住上次写入 (sequence, sha) 不再回读文件、只 hash 一次；非强制 flush 单飞后台；terminal 前的强制 flush 保持 await。
2. `waitForGenerationWrite`（`NovelCreation.swift` ~992）、`NovelGenerationLifecycle.swift` ~666 的 `Task.yield()` 忙等 → continuation 等待。
3. `upsertIndexBestEffort`/`writeIndexBestEffort`（~1918-1956）只 patch 当前项目 manifest 条目。
4. blob GC（`ShardedStorage` ~503-507）每次写都解码双 layout+列目录：只删上一 layout 丢弃的 digest，完整 GC 放到 load。
5. `sessions` 段每次 commit 全量重编码（`ShardedStorage` ~372-427）：仅当测试证明所有 reducer 在就地修改消息时都 bump `session.revision`，才按 per-session 指纹缓存；否则跳过本项。

## 验证门禁（每个 phase）
- 编译 + 受影响测试：`NovelSessionViewModelTests`、`NovelSessionReplayTests`、`NovelGenerationLifecycleTests`、`NovelManualEditSyncTests`、`NovelFactTransactionLifecycleTests`、`NovelCreationPresentationTests`、`IOSNovelCreationWiringTests`，涉及 repository 时补跑 stale-revision / out-of-band-edit 相关测试。
- 触碰 transcript/行/滚动/pacing 时再跑 `ChatSwiftUIStreamReplayTests`、`NativeTimelineScrollCoreTests`、`ChatViewportPolicyTests`。
- 命令模板：`xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:iosAppTests/<Suite> test`
- 真机手感（IME、120Hz、后台）标记为待验证，不宣称已验证。
