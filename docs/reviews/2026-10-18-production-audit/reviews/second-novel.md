# Novel 候选独立二次复核

复核者：audit_tools。输入 `audit-novel.md`；只读核查给定 N1-N5，不扩扫、不构建、不测试、不改源码。已读取 NovelCreation/AGENTS.md。结论均为代码与契约复核，运行失败测试仍由实施/Root完成。

| 候选 | 结论 | 优先级判断 | 最小修复边界 |
|---|---|---|---|
| N1 分支移除全局 discardedAt | accepted | P1，兄弟分支正文/注入/导出消失 | 只改 deleteFromManuscript 的全局标记副作用；显式 discardChapter 不顺带改变 |
| N2 chapterPlots 丢失 | accepted | P1，模块丢失且可清除 stale 生成门禁 | 共 4 个 snapshot 创建点；clarify保留、structural sync按选择保留、rebuild/collect按已有规则更新 |
| N3 failed run at-rest剪除 | accepted | P1/P2，真实精确重试消失 | quiet-rest只剪可放弃的 completed，failed 保留历史链；保留原completed优化 |
| N4 raw正文被破坏性normalize后继续append | accepted | P2，仅流式呈现，成功durable稿可纠正 | 同一presentation owner保留raw累积输入，target由完整raw生成；不另建pacer |
| N5 reasoning delta 前缀推断吞字 | accepted | P2，仅可见reasoning，不是manuscript丢字 | 消费端按delta累加，并显式解决producer的full-message快照语义 |

## N1：真实入口与反证

`NovelReducer.deleteFromManuscript` 注释（:1001-1002）明确“当前分支工作稿移除”且函数收到 branchID。:1036 检查目标 branch selection；:1048-1049 却改共享 `chapters` record.discardedAt，然后只删本 branch selection（:1051-1052）。`NovelWorkspaceLedger.liveWorkingSelections` :223-225 对每个分支都过滤该共享标志。因此 fork后两个分支共享同章 selection 的正常状态下，A分支移除就会影响B。这不是全局丢弃命令的预期行为。

最小边界应保留 `workingRevision` / `needsSync` / operation ledger / approval transaction 等原有行为，只去掉分支命令对共享章节的标记。现有源码注释提 checkpoint undo/restore，不能直接证明该全局副作用正确；实施要让A undo恢复selection仍有效，同时B始终保留正文。测试以同章两个分支为输入，检查 A/B live selections、注入、export，而不是仅检查数组计数。

## N2：四个真实写点，均默认空数组

已核查 `NovelStateSnapshotRecord.init`（NovelManuscriptRecords.swift:175-195）`chapterPlots` 默认 `[]`；以下写点未传该参数，不存在自动从旧snapshot继承：

1. `NovelBranchOperations.clarifyCharacterIdentity` :1071-1083。它只解决人物身份，保留所有旧facts/summary，却遗漏模块；branch需synchronized，但可以有stale chapter modules（synchronized和D-D stale是两条门禁）。因此清空 stale 模块确实改变 `hasUnresolvedChapterPlots`（WorkspaceLedger:16-26），不是仅UI显示问题。
2. `NovelFactTransactions.commitStateDeltaCollection` :762-775。核查了真实代笔入口 `commitGhostwriteAdjudication` :210-285 直接调用该函数；其后 :825-854 安装新snapshot/checkpoint，没有后置重建chapterPlots。所以不是被后续helper补齐的暂态。
3. `NovelManualEditTransactions.finalizeManualSync` :677-690。模型rebuild成功后创建snapshot遗漏模块；输入 baseState 的不受影响模块与本次受影响的章节需按既有领域契约保留/重建。不能简单照抄所有旧stale模块。
4. **补充同一问题的遗漏写点** `NovelManualEditTransactions.commitStructuralManualSync` :471-480。无需模型的结构删除/回退路径也漏字段；这里 `rebuildBase.chapterSelections == branch.workingChapterSelections`（:457）已明确覆盖，适合复用现有pointer/relink规则保留匹配模块。只修原报告前三点会遗留真实入口。

测试应覆盖四个owner并最终断言 current snapshot 的模块与working selections/version匹配，clarification不得改变stale flag；不以简单非空断言代替正确性。沿用现有workspace helper，不新增另一套剧情抽取服务。

## N3：不是completed瘦身的泛化反对

`NovelGenerationReducer.fail` :759-784 将失败写成 error/interruptedDraft message，记录原runID与failed terminal。`NovelWorkspaceProjectStore.persistableAtRest` :600-614 认为failed和completed都可删，连同receipts/startRun ledger剪除；`NovelProjectRepository.installValidatedCommit` :398-404 把此剪后快照返回内存owner，因此不是只有重启才出问题。

真实消费者 `NovelSessionActionAvailability` :31-42 必须从runByID找failed run，`NovelSessionRunLifecycle.retryGeneration` :79-87 同样必须从activeRuns找到failed/interrupted记录。这一链路直接证明“retryable失败用户可精确重试”契约受损。代码注释有性能理由支持 completed 剪除，但没有取代 failed consumer 的另一恢复owner。修复保留failed现有历史链即可；不要把该问题扩成永久保存全部completed。

最小测试应使用 workspace-native file repository，脚本失败保存后refresh/reopen，检查 row retry action可用、重试原run的mode/granularity/user文本；不能只用不经过persistableAtRest的memory repository。

## N4：分包围栏及空白确会破坏目标

`NovelSessionStreamingPresentation.enqueuePresentationDelta` :109-111 向target追加raw delta；`normalizePresentationBufferIfNeeded` :138-146 把normalize结果写回同一个target。已核查normalizer `NovelCandidateProseNormalization` :27-72，单独 `"```"` 会按未闭合已知语言opener变 `""`；后续 `"markdown\n正文"` 便不再有opener可识别。先发 `"```markdown\n正文"` 后发 `"\n```"` 则当前target已是 `"正文"`，closer变可见正文。另围栏路径normalizer做trim，先发 `"```markdown\nHello "` 再发 `"world"` 会产生 `"Helloworld"` 的流式target。

因此 accepted，但影响表述必须限定：raw durable run正文仍由generation owner累积，成功terminal authoritative内容可纠正；不能宣称正式候选稿必然永久丢字。过程泄露围栏/吞空格与failed/persistenceBlocked的buffer目标错误已足够构成真实问题。测试应在complete之前等待pacer追平并断言目标，再检查terminal不突然改写；补split opener、split closer、尾空白三种固定分包。

## N5：delta语义确定，full-message入口也要一并处理

`NovelLiveModelAdapter.events/frameEvents` :1049-1052/:1084-1087 从choice.delta抽出reasoning后发送 `.reasoningDelta`；generation stream :638-642只broadcast，session consumer接入applyReasoningPresentation。消费者 :15-18 的前缀判断导致 `["哈","哈"] -> "哈"`、`["A","AB"] -> "AB"`，与delta契约矛盾。即使两delta在同一48ms拍前到达，pendingReasoningText也参与同一逻辑，故不依赖特殊渲染时序。

**修复约束**：adapter `choice.message` :1058-1061/:1093-1096 也把完整reasoning快照标为delta。仅把UI改append后，这类provider末尾full-message快照会重复叠加已显示文本。因此应在已有producer owner明确区分/转换snapshot与delta，或采用明确replacement事件；不要保留UI基于字符串前缀猜语义。测试同时覆盖重复delta、前缀delta和full-message authoritative入口。reasoning不入durable manuscript的现有断言继续保留。

本次没有 rejected 项；上面两处影响限定与修复约束是二次复核收紧点，不应扩大成通用恢复/兼容框架。
