# 手机控制：复用现有 VPN 与蜂窝网络验证

2026-10-11。承接用户“按需求继续”，目标是随身使用、保留已有上网 VPN、减少手动操作。范围是当前已授权 iPhone 和 Amber；不扩大到其他设备或对外发送消息。保留工作目录已有修改，不提交或推送。

## 当前证据

- 原内置隧道在关联 Wi-Fi 后已通过 greeting、认证 runner 和界面读取；同一版本此前在 SYN 阶段收到本机 RST。具体系统接收条件尚未证实。
- 当前手机有 Clash Mi 1.0.30，可用于验证兼容 VPN。已有开源 `tun.loopback-address` 配置不能证明 RemotePairing/XCTest 也兼容。
- Devin / Opus 5.5 已恢复，本轮只读复核识别两处现有约束：控制器总会启动自己的 NE，native 仅匹配 10.7.1.1。它建议先验证候选 greeting，不直接推广为生产支持。
- 10:56 UTC设备通过 `localNetwork` 连接；USB列表为空。关闭Wi-Fi前需要独立恢复通道，不能把Mac同时失联误判成手机控制失效。

## 阶段与验收

1. **诊断能力与现有 VPN 验证。** 保留生产选路，新增仅启动参数可触发的无凭据 greeting：UDP connect/local_addr读取实际选路，不发UDP报文；要求唯一、UP的utun，在实际TCP socket上绑定接口。先检验现有Clash Mi配置；只增加必要的本机回环覆写，保留原配置。greeting被拒绝则停止这条接入，不继续发送配对信息。
2. **条件成立后接入借用模式。** 只有greeting通过才验证配对、动态TLS端口、RSD、runner、读树和停止。完整通过后增加用户可见的连接来源选择；借用模式不能启用或停止Amber或其他App的VPN，中途失效不自动切换。
3. **蜂窝切换实验。** 同一手机会话记录native状态、runner签名状态/只读观察、手机网络状态、模型连接。Wi-Fi建立后再切蜂窝；连接失败后不重启runner掩盖。实验有时限并恢复原网络状态。USB恢复通道未就绪时只准备实验，不关闭唯一管理链路。
4. **独立review与交付。** 每阶段检查调用链、归属和清理；如有UI修改检查普通/辅助字号、布局及真实接线。明确区分测试、签名构建、安装、协议、模型及设备行为验收。失败路线保留证据，不增加猜测重试或新后端。

## 证据与边界

- 本轮记录放在 `build/transport-portability-20261011/`，仅记录固定阶段、状态和必要UI；不导出凭据或订阅链接。
- 无VPN电脑USB和外部路由器反射属于已知替代架构，本轮不把它们作为随身独立控制产品的默认方案。
- 暂时关蜂窝的SideStore做法不等于持续联网控制；不自动安装快捷指令或改变用户其他网络配置。

## 2026-10-11 本轮进展

### 已完成的诊断入口

- 新增 `amber_iphone_control_inspect_routed_handshake`，只由显式诊断启动参数调用。生产配对及动态 TLS 仍走原有固定地址选路。
- 原生 37 项测试通过，独立 review 核对了不发 UDP 数据、唯一 UP utun、实际 TCP 绑定及不退回普通网络。签名 Release 构建及覆盖安装通过。
- 覆盖安装前后 363 个聊天文件的大小和修改时间一致，没有缺失或新增。
- 未连接本地 VPN 的设备对照返回 `loopback_route_unavailable`，在发送 greeting 之前停止。这只是负对照，不是 Clash Mi 兼容性结论。

### Clash Mi 方案的源码依据与限制

- [Clash Mi 固定版本](https://github.com/KaringX/clashmi/tree/daef7be6c40d49a98a174a82c10599e163e71afd) 默认 tun 地址是 `172.19.0.1/30`，与 Amber 当前固定 `10.7.1.1` 不同。其公开 iOS Extension 交由 Libclash 运行。
- [sing-tun 的 gVisor TCP 路径](https://github.com/metacubex/sing-tun/blob/27e28c30de350cff262e32d9ed92b87215a0ff7c/stack_gvisor_tcp.go#L48) 在 forwarder 前交换地址、更新校验和并回注数据包。Devin 复核后撤回了先前“终止 TCP 再拨回本机”的推断，主 agent 已直接读源码核实。
- 手机已安装的 1.0.30 是否包含该内核、Libclash 对 tun 字段的合并顺序，无法仅凭公开仓库确认；必须用这部手机的 greeting 结果判定。
- 独立覆写使用[固定 commit 的三行配置](https://github.com/tom-snow/Sidestore-ClashMi/blob/02b5542ccbbb4453c5958c765f061d4d56c48eab/profile_overwrite_min.yaml)。不导出或改写订阅。
- Opus 5.5 的第二轮 review 发现：自定义覆写默认不再追加 App 设置。验证流程已限定当前为“内置-覆写”才新增，并将新条目的“追加覆写”设为“内置-覆写”；已有自定义选择则停止核对，防止影响原来的配置语义。
- 配置验证走 Amber 手机上的正常模型和手机工具。Mac 只负责启动已授权验证、读阶段日志及截图，不运行 XCTest 或模型控制循环。`phone_add_app` 若实际调用，会将 Clash Mi 持久加入可控应用列表，需如实记录。

### 首次配置验证与 UI 前置修复

- 正常模型链已查到 Clash Mi 并通过 `phone_add_app` 加入范围，启动 runner 后进入核心设置及覆写列表。确认只有两个内置覆写，当前为“内置-覆写”。没有新增覆写、没有改变 Clash Mi 的未连接状态；最后 `phone_stop`，runner shutdown accepted。
- 真实标签 `覆写\n内置-覆写` 的原始 LF 导致 NSPredicate 解析失败，动作 `not_sent`。包内 literal 已仅补 LF 转义；真实 Foundation 解析红绿回归与独立 review 通过。此处不改变定位协议，不自动降级坐标。
- “添加”ref 和新截图坐标点击有执行回执，但 UI 未变化。截图中的系统 BG 进度卡位于顶部；其是否实际拦截目标点击尚未通过对照验证，不把模型的归因当作事实，也不能据此判 Clash Mi 回环不兼容。
- 文案、系统按钮及源码均确认该卡来自 `BGContinuedProcessingTask`，不来自 Amber 的自定义 ActivityKit 布局。Apple 公开接口没有收起方法；[iOS 27 用户手册](https://support.apple.com/en-ca/guide/iphone/iph28f50d10d/ios) 说明展开活动可向上滑收起。
- 增加截图绑定的 `swipe_point`，调用既有 runner `/swipe`，固定 300ms。复用 tap_point 的最新观察、前台 App 和屏幕尺寸复验；不改变后台执行方式、不会自动滑动或重试。完整包 47 项测试通过；工具解析、目录及 ChatKernelRunHost 三组模拟器测试共 45 项通过，Opus 5.5 独立 review 无阻断。真机验证另记。
- 系统 BG 卡的标题改为固定品牌“Amber”，副标题仍报告阶段，避免完成副标题与“正在生成”标题同时出现。无需增加状态或修改共享 KeepAlive API。
- 下一次配置验证仅允许一次基于新截图的上滑，并检查卡片收起、前台仍为 Clash Mi 后才继续。若未收起或前台变化则停止；完整 VPN 借用模式仍以 greeting 通过为前提。

### 查询挂起现场与日志失败回归

- 11:24 UTC，另一轮手机任务停在只读 `phone_apps`，没有 `phone_act`。记录、截图及生命周期元数据已保留；没有持久化后台 job。普通重启后实际收口为 `interrupted/process_killed`，没有重放工具或自动续跑手机动作。安装前后聊天目录条目数均为 370，无缺失；恢复过程中有元数据更新，不能称所有文件字节不变。
- 该次手机挂起的具体栈未取得。NE preferences continuation 和 native join 存在不受目录 30 秒计时覆盖的等待，但没有证据指向它们，未添加猜测性超时或重试。sysdiagnose 需要本机管理员认证，本轮取消采集，未扩大权限。
- Opus 5.5 用链接生产 FFI 的主机 harness 实造 stderr `EPIPE/EIO`：日志 panic 使 worker 退出，状态留在 connecting、目录留在 pending，之后 stop 可能跨 C 边界 abort；iOS Release 库的 panic unwind 符号也已核对。这是独立复现的真实缺陷，尚不能断言是上述真机挂起的原因。
- 修复仅涉及两处 native 日志：先提交状态并释放锁，再做忽略 IO 错误的写入；runner 启动日志同样不能因写失败 panic。独立子进程回归先红后绿，全 native 38 项通过；独立 review 无阻断。没有引入新的日志系统、重试或超时。阻塞式 stderr 背压尚无现场证据，不将它算作已解决。
- 含上述修复的签名 Release 已覆盖安装。本轮后续手机任务以无 console 的普通启动方式执行，避免把有限时长的开发控制台连接留给用户长期任务。

### 配置链路真机结果

- 新验证 run `A2F753D1-8249-4D23-91A9-083A9E706C13` 已 completed，`phone_apps` 约 1 秒完成；手机端正常模型完成打开、导航、输入、保存、复核和 `phone_stop`。
- 多行标签 `覆写\n内置-覆写` 的 ref 点击已通过真机，后续进入覆写列表；“追加覆写\n内置-覆写”在保存、重新打开后仍存在。新增条目“Amber 本机回环”，当前选择由“内置-覆写”切换至它，追加设置保留“内置-覆写”。没有改 DNS、订阅、节点或分流规则。
- 本次系统卡片在操作时已收起，未执行 `swipe_point`，因此不能把这次成功归功于上滑，也没有证明上一轮点击失败一定来自遮挡。一个无 label 的返回容器点后无变化，用新截图定位 `tap_point` 后成功返回，验证了坐标点击的实际页面效果。
- 官方 `clashmi://connect?background=true` 启动在 VPN 建立前报错：`dns.nameserver-policy[22]` 中 `+.bilivideo.+` 不合法。新增三行 YAML 不含 DNS；公开内置设置也不包含该键，但最终合并位于非公开 Libclash，仍需要恢复原选择作对照。尚未执行通过 Clash Mi 的 greeting，不把此结果解释为回环不兼容。
- 对照 run `0F9AAC83-5863-49CF-A952-4F87F8A81846` 在约 18 秒内完成：关闭对应错误提示、仅恢复“内置-覆写”、重新观察确认，`phone_stop` 返回 `cleanup_complete=true`；临时条目保留但未选中。含日志修复的新版本实际跑通了此次 runner、观察、点击和清理。
- 恢复原选择后，冷启动 Clash Mi 并通过同一官方 connect 链接测试，等待超过 60 秒，实际结果为 `startVPNTunnel status timeout`，主界面显示“未连接”。**此结果与前一次 DNS 错误不同**，只能证明当前原选择也没有成功启动，不能据此断言 DNS 报错来自原订阅。未更改 DNS 或订阅来绕过该阻断。

### 本轮交付与剩余验证

- 最终已签名、安装并正常打开的主 App SHA-256：`3b86698f4844de7c2aa4ee00040bc51201d0fcdb0b9eb7a7c039ce81b6bd3199`。主 App 与 NE 的 Bundle ID、Team、设备 profile 和 entitlement 已核对。
- 已验证：应用发现、多行元素定位、截图坐标返回、配置输入/保存/重读、正常停止；native 日志故障红绿回归及独立 review；包 47、App 45、native 38 项测试通过。
- 未验证：`swipe_point` 的真机上滑、复用 Clash Mi 的 greeting/配对/runner、纯蜂窝启动、Wi-Fi 到蜂窝的会话保持。当前 USB 仍未连接，Mac 管理链路只有 Wi-Fi，未关闭该链路做蜂窝实验。
- Phase 1 的诊断入口与 UI 前置修复已交付；候选 VPN 的运行被其自身启动错误阻断，因此 Phase 2 不进入生产接线，Phase 3 保留待测。没有证据支持“必须永远依赖 Wi-Fi”，也没有证据支持“任意上网 VPN 都能直接复用”。
- 未提交或推送。所有已有未提交及未跟踪工作保留；诊断原始记录留在本机 build 目录，不纳入提交。

## 2026-10-12 外出 5G 启动失败反馈

- 用户报告：离开 Wi-Fi 后，5G 下无法启动自动化服务，也没有出现此前输入锁屏密码的系统步骤。此为用户现场反馈；本次尚未取得具体工具失败 `code/detail`，不能把上一轮 `ConnectionRefused/os=61` 直接冒充本次错误。
- 本轮只读 `devicectl list devices` 确认目标 iPhone 当前 unavailable，无法从 Mac 读取此次手机日志或执行蜂窝对照。没有重新安装、重新配对、改 VPN/网络或触发手机业务动作。
- 独立源码审查确认，生产路径为固定 `10.7.0.1:49152` → Amber 内置隧道 → RemotePairing → RSD/XCTest；只要求绑定到地址 `10.7.1.1` 的唯一活动 utun，没有 en0/Wi-Fi 硬拦截。en0 选择只存在于显式直连诊断 probe，不能作为生产根因。
- TCP 连接在 RemotePairing 验证及 runner 启动之前；若本次仍为连接拒绝，后续系统确认阶段尚未到达。正常启动仅验证已有配对，不自动新建配对。没有原密码框内容，无法从源码确定用户所说系统提示的具体归属；未弹提示本身不能证明配对失效。
- 当前可观测分岔：`connection_failed / ConnectionRefused / os=61` 为初始开发端口连接拒绝；`loopback_route_unavailable` 为所需 utun 路由缺失；通用“本机连接启动失败/10 秒超时”停在 NEVPN 状态层。后者未保留扩展断开详情，是诊断能力的独立缺口，不是此次 5G 失败的已证根因。

### 开源对照与下一次实机变量

- [StikJIT 当前集成说明](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md#minimum-built-in-stikjit-user-instructions) 的无 Wi-Fi 方法是先开蜂窝、连接 LocalDevVPN，再开飞行模式。它不证明蜂窝持续联网时可以新建连接；对需要在线模型的 Amber 不能直接作为可交付方案。
- [StikDebug PR #457](https://github.com/StikDebug/StikDebug/pull/457) 已关闭、未合并。最后的 [29eb183 固定提交](https://github.com/StikDebug/StikDebug/commit/29eb18386149364159d5253a2ab8f377afea032e) 纠正了早先“换网络即重连”的假设，报告既有本地连接可跨 Wi-Fi/蜂窝存活，而蜂窝下 fresh connect 失败；该提交同时注明未完成设备验证，因此这里只把它作为候选实验依据，不将作者的监听器解释提升为 Apple 已证规则。
- [Madeira 的 JIT 说明](https://github.com/willfaust/Madeira/blob/main/docs/JIT.md) 也描述启动前关蜂窝、成功后恢复的路径，但使用 `10.7.0.1:62078` 的 lockdown；协议入口与 Amber 不同，不能直接照搬为已验证功能。
- 下一次需要实机区分三个不同问题：纯蜂窝新建；Wi-Fi 建立后切蜂窝、保持同一会话；短暂离线建立后恢复蜂窝。每项分别检查 greeting、认证 runner、新界面读取及在线模型可用性，不能只看 VPN 图标或 TCP 连接。后两项尚未在本机证明可用。
- Amber 当前任务结束会关闭自己的开发会话和隧道。若实测证明存活路径成立，再评估显式会话保留及其停止/权限/后台边界；本轮不直接加入自动重试、常驻连接或新的控制后端。

本轮只完成代码/已有设备证据/开源对照复核，未取得本次问题的可自动复现现场，因此没有修改生产代码，也不宣称 5G 问题已修复。
