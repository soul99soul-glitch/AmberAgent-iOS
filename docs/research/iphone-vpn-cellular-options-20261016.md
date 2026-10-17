# Amber 自动化的 VPN 共存与蜂窝启动

日期：2026-10-16。范围：非越狱 iOS 27.2、同一部 iPhone 的现有 RemotePairing → RSD → XCTest 控制链。初版为只读代码和开源调研；当时未运行候选项目或进行新的真机网络实验。后续适配与设备验证另记于产品计划。

## 结论

- 现有代理 VPN 与本地回环可以合并进同一个隧道，已有公开配置和应用报告，适合 Amber 增加“使用现有回环 VPN”的连接方式。
- 没找到可直接移植、已证明能同时满足“无 Wi-Fi、蜂窝持续联网、同机开发服务自动化、保留现有普通 VPN”的成熟实现。
- SideStore 已实现实验性蜂窝刷新，但关键设备操作期间关闭蜂窝，完成后恢复。不能把这项进展遗漏，也不能据此宣称持续联网自动化已经解决。
- USB NCM 外部转发和 USB HID 是不同的硬件路线；前者保留开发服务，后者改变输入与观察体系。二者都需要 Amber 自己的真机验收，当前不能承诺纯 5G 可用。

## 当前 Amber 的具体限制

`iosApp/PhoneControlTunnel/PacketTunnelProvider.swift` 只认领 `10.7.0.1/32`，排除默认路由，不配置 DNS。它没有把普通互联网流量送进本地回环，但仍通过 `NETunnelProviderManager` 创建系统 VPN。

Apple 文档说明，这类 regular enterprise VPN 同时只能启用一个；Personal VPN（系统 IKEv2/IPsec）另有可共存规则，不能笼统说 iOS 任何两种 VPN 都不能同时连接。[官方 NETunnelProviderManager 文档](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)

`PhoneControlLocalTunnel.swift` 目前在启动时管理 Amber 自己的 VPN。原生 `native/iphone-control/src/loopback_route.rs` 的生产连接还要求地址为 `10.7.1.1` 的活动 utun；按内核当前路由选择其他 utun 的函数目前仅用于诊断。因此借用现有 VPN 需要调整准备、实际 socket 路由及结束清理，不能只更换设置页 IP。

仓库已有的 2026-10-11 真机记录显示：内置回环和 LocalDevVPN 均在开发服务初始连接被拒绝，包头确认回注的 SYN 收到本机 RST；同一版本和配对在连接可用 Wi-Fi 后恢复，随后读取界面树成功。这是旧实验记录，本轮未重现；它支持定位到模型请求之前的网络/开发服务入口，尚不证明 Apple 内部监听规则。见 [既有传输记录](iphone-control-transport-options-20261011.md) 与 [证据文件](../iphone-control-evidence/embedded-tunnel-20261011.json)。

## 候选信息

GitHub CLI 本轮实时查询；Stars/Forks 仅用于规模参考，不能替代运行证据。全部未归档。时间为 `pushedAt` 的 UTC 日期。

| 项目 | Stars / Forks | 主要语言 / 许可证 | 最近推送 | 可借鉴范围 |
| --- | ---: | --- | --- | --- |
| [Sidestore-ClashMi](https://github.com/tom-snow/Sidestore-ClashMi) | 248 / 23 | JavaScript / 未声明 | 2026-02-13 | 已有代理同时提供 loopback 的配置思路 |
| [SideStore](https://github.com/SideStore/SideStore) | 6901 / 547 | Swift / AGPL-3.0 | 2026-10-13 | 蜂窝关闭/恢复和真实 endpoint 就绪检查 |
| [actell](https://github.com/ja1chen/actell) | 67 / 24 | Swift / GPL-3.0 | 2026-10-15 | ESP32 USB NCM 转发开发服务；另有现有代理回环使用报告 |
| [anan-iphone-use](https://github.com/ananhq/anan-iphone-use) | 102 / 18 | C / GPL-3.0；含 AGPL-3.0-or-later 组件 | 2026-10-15 | USB NCM + HID；画面观察由客户端提供 |
| [sidestore-vpn](https://github.com/xddxdd/sidestore-vpn) | 100 / 14 | Rust / Unlicense | 2026-05-21 | Linux/路由器反射；需要同 LAN 或另行组网 |
| [sidestore-vpn-tailscale](https://github.com/shiqi917/sidestore-vpn-tailscale) | 4 / 1 | Rust / Unlicense | 2026-10-02 | 复用 Tailscale 和远端反射；项目仍报告需要 Wi-Fi |

### 最贴近现有产品：复用代理回环

Sidestore-ClashMi 的 [最小配置](https://github.com/tom-snow/Sidestore-ClashMi/blob/02b5542ccbbb4453c5958c765f061d4d56c48eab/profile_overwrite_min.yaml) 为 TUN 增加 `loopback-address: [10.7.0.1]`，让普通代理和本地回环共用一个隧道。该项目 [Q&A](https://github.com/tom-snow/Sidestore-ClashMi/issues/5) 同时报告作者纯蜂窝尝试未成功。没有许可证，不直接搬其完整配置或 JS。

actell 的 [固定 README](https://github.com/ja1chen/actell/blob/55234856b8cb6fc114c0ca2674cd7bd420b1654c/README.md#using-loopback-with-your-regular-vpn) 报告 Shadowrocket 和 Clash 已与其回环方式测试过，界面提供不同 utun 地址预设；也明确没有据此证明蜂窝限制解除。它证明这种产品连接方式值得借鉴，不是 Amber 已验收。

Amber 适配范围：保留内置连接作为既有方式；增加外部回环方式，外部方式不启动或停止用户 VPN；根据实际有效路由约束初始连接和后续动态 TLS 端口，结束时只释放本次自动化会话。无需引入整个代理引擎。

### 新蜂窝技巧：离线窗口

SideStore 当前 develop 固定提交 `12ff39c6b6c0ccd8180f0834a893a4bbaf7bcd31` 中：

- [CellularRefreshManager](https://github.com/SideStore/SideStore/blob/12ff39c6b6c0ccd8180f0834a893a4bbaf7bcd31/SideStore/Core/Shortcuts/CellularRefreshManager.swift#L159-L206) 在无 Wi-Fi 时执行关闭蜂窝的快捷指令，等待 endpoint 就绪，随后按需恢复蜂窝。
- [实际刷新调用点](https://github.com/SideStore/SideStore/blob/12ff39c6b6c0ccd8180f0834a893a4bbaf7bcd31/SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift#L48-L56) 把安装 profile 放在关闭与恢复蜂窝之间；失败也尝试恢复。
- [Minimuxer 检查](https://github.com/SideStore/SideStore/blob/12ff39c6b6c0ccd8180f0834a893a4bbaf7bcd31/SideStore/Core/DeviceApi/MinimuxerWrapper.swift#L202-L219) 拒绝在该模式使用 WireGuard，原因是关闭蜂窝时 iOS 会暂停该隧道。

维护者的 [快捷指令说明](https://github.com/SideStore/SideStore/issues/1505#issuecomment-5645084560) 与生产代码一致。`0.7.0-alpha` 已有早期蜂窝切换，但 develop 的 endpoint ready 等待不能当作该 alpha 全部具备。

StikJIT 的 [1.9.0 集成说明](https://github.com/StikDebug/StikJIT/blob/32287268fa5824f9edce4cb359f5833ce0cf7b00/INTEGRATION.md#minimum-built-in-stikjit-user-instructions) 也给出“开蜂窝 → 接通 LocalDevVPN → 开飞行模式 → 返回应用”的无 Wi-Fi 操作。它服务于一次性 JIT 准备，没有证明恢复蜂窝后持续控制可用。

对 Amber 的研究价值是“离线建链后恢复 5G，会话是否仍可用”这一单一实验。不能默认为已支持，更不应每次点击都切换网络；Jev、主模型和在线题目依赖互联网。

### 释放系统 VPN：硬件或外部设备

actell 的 [USB NCM 固件说明](https://github.com/ja1chen/actell/blob/55234856b8cb6fc114c0ca2674cd7bd420b1654c/firmware-device/README.md) 提供 ESP32 外部来源转发开发服务，不设置默认路由。它最接近复用现有控制后端，但文档明确要求单独测试蜂窝/系统 VPN 能否继续访问模型。

anan-iphone-use 的 [固定 README](https://github.com/ananhq/anan-iphone-use/blob/745a90f9819d4ddb249176128c2b9b603343b163/README.md) 使用 USB Ethernet（网关/DNS 留空）和 HID。输入本身不依赖 RemotePairing/XCTest，因而是绕开该开发服务入口限制的不同原理；但固件不提供截图，Amber 必须接入新的屏幕共享观察方式。Anan 客户端当时尚未开源，不能说完整现成方案都可复制。纯 5G + Amber 连续任务仍需实测。

路由器反射与 Tailscale 能改变请求来源，但增加 Linux/路由设施，前者依赖 LAN，后者仍使用手机的 Tailscale VPN，均不满足纯手机、纯 5G 的全部条件。参见 [Linux 反射原理](https://github.com/xddxdd/sidestore-vpn/blob/1cb5f5d94e6f0baf4ed432d30b926bb0c39a9904/README.md) 和 [Tailscale 当前 Remote Endpoint 方式](https://github.com/shiqi917/sidestore-vpn-tailscale/blob/94cf7c15d37cec8ee3709464894c2225c58e17b0/README.md)。

## 已排除的误读

- [LocalDevVPN #31](https://github.com/jkcoxson/LocalDevVPN/issues/31#issuecomment-5613441760) 的协作者明确确认蜂窝不支持并以 not planned 关闭。它是维护者判断，不是对所有 iOS 网络入口的数学证明；不能把 issue 作者猜测的 `enforceRoutes` 当作已确认修复。
- [StikDebug #432](https://github.com/StikDebug/StikDebug/pull/432) 标题提及 Cellular support，但未合并、已关闭，主要是路径监控和重试；不能把 PR 中 README 的宣称当已发布能力。
- TouchSynthesis 热路径不逐次经过隧道，不等于初始化与整个 testmanagerd 会话可脱离隧道。旧 Jitterbug 内嵌 VPN 也没有释放该 VPN 位置。

## 主流代理兼容性补查（2026-10-16）

以下“具备能力”指工具能把 `10.7.0.1` 流量反射回本机，不代表 Amber 已完成对应真机读树/动作验收；本轮真机首次启动被系统锁屏拒绝。普通 DIRECT 分流、代理监听或允许局域网访问均不能替代该能力。

| 工具 | 结论 | 必要配置或版本 | 证据 |
| --- | --- | --- | --- |
| Clash Mi | 有明确使用与配置证据 | 当前 TUN 覆写增加 `loopback-address: [10.7.0.1]`，启用后重连 | [公开最小覆写](https://github.com/tom-snow/Sidestore-ClashMi/blob/02b5542ccbbb4453c5958c765f061d4d56c48eab/profile_overwrite_min.yaml) |
| Shadowrocket | 有明确接入证据 | 在“设置 → 其它”开启“包含路由 10.7.0.1/32”；版本需实际提供此开关 | [WrapPin 固定集成说明](https://github.com/suversal/WrapPin/blob/0dcee0fd288b11f80526de43aaf139831f4f6603/Documentation/ShadowrocketIntegration.zh-CN.md)；actell 另有使用报告 |
| Loon | 官方明确支持所需机制 | 3.5.3 / Build 1007+，`include-tun = 10.7.0.1/32`，插件 `[IP Rewrite]` 内 `10.7.0.1 = reflect` | [官方包含路由](https://nsloon.app/docs/General/#include-tun)、[官方 IP Rewrite](https://nsloon.app/docs/Plugin/#ip-rewrite) |
| Stash | 尚未确认，暂不列入支持清单 | 当前官方配置、iOS 发布说明未找到同等 IP 反射功能；兼容部分 Clash YAML 不代表支持此 TUN 扩展 | [官方配置样例](https://stash.wiki/configuration/example-config)、[官方 iOS 发布说明](https://stash.wiki/release-notes/ios) |
| Surge iOS | 官方明确支持所需机制 | 5.23.0+，`tun-included-routes` 包含该地址，`[IP Rewrite]` 配置 `reflect` | [官方文档直接给出同机开发服务示例](https://manual.nssurge.com/features/ip-rewrite.html) |

Loon 的 IP Rewrite 只允许写在插件，单独 `include-tun` 不执行反射。Surge 的 IP Rewrite 只处理进入 VIF 的包。两者的官方示例均区分“让包进入隧道”和“回注”。Shadowrocket 的上述开关由集成项目说明确认，本轮没有独立核实它最早出现的版本，不编造最低版本号。

WrapPin 为 532 Stars / 95 forks、Swift、最近推送 2026-10-14，许可证是 PolyForm Noncommercial 1.0.0，属于源码可读而非 OSI 开源；本轮只用其公开接入说明作为项目自身报告，不复制实现或模块。[当前发布说明](https://github.com/suversal/WrapPin/releases/tag/v1.0.18)仍提示 Shadowrocket、Surge、Loon 蜂窝建链不可靠，因此这些兼容证据不能用来承诺纯 5G 支持。

本次另由只读子代理核查 Stash/Loon 官方资料，主代理直接复核 Loon 官方两个关键段、Surge 官方完整示例和 Shadowrocket 集成说明。推荐先用已安装的 Shadowrocket 或 Clash Mi 做 Wi-Fi 验收，再验证 Loon；Stash 等找到确切反射机制后再列为适配对象。

## 推荐顺序与验收

1. 先适配已有代理的回环方式，解决可以确认的 VPN 冲突。验收完整启动、读树、动作、再读树与结束；任务结束后原代理继续连接，模型及目标 App 的互联网访问正常。
2. 单独验证离线建链后恢复 5G；成功标准是恢复后继续读树、动作、截图及真实云端请求，而不只是显示 VPN 已连接。若网络切换使会话失效，不增加盲目重试或每步切网。
3. 若持续纯蜂窝是产品硬要求，再选择 USB NCM 外部转发或 HID。前者更接近现有后端，后者摆脱开发服务但需补屏幕观察与视觉动作能力；在实测前不同时维护两套新后端。

## 检索与审查范围

使用 GitHub CLI 的仓库元数据、README、固定源码、issues、PR 状态及官方 Apple 文档。关键词覆盖同机 loopback、cellular/无 Wi-Fi、RemotePairing、XCTest、proxy coexist。两名只读子代理分别核查蜂窝修复和 VPN 共存候选；主代理合并去重，并直接复核当前 Amber 路由/生命周期、Apple VPN 分类、LocalDevVPN #31、StikDebug #432、SideStore 三个关键调用点、ClashMi 最小配置及 actell/Anan 文档。未把 SideStore 刷新、一次性 JIT、TCP 可达或其他手机的作者报告当作 Amber 真机验收。
