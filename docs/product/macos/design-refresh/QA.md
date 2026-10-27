# macOS 视觉整改独立复核

日期：2026-10-23。复核者：独立 `design_verification` subagent。

本轮复核覆盖真实 SwiftUI 源码、同尺寸原生组件截图，以及主 agent 另外提供的实际 App 截图。已定位并修复 sidebar 双层选中背景、浅色禁用发送箭头不可见、深色发送箭头与浅金按钮的对比、已选服务商图标的对比问题。复核范围内未发现本轮变更新增的阻断问题。

## 源码与调用链

`before/source-manifest.tsv` 与 `after/source-manifest.tsv` 分别记录 76 个参与离屏构建的真实源码文件及 SHA-256。两次快照间 14 个文件有变化，均位于 UI 或 PreviewSettings；Runtime 文件未变。最终 after manifest 已逐项与生产源码比对。

- Conversation List 的 selection/tag、键盘选择入口与上下文菜单保留；自绘内层选中卡片已去除，保留原生选择状态。
- 欢迎建议只写入草稿并请求输入框聚焦，没有发送请求。
- Composer 保留原生 TextField 与输入法 marked-text 判断、附件/拖放、⌘Return、队列、Stop、跨会话 generation owner 归属。
- `sendDisabled` 与提取前的表达式逐字段等价：五项工作状态，以及「trim 后草稿为空且无附件」条件，运算符和括号未变。
- Transcript 的自动跟随、手动滚动、来源消息定位、编辑/重生成/删除 owner 守卫、版本切换、复制与朗读入口保留；动作未通过透明度隐藏。
- Settings 新分类 Picker 仍通过 `request(.tab)`，保存并继续/放弃/取消仍进入原确认流程；四个内容分支沿用原参数。Knowledge 的 SOUL 草稿仍由父 State 持有，关闭未保存守卫与加载失败禁用状态保留。
- 审批、Recipe、协作、备份、文件库与存储视图的权限、取消、保存和会话归属调用未改变。

## 原生组件证据

离屏构建使用生产 UI/Runtime 的真实源文件和既有真实 iosMath checkout；未创建 Shared 替身、未改写服务实现、未用 mock 页面代替界面。截图来自 NSHostingView 的原生 bitmap，像素尺寸与下列 pt 视口一致。

| 场景 | 视口与外观 | 已检查内容 |
|---|---|---|
| 普通聊天、欢迎页 | 1280×800 浅色；860×600 深色 | 字号层级、阅读宽度、两栏比例、留白、建议按钮、Composer 对齐 |
| 发送草稿 | 860×600 浅色/深色 | 文字与按钮边距；禁用/可用状态仍由真实谓词控制 |
| 审批 + 三条队列 | 860×600 浅色/深色；1280×800 深色 | 审批理由、长参数、完整内容入口、拒绝/允许、队列计数、Stop 可见性 |
| 长阅读 | 1280×1000 深色；860×800 浅色 | 长中文、嵌套列表、引用、表格行高、长代码横向滚动、真实数学公式 |
| Knowledge | 860×720；技能/SOUL 浅色，记忆深色 | 长说明换行、分类控件、编辑/删除与元数据对齐 |
| Settings | 860×760；服务商/MCP 浅色，同步深色 | 长模型名、表单分组、分类控件、字段与页脚边距 |
| 任务、Recipe、协作 | 860×720 / 750 / 780 | 长标题、审批参数、开关与操作按钮、配置分组与滚动范围 |
| 备份与恢复 | 860×560 浅色；1280×680 深色 | 恢复后的长状态说明、密码与操作按钮，不裁切结果 |
| 图片表单、存储用量 | 860×720 浅色；860×640 深色 | 表单、行列与页脚布局 |

最终 after 含 24 张有效离屏组件图。Knowledge 的 SOUL/Memory 与 Settings 的 MCP/Sync 通过真实 NSSegmentedControl 的 action 进入相应 SwiftUI Binding，日志确认 selected segment 分别为 1/2 与 2/3；这是程序化组件状态证据，不等同于用户交互验证。

原 before 的 `knowledge-memory-dark.png` 和 `settings-general-dark.png` 未能通过旧 NSTabView 切页，实际仍是默认页，保留为原始记录，不作为 Memory/General 的同状态对比。其余 18 组离屏场景可直接按同名、同视口、同 fixture 状态比较。

## 对比与可读性

主阅读最大宽度由 860 缩至 760；sidebar 理想宽度由 260 缩至 248，品牌字由 23 缩至 18。Composer 最少行数由两行降至一行，移除重复模型说明后，在 860 宽度的审批与队列场景中仍保留完整操作入口。消息动作与次要操作降为中性色，琥珀色集中于品牌、关键动作与确认区域。

按声明的平面颜色合成计算，muted 小字与浅色 canvas/sidebar 的对比分别约 4.90:1 / 4.83:1，与深色 canvas/raised 约 6.13:1 / 5.52:1。发送按钮的声明色在浅色约 5.00:1，深色墨色箭头与浅金底约 8.64:1；原生控件活动状态仍以实际 App 截图为准。

## 证据边界

- 离屏窗口处于 inactive 状态，原生 prominent button 会采用非活动绘制，不能据此判断实际活动窗口的按钮底色。实际 App 的发送、禁用发送、主题切换由主 agent 另行检查。
- 离屏不包含真实窗口 toolbar，也不证明 hover、键盘导航、弹出菜单或权限交互。实际窗口的模型菜单、Knowledge 三个分支、Settings 未保存取消/放弃流程由主 agent 用 CUA 检查。
- General 页面会读取 UNUserNotificationCenter 的授权状态，裸命令行离屏进程缺少正常注册的 App bundle，因此跳过离屏捕获，未替换通知实现。General 的主题与未保存守卫以实际 App 验证为准。
- 本轮未改 Runtime，不将 Preview/离屏编译当作正式 Shared.framework 的构建或真实 provider 调用证明。

## 验证结果

真实源码离屏 SwiftPM 构建通过；24 个有效组件场景渲染完成，exit 0。最后 Workspace 日期排版与 Composer 颜色修复另做源码等价复核、重建（11.40 秒，exit 0）与全部 11 个 workspace 场景复渲染（exit 0）。最终 76 项 manifest 同时与生产源码、实际参与渲染的源码副本逐项一致，无差异。实际 App 构建与交互证据由主 agent 维护。
