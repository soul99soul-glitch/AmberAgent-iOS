# Phase 1 S1 ownership gate 独立窄复核

结论：**PASS，无已确认 blocking**。只读源码与phase-1-storage.md；未运行测试/构建、未修改生产代码。没有重审其他phase项。

## 占用与释放

- `Chat/Storage/IOSConversationBranching.swift:23–35` 在目标Conversation读取前按ID占用branch owner，拒绝已有branch或snapshot writer。所有五个branch入口均先begin，然后立即安装defer；invalid index、加载失败、import epoch失效、persist失败、成功均释放。
- `selectVariant`/`appendVariant`/`truncateAfter`持有owner直到`setCurrent`后返回；`deleteMessage`和`appendVariantAndTruncateAfter`还覆盖refreshSummaries await。这保证当前Store快照发布以前，不会提前放进新的snapshot write。
- `IOSConversationStore.save:603–604`的外层snapshot计数在读/改之前进入，并覆盖persist完成、setCurrent和summary刷新；persist本身`:1303–1304`也计数，嵌套save→persist是2→1→0，分支在任何中间时刻均不能进入。
- `persist`先安装全局write drain的defer，再尝试新message owner；message owner拒绝时全局计数仍会释放。每个message计数增加后紧接defer，失败不会残留计数。ownsBranchMutation只由已持有branch的入口传true，当前调用点无越权绕过。

## 失败与跨会话

- snapshot和branch的busy拒绝均返回false/nil并沿现有可见error通道给出可重试提示，没有排队重放旧numeric index。
- `sendMessage`在消费composer、调用startDeferredGenerationNow之前检查branch owner（ChatConversationMutations.swift:24）；card/image-edit也在mutate以前拒绝。现有reservation regression证明的是已进入异步持久化后的真实窗口。
- 所有owner key来自目标UUID，不依赖当前选中会话。branch保存的目标ID在首个await前固定；完成后只有`currentConversation.id == target`才setCurrent。VM `applyPersistedBranchIfCurrent`还同时核对原state、current ID和Store目标，旧会话完成不能改写新会话timeline或启动新会话生成。
- import epoch和delete tombstone原检查仍在persist前/后读路径，未见本次gate放宽写入授权或复活旧document。

## 两个额外疑点未升级为blocking

1. VM同步入口会创建Task，Store owner要等该Task执行才占用。合成同一同步turn直接连续调用`deleteMessage(); sendMessage()`确实绕过入口query，后续save可能被拒；但当前production UI每个delete确认、edit或variant事件只发一个action，未找到在该Task开始前同一生产调用链会连续调用send的证据。不能仅凭这种测试API组合把它当已证实用户故障，本phase不为此增加第二套状态。
2. saveBackgroundCompletion遇busy会很快耗尽三次尝试，但生产branch UI均先guard !isGenerationActive；ChatViewModel.swift:505–512明确将active background job纳入isGenerationActive。因此不能单凭直接Store调用构造branch与active background completion冲突来判定本次引入丢写。已有后台didSave=false转recoveryPending路径保留，不把它描述为成功；各后台owner的更广恢复行为属于既有单独phase，不在此窄审扩大范围。

本次没有发现必须在Phase1交付前追加的修正。实际green与现有concurrency/branching/persistence suite执行结果由root统一报告。
