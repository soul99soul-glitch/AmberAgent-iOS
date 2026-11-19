# 2026-11-11 Jev 页内连续控制、自动化过程截图相册归组与等待气泡抑制报告

- **工作树**：`/Users/arquiel/.synara/worktrees/ce201253131e`
- **Git 现场**：`HEAD = 84176fde736d3056e7a30fb1df66e44b7d378f5c`，`MERGE_HEAD = 6e89805b2667098e8ef523545915ca77c7b5f4a2`（完整保留 pending merge 与全部前序 WIP，未 commit / push / reset）

---

## 1. 根因诊断与最小实现

### 1.1 Computer Use / WebMount 页内连续点按（`IOSJevWebMountLoop.swift`、`ChatWebGoalTool.swift`、`IOSWebMountToolCatalog.swift`）
- **根因**：
  1. `IOSJevWebMountLoopService.legalActionCandidates` 仅生成 `scroll`、`click_nav`（限定 `role == "link"`）、`type_draft`、`submit_readonly_search`，完全排除了同一页面内的 `button`、`option`、`tab`、`radio`、`checkbox`、`switch`、`menuitem` 交互控件，导致词块组句、筛选项切换等页内连续操作每一步都回落通用 LLM。
  2. `PageElement` 未解析 `disabled` 与 `selected`/`checked` 状态，`recentSteps` 仅保留最近 5 步，长句或多步选择后半程易丢失上下文或误点已选中项。
  3. `ChatWebGoalTool.webMountLoopExecute` 在动作输出未带 `page_revision` 时执行一次 `wm_observe`，紧接着下一拍循环顶部又重复执行一次 `wm_observe`。
- **修复**：
  - 在 `ActionKind` 与 `actionWhitelist` 中新增 `click_control`，映射至 `wm_click`（继承宿主审批门与运行账本），仅对未禁用的具名页内交互角色生成候选，并通过 `isWithheldControlLabel` 严格排除发送、发布、支付、购买、下单、删除、登录、授权、提交、确认、验证码等高后果与敏感控件。
  - 解析 `disabled` / `selected` 状态并在候选描述中标注 `（已选中）` 与 `（同名第 k/n 项）`；`recentSteps` 窗口扩至 12 步。
  - 新增可选 `page_anchor`：子目标尚未达成而页面语义锚点偏离时立即 `handback` 交回通用 LLM，不在新页面盲点。
  - 在 `ChatWebGoalTool` 缓存动作后紧邻观察快照供下一拍循环顶部直接消费，消除重复 `wm_observe`。

### 1.2 Phone Use 页内连续控制与按需截图升级（`IOSPhoneGoalLoop.swift`、`IOSPhoneGoalModels.swift`、`IOSPhoneControlToolExecutor.swift`、`IOSJevPhoneControlService.swift`、`IOSPhoneControlToolCatalog.swift`、`IOSPhoneAutomationRequestPolicy.swift`）
- **根因**：
  1. `IOSPhoneControlToolExecutor` 在 `phone_run_goal` 每轮 `choose` 中无条件传入 `runner.screenshotObservation()`，开启截图权限后每次普通文本候选点按都要额外执行全屏抓图、PNG/JPEG 重编码与多模态上传。
  2. `IOSPhoneGoalRequest` 根级目标模式缺少 `page_anchor`，无法在单页目标模式下锁定当前题面/页面锚点；`IOSPhoneAutomationRequestPolicy.planningPrompt` 未明确引导同页多词块/多选项连续操作优先走单次 `phone_run_goal`。
- **修复**：
  - 新增 `IOSPhoneControlToolExecutor.chooseGoalAction`：默认先走纯 UI tree 极速决策（`screenshotProvider: nil`，`recentStepLimit: 12`，同时保持 `IOSJevPhoneControlService.chooseAction` 默认 `recentStepLimit = 5` 不破坏既有共享契约）；仅当 Jev 返回 `.needsScreenshot` 且截图范围已授权时，在同一轮立即补抓一次截图重判，免去 `400ms` `waitForUI` 空等。
  - 为 `IOSPhoneGoalRequest` 与 `phone_run_goal` schema 增加可选根级 `page_anchor`（与 `steps` 互斥），在初始观察及每次动作后核验锚点唯一匹配与内容稳定，页面语义变化立即以 `ReasonCode.pageChanged` 交回主模型。
  - 更新 `IOSPhoneAutomationRequestPolicy.planningPrompt` 与 `phone_run_goal` 描述，明确同页多步选词组句/多选切换优先使用单次 `phone_run_goal`。

### 1.3 连续自动化过程截图合并相册（`ChatPhoneToolGrouping.swift`、`ChatPhoneToolGroupHeader.swift`、`MessageBubbleView.swift`、`NativeTimelineProjection.swift`、`NativeTimelineChunk.swift`、`ChatTimelineChunkView.swift`、`NativeChatTimelineView.swift`、`ChatTimelineRows.swift`）
- **根因**：带图自动化工具（`phone_*`、`wm_*`、`browser_*`、`desktop_*`、`device_*`）输出含 `UIMessagePart.Image`，导致 `isGlobalStatusOnly == false`，连续批次的每条消息都挂载独立的全宽 `ChatToolMediaGallery` 纵向刷屏。
- **修复**：
  - 新增 L1 投影 `ChatAutomationScreenshotGrouping` / `ChatAutomationScreenshotGroupRole`，将同一连续自动化批次（跨越中间无图状态步骤，遇到用户消息、非空正文、子代理卡片、多变体、引用或非自动化媒体时收口）的过程截图聚合到批次首条消息（`.head`），其余纯过程截图成员行设为 `.member` 并在 `ChatTimelineChunkView` / `NativeChatTimelineView` 原位零高度折叠（保持 `entry.id` 与行索引不变）。
  - 新增 `ChatAutomationScreenshotAlbumView`：默认收起为紧凑卡片（叠放缩略图 + `过程截图 · N 张` + 步骤来源摘要 + 展开/收起箭头，兼容 `accessibilityReduceMotion` 与无障碍大字号）；展开后展示逐张截图卡片、序号、步骤标题与外部来源 `Link`，点击任意截图打开 `ChatMediaGalleryPreview` 全屏翻页缩放查看。
  - 遵守 `iosApp/AGENTS.md` 主线程纪律：`MessageBubbleView.body` 内仅走纯内存 `allowDiskLookup: false` 路径，零磁盘 IO、零 `JSONSerialization`。

### 1.4 无信息增量重复等待气泡抑制（`ChatAsyncTaskIsolation.swift`、`MacGatewayCloudDialogue.swift`）
- **根因**：本地 `ChatTaskCommentaryCoalescer` 与云端 `MacGatewayStore.ingestCloudDialogueEventsPage` 此前仅拦截逐字完全一致的同阶段/同 `workItemId` 文本，变体式纯等待套话（如“正在处理，请稍候…”“仍在继续操作中，请稍等。”）仍会不断生成或拼接正文气泡。
- **修复**：
  - 在 `ChatTaskCommentaryCoalescer.isZeroInformationWaitingText` 中基于纯通用等待子句集合识别零信息量等待语（严格排除含数字、问号、错误/异常/阻断、发现结论或业务名词的内容）；本地首轮接话后，无显式里程碑/阻断/审批的纯等待轮次自动剥离文本转为 `isGlobalStatusOnly` 状态更新（保留 60s 静默保活契约不变）。
  - 在 `MacGatewayStore.ingestCloudDialogueEventsPage` 中，同一轮对话已有前置回执气泡后到达的重复或变体零信息等待 `assistant_reply` 不再追加正文气泡，改为转为内部进度事件原位更新 `cloudDialogueProgressByWorkItem` 单行状态。

---

## 2. 定点验证证据（合成脱敏 Fixture，零真实付费模型调用）

| 验收维度 | 修改前基线（合成脱敏复现） | 修改后实测 |
| --- | --- | --- |
| WebMount 同页 4 词块连续组句 | `button` 不在候选内，0 次有效点击，需退回通用 LLM 逐步操作 | 单次 `wm_run_goal` 内由 Jev 连续完成 4 步 `click_control`（通用 LLM 往返 **1 次**），禁用项与“立即支付”自动拦截；题面锚点变化时第 1 步后立即 `handback` |
| Phone Use 同页 7 词块连续组句 | 若拆 `phone_act` 需 **7 次** LLM 往返；开启截图范围时每步抓图共 **7 次**（模拟页耗时 `>3500ms`），第 7 步仅见最近 5 步历史 | 单次 `phone_run_goal` 内 Jev 连续完成 **7 步**（通用 LLM 往返 **1 次**）；纯文本步零抓图，仅在模拟 `needs_screenshot` 的 1 步同轮补图 **1 次**（`waitForUI = 0 次`，模拟页总耗时 `<1500ms`），第 7 步完整可见前 6 步历史；题面变化立即返回 `ReasonCode.pageChanged` |
| 连续 3 步自动化过程截图时间线 | 3 条独立大图消息纵向平铺 | 收敛为 **1 个**紧凑相册头（`过程截图 · 3 张`），折叠态时间线总高 `<460pt`，展开后增高 `>80pt` 并完整保留 3 张图标题与 `practice.example` 来源 |
| 本地 + 云端重复等待气泡 | 变体等待语新增 2–3 个正文气泡 | 重复无增量等待气泡 **0 个**（原位更新单行状态），首条接话、实质异常发现与最终结果气泡完整保留 |

### 已执行通过的测试命令与套件
- `IOSJevWebMountLoopTests`、`IOSJevWebMountContractTests`、`IOSJevWebMountSelectCandidateTests`：全部通过（exit `0`）
- `IOSPhoneGoalLoopTests`、`IOSPhoneGoalLoopRecoveryTests`、`IOSPhoneGoalToolIntegrationTests`、`IOSJevPhoneControlServiceTests`、`IOSPhoneAutomationRequestPolicyTests`：全部通过（exit `0`）
- `ChatPhoneToolGroupingTests`、`ChatMediaTests`、`IOSDialogueTimelineResidualTests`：全部通过（exit `0`）
- `ChatAsyncReActLoopTests`、`MacGatewayCloudDialogueTests`（含前序云端三点波浪、单行状态流光与建议条避让全部 12 项测试）：全部通过（exit `0`）
- `NativeTimelineScrollCoreTests`、`ChatViewportPolicyTests`、`ChatRowContentHashCacheTests`、`ChatMessagePresentationTests`：全部通过（exit `0`）

---

## 3. 「云端配置」实质去重重构与同尺寸截图核验

针对真机截图 `IMG_2882.PNG`（「切换云端服务商与模型」区域服务商/模型/`Base URL` 重复 3–4 次、大号彩色图标与高对比值相互竞争、「重新同步…」动态截断标题混排「切换并使用」胶囊按钮），已在 [CloudConfigSettingsView.swift](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosApp/CloudConfigSettingsView.swift)、[CloudConfigTransitionSupport.swift](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosApp/CloudConfigTransitionSupport.swift) 与 [CloudConfigSheetViews.swift](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosApp/CloudConfigSheetViews.swift) 完成实质删减重构：

1. **彻底消除同屏重复**：删除顶部重复的 4 行「云端当前模型」卡与主卡内的双行「当前 / 目标」摘要及底部冗余操作/安全说明；同一配置在首屏仅出现一次。
2. **主卡收敛为「修改云端配置」**：仅保留无「目标」前缀的「服务商」「模型」两行干净菜单选择（移除所有行级红色大图标底板与高对比着色值）；当所选与云端一致时仅显示普通非可点文本状态「已在使用」；仅当选择变化时显示单行简短变化提示（如 `当前：deepseek-v4.1-flash`，中间截断）与全页唯一主按钮「切换并使用」（`fixedSize` + `layoutPriority(1)`，43 字符长模型名绝不挤压标题或按钮），保留切换中（`正在切换…`）与内联失败反馈。
3. **「从本机同步」独立为次级操作**：移出主操作卡，使用固定短标题「从本机同步」配单行覆盖副作用说明（「上传本机配置与 API Key，确认后覆盖云端现有设置。」），点击进入确认面板，不与云端直接切换混排。
4. **次级与底部高级分层**：「联网搜索」收敛为两行安静次级项；「手动配置」与默认折叠的「连接详情」（收纳 `协议类型`、`Base URL`、`API Key` 状态与 `配置版本`）下沉至页面底部「高级」区。
5. **定点测试与同尺寸截图核对**：
   - `IOSCloudConfigTests`（含新增 `testPrimarySwitchStateShowsPlainInUseWhenMatchedAndConciseHintOnlyWhenChanged`）与 `IOSCloudConfigTransportTests` 全部通过（exit `0`）。
   - `iPhone 17 Pro`（同宽 `1206px`）真实渲染留证：
     - 亮色一致态（`已在使用`）：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/db04e0d9-4c2a-4106-a55f-bdcd44e71521.png`
     - 亮色变更 + 43 字符长模型名态（唯一主按钮 `切换并使用`）：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/f65c4ea4-047f-49e7-8c72-1a32ddbf435b.png`
     - 深色模式 + 「高级 › 连接详情」展开态：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/7dc8f8fa-6c6b-42ca-bf39-591d1f654c4e.png`

---

## 4. 物理真机无线保数据覆盖安装与模拟器验证证据

1. **物理真机最终版 Xcode 签名构建与无线保数据覆盖安装（包含本轮云端配置精简 UI + Jev 连续控制 + 截图归组 + 等待抑制）**：
   - 目标物理真机：`iPhone (2)`（`iPhone 18 Pro`，`iPhone19,2`，UDID `00008160-001939111420000A`，无线 `available (paired)`）
   - 增量签名编译产物：`/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADeviceBuild20261108/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app`
     - `Scheme` / `Configuration`：`iosAppExperimentalGPL` / `Debug-iphoneos`
     - `DEVELOPMENT_TEAM`：`TY4JTL3V2M`
     - `CFBundleIdentifier`：`app.amber.ios`（`Amber`，`1.0.0` / `1`，与机上已有应用一致，无卸载、无数据清空、无第二图标）
     - 最新主二进制 SHA-256：`dd1198ad4fb6037c8a5c76e0e07379bcfb285d30e8387b5dc36e502fe1cd29d4`（替换前两版 `6b035c6c...` -> `c55f09ec...` -> `dd1198ad...`）
     - 签名严格校验：`codesign --verify --deep --strict --verbose=2` 返回 `valid on disk`、`satisfies its Designated Requirement`（退出码 `0`）
   - 无线保数据覆盖安装结果：
     - 命令：`xcrun devicectl device install app --device 00008160-001939111420000A`
     - `outcome`：`"success"`
     - 最新 Bundle 容器：`file:///private/var/containers/Bundle/Application/65F4B7FD-21A8-4E93-BCC7-5102B6AB44F0/iosAppExperimentalGPL.app/`
     - `databaseUUID`：`14914597-0AC5-4C9D-9E54-4D10AB79E1D7`
     - `databaseSequenceNumber`：`3376`（由上一轮 `3360` 递增至 `3376`）
   - 远程进程启动状态（严格区分「已安装」与「锁屏未拉起」）：
     - 新包已完整覆盖安装落盘；执行 `devicectl device process launch` 时真机处于锁屏态（`FBSOpenApplicationErrorDomain error 7 / BSErrorCodeDescription = Locked: "Unable to launch app.amber.ios because the device was not, or could not be, unlocked"`），解锁手机点开 Amber 即直接运行该最新二进制 `dd1198ad...`。
   - 原始 JSON 证据文件（位于 gitignore 的构建目录下）：
     - `/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/JevDeviceInstall20261111/iphoneos-cloud-ui-build.log`
     - `/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/JevDeviceInstall20261111/cloud-ui-install-result.json`
     - `/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/JevDeviceInstall20261111/cloud-ui-launch-result.json`
2. **模拟器保数据覆盖安装与启动验证**：
   - 目标模拟器：`iPhone 17 Pro`（iOS 26.5，UDID `F3D5299E-EEA6-4098-BF61-AB1C516933C0`）
   - 安装包：`/Users/arquiel/Library/Developer/Xcode/DerivedData/AmberAgent-gztviftspdepikbgojeuyltfvnsg/Build/Products/Debug-iphonesimulator/iosApp.app`（`CFBundleIdentifier = app.amber.ios`）
   - 执行结果：`device_install` 保数据覆盖安装成功，`device_launch(restart: true)` 正常模式拉起成功（`pid: 60298`，`settled: true`）。

---

## 5. 2026-11-11 续修补记：云端配置直接切换修复、Duolingo 真机分段诊断与合并安装

### 5.1 「云端配置」直接切换失效根因与界面收敛对齐
- **根因**：
  1. `SwiftUI` `List` 行内未声明 `.buttonStyle(.plain)`，整行吸收点击导致右侧 `切换并使用` 胶囊存在死区；
  2. `CloudConfigSettingsSupport.normalizedHTTPSURLString` 未对省略协议头的域名输入（如 `opencode.ai/zen/v1`）自动补全 `https://`，或遇到非合法 URL 时缺少前置拦截；
  3. OAuth 登录服务商（如 Claude / OpenAI Codex）在本机无明文 `apiKey` 时缺少从当前活跃对话连接回退凭证的路径；
  4. 用户切换下拉菜单后未清理上一次切换遗留的顶部绿色成功横幅。
- **修复与对齐**：
  - 更新 `CloudConfigSupport.swift`、`CloudConfigTransitionSupport.swift`、`CloudConfigStore.swift`、`MacGatewayStore.swift`、`CloudConfigSettingsView.swift`：补齐 `.buttonStyle(.plain)` + `.contentShape(Rectangle())` 命中区域、自动补全并校验 `https://` URL、支持活跃会话凭证安全回退、切换选择即清除陈旧成功提示，并将页面结构统一收敛为 `云端模型` / `本机同步` / `联网搜索` / `高级` 四区。
  - 验证：`IOSCloudConfigTests` 与 `IOSCloudConfigTransportTests` 全量通过；`iPhone 17 Pro`（`402x874pt`）浅色与深色模式证明截图及 `@319,304` 真实点击 `切换并使用` 闭环验证通过：
    - 浅色一致态（`已在使用`）：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/77ddabfc-c1c1-4e11-99c8-6acc28b9f5e2.png`
    - 浅色待切换态（`切换并使用`）：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/64cc000e-ae94-45c4-ade5-7b82ee8f0282.png`
    - 深色待切换态（`切换并使用`）：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/65bee579-f23f-4d3e-a1fa-95782e089f4b.png`
    - 深色点击后成功态（`已切换云端配置为 Claude · claude-sonnet-4-5`）：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/e55b8be9cdddc4388acfb88e/2e693bf5-0a5a-4902-8259-f439cdaf156b.png`

### 5.2 Duolingo 真机实跑（`conv-0821` / `conv-2301`）分段耗时诊断与最小安全修复
- **真机实跑还原（`2026-11-11 08:16:47.7` → `08:21:45.3 +08:00`，总墙钟 `297.6s`，`15` 个模型轮次）**：
  - 全程调用 `phone_status` × 1、`phone_act` × 9、`phone_observe` × 4，**`phone_run_goal = 0` 次、`Jev phoneActions = 0` 次**（前一晚 `conv-2301` 耗时 `587s` 同样 `phone_run_goal = 0` 次，`phone_run_flow` 3 次全部 `handback`）。
- **5 项已证实根因与对应修复**：
  1. **旧版记忆技能笔记绕过 `phone_run_goal`**（`IOSPhoneAutomationRequestPolicy.swift`）：召回的历史 Duolingo 笔记成文于 `phone_run_goal` 之前，指导逐步调用 `phone_act` / `phone_run_flow`；已强化 `planningPrompt` 明确单页选词/选项 + Check 优先走单次 `phone_run_goal`，且 `truncated=false` 时无需为 `omitted` 重复调用 `phone_observe`。
  2. **`fastFirstReasoning` 覆盖手机会话 `.low` 思考上限**（`IOSAgentToolEngine.swift`）：`steps >= 1` 时 `workerReasoningName = "HIGH"` 将 `phoneRequestParams` 已收紧的 `.low` 覆盖回 `.high`，导致每步单次点击耗时 `11.8s–26.5s` 并放大主线程流式渲染卡顿（`amber-perf-live.jsonl` 记录 `1,137` 次 hitch，峰值 `1,484ms`）；现保留 `normalParams !== effectiveParams` 时的专属推理参数。
  3. **`omitted=70` 歧义引发 `120.0s` 连续空转**（`PhoneControlModels.swift`）：`08:19:45.7` → `08:21:45.3` 单题卡顿源于模型将 `nodes=98 displayed=28 omitted=70`（`truncated=false`）误判为题干/词块被裁剪，连发 3 次冗余 `phone_observe` 并触发保活后长思考；现显式输出 `(empty_containers=...; unlabeled layout wrappers only, no text or controls omitted)`。
  4. **Duolingo 词块内嵌只读 `TextView` 与底部判题横幅同名外层 `Other` 引发 `ambiguous_target` / `step_not_executable`**（`IOSPhoneGoalVerification.swift`）：`collapseLabelChildMatches` 现折叠同标签父控件矩形内的只读非聚焦 `XCUIElementTypeTextView`，以及包围具名实体交互控件（如 `Button id="challenge_check_button" label="继续"`）的无 ID 同标签外层 `Other`/`Group` 容器。
  5. **Jev 多模态动作后校验 `1200ms` 超时与 `needsScreenshot` 空等**（`IOSJevSettings.swift`、`IOSJevDecisionCoordinator.swift`、`IOSPhoneGoalLoop.swift`）：真机 `IOSJevMetricsStore` 中 `phoneVerification` 因上传截图命中 `1200ms` 预算 `2/2`（`100%`）超时，现对齐至交互级 `webActionsDeadlineMs`（`2500ms`）；同时将 live `runGoal` 的 `.needsScreenshot` 从 3 轮空转轮询分离为立即 `screenshotRequired` 回交，并过滤系统滚动条指示器（`水平滚动条` / `垂直滚动条`）混入候选集。
- **Red -> Green 回归测试**：
  - `AmberPhoneControlTests`：`126` 项测试全部通过（`0` 失败）。
  - `AmberAgent.xcodeproj` 受影响单元测试套件（`IOSAgentToolEngineTests`、`IOSPhoneAutomationRequestPolicyTests`、`IOSPhoneGoalVerificationTests`、`IOSPhoneGoalLoopTests`、`IOSPhoneGoalLoopRecoveryTests`、`IOSJevPhoneControlServiceTests`、`IOSJevSettingsTests`、`IOSCloudConfigTests`、`IOSCloudConfigTransportTests`）：`248` 项测试全部通过（`0` 失败）。

### 5.3 合并后唯一次真机无线保数据覆盖安装证据
- **目标真机**：`iPhone (2)`（`00008160-001939111420000A`），`CFBundleIdentifier = app.amber.ios`
- **最新签名主二进制 SHA-256**：`bd2a28b022cf96aa744451ee963b82c43099d65e20099c9a5a24cd55b080ac9b`（`codesign --verify --deep --strict` 通过）
- **安装结果**：`outcome = "success"`，`databaseSequenceNumber = 3416`（由 `3376` 递增至 `3416`），`installationURL = file:///private/var/containers/Bundle/Application/CEF20399-4FB3-48DE-BF7B-F106EAECB97C/iosAppExperimentalGPL.app/`，原数据容器完整保留；远程启动因锁屏返回 `FBSOpenApplicationErrorDomain error 7 (Locked)`。
- **真机最短实测步骤**：解锁手机打开 Amber -> 先在设置检查/清理或更新旧版逐步 `phone_act` 的 Duolingo 技能笔记（可选，系统提示词已兜底优先 `phone_run_goal`） -> 在新对话发起 1 节 Duolingo 练习，观察 `phone_run_goal` 连续选词提交及 `IOSJevMetricsStore` 中 `phoneActions` / `phoneVerification` 延迟与成功率。
