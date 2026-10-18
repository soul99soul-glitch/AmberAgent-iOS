# 平台、状态与持久化拆分 review（只读）

基于 2026-10-18 当前工作区，遵守根/iosApp AGENTS；未修改产品源码，未运行构建/测试。当前 `IOSPermissionModels.swift` 有用户未提交修改，落地必须以用户最终 WIP 为基线。本组只覆盖下表 8 个生产文件；不声称已经做行为缺陷审计或全路径运行验证。

| 当前文件（iosApp/iosApp/） | 当前行数 | 判断 |
|---|---:|---|
| IOSChatBackgroundGenerationCoordinator.swift | 4949 | 最优先规划，但最后高风险落地；后台所有权、执行、恢复、落盘、composition 混合 |
| DocumentAccessStore.swift | 2500 | 最清晰的职责拆分收益；文件名无法体现内含 workspace 与 tool runtime |
| IOSPermissionModels.swift | 2093 | 主要是约 1380 行静态能力目录；模型、目录、策略 store 分离即可，不能仅凭行数称“屎山” |
| IOSContextCompactionCoordinator.swift | 2087 | 协调任务、纯算法、摘要文件存储、token 估算、测试入口混合 |
| IOSConversationStore.swift | 1999 | 有意集中的正确写入 owner；拆出纯 merge/read model，不要拆出多个写入 owner |
| IOSSharedSettingsStore.swift | 1865 | KMP snapshot 的单一提交点合理，按设置域分文件，保留凭据事务 |
| IOSGenerativeWidgetParser.swift | 1652 | 已有独立类型可直接移出；parser 之外包含 HTML runtime 资源安全策略 |
| IOSSystemPermissionCoordinator.swift | 1553 | 每个 SDK 已有 extension 段，按权限领域移出 adapter，保留统一 preflight 与 results |

## 6 个有证据的架构发现

1. **后台 coordinator 同时是 composition root、全局运行 owner、恢复器和持久化/展示收尾器。** `IOSChatBackgroundGenerationCoordinator.swift:690` 开始维护多组 activeJobs/runStates/tasks/recovery flags；`:834` 创建 SettingsStore、ConversationStore、permission/tool executor 及 ChatViewModel 对象图；`:1641` 恢复 server Responses；`:2326` 是约 700 行 `handle`；`:3995` 编码 KMP payload 并写盘；`:4813` 做释放 owner、通知和 mailbox 恢复。影响是修改一个终态必须理解跨越数千行的执行与释放顺序。真实接缝已经存在于 handoff、runtime job、run state、payload bridge、durable run store，优先沿这些拆，不新增一个“万能状态机”。
2. **DocumentAccessStore 的文件边界严重偏离业务边界。** `DocumentAccessStore.swift:196` 是独立 Observable workspace store；`:444` 路由 workspace tools；`:491`–`:883` 是 shell 文件操作、安全路径和回滚；`:1529` 才进入选中文件授权 store；`:1735` 是后台文件解析；`:2378` 另有 IOSToolRuntime。修改 picker 授权、工作区写事务、ZIP/XML 解析三个变化原因完全不同。应拆为 Documents、Workspace、Permissions/SelectedFileRuntime 三域。当前是 **内存一次授权（10 分钟/1 次）+ 配对 security-scoped access**，未发现持久化 bookmark；此次不能顺手改成永久书签授权。
3. **权限静态目录、策略选择和系统授权状态是三种不同事实，但文件命名掩盖了区别。** `IOSPermissionModels.swift:180` 目录；`:1770` 不可变 execution policy snapshot；`:1851` 是 Observable IOSPermissionStore、UserDefaults 与 approval audit；`IOSSystemPermissionCoordinator.swift:134` 独占系统 results，`:184` refresh / `:208` request / `:317` preflight。合理目标是目录提供不可变 metadata、permission store 只拥有 agent policy/approval history、system coordinator 只拥有 OS 查询结果与请求生命期；不能合并成一份“授权状态”，也不能从静态 supported 推断 OS authorized。
4. **ConversationStore 的体量一部分来自必须集中维护的并发写入契约，按功能随意拆 store 会破坏已有保证。** `IOSConversationStore.swift:208`–`:231` 集中 storage、deleted IDs、writeSequences、importEpoch、in-flight writes；`:687` 的后台 merge 每轮读取 write baseline 再提交；`:1800`–`:1916` 负责 import drain、stale-write guard、并发写后 reload。拆分时把 merge/branch/search 算法移开，所有 mutation 仍回同一个 persist gate；不让 BackgroundStore、BranchStore、ImportStore 各持一份 JsonConversationStorage/currentConversation。
5. **SharedSettings 的核心事务值得保留，真正的问题是领域命令与兼容投影全挤在同一文件。** `IOSSharedSettingsStore.swift:114` 持有 KMP Settings 与 revision；`:276`–`:319` 先完成 Keychain 写入（失败回滚）再写脱敏 JSON、提交 snapshot/revision；`:679` provider mutation；`:1101` 将当前模型投影到 legacy SettingsStore。按 provider/search/TTS/agent domains 分文件时，共享同一 snapshot/restoreSnapshot，不能每域复制 Settings，也不能让新 adapter 直接写 UserDefaults/Keychain 绕开事务。已有 `IOSCredentialSideTable.swift`(97)、`IOSCredentialRedactor.swift`(388)、`IOSSettingsSnapshotSource.swift`(10) 可复用。
6. **纯变换与有副作用的 owner 有可验证边界，可以先做低风险真实模块化。** `IOSContextCompactionCoordinator.swift:71` 保有 per-conversation tasks；`:631` 独立 compact file store；`:787` 之后的 plan/fit/edit/normalize 大部分是纯算法。`IOSGenerativeWidgetParser.swift:169` parser、`:965` chart validator、`:1127` HTML validator/runtime URL policy 本已是独立类型。将这些按输入/输出界面拆出，比把巨类切成无语义的 Part1/Part2 更容易测试，也能首批验证工程注册与跨文件访问控制是否正确。

以上是确定的职责与依赖发现，不将尚未复现的潜在 bug 混入重构结论。

## 每文件建议落点与单一 owner

以下目录相对 `iosApp/iosApp/`。行数是落地预算，不是已经拆完的实测值；所有目标 ≤1500，常规主体优先 ≤1200 留增长空间。

### A. IOSGenerativeWidgetParser.swift → GenerativeUI/（低风险先行）

- `IOSGenerativeWidgetModels.swift`：segment、widget、action、rendering protocol（约 60）。
- `IOSGenerativeWidgetPayloadDetector.swift`：增量探测、chunk checkpoint、final reconciliation（约 110）。
- `IOSGenerativeWidgetParser.swift`：fence/partial JSON/完整与流式 widget 组装（约 850）。
- `IOSVChartSpecValidator.swift`：结构化 chart/slides 归一化及边界限制（约 165）。
- `IOSGuizangHtmlDeckValidator.swift`：full_html/legacy alias、结构校验、runtime assets、远端资源重写和 CSP（约 480）；若后续增长再拆资源策略，首轮无需多一层 abstraction。
- 底部 String/Dictionary helpers 根据实际消费者放到 parser support 或具体类型，避免新的全局 Utils 文件。
- owner：parser/validators 无运行状态；仅 PayloadDetector 值类型按每条消息拥有增量状态。复用既有 `IOSGenerativeWidgetRenderer.swift`、`IOSGenerativeWidgetSanitizer.swift`，不要重造 renderer/sanitizer。
- 验证：IOSGenerativeWidgetParserTests、IOSGenerativeWidgetSanitizerTests、IOSGenerativeWidgetPayloadDetectorTests；重点 chunk 边界 ID 稳定、同长改写探测、SVG 与 HTML route 区分、远端资源 allowlist/CSP。若移动触及渲染调用，依 iosApp/AGENTS 跑 timeline 三组测试；视觉仍需模拟器/真机证据。

### B. IOSPermissionModels.swift → Platform/Permissions/（低风险，先冻结当前 WIP）

- `IOSPermissionModels.swift`：capability/status/risk/domain/requestKind/gate/policy、approval record（约 250）。
- `IOSCapabilityRegistry.swift`：有序聚合、lookup、composite action requirements、gate factory（约 220）。
- `IOSCapabilityCatalog+AgentAndFiles.swift`、`+PersonalDataAndSensors.swift`、`+SystemAndExtensions.swift`：按领域装载目录，每个约 400–650；明确保持原数组排序和全部 IDs/aliases，不改产品可见性。
- `IOSExecutionPolicySnapshot.swift`：编码/digest、withoutAutoApprove（约 100）。
- `IOSPermissionStore.swift`：policy normalization、迁移、持久化、approval log 与 task projection（约 250）。
- owner：IOSPermissionStore 唯一拥有 mutable policy/approval history；execution snapshot 仍是 run 创建时的不可变副本；registry 全静态。目录 factory/gates 仅开放需要的 module-internal 接口，不能为了跨文件把所有 private 改 public。
- 验证：IOSPermissionStoreTests、IOSPermissionsStatusSnapshotTests；比较 capability IDs/order/modelToolNames/blockedToolNames/default policies 的前后快照，保留 unsupported build 不擦用户旧策略、run-scoped 旧值迁移、high-risk gate 行为。

### C. IOSSystemPermissionCoordinator.swift → Platform/Permissions/System/（低中风险）

- `IOSSystemPermissionModels.swift`（约 45）。
- `IOSSystemPermissionCoordinator.swift`：results、request/refresh dispatch、统一 preflight、设备/Info.plist/entitlement/extension 判断（约 440）。
- `IOSSystemPermissionCoordinator+Media.swift`：camera/mic/speech/personal voice/photos/media/image capture（约 400）。
- `IOSSystemPermissionCoordinator+PersonalData.swift`：location/contacts/calendar/health/motion/workout 及其 delegate helper（约 340）。
- `IOSSystemPermissionCoordinator+System.swift`：notification/live activity/tracking/focus/passkeys/FaceID/bluetooth/network/finance/alarm/passKit/videoSubscriber（约 450）。如领域稍增可以进一步分 Identity 与 Connectivity，而非按固定行数截断。
- owner：coordinator 唯一拥有 results 与 requester/probe 生命周期；adapter 函数返回 IOSSystemPermissionResult。保持 `@MainActor`、`canImport`/availability guards 跟随实现。不能迁移成同步 UI body 查询，不能新增权限/entitlements。
- 验证：IOSSystemPermissionCoordinatorTests、IOSPermissionsStatusSnapshotTests；未授权/拒绝/受限/limited、缺声明与 entitlement、refresh 不误弹窗；真实系统 prompt/Settings 往返单列真机验收。

### D. DocumentAccessStore.swift → Platform/Documents/ + Workspace/（高收益、中高风险）

- `Documents/SelectedDocumentModels.swift`：grant/result/errors（约 160）。
- `Documents/DocumentAccessStore.swift`：picked grant、10min/1-use、isReading、latest grant ID 防旧结果覆盖（约 210）。
- `Documents/DocumentPreviewReader.swift`：唯一入口，security scoped access 的 begin/defer-stop、尺寸/类型选择、text/PDF/office parser 与 XML helpers（约 450）。
- `Documents/IOSDocumentZipReader.swift`：ZIP entry/read helpers（约 130）。
- `Workspace/IOSWorkspaceModels.swift`（约 140）。
- `Workspace/IOSWorkspaceStore.swift`：files/artifacts/index/revision、import/reparse、唯一 payload/index commit/rollback（约 650）。
- `Workspace/IOSWorkspaceStore+Tools.swift`：workspace file tool schema/JSON I/O、read/edit/list/search/move（约 480）；只经 Store 事务接口提交。
- `Workspace/IOSWorkspaceStore+Shell.swift`：shell operations 与路径/symlink validation（约 400）；同样回 Store 事务接口。
- `Permissions/IOSSelectedFileToolRuntime.swift`：IOSToolInvocationRequest、IOSPlatformGateDecision、IOSToolExecutionResult、IOSToolRuntime（约 180）。
- owner：DocumentAccessStore 唯一 transient picked grant；WorkspaceStore 唯一 workspace index/revision 与 commit/rollback；PreviewReader 无授权持久化。Tool/Shell 不缓存另一个 files 数组，也不独立保存 workspace.json。
- 顺序：models/ZIP/reader → selected runtime → workspace owner 独立文件 → tools/shell；在共享 commit 接口定清之前不要让不同 worker 同时改 workspace mutation。
- 验证：DocumentAccessStoreTests；已有失败注入覆盖 index 写失败回滚、并发 reparse/delete/move/edit、shell 新旧写竞争；保留中文/GB18030/UTF16/PDF/DOCX/PPTX、read-time 尺寸检查、grant 过期/替换/一次消费、安全路径与 symlink 拒绝。文件 picker / 外部文件 provider 的 scoped access 需设备复验，构建不能代替。

### E. IOSContextCompactionCoordinator.swift → Chat/Context/（中风险）

- `IOSContextCompactionModels.swift`：compact/policy/plan/event、run event router（约 90）。
- `IOSContextCompactionCoordinator.swift`：prepare/finalize 流程、单 conversation task owner、摘要 provider 选择与 cancellation/failure suppression（约 580）。
- `IOSConversationCompactStore.swift`：原格式存储、cache、corrupt 文件保护、删除（约 65）。
- `IOSContextCompactionPlanner.swift`：estimate occupancy、plan/force plan、ancestry/covered IDs 校验（约 430）。
- `IOSPreparedContextEditor.swift`：请求级裁剪、tool output edit/fit、可见 truncation notice、最终 budget assert（约 450）。
- `IOSCompactSummaryCodec.swift`：prompt/template、JSON summary normalization、injection/timeline text（约 330）。
- `ContextTokenEstimateMemo.swift`（约 90）；测试入口仅 `#if DEBUG` 下迁到命名清楚的 support 文件（约 170）或改测生产内聚类型；不把关键行为测试删掉。
- owner：coordinator 唯一 activeCompactionTasks/failedCompactionHistoryCount；store 唯一 compact cache/persistence；planner/editor/codec 纯函数。保留 request-only 与原始 storage message 区别，不能将裁剪后的 upload 永久替换历史。
- 验证：IOSContextCompactionCoordinatorTests、相关 token/context 测试；摘要阈值、压缩输入模型窗口、先前 compact ancestry、巨型 tool output、cancel 后不重建已删 compact、失败不每轮重试、timeline boundary 恢复、runId 事件路由。若仅 Swift 组织变更不要求伪造 KMP 改动；若实际动 shared bridge/runtime，补对应 Gradle gate。

### F. IOSConversationStore.swift → Conversations/（高风险，保留单一 writer）

- `IOSConversationModels.swift`：error、search result、baseline（约 110）。
- `IOSConversationStore.swift`：Observable 当前会话/修订、bootstrap/CRUD、storage 与唯一 persist/writeSequences/importEpoch/drain owner（约 1000–1200）。
- `IOSConversationStore+Import.swift`：批量导入协调、thread edge backup（约 100）；依然在同一 store 的 gate 内执行。
- `IOSConversationStore+Branching.swift`：variant/select/append/delete/truncate（约 280）；消息变换可提为纯 helper，提交统一回 store。
- `IOSConversationMerge.swift`：background checkpoint/suffix/tool-output/IntelligentUI terminal merge 纯策略（约 250–350），save/retry/notification 留 store。
- `IOSConversationSearchProjection.swift`：search/session/board/read-only export projection（约 200–250）。
- owner：currentConversation、summaries、deleted IDs、write sequences、import epoch 不变；既有 IOSConversationArtifactStore、IOSConversationRecapStore、IOSIntelligentUIStateStore 继续各自拥有其 sidecar，不能新造统一大仓库吞回这些小 owner。
- 顺序：models + pure merge → read projections → branching/import 文件组织；最后才评估是否需更窄 read protocol；不先拆成多个 repository。
- 验证：IOSConversationStoreTests、IOSConversationStoreBranchingTests、IOSBackgroundCompletionMergeTests；重点 title/pin/metadata、后台新消息与前台新分支合并、删除墓碑、导入 drain/stale snapshot、revision 与 switchRevision 区分、多会话后台通知不覆盖。若触碰 KMP JsonConversationStorage，补 `core/conversation-storage/src/jvmTest/.../JsonConversationStorageTest.kt` 对应 Gradle 测试。

### G. IOSSharedSettingsStore.swift → Settings/（中高风险）

- `IOSSharedSettingsStore.swift`：唯一 Settings snapshot/revision、init/migrations、hydrate、credential transaction/restoreSnapshot（约 400）。
- `IOSSharedSettingsStore+Providers.swift`：provider config/auth mode/model catalog/current model resolution 与 legacy projection（约 500–600）。
- `IOSSharedSettingsStore+Services.swift`：search/TTS mutation 和 legacy mirrored collection（约 250）。
- `IOSSharedSettingsStore+Agent.swift`：memory/council/subagent/skills/prompt injection/lorebook/miniapp/board mutations（约 450）。
- `IOSSharedSettingsStore+LocalFeatures.swift`：Jev、remote sync status、capability compatibility fields（约 230）。
- `IOSSettingsPatchModels.swift`：MiniApp/TodayBoard patches、sync status、capability gate models（约 250）。
- owner：snapshot、credentials 提交顺序、revision 只有一个 store；domain extensions 通过 restoreSnapshot；重构阶段保留现有 UserDefaults keys/JSON、provider UUID 与 Keychain side-table references、legacy SettingsStore 投影，不擅自删兼容数据。
- 验证：IOSSharedSettingsStoreProvidersWriteBackTests、CouncilSeatTests、SkillWriteBackTests、SubAgentOverrideTests、IOSSettingsWiringTests；确保 UI 保存 →重启 hydration →provider/model/tool runtime 消费保持相同，凭据失败不提交、回滚正确、删除 provider/model 不复活；有 KMP mutation/bridge 改动再跑对应 Gradle 测试。

### H. IOSChatBackgroundGenerationCoordinator.swift → Chat/Background/ + Chat/Composition/（最后集中做，高风险）

建议 9–11 个职责文件，预算全部 ≤1200，先沿既有类型迁出再缩 owner。大致：

- `IOSChatBackgroundModels.swift`：handoff/mode/runtime job/dependencies/events（约 230）。
- `IOSChatBackgroundRunState.swift`：terminal claim/finalize/system completion gate 与 snapshot boxes（约 360）。这是既有 run 级同步边界，不另起竞争的 terminal owner。
- `IOSChatHeadlessComposition.swift`（Chat/Composition/）：headless 对象图与建造、AppShell 复用入口（约 170–220）；提取时与负责 AppShell 的人协调，不复制第二套 composition graph。
- `IOSChatBackgroundProvider.swift`：provider adapter/upload preparer（约 110–150），继续调用现有 KMP provider。
- `IOSChatBackgroundCheckpointStore.swift`：requestId map、payload 文件、KMP payload encode/decode、rehydration 参数校验（约 400–500）；沿用 IosChatBackgroundPayloadJsonBridge，不改 schema。
- `IOSChatBackgroundExecutor.swift`：原 handle 的一次 job 执行、tool loop callbacks、progress 和 miniapp result 接入（约 850–1000）。
- `IOSChatDurableResponseResumer.swift`：server responseId/cursor transport 与 accumulator/completion（约 650–850）。
- `IOSChatBackgroundRecovery.swift`：ordinary same-process resume、stale sweep、ledger reconciliation、outcome-unknown gate（约 650–850）。
- `IOSChatBackgroundTerminalWriter.swift`：成功/partial/truncated/error/cancel/expiration terminal 的 conversation+run ledger 落盘与 UI presentation（约 850–1100）。
- `IOSChatBackgroundGenerationCoordinator.swift`：App 级 entrypoints、registry、matching runId/requestId 所有权、start/cancel/release/finish、依赖接线（约 650–900）。
- mailbox/presentation pure helpers 若导致上述超限，再分别放命名明确 helper（各约 150–250）；不能为了达标做 30 个转发 wrapper。

owner：coordinator 唯一掌握 active registry 和 run 生命周期；RunState 唯一决定终态占有；executor/resumer 只回报带 runId/requestId 的事件；terminal writer 只为被接受的终态提交。释放 owner、任务完成、payload 清理、LiveActivity end/mailbox 后续任务顺序保持原契约。避免 coordinator 与 resumer 各存另一套 activeJobs；避免 delegate 反向强持 coordinator 形成新 retain cycle。

顺序：models/runState/provider → checkpoint codec/存储 → headless composition →纯恢复策略 → executor/resumer → terminal writer/owner 瘦身。每步可构建、保留 API 转接的短期过渡，终态 writer 与 coordinator 收尾由同一实现者串行整合。

验证：IOSChatBackgroundExecutionTests、IOSBackgroundCompletionMergeTests、IOSChatBackgroundSuspensionTests、IOSBackgroundLifecycleLogTests、BackgroundGenerationKeepAliveTests 与 durable response/ledger 现有相关测试；覆盖 success/partial/error/cancel/expiration/retry/stale、完成与超时竞争、旧 run 回调不结束新 run、后台工具 unresolved side effect 不重放、持久化失败不错误宣告完成、cold response 恢复/普通流不虚假宣称跨进程可恢复、headless Watch 图被 AppShell 原样接管。长后台/Live Activity/system adoption/真实 provider resume 必须保留设备+provider 验收，不用单测替代。

## 推荐集成依赖与范围边界

先 A/B/C（不可变类型与 SDK adapters）→ D/E（workspace/compaction 独立 owner）→ F/G（shared state owner）→ H（依赖前述状态层稳定后做）。A/B 可以并行；D 与 E 可以并行；F/G 可以并行但 H 不与 F 的 persist 和 G 的 hydration 同时改。单个大文件同一批只有一个实现 owner。

这是 iOS target 内真实职责拆分与目录整理计划；目前仍依赖本仓 Gradle 生成 Shared.framework，不能把这一轮计划写成“已独立 Amber Core/SPM”。独立 Swift Package/target 仅在边界已经稳定、真实有多个消费者且依赖/构建收益明确后另立决策，不作为压行数前提。

本组没有执行测试，所列是已确认存在的可复用 gate 与落地验收要求。代码路径与行数均来自当前工作区，不依赖旧 memory 事实。
