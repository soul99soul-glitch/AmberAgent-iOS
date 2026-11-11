# 产物架无上限膨胀修复、子智能体卡片回归与真机安装包交付报告（2026-11-10）

## 1. 问题根因与修复要点

### 1.1 产物架（`ConversationArtifactIndex` / `ChatArtifactShelfPanel`）无上限膨胀修复
- **根因 1（检索网页全量计入顶层成果数）**：`iosApp/iosApp/ConversationArtifactIndex.swift` 原实现将每次成功的 `scrape_web`、`wm_open`、`wm_extract` 均平铺计入顶层 `count = images.count + files.count + webPages.count + htmlPages.count`，导致多轮联网检索后右上角 `#topbar-dock` 角标与面板标题暴涨至 `产物架 54`（`1` 图 + `53` 网页）。
- **根因 2（跨轮同源 URL 与同内容文件版本未规范化去重）**：原 `appendWebPage` 与 `appendImage` 仅按原始 URL 字符串判重，未对协议（`http`/`https`）、大写域名、默认端口（`:80`/`:443`）、尾部 `/`、`#fragment`、追踪参数（`utm_*`/`spm`/`from`/`fbclid`/`gclid` 等）与查询参数顺序做规范化；`appendFileVersion` 对连续写入相同非空 `content` 的 `workspace_file_write` 亦重复追加版本。
- **根因 3（面板平铺旧轮次原始链接）**：`iosApp/iosApp/ChatArtifactShelfPanel.swift` 原实现直接按旧轮次升序平铺 `ForEach(artifacts.webPages)`，未按轮次分组收起临时检索资料。
- **修复文件与行号**：
  - `iosApp/iosApp/ConversationArtifactIndex.swift:41-58`、`91-118`、`205-248`、`300-335`、`388-512`：
    1. 新增 `WebPageGroup`（`id: "web-turn-\(turn)"`、`turn`、`pages`、`latestSource`）及 `webPageGroups: [WebPageGroup]`（按 `source.turn` 降序分组，最新轮次在顶）；
    2. 顶层 `ConversationArtifactIndex.count` 改为 `images.count + files.count + webPageGroups.count + htmlPages.count`，每轮检索网页聚合计为 1 个逻辑检索组（与 `FileGroup` 多版本计 1 项保持一致），不再将 54 条原始网页链接逐条撑大顶栏角标；
    3. 新增 `canonicalWebIdentity(_:)` 与 `canonicalImageIdentity(_:)`，对跨轮同源 URL/图片按规范化 identity 去重，合并时优先保留 `https://` URL、非 URL 标题与非空摘要，并将 `source` 更新为最新轮次；
    4. `appendFileVersion` 对同路径连续相同非空 `content` 的写入就地更新最新版本，不产生冗余版本；同消息/跨消息完全相同的生成式 HTML widget 亦按标题+代码去重。
  - `iosApp/iosApp/ChatArtifactShelfState.swift:31-36`：
    - `entries(_:)` 改为跟踪 `index.webPageGroups`（`globe`），使新轮次检索组到达动画与顶栏逻辑计数一致。
  - `iosApp/iosApp/ChatArtifactShelfPanel.swift:31`、`73-112`、`265-389`：
    - 新增 `@State var expandedWebGroupTurns: Set<Int> = []` 与 `ChatArtifactShelfPanel.visibleWebPages(in:expandedTurns:)`；
    - 单条网页（`webPages.count == 1`）保持直接展示 `ChatArtifactWebPageRow`；多条网页（`webPages.count > 1`）展示 `网页  N 轮 · M 条` 与按轮次降序排列的 `ChatArtifactWebTurnGroupCard`，默认收起各轮次原始检索链接，点击轮次卡片可按需展开查看该轮全部网页来源并保留 `"第 N 轮 ↗"` 跳转定位与多选导出能力。
  - `iosApp/iosAppTests/ConversationArtifactIndexTests.swift:448-680`：
    - 新增 `testMultiTurnWebSearchDeduplicatesCanonicalItemsGroupsByTurnAndPreservesDeliverablesAt54PlusScale`（含 56 次原始检索 -> 54 条唯一网页 -> 3 个轮次组、顶层 `index.count == 5`、用户显式收藏固定 `IOSPinnedArtifactSnippet`、文件成果与图片成果保留、报告导出、取消收藏删除及 `UIWindow` + `UIHostingController` 宿主下 `ChatArtifactShelfPanel` 默认收起 vs 展开第 1 轮的高度与滚动校验）。

### 1.2 `ChatSubAgentResultCard` 展开/收起重叠与底部滚动截断修复（同轮保留）
- `iosApp/iosApp/ChatSubAgentResultCard.swift:18-92`、`214-281`：注入 `@Environment(\.markdownLayoutInvalidationID)` 并在 `body` 与 `toggleExpansion()` 调用 `ChatTimelineRowLayoutInvalidation.markRowDirty(layoutInvalidationID)`；以 `ChatSubAgentResultStackLayout(isExpanded: isExpanded)` 替代内部 `VStack`，收起态仅测量 `header` 高度。
- `iosApp/iosApp/Chat/Timeline/ChatTimelineRowLayout.swift:122-167`：在 `sizeThatFits` 入口同步校验 `cache.invalidationToken`。
- `iosApp/iosAppTests/ChatTimelineRowLayoutTests.swift:84-334`：新增 `testSubAgentResultCardExpandCollapseAndConsecutiveArrivalMaintainNonOverlappingLayoutAndBottomScrollReachability`。

---

## 2. RED / GREEN 自动化测试统计与原始输出

### 2.1 产物架 RED 失败输出（实现修复前）
- 命令：`xcodebuild test ... -only-testing:iosAppTests/ConversationArtifactIndexTests/testMultiTurnWebSearchDeduplicatesCanonicalItemsGroupsByTurnAndPreservesDeliverablesAt54PlusScale`
- 原始失败断言：
  - `XCTAssertEqual failed: ("56") is not equal to ("54") - 同规范 URL 跨轮检索必须去重为单个逻辑网页项`

### 2.2 全套定向 GREEN 测试结果（产物架 40 项 + `ChatSubAgentResultCard` 7 项 = 47/47 通过）
- 结果包路径：`/tmp/artifact-shelf-and-card-green2.xcresult`（`exit 0`，耗时 `35.764s`）
- 套件明细（`TOTAL: passed=47, failed=0`）：
  - `ConversationArtifactIndexTests`：`19/19 Passed`（含 `testMultiTurnWebSearchDeduplicatesCanonicalItemsGroupsByTurnAndPreservesDeliverablesAt54PlusScale()`，`0.54s`）
  - `ChatArtifactShelfStateTests`：`3/3 Passed`
  - `ChatArtifactActionsTests`：`12/12 Passed`
  - `IOSConversationArtifactStoreTests`：`4/4 Passed`
  - `ChatArtifactShelfLayoutTests`：`2/2 Passed`
  - `ChatTimelineRowLayoutTests`：`2/2 Passed`（含 `testSubAgentResultCardExpandCollapseAndConsecutiveArrivalMaintainNonOverlappingLayoutAndBottomScrollReachability()`，`3s`）
  - `ChatTimelineReviewRegressionTests/testRowZeroOuterRefreshSkipsGraphHostAndRowRemeasureWhileStreamingLineWrapGrowsHeight`：`1/1 Passed`（`3s`）
  - `ChatMessagePresentationTests`（3 项 `ResultCard` 测试）：`3/3 Passed`
  - `PerformanceHygieneTests/testMessageBubbleViewInjectsIdentityStableEnvironmentValues`：`1/1 Passed`

---

## 3. 真机签名包构建与 `device_*` 覆盖安装/启动验证

### 3.1 真机签名包（`iphoneos` arm64）
- **产物路径**：`/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADeviceBuild20261108/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app`
- **Bundle ID / Team**：`CFBundleIdentifier = app.amber.ios`，`TeamIdentifier = TY4JTL3V2M`（`Apple Development: Chen Li (V3NCZ67NRP)`）
- **签名校验**：`codesign --verify --deep --strict` 通过（`exit 0`）
- **主二进制 SHA-256**：
  - `f677019816a572151ca6fe8b90ffe90b267016e04922da26365c2303ef1c8f20`（`iosAppExperimentalGPL.app/iosAppExperimentalGPL`）
- **工作树完整性**：`HEAD = 84176fde736d3056e7a30fb1df66e44b7d378f5c`，`MERGE_HEAD = 6e89805b2667098e8ef523545915ca77c7b5f4a2`，全部既有主线融合改动与本轮两项修复完整保留，未执行 `commit` / `push` / `reset`。

### 3.2 `device_*` 工具检查、安装与启动状态
- **`mcp_synara_device_list(includeShutdown: true)`**：
  - 仅返回 3 台 `platform: "ios-simulator"` 设备（其中唯一 booted 设备为 `iPhone 17 Pro`，`UDID = F3D5299E-EEA6-4098-BF61-AB1C516933C0`），未枚举物理真机。
- **物理真机 `mcp_synara_device_install` 阻断说明**：
  - 对物理 iPhone UDID `00008160-001939111420000A` 调用 `mcp_synara_device_install` 返回：
    `Encountered error in tool execution: simctl install failed: Invalid device: 00008160-001939111420000A`
  - 原因：当前宿主 `device_*` 工具集底层绑定 `simctl`（仅支持 `ios-simulator`），未暴露物理 `iphoneos` 设备安装通道；严格遵守项目约束未使用被禁止的绕行命令，也未卸载或清空任何设备数据。
- **在 `device_list` 可用目标（`F3D5299E-EEA6-4098-BF61-AB1C516933C0`）上的保留数据覆盖安装与启动校验**：
  - `mcp_synara_device_install`：成功覆盖安装 `/Users/arquiel/Library/Developer/Xcode/DerivedData/AmberAgent-gztviftspdepikbgojeuyltfvnsg/Build/Products/Debug-iphonesimulator/iosApp.app`（`bundleId: "app.amber.ios"`）。
  - `mcp_synara_device_launch`：成功启动（`pid: 39334`，`settled: true`，`waitedMs: 4169`，`screenChanged: true`），首屏 17 个可见无障碍元素（含 `#topbar-dock` `"产物架，0 项"`、`#chat.duet.tab.chat` `"对话"`、`#chat.duet.tab.tasks` `"任务"`、`#chat.duet.tab.hubs` `"中心"`、`#chat.duet.hostSwitcherPill`）正常就绪。
  - `mcp_synara_device_screenshot(proof: true)`：`/Users/arquiel/.synara/codex-home-overlay/generated_images/device-proof/30389bda76d59eafeda8b532/a402a024-9e6b-468c-8a19-7ed15844f46f.png`。

---

## 4. 未验证的真机动态边界
1. 物理 iPhone（`00008160-001939111420000A`）上的直接覆盖安装与真机触控交互：因 `mcp_synara_device_list` / `mcp_synara_device_install` 底层仅支持模拟器 `simctl`（报错 `Invalid device: 00008160-001939111420000A`），尚未通过 `device_*` 写入物理真机；但真机签名包 `iosAppExperimentalGPL.app`（SHA-256 `f6770198...`）已在本地构建并完成严格签名校验。
2. 真实云端 Gateway 多子智能体并发长流式输出与 50+ 轮真实联网检索在物理真机帧率/热节流下的表现，仍需在真实云端会话中动态观察。
