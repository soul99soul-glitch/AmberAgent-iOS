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
