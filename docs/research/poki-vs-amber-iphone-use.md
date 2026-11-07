# poki 与 Amber：iPhone use 能力对比

调研日期：2026-11-06，北京时间。查询跨越 11 月 5 日深夜至 6 日凌晨。

范围：只读核对公开仓库、官网、release、issue/PR，以及本工作树源码。未安装 poki、未运行两端设备测试、未调用付费模型、未连接线上 amberd。本文区分源码实现、作者自测、历史验收记录和待验证推断。

- poki 固定源码：[`f42f91d31eef2b4766230daaaa2fbd6053b79e9c`][P-commit]。
- Amber 固定源码：`aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94`，本工作树起始状态干净。

## 结论

**目前没有证据证明 poki 的 iPhone use 整体“最强”，也没有它与 Amber 的同条件对照。它确实有几个值得借鉴的工程点，最突出的是把成功任务编译成可校验、可参数化、能少调甚至不调模型的路线。**

把 Amber 理解成“只会快捷指令，不能操作别的 App”会得出错误结论。当前 Amber 已有完整的同机 PhoneControl 调用链：用户任务 → 工具曝光 → Swift executor → 本机开发隧道 → XCTest runner → UI tree / 动作 / 新观察；还有目标循环、固定流程、OCR、坐标操作、剪贴板和系统导航。[A-tools][A-executor][A-build-request][A-adapters][A-native]

两者的主要区别是执行位置与产品重心：

| | poki | Amber iOS 当前基线 |
| --- | --- | --- |
| 重心 | 让 Mac 上的外部 agent 专门操作 iPhone | 手机上的个人 agent，手机自控是其中一条能力路径 |
| 真机控制 | Mac → usbmuxd / CoreDeviceProxy → RSD → RemoteAX、屏幕媒体服务、UniversalHID | iPhone 上的 Amber → 本地回环隧道 → RemotePairing / RSD → XCTest runner → 私有 AX 与动作接口 |
| 常驻宿主 | 需要 Mac 上的服务持续运行 | 源码支持运行时同机自控；仍需开发服务、配对、签名单独安装的 runner 与本地连接准备 |
| 重复任务 | 自动学习带前后条件的路线；满足条件时可零模型调用 | 有已知步骤批量执行和成功路径记忆；成功路径目前主要供模型参考 |
| 分发性质 | 当前交付是 Mac CLI/MCP，原生 iOS App 仍在路线图 | 已有原生 iOS 客户端；PhoneControl 这条开发者服务路线也不能直接等同普通 App Store 能力 |

架构依据见 [poki bridge][P-native]、[poki AX][P-ax]、[Amber native][A-native]、[Amber runner][A-runner]。表中是实现对比，不代表本轮确认了两端在当前手机上的可用性。

## 1. poki 是什么，宣传能核实到哪一步

### 仓库与公开证据

| 项目 | 本轮查询结果 |
| --- | --- |
| 仓库 | [JosssphZhou/poki][P-repo]，公开、未归档，默认分支 `main` |
| Stars / Forks | GitHub API 本轮快照为 **29 Stars / 8 Forks**，增长较快，数字会变化 |
| 仓库创建 | `2026-11-05 15:04:31 UTC`，即北京时间 `23:04:31`；这是该公开仓库创建时间，不代表项目开始开发时间 |
| 最新代码活动 | `pushed_at=2026-11-05 15:54:53 UTC`；固定 commit 的提交时间为 `15:54:51 UTC`，内容是移除文档中的工具数量 |
| 主要语言 | GitHub 标为 JavaScript；核心另有 Rust、Swift、Objective-C/Python 辅助程序 |
| 许可证 | 根项目 **AGPL-3.0-only**；依赖另有各自许可，见第三方声明 |
| Release | 首个公开版 [v0.1.0][P-release]，`2026-11-05 15:32:46 UTC`；提供 Apple Silicon Mac 的签名、公证预编译包 |
| Issues / PR | 本轮 `gh issue list --state all` 与 `gh pr list --state all` 均返回空列表；没有可用的外部用户问题/修复记录来交叉验证成熟度 |

元数据以 [GitHub API][P-api] 和 [固定 commit][P-commit] 为准。网页抓取缓存曾显示较少 Stars，本表采用稍后读取的实时 API 快照。签名与公证是 release 的作者说明，本轮没有下载并验证二进制。[P-release][P-notices]

在检查的英文/简体中文 README、官网文本和验证文档中，**没有找到“最强”的明确比较对象、统一指标或排行榜**。能定位到的卖点是：无需越狱和额外控制硬件、真实 App/系统界面操作、MCP、IM 派活、自学习路线。无法据此确认用户看到的那句宣传原文出处。[P-readme][P-site][P-verification]

### 宣传与实现对照

| 宣传或容易产生的理解 | 核实结果 | 证据强度与边界 |
| --- | --- | --- |
| “无需外接硬件、无需越狱” | 控制代码使用开发者配对服务，没有要求越狱或外接 HID 控制器 | 源码与安装流程一致；**仍要 Mac + iPhone**，不是手机独立运行 |
| “像人一样用真实 App” | 有跨 App 启动、界面读取、触摸、键盘、滚动等实现 | 机制成立；不表示每个 App、控件或系统界面都可靠 |
| “越用越快” | 有成功轨迹编译、任务/初始上下文匹配、步骤前后条件检查、当前结果提取 | 源码成立；真实复杂 App 的学习收益没有公开大样本对照 |
| “从任何地方派活” | 任务从终端、iMessage/Telegram 通道到 Mac 上的 agent，再操作手机 | 不是云服务直接跨公网控制手机；Mac 和可达的配对手机仍须在线 |
| Telegram 已能正式使用 | 协议与通道代码存在 | 文档和官网标 **Coming soon**；本版没有真实 bot 收发验收 |
| 原生 iPhone App 已交付 | 未交付 | 官网与 README 路线图都列为后续工作 |
| 官网多 App 案例证明普遍成功 | 官网展示小红书→地图→微信、微信→提醒事项、账单→备忘录等案例 | 属于项目展示；未见这些案例的统一试验方法、逐次结果和失败分母，不能当 benchmark |

依据：[安装与硬件准备][P-physical]、[官网][P-site]、[Agent 文档][P-agent]、[路线编译源码][P-routes]、[路线执行源码][P-fast]。官网包含视频和交互展示，本轮没有对演示视频逐帧鉴定，也未复现其中任务。

## 2. poki 的 iPhone use 如何实现

### 真机控制链

真机主路径是 **Mac 上的 Node MCP daemon → Rust bridge / idevice → 已信任配对设备 → CoreDeviceProxy 软件隧道与 RSD 服务发现**。`connect_device()` 的实现直接创建软件隧道并完成 RSD 握手。[P-native]

- **读界面**：连接 `com.apple.accessibility.axAuditDaemon.remoteAXService`，通过 DTX 订阅原生无障碍树；提供角色、标签、值、位置、焦点和前台 App 信息。不是依赖 iOS 给普通第三方 App 提供全局 AccessibilityService。[P-ax]
- **看屏幕**：建立 CoreDevice displayservice 屏幕媒体会话，接收画面；无法取得可用 AX 时可借助 macOS Vision OCR。视觉模型可以按需看截图，操作并非每一步都必须先做视觉推理。[P-stream][P-device]
- **做动作**：UniversalHID 注入触摸、键盘和硬件按键。发送触摸前先建立屏幕媒体会话，代码注明它用于保持输入认证通道。**这条真机主路径不需要先安装 WDA/XCTest runner。**[P-native][P-stream]
- **启动/管理 App**：RemoteXPC AppService 负责启动与应用发现；安装/卸载走 InstallationProxy，仍受 iOS 签名与授权约束。部分管理操作仍调用 Xcode 的 `devicectl`。[P-apps][P-platform]

它不是 App Intents/快捷指令方案，也不是越狱方案；“使用了 AX”不意味着使用了面向 App Store 普通 App 的公开全局控制 API。作者明确承认 CoreSimulator 和真机 bridge 依赖苹果私有接口，可能随系统改变。[P-verification]

### 能做什么

MCP 工具层支持启动 App、查看前台、读 AX/OCR、截图、点击、双击、长按、滑动/拖动、双指缩放、键盘组合键、文字输入、剪贴板、Home/锁屏/音量/Siri 等按键，以及批量动作、录屏、安装/卸载和开发诊断。实际执行分别进入真机与模拟器适配器。[P-tools][P-device][P-native]

需要分开理解三层：

1. **MCP 能力面**很宽，外部客户端可以调用更多开发工具。
2. **内置 Poki Agent 的模型白名单**较窄，主要是读屏、启动、点击、输入、滚动、返回、弹窗与 batch；不能把整个 MCP catalog 算成默认 agent 都在使用的能力。选配解锁由宿主另行提供。[P-task]
3. **真机验收面**更窄：仅中文界面、竖屏；横屏不支持；真机 App container 导出、Settings 子页深链不可用；底部浮动栏附近某些点击失效尚未解决；拖动/缩放虽有实现，但公开测量没有覆盖它们。[P-verification]

跨 App 探索与快速路线也要分开：探索 agent 可以启动不同 App；当前 `runFast` 路线绑定单一 `bundle_id`，并检查前台/PID。不能把“自学习路线”理解成已经有任意跨 App 流程的通用编译器。[P-fast][P-task]

因此，跨 App 工作的基本机制成立，但“任意 App 全自动完成任何事”没有得到证明。游戏、画布、不可见内容、支付/登录、权限弹窗以及时序变化仍可能中断流程。

### 电脑、数据线、模型、延迟与成本

| 维度 | 核实结果 |
| --- | --- |
| 电脑 | 需要持续运行服务的 Mac。源码安装要求 macOS 15+、完整 Xcode、Node 24+、Rust、FFmpeg；预编译包省去 Rust 编译，不省去真机所需完整 Xcode |
| 数据线 | 首次 USB 连接、解锁、信任电脑；开启开发者模式和 UI Automation，准备 Developer Disk Image。配对后可同一局域网 Wi-Fi 操作，需设备可达，通常保持解锁 |
| 是否越狱 | 安装流程不要求越狱；依赖开发者权限及服务，并非普通安装后即可全局控屏 |
| MCP 模式模型 | 由 Claude Code、Codex 等 MCP 客户端决定，可沿用客户端现有模型账户；控制服务不强制一个模型 |
| 独立 Agent 默认 | 源码默认 OpenAI `gpt-6.1-terra`，推理 `low`，请求 `priority`；支持 ChatGPT 登录或 API key。内置 Agent 当前不支持任意远端第三方 provider |
| Fast 是否有效 | 源码记录请求 tier 与实际返回 tier；文档说作者本地账户即使请求 Fast 也返回 `default`，没有确认实际 Fast 生效 |
| 单次动作耗时 | 作者真机日志中 `tap_text` 约 **8 秒**，`fill` 约 **15 秒**；这里包含连接、观察、输入与读回，不是模型纯推理时间 |
| 成本 | 使用用户自己的订阅/API；没有可用于比较的每任务 token、美元成本或统一复杂任务成本表。可验证路线减少模型调用，但设备调用耗时仍在 |

环境依据：[README][P-readme]、[真机准备][P-physical]。模型依据：[model-config][P-model]、[pi-session][P-session]、[Agent 文档][P-agent]。延迟依据：[作者验证记录][P-verification]，不应外推为所有设备的速度。

### 安全与权限边界

- **连接防护有实装**：daemon 仅监听 `127.0.0.1`，使用随机 bearer token、Host/Origin 检查；状态目录和 endpoint 文件分别使用 0700/0600。多客户端协调有串行执行、租约、取消和过期清理，但只在同一个 daemon 内生效。[P-daemon][P-coordination]
- **审批不是对所有后果统一拦截**：安装/卸载、构建运行、URL、容器导出、剪贴板等有 Mac 本地确认，`POKI_MCP_APPROVAL_MODE=allow` 可预先放行；普通 tap/fill/Return 不在这份强制确认名单内。不能指望它自动识别并阻止每次支付、发送或删除。项目本身也提示它会照任务操作真实账户。[P-device][P-readme]
- **内容会外发**：当前屏幕文字、按需截图进入配置模型；路线和任务记录留在本机运行目录。localhost 不等于端到端内容全部离线。[P-agent][P-verification]
- **文字输入有细致校验**：核对正在编辑的唯一字段，再清空/粘贴和读回；Unicode 经剪贴板与 Command-V，尝试保存/恢复原剪贴板，失败保留明确状态；输入未核实不发送 Return。但本次操作触发的 Allow Paste 弹窗可被代码自动接受，这与 Amber 当前“不自动批准粘贴许可”的策略不同。[P-pasteboard][A-executor]
- **可选密码解锁有额外暴露面**：用户可自行在 Mac 的私有启动环境设置锁屏密码，宿主经 stdin 传给 helper，避开模型参数。文档承认同 Mac 的程序可能读到；只验证过一个六位密码、固定竖屏键盘布局。它是已知密码输入，不是绕过锁屏安全。Amber 当前明确拒绝输入有密码锁屏的密码。[P-unlock][P-agent][A-unlock]
- **不确定结果不能重放**：多处保留 `not_sent` / `completed` / `unknown` 与观察结果，发送成功不等于业务完成；这也是 Amber 已有的语义。[P-native-doc][P-tools][A-client]

探索任务的结果另由一个没有设备工具的模型会话检查现有证据；快速路线则可直接按当前屏幕条件核验。这比只相信执行模型的“做完了”更可审查，但模型复核仍可能误判，不能替代真实结果证据。[P-verify][P-task]

## 3. “最强”有没有实测支持

目前找到的是作者维护的验证日志和可执行评测脚本，**没有与 Amber 或其他 iPhone agent 的同任务横向榜单**。[P-verification][P-eval]

### 作者真机自测

记录来自一台 iOS 27.3 iPhone、Wi-Fi、一个聊天 App 的特定搜索框等场景：

| 检查 | 作者公布结果 | 可支持的判断 |
| --- | --- | --- |
| 搜索框触摸 | 老连接策略丢 2/70；延迟关闭连接后 0/70；最后版本另有 0/24 | 针对特定目标改进了触摸送达；不能得出全设备 100% |
| MCP `tap_text` | 12/12 生效，约 8 秒 | 该场景跑通 |
| 启动后 batch 打开会话 | 14/14 | 该组合跑通 |
| MCP `fill` | 6/6，约 15 秒 | 该字段的输入/读回跑通 |
| 启动后过早点击 | 1.5 秒时 0/3；2.8 秒或以后 12/12 | 存在明显 readiness / 时序限制 |
| Settings 底部浮动栏旁点击 | 4/4 无效，未修复 | 仍有明确真机失败场景 |

这些都是**项目作者自报**。文档也承认最新 screen-change 比较逻辑未随触摸重测，拖动/缩放和横屏存在证据缺口；本轮没有独立复现。[P-verification][P-native-doc]

### 模拟器 batch 评测

同一 commit、相同 fixture，只隐藏/开放 batch，每组交错运行 5 次，表中为中位数，计时从客户端启动到最终回答：

| 客户端 / 任务 | batch 往返 | 单步往返 | batch 总秒数 | 单步总秒数 |
| --- | ---: | ---: | ---: | ---: |
| Claude Code / Counter | 3 | 5 | 17.1 | 24.6 |
| Claude Code / Form | 3 | 8 | 20.0 | 31.6 |
| Codex CLI / Counter | 2 | 7 | 24.4 | 36.4 |
| Codex CLI / Form | 2 | 7 | 28.7 | 46.1 |

它支持“已知小任务合并调用可以减少往返与耗时”，约下降 30%–38%，**不支持“poki 真机比 Amber 快 30%–38%”**：对照对象是 poki 自己的单步版本，环境是模拟器，任务是 Counter/Form，且这些数据早于后续真机输入修改。[P-verification][P-eval]

`npm test` 主要验证协议、协调和替代外部程序的 fixture；项目明确说它不操作真实手机/模拟器 UI。`verify-fixture` / `verify-platform` 才是另行执行的模拟器验证。不能把协议测试通过当作新用户装机或复杂跨 App 成功率。[P-verification]

## 4. Amber 当前能操作手机做什么

以下均以 `aed70f8f` 源码为准。既有笔记中“没有 phone_clipboard / phone_system”等旧结论已不适用于这个基线。

### PhoneControl：已经有跨 App 自控

`ChatGenerationRequestBuilder` 在用户发起且不是编排子任务的路径上决定是否加入手机工具；开关关闭时不曝光；`ChatToolExecutorAdapters` 将同一组工具绑定到 `IOSPhoneControlToolExecutor`。Controller 用 run/session/operation 身份持有连接，首次实际操作才启动 runner。[A-build-request][A-adapters][A-controller]

| 能力 | 当前实现 | 重要边界 |
| --- | --- | --- |
| 状态与准备 | `phone_status`、配置/连接/runner/UI tree 分阶段自检 | 查状态不代表会启动或修复连接 |
| 发现与授权 App | `phone_apps`、`phone_add_app`；从本机开发服务取得真实 Bundle ID | 添加只能依据目录；保存选择并不等于目标 App 可操作 |
| 跨 App 启动/回到原会话 | `phone_act launch`、`phone_return_to_amber` | 切 App 后旧 ref、截图失效；回执与前台核验分开 |
| 观察 | AX UI tree；可选端侧 OCR 和截图 | OCR 结果是文字/坐标证据，不自动获得原生 ref；画面可能不暴露完整语义 |
| 动作 | 语义点击/输入/清空/滚动/长按、截图坐标点击/滑动/长按、精确弹窗按钮、键盘提交 | 坐标绑定最新 observation 与前台/尺寸；unknown 停止，不重放 |
| 多步目标 | `phone_run_goal`，Jev 只从本机列出的候选选择 | 需要相应 Jev 配置和数据范围；只在当前授权 App 内，默认 15 步/最多 30 步、180 秒预算；不能自行生成任意坐标/文字 |
| 固定步骤 | `phone_run_flow`，语义目标 + 每步条件 + 最终条件 | 1–12 步；偏离或不确定就交回；发送、支付、登录等最终操作留给主模型路径 |
| 搜索与列表读取 | `phone_scroll_until`、`phone_collect_list` | 有滚动、收集预算和完成条件；不意味着全 App 数据导出 |
| 剪贴板 | `phone_clipboard` 文本读写 | 要先让 Amber 在可交互前台；系统许可由用户决定；不支持图片/文件剪贴板 |
| 系统界面 | `phone_system` 的观察、Home、音量、收键盘、锁屏、锁状态、无密码解锁 | 按需开放本轮 SpringBoard 范围；不保证通知/控制中心均可访问；有锁屏密码则拒绝远程输入 |
| 人工接管/停止 | Live Activity 的接管/继续入口、run 归属、停止和结果未知处理 | 停止不能撤销已发动作；恢复前须新观察 |

声明与执行依据：[tool catalog][A-tools]、[executor][A-executor]、[client][A-client]、[controller][A-controller]、[Live Activity intents][A-activity]。这些条目已追到执行入口，仍不应以源码存在代替逐项真机成功率。

底层配置保存 RemotePairing 凭据于 Keychain，默认本机私有存储、不走同步；runner HTTP 使用带时间戳、nonce 和 body 摘要的 HMAC。允许的 App 范围与旧观察检查在客户端执行。用户可为当前任务通过 `phone_add_app` 扩大保存范围，因此允许列表不是一个永远不可扩展的硬沙箱。[A-credentials][A-http][A-controller]

同机路径无需 Mac 常驻是架构能力，**不等于没有准备成本**：仍需开发服务许可、配对、本地隧道与独立签名安装 runner。内置 `NEPacketTunnelProvider` 只认领固定本地 peer 的 /32 路由；设置页明确提示可能中断其他 VPN，也支持使用现有本地回环 VPN。[A-native][A-tunnel][A-settings]

### 系统 API、快捷指令、Smart UI、网页与远端工具

| 路径 | 实际已接线的内容 | 不能混淆的地方 |
| --- | --- | --- |
| App Intents / Shortcuts | 询问/打开/继续对话、运行快捷消息、发送文字、读取最新回答；安排/执行/取消/等待续跑任务、读取同一任务结果、显式事件触发 | 是把 Amber 自己的功能交给 Siri/快捷指令等系统入口；没有因此获得任意第三方 App 的全局控制权 |
| `shortcut_compose` | 校验真实 Amber actions 与参数，生成系统编辑器的实施步骤和链接 | 它是规划工具，不会把 JSON 自动安装成快捷指令；创建/保存/测试需真实 Shortcuts UI 或用户操作 |
| Apple 原生工具 | EventKit 日历/提醒事项 CRUD、通知、系统版本支持下的闹钟/运动计划、健康摘要/天气、联系人/照片等 picker 路径 | 受系统授权、设备支持与前台条件约束；例如 picker 不是任意后台读取全通讯录 |
| Smart UI | `task-ui v1` 原生决策、表单、浏览和学习卡，操作结果进入后续对话 | 是 Amber 自己的交互界面；卡片不能声明工具/权限或执行任意代码，不是跨 App 点击引擎 |
| MiniApp | WKWebView 宿主桥、剪贴板、位置、传感器、语音、分享/打开链接等受控能力 | 受可信主文档、开关、grants 和确认限制；不等于系统全局无障碍 |
| WebMount | App 内 WKWebView 的 DOM/可见内容观察、点击/输入/滚动、截图/视觉读取、batch 和受限目标循环 | 控制的是 Amber 内网页会话，不能用来证明可操作 Safari 或第三方原生 App |
| 本机工具/终端 | 用户选取文件、App 工作区读写、AmberShell 非交互任务与 stdout/stderr/exit code；另有远端 SSH 执行入口 | AmberShell 的 `/workspace` 约束仍在；不是取得 iPhone root shell，也不能由此读取别的 App 容器 |
| 云端任务 | `/v2/dialogue/*`、`/v2/work-items` 派活/补充/停止、回执和事件/结果消费 | 本仓核实到的是 iOS 客户端协议；没有发现这些请求把云端命令直接桥接为本机 `phone_act`。云端主机执行文件/脚本/网络任务也不等于操作 iPhone |

证据：[App Intents][A-intents]、[自动化 intents][A-automation]、[续跑 intents][A-wake]、[快捷指令编写][A-shortcut]、[Apple 工具与 EventKit 执行][A-apple]、[Apple 工具调度][A-advanced]、[系统 picker][A-picker]、[Smart UI][A-smart]、[MiniApp 桥][A-miniapp]、[WebMount][A-webmount]、[AmberShell][A-shell]、[云任务客户端][A-cloud-task]、[云对话客户端][A-cloud-dialogue]。本轮未跨仓审查线上 amberd 的工具实现或实际部署，不能从客户端契约推断服务器全部可用能力。

### Amber 仍不能据现有证据承诺什么

- 未做准备就像普通 App 一样全局点击；绕过开发服务/签名/锁屏限制；任意时间保证后台持续控屏。
- 任意 App、横竖屏、系统界面和多指手势全覆盖。runner 内部比公开模型工具更宽，不能把内部路由全部算作模型可用功能；当前公开 `phone_act` 没有 poki 那样独立的 pinch / double_tap / 任意键盘组合接口。[A-tools][A-runner]
- 把一个 App 的成功路径拿来无条件重放。`PhoneRecipeStore` 每 App 只保留最近成功目标与最多 12 条步骤文字；executor 将其作为 `last_successful_path` 提供给模型，不是 poki 那种带条件的路线执行器。[A-recipe][A-executor]
- 单凭旧构建或历史报告证明 `aed70f8f` 的当前真机表现。仓内确有一次截图坐标关闭营销弹窗、重新截图确认并停止的历史验收记录，但那只覆盖 2026-10-11 的一个场景，本轮没有重跑，也未核实旧外部构建目录仍完整。[A-history]

## 5. poki 到底领先在哪里

| 维度 | 判断 | 原因与限定 |
| --- | --- | --- |
| 成功轨迹变成可执行路线 | **poki 实现更完整，最值得学** | 编译步骤、参数绑定、任务+初始上下文匹配、前后条件、读当前结果；匹配时导航不问模型，变化时交回。Amber 只有供模型参考的 App 级最近路径。没有复杂真机收益的横向实测。[P-routes][P-fast][P-task][A-recipe] |
| 给外部 agent 接 iPhone | **poki 交付更直接** | 标准本地 MCP，独立于它自己的 agent，Claude Code/Codex 可直接使用；本次 Amber iOS 看到的是内部工具 executor 与 MCP 客户端，没有等价的对外手机控制 MCP 服务。[P-daemon][P-tools][A-adapters] |
| 避免单独安装 XCTest runner | **poki 的 Mac 路线有优势** | 它直接使用开发者服务、AX 与 HID；Amber 需要安装签名 runner。但代价是 poki 要 Mac 常驻，不能简单移植成手机独立方案。[P-native][A-native] |
| 多指/键盘/开发工具广度 | **poki MCP 更宽** | 有独立 pinch、double_tap、按键组合、录屏、安装和诊断；其中有些仅有实现或模拟器验证，内置 Agent 也未全量开放。[P-tools][P-task][P-verification] |
| 中文输入与剪贴板恢复 | **poki 有值得参考的细节** | 编辑字段身份、读回后 Return、中文 composition 清空、尝试恢复剪贴板等；约 15 秒的公开 fill 记录不足以声称更快，自动接受粘贴提示也不宜照搬。[P-pasteboard][P-verification] |
| 减少模型往返 | **两边都有，不能算 poki 独有** | poki 有 batch，Amber 有 flow/goal/滚动收集；poki 额外有条件匹配时的零模型路线。[P-tools][A-tools] |
| UI tree / OCR / 截图 / 动作后新观察 | **功能层面接近** | 两边都具备，实际树质量、延迟、点击成功率需同机对比。[P-device][A-executor][A-client] |
| 手机独立入口与同机运行 | **Amber 架构更符合移动使用** | 原生客户端、同机控制与回原会话；poki 当前由 Mac 执行，iOS App 未交付。Amber 的连接准备与实际稳定性仍须验收。[A-native][A-settings][P-readme] |
| 直接使用系统业务 API | **Amber 覆盖更广** | 日历/提醒事项等可直接执行，避免为原生 API 已能完成的事去点 UI；App Intents/快捷指令也已有实现。[A-apple][A-intents] |
| 任务 UI、人工接管和个人 agent 功能 | **Amber 有现成覆盖** | Smart UI、Live Activity 接管/继续、同机任务与云任务消费；poki 更专注控制引擎。不能据功能数量推断流畅度更好。[A-smart][A-activity][A-cloud-dialogue] |
| 安全策略 | **各有保护，Amber 的部分边界更保守** | 都处理 stale/unknown/归属。Amber goal 将最终提交留给主模型、拒绝有密码锁屏输入；poki 可以配置密码 helper，普通 UI 动作也无逐项强制业务审批。不是完整安全审计。[A-tools][A-controller][P-device][P-unlock] |
| 速度、稳定性、成功率 | **无法排名** | poki 有小样本自测，Amber 有历史场景记录；没有同设备、同模型、同任务和网络条件的对照 |
| 普通 App Store 分发全局手机控制 | **两者都不能据此宣称解决** | 两条控制链均依赖开发者服务/私有接口；poki 的 Mac 签名公证不代表 iOS App Store 审核通过 |

上架判断是依据实现和平台规则做的风险推断，不是已发生的审核结论。苹果 [App Review Guidelines 2.5.1 / 2.5.2 / 2.5.4][Apple-review] 要求公开 API、容器/执行边界及正确的后台用途。Amber 的 App Intents、EventKit 等公开 API 路线可按平台规则评估，不能把这一点外推到 PhoneControl；poki 的 Mac CLI 分发与 iOS App Store 分发也应分开讨论。苹果对 [App Intents][Apple-intents] 的定位是把 App 自身动作提供给系统体验，并非赋予第三方 App 全局控屏能力。

## 6. Amber 值得借鉴的三项具体改进

以下为基于源码的粗略工程估计，按一名熟悉现有代码的工程师估算，不含排队、账号审批或全面设备兼容成本；本轮没有开始实现。

### ① 把成功路径升级为可核验路线，优先覆盖重复的只读与导航任务

**做法**：在现有 `PhoneRecipeStore` / `phone_run_flow` 上，按“目标模板 + 初始上下文 + App”保存语义步骤、参数、每步页面条件与最终结果条件。只在新观察唯一匹配时执行；从当前屏幕重新取结果，不能复用旧答案；页面变化就交回目标循环。发送/支付/删除继续沿用现有最终动作策略，不为省调用而扩大授权。

**收益**：这是 poki 相比当前 Amber 最明确的实现差距。频繁查固定字段、进某页、按固定结构收集列表，可跳过重复规划；不要把零模型推广为所有任务。[P-routes][P-fast][A-recipe][A-executor]

**可行性/工作量**：较高；复用现有 flow 和语义定位，先做 2–3 个受控场景约 **5–8 个工作日**。保留失败交回，不先建设泛用录制平台。

**上架风险**：存储/匹配机制本身不新增系统权限；跑 PhoneControl 的路线继承其现有分发风险。若以后复用于 EventKit 或 App 内 WebMount，应沿各自原有权限执行，不能绕过审批。

### ② 做小而真实的手机控制对照，先确定慢在模型、观察还是动作

**做法**：复用现有 action diagnostics / goal metrics，固定一台测试手机、模型、网络和起始状态，选 3–4 个日常任务；记录首次与重复运行、成功/失败、模型往返、读树/截图、动作、最终确认的耗时，保留失败分母。流程成功必须有新界面的业务结果，不能只看 `completed` 或 `sent`。无需先跑全量测试或建排行榜。[A-client][A-executor][P-eval]

**收益**：poki 给出了可审查的失败场景和 batch 对照，这一点值得学。Amber 当前不能仅凭“已有批处理”判断性能问题已解决；同样也不能从 poki 的视频判断更快。

**可行性/工作量**：高；整理既有指标与一份窄任务脚本约 **1–2 个工作日**，随后另约一次已授权的真机窗口。这里只涉及手机控制，不替代聊天流式 UI 卡顿的性能采样。

**上架风险**：本地、受控测试不要求新增产品权限；应避免把截图、剪贴板、密码或个人内容放入测试仓库。本文不授权实际操作用户手机。

### ③ 有明确外部控制需求时，先验证 Mac 直连 AX/HID 的小闭环

**做法**：若目标是“让 Mac 上的 agent 操作手机”，先做独立试验：配对开发服务 → 读 AX → 一个已授权点击 → 新观察确认。比较它和现有 XCTest runner 的启动成本、树完整度和触摸丢失情况，再决定是否需要可选 Mac companion/MCP。只借鉴接口与机制；复用代码前核对 poki 的 AGPL-3.0-only 和各依赖许可。[P-native][P-ax][P-stream][P-notices]

**收益**：可能省去独立 runner 安装/续签，并方便外部 agent 接入。**它没有现成解决 Amber 的同机替代问题**：poki 的入口是 Mac 的 usbmuxd/CoreDeviceProxy，Amber 的入口是手机本地回环 RemotePairing；访问方向、服务权限和生命周期不同。

**可行性/工作量**：Mac 试验中等，约 **2–3 个工作日**；若继续做可交付的配对、鉴权、取消与版本兼容，粗估再 **2–4 周**。同机能否使用同一组服务仍是未知项，不能先承诺可替换 XCTest，也不建议现在并行养第二套生产后端。

**上架风险**：私有开发服务风险仍在；独立分发 Mac 开发工具与把能力塞入 iOS App Store 包是两回事。此项应低于前两项，除非用户明确需要外部 agent 控手机。

## 7. 本轮检索与验证边界

- 搜索路径：先核对本地根、HEAD、Git 状态和 PhoneControl 实现，再用 `gh repo view/api` 读取 poki 元数据、release、全部公开 issue/PR 列表；读取固定 SHA 的源码快照、文档及官网。Git clone 出现 TLS 错误后改用 GitHub API tarball，没有执行下载代码或安装脚本。
- 核心源码覆盖：poki 的 daemon/device/platform、Rust bridge/AX/媒体/输入/剪贴板、Agent 模型配置/任务/路线/结果校验；Amber 的工具曝光→executor→controller→native/runner、系统工具与权限、自动化 intents、Smart UI/MiniApp/WebMount、终端与云任务客户端。
- 当前线程为 Hub worker，本轮未另派线程或 subagent，避免重复查阅与协调开销。
- 实际验证：源码调用链交叉检查、GitHub 当前公开元数据、作者测试说明与脚本核对、文档引用检查。没有运行构建、测试、安装、设备控制或模型任务；不存在本轮双方性能对照或真机验收结论。
- 结论可信度：**机制和源码差异高；作者自测描述中等；实际速度/稳定性排名、上架审核结果及同机 HID 替代可行性未知**。

## 资料链接

以下 poki 源码链接固定在本轮 SHA；Amber 源码链接固定在指定基线，私有仓库需要相应访问权限。

[P-repo]: https://github.com/JosssphZhou/poki
[P-api]: https://api.github.com/repos/JosssphZhou/poki
[P-commit]: https://github.com/JosssphZhou/poki/commit/f42f91d31eef2b4766230daaaa2fbd6053b79e9c
[P-site]: https://poki.bot/
[P-release]: https://github.com/JosssphZhou/poki/releases/tag/v0.1.0
[P-readme]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/README.md
[P-physical]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/docs/physical-iphone.md
[P-verification]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/docs/verification.md
[P-native-doc]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/native/NATIVE.md
[P-native]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/native/bridge/src/main.rs#L272
[P-ax]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/native/bridge/src/ax.rs#L61
[P-stream]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/native/bridge/src/stream.rs#L1
[P-pasteboard]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/native/bridge/src/pasteboard.rs
[P-apps]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/native/bridge/src/apps.rs
[P-platform]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/src/platform.mjs
[P-tools]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/docs/tools.md
[P-device]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/src/device.mjs
[P-daemon]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/src/daemon.mjs
[P-coordination]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/src/coordination.mjs
[P-agent]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/README.md
[P-task]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/task-runner.mjs
[P-verify]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/verify-result.mjs
[P-routes]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/routes.mjs#L225
[P-fast]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/fast/run.mjs
[P-model]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/model-config.mjs
[P-session]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/pi-session.mjs
[P-unlock]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/agent/unlock-device.mjs
[P-eval]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/bin/eval-first-call.mjs
[P-notices]: https://github.com/JosssphZhou/poki/blob/f42f91d31eef2b4766230daaaa2fbd6053b79e9c/THIRD_PARTY_NOTICES.md
[A-tools]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/PhoneControl/IOSPhoneControlToolCatalog.swift
[A-executor]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/PhoneControl/IOSPhoneControlToolExecutor.swift
[A-build-request]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/Chat/Generation/ChatGenerationRequestBuilder.swift
[A-adapters]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatToolExecutorAdapters.swift#L70
[A-native]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/native/iphone-control/src/lib.rs#L610
[A-runner]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/PhoneControlRunner/Sources/RunnerWDA.swift
[A-client]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/Packages/AmberPhoneControl/Sources/AmberPhoneControl/PhoneRunnerClient.swift
[A-controller]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/PhoneControl/IOSPhoneControlController.swift
[A-settings]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/PhoneControl/IOSPhoneControlSettingsView.swift#L240
[A-tunnel]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/PhoneControlTunnel/PacketTunnelProvider.swift
[A-credentials]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/PhoneControl/IOSPhoneControlCredentials.swift
[A-http]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/Packages/AmberPhoneControl/Sources/AmberPhoneControl/RunnerHTTP.swift
[A-unlock]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/PhoneControlRunner/Sources/RunnerWDA.swift#L1091
[A-recipe]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/PhoneControl/PhoneRecipeStore.swift
[A-activity]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/AgentActivityControlIntents.swift
[A-intents]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSAppIntents.swift
[A-automation]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSConversationAutomationIntents.swift
[A-wake]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSWakeAppIntents.swift
[A-shortcut]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/Automation/IOSShortcutAuthoring.swift
[A-apple]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSAppleIntegrationsView.swift#L317
[A-advanced]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatAdvancedToolOperations.swift
[A-picker]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSPersonalContextPicker.swift
[A-smart]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSIntelligentUIProtocol.swift#L267
[A-miniapp]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/IOSMiniAppBridgeRuntime.swift
[A-webmount]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/WebMount/IOSWebMountToolCatalog.swift
[A-shell]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/Infrastructure/Terminal/IOSAmberShellExecuteExecutor.swift
[A-cloud-task]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/MacGatewayCloudTasks.swift
[A-cloud-dialogue]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/iosApp/iosApp/MacGatewayCloudDialogue.swift
[A-history]: https://github.com/soul99soul-glitch/AmberAgent-iOS/blob/aed70f8f5e61dec15e305a8b8e3f68dffc5b4b94/docs/iphone-control-evidence/popup-close-20261011.json
[Apple-review]: https://developer.apple.com/app-store/review/guidelines/#software-requirements
[Apple-intents]: https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents
