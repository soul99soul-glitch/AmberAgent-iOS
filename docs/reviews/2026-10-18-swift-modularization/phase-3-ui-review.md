# Phase 3 渲染与聊天 UI 独立审查

审查范围：以 `/tmp/amber-phase3-source-baseline/files` 为迁移前完整工作树基线，检查六个聊天渲染大文件、共享图片 URL/布局、`ChatView`/composer 生产入口及相关呈现状态。此基线已包含用户的 `MessageBubbleView`、`ChatMediaView`、`ChatView` 修改和 Phase 2 手机控制接线；不以 `HEAD` 的差异判定本期回归。本审查只读产品代码、配置和测试，不运行 Xcode、模拟器或真机；构建、测试及截图由 Root 实际执行并交付结果，本 reviewer 独立核对结果文件和图片。

## 已核对的契约

- Session worker 后续拆了 `ChatView`，映射见 `phase-3-session-moves.json`。`chatListSummary` 仍是父视图读取的可判等投影，类型移到 `ChatScreenValues.swift`；`ChatTimelineSignalHost` 保持同一信号观察方式；默认列表现于 `ChatView.swift:864` 无条件构造 `NativeChatTimelineView`，`messagesProvider` 仍在事件闭包中读取原消息。`ChatSwiftUIMessageList` 只用于非默认回归，不能单独证明生产路径。
- `phase-3-render-moves.json` 对六个原渲染大文件的 13,270 个物理行逐行覆盖，没有遗漏或重复。Native host 的 `@State`、history window、projection cache、scroll driver、行 ID 与回底处理仍在原 owner；迁移主要改变文件位置与必要的 `private` 可见性。`ChatTimelineRows.swift` 中 Native 行的等价判断、live-tail `@ObservedObject` 粒度及 `.id(model.renderIdentity)` 保留。
- Markdown 唯一入口、流式 block 与 stable renderer 分支仍在。stable controller 保留 `@MainActor`、`Task.detached` 解析、取消与 generation 比对、最新快照发布、静态 renderable/identity cache；缓存仍可跨 View 重挂载。block controller 保留解析任务的取消和合并发布。所见迁移差异为跨文件访问级别及测试专用条件编译边界，没有发现可达的异步次序改变。
- `MessageBubbleView`、生成图 grid/tile/preview 的原状态与布局按类型搬迁；`ChatWidthDrivenAspectRatio` 的同一 `Layout` 算法单独成文件。`ChatMediaView` 仅两处从 repository URL helper 改为 `ChatGeneratedImageURL` 直接调用；新 helper 与迁前实现逐分支相同，repository 保留原静态接口转发，其他调用者可继续使用。`ChatVideoView` 未发生本期渲染路径的逻辑改动；`ChatView` 的后续 session 拆分已单独核对。
- 工具呈现拆为 style/model/subagent/phone/header/view；解析仍共用 `ChatToolOutputAnalysis`，格式化与预算位于 `AgentRuntime/Tools/Output`。phone group 的环境 toggle handler 保留引用身份，不在 `body` 每次新建。工具 timeline 的 subagent 状态查询仍由组件本地 `@State` 持有，未提升为整个聊天页观察。
- Composer 的 `.safeAreaInset(edge: .bottom)` 仍留在 `ChatView`，`ComposerInputController` 的 `@State` 身份未搬；输入布局与发送事件移到同类型 extension `ChatViewComposer.swift`，审批卡成独立 `ChatComposerApprovalCards`，附件 picker 事务移到 `ChatViewAttachmentImport.swift`。三组局部布尔值/尺寸/任务按 composer、附件、browser 归入 `ChatScreenLocalState.swift`，仍由 `ChatView` 的 `@State` 持有；焦点 binding、popover namespace、审批卡高度预算及 `.frame`/裁切顺序与基线一致。

## 集成与实际呈现证据

- 初审发现 `iosApp/NovelApp/project.yml` 指向已迁走的 Markdown 路径；Root 改为实际新源及共用媒体 URL/布局闭包，随后独立 Novel ARM64 构建通过（`/tmp/amber-phase3-novel-build.log`）。固定旧源码路径的可执行测试断言也已指向实际 owner；旧测试方法保留，Root 核对 327 个原 render/session 方法各执行一次，其中 325 通过、一项 canary 首轮失败后同阈值定点通过、一项手工条件跳过。Native 38 个原 replay 分布于 `ChatSwiftUIStreamReplayTests` 和三个新的 `ChatNativeTimelineReplay*Tests` 类，不能只用旧类 selector 为生产路径背书。
- Root 的 r10 主集成报告为 1475 项中 1466 通过、7 失败、2 跳过。与 Phase 3 相关的三项失败中，两项是已修正的旧路径源码 guard，一项表格计时为 42.57 ms、略高于原 40 ms 阈值；三项按原阈值定点重跑均通过（`/tmp/amber-phase3-focused.xcresult`）。这支持接线正确，但一次计时复跑不能证明稳定性能提升。另四项失败属于未改动的 Novel fixture 与原过滤契约冲突，由 Root 另列 Phase 4；本 UI 审查不把它们算成通过。Engine/Host/Orch 的 118 项迁移回归均通过。
- overlay 修复后的六个强制滚动测试类在 `/tmp/amber-phase3-scroll-overlay.xcresult` 共 97 项：96 通过、0 失败、1 项原手工条件跳过。此前仅删除 bottom padding 的中间版本曾有一项 first-line 的 `distanceToBottom` 为 51.67 pt，高于原 48 pt 阈值；原基线也曾出现此项失败，r10 则在原阈值内通过。最终 overlay 复跑通过不抹去这段距离阈值波动，也不构成 120Hz 长时性能验收。
- 我逐张检查了 `/tmp/amber-phase3-layout-after` 的 20 张模拟器 PNG，并与 `/tmp/amber-phase3-layout-before` 的九张对应图核对。Native 工具密集 timeline、phone 折叠/展开、subagent 展开/AX 及建议条等六组像素完全一致；compact Native 仅加载点动画帧不同，subagent 两张只有玻璃阴影渲染小幅差异，正文和边界未位移。320pt/AX2 媒体块、393pt 长 CJK/四 renderer 宽表、320pt/AX3 phone header、结果卡与建议均未见新增重叠、错位或正文裁切。宽表右端落在横向滚动视口之外，符合组件可横滚的契约，不能据单张截图判作裁切缺陷。
- 实际产品路径 `Home → 新建聊天 → 输入英文草稿/系统键盘 → 清空 → 附件菜单` 的 `SwiftModularizationNavigationUITests/testChatComposerKeyboardAndAttachmentLayout()` 在 iPhone 17 Pro / iOS 26.5 模拟器通过 1/1（最终 `/tmp/amber-phase3-navigation-overlay.xcresult`）。我核对了最终 `/tmp/amber-phase3-navigation-overlay-attachments` 三张截图：输入框和发送键在键盘上方，模型/控制条和附件菜单留有间距，拍照/照片/文件入口可见；测试还断言了 44pt 点击尺寸、键盘不遮挡、文件入口可达及空态标识相对顶栏/附件菜单的几何边界。这是模拟器系统英文键盘证据，不等同于真机中文 IME、120Hz 长时间滚动或真实 provider 验收。

## 空态键盘重叠的发现与修复

首轮实际键盘截图中，空聊天欢迎态的圆形 A 标识上移并与顶栏 Amber 标签交叠；迁前 `ChatEmptyState` 的固定底部 180pt 留白、Native 空态滚动行及顶栏结构相同，所以它是既有可达问题。仅删除固定留白后，键盘态已分离，但附件面板进一步压缩视口时仍能使空态滚入顶栏；定点截图证明只调 padding 不足以闭环。

最终修改保留 Native empty 投影及底锚，将装饰性 `ChatEmptyState` 从消息滚动行移到仅空投影时的顶对齐 overlay；`ViewThatFits(in: .vertical)` 在空间不足时不绘制欢迎装饰。`ChatEmptyState` 保留顶部 104pt 内边距，删除无内容作用的底部 180pt。滚动 driver、历史窗口、配置卡和 composer owner 均未改。最终普通页与纯键盘页的标识/圆环均在 Amber 顶栏下方且位置稳定，附件页不再绘制欢迎装饰；三张实际 PNG 均未见其与顶栏、附件菜单或输入区重叠。最终导航用例 1/1 通过，几何断言绑定整个标识的 `chat-empty-state-mark`，并在附件态标识存在时核对其边界。

附件页的 `app.debugDescription` 仍列出未绘制的欢迎候选内容及 `chat-empty-state-mark`，因此这里**只签视觉布局修复，不声称 VoiceOver 不会读到该候选**。先前滚动行在附件态同样可在 AX tree 中留下屏外欢迎内容；目前没有实际 VoiceOver 聚焦缺陷的证据。真机 VoiceOver 接受验收仍未进行。

## 维护性判断

六个旧文件按投影、生产列表、回归列表、Markdown、工具呈现/输出与图片职责分开，调用入口仍直接。此次未发现仅为了缩短文件而改变状态 owner、缓存生命周期或增加补偿状态机。显式目标源清单和固定路径测试已接线并获得构建/运行证据；最终空态修复也落在视觉装饰 owner，未加滚动补偿状态。**Phase 3 渲染与聊天 UI 迁移及空态视觉修复审查签字：已检查的实际产品路径和截图未见可达画面回归，六个强制滚动类最终复跑 96 通过、0 失败、1 项原手工条件跳过。**本签字不覆盖 Runtime/Kernel/Engine 独立审查，也不声称真机、真实 provider、中文 IME、VoiceOver 或 120Hz 性能验收。
