# Phase 4 首次 green 失败收口：独立 review

结论：**PASS（源码与测试审查），无已确认 blocking findings。** 本 reviewer 未参与该实现；仅审查 phase4-followup-changedpaths.txt 的六个文件及必要的既有验证/持久化入口，没有重审全仓、修改源码/测试或执行构建。Root 下一轮实际 green 尚待完成，此结论不替代运行结果。

审查输入：phase4-followup-diagnosis.md、phase4-followup-implementation.md、先前 phase-4-independent-review.md 与 phase4-rendering-green-summary.json。首次 512 项中的 8 个失败确为四个 delete 验证合同失配和四个正文/plot 文件误计数，未将已通过的流式/reasoning/Markdown/Native 部分重新列入本轮。

## 1. 新写删除转移与历史文档验证职责已分开

实际 validator 路径已通过 rg 和调用入口核对：

- `NovelDocumentValidator.validate` 调用 `NovelOperationLedgerValidation.validateOperationLedger`；它是加载历史文档时的完整静态验证。
- `NovelDocumentValidator.validateTransition/validateTransitionFromValidatedCurrent` 调用 validateChapterTransition；这是新提交相对已存在文档的转移验证。
- `NovelDocumentCheckpointValidation` 的分支时间线继续校验 delete 的 outcomeWorkingRevision 恰为历史 workingRevision+1；本轮没有删除该证据约束。
- `NovelReducer.deleteFromManuscript` 末尾现在调用 validateTransition，直接 reducer 入口也应用新合同；文件 repository 的 commitProject 仍执行相同转移验证。

### 新 delete 不再取得 global discard 写权限

`NovelDocumentValidator.swift:334-347` 的 discardedAt owner 仅允许 chapterDiscardStateChanged 与匹配的 discardChapter/restoreChapter；deleteChapterFromManuscript 不再属于该全局字段的合法写者。因此不能用一个新 delete outcome 为全局 discardedAt 翻转背书。

同时，`:368-389` 并非只撤掉旧断言，而是验证新 delete 的具体效果：

1. operation.kind 必须为 deleteChapterFromManuscript，目标 branch 在 current/next 均存在。
2. 整个 next.chapters 与 current.chapters 完全相等。
3. 原 branch 确实选择目标 chapter；新 selections 精确等于旧 selections 按目标 chapterID 过滤，保留其余 version、次序和内容。
4. workingRevision 恰为原值+1，且与 outcome 中 workingRevision 一致；新 syncStatus 必须 needsSync。

`NovelReducer.swift:1003-1077` 的实际 mutation 与这些检查一致：只移除该 branch selection、增加 workingRevision/项目revision、标 needsSync、记录原有 ledger/approval；不写章节全局记录。没有新增删除协议、状态机或绕过持久化入口。

### 历史 delete 可读，后续 undo 不被永久缺席断言阻挡

`NovelOperationLedgerValidation.swift:440-462` 仍验证 project revision 对齐、workingRevision>=1、branch/chapter 存在，以及 branch 当前 workingRevision 不早于该 delete outcome。仅当当前 workingRevision 恰等于 delete 结果时，要求目标章已不在 working selections；后续 revision 允许其被既有 undo 重新选回。这里不再要求 discardedAt 非 nil，因此历史新旧两种标记均可静态读取。

这与既有 undo 一致：`NovelBranchOperations.undoBranchHead` 在恢复 checkpoint selections 时增加 workingRevision，不回退计数；`NovelDocumentCheckpointValidation` 的历史 timeline 与 `validateNewUndoTransitions` 的 semantic target 验证仍保留。没有把历史 delete 解释成永久不得重选，也没有顺手清除历史全局 marker 或改变显式 discard 语义。

## 2. 测试没有通过删除有效约束取得通过

`NovelDocumentValidationTests.testDeleteChapterFromManuscriptRemovesWorkingSelection` 将已不符合 N1 合同的 discardedAt 非 nil 断言替换为 chapters 数组完全不变，同时保留 selection 缺席、needsSync、revision+1 与 chapterVersions 历史存在。新增同一文档带旧 global marker 时 validate 可读的控制；从 current 新提交该 global marker 的负例必须被 transition 拒绝。

显式 `testChapterDiscardAndRestoreAreValidAtomicTransitions` 保留并加强：discard 改全局 marker但不改 selections、导出隐藏；restore 恢复原 chapters/selections 和完整 Markdown。它防止本轮把两个领域动作混为同一种删除。

`NovelDomainIntegrityRegressionTests` 在 delete→结构同步后继续走真实 undo reducer，比较恢复后的 selections、全部 chapter records 和导出 Markdown，且断言第二章正文再次可见。这覆盖了 ledger 的“历史删除不得要求永久缺席”边界，未只检查一个 revision 数字。原父分支删除/兄弟分支正文可见回归仍保留；现有 ManualEditSync 的中间章和尾章删除回归未削弱。

## 3. Workspace 仅纠正正文路径识别

当前 Backup 原生产合同为正文 `branches/<slug>/chapters/<file>.md`，剧情模块为 `branches/<slug>/plot/chapters/<file>.md`。新 isManuscriptChapterPath 要求恰为四个路径段、首段 branches、第三段 chapters、末尾 .md；用于 checkout filesystem、export、head tree 与 undo removed-object 四个筛选位置。它排除多一层 plot 的模块路径，没有改变 Workspace 生产导出。

原正文 2/3 项数量、undo 后 1 项、fork 正文内容、removedHash 对象存在与 objectContents 包含已移除正文的断言均保留。另增 plot 总数=2 与两个大小写碰撞分支各自 plot 路径断言，能够发现“删剧情文件凑正文数”的错误修复。没有把预期 2 改为 4 或 3 改为 6。

此部分另由未参与实现的 audit_kmp 做窄只读 peer，结论同为 PASS；其核对生产正文/plot 路径及保留断言的结果与以上一致。

## 验证边界

本轮判断基于最终冻结源码、测试断言与 Root 已提供的首次失败清单；未把上一轮 PASS 源码审查或 503 个历史通过项当成当前八项已经 green。Root 应在冻结后实际运行 NovelDocumentValidationTests、NovelDomainIntegrityRegressionTests、NovelManualEditSyncTests 与 NovelWorkspaceRepositoryTests，再合并所需集成结果。

没有改动此前通过的 N4/N5、Markdown、Native Timeline 或滚动阈值；没有新增全局 discard 迁移、自动重试、历史修复兜底或 Workspace 新格式。真实 provider、IME 和物理设备验收边界保持原记录。
