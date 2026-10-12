# 同机 iPhone 控制：不用 LocalDevVPN 的开源路线复核

日期：2026-10-11。范围：非越狱 iPhone、Amber 自行启动开发服务与 XCTest 控制。仅调研公开仓库、源码和维护者说明；未改产品、设备、VPN、路由器或签名配置，未运行候选项目。下文的开源项目运行结果均为作者报告，不是 Amber 真机验收。

## 判断

“不用 LocalDevVPN”至少有三种不同目标，不能混为一谈：

| 目标 | 当前证据 | 判断 |
| --- | --- | --- |
| 不再单独安装或切换 LocalDevVPN App，仍允许系统本地隧道 | Jitterbug 自带 `NEPacketTunnelProvider`；旧版 StikDebug 曾自带相同能力 | 有可审查的既有实现，最符合“一部手机、一处操作”的易用性目标；仍是 VPN，需要相应签名能力，不能据此承诺长期系统兼容 |
| 手机不启用任何 VPN，但允许局域网外部设备 | `xddxdd/sidestore-vpn`、KoolCenter 插件在 Linux/路由器反射数据包 | 有可审查实现；可试 Amber 的 RemotePairing / CoreDeviceProxy，但没有已验证 XCTest 闭环证据 |
| 完全本机、不用 VPN、不用外部设备，冷启动取得 XCTest 跨 App 控制 | 本轮检索没有找到满足所有条件、且当前 iOS 验证过的实现 | 不能证明数学上不可能；也不能把 JIT、普通 localhost 服务、已启动 runner 当作已解决 |

LocalDevVPN 不是远端 VPN 服务：其核心只是创建本地虚拟接口，接收特定路由的数据包，交换源/目的 IPv4 后写回系统。[当前官方源码](https://github.com/jkcoxson/LocalDevVPN/blob/af3fd697803ada4ac2b8d518358f5ab0a534844c/TunnelProv/PacketTunnelProvider.swift#L48-L97) 与 [Jitterbug 早期实现](https://github.com/osy/Jitterbug/blob/b0449f18c9663c732ee16beefe6df60fa0cea137/JitterbugTunnel/PacketTunnelProvider.swift#L23-L93) 都可直接核查。因此，换一个 `127.0.0.1` 地址不等价于这层网络来源变化。

## 当前仓库元数据

由 `gh api repos/<owner>/<repo>` 现场查询；Stars/Forks 只反映关注度，不作为运行正确性证据。`pushed_at` 为 UTC。LICENSE 未识别或缺失时没有猜成 MIT。所有源代码比较均固定到下文 commit。

| 仓库 | Stars / Forks | License | pushed_at |
| --- | ---: | --- | --- |
| [StikDebug/StikDebug](https://github.com/StikDebug/StikDebug) | 2660 / 266 | AGPL-3.0 | 2026-10-10T23:53:13Z |
| [StikDebug/StikJIT](https://github.com/StikDebug/StikJIT) | 25 / 6 | MPL-2.0 | 2026-09-27T21:01:48Z |
| [SideStore/SideStore](https://github.com/SideStore/SideStore) | 6767 / 523 | AGPL-3.0 | 2026-09-20T03:17:35Z |
| [LiveContainerMirror/LiveContainer](https://github.com/LiveContainerMirror/LiveContainer) | 83 / 16 | AGPL-3.0 | 2026-09-26T11:46:37Z |
| [osy/Jitterbug](https://github.com/osy/Jitterbug) | 1562 / 138 | Apache-2.0；已归档 | 2022-09-14T05:43:51Z |
| [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | 531 / 116 | MIT | 2026-10-08T22:26:04Z |
| [jkcoxson/LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | 148 / 42 | 自定义 StosVPN License，GitHub NOASSERTION | 2026-09-03T03:47:37Z |
| [SideStore/StosVPN](https://github.com/SideStore/StosVPN) | 397 / 180 | 自定义，GitHub NOASSERTION | 2026-03-31T07:54:50Z |
| [xddxdd/sidestore-vpn](https://github.com/xddxdd/sidestore-vpn) | 100 / 14 | Unlicense | 2026-05-21T08:05:58Z |
| [DemoJameson/KoolCenter.SideStoreVPN](https://github.com/DemoJameson/KoolCenter.SideStoreVPN) | 7 / 0 | MIT | 2026-09-25T02:10:34Z |
| [shiqi917/sidestore-vpn-tailscale](https://github.com/shiqi917/sidestore-vpn-tailscale) | 4 / 1 | Unlicense | 2026-10-02T16:54:47Z |
| [tom-snow/Sidestore-ClashMi](https://github.com/tom-snow/Sidestore-ClashMi) | 239 / 23 | 未声明 | 2026-02-13T15:27:40Z |
| [NRG-Wardog/sidestore-auto-refresh](https://github.com/NRG-Wardog/sidestore-auto-refresh) | 142 / 14 | 仓库元数据 MIT；其 SideStore/LiveContainer 组件另有许可证 | 2026-10-08T13:35:48Z |
| [CelloSerenity/JITserver](https://github.com/CelloSerenity/JITserver) | 16 / 4 | API 未识别；README 声称 AGPL-3.0 并附非商用限制，不能当标准 AGPL | 2026-10-07T23:21:07Z |
| [willfaust/TouchSynthesis](https://github.com/willfaust/TouchSynthesis) | 107 / 13 | 未声明 | 2026-08-05T01:50:22Z |
| [FrizzleM/SideInstaller](https://github.com/FrizzleM/SideInstaller) | 940 / 80 | 自定义非商用许可证，GitHub NOASSERTION | 2026-10-10T15:50:17Z |
| [xXWapixelXx/Mirage-updates](https://github.com/xXWapixelXx/Mirage-updates) | 128 / 8 | 未声明；主要为发布/文档仓库 | 2026-08-10T11:11:44Z |

`LiveContainer/LiveContainer` 的 GitHub API 此次返回 404，故表中明确记录可读镜像的数据，不能冒充原仓库 Stars/Forks。PairVPN 官网可访问，本轮未找到其官方开源代码仓库，故不编造 Stars、许可证或提交时间。

## 候选逐项复核

### StikDebug / StikJIT：减少外部工具，不消除隧道

StikDebug 当前支持声明为 iOS 17.4+，README 将 loopback VPN 列为前置条件；`TunnelManager` 将目标设为配置 IP 的 49152 端口，失败提示仍要求 LocalDevVPN。StikJIT 虽能内嵌 XCFramework 和 helper extension，其集成文档也明确要求 LocalDevVPN 连接，默认仍是 `10.7.0.1:49152`。JIT 成功并不意味着建立 XCTest 控制会话。[StikDebug README 固定版本](https://github.com/StikDebug/StikDebug/blob/775fba15f3fbadc18f7f1444dc6ffb1566adaa4c/README.md)、[连接实现](https://github.com/StikDebug/StikDebug/blob/775fba15f3fbadc18f7f1444dc6ffb1566adaa4c/StikDebug/Services/TunnelManager.swift)、[StikJIT 集成约束](https://github.com/StikDebug/StikJIT/blob/32287268fa5824f9edce4cb359f5833ce0cf7b00/INTEGRATION.md#L396-L406)。

旧版自带 VPN 的删除是发行/签名选择。维护者在 [#306](https://github.com/StikDebug/StikDebug/issues/306) 解释删除相关 entitlement 以支持免费账号侧载；这支持“把隧道放回 Amber”是工程整合路线，而不是新的无 VPN 漏洞。[#438](https://github.com/StikDebug/StikDebug/issues/438) 的“插电脑免 VPN”请求最终指向 JITserver，仍依赖外部电脑。

### Jitterbug：内嵌回环的最小可读参考

源码直接包含 `NEPacketTunnelProvider`，配置目标网段、排除默认路由，读出 packet 后交换地址再写回。README 区分完整版和没有 Network Extensions 的 Lite：Lite 借助另一台 iOS 设备；自调试模式需要隧道。工程 deployment target 为 iOS 14.0/14.4，仓库 2022 年归档，不能把它作为 iOS 27.2 的完整开发协议实现；可参考其小型网络扩展，继续使用 Amber 已跑通的 idevice/XCTest 链。[README](https://github.com/osy/Jitterbug/blob/b0449f18c9663c732ee16beefe6df60fa0cea137/README.md)、[PacketTunnelProvider](https://github.com/osy/Jitterbug/blob/b0449f18c9663c732ee16beefe6df60fa0cea137/JitterbugTunnel/PacketTunnelProvider.swift)。

它的价值是免单独 VPN App、免用户来回跳转；不是免系统 VPN 权限。许可证为 Apache-2.0，较直接搬自定义许可的 LocalDevVPN 更容易做清晰的来源管理。

### SideStore / LiveContainer：产品集成参考，不是 XCTest 替代

SideStore 官方安装文档要求 iOS 15+，源仓 README 的构建最低版本仍写 iOS 14+；两者口径不同。无电脑刷新依赖专用 VPN，不能把“untethered”读作“不用 VPN”。[官方安装前置条件](https://docs.sidestore.io/docs/installation/prerequisites)、[源码 README](https://github.com/SideStore/SideStore/blob/0dd743f75afc358b0ba4a002feb5f19474492371/README.md#L13-L34)。

LiveContainer 的 JIT-less 是把重新签名的 guest 可执行文件转成 dylib，在宿主内加载；不是绕过设备服务，也不是控制手机现有安装的 App。文档明确 guest entitlement 不会转移、guest 不具备独立沙箱、扩展有限制。要求把目标 App 重新装入容器会改变当前产品目标，不建议用它替代系统跨 App 控制。[镜像固定 README](https://github.com/LiveContainerMirror/LiveContainer/blob/4dbe0f9a626de801184a42c0be8d2cb105058e3d/README.md)。

### idevice / CoreDeviceProxy：不同入口值得探测，但不是库名即绕过

idevice 的 `TcpProvider` 本质是 `TcpStream::connect`；库支持 USB、TCP、RSD，并不会自动获取特殊网络来源。当前固定 commit 与 Amber 既有依赖相同。换 libimobiledevice、pymobiledevice 或 StikJIT 包装层本身，不能解决服务端拒绝自身来源的问题。[provider.rs](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/idevice/src/provider.rs#L62-L125)。

但“RemotePairing 入口拒绝”不自动证明 “经典 lockdown → CoreDeviceProxy 入口也拒绝”。后者使用已有经典配对记录，通过 `:62078` 启动 CoreDeviceProxy，再走 CDTunnel/RSD，值得做有限、只读 A/B 探测。NRG-Wardog 的项目确实使用这条路线，但当前 README 仍要求 LocalDevVPN、Wi-Fi，并明确当前版本未完成部分实机发布验证，不能引用它证明免 VPN 可用。[固定 README 的真实依赖与状态](https://github.com/NRG-Wardog/sidestore-auto-refresh/blob/7aff2fcc6163b91c6a4e8f6403de90e003e0baab/README.md)。

SideInstaller 的维护记录给出更具体的反例：`createListener` 的新端口只在 en0 可达，直连 en0 的 TLS 成功后立即收到 `close_notify`；维护者因此怀疑自连接检查，转向 CoreDeviceProxy。它对直接 `127.0.0.1:62078` 是否可用仍留有疑问。这是另一项目的诊断记录，不能当作对所有 iOS 的已证定理。[NOTES 固定版本](https://github.com/FrizzleM/SideInstaller/blob/9c5aeff24e396f2873888b4229717f887249204b/NOTES.md)、[DeviceConnection 实现](https://github.com/FrizzleM/SideInstaller/blob/9c5aeff24e396f2873888b4229717f887249204b/ios-app/DeviceConnection.swift)、[iOS 27 双机 lockdown Pair 失败报告](https://github.com/FrizzleM/SideInstaller/issues/52)。

### 路由器反射：真正不用手机 VPN 的明确候选

`xddxdd/sidestore-vpn` 是 Linux TUN 工具：收到去 `10.7.0.1` 的 IPv4 包后交换源/目的地址。手机只需要路由能到这台 Linux 设备；不要求手机装 VPN。KoolCenter 插件用每台设备对应的 DNAT/SNAT 规则完成相近的局域网发回过程。源码分别可以核查，而不只是宣传截图。[Rust 核心](https://github.com/xddxdd/sidestore-vpn/blob/1cb5f5d94e6f0baf4ed432d30b926bb0c39a9904/src/main.rs)、[部署拓扑](https://github.com/xddxdd/sidestore-vpn/blob/1cb5f5d94e6f0baf4ed432d30b926bb0c39a9904/README.md)、[KoolCenter 规则](https://github.com/DemoJameson/KoolCenter.SideStoreVPN/blob/ec1b14308f28d52ba7111756ab94376981dfdfc4/sidestorevpn/scripts/sidestorevpn_config.sh#L116-L155)。

这改变了请求的真实网络入口，具备绕开 self-origin 条件的合理机制。它依赖同网段 Linux/路由器和可控路由；不是纯手机方案，离开此网络便失效。现有项目主要验证 SideStore 安装/刷新，未给出 Amber 的 iOS 27.2 XCTest 会话证明。主方案没有采用 LAN 实验；若以后验证，应使用覆盖动态端口的包反射，或明确实现 RemotePairing 新返回 TLS 端口的转发。只转发初始49152无法证明后续链路可用，也不能据此判 LAN 路线失败。

### Tailscale / ClashMi / PairVPN：合并已有网络工具，有不同依赖

`sidestore-vpn-tailscale` 适配 SideStore 新版 Remote Endpoint，Linux Docker 节点反射数据包；手机仍启用 Tailscale VPN。它的目标是免切 VPN，不是免 VPN；远端转发还可能增加延迟和可用性依赖。[固定 README 和拓扑](https://github.com/shiqi917/sidestore-vpn-tailscale/blob/94cf7c15d37cec8ee3709464894c2225c58e17b0/README.md)。

ClashMi 方案也是在现有 VPN 配置中增加 SideStore 对应转发规则；只有用户本来就使用该工具时才可能减少切换成本。它没有 XCTest/iOS 27.2 无 VPN 证据，配置示例无许可证，不应直接当产品依赖搬入。[固定配置说明](https://github.com/tom-snow/Sidestore-ClashMi/blob/02b5542ccbbb4453c5958c765f061d4d56c48eab/README.md)。

PairVPN 官方 FAQ 的模型是另一台手机/电脑做服务端、当前设备做 VPN 客户端，建立两设备隧道。它既没消除 VPN，也没消除外部设备；本轮没找到其官方开源实现或同机 XCTest 证明，排除作为当前简化方向。[官方 FAQ](https://pairvpn.com/faq)。

### TouchSynthesis：可研究降低控制开销，不证明能关 VPN

该项目报告在 iPhone 13 Pro / iOS 26.3 通过同一进程充当 IDE 与 runner，`dlopen XCTest` 并建立 testmanagerd 会话。初始化仍为 LocalDevVPN → lockdown → CoreDeviceProxy → RSD → 两条 DTX 控制连接。动作优先调用 `XCSynthesizedEventRecord.synthesizeWithError:`；截图调用已建立会话的 daemon proxy。这是比“JIT 等于控制”更接近目标的真实实验。[固定 README](https://github.com/willfaust/TouchSynthesis/blob/688c0f40c270d71166db3fd6858071f09003627d/README.md)、[SelfRunner](https://github.com/willfaust/TouchSynthesis/blob/688c0f40c270d71166db3fd6858071f09003627d/TouchSynthesis/TestManager/SelfRunner.swift)、[动作入口](https://github.com/willfaust/TouchSynthesis/blob/688c0f40c270d71166db3fd6858071f09003627d/TouchSynthesis/TouchSynthesizer/TouchSynthesizer.m#L854-L875)。

重要限制：代码仍持有两条 DTX/RSD proxy 和 heartbeat，并没有证明拔掉隧道后自动化权限仍保留。README 的“动作不经过 tunnel”不能推出“VPN 可以关掉”。另外没有 LICENSE，不宜直接复用源码，但可研究原理并独立验证；它也有提前返回动作成功的语义，不能把整套实现直接替换 Amber 当前以真实回执为准的控制链。[DTX 持有关系](https://github.com/willfaust/TouchSynthesis/blob/688c0f40c270d71166db3fd6858071f09003627d/TouchSynthesis/TestManager/TestManagerClient.swift#L77-L145)、[代理和 heartbeat 清理](https://github.com/willfaust/TouchSynthesis/blob/688c0f40c270d71166db3fd6858071f09003627d/TouchSynthesis/idevice/IdeviceTunnel.m#L503-L544)。

Mirage 的公开 Setup 也区分付费签名的内置 VPN 与免费侧载的 LocalDevVPN；说明内嵌是可用的产品方向，没有展示免 VPN 的实现，且仓库主要是发布材料。[固定 Setup](https://github.com/xXWapixelXx/Mirage-updates/blob/37adcf5b9c7ee67cae78ebafdb5aa7a1459175cb/SETUP.md)。

## 推荐的最小实验与停止条件

1. **有限验证不同入口，而不是继续随机换 IP。** 在不重配对、不删记录的前提下，若已有合法经典 lockdown 记录且旧证据未覆盖，VPN 关闭时分别对已发现的本机地址做 `GetValue`、已有记录 `StartSession`、CoreDeviceProxy → RSD，只做查询。每种地址/入口一次 bounded 尝试，记录在哪一层失败。若 `:62078` 同样在首包复位，或 CoreDeviceProxy 返回 self-origin 拒绝，就停止这一分支。TCP 能连通不是成功标准，读到可信设备信息与 RSD 才是。
2. **外部来源对照（未纳入当前主方案）。** 未来若验证，必须覆盖 RemotePairing 初始入口和 `create_tcp_listener` 返回的动态 TLS 端口；可采用已研究的包反射，或另外设计受限的动态端口转发。仅初始49152的 TCP relay 不足以验收到 RSD。Amber 原配对协议保持端到端，不由 relay 终止认证。届时先验收到 RSD/应用列表，不点其他 App；成功也只证明“免手机 VPN 但依赖外部节点”，不能叫纯本机方案。
3. **易用性优先的主线。** 如果目标是少装 App、少点开关，优先验证 Amber 自带一个小型 packet tunnel extension；复用已成功的 RP/XCTest 链，不同时引入第二套自动化后端。测试只路由开发 peer，外网流量正常、任务结束释放、其他 VPN 的行为明确。签名能力和系统首次权限需先核实，不假设现有 team ID 自动包含 entitlement。
4. **自 runner 仅做后续独立实验。** 若需要减少 runner 安装/进程开销，研究 TouchSynthesis 的同进程启动思想，并独立实现最小 PoC：初始化→读取界面→一个无副作用动作→再读取→关闭 VPN 后重新查询。仅看调用返回值不够；还要确认 testmanagerd 不撤销会话、后台进程不被挂起。当前没有证据支持为了去 VPN 先重写整个 runner。

本轮建议：保留“纯本机免 VPN 尚未证实”的诚实结论；把 CoreDeviceProxy 直接入口作为有边界的排除实验，把内嵌本地隧道作为最短产品简化路线，把 LAN relay 作为真正免手机 VPN 的可选方案。不要默认叠加多种 VPN、多个 runner、自动重配对或隐式切换网络。

## 检索记录

使用 GitHub 仓库、issue、code 搜索和 primary web 来源。搜索覆盖 `StikDebug VPN`、`SideStore without VPN`、`idevice localhost/loopback`、`remotepairing 127.0.0.1`、`remotepairing IP_BOUND_IF`、`ios jit no vpn`、`ios on-device automation`、`RPPairing without VPN`、`lockdownd loopback`、`self-origin remoted`，并读取候选 README、源码及 issue 评论。检索无结果只能作为“本轮没有发现”的范围说明，不能证明不存在。
