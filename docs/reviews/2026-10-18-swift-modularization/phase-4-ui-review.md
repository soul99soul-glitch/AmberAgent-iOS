# Phase 4 小说 UI / IME 独立审查

审查基线是 `/tmp/amber-phase4-source-baseline/files`，包含 Phase 4 开始前未提交的小说 UI 工作；不以 `HEAD` 代替迁前状态。审查范围为原 `NovelSessionView.swift`、`NovelSessionSheets.swift`、`NovelSessionBubble.swift` 及其 15 个拆出文件，对照 `/tmp/amber-phase4-ui-moves.json`。本 reviewer 只读产品代码与 Root 交付的结果，不修改源码、测试或 YAML，也不执行构建和模拟器。

## 生产路径与状态归属

- `NovelSessionView` 仍从 `NovelSessionTranscriptScope` 获得可判等的会话摘要，默认正文列表仍走 `ScrollView`、`NativeTimelineScrollDriver`、原有 `ScrollPosition`/follow reducer；历史与活跃 run 保持两个 eager `ForEach`，行继续按 `NovelMessageID` 标识并 `.equatable().id(row.id)`。`NovelSessionRowView` 只接收 row、阻断状态和事件回调；终态等待保存、失败、重试及未可见尾部冻结仍由原列表/气泡分支消费。未发现迁移导致的行 ID 或滚动 owner 断链；真实生成过程中的滚动跟随仍需另行验收。
- 主 composer 的输入文本、焦点、尺寸、context popover、`ComposerInputController` 仍由 `NovelSessionView` 持有，拆出的 `NovelSessionComposerDock` 只通过 binding 和动作闭包呈现。发送时仍先读 `committedText()`、更新绑定，之后才 `dismissKeyboard()`；失败时仍把原文存回原项目/分支草稿并在当前空输入框恢复。底部 `.safeAreaInset` 与生成状态条的固定最小高度仍在父视图，避免切换时改变滚动 owner。
- `NovelSessionChrome` 仅接收 recovery abandon IDs/task 和 revision request 的原 `@State` binding；同步、Quick Start、错误与代笔状态分支仍读取同一个 workspace/session。气泡仍从 row 的 `reasoningContent` 单独渲染 `ChatReasoningCard`，没有混入正文；基线中的 `@AppStorage(autoExpandThinking)` 与传参均保留。长文阅读的分页状态仍局部持有。

## Sheet、中文输入与事务

- `NovelWritingContextSheet` 继续一次性持有 tab、预算、资料选择、预览标识、`NovelWritingContextFieldState`、draft owner、`chapterPlanSaveTask` 和提交状态。拆出的字段定义仍是同一个 `@MainActor @Observable` 对象，内部只有一份 `NovelIMEFieldBank`、dirty 标志及 plan/arc edit revision；子字段通过 binding 写回并标记版本。保存/确认/清除、预览与关闭先 `NovelTextInputCommitter.perform` 或同步 `fieldBank.commitAll()`，再读取字段；workspace 快照回填仍在 dirty/marked-text 条件下避让。关闭时保留原项目/分支草稿，若已有保存任务先等待结果，再按提交版本决定是否补存；未看到拆分新增的独立草稿 owner。
- Archive、collect、fork 和润修 Sheet 各自保留本地 IME bank、编辑/提交状态与失败后留在原 Sheet 的重试入口。收录仍先提交 marked text，再从选中段落、编辑文本和目标章节构造 `NovelParagraphSelection`/`NovelCollectionTarget`，只有 `onCollect` 返回 completed 才触发完成回调并关闭；候选稿未由 View 直接写为正式正文。代笔润修仍允许编辑 brief，`onStart` 返回 false 时显示错误而不关闭。人物身份卡打开已有建议时仍经 `NovelSessionView` 的 `onAcceptSettingProposal` 到 `NovelProjectWorkspaceView` 的 `.proposal` sheet；`NovelProposalAcceptanceSheet` 保留标题/内容/类型等编辑项，提交 marked text 后调用 `resolveProposal(.accept)`，成功才关闭。行内 `NovelAskUserCard` 则是另一条审批回答路径，没有与资料建议事务混用。
- 拆出的按钮保留至少 44pt 热区、固定短标题和长文 `fixedSize`/换行约束；这些源码约束不能替代 320pt/393pt 与辅助功能字号的实际几何和截图检查。

## 集成接线复核

- 初次独立 Novel 构建发现 `NovelWritingInjectionSelection` 离开 `View` 后失去原先的 MainActor 推断；实现 owner 已在该同步选择/预览辅助类型上显式加 `@MainActor`，没有加入新任务或异步状态。另一个跨文件接线缺口是原 file-private 数字本地化 helper；现由审批卡文件提供单一 internal `novelSessionLocalizedNumber`，长文分页与审批文案调用同一格式化实现。`/tmp/amber-phase4-novel-build-r4-summary.json` 记录修正后的独立 Novel target 在 iPhone 17 Pro 模拟器 arm64 上 `status=succeeded`、`errorCount=0`；日志中的 7 条 `exit code 0` 消息未计作构建失败，首轮失败也不计作通过。
- 对照 `/tmp/amber-phase4-source-guard-adjustments.json` 抽查了身份卡、Markdown 长文、proposal 编辑、collect 标题、IME、archive/collect/context Sheet 与 follow/row action 的固定源码 guard。它们现在分别核对父视图实际构造子视图，以及子视图/领域命令中真正拥有的行为，不只检查新类型名。抽查时发现 `testNovelDraftActionsCommitMarkedTextBeforeReadingState` 的 save-bound loop 仍要求父 `NovelSessionBubble` 持有已搬到 `NovelSessionApprovalCards` 的 IME bank，必然误报；Root 已将该项指向审批卡，同时保留 bubble 调用 `NovelAskUserCard` 的入口断言。调整后源码 parse 通过，Root 的主 App r3 全量运行实际发现原有小说测试方法；其中运行链 late-detach 失败由对应 owner 继续处理。

## 实际验证与结论

独立 Novel target 已构建通过。`/tmp/amber-phase4-navigation-r1-summary.json` 记录实际产品导航 1/1 通过：从首页进入小说创作，创建或复用本地测试项目，访问创作、正文、设定及项目控制的“模式与偏好”“上下文注入”两段。我独立查看 `/tmp/amber-phase4-navigation-r1-attachments/manifest.json` 对应的 7 张截图和 7 份 AX 树：标题、分段、空态、输入栏、计划字段、注入列表与滑杆没有观察到裁切或重叠，关闭入口可见。主工作区三个 tab 的 AX 高度为 38pt；实际 UI 测试分别点击中心上下 21pt 并验证选中态，不能仅凭 AX 边框把它判为 44pt 触控缺陷。这里的“全局模型不可用”属于无 provider 的本地测试项目状态，不代表生成行为验收。

主 App r2 全量结果 `/tmp/amber-phase4-main-r2-summary.json` 为 1205 通过、12 失败、4 跳过；其中本审查范围的 3 个初版 hosting 布局测试均因同一测试设施问题失败：单元测试创建的窗口有 UIKit 子视图，却没有任何可枚举的窗口 AX 标签，故 `XCTUnwrap` 找不到按钮。`/tmp/amber-phase4-focused-r1-summary.json` 的相关定点运行是 16 通过、这 3 项失败。该证据不能证明三个产品按钮缺失或不可点。测试 owner 因而将三项调整为实际渲染、滚动及 viewport 几何探针；单元 hosting 不宣称 AX 或真实点击，前述实际产品导航保留为触控证据。

主 App r3 的新版 hosting 中，长候选与 AskUser 两项已通过；收录 Sheet 一项仍在首屏寻找惰性挂载的 `UITextView` 时失败，不能据此判定编辑器缺失。已生成的 4 张 candidate 和 8 张 AskUser 图由我逐张核对：320pt/393pt、large/AX3 下长文在视口内换行，滚动到底后“作为新章收录”和“确认选择”完整可见，选项没有横向溢出。AX3 下 AskUser 单行自定义输入的占位文案右端会截断，但文案和输入分支在迁前基线 `NovelSessionBubble.swift` 中相同，未确认是本次迁移回归。r3 的收录 Sheet normal 图底部仅露出“章节位置”开头，未证明表单真正滚到底，因此不能据它签字。

最终定点结果 `/tmp/amber-phase4-stream-red.xcresult` 中 3 个 layout case 全部通过。收录 Sheet 探针现在取实际 Form 外层滚动容器，沿视口逐步找到惰性挂载的编辑器，滚至实际最大 offset 连续两次稳定，再断言末尾“第 1 章”标题输入框位于视口内。我按 `/tmp/amber-phase4-final-collect-images.json` 逐张复核其 8 张 PNG：320pt/393pt、large/AX3 下，编辑区和末尾章节标题都能经滚动呈现；中文段落在横向视口内换行，顶部“取消”“收录”与标题没有重叠，正文、说明与章节字段的间距可辨。4 张 candidate、8 张 AskUser、8 张 Collect 共 20 张最终图的本期视觉范围闭合。

据此，对 Phase 4 小说 UI 拆分的生产接线、状态/IME owner 保留及上述模拟器视觉范围签字；未确认本次迁移新增的可达 UI 回归。这个签字不覆盖真机中文 IME 组合输入、真实 provider 与生成后的长文跟随手感、VoiceOver 导航，或当前由运行链 owner 处理的 late-detach 红测。hosting 单元图不证明 AX/触控，实际产品导航 1/1 及其边缘点击是本次有限的交互证据。
