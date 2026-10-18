# Phase 2 独立审阅

结论：Phase 2 的 WebMount/网络/测试/UI 拆分及本阶段可取得的模拟器证据已闭环；对照迁前快照、迁移映射、源码关键链路、实际 XCTest 发现结果和截图，未发现可定位到本阶段的行为或 UI 回归。最初集成编译暴露的跨文件引用缺口已指回唯一实现 owner 修复。Novel 完整构建的既有共享渲染源清单缺口仍是 Phase 3 必须关闭的门禁，不能计作本阶段构建通过。本审阅只写本报告，未修改产品代码或测试。

## 范围与迁移核对

以 `/tmp/amber-swift-modularization-baseline-20261018-010059/files` 为原始快照，审阅 `IOSLocalToolExecutor`、`IOSSearchExecutor`、`IOSWebMountDesktopBackend`、`WebMountView` 及 Local/Desktop/Jev 三组大测试。职责和原行段对应关系见 [WebMount/网络迁移映射](phase-2-webmount-moves.json) 与 [UI 迁移映射](phase-2-ui-moves.json)。Phase 2 的 23 个 WebMount/网络结果文件和 9 个 UI 结果文件均不超过 1500 物理行；UI 原有非空布局/状态行保持，只有跨文件引用所需的少数 `private` 声明放宽。

- 公共 URL 策略移至 `Infrastructure/Networking/IOSPublicURLPolicy`；Search 旧静态入口保留原错误域适配。`IOSSearchHTTPTransport.sendPublic` 继续在初始请求与重定向检查公共 URL、DNS/IP，并保留响应大小和取消约束。已验证抓取的 HTTPS Fake-IP 例外仍在其专用链路，未扩散到严格公共 transport。WebMount 的站点导航策略与通用公共 URL 策略仍有各自边界。
- `IOSWebMountController` 保留工具入口、session/run 绑定、共同权限判断和 `sessionStore`；`LocalCommands` 独占 agent 上次观察，`StationCommands` 独占站点记忆已观察 host，desktop adapter 独占连接、快照/页身份和状态。`wm_act` 的每一步仍递归经过同一 `executeResult`，未绕过所有权、审批或快照检查。核对 local/desktop 的 mutation 预检、dispatch、receipt、postcondition、取消及 `unknown_after_action` 分支，未见迁移改变可达顺序或把可能已生效误报为成功。commands 的 `unowned controller` 在现有 controller 持有 commands 的调用链中没有证明可触发的生命周期问题。
- `WebMountSiteView` 继续持有同一 `@ObservedObject runtime`、root/inspector/popup host ID、popup 队列和 sheet 状态；WKWebView 复用、popup 身份及 presentation host 的挂载/离开处理仍连通。未把 popup 迁成另一个 runtime owner。
- 为隔离 Novel 共享编译对 PhoneControl 单例类型的间接依赖，`IOSAgentToolEngine.phoneRequestParams` 改为只查询已有的 `phoneSessionIsActive` hook；前台 `ChatRunKernelAdapter` 对注入的 controller 或原 shared controller 执行相同的 handoff/requested-session 双条件查询，后台 coordinator 显式传原 shared 查询。两条生产自动推理路径均提供 hook；自动推理关闭或没有 run ID 时仍直接返回原参数，未增加权限或新状态 owner。
- 三组原测试的 199 个方法及原断言正文保留；共享测试基类仍执行 Local 的 session counter 初始化，且不自带测试。迁移映射、方法哈希和断言核对见 [旧新标识](phase-2-test-identifiers.json)、[方法哈希](phase-2-test-method-hashes.json)。初次集成时 12 个 Jev 方法仍归旧 suite，随后仅把 extension owner 改至 Contract suite；[实际发现核对](phase-2-test-discovery-check.json) 以最终主门禁加 Jev 复跑验证原 199 个标识各执行一次、零缺漏、零重复、零不通过。

## 实际验证与视觉证据

- `/tmp/amber-phase2-integration-retry.xcresult`：iPhone 17 Pro、iOS 26.5 arm64 模拟器，474 项中 472 通过、0 失败、2 跳过。跳过的是既有的两个 opt-in live-network 用例：`IOSFreeSearchAggregatorTests/testLiveEachFreeEngineReturnsResultsWhenEnabled` 和 `IOSSearchExecutorTests/testLivePublicScrapeUsesProductionTransportWhenEnabled`。`/tmp/amber-phase2-jev-discovery.xcresult`：最终 Jev Contract 27 项、Loop 34 项，共 61/61 通过；与主门禁非 Jev 结果合并后，原 199 项映射全覆盖。
- 对 PhoneControl hook 接线的最终定点复跑 `/tmp/amber-phase2-phone-boundary.xcresult`：实际发现 Engine、PhoneRequestPolicy、PhoneHandoffExecutor、KernelHost、BackgroundExecution 五个 suite，共 118/118 通过，0 失败、0 跳过；这是三处接线改动之后的结果。
- 首次筛选把 suspension 测试文件名当作 suite 名，结果树确认未选中它；按实际声明补跑 `/tmp/amber-phase2-background-owner.xcresult`，`IOSChatBackgroundStaleSweepTests` 9 项与 `IOSChatBackgroundPhoneActivityTests` 1 项，共 10/10 通过、0 失败、0 跳过。两份结果合计覆盖这次接线涉及的前台、后台和 owner 终止链。
- `/tmp/amber-phase2-navigation.xcresult`：真实 app 的 Settings→WebMount 站点列表 UI 测试 1/1 通过。查看 `/tmp/amber-phase2-navigation-attachments` 中首屏、滚动后截图及 AX 树，页眉、增删入口、站点行与开关对齐，未见遮挡。
- 查看 `/tmp/amber-phase2-layout-attachments` 的桌面任务创建 320/393 宽、浏览器 toolbar 长地址/大字/暗色、网页 dialog 和 run report 截图，并抽查 `/tmp/amber-phase2-memory-shots` 的审批与站点记忆 320/393 宽、大字、短容器、明暗模式截图。选项行与创建按钮、地址栏与控制权按钮、报告/记忆卡边距均正常；dialog 的长正文位于独立可滚动区，截图只显示该区当前截面，确认/取消按钮仍可见且没有重叠。短聊天容器里审批卡上方正文的裁切与 Phase 1 基线同图，属既有表现，本阶段没有加重。

## 证据边界

现有 runtime 测试覆盖 popup/opener/cookie、dialog、控制权交接及离开 host，但没有把 inspector→popup→dismiss 的 SwiftUI presentation 队列组合做成完整自动 UI 流程；源码身份核对与站点列表实拍不能替代该组合的交互验收。截图来自模拟器/hosting fixture，尚未证明真实外部站点、live MCP desktop 后端、真机 WebKit 或物理设备行为。两个 opt-in live-network 测试跳过，因此也不构成外部 provider 验收。

DeepRead 的独立 arm64 模拟器无签名构建已通过（`/tmp/amber-phase2-deepread-arm64-retry-build.log`）；通用 x86_64 构建受当前预编译 Shared/Markdown framework 缺少该架构切片限制，不能据此判定本阶段源码失败。Novel 的独立 arm64 模拟器构建目前未通过：首次构建暴露原 YAML 缺现有 Intelligent UI 源，补齐后发现原 PhoneControl 依赖缺源；继续验证至 `/tmp/amber-phase2-novel-boundary-build.log` 时，仅剩 `ChatAssistantMarkdownView` 对未纳入 target 的 `ChatMarkdownMediaContent` 的引用。该共享 Markdown 媒体及下游 Gallery/Video 源属于 Phase 3 渲染器拆分范围；初始快照的 Markdown 源及 Novel target 缺源事实已对照，不能把此未闭合门禁表述为 Phase 2 新行为回归，也不能宣称 Novel 已构建通过。Phase 3 必须关闭 Novel 完整构建门禁。
