# Phase4 实测失败收口诊断（当前只读冻结）

证据 phase4-rendering-green-summary.json：512总，503pass、8fail、1skip。通过的流式、reasoning、Markdown与Native门禁不动。

## N1 validator合同尚未同步

四个删除相关失败均源于 NovelOperationLedgerValidation:440-458 仍强制 chapter.discardedAt!=nil；NovelDocumentValidator:344-351 又允许 delete 作为全局discard owner，375-391 强制delete后的chapter全局discarded。它们与已确认的分支局部移除合同矛盾。

最小纠正不应恢复global写，也不能只删验证：ledger保留chapter/branch存在与workingRevision证据，当前workingRevision等于该delete结果时必须章不在working selections，后续revision则允许历史undo恢复；transition撤销delete对global discard的授权，改强验证chapter record完全不变、next selections精确为旧selections移除目标、workingRevision恰+1且匹配outcome。delete reducer走validateTransition，direct调用也执行强检查。

已有NovelDocumentValidationTests.testDeleteChapterFromManuscriptRemovesWorkingSelection仍断言global discardedAt非nil，需要改为chapter record完全不变；显式discard/restore的独立控制回归保留。增加delete→sync→undo恢复可见正文，防历史ledger误当永久状态。

## Workspace四项文件数量翻倍是正文选择器误计剧情文件

N2修复stateDelta collection后，fixtures现在拥有正确的chapterPlots；NovelWorkspaceBackup:289-307按现有合同写branches/<slug>/plot/chapters/*.md。正文仍在branches/<slug>/chapters/*.md，并未多写正文；测试chapterFiles helper:72及export/tree过滤仅contains('/chapters/')，误把plot章文件纳入，故2→4、3→6。

最小纠正只限NovelWorkspaceRepositoryTests的artifact路径识别：规范正文path必须branches/<slug>/chapters/<filename>.md；保持原来的正文数量、内容、undo对象库断言，不将2改4。必要时增加分离的plot路径断言证明恢复模块未被漏测。无需改workspace生产，也与N3 failed pin无因果关系。

当前validator/测试未落地，按Root要求保持可编译状态冻结，待其当前Chat build/red结束后放行。
