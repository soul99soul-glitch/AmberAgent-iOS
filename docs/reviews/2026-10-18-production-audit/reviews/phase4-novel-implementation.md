# Phase 4 Novel 实施交付（冻结）

状态：N1–N5 已实现，生产与测试文件已停止写入，可交 Root 统一构建、测试及独立 phase review。没有改 Chat/Engine/Host/Background、其它产品、工程 membership 或 project.yml；没有提交或推送。既有 tracked/untracked 模块化 WIP 全部保留。

## 失败证据

Root 已运行 future-domain-red，/tmp/amber-audit-20261018-current/future-domain-red-summary.json 记录 Novel 三个新类原十项全部失败：

- 分支删除：共享 chapter.discardedAt 被错误设置。
- 人物澄清/代笔收录/模型同步/结构同步：chapterPlots 为空。
- 文件仓错误终态：fresh repository 重载找不到 failed run。
- 流式正文：split opener 泄露 markdown 标签，split closer 泄露 ```。
- reasoning：重复/前缀 delta 不满足完整文本断言。

该运行同时包含其它组的 WebMount 测试，其失败不归本 phase。

## 实际修复

N1：deleteFromManuscript 只移除目标分支 selection，不写全局 discardedAt，独立 discardChapter 原语义不变。

N2：clarify 复制原 chapterPlots，stale gate 不丢；stateDelta collection 在最终 selections 确定后用现有 relinkChapterPlots 保留前章模块、更新本章 excerpt，非 fast-forward 继续按既有规则标后章 stale；manual finalize 从真实 rebuild base 保留 curated 稳定前缀，重建 suffix 用当前版本 seedTexts 新建 fresh 模块；structural sync 按准确基线 alignedModules 保留剧情。没有新建 snapshot builder 或第二套抽取协议。

N3：persistableAtRest 仅在 activeRuns 全部 completed 时裁剪，failed 与原有 running/interrupted 一样 pin 住请求、receipts 与运行记录，精确重试所需资料保留。completed 裁剪策略未扩大。

N4：raw 稿件归现有 NovelSessionPresentationBuffer，append/replacement 与规范化 target 分离；normalizer 从完整 raw 计算、只改 pacing target，terminal 在清 buffer 前读 raw。恢复非空 manuscript 按 raw/normalized 初始化，consume 更换订阅仅保留匹配 run/message/token 的 buffer，detach/reset 原生命周期清理。普通流仍走 append fastpath，不逐 chunk replace 重锚。

N5：新增明确 reasoningReplacement，贯穿 model/frame/run event。choice.delta 为 delta、choice.message 为 replacement；discussion 累计输出改用 message snapshot。UI delta 追加、replacement赋值，flush不再按字符串前缀猜语义。structured executor仅刷新 heartbeat；generation仅广播，reasoning没有进入正文、候选稿、sidecar或结构化JSON。没有修改KMP/Gemini/Grok provider。

## 本 phase 文件所有权

精确路径见 phase4-novel-changedpaths.txt。若同一 tracked 文件已有其它 WIP，只将上述修复视为本 phase 改动，不以整个 git diff 归属本任务。

新增三个测试类仍由 Root 已维护的工程 membership 包含；StreamIntegrity 在原四个 RED 项上增加了 replacement fence 与短 reasoning replacement 后接 delta 两条回归。既有 adapter 增加 foreground/durable frame snapshot 测试；discussion 旧方法更名为 testDiscussionTransportForwardsReasoningSnapshotsBeforeAnswer，保留正文之后不重放思考的断言。新增事件的对应测试 support 穷举接线已更新，不用 default 隐藏遗漏。

## Root 验证入口

首先运行：

```
-only-testing:iosAppTests/NovelDomainIntegrityRegressionTests
-only-testing:iosAppTests/NovelWorkspaceRetryTests
-only-testing:iosAppTests/NovelStreamIntegrityRegressionTests
-only-testing:iosAppTests/NovelLiveModelAdapterTests
```

新增/更名的两个 adapter 精确入口：

```
iosAppTests/NovelLiveModelAdapterTests/testReasoningSnapshotsPublishReplacementInForegroundAndDurableFrames
iosAppTests/NovelLiveModelAdapterTests/testDiscussionTransportForwardsReasoningSnapshotsBeforeAnswer
```

领域与存储受影响回归：NovelForkTests、NovelCharacterIdentityCandidateTests、NovelFactTransactionLifecycleTests、NovelManualEditSyncTests、NovelWorkspaceLedgerTests、NovelWorkspaceRepositoryTests（含completed receipts瘦身对照）、NovelChapterReplacementStateTests、NovelGhostwriteGenerationTests。

事件/终态/呈现：按 docs/reviews/2026-10-18-swift-modularization/phase-4-test-entrypoints.md 当前职责映射覆盖 NovelGenerationLifecycleTests/NovelGenerationRecoveryTests、NovelStructuredModelExecutorTests、NovelSessionTailPresentationTests、NovelSessionRetryAndPolishTests、NovelSessionRunOwnershipTests、NovelSessionStreamingPerformanceTests。N4触及现有pacer，执行 iosApp/AGENTS 指定 Native Timeline/viewport 门禁。

## 验证与检查边界

本实施组未自行构建或运行测试。三位 owner 已分别对各自本轮差异完成一次有限 code-simplifier 维护性检查，未追加重构/兜底；目标路径 git diff --check 无输出。生产代码穷举switch静态检索已覆盖，是否完整可编译以 Root 实际集成构建为准。

模拟器绿色后仍不能声称真实provider、中文IME、长文手感、后台/真机验收完成。若Root发现本 phase实际编译/行为失败，本组继续在原范围修正；当前不扩大审查到新问题。
