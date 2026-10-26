# Amber 搜索审查与分阶段修复

## 目标与完成标准

核查搜索设置、持久化、供应商选择、工具审批、前后台执行、免费聚合与网页抓取完整链路。候选问题必须二次核实可达条件、实际影响及设计契约；只修复确认的问题。每阶段由未参与该阶段实现的 subagent 复审。完成受影响 Swift/KMP 检查，记录真实供应商和设备验收边界。

## 基线与约束

- 2026-10-25，`main`，HEAD `bd51719c4bf265f5e63fabed1f337c26fefd2c77`。
- 原工作区已有手机控制/后台自动化 WIP，以及未跟踪的 `2026-10-25-search-tools-review.md`。保护原内容，草稿只作线索，本轮另存报告。
- 原 tracked diff/status 已保存在 `/tmp/amber-search-audit-20261025/`；不提交、推送、清理或改动其他产品仓库。
- 不新增无依据重试、供应商轮询、权限或框架；已有 Key 不输出、不随备份导出。

## 工作包与阶段

1. 审计与二次核实：独立检查设置/KMP、网络/聚合、工具/权限，主 agent 检查供应商协议与集成；确定真实问题、排除项和修复边界。
2. Phase 1：修复设置、供应商管理与运行路由契约，受影响 Swift/KMP 回归，独立复审。
3. Phase 2：修复搜索权限与前后台执行链路，回归和独立复审。
4. Phase 3：修复免费聚合、取消与网络等待，回归和独立复审。
5. Phase 4：集成检查、一次有限维护性审查、受影响测试/构建，交付问题表、证据与未验证项。

阶段之间只按依赖调整，不扩大到其他能力。具体 findings、修复与验证结果在下方持续记录。

## 状态

2026-10-25 本轮继续执行。开始时工作区已有部分搜索修复草稿（执行器 Jina/免费开关、Settings 管理数据源、数量范围及部分测试），按现状保留、复核和完善，不覆盖已有内容。

### 本轮验收约束与计划

- 先对 11 项候选逐项复核可达条件；原生模型搜索作为产品契约观察，不擅自关闭或改变模型能力。
- Phase 1：保留单默认供应商设计，将 UI 明确为“默认 + 备用顺序”；提供已有供应商的选择/凭据管理入口，以 Settings 服务 ID 管理恢复条目；修复删除状态、免费开关、Jina 认证和 1–10 数量范围。完成后独立 subagent 复审调用链与页面布局。
- Phase 2：使用已有 run 权限快照，统一搜索拒绝/审批/自动批准行为，覆盖前台、后台、recipe 与子代理入口。完成后独立 subagent 复审。
- Phase 3：修复 Google 触发阈值、跳转取消、聚合取消与 URL 去重；复用现有 DNS 等待设施处理公网抓取。完成后独立 subagent 复审。
- Phase 4：完成相关 Swift/KMP 测试、构建与搜索设置页常规/紧凑/大字号截图检查；只修已观测到的对齐、间距、尺寸等问题。进行一次当前改动维护性审查，交付验证证据和外部验收边界。
- 每阶段复审发现的真实问题在进入下一阶段前修正。保留用户 WIP，不提交、不推送、不清空 App 数据。

### 执行记录

- Phase 0 复核：11 项候选均保留真实触发条件；供应商“优先级”定位为 iOS 默认选择/备用顺序的契约问题，不修改 KMP 排序保留 selected 的设计；原生模型搜索保持为契约观察。
- Phase 1 实现与独立静态复审通过：两页按 Settings ID 管理服务、默认选择与备用顺序分开、Jina 必填 Key、1–10 数量范围、删除保留选择且不擅自启用、恢复条目补 Key。凭据更新复用现有事务，不展示旧 Key。`shared.IosSettingsMutationsSearchTest` 6 个场景通过，新的 iOS Simulator Shared.framework 构建成功。Swift 与视觉证据在最终集成阶段运行。
- Phase 2 实现与独立静态复审通过：前后台、Recipe、旧子代理和批准完成使用同一搜索权限判断；disabled 优先，按 run 快照判定。新增实际 runtime 权限行为测试。Novel 没有现成的单次搜索审批恢复入口，因此保留权限门禁，返回准确可重试提示，提供“逐能力自动批准”或“关闭搜索”两条操作路径，未扩展小说领域审批协议。
- Phase 3 补完与独立复审通过：已足额的小结果请求不启用 Google、Google 跳转任务传播取消、聚合迟到结果仍检查取消、DNS 使用可取消 waiter 并共享剩余预算、URL 只规范 host/scheme 并仅裁 path 尾斜杠。当前源 host 验证：DNS 取消约 0.103 秒、0.2 秒超时约 0.212 秒，双 DNS 共享 2 秒预算约 2.064 秒结束；Google 的 3 个跳转任务均收到取消。上述不是 App XCTest 或真实 WebView 验收。
- Phase 4 完成：Xcode 自带系统资源初始化成功，CoreSimulator 更新为 1174.9.2。使用仅供本任务的 `Amber Search Validation 1025`（UDID `8A5A7B59-7952-40E1-B33B-A004DA1CF4BA`，iOS 26.5）完成 App 构建、受影响 XCTest 和真实窗口截图；结束后已关闭该模拟器。
- 集成时修正两处编译问题：新凭据页向 LocalizedStringKey 传入插值文本；已有非搜索 WIP 的 `ChatConversationInbox` 调用对可选会话 ID 做类型安全判断。后者只为解除整体编译门槛，未回退其消息队列/持久化修改。

本轮基线与既有 WIP 哈希：`/var/folders/2c/0pbv0ybx6h1crqbxq9zft5780000gn/T/amber-search-remediation-baseline-20261025-me3jasc5/`。

### 最终验证与 UI 复审

- 受影响 App 和测试目标实际编译成功，并在模拟器执行。第一轮 104 项中 14 项旧 API/媒体测试失败，失败集中于使用系统 Keychain 的夹具导致服务未写入；改为隔离的内存凭据 hooks，保留全部路由、请求头、结果、媒体和取消断言，生产凭据实现未因测试失败而放宽。
- UI 首轮真实截图 21 张，覆盖 393pt、320pt 和 320pt/accessibility3 的搜索服务、供应商配置、新 Key 编辑页。主 agent 与独立 subagent 确认并修正三项实际问题：供应商标题截断（对称 44pt 控件及两行标题）、新输入框固定小字号（改随系统字号）、数量 10 被拆行（单行理想宽度，加减按钮 44pt）。第一页首行裁剪确认为测试驱动错误地滚到 y=0，已保留初始滚动位置，未据此修改产品滚动逻辑。
- 只重跑受影响的三个测试类：`IOSSearchExecutorTests`、`IOSForegroundToolExecutorsTests`、`IOSSearchSettingsAcceptanceTests`，结果 58 通过、1 项实网条件跳过、0 失败。此前通过且未受后续改动影响的权限、网络、凭据事务、设置和 Novel 用例复用其证据。
- 按每项测试的最新执行结果合并：102 通过、2 跳过、0 失败。两个跳过项为 `testLiveEachFreeEngineReturnsResultsWhenEnabled` 和 `testLivePublicScrapeUsesProductionTransportWhenEnabled`，本轮没有设置其显式实网开关。
- 修后 21 张新截图已按时间戳单独归档，独立 subagent 再看受影响图片后确认三项 UI 问题均已解决，未发现剩余错位、覆盖或读数截断。一次有限维护性检查通过，未追加框架或无依据回退；已无生产调用者的 `shouldExecuteSearchInBackground` 仅在此标记保留，未删除。
- 限定搜索改动的 `git diff --check` 通过。未提交、推送或修改真实手机的 App 数据。

证据位置：

```text
/tmp/amber-search-remediation-kmp-tests.log
/tmp/amber-search-remediation-shared-framework.log
/tmp/amber-search-remediation-tests-r1.xcresult
/tmp/amber-search-remediation-tests-r1-summary.json
/tmp/amber-search-remediation-tests-r2.xcresult
/tmp/amber-search-remediation-tests-r2-summary.json
/tmp/amber-search-remediation-combined-results.json
/tmp/amber-search-ui-before-20261025/
/tmp/amber-search-ui-after-20261025/
/tmp/amber-search-remediation-final-source-hashes.json
```

### 交付边界

代码修复、相关回归、模拟器构建/执行与上述 UI 渲染复审完成。2026-10-26 已按用户追加指令完成 Release 签名及真机覆盖安装，具体证据见下方。前台启动受锁屏阻断，键盘/拖动手感与真实付费供应商 Key 尚未验收；Google 真实 WebView 搜索结果与各免费源的长期可用性没有据 mock 或截图宣称通过。

小说讨论仍不提供逐次搜索审批入口：每次询问时会阻断请求并明确提示将该能力设为自动批准后重试，或关闭 Agent 网络搜索后重试；禁用策略仍优先。供应商原生模型搜索保留原契约，本轮没有将它并入本地搜索服务优先级或新增供应商轮询。


### 2026-10-26 真机覆盖安装

- 当前工作区（含搜索修复及已有未提交代码）使用 `iosAppExperimentalGPL` / Release 构建成功；真机 KMP `:shared:linkReleaseFrameworkIosArm64` 完成。构建期间基线源码哈希未变化。
- 最终包名 `app.amber.ios`，签名 Team `TY4JTL3V2M`，App Group 沿用 `group.app.amber.ios.experimental-gpl.watchkit`；`codesign --verify --deep --strict` 通过。主可执行文件 SHA-256：`3f6d8a149895fa9870237b1f2a2ff949cdf05e57a7b9bcfa57508a628366d1e5`。
- 已覆盖安装到当前连接的 iPhone 18 Pro（`00008160-001939111420000A`，iOS 27.2），CoreDevice 返回安装成功；未卸载、清数据或变更 App 身份。
- 紧邻安装前后的 `Documents/conversations` 清单均为 276 条，无新增、删除、大小或修改时间变化；本次未比较文件内容哈希，不能据此声明逐字节完全一致。
- 前台启动请求被系统明确以 `Locked` / `FBSOpenApplicationErrorDomain 7` 拒绝。进程清单仅看到新安装目录下的 Widget，不能认作主应用启动成功；真实交互和 provider 行为未验收。
- 本次仅生成工程和构建产物、执行覆盖安装并更新交付记录，未提交或推送。

证据：

```text
/tmp/amber-search-device-release-build-20261025.log
/tmp/amber-search-device-build-result-20261025.json
/tmp/amber-search-device-artifact-20261026.json
/tmp/amber-search-device-install-20261026.json
/tmp/amber-search-device-retained-data-20261026.json
/tmp/amber-search-device-launch-20261026.json
/tmp/amber-search-device-screen-20261026.png
```
