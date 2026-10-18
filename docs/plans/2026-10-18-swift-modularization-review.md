# Swift 文件拆分与模块整理：审查及实施计划

日期：2026-10-18。基线：`main` / `b98bd6f0f2f82dd9492ff021e53d03bfe26d2dce`，包含审查开始时的未提交工作。范围仅本独立 iOS/KMP 仓库。本轮交付审查和计划，不实施重构、不提交、不推送。

## 1. 判断与范围

项目已经需要系统整理。问题集中在职责聚集、状态接口过宽、文件名不能反映实际内容，以及多产品共享源码的构建接线。现有的 run owner、领域 actor/reducer、repository、provider/tool interface 和行为测试有保留价值，适合沿这些契约逐步拆分。

推荐先在现有 target 内形成职责清楚的逻辑模块，完成全部超限文件治理；编译模块化（Swift Package/framework）单独评估。文件夹归类本身不算完成：每个模块还需要能找到入口、唯一状态 owner、明确依赖方向和对应行为测试。

### 当前可复现统计

统计 `git ls-files --cached --others --exclude-standard -- '*.swift'` 去重后仍存在的文件；计算完整物理行，包含空行、注释、多行字符串，末尾没有换行的最后一行也计入。与 `rg --files -g '*.swift'` 交叉核对，文件集合相同。本次所有文件的物理行计数也与换行符计数一致。

| 范围 | 文件数 | 总行数 | >1000 行 | >1500 行 | 最大文件 |
|---|---:|---:|---:|---:|---:|
| 自有非测试文件，含示例 | 501 | 336,104 | **101** | **51** | 8,429 |
| 自有测试与 fixture | 345 | 194,734 | 53 | **29** | 5,713 |
| vendor，含其测试与示例 | 106 | 13,006 | 0 | 0 | 928 |
| 合计 | **952** | **543,844** | **154** | **80** | **8,429** |

因此，用户提出的 101 个文件与当前非测试口径吻合。全仓最大单文件不超过 1500 行，需要治理 80 个文件；测试不能被排除以提前宣告完成。主应用 `iosApp/iosApp/` 有 431 个 Swift 文件，其中 100 个超过 1000 行、51 个超过 1500 行；额外的一个非测试 >1000 文件是 `PhoneControlRunner/Sources/RunnerWDA.swift`。

`AmberThemePack.swift` 当前正好 1500 行，满足上限但没有增长空间。1001–1500 行文件不因数字自动列入强制拆分；随所在职责的迁移归位，必要时给经常修改的文件留出余量。完整文件清单与职责拆法见本文附录和同目录 CSV。

### 审查覆盖与限制

- 全量枚举 Swift，逐个为 51 个生产超限文件和 29 个测试超限文件制定归属与拆法。
- 分别审查聊天、小说、工具执行与编排、平台状态、通用 UI、构建与测试；追踪关键生产入口、现有 owner、调用者和测试契约。
- 最近 100 条提交的文件触及统计显示：`ChatToolRuntime`、`ChatViewModel` 各 28 次，`ChatKernelRunHost` 24 次，`ChatView` 19 次，后台生成 coordinator 18 次。优先级同时考虑变更频率和风险，不仅按行数排序。
- 本轮未运行构建、测试、模拟器、真机或真实 provider；这是源码架构审查，不能解释为功能无 bug、重构已完成或性能已有改善。

## 2. 主要发现

### A. 最大文件主要装了另一个完整子系统，优先按现有 owner 拆

`IOSLocalToolExecutor.swift:141–1154` 是约 1014 行的执行器本体，`:1156` 起是 WebMount：registry、URL policy、cookies、WK runtime、桥接 JavaScript、session store、controller 和 redaction。WK runtime（`:2065–3234`）和 bridge scripts（`:3241–4288`）整块迁出后已经分别小于 1500 行。

这项拆分首先改善定位和修改局部性，不需要重写工具协议。之后单独处理约 2860 行的 WebMount controller（`:5304–8163`）：session/store 继续拥有运行时和控制权，local/desktop 命令各自封装执行细节。不能把这些状态复制给多个 handler。

### B. 聊天的运行职责仍偏集中，现有隔离接口适合局部收窄

当前生产链是 `ChatViewModel.generateResponse` → `ChatKernelRunHost` → `ChatRunKernelAdapter` → `IOSAgentToolEngine`。`ChatGenerationSupport.swift:95–168` 的 `ChatGenerationBindings` 有 **40 个闭包字段**，接线集中在 `ChatViewModel.swift:1264–1531`。该文件本身只有 553 行，仍要求两端共同理解逐属性写入、副作用及调用顺序。不过它只有一个生产构造点，另有两套测试 harness，用于隔离和记录存储、ledger、系统效果的真实顺序；数量本身不是设计错误。

保留这条已经工作的链。先迁走请求准备、消息投影、独立工具族等清晰职责，再局部收拢 9 个审批 setter 与 triage 等重复接线。CAS 持久化、带回滚的 MiniApp 提交、系统副作用与 mailbox/steer 顺序继续显式。请求快照、运行命令和 UI 投影应有清楚角色；不能为了减少闭包数量再塞进一个无所不包的 context 对象。

`ChatToolRuntime.swift` 的 7705 行包含审批准备、recipe checkpoint、plugin host、exec/wait、跨会话查询等多类工作，需要具体职责 owner 的组合。只新增一批 `+Helpers.swift` 并放宽所有 `private`，会把同一个大对象分散到更多文件。

### C. 大量 UI 文件适合完整类型迁出；涉及编辑事务的部分要另做行为对照

`PlaceholderViews.swift`（3519）实际包含首页、搜索、设置首页和 Workspace；`MemoryToolApprovalCard.swift`（2154）聚集多类审批卡及 AskUser；`CouncilChatRuntimeView.swift`（4414）混有 UI、ViewModel、DTO 和 archive store。这些先按完整类型迁出，适合作为低风险试点。

`RuntimeEnvironmentView.swift`（2632）和 `ProviderDetailView.swift`（2462）则同时拥有草稿、异步请求、保存及回滚。SSH 编辑的探测/信任/认证事务、provider 的 headers/config 保存和模型发现必须各自保持一个状态 owner。新子视图不应复制草稿，也不能把父级清理逻辑散落到多个 `onDisappear`。

### D. 小说已经有领域模型，拆分应维护现有权威写入链

`NovelCreation/` 有 78 个生产 Swift 文件、16 个超过 1500 行。已有 `DefaultNovelCreation` actor、reducer、repository、generation lifecycle、projection 等职责。重点治理两个 ViewModel、生命周期编排、事务和 codec/UI 的混装。

项目文档仍是唯一权威来源；UI 只表达意图和呈现。候选稿进入正文继续经过既有 collect/replace/polish 事务，run identity、FIFO、terminal drain、needsSync 门禁、中文输入提交顺序不得改变。拆分不是再造一套小说状态机的理由。

历史 prompt、accepted versions 和兼容 codec 有数据契约，不能通过删历史分支降低行数。纯模型定义或静态 prompt 的长文件与多 owner 的大 coordinator 应采用不同拆法。

### E. 有真实跨域依赖，应该先纠正归属

`IOSSearchExecutor.swift:1255–1346` 的公网 URL/IP/DNS policy 被 WebMount、MiniApp、Watch 和聊天使用；search transport 又依赖 `IOSWebMountPublicDNS.resolve`。先将稳定的公共网络判定归入 Networking，再让各功能消费它。保留严格公网访问与 verified scrape 的 Fake-IP 例外差异，不能合并成更宽松的通用 fetch。

`IOSTerminalRuntime.swift:235–626` 内的 `IOSAdvancedTaskStore` 实际也被 Council、SubAgent 使用。将已有 task models/store 整体迁到运行任务目录即可，不需要新建通用任务框架。

### F. 文件拆分涉及构建图和测试发现，不能只看主 target 编译

主应用按目录收集源码，NovelApp/DeepReadApp 则显式引用部分共享文件；NovelApp 还显式引用共享测试。路径变动必须连同 project.yml 的 target membership 更新。`Shared.framework` 仍由本仓 Gradle 构建，没有已独立发布的 Core 可以直接依赖。

若干测试通过 `#filePath` 及固定 Swift 文件名读取源码，迁移后会产生结构性假失败；还有跨 suite 复用的 nested provider/ledger fake。需要保持断言含义、调整实际职责入口和 helper 归属，不能删断言或只跑旧 suite 名而漏掉拆出的新类。

### G. 现有行数门禁不能支撑新目标

当前未跟踪的 `.swiftlint.yml:17–19` 是 2500 行 warning、4000 行 error，开头注释也认可既有超长文件。它与本次 1500 上限不一致。实施时在保留该文件其他未提交内容的前提下更新相关规则，并建立独立、可复现的全仓物理行检查。当前 vendor 最大 928 行，无需修改 vendor 或设置永久豁免来达到目标。

## 3. 路径选择与目标组织

| 路径 | 收益 | 成本与问题 | 判断 |
|---|---|---|---|
| 仅按行数拆成多个 extension | 很快降低单文件数字 | 大对象、共享状态和调用顺序仍然分散，常需扩大可见性 | 只用于同一 owner 内部很明确的组织，不作为主方案 |
| **现有 target 内按职责形成逻辑模块** | 保留部署/KMP/观察机制，能逐批验证；同时整理入口与 owner | 编译器暂不能强制全部 feature 依赖约束，需要审查依赖和可见性 | **推荐作为本次完整交付范围** |
| 一开始拆成大量 Swift Package/framework | 可形成编译隔离 | Shared/KMP、显式共享源码、资源、测试宿主及访问控制一起变化 | 本轮不直接采用；先稳定逻辑职责，再评估少量有真实消费者的叶子模块 |

推荐目录是职责地图，不是要求一次搬完全部文件；每个 feature 在本批次拆分时带着相关小文件归位。现有 `NovelCreation`、`DeepReadCore`、`PhoneControl` 的根与局部规则先保留。

```text
iosApp/iosApp/
  App/                       # 应用入口、依赖组装、导航
  DesignSystem/              # 主题、字体、通用视觉原语
  Chat/
    Presentation/            # Composer、Timeline、Markdown、消息卡、Artifacts
    Application/             # 会话意图、请求准备、界面投影
  AgentRuntime/
    Kernel/                  # Host、Adapter、ToolEngine
    Background/              # run 调度、恢复、终态持久化
    Tools/                   # 工具路由、审批、具体执行入口
    Orchestration/           # 子代理、mailbox、model pool
    Tasks/ Recipes/ Plugins/
  Home/ Search/ Settings/ Providers/ Conversations/
  Council/ WebMount/ Workspace/ MiniApp/ Board/ DeepRead/ GenerativeUI/
  Infrastructure/
    Networking/ Persistence/ Permissions/ Documents/ Terminal/
  NovelCreation/
    Domain/ Application/ Persistence/ Generation/ Presentation/ Integration/
  DeepReadCore/ PhoneControl/ # 沿已有职责整理，保持各自契约
```

依赖方向：App 负责组装；功能 UI 读取投影并发送意图；功能 application 调用已有 domain/runtime；平台 adapter 封装持久化、网络、系统权限及 Shared 桥。通用纯模型、policy、codec 不反向读取 View、当前页面或 `AppShell`。后台、终态、存储等 stateful owner 只能存在一份，helper 传入快照或明确依赖，不持有另一份权威状态。平台 SDK 不得依赖页面；具体功能的 store 可以继续与其领域契约同目录，不都搬到通用 Persistence。

域报告的候选路径统一规则：`ToolExecution`、非展示的 `Chat/Tools` 归 `AgentRuntime/Tools`；审批卡和工具时间线归 `Chat/Presentation`；`Chat/Background` 归 `AgentRuntime/Background`；`Platform/*` 归 `Infrastructure/*`；`MiniApps` 统一为 `MiniApp`。小说的 session UI/projection 归 `Presentation/Session`，会话与 workspace 的运行意图归 `Application`，prompt/structured/injection 归 `Generation`，transport 归 `Integration`。这些是逻辑职责文件，不要求每个候选文件都新增一个 class/protocol；自然相邻的小类型可共置。

这里的 module 以入口和状态责任定义。interface 应让调用者少了解内部顺序；seam 沿现有 provider、repository、runtime 的替换点保留；adapter 继续承担平台或 Shared 适配。拆分的 depth、locality 和 leverage 由调用者是否更少了解实现、改动是否集中来判断，不用文件数或新增 protocol 数衡量。

## 4. 分阶段实施

各阶段包含一组可独立回归的小批次；同一批次只迁目录/类型，或抽一个状态职责，避免混在一起。测试按对应生产任务同步拆分，不把全部测试留到最后。

| 阶段 | 工作及依赖 | 完成标志 | 风险 |
|---|---|---|---|
| 0 基线与检查 | 固定最新工作树快照；登记既有 WIP；记录构建 target、测试选择器和源码读取测试；增加物理行检查 | 952 文件清单可重现；80 项债务有 owner；受影响基线测试结果单独记录 | 低 |
| 1 低风险试点 | 迁出 Placeholder 中各 feature；按审批类型拆卡片；迁 recipe/plugin、task/terminal 独立类型；同步测试 fixture | 新文件通常 300–1000 行；入口/状态不变；证明 target membership 与测试迁移流程可用 | 低–中 |
| 2 公共网络与 WebMount | 先完成 URL/DNS policy 归位，再迁 registry/WK runtime/scripts/session store，最后拆 controller 与 desktop semantics | executor 本体保持约 1000–1200 行；控制权、审批范围、未知结果语义和 WK 生命周期保持 | 中–高 |
| 3 聊天与工具运行 | 先完整类型/纯投影，再请求准备与工具族；随后 Host/Adapter/engine；后台此期只迁独立值类型/codec，stateful拆分等待阶段5的store稳定 | 主路径界面和运行契约保持；本阶段负责文件 <=1500；run owner、FIFO、terminal/CAS、取消与切会话回归通过 | 高 |
| 4 小说纵向整理 | 可在阶段 1 后独立开展；先模型/codec/prompt/UI，再 Session/ViewModel、generation 与 fact transaction | 全16个超限源文件达标；actor/reducer/repository权威链不变；主App与NovelApp均纳入验证 | 高 |
| 5 其余功能与平台、后台收口 | Council、Workspace、MiniApp、Provider/SSH editor、permission/settings/store/compaction；基础owner稳定后串行完成Background executor/resumer/terminal | 全部51个生产超限文件处理完；保存/恢复/凭证/原始会话归属不变 | 中–高 |
| 6 全仓收口 | 收齐29个测试文件；检查所有受影响 target、相邻1000–1500文件、依赖及可见性；移除临时存量清单 | Git可见Swift零文件>1500；新增suite全部被执行；所需设备/provider检查有明确结果或待验收记录 | 中 |

并行安排：UI 独立类型、小说、测试基础清点可以并行；Search policy 与 WebMount 的同文件迁移串行；Chat/ToolEngine/Background 的共享接口由一个集成 owner 维护；project.yml、公共测试支持、源码路径检查由一个 owner 统一更新。不能让多个实现者同时改 ViewModel/Host 的两端而没有明确接口版本。

建议第一个实施批次包含“基线/增量门禁 + Placeholder 各页面迁出 + 对应 Home/Settings/Workspace 接线验证”，随后再以 WebMount 的完整类型拆分降低最大文件。先用两个边界清楚的批次确认实际编译与回归成本，再给后续高风险阶段排工期。行数不能直接换算为可靠工时。

## 5. 行数与质量验收契约

1. 最终所有 Git 可见 Swift 源文件（应用、独立产品、extension、package、测试、fixture、vendor/示例）**物理行数 <=1500**。本地构建产物不是源码，不纳入。当前 vendor 无超限，不改其行为或默认值。
2. 新文件建议 300–1000 行；有凝聚力的 owner 可以到 1000–1200，1500 是硬上限，不是每个文件应填满的目标。
3. 不压缩空行、多语句挤一行、删注释/历史协议、删测试/死代码、转移成超大字符串或临时排除文件来达标。已经存在的完整脚本/prompt可以按职责与版本迁到合理文件，不改变字节内容/资源加载方式。
4. 阶段0建立的存量清单只用于渐进实施：新文件不能超限，现有超限文件不能继续增长；一个责任批次完成就清掉对应条目。阶段6必须清空清单并启用全量硬失败，没有永久豁免。
5. SwiftLint 阈值同步为 warning 1200 / error 1500；独立标准库脚本作为物理行最终判定，明确注释/空行也计入。CI增加此项；阶段中与最终模式的区别写清楚。
6. 同一 owner 的 `private` 不为跨文件 extension 大面积升级为 `internal/public`；确需跨文件可见的符号先判断职责是否选错，按最小必要接口暴露。保持现有 `@MainActor`、actor、锁与 task 生命周期。
7. 保持 public facade、序列化字段、UserDefaults/Keychain key、磁盘目录、provider请求、权限含义和错误语义。纯拆分不引入数据迁移、新权限或重试机制。
8. 每批只做一次有限可维护性审查：入口、状态写入、错误/取消、测试归属是否更易定位。达到本批验收后交付，不附带扩展框架和无关优化。

## 6. 验证策略

下面是实施期门禁，不是本轮已执行结果。

- **基线**：在受保护的完整工作树快照或隔离工作区运行受影响测试；不能只从 HEAD 建 worktree 后遗漏本轮用户 WIP。既有失败单独登记，不以重构消除断言掩盖。
- **整类型迁出**：对照原方法/常量内容、最小必要的访问控制变化、target membership，运行既有对应测试及消费者编译。无需为“文件移动”新增镜像测试。
- **状态职责抽取**：先确认既有行为覆盖；只对确有缺口的高成本路径补测试。重点是旧回调、取消、权限与真实IO失败、切会话、terminal落盘、重复提交等状态转换。
- **测试迁移**：先整理被多个 suite 引用的明确 fixture，再按行为拆类；保留方法/断言清单和 actor/setup/teardown语义，更新所有 `only-testing` 选择器。源码结构测试继续读真实职责入口，不能靠全库字符串搜索让检查失去定位能力。
- **UI**：保持 view identity、state/observable对象生命周期、动态字体、sheet和keyboard行为。聊天固定跑 Native Timeline/viewport/stream replay门禁，不能用非默认列表代替生产路径验收。
- **跨产品**：根据共享文件消费关系运行 iosApp、NovelApp、DeepReadApp 及涉及的 Watch/Widget、GPL/runner/package gate；每次路径变更核对对应 XcodeGen 输入，不编辑生成项目作为唯一事实。
- **KMP**：保留本仓 Gradle → Shared.framework → Swift 路径；触碰provider/runtime/storage语义时，同时运行对应Gradle测试及Swift消费者。纯Swift迁出不借机改共享核心。
- **设备/provider**：最后对受影响的长文流式、历史浏览/回底、中文IME、后台/恢复、WebMount接管、系统权限等进行相应真实路径验收。构建、测试、安装、启动、用户行为分别报告。

实施完成标准是：80个超限文件全部有清楚去向，全仓行数门禁通过，重要状态契约保留，相关测试与target完成实际验证。仅行数达标不能宣告模块整理完成；没有设备/provider证据的部分要明确保留为待验收。


## 7. 全部超限文件的处置索引

以下覆盖全部 80 项；详细目标文件名、保留的 owner、源码行号和测试矩阵见各域报告。目标目录以本文第 3 节为准，域报告中的目录别名在实施时统一，不能同时保留两套同义目录。规划行数是预算，不能当作拆分后实测。

| 领域 | 超限生产文件 | 详细审查 |
|---|---:|---|
| 聊天与渲染 | 11 | [聊天与渲染报告](../reviews/2026-10-18-swift-modularization/chat.md)；[渲染细表](../reviews/2026-10-18-swift-modularization/chat-render.md) |
| 小说 | 16 | [小说报告](../reviews/2026-10-18-swift-modularization/novel.md) |
| 工具执行与编排 | 8 | [工具执行与编排报告](../reviews/2026-10-18-swift-modularization/tools.md) |
| 平台/状态/持久化 | 8 | [平台/状态/持久化报告](../reviews/2026-10-18-swift-modularization/platform.md) |
| 页面与编辑事务 | 8 | [页面与编辑事务报告](../reviews/2026-10-18-swift-modularization/ui.md) |
| 测试/构建 | 29 个测试文件 | [29项拆分、target关系和计划命令](../reviews/2026-10-18-swift-modularization/build-tests.md) |

### 51 个生产文件

| 原文件 | 行数 | 拟拆职责 |
|---|---:|---|
| [IOSLocalToolExecutor.swift](../../iosApp/iosApp/IOSLocalToolExecutor.swift) | 8429 | 保留约1014行executor；迁WebMount registry/policy/cookie/WK/scripts/session store；再拆controller/local/desktop命令 |
| [ChatToolRuntime.swift](../../iosApp/iosApp/ChatToolRuntime.swift) | 7705 | 保留验证/dispatch；拆 plugin、recipe/checkpoint、JS、session-read、approval、executor adapters，状态随消费 owner |
| [NovelCreation/NovelSessionViewModel.swift](../../iosApp/iosApp/NovelCreation/NovelSessionViewModel.swift) | 6493 | 拆run lifecycle、stream/pacer、projection、approval/candidate intents、batch polish、ghostwrite执行/恢复 |
| [ChatViewModel.swift](../../iosApp/iosApp/ChatViewModel.swift) | 5293 | 保留呈现/意图组合；拆 run registry、persistence/recovery、inbox、附件、请求构造、MiniApp提交 |
| [IOSChatBackgroundGenerationCoordinator.swift](../../iosApp/iosApp/IOSChatBackgroundGenerationCoordinator.swift) | 4949 | 保留registry与run claim；拆headless composition、checkpoint、executor、resumer、recovery、terminal writer |
| [NovelCreation/NovelCreationViewModel.swift](../../iosApp/iosApp/NovelCreation/NovelCreationViewModel.swift) | 4459 | 保留workspace快照/mutation gate；拆selection、project commands、quickstart、state-sync、continuity、transfer/run bridge |
| [CouncilChatRuntimeView.swift](../../iosApp/iosApp/CouncilChatRuntimeView.swift) | 4414 | 拆room UI/rows/sheets、ViewModel、models/copy、transcript与archive store；App级owner不动 |
| [ChatCollectionMessageList.swift](../../iosApp/iosApp/ChatCollectionMessageList.swift) | 3711 | NativeChatTimelineView整体迁出；分 regression list/policies、projection cache、rows、render state/hash cache |
| [PlaceholderViews.swift](../../iosApp/iosApp/PlaceholderViews.swift) | 3519 | 迁出Home/Conversations/rows/controls、Search、SettingsHome、Workspace/detail；保留真正placeholder |
| [WebMountView.swift](../../iosApp/iosApp/WebMountView.swift) | 3405 | 拆routes/handoff、task card、site list/view、memory/report sheets、WK presentation与controls |
| [NovelCreation/NovelSessionSheets.swift](../../iosApp/iosApp/NovelCreation/NovelSessionSheets.swift) | 3301 | 按archive/collect/fork/rewrite拆sheet；写作上下文再分container/plan/injection，IME draft保持owner |
| [ChatKernelRunHost.swift](../../iosApp/iosApp/ChatKernelRunHost.swift) | 3117 | 保留 run/phase 唯一 owner；拆 image run、upload、approval session、terminal commit、durable provider |
| [IOSThreadOrchestrationToolService.swift](../../iosApp/iosApp/IOSThreadOrchestrationToolService.swift) | 3045 | 保留协调门禁；拆launch policy、Jev routing、DAO桥、launcher、models；mailbox按需要分文件 |
| [CouncilRunner.swift](../../iosApp/iosApp/CouncilRunner.swift) | 3031 | 拆settings/models/researcher/streamer/routing/prompts/room runner/live model，保留chat facade |
| [NovelCreation/NovelDocumentValidator.swift](../../iosApp/iosApp/NovelCreation/NovelDocumentValidator.swift) | 3012 | 统一入口；拆record、checkpoint、operation-ledger、transition校验，保留既有子validator |
| [NovelCreation/NovelSessionView.swift](../../iosApp/iosApp/NovelCreation/NovelSessionView.swift) | 2788 | 拆transcript/composer/recovery/identity UI与scroll接线；保留现有滚动owner和state identity |
| [IOSTerminalRuntime.swift](../../iosApp/iosApp/IOSTerminalRuntime.swift) | 2642 | 拆terminal models/policy/runtime/三类executor；AdvancedTaskStore整体归Tasks |
| [RuntimeEnvironmentView.swift](../../iosApp/iosApp/RuntimeEnvironmentView.swift) | 2632 | 拆SSH editor view/model事务、diagnostics view/model、components/task detail；根页面只组合 |
| [IOSAgentToolEngine.swift](../../iosApp/iosApp/IOSAgentToolEngine.swift) | 2574 | 保留run loop；拆contracts、KMP provider adapter、provider step、tool batch；不拆终态/取消owner |
| [NovelCreation/NovelGenerationLifecycle.swift](../../iosApp/iosApp/NovelCreation/NovelGenerationLifecycle.swift) | 2569 | 同一DefaultNovelCreation actor中按start/recovery/stream/terminal/request分文件；runtime value types独立 |
| [DocumentAccessStore.swift](../../iosApp/iosApp/DocumentAccessStore.swift) | 2500 | 拆selected grant、preview reader/ZIP、workspace store/tools/shell、selected-file tool runtime |
| [BoardView.swift](../../iosApp/iosApp/BoardView.swift) | 2499 | 拆Board/history/topic、DeepRead detail、WK hosts、reader components；复用DeepReadCore |
| [NovelCreation/NovelSessionPresentation.swift](../../iosApp/iosApp/NovelCreation/NovelSessionPresentation.swift) | 2468 | 拆models、durable projection、projection index、action availability、bottom-follow policy |
| [ProviderDetailView.swift](../../iosApp/iosApp/ProviderDetailView.swift) | 2462 | 拆configuration editor/view、models view/editor、discovery、auth actions、components |
| [NovelCreation/NovelFactTransactions.swift](../../iosApp/iosApp/NovelCreation/NovelFactTransactions.swift) | 2428 | 保留reducer事务语义；拆models、collection、manual-edit-sync、guards及统一入口 |
| [NovelCreation/NovelDomainModels.swift](../../iosApp/iosApp/NovelCreation/NovelDomainModels.swift) | 2417 | 按identifiers/project/plan/session/manuscript/run/document拆完整类型，identity resolver独立 |
| [NovelCreation/NovelStructuredOutput.swift](../../iosApp/iosApp/NovelCreation/NovelStructuredOutput.swift) | 2407 | 拆contracts、partial presentation、plan Markdown、decoder、semantic validation、strict JSON/duplicate-key parser |
| [ChatView.swift](../../iosApp/iosApp/ChatView.swift) | 2390 | 页面组合；拆 composer container、附件导入 controller、screen/artifact presentation |
| [ChatToolTimelineView.swift](../../iosApp/iosApp/ChatToolTimelineView.swift) | 2311 | 拆 timeline、visual style、step model、subagent/phone presentation、result summary、group header |
| [ChatAssistantMarkdownView.swift](../../iosApp/iosApp/ChatAssistantMarkdownView.swift) | 2289 | 保留入口；分 configuration、blocks/parser/detector、stable stream/controller/cache、既有 test support |
| [NovelCreation/NovelProjectRepository.swift](../../iosApp/iosApp/NovelCreation/NovelProjectRepository.swift) | 2165 | 同一repository actor；拆disk layout、recovery、lifecycle、index；commit/authorization不分裂 |
| [MemoryToolApprovalCard.swift](../../iosApp/iosApp/MemoryToolApprovalCard.swift) | 2154 | 按现有完整审批类型迁出；AskUser/OutcomeUnknown独立，主题试穿归DesignSystem |
| [NovelCreation/NovelActions.swift](../../iosApp/iosApp/NovelCreation/NovelActions.swift) | 2131 | 拆commands/action/outcome/run contract/creation protocol/error，canonical payload保持 |
| [IOSPermissionModels.swift](../../iosApp/iosApp/IOSPermissionModels.swift) | 2093 | 拆models、有序capability registry与分域静态catalog、execution snapshot、permission store |
| [IOSContextCompactionCoordinator.swift](../../iosApp/iosApp/IOSContextCompactionCoordinator.swift) | 2087 | 拆models、compact store、planner、prepared-context editor、summary codec、token memo |
| [NovelCreation/NovelPromptCatalog.swift](../../iosApp/iosApp/NovelCreation/NovelPromptCatalog.swift) | 2056 | 保留catalog版本入口；分current/historical prompts、contracts、prose normalization；历史版本不删 |
| [IOSWebMountDesktopBackend.swift](../../iosApp/iosApp/IOSWebMountDesktopBackend.swift) | 2003 | 拆models、mapping、pure semantics、adapter；connection/snapshot保持一份 |
| [IOSConversationStore.swift](../../iosApp/iosApp/IOSConversationStore.swift) | 1999 | 保留单writer/persist/importEpoch；拆pure merge/search projection与branch/import职责文件 |
| [IOSSharedSettingsStore.swift](../../iosApp/iosApp/IOSSharedSettingsStore.swift) | 1865 | 保留snapshot/credential事务；分provider、services、agent、local features与patch models |
| [MiniAppRunnerView.swift](../../iosApp/iosApp/MiniAppRunnerView.swift) | 1853 | 保留runner identity；迁system bridge、confirmation owner、AI generation/recovery及management sheet |
| [NovelCreation/NovelLiveModelAdapter.swift](../../iosApp/iosApp/NovelCreation/NovelLiveModelAdapter.swift) | 1821 | 保留activeRuns；拆transport contract、KMP/Responses/discussion/provider实现、mapping/FIFO sink |
| [IOSRecipeFileStore.swift](../../iosApp/iosApp/IOSRecipeFileStore.swift) | 1787 | 按已有owner拆RecipeFileStore、PluginArchiveCodec/Health/DirectoryPolicy/FileStore |
| [ChatToolSupport.swift](../../iosApp/iosApp/ChatToolSupport.swift) | 1781 | 拆 output analysis/cache、approval models/builder、output formatter/budget；runtime不依赖UI命名空间 |
| [NovelCreation/NovelSessionBubble.swift](../../iosApp/iosApp/NovelCreation/NovelSessionBubble.swift) | 1721 | 拆full-text reader、action buttons、AskUser/approval cards；bubble identity和用户WIP保留 |
| [ChatRunKernelAdapter.swift](../../iosApp/iosApp/ChatRunKernelAdapter.swift) | 1686 | 保留 working/snapshotSeq；拆 approval resolver、nested FIFO tool runner、transfer values |
| [IOSGenerativeWidgetParser.swift](../../iosApp/iosApp/IOSGenerativeWidgetParser.swift) | 1652 | 按已有类型拆models、payload detector、parser、chart validator、HTML/resource validator |
| [MessageBubbleView.swift](../../iosApp/iosApp/MessageBubbleView.swift) | 1641 | 保留 bubble；独立 generated image grid/tile/preview 和 user image tile；复用已有 photo writer |
| [IOSSystemPermissionCoordinator.swift](../../iosApp/iosApp/IOSSystemPermissionCoordinator.swift) | 1553 | 保留results/dispatch/preflight；按media/personal-data/system拆SDK实现，延续actor/availability |
| [NovelCreation/NovelInjectionPlanner.swift](../../iosApp/iosApp/NovelCreation/NovelInjectionPlanner.swift) | 1539 | 迁出injection models/panel presentation；保留约1174行planner与原排序/budget/digest |
| [ChatMessageProjection.swift](../../iosApp/iosApp/ChatMessageProjection.swift) | 1537 | 拆 message anchors、基础 projection、Native projection、phone grouping |
| [IOSSearchExecutor.swift](../../iosApp/iosApp/IOSSearchExecutor.swift) | 1502 | 公共URL/DNS策略前置归Networking；拆HTTP transport；原search主体约1150–1250行 |

### 29 个测试文件

逐项行为分组和 fixture 迁移列在 [构建与测试报告](../reviews/2026-10-18-swift-modularization/build-tests.md#29-个超限测试文件的拆分清单)。此处保留完整范围索引，实施时增加旧 test identifier → 新 suite/test identifier 的映射。

| 测试文件 | 行数 |
|---|---:|
| [NovelSessionViewModelTests.swift](../../iosApp/iosAppTests/NovelSessionViewModelTests.swift) | 5713 |
| [IOSLocalToolExecutorTests.swift](../../iosApp/iosAppTests/IOSLocalToolExecutorTests.swift) | 4763 |
| [IOSCouncilRunnerMechanicsTests.swift](../../iosApp/iosAppTests/IOSCouncilRunnerMechanicsTests.swift) | 3752 |
| [IOSRecipeIntegrationTests.swift](../../iosApp/iosAppTests/IOSRecipeIntegrationTests.swift) | 3268 |
| [ChatSwiftUIStreamReplayTests.swift](../../iosApp/iosAppTests/ChatSwiftUIStreamReplayTests.swift) | 3132 |
| [NovelFactTransactionLifecycleTests.swift](../../iosApp/iosAppTests/NovelFactTransactionLifecycleTests.swift) | 2951 |
| [NovelSessionReplayTests.swift](../../iosApp/iosAppTests/NovelSessionReplayTests.swift) | 2803 |
| [NovelGenerationLifecycleTests.swift](../../iosApp/iosAppTests/NovelGenerationLifecycleTests.swift) | 2752 |
| [NovelCollaborationModeTests.swift](../../iosApp/iosAppTests/NovelCollaborationModeTests.swift) | 2660 |
| [ChatMessageProjectionTests.swift](../../iosApp/iosAppTests/ChatMessageProjectionTests.swift) | 2624 |
| [NovelCreationViewModelTests.swift](../../iosApp/iosAppTests/NovelCreationViewModelTests.swift) | 2541 |
| [IOSOrchestrationToolTests.swift](../../iosApp/iosAppTests/IOSOrchestrationToolTests.swift) | 2540 |
| [ChatViewModelSelectedFileContextTests.swift](../../iosApp/iosAppTests/ChatViewModelSelectedFileContextTests.swift) | 2462 |
| [IOSAgentToolEngineTests.swift](../../iosApp/iosAppTests/IOSAgentToolEngineTests.swift) | 2460 |
| [IOSParityRedLightTests.swift](../../iosApp/iosAppTests/IOSParityRedLightTests.swift) | 2181 |
| [PhoneRunnerClientTests.swift](../../iosApp/Packages/AmberPhoneControl/Tests/AmberPhoneControlTests/PhoneRunnerClientTests.swift) | 2098 |
| [IOSWebMountDesktopBackendTests.swift](../../iosApp/iosAppTests/IOSWebMountDesktopBackendTests.swift) | 2010 |
| [IOSChatKernelRunHostTests.swift](../../iosApp/iosAppTests/IOSChatKernelRunHostTests.swift) | 1956 |
| [NovelLiveModelAdapterTests.swift](../../iosApp/iosAppTests/NovelLiveModelAdapterTests.swift) | 1866 |
| [IOSSkillMcpToolsTests.swift](../../iosApp/iosAppTests/IOSSkillMcpToolsTests.swift) | 1838 |
| [NovelContinuityAuditTests.swift](../../iosApp/iosAppTests/NovelContinuityAuditTests.swift) | 1810 |
| [IOSNovelProjectToolExecutorTests.swift](../../iosApp/iosAppTests/IOSNovelProjectToolExecutorTests.swift) | 1653 |
| [IOSJevWebMountLoopTests.swift](../../iosApp/iosAppTests/IOSJevWebMountLoopTests.swift) | 1639 |
| [IOSPhoneGoalLoopTests.swift](../../iosApp/iosAppTests/IOSPhoneGoalLoopTests.swift) | 1632 |
| [NovelManualEditSyncTests.swift](../../iosApp/iosAppTests/NovelManualEditSyncTests.swift) | 1595 |
| [NovelCreationPresentationTests.swift](../../iosApp/iosAppTests/NovelCreationPresentationTests.swift) | 1591 |
| [IOSConversationStoreTests.swift](../../iosApp/iosAppTests/IOSConversationStoreTests.swift) | 1587 |
| [IOSPhoneControlControllerTests.swift](../../iosApp/iosAppTests/IOSPhoneControlControllerTests.swift) | 1577 |
| [NovelGenerationReducerTests.swift](../../iosApp/iosAppTests/NovelGenerationReducerTests.swift) | 1534 |

[全量 952 个文件的行数、分类及拆分索引 CSV](2026-10-18-swift-file-inventory.csv)。本表与报告描述的是审查时工作树；实施前应重新扫描并保留用户期间新增的修改。
