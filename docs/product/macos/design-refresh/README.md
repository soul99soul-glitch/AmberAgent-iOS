# macOS 设计整理

本页记录此前设计批次。当前 Preview 与 ZIP 已由后续[全面复核与修复](../comprehensive-review/review.md)更新，最新源码、签名和启动验收边界以该目录为准；下方截图与 delivery.json 保留为本设计批次的历史证据。

2026-10-23。本轮把已有功能整理成安静、清晰的原生 Mac 工作台：近白/墨灰为底，少量琥珀色强调品牌和主要动作，阅读内容优先。基于已有 SwiftUI 页面实现，没有引入新的 UI 框架。

## 计划与完成情况

| 阶段 | 结果 | 复核 |
| --- | --- | --- |
| 1. 采集现状、确定视觉方向 | 保存本轮实窗与同源原生组件 before；确认泥灰底、侧栏信息过密、重复模型和操作抢占层级 | 独立 subagent 检查普通聊天、阅读、审批与队列的基线 |
| 2. 落实统一设计 | 主窗口、正文、输入器、设置及七个支持面板完成；浅深色共享颜色与间距规则 | shell/panels 独立源码 review；核对消息、权限、owner、取消与未保存守卫 |
| 3. 视觉与交互验收 | 完成构建、24 个原生组件场景、真实 App 操作；修复发现的问题后重新渲染、打包 | 独立最终 review 无剩余阻断发现，见 [QA.md](QA.md) |

## 具体取舍

| 部位 | 最终设计 |
| --- | --- |
| 侧栏 | 理想宽度 248pt；18pt 品牌字；标题独占首行，摘要与日期置于次行；消息数留在提示与辅助信息中；使用单层系统选中态 |
| 阅读区 | 最大行宽 760pt；用户消息轻底色区分；角色标签和消息操作降次；代码、引用、表格使用细边界 |
| 输入器 | 一行起步、最多八行；12pt 内边距与圆角；模型只在工具栏出现；工具开关保留明确状态；浅深色与禁用发送箭头分别验证 |
| 欢迎页 | 一句主标题、一句说明、三个可编辑的起步建议；点击只预填和聚焦，不自动发送 |
| 设置与面板 | 20pt 主标题、13pt 说明、24pt 外边距；分类使用原生分段控件；减少嵌套灰盒；关键操作与辅助操作分清层级 |

## 视觉证据

同状态组件对比：[聊天 before](before/workspace-chat-1280-light.png) / [after](after/workspace-chat-1280-light.png)，[窄窗审批 before](before/workspace-queue-860-dark.png) / [after](after/workspace-queue-860-dark.png)。这些由真实生产 SwiftUI 源码通过 NSHostingView 渲染；真实窗口工具栏和交互以以下实窗截图为准。

- [最终聊天实窗](after/01-current-window.png)
- [浅色欢迎页与草稿](after/02-welcome-draft.png)
- [服务商设置](after/03-settings-providers.png)
- [深色欢迎页与发送状态](after/04-welcome-dark-send.png)
- [SOUL 编辑面板](after/05-knowledge-soul.png)
- [通用设置](after/06-settings-general.png)

真实 App 已检查：模型菜单的完整名称、知识三个分类切换、建议预填且 Return 换行、设置未保存时取消保留编辑/放弃后进入目标分类、主题切换、选中底与发送箭头。测试草稿已清空，最终预览停留在主聊天页。

## 构建与交付

`macApp/scripts/build-preview-swiftpm.sh --iosmath-path iosApp/build/ExperimentalDeviceBuild/SourcePackages/checkouts/iosMath` 构建成功；76 项组件源码清单及 Preview App 入口与打包构建副本逐字节一致。ZIP 解压后严格签名验证通过。校验数据见 [delivery.json](delivery.json)。

可打开应用：`macApp/build/swiftpm-preview/AmberPreview.app`；打包：`macApp/build/AmberPreview.zip`。

本轮未修改 Runtime/KMP，不重复用旧测试计数代表本次 UI 验收。交付仍为明确标注、未连接真实模型的 Preview；正式 Shared.framework/Native 集成阻塞与产品差距继续以父目录记录为准。本轮设计验收不代表完整产品已完成。
