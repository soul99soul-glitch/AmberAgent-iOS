# macOS Phase 3 · 真实工作流与扩展边界

日期：2026-10-31 · worktree `d104f2c37f52`，分支 `synara/amber-macos-context-safety`，基线 HEAD `e3837594`（未提交）。

## 出口条件对照（计划 §5 P3）

| 计划要求 | 状态 | 证据 |
| :--- | :--- | :--- |
| 插件 `sideEffect` 回归测试通过，自动批准不得执行、手机端不得批准 | 通过 | `DesktopPluginApprovalTests` 4 项（含 `meeting_closeout`） |
| `watchtower` 至少 1 条端到端证据 | 通过（单测级） | `DesktopWatchtowerTests` 7 项 + `DesktopBuiltInRecipeTests` |
| `apple_schedule` 至少 1 条端到端证据 | 通过（假服务级） | `DesktopAppleScheduleTests` 8 项 |
| `feishu_meeting_loop` 至少 1 条端到端证据，重复执行不重复发送 | 通过（模拟传输级） | `DesktopFeishuIdempotencyTests` 12 项 |
| 能力声明与真实行为一致 | 通过 | `DesktopPluginCapabilityTests` 7 项 + `DesktopPluginCapabilityLayoutTests` 3 项 + `docs/plugins.md` 能力矩阵 |

**真实外部账号的 E3 未做**：按交接要求不向飞书、系统日历做真实写入，也不启动用户正在运行的 Amber。上述三处「端到端」的证据止于注入的假传输 / 假日历服务，不是真实账号回执。

## 实现

### M3.1 插件审批边界（前序线程已完成，本轮只补回归覆盖）

- 覆盖 `DesktopPluginApprovalTests` 的 pure / networkRead / idempotent / sideEffect 四档判定、全局自动批准不得放行外部写入、通知与手机端批准被拒绝。
- 本轮把新增的 `meeting_closeout` 一并纳入高风险断言。

### M3.2 插件能力诚实（补缺口）

- `DesktopPluginCapabilities` 新增 `hostModules`，取值受 `DesktopPluginHostModule` 约束；未知模块名让清单校验直接失败。
- 能力矩阵新增「系统数据」行：未声明时明确写「沙箱脚本无法访问日历、提醒事项等系统数据」，而不是沉默。
- `hostModules: ["calendar"]` 只有在 `DesktopPluginHostModule.implemented` 里存在且插件启用时才标「已接线」，否则标「未接线」并说明原因。
- 权限摘要不再对第三方插件承诺「允许访问 N 个 HTTPS 域名」，改为「沙箱网络尚未接线，请求不会发出」。
- `docs/plugins.md` 增加「沙箱真实能力」与「官方内置插件」「随附 Recipe」三节，与代码逐项对齐。

### M3.3 `watchtower`（纯 JS 快照 / diff）

- 新增内置插件 `watchtower`：`snapshot`（建基线 / 比差异 / 报新增与消失行）、`status`（已监控页面清单）。
- 沙箱不联网：页面正文由宿主 `scrape_web` 抓取后作为参数传入，符合「不要开无限制的口子」。
- 差异按行归一化（压缩空白、忽略空行），只有真实内容变化才算变化；空白重排保持安静。
- 空正文被拒绝且不覆盖既有基线，避免把一次抓取失败变成「页面被清空」。
- 新增 `DesktopWatchtower.quietVerdict(tools:)`：定时任务若最后一次 watchtower 调用返回 `changed=false`，该轮直接标记为「不值得打扰」并在通知层静默；无法解析或没有 watchtower 调用时保持原行为（不会误静音）。
- 随附 Recipe `watch_page`：`scrape_web` → `plugin__watchtower__snapshot`。

### M3.4 `apple_schedule`（官方原生插件，EventKit）

- 新增 `DesktopCalendarService` 协议 + `DesktopEventKitCalendarService` 实现；插件工具层只依赖协议，因此整条链路都能用假服务测试。
- 工具：`list_events`、`list_reminders` 只读；`create_event`、`update_event`、`delete_event`、`complete_reminder` 为外部写，按高风险处理（「自动批准普通变更」放行不了，手机端只能拒绝）。
- 权限：
  - 读取不弹系统授权框（`requestIfNeeded: false`），避免后台任务突然弹窗；
  - 权限被拒时给出可执行提示——「系统设置 › 隐私与安全性 › 日历」，并说明可停用插件；
  - `.writeOnly` 不算已授权（读不回来）。
- 写入目标：默认写进 Amber 自建日历 `Amber`，避免混进用户自己的日历；显式传 `calendar` 名称时按名称匹配，只读日历会被拒绝。
- `EKEventStore` 惰性创建。这是本轮定位到的一个真实缺陷：之前在插件 store 初始化时创建，在无 TCC 上下文的快照 / 测试宿主里直接 `EXC_BAD_ACCESS`。

### M3.5 `feishu_meeting_loop` + 幂等

- 新增 `DesktopFeishuIdempotency`：键 → 已确认结果的 JSON 存储（最多 200 条，按时间裁剪），跨重启有效。
- `bot_create_doc`、`bot_send_message`、`create_event` 接受可选 `idempotency_key`；命中时返回上次结果并标 `replayed: true`、附中文说明。
- 新增 `meeting_closeout` 工具：一次调用完成「建云文档 → 发群回执」，键默认按「日期 + 标题」生成，因此重跑同一会议天然幂等；`send_receipt: false` 可只归档；回执只在文档建成后才发，群里不会出现死链。
- 随附 Recipe `feishu_meeting_loop`：单步 `meeting_closeout`；读群聊与写纪要仍由对话完成，人审后再触发。
- Recipe 绑定语法只支持一级字段，所以 `meeting_closeout` 额外把 `document_id` / `url` / `message_id` 平铺到顶层（嵌套对象保留给工具卡片）。

### 顺带修复的两个阻断性缺陷

1. **`Date` 比较运算符导致测试进程 SIGSEGV。** 本机 Xcode 27 的 SDK 与运行库不匹配，`Date.>=` / `Date.>` 解析到 `Foundation` 里不存在的符号，`Date` 比较一律 `EXC_BAD_ACCESS`。已在小样例中独立复现（`Symbol not found: _$s10Foundation4DateV2geoiySbAC_ACtFZ`）。全仓把对 `Date` 的比较改写为 `timeIntervalSince(...)`：`DesktopContextBudget`、`DesktopScheduledTasks`、`DesktopGateway`、`DesktopWorkspace`、`DesktopWorkspaceView`、`DesktopScheduledTasksView`，以及本轮新增的两个日历文件。这不是 P3 范围内的功能改动，但不修就无法跑全量测试。
2. **快照工具整轮崩溃。** `DesktopWorkspace.uiFixture()` 的全量窗口矩阵在 SwiftUI `sidebarGroups` 里崩溃，在未修改的 `HEAD` 归档上同样复现（既有问题）。为只截改动界面，新增 `AMBER_SNAPSHOT_ONLY` 开关；默认行为不变。

## 命令与计数

| 命令 | 结果 |
| :--- | :--- |
| `macApp/scripts/test-runtime.sh -j 6 --filter "DesktopPluginCapabilityTests\|DesktopAppleScheduleTests"` | 15 / 15 通过 |
| `--filter "DesktopWatchtowerTests\|DesktopFeishuIdempotencyTests"` | 19 / 19 通过 |
| `--filter "DesktopBuiltInRecipeTests"` | 6 / 6 通过 |
| `--filter "DesktopPluginCapabilityLayoutTests\|DesktopPluginCapabilityTests"` | 10 / 10 通过 |
| **全量** `macApp/scripts/test-runtime.sh -j 6` | **485 项，2 跳过，0 失败**（P2 结束时 445） |
| `snapshot-ui.sh`（`AMBER_SNAPSHOT_ONLY=1 AMBER_SNAPSHOT_APPLE_SCHEDULE=1 AMBER_SNAPSHOT_PLUGIN_CAPABILITIES=1`） | 4 张图 |

## 截图

`docs/product/macos/phase3/plugin-capabilities/`

- `plugin-capabilities-light.png` / `plugin-capabilities-dark.png`（880×1500）：飞书插件的「权限与能力边界」卡片，含新增的「系统数据」行。
- `plugin-apple-schedule-light.png` / `plugin-apple-schedule-dark.png`（880×1180）：`apple_schedule` 选中、技术详情展开的状态。

**视觉检查方式与局限**：本会话模型不支持图像输入，`vision` 子代理在本机模型注册表里不可用（`Unknown subagent model 'opencode-go/qwen3.7-plus'`）。因此**我没有用眼睛看过这四张图**。替代手段是 `DesktopPluginCapabilityLayoutTests`：用与视图相同的字体和字号实测每个能力名与徽章的文字宽度，断言它们分别放得进 84pt 名称列与 64pt 徽章列（含内边距）。这能挡住截断与参差，但挡不住遮挡、z 序、颜色对比度这类只有看图才发现的问题——后者留给 P5 的窗口矩阵。

## 未验证项

- 真实飞书账号端到端（建文档、发卡片、读群聊）与真实系统日历写入：按交接要求全部用模拟传输 / 假服务替代，没有任何真实外部写入。
- TCC 授权流程的本机表现：`requestFullAccessToEvents` 的真实弹窗、`.writeOnly` 的实际返回、用户在系统设置里改权限后的恢复路径，均未在带签名的 Amber.app 上实跑。
- EventKit 提醒事项读取使用了 `DispatchSemaphore` + `RunLoop` 轮询等待异步回调，这段在主线程上的真实行为未实跑验证。
- `watchtower` 的真实页面抓取质量（`scrape_web` 正文抽取）未验证；只用合成文本测了快照与差异逻辑。
- 真实定时任务触发 watchtower 并静默的端到端：`quietVerdict` 有单测，但「定时任务真的跑一轮 + 通知真的不发」未实跑。
- 四张截图未经人工或视觉模型核对（见上）。

## 交接要点

1. **改动都在 worktree `d104f2c37f52`，未提交、未推送。** 36 个已跟踪文件被修改，28 个未跟踪（其中 9 个是本轮新增的源码/测试）。更早的 UI 未提交改动（顶部胶囊、飞书设置页、侧栏性能）完整保留。
2. **`Date` 比较必须继续用 `timeIntervalSince`。** 这是本机环境缺陷，不是代码风格；写回 `Date.>=` 会让测试进程 SIGSEGV，且崩溃点在 Foundation 内部，堆栈会指向业务代码，很难认。新增代码请照抄现有写法。
3. **不要在全量快照里跑窗口矩阵**：`DesktopWorkspaceView.sidebarGroups` 在 HEAD 上就崩，需要单独排查；暂时用 `AMBER_SNAPSHOT_ONLY=1` 只截改动界面。这个崩溃在 P5 做窗口矩阵时会直接挡路。
4. **三个内置插件 ID 已占用**：`feishu_calendar`、`apple_schedule`、`watchtower`。导入同名插件会被拒绝；`store.plugins` 现在恒有三项，任何「只有一个内置插件」的假设都要改（`DesktopPluginTests` 已按插件 ID 过滤）。
5. **随附 Recipe 在启动时安装**：`DesktopBuiltInRecipes.install(into:hasFeishu:)` 由 `DesktopLiveWorkspace` 调用，已存在的用户版本不会被覆盖。
6. **留给 P4/P5 的接口**：`DesktopCalendarService` 是事件源的正确接缝，P4 若要做「日程触发任务」应在这里加事件而不是在工具层加轮询；`DesktopFeishuIdempotency` 的存储键命名（`idem:` 前缀 + 200 条上限）需要和看板/审计记录保持语义一致。
7. **独立 review 尚未进行**：按 Hub 规则实现者不得自审通过。本阶段只能标「待独立 review」，建议审查顺序为 Tool Schema（`DesktopAppleScheduleTools` / `meeting_closeout` 参数）→ 审批链路（effect → `isHighRisk` → 通知/手机端拒绝）→ 存储（`storage.json` 的幂等键与 watchtower 快照）→ UI 消费（能力矩阵与权限摘要）。
