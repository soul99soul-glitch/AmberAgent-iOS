# Chat rendering / projection 只读审查

基于工作树 HEAD b98bd6f0，2026-10-18。已读 iosApp/AGENTS.md。MessageBubbleView.swift 有用户未提交修改，本报告包含当前内容，不应回退。无产品修改、无测试运行。本轮是结构审查，不声称发现运行时 bug。

## 现状与关键证据

六文件共 13,270 行：ChatCollectionMessageList 3711，ChatToolTimelineView 2311，ChatAssistantMarkdownView 2289，ChatToolSupport 1781，MessageBubbleView 1641，ChatMessageProjection 1537。

默认入口：iosApp/iosApp/ChatView.swift:1568 无条件创建 NativeChatTimelineView；ChatCollectionMessageList.swift:329-331 明确生产 native driver owner。ChatSwiftUIMessageList 定义在同文件 1997，为非默认回归路径，不能用其回归成功单独证明生产路径。不能凭 Collection 文件名认定 UICollectionView 是主路径。

### 结构问题 A：生产、回归路径及渲染基础设施共处错误命名文件

- ChatCollectionMessageList.swift:90 projection cache；331 Native view；1634 起 legacy viewport policies；1997 SwiftUI legacy list；3287 live-tail model；3342 render-state store；3484 content identity；3519 hash cache。
- Native View 约 1237 行，本身已经低于 1500。主问题是独立职责拼在一起，并非需要把该 View 扩散成十几个 extension。
- Native View:357-386 约 30 个 State 分属 viewport/follow、renderer、external anchor、history window、phone group。第一轮应保留 owner 和 SwiftUI identity，不把所有 State 移入一个大 ObservableObject 扩大 delta 重算。
- 现有 NativeTimelineScrollCore.swift (548) / NativeTimelineScrollDriver.swift (649) 已是 policy/平台适配边界，应复用。

### 结构问题 B：UI 文件 / Support 同时承担协议解释、输出整形、presentation

- ChatToolTimelineView.swift:525 ChatToolStepModel 内含 579 起工具分派、1093 子 agent receipt 解释、1385 WebMount 脱敏摘要、1460 终端输出摘要；1711 才是 Timeline View。
- ChatToolSupport.swift:1098 ChatToolOutputFormatter 同时装 nonisolated 缓存分析（1105/1112）、runtime outcome 转换（1116）、workspace/WebMount 文本、1392 cappedToolOutputParts 与 1421 起 JSON 保形截断。
- 真正跨层 caller：ChatToolRuntime.swift:6983 subAgentOutcome、7126 cappedToolOutputParts；IOSContextCompactionCoordinator.swift:1044 cappedToolOutputParts；ConversationArtifactIndex.swift:211 等 analysis。应把能力归入 execution/output owner，避免未来 runtime/compaction 依赖 UI 模块。
- ChatToolDetailSheet.swift:66,88,577 等借 ChatToolStepModel 的解析/title helpers；IOSSubAgentOutput.swift:121 也借 friendlyToolTitle。迁移需一并改 caller 或短期保留原静态接口。
- 现有 ChatToolCallParsing.swift (53) 与 ChatToolOutputAnalysis 精确 snapshot cache 应继续共用；不引入通用 tool plugin registry。

### 结构问题 C：部分验证固定源码路径和 private 名称，直接移动会失败或失去覆盖

- ChatMessageProjectionTests.swift:1206-1227 读取 ChatAssistantMarkdownView.swift，查 private class/Task.detached，并用字符串分割提取 controller body。
- 同测试:943 固定 Markdown 路径；ChatRowContentHashCacheTests.swift:347 固定 Collection 路径；IOSGenerativeWidgetPayloadDetectorTests.swift:115/149、IOSSettingsWiringTests.swift:219/220、IOSThemePackToolTests.swift:630 也固定路径。
- 每 packet 更新到实际 owner 源码定位，保留行为断言；不得删检查来通过。已有真实 renderer/replay 测试是核心验收。
- project.pbxproj 为显式 PBXFileReference/Sources，非自动目录同步；599/794 同一 Collection 源出现在两个 sources phase，新增文件需在 XcodeGen project.yml 中保持同等 target membership 后重新生成工程；不能只编辑生成的 pbxproj。

## 拟拆文件与行数预算

目录仅为 app target 内逻辑模块，暂不增加 package/framework/DI 容器。预算为职责迁移后量级，每文件 <=1500；不以机械逐行切割验收。已有小文件可原地保留或随逻辑目录移动。

### ChatCollectionMessageList.swift → Chat/Timeline/

| 目标 | 范围/职责 | 预计行数 |
| --- | --- | ---: |
| NativeChatTimelineView.swift | 原 331-1565；生产 State/body/事件完整保留 | 1200-1280 |
| NativeTimelineProjectionCache.swift | 原 90-326；@MainActor projection reuse | 240-280 |
| Regression/ChatSwiftUIMessageList.swift | 原 1997-3055 + runtime 1955 | 1100-1160 |
| Regression/ChatSwiftUIViewportPolicies.swift | 原 1634-1857 + legacy helpers | 250-350 |
| ChatTimelineRows.swift | 原 3057-3285 wrappers + notice 1568 | 300-390 |
| ChatRenderState.swift | 原 3287-3456；live tail model/state/store | 180-240 |
| ChatRowContentHashCache.swift | 原 3484-3627；metadata identity/hash | 150-200 |
| ChatTimelinePolicies.swift | actions/session/native policy/anchor/modifier | 170-260 |
| PhoneAutomation/ChatPhoneToolGroupExpansionStore.swift | 原 3459；可并入领域 host support 避免过碎 | 30-45 |
| Regression/ChatRowHeightCache.swift | 原 3629；仅搜到定义，标候选未引用 | 80 |

风险/接口：保留 Native init、historyPageSize、testable static policies。跨文件 wrapper/model 只提升到 internal，不改 public，不整体开放 State/private func。HistoryRevealAnchor/scroll geometry 可与 Native host 同文件。缓存必须保留 mutable metadata snapshot，不能改为仅引用/length。没有删除授权，不删候选无引用类型。

### ChatMessageProjection.swift → Chat/Timeline/Projection/

| 目标 | 范围 | 预计行数 |
| --- | --- | ---: |
| ChatMessageAnchors.swift | 1-193 anchor/image resume | 200 |
| ChatMessageProjection.swift | 194-275 row/basic types + 852-1177 planner/projector/signature | 430-500 |
| NativeTimelineProjection.swift | 276-851 entry/projector | 580-640 |
| PhoneAutomation/ChatPhoneToolGrouping.swift | 1179-1537 summary/role/grouping | 370-420 |

保留 messageID/bottom/pending identity、streamed memory、renderDigest API；不在迁移波合并两套 entry 模型。grouping 仍接收 expansion value，timeline 单写；不在 projector 直接读 shared store。Native entry 的 “future Native” 注释应与现主入口同步。

### ChatAssistantMarkdownView.swift → Chat/Rendering/Markdown/

| 目标 | 职责 | 预计行数 |
| --- | --- | ---: |
| ChatAssistantMarkdownView.swift | 唯一入口、task/widget composition、URL policy | 520-620 |
| ChatMarkdownRenderConfiguration.swift | typography 571-630 + config/cache 408 起 | 220-300 |
| ChatStreamingMarkdownBlocks.swift | view/list/key/controller/model 631-835 | 220-280 |
| ChatStreamingMarkdownBlockParser.swift | parser 836-1120 + row cache 1281-1348 | 380-430 |
| ChatStreamingMarkdownDetection.swift | incremental table/widget detection 1122-1280 | 170-200 |
| ChatStableStreamingMarkdown.swift | view/controller/cache 1449-2056 | 620-700 |
| ChatMarkdownTestSupport.swift（可选） | 当前已存在 test support；或随 owner 共置 | 320-380 |

风险/接口：保留 ChatAssistantMarkdownView init，State/StateObject identity、MainActor controller + detached parser、cancel/latest-wins/publish 次序、speculative→completed cache 签名。静态 cache 不可为“解耦”改成每 View 实例而失去 remount reuse。测试 support 通过必要 internal 类型访问，不 public 化，也不删除原断言。复用现有 ChatMarkdownMedia.swift (318)；不复制媒体 parser。

### ChatToolTimelineView.swift → Chat/Tools/Presentation/

| 目标 | 职责 | 预计行数 |
| --- | --- | ---: |
| ChatToolTimelineView.swift | 1711-2020 layout + local status observation | 330-380 |
| ChatToolVisualStyle.swift | kind/state 6-224 | 230-260 |
| ChatToolStepModel.swift | model/init router 525-890 + common state/title | 450-650 |
| ChatSubAgentPresentation.swift | 226-327 + subagent parser 1052-1354；头像按 UI 归属 | 400-500 |
| ChatPhoneToolPresentation.swift | 386-523 | 150-180 |
| ChatToolResultSummary.swift | terminal/WebMount/search/image 剩余摘要/title | 500-700 |
| ChatPhoneToolGroupHeader.swift | 2022-2311 + stable handler/environment | 300-330 |

保留 StepModel init/identity、subagent accepted receipt refinement 门槛、可注入 ChatSubAgentRunStatusLoader。统一 output analysis，不重复 JSON 解码。环境 handler 继续稳定引用，不能改成 body 新闭包。

### ChatToolSupport.swift → ToolExecution/Approval + ToolExecution/Output

| 目标 | 范围 | 预计行数 |
| --- | --- | ---: |
| Output/ChatToolOutputAnalysis.swift | 1-272 analysis/memo/cache，private singleton 共置 | 280-320 |
| Approval/ChatToolApprovalModels.swift | 277-716 request/preview values | 450-520 |
| Approval/ChatToolApprovalRequestBuilder.swift | 718-1095；MCP declarations 可归父 packet runtime catalog | 380-430 |
| Output/ChatToolOutputFormatter.swift | 1097-1390 + 1751-1781 | 330-420 |
| Output/ChatToolOutputBudget.swift | 1392-1750 JSON/plain output cap | 370-430 |

先保留现 formatter 静态 API facade 内委托可降低 caller 同时变动，最终完成同 target caller 迁移再决定是否留。保持 @MainActor formatter/nonisolated analysis/failure 与 NSLock/unchecked Sendable cache 原边界；不能全体 MainActor 化。跨产品/版本化 Core 不在本任务范围。

### MessageBubbleView.swift → Chat/Message + Chat/Media/GeneratedImages

| 目标 | 范围 | 预计行数 |
| --- | --- | ---: |
| Message/MessageBubbleView.swift | 1-739 row dispatch、branching、annotations、alert | 740-800 |
| GeneratedImages/ChatGeneratedImageGrid.swift | 741-1097 grid/loading/failure/display/layout | 370-420 |
| GeneratedImages/ChatGeneratedImageTile.swift | 1098-1333 share/save/preview targets | 250-300 |
| GeneratedImages/ChatGeneratedImagePreview.swift | 1334-1543 preview/edit sheet | 220-260 |
| ChatUserImageTile.swift | 1545-1641，仅搜到定义，候选未用但保留 | 100 |

复用现有 ChatGeneratedImagePhotoWriter.swift (114)、ChatImageGenerationReference.swift (128)、ChatMediaGallery，不造第二份权限/下载/相册 service。bubble 继续拥有 detail/alert/focus；tile 拥有 save/preview/edit 状态。MessageBubbleView.swift:1273 photo write Task/状态、1248 covers 迁移后保持 owner 身份。用户 WIP 需先冻结本轮基线。

## 顺序和验证

1. Projection、OutputAnalysis/Approval/OutputBudget 完整 type 迁移；同步 XcodeGen project.yml 的 source membership、重新生成工程，并更新固定源码测试定位。
2. Bubble 独立图片 views、Tool presentation；保持 init/action/ID。
3. Markdown parser/detector/config/controller 成组迁移，一波仅一个 owner，不重写 async/cache。
4. Timeline 最后隔离 production/regression/caches/wrappers；保留 1237 行 Native host，不同波重构滚动算法。
5. 不因目录完成声称编译隔离；暂不新增 package。

每个涉及滚动、投影、Markdown packet 按 AGENTS 跑 ChatSwiftUIStreamReplayTests、NativeTimelineScrollCoreTests、ChatViewportPolicyTests。首类确有 Native 生产 replay（例如 :583 tool dense、:651 growing table、:890 image anchor），不是只有旧 SwiftUI。

- Projection/cache：ChatMessageProjectionTests、ChatRowContentHashCacheTests、ChatRowDigestTests、ChatIslandNavigationTests、ChatArtifactAnchorLayoutTests。
- Markdown：ChatStreamingTableLayoutTests、ChatMarkdownCJKEmphasisTests、ChatMarkdownCodeBlockTests、ChatMarkdownMediaTests、IOSGenerativeWidgetPayloadDetectorTests；重点 completion 不闪 raw text、remount 高度、growing table、cancel/stale parse。
- Tools：ChatToolGlyphMappingTests、ChatToolTimelineWidthOverflowTests、ChatPhoneToolGroupHeaderLayoutTests、IOSPhoneToolPresentationTests、ChatSubagentConversationLinkTests。
- Output/approval：IOSToolRuntimeTests、IOSWebMountOutputBudgetTests、IOSToolLoopGuardTests、IOSThemePackToolTests 和对应 approval/policy。
- Bubble：ChatMessageWidthOverflowTests、ChatReasoningCardTests、ChatMediaTests、ChatImageGenerationReferenceTests、IOSSettingsWiringTests。
- 必要 perf baseline：生产 30KB streaming/table、tool dense replay，确认可见行更新、停留历史不拉底、主动回底继续更新；本拆分不承诺性能提升。
- 真机门槛：滚动/键盘/手势、辅助功能字号、相册系统权限、VoiceOver image anchor。模拟器通过不能标真机已验证。
