# iOS timeline 富媒体交付计划

目标：搜索图片、独立视频卡片与 Markdown 配图可在默认 NativeChatTimelineView 使用，媒体加载和失败不改变预留尺寸，用户阅读历史时不抢滚动位置。复用 UIMessagePart、现有消息存储、原生预览及滚动策略。

授权：实现、测试、模拟器运行及逐阶段 subagent review；不提交、不推送、不新增系统权限。保护原有通知相关三个文件的未提交修改。

## Phase 1：搜索图片与通用图片展示

- 打通搜索 provider → 工具结果 Text.metadata → 持久化消息 → timeline 图集；保留模型可读摘要与图片来源，不把所有搜索缩略图作为模型视觉输入。
- 复用 Image / metadata，明确来源、标题和稳定身份；通用工具图片不依赖 generate_image 特例。搜索用 display-only metadata，其他原生工具图片仍用 Image。
- 固定比例图片容器、多图横向排列、全屏预览、加载失败和重试。生成图片保留既有专属操作。
- 验证搜索解析/调用输出、消息投影与尺寸；subagent 审查链路和 UI，修复已复核问题后进入下一阶段。

## Phase 2：视频卡片与播放

- Video part 单独可显示、可与文字混排；封面、播放按钮、可用标题/时长及来源。
- 用户点击才创建系统全屏播放器，关闭停止，保持 timeline 原卡片和滚动身份；失败可见且能重试。
- 支持提供给 Video part 的可播放 HTTP(S)/受支持本地媒体；普通网页链接仍走来源网页，不假装可播放。
- 验证数据入口、播放器生命周期和卡片尺寸；subagent 审查并修复。

## Phase 3：Markdown 配图与整体稳定性

- 完整 Markdown 图片语法转换为原生媒体块，保留前后文字、链接图片与代码块字面内容；流式未闭合语法不提前发请求，稳定块不随每个 chunk 重建。
- 用户图片、搜索图片和 Markdown 图片加载前后预留框稳定；缩略图按显示尺寸后台降采样，限制缓存开销。
- 验证流式/终态、历史重开、来源打开、重试、横竖图和长文本/动态字号；subagent 审查并修复。

## Phase 4：整体验证与交付

- 运行受影响定点测试与项目规定的 streaming replay / native scroll / viewport 三组回归，完成模拟器 build 和视觉检查。
- 每阶段记录实际检查、review 结果和精准修复；最终仅对本轮 diff 做一次有限可维护性审查。
- 检查现有用户 WIP 未改变。报告构建、模拟器、真机及真实 provider 验收各自证据，不把未测项目说成通过。

## 进度

- Phase 1 实现、独立调用链 review、模拟器测试及终态截图 review 完成。图片来自 Brave、Tavily、Exa、Serper news、SerpAPI organic/news 的明确响应字段。前台、审批、后台均保存 metadata。review 修复了共享布局访问级别、body JSON 解码及历史首帧媒体高度问题。
- Phase 2 实现、独立调用链 review、生命周期测试及横竖卡片截图 review 完成。MCP 标准图片内容及明确 MIME 的视频 resource_link 接入 typed output。已修复 Video 未进入模型正文、长 JSON 截断丢媒体、封面重试嵌套播放按钮。内嵌 video blob 显示资源说明，不转换成巨大 data URL。
- Phase 3 实现、独立 review、AST/流式测试及真实 scene 截图 review 完成。历史初始计划预留媒体高度；完整段落后提升流式图片。普通文字/图/文字按顺序拆分，复杂 inline 格式、列表、引用和表格保留原容器后附媒体。已修复格式残片、未提升链接/相对图丢失及空 alt/code alt 语义。
- Phase 4 完成唯一一次有限可维护性审查及整体验证。视频接既有 keep-alive suspend/resume owner、串行音频队列和 session epoch，覆盖取消/重试/失败和迟到清理。所有阶段 reviewer 已实看最终媒体截图，无富媒体 UI 阻断。完整回归仍有下述长文时序保留项，不能标为全绿。
- 本任务代码已冻结；构建、模拟器测试及正常启动检查完成。未做真机、真实外网 provider、弱网或 120Hz 手感验收。
- 并行工作说明：初始 HEAD 为 657976c3，原有通知 WIP 三文件 SHA256 已在本轮工具输出保存，并在外部写入前复核一致。外部任务随后将包含本轮富媒体文件的内容混合提交于 0c746ced，又提交 99233fb0 并继续 PhoneControl 工作。本任务没有执行 commit/push/reset/stash/clean；不回滚外部提交，不覆盖通知、Live Activity 或 PhoneControl 改动。

## 验收记录

- 第一轮模拟器构建完成，17 个测试类实际执行 404 项：398 通过、2 跳过、4 失败。搜索、MCP、runtime、视频生命周期、音频 owner、消息投影、宽度和 scroll core/viewport 测试通过。
- 两个新增高度测试在 detached host 与挂载 window 后比较，受到 54pt 安全区差异影响。已统一同一已挂载 window 和组件布局域，保留 1pt 高度稳定断言；未放宽容差。
- 另两项流式性能测试略超原阈值（24KB 发布次数 44/45、长表格 p95 41.02/40ms），继续使用原断言复跑必测三组。
- Phase 1/2/3/4 reviewer 已实际查看窄屏、大字号、图片成功/失败、用户图、视频横竖卡和 Markdown 混排截图，未发现确定的错位、重叠或宽度溢出。默认 timeline 截图仍有 loading 状态，补充真实图片像素终态断言和可见性诊断后再确认加载闭环。
- Markdown 复杂容器中已提升的图片改为转义 alt 文本，避免原 renderer 显示原始图片语法；代码片段 alt 仅显示内容，保留代码示例和相对路径图片。对应新增回归通过。
- 真实 scene 验证完成：ChatMediaTests 与 ChatMarkdownMediaTests 共 28 项全部通过，包含默认 Native timeline 实际图片像素、失败重试 UI、前后 contentSize 高度不变、复杂容器最终 bullet 列表。所有阶段 reviewer 已实看更新截图，图片内容和列表均已正确显示，无新增 UI 阻断。
- 旧 spinner/字面列表/大空白截图确认为测试窗口未关联真实 UIWindowScene、layer.render 未正确合成更新造成；沿用本仓已记录的 scene 测试约束修正夹具，产品加载和 vendor 无额外补偿代码。
- 24KB canary 同 binary A/B：旧 Markdown 入口也触及 p95 36/24 字符阈值，新媒体入口本轮通过；两者均 app/scene active。不能据此前边缘失败认定新媒体造成回归，也不宣称新入口提速。临时 bypass、对照测试与所有诊断打印已清除，原测试断言不变。

## 最终证据与保留项

- Xcode Simulator Debug 构建完成；iPhone 17 Pro / iOS 26.5 正常启动 `app.amber.ios`，实际主页截图已保存，进程存活。没有将构建/启动当成真机或外网媒体验收。
- 最终 17 类回归：407 项，403 通过、2 跳过、2 失败。媒体、Markdown 媒体、视频、搜索/MCP/runtime、音频 owner、投影/hash、宽度、NativeTimelineScrollCore 和 viewport 类全部通过。结果包 `/tmp/amber-media-final.xcresult`。
- 两项完整回归失败均在 `ChatSwiftUIStreamReplayTests`：24KB 发布次数 38/45、p95 增长 36/24 字符及高度 61/40pt；推理卡终态最大瞬时 anchor 偏差 29/25pt（尾段贴底和回跳断言通过）。不把这一轮描述为全绿。
- 同 binary 定点复验：推理卡终态用例通过；24KB 节拍仍失败（40/45 次发布）；额外连续正文 warmup 捕获单次 61/40pt 段落高度增长。结果包 `/tmp/amber-media-final-targeted.xcresult`。既有纯正文路径存在时序波动，尚无新媒体调用链导致该波动的确定证据；没有放宽阈值、吞断言或添加滚动补偿。
- 富媒体确定性验收：真实图片像素显示、失败重试、历史首帧预留高度、加载前后 contentSize 稳定、320pt/辅助功能字号、横竖图/视频、复杂容器最终列表全部通过。截图目录 `/tmp/amber-rich-media-evidence`，各阶段 subagent 已实际复看。
- 未验证：真实搜索/MCP 服务返回与外网视频下载、弱网重试手感、系统全屏播放器的人工点击验收、真机音频/后台及 120Hz 滚动。视频测试使用实际生成的本地 MP4 和真实 AVPlayer，音频 owner 竞态使用注入依赖验证。
- 本任务未执行提交或推送。共享工作区的其他任务持续提交，最后验证时 HEAD 为 `b98bd6f0`；保留外部通知、PhoneControl、构建工具配置及其未跟踪文件。

## 正常 App 整屏截图补验

- 原有纯色 fixture 图属于模拟器内组件测试截图，不等同于正常聊天页的整屏截图。补充 iPhone 17 Pro / iOS 26.5 正常 App 的独立「富媒体验收样例」会话，使用下载到本地的实拍照片和 MDN CC0 花朵 MP4；不是实际搜索 provider 返回的结果。
- 通过模拟器直接截图，保存正常 timeline、全屏视频和关闭返回后的整屏画面于 `/tmp/amber-rich-media-screen-proof/`。实际点开视频、播放及系统左上关闭返回已确认，返回后图集和视频卡位置保留。原有 9 份会话正文文件 SHA256 前后完全一致。
- 真正打开系统播放器后发现右上自定义关闭按钮与系统控件重叠，精准改为仅在 loading/failure（player 为 nil）显示自定义关闭；成功播放使用系统关闭。Phase 2 reviewer 已复核，最低部署 iOS 26.0，错误退出和 onDisappear → stop 清理不变。
- 补修后 9 项 ChatVideoTests 全部通过（`/tmp/amber-video-controls-review.xcresult`）；已再次实际播放、检查控件并关闭返回。真实外网 provider、弱网及真机/120Hz 保留项不变。

## 真机安装

- 按用户后续「安装真机」授权，向已连接 iPhone 18 Pro 覆盖安装 `app.amber.ios`。使用现有 `iosAppExperimentalGPL` 开发签名 Debug 配置、Team/App Group，不卸载、不清空数据，不复制模拟器验收样例到手机。
- 当前工作区源码构建成功，codesign deep/strict 校验通过，12 份富媒体相关源码的构建前后 SHA256 一致。二进制 SHA256：`2db7ba5a301946c85c01d0701640506e4cb160297f54ebced4de11ccfd4daf26`。
- devicectl 安装成功，启动成功；随后查到主 App 进程 71564，其可执行路径与安装返回的新 bundle 容器一致。安装结果 `/tmp/amber-media-device-install.json`，启动和进程结果 `/tmp/amber-media-device-launch.json`、`/tmp/amber-media-device-processes.json`。
- 安装前后原有 396 个会话 JSON 的文件名和大小全部一致，共 246499644 字节；未逐文件读取内容计算 hash。清单 `/tmp/amber-media-device-files-before.json`、`/tmp/amber-media-device-files-after.json`。
- 本轮确认真机安装及进程启动；真实 provider、真机图片/视频交互、弱网及 120Hz 手感仍需实际测试。


## 真机反馈补修：视频首帧与 iSH 权限（2026-10-17）

- 范围收敛为两项反馈：无 posterURL 的视频一直灰底；已包含 iSH 的 GPL 构建未向模型暴露 ios_ish_execute。按“定位 → 修复 → 独立调用链/UI review → 构建安装”推进，不增加媒体框架或自动授权迁移。
- 视频修复前，真实 MP4 卡片像素测试为 0 个首帧像素而失败（`/tmp/amber-poster-red.xcresult`）。现在优先使用独立封面，缺失/失效时由 AVAssetImageGenerator 异步取首帧；仅可见卡片加载，限制尺寸和 16 MB 缓存，取消后不缓存或发布，不创建播放器或占用音频会话。
- 窄屏大字号截图发现失败说明压住播放钮；改为单行“无封面”并与时长共用底栏。独立 reviewer 实看修改后的 320pt 横竖卡片，确认播放钮、圆角、标题和来源间距正常。显式封面测试最初把 ImageIO 的 40px 预算误期望为原图 20px；夹具预算改为 20px，保留精确尺寸断言。
- iSH 真机证据：原保存值 `ios.embedded.ish_runtime=disabled`，一次性迁移标记已存在；截图会话真实工具搜索也未返回 ios_ish_execute。构建包含 iSH，不能把该状态表述为“不支持”。已复现另一条配置丢失路径：不支持 iSH 的构建会覆盖原允许策略。现保留不支持构建中的保存值，实际策略消费仍禁止执行；用户明确保存的禁用值不被恢复。
- 运行环境页接入 AppShell 同一个 IOSPermissionStore，准确显示未链接/已禁用/可回传，并提供原生权限菜单。实际 GPL 模拟器操作“禁用 → 每次询问”，状态立即刷新，磁盘策略最终为 askEveryTime。下次请求重建工具目录的定点测试通过；当前运行仍使用既有快照。UI 的真实入口为“设置 → 运行环境 → Runtime 与任务 → iSH 工具能力”，在弹层点当前的“禁用”选择“每次询问”；Picker 没有单独显示其 accessibility label 标题。
- iSH 与视频均完成独立 source/调用链 review；本轮有限可维护性检查已完成，未追加请求池、重试器或状态框架。
- 最终相关回归 `/tmp/amber-poster-ish-regression.xcresult`：120 项，118 通过、1 跳过、1 失败。视频 13 项、权限存储 8 项、设置接线和下一请求工具目录刷新均通过；Native scroll core、viewport 通过。唯一失败为长表格流式 p95 42.12ms / 40ms；同一二进制定点复验为 45.02ms / 40ms，仍未过。默认原生 timeline 的媒体加载高度用例在该次定点复验通过（`/tmp/amber-poster-table-recheck.xcresult`）。没有放宽断言；该纯文字/表格 fixture 不会进入新增首帧路径，但这不代表整体性能门禁已通过。
- 完整回归测试结束后，Xcode 的 simctl diagnose 子进程收集挂起；只终止该任务自有诊断收集，测试结果与日志均已保留并能读取。后续定点复验关闭 verbose diagnostics 收集，保留测试本身及原阈值。
- 正常 App 外网验收：本任务原有模拟器样例改为不含独立封面的 Markdown MDN MP4 直链，首帧实际显示，实际播放至 0:02/0:05，再经系统 X 返回。独立 reviewer 实看封面、全屏控制和返回截图，确认图片/文字/视频位置一致。截图 `/tmp/amber-poster-fix-proof/chat-remote-poster.png`、`remote-video-controls.png`、`returned-after-remote-playback.png`；GPL 权限图为 `ish-disabled.png`、`ish-policy-menu.png`、`ish-ask-every-time.png`。原有 9 份模拟器会话正文 SHA256 全部保持一致，只修改本任务自建样例。
- 最新 ExperimentalGPL 模拟器与真机 Debug 构建成功；真机签名 deep/strict 校验通过，4 份本轮产品源码在构建前后 hash 一致。物理包 SHA256 `384d5ca17a0ac5bd4f1bb9997faa1dc8dab918a5d4ebcb7e9bf7525d9128bec7`。
- 已向 iPhone 18 Pro 覆盖安装同一 app.amber.ios 并启动；新 bundle 容器为 771A9492-B472-4051-B0DD-16A466BF33E1，主进程 71727 路径匹配。原有 397 份会话 JSON 文件名与大小全部保留，未逐份计算内容 hash。安装、启动、进程与保留检查均在 `/tmp/amber-poster-fix-proof/physical-*.json`。
- 手机安装后实际保存值仍为 disabled；没有改写用户授权。需由用户从上述入口改为每次询问后再发新请求。真机图片此前用户已确认；本轮新封面/播放触感、实际 provider 调用 ios_ish_execute 和真实 stdout 回传尚未代替用户完成验收。不将安装启动当作这些行为已通过。

## 图片展示引导与缓存、滚动补修（2026-10-17）

- 完成标准：搜索取得真实图片直链时，每轮上传上下文明确要求原生 Markdown 展示并保留来源；同资源附近滚动不清空位图，进入视口前预加载；缩略图跨进程可复用且磁盘有上限，共享请求保留逐消费者取消语义；通过定点测试和必测滚动回归，独立 review 后覆盖安装同一真机 App 并检查数据保留。
- Phase A（缓存与展示契约）：已实现并完成独立源码/调用链 review。ChatRuntimeContextBuilder 注入 chatMedia system section，不改已保存的 bot 提示词或消息；图片和视频封面复用 128 MB 磁盘缩略图缓存及共享请求，视频先查最终封面缓存再尝试失效 poster。没有新增权限、依赖、重试框架或自动刷新策略。
- 受控真实 Simulator CLI 基线：正常可缓存 HTTP 响应、固定 150ms 网络延迟、实际 UIKit/ImageIO/AVFoundation。新进程图片 200ms → 11.3ms，视频首帧 388ms → 3.96ms；同 URL 并发四次请求 4 → 1；已有首帧但 poster 失效时 160ms → 0.027ms。第二进程 HTTP 请求数不增加；单消费者取消、最后消费者取消后同 key 新请求均通过。原始输出和快照在 /tmp/amber-media-cache-probe/。首次图片冷加载单样本 205ms → 248ms，包含 PNG 写盘，不能宣称首次网络加快。
- Phase B（视口与预取）：现有 onGeometryChange 本地坐标交集方向正确；已确认每次 visible 切换即清空 image，且没有预加载。两项实际挂载 scene 的预取回归在修改 UI 前均失败（图片/视频像素为 0），结果 /tmp/amber-cache-viewport-red-resume.xcresult。已实现沿纵横滚动轴各提前约一屏加载、一至两屏保留已有位图、两屏外释放；瞬态零尺寸不卸载可见内容。图片按 URL/像素预算、封面按 URL/posterURL 识别资源，避免串图，标题/时长更新不清封面。
- 受影响四组测试首次执行 77 项，76 通过，仅新 Native 部分可见夹具的初始首图像素失败（/tmp/amber-cache-media-green.xcresult）；两个预取红测试、缓存/取消/提示词及原媒体布局均通过。独立核实夹具手动滚顶与现有首次 attach 到底部发生竞争，改为应用已有首图 ChatMessageAnchor，像素和 1pt 高度断言不变；定点复验通过（/tmp/amber-cache-native-recheck.xcresult）。没有为夹具改产品滚动。
- Phase C（集成与交付）：源码/调用链、一次有限可维护性审查及独立视觉 review 完成，未追加抽象或兜底。reviewer 实看 11 张组件图、Native 复验图和正常 App 整屏：图集邻图露出、窄屏大字号、用户单图、图片部分可见、视频封面/时长/播放钮和混排无新增错位、重叠或异常间距。review 记录 /tmp/amber-cache-fix-proof/viewport-source-review.md。
- 必测三组执行 97 项：93 通过、1 跳过、3 失败（/tmp/amber-cache-scroll-regression.xcresult）。NativeTimelineScrollCore 与 ChatViewportPolicy 全通过；纯文字 StreamReplay 的 24KB 更新 p95 36/24 字符、长表格帧间隔 p95 45.54/40ms、推理卡终态 anchor 29/25pt 未过。同二进制一次定点复验中推理卡通过，24KB 和长表格仍失败（/tmp/amber-cache-stream-recheck.xcresult），该轮长文仅一次可见发布、表格 p95 124.01/40ms。未放宽断言，也没有把完整回归描述成通过；这些不含媒体的回放路径尚有未解决的性能问题。
- 正常模拟器 App 使用本任务原有独立样例，增加尾部文字提供真实滚动空间；实际查看图片部分出屏、回看、远程视频播放至系统控件 0:01/0:05，并经系统 X 返回，原位置及封面保留。证据 /tmp/amber-cache-fix-proof/chat-normal.png、chat-partial-scroll.png、chat-scroll-return.png、video-controls.png、chat-after-playback.png。原有 9 份模拟器会话正文 SHA256 全部不变；仅修改本任务样例。
- 真机 ExperimentalGPL Debug 构建及 deep/strict 签名校验通过，产品三文件在构建/安装前后 SHA256 不变；可执行文件 SHA256 为 4a4069bbb3f5bed49c9a063a76dba338fefd22d2006ba6aa19685afd57aab544。覆盖安装同一 app.amber.ios，启动后主进程 72003 的路径匹配新容器 7D4924C6-02FC-4284-BDBF-0C32CC5E3E43。紧邻安装前后的 169 份会话 JSON 文件名与大小完全相同，共 214600047 字节，未逐文件计算内容 hash。证据 /tmp/amber-cache-fix-proof/physical-*.json。没有改用户权限策略或执行提交/推送。
- 本轮已验证缓存和渲染契约、模拟器实际显示/播放与真机安装启动；真实 provider 对展示指导的遵循、弱网及真机 120Hz 交互仍未代替使用验收。首次联网没有提速承诺，快速跳到远处或网络未完成时仍可能出现占位。

## 显示设置补充：自动展开思考内容（2026-10-18）

- 在“显示与字体 → 消息显示”增加“自动展开思考内容”，说明为“关闭后默认折叠，仍可点击查看思考内容。”默认开启，使用 iOS 本地偏好 app.amber.ios.display.autoExpandThinking，与现有显示项一样由 AppStorage 保存。
- 普通聊天的已有思考/等待思考两入口和小说共享思考卡均消费同一偏好。关闭同时覆盖首次呈现、首段思考到达与再次开始思考；手动展开/收起继续优先，原 autoCloseThinking 与 Reduce Motion 分支保留。不改 provider、消息正文或小说领域数据。
- ChatReasoningCardTests、IOSSettingsWiringTests、IOSNovelCreationWiringTests 共 105 项通过；包含实际消息气泡读取隔离偏好、偏好持久化、关闭后首段/新一轮不展开和动态开关。结果 /tmp/amber-reasoning-option-targeted.xcresult。
- 必测三组 97 项中 95 通过、1 跳过，唯一失败为既有纯文字长表格帧间隔 p95 42.38/40ms；长文、推理终态、Native scroll core 和 viewport 通过。结果 /tmp/amber-reasoning-option-scroll.xcresult，未修改阈值。
- 正常模拟器实际从设置关闭，确认磁盘单 key 为 false，重启后设置仍关闭；独立样例中的思考卡可真实点击展开、再次点击收起。检查后恢复模拟器开启。独立 reviewer 实看设置开/关和思考卡折叠/手动展开截图，标题副标题、间距、分隔线、开关与正文布局无新增问题；一次有限可维护性审查无需抽象或补偿。证据 /tmp/amber-reasoning-option-proof/，只修改本任务已有样例，原有 9 份模拟器会话正文 hash 不变。
- 真机 ExperimentalGPL Debug 构建、签名 deep/strict 校验、覆盖安装及启动通过，主进程 72023 的路径匹配新容器 FD843157-D688-4C46-A2D9-BA0D76C43D85。可执行文件 SHA256 601ff06444cbd3851e13d48824888e0df62b17a2532674f5057285b186b576ff。本轮 5 份产品源码 hash 构建前后相同，前轮媒体/缓存/上下文源码 hash 保持不变。手机 169 份会话 JSON 文件名和大小全部保留，未逐份读取正文计算 hash。没有替用户关闭手机的新开关；默认行为仍开启。真机交互及真实 provider 思考流尚未单独验收，未提交/推送。

## 产物架图片漏收补修（2026-10-18）

- 根因：ConversationArtifactIndex 原来只索引 generate_image 的图片输出。聊天已经展示的 Markdown 图片、助手 Image part 和搜索结构化图库没有进入索引，属于入口漏接，无需修改会话存储。
- Phase A：先新增两项索引回归，在原实现上均得到空 images 而失败（/tmp/amber-artifact-red2.xcresult）。现已接入三路助手图片，Markdown 复用聊天 AST；普通链接、代码块/行内代码、未完成语法不收录。用户上传仍不自动当助手产物。URL 去重，新增图片按地址生成稳定标识，生成图保留原 ID 与 prompt。历史加载、分支切换、工具完成和助手终态沿现有信号重建索引。
- Phase B：正文图片与 widget 解析缓存统一由 ConversationArtifactContentCache 持有，正文未变复用结果，切分支 prune。产物架缩略图复用共享图片加载器，全屏复用聊天图库，既有选择、继续、来源定位和报告导出承接新增图片；默认无标题文案改为“图片”。独立 subagent 完成一次本轮有限源码/可维护性审查。
- 定点验证：索引、缓存、Markdown、产物架状态、布局、锚点和集成首轮 59 项中 58 通过，唯一失败为报告旧文案断言；更新为中性“图片”后 ChatArtifactActions 12 项复验全过，其余有效断言保留。结果 /tmp/amber-artifact-green.xcresult、/tmp/amber-artifact-regression.xcresult。后续 ChatMediaTests 14 项通过（/tmp/amber-artifact-share.xcresult）。
- 必测三组与 Actions 合计 109 项：107 通过、1 跳过、1 失败。失败为纯文字 24KB prose 的贴底跟随误差 79pt 超过 72pt；长表格帧间隔本轮通过。本轮未改滚动策略或放宽阈值，不能声称全部回归通过。
- Phase C：普通模拟器 App 原有独立样例收录两张 typed 图片和一张 Markdown 图片，产物架计数 3，缩略图、横滑、点击第三张进入 3/3、大图 1/3→2/3→3/3 切换、来源回到第 1 轮实测通过。独立 reviewer 实看整屏、缩略图和全屏比例/安全区，未见新增错位、间距或异常空白。原有 9 份模拟器会话 SHA256 均不变，只追加本任务样例图片。
- 实测额外发现图库旧命令式分享会同步误判失败：系统 UIActivityViewController 在延迟呈现，返回 false 随即触发 SwiftUI alert，与系统面板发生 presentation-in-progress 冲突，日志 /tmp/amber-artifact-image-proof/share-presentation.log。预览按钮改为已有 ShareLink；当前 URL 的准备状态在 task 中生成，切图取消及 URL 标记避免串图，task 随 URL 变化重跑。未改全局分享工具、未加重试或多窗口兜底。最终模拟器构建中，文件 URL 与 Markdown data 图片均成功呈现系统分享面板，标题/缩略图正确；独立 reviewer 复核这两张新结果图通过。没有执行向外部 App 发送。
- 实际截图：/tmp/amber-artifact-image-proof/final-shelf.png、shelf-markdown-image.png、shelf-source-located.png、final-url-preview.png、final-page-two.png、final-data-preview.png、final-url-share.png、final-data-share.png。不以模拟器结果代替真机交互或真实 provider 验收。
- 真机交付：最终 ExperimentalGPL Debug 构建与 deep/strict 签名校验通过，可执行文件 SHA256 9245fd12ed4cfa61d4520a80e87b36c1b87745bbfd8b6db447629012c82f05ab。同 app.amber.ios 覆盖安装成功，安装容器 9E999669-40E2-4B61-AB53-44FCB4437E31。首次安装因远端 XPC 中断返回 CoreDevice 3002，在设备仍 available 后单次重试成功；没有卸载或更改用户数据。紧邻安装前后 169 份会话 JSON 文件名及大小完全一致，共 214600047 字节，未逐份计算正文 hash。自动启动被锁屏明确拒绝（CoreDevice 10002 / FBSOpenApplicationErrorDomain 7 Locked），所以只声明构建、签名与安装完成，不声明最终版本真机启动或交互已验收。证据 /tmp/amber-artifact-image-proof/device-*.json。没有提交或推送。
