# iPhone 自主控制：免 LocalDevVPN 路线与产品取舍

日期：2026-10-11。对象：当前 iPhone 18 Pro、iOS 27.2（24B5089g），开发签名的 Amber。

初版记录源码、历史真机证据和公开资料调研；初版阶段没有切换手机 VPN、重建配对、安装 App、执行新探针或修改生产代码。后续经用户批准的真机实验单独记录在下文和证据文件中。原有未提交工作保留；未提交或推送。与 Devin / Claude Opus 5.5 完成初稿、相互挑战和修订，并由独立 subagent 审查本地证据、调研开源替代项目。

## 决定

目前**没有找到在这台手机上验证过的纯本机、无 VPN、无外部设备的完整控制方案**。这不等于证明全部无 VPN 路径都不可能。已有证据排除了直接本机 IPv4 的当前入口；后续补测中，scoped IPv6 在首握手读取时被 reset，传统 lockdown 入口在 connect 时返回 EPERM；两者均未建立完整通路。

两个入口探针均未取得可用通路，当前选择 Amber 内置 packet tunnel，保留已跑通的 RemotePairing → RSD → XCTest 架构。目标是少装一个 App、少一次手动切换，不声称彻底消除了 VPN。外部路由器、ClashMi/Tailscale 接入和自 runner 暂不纳入产品，避免同时维护多套尚未验收的传输。

## 执行进展（2026-10-11）

用户已批准尝试上述计划。阶段1已构建、签名并覆盖安装诊断版；首轮安装前后355个聊天文件的大小和修改时间均一致。暂时停用LocalDevVPN后：

- 传统入口：实际唯一本机Wi-Fi IPv4:62078在 `TcpStream::connect` 阶段返回 `PermissionDenied / EPERM(1)`；没有发送QueryType，没有读取配对凭据或继续StartSession。当前入口未得到可继续的通路。尚无同步系统拒绝日志，不能断言具体是sandbox、NECP或哪一项权限规则。
- IPv6首轮未发greeting；修订后复测发现两个真实本机IPv6候选，其中一个属于活动en0接口。选定这一scoped link-local候选后，greeting在 `read_magic` 返回 `ConnectionReset / os=54`，发生在发送配对材料之前。两轮都未使用VPN地址；没有同步daemon trace，不推断其内部拒绝条件。
- Scope修复另有真实Darwin sockaddr fixture支持；实际复测日志 `embedded_scope=0`，因此不能把embedded scope丢失说成本机首轮的实证根因。选择唯一en0候选解决了本轮的多候选问题。
- 已恢复LocalDevVPN，生产路径无凭据greeting返回 `handshake_ok`。阶段1两份Release制品均签名、安装成功；修订版26项iOS定点测试通过，Rust探针32项测试通过；独立subagent已review。进入内置NE的签名和最小启动验证，不新增其他传输回退。

首轮构建、安装与脱敏终态见[直连入口实验](../iphone-control-evidence/direct-entry-20261011.json)。Mac本次经Wi-Fi连接，USB helper未能附加同步daemon trace；未将缺失的trace记为协议成功或拒绝证据。

## 阶段2、3的交付与阶段4验收

内置扩展、单配置manager、控制器、应用查询和设置入口已接通。独立review修正了接口掩码、停止超时后的状态、停止回执跨owner读取及页脚间距。管理器14项测试通过；控制/工具/后台恢复/视觉相关最终43项测试通过。设置普通字号与辅助字号截图已复核。

首次签名因Xcode未登录、缓存profile缺少Network Extension能力而失败。用户登录后，宿主和appex均已取得并核验实际签名、packet-tunnel entitlement与目标设备资格。正式Release覆盖安装前后355个聊天文件和App Group文件的大小、修改时间一致。手机已保存Amber自己的VPN配置，配置复用启动完成 `handshake_ok` 和 `disconnected=true`。

完整接线版在真机上完成138个应用的查询/添加工具检查，随后另起会话完成认证runner启动、189节点界面读取和正常断开，没有再询问VPN权限或切换外部App。

首次真实Agent动作任务未通过关闭弹窗验收：工具返回 `completed`，新截图中弹窗仍在。图片复核显示模型点击y=0.673，关闭按钮中心约y=0.697，点击落在按钮外侧，不能归因于坐标映射或控制后端。期间另出现启动旧任务终态冲突；设备上4个旧checkpoint的ledger已是 `interrupted/process_killed`，新手机任务自身为 `completed`。旧记录清理已修复：先保留outcomeUnknown规则，再尊重已持久终态，只清理匹配owner与checkpoint，不改聊天或终态。修复前测试复现3个错误；修复后29项定点回归通过，独立review通过，最终Release签名及双bundle资格核验通过。

USB于10:05 UTC重新连接后，最终修补版已覆盖安装；安装前后362个聊天文件、3个App Group文件的大小和修改时间一致。冷启动实际清理8个旧checkpoint，原有ledger终态、时间和对应聊天文件未变。此项已完成设备复核，但实际关闭动作仍待复测。

随后在同一已安装版本复现用户的 `ConnectionRefused / os=61`。Amber内置隧道与已授权的LocalDevVPN对照都在初始TCP连接失败；尚未发送greeting、验证配对或启动runner。Bonjour仍发布本机49152端口；受信USB命名服务接受同一greeting，DDI报告可用。短时USB包头记录显示：SYN经过utun回注，手机随即从49152返回RST/ACK，证明本轮包回注已发生，不能据此确定iOS内部监听或网络限制的具体规则。同步daemon记录的“Unable to lookup agent … data from kernel”只有时间相关性，未证明是原因。

当前只读诊断未找到可用的本机Wi-Fi IPv4入口，IPv6记录也无Wi-Fi候选；实际Wi-Fi连接状态仍待单变量对照。参考项目[StikJIT的接入说明](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)同样区分Wi-Fi与无Wi-Fi场景，但文档不能替代本机因果验证。用户要求先诊断，本轮未追加产品代码修补、重配对或重装runner。Devin/Opus 5.5的新诊断请求被供应商cyber verification policy拒绝，未取得新意见，不把既往讨论当成本轮review。证据见[内置隧道实施](../iphone-control-evidence/embedded-tunnel-20261011.json)。

10:32 UTC用户确认连接可用Wi-Fi后，对照通过：没有重建、安装、换配对或改源码，同一内置入口返回 `handshake_ok`。包头从SYN后RST变为正常三次握手、双向数据、双方FIN。随后认证runner启动、187节点读取、停止和隧道断开均通过。可以确认这台设备的本次失败与网络状态相关，连接Wi-Fi后恢复；尚未证明Apple内部监听规则，也不能泛化为所有蜂窝环境必然不可用。

接着经正常模型工具路径启动美团并完成两次新观察，验证停止后新任务可以重新启动控制。此次出现的是短时开屏广告，点击skip ref时返回 `elementNotFound / not_sent`；下一张截图已是首页，无此前券包弹窗。开屏广告自行结束不能算作成功点击，精确关闭X仍待该目标实际出现时验收。任务ledger为completed、无匹配待恢复checkpoint，`phone_stop`回执 `cleanup_complete=true`。本轮到此未追加产品修补；暂不引入蜂窝硬拦截、自动重试或runner重装流程。

## 已知事实与证据边界

| 路径 | 实际证据 | 能说明什么 |
|---|---|---|
| Amber → Bonjour 唯一本机 IPv4 → RemotePairing | greeting 的 `read_magic` 收到 reset；同时间系统日志明确拒绝本机来源 | 此设备、此入口失败，发生在发送配对密钥之前；反复授权或更换配对文件没有针对这个故障点 |
| Mac → usbmux → 49152 | 同样被报告为自身/loopback 来源 | 把网络端口直接经 USB 转发不是已验证的替代方案 |
| Mac → 受信 lockdown 命名服务 | 相同 greeting 被接受 | 帧格式能工作，服务入口有区别；不证明手机 App 能访问该入口 |
| Amber → scoped en0 IPv6 | 本轮无VPN真机greeting在read_magic被reset | 此具体候选未取得通路；没有daemon内部拒绝原因 |
| Amber → 本机Wi-Fi IPv4:62078 | 本轮connect返回EPERM，QueryType未发出 | 当前入口被拒绝；不能把它当作传统session或CoreDeviceProxy验证 |
| 系统 → Amber PairableHost | 两次发布，没有确认实验窗口内的系统列表状态，也没有入站 | 实验不完整；不能据此判反向发现不可行，更不能判运行隧道可行 |
| Amber → LocalDevVPN → RemotePairing | 配对、TLS/RSD、XCTest，以及截图→关闭弹窗→新截图已有真机证据 | 当前可工作的基线 |

本地证据：[直接连接诊断](../iphone-control-evidence/usb-self-connection-diagnosis.json)、[反向发现实验](../iphone-control-evidence/device-delivery-69c2144-resume.json)、[LocalDevVPN 路由验证](../iphone-control-evidence/localdevvpn-route.json)、[关闭弹窗验收](../iphone-control-evidence/popup-close-20261011.json)。

`rejectsSelf`、`loopback` 等字段是本仓 helper 对系统日志关键词的分类，不是 Apple daemon 的内部变量。不能用其他分类为 false 推导内部判定分支已被全部覆盖。没有取得 daemon 内部判定实现，不能确定它仅比较地址表、接口，还是其他来源信息。

同类外部报告：[AirCard #13](https://github.com/Mak5er/AirCard-iOS/issues/13) 在 iOS 27 上记录了本机来源拒绝；维护者最终修复的是 LocalDevVPN 路由发现与连接校验。它支持这个故障类别存在，不能证明任何系统版本的无 VPN 路线都不可能。

## “本地回环”究竟做了什么

当前方案已经是本地回环。LocalDevVPN 建立系统虚拟网卡，认领一个对端地址，把 IPv4 源/目的地址交换后回注；没有外部 VPN 服务器。普通 `127.0.0.1` 或手机 Wi-Fi 地址并不会自动获得这种包路径。

实现依据：[固定版本 PacketTunnelProvider](https://github.com/jkcoxson/LocalDevVPN/blob/af3fd697803ada4ac2b8d518358f5ab0a534844c/TunnelProv/PacketTunnelProvider.swift)。Amber 的 [loopback_route.rs](../../native/iphone-control/src/loopback_route.rs) 只负责找到正确 utun 并把初始与动态 TLS socket 绑定到该接口，旧基线的包回注由 LocalDevVPN 完成；新版本由 Amber 内置扩展完成。

因此要分开两种目标：

- **不再安装 LocalDevVPN App**：内置 Network Extension 已签名安装，并完成握手、应用查询、runner和界面读取。
- **完全不用系统 VPN**：本机直连尚未找到完整成功先例；外部 LAN 反射有开源实现，但增加了网络设施依赖。

## 开源项目比较

GitHub 元数据为本轮查询快照（2026-10-11），不以 stars 代替真机证据。完整候选、固定源码链接、检索记录见[独立调研](iphone-no-vpn-alternatives-20261011.md)。

| 项目 | Stars / 许可证 | 与 Amber 的关系 | 取舍 |
|---|---|---|---|
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | 148 / StosVPN License | 已验收的本地 packet reflector；最近推送 2026-09-03 | 适合借鉴窄路由与包回注机制；内置只消除第二 App |
| [idevice](https://github.com/jkcoxson/idevice) | 531 / MIT | Amber 已采用的协议基础；最近推送 2026-10-08 | 优先复用现有诊断和协议，不因探索入口重写控制后端 |
| [Jitterbug](https://github.com/osy/Jitterbug) | 1562 / Apache-2.0，已归档 | 有内置本地 packet-tunnel 的小型实现；最近推送 2022-09-14 | 适合参考扩展封装和许可清晰的源码，不把旧开发协议搬入 Amber |
| [SideStore](https://github.com/SideStore/SideStore) | 6767 / AGPL-3.0 | sideload、lockdown/CoreDevice 经验 | 能安装或启用 JIT，不等于证明 Amber 的同机 XCTest 无 VPN 可行 |
| [KoolCenter.SideStoreVPN](https://github.com/DemoJameson/KoolCenter.SideStoreVPN) | 7 / MIT | 路由器做 DNAT/SNAT，手机可以不开 VPN | 有实质机制，依赖固定 LAN；尚未验证 Amber 的动态 TLS/RSD/XCTest |
| [sidestore-vpn](https://github.com/xddxdd/sidestore-vpn) | 100 / Unlicense | 外部设备反射包 | 不适合作为随身独立控制的默认依赖 |
| [TouchSynthesis](https://github.com/willfaust/TouchSynthesis) | 107 / 未发现许可证 | 进程内触控，自 runner；初始化仍经 LocalDevVPN/lockdown/CoreDeviceProxy | 动作热路径不经隧道不代表能断开隧道；不能直接引入源码，暂不替换现有 runner |

LocalDevVPN 的 [LICENSE](https://github.com/jkcoxson/LocalDevVPN/blob/af3fd697803ada4ac2b8d518358f5ab0a534844c/LICENSE) 是自定义 StosVPN License，不是 MIT。若复用代码，应保留许可、明显署名及来源说明，并核对其对整体复制和命名的限制。本轮没有复制实现。不能把读过源码后的实现称为已经完成 clean-room 审查。

内置扩展还有 [Jitterbug 的 Apache-2.0 实现](https://github.com/osy/Jitterbug/blob/b0449f18c9663c732ee16beefe6df60fa0cea137/JitterbugTunnel/PacketTunnelProvider.swift) 可参考。它已归档且针对旧系统，因此只参考扩展结构，继续沿用当前实测通过的窄路由与开发协议，不以旧版自调试成功替代 iOS 27.2 验收。

ClashMi、Tailscale 和 WireGuard 组合可能复用其他 VPN，但并不消除 VPN；Tailscale 方案还依赖外部反射器。桌面 `pymobiledevice3` 的用户态隧道可减少电脑端 root 权限，但仍须先到达手机开发服务，不能拿来证明同一 iPhone 的首连接已解决。参考 [pymobiledevice3 网络栈说明](https://doronz88.github.io/pymobiledevice3/guides/network-stacks/)。

## 两条本机直连路线的验证设计与结果

### A. 保留 scope 的 IPv6 RemotePairing

探针实现前，[PhoneControlServiceInspection.swift](../../iosApp/PhoneControlRuntime/PhoneControlServiceInspection.swift) 只为身份比较归一化 IPv6，实际 endpoint 只产出 IPv4。本轮已保留显式与 Darwin embedded scope，并要求有效 scope 匹配真实活动本机接口。地址身份比较仍忽略 scope，连接时则保留数值接口编号。

诊断从实际 Bonjour 结果选择唯一、已确认属于本机活动 Wi-Fi 接口的 IPv6 端点，做一次有界 greeting；不扫描其他接口或端口、不读取配对私钥、不启动 runner。首轮因候选选择未完成而未发请求，修订后的单次握手在 `read_magic` 被 reset。实验结果按以下边界解释：

- 返回正确 greeting：才进入现有配对材料、TLS/RSD 的下一步。
- daemon 明确拒绝自身来源：此具体候选被排除。
- 超时、不可达、未获得端点：记录为不确定，不能伪装成协议层拒绝。

如果 greeting 成功，后续还需修正 [lib.rs](../../native/iphone-control/src/lib.rs) 创建动态 TLS 地址时丢 scope 的问题：保留完整 SocketAddr，只替换端口。否则会产生“首入口通过、后续假失败”。IPv4-mapped IPv6 没找到可靠成功实现，暂不盲枚举。

### B. 本机传统 lockdown 62078 → CoreDeviceProxy

诊断原计划向已确认本机 Wi-Fi 地址的 62078 发一次无凭据 `QueryType`，只验证服务可达与协议回应。实测在 connect 阶段收到 EPERM，QueryType 未发出，因此没有进入以下后续验证。

若有正常回复，下一关才是受信 session、命名服务启动和 CoreDeviceProxy。传统 `PairingFile` 使用证书/HostID 等材料，当前 RemotePairing 的 `RpPairingFile` 不能替代它。Mac 经 USB 的成功不代表手机上的传统 session 会被允许。

CoreDeviceProxy 是不同的入口；即使之后仍到 RSD，也不能说它“绕回原来的失败”。但 `QueryType` 成功绝不等于 `StartSession`、`StartService` 或 XCTest 成功。

设备发起的反向配对另行保留线索。当前 vendor 的 [PairableHost](../../native/iphone-control/vendor/idevice/src/remote_pairing/responder.rs) 只完成 pair-setup，拒绝 pair-verify，并声明不接收入站 tunnel。改一个 `Origin` 字段不会自动补齐整条反向运行通路。没有完整先例前，不投入第二套发现/配对/隧道实现。

## 内置隧道的实际前提与体验

产品目标：用户在 Amber 首次开启本机控制时完成一次系统 VPN 配置；之后任务开始时由 Amber 启动自己管理的隧道，等待连接就绪，再启动控制会话。设置页显示就绪、连接中、失败或被占用等真实状态，不再让用户手动切去另一个 App。这里的“一次”指配置仍存在且授权未被撤销的正常路径。

实现保持一个 packet-tunnel extension、一个由 Amber 管理的配置和一条窄对端路由；不引入远程服务器，不接管普通互联网流量，不新增常驻 Mac helper。继续使用现有协议链和 runner。

系统前提与验收边界：

1. 签名门槛已通过：登录后，宿主及扩展均已取得并核验 `com.apple.developer.networking.networkextension`、有效设备profile和实际代码签名，正式Release覆盖安装成功。首次系统配置、握手、runner和界面读取也已分别验证，具体动作另行验收。
2. 用户已给 LocalDevVPN 的授权不等于新 Amber 配置已被系统批准。新配置首次需要 iOS 系统确认，普通 App 无法代点；此设备已完成该步骤。产品应把配置流程集中在首次准备阶段，而非每个任务询问。
3. Apple 文档明确：`NETunnelProviderManager` 创建的 enterprise VPN 同时只能启用一个；Personal VPN 可在路由不冲突时并存。故不能承诺与所有代理 VPN 共存，也不能泛称“iOS 只能一个 VPN”。App 只能管理自己创建的配置，不能静默接管 LocalDevVPN 的配置。依据：[NETunnelProviderManager](https://developer.apple.com/documentation/networkextension/netunnelprovidermanager)。
4. 内置方案的签名、启动/停止、runner和读取已单独验收；实际Agent关闭弹窗的首次测试点偏，需修正并复测，不能将执行回执当作业务成功。

Apple 的 [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) 明确 iOS packet tunnel 采用 app extension，普通目的地址模式不要求 MDM；不能因此推导可用 per-app VPN 无条件解决共存。[TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 不推荐将 packetFlow 读出的包重新注入本机。当前方案有这台手机的工程验证，但不是 Apple 承诺稳定支持的自动化接口；内置不会改变这一点。

## 推进顺序与验收

| 阶段 | 具体工作 | 进入下一阶段的条件 |
|---|---|---|
| 1：补齐入口证据 | 诊断构建分别做 scoped IPv6 greeting、62078 QueryType；每项一次有界请求 | 成功进入相应完整链路验证；明确拒绝则结束该分支；不确定保留原因，不无限重试 |
| 2：选定一条主线 | 若入口探针通过，继续到 RSD/XCTest；否则优先内置 NE，先验签名与最小扩展启动 | 取得完整通路证据后才做设置整合；不做多传输自动回退 |
| 3：完成准备体验 | 按选定路线接入就绪/连接/失败状态；只有 NE 分支需要首次 VPN 配置和任务启动隧道；状态更新沿现有任务/灵动岛链路 | 不需切换第二 App；连接失败真实呈现；结束状态不残留“进行中” |
| 4：真机验收与 review | 同一设备冷启动、Mac 不维持控制连接，读取→可逆动作→新读取；验证停止和下一任务 | 分别记录构建、签名、安装、启动、握手、runner、实际动作；每阶段 subagent 检查调用链与相关 UI |

不在本轮计划中：路由器设置、外部云中继、自动修改其他 VPN、替换触控后端、用多套传输不停重试。TouchSynthesis 的会话存活实验只在以后确实需要“运行阶段释放 VPN”时考虑；即使成功，也没有消除冷启动对隧道的依赖。

## 与 Opus 5.5 讨论后撤回的判断

- 撤回“手机不用 NE 就没有可行路线”：改为当前设备未找到验证通过的完整方案。
- 初版撤回“62078 已基本证伪且没用”：当时本机探针未做，CoreDeviceProxy 是不同入口。后续实测补上了 connect EPERM 的证据，仍不推断协议请求后的行为。
- 撤回“日志已经证明按地址表比较”：目前只是系统日志语义，内部机制未知。
- 撤回“所有 VPN 互斥”“NE 签名权限已就绪”以及无依据的上架判断。
- 不把“单次动作不走隧道”推导成“关闭 VPN 后整个控制会话仍存活”。

讨论记录：Synara thread `agent-64d27c71bcb4c9b46b25647f76b9e77f`，2026-10-11 的初稿与挑战轮。主要检索入口包括 `gh search repos LocalDevVPN`、候选 `gh repo view`/`gh api contents`、项目 issue、Apple 原始文档；已执行与未执行的证据如上区分。

初版调研 review 修正了阶段3对 NE 分支的无条件表述，以及单端口 LAN relay 无法覆盖动态 TLS 端口的遗漏。实施阶段分别完成了直连探针、内置扩展和连接管理器的独立 review；源码与测试结论和签名、安装、真机行为分开记录。阶段3已替换外部VPN入口并显示内置连接状态，完成测试与截图复核，并已随完整接线版安装到真机。
