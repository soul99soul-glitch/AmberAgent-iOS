# NovelCreation 只读架构审查与拆分建议

本报告只审 `/Users/arquiel/Downloads/AI/amberagent-ios/iosApp/iosApp/NovelCreation` 的生产 Swift，读取当前工作树。未修改源码、未运行构建/测试、未读取其他产品仓库。已读根上下文、`iosApp/AGENTS.md`、`NovelCreation/AGENTS.md`，采用 `improve-codebase-architecture` / `codebase-design` 的职责与深模块审查方法；按任务要求输出 Markdown，不自行实施或增加确认阶段。

## 规模与判断

- 当前目录有 **78 个 Swift，79,989 行；32 个超过 1,000 行，16 个超过 1,500 行**。这 16 个共 43,775 行，占目录 Swift 行数 54.7%。用 `Path.read_text().splitlines()` 按物理行统计，含注释/空行。
- 最大是 `NovelSessionViewModel.swift` 6,493 行，其次 `NovelCreationViewModel.swift` 4,459 行。这不是没有架构：已经存在 actor、repository、reducer、projection、structured executor、transaction lifecycle，必须保留这些真正有用的 seam。
- 适合本轮的目标是 **同一编译模块内按职责整理目录、拆出内聚类型与实现文件，让所有自有 Swift ≤1,500 行**。并不需要先建多层 Swift Package，也不能把一个对象简单切成若干 `Part1/Part2` 文件就宣称完成模块化。
- 当前 `NovelSessionBubble.swift` 有用户未提交改动；落地时应基于冻结基线/隔离工作树处理，不覆盖。近两次小说提交含独立 AmberNovel 应用与后台续跑，应同时核对共享源码的 target membership。

## 6 个主要发现（不是功能 bug 报告）

### 1. 两个 ViewModel 聚合了真实独立职责，文件大小已转化为维护耦合（Strong）

`NovelSessionViewModel.swift:496` 的类同时拥有 binding/run consumer（535–558）、batch polish task（559–565）、ghostwrite task/background ownership（567–580）、projection cache（581–604）、text/reasoning pacer（606–639）。同文件还放纯 pacer（77–374）、审批提交（1568–1942）、批量润色（2768–3175）和多章代笔执行（4812–6493）。修改一个生成流程时，必须在多个上千行片段间寻找任务/令牌/可见状态，locality 很差。

`NovelCreationViewModel.swift:263` 同时持有选择快照、Quick Start、operation owner、状态同步、连续性检查和外部 mutation 监听；`perform`（3649）把 operation gate、事务、刷新、已提交但刷新失败的状态串在一起，是应该保留的中心 seam，不能复制到新模块。

建议把纯计算/投影先独立，再把批量润色、代笔执行等 **状态和方法一起** 转入由现有 App/workspace owner 持有的协作模块。主 ViewModel 继续只呈现单份状态和用户意图；不得在新 controller 与原 ViewModel 同时保存同一个 run/progress。只做跨文件 extension 能满足行数，但不能单独解决这项问题。

### 2. 已有领域 mutation 主链很重要，拆分应在其内部增加 locality（Strong）

`NovelCreation.swift:219` 的 `DefaultNovelCreation` actor 持有 repository/modelRunner、in-flight operations、generation runtimes 与 recovery 状态（233–266）。`NovelGenerationLifecycle.swift:2321` 统一序列化生成写入，再走 validated transition / repository commit / install committed snapshot。`NovelFactTransactions.swift:67` 已是纯 reducer；副作用在 `NovelFactTransactionLifecycle.swift`。

因此本轮应维持 **UI intent → NovelCreation interface → DefaultNovelCreation actor → reducer/validator → NovelProjectPersisting adapter**。不能为了拆文件再增加“总协调器”、另一套 reducer、第二个 project store，或让 ViewModel 直接写文档。对同一 actor 的多个 lifecycle 实现文件，按业务阶段使用 extension 是合理的，不必为了“模块化”把串行 owner 拆成几个 actor。

### 3. 流式可见态与 durable 终态已经有不同 owner，搬移会触发时序风险（Strong）

`NovelSessionViewModel.swift:3555` 按 run 事件处理正文、reasoning、completed/interrupted/failed/persistenceBlocked；`publishTerminalPresentation`（4297）先 drain 可见 partial，再切终态/刷新 durable。`NovelGenerationLifecycle.swift:1485` 的 terminal claim 与 1887 的 persistence 负责另一层 durable 收口。`NovelSessionPresentation.swift:2238` 起已有 bottom-follow reducer；`NovelSessionView.swift:1677` 消费其 commands。

拆分必须让原 runID/projectID/branchID/bindingToken 贯通：只有一个 presentation FIFO、一个 terminal claim、一个 durable mutation owner、一个 scroll owner。可把 pacer、cache、render projection 分开，但不能在新 View 子树里复制 binding 状态、重新创建滚动 owner，或把视图消失改成取消 App 持有的运行。这里的风险来自 async/观察/身份迁移，不是“函数移动”本身。

### 4. repository/validator 很长，但职责已可明确分组，不能拆碎事务（Strong）

`NovelProjectRepository.swift:20` 的 actor 将 CRUD/commit、sidecar、lifecycle marker、路径布局、sharded read/write、兼容迁移、summary index 缓存放在一起。`commitProject`（334）通过精确 cache/layout 检查与 checkout reconcile 保证新磁盘 revision 不被覆盖；`installValidatedCommit`（399）负责安装后结果判定。

`NovelDocumentValidator.swift:18` 已统一调用 material/session/chapter/checkpoint/candidate/ledger 规则，并接入独立 `NovelPolishDocumentValidator` / `NovelGenerationDocumentValidator`。适合按记录组、transition、ledger 拆 validator；保留一个统一入口与同一份校验输入。repository 适合拆文件布局/sidecar/index 的实现，保留 actor 的 cache 与写入顺序，不能把一次 commit 的 authorization claim 与 primary install/重读确认分给独立并发 owner。

### 5. 一部分大文件是契约/历史资产混装，不应该通过删兼容或加抽象解决（Strong）

`NovelDomainModels.swift` 混有 Codable 记录、ChapterPlan digest/injection、人物身份匹配算法（863–1158）、proposal filter（1160）与 snapshots；`NovelActions.swift` 同时装 commands（4）、canonical payload（595/896）、outcome（1233）、run request/event（1479/1693）、公共 `NovelCreation` protocol（1722）和 errors（2059）。这些可按领域自然拆开，已有 interface 不变。

`NovelPromptCatalog.swift:42` 维护历史 prompt version 接受集；648 起约 1,000 行是历史 system text，不能因长而删除。其注释记录历史 receipt 与当前 prompt version 混用曾导致旧项目被判损坏。重构应拆 Current / History / Contracts / Normalization，同时验证全部 `(kind, version)` 的文本/摘要相同。`NovelStructuredOutput.swift:1554` 的严格 JSON/type/key 校验及 2280 的重复键 parser 也不是无效冗余，不应改成宽松解析来减少行数。

### 6. 文件路径参与测试契约，搬文件需要同步接线测试，不能只让编译通过（Strong）

`IOSNovelCreationWiringTests.swift:305`、315、629–630、971 等直接读取 `NovelSessionSheets.swift` / `NovelSessionViewModel.swift` / `NovelCreationViewModel.swift`；`NovelSessionReplayTests.swift:394`、2132、2494、2510–2520 也直接读取具体源文件。

这些测试在正确拆分后会因实现移动失败。应把路径改到明确职责文件，并保留同一约束/行为断言；有真实行为入口时逐步让断言通过 interface 验证。不得删除断言或改为对所有源码宽泛 `contains` 来制造绿色。共享到 AmberNovel 的新源文件还需双 target 编译校验。

## 目录建议

以下是同一 target/module 内的导航目录，不是新增 package。现有小文件按职责移动；与拆分无关的改名/风格调整不混入。

```text
NovelCreation/
  Domain/             # IDs, records, commands, outcomes, snapshots, reducers, validation
  Application/        # NovelCreation interface / DefaultNovelCreation, lifecycle orchestration
  Persistence/        # repository, package/shards, sidecars, workspace IO/ledger
  Model/              # model adapter, transport mapping, structured output, prompt/injection
  Workspace/          # workspace view model, selection, project intents, state sync, import/export
  Session/            # session view model, run observation, projection, presentation, transcript
  Ghostwrite/         # existing ghostwrite contracts + chapter execution/progress/recovery
  Polish/             # existing polish contracts + batch polish UI orchestration
  Views/              # project/branch/material/manuscript views
  Views/Sheets/       # collect/archive/context/plan/revision sheets
```

Domain 内可按 `Records/Commands/Validation` 二级目录再分，避免一个目录重新堆满文件；目录拆分与行为模块拆分应分批实施，必要时先原位提取，再整体移动。

## 全部 16 个超限文件的拆分清单

行数是当前快照。以下名称是可审阅的职责草案；每个结果文件必须 ≤1,500 行，通常留在 400–1,200 行，避免刚好卡到 1,500 后立即再次溢出。小的独立类型不为凑文件数再拆。`+` 文件只用于保留同一 actor/类型 owner 的实现分区，不是新状态容器。

| 当前文件 / 行数 | 拟拆文件与职责 | 保留 owner / interface | 风险与行为验证 |
|---|---|---|---|
| `NovelSessionViewModel.swift` **6493** | `Session/NovelSessionViewModel.swift`：状态呈现、binding、用户意图；`NovelSessionRunLifecycle.swift`：start/attach/retry/stop 与 FIFO 消费；`NovelSessionStreamingPresentation.swift`：buffer/reasoning/terminal drain；`NovelSessionPresentationPacer.swift`：纯 cursor/pacing；`NovelSessionProjectionStore.swift`：durable projection cache/失效/局部 tail patch；`NovelSessionApprovalActions.swift`：ask_user/修订/撤销/删除确认；`NovelSessionCandidateActions.swift`：collect/fork/archive/polish intents；`Polish/NovelBatchPolishController.swift`：串行生成-采用与报告；`Ghostwrite/NovelGhostwriteSessionController.swift`：批次启动暂停/外层循环；`NovelGhostwriteChapterExecution.swift`：章内生成/审校/收录/同步；`NovelGhostwriteRecovery.swift`：sidecar/background lease/恢复。每个状态模块随其 task/token 一起迁移，分批缩减主 VM。 | 继续 `@MainActor` 与现有 session/workspace 生命周期；durable mutation 仍交给 creation actor。单份 transientTail/progress，gate 仍统一。复用 `NovelGhostwritePipeline.swift` 现有 contracts/phase，不新增状态机。 | **最高**：async 重入、detach、旧 run 回调、Observation 依赖、终态 drain。验证 SessionViewModel/Replay/GenerationLifecycle、BatchPolish/CollaborationMode/FactTransactionLifecycle，以及后台取消、同步后记账不重复、审批落到原 run。 |
| `NovelCreationViewModel.swift` **4459** | `Workspace/NovelCreationViewModel.swift`：依赖、可见快照、单一 mutation gate；`NovelWorkspaceState.swift`：draft/status/owner value types；`NovelProjectSelection.swift`：list/select/refresh/reload/cache revision；`NovelWorkspaceProjectCommands.swift`：项目/资料/分支/正文 intents；`NovelQuickStartController.swift`：任务/owner/status；`NovelWorkspaceStateSync.swift`：自动/手动同步队列、取消、活动与恢复；`NovelWorkspaceContinuity.swift`：plan/audit/repair；`NovelWorkspaceTransfer.swift`：import/export/workspace；`NovelWorkspaceRunBridge.swift`：run 入口/background lease。状态同步相关约 1,000–1,200 行，超预算时活动投影单独成 `NovelStateSyncActivity.swift`。 | `projectSnapshot` 是领域快照的呈现；selectionToken、operationOwnerID、`perform` 提交后刷新失败语义保留单一权威。新职责模块不得各自维护项目缓存/各自放行 mutation。 | **高**：切项目/分支后异步结果串台、已提交但 reload 失败、工具外部 mutation。CreationViewModel/CreationPresentation/ManualEditSync/ContinuityAudit/IOSNovelCreationWiring。 |
| `NovelSessionSheets.swift` **3301** | `NovelDiscussionArchiveSheet.swift`（含 offer/preparation）；`NovelCollectCandidateSheet.swift`（含 target choice）；`NovelSessionForkSheet.swift`；`NovelWritingContextSheet.swift` 仅容器/路由/共享 draft；`NovelWritingPlanSection.swift` 放本章计划/下一弧/模式编辑与 IME field state；`NovelInjectionContextSection.swift` 放材料选择/budget/preview；`NovelGhostwriteRevisionSheet.swift`（含 strategy）；`NovelManualRewriteCandidateSheet.swift`。写作上下文原有约 1,790 行，不能只整块移到另一个超限文件，至少分 plan/context/container 三职责。 | draft/dirty revision/IME field bank 在 owning sheet 存活一次；children 用 bindings/明确 submit，事务仍走 workspace/session。 | **中高**：中文 marked text、sheet dismissal、dirty draft 被快照覆盖、审批提交一次性。CreationPresentation/IOSNovelCreationWiring，真机 IME 与 sheet 切换。 |
| `NovelDocumentValidator.swift` **3012** | `Domain/Validation/NovelDocumentValidator.swift`：统一入口、错误聚合、validated transition；`NovelDocumentRecordValidation.swift`：project/material/session/chapter/proposal/candidate；`NovelCheckpointValidation.swift`：checkpoint/lineage/head timeline；`NovelOperationLedgerValidation.swift`：ledger/outcome/branch order；`NovelDocumentTransitionValidation.swift`：immutable prefix 与每种记录 transition。按现有函数组分配，每份约 500–1,000 行。 | 统一 validate/validateTransition interface 不变；继续调用现有 Generation/Polish/Compatibility validators；共享校验上下文按当前实现复用，不新增全局缓存。 | **高**：漏调用某组 validator、错误归类变化、重复全量验证。DocumentValidation/CompatibilityLineage/GenerationReducer/Collection/ManualEditSync。 |
| `NovelSessionView.swift` **2788** | `Session/NovelSessionView.swift`：页面路由/sheet/state composition；`NovelSessionTranscriptView.swift`：行列表、scope、archive card；`NovelSessionComposerView.swift`：dock/meta/input；`NovelSessionRecoveryViews.swift`：sync/polish/quick-start/error banners；`NovelSessionScrollCoordinator.swift`：既有 follow event/command 与 UIKit driver 接线；`NovelCharacterIdentityCards.swift`：identity UI；intent preference/policies 放 `NovelSessionViewPolicy.swift`。 | 原滚动 owner 与 state identity 保持；新 transcript 子树不要在 body 重建 controller。状态归属先明确再移动 @State，不能把关闭 sheet 变成 detach/cancel。 | **高**：stream 滚动、历史冻结/回底追平、cold-open、keyboard。SessionReplay、Native Timeline/Viewport 三门禁、真机长文与 IME。 |
| `NovelGenerationLifecycle.swift` **2569** | `Application/NovelGenerationRuntime.swift`：policy/runtime/terminal value types；`DefaultNovelCreation+GenerationStart.swift`：reservation/start/interrupt；`+GenerationRecovery.swift`：恢复、detached reconnect、background；`+GenerationStream.swift`：subscriber/install/consume；`+GenerationTerminal.swift`：claim/reduce/persist/settle/replay；`+GenerationRequest.swift`：model policy/params/prompt/injection preview。各约 250–850 行。 | **全部保留同一 DefaultNovelCreation actor**；runtime dictionary、write lock、terminal claim 不分裂。必要跨文件 helper 只放最窄 internal scope，不批量去掉 private。 | **最高**：cancel-start race、claim 幂等、保存失败 retry、sidecar/durable terminal 顺序、背景恢复。GenerationLifecycle/SessionViewModel/SessionReplay/LiveModelAdapter。 |
| `NovelSessionPresentation.swift` **2468** | `Session/NovelSessionPresentationModels.swift`：rows/actions/transient tail/list/input；`NovelSessionPresentation.swift`：durable project、tail patch、archive folding；`NovelSessionProjectionIndex.swift`：预建索引；`NovelSessionActionAvailability.swift`：candidate/retry/fork/undo gates/digests；`NovelSessionBottomFollowPolicy.swift`：已存在 bottom-follow state/reducer。若 models 接近上限，tail 与 list 各为完整文件。 | 全部保持纯 projection；prepared index 单次构建后复用；bottom-follow 原 reducer 原接口，不能重新设计滚动策略。 | **中**：动作可用性与生成 gate 不一致、row digest/hash 变化、重复 O(n) scan。SessionReplay/CreationPresentation；retain projection-build-count & tail patch assertions。 |
| `NovelFactTransactions.swift` **2428** | `Domain/NovelFactTransactionModels.swift`：input/result/receipt value types；`NovelFactTransactionReducer.swift`：保留入口和共有 transaction contract；`NovelCollectionReducer.swift`：prepare/commit/ghostwrite adjudication（82–944）；`NovelManualEditSyncReducer.swift`：manual edit/plot/manual rebuild/finalize（945–1701）；`NovelFactTransactionGuards.swift`：pending/retry/receipt/lineage helpers（1702 后）。可保持现有 reducer extension 名称，职责文件名表达业务。 | 同一 reducer 语义；canonical projected-state 与 receipts 共用现有构造；commit 仍只由 lifecycle/actor 执行。 | **最高**：候选稿变正文、atomic collect、plan digest、retry 幂等、手改 needsSync。FactTransactionLifecycle/Collection/ManualEditSync/ChapterReplacementState/CollaborationMode。 |
| `NovelDomainModels.swift` **2417** | `Domain/NovelIdentifiers.swift`；`NovelProjectRecords.swift`（project/material/branch/config）；`NovelWritingPlanModels.swift`（chapter plan/upcoming arc/readiness）；`NovelSessionRecords.swift`（messages/ask user/candidates）；`NovelManuscriptRecords.swift`（chapters/versions/state/checkpoints）；`NovelRunRecords.swift`（run/recovery/pending/receipts）；`NovelProjectDocument.swift`（aggregate Codable/init/encode + snapshots）；`NovelCharacterIdentityResolver.swift`（已有算法与 proposal filtering，可按变化原因独立）。 | 类型名、Codable keys/defaults、digest payload 逐字保留；每个类型的 init/encode 与自身共置。不顺手迁数据 schema。 | **中**：兼容 decoder default、身份 heuristic、稳定序列化。CreationModule/DocumentValidation/CharacterIdentityCandidate/ProjectPackage/CollaborationMode。 |
| `NovelStructuredOutput.swift` **2407** | `Model/Structured/NovelStructuredContracts.swift`：output DTOs；`NovelQuickStartStreamingPresentation.swift`：partial JSON 展示；`NovelChapterPlanMarkdown.swift`：既有 Markdown fallback parser；`NovelStructuredOutputDecoder.swift`：decode dispatch/errors；`NovelStructuredOutputValidation.swift`：semantic validation；`NovelStrictJSON.swift`：strict shape/key/type；`NovelJSONDuplicateKeyValidator.swift`：lexer/parser。 | 现有 strict decode interface/error category 不变；流式展示与最终可信解码仍分开；canonical contract 不重复声明。 | **中高**：未知 key/重复 key/尾随文本/输出协议被意外放宽。StructuredOutput/StructuredModelExecutor/FactOutputValidationAnchor。 |
| `NovelProjectRepository.swift` **2165** | `Persistence/NovelProjectRepository.swift`：actor/dependencies/cache/CRUD/commit；`NovelProjectRepository+DiskLayout.swift`：paths、sharded read/write、migration、previous；`+Recovery.swift`：recovery/ghostwrite sidecar；`+Lifecycle.swift`：tombstones/replacement/lifecycle records；`+Index.swift`：summary inventory/manifest/cache。核心 install/authorization/reconcile 保持同一个方法组，约 700–1,000 行。 | 保留 `NovelFileProjectRepository` actor 与 `NovelProjectPersisting` adapter；现有 `NovelProjectShardedStorage` / WorkspaceProjectStore 继续使用，不再封一层空仓库。 | **最高**：磁盘 out-of-band edit、stale revision、primary 已安装但 index 失败、恢复覆盖。ProjectRepository/WorkspaceRepository/WorkspaceContract/ProjectLifecycleOperation/ProjectPackage。 |
| `NovelActions.swift` **2131** | `Domain/NovelCommands.swift`（4–414）；`NovelAction.swift`（enum + metadata + canonical action payload，415–1232）；`NovelOutcome.swift`（outcomes/snapshot，1233–1478）；`NovelRunContract.swift`（request/canonical payload/receipt/event，1479–1721）；`Application/NovelCreation.swift` 或 `NovelCreationContract.swift`（protocol/defaults，1722–2058，避免与当前 actor 文件重名）；`NovelError.swift`（2059 后）。 | caller-facing type names 与默认能力行为保留；canonical payload encoding 与 enum case 顺序/keys 不变。 | **中**：operation hash 稳定性、重试识别。Reducer/GenerationReducer/FactTransactionLifecycle/CreationModule。 |
| `NovelPromptCatalog.swift` **2056** | `Model/Prompts/NovelPromptCatalog.swift`：kind/template/version dispatch；`NovelCurrentPrompts.swift`：当前文本；`NovelHistoricalPrompts.swift`：历史版本文本（原 648–1654，约 1,007 行）；`NovelPromptContracts.swift`：共享 JSON/evidence 文本；`NovelCandidateProseNormalization.swift`：polish sentinel/fence 清理。 | 外部仍经 Catalog；保留所有 acceptedVersions、历史 systemText 和规范化语义，不改 prompt 内容/版本。 | **中**：历史 receipt 读不回、prompt byte/digest 变化、误清正文 fence。PromptCatalog/StructuredModelExecutor/GenerationReducer/DocumentValidation。 |
| `NovelLiveModelAdapter.swift` **1821** | `Model/Transport/NovelLiveModelAdapter.swift`：actor route/start/resume/cancel/active run；`NovelLiveTransportContract.swift`：request/callback/handle/hooks；`NovelKMPTransport.swift`（含 request mapping）；`NovelResponsesTransport.swift`：background start/resume；`NovelDiscussionTransport.swift`：tool loop与 step accumulator；`NovelProviderTransport.swift`：Grok/Gemini hooks；`NovelModelEventMapping.swift`：UIMessage/MessageChunk转换；`NovelLiveCallbackSink.swift`：FIFO callback queue/cancellation boxes。可以合并自然相邻的小类型，避免过细。 | 同一 activeRuns owner；实际 `NovelModelRunning`/`NovelDurableModelRunning` interface 保留；transport closure 依赖已可注入，无需额外 protocol 框架。 | **高**：provider 配置快照、callback FIFO、旧 attempt、cancel before handle、reasoning 不污染 manuscript、discussion step replacement。LiveModelAdapter/ModelAdapter/StructuredModelExecutor + 对应 KMP bridge/真实 provider 验证。 |
| `NovelSessionBubble.swift` **1721** | `Session/NovelSessionBubble.swift`：row composition；`NovelSessionFullTextReader.swift`：windowed Markdown/pagination/full text sheet；`NovelSessionActionButtons.swift`：button availability/labels；`NovelAskUserCard.swift`：options/freeform；`NovelApprovalCards.swift`：plan/revision/plot/revert/delete 卡片及共用 morph；若卡片约 650 行可合并，勿拆成几十个零碎控件。 | Bubble 保持 Equatable/input identity；approval 状态只消费 row，确认仍发回唯一 intent。保留当前工作树已有修改。 | **中高**：approval→result 动画、正文长文分页、tap target、row invalidation。SessionReplay/CreationPresentation/IOSNovelCreationWiring，视觉/IME 真机。 |
| `NovelInjectionPlanner.swift` **1539** | 最小合理提取：`Model/Injection/NovelInjectionModels.swift`：request/receipt/section/plan（4–292）；`NovelInjectionPanelPresentation.swift`：panel projection（293–365）；原 `NovelInjectionPlanner.swift` 保留 planner + selection/build helpers，约 1,174 行；不为仅超 39 行重写整个算法。 | 仍只有一个 planner 返回 plan/receipt；排序、token budget 与 canonical context 相同。 | **中**：当前已持久化 snapshot 注入、needsSync gate、budget/排序/digest。InjectionPlanner/ManualEditSync/FactTransactionLifecycle。 |

## 实施先后与依赖

1. **冻结基线和验收口径**：记录 HEAD/dirty diff；确定所有自有 Swift 与共享 targets 的统计/编译范围；记录受影响既有测试结果。变更内容与源文件路径都从基线清单追踪。
2. **先拆低耦合契约与纯逻辑**：DomainModels、Actions、PromptCatalog、StructuredOutput、InjectionPlanner；保持类型和输出完全一致。此阶段为后续状态模块提供清晰目录，但不改 schema/protocol。
3. **展示纯计算与低风险叶子 UI**：SessionPresentation（含原 bottom follow reducer）、Bubble 的卡片/reader、Sheets 的 archive/collect/fork；WritingContext 分区须保持 draft/IME owner。同步源路径测试，保留断言。
4. **ViewModel 的实际职责拆分**：先 pacer/projection/approval，再 batch polish，最后 ghostwrite；workspace 先 selection/commands/import-export，再 quick-start/state-sync/continuity。每次只迁移一个状态 owner，不能将方法移走后暂时存在两份 task/token。主 ViewModel 最后收敛到 composition 与意图。
5. **高风险事务/持久化/runtime**：Validator → FactTransactions → Repository → GenerationLifecycle → LiveModelAdapter；其各子批次可按依赖并行，但同一 actor/状态区不要由不同 implementer 同时改。这些必须保持统一 commit/terminal owner。
6. **收尾验收**：每个原超限文件有归属清单，所有新文件/旧文件均 ≤1,500；无重复状态、无缺 target membership、无遗漏 source-path assertion。运行受影响 tests 与两个 app targets 的编译；对流式/输入/后台/真实 provider 保留单独行为验收，不用编译成功替代。

## 本域必须覆盖的行为矩阵

- Session：新开/重进/切分支；运行中 detach/re-attach；历史浏览不追底、显式回底后跟随；complete/error/cancel 时 visible partial drain；reasoning 单独呈现。
- Generation：cancel before start、旧回调、background expiration、durable save fail/retry、恢复 cursor、run identity。
- Domain：候选不可直接变正式正文；审批后走既有 manual edit/collect；needsSync 可讨论但禁止正文/重写/润色；本章计划 digest/代笔收录/连续性审计角色保持。
- Persistence：load/save/restart roundtrip、已安装 primary 但 index 失败、newer disk revision、legacy/package/sharded/workspace 导入导出；sidecar ownership/hash/sequence。
- UI：marked text 保存/提交/关闭、dirty draft 不被 snapshot 回填覆盖、审批卡状态变化、长文性能和滚动。
- 文本契约：所有已接受 prompt 版本、canonical payload/digest、strict JSON duplicate/unknown key/error category。

以上是当前源码证据支持的重构 plan，不声明存在已复现功能 bug，也不声明已跑过这些门禁。
