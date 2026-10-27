# 原生离屏布局证据

2026-10-23。以生产 Runtime/UI 源码快照编译，通过 NSHostingView / NSWindow 原生 bitmap 绘制；窗口不处于 key 状态。会话使用既有界面 fixture 和内存 storage，知识导入与备份恢复实际执行于临时目录；没有连接模型服务或 Shared。

这些是离屏组件验证，**不是锁屏后的最终 App 交互复拍**。源码 SHA-256 见 `offscreen-source-manifest.tsv`。

| 文件 | 实际场景与尺寸 |
| --- | --- |
| offscreen-workspace-860x600-light.png | 完整 860×600pt 工作区；审批、三条排队摘要、输入区与停止按钮 |
| offscreen-workspace-860x600-dark.png | 同尺寸深色工作区，检查非 key 状态停止图标对比 |
| offscreen-reading-1280x1000-dark.png | 1280×1000pt；中文表格自然行高、长代码横向滚动、真实 iosMath |
| offscreen-backup-620x440-light.png | 620×440pt 原生面板置于 860×560pt 画布；真实恢复后的长状态 |
| offscreen-recipes-820x670-light.png | 820×670pt 原生面板置于 860×750pt 画布；已导入 Recipe、长名称与输入 |
| offscreen-collaboration-820x700-dark.png | 820×700pt 原生面板置于 860×780pt 画布；三个成员与模型选择 |

本轮发现并修复工作区竖向裁切与非 key 浅色停止图标对比问题。弹出详情的交互、窗口 toolbar、Knowledge / Settings 的 Tab 选择器及真实 provider 仍须最终 App 交互验证；离屏图不替代该项证据。透明画布失败图和修复前截图未保存。
