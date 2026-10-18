# Phase 6 PLAT-2 Home Search 提交独立修后复核

当前结论：**v2源码复核 PASS，无 blocking findings；真实UI验收待平台执行。** 只比较 `/tmp/amber-audit-20261018-current/home-search-before-fix.swift` 与当前 `Home/ConversationsView.swift`，本轮仅复核首修后的四处收口。未修改源码、测试、项目或设备，未构建/跑测试。

当前v2源 SHA256：`5d9667b915cf4fba26db3355091ffe31999d7bcea8ac07b00a4d1ab5f5369448`。

## 已确认的原缺陷

PLAT-2为真实P2：Home已输入并提交的TARGET经实际键盘Search进入Global Search后变空。`search-real-ui/home-submit-committed-before-ax.json`表明Home TextField为TARGET，且会话标题过滤只剩AUDIT SEARCH TARGET、ORIGINAL隐藏；键盘已是标点suggestions，排除未提交IME marked text。`home-submit-after-ax.json`记录实际tap键盘Search后Global字段仅有placeholder，并显示最近会话。

原onSubmit明确要把searchQuery传给Route.search.initialQuery；focus-lost却可先调用同时清query的collapseSearch。问题位于Home草稿被提前销毁，不需要在Search页面恢复或猜测查询。

## 首修源码推断被真实UI纠正

首修源为`f79673bd1519ccb367546c358dc4f78eea5059e808709e6ca2c2c12e6b168e59`。它对所有collapse都保留query、仅在下次expand清空；独立源码审查当时推断“无用户可见旧query残留”，该推断已被真实UI结果纠正，**不能作为最终验收结论**。

`search-real-ui/home-validation.md`确认首修提交到Global已通过，但inline Cancel或点外收起后再次展开，原生TextField仍显示TARGET；继续输入实际变成TARGETTARGET。`home-reopen-cancel-residual-ax.json`、`home-reopen-outside-residual-ax.json`同时显示字段残留与全列表，说明State筛选已重置而原生输入没有同步。这不是仅AX旧快照。名为`home-green-reopen-empty.png`的截图实际记录失败，不能列作green。

## v2四处收口

1. 仅focus-lost回调使用`collapseSearch(clearQuery: false)`，保留提交回调尚需读取的草稿。
2. inline Cancel改为显式闭包调用默认clear；Escape与submit仍调用默认clear。submit先局部捕获submittedQuery，再清空、折叠并导航，原非空查询不会被后续失焦反向修改。
3. `collapseSearchIfNeeded`在isSearchExpanded guard之前清query。点外或既有离场导航调用即使晚于focus-lost折叠，仍执行明确的清空意图，避免因guard早退留下草稿。
4. `collapseSearch(clearQuery: Bool = true)`恢复明确取消等路径的原清空行为，只在false的已证实focus路径保留query。

首修的collapsed过滤门、HomeEmptyCard展开条件和新次expand重置保持。collapsed列表不受隐藏草稿影响，空库文案不被旧query改变；没有新增onDisappear路径、`.id`重建、延迟、yield、额外状态或兜底。

## 一次有限可维护性复审

所有默认clear调用点仍在原Home owner内：显式Cancel、Escape、submit，以及点外/账号/设置/会话/新建等既有collapseSearchIfNeeded入口。唯一保留草稿的调用点是focus-lost，原因由短注释说明；提交通过局部String快照传值，不保存第二份query。四处收口直接表达“焦点变化”和“明确取消/提交”两种已观测意图，未引入通用状态机。源码没有需再修改的阻塞项。

## 验证边界

首修“提交TARGET”真实UI green可证明提交方向，但**取消/点外/重新展开的v2真实UI GREEN尚待Root增量构建后执行**。必须重新检查这两个曾失败路径的原生字段和后续输入，不能仅以Home全列表证明输入已清空。正常target点击、Search损坏目标失败与同hit重试由PLAT-1证据另行记录，不与PLAT-2合并计数。

本报告只给v2源码PASS；最终交互验收由Root依据平台重新实测补充。现有HomeDesignContractTests不含真实submit/原生TextField复用行为，不用源码字符串断言或已失败的进程内SwiftUI AX设施代替上述UI证据。
