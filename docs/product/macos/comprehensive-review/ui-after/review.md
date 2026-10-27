# macOS UI 修复后复核

2026-10-23。本轮已确认的编辑重发草稿丢失问题 R6 已修复；取消队列占位、生图本地保存恢复和编辑器的真实生产组件复核通过。未确认新的布局碰撞、错误裁切或不可达操作。最终 App 实窗启动及复拍仍未通过，不能把以下组件验证写成最终包实窗验收。

## R6 编辑重发

生产调用链为 `DesktopMessageEditor.submit` → Transcript async closure → `withCheckedContinuation` → `workspace.editAndResend(...completion:)`。同步拒绝和异步保存失败均返回 false，读取原 owner 的错误；原分支持久化并发布成功才返回 true。provider 后续生成失败不撤销已保存的编辑，因此不阻止编辑器关闭。Runtime 的 25 项分支测试由 runtime reviewer 验证，UI 源码另经独立 reviewer 复核。

隔离 harness 加载未改写的生产 `DesktopMessageEditor`，由 SwiftUI 的真实 `.sheet` 呈现；只在容器设置原生背景与浅色 appearance。使用该测试进程自身 `NSWindow.performKeyEquivalent(with:)` 驱动实际 ⌘Return/Escape，未提取或替换按钮逻辑，未通过系统事件控制用户 App。async 提交回调由测试 continuation 控制结果。

实际断言及截图：

- [ready](components/phase3-editor-ready.png)：560×390，标题、分支移除说明、原始草稿和按钮完整。
- [busy](components/phase3-editor-busy.png)：560×390，首次真实提交保持 pending；重复 ⌘Return 不增加提交次数，Escape 不关闭。取消与保存按钮呈禁用状态。
- [failure](components/phase3-editor-failure.png)：560×466，返回 4 次重复的长错误后 sheet 保持，原稿显示完整，错误自然换行且底部按钮可见。再次 ⌘Return 的实际 payload 与第一次逐字相同。
- 第二次返回 nil 后实际 `isPresented == false` 且原生 sheet 窗口隐藏。没有用空白替身页面表示成功。

`harness/phase3-editor-states.log` 为成功运行 exit 0 的日志，包含 `PHASE3 REAL EDITOR COMPLETE`。busy 时禁用 TextEditor 的正文没有被离屏缓存绘出；失败状态恢复后原稿可见，两次提交完全相同。这不是数据丢失证据；因 CUA 断连，目前不能通过最终 App 实窗排除该原生绘制差异。

## Phase 2 新状态

[浅色取消场景](components/phase2-cancelled-steer-860-light.png)及[深色取消场景](components/phase2-cancelled-steer-860-dark.png)均为860×600。上一条 assistant 仍为 complete，新空 cancelled assistant 显示“已停止，可重新生成”，重试入口、消息间距和输入器完整；有内容的取消回复仍使用保留生成内容的提示。

生图状态使用实际 `IOSImageGenerationHistoryStore` 的 `source = macos:<owner UUID>` 记录、真实临时 PNG、实际 `DesktopWorkspaceFiles` 与 `DesktopImageGeneration`，未模拟保存页。

| 状态 | 实际断言 | 截图 |
| --- | --- | --- |
| 待保存 | pending 2；指向原 owner | [pending](components/phase2-images-pending-light.png) |
| 部分保存失败 | 第一张已导入原 owner；第二个暂存文件缺失；artifacts 1 / pending 1 | [light](components/phase2-images-partial-light.png)、[dark](components/phase2-images-partial-dark.png) |
| 恢复保存 | 补齐第二个本地暂存文件后重试；artifacts 2 / pending 0 | [recovered](components/phase2-images-recovered-light.png) |

四张生图 PNG 实际为740×660，生产表单固定680×620。待保存说明、失败提示和底部重试入口完整；artifact 卡片在 ScrollView 中，首屏只露出一部分属于正常滚动内容。实际文件错误被生产 Runtime 收敛为用户提示，未声称此图覆盖长服务端错误。整个恢复链 transport 计数为0，没有真实网络、凭证或 provider 请求。`harness/phase2-states.log` 为成功运行 exit 0 的日志。

第一次临时 fixture 重试曾被前一个离屏窗口的真实 `onDisappear` 取消；等窗口卸载后再驱动模型即通过。这是测试时序问题，未据此修改生产代码。

## 源码与独立复核

`components/source-manifest.tsv` 包含78份生产 Swift 源文件的 SHA-256，已逐项比对当前生产文件与 harness 源码副本，78/78 一致，包括新增 `DesktopPublicSearchURL.swift` 与既有 `IOSPublicURLPolicy.swift`。harness 全量编译通过，未修改 Shared.framework 或生产状态访问级别。三份 fixture 源码、Package.swift 和成功日志保留在 `harness/`。

独立 UI reviewer 对 Phase 2 六张 fresh 图、Editor 三张最终状态图、R6 async 回调及空取消文案均复核通过。长错误增高后底栏仍有约24pt余量，未发现碰撞或裁切。修复前本轮9张实窗图与24张组件压力图仍保存在 `../ui-before/`；本页的新状态截图均由最终 frozen UI 源码重新构建后生成。

## 实窗与平台边界

最终包 rebuild 后 CUA 重试返回 `Transport closed`，未再重试或绕行系统自动化。Root 的 LaunchServices 启动返回 -10827；直接二进制启动 exit134 且无可用崩溃链。最终 Mach-O 和签名检查通过也不能证明实窗成功。本轮没有证据把这一受限环境现象定位为生产崩溃，但最终包的正常桌面启动、上述失败后恢复的 App 实窗操作及 busy 正文绘制仍待可用桌面会话验证。

正式 Native、真实 provider、登录和系统权限不属于离屏证据；General 通知页此前因裸进程 bundle 限制未离屏验证。本轮未修改系统权限、外部登录或真实用户凭证。
