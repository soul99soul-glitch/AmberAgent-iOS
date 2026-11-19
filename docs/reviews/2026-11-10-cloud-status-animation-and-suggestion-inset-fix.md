# 2026-11-10 云端 Amber 三点波浪、单行状态动效与建议气泡避让修复报告

## 1. 现象与根因核查（本地 vs 云端对比）

### 1.1 问题一 & 问题二：云端生成缺少「三个点波浪」与「单行状态动效」
- **本地实现（`ChatTimelineActivityRowView` → `ChatTaskInlineCardView`）**：
  - 使用 `ChatTaskProgressDot`（内部挂载 `ChatTaskWaveLayers` / `ChatTaskWaveLayerView`，3 个错相灰阶圆点做正弦波浪循环，`accessibilityReduceMotion` 开启时降级为 3 个静态灰阶点，结束后收拢为单点）。
  - 使用 `ChatTaskProgressTextShimmer`（内部挂载 `ChatTaskShimmerLayers` / `ChatTaskShimmerLayerView` 流光遮罩），配合 `ZStack` + `.id(headline)` 的非对称推拉淡入淡出 `.transition` 与 `.snappy(duration: 0.26, extraBounce: 0)` 动效。
- **云端实现缺失根因（`AmberHostSwitcherPill.swift`、`MacGatewayCloudDialogue.swift`）**：
  1. `AmberInlineCloudMainDialogueView` 的 `liveProgressSection` 与 `awaitingCloudReplyRow` 以及 `MacGatewayCloudDialogueSheet` 的进度列表均直接使用了普通 `ProgressView().controlSize(.small)` 转圈与无动效静态 `Text`，未接入 `ChatTaskProgressDot` 与 `ChatTaskProgressTextShimmer`。
  2. `liveProgressSection` 原本被放在 `LazyVStack` 顶部（所有对话气泡上方），且 `sortedProgressItems` 未过滤已完结的历史 `WorkItem`。一旦存在历史 `WorkItem` 或收到首个 `process_event`，底部 `awaitingCloudReplyRow` 立即消失，而顶部进度区在多轮对话中位于视口上方不可见。
  3. `MacGatewayCloudDialogueEvent.isUpfrontAcknowledgement` 未覆盖 `"正在处理，请稍候"` 前置等待回执，且 `MacGatewayStore.isAwaitingCloudMainReply` 在 `delegatedWorkIds` 非空时未排除 `isUpfrontAcknowledgement` 事件，导致收到前置人格化等待气泡后等待状态被提前清空。
  4. `AmberInlineCloudMainDialogueView` 首次挂载 `.onAppear` 调用 `scrollToBottom()` 时底层 `UIScrollView` 尚未由 `NativeTimelineScrollViewResolver` 完成异步绑定，导致长对话首次挂载未自动收敛至最底部。

### 1.2 问题三：建议气泡轻微压住底部消息正文（`ChatSuggestionStrip`）
- **根因（`ChatComposerViews.swift`、`NativeTimelineScrollDriver.swift`、`AmberHostSwitcherPill.swift`）**：
  1. 云端回复到达时，`AmberInlineCloudMainDialogueView` 先按无建议条时的 `inputBar` 高度完成一次贴底滚动；随后 `refreshCloudSuggestions(gateway:)` 异步生成建议词并动态插入 `ChatSuggestionStrip`，使 `.safeAreaInset(edge: .bottom)` 向上增长 `56.0pt`。
  2. 此时仅 `UIScrollView.safeAreaInsets.bottom` / `adjustedContentInset.bottom` 增大，滚动内容自身尺寸不变；而 `NativeTimelineScrollViewResolver` 的探测视图位于滚动内容内部，未能感知外层 `UIScrollView` 安全区变化，且 `AmberInlineCloudMainDialogueView` 缺少 `.defaultScrollAnchor(.bottom, for: .sizeChanges)`（`ChatSizeChangesPinModifier`）与 `onMetricsChanged` 贴底重锚定逻辑。
  3. 窄复现测试实测：建议条异步出现后，`UIScrollView` 存在 `56.0pt` 未补偿的底部 inset 增长，最后一条云端消息气泡底边（`698.0pt`）越过建议条顶边（`676.0pt`）达 `22.0pt`，直接压住气泡底部正文与边框。
  4. 此外 `ChatSuggestionStrip` 内部横向 `ScrollView` 未声明 `.fixedSize(horizontal: false, vertical: true)`。

---

## 2. 修复内容

1. **`iosApp/iosApp/MacGatewayCloudDialogue.swift`**：
   - 扩展 `MacGatewayCloudDialogueEvent.isUpfrontAcknowledgement` 识别 `"正在处理，请稍候"` 前置回执，保留其作为正文消息气泡显示，不新增模板化等待句，也不替换正文气泡。
   - 修复 `MacGatewayStore.isAwaitingCloudMainReply` 在检查 `hasTopicActivity` 时排除 `!candidate.isUpfrontAcknowledgement`，确保前置等待气泡到达后至首个 `process_event` 或最终回复到达前持续保持生成等待态。
2. **`iosApp/iosApp/Navigation/AmberHostSwitcherPill.swift`**：
   - 新增 `AmberCloudTaskProgressRowView`，完整复用本地 `ChatTaskProgressDot`（三点波浪）与 `ChatTaskProgressTextShimmer`（单行流光 + `.id(headline)` 非对称推拉切换 + `.snappy(duration: 0.26, extraBounce: 0)`），严格遵守 `@Environment(\.accessibilityReduceMotion)`，并保留运行中 `WorkItem` 的内联「补充」「停止」操作胶囊。
   - 在 `AmberInlineCloudMainDialogueView` 时间轴尾部（消息列表下方、`cloud-dialogue-bottom-anchor` 上方）统一渲染 `tailStatusItems`，将主状态行 ID 固定为 `"cloud-status-primary"`，使初始等待状态向实时 `process_event` 状态切换时原位平滑过渡而不重建波浪图层，同时不再把已完结的历史 `WorkItem` 常驻在列表顶部。
   - 新增 `AmberCloudTimelineScrollCoordinator` 并挂载 `ChatSizeChangesPinModifier(preservesScrollIdentity: true, enabled: scrollCoordinator.isPinnedToBottom)`，在首次解析 `UIScrollView`、新消息/状态推进、以及底部安全区/建议条显隐引发 `adjustedContentInset.bottom` 变化时自动贴底重锚（用户上滑阅读历史时不强拉回底）。
3. **`iosApp/iosApp/ChatComposerViews.swift` & `iosApp/iosApp/NativeTimelineScrollDriver.swift`**：
   - 为 `ChatSuggestionStrip` 的横向 `ScrollView` 增加 `.fixedSize(horizontal: false, vertical: true)`，锁定纵向布局高度。
   - 在 `NativeTimelineScrollViewResolver.Coordinator` 中为宿主 `UIScrollView` 直接挂载 `0x0` 隐藏探测视图 `ScrollViewInsetProbeView`，捕获 `.safeAreaInset(edge: .bottom)`（如建议条异步显隐、底栏高度变化）触发的 `safeAreaInsetsDidChange()` 并启动 `monitorRecentMetrics()`，使本地与云端时间轴均能即时响应底部 inset 变化。

---

## 3. 验证证据

### 3.1 窄复现与联合回归测试（合成脱敏夹具）
- **RED 复现（`/tmp/cloud-motion-suggest-red.xcresult`）**：
  - `cloudMainDialogueMountsWaveDotsAndSingleLineStatusShimmerAtConversationTail`：`personaAckEvent.isUpfrontAcknowledgement → false`、`store.isAwaitingCloudMainReply → false`、`!waveViewsPhase1.isEmpty → false`、`!shimmerViewsPhase1.isEmpty → false`。
  - `cloudBottomSuggestionStripAppearingAsynchronouslyNeverOverlapsLastMessageBubble`：`uncompensatedInsetGrowth == 56.0pt`、`contentBottomInWindow (698.0) > suggestionFrameInWindow.minY (676.0)`。
- **GREEN 回归（`/tmp/cloud-motion-suggest-regression.xcresult`）**：
  - **52/52 全部通过（0 失败）**：
    - `MacGatewayCloudDialogueTests`：`12/12` 通过（含 `cloudMainDialogueMountsWaveDotsAndSingleLineStatusShimmerAtConversationTail` 与 `cloudBottomSuggestionStripAppearingAsynchronouslyNeverOverlapsLastMessageBubble`）
    - `AmberPersonaAvatarTests/testProgressRowWaveShimmerTransitionAndFixedAvatarAnchorOnRealChatMount`：`1/1` 通过
    - `ChatMessagePresentationTests/testSuggestionStripReachesScreenEdgesAndDraftRemainsEditableAfterFilling`：`1/1` 通过
    - `ChatTimelineRowLayoutTests`（`ChatSubAgentResultCard` 与时间轴布局回归）：`7/7` 通过
    - `ConversationArtifactIndexTests`（产物架去重与按轮次分组）：`19/19` 通过
    - `ChatArtifactActionsTests`：`12/12` 通过
    - `ChatArtifactShelfStateTests`：`3/3` 通过
    - `ChatArtifactShelfLayoutTests`：`2/2` 通过

### 3.2 模拟器实机与真机签名包验证
- **模拟器 `iPhone 17 Pro`（`UDID: F3D5299E-EEA6-4098-BF61-AB1C516933C0`）**：
  - 通过 `device_install` 安装最新 `iosApp.app` 并通过 `device_launch` 启动（`pid: 66249`, `settled: true`）。
  - 留证截图：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/30389bda76d59eafeda8b532/3a6b8c9c-56e9-4cd8-b0a8-e48a68209c28.png`。
- **真机 `Debug-iphoneos` 签名包构建**：
  - 产物路径：`iosApp/build/GroupADeviceBuild20261108/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app`
  - 签名团队与 Bundle ID：`DEVELOPMENT_TEAM=TY4JTL3V2M`，`AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER=app.amber.ios`
  - `codesign --verify --deep --strict`：退出码 `0`
  - 二进制 SHA-256：`6b035c6c01608267bd4801ca7aa663f253305dfc411b9e24d6c7575f776412b9`
- **物理真机安装通道说明**：
  - `device_list` 当前仅枚举 `ios-simulator` 设备（`F3D5299E-EEA6-4098-BF61-AB1C516933C0`、`E6AA19C9-1C19-45CB-8B62-963E86332A90`），底层 `device_install` 走 `simctl install`，尚不支持物理真机 UDID 直装；遵守宿主约束未使用任何未授权绕行命令，真机签名包已就绪。
