# macOS Phase 5：UI / 交互一致性与可访问性验收记录

> 更新日期：2026-10-31
> 范围：计划 §5 `M5.1`–`M5.4`（改动页面浅/深色矩阵、长文本与长会话、控件焦点与 Reduce Motion、Liquid Glass 顶部胶囊与 Inspector 固定锚点）

## 1. 改动页面浅色 / 深色截图与逐张检查结论（M5.1 / M5.2）

| 页面 / 组件 | 浅色截图 | 深色截图 | UI 检查结论（错位 / 间距 / 字号 / 截断 / 对比度） |
| --- | --- | --- | --- |
| 服务商设置（含 Claude `promptCaching` 开关） | [`settings-claude-caching-light.png`](screenshots/settings-claude-caching-light.png) | [`settings-claude-caching-dark.png`](screenshots/settings-claude-caching-dark.png) | 表单分组对齐、标签与开关基线一致、无文字重叠或异常截断 |
| 定时任务与无人值守审批 | [`scheduled-tasks-approval-light.png`](screenshots/scheduled-tasks-approval-light.png) | [`scheduled-tasks-approval-dark.png`](screenshots/scheduled-tasks-approval-dark.png) | 左侧列表卡片与右侧编辑器双栏对齐，等宽工具白名单框换行正常 |
| 飞书日历工作台视图 | [`plugin-feishu-workspace-light.png`](screenshots/plugin-feishu-workspace-light.png) | [`plugin-feishu-workspace-dark.png`](screenshots/plugin-feishu-workspace-dark.png) | 修复顶部副标题在 1080pt 宽度下被压缩截断的问题（增加 `.layoutPriority(1)` 与 `.lineLimit(2)`），复拍后完整展示 |
| 工具调用卡片（Apple 日程摘要徽章） | [`tool-call-card-schedule-light.png`](screenshots/tool-call-card-schedule-light.png) | [`tool-call-card-schedule-dark.png`](screenshots/tool-call-card-schedule-dark.png) | 26pt 折叠头与展开详情对齐，`共读取 2 项本机日历日程` 徽章在浅/深色下对比度良好 |
| 插件设置与能力矩阵（Arquiel Design 2.0） | [`../phase3/plugin-capabilities/plugin-capabilities-light.png`](../phase3/plugin-capabilities/plugin-capabilities-light.png) / [`../phase3/plugin-capabilities/plugin-apple-schedule-light.png`](../phase3/plugin-capabilities/plugin-apple-schedule-light.png) | [`../phase3/plugin-capabilities/plugin-capabilities-dark.png`](../phase3/plugin-capabilities/plugin-capabilities-dark.png) / [`../phase3/plugin-capabilities/plugin-apple-schedule-dark.png`](../phase3/plugin-capabilities/plugin-apple-schedule-dark.png) | 五段式信息架构（状态→连接→通用→高级→权限与技术详情），域名流式换行，能力摘要与实际接线一致 |
| 上下文面板与右侧 Inspector 浮岛 | [`../phase1/context-panel-evidence/workspace-inspector-trimmed-light.png`](../phase1/context-panel-evidence/workspace-inspector-trimmed-light.png) | [`../phase1/context-panel-evidence/workspace-inspector-trimmed-dark.png`](../phase1/context-panel-evidence/workspace-inspector-trimmed-dark.png) | 缓存命中率、预算裁剪提示条与 16pt 浮岛圆角在浅/深色下无遮挡 |

## 2. 控件命中区、键盘导航与 Reduce Motion（M5.3）

- **按钮命中区与可访问性标签**：
  - 工具栏图标按钮、服务商增删按钮（`26×26pt`）、工具调用胶囊头（`height: 26pt`）、插件工作台返回按钮（`height: 28pt`）均配置了明确的 `.accessibilityLabel` 与 `.help` 提示。
- **键盘快捷键（Esc / Return / ⌘Return）**：
  - 插件工作台「返回对话」按钮支持 `Esc` 键直接切回对话视图（`DesktopPluginWorkspaceView.swift`）。
  - 发送快捷键支持 `⌘Return`、`Return`、`⇧Return` 三档切换并在底部状态栏实时提示。
- **Reduce Motion 降级**：
  - `DesktopLiquidMotion.toolbarCapsuleTransform` 在 `reduceMotion == true` 时关闭 overshoot、垂直挤压/膨胀、收腰形变与高光闪烁（由 `DesktopConversationPresentationTests.testLiquidMotionTransformAndReduceMotionBranches` 锁定）。
  - `DesktopToolCallCard.HeaderButton` 接入 `@Environment(\.accessibilityReduceMotion)`，开启减弱动态效果时直接切换展开态。

## 3. Liquid Glass 顶部胶囊与 Inspector 固定锚点（M5.4）

- **固定点击锚点（ΔX = 0）**：
  - `DesktopConversationLayoutTests.testRightInspectorToolbarToggleRemainsStationaryAcrossExpandAndCollapse` 验证右侧 Inspector 展开（胶囊 `80pt`）、收起（胶囊 `260pt`）及 90ms 动画中途折返连点时，`sidebar.right` 按钮中心点保持 `ΔX = 0`（精度 `1.0pt` 内）。
- **长会话视口虚拟化**：
  - `DesktopConversationLayoutTests.testTranscriptContentWidthClampsSidebarToggleAndRowHeightsPreserveOffWindowFallback` 验证侧栏切换时正文列宽保持 `680pt` 恒定，不触发全量行高缓存失效。
