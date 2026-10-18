# 第 6 阶段：Search、Watch 与 DeepRead

PLAT-1、PLAT-2、SYS-1–3 的修复与独立源码复核已完成，结论为 **PASS，无阻塞发现**。[独立复核报告](reviews/phase-6-independent-review.md) 记录了调用链、冻结文件 SHA 和验证边界。本阶段沿现有选择、决策和存储所有者修复，没有增加恢复框架、自动重试或新的导航协调层。

| 问题 | 根因 | 修复与保留的边界 |
| --- | --- | --- |
| PLAT-1：Search 打开失败后进入旧会话，异步选择缺少请求归属 | Search 忽略 `selectConversation` 的加载结果，每次点击创建独立 Task，随后无条件进入聊天页。 | Search 持有一个导航 Task；新点击、取消、路径变化和页面离场取消旧请求。使用 `selectConversationIfAvailable`，在 Store 提交前检查取消状态，导航前再次核对目标 ID。有效失败显示 alert，保留查询与结果供重试。普通标题、消息及最近会话入口继续共用这一流程。 |
| SYS-1：旧 Watch run 清除当前 run 的待确认数据 | 审批和 ask_user 包装方法先清理另一类 pending 字段，再由 `publish` 判断 run 顺序；旧 run 虽被拒绝，当前决策已经受损。 | 只有 `publish` 接受该 run 后，才清理另一类字段并保存新 prompt/request。现有 run 排序、卡片投影和审批执行链保持。 |
| SYS-2：补齐失败恢复原文章时丢失 Workspace 未保存标记 | 原完成快照只保存正文、结构化 JSON 和缺失段落，重试准备及恢复完成都会清空 `workspaceSyncFailed`。 | 原完成快照同时保存同步失败标记，失败或系统中断恢复时与原文章在同一次持久化中写回。正常生成新文章仍清旧标记，并继续原有 Workspace 保存流程。 |
| SYS-3：DeepRead 历史加载失败后，新建任务覆盖原文件 | 缺失文件、读取错误和解码错误均被当作空库，后续创建用新数组替换原 `tasks.json`。 | 仅真正缺失文件进入首次空库；其他失败成为可观察 `loadError`。创建和持久化入口拒绝覆盖，主 App 历史与独立 DeepRead 阅读库显示错误。保留原字节，不自动删除、重建空库或忽略损坏记录。 |

Watch 的两项新回归通过真实 Host 执行回答和审批，确认旧 run 的相反类型决策不会妨碍当前 run 续跑。DeepRead 的两项新回归分别确认损坏历史拒绝创建且原字节不变，以及补齐失败后重启仍保留原文章和 Workspace 告警，随后能实际补存该文章。这四项在 [实际执行批次](boundary-red-and-independent-greens-r2-summary.json) 中通过；该批次还包含其他阶段的失败项，整体结果仍为 Failed，不能描述为全轮绿色。原缺陷的预期失败见 [RED 摘要](pending-domains-red-summary.json)。

共享 Store 的独立消费者验证也已完成：[DeepRead 全量测试摘要](deepread-consumer-green-summary.json) 为 **109 项通过、零失败、零跳过**。最终集成 `build-for-testing` 已 [exit 0](final-integration-build.status.json)；这一结果证明构建完成，不代表最终组合测试或用户行为验收完成。

Search 的 RED 来自普通安装 App 的真实模拟器界面：[复现步骤](reviews/search-real-ui/reproduction.md) 包含有效目标控制、损坏目标仍有搜索命中时误开 ORIGINAL 会话的截图及 AX 证据。此前新增的进程内 AX 测试无法枚举 SwiftUI 控件，不能证明导航行为，已按任务授权原样归档；它不计入通过证据，也未用于删减有效业务断言。

**Search 真实 UI GREEN 已完成**：[实测记录](reviews/search-real-ui/green-verification.md) 与 [复现全程](reviews/search-real-ui/reproduction.md) 留档。有效 TARGET 正常打开；损坏 TARGET 后留在 Search，显示“无法打开会话”；关闭提示后查询 TARGET 与全部命中仍在；恢复同一目标文件后，不重搜直接点击原命中即可打开 TARGET。另一次失败后取消回 Home，ORIGINAL 仍是当前会话，截图及 AX 均保留。验证只修改任务创建的模拟器数据，目标有效字节已恢复。

取消和离场的过期请求已通过源码所有权复核；Store 已有 `testConditionalSelectionDoesNotCommitAfterItsOwnerBecomesStale` 与 `testSelectingMissingConversationFailsWithoutChangingCurrentConversation` 行为测试，Root 将统一重跑相关套件。快速点击、取消或离场的 UI 时序尚未形成独立竞态实测，不将源码检查表述为交互验收。

## 验收补出的 PLAT-2：首页提交清空搜索词

真实模拟器上，Home 输入 TARGET 后，会话列表实际只显示 TARGET，证明输入已写入 SwiftUI State；直接点击系统键盘“搜索”，全局搜索却显示空查询与最近会话。旧 App 和修复 PLAT-1 后的 App 均可复现。[独立二次判定](reviews/second-home-search-submit.md) 排除了输入法 marked text、工具提交异常和 by design。

根因在 Home owner：失焦折叠先清空 `searchQuery`，随后 `onSubmit` 读取已清空的 State。提交捕获输入再折叠导航；仅失焦路径暂留草稿，显式取消、点外与提交完成仍立即清空。收起时停止标题过滤，空库文案同步按展开状态判定。没有增加状态、异步延迟或兜底查询。

首修曾把所有清空移至下一次展开，源码审查未发现原生 TextField 复用风险；真实 UI 测试证实取消/点外后仍残留 TARGET，继续输入会拼成 TARGETTARGET，故未接受该轮为最终 GREEN。失败 [实测记录](reviews/search-real-ui/home-validation.md) 和首轮截图保留。v2 恢复显式意图立即清空，并在 `collapseSearchIfNeeded` 的 guard 前清空，避免焦点先收起后外部 tap 跳过清理。相关 [源补丁](reviews/home-search-fix.patch) 及 [修后独立复核](reviews/phase6-home-search-independent-review.md) 已留档，v2 源码结论 PASS；[最终构建](home-search-final-build.status.json) exit 0，随后 [真实 UI v2 复测](reviews/search-real-ui/home-v2-verification.md) 通过。Home 键入 TARGET 后点击真实键盘 Search，全局查询保持 TARGET；取消或点外恢复全部会话，再次展开为空，继续输入恰为 TARGET 且匹配，不再拼接旧文本。普通 List 滚动未收起键盘，没有据此声称纯收键盘路径验收；空库未移动数据，文案只作源码复核。

本阶段未取得真实 provider、物理设备或 Watch 配对行为证据。Search/Home 真实 UI 已收口，主 App 最终组合测试由 Root 执行并汇总到 [验证记录](verification.md)。
