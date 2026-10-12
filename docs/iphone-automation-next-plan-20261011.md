# 手机自动化下一轮：可靠操作、接手与常用流程

## 目标和范围

用户要求完善计划后连续完成各阶段，每阶段独立 subagent review 调用链、状态逻辑和 UI，修正确认的问题后继续。延续 GPT‑6.1 Sol / high / priority 审查偏好。以当前 dirty 工作目录为产品基线，HEAD `69c2144`；初始快照在 `build/phone-automation-next-20261011/baseline`。保护已有手机控制与另一线程的 Intelligent UI 工作，不提交或推送。

完成标准：用户能明确判断连接是否实际可用；能改写已有输入并等待真实界面结果；Jev 返回可处理的交回原因及可测耗时；用户接手后以新观察继续；常用任务通过已有入口带参数运行。设置、持久化、工具、前后台执行、停止清理和展示必须相互接通。网络兼容性与设备验收单独记录，未经实际验证不得称支持。

当前交付状态（2026-10-12）：三个阶段的实现、独立逻辑/视觉审查和模拟器验收已完成；最终签名 Release 已原位安装。首轮正常启动被设备锁屏拒绝，后续获释窗口内正常启动成功并确认进程存活。新版自动化行为、后台接手和网络兼容性仍未验收。没有提交或推送。

## Phase 1：真实就绪和基础操作

1. 设置提供“检查自动化”：在自身 App 上启动临时、独占控制会话，读取新界面后关闭；展示检查阶段、结果与时间。配置存在和实际可用分开。任务首个工具仍走原 startTask，不重复建连。诊断不会持久扩大应用范围。
2. 基于 runner 已有 clear 端点暴露显式清空输入动作。沿用最新 ref、唯一目标和动作回执；清空后重新观察，确认空值，再输入并核验。原 type 保持追加语义，不放宽 Jev 空输入限制。
3. `phone_act + expectation` 增加短、有界的只读条件等待：完成即返回，只在可观察且条件未满足时继续读；取消、App/进程变化、证据不足立即交回。不重放动作。截图不足仍交回已有视觉路径。
4. 常规准备控件简化，高级配对/USB/服务信息折叠；保持既有视觉系统和 24pt 图标列。
5. `phone_scroll_until` 在观察到的唯一滚动容器中查找精确目标，每次滚动后更新界面证据；默认 3 次、最多 8 次，截断/歧义/无进展/未知结果立即交回，不需要逐次主模型往返。

验收：包内动作契约测试；controller 独占/取消/清理测试；核验等待/终止/unknown 测试；普通宽度、320pt 和辅助字号渲染；独立 review 修正后才进入 Phase 2。

## Phase 2：Jev、接手和状态

1. 目标循环返回少量稳定原因与候选诊断，区分截断、重名、非空输入、无可执行项、动作耗尽等；保留当前限制，不让 Jev 发明文字/坐标或重放已执行动作。
2. 输出本次调用分段耗时及 Jev 服务调用次数（服务可能本地返回，不能等同 HTTP 请求数）。为相同任务的真实请求比较提供证据；本轮没有基准时不宣称加速、不调整调用数量/等待。
3. 复用当前 run owner，加入显式“我来操作/继续”握手。暂停在动作边界生效；在途回执先收口。恢复必须先读新界面，不重发旧 ref/坐标/整段目标循环；unknown 保留原停止核对语义。
4. 当前任务页与 Live Activity 展示核验/等待用户/已暂停/停止，控制入口放在有空间的展开或 App 页面。保持 runId 隔离，不把后台提交当作系统持续运行保证。

验收：前后台同一 executor 消费；暂停/继续/取消/旧回调不串 run；配置变更不继续派发；实际状态展示及辅助字号截图；独立 review。

## Phase 3：常用流程

1. 沿用已保存快捷消息和 App Intent 入口，为手机任务提供少量可编辑参数和明确完成条件。
2. 保存目标/步骤提示/参数，不存旧 ref 和坐标；每次执行从新观察开始，已有 App 目录与授权机制照常生效。
3. 完成创建、编辑、删除、参数校验、发起任务及重启持久化链路；避免另一套宏引擎或任意脚本运行器。直接接口仅复用项目里确实已有且可调用的入口，不承诺任意第三方 App Intent 可执行。

验收：不同参数、已有输入、不同起始页面的任务契约；已有快捷入口兼容；设置/UI 普通及辅助字号；独立 review。

## 网络与交付验证

- 读取当前设备连接和现有 VPN 证据；不为验证破坏唯一管理链路，不自动修改 Loon/订阅/DNS。兼容 VPN、纯蜂窝、Wi‑Fi 切换分别验证，未通过就保留具体证据，不新增猜测性选路。
- 每阶段通过受影响测试后才扩大到集成。与另一个正在运行的 Xcode 测试协调，使用独立构建输出；不终止别人的编译、不覆盖正在使用的模拟器 App。
- 最终一次有限可维护性审查，Release 构建、签名校验、原位安装、正常启动与数据清单对照；真机按已有授权只做必要的非提交任务，禁止重放历史办公消息、付款或发布。
- 源码/单元测试、模拟器视觉、真实 provider、真机行为、后台和网络分别列证据。外部条件阻断时继续完成独立部分，如实列出未验收项。

## 执行记录

- 已保存初始快照；发现另一线程正在执行 Intelligent UI 模拟器回归。本轮先实现互不重叠的 PhoneControl 模块，暂不占用该模拟器。
- Phase 1 进行中：输入清空 Package、就绪检查及设置 UI 分别有独立 owner；主 agent 负责工具接线、效果等待、集成和阶段审查。

### Phase 1 审查记录

- `automation_capability_review` 独立检查 clear、有限核验、滚动搜索、工具分类及前后台入口；发现 sleep 后缺少 2 秒继续预算复查，已修复，并新增 1.9 秒读取 + 0.3 秒等待的回归。再次源码检查未发现剩余可达缺陷。
- `handoff_recipe_map` 独立检查临时 readiness owner、scope、取消/清理和设置布局；源码未发现串 run 或持久化污染，实际截图验收等待集成测试。
- 为避开另一线程正在使用的项目/模拟器，基于原 spec 只改项目名生成临时 `AmberPhoneAutomation.xcodeproj`，专属模拟器 `A2C1C295-C860-49AF-B88B-4F89E2A4B40C`，独立 DerivedData `iosApp/build/PhoneAutomationNext`。未覆盖其他线程项目/设备。

### 网络边界复核

2026-10-11 本轮只读复核：目标 iPhone connected/paired，当前 transport=localNetwork，usbmuxd 的 USB 设备数为 0。此前同版本 Wi-Fi 对照已通过 greeting、认证 runner、187 节点 UI tree 与 cleanup；纯蜂窝和 Wi-Fi 切蜂窝未验证。生产入口仍启动 Amber 内置隧道；借用现有 VPN 只有诊断 probe，不能称为已支持。Clash Mi 当时未建立 VPN（新增配置 DNS 错误，恢复原选择仍启动超时），不足以判断回环是否兼容。未改 Loon、VPN、DNS、订阅或网络。下一步设备网络实验需要另一线程释放真机与独立 USB 管理通道，不能切断当前唯一管理连接来换取测试。

### Phase 1 验收收口

- Package 清空动作契约 59/59 通过。整应用首轮 103 项中 99 通过，4 项 failure path 触发 Swift Observation exclusivity crash，崩溃点为同时读写 `readinessReport?.failureStage = readinessReport?.stage`。改为先读取局部值后赋值；受影响 Controller 31/31 重跑通过。其他 72 项无需重复。
- 证据：`phase1.xcresult`、`phase1-readiness-fix.xcresult`，位于 `build/phone-automation-next-20261011/`。视觉输出在 `phase1-visual/`，独立 reviewer 已看普通/320pt AX3、未准备/高级准备展开/已验证的全部滚动页及 App picker，未见本次新增错位、截断、重叠或不可达按钮。
- 进入 Phase 2；源码/模拟器验证完成，物理设备行为留到最终安装后单列。

### Phase 2 独立审查与修正

- 人工接手后，旧模型响应中的后续 `launch` / `goal` 不依赖旧 ref，仍可能执行。新增 typed `replanRequired`：当前项保留原回执与新观察，同一批其余项明确 `not_sent`，下一 provider 轮再规划。执行记录保存此标记，重放已完成结果也保留批次边界。
- 明确的人工暂停原先仍按 running 设置 180 秒 staleDate，超时会隐藏“继续”。仅对 phone.paused 取消此期限，pausing/resuming 和普通运行仍保留失联规则。
- 恢复观察失败（例如用户切到未授权 App）原先滞留 resuming。失败应按原 session/generation 收口到暂停、保留 fresh gate，显示原因并等待用户继续；不能自动重读，也不能覆盖新接手或已停止的 owner。
- 模型诊断只输出候选 ID 与稳定原因；耗时区分观察、决策、动作与复核。unknown 仍走原 durable stop，不被人工接手或普通完成状态覆盖。

### Phase 3 实现约束

- `IOSSharedSettingsStore` 统一拥有已有 `quickMessages` 的 CRUD；Watch 保留原选择元数据，避免手机功能依赖 Watch service。写入检查现有 `restoreSnapshot` 结果，不把无法观测的磁盘落盘当成已验证。
- 参数沿用 `{输入}` / `{輸入}` / `{input}` 的单项文本替换；不新增参数 schema。普通任务不询问输入，模板缺值才请求输入；最终 prompt 长度仍按原契约校验。
- 手机设置与 `IOSRunSavedActionIntent` 均按当前 ID 读任务，复用 opaque prompt handoff → 新对话正常发送 → 新 run claim。保存不会启动控制，不缓存运行时 ref/坐标，不重放上次动作。
- 系统参数询问使用现有 App Intents [`requestValue`](https://developer.apple.com/documentation/appintents/intentparameter/requestvalue(_:)-592nd)；代码编译和协议测试不替代 Siri/快捷指令的系统验收。

### Phase 2 验收收口

- 集成结果 `phase2-r2.xcresult` 199/199 通过；持久恢复补强与界面修正后的 `phase2-recovery-r3.xcresult` 80/80 通过，无跳过或运行期警告。中间被线程中断的构建不计作测试失败或通过。
- 真实 Room ledger → recovery planner/applier → conversation 保存重载 → engine 已覆盖：即使当前工具回执已存入消息，恢复也保持 replan 屏障，同批未派发项不执行；未知结果和已经完成的回执保持原语义，后续新批次正常执行。
- 独立 reviewer 查看全部 34 张接手状态截图及 4 张基线，确认 AX3 spinner 绘制侵占 24pt 图标列。只为该图标固定 Dynamic Type，右侧文字继续自适应；`phase2-final-visual/` 两张定点重新渲染并独立复核通过。
- 系统锁屏 Live Activity 的 paused 预览已实际显示“你正在操作 / 继续”，独立截图复核通过：`phase2-system-visual/paused-lock-screen.png`。本次模拟器未取得紧凑/展开岛画面；预览不创建真实控制 owner，不能代替按钮行为或物理设备后台接手验收。预览已清理。
- Phase 3 已进入实现，存储/Watch/Intent 与设置 UI 分别分工，最终共同审查和集成。

### Phase 3 独立审查与正常入口验收

- 共享存储统一处理快捷消息 CRUD、当前 ID 解析与参数替换；编辑保持原 ID/位置，写入失败不会报告成功。保留空标题 legacy 任务的“未命名快捷消息”显示，新建仍要求标题。
- 独立逻辑 reviewer 发现 Watch 下发列表已支持 legacy 空标题，手机 Watch 设置仍过滤掉它；现已统一使用 `savedQuickActions()` 并完成定点复核。
- `phase3.xcresult` 首轮 83/90 通过；六项新 native 交互测试无法通过协议 cast 查询 SwiftUI virtual AX identifier，改为既有交互测试采用的唯一 accessibilityLabel，保留真实按钮激活与行为断言；另一个旧接线断言随共享入口更新。没有 skip。Xcode 诊断收集挂在本轮 `simctl diagnose`，仅终止该诊断子进程让结果写出；后续测试使用 `-collect-test-diagnostics never`。
- `phase3-visual/` 全部 14 张普通/320pt AX3（列表、空状态、编辑、参数输入）已独立逐张查看，无错位/重叠/横向截断。
- 正常 App 的设置 → 运行环境 → 本机手机控制 → 常用任务已实际完成创建、编辑保持 ID、空参数留页，并填写本次参数。首次运行暴露导航缺口：局部 destination 没加入根路由，根页面虽收到 prompt 但设置页残留。改为已有 `Route` 系统的 `phoneSavedTasks`，由 AppShell 注入共享存储；不增加 dismiss 调度补丁。正在重跑与原样复测。
- 一次有限维护性审查已覆盖本轮存储/UI owner、readiness/动作核验/滚动搜索、handoff lease 与 Engine/Ledger 恢复边界；保留具有独立状态或失败原因的模块，没有新增重试框架或宏引擎。原有 `IOSAppIntentError.missingSavedAction` 分支已无调用，仅标记，未删除。

### Phase 3 验收收口

- `phase3-r2.xcresult` 64/67 通过；剩余两项误将输入框 value 当 label，已按正常 App 的实际 AX 值修正。系统确认按钮无法在 unit-host 中用 `accessibilityActivate` 驱动，因此该层只断言首击弹出确认且不删除；完整确认删除由正常 App 外部点击验证。没有绕过或跳过生产删除流程。
- `phase3-r3.xcresult` 8/9 通过，剩余断言误要求系统一定显示“取消”按钮。实际系统确认 UI 支持点外部关闭，AX 中没有该按钮；删除这一不属于产品契约的假设，保留确认按钮和未删除断言。
- 正常入口再次复现导航失败。诊断日志证实根路径已写成 `[.chat]`，没有回写；UIKit 明确记录 `setViewControllers:animated: ... while an existing transition or presentation is occurring`。根因是发送失败时同步弹出 alert，与导航争用展示过程。复用现有 composer 的 `configurationError` 展示失败原因并保留 prompt，不新增导航状态框架。
- 模板输入页仅准备 opaque URL，父页等真实 `.sheet(onDismiss:)` 后取走并提交一次；取消不提交，失败留页，关闭动画内重复点击不重复准备。普通任务直接提交。最终定点独立 review 已检查这些边界，临时诊断日志已移除。
- 最终 `phase3-r4.xcresult` 38/38 通过，无跳过或运行期警告。普通任务、模板空值校验、参数替换、关闭输入页并进入聊天页均通过正常 App 入口；缺 API Key 时保留实际任务文本并显示原因，无导航冲突日志。删除确认后为空列表，重启再进入仍为空。
- 正常交互证据在 `phase3-interactive/`：`plain-routed-to-chat`、`template-routed-to-chat` 的截图和 AX JSON，`empty-input-validation.json`、`deleted-empty.png`、`relaunch-delete-persisted.json`。最终三张正常入口截图也已独立复核，文本完整、输入区按钮无重叠、卡片边距一致。测试任务已清理，专属模拟器已关闭。本模拟器未配置真实 provider，这些证据只证明 UI/参数/交接与失败展示，不宣称已执行真实模型或手机动作。

### 使用入口

- 设置 → 运行环境 → 本机手机控制 → 检查自动化：检查实际连接、runner 与新界面读取，最后关闭临时连接；结果带检查时间。开启总开关后持续有效，任务仍受已选 App 范围约束。
- 同页 → 管理常用任务：保存标题、目标和完成条件；需要每次填写内容的位置写 `{输入}`。运行会新建对话，使用当次输入和当前控制配置，不保存旧元素 ref/坐标。
- 手机任务进行时可“我来操作”，待在途回执收口后手动操作；点击“继续”会先读取新界面，让模型重新规划，避免继续使用接手前的动作。

### 最终交付验证

- 首轮 Release 在 UI 现场发现导航缺陷后主动取消，不能作为最终构建证据。仅取消本轮构建进程，未触碰另一线程构建或设备任务；共享框架生成已完成。
- 已完成本轮源代码、受影响测试、独立逻辑与视觉审查、模拟器正常操作。签名版构建、原位安装、真机运行和就绪读取待最后一次交付验证；物理设备目前由另一线程验收并处于锁屏状态，不能将模拟器结果替代真机行为。

- 最终 Release 首次完整构建 `final-device-build-r2.xcresult` 成功（0 errors）。安装前签名核对发现实验 scheme 默认 App Group 与设备当前正式版不一致，已阻止安装该产物。只在私有验收 spec 将主 App、Watch、WatchWidgets entitlements 指向各自正式文件，并使用正式 App Group/URL scheme；独立重建 `final-device-signing-r3.xcresult` 后再安装。未改产品实验版默认配置，也未生成或覆盖另一线程正式项目。

- 2026-10-12 01:11:49，最终 `final-device-signing-r3.xcresult` 的 buildResult 为 `succeeded`，0 个 error summary、48 个 warning。日志有一次 SwiftCompile “exit code 0 but produced no further output” 诊断；最终进程退出 0，主二进制于本次构建末尾生成，签名校验和设备安装均成功，没有把该行当成源码编译失败或省略其证据。
- 主 App、Activity、内置隧道、Watch 和 WatchWidgets 均为正式 Bundle ID 与同一 Team。主 App/Watch/WatchWidgets 的 App Group 为 `group.app.amber.ios.watchkit`，URL scheme 分别为 `amber` / `amber-watch`；目标设备在 provisioning profile 内，`codesign --verify --deep --strict` 通过。完整核对在 `final-device-signing-r3.json`。
- 已安装到当前 iPhone 的 `app.amber.ios`，未卸载。安装前后 200 个偏好键中，仅 `amber.watch.sequence.v3` 不同；共享设置、主要设置、手机控制开关、App 范围、应用名映射与 Jev 配置六个关键键完全一致。App Group 容器路径不变；系统重新分配了 App 数据容器路径，不能声称路径未变，也未逐项验证 Keychain 或全部对话文件。
- 正常启动仅尝试一次：CoreDevice 10002，内层 `FBSOpenApplicationErrorDomain` code 7 / `Locked`，系统明确拒绝在未解锁状态启动。未运行本次 readiness、Mac XCTest 或任何历史消息动作，没有改 VPN/网络。物理设备已归还并告知另一线程可复用合并产物。
- 24 个本轮源码文件与构建前 manifest 一致；合并产物也包含另一线程 17:02 UTC 的 Markdown renderer 更新，三个 renderer 文件 hash 均一致。构建负载、专属模拟器已释放，临时交互任务和预览已清理。
- 待实机验收：解锁后的正常启动与“检查自动化”、真实 provider 驱动的新增动作/常用任务、后台接手/继续、紧凑及展开灵动岛、Siri/Watch 系统调用、纯蜂窝、Wi-Fi 切换与 Loon 共存。这些没有被构建/模拟器证据替代。
- 本次交付汇总：`docs/iphone-control-evidence/automation-next-delivery-20261012.json`；原始构建、签名、安装、设置对比和启动错误在 `build/phone-automation-next-20261011/`。

### 真机释放后的启动复核

- 2026-10-12 01:25 后收到新的真机释放授权。只读核对设备 bundle URL 与已安装的 r3 完全相同、App Group 相同，本轮自动化及合并 renderer 源码 hash 没有变化，因此没有重复安装。资源通知中的 PID 80296 已不在当前进程列表。
- 本次无参数正常启动成功，主进程 PID 47013；随后只读进程查询仍能找到该主进程。证据：`device-normal-launch-followup-20261012.json`、`device-processes-followup-20261012.json`。这更新了此前锁屏启动失败的状态，但只证明启动和短时存活，不替代 runner 或实际动作验收。
- 遵照此次协调范围，没有运行 Mac XCTest、额外 runner/tunnel 诊断或修改配置。已立即通知另一线程启动成功并归还真机窗口，保留其模拟器及性能测试占用。

### 提交范围与证据边界（2026-10-12）

- 本次提交收录本线程自 `69c2144` 以来的手机控制改动：持续开关、本机应用目录、内置隧道、动作核验与滚动查找、Jev、人工接手后重新规划、常用任务，以及对应测试和诊断记录。共享文件只纳入这些能力的接线；另一线程的 Intelligent UI、自适应卡片和流式预览，以及原有启动/存储优化继续保留在工作区。
- 上述构建、模拟器和装机结果对应当时的合并工作树与历史产物。本次分离后的提交另做了依赖范围审查、Swift 语法检查、结构化文件解析与 vendor patch 对照，没有重新执行整应用构建或真机验收。历史装机 SHA 不代表手机后来由另一线程更新后的版本。
- 用户外出后反馈纯 5G 仍无法启动自动化。本轮只读排查及开源证据已写入 `research/iphone-control-portability-plan-20261011.md`；当前问题未修复，蜂窝冷启动、网络切换和其他 VPN 共存均不能标为通过。
