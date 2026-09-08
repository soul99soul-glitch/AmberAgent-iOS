# MiniApp 系统能力审查记录 · 2026-09-08

本轮按用户要求，由三个 subagent 分别检查调用链、原生生命周期和 UI，另一个 subagent 补齐本地化；主 agent 核实问题、整合修复并执行最终验证。范围是本次 MiniApp 的 7 类、16 个系统接口及设置、授权、调试展示，不包含并行 Watch、聊天和小说功能的改动。

代码与模拟器审查通过，未发现当前范围内未修复的阻断问题。整体 Review Convergence Gate 为 **PARTIAL**：真机触感、音频和外部目标仍缺实际设备证据。

## 调用链核对

已从实际源码核对：生成指令 → 输出解析与权限归一化 → 仓库存储 → Runner 加载可信 HTML → 注入 Amber SDK → WKScriptMessage → Runtime 的设置、声明权限和授权检查 → 原生能力 → Promise 成功或失败。

同时核对拒绝或撤销授权、首次授权、设置关闭、HTML 重载、页面退出、后台失活及迟到回调。`getCapabilities()`、SDK 方法名、运行时分派和权限映射一致；首次允许授权不会重建页面而丢失 Promise。二维码不单独申请权限，但受系统交互总开关控制。外链每次确认，分享由系统面板交给用户选择目标。

## 发现与处理

| 状态 | 风险 | 问题与修复 | 证据 |
| --- | --- | --- | --- |
| fixed | 中 | WebView 调试日志原样显示请求、结果和事件，可能包含分享文本或 URL。日志改为已知方法名与状态，不记录参数、请求 ID、返回内容及未知方法原文。 | `IOSMiniAppSystemSDKTests` 在真实 WKWebView 内验证敏感请求、响应、事件和未知方法均不泄漏。 |
| fixed | 中 | 原生处理器若忽略取消，旧文档结果可能回到重新加载后的页面。Bridge 按文档代次校验请求、响应和订阅事件；Runtime 在处理器返回后再次检查取消及关闭状态。 | 真实 WKWebView 重载后的迟到响应为零；非配合式处理器的取消回归通过。 |
| fixed | 中 | 全局系统开关关闭时，管理页仍只显示“允许”，无法解释实际调用被拒。现在保留授权意图，同时显示“全局关闭”及原因，并调整状态颜色。 | 设置持久化与 Runtime 消费测试；正常字号及辅助字号权限截图。 |
| fixed | 中 | iPad 上管理弹窗覆盖 WebView 时，分享面板仍使用底层页面作为定位来源。现在定位到当前可见 presenter 的视图。 | iPad 严格检查 sourceView 身份及 sourceRect；iPhone/iPad 均验证实际呈现与退出后结束请求。 |
| fixed | 低 | 大字号下标题占用过多固定空间，说明文字夹在图标与开关之间，授权按钮触控区域偏小。辅助字号改为说明独占一行、收紧页头；授权控件至少 44 点，胶囊增加垂直留白。 | 320 点宽度、accessibility3 的生产 SwiftUI 视图截图检查；未见重叠或横向溢出。 |
| fixed | 低 | 操作提示浮在滚动内容上方，管理弹窗可能遮住提示。改用底部 safeAreaInset，并在当前可见的管理页展示。 | Runner 和管理 sheet 的实际布局代码检查。 |
| fixed | 低 | 超长外链撑大确认文案。确认预览保留目标主机和部分路径，标记省略；真正打开的 URL 保持原值并继续校验。 | 2800 字符查询参数用例，提示长度小于 400 字符，实际 URL 未被截断。 |
| fixed | 低 | 新权限和设置说明存在漏译，设置行动态 String 未走本地化。补齐六种语言，并使用 LocalizedStringKey；最近活动复用可读权限名称。 | 36 个设置标题/说明全部具备六种语言；英文设置页截图复查。 |
| superseded | 集成缺口 | 早期原工程被并行 Watch continuation 编译问题阻塞。后续该任务完成修复，本轮已回到原工程构建并通过全部定向测试。 | 最终 92 项测试直接使用原工程，无隔离替换。 |

没有为外部浏览器打开链接额外引入 DNS 预解析层；当前 URL 契约拒绝明确的本地、私网字面地址和不支持的协议，不承诺控制外部浏览器之后的 DNS 或重定向。WebView 首次布局前零尺寸锚点目前没有复现为故障，不据此扩展实现。

分享测试先前的失败已定位：iPad 测试需要等待 UIKit 完整转场；iPhone 窄屏会适配分享面板并改写其内部定位视图，因此不应套用 iPad popover 的身份断言。最终测试保留 iPad 的严格定位断言，两端都等待面板进入窗口并验证关闭结果。UIKit 的适配规则见 [Apple 视图控制器呈现文档](https://developer.apple.com/library/archive/featuredarticles/ViewControllerPGforiPhoneOS/PresentingaViewController.html)。

## 最终验证

环境：Xcode 26.5；iPhone 17 Pro 与 iPad Pro 11-inch (M5)，iOS 27.0 模拟器。Debug 构建，关闭并行测试以避免共享窗口相互干扰。

| 验证 | 结果 |
| --- | --- |
| 原工程构建与 iPhone 定向回归 | **92 通过，0 失败** |
| 同一份原工程构建产物在 iPad 上运行原生能力回归 | **10 通过，0 失败**；为上述测试子集，不是额外 10 个独立用例 |
| UI | 10 张生产 SwiftUI 视图截图；320/393 点宽度、中英文、辅助字号、全局关闭权限状态 |
| 本地化 | 36/36 个设置 title/subtitle key 具备 en、ja、ko、ru、zh-Hans、zh-Hant |
| Swift 语法与差异检查 | 通过；`git diff --check` 无输出 |

92 项包括 Runtime 31、原生能力 10、SDK 5、解析 9、仓库 23、主题 6、HTML 校验 5、设置接线 1、UI 证据 2。原工程仍有其他模块的编译警告，本轮构建日志未出现 MiniApp 文件的编译警告；未进行无关清理。

最终结果包：

- iPhone：[92 项结果](/Users/mi/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/result-bundles/test_sim_2026-09-08T11-13-18-728Z_pid67195_8fe491d5.xcresult)
- iPad：[10 项结果](/Users/mi/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/result-bundles/test_sim_2026-09-08T11-16-51-585Z_pid67195_4bfa8929.xcresult)

截图证据：

- [中文窄屏设置](/Users/mi/.codex/visualizations/2026/09/08/01a08067-d6e5-7070-a3ed-880bf33fd6b2/miniapp-review/miniapp-settings-compact.png)
- [大辅助字号设置](/Users/mi/.codex/visualizations/2026/09/08/01a08067-d6e5-7070-a3ed-880bf33fd6b2/miniapp-review/miniapp-settings-accessibility.png)
- [英文设置](/Users/mi/.codex/visualizations/2026/09/08/01a08067-d6e5-7070-a3ed-880bf33fd6b2/miniapp-review/miniapp-settings-english.png)
- [权限状态与按钮间距](/Users/mi/.codex/visualizations/2026/09/08/01a08067-d6e5-7070-a3ed-880bf33fd6b2/miniapp-review/miniapp-permissions-accessibility.png)
- [全部 10 张截图的来源记录](/Users/mi/.codex/visualizations/2026/09/08/01a08067-d6e5-7070-a3ed-880bf33fd6b2/miniapp-review/manifest.json)

本轮主要修改：`MiniAppBridge.swift`、`IOSMiniAppBridgeRuntime.swift`、`IOSMiniAppDeviceCapabilities.swift`、`MiniAppRunnerView.swift`、`MiniAppSettingsView.swift`、`Localizable.xcstrings` 及对应回归测试。复用现有 SDK、授权流程、主题和原生系统面板，没有新增依赖或重写导航。

## 收口边界

可关闭：当前发现的调用链、生命周期、设置状态、已检查 UI 布局和文案问题。原工程集成验证缺口已关闭。

待补：真机振动手感、实际朗读音频、真实分享目标、外部邮件/拨号应用和真实后台使用体验。模拟器的失活测试不能代替这些证据；没有执行真实发送，也没有宣称全项目测试或真机验证通过。

下一步最小验证是在 iPhone 真机上，用一个声明相应权限的小应用逐项触发振动、朗读、分享、外链与常亮，再退出或切后台检查停止和恢复。无需继续重复当前已经通过的代码 review。
