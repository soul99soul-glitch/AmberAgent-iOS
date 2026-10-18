# NovelCreation 只读审查（2026-10-18 当前工作树）

范围：已读 iosApp/AGENTS.md、NovelCreation/AGENTS.md；当前 tracked 与 untracked 模块均按生产代码审阅。审查中没有改产品代码、运行测试或构建。以下是沿真实 owner/入口二次复核后的候选，交 root 独立复核及实施。

## N1 / P1 分支删章写全局 discardedAt，污染兄弟分支

- 位置：NovelReducer.swift:1046-1052。deleteFromManuscript 只从目标 branch.workingChapterSelections 删除，却先给全局 chapters[chapterIndex].discardedAt 赋值。
- 可达：已有收录正文后 fork，两个分支共享 chapter IDs；在 A 分支通过“从正文移除”或 novel_delete_chapters 审批删除共享章。
- 影响：B 分支仍保留该章 selection/head，但 NovelWorkspaceLedger.liveWorkingSelections、NovelInjectionPlanner.swift:672、正文/导出路径都按全局 discardedAt 过滤，B 的正文、上下文与导出会失去该章。B 的 head/sync 状态没有相应改变。
- 二次复核：fork 共享 chapter identity 是既有设计；命令、UI、审批都带明确 branchID，按分支移除正文并非全项目删除。注释声称为了恢复与过滤而设 discardedAt，不足以抵消其跨分支副作用。已有全局 discardChapter 与分支 deleteFromManuscript 是不同领域操作。
- 最小修复：分支 remove 不给全局 chapter 打 discard 标记，保留该分支 selections / workingRevision / needsSync / approval ledger 的既有事务。检查后续 restore/undo 行为，不引入新 tombstone 机制。
- 测试 seam：NovelBranchingTests / NovelApprovalCommitTests 既有 fork + collected fixture；A 删除后检查 B selections、live manuscript、injection 和 markdown export 仍含共享章，A 不含；A sync/undo 保持契约。

## N2 / P1 新建 state snapshot 遗漏 chapterPlots，清空逐章剧情并可绕过 stale 门禁

此问题有三个同类 owner 写点，不能只修一处：

1. NovelBranchOperations.swift:1071-1083 clarifyCharacterIdentity：复制 facts、summary、highlights 却未传 chapterPlots（默认 []）。确认人物身份后所有剧情模块清空。
2. NovelFactTransactions.swift:762-775 commitStateDeltaCollection：生产代笔 Session/NovelSessionGhostwriteChapter.swift:109 -> adjudicateAndCollectGhostwriteChapter -> commitGhostwriteAdjudication 确实调用该 state-delta collection。收录下一章后既有 modules 清空，新章也没有 module。
3. NovelManualEditTransactions.swift:677-690 finalizeManualSync：老项目手改/分支删章后的真实 sync 路径创建新 snapshot，同样漏 chapterPlots。

- 可达/影响：项目已有 unresolvedEntityNames 和 chapterPlots；中间章原子手改会把后续模块标 stale，但 branch 仍 synchronized。此时允许身份澄清，清空 modules 后 NovelWorkspaceLedger.hasUnresolvedChapterPlots 立即变 false，正式生成门禁被绕过，workspace 的逐章剧情导出同时丢失。自动收录与 sync 则造成同样的数据丢失，无需故障或并发。
- 二次复核：人物身份澄清不应改动剧情；D-B 原子正文+plot 与 D-D stale gate 已是当前明确契约。普通 deterministic collect 已更新 chapterPlots，可作真实参照，说明其它 snapshot 创建点漏字段不是有意回退旧模型。
- 最小修复：clarify 直接传 state.chapterPlots；代笔收录按最终 chapter selections 保留之前模块并更新本章 module（复用 NovelWorkspaceLedger 现有 relink/aligned helper 与 deterministic excerpt，不新增另一套事实抽取）；manual sync 从当前 working versions 重建受影响模块并保留不受影响前缀，不能盲目透传 stale 或默认为 []。
- 测试 seam：NovelCharacterIdentityTests 增带 stale modules 的 clarification；NovelGhostwriteAdjudicationTests 从已有 module 收录新章；NovelManualEditSyncTests 用带 modules 的旧 needsSync/suffix rebuild fixture，断言 sync 后模块覆盖 current manuscript，既有正确模块不丢。

## N3 / P1 Workspace quiet-rest 瘦身删除失败 run，生产错误消息失去精确重试

- 位置：NovelWorkspaceProjectStore.swift:600-605，guard 将 .failed 与 .completed 都视为可全量删除，随后 activeRuns=[]、receipts/factAttempts 清空，并在 609-614 删除 startRun ledger。
- 可达：生产 NovelCreationComposition 创建 workspace-native 项目；provider 返回 isRetryable=true 的失败（可有 partial）。NovelGenerationReducer.fail 落 failed run，NovelFileProjectRepository.installValidatedCommit 返回 persistableAtRest(document)，creation 安装该快照，session refresh 随即看到 activeRuns 不含失败 run。
- 影响：Session/NovelSessionActionAvailability.swift:32-35 找不到 index.runByID，不给失败消息生成 retryGeneration；Session/NovelSessionRunLifecycle.swift:79-87 直接要求 projectSnapshot.activeRuns 含 failed/interrupted run，retryLastTerminal/hydrateTerminalState 也无法恢复精确重试。用户仅能重新发送；原始 mode/granularity/request 信息不可由错误正文恢复。
- 二次复核：completed 历史瘦身有明确性能目的，当前不据此要求保留全部 completed receipts。failed 与 interrupted 一样仍服务活跃重试入口，删除它是当前生产 consumer 的实际损坏。内存仓 fixture 不做 quiet-rest projection，现有 lifecycle/retry tests 掩盖该差异。
- 最小修复：failed run 与 interrupted/running 一样保留既有历史链；调整 kept 条件即可，不新增缓存/恢复格式。completed 瘦身范围保持现有设计。
- 测试 seam：用 NovelFileProjectRepository(workspaceNative:true) + scripted retryable .failed 跑 DefaultNovelCreation；refresh/reopen 后 failed run 与 failure/source user message 仍可检索，row retry enabled，重试保持原文、mode、granularity；另保留 completed receipt slimming 原测试。
- 附带观察（不扩大本次必修）：completed run/startRun ledger 剪除亦令 actor exact completed replay 与 post-install terminal reconciliation 找不到 run；目前尚未证明独立用户入口，不将其当成必须保存所有历史的理由。

## N4 / P2 流式围栏规范化销毁原始上下文，分包 opener/closer 泄露到正文

- 位置：Session/NovelSessionStreamingPresentation.swift:109-111、138-146。
- 可达：raw delta 被 append 到 presentationBuffer 后，normalizePresentationBufferIfNeeded 把 normalized 输出写回同一 buffer。provider 先发 "```" 再发 "markdown\n正文"，前一拍已丢 opener，markdown 被当正文；或先发 "```markdown\n正文" 再发 "\n```"，closer 失去对应 opener 而保留。
- 真实链路：NovelLiveModelAdapter textDelta -> NovelGenerationStream delta -> NovelSessionRunLifecycle.consume -> enqueuePresentationDelta。分块边界任意，以上均合法。
- 影响：流中语言标签/closing fence 出现在正文，成功 terminal authoritative 会突然纠正，failed/persistenceBlocked(nil authoritative) 可以保留错误 buffered target。
- 二次复核：strip 外层围栏是既定设计；问题是用已 normalize 的文本作为下个 raw delta 的基底。testFencedTerminalProseContinuesFromVisiblePrefixInsteadOfSnapping 只发送单 delta 完整围栏，不覆盖该边界。
- 最小修复：现有 presentation owner 保留累积 raw snapshot，以完整原文计算规范化 pacing target；不要追加到已经去围栏的 target。不新增 pacer/队列/fallback。
- 测试 seam：NovelSessionTailPresentationTests，分别 opener split 与 closer split，complete 前断言裸正文，终态断言内容不跳变。

## N5 / P2 对 reasoningDelta 做前缀推断，吞掉重复或前缀增量

- 位置：Session/NovelSessionStreamingPresentation.swift:13-20。
- 可达：NovelLiveModelAdapter.swift:1049-1052 / 1084-1087 从 choice.delta 读取 reasoning 原样发 reasoningDelta；NovelGenerationStream.swift:638-642 原样 broadcast。输入 ["哈","哈"] 应为 "哈哈"，当前为 "哈"；["A","AB"] 应为 "AAB"，当前为 "AB"。
- 影响：可见思考丢字；按明确契约 reasoning 不入 manuscript，因此不描述为正文或候选稿丢失。
- 二次复核：adapter 的 choice.message 也使用同事件，说明生产端需表达真实语义；不能靠 UI 字符串前缀猜测 delta/replacement。不同句子样本通过不构成重复 token 的反证。
- 最小修复：明确生产端事件 delta 语义，消费者直接 append。确有完整 message reasoning 的入口应在该入口明确 replacement/先转换增量；不要在 presentation 猜前缀。
- 测试 seam：NovelSessionTailPresentationTests 连续重复与前缀 reasoning delta、pause 后断言完整思考，继续正文完成后断言 manuscript 不含 reasoning；对应 adapter full-message 路径补行为验证。

## 已排除 / by design

- start await 后部分状态写回没有逐项 binding guard：握手期间 workspace.acquireSessionOperation 持 isPerforming，selectProject/selectBranch 拒绝切换，缺 guard 本身不能证明污染。
- attach stale 回调：已有 attemptID + binding token + tail runID 校验。
- 页面 detach 继续生成：App owner 继续持久化是契约；页面只解观察。
- 结构化建议失败不将 partial JSON 收录正文：正确协议边界。
- completed receipts 瘦身本身：存在明确当前性能设计，只有 failed retry 的直接回归列为必修。

建议 phase：领域状态完整性（N1/N2）-> durable retry（N3）-> 流式呈现（N4/N5）。每 phase 按受影响 seam 运行测试，再交独立 subagent 审查实际 diff；若 N4 触及 shared pacing/scroll，执行 iosApp/AGENTS Native Timeline/viewport 门禁。最后跑当前职责映射中的 Novel 端到端组合。中文 IME、真实 provider、长文追底、真机后台仍单列未验收。
