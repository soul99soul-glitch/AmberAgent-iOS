# iPhone 本机自动化实施记录

2026-10-10。基线：`dd2a7259b69950a7155690aed5b4575cb0db45d6`，开始时工作区干净。

用户已授权完善计划并逐阶段实施，每阶段独立 subagent review 后修复确认的问题。范围是本仓 iOS 产品及任务专用的启动器、runner、验证程序；不修改其他产品，不提交或推送。设备实验只对任务专用应用执行可逆操作。

## 目标与固定决定

同一部非越狱 iPhone 上的 Amber 自行启动并维持控制会话，用 UI 树驱动跨 App 操作，必要时才截图；运行时不依赖电脑维持测试会话或模型循环。首次配对、开发签名与安装可使用电脑，不能把它们与运行时独立混为一谈。

- idevice 固定 `3854a5df4a5a6dee71ffce4d8befc2ea356a8065`；iphone-use runner 固定 `955316e3fe12572f142fd7e75fb5d95c21fd9e03`。
- 不复制 StikDebug 的 AGPL App，不集成 Mac daemon，不引入第二条 HID 控制后端。
- 模型工具复用现有 Engine / Ledger / Background owner。结果未知必须保留并停止，不自动重放。
- 每次启动轮换鉴权 token；配对信息不进入模型、聊天记录或同步备份。
- 第一版是用户发起的有界任务，不承诺永久后台、开机自启或自动续签。

## 执行阶段

| 阶段 | 工作与验收 | 独立检查 |
|---|---|---|
| P0 固定协议与构建 | 固定来源和许可；Rust → C → Swift 窄启动接口；runner 元数据；HMAC/树/动作结果契约；iOS 与模拟器构建 | 检查 ABI 生命周期、协议一致性、真实错误分类、构建来源 |
| P1 同机控制原语 | 手机新建测试会话；签名 status → 树 → 定位 → 可逆操作 → 新树；拒绝未签名调用；验证没有主机维持会话 | 核对启动全链、权限/路由、动作与观测证据，检查探针界面 |
| P2 后台确定性流程 | 接现有 App owner 和 continued task；先用确定性任务在 30 秒/3 分钟验证前台目标 App 与后台 Amber | 检查所有权、过期/取消、旧回调、页面退出与重复执行 |
| P3 Agent 工具 | status / observe / act / stop；范围授权；树优先；按需原生图片；未知结果进现有账本 | 检查声明到前后台执行/审批恢复/Provider 的完整调用链 |
| P4 产品入口与收尾 | 默认关闭设置、准备状态、运行/停止/恢复；适配布局/动态字体；必要构建/测试/设备验收 | 检查 UI 错位/对齐/间距/大小及回归，最后一次有限可维护性审查 |

每阶段按“实现 → 针对性验证 → 独立 review → 修复 → 重跑受影响验证”推进。实现和验证状态分别记录；构建或模拟器通过不能替代真机。若系统授权、路由或后台限制挡住目标，保留具体失败证据并重新评估入口，不偷偷改为 Mac 托管或削弱鉴权。依赖尚未成立的阶段不能标记验收通过。

## 工作分工与当前进度

- 主 agent：阶段整合、runner/探针项目、产品构建与真实设备证据、最终判断。
- 原生启动桥 worker：独立目录内的固定 idevice 依赖、最小 RSD XCTest 适配、C ABI 与 Rust 制品；不编辑 Swift 或项目配置。
- Runner 客户端 worker：独立 Swift 包内的 HMAC HTTP、UI 树、临时节点引用与动作结果；不编辑聊天/设置/项目配置。
- 只读 explorer：现有产品工具/后台/设置的最小接点与所需测试。
- 各阶段 review：检查当阶段变更和验收材料，不以同作者自评替代。

## 已完成工作与真实证据

P0 的启动桥、HTTP 客户端与独立构建边界已经实现。Rust 固定源码构建出 device/simulator staticlib；Swift 客户端验证 HMAC 固定向量、UI 树、fresh plural lookup、歧义拒绝、停止、并发与未知结果不重放。runner 的签名 build-for-testing 完成；实际 ProductModuleName 为 `iPhoneUse`，插件为 `iPhoneUse.xctest`。

独立 subagent review 已修复：

- 探针缺少本地 HTTP ATS 设置；成品 plist 已核对 `NSAllowsLocalNetworking=true`。
- 旧 native 会话尚在关闭时可启动新会话；现由共享关闭任务保留占用，迟到 readiness 同时检查 owner 和 native identity。
- 第二次靶场验证错误假设计数一定为 1；改为从首树读取 n，检查新树 n+1。
- 首次配对按钮重复创建 identity 后无法覆盖 Keychain；改为已有 task-owned 记录时不再发起首次配对。

P1 的现有证据：iPhone 18 Pro / iOS 27.2 Beta `24B5089g`，Developer Mode 和 DDI 已开启。手机端 TCP 探针可连接自身 `127.0.0.1:49152` 与自身 Wi-Fi 地址；`10.7.0.1` 不可达。但正式 RemotePairing 初始化立即返回 `native_error_code=1`（I/O），没有完成系统确认，没有生成或保存配对密钥。**TCP 可达不证明 RemotePairing 可用，更不证明可以省去 VPN 或自行启动 XCTest。** 更细的错误诊断已经加到源码，没有再部署复测，具体断开原因仍未确认。

Mac 一次初始化助手因该设备仅在 CoreDevice 无线通道中可见而得到 `DeviceNotFound`；它未创建成功配对，也未启动任何 XCTest。未将 Mac 启动的测试会话作为手机独立证据。

上述是第一次设备实验结束时的状态：P0 实现与独立审查完成；P1 未通过。随后按用户的继续指令实施了 P2–P4 的产品接线，最新状态见下文。

## 用户纠正后的验证边界

用户明确要求只做必要测试，并对日用手机被安装三个验证 App 提出异议。本轮三个 task-owned App 已经卸载，三个卸载命令均返回成功：

- `app.amber.selfcontrol.probe`
- `app.amber.selfcontrol.target`
- `app.amber.selfcontrol.runner.xctrunner`

停止新增安装与真机实验。后续不扩大探索性测试；当前仅完成与源码改动直接相关的编译收口。不会通过继续堆实验程序、隐藏 Mac 托管或降低鉴权来把 P1 标记为成功。

## 2026-10-10 继续实施

用户要求继续推进。保持仅必要验证和不再安装临时真机 App 的约束，推进 P2–P4 产品源码接线、构建、定点测试及独立 review。P1 的同机配对／启动仍是独立真机验收门槛，后续源码完成不将它标记为通过。

本次授权入口：默认关闭；导入本机 RemotePairing 材料后，用户选择目标 App 与 1–5 分钟时间，明确授权下一次主动发起的聊天任务。授权一次性、进程内有效，绑定 runId，不随设置修改扩权；取消、到期与运行终态撤销。模型不能建立或恢复授权。后台继续沿现有有界任务 owner，页面退出不结束控制，系统租约失效不自动重放动作。

## 产品接线与阶段结果

| 阶段 | 已完成的实现与检查 | 仍缺少的验收 |
|---|---|---|
| P0 | 固定来源、Rust/C/Swift 启动桥、HMAC 本机 HTTP 客户端；device/simulator 编译、协议测试与独立 review | 当前 OS 的系统授权仍要真机证明 |
| P1 | 最小实验完成，失败证据保留；增加可见的类型化诊断；三个临时 App 已卸载 | 同机 RemotePairing 成功、独立启动 XCTest、树/动作/新树，均未通过 |
| P2 | App 级 owner 接前后台运行、取消/到期/终态关闭、冷恢复不补授权；独立 review 与定点检查完成 | Amber 切后台后连续 30 秒/3 分钟执行下一轮，未实测 |
| P3 | 四个原生工具接现有发现目录、前后台 executor、图片输出与未知结果账本；独立 review 完成 | 实际模型驱动跨 App 多轮控制，未实测 |
| P4 | 主产品设置入口、首次配对/取消/导入、范围/时长/单次授权、状态/停止；模拟器布局与独立 review | 真实配对、签名部署及设备使用验收尚未完成 |

**P2–P4 的源码完成不使 P1 自动通过。当前可以交付实现、构建和模拟器界面证据，不能称手机独立控制产品已经可用。**

### 可定位的主调用链

1. `ExecutionSettingsView` → `Route.phoneControl` → `IOSPhoneControlSettingsView`。页面默认不启动控制，显示配对/runner/同机启动三者的区别。
2. 显式首次配对 → `IOSPhoneControlController.preparePairing` → `PhoneControlPairingSession` → C ABI `pairing_start` → 系统开发配对协议。只有成功返回的材料才经格式和密钥校验后写入本机 Keychain。导入入口复用同一验证；有效记录不会被首次配对重复创建。
3. 用户选择 App 范围和 1/3/5 分钟 → `authorizeNextTask`。待用授权只在进程内保存，5 分钟内有效；设置变更会撤销待用授权。
4. 用户主动发送/编辑/重新生成 → `ChatViewModel.generateResponse(phoneControlUserInitiated: true)` → 冻结本次工具目录 → `ChatKernelRunHost.start` → claim 本次 runId。自动 mailbox 唤醒、steer 后续任务、子代理和冷恢复均不能消费新授权。
5. 运行账本记录 `.running`、既有后台租约建立后 → controller/session → Rust RemotePairing/TLS-PSK/CDTunnel/RSD → testmanagerd/XCTest → 注入本次 token 的已签名 runner。收到签名 status 才报告本次启动就绪；startup 失败进入现有运行错误路径。
6. `tool_search` 暴露 `phone_status / phone_observe / phone_act / phone_stop` → `ChatToolRuntime` 的原生 executor。前后台复用同一个 run owner；后台目录只能重建原运行的工具声明，不从当前设置扩权。
7. `phone_observe` 默认只返回新 UI 树，临时 ref 供 tap/type/swipe；launch 使用授权 Bundle ID。只有显式 `include_screenshot=true` 才输出 PNG 原生图片到已有 Provider 消费路径。
8. 动作回执分为 completed/not_sent/unknown。unknown 原样进入现有 `IOSAgentToolOutcome.outcomeUnknown` 和 Ledger，阻止后续工具；不新建客户端重放。执行回执不证明业务效果，需重新观察。
9. 显式停止/关闭开关/时长到期同时取消匹配的前台或后台 run。运行终态、系统后台到期先撤销动作访问，再关闭 native 线程并释放占用。页面退出与正常前后台交接保留同一 owner；进程死亡不恢复授权。

### 独立 review 后的具体修复

- P2：增加明确的用户发起标志，修复自动 mailbox 唤醒可能消费新授权的路径；系统任务到期的统一入口撤销控制，覆盖等待中终态保存分支。
- P3：复核动态工具声明到前后台 executor、冻结目录、原生图片、unknown 账本及原会话回写路径；四个工具禁止从嵌套 `exec` 间接调用。未引入第二套 agent/恢复内核。
- P4：错误移到固定页头下，页面重新进入仍可取消进行中的配对；最大辅助功能字号下确认图标溢出固定槽位，给图标显式 20pt 字号，正文继续缩放；Bundle ID 的多行输入占位文字被裁，改为原生单行字段。
- 收尾只做一次有限可维护性检查。复用已有 `diagnosticSummary` 保留启动错误的 code/subcode/I/O/OS 信息；没有新增重试、兜底传输或通用状态框架。

### 仅必要的验证

- 之前 P0：8 个 Rust 生命周期/契约测试、18 个 Swift 客户端协议/未知结果测试通过；本次未重复运行未变更的底层测试。
- 本次模拟器定点检查覆盖授权单次消费、范围冻结、旧 owner、冷恢复/关闭开关、RemotePairing 校验、树/动作参数、HTTP 200 中动作错误保留为 unknown、后台冻结目录、嵌套调用排除、设置接线，以及复用已有未知副作用恢复账本用例。
- 首轮 10 项中 9 项通过。目录 fixture 漏算既有常驻 `tool_search`，修正为精确集合后，只重跑受影响的 controller/catalog/settings 6 项，全部通过；其余未变更的 executor 3 项和恢复账本 1 项复用首轮成功记录。没有削弱断言或删用例掩盖失败。
- 完整主产品已通过模拟器及 generic iOS 未签名构建。当前改动的最终构建、xcresult 路径及退出码记录在 [verification.json](iphone-control-evidence/verification.json)。构建不表示签名安装。
- UI 使用同一个现有 iPhone 17 Pro / iOS 26.5 模拟器，普通字号浅色和最大辅助功能字号深色检查；只在设置页导航/滚动，没有按下配对、导入或授权，也没有调用模型或 native 开发服务。未签名模拟器产品的 Keychain 读取报告 `-34018`，本轮凭据行为使用隔离存储测试，不把布局检查当系统 Keychain 验收。

模拟器截图：

- [普通字号浅色](iphone-control-evidence/settings-light.png)
- [最大字号深色页头](iphone-control-evidence/settings-accessibility-dark-top.png)
- [配对区域修复前](iphone-control-evidence/settings-accessibility-dark-pairing.png)与[修复后](iphone-control-evidence/settings-accessibility-dark-pairing-fixed.png)
- [授权时长修复后](iphone-control-evidence/settings-accessibility-dark-duration-fixed.png)
- [输入框修复前](iphone-control-evidence/settings-accessibility-dark-input-before.png)与[修复后](iphone-control-evidence/settings-accessibility-dark-input-fixed.png)

### 剩余产品门槛

当前日用手机没有 task-owned runner，既有同机配对也未成功。需要先解释 P1 的实际开发协议失败，再用同一套产品入口验证独立测试会话，之后才能验证后台多轮 agent。重启、锁屏断连恢复、签名到期与端侧续签均未完成。源码保留明确失败，不退回 Mac 代跑，不减弱 HMAC，不声称能永久常驻。以上 P2–P4 源码接线续轮没有真机连接、安装、签名部署或网络/配对设置变更，也没有提交或推送。

## 后续 P1 协议复核

用户继续指令后，由 `pairing_protocol_review` 独立进行只读审查。未发现足以解释现有初始 I/O 的确定性协议错误：当前 raw TCP → `attempt_pair_verify` → `validate_pairing` → 显式首次 setup，符合固定 upstream 的 Wi-Fi 路径。`_remoted._tcp` 对应先 RSD、后 RemoteXPC 的另一入口，不能在没有服务身份的情况下直接替换。

- [固定 upstream 的发现分支](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/pair_rsd_ios.rs#L77)使用 Bonjour 返回的实际地址/端口；`127.0.0.1:49152` 可建立 TCP 连接仍不能证明该端口接受 raw initiator 配对。
- 当前错误位于初始 RemotePairing 握手，尚未进入 TLS 隧道、RSD 或 XCTest。此时不应修改 runner 签名或 UI automation 配置来解释失败。
- 固定源码另有 [iOS 27 PairableHost responder](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/idevice/src/remote_pairing/responder.rs#L1)：广播 `_remotepairing-pairable-host._tcp`，由设备主动连接。源码存在不证明同机能发现并连接自己；本轮没有添加这条后端。
- 下一条有区分力的证据是已加入的 I/O kind/OS code，以及错误发生于发送、magic、长度还是正文读取；不输出配对正文。没有这些证据，不猜改协议版本、不轮询回退传输、不扫描端口。

## 用户授权正式 Amber 装机

随后用户明确要求“先安装到真机”。此次授权用于现有 Amber 原位更新和启动检查，不恢复临时探针/靶场/runner 安装或自动配对实验。

安装前的实机记录显示：iPhone 18 Pro 上 `app.amber.ios` 实际来自 `iosAppExperimentalGPL.app`，并使用 `group.app.amber.ios.experimental-gpl.watchkit`。因此沿用仓库既有装机脚本的 ExperimentalGPL 配置和 Bundle ID 覆盖方式，保持现有终端能力、App Group 与签名团队。

Release 构建、签名校验、原位安装与启动均成功；读取进程列表确认 PID `38729` 来自新安装 bundle。安装没有卸载 Amber、清空数据或追加临时 App。系统更新时更换了主数据容器路径，App Group 容器保持一致；只读文件元数据确认安装前已有的非空会话文件仍在，没有读取会话正文。具体计数、签名制品指纹及命令证据见 [device-delivery.json](iphone-control-evidence/device-delivery.json)。

此次仅完成正式产品交付，没有点击配对、授权或运行手机控制，P1 的同机启动与真实后台控制状态保持未验收。原 [verification.json](iphone-control-evidence/verification.json) 记录的是此前没有真机操作的源码接线续轮，设备交付证据单独保存，避免改写历史边界。

## 公司 AI 交接与提交授权

用户随后明确要求“提交和推送，再给一个可以直接给公司 AI 接手的 prompt”。此次授权将本任务当前源码、固定依赖/许可、计划与已有验证证据提交到本仓 `main` 并推送 `origin/main`，用于跨机器继续；此前“未提交/未推送”是各轮当时的历史状态。具体提交与远端 SHA 以交接回复和 Git 记录为准。

这是当前实现的交接版本，P1 同机 RemotePairing／XCTest／树-动作-新树仍未通过，P2–P4 的源代码完成与正式主应用装机也不改变该结论。公司 AI 应先核对本地规则、HEAD 和 WIP，读取本文件、`iphone-control-evidence/verification.json`、`iphone-control-evidence/device-delivery.json`，再定位首次握手失败的服务入口与具体 I/O 阶段。旧研究中的 FFI 缺口已经由本轮桥接实现补齐，不重复研究或重写设置页。

交接不扩大设备实验范围：不恢复三个临时 App，不改变 VPN／Developer Mode／配对材料，不把主应用原位更新授权解释成任意设备实验。已授权的源码工作按阶段继续，每阶段独立 subagent review，只做与真实问题直接相关的验证。保留 ExperimentalGPL／`app.amber.ios` 与现有 App Group；不能默认执行旧设备 ID 的装机脚本。


## 2026-10-10 公司机器 P1 诊断续轮

公司机器原工作区在 `main` / `13ceb5eece1821eeca04e0d3723c87d8261208e9`，有聊天、后台与 Three.js 未提交工作，且尚未包含交接提交。获取 `origin/main` 后，在本仓忽略目录 `build/iphone-control-p1` 建立独立 worktree / `codex/iphone-control-p1`，以 `6390cef4efb1de5c672f23ff46884b9538452357` 为基线。没有 reset、clean、stash、覆盖原工作区或读取兄弟产品仓库。

本轮修复诊断缺口，未猜改 wire protocol version、扫描端口或新增传输后端。

- Amber 两个 RemotePairing 入口显式启用 framing 阶段诊断，错误状态附 `native_transport_stage`。区分写入、flush、magic、长度、正文、JSON 解码与响应结构；不保留协议正文、magic 字节、密钥或 token。Swift 消费及错误摘要支持新字段，旧状态仍可解码。
- 该入口在读取长度前校验 `RPPairing` magic。vendor 默认构造器保持既有行为，额外 patch 和 SHA-256 已登记。
- 独立 review 找到已有首次配对入口对任意 verify 错误继续 setup 的问题。真实本地 socket 回归检查在修复前得到 `pairing_setup_failed`；修复后 verify EOF 立即返回 `pairing_verify_failed`，无后续 setup 请求、无材料导出。只有 typed `PairVerifyFailed` 可进入一次 setup。
- `native_transport_stage` 表示最后一次传输操作。verify 拒绝后的 cleanup 写入可能成为最后阶段，不应将它当作最初错误位置，也不证明系统已经显示 consent 提示。
- `p1_protocol_review` 对调用链、生命周期、脱敏、默认行为与 provenance 独立复核，Rust 11 项通过。Swift 与装机结果单独记录，不能由 Rust 测试背书。

USB 已连接到 iPhone 18 Pro / iOS 27.2 Beta `24B5089g`。Mac 的 Bonjour 定向发现 `_remotepairing._tcp`，解析出 `iPhone-2.local.:49152`，与设备名相符。固定 upstream 使用 [Bonjour 实际地址与端口](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/pair_rsd_ios.rs#L68-L104)进入 [raw RPPairing](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/tools/src/pair_rsd_ios.rs#L284-L328)。这不是手机进程中 `127.0.0.1:49152` 服务身份、配对成功或自主 XCTest 的证据。

本轮读取安装版及设备信息，使用 Xcode 自带 USB screenshot 观察 Amber。iPhone Mirroring 未运行，未点击 Connect/Continue；没有改用 Mac 维持控制会话。未恢复 probe/target/runner，未改变 VPN、Developer Mode 或配对配置。首次配对复测尚待既有实验边界之外的明确授权；P1 仍未验收。

最终必要检查及交付状态见 `iphone-control-evidence/p1-continuation.json`。历史 `verification.json` 与 `device-delivery.json` 保留原记录。


续轮最终构建与交付边界：Rust 11/11、Swift 状态兼容检查 1/1 通过；device 与 simulator 原生库、主产品模拟器测试构建和 `iosAppExperimentalGPL / Release` 签名构建通过。严格签名校验、Bundle ID、既有 ExperimentalGPL App Group 以及新诊断/verify guard 在可执行文件中的存在性均已核对。构建环境补齐 Rust iOS targets，命令级使用可用 JDK 21，没有修改项目配置或新加产品依赖。

构建完成时设备仍显示 `unavailable` / CoreDevice `4016`，所以本轮未安装更新版、未运行新二进制，也未复测首次握手。仅此前交接安装版曾通过 USB 启动与截图观察。更新前会话文件元数据读取为 345 个条目，未读取正文；未发生安装，因此没有声称本轮更新后的数据保留已验证。App Group 文件元数据读取在连接失效时失败，保留该验证缺口。生成的无关 `Package.resolved` 变化已经移除；原工作区 WIP 没有被修改。本轮未提交或推送。


### USB 恢复后的诊断版原位交付

用户要求继续后，USB 已恢复为 available。复核源码与签名制品指纹一致，复用已通过检查的 `iosAppExperimentalGPL / Release`，原位更新 `app.amber.ios`，保留既有 ExperimentalGPL App Group。安装、启动均返回 0；进程列表与安装路径核对，确认 PID `39525` 来自新 bundle。更新前后会话文件元数据均为 345 条，没有缺失或大小变化，未读取正文。相同 App Group 域在更新前后均可访问，顶层条目保留；没有递归比较 Group 内部内容。未卸载 Amber、清空数据或安装临时 App。

使用 Xcode USB screenshot 确认新应用首页已经显示；首页含用户会话标题，截图只留在本机临时目录，不提交。正式交付结果见 `iphone-control-evidence/device-delivery-p1-diagnostics.json`，历史 `device-delivery.json` 保留。

此时仍未按下配对按钮，未建立控制会话。依据既有实验边界，已经提出仅一次正式 App 首次配对的授权问题，系统确认由用户处理；回复前不进行该操作。装机成功仍不证明 P1 配对、XCTest、真实跨 App 或后台通过。

`p1_delivery_review` 已独立复核上述交付材料，未发现阻塞问题。复核确认源码/patch/制品指纹、严格签名、Bundle ID/App Group、进程来源与元数据前后保留；未把 Apple Development 诊断签名称为分发签名，也未把主应用启动称为控制验收。没有重复构建或测试。

用户随后明确授权一次正式 Amber 首次配对复测，系统确认由用户处理，仍不安装 probe/target/runner 或改变 VPN/Developer Mode。USB 可读截图，当前镜像未运行且现有点击工具只支持模拟器，因此通过现有正式按钮发起：已请用户进入“设置 → 运行环境 → 本机手机控制”，只点一次“在本机建立配对”，结果留在页面供 USB 观察。授权已获得，不再重复询问；实际点击前不记为已经发起配对。


### 一次正式 App 首次配对的真机结果

用户报告已只按一次“在本机建立配对”，并留在结果页。USB 截图读到 `pairing_handshake_failed, native=1, subcode=0, transport=read_magic, io=ConnectionReset, os=54`；准备状态仍为“尚未导入配对文件”。控制开关在该截图中为开启，但目标 App 字段为空，本 agent 未建立下一次任务范围授权。

结合已安装源码，TCP 连接、首请求序列化、`write_all` 和 `flush` 已返回成功，错误发生在响应 magic 读取未完成时。它不是长度/正文/JSON 解码错误，未进入 app 的 pair-verify、consent 或 setup 分支，也没有成功配对材料导出/保存。写入成功不代表对端接受了协议；现有诊断没有接收计数，不能说响应为 0 bytes，也不能把错误直接归因为 wire version、设备权限、VPN 或 loopback 服务身份。

脱敏记录见 `iphone-control-evidence/pairing-retest.json`。原截图仅保留本机临时目录，其个人状态栏与 Live Activity 不提交。本次明确授权的一次尝试已结束，不再重试、扫描端口、变更协议版本、配置 VPN 或恢复临时 App。P1 配对/XCTest/跨 App 验收仍未通过。


`p1_reset_review` 已独立复核实际截图、调用链与失败关闭流程，确认错误没有误报为成功，失败后没有成功材料写入；没有第二次尝试，也没有改代码或重复测试。

一手入口核对：同一固定依赖已提供 [device-initiated PairableHost responder](https://github.com/jkcoxson/idevice/blob/3854a5df4a5a6dee71ffce4d8befc2ea356a8065/idevice/src/remote_pairing/responder.rs)，其角色和首消息方向与当前主动拨号入口不同；[上游 iOS27 工具说明](https://github.com/jkcoxson/idevice_pair#over-wi-fi-with-iphone-or-ipad)由设备选择所广播的 host 并输入代码。这支持优先核对 iOS27 首次配对服务入口/角色，但不证明旧 initiator 路径在全部 iOS27 上被移除，也不能把当前 RST 定为唯一的角色问题。改动版本号或直接增加另一条未验证路线没有依据。

下一条必要证据是同机 endpoint 的服务身份/路由及脱敏拒绝原因。若评估 responder，应先证明 iOS 设置能发现并连接本机 App 自有 listener，再决定实现；电脑-host 的上游示例不是同机可用性的证据。本轮只完成一次诊断复测，P1 的真实配对、XCTest、跨 App 与后台仍未通过。


### 初始化分叉的授权准备

用户要求继续推进后，针对原有一次性 Mac 助手新增只读 `--check-device`，并收口错误脱敏、不覆盖输出、独立 attempt 身份与 verify typed guard。它只在命令行使用，不进入正式 App、Probe 或 runner 构建；没有新依赖，正式 Amber 源码/签名制品不变。两项检查验证协议/IO 错误脱敏和已有输出保持不变；`pairing_options` 独立复核通过。失败输出保留，避免删除可能唯一的部分身份副本或发生路径所有权竞态；失败产物不表示配对成功，不自动重试。

最初只读查询返回 native22，随后同一默认 Unix socket 的原始/库级 `ListDevices` 均看到目标设备，UDID 精确匹配、类型 USB；请求 tag0/1 比较均成功。预检与实际准备现在都使用同一 `USBMUXD_SOCKET_ADDRESS` 规则。首次失败的时序/环境原因没有确证，不把它归因为协议 bug，也没有运行正常 prepare、读取 trust record、创建 RemotePairing 材料或修改设备配置。

可选路径已具体化。推荐复用 Mac 助手首次准备与正式 Amber 导入，不让 Mac 维持 XCTest/模型循环；另一条是 App 自有 PairableHost，需要 Bonjour、稳定身份、PIN 与生命周期完整实现，以及同机发现/连接证据。后者是重大初始化架构选择，前者涉及新设备凭据操作，已向用户合并提出路线/授权选择。回复前不做新的配对。目标仍是手机独立运行；此预检不证明 CoreDevice untrusted service、配对创建、手机 loopback 验证或跨 App 控制通过。


### P1 一次性 Mac 初始化与正式 App 安全导入续轮

用户已选择并授权一次 Mac 首次初始化及正式 Amber 导入。先前 CoreDeviceProxy/RSD/untrusted 路线在 60 秒上限内未产出材料，阶段无法确认；未猜改协议或盲重试。核对固定官方 idevice_pair 创建入口后，仅将现有助手切换到已有 USB 信任下的 `RemotePairingLockdownService`，显式完成两段准备。助手已成功生成 501 字节私有 plist 并退出；没有安装测试 App、启动 XCTest 或运行模型循环。脱敏记录为 `iphone-control-evidence/mac-initialization.json`，私有材料和路径仅在被忽略的本机任务状态内。

正式设置增加“导入 USB 准备的配对材料”一个按钮，复用现有读取、CryptoKit 验证及 ThisDeviceOnly Keychain。USB 仅暂存到正式 App 私有 `Library/Caches/amber-phone-control-usb.plist`，复制前检查不存在；保存成功且内容未变化后删除。失败保留文件，不破坏已有钥匙串。全程由 App controller 持有导入占用和 preparationRevision，不消费一次性控制授权。独立 usb_import_review 已确认源码逻辑闭环；构建、更新、导入及视觉检查按后续证据分别记录。

生成有效结构材料不等于手机本机入口验证成功，不等于手机自己启动 XCTest。当前仍无 runner 或真实跨 App 控制验收。不得把 Mac 初始化成功合并成自主运行成功。


正式 USB 导入阶段已取得设备结果：`iosAppExperimentalGPL / Release` 构建 exit 0，strict codesign、`app.amber.ios` 及原 App Group 核验通过；新二进制 SHA256 为 `cfb18ed25ad0d07107b0e2597a9d74655b43b7217c0e00ef0ced251a8fd97058`，原位安装及启动成功，PID 39739 来自新 bundle。更新前后 345 个会话文件元数据无丢失、大小无变化，App Group 顶层元数据保持一致；未读取正文。

配对材料经 USB 送入正式 App 私有 Caches，501 字节、权限 0600，复制前确认无保留同名文件。用户仅点一次新增导入按钮，手机显示“已保存配对文件”，截图见 `iphone-control-evidence/usb-import-device.png`。USB 元数据确认该暂存已消失，结合 App 保存成功后才删除的源码路径，确认 CryptoKit 校验与 Keychain 保存成功；没有导出钥匙串秘密。Mac 本任务成功材料及其空临时目录已删除，失败的旧材料未导入。辅助字号只在模拟器验证，普通字号同时在真机看过；控制器 6/6、助手 3/3 通过，独立源码 review 无阻断问题。

这是首次材料初始化/导入完成，不是 P1 手机本机握手验收。手机本机验证、runner 安装和启动、signed status/unsigned rejection、真实跨 App 和后台多轮均没有本阶段设备证据。Mac 助手已退出，不维持控制会话。下一步先验证手机入口及已导入材料，不扫描端口、重建身份或盲重放动作；runner 的安装仍须遵守用户明确禁止自动恢复安装的边界。


### 三方 App 闭环续轮

用户明确要求手机自主操控小米办公 Pro（`com.dancesuite.dance.ka.saxmsa667`），精确收件人刘剑崑，只发送一条“你好你好”，新观察确认，不确定就停止且不补发。用户随后单独授权只安装固定 runner，禁止 probe/target，Mac 不跑 XCTest 或模型循环。现有 Xcode 账户与 wildcard profile 起初不满足新手机，用户确认登录现有团队后 runner 的签名 build-for-testing、strict codesign、当前 UDID 和模块/插件核验通过；设备清单确认仅增加 `app.amber.selfcontrol.runner.xctrunner`，没有启动它。

USB 读取用户指定的新普通聊天，实际四次 tool_search 与一次 tools_list 未发现 phone 工具，也没有 phone 工具调用。由于 Host 在 claim 成功时必先启动 native、失败不调用 provider，可判断本轮没有取得控制 owner；授权在 start 时是否存在仍未有设备证据，不猜测其原因。新增 `phoneControlRunGate` 沿现有 lifecycle ring 仅记录六个布尔门控值，无 token、正文或 pairing 数据。真实新用户 grant 存在时四个 phone 工具在首轮直接可见，自动任务/无 grant 仍不暴露工具。

独立 review 确认保活到期路径在成功 handoff 前提前 revoke 是源码阻断。定点回归在修复前实际失败，修复后同 run owner 在成功 handoff 保留，失败由 cancel revoke，stale run 不影响当前 owner；VM→Host 使用同一默认 App shared controller。直接 VM 测试涵盖未授权/授权/自动组装/撤销目录与首轮可见性，并隔离内存材料和 lifecycle log。最后相关 suite 159 pass、3 fail、1 skip；失败之一是 handoff 基线已存在的后台接线字符串断言，另外两个是未改动 replay 渲染路径上的帧性能用例，独立复跑仍失败，未扩改无关渲染代码或降低断言。

更新主应用仍为 ExperimentalGPL / Release / app.amber.ios / 既有 App Group。真机目标因 Xcode discovery 不可用未进入编译，改 generic iOS 完成同一签名构建，再通过明确 UDID 原位安装并启动，新 SHA256 `2ba549ed714ce9ba30b8504f99b8a13eb882acb36557d8c8f44590fbbaa0d504`，PID39839 来自新 bundle。347 会话文件元数据前后无丢失、大小变化，App Group 顶层保持。一次性授权按契约不跨重启恢复，已请用户重新 grant 并立即从空闲普通聊天发出指定任务；USB 直接读取实际结果。

现有 Mac 初始化助手另增只读 `--check-runner-auth <UDID>`：仅在手机自己已启动 runner 后，用已有 USB 到固定8100发送一次无 token GET/status，5秒 deadline，仅读上限1024的首行且必须401，不记录正文、不创建配对或维持任何测试/模型会话。5/5 和锁定构建通过并独立收口 review。真实运行、unsigned401、三方树→发送→新树仍待设备证据，完整状态见 `iphone-control-evidence/cross-app-closure.json`。

### 2026-10-10 授权窗口续轮

用户明确要求将一次性授权改为 5 分钟、30 分钟、2 小时和无限制。窗口从点击时固定计时，claim 不消费也不延长；无限制使用 nil deadline。窗口只存在当前进程，重启不会恢复。正常完成与本机启动失败保留窗口；设置页停止、取消聊天、改目标范围、到期及 matching run 的 unknown 会撤回。phone_stop 按原工具契约只释放当前 run 的连接。单 runId owner、冻结范围、HMAC 和 unknown 不重放机制保持。

授权窗口、Host、后台取消/恢复 unknown 及服务身份解析定点检查 81/81 通过。新增只读服务核对仅浏览 `_remotepairing._tcp`，最多四条、5 秒结束；不读取 TXT、不连接 TCP、不发送 pairing 数据。无结果表示身份未知，不能作为服务不存在证据。正式更新和设备服务观察仍待完成；跨 App 树、动作、发送和新树均未验证。

窗口版 `bc6c9f04…` 已成功原位安装并启动，348 个会话文件没有丢失，两个文件在启动时大小增加，原因未定，未读取无关消息正文。真机截图确认窗口文案、配对仍保存。用户随后提供普通“你好”“啥？”也被手机握手失败挡住的证据，暴露了窗口复用与 Host 预启动的回归；此前源码检查未覆盖此产品行为，不能以通过测试掩盖实际失败。

修复将启动入口移动到前后台共用的 phone executor：Host 只冻结本 run 的授权范围，不在 provider 之前连接；phone_status 和 phone_stop 不启动；首次 phone_observe/phone_act 才启动，失败只产生 not_sent 且禁止同 run 重连。尚未请求连接的普通任务不因关闭或到期的控制窗口被取消。真机服务核对暂缓，先恢复普通聊天；定点测试、正式构建及纠正版装机仍在进行。

惰性启动纠正版 `8ebdb3e9…` 已原位安装并启动，PID40107，349 会话文件无丢失及大小变化，84/84 定点检查通过。用户随后提供真实 phone_status → phone_act(launch) → 启动失败 → 停止的工具调用结果，证明工具路由已恢复；首次配对握手仍 read_magic/ConnectionReset/os54，没有发送手机动作。USB 系统 App 元数据确认授权 ID 对应 Miwork Pro 7.72.25，不能凭 bundle 命名要求用户更改范围或重配。

为消除手动按钮触发歧义，新增仅显式启动参数 `-amber-phone-service-inspection-once` 的一次只读 Bonjour 核对。正式 `a81126c8…` 装机通过；Mac 控制台只保留元数据白名单，其余输出不存储。手机实际返回 started(source=launch)、resolved=1、port=49152、families=ipv4,ipv6、local=true。控制台12秒超时 exit2发生在结果后，不伪报 exit0。一次 CoreDevice4016因可信开发连接不可用阻断读取，usbmux仍识别USB设备；用户解锁后连接恢复，不修改配对记录。

下一项有证据的最小修复是将刚解析出的唯一匹配本机 IPv4 数值地址送入原有启动配置。材料在任何 DNS 前校验，发现后再次检查 cancellation/run owner，无候选或多个候选在 TCP 前停止，不猜127/10.7、其他端口、IPv6 scope或协议版本，不自动重试。该接线已独立审查；定点检查、构建和装机后的单次握手验证仍待完成。服务地址匹配不能证明 pairing、XCTest 或跨 App 操控成功。

唯一地址版 `8ac20b40…` 已正式原位安装并启动，PID40218，定点90/90通过。用户授权后发送一次既定任务，USB读取指定新会话的工具结果与脱敏门控：phone_status为authorized，phone_observe在首次启动中使用Bonjour确认的非loopback本机IPv4，但仍在read_magic返回ConnectionReset/os54。没有pairVerify、XCTest或手机动作，不能把地址接线作为P1修复完成。Agent凭bundle命名否定Miwork身份是错误推断；系统安装元数据仍确认该ID是Miwork Pro，未改范围或旧记忆。

下一阶段只准备正式App的有界self-responder入口验证：`-amber-phone-self-discovery-once`精确参数才启用App级owner；生成临时UUID/host身份及固定上游TXT，NWListener用临时端口发布`_remotepairing-pairable-host._tcp`，最多60秒，系统后台到期可提前停止。后台assertion不可用则不发布；服务不自动改名；所有入站连接立即关闭，不读写配对正文、不调用PairableHost.accept、不生成PIN、不读写Keychain、不启动runner或模型。日志只留ready/published、local地址匹配布尔、零应用层正文读写及固定停止原因，不存地址、identifier或authTag。native13/13通过，Swift首轮10/10及必要清理修正后的受影响4/4通过，独立review通过；正式Release构建进行中，系统设置发现/入站证据尚无。

此阶段的后续边界也已核对：pinned PairableHost.accept仅返回PeerDevice，accepted socket未暴露为tunnel client，且responder声明allowsIncomingTunnelConnections=false。即使自发现和首次配对通过，仍需用新RpPairingFile另建host client来走CDTunnel/RSD/XCTest；不能假设旧49152路径已恢复。host altIRK与RpPairingFile中的对端altIRK不同，且稳定广播身份不保证系统重启后自动连接。真实配对、手机启动XCTest、签名接口、跨App闭环与后台流程继续保持未通过。

该验证制品的正式ExperimentalGPL/Release构建已exit0，严格签名、同Bundle ID/App Group、团队和当前手机描述文件通过，执行文件SHA256为`ab7e3b1e10ede27f7227d39f84250742a6449aa9f25b11ae0ffd27c7ad75f6a3`。首次安装exit1，CoreDevice4016；只读设备状态确认tunnelState=unavailable、ddiServicesAvailable=false。已请求用户解锁与处理系统提示，没有自动修改信任/VPN/Developer Mode/配对设置。此制品尚未安装或启动，系统发现和入站验证仍未执行。
