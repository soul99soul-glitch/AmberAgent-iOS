# AmberAgent iOS UI 分区拆分 review（只读，2026-10-18）

范围：CouncilChatRuntimeView、PlaceholderViews、WebMountView、RuntimeEnvironmentView、BoardView、ProviderDetailView、MemoryToolApprovalCard、MiniAppRunnerView，以及 AppShell / Settings 已有组织。未改源码、未运行构建/测试；行号来自当前工作树。已读 iosApp/AGENTS.md。

## 判断与顺序

8 个超 1500 行文件不是同一种问题。PlaceholderViews、MemoryToolApprovalCard、BoardView 主要把已经独立的类型挤在同一个文件，适合先完整搬迁类型；CouncilChatRuntimeView 同时混合 UI、Observable owner、DTO、归档；RuntimeEnvironmentView / ProviderDetailView 主 View 自身已超 1500，必须提取明确状态责任；WebMountSiteView 和 MiniAppRunnerView 主类型虽仍低于 1500，但有生命周期/权限/回调敏感路径，不能靠任意片段 extension 达标。

推荐单模块内先按 feature 目录组织，保留现有 @Observable / @StateObject / @Bindable。目录不是 SPM 模块；当前 UI 普遍消费 Shared、SettingsStore、RouterPath、ChatViewModel，不应这一轮强造多个编译 target。已有 NovelCreation / PhoneControl / DeepReadCore / HotlistCore 可延续，避免另造重复 feature 树。

第一波：PlaceholderViews + 审批卡 + Board 已有独立类型；第二波：WebMount / MiniApp / Council 的独立 types 与 stores；第三波：Runtime / Provider 的状态 owner 提取；Council 主 owner 若完整搬出约 1457 行，可先达到硬上限，再随明确责任提取留出空间。文件建议目标 300–1100 行，1500 是硬门禁，不能每个拆成 1499。

## 1. CouncilChatRuntimeView.swift，4414 行

证据：View 76–906；消息行与详情 908–1191；成员/配置 sheet 1214–1765；@Observable CouncilChatViewModel 1793–3249；展示与消息模型 3251–3855；DTO / current transcript / archive persistence 3857–4229；history sheet 4288–4414。是多层混装，也确有一个约 1457 行状态 owner。

拟拆到 Council/：

- CouncilChatRuntimeView.swift：现有根 View + 跟随滚动状态/输入附件宿主，约 830 行；不要第一步搬走 ScrollPosition、scrollDriver、测量 task。
- CouncilTranscriptViews.swift：TranscriptMessagesView / MessageRow / detail / scroll geometry policy，约 400 行。
- CouncilRoomSheets.swift：members / room settings（以后按变化原因再拆，不强制每个百行一个文件），约 600 行。
- CouncilHistorySheet.swift：历史 UI + 空态，约 130 行。
- CouncilChatViewModel.swift：先完整保留 app 级 runtime owner，约 1460 行；必要的第二步可提取纯详情/展示投影与配置解析以降至 1200 左右，不分散 discussionTask、activeDiscussionID、activeDurableRunID。
- CouncilChatModels.swift / CouncilDisplayCopy.swift：消息、参与者、模式、展示文案，约 600 行+180 行。
- CouncilTranscriptPersistence.swift：Codable DTO、UserDefaults transcript，约 160 行。
- CouncilRoomArchiveStore.swift：archive store 与 write generation，约 230 行。

状态约束：AppShell:23 和 85–92 创建 CouncilChatViewModel；View:84 只持有该实例。离页 runtimeDidDisappear:1930 保存检查点，不取消 app owner；resetRoom:3068 与 stopAndCheckpointActiveDiscussion:3161 要先 durable/checkpoint 再释放 lease；deferred write generation 在 4201，不能拆出另一个独立写入时序。材料 preparation generation:1851 / attachmentRoomGeneration:1852 必须仍绑定当前房间。

Swift 访问范围：attachmentRoomGeneration 当前为 fileprivate private(set)，UI 在 805–886 取 token，移开后需要受控 internal 只读 token 入口；不能把整个 model private 状态批量 internal。Color/String private extensions（4243/4273）需随实际消费者移动或改为域内命名 helper，避免全模块泛化。

已有测试：IOSCouncilRoomArchiveStoreTests 覆盖 deferred coalesce、同步保存压过 stale deferred、load/replay/interruption（158、182、219、321 等）；IOSCouncilRunnerMechanicsTests 覆盖 FIFO/pacing/follow、durable ownership races 等；CouncilSourceMaterialsTests 覆盖材料。触碰滚动类型需执行 iosApp/AGENTS.md 指定三套 scroll 回归。source-string wiring tests 在 IOSCouncilRunnerMechanicsTests:12/435/2364、CouncilSourceMaterialsTests:124、IOSSettingsWiringTests:164/306/836、PerformanceHygieneTests:80 均引用旧文件，必须按职责改路径且保留语义断言。缺口：搬迁后 View 真实切换/回放/附件取消/后台返回的组合验收，尤其 sheet dismiss 与 AppShell owner 存活。

## 2. PlaceholderViews.swift，3519 行

证据：这不是占位文件。Home 图标/候选投影 38–687；Home 样式 689–1003；生产 ConversationsView 1005–1747；ConversationSummaryRow 与动画 1752–2233；Search 2235–2648；SettingsHome 2650–2844；Workspace 2846–3449；真正 placeholder 3451 以后。命名和目录妨碍定位，耦合主要来自文件聚集。

拟拆：Home/ConversationsView.swift（~750）；Home/HomeContinueCardModel.swift（refs+resolve ~400）；Home/HomeConversationIcon.swift（~260）；Home/ConversationSummaryRow.swift（row+avatar动画 ~480）；Home/HomeControls.swift（~350）；Search/SearchView.swift（含专用 search rows ~415）；Settings/SettingsHomeView.swift（~195）；Workspace/WorkspaceView.swift（~240）；Workspace/WorkspaceDetailViews.swift（~570）；SharedUI/CapabilityGateLockedView.swift 与确实 placeholder 文件（~70）。HomeAccountAvatar 可归 Home/AccountAvatar 或现有共用组件位置；SettingsHome 同时使用时只暴露该类型，无需抽一个通用组件框架。

状态不动：ConversationsView 的 Namespace、FocusState、delayed searchFocusTask、conversationNavigationTask 保留根宿主（1018–1040）；HomeContinueCardModel 继续是跨 feature 输入的值投影，不能把各 feature 的持久化 owner 复制进 Home。Search query/cancel 仍由 SearchView:2241–2244 / 2440 负责。Workspace 是 @Bindable IOSWorkspaceStore:2847，UI 仅持有 sheet 与选择状态。

identity 风险：ConversationSummaryRow 的 Equatable 1793 只比较显示值，闭包刻意不比较，注释 1779–1792 清楚约束只捕获稳定 owner、summary.id、参与相等比较的 title。抽视图时保留 ForEach id（1490）、equatable（1520）、namespace、focus 和主视图 task 的生命周期，不创建新 owner 或 AnyView。私有样式只在使用它的 feature 里放宽访问。

已有测试：HomeDesignContractTests 的图标缓存、row equality、跨 feature continue priority 与动画；IOSConversationStoreTests/分支测试为 store 提供回归，但不是搜索键盘/导航实测；IOSAmberShellWorkspaceStoreTests 为 store 侧依据。源路径依赖：HomeDesignContractTests:655/741、IOSSettingsWiringTests:75、AmberThemePackTests:536。缺口：首页搜索展开/收起焦点、异步切会话中再点击、返回首页、workspace sheet import/error 的 UI 行为。

## 3. WebMountView.swift，3405 行

证据：route/handoff/store/DeepRead adapter 5–217；AgentBrowserTask cards 262–626；站点列表 628–957；WebMountSiteView 959–2320（约 1362 行）；site memory sheet 2322–2565；report sheet 2567–2853；WK adapter / presentation host / dialogs 2855–3064；controls 3066–3405。

拟拆到 WebMount/：WebMountRoutes.swift（~65）；IOSWebMountContentHandoff.swift（adapter/DTO/stores ~150）；AgentBrowserTaskCard.swift（~365）；WebMountView.swift（~330）；WebMountSiteView.swift（~1365，后可提取 inspector 纯 UI 留余量）；WebMountSiteMemorySheet.swift（~245）；WebMountRunReportSheet.swift（~290）；WebMountBrowserPresentation.swift（WK host/presentation lease/dialog ~215）；WebMountControls.swift（~340）。跨到 Chat 的 handoff / DeepRead adapter 名称保留，依赖不搬回 renderer。

状态约束：controller/registry/session store 现有 owner 不动；SiteView 的 @ObservedObject runtime:966 必须保持原实例，root/inspector/popup hostIDs:989–991、popupPresentationQueued / selectedPopupIdentifier / lastPresentedSheet:983–985 归同一个 SiteView。不要把 popup 切成拥有自己 runtime 的屏幕。WebMountRuntimeWebView:2855 返回已经存在的 WKWebView；popup .id(ObjectIdentifier(popup)):1612 和 runtime browserPresentationHost:1259/2881 共同决定挂载与 JS dialog 是否可呈现。sheet onDismiss:1718 取消 popup dialog 后排队再呈现，拆 view 时生命周期语义不能变。

已有测试：IOSWebMountRuntimeEvidenceTests:108 popup/opener/cookie，142 dialogs，203 control handoff，274 stale dialog，295 last host leave，424 toolbar，495 report；IOSWebMountAutomationContractTests 行为契约；IOSWebMountSiteMemoryLayoutTests 特别覆盖 Chat 内短容器+attachments+artifact；IOSLocalToolExecutorTests:2884 等 route/watch 局部。源路径依赖 AmberThemePackTests:975/1019。缺口：inspect→popup→dismiss 的 SwiftUI presentation queue 组合 UI 自动覆盖，runtime 测试并不完全等同视图身份回归。

## 4. BoardView.swift，2499 行

证据：BoardView 29–853；少量状态/列表 row 855–1049；独立 IOSDeepReadTaskDetailView 1051–1870（~820）；navigation policy + template/editorial WK hosts 1872–2145；topic action sheet / skeleton / related rows 2179–2499。主要多屏幕和 renderer 混装，单个主 View 不需要新 ViewModel 才能降行数。

拟拆：Board/BoardView.swift（~830）；Board/BoardHistoryRows.swift（~200）；Board/BoardTopicActions.swift（~80）；DeepRead/IOSDeepReadTaskDetailView.swift（~820）；DeepRead/IOSDeepReadWebViews.swift（~275）；DeepRead/DeepReadReaderComponents.swift（skeleton/related row ~245）；Board/BoardCapabilityViews.swift（~35）。继续沿用 DeepReadCore 存储/渲染责任，不把 SwiftUI 放进 core；若根方案采用 DeepRead/UI 同样可行，但不要并存 DeepRead 与 DeepReadFeature 两套目录。

状态：Board 本地 creation draft/collection snapshot 与 deepReadStore/hotListStore 继续独立；reader 的 decodedJSON/closeReading/templateArticle、editorialHeight、originalChoice 留在 detail view（1051–1080）。WK Coordinator:2027 缓存 loadedHTML、lastHeight、持有 onHeight Binding；必须整体搬，保留 JS height observer、禁内滚动、initial-document policy，不能因拆 UIViewRepresentable 重建 WKWebView 或更改 font origin。文件头 BoardSignal @retroactive @unchecked Sendable 需只保留一份。

已有测试：IOSBoardPersistenceTests:455+ navigation policy 与 editorial height；IOSDeepReadPipelineTests 为 generation/cancel/stale/partial/workspace-sync 提供行为证据；IOSDeepReadTemplateStoreTests / StructuredRendererTests。缺口：reader 长文高度、脚注展开、字号/字体、来源 link、分享 PDF/Markdown 的 UI /系统交互需针对抽取验收；pipeline 绿不证明 WK layout。不额外变更 pipeline。

## 5. MemoryToolApprovalCard.swift，2154 行

证据：ToolOutcomeUnknown 3–86；Memory 88–295；WebMount 297–651；Search 653–748；Workspace 750–839；Mcp 841–1206；ThemeTryOnBar 1208–1257；Council 1259–1363；iSH 1365–1644；ChatAskUser 1646–1790；Recipe 1805–2154。高度适合类型整体搬迁，不是一个 2154 行 God View。

拟拆到 Chat/Approvals/：MemoryToolApprovalCard.swift（~210）；WebMountToolApprovalCard.swift（~355，含 PreferenceKey 与详情）；SearchToolApprovalCard.swift（~100）；WorkspaceToolApprovalCard.swift（~90）；McpToolApprovalCard.swift（~365）；CouncilToolApprovalCard.swift（~105）；IshHandoffToolApprovalCard.swift（~280）；RecipeToolApprovalCard.swift（~350）；ToolOutcomeUnknownCard.swift（~85）；ChatAskUserCard.swift（~145，若统一叫 Chat/Questions 亦可）；AmberThemeTryOnBar.swift（~50，按既有 Theme 责任目录）；ApprovalHitTarget.swift（约10行共享 UI 行为，可纳入已有共享审批组件文件而非创造微模块）。

状态：approval request + onApprove/onDeny 输入保留，审批续跑状态在原 runtime/Chat owner；这些卡只拥有展开状态、选项、输入文字。WebMount preference key 297 和 measured decision row 313/340 被 Chat 父层消费，不能换 key 或缩短 max-height 约束。Mcp/Recipe 不应为了统一卡片外观抽一个大 switch 或统一 AnyView 工厂。

已有测试：IOSWebMountSiteMemoryLayoutTests（包含生产 Chat 容器 184），IOSJevApprovalChipsVisualEvidenceTests；IOSThemePackToolTests:623 直接读此文件验证 TryOn wiring，需迁移；IOSJevApprovalTriageTests、对应 ChatTool/runtime 执行测试提供业务 owner 证据。缺口：拆后各卡 approve/deny/ask-user 回调次数与 sheet/task 关闭、长命令、长 recipe 大字号/VoiceOver 验收。低风险整体搬迁不必机械加每卡一个新测试，但需跑现有相关 UI evidence。

## 6. MiniAppRunnerView.swift，1853 行

证据：根 view 12–1280（~1269）；AI recovery 1282–1309；web identity/access identity 1317–1327；系统桥 1329–1539（location/motion）；prompt DTO 与 confirmation owner 1542–1828；errors 1830–1853。其中根 view 自身包含管理 UI、真实 AI provider/durable run、宿主 context/artifact/chat integration。

拟拆到 MiniApps/：MiniAppRunnerView.swift（先完整 view ~1270）；IOSMiniAppSystemBridge.swift（~215）；MiniAppHostConfirmationOwner.swift（~290，含 prompt DTO）；IOSMiniAppAIRunRecovery.swift（~30，或与 AI operation 合并）；再将当前 831–955 的 provider/durable lease 调用与 recovery 一起移到 IOSMiniAppAIGeneration.swift（~160），可使根 view ~1150。managementSheet 与 grants/versions/activity/developer 可在后续本任务中按实际闭包接口拆 MiniAppManagementSheet.swift（约450），但不能简单把全部 root state 传成巨型 context。

状态：hostConfirmationOwner/systemBridge 当前 @StateObject:37–38，必须由 runner 同一生命周期持有。root .onAppear reopen / .onDisappear close:121–129；web identity 342–346 由 htmlHash+policy+access 决定，传入 `.id` 不变，不能因管理sheet打开重载 WKWebView。permission owner:1710 持有 continuation、同权限合并 task、presentation waiters、lifecycle generation；整类搬迁。AI provider/lease 拆出后仍按 runId 结束 durable state，不把页面关闭自动等同取消所有后台工作。Host handler 978–1040 能改 chat input / workspace artifact，仍经过原 confirmation，不能让管理子视图绕过 approval。

已有测试：IOSMiniAppBridgeRuntimeTests:604/635/664/700/842 等覆盖确认 close/queue/coalesce/revocation 身份；IOSMiniAppSystemSDKTests:149 late reply after document changes；IOSMiniAppVisualEvidenceTests:10 first-run reveal / 75 compact grants / 118 settings；Repository / ThemeBridge / DeviceCapabilitiesTests。源路径依赖 IOSSettingsWiringTests:61/168、AmberThemePackTests:908/977。缺口：具体 runner AI owner 的后台 expiration/terminal durable 路径和 sheet打开关闭不重建WebView 的端到端验收，模拟器不能证明定位/传感器真机权限。

## 7. RuntimeEnvironmentView.swift，2632 行

证据：根视图持有 SSH 草稿、敏感凭证、探测任务、运行任务、sheet 和 PTY 状态（12–35）；UI 到 864；命令执行、轮询、任务持久化、审批记录在 1109–1338；SSH 编辑/信任/密钥链事务在 1340–1647；1652 起约 980 行为独立卡片/行/详情视图。主 View 自身 5–1650 超过 1500，仅移走 components 不足以达标。

拟拆到 Runtime/：RuntimeEnvironmentView.swift（页面编排/概览/sheet，~400）；SSHConnectionEditorView.swift（SSH 表单、密钥管理、fingerprint，~400）；SSHConnectionEditorModel.swift（SSH 草稿、验证与提交事务，~400）；RuntimeDiagnosticsView.swift / RuntimeDiagnosticsModel.swift（smoke、命令、任务结果，每个~200–400）；RuntimeEnvironmentComponents.swift（纯 UI 行/卡片，~800）；TerminalTaskDetailView.swift（~120）。状态 owner 使用当前技术栈；不存在迁移整套 observation 的理由。

关键风险：密码、私钥、host/port/auth、probe snapshot、verification task、status 一起归 SSH editor，子 View 用 Binding/命令，不复制草稿。现有探测先保存 candidate 与 persisted snapshot（1421–1449）；确认信任只写内存 candidate（1462–1488）；认证成功且草稿和已持久化 profile 都没变，才 upsert（1493–1537）。这些是正确防线，必须整体保留。host/port/username/auth 的 Binding 会取消探测并使信任失效（1340–1383）；后台、外层 sheet 关闭、离页清敏感草稿（122–131、1618–1626），不能挂到每个子视图 onDisappear。命令 job 生命周期与 SSH 编辑不同，runRemoteCommand 同时写 runtime/advanced tasks/permission audit（1160–1316），不能由于新子视图销毁就取消实际 job。

已有测试：IOSSSHRuntimeTests 有绑定/endpoint变更清信任/晚完成/timeout/cancel/job状态；IOSSSHBackendIntegrationTests 有 loopback SSH 成功、host mismatch、认证失败；IOSSSHPrivateKeyTests 有生成/导入；IOSSettingsWiringTests:36–56、AmberThemePackTests 部分源接线。待补 owner 行为：probe取消/拒绝信任不改 profile；probe后改草稿/改 persisted profile/认证晚到都不提交；成功才提交；后台/关闭只清编辑状态。顺序是先迁出 UI，再用这些行为测试约束 editor 提取；不要先批量改访问级别。

## 8. ProviderDetailView.swift，2462 行

证据：主 view 9–1556 自身略超 1500；19–41 同时拥有配置草稿、发现任务、候选模型、连接结果、编辑器、三种登录状态；88–199 sheet 回调直接改 auth、endpoint、模型目录、默认模型和 legacy mirror；979–1154 保存/headers回滚/协议和auth切换；1156–1292 多客户端分派与任务；1294–1445 模型CRUD/default；1839以后编辑器和大量行控件。

拟拆到 Providers/：ProviderDetailView.swift（tab/alert/sheet协调，~350）；ProviderConfigurationView.swift（~500）；ProviderModelsView.swift（~150）；ProviderModelEditorSheet.swift（~210）；ProviderDetailComponents.swift（~400）；ProviderConfigurationEditor.swift（草稿与保存事务+模型CRUD，~400）；ProviderModelDiscovery.swift（候选列表/request生命周期，~180）；ProviderAuthenticationActions.swift（当前登录后的特定配置变更，~130）。不要把 identity 等同 provider名称，沿原 providerId 固定 editor/model-discovery scope。

关键风险：Discovery保留 Task + requestID 双重过期保护，并冻结开始时 provider/header（1188–1263），旧成功/旧失败都不能写 UI（1262、1277）；availableModels 是候选，只有 addFetchedModel（1294–1316）才持久化，不能抽成 fetch即保存。saveConfig 先存 headers 再存 provider，后者失败恢复旧 headers（1019–1056），配置变化清旧发现结果（1043），需一个 editor 保存入口。Grok 登录替换 endpoint、收编目录、必要时重选默认模型，退出恢复备份（113–163），Codex/Google是不同契约（88–106、167–199），迁移不能顺手统一行为。sharedSettings.revision 当前会 loadDraft（79、979–1005），须保持刷新语义，不把结构重构混成草稿策略改变。

已有测试：IOSSharedSettingsStoreProvidersWriteBackTests 覆盖凭证写失败回滚、默认模型、删除；IOSSettingsWiringTests:454–480 与 IOSCodexModelCatalogTests/AmberThemePackTests 有部分接线和截图。缺口：Discovery A→B、取消后晚成功/晚失败、auth/endpoint/header变化后的旧响应失效；候选获取不写用户配置；headers成功但provider写失败的恢复；Grok登录/退出恢复endpoint；编辑/删除当前聊天或生图模型保留原选择规则。settings层测试不等同 view/editor事务测试。

## AppShell 与 Settings 的组织建议

AppShell.swift 1369 行未超上限，但含 app composition 47–约140、startup/deeplink/navigation、AppTab:767、TabRouter:829、RouterPath:860、Route:881、SheetDestination:952、destination View extension:964 与 UINavigationController gesture delegate:1313。应放到 App/：AppShell.swift 继续唯一 app 生命周期与实例 composition owner；AppRoutes.swift 放 value routes + RouterPath/TabRouter；AppNavigationDestinations.swift 放路由展示组装；InteractivePopGesture.swift 放 UIKit interop。不能重建依赖导致 app 级 Chat/Council runtime 在导航中丢失，不能把 AppShell 构造循环塞进全局 singleton。

Settings 已有按主题拆分的文件：Appearance 724、Board 963、Council 624、DisplayFont 307、Execution 564、IOSJev 1054、Watch 523、Language 133、MacGateway 398、MiniApp 361、TTS 403。问题主要在根目录发现性与个别 detail owner，不必因为“模块化”再把所有设置统一成新 schema 框架。可把 setting UI 按对应 feature 下的 Settings/ 放置，SettingsHome 只是导航聚合，SettingsStore / IOSSharedSettingsStore 仍是配置唯一写入 owner。

## 通用迁移契约

1. 每次以一个真实 feature 类型组为搬迁单位，先保持类型/方法签名和运行行为，再做必要责任提取。保持 UI instance identity、Task cancellation、sheet item IDs、@StateObject 初始化位置与 root Environment 注入。
2. private/fileprivate 调整是逐符号审查，internal 仅用于跨文件真实调用。禁止把全类型 private 状态改 internal 后切成任意 extensions；这满足行数但保留全部耦合。
3. 现有测试有大量 `String(contentsOf: ...swift)` 旧路径/源码 contains。搬迁要明确维护这些断言定位；不能删除有效断言、全文拼接所有目录掩盖责任、或者以 wiring 测试代替行为测试。
4. 当前证据只有静态源码 review 和现有测试覆盖读取；没有宣称测试通过、构建通过、视觉/设备/provider 验收。
