# Amber Watch 首页与记录列表布局补验

2026-09-08。用户反馈最近记录、设置与连接和快捷动作不居中，以及最近对话列表严重错位。本次限定修复这些布局及对应 DEBUG 样例。

## 上轮遗漏

上一轮截图主要覆盖任务和输入页，没有包含首页底部与多条长标题的最近列表。仅有一条短对话的夹具没有暴露默认胶囊按钮容纳多行内容时的圆角溢出、文本对齐与空预览占位问题。上轮的 UI 检查不能作为这些页面已验收的依据。

## 修复

- 首页胶囊按钮有两层偏移：图标文字明确左对齐，且按钮外框在左对齐容器中偏左。统一标签组居中，并在按钮外部提供满宽居中布局。覆盖提问、记事、快捷动作、草稿、最近记录和设置入口。
- 最近对话和记事复用现有圆角卡片，使用原生 plain Button，去掉不适合多行记录的默认胶囊。标题、预览、时间和同步状态左对齐，按内容自然增高；标题与预览最多两行，正文可在详情查看。
- 空白预览不生成 Text，占位消失；预览和时间使用次要文字颜色，标题保持主要文字层级。
- 普通首页预览移除写死的「翻译一句话」。仅 `home-actions` 测试场景包含明确标为「示例快捷动作」的完整问题。正式动作继续读取手机快捷消息。
- DEBUG 夹具增加 10 条长短标题、空预览、混合语言、同步/未同步记事、最近/设置直达及初始滚动位置，均使用隔离存储。

生产修改位于 `iosApp/WatchApp/WatchTaskRootView.swift`；样例位于 `WatchTaskViewModel.swift`。没有新增组件体系或依赖。

## 视觉证据

以下为 watchOS 模拟器的实际渲染截图；数据是隔离样例，不能当成真机同步或点击链路的证据。

| 场景 | 截图与结论 |
| --- | --- |
| 46mm 记录列表，预览开启 | [修复前](assets/amber-watch-layout-fix/before-recent-46-preview.jpg)、[修复后](assets/amber-watch-layout-fix/after-recent-46-preview.jpg)：消除圆角溢出与多行居中，左右卡片边距对称 |
| 46mm 首页底部 | [修复前](assets/amber-watch-layout-fix/before-home-footer-46.jpg)、[修复后](assets/amber-watch-layout-fix/after-home-footer-46.jpg)：组内和按钮外框均居中 |
| 46mm 首页顶部与快捷动作 | [主入口](assets/amber-watch-layout-fix/after-home-top-46.jpg)、[快捷动作](assets/amber-watch-layout-fix/after-home-actions-middle-46.jpg)：同类胶囊按钮对齐一致 |
| 40mm 首页底部 | [截图](assets/amber-watch-layout-fix/after-home-actions-footer-40.jpg)：最近记录、设置与连接居中；本图不包含快捷动作 |
| 40mm 最近列表 | [预览关闭](assets/amber-watch-layout-fix/after-recent-40.jpg)、[预览开启](assets/amber-watch-layout-fix/after-recent-40-preview.jpg)：文字不越界，卡片按内容增高 |
| 40mm xxxLarge | [列表顶部](assets/amber-watch-layout-fix/after-recent-40-large-preview.jpg)、[列表底部](assets/amber-watch-layout-fix/after-recent-40-large-bottom.jpg)：长标题省略，时间和刷新仍能完整显示；初始定位夹具不是手势滚动测试 |
| 记事与同步状态 | [46mm 两种状态](assets/amber-watch-layout-fix/after-notes-46.jpg)、[40mm 大字号](assets/amber-watch-layout-fix/after-notes-40-large.jpg)：状态可换行，不重叠 |
| 46mm 设置 | [截图](assets/amber-watch-layout-fix/after-settings-46.jpg)：连接卡片、同步按钮、触感开关对齐正常 |

独立 subagent `watch_alignment_review` 读取代码并查看上述截图，主线程逐图复核。系统导航栏右侧标题是 watchOS 原生布局，与本次首页按钮居中问题分开记录。

## 构建与安装

- 40mm、46mm 实验版 Watch 模拟器构建及启动通过；最终模拟器构建日志 `build_run_sim_2026-09-08T09-43-35-520Z_pid63831_9b5da0fe.log`。
- 真机 Watch 构建通过：`/private/tmp/amber-watch-layout-physical-build.log`。
- `git diff --check` 通过。本轮没有修改通信或持久化行为，不复用上轮 150 项测试作为本轮视觉通过依据。
- Apple Watch Series 10（watchOS 26.6）已成功覆盖安装并正常启动 `app.amber.ios.watchkitapp`；安装、启动 JSON 均为 `success`，没有 error。结果分别位于 `/private/tmp/amber-watch-layout-device-install.json`、`/private/tmp/amber-watch-layout-device-launch.json`。
- 正常启动没有带预览样例参数。[真机首页](assets/amber-watch-layout-fix/real-home-series10.png)确认主按钮居中，当时手机可达状态为离线；随后通过已有 recent 深链成功打开[真机最近记录](assets/amber-watch-layout-fix/real-recent-series10.png)，确认卡片外框左右边距正常。系统在截图中遮蔽了 privacySensitive 文字，不能用该图证明真实长文本排版；长文本证据来自上面的隔离模拟器样例。

尚不把截图检查等同于手势、VoiceOver 或所有系统状态的完整验收。手机沿用此前安装的 iSH 集成版和已开启的音频保活设置。
