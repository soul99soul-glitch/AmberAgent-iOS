# Phase4 实测失败收口（已冻结）

Root实测 phase4-rendering-green-summary.json 为512总、503pass、8fail、1skip。本轮仅修正四项N1 validator合同失败和四项Workspace正文/plot误计数，未触碰通过的流式/reasoning/Markdown/Native部分。Rootbuild期间保持冻结，收到明确GO后才改代码；当前已再次完整冻结，未自行构建或测试。

## N1 合同同步与更强转移验证

根因：此前只修delete reducer不再写global discardedAt，而ledger仍把历史delete outcome绑定到global discarded、transition仍允许delete拥有global discard翻转并强制全局废弃。

- NovelOperationLedgerValidation保留branch/chapter存在、project revision与workingRevision证据；结果仍是当前workingRevision时必须目标章已移除，后续revision允许undo重新选择历史章，不再要求永久全局discard。
- NovelDocumentValidator撤销delete对global discard翻转的授权；新delete transition要求整个chapters数组不变，next selections精确为旧selections移除目标，workingRevision恰+1、与outcome一致，并进入needsSync。
- NovelReducer.deleteFromManuscript执行validateTransition，direct入口也应用强约束。
- NovelDocumentValidationTests旧delete预期改为chapter records完全不变；保留旧历史global marker静态可读兼容，但负例证明新delete不可再写该副作用。显式discard/restore对照加强选集不变与导出隐藏/恢复，保证两种领域动作没有混合。
- NovelDomainIntegrityRegressionTests结构sync后新增undo，验证原selections/chapter records/Markdown完全恢复、第二章正文可见，防止historical delete ledger把恢复误判为无效。

## Workspace正文与剧情文件分别验证

N2修复后fixtures恢复chapterPlots，Backup按原合同写branches/<slug>/plot/chapters/*.md；旧test helper和tree/export过滤只contains('/chapters/')，把两类文件合计，正文没有被生产代码重复写入，N3也无关。

仅NovelWorkspaceRepositoryTests新增规范正文path predicate：恰为branches/<slug>/chapters/<file>.md。filesystem/export/ledger/undo对象库查找一致使用该predicate，原2/3/1正文数量、正文内容与对象保留断言均保持。CaseInsensitive测试另断言两个分支各自plot/chapters文件存在且总数2，确保没有删剧情文件凑正文数字。Workspace生产代码未改。

## 本轮路径与验证

路径见phase4-followup-changedpaths.txt，仅六个文件；需结合任务前WIP识别本轮局部差异，不将整个tracked/untracked文件归本轮。各owner对该收口做过一次有限自审，target git diff --check无输出。

Root优先重跑：

```
-only-testing:iosAppTests/NovelDocumentValidationTests
-only-testing:iosAppTests/NovelDomainIntegrityRegressionTests
-only-testing:iosAppTests/NovelManualEditSyncTests
-only-testing:iosAppTests/NovelWorkspaceRepositoryTests
```

N4/N5及此前通过门禁的证据可复用；本次未扩大生产影响范围。当前绿色结果待Root实际执行，不据静态检查声明已通过。
