# 任务看板与主动性第 2 轮 实施计划

日期：2026-10-27 · 分支：`feat/macos` · 前置：定时任务 S1–S6、Mac Gateway 并入（d027e6c…59d6e28）

## 为什么做

用户反馈：任务挂在「设置 › Mac Gateway」里，标题是一排「mi」，开关没有意义，整体不像一个助理在干活。对照 OpenAI Dots、Meta Muse、Grok Bot，差的是五件事：任务有独立的面板；标题和进展由助理自己写；除了按时间，还能按事件触发；只在有新情况或需要批准时才打扰；运行结果有一句话的摘要。

## 目标

1. **任务看板成为一等入口**
   - Mac：侧栏「新建会话」下面加「任务」行，在主窗口打开看板。
   - iPhone：首页快捷入口里「任务」取代「小说创作」（站点保留），「待继续」卡片显示等你处理的任务。
   - 「设置 › Mac Gateway」只留配对、推送、设备三项。
2. **看板分四组**：等你处理 / 进行中 / 已排定 / 已完成。定时任务、它的每次运行、Claude Code / Codex 会话都在里面。等你批准的卡片直接带批准和拒绝按钮。
3. **标题和摘要由 Amber 写**
   - Claude / Codex 会话：用第一句话的开头（只存在 Mac 上，最多 400 字）生成 10 来个字的标题。
   - 定时任务：每次运行结束后，生成一句结果摘要，显示在卡片上。
4. **事件触发**：定时任务新增两种触发方式，「文件夹里有新文件」和「某个 Claude / Codex 会话结束或等你处理」。
5. **通知收敛**：定时任务跑完、摘要判断「没有新东西」时不推送，只记在卡片上；有发现、失败或需要批准时才推送。

## 现状（已确认）

- **网关已有的数据**：
  - 每个会话的 `summary`（第一句话的前 40 字）、`opening`（前 400 字，只留在 Mac 本地）。
  - `retitle` 事件，可以给会话写入 `generatedTitle`。
  - `/v1/status` 中的 `summary` 字段：优先返回 `generatedTitle`，没有时返回第一句话。
- **Amber**：`DesktopScheduler`（tasks、running、recentRuns）、`DesktopTitleGeneration`（调用辅助任务「生成会话标题」所配的模型）、`runScheduled` 返回的 `DesktopScheduleRunRecord`。
- **iOS**：
  - 首页 `ConversationsView.shortcutButtons` 有五个入口。
  - `HomeContinueCardModel` 按优先级选出一张「待继续」卡片。
  - 任务列表在 `MacGatewaySettingsView` 里。
- **Mac**：主窗口是 `DesktopWorkspaceView`，侧栏包括新建会话、搜索、会话列表；定时任务页是一个 sheet。

## 设计

### 1. 看板数据（Mac 汇总，手机只负责显示）

看板的每一行由 Mac 端统一算好，避免 Mac 和手机各写一套分组逻辑：

```
BoardItem { id, kind: schedule|run|agentSession, column: needsYou|running|scheduled|done,
            title, detail, updatedAt, scheduleId?, sessionKey?, pendingApproval?, nextRunAt?, highRisk }
```

**来源和分组**：
- 定时任务：已启用且没在运行的放进「已排定」。
- 定时任务的最近运行：运行中的放进「进行中」，等待批准的放进「等你处理」，已结束的放进「已完成」（只取最近 7 天，每个任务最多 3 条）。
- Claude / Codex 会话：数据取自网关的 `registry.json`，Amber 与网关同机，直接读本地文件。等你处理的放进「等你处理」，运行中的放进「进行中」，已结束的放进「已完成」。

**送到各端**：
- Mac 看板直接用这份数据。
- 网关新增 `GET /v1/amber/board`，转发给 Amber 的 socket；手机看板调用这个接口。
- Amber 没在运行时，手机退回到现在的 `/v1/status` 会话列表加定时任务列表（只读）。

### 2. 标题与摘要（`DesktopBoardWriter`）

- **会话标题**：
  - 新会话出现、没有 `generatedTitle`、且有 `opening` 时，排队生成标题。
  - 用的是辅助任务「生成会话标题」的模型，同一时间只跑一个。
  - 结果通过 `retitle` 事件写回网关，手机和 Mac 都能看到。
  - 生成失败就继续用第一句话。
- **运行摘要**：
  - 运行结束后，把这次回复的最后一条交给模型。
  - 让模型输出一行 JSON：`{"summary": "...", "noteworthy": true|false}`。
  - 摘要存进 `DesktopScheduleRunRecord.summary`。
  - `noteworthy` 决定要不要推送「已完成」，规则见 §4。
- **范围**：只有在设置里配置了模型才生成。没配置时只用第一句话，不推测、不重试。

### 3. 事件触发

`DesktopScheduledTask` 新增 `trigger`，两种触发方式与 `schedule` 平级：

**`folder(path)`**：
- 用 `DispatchSource` 监听目录。
- 有新文件时去抖 30 秒再运行，并把新文件名列表附在提示词后面。
- 两次触发之间至少隔 15 分钟，和间隔规则的下限一致。
- 文件夹由用户在 Mac 上用访达选择，手机端不能选。

**`agentSession(.ended | .needsYou)`**：
- 订阅网关 registry 的变化，用文件监听，不轮询。
- 某个会话进入相应状态时运行，提示词里附上会话标题和来源。
- 同一个会话只触发一次。

**约束**：
- 事件触发的任务和定时触发的任务一样，受同任务不并发、全局并发上限 2、审批策略的约束。
- 手机端新建任务仍只支持时间规则。

### 4. 通知收敛

在 `scheduler.onRunFinished` 里决定：
- **推送**：失败、`noteworthy == true`、或者还没生成摘要（没配置模型）。
- **不推送**：完成且 `noteworthy == false`。卡片照常更新。
- 网关这边，Amber 会话的「已完成」推送也按同样规则走：`runExit` 附带 `quiet: true` 时不推送。

### 5. 入口与界面

**Mac**：
- 侧栏「新建会话」下面加「任务」行，有待处理事项时显示角标数字。
- 点击后主区域显示 `DesktopBoardView`，按四列并排；窗口窄时改成纵向分组。
- 「工作台 › 定时任务」和菜单栏的「定时任务…」都改为打开看板。
- 新建和编辑定时任务沿用现有表单，作为 sheet 弹出。

**iPhone**：
- 首页快捷入口：`HomeShortcut(entry: .tasks)` 取代 `.novel`，有待处理事项时显示红点数字。
- 「待继续」卡片：新增 `macTask` 候选，优先级为 `actionRequired`。
- 看板页 `MacTasksBoardView` 按四组纵向排列，复用现有的行组件和审批行。
- 「设置 › Mac Gateway」去掉任务和定时任务两个分组，加一行「打开任务看板」。
- 没有配对 Mac 时，看板页引导用户去配对。

## 实施顺序

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| B1 | 看板数据模型、分组逻辑、`/v1/amber/board` | 单测覆盖分组、排序、7 天与每任务 3 条的截断，网关转发集成测试 |
| B2 | Mac 看板页、侧栏入口、角标、旧入口改指 | 浅色和深色截图，窄窗口和宽窗口 |
| B3 | iPhone 看板页、首页入口替换、待继续卡片、Gateway 设置页瘦身 | iOS 单测；模拟器截图；配对状态下实测批准一次 |
| B4 | 标题与运行摘要（`DesktopBoardWriter`） | 单测用假 provider 测排队、失败回退、JSON 解析；端到端测试：会话出现后标题写回网关 |
| B5 | 事件触发（文件夹、Agent 会话） | 单测覆盖去抖、最小间隔、同会话只触发一次、受并发上限约束；实测往文件夹放文件后触发运行 |
| B6 | 通知收敛 | 单测：noteworthy 为 false 时不推，失败照推；网关测试覆盖 quiet 的 runExit |

每个阶段：全量测试（Mac + gateway，涉及 iOS 时加 iOS 的相关测试）→ subagent review（逻辑闭环、调用链、界面细节）→ 精准修复 → 单独提交。

## 不在本轮

- 小说创作功能本身的清理：本轮只移走首页入口，代码留给用户后续单独清理。
- 接入邮件和日历、多步「目标」、真机推送凭据（用户已导入 APNs，属于运维项）。
- Android / 鸿蒙。
