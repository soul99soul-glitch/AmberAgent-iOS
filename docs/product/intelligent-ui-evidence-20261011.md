# AmberAgent iOS 智能 UI 实施与验收记录

本轮范围是原生任务 UI。模型通过 `task-ui` JSON 描述决策卡和组件组合；宿主负责局部状态、来源归属、保存及明确提交。SVG、Three.js、VChart、slides 与 MiniApp 继续承担各自的展示或应用职责。

验收日期：2026-10-11 至 2026-10-12。P0–P2 实现与各阶段 review 已完成；P3 的源码、受影响回归和合并设备交付已完成，真机生产 UI 操作及同会话持久化终态核验仍未通过。下方分别记录各层证据。

## 实施范围

| 阶段 | 交付 |
| --- | --- |
| P0 | v1 协议、流式边界、默认 NativeChatTimeline 接入、原生决策卡、正文与表格分段 |
| P1 | 独立草稿 owner、同设备恢复、会话与变体来源隔离、冻结提交快照、保存成功后继续生成、后台成功来源标记 |
| P2 | 80 种原生语义组件、设计 token、有界组合、能力 prompt、明确文字继续 |
| P3 | 源码闭环审查、受影响回归、实际 hosting 截图、真实 provider 与设备验收 |

组件分为布局 10、文字 12、状态 10、输入 14、数据 10、媒体 8、任务语义 8、动作 8，共 80 种。每一种都有对应原生渲染分支；颜色与样式变体不计入这个数量。样式允许 5 种 tone、4 种 emphasis、2 种 density、2 种 alignment，以及间距和内边距 token；组合深度限制为 8，节点上限 160。

生产调用链：

```text
NativeChatTimelineView
  → MessageBubbleView
  → ChatAssistantMarkdownView
  → ChatIntelligentUIBlock / IOSIntelligentUICard
  → IOSIntelligentUIStateStore
  → IOSIntelligentUIHost.submit
  → ChatViewModel.submitIntelligentUI
  → durable user message + frozen metadata snapshot
  → recheck actual saved branch
  → existing generateResponse / provider pipeline
```

## 各阶段 review 与精准修复

- P0 review：修正任务卡两侧表格共用缓存身份、冻结时旧快照、选项及必填字段的无障碍文案。真实 hosting 的 320pt 深浅色、大字号及默认 timeline 已完成逐张视觉检查。
- P1 review：修正提交保存期间的消息 mutation 门禁和分支 receipt 刷新。后台 checkpoint 与终态按同消息、同正文、同 run 合并，仅更新任务来源 metadata，保留较新的内容及其它字段。
- P2 review：修正内嵌继续按钮门禁、重复标题、未回答开关与明确 false 的区别、filled 前景色、字段标签、摘要语义。实际 AX3 图片又确认多选说明截断和颜色选项错位，已分别修正纵向展开和单列／顶部对齐。
- P3 review：独立 reviewer 沿生产展示、草稿、提交、保存、请求及生命周期核查，未发现新的确定阻断。源码 review 与运行结果分别记录。
- 真实保存回归发现 Swift 字典回传 `UIMessagePart.Text.metadata` 不是真正的 Kotlin `JsonObject`，导致消息序列化失败。新增 Kotlin `textPart(text, metadata)` 桥接构造 `JsonObject`；嵌套 metadata 回归又确认 Swift 强类型 Map 读取会触发 K/N 集合映射崩溃，因此增加标量读取 `metadataString` 和 Kotlin 内合并 `mergeTextMetadata`。提交与终态路径保留嵌套 JSON，不经 Swift 强类型 Map 往返。
- 普通流式正文增加 task-ui 预检测后，长文回放连续失败。早期同配置原始 renderer 对照为 37 通过、1 跳过，新 renderer 为 36 通过、1 失败、1 跳过；后续 G 轮原始 renderer 也在长文和表格门槛上失败，因此不能把持续失败全部归因于新增任务路径。检测器微测确认 KMP NSString 上的 UTF8 count／索引会转码旧正文，已改为 UTF16 有限范围扫描与原始 code unit checkpoint，并恢复普通正文的直接 Markdown 分支。两项产品改动均完成独立 review。
- 最终性能调查另确认测试观察器每帧扫描 foreign String 的成本。`hasRawMarkdown` 增加 ASCII 字面候选预筛，最终判断继续使用原来的 `String.contains`、分行和空白裁剪；16 个结构样例与 102 个 Unicode 邻接样例保持一致。递归遍历、每帧采样、全部断言和阈值未改。直接用字面匹配替代原判断会误判组合字符，未采用该方案。I 轮生产 renderer 的完整受影响集合通过；表格性能用例不使用这个观察器，不能把它的通过也归因于观察器修正。

## 运行证据

### KMP metadata 桥接

```text
./gradlew :shared:jvmTest --tests shared.IosToolOutputJsonBridgeTest --console=plain
4 tests, 0 failures, 0 errors; BUILD SUCCESSFUL
```

测试覆盖嵌套 metadata 序列化往返、空 metadata、标量读取及字符串标记合并。日志为 `/tmp/amber-task-ui-metadata-jvm-r2.log`。模拟器 r5 的真实保存、重启读取及后台终态合并回归通过，包含已有嵌套对象、数组和布尔值的保留。

### 模拟器与真机

模拟器使用 F3D5299E、iOS 26.5。r5 集成结果为 275 通过、2 失败、1 跳过（共 278）：失败项是既有长正文 viewport 性能门槛和 unit hosting AX 交互；跳过项为既有专用条件测试。协议、草稿、生命周期、终态、真实保存、请求 policy、正文渲染回归和生产 timeline 视觉测试通过。组件 16 项使用未发生产品变更的 r4 通过结果，基础截图共 80 种，并补充辅助功能样本。

unit AX 交互的失败已定位为 SwiftUI AX node 不支持测试中的 protocol cast；fixture 首个选项改由唯一 label 识别，其余真实点击和状态断言保留。同一次测试已验证选择、多选、明确 false、展开、一次冻结提交、禁用重复提交及重置，后续 A/C/D/E 均通过。E 轮非 Replay 的 105 项全部通过；Replay 37 项为 35 通过、1 失败、1 跳过，长文获得 38 个增长快照（要求至少 45），p95 文字增量 36（上限 24）、高度增量 61pt（上限 40pt）。这些结果不能标为性能通过。

另一次移除 delta 任务检测的诊断构建在并行 Release 编译期间运行，仍有两项性能失败；该次环境不能用于独立归因。F 轮为 138 通过、2 失败、2 跳过；G 轮原始 renderer 的 Replay 为 34 通过、2 失败、1 跳过。所有历史结果保留，正式项目已恢复生产文件引用，没有保留诊断替身。

**最终 I 轮：142 项，140 通过、0 失败、2 跳过，xcodebuild exit 0。** 覆盖 Replay 37、NativeTimelineScrollCore 55、ViewportPolicy 4、RowContentHashCache 12、Protocol 28、ComponentInteraction 1、RenderingRegression 3、Visual 2。24KB 长文 snapshots／p95／跟随 debt 和增长表格帧间隔均通过原门槛；计时期间无 Swift 编译负载。跳过项为按条件启用的 reasoning 成本采样和 unit hosting 未暴露可激活 AX 的交互测试；后者沿用前面已通过的 E 轮实际 AX 动作证据，I 轮跳过本身不证明交互。结果包为 `/tmp/amber-task-ui-final-simulator-i.xcresult`，完整调查边界见 [性能记录](intelligent-ui-evidence/performance-investigation-20261012.json)。

真机为 `00008160-001939111420000A`，iOS 27.2（24B5089g）。r5 与后续 UTF16 r6 的签名构建、安装成功；r2 真机运行有 16 项通过：真实 provider 两轮 1 项、提交与保存 13 项、原生 hosting／默认 timeline 视觉 2 项。独立 UI runner 两次在 test method 开始前失去 IDE 连接（code 74），r3 未执行产品交互。模拟器独立 UI runner bootstrap 已成功，但因没有启用真实 provider 环境开关，唯一用例跳过；它只证明模拟器 runner 能连接。

最终合并设备产品由并行手机自动化线程构建 GPL target；其私有验收项目已对齐正式 App Group、main／Watch／Widgets entitlements 及 URL scheme。r3 Release 构建成功（0 errors、48 warnings），已原位安装 `app.amber.ios`，包含 01:02 CST 落盘的最后 renderer 修复。主 executable SHA-256 为 `55faaa2d2e4516c8348e7ac7d412ebeb3fed8d46b13fcec6b304d9af457d90ee`，本任务已复核一致；主／Watch URL 分别为 `amber`／`amber-watch`。直接复用已安装产品，不再次用普通 target 覆盖。

安装前后六个核心设置键一致，App Group 标识及容器路径保持；全部 preferences 并非逐项不变，`amber.watch.sequence.v3` 有变化，app data container 路径也随安装更新。首次正常启动遇到 CoreDevice 10002／FBS Locked，随后 01:26 左右同版本无参数正常启动成功（PID 47013），已核对独立 launch 记录。

本任务立即启动 r4 真机 UI 验收，但设备在测试预检时再次锁屏，424 秒后 runner 以启动前 pending connection 丢失结束，未执行任何产品测试方法。最终只读检查仍为 `passcodeRequired=true`。因此签名、安装与正常启动通过，生产任务卡点击、键盘及同会话 durable 终态仍未通过。[最终合并设备记录](intelligent-ui-evidence/final-device-delivery-20261012.json)保留源码与 binary hash、设置比较和每次事件边界，不包含凭据。

实际 provider 为当前助手的 `DeepSeek / deepseek-flash`，优先于全局的 `opencode go / hy4-preview`；不是测试切换模型。两轮响应分别生成合规卡片及复述“本地存储／必须离线可用”，见 [响应附件](intelligent-ui-evidence/live-provider-device-20261012.txt)。安装前后及运行后，legacy settings 和 sharedSettingsJson 解析内容相同，见 [配置保留记录](intelligent-ui-evidence/device-config-preservation.json)。[真机 hosting 的默认 timeline 图片](intelligent-ui-evidence/native-timeline-physical.png)已检查对齐、间距与文字布局；它不代替 app 内点击与键盘验收。

长文 fixture 的配对微测覆盖 60 次追加，每次 12 个中文字，初始 26,298 UTF16 units／78,032 UTF8 bytes，`swiftc -Onone`，30 轮中位数，排除快照构造及初始扫描。NSString 路径从 87.678ms 降为 0.042ms；Swift 原生字符串从 0.407ms 变为 2.984ms（约 0.050ms／次）。[原始检测成本记录](intelligent-ui-evidence/preflight-utf16-cost.txt)只证明检测器成本，不能替代整体 UI 回放。

历史失败保留：r1 有一次 40.21ms / 40ms 性能门禁失败；r3 出现 metadata 保存失败、测试 fixture 越界及截图语义检查方式不适用。没有放宽性能断言，也没有以截图存在替代保存成功。

## 证据边界

- 80 种组件都生成了基础 hosting 图片；视觉 review 对生产卡片及高风险代表性组件逐张检查，没有声称人工逐像素验收全部组合。
- 展开、tabs 等 presentation 字段不上传为任务约束，但仍属于本地草稿 revision；修改后可以明确再次提交。这是本轮按草稿 revision 去重的行为。
- 真实 provider 的两轮选择消费、真机原生点击与键盘、系统后台持续运行、120Hz 手感和所有 provider 兼容性属于不同验收层级，只记录实际取得的证据。
- 未提交、推送或对外发布。当前工作树包含用户原有及并行手机自动化工作，构建安装内容须结合该工作树状态理解。

## 真实交互验收的复现路径

独立 scheme `IOSIntelligentUIAcceptance` 只引用 `iosApp/iosAppUITests/IOSIntelligentUIAcceptanceTests.swift`，普通 `iosApp` scheme 的测试集合不受影响。先为目标设备 `build-for-testing`，再复制生成的 `.xctestrun` 到同一 `Build/Products` 目录，在 UI test target 的 `EnvironmentVariables` 中加入 `AMBER_TASK_UI_LIVE_PROVIDER=1`，通过 `test-without-building -xctestrun` 运行。未设置此值时用例跳过，不发真实请求。

在真机复用合并产品时，还需把该 manifest 的 `UITargetAppPath` 指向已经核对身份、签名和 App Group 的最终 GPL app；不要保留旧普通 app 的安装路径。保留原 manifest 的 `__TESTROOT__`／`__TESTHOST__` 路径语义。测试新建独立会话，不覆盖 composer 草稿、不修改模型或认证，使用唯一 `TASK_UI_ACCEPTED_<32 hex>` 标记关联第二轮助手。

UI 测试通过后，用 `devicectl device copy from` 的 `appDataContainer` 域、`app.amber.ios` 标识，复制 `Documents/conversations`、`Documents/agent_runtime.db` 及实际存在的 `-wal`／`-shm` 到私有证据目录。保留所有 SQLite sidecars，再执行：

```bash
python3 iosApp/scripts/check-intelligent-ui-acceptance.py \
  "$ACCEPTANCE_COPY/conversations" "$ACCEPTANCE_COPY/agent_runtime.db" \
  --marker "$ACCEPTANCE_MARKER"
```

脚本只检查该标记对应的四条选中消息、任务来源及冻结提交 metadata、已保存草稿和 Room 中两个实际 `chat` run 的成功终态。它不修改真机或原始副本，不打印其它会话及凭据。脚本 fixture 已覆盖 WAL 正例和失败边界；当前尚未取得真实 app 点击后的通过记录。

设计与阶段契约见 [intelligent-ui-plan.md](intelligent-ui-plan.md)。
