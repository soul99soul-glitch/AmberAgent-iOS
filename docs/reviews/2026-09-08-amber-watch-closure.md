# Amber Watch：设置页重排与链路收口

本轮由用户的真机截图触发。第一版只统一卡片外框，仍有五段独立排版、说明分散、文字起点与图标使用不一致的问题；用户再次拒绝该版。旧截图及此前“未发现裁剪”的结论不代表设计验收通过。

## 当前设计

- 沿用设置主页的页头、分组容器、图标底板和字号；设置首页 Apple Watch 入口不显示额外副标题。
- Watch 设置收为设备与助手、快捷动作、记事与提醒三组。统一 16 pt 页面边距、14 pt 行内边距、28 pt 图标列及 12 pt 列间距；分隔线从文字列起始。
- 连接状态和助手配置用短状态表达。快捷动作名称打开编辑，右侧只保留选择开关；编辑器承载全文与删除。记事默认收起，可以展开和查看全文；提醒保留实际系统授权反馈。
- `WatchSettingsVisualEvidenceTests` 渲染生产视图与隔离数据，保存浅色、深色、320 pt 窄屏、辅助功能字号、长动作和展开记事截图。截图必须人工检查，测试成功本身不等于视觉质量通过。

## 复查登记

| 项目 | 状态 | 证据与处理 |
| --- | --- | --- |
| 设置入口多余副标题、详情页宽度与排版混杂 | 已修复 | 第二版三组统一行结构；独立审图确认图标列、文字列、右侧控件、分隔线、明暗主题与设置主页一致 |
| Watch 设置/操作按钮文字与胶囊中心不一致 | 已修复 | 统一全宽居中 label；40/46 mm 截图验证 |
| 最近结果与近期动态缺少未读辅助功能值 | 已修复 | 挂接 accessibilityValue；未宣称真机 VoiceOver 播报已测 |
| 异步旧 library 覆盖较新选择 | 已修复 | refresh revision 拒绝过期构建；可控 continuation 测试先失败后通过 |
| 旧设置缺少未消费字段导致整份缓存解码失败 | 已修复 | 删除未使用字段；旧缓存保留记事、偏好、已读标记的回归先失败后通过 |
| 保存失败后同 run 恢复成功，历史仍显示失败 | 已修复 | 只允许 failed → 明确 completed；终态防回退测试先失败后通过 |
| 工具结果未知被误显示为失败 | 已修复 | 使用非审批 phone-only gate；核实仅移除对应 gate，不制造 completed/failed；清除旧版同 run 的错误失败历史 |
| 同 run 多个 unknown，首次核实后冷启动丢剩余 gate | 已修复 | 保留有剩余 unknown 的 durable run 为 outcomeUnknown，最后一项核实后才变为 interrupted；真实 Room、实际 recoverable run 查询、新 VM/W3、重复核实和最后一项核实均通过 |
| recoveryPending 的工具 ledger 仍有 unknown，旧取消请求绕过核实 | 已修复 | 执行边界同时检查 run 和精确 runId 的 tool ledger；查询错误拒绝取消。真实 Room 冷取消用例确认不修改 run/ledger，恢复 phone-only gate |

## 验证记录

- 基线定向 51 项通过。
- 三项新增回归先产生 14 个失败断言，再随对应修复通过。
- 第一版设置页与逻辑修复：68 项通过；随后视觉夹具单项重跑通过。第一版设计已被用户否决，不能作为第二版截图证据。
- 第二版最终定向集：119 项通过，0 失败。日志 `test_sim_2026-09-08T12-17-27-494Z_pid63831_759d3580.log`，结果包 `test_sim_2026-09-08T12-17-27-494Z_pid63831_00b102f3.xcresult`，位于本机 XcodeBuildMCP 的 ios-396633e5a58a 工作区。
- 集成时修复了 await 位于布尔 autoclosure、缺 return、错误引用不存在 idle enum 的编译问题，以及 phone-only 类型修改后遗漏更新的断言；119 项通过记录包含这些修正。
- 实际查看常规明暗、长动作、展开记事、320 pt 与辅助功能字号截图。辅助功能字号将尾部控件下移，避免挤窄文字；独立 reviewer 确认控件完整、列对齐、子列表缩进明确。常规子列表是预览，点入详情查看全文，不把展开列表等同于展开每条全文。
- 已有动作时移除重复尾注，助手名称提升为主标题，连接副标题明确显示暂不可达。两个设计 reviewer 的意见由主线程结合页面层级取舍，没有自动采纳全部建议。
- 补拍辅助功能字号中段与展开记事，实际滚动高度连续取 5 帧，确认长动作、选择开关、子项预览、删除按钮与底部提醒均可到达，没有重叠。截图 `phone-watch-accessibility-expanded*.png` 从 xcresult 的保留附件导出；不是拼接图，也不是生产滚动修补。
- 最终 UI/投影/冷启动 46 项通过：`test_sim_2026-09-08T12-32-52-134Z_pid63831_f5a13819.log`；结果包 `test_sim_2026-09-08T12-32-52-135Z_pid63831_620e4f34.xcresult`。
- 最后真实数据库恢复 30 项通过（含新两项）：`test_sim_2026-09-08T12-35-11-336Z_pid63831_fd5750c0.log`；结果包 `test_sim_2026-09-08T12-35-11-336Z_pid63831_5ec97705.xcresult`。这些轮次存在重叠，没有相加冒充独立用例数量。

## 边界

- 真机可以直接通过 devicectl 抓图，无需 iPhone 镜像。已验证捕获能力；只有在新版本目标页面打开后才能称为真机页面验收。
- 第二版已覆盖安装到 iPhone（app.amber.ios）及 Apple Watch（app.amber.ios.watchkitapp）；两包签名验证通过。iPhone 启动请求因锁屏被系统拒绝，已请用户自行打开目标页。最后两处逻辑修正的 iPhone 包也已构建并通过签名验证，最终覆盖结果见下方。
- Watch 收到过成功启动回执；直接抓图得到的是表盘，未作为应用 UI 证据。紧随启动的再次抓图尝试遇到启动超时，没有冒称真机界面已核对，也没有把非目标页面截图复制进仓库。
- 保留 iSH 实验构建与 audio/processing 后台模式。不能把后台模式声明等同于系统保证持续运行。
- 未覆盖无关 MiniApp 改动，未新增依赖、提交或推送。

## 最终结论

最终 iPhone 包已再次覆盖安装成功，安装回执 `/private/tmp/amber-watch-closure-phone-final-install.json`（databaseSequenceNumber 2816）。最终包确认 `UIBackgroundModes = [audio, processing]`，包含 iSH `fs` 资源；未重写用户已有音频开关偏好。构建日志 `/private/tmp/amber-watch-closure-phone-final-build.log` 与 `/private/tmp/amber-watch-closure-watch-build.log` 均为成功。

代码、定向回归和模拟器视觉：PASS。真机目标页面与系统交互：PARTIAL，仍需解锁并打开对应页面核验；已确认的覆盖安装不等于端到端使用验收。

主要修改：`IOSWatchSettingsView.swift`、`WatchTaskRootView.swift`、`WatchTaskCoordinator.swift`、`WatchTaskSnapshotBuilder.swift`、`IOSWatchCompanionService.swift`、`WatchLocalStore.swift`、`IOSRunRecovery.swift`、前后台及 W3 的 Watch 发布入口、六语言资源与对应测试。设置页复用既有表单容器，删除独立拼卡与重复说明；没有另建主题或导航系统。
