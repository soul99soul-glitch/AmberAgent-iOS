# Phase 4 Novel 独立审查

结论：**PASS（源码审查）**。在冻结的 N1–N5 修复范围内，没有发现需要追加修正的具体 correctness、领域契约或过度设计问题。此结论不代替 Root 的编译和绿色回归；本审查没有构建、运行测试或修改生产/测试文件。

审查输入：`phase4-novel-implementation.md`、`phase4-novel-changedpaths.txt`、`future-domain-red-summary.json`，并逐项读取当前实际 owner 与新增测试。此前的 tracked/untracked 模块化 WIP 不当作本轮重写；没有因 HEAD 整体 diff 扩大问题范围。已读取 NovelCreation/AGENTS.md。

## 已复核的修复边界

### N1 分支正文移除

`NovelChapterDiscardReducer.deleteFromManuscript` 现在只修改目标 branch 的 working selection/revision/syncStatus，并继续通过既有 ledger/approval/validator。对全局 chapter 存在性的检查保留；没有改变显式 discard/restore 原语义。fork 仍共享 chapter/version identity，因此移除全局 discardedAt 副作用正好消除了兄弟分支的过滤污染。新增测试不仅检查 selection，也对比完整兄弟branch和导出正文，未靠弱化断言获得通过。

### N2 chapterPlots 四入口及 stale gate

- 人物澄清直接传旧 `state.chapterPlots`，不会清除 stale flag。
- state-delta/代笔收录先确定最终 chapter selections，再用已有 `relinkChapterPlots`：旧章节模块保留，新/修改章用最终 proposedVersion 的 excerpt 更新，非末尾改章继续按现有 `isFastForwardCollect` 标记后章 stale。proposedVersion 尚未放入 document 的时序已核对：updatedText 显式提供最终版本，因此不会依赖旧seed代替本章。
- 模型 manual sync 以实际 `input.chapters` 区分重建suffix，保留 base snapshot 的未受影响模块；重建章从当前 working version 的现有seed规则重建，不保留其旧stale标记。
- structural manual sync 在准确 `rebuildBase.chapterSelections == branch.workingChapterSelections` 前提下用已有 `alignedModules`，没有清空或任意重解释旧模块。

`hasUnresolvedChapterPlots` 仍读 current snapshot 的 stale 模块；本轮未改门禁定义。测试覆盖了四owner，确认人物澄清保持门禁、代笔保留旧module并新增本章、manual sync稳定前缀与新版suffix、structural sync保留curated模块。没有新增第二套事实抽取、snapshot builder或补偿框架。

### N3 failed run durable retry

`persistableAtRest` 仅在所有 run 均为 completed 时进行原有整链裁剪；failed 与 interrupted/running 一样pin住运行与receipt/startRun链，避免局部裁剪造成悬空引用。file repository安装后返回剪后快照的行为未另加缓存。新增 `NovelWorkspaceRetryTests` 真实使用workspace-native file repository，fresh repository重载后查failed run并执行精确重试，覆盖原 user文本/mode/granularity。completed性能策略保持原边界。

### N4 raw presentation buffer owner/lifecycle

rawContent 存在原 `NovelSessionPresentationBuffer` 内；delta/replacement更新raw source，规范化只写pacing target。terminal 在清buffer之前读取raw，避免去围栏后的target丢掉后续delta所需的上下文。原run/message/bindingToken匹配继续控制复用；非空恢复稿初始化raw/normalized两个语义，订阅替换仅保留完全匹配buffer，detach/reset继续走原清理。普通文本target仍使用append path，未增加新pacer、timer、scroll owner或恢复状态机。

新增分包opener/closer和replacement后继续delta的测试在complete前等待pacer追平，断言裸正文，再检查durable候选稿，能够发现原来的错误中间态，而非仅等成功终态权威全文掩盖它。实际性能门禁仍应由Root按计划执行。

### N5 reasoning delta/replacement 语义

`choice.delta` 继续发送reasoningDelta；`choice.message` 在普通与durable frame适配入口明确发送reasoningReplacement。discussion engine回调本来提供累计snapshot，现在通过message-shaped replacementChunk表达，未在UI继续猜字符串前缀。

consumer按delta累加、replacement赋值，pendingReasoningText是下一拍完整思考快照；短replacement后delta也被新增测试覆盖。generation普通/frame两条路仅广播reasoning并更新heartbeat/后台进度，不写partialContent/sidecar；structured executor仅heartbeat，不拼入JSON。QuickStart与test support穷举已同步接线。新增adapter测试同时校验foreground与durable frame；discussion测试保留“正文出现后不重放思考”的断言，没有把reasoning当manuscript。

## 验证状态

已读取Root旧RED摘要，Novel十项原始失败与修复目标对应。未自行执行任何测试；当前编译/运行绿色与Native Timeline/viewport门禁结果由Root补充。真实provider、中文IME、长文手感与真机后台没有在本独立源码审查中验收。
