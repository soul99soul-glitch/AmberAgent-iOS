# Swift 模块整理执行记录

目标：落实同日审查计划，按职责拆分全部超限 Swift，最终全仓 Git 可见 Swift <=1500 物理行；保持运行、状态归属和持久化契约。分支 `codex/swift-modularization-1500`，初始 HEAD `b98bd6f0f2f82dd9492ff021e53d03bfe26d2dce`。

授权：用户已同意在分支实施，指定全部 subagent 为 `gpt-6-sol` / `high`。未授权提交、推送、合并、发布或删除死代码。

保护：初始所有相关源码、配置和文档已备份到 `/tmp/amber-swift-modularization-baseline-20261018-010059`，含哈希、Git status、staged/unstaged binary patch。重构以当前完整工作树为基线，保留既有改动。

方法：采用 implement、codex-dynamic-workflows；SwiftUI 拆分保留现有观察和身份机制；每批完成后按 code-simplifier 做一次有限审查。原审查与文件映射见 `2026-10-18-swift-modularization-review.md`。

## 分工与集成

- Root：分支与备份、基线及集成构建、所有 project.yml / AGENTS 测试入口 / 跨域源码接线测试、剩余跨域编译修复、结果验收。
- Gate：独立物理行检查、增量存量清单、CI/SwiftLint（只处理本任务相关配置）。
- UI：完整页面/审批类型迁出，随后编辑事务职责拆分。
- Tools：网络 policy / WebMount / tool engine / orchestration / terminal / recipes。
- Chat：渲染/投影，然后 runtime / VM / host / adapter。
- Novel：保留 actor/reducer/repository 的领域及界面拆分。
- Platform：权限/解析/存储/压缩，后台 owner 最后集成。
- Tests：按职责拆29个超限 suite、共享fixture、保持测试标识映射。

并发任务必须有窄文件所有权；不得修改他人负责文件或回滚他人改动。共享配置由 Root 串行集成，不让实现者同时更新 project.yml 或源码字符串接线测试。每个目标文件记录原文件到新职责文件的映射。

用户补充执行契约：先完善计划，严格按 Phase 0→6 顺序实施，全部完成前持续推进。每个 phase 的实现、集成与实际验证完成后，由未参与该 phase 实现的 `gpt-6-sol` / `high` 子 agent 独立检查逻辑闭环、完整调用链和 UI 细节；对有证据的问题精准修复，再复核受影响部分，才进入下一 phase。后续 phase 可以只读准备，不得提前写源码。取消全局 sentinel 放行，以 Root 的明确 phase GO 为准。

## 每个 Phase 的完成门禁

| Phase | 本期实现范围 | 逻辑与构建门禁 | UI 检查与独立 review |
|---|---|---|---|
| 0 | 分支/备份、物理行脚本、迁移清单、SwiftLint、CI；记录原始编译与相关行为基线 | 1500边界/Git可见性/新增超限/存量增长测试通过；80项清单可复现；基线异常明确归因 | 无产品UI改动，视觉不适用；独立review脚本→CI调用链、保护策略及执行计划 |
| 1 | Placeholder/Home/Search/Settings/Workspace完整类型、审批卡、Board/DeepRead UI；terminal/task和recipe/plugin独立类型；对应测试 | 内容/符号迁移对照；更新源码定位及所有共享target；定点Home/Settings/Recipe/Terminal/DeepRead测试与消费者编译 | 320/393宽、普通/辅助功能字号下检查审批按钮对齐/可达、间距边距、首页/Workspace/DeepRead布局；截图或hosting几何证据交独立review |
| 2 | 公共网络policy；WebMount runtime/store/controller/desktop；WebMount UI；对应大测试 | URL→policy→transport、session/run→dispatch→receipt链完整；WK/desktop/takeover/unknown/取消回归；各文件<=1500 | 检查站点列表/站点页面、popup/inspector切换、memory/report sheet、审批短容器与长内容；复用已有layout evidence并检查实际截图 |
| 3 | Chat渲染/投影、Runtime/VM/Host/Adapter、Engine/Orchestration；对应大测试 | 保留Native默认入口、单run owner/FIFO/terminal/CAS/审批/跨会话归属；执行六个滚动测试类（含拆出的 Native replay）及相关工具测试 | 检查长文/表格/图片/工具卡宽度、历史浏览/回底、composer安全区和键盘、动态字号；独立review追完整生产链及布局证据 |
| 4 | Novel全部16个超限生产文件与12个相关大测试（含工具suite） | 同一actor/reducer/repository提交链；candidate/collect、IME、needsSync、终态、恢复与原项目归属；主App与NovelApp编译/测试 | 检查创作/正文/设定、长文气泡、审批→结果、sheet/多字段编辑及大字号；独立review不得以测试stub声称真实provider已验收 |
| 5 | Council、MiniApp、Provider/SSH editor；平台权限/设置/Workspace/Conversation/compaction；最后后台owner | 单writer/凭证事务/权限含义/过期异步结果；基础store稳定后集成background executor/resumer/terminal；对应行为测试和共享消费者构建 | 检查provider编辑/模型发现、SSH信任表单、Council卡片、MiniApp管理/授权、系统设置页面的对齐/溢出/点击尺寸；后台review核对runId所有权 |
| 6 | 剩余测试suite、目录/调用者收口、移除存量清单、严格CI；全产品集成 | 全Git可见Swift<=1500；旧→新测试标识无遗漏；相关主/Novel/DeepRead/GPL/Watch/Widget/package门禁；保留用户WIP | 独立整体review所有phase证据与残留问题；最终UI抽样真实渲染。构建、安装、启动、用户行为、真实provider/设备分别记录 |

UI问题判定必须有当前代码与可观测渲染/几何证据：只修改能定位的错位、裁切、间距、尺寸或身份回归，保留既有设计token和观察机制。没有证据不做通用补偿、额外fallback、重试或新状态机。后端阶段只审受影响消费者，不无关重做全产品视觉。

每期独立review一次（必要修复后只复核受影响点），作为本期有限可维护性审查；Root保存review结论、测试结果包和截图路径。不得以“文件已变短”替代接口、调用链和产品行为验收。

## 当前状态

Phase0–6 已按顺序完成实施、实际门禁和独立运行链/UI审查。最终1318个Git可见Swift全部不超过1500；Main完整5089项为5073通过、0失败、16原跳过，独立Novel完整1048项为1045通过、0失败、3原跳过；DeepRead109/109、Phone SwiftPM105/105、实际导航6/6均通过，GPL/Watch等构建成功。最终联合发现审计无遗漏或重复。各期报告和失败历史保留在同日reviews目录，机器状态见 `2026-10-18-swift-modularization-state.json`。分支未提交、未推送。

Phase5 最终主集成995项（993通过、0失败、2原跳过），MiniApp补丁后定点184/184，实际Provider与Runtime/SSH/MiniApp/Council两条导航各通过。修正后的窄屏Council顶栏与真实AX3权限组件均经截图复核。此前Novel独立全量1048项（1045通过、0失败、3原跳过），Main64项终态/代笔交接定点通过。最终结果以Phase6消费方全量结果为准，不累加重复执行的测试数字。

真实provider、真机、OS权限/后台系统保证与中文IME不由上述模拟器证据替代；按最终交付逐项陈述。

## Phase 2 实施中发现的共享消费者约束

Novel 独立工程的既有显式 source 清单缺少共享 Markdown 已引用的 IntelligentUI 实现，且共享 Engine 直接引用主 App 手机控制单例。原 Markdown/Engine 内容与初始快照一致，属于既有消费者接线缺口。本期为使共享消费者闭环，补齐现有 UI 源、Phone 请求纯策略/catalog；沿 Engine 已有 `phoneSessionIsActive` 注入点，把单例查询留在前台 Adapter 与后台组装处，不引入手机控制 package 到 Novel，也不创建新兼容层。

这次必要接线使尚待 Phase 5 拆分的后台 coordinator 增加 5 行（4949→4954）；迁移清单只对此已证明的接线调整预算，明确记录例外。最终 <=1500 门槛不变，不为保持中途行数删除注释、压缩语句或提前拆后台 owner。增加手机请求策略、handoff、Host 和后台行为验证；Phase 3 source 快照在这次接线完成后刷新。

Novel 的完整 build 还暴露共享媒体清单缺口（MarkdownMedia → Gallery/Video → 共用图片URL/布局），其中共用布局和渲染正是 Phase 3 的职责拆分范围。完整 Novel 构建门禁移到 Phase 3 并设为必过；Phase 2 不以拉入整套主 App 或 stub 隐藏缺口。主 App 与独立 DeepRead 构建、WebMount 链与视觉仍按本期门禁完成。

## 验证约定

先取得基线编译与行为证据，再按批集成。保持完整类型内容与状态身份；只补真实缺口测试。目录迁移同时维护 XcodeGen source membership，拆 suite 同时维护选择器和源码接线断言。最终记录源代码、构建、XCTest、设备/provider 各自结果，不以行数达标替代行为验收。

## Phase 4 具体实施与验收包

此阶段仅在 Phase 3 独立 review 和最后 UI 修复复测闭环后正式 GO。原始 30 文件快照为 `/tmp/amber-phase4-source-baseline`；迁移前的 588 个相关原方法已实际运行，583 passed、4 个既有 fixture failed、1 个原手动采样 skipped。

- Session 状态包：SessionViewModel / Presentation。保留同一 binding token、run identity、pacer/FIFO、终态 drain、consumer detach 和 mutation gate；投影、审批/候选意图、批量润色和代笔执行按变化原因拆分。
- Generation 包：CreationViewModel / GenerationLifecycle / LiveModelAdapter / InjectionPlanner / PromptCatalog。同一个 DefaultNovelCreation actor 和 write lock；activeRuns 与 attempt ID 不分裂；prompt 版本及文本、预算排序和 digest 逐项核对。
- Domain 包：Models / Actions / Validator / FactTransactions / Repository / StructuredOutput。完整值类型搬迁；repository 的提交/授权事务不拆出第二个 writer；receipt/evidence/commit 继续共用 canonical projected state。
- UI 包：SessionView / Sheets / Bubble。滚动、sheet 身份、composer 和 IME field bank/dirty/revision/save task 保持原 owner；仅迁出完整组件和明确输入的 section。
- 两个测试包：12 个超限 suite，347+241 个原方法、全部非测试 helper/type/extension 都须映射。方法正文 SHA、实际 discovery 和一次性执行结果共同核对；继承基类不得意外复制测试。
- 布局测试包：新增少量真实 hosting 的长文气泡/审批/编辑 sheet 可达与尺寸检查，320/393pt 及辅助功能字号截图。Root 另走实际 Home→小说创作→本地空白项目→创作/正文/设定→项目控制，不依赖真实 provider。

Root 单独维护 NovelApp 显式共享 tests source、真实 owner 的源码 guard 和 AGENTS selectors。测试 fixture 中「粮仓/马厩」被既有建议过滤契约隐藏，已证明四项失败和一项空数组拒绝 false-pass；只把 fixture 改为合法持久设定并补实际拒绝证据，保留生产 filter，不放宽断言。集成后执行全部 Novel 行为 suite、主 App/独立 Novel ARM64 构建、必需的 Native 六类滚动门禁，再交两个独立 reviewer 分别核对领域/运行链和 UI/IME 证据。

## Phase 3 closure

Runtime and UI independent reviews passed. All 327 original migrated methods were discovered once (combined326 passed/1 original manual sample skipped); helper audits cover152 non-test declarations. Main r10 retains its full failure history; three Phase3 failures passed focused with unchanged thresholds; four untouched Novel fixture failures move to the Phase4 baseline. Standalone Novel ARM64 build passed. Confirmed empty-chat keyboard/attachment header overlap was repaired at the decoration owner without scroll-driver changes; actual UI navigation passed1/1. Final six mandatory scroll classes passed96/0/1 at original thresholds, result `/tmp/amber-phase3-scroll-overlay.xcresult`. Current migration gate:1150 Swift,48 over1500,0 problems. Phase4 formally GO.

## Phase 5 实施包与顺序

准备快照 `/tmp/amber-phase5-source-baseline` 固定 13 个生产文件和 2 个大测试文件；实施前逐个复核 SHA，不以快照覆盖更新。迁前实际门禁为 719 个唯一用例：基线 687 项中 686 passed、1 原手动采样 skipped，另三个真实 SSH runtime 类 32/32 passed。此阶段仅在 Phase4 最终运行链和 UI review 闭环后由 Root 明确 GO。

| 独立责任包 | 文件与变化原因 | 必须保留的 owner / 事务 |
| --- | --- | --- |
| Editors | ProviderDetailView、RuntimeEnvironmentView、MiniAppRunnerView；完整组件和编辑职责 | Provider credential/header 写入与回滚、模型发现 requestID/frozen auth；SSH draft/probe/trust/persisted snapshot、用户 iSH permission WIP；MiniApp recovery/bridge/confirmation continuation |
| Permissions / Parser | IOSPermissionModels、IOSSystemPermissionCoordinator、IOSGenerativeWidgetParser | 101 个 capability ID 的顺序与语义、unsupported policy WIP；系统请求状态；原校验/清理规则 |
| Storage / Compaction | DocumentAccessStore、IOSContextCompactionCoordinator、IOSConversationStore、IOSSharedSettingsStore | 唯一 writer、writeSequences/importEpoch/restore gate、索引失败回滚；凭证 write-all→rollback→masked JSON/snapshot→旧凭证删除 |
| Council | CouncilChatRuntimeView、CouncilRunner | 单 VM、单 live runner、FIFO/terminal drain、provider route、archive generation、原 AppShell 生命周期 |
| Tests | Council 89 项、ConversationStore 37 项 | 逐方法/全部 helper 映射；零测试基类；Root 统一迁移实际 owner 的源码断言 |
| UI | 两组新 hosting tests 与追加真实导航 | 320/393 × large/AX3；本地 fixture、真实渲染/滚动几何、逐图独立 review；Runtime SSH 等 private sheet 用实际 XCUI 导航 |

新职责文件使用已有邻近目录：Provider/SSH 在 `Settings/Providers` / `Settings/Runtime`，MiniApp 在 `MiniApp`，Council 在 `Council`，权限在 `Infrastructure/Permissions`，设置和存储在 `Infrastructure` / `Chat/Storage` / `Workspace`，压缩在 `Chat/Compaction`。保留现有入口与状态实例，不扩大成全仓目录重排。具体类型名与边界以实际源码和迁移清单为准。

第一批稳定并通过对应 store/Council/permissions/editor 测试后，Root **另行**放行 Background 包。`IOSChatBackgroundGenerationCoordinator` 保留唯一 job/run/system-task registry 与 claim/start/cancel/finish，按具体工作拆 executor、resumer、codec、terminal writer、recovery/projection；不使用万能 context 或第二个后台状态 owner。保持 conversation terminal persist→durable CAS/recoveryPending→activity/Watch→finish/system completion 顺序和原 expiration 例外，以及已注入的 phoneSessionIsActive 查询。

Root 串行维护 XcodeGen、Novel/DeepRead 的显式 source closure、测试源码 guard、baseline 收缩与结果发现核对。实现 worker 不并发构建。主 App 集成、受影响共享消费者、真实页面导航和布局图齐备后，两个未参与本期实现的 reviewer 分别签运行链与 UI；有证据的问题只修所属 owner。Phase5 完成才放行 Phase6 测试余项与严格 gate。

## Phase 4 closure

最终 Main64/64 和独立 NovelTests r4 1045/0/3 原 skipped 通过；独立运行链与 UI review 均签字。28 个原超限文件全部达标，当前1256 Swift、20超限、迁移门禁0问题。1022个独立Novel原方法各执行一次，2个Main-only bridge方法已在Mainr3通过。588个迁移方法与全部helper有明确映射。原失败与真实竞态修复、20张layout图及实际导航证据见phase-4-review。Phase5 primary/UI/source-guard包正式GO，Background继续等待基础stores通过后的单独GO。

## Phase 6 实施包与最终验收

Phase5 独立运行链与 UI review 完成后，Root 明确 GO。剩余仅五个测试文件：PhoneRunnerClient（SwiftPM）、IOSPhoneControlController、IOSPhoneGoalLoop、IOSParityRedLight、IOSSkillMcpTools。保留现有 XCTestCase 类和方法 ID，以同类 extension 按行为拆分；fixture registry、temp directory/teardown 和 actor 所有权各保留一份。不新建含测试方法的继承基类。Phone 包228项与 Parity/Skill99项共327项逐方法、helper、类型与 SHA 映射；Parity沿用 Phase5 已加强的后台 owner 断言，并将旧日志保护断言指向实际 Hotlist/DeepRead owner。

Root 在所有五文件完成后撤销迁移存量清单，让 CI 无条件执行严格物理行门禁。最终验证串行执行：主 App 全部 iosAppTests、独立 Novel 全部 NovelTests、独立 DeepRead 全部 DeepReadTests、GPL App（依赖 Watch/Widget/ActivityWidget/PhoneTunnel）构建、AmberPhoneControl SwiftPM105项、Shared export reachability 和行数脚本四项测试。以最终 xcresult 的实际 discovery 和 SwiftPM 完整 start/end 日志核对原5368项声明及已迁移标识，不把编译成功代替行为结果；原本无 target 的设备 smoke source 单独保留事实说明。主 App 本地导航六项作为最终 UI 抽样，保留数据，不发 provider 请求、不保存凭证或信任未知 SSH 主机。

未改变的消费者复用本期前序证据；构建/安装/启动/页面点击、真实 provider、系统权限及真机触感和后台验收分别陈述。最后恢复 resolver 对 vendor Package.resolved 的任务副作用，检查初始 index/HEAD 与无关 WIP 哈希，并由独立 reviewer 收口运行链、测试发现和 UI。

## Phase 5 closure

运行链和UI独立报告均已签字；源码/截图/实际导航证据与首轮测试设施错误、同值设置保存的边界见 `../reviews/2026-10-18-swift-modularization/phase-5-review.md`。Phase6已正式GO；不保留任何最终文件行数豁免。

## Phase 6 closure

严格门禁最终为1318文件、0超1500、0问题；最大1500、测试最大1490，物理行与SHA清单已封存。五个剩余大测试文件327个原方法全部发现并通过，fixture/helper/type有逐项映射。最终联合审计覆盖原5368项声明与2202次跨target映射观察，无遗漏、重复或membership缺口；16项Main跳过均属于原集合，IUI原生AX及SavedTasks16项实际通过。

全量测试暴露的两处既有Novel夹具时序问题只修就绪依赖与断言：测试显式注入无保护租约，避免其他用例的全局租约干扰，项目快照请求改为既有eventually有界等待；批量润色在真实UI选择门禁开放后切换，并验证选择返回值。原业务断言和生产规则保留。两案在最终Main r6及独立Novel r2均通过；r1–r5失败、挂起和零用例启动历史全部留档。

独立运行链、UI、覆盖和WIP审查均签字。vendor Package.resolved已恢复原HEAD字节，HEAD/index未变；26个原WIP文件逐字节一致，混改路径已核对语义，原CSV缺初始快照的限制保留。全部任务改动留在分支工作区。最终结论与证据入口见 [Phase 6审查](../reviews/2026-10-18-swift-modularization/phase-6-review.md)和[模块导航](../reviews/2026-10-18-swift-modularization/module-guide.md)。真实provider、SSH/系统权限、真机与OS后台保证未由本次模拟器结果替代。
