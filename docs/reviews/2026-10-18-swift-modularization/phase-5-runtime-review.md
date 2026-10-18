# Phase 5 — 平台功能与运行链独立审查

状态：**Phase 5 源码与 MiniApp 定点行为审查通过；实际导航仍待 UI reviewer 收口。** Provider/Runtime/MiniApp、权限与 parser、存储、Council、Background 已对照迁前快照。Root 的 Main final-r1 已实际执行 995 项，993 通过、0 失败、2 跳过；grants 新组件补丁后另有定点 r3 实测 184 项全通过。

基线为 `/tmp/amber-phase5-source-baseline/files`，包含本期开始前的用户 WIP。审查只读；本 reviewer 没有修改产品、测试、YAML，也没有运行构建或模拟器。目录内的 `phase-5-editors-audit.md`、`phase-5-permissions-audit.md`、`phase-5-storage-audit.json` 和 `phase-5-council-audit.json` 用于逐段定位，以下判断另沿当前调用链复核。

## 当前已核的 owner 链

- Provider 页仍拥有表单 draft、model fetch request ID/取消及 `saveConfig`。保存先写请求头，随后通过 `IOSSharedSettingsStore.updateProviderConfiguration → restoreSnapshot` 把 endpoint/API Key 同一提案提交；Keychain 任一步失败时回滚已写凭据，设置 JSON 和内存 snapshot 不提交。若配置失败，页仍按原逻辑尝试恢复旧请求头并给用户错误。组件和 model/status 类型的提取没有生成第二份凭据状态或新保存入口。此链的代码体与迁前一致。
- Runtime SSH 页的 host/port/user/auth binding 仍写同一 `sshProfileDraft`，变更会取消 probe 并清 trust 候选。probe 仅保存内存中的候选与 probe 前 profile；显式信任后仍需认证成功，且在持久化前比较当前 draft 和已存 profile，最后只经 `SettingsStore.upsertSSHProfile` 写 profile/credential。原 iSH policy 和 remote-command WIP 保留。新增文件是同一 `RuntimeEnvironmentView` 的编辑职责 extension，没有第二个 credential writer。
- MiniApp runner 仍拥有 `appId`、加载状态、bridge/host-confirmation owner；抽出的 AI 恢复器由 AppShell 启动，用相同 durable run ID 与 `miniapp:` input ref 标记中断并记审计。system bridge 和 confirmation owner 原实现搬迁，未创建新的 runner identity 或绕过宿主确认。
- 权限 catalog 的完整 `capabilities` 字面量从迁前与当前独立抽取，均为 **101 个有序且唯一的 ID**，UTF-8 SHA-256 同为 `6ed97589528a5e8cfb2e4bd20b7e1cee793514562808baa461e8ed20c85bfebc`；其中 10 条 Android 不支持能力及原 WIP 字段仍在。registry 管数据与派生集合，policy store 管同一设置/审批持久化，coordinator 仍路由系统请求，两个 widget validator 仅处理各自格式，没有更改权限含义。
- `IOSConversationStore` 仍持有 `importEpoch`、restore gate、`writeSequences`、在途写入 drain 和唯一 `persist`；新 branching extension 读取同一 storage，跨 await 核 epoch 后仍调用原 `persist`/`setCurrent`，没有直接增加第二个 `saveConversation` writer。`DocumentAccessStore` 的 workspace store 与 SharedSettings agent 特性、Compaction budget/codec/context 按各自变化原因拆出。Compaction 的跨文件策略类型、显式六字段初始化器及 helper 由实际调用方决定 internal 可见性；四个仅 codec 文件内使用的 helper 保持显式 `private`，没有把所有 helper 一概开放。
- Council 的 `CouncilChatViewModel` 仍持有 discussion ID、消息、归档和后台 lease；`IOSCouncilRoomRunner` 持有 generation、任务 ID 和 provider 流程。streamer 的 close 先封接收边界、排空已接受的 FIFO chunk 再取 terminal snapshot；停止/到期仍先写 transcript/archive 再释放该 discussion 的 lease，旧等待任务核 discussion ID，不会释放新轮租约。UI/归档/plan/streaming 的提取没有再造运行 owner。

## Background 源码取舍

原 packet 建议 concrete executor/resumer/terminal 与窄输入、registry 私有；最终实现为同一个 `@MainActor IOSChatBackgroundGenerationCoordinator` 的八个职责文件，原 Coordinator 保留 registry、BGTask 注册、headless composition 和 run claim。`/tmp/amber-phase5-background-bodysha.json` 映射 192/192 个迁前方法体且签名无增删，但这只证明文本迁移。本次另查真实访问：Executor 持有执行入口，ResponseResumer 管 response/ledger 恢复，TerminalWriter 管 durable terminal，Recovery 管陈旧任务与恢复，PayloadCodec 和 MessageProjection 为数据转换，Contracts/RunState 各自保存原合同与生命周期类型；没有新 helper 实例、第二 registry 或 context bag，生产其它类型未直接读写这些 registry。为纯粹拆出 helper 实例而追加回调和参数转接，在当前并发顺序下缺乏收益；因此**同 owner 的职责 extension 可接受**，但不称为独立模块编译或独立状态 owner。

多个字段因跨文件 extension 改为 internal。`activeJobs`、`activeRunStates`、`activeBackgroundTasks` 等在对应职责文件有真实写入，不应为形式上的私有化制造转发。`dependencies`、`activeDetachedResponseTasks`、`foregroundResumeInFlightRequestIds`、`db`、`runStore`、`toolLedger` 仅在原 Coordinator 文件赋值或移除，extension 只读取/调用，已定向改为 `private(set)`，保留跨文件 getter 和唯一 setter。最终实现包把这些文件归在 `Chat/Background`，早期目录候选不构成额外搬迁要求。

## 精准可见性与最终验证

初版 `IOSConversationStore.importEpoch` 曾从原 `private var` 扩为模块内可写 `var`，而新 branching extension 只需读取。最终已改为 `private(set) var importEpoch`，跨文件 getter 可用，restore 的原 Store 保持唯一 setter。Compaction 初版跨文件 `private extension` helper 造成实际编译错误；最终按调用者修订为 16 个必需 internal helper、4 个文件内 `private` helper，`IOSCompactPolicy` 的显式初始化器可供 budget extension 使用。`phase-5-storage-audit.json` 已更新为 30 项定向可见性记录，关键业务体 SHA 未变。Council 的 `attachmentRoomGeneration` 原文件内 getter 被新 RuntimeView 读取；当前改为 `private(set)`，仅 ViewModel 可递增。我另扫剩余 `fileprivate` 与 `private extension` 的调用文件，未发现尚需跨文件开放的成员。其后 Root 的 Main final-r1 已构建并执行测试。

MiniApp grants 最后提取为 `MiniAppPermissionGrantsSection` 后，展示决策用 `IOSMiniAppPermission.normalized(permission)` 与同 app 的 repository grant record 比较；repository `setGrant` 也以相同规范化键保存。Runner 的 `app` 读取 `repository.revision`，持久化成功与回滚后的 `publish` 都递增 revision，管理 sheet 随父 View 重算并重新注入 grants；新组件本身只调用 `onDecision`，唯一写入口仍是 Runner `setGrant → IOSMiniAppRepository.setGrant → persistAndPublish`。新组件没有第二份授权状态，也没有绕开 host confirmation。

补丁初稿有一处真实编译阻断：`MiniAppRunnerView.grantsSection` 改为 `private`，而既有 `IOSMiniAppVisualEvidenceTests.swift:104` 跨文件调用它。QA 已把该测试的视图入口改为直接构造新组件，并保留原 fixture、布局断言和截图名；我复核了当前调用点，无需放大生产可见性。此项源码阻断已闭合，补丁后定点 r3 也已完成实际编译和执行。

我独立读取 `/tmp/amber-phase5-final-r1.xcresult` 的 test-results summary：`Passed`，995 total / 993 passed / 0 failed / 2 skipped。再独立读取新组件后的 `/tmp/amber-phase5-miniapp-final-r3.xcresult`：`Passed`，184 total / 184 passed / 0 failed / 0 skipped，`runtimeWarnings` 为空；同结果已归档 `phase-5-miniapp-final-summary.json`。故 **MiniApp grants 源码及本次定点行为范围可签**。先前 r2 的 testmanager 握手失败并无真实 XCTest 执行，不计作产品回归；保留其诊断记录，不代替 r3 实测。独立 Novel P5 consumer build 已由 Root 的 `build-results` 复核为 succeeded、0 errors、7 项既有 warnings，只证明该消费者的源闭包可构建。两项实际导航仍待 UI reviewer 的结果；真实 provider、Keychain/系统权限弹窗、SSH 网络、后台系统执行和真机体验不能由模拟器单测替代。
