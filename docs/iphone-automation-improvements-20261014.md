# 手机自动化：速度、观察与可靠流程

## 目标与范围

用户反馈点击慢、Jev 没有明显加速，要求完善计划后连续完成各阶段，每阶段由 subagent 检查逻辑、调用链和 UI，修复确认的问题再继续。

基线：当前工作树，起点 `8a0e6df8`。保留已有三个 Intelligent UI 未提交文件，不修改兄弟产品，不更换控制后端，不新增外设或权限。本轮只复用 Amber 已有的本机 XCTest、Jev、截图、任务 owner、账本及快捷任务入口。提交/推送只在用户授权对象与范围内进行。

完成标准：减少可以证明多余的观察/决策成本；动作结果和业务核验分别可见；读不到原生文字的页面能用截图 OCR；长按与授权 App 内弹窗操作可达；列表读取有覆盖边界；常用任务以新观察和参数执行，失败不重放已完成副作用。每阶段先完成端到端路径，再补实际边界。

## Phase 1：耗时证据与点击主链路

- 核对真实任务记录及当前调用链，分别测观察、选择、动作、复核、界面等待和总体耗时。使用真实链路测试或可观测复现锁定重复成本；没有设备数据时不把受控请求数或测试时间说成真机加速。
- 接通现有 `/wda/settle`，动作后的界面等待有界，并给最后读取预留时间；稳定不等于业务成功。空白/不可读画面明确交回，不重试动作。
- 去除有证据可由当前本地条件确定的重复 Jev 复核；保留模式、数据范围、配置 revision、owner、取消和 unknown 边界。多候选选择继续由 Jev 负责，不为省一次请求放宽操作语义。
- 仅补 NE 启动错误已知的诊断信息缺口，区分本机隧道、初始连接、配对和 runner；纯 5G 根因待实机证据，不猜改选路或增加重连。
- 独立 review：client → tool → GoalLoop → Activity/Ledger，测试与失败路径；相关阶段 UI 的普通/窄屏/辅助字号检查。

验收：受影响 Package/App 测试通过；前后请求数与可复现耗时可比；没有旧引用执行、取消后派发或 unknown 重放；完整源码构建可用。

## Phase 2：观察和操作补强

- 在显式截图观察中增加端侧 Vision OCR，返回文字、置信度和归一化位置，绑定同一 screenshot observation；树、OCR、截图来源保持可辨，OCR 不伪造 ref。低覆盖页面给出明确观察建议，不用一个面积阈值判断所有 App。
- 复用 runner 的长按、授权 App 内弹窗接口，接通模型工具和动作后新观察；弹窗选择使用明确按钮和当时弹窗证据，不自动批准权限。
- 收紧模型观察输出：保留本地完整快照与唯一定位判断，减少重复容器/默认字段；陈旧或截断边界继续报告，不删掉决定正确性的上下文。
- 增加有界列表采集，逐屏新观察、保持顺序、处理重叠、报告覆盖与停止原因；不把未读到的内容宣称完整。
- 独立 review：新工具声明、参数、前后台入口、屏幕坐标、取证、取消、unknown、观察输出；涉及 UI 的文字、布局及实际展示。

验收：OCR 文字与坐标、图标盲区、旧截图失效、长按菜单、连续授权 App 弹窗、重叠列表/无进展/截断均有对应证据；受影响测试通过。

## Phase 3：常用流程与整产品验证

- 沿已有快捷任务入口保存少量参数化语义流程及完成条件，每次从新观察开始，不保存上次 ref/坐标，不新增通用脚本引擎。先选导航、搜索、填写草稿等可验证场景。
- 流程步骤使用页面条件和动作后核验，失败返回已执行步骤与最新证据；人工接手后重新规划，未知结果继续由原账本停止。
- 常用任务 UI 与持久化/运行入口接通；普通宽度、320pt、辅助字号、空/加载/失败/运行态由 subagent 看实际渲染和交互证据。
- 一次有限维护性检查，受影响集成测试、GPL 完整构建与 Runner 构建；有设备时原位安装并测新任务，不重放旧办公消息，不更改其他 VPN 或网络。
- 验证分层报告：源码/测试、模拟器 UI、构建、签名、安装、正常启动、真实 provider、真机操作和网络。设备不可用时继续全部可完成工作，明确保留实际设备验收门槛。

## 执行结果（2026-10-15）

三个 phase 的源码、接线、逐阶段逻辑与 UI review 均已完成。保留原有三个 Intelligent UI WIP 文件，没有把它们纳入本轮提交。设备构建使用当前工作树，因此包含这些原有 WIP；构建输入已单独记录 hash，不把此设备包称为纯提交产物。

### Phase 1：点击成本与可观测性

- `PhoneRunnerClient` 在观察内接通 settle，动作后返回新树；返回客户端阶段耗时、请求数和 Runner 的 timing header，界面稳定与业务成功分别报告。
- `IOSPhoneGoalLoop` 在明确中间页已变化、完成条件未满足且下一步有新候选时，省去单独一次 Jev 远程复核。下一次选择仍可等待、要截图或交回，单候选不自动执行。两步受控导航仍为3次观察、2次动作，远程选择/复核由2+1变为2+0。
- Jev 请求准备不再对增长中的全量数组反复编码；准确计算逐节点字节预算，再编码最终 payload。3321个组合与旧 JSON 逐字节一致。M4 / Swift 6.4 / Release，500节点、30次采样的本地构造中位数从100.077ms降至1.084ms；此数不包含模型、网络和设备操作。
- NE 错误保留阶段、domain/code及实际连接失败的底层原因；超时不使用历史断开原因。不据此宣称修复蜂窝选路或增加自动重连。
- 独立逻辑 review 核对 client → tool → GoalLoop → Activity/Ledger 的取消、owner、旧引用和 unknown 边界；UI review 修正 Jev 缺数据范围时的文案与状态，普通/320pt AX3 实际渲染通过。

验证：受影响 App gate 105项通过；最终 UI 定点1项通过。旧行为→新行为请求数和本地 CPU 测量可复现，未测真机点击加速。

### Phase 2：观察、长按与列表

- `phone_observe` 仅在显式 `include_screen_text` 时运行端侧 Vision OCR。同一次 PNG 的文字、置信度、归一化位置和 screenshotID 一起返回；不伪造原生 ref，不在每次点击中隐式添加 OCR。默认观察不额外截屏。
- `phone_act` 接通元素/截图坐标长按及授权 App 树内弹窗按钮。长按不能退化为普通点击；弹窗比较当时 PID、标题和按钮上下文，旧 Runner 没有 guard 能力时拒绝执行。未扩大到 SpringBoard，不自动批准权限。
- 观察的展示文本去掉无内容普通容器，但完整快照、引用和定位判定保留。
- `phone_collect_list` 逐屏新观察，限制滚动与项目数，报告停止原因与 `observed_screens_only` 覆盖。只有文字一致且两屏均唯一的稳定 identifier 才合并重叠；匿名同名行保留，重复稳定 ID 交回。
- 聊天时间线与详情页区分动作回执、业务核验和待继续/待核对状态。unknown 不再显示成功，320pt AX3 状态后缀完整展示，默认摘要不带输入/OCR正文。
- 独立逻辑 review 找到匿名行误合并后先取得失败证据再修复；独立 UI review 修正错误状态和标题截断，最终6张实际渲染图通过。

验证：Package 85项通过，Runner 真实逻辑回归2项通过，列表生产源码 harness 27项通过，Vision Mac fixture 5项通过；受影响 App gate 联合219项通过，原有 opt-in reasoning 性能采样默认跳过。OCR-only 测试 fixture 的 JSON 解析已修复并定点通过。Runner iPhoneOS build-for-testing 通过；既有音量键 API 不支持模拟器，未改变产品行为迁就测试。

### Phase 3：常用流程与完整入口

- `phone_run_flow` 执行1…12个按序语义步骤，继续执行预算60秒。复用当前候选唯一定位和动作后核验，后一步消费上一动作的新树；不保存旧 ref/坐标，每步动作最多发送一次，不逐步请求 Jev。
- 回执记录已完成步骤、核验、最新观察和耗时。unknown 不补读不重放；handback 沿 `replanRequired` → durable `completed_requires_replan` 收口，阻止同轮后续工具，人工接手后重新规划。
- 常用任务沿现有 quickMessages、参数输入、Watch/Siri 和一次 opaque handoff 保存、运行。仅空的新建任务提供 Notes 搜索示例，已有标题和提示词不被替换，不新增脚本存储层。
- 独立逻辑 review 确认前后台、旧 run 冻结授权、nested exec 排除、owner、取消和持久化 replan barrier 调用链完整。
- UI review 用真实底部提交操作复现错误反馈离屏：保存错误 y=-625、运行错误 y=-1113，滚动位置未变。仅把两种表单原错误项移到主要按钮前，新增断言要求错误完整 frame 位于当前 viewport。修复后的13张图和此前25张普通/320pt AX3任务图已独立复看，全文、间距、对齐和按钮均无剩余 blocker。
- 完成一次限定本轮 diff 的维护性检查：共用语义动作 schema 与校验，移除注册完成后重复特判，没有追加框架或广泛重构。

验证：Flow 生产源码 harness 25项通过；阶段集成190项通过；最后受影响 UI/保存/手机展示/5项 replan Engine gate 35项通过。项目要求的聊天流式重放、NativeTimelineScrollCore、ChatViewportPolicy 已运行通过，opt-in 性能采样除外。

扩大运行整个 Engine 类时，`testForegroundProviderCreateRedactsCanonicalInputAndNextRequest` 在 `ProviderSetting.OpenAI` 取得 nil 而失败。独立运行，以及仅替换为起点 `8a0e6df8` 的 Engine 对照版本，均复现相同失败；不是完整起点工作树的基线测试。Phase 3 仅更改 Engine 的重规划文案，未改 provider 创建行为，不把该项计为通过。后续 DeepSeek 补修改的是能力和思考参数接线，未处理该创建测试。

### 首次构建、设备和保留数据（r2，反馈补修前）

- App GPL Release 构建通过，主 App、Activity、Tunnel、Watch、Watch Widget 五个 bundle 的签名、profile目标设备与运行时 Group 已核对。采用设备当前实际安装的 Experimental Group，未迁移数据 Group。
- 独立 Runner 已构建、签名验证，并与 App 一起在18 Pro原位覆盖安装；没有卸载。
- 安装前后212个偏好键保留，0新增/缺失；6个关键键 hash 全部一致。唯一非关键变化为 Watch sequence。390条会话文件名称、大小、修改时间、resources均一致；6项系统扩展属性变化不等同于正文变化。3项 Group 文件元数据一致。保留数据检查只比较元数据，未比较会话正文或全部 Keychain；后续诊断另在私有目录读取了最新多邻国任务记录。
- App 无参数正常启动成功，随后进程检查确认存活。
- 既有原生一次 readiness 检查通过：Runner signed ready=true/authenticated=true；读取本 App private-ax 新树187节点、budget200、truncated=false；authenticated shutdown accepted；Finished disconnected=true。启动至认证就绪约5.425秒、就绪至树返回约0.252秒、整个检查约5.799秒。这是一次本机连接/只读检查，不包含点击、Jev或新操作。

本轮没有对真实 provider、完整新任务的真机操作、点击端到端耗时、长按菜单、App 弹窗、OCR真机冷启动、蜂窝网络冷启动做验收；源码与测试完成不等于这些体验已通过。Mac 本地 CPU 及受控请求数改善不能直接换算成手机上的点击加速比例。

### 主要入口与证据

入口：`IOSPhoneControlToolCatalog` → `IOSPhoneControlToolExecutor` → `IOSPhoneFlow` / `IOSPhoneGoalLoop` / `IOSPhoneListCollection` → `PhoneRunnerClient` → 本机 Runner；聊天展示由 `ChatPhoneToolPresentation` 与详情页消费回执。参数化任务继续使用 `IOSPhoneControlSavedTasksView` 及既有快捷任务存储。

本地证据位于 `build/phone-automation-20261014/`（未提交）：各阶段 xcresult、渲染附件、CPU benchmark、签名验证、安装及设备固定 metadata。设备原始偏好文件只存0700目录/0600文件，不提交。对外可读汇总随本计划保留，不包含设置值、会话正文、配对文件或密钥。


### 真机反馈补修：多邻国速度与断流

用户在本轮装机后反馈多邻国仍慢、网络很快断开。以本次真实 selected 对话及生命周期日志重新定位，完成下述补修后重新构建、覆盖安装。

- 本次只有普通 `phone_act` / `phone_observe`，未调用 Jev Goal 或 Flow。12段已完成主模型推理累计72.538秒，已记录动作3.402秒、观察4.756秒（其中settle2.844秒）；这不是完整端到端耗时，也没有旧包同场景对照。最长单段推理21.083秒。缓存命中接近此前上下文，不能把增长的prompt直接称为每轮全量重算。
- 一次坐标滑动引用了操作及新观察后已经失效的旧截图，真实guard以staleObservation拒绝，动作未发送。普通动作回执明确 `visual_actions_available=false`，提示直接使用新树ref或重新截图；Flow声明鼓励合并已知连续步骤，未知新题仍交回主模型，不删除旧截图保护。
- 当前真机 `deepseek-flash` 保存AUTO、abilities为空、没有thinking/effort覆盖。精确alias此前既未识别DeepSeek effort家族，也未匹配registry能力；运行时因此省略thinking参数，而[DeepSeek官方文档](https://api-docs.deepseek.com/guides/thinking_mode/)说明默认开启高档思考。修复精确alias的family、registry及既有session group，旧配置无需写回能力；用户选择LOW才能实际发送low，不自动改变保存的AUTO/HIGH，不新增vision能力。
- 实际任务进入后台35.736秒后发生系统任务expiration，之后音频被中断，回前台时模型请求报`NSURLErrorDomain -1005`；Runner shutdown失败是后续cleanup结果。诊断readiness在用户任务claim之前43.122秒已结束，无重叠证据。没有系统suspend trace及具体expiration理由，不能把保活事件硬判为断流唯一原因。
- 可达源码缺陷是系统Progress饱和：固定4阶段，第一次工具后completed=3，之后每轮1/2/3受max夹制，真实模型输出和工具完成不再推进。[Apple说明](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)要求实际进度，并在资源紧张时优先结束低进度或无进度工作。用真实输出、工具结果与durable checkpoint推进手机任务的未知总量进度，保留普通聊天4阶段，不加定时假心跳、不重新提交已被收走的系统任务。
- `NSURLErrorDomain`的诊断地址恰含401/404时，原错误文案会误判认证/模型。错误归因先识别URLSession domain，保留真实网络错误，未新增自动重试或模型切换。

验证结果：错误归因先红后绿，网络与普通provider分类及动作新树回执3项通过；DeepSeek family/registry 42项、真实provider request body 28项通过。真实Host调用链已取得进度饱和红测试。独立review追加两条必要闭环：审批恢复后的新工具结果不能依赖已清空的瞬时activeToolName；成功交接到后台Coordinator后必须继续推进同一个lease的真实进度，不能回到4阶段或从新facade的0计数夹住原进度。这两条追加链路均先取得真实App红测试，再修复。最终受影响App gate 175项通过，0失败；1项既有opt-in性能采样默认跳过。包括全部Host/BackgroundExecution/GenerationParams与项目要求的3组聊天回归，7项进度回归覆盖真实多轮、审批、原lease继承、重复/空内容、取消与交接。独立逻辑review Ready；普通/320pt AX3思考档位渲染review通过。真正远程durable transport的resumeDetachedResponse不经过本次本地continueModel回调，未把该旧路径称为补修已验收。

### 多邻国断流补修版交付（r3）

- GPL Release 完整构建通过，包含 Gradle 生成的 Shared.framework；五个 bundle 的签名、目标设备授权及 App Group 核对通过，构建输入 hash 与最终源码一致。设备包仍包含三个原有 Intelligent UI WIP，提交不包含这些文件。
- App 已在18 Pro原位覆盖安装成功，无参数正常启动成功，随后进程检查确认存活。Runner 源码未再修改，沿用已签名并安装的本轮 Runner。首次 r2 的只读 readiness 结果不作为 r3 的重新配对或完整操作验收。
- 紧邻安装前后，偏好键213→214、0缺失。6个关键设置语义全部一致：4个原始 hash 相同，另2个 JSON 解析后的字段、类型和值一致，仅存在等价序列化的键顺序差异。保存的 AUTO、abilities 和 modelId 均未改变。非关键变化是 Watch、StoreKit、记忆提取及子任务状态，新增项是绑定新 App 数据容器路径的记忆 Markdown 签名缓存。
- 390条会话文件名称、大小和 resources 一致，用户会话 UUID 文件修改时间未变；只有 summary-cache-v1.cache 的修改时间变化，大小仍为201554，另2项系统数据保护扩展属性变化。App Group ID、容器路径和3项 Group 文件完整元数据一致；App 数据及 bundle 容器路径重新分配。未比较会话正文或全部 Keychain。
- 数据比对的 after-copy 完成后才执行正常启动；缓存及偏好变化已在复制前落盘，具体写入触发者未确认。补修后的完整多邻国任务、真机点击耗时及蜂窝稳定性尚未重跑，不能据构建和安装成功声称这些体验已通过。

提交的模拟器合成场景截图：[手机回执AX3](iphone-control-evidence/automation-receipts-ax3-20261015.png)、[保存错误AX3](iphone-control-evidence/automation-save-validation-ax3-20261015.png)、[运行输入错误AX3](iphone-control-evidence/automation-run-validation-ax3-20261015.png)、[DeepSeek思考档位AX3](iphone-control-evidence/deepseek-flash-reasoning-ax3-20261015.png)。这些是产品组件的测试渲染，包含fixture数据，不是用户真机屏幕。

### 决策轮数补修（起点 6effcb24）

用户批准进一步减少逐按钮主模型决策。范围是现有 Engine、Flow 与手机任务默认思考策略，不新增手机后端或通用编排器。验收分开记录请求策略实际到达、连续动作与停止条件、请求档位、模型实际采用和真机耗时。

- 在前后台共用的 Engine 每轮请求副本中加入短的手机规划指令：当前题答案及操作顺序已确定时优先短 Flow，未知新题、答错、未知页面和视觉歧义交回主模型。先注入再进入现有窗口预算处理；canonical 不保存这段新增指令，未暴露 Flow 的冻结目录不添加。工具循环最终总结时清理该指令。
- Host 冻结原始 AUTO 资格，经 Adapter 与内存后台 handoff 传递。普通用户轮也可能预先 claim 手机工具，不能据此降档；只有同一个有效 owner 已实际请求手机会话后，且模型支持 LOW，才让 AUTO 的后续请求使用 LOW。首个需求判断请求、普通聊天、旧历史、撤权 owner、显式 HIGH/LOW/OFF/MAX 保持原档位。不改保存设置和自定义 body，冷恢复不从历史重新获得资格。
- Flow 增加 `enabled` 核验，区别“检查按钮可见”和“检查按钮可以使用”。受控练习使用新树完成选择答案、检查、核对已知正确反馈、继续到新题边界；错误反馈或按钮仍 disabled 时停止并保留回执。没有稳定反馈证据的题型缩短流程，不虚构 marker。
- 独立逻辑 review 发现旧 provider 合并 system 后丢失 section metadata，可能在后台重复追加策略。精准清理本版本自身提示原文，保留其他系统内容、metadata 和消息身份，并覆盖连续三次合并交接与最终无工具总结。
- 设置页沿现有 footer 说明默认档位的手机执行策略，不新增开关。独立 UI review 实际检查普通393pt首页/page2、320pt AX3首页/page2/page3：说明全文可通过滚动阅读，与状态和常用任务卡无重叠，未发现错位、对齐、边距、间距或大小阻塞。合成场景的两张原图保留为 [AX3首页](iphone-control-evidence/phone-decision-policy-ax3-page1-20261015.png)、[AX3第二页](iphone-control-evidence/phone-decision-policy-ax3-page2-20261015.png)，没有拼接或修改图像。

当前验证：生产源码 Flow harness 92项通过，包含 Flow 28项、Verifier 13项。受影响 App gate 174项通过，0失败、0跳过，包括前后台、原始AUTO资格冻结、旧历史/撤权不降档、真实观察后LOW、请求Ledger一致性、预算入口可见策略及合并去重。独立逻辑 review 唯一去重 blocker 已修复并放行；本次改动完成一次有限维护性检查。

追加调用次数对照及同类回归20项通过（与174项有重叠）：受控 provider 经生产 Engine 和真实执行器，把相同两步拆成两个工具轮与合并成一个 Flow 比较，操作决策2→1轮，含最终回复的provider请求3→2次，观察4→3次，两个动作的mutation请求序列相同。这不是外部模型实际采用率或真机速度测量。

GPL Release 通过 generic iOS 目标完整构建成功，包含 Gradle 生成的 Shared.framework。五个 bundle 的严格签名、profile目标设备授权、App Group和URL scheme核对通过，1165个源码输入hash与构建记录一致；主可执行文件hash不同于已安装r3。设备包使用含原有三个Intelligent UI WIP的当前工作树，提交不包含这些WIP。签名包位于 `iosApp/build/PhoneAutomationDevice20261014/Build/Products/Release-iphoneos/iosAppExperimentalGPL.app`。

首次设备预检和构建后的最终单次live复查均返回CoreDeviceError4016，Mac当前不能建立真机开发连接，不能确认用户任务及安装窗口；历史配对缓存不作为当前状态依据。本轮r4未安装、未启动、未做新的保留数据比对。上一节r3的安装/启动/数据证据属于旧版本，不能替代r4验收。没有重连、重新配对、改变trust或干预用户任务。

主机上的真实 provider 对照未完成：配置快照的密钥是 mask sentinel，实际密钥保存在真机 Keychain；首次拿占位值发出的请求返回401，这不代表真机凭证失败。已停止这条路径，没有导出真实密钥。已有产品的 App Intent/Saved Task 通过设备进程内 opaque handoff 传任务；外部 `devicectl --payload-url` 不能构造任意 prompt，未新增诊断入口或回写偏好文件以绕过。模型实际采用率、复杂题正确率和完整多邻国真机速度不计为通过。
