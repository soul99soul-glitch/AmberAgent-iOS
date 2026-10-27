# 桌面版定时任务（主动性 第 1 步）实施计划

日期：2026-10-26 · 分支：`feat/macos` · 状态：待实施

## 目标

让 Amber 桌面版能按时间自己跑 agent 任务：关掉窗口也照常运行，跑完或需要批准时发 macOS 通知。这一步不涉及 Gateway 推送和 iOS 端，只在桌面版内部形成闭环。

验收标准：建一个「每天 9:00 汇总某目录新文件」的任务，关掉主窗口后它照常运行；结果写进一个新会话，并弹出「任务已完成」通知；如果任务中途碰到需要批准的工具，会暂停并推送通知，在通知上点「批准」后继续执行。

## 现状（已读代码确认）

- 对话主链路：`DesktopWorkspace.send()` → `startGeneration(conversationID:configuration:apiKey:)` → `DesktopAgentProvider.start(... context: DesktopRunContext)`。它依赖 `selectedID` 和 `draft` 这类 UI 状态，没有无界面的入口。
- 审批：`DesktopAgentExecutor.execute` 调 `tasks.autoApproves(toolName)`，读取的是全局 `autoApprove` / `autoApproveHighRisk`（`DesktopAgentTasks.swift:140`）。不需要自动批准的，走 `requestApproval` 持久化后等待 `decide`。
- 通知：`DesktopNotifications.notify(runID:conversationID:outcome:)` 只有已完成和未完成两种结果，没有操作按钮。点通知会经 `DesktopNotificationRouter` 打开对应会话。
- 生命周期：只有一个 `Window("Amber")` 场景，没有菜单栏常驻，也没有开机自启。退出流程在 `AmberMacAppDelegate.applicationShouldTerminate`。
- `DesktopRecipes` 是固定步骤的工具流水线（amber.recipe.v1），不负责调度。之后可以把它作为定时任务的一种执行体。

## 设计

### 1. 数据模型 `DesktopScheduledTask`（schema `amber.schedule.v1`）

```swift
struct DesktopScheduledTask: Identifiable, Codable, Equatable, Sendable {
    var schema = "amber.schedule.v1"
    let id: UUID
    var name: String
    var prompt: String
    var schedule: DesktopSchedule          // once(Date) / daily(h,m) / weekdays(h,m) / weekly([weekday],h,m) / interval(minutes ≥ 15)
    var providerID: UUID?                  // nil = 当前默认模型
    var toolsEnabled: Bool
    var subagentsEnabled: Bool
    var approval: DesktopUnattendedApproval
    var output: DesktopScheduleOutput      // .newConversation（默认）/ .appendTo(conversationID)
    var missedRun: DesktopMissedRunPolicy  // .runOnceOnWake（默认）/ .skip
    var enabled: Bool
    var lastRun: DesktopScheduleRunRecord?
    var nextRunAt: Date?
}

struct DesktopUnattendedApproval: Codable, Equatable, Sendable {
    var autoApproveOrdinary: Bool          // 默认 false
    var autoApproveHighRisk: Bool          // 默认 false，打开时 UI 二次确认
    var allowedTools: [String]?            // nil = 全部已暴露工具；否则白名单外直接拒绝
    var approvalTimeoutHours: Int = 12     // 超时未批准 → 本次运行记为失败
}
```

- 定时任务一律使用自己的审批策略，不读全局的 `autoApprove`，这样无人值守的任务就不会受对话设置影响。
- 模型先在 Swift 侧定义，wire 格式加上版本号。等到第 4 步 iOS 需要远程创建任务时，再迁到 KMP。之前我说过「放在 KMP 共享层」，这里做了调整：理由是第 1 步只有桌面版用到它，过早放进 KMP 会多一轮 Kotlin/Swift 桥接。
- `cron` 表达式不做，五种 schedule 就能覆盖绝大多数场景，也便于 UI 呈现。

### 2. 存储 `DesktopScheduleStore`

- 路径为 `~/Library/Application Support/AmberAgent/Schedules/`，每个任务一个 JSON 文件，采用原子写入，写法照搬 `DesktopAgentJournal`。
- 读取失败的文件保留原样，并在 UI 中提示，与任务记录的处理方式一致。

### 3. 调度器 `DesktopScheduler`（`@MainActor @Observable`）

- 只维护一个计时器，指向所有任务中最早的 `nextRunAt`，不给每个任务各开一个。
- 以下时机会重新计算：启动、`NSWorkspace.didWakeNotification`、`NSSystemClockDidChange`、时区变化、任务增删改。
- 补跑规则：醒来后如果发现错过了运行时间，按 `missedRun` 处理。多次错过只补跑一次，绝不连环补跑。
- 并发：同一个任务同时只跑一个实例，上一次还没结束时本次跳过并记录；全局最多同时跑 2 个定时任务。
- 防睡眠：运行期间持有 `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`，结束后释放。不做定时唤醒（需要 root 执行 `pmset`），Mac 睡着时任务不会运行，醒来后补跑。这个限制要在 UI 里写明。
- 时间计算用 `Calendar.nextDate(after:matching:)`，正确处理夏令时和时区。

### 4. 无界面执行入口

在 `DesktopWorkspace` 中新增：

```swift
func runScheduled(_ task: DesktopScheduledTask) async -> DesktopScheduleRunRecord
```

- 它直接创建或定位目标会话，追加 user message，再调用 `startGeneration`，全程不碰 `selectedID`、`draft` 等 UI 状态。会话标题记为「⏱ 任务名 · 日期」。
- `DesktopRunContext` 新增 `approvalPolicy: DesktopApprovalPolicy?`：对话场景传 nil，沿用全局开关；定时任务场景传入任务自己的策略。`DesktopAgentExecutor` 有 policy 时优先用 policy，`allowedTools` 白名单外的工具直接返回 `.denied`。
- 等待批准时，复用现有的 `requestApproval` 和 journal 持久化，再加一个超时检查。超时后把任务标为 failed 并发通知。
- 结束时更新 `lastRun`（状态、会话 ID、耗时、错误）和 `nextRunAt`。

### 5. 常驻与自启

- 新增 `MenuBarExtra` 菜单栏图标，菜单内容包括：正在运行的任务、下一个任务及其时间、「打开 Amber」「暂停所有定时任务」「退出」。
- 设置项「关闭窗口后继续在菜单栏运行」，有启用中的定时任务时默认打开。关闭最后一个窗口时 App 不退出，同时切成 `.accessory` 策略隐藏 Dock 图标，重新打开窗口时再切回 `.regular`。这里需要实测 SwiftUI `Window` 场景关闭最后一个窗口时的默认行为。
- 设置项「登录时启动」，通过 `SMAppService.mainApp.register()` 实现。
- 退出时，如果有定时任务正在运行，沿用现有 `applicationShouldTerminate` 的收尾流程，先 cancel 再 flush。被中断的运行记为 failed，附上原因「应用退出」。

### 6. 通知

- `DesktopNotificationOutcome` 新增 `.needsApproval`。
- 注册一个 `UNNotificationCategory`，内含「批准」「拒绝」「查看」三个操作。等待批准的通知正文写明工具名和参数摘要（截断到 120 字），点「批准」或「拒绝」直接调用 `agentTasks.decide(runID:allow:)`。
- 高风险工具的通知不显示「批准」按钮，只给「查看」，必须进入 App 核对后才能批准。
- 已完成和失败的通知标题带上任务名，比如「⏱ 每日汇总 已完成」。

### 7. UI

- 侧栏新增「定时任务」页面，列表每行显示任务名、下次运行时间、上次结果和开关。
- 编辑表单的字段：名称、提示词、时间规则、模型、工具和子代理开关、无人值守审批（含白名单）、错过运行时怎么处理、结果写到哪里。
- 每个任务都有「立即运行一次」按钮，方便调试，运行历史链接到对应会话。

### 8. 从对话创建任务（1b，可后置）

- 新增工具 `schedule_create` / `schedule_list` / `schedule_update`。其中 create 和 update 永远需要用户批准，不受任何自动批准开关影响；审批卡片上完整显示任务定义。
- 用户在对话中说「每天早上 9 点帮我……」，模型就生成任务草案，批准后启用。

## 实施顺序

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| S1 | 模型、存储、下次时间计算 | 单测：五种规则、夏令时切换日、时区变化、补跑只补一次 |
| S2 | `runScheduled` 和 `DesktopRunContext.approvalPolicy` | 单测：定时运行不读全局开关、白名单外拒绝、审批超时转为失败；fake provider 端到端测试 |
| S3 | 调度器（计时器、唤醒、时钟变化、并发上限、防睡眠） | 单测用可注入时钟；手动测试合盖再开盖后补跑 |
| S4 | 菜单栏常驻、关窗继续运行、登录自启 | 实测：关窗后到点运行；重启后自启 |
| S5 | 通知分类与操作按钮 | 实测：在通知上批准普通工具后任务继续；高风险工具没有批准按钮 |
| S6 | 定时任务页面 | 浅色和深色截图走查 |
| S7（可选） | `schedule_*` 工具 | 单测：create 永远需要批准 |

每个阶段结束都跑一遍 Mac 全量测试。S4、S5 必须在真机实测，单测不能替代。

## 不在本步范围

- Gateway 推送到手机、手机端批准（第 2、3 步）。
- iOS 远程创建和管理定时任务，以及模型迁入 KMP（第 4 步）。
- 由记忆驱动的任务建议（第 4 步）。
- 睡眠中定时唤醒 Mac。

## 风险

- 无人值守时开启了高风险自动批准，任务就可能在没人看着的情况下执行 shell。对策：默认关闭；打开时二次确认；任务列表上显示红色标记；运行记录里列出所有自动批准过的调用。
- 和自动批准开发的冲突：线程 f323bb93 刚加了全局 `autoApprove`。S2 会改 `DesktopAgentExecutor` 的审批分支，要等那边提交之后再动。
