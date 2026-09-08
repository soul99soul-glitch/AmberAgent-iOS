# Amber Watch 实施与验证记录

> 后续独立复查、修复与最新 150 项用例验证见 [调用链与界面复查](2026-09-08-amber-watch-followup-review.md)。下文保留首轮实施记录。

日期：2026-09-08。范围：用户选择的「腕上提问、记事与手机任务交互」和「任务进度、提醒、快捷操作」。产品定义见 [Amber Watch 1.0](../product/amber-watch-v1.md)。

## 实现

- **Watch 原生页面**：首页、问题/笔记输入、当前任务、完整追问选项、回答节选、继续原对话、最近 10 条对话、笔记详情、连接与设置。沿用 Amber 标识和暖色，支持系统听写入口；长文字使用滚动布局。
- **输入与同步**：问题草稿和笔记先以原文原子写盘；笔记离线排队，iPhone 写入成功并应用层确认后才标为已同步；相同 ID 不得覆盖不同原文。问答和任务命令不离线排队，发送不确定时保留完整原请求。手机在启动请求前写持久回执，重启重试不会另启任务。快照使用单调序号抵御同秒更新和乱序包。
- **手机执行与接力**：复用现有 ChatViewModel/provider/工具链。当前输入或任务忙碌时保留手机草稿并拒绝抢占。后台唤醒可建立同一套持久 owner；随后 AppShell 接管原实例和会话存储，startup recovery 排除仍有 owner 的 run。手机接力保存稳定 URL，成功应用导航后才删除；手表只声称「已发送到 iPhone」。
- **有界确认**：仅完整可展示的只读网页搜索/公共 HTTP 网页读取可在手表批准。其他操作可拒绝或在手机处理；短回答与选项保留原问题、runId、decisionId 校验，旧按钮和取消对话框不能操作新任务。
- **手机设置**：Apple Watch 页面显示连接、当前助手、快捷动作的添加/编辑/删除与最多 4 项选择、全部同步笔记原文和通知设置；显式选择空列表可持久化，选择和助手改变后重新发布。快捷动作复用 KMP Settings 的现有 JSON 桥和手机消息集合；只含 `[ROUTE:…]` 的预置路由入口不会被当作可发送问题。
- **系统入口**：正式/实验 Watch target 都含原 Amber AppIcon、自己的 WidgetKit 扩展、独立 URL scheme 和 App Group。圆形提问/记事/最近入口，矩形当前任务卡。Widget 缓存只含状态及定位 ID，排除问题、结果、助手和会话库。
- **提醒与隐私**：沿用手机完成通知并增加需要回答提醒；同一决定去重，解决后取消待投递提醒，通知正文为泛化文案。触感和内容预览持久化；低亮度且预览关闭时各页隐藏正文。清缓存保护未同步笔记、问题草稿和当前未发送回答。

- **多语言**：新增 158 个固定文案键，均包含简体中文、繁体中文、英文、日文、韩文和俄文；英文输入页与俄文任务页完成模拟器抽查。尚未进行逐语言母语校审。

工程配置继续由 `iosApp/project.yml` 生成，没有新增第三方依赖，也没有改 KMP provider/runtime/storage。Swift 仍通过 Gradle 工程生成并消费 Shared.framework。

## 自动化验证

共 137 个不同的相关用例通过，分轮收敛：

- 完整定向集：135/136 通过。唯一剩余失败是去重测试预期打开失败任务的 result 页，实际约定为 task 页；去重与 URL 身份断言本身通过。
- 调整该测试的目标页预期并清理测试 actor 警告后，重新运行 `WatchTaskSnapshotTests` 与 `WatchLocalStoreTests`：43/43 通过。
- 快捷动作编辑闭环补齐后，再运行手机 Watch 存储与端到端状态用例：13/13 通过，含新增的创建、修改、重载、删除与路由标记过滤测试。
- 测试覆盖：Watch 快照与审批、传输可靠性、手机与手表原文存储、请求幂等、通知、接力持久化、设置接线、后台恢复及 ChatKernelRunHost。

运行环境：iPhone 17 Pro / iOS 27 Simulator，`iosApp` Debug，`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，禁用并行测试。

本机原始记录：

- 完整集日志：`~/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/logs/test_sim_2026-09-08T06-20-37-451Z_pid69148_a9eef5ed.log`
- 最终复跑日志：`~/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/logs/test_sim_2026-09-08T06-23-03-974Z_pid69148_97ea8804.log`
- 快捷动作与状态复跑：`~/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/logs/test_sim_2026-09-08T06-35-37-543Z_pid69148_8909ee3f.log`
- 最终复跑结果包：`~/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/result-bundles/test_sim_2026-09-08T06-23-03-974Z_pid69148_6950226d.xcresult`

第一次关闭模拟器代码签名运行时，3 个原有 Grok OAuth 用例在 Keychain 写入处失败；使用模拟器 ad-hoc 签名重新运行后，这 3 项全部通过。未修改认证逻辑或弱化测试。

正式与实验 Watch App 及其 Widget 扩展在 watchOS 27 模拟器构建并启动成功。最终资源检查后的记录：

- iPhone 主应用：`build_sim_2026-09-08T06-49-50-012Z_pid69148_67797857.log`（全部最终资源合并后通过，75.7 秒）。存在原有弃用 API / Sendable 等警告，无构建错误。
- 正式版：`build_run_sim_2026-09-08T06-48-25-003Z_pid69148_61b05194.log`（40 mm，13.1 秒）。
- 实验版：`build_run_sim_2026-09-08T06-49-18-359Z_pid69148_12f8ae85.log`（46 mm，11.0 秒）。
- 新增 158 个字符串键的六语言完整性、JSON 解析、相关 plist/entitlements 与 `git diff --check` 通过。AppIcon 已经 actool 编译，保留原 Amber 1024 像素源图。

## 模拟器界面证据

| 画面 | 设备 / 数据来源 | 证据 |
| --- | --- | --- |
| 首页离线 | Watch SE 3，40 mm；正常启动、实际不可达状态 | [首页](assets/amber-watch/home-40mm-offline.jpg) |
| 等待回答 | Watch SE 3，40 mm；DEBUG 示例快照 | [等待回答](assets/amber-watch/waiting-40mm-fixture.jpg) |
| 已完成与回答节选 | Watch Series 11，46 mm；实验版，DEBUG 示例快照 | [完成](assets/amber-watch/completed-46mm-fixture.jpg) |
| 输入原文完整预览 | Watch SE 3，40 mm；英文 UI、中文用户输入，DEBUG 草稿 | [输入](assets/amber-watch/compose-40mm-en-fixture.jpg) |
| 俄文任务标题与状态 | Watch Series 11，46 mm；俄文 UI、中文任务内容，DEBUG 示例快照 | [俄文](assets/amber-watch/waiting-46mm-ru-fixture.jpg) |
| 原文笔记待同步 | Watch Series 11，46 mm；实验版，独立临时文件中的 DEBUG 示例笔记 | [笔记](assets/amber-watch/note-46mm-fixture.jpg) |

示例状态通过 `-amber-watch-preview=` 启动，只在 DEBUG 生效，使用独立临时存储并禁用真实发送。它们证明布局能渲染这些状态，不能当作手机真实问答、按钮点击或同步成功的证据。

## 仍需真机验收

开发时 iPhone Air 与 Apple Watch Series 10 均报告不可达；Mac 锁屏阻止 Simulator 的 UI 点击，当前环境也没有 AXe。已检查渲染截图和行为测试，尚未完成如下实际设备验证：

- 配对手机后台/锁屏唤醒后的真实 provider 问答、原会话追问和双端重启后的回执恢复。
- 系统听写、触感、通知转发与点入任务、表盘安装/点按及智能叠放刷新。
- 抬腕放腕、VoiceOver、辅助功能字号、最小/最大支持机型的实际操作。
- 手机产品设置页的点击、同步原文管理与真实系统权限对话框。
- 新 App Group/Watch Widget target 在开发者账户中的真机签名及安装；此次没有发布或生成正式分发包。

WatchConnectivity 和 WidgetKit 的后台执行、投递与刷新由系统调度，界面使用真实状态和更新时间；不声明离开手机也可独立运行，亦不声明任意 provider 可无限后台执行。产品文档中的设备验收项保留未勾选，完成这些验收前不能称为已经通过发布验收的版本。
