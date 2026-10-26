# Amber macOS 与 iOS 功能差距及 TODO

日期：2026-10-23。对比基线为本仓当前 iOS 实际页面/调用链，以及 `macApp` 正式源码和已打开的 `AmberMacPreview`。本轮推进状态随对应条目更新；证据见 `validation.md`、`review.md` 与 `kmp-validation.md`。

## 范围与结论

明确排除：**小说创作、深度阅读、小应用、WebMount**，以及这些模块专属的入口、设置、数据和执行能力。普通聊天里的文件、Workspace、工具审批和产物仍属于本次范围。

当前 Mac 源码已接结构化消息、分支操作、多模型、原共享 Agent 工具循环、审批、MCP、知识与文件、任务、协作、Recipe、备份与 WebDAV。Preview 使用内存会话，并明确标记不可用的真实 provider/catalog/OAuth 边界；Settings 已复用正式编辑器。不能以源码存在或隔离测试通过直接宣布产品完成。

正式 Mac Shared.framework 构建/链接仍受 Gradle 本地 socket 环境限制；真实 provider、Keychain/OAuth、系统通知/音频和完整窗口/内容矩阵尚待验证。以下原始清单保留初次审计的差距和验收范围，**当前状态以文末「逐项现状复核」为准**。未新增勾选，原有 MAC-003/004、UI-01 的 Preview 实测结论保留；这不代表正式 Native 全链通过。

### 状态口径

- **基础已有**：存在页面和消费代码；其中窗口/新建/本地示例发送/预览主题已经实测，其余不能一概称为运行通过。
- **源码已接、待闭环**：正式 provider、Keychain、KMP 存储等已有实现，但未完成真实 Mac 构建/系统/网络验收。
- **缺失**：Mac 当前没有相应用户入口和运行时消费。
- **平台适配**：iOS 有此能力，Mac 应使用对应系统能力，不能直接照搬手机 UI 或专用二进制。

## 已有基础，继续补齐而非重写

| 能力 | 当前 Mac 状态 | 仍需补齐 |
| --- | --- | --- |
| 原生窗口/侧栏/菜单 | 基础已有，Preview 已实际打开 | 完整导航、运行归属、窗口尺寸与安全区验收 |
| 新建/切换/置顶/重命名/删除 | 已有代码；新建与示例会话切换已观察 | 时间/条数/运行状态与完整真实持久化验收 |
| 会话搜索 | 标题和消息包含查询后过滤会话列表 | 独立结果、命中片段、高亮与分类 |
| 文本聊天状态 | FIFO、停止、失败重试、切会话归属有实现及隔离单测 | 真实 provider/终态/重启完整链路；正常回答的重生成与分支 |
| Markdown/代码/表格 | 有基础渲染和复制 | 完整列表/引用/公式/高亮/图片与流式渲染体验 |
| 附件 | UTF-8 文本；单个 1 MB、总计 2 MB、最多 8 个 | 图片、文档解析、Workspace 关联、桌面拖放与粘贴 |
| 导入导出 | Preview 使用 Mac v1 envelope；正式源码已接原始 KMP JSON 与旧 v1 兼容 | 正式跨语言运行验收、可阅读的 Markdown/PDF、完整跨端备份迁移 |
| 模型配置 | 正式源码有 OpenAI-compatible/Claude，按服务商手填一个 model ID | 真机运行、模型目录/能力、更多协议与 OAuth |
| 外观/快捷键 | 三档明暗模式、少量菜单快捷键已有 | 字体/主题体系、按功能的键盘与焦点设计 |

## 第一批：先使真实桌面聊天成立（P0）

- [ ] **MAC-001 · 正式构建与真实聊天闭环**。产出正式 `Amber.app`，验证 Mac `Shared.framework`、Swift 头文件与动态链接、Keychain、重启持久化；真实 KMP OpenAI/Claude 请求覆盖成功、错误、停止和重试。验收：退出重开后配置和消息存在，当前打开的窗口可以使用真实服务商，不靠 Preview 示例回复。依赖：正常构建环境。证据：`macApp/project.yml`、`DesktopLiveWorkspace.swift`、`DesktopProvider.swift`、`DesktopConversationStorage.swift`。

- [ ] **MAC-002 · 恢复结构化消息契约**。初版纯文本 DTO 已改为完整 KMP canonical JSON 与派生展示；源码保留完整 parts、工具参数/结果、metadata、usage、节点与隐藏变体，流式消息身份统一，旧 v1/raw JSON 导入和保存失败后备份已接线。13项实际 Kotlin/JVM 测试和 Swift 传递/真实 serializer fixture 测试通过，并做独立 review；正式 Native provider→Swift→存储→重开的集成仍未通过，故保持待验收。媒体/工具控件与分支操作分别在后续条目实现，不因保留数据而算作完成。证据：`message-contract.md`、`DesktopModels.swift`、`desktop-shared/.../DesktopBridge.kt`。依赖：先于工具、多模态、分支和跨端迁移。

- [x] **MAC-003 · 定位并修复聊天顶部遮挡**。根因为 Preview 顶部说明条与 `NavigationSplitView` 的组合造成重复材料覆盖区；说明条移到窗口底部 footer，正文、滚动与正式 App 根结构未加补偿。浅深色、空/短会话、长会话滚顶/滚底已实际检查，并由独立子代理复拍确认首条身份和末段完整、输入器不被覆盖。860pt最小宽度仍归UI-10待验，未冒充全窗口矩阵通过。

- [x] **MAC-004 · 修正跨会话运行的操作归属**。停止仅在当前生成的owner会话显示；其它会话显示“查看生成中的会话”，侧栏标记同一owner。状态机断言及独立源码review通过；实际本地示例流由作者和独立评审分别完成生成→切会话→返回原任务→停止，partial保留、运行标记消失、可重试。保持现有单运行能力；真实KMP请求取消仍在MAC-001待验。证据：`DesktopComposer.swift`、`DesktopWorkspace.isSelectedConversationGenerating`、`validation.md`、`review.md`。

- [ ] **MAC-005 · 确定桌面信息架构与真实状态**。围绕聊天、Workspace、执行任务、模型/工具配置建立稳定入口；标题、模型选择和运行状态明确分工。不要一次放入尚未接线的入口。验收：从入口到页面、持久化与消费完整，不再把多个不同用途塞进一个模型下拉或全局设置面板。

## 第二批：补齐日常聊天与模型（P1）

| TODO | iOS 当前能力/证据 | Mac 差距与验收 |
| --- | --- | --- |
| [ ] MAC-006 消息编辑/删除 | 生产聊天消息菜单与 `ChatConversationMutations` 有消息级修改链路 | 当前只有复制和失败/停止后的重试。补编辑重发、删除及其后续上下文语义，重开结果一致 |
| [ ] MAC-007 正常重生成与版本/分支 | iOS 按 MessageNode 变体与选中分支工作 | 当前成功回答不能重生成，线性 DTO 无法选版本。补正常回答重生成、版本切换、当前分支持久化，不覆盖原回答 |
| [ ] MAC-008 上下文管理 | `ChatContextSupport`、`ChatContextSnapshot`、context compaction 与聊天回顾链路 | 当前基本将历史直接交给 provider。补上下文占用/预算、压缩与回顾；长会话不靠服务商报长度错误收口 |
| [ ] MAC-009 模型目录 | `ProvidersView` / `ProviderDetailView` / `ComposerModelPicker`：预设、获取/手填、同服务商多个模型与分组 | 当前一条服务商记录只有一个 modelID。服务商与模型分离，拉取/手填/启停/选择有完整消费 |
| [ ] MAC-010 模型协议与认证 | `ChatProviderConfiguration` 及 Codex/Grok/Gemini resolver 有各自请求与认证路径 | Mac 仅 OpenAI-compatible/Claude。补 Gemini；明确 Responses 模式（Kotlin桥已能表示，Swift enum/UI尚不能选）；OAuth按真实 resolver 分别迁移和验收 |
| [ ] MAC-011 生成参数与覆盖 | iOS 有 reasoning、model 参数、headers/body 覆盖及运行时配置桥 | Mac bridge 仅以 modelID 构建默认 params。补实际支持的推理等级/参数/请求头与单次或模型覆盖，设置必须进入真实请求 |
| [ ] MAC-012 辅助模型 | `ModelDefaultsView`：视觉、标题、建议、压缩、生图模型 | Mac 只有一个当前 modelID 与全局 system prompt。补每项辅助任务选择与运行消费，不能只做选择器 |
| [ ] MAC-013 搜索体验 | iOS `SearchView` 有会话/消息分类、命中摘要/高亮和最近会话 | Mac 仅过滤列表。补结果页与摘要；注意 iOS 当前点结果只打开会话，并未接到具体消息锚点，精准定位不能误记为既有 parity |
| [ ] MAC-014 会话列表与任务状态 | iOS `ConversationSummaryRow` / ActivityCenter 有时间、条数、继续任务等展示 | Mac 仅标题+最后原文，Markdown 标记会泄露到摘要。补干净摘要、时间/条数、生成/失败/未读状态与可见归属 |
| [ ] MAC-015 Markdown 阅读能力 | iOS 默认聊天使用专门 Markdown/公式/代码渲染与流式稳定布局 | Mac 为轻量块解析+Text：补结构化列表/引用、代码语法高亮、公式与图片；表格列宽/对齐/长单元格和流式排版需真实截图回归 |
| [ ] MAC-016 图片输入与视觉回退 | `ChatViewAttachmentImport`、图片编码/预览、视觉模型选择与请求准备 | Mac 无图片 parts、缩略图/查看器、视觉 fallback。补图片导入/预览/移除→请求→持久化；桌面以拖放/粘贴/文件选择为主 |
| [ ] MAC-017 文档与文件上下文 | `DocumentAccessStore` 与 Workspace：PDF/DOCX/文本等导入/解析/预览及授权 | Mac 只接受小型 UTF-8 文本且直接拼进prompt。补解析、预览、来源/范围与失败反馈；与授权文件和Workspace关联 |
| [ ] MAC-018 系统语音与图片生成 | iOS 系统语音试听/速度已接播放器；普通聊天有图片生成模型与产物链路 | Mac 无对应系统语音设置或生成图片流程。分别完成配置→请求→播放/预览→结果保存；不把 iOS 自身未闭环的云 TTS 算为桌面落后 |
| [ ] MAC-019 阅读/分享导出 | iOS `IOSConversationExporter` 实际有 Markdown/PDF 导出，消息菜单接系统分享/分享为图片 | Mac仅自有JSON和文本复制。补当前会话/选定消息的可阅读导出与分享，正文与图片/工具摘要、分支一致；源JSON继续用于迁移 |
| [ ] MAC-037 生成中追加指令/队列 | iOS `ChatConversationMutations.sendMessage` 可 enqueueSteerMessage，composer有队列条 | Mac生成时全局拦截新发送。补当前任务追加指令/排队与撤回，按原run消费，禁止串会话 |
| [ ] MAC-038 回顾与下一步建议 | iOS 会话回顾面板、RecapGenerator和输入器建议有消费入口 | Mac没有回顾/建议卡。生成后能查看回顾、沿建议继续；来源与当前分支一致 |
| [ ] MAC-039 长历史加载 | iOS 默认NativeChatTimelineView有加载更早消息的路径 | Mac启动loadAll加载所有会话正文，单会话也用完整数组。先做summary列表与按需读会话，再按实测需要分页；大量会话与长历史下启动和滚动保持可用 |

桌面专属增强单列：拖放文件/图片、剪贴板图片、多窗口/选项卡、会话内查找、Esc/Tab/快捷键与焦点恢复。这些是桌面使用方式的适配，不一律写成“iOS 已有”。

## 第三批：让桌面具备 Amber Agent 主干（P1）

| TODO | iOS 当前真实主干 | Mac 差距与验收 |
| --- | --- | --- |
| [ ] MAC-020 Agent 工具循环 | 请求构造→ChatKernelRunHost→ChatRunKernelAdapter→IOSAgentToolEngine→工具执行→结果回填→续轮 | Mac直接provider.start，params无工具定义；没有发现/调用/回填循环。先选少量工具跑通多轮，不先堆完整工具目录 |
| [ ] MAC-021 权限与批准 | `ToolPermissionsView`、权限store、approval cards与拒绝/中断记录 | 无能力开关/批准队列/执行范围/工具记录。验收批准执行、拒绝不执行、取消不续跑、旧批准不作用新run，均回原会话 |
| [ ] MAC-022 搜索工具与引用 | 搜索服务配置→IOSSearchToolDispatch→搜索执行与聊天结果 | 缺联网搜索、服务商配置、结果引用与失败状态。与MCP/浏览器分开，排除WebMount不等于排除联网搜索 |
| [ ] MAC-023 MCP | 服务器添加/导入、HTTP/SSE、工具发现/开关、凭证与真实runtime消费 | 无MCP管理或调用。验收连接→发现→启停→批准→调用→结果回填；凭证不进入导出/日志 |
| [ ] MAC-024 Skills | `SkillsView`、本地skill store、启停/编辑、角色默认skill与运行时注入 | 缺技能文件/选择/启停及消费。验收启用影响真实请求，修改和移除后不残留旧注入 |
| [ ] MAC-025 灵魂与长期记忆 | memory overview/records、检索/提取/整合、记忆工具与soul service | 缺记忆管理、检索、写入/删除批准、污染/来源处理及真正的跨会话作用；单个system prompt不能替代 |
| [ ] MAC-026 Workspace | 文件库、解析/预览/重解析、生成产物、工具读写与聊天引用 | 缺文件/产物导航、存储与授权的完整owner。验收导入→聊天引用→工具写结果→预览/导出全链路 |
| [ ] MAC-027 产物架与结果定位 | `ChatArtifactShelfPanel` 等普通聊天产物固定、来源定位/导出 | 缺从对话提取/固定结果、文件/文档预览与来源关系；与被排除的小应用runtime分开 |
| [ ] MAC-028 执行与任务工作台 | 运行环境、SSH/terminal、任务记录与执行状态入口 | 缺执行环境选择、终端/文件操作、审批与任务状态。Mac使用原生进程/受控目录/SSH；不搬iOS iSH/Python二进制 |

依赖：MAC-002 是 MAC-020/016/017/027 的数据前提；MAC-020 与 MAC-021 先于外部有副作用的 MCP/执行工具。没有正式构建与真实provider，不能靠更多Preview页面关闭本批任务。

## 第四批：扩展能力与数据可持续性（P2）

- [ ] **MAC-029 子代理**：补角色、提示词/模型/工具与技能配置、并发/超时、运行进度、独立会话与结果回原会话；不要只加一个“分工”按钮。
- [ ] **MAC-030 模型议会**：补席位/模型、讨论流程、启动/取消/状态、讨论记录与结论；共享 runner 存在也必须接桌面页面与存储。
- [ ] **MAC-031 Recipe/插件扩展**：补导入/配置、发现/启停、执行/批准、失败/运行记录与产物链路，继承 iOS 现有边界。
- [ ] **MAC-032 运行生命周期**：补App级任务owner、任务列表、完成/失败通知、退出确认/恢复、窗口关闭后任务归属。Mac以进程与窗口生命周期设计，不复制Live Activity卡片。
- [ ] **MAC-033 备份同步与迁移**：iOS有加密备份、目录/WebDAV/CloudKit入口及冲突/恢复预览；Mac无相应数据设置，当前自有会话JSON也不能称为跨端迁移。先保证结构化数据无损往返，再做同步策略。
- [ ] **MAC-034 存储管理**：补文件数量/用量、会话与附件清理、失败恢复、子任务记录归属；避免普通删除之外全无可见数据管理。
- [ ] **MAC-035 显示与偏好**：iOS已有字体/字号、Agent名、思考默认展开、跟随生成和主题等；Mac只有明暗/提示词。逐项接入真实消费者，保留可读预览；不为触觉/手机岛动画制造桌面设置。
- [ ] **MAC-036 个人资料/语言/订阅边界**：核对昵称/头像、本机Apple账户绑定、多语言与StoreKit相关行为。它们不应抢占聊天和Agent主干的优先级，也不把本机Apple绑定写成已存在的云端账号同步。

## 设计与完成度专项 TODO

以下是当前 Mac 实拍或源码可确认的问题/不足。默认浅色截图中正文与输入框左右边缘已经基本一致，这一点保留。

| TODO | 具体问题 | 最小完成标准 |
| --- | --- | --- |
| [x] UI-01 顶部内容区域 | 上述MAC-003已定位并修复 | 已通过实际浅深/空短长会话与独立复拍；完整最小宽矩阵见UI-10 |
| [ ] UI-02 标题与模型分工 | 顶栏同时承载长会话名与长provider/model文本，信息互抢 | 会话名为主标题；模型独立紧凑入口，全文tooltip/弹层保留；窄窗不互挤 |
| [ ] UI-03 侧栏信息质量 | 摘要直接显示`##`、表格/代码标记；缺时间、条数、任务状态 | 单行可读摘要+少量状态，正文与元信息权重明确 |
| [ ] UI-04 消息操作层 | 普通回答只有复制；缺正常重生成、编辑/分支及模型/耗时等上下文 | 悬停/选中出现适量操作，操作可访问且有状态，避免所有按钮常驻挤正文 |
| [ ] UI-05 输入区比例与能力 | 空白输入框偏大，只有附件与发送；缺当前上下文/推理/工具等入口 | 空态紧凑、随输入增长；能力按需展开，任务归属清晰，不做一排无效按钮 |
| [ ] UI-06 阅读排版 | 简易Markdown弱化了列表/引用/公式/代码层次，表格偏通用Grid | 用真实中文、长代码、长表格、数学/引用逐类验证；保持内容宽度与视觉节奏 |
| [ ] UI-07 颜色与品牌层次 | 暖灰底有复用，但顶栏、侧栏、正文深色面色与强调色整体感不足 | 统一背景/表面/边框/文字层级和用户/助手身份表达，沿Amber现有设计而非叠更多装饰 |
| [ ] UI-08 状态与错误 | 切会话运行归属、加载/失败/中断/等待批准等还没有完整统一表达 | 每种状态能看懂下一步，行内与任务入口对应；错误可重试/定位原会话 |
| [ ] UI-09 设置与导航 | Preview仅演示外观/提示词，正式设置只有服务商/通用，功能分类缺位 | 模型/工具/记忆/执行/数据设置有完整入口与消费者；未实现项不冒充可用 |
| [ ] UI-11 设置编辑状态 | 已修保存/放弃/取消、编辑清提示、保存后启用和Tab返回不重载草稿；6项设置测试及正式View类型检查通过，独立源码review通过 | 正式服务商编辑器与真实Keychain交互仍待运行；Preview设置不包含该编辑器，不能替代验收 |
| [ ] UI-10 桌面验收 | 已看默认浅/深窗和Preview设置，缺最小/宽窗/长内容/真实流式/键盘完整验收 | 建固定场景清单，逐个实际窗口检查、子代理review、只修确认问题 |

## 逐项现状复核（2026-10-23，39 MAC + 11 UI）

本节更新每个原 ID 的实际状态，不扩大范围。`已接`表示可见入口、持久化/状态与运行时消费者可从源码追到；不等于正式 Native、真实服务商或系统行为已经验收。其余原始验收条件继续有效。新补齐中的项目，只有实际消费者和受影响验证落地后才改为已接。

本轮缺口补齐增量：模型 headers/body/视觉能力兼容与 TTS 6 项播放器消费测试合计相关 50/0（`/tmp/amber-mac-model-speech-tests.log`）；真实 SDK 的 AVSpeech backend 与完整 Settings/MCP/WebDAV/存储 View + 当前纯 Runtime Swift6 typecheck 通过（`/tmp/amber-mac-phase8-sync-settings-typecheck.log`）。KMP 模型覆盖实际消费所在 suite 82/0（`/tmp/amber-kmp-overrides-check.log`）。生图原 repository fixtures 6/0（`/tmp/amber-image-generation-tests.log`），队列/持久/transcript 15/0（`/tmp/amber-workspace-queue-tests.log`）。它们证明具体边界的行为，不证明音频已听到、真实外网生成成功或正式 Native 已链接。

最终整套验证：2026-10-23 20:36:45 CST（UTC+08:00），当前实际源码 **227 项 Swift tests / 0 失败**（`/tmp/amber-mac-all-runtime-delivery.log`）；包含真实 Workspace 视觉模型/provider/key、标题原 owner 持久化/手动改名保护及重试时旧错误精准清理、搜索凭证、队列保存失败重试，以及生图新增 2 项状态序列回归（500 后改为缺失模型不增加网络请求、busy 时保留原 run 状态）。此前 20:27:15 的 225/0 checkpoint（`/tmp/amber-mac-all-runtime-final.log`）及分块测试不与 227 重复相加。KMP 最新 **82/0**（`/tmp/amber-kmp-overrides-check.log`）。标题菜单、搜索设置 sheet、Live 生图启用/原 owner 文件链/备份与删除/退出，以及同实例消息朗读与 Settings 试听均已核对源码消费者；独立 review 当前没有未修的确定逻辑缺陷。新 860pt 离屏实测确认「审批卡 + 3 条队列」曾裁切停止按钮，现已精准改为两个 popover，未增加最小高度；最终复拍仍在进行。正式 Native、锁屏后的整窗矩阵、真实音频/系统权限/外网以及下列高级功能差距继续保留。

共同证据：`macApp/AmberMac/Runtime/` 与 `UI/` 当前源码；KMP 契约证据见 `message-contract.md` / `kmp-validation.md`。模型/目录/OAuth/协作/通知相关 41 项实际源码隔离测试为 0 失败（`/tmp/amber-mac-model-collab-notification-tests.log`：10 ModelSettings、3 Catalog、4 OAuth、12 Collaboration、6 Notification、6 RuntimeSettings）。存储扫描 3 项真实临时目录测试通过；MCP 8 + WebDAV 6 项通过。以上不能代替真实 Keychain、OAuth 网络、系统音频/通知或正式 Native 构建。最新 UI 实拍仍由独立 reviewer 逐项确认。

| 原 ID | 当前实现与消费者证据 | 仍缺 / 待验 |
| --- | --- | --- |
| MAC-001 | `DesktopLiveWorkspace`、`DesktopProvider`、canonical storage 与实际 Agent provider 已接。 | 正式 Shared.framework/Swift header/链接、Keychain、重开及真实各 provider 成功/错误/停止/重试均未验收。 |
| MAC-002 | canonical parts/metadata/usage/隐藏变体、流式身份与 raw/旧 v1 保存/导入已接；Kotlin/JVM 和 Swift serializer fixture 已验。 | Native provider→Swift→存储→重开的实际往返尚未验收；数据保留不代表各媒体控件都完成。 |
| MAC-003 | 已勾选的顶部遮挡修复保持；浅深、空短长滚顶/滚底有作者和独立 reviewer 的 Preview 实拍。 | 最小宽度/完整窗口矩阵仍在 UI-10；正式 Native 未验。 |
| MAC-004 | 已勾选的 owner 停止/查看原运行会话有本地流实拍和独立 review，partial/重试保留。 | 真实 KMP 取消仍在 MAC-001，不把 Preview 当网络取消证据。 |
| MAC-005 | 聊天、Workspace、任务、知识、协作、Recipe、模型/MCP/同步设置有实际入口和分工。 | 全部入口在最小/宽窗、真实数据/网络下的导航闭环尚待验。 |
| MAC-006 | `DesktopWorkspace` canonical 编辑/删除 + `DesktopTranscript` 菜单已消费；变体/失败回滚测试已跑。 | 正式存储重开、删除后真实请求上下文仍待 Native 验证。 |
| MAC-007 | 正常重生成、隐藏变体、选中版本与 KMP MessageNode 变更/保存已接。 | 真实 provider→选版本→重开的 Native 往返待验。 |
| MAC-008 | context 占用/预算、当前 branch 来源、压缩结果与后续请求消费已接；回顾单独展示。 | 真实长会话、服务商长度边界/能力与完整上下文 UI 待验。 |
| MAC-009 | 多模型独立 UUID、legacy 迁移立即落盘，目录合并保 alias/参数；手填/启停/toolbar 选择及视觉能力覆盖已消费。 | 真实目录与 Keychain 未验，不能只按模型数量验收。 |
| MAC-010 | OpenAI/Responses/Claude/Gemini 已接；复用 Codex 设备码/refresh 与已有 Antigravity token resolver；认证与协议独立。 | 各协议真实网络、OAuth/Keychain 待验；无新 Antigravity 假登录入口，也未实现 Grok OAuth。 |
| MAC-011 | context/temperature/maxOutput/reasoning 及自定义 headers/body JSON 已由模型编辑→校验→持久化→KMP params 消费；旧多模型缺新字段能重开，invalid JSON/header 不覆盖凭证。 | 当前没有单次覆盖入口；真实各协议请求/预览仍待正式 Native，不用 JVM 参数测试冒充网络。 |
| MAC-012 | 六角色（回顾/建议/压缩/视觉/标题/生图）模型 UUID 选择与清理已接，生图只认显式选择；Workspace 视觉 provider/key、标题原 owner 持久化与手动改名保护均有实际 consumer 测试，标题菜单已接。 | 真实网络与各辅助模型结果仍待 Native；未以选择器代替消费者验收。 |
| MAC-013 | summary 标题/消息片段、分类去重、高亮、异步失败状态与会话 focus 请求已接。 | 磁盘大库搜索和焦点真实窗口待验；不把 iOS 本来没有的精确消息锚点写成既有 parity。 |
| MAC-014 | `DesktopConversationPresentation` 清洗摘要、时间/条数，sidebar owner 运行标记已接。 | 全部失败/恢复/未读状态及长文本深浅截图仍待验。 |
| MAC-015 | Markdown AST 列表/引用/表格、代码高亮、iosMath、图片有真实 renderer；表格对齐有精准修复。 | 最新中文/长代码/长表格/数学/图片与流式完整截图矩阵未完成，parser 测试不替代视觉。 |
| MAC-016 | 文件/拖放/粘贴图片、缩略/查看器、原图片 parts 与 canonical 消息保存已接；模型自动/支持/仅文本能力、显式视觉 fallback→Workspace 实际 provider/key 消费已测且不改聊天选择。 | 真实图片 provider、原 owner 的完整屏幕交互和正式存储重开仍待 Native。 |
| MAC-017 | 文档实际解析、来源/范围、失败反馈、Workspace 本地副本/引用/预览已接。 | 各格式/OCR/系统文件权限和重解析完整矩阵待验，不再仅 UTF-8 拼接。 |
| MAC-018 | 已接系统声音/语速持久、Settings 试听、消息正文朗读/停止；唯一 player 以 request/utterance 身份拒绝迟到回调。生图显式辅助模型→原 iOS repository→原 owner Workspace 文件与预览 sheet、Live 启用/备份删除/退出已核，取消/多图回滚有 6 fixtures。 | 系统音频未实际听验；生图真实 provider/OAuth POST与屏幕结果未外网实测，正式 Native 未验。iOS 云 TTS 未闭环不算 Mac 缺口。 |
| MAC-019 | 当前分支 Markdown/PDF writer、图片与工具摘要、Workspace 导出动作已接。 | 最新媒体/PDF 回归与真实导出视觉待验；选定消息导出/系统分享完整 parity 未确认，JSON 另属迁移。 |
| MAC-020 | `DesktopAgentProvider` 复用原 `IOSAgentToolEngine`，schema→批准/执行→tool result/transcript→续轮已接。 | 正式 Native 真实 provider 工具多轮待验；无工具 old start 仅供辅助/协作，不用它证明 Agent。 |
| MAC-021 | run/tool 审批、拒绝/取消、能力开关、durable task 与 outcome-unknown 恢复、原 owner UI 已接。 | 真实副作用工具、旧批准不串新 run、进程/网络取消与续轮待验。 |
| MAC-022 | search_web/scrape 复用原 `IOSSearchExecutor`、公开 HTTP transport 与工具回填；`DesktopSearchSettings` 服务/数量/独立 Keychain→实际请求快照有 consumer 测试，设置 sheet 已接。 | 真实搜索、引用显示与失败状态完整验收仍缺，隔离凭证实现不代替系统 Keychain/外网。 |
| MAC-023 | MCP 管理页/Store/Manager：HTTP/SSE/stdio、导入/连接/发现/启停/工具开关、独立凭证与 registry 消费已接。 | 8 项受影响测试不代替真实外部 server、Keychain 和完整 transport Native 握手/取消验收。 |
| MAC-024 | skill 导入/启停/编辑、启用内容进入真实请求上下文已接，修改/移除后不读旧注入。 | 角色默认 Skill/子代理每角色 Skill 未等同完成；真实 provider 与长 skill UI 待验。 |
| MAC-025 | SOUL、跨会话本地记忆与来源、检索、受批准写入/删除工具及请求注入已接。 | 自动提取/整合全 parity 未确认，真实多会话污染/来源及 Native 端到端待验。 |
| MAC-026 | 会话 owner 文件库、导入/解析/预览/导出、上下文引用与工具受控读写，输出保存原会话已接。 | 正式 provider 读写→回填→重开及全部格式/权限待验。 |
| MAC-027 | 消息/协作/Recipe 输出可存 Workspace 文件、预览/导出，有原 owner 和结构结果路径。 | 独立 pin/unpin 产物架、固定产物→原消息定位的完整 parity 未确认，不能用文件列表替代。 |
| MAC-028 | 原生本地进程/受控目录、审批、日志/取消/重开状态和工作台已有。 | SSH/执行环境选择未实现；真实进程组取消和 formal Agent terminal 续轮仍待验，不搬 iOS 专用二进制。 |
| MAC-029 | 角色/提示词/模型、全局并发/超时/取消、原 parent 结果保存、durable runs 与重开中断不重放已接；12 tests/review 已过。 | 仍是无工具文本子调用，缺独立子会话和每角色工具/Skill；真实 provider/完整新 UI 待验。 |
| MAC-030 | 席位/模型、各席真实输出→综合、partial/失败/取消、原 parent 与持久记录已接。 | 当前一轮独立观点+综合，未含 iOS freeChat/debate/research 多轮/动态席位全模式；网络与截图待验。 |
| MAC-031 | 固定 Recipe JSON 导入/启停、bindings、注册工具执行/批准、失败停止/取消、记录和产物已接。 | 通用插件/远程脚本 manifest 不等于已实现；不新造任意脚本容器，完整 Native 执行待验。 |
| MAC-032 | App owner、退出 flush/确认、任务/协作持久恢复不重放、默认关闭通知、落盘成功才按原 run/parent 发聚合通知已接。 | 系统授权/投递/通知点击 owner、关窗/退出真实证据待验；隔离通知6+协作通知2不证明系统送达。 |
| MAC-033 | Mac 加密 archive/预览/copy-import 新 UUID/回滚与 WebDAV 真上传/下载/删除，remote 强制加密已接。 | Mac 格式不是 iOS 全量备份互导/CloudKit/自动冲突同步；真实远端与 Native canonical 往返待验。 |
| MAC-034 | async 实际目录字节/文件数/分区与明确内存/未测说明、会话/文件删除/备份入口已接；scanner3通过。 | 正式 AppSupport 全量统计、附件删除恢复与新 UI 待验；无总清空/自创缓存系统。 |
| MAC-035 | 字体三档/12–22字号/称呼/昵称/思考默认/底部跟随/明暗已持久；Transcript/Markdown/scroll 真消费，重开测试通过。 | 新 binary 完整字体/宽度/深浅/长内容实拍待验。 |
| MAC-036 | 昵称/助手称呼由消息身份真实消费。 | 中文单语；无头像/Apple绑定/Mac StoreKit。iOS SKU 属 iOS 私有 CloudKit 权益，不可假作 Mac 订阅/云账户，不加无消费者 picker。 |
| MAC-037 | 已接原 owner/run 队列、边界消费/落盘 ack、撤回为草稿、失败/取消保留与 awaitingSave 重试不重发；最终整套包含 7 queue tests，含保存失败后重试不重发。 | 队列 UI 三态新二进制与真实 provider/tool 边界待验；附件不会假装支持 steer。 |
| MAC-038 | 回顾/建议生成、辅助模型、branch 来源校验、结果卡与建议回填已消费。 | 真实结果、分支切换、卡片完整截图待验。 |
| MAC-039 | 启动仅 summary、按需读取会话与搜索已接，避免启动 loadAll 正文。 | 单会话仍完整数组/LazyVStack；真实大量会话/长历史内存与滚动未测，未据实测决定分页。 |

| 原 ID | 当前状态与证据 | 仍待验证 |
| --- | --- | --- |
| UI-01 | 已勾选的顶部内容修复与独立 Preview 复拍保留。 | 最小宽完整矩阵在 UI-10。 |
| UI-02 | 紧凑独立模型 Menu、主会话标题和全文 tooltip 已接。 | 最小/宽窗长中文模型名不互挤的实拍。 |
| UI-03 | 干净摘要/时间/条数与 owner 标记；presentation 测试已有。 | 长摘要、失败/恢复/未读及深浅实拍。 |
| UI-04 | 编辑/删除/重生成/版本菜单、复制、可访问标签和禁用语义已接。 | 元信息、所有菜单键盘/窄窗实拍；不以菜单存在完成交互验收。 |
| UI-05 | 紧凑增长输入器、图片/文件、Workspace/context/tools、原 owner 停止与追加队列三态已接。 | 队列/撤回、长输入/键盘/全部状态新二进制矩阵。 |
| UI-06 | 真实 AST/列表/引用/代码/公式/图片与表格修复已接。 | 最新逐类截图和流式尺寸/对齐验证。 |
| UI-07 | 沿 DesktopTheme 暖色系统统一表面/边框/文字/身份，部分深浅已观察。 | 全部新页面/禁用/错误/选中/宽度视觉矩阵。 |
| UI-08 | owner 跳转、加载/失败/中断/审批/不重放恢复、局部错误与任务入口已接。 | 真实 provider/tool/system 终态与最新 UI 的对应下一步。 |
| UI-09 | Preview 已复用实际 SettingsView 四 tab；知识/任务/文件/协作/Recipe/备份/存储、搜索 sheet/同实例朗读/生图/标题菜单和辅助六角色已有实际消费者入口。 | 新功能状态实拍与实际系统凭证/网络待验。 |
| UI-10 | 顶部/跨会话本地流已独立复拍；统一新 Preview binary 已构建。 | 当前 Mac 锁屏使新复拍挂起；默认/最小/宽窗、长内容/真实流式/键盘完整场景未全部执行。 |
| UI-11 | 正式编辑器现复用于 Preview；provider/model/参数/key 草稿、跨 provider/tab 保存/放弃/取消、目录取消/login-first/删除已测试和 review。 | Keychain/OAuth/provider 请求及最新 Settings 完整实拍，不用不可用 Preview catalog/auth 证明成功。 |

## 平台差异，不强行复制

- 手机控制：iOS已有专门桥接、授权与任务入口；Mac当前缺失。若纳入桌面产品，需要独立评估设备连接/权限与平台native slice，不能拿iOS模拟器切片链接。列作后续平台迁移项目，不阻塞基础聊天完成。
- 日历、提醒事项、联系人、照片、麦克风、语音、通知等：按Mac实际API和权限接对应能力，而不是照抄iOS权限清单。
- Apple Watch直接配对、Live Activity、AlarmKit、NFC等：属于iPhone能力，不列为Mac通用parity门槛。需要延续的任务通知改用Mac通知/任务列表等合适形式。
- Mac Gateway是iOS连接独立gateway的配对与任务状态功能，不等于当前新Mac App已具备gateway服务端。是否整合应单独决定，不能根据名称算已复用。

## 不应误列为缺失的项目

- iOS `AssistantsView` 当前仍是“只保留一个Amber Assistant”的占位，不把多助手管理列成iOS已完成能力。
- iOS搜索结果现有回调只打开会话，不把精准跳至某条消息写成已存在能力。
- 当前Mac的会话CRUD、基础搜索、基础Markdown、取消/错误重试、Keychain/source provider适配不应重写；应补全真实运行与领域能力。
- 2026-09-24 iPhone展示截图只作为视觉参照，不代表当前源码或所有provider/后台路径已重新跑通。

## 推进顺序与完成口径

1. **正式构建＋结构化消息＋顶部遮挡/运行归属**：先关MAC-001~004，得到可真实使用且数据不丢的聊天基础。
2. **桌面聊天工作区**：补导航、模型目录/参数、消息编辑/分支、多模态/文件、搜索/导出，并用真实长对话验收。
3. **最小Agent闭环**：选择少量搜索/文件工具跑通发现→批准→执行→回填→续轮，再接MCP/skills/记忆。
4. **Workspace/任务与高级编排**：补产物、执行工作台、子代理、模型议会与扩展。
5. **同步/迁移、平台能力与整体打磨**：按已有数据契约推进，不在早期堆更多未接线设置。

补充：可选 Jev 智能上下文选择/预算调度在 iOS 也有实际请求前调用；它属于后置智能调度能力，不应先于普通上下文预算与压缩（MAC-008）推进。

每个TODO关闭时，至少给出相应的UI入口、持久化或状态owner、真实消费者与匹配的验证证据。源码存在、隔离单测、Preview截图和正式产品验收应分别记录。

## 主要源码证据

- iOS导航与设置：`AppShell.swift`、`Navigation/RouterPath.swift`、`Settings/SettingsHomeView.swift`。
- iOS聊天/消息：`Chat/Composer/ChatViewComposer.swift`、`Chat/Composer/ChatViewAttachmentImport.swift`、`Chat/Session/ChatConversationMutations.swift`、`Chat/Rendering/Markdown/ChatAssistantMarkdownView.swift`。
- iOS模型：`ProviderDetailView.swift`、`ComposerModelPicker.swift`、`ModelDefaultsView.swift`、`ChatProviderConfiguration.swift` 与对应resolver。
- iOS Agent：`ChatToolRuntime.swift`、`AgentRuntime/ToolEngine/`、`ToolPermissionsView.swift`、`McpServersView.swift`、`SkillsView.swift`、`SubAgentsView.swift`。
- iOS数据：`Workspace/WorkspaceView.swift`、`Infrastructure/Workspace/IOSWorkspaceStore.swift`、`SyncBackupView.swift`、`ConversationStorageView.swift`、`IOSShareSupport.swift`。
- Mac：`macApp/AmberMac/Runtime/`、`macApp/AmberMac/UI/`、`macApp/Preview/`、`desktop-shared/src/commonMain/kotlin/desktop/DesktopBridge.kt`。
- 视觉：本轮实际Mac Preview窗口与`docs/assets/readme/iphone/`的历史参考截图。截图日期/限制见该目录README。
