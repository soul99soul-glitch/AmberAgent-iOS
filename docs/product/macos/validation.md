# macOS 实施与验收状态

日期：2026-10-23。当前八阶段主链已实现并做受影响测试与独立 review，后续[全面复核与修复](comprehensive-review/review.md)确认六个问题并顺序修复，最新共用 Swift Runtime **253 tests/0 failures**（23:22:37 CST），正式 Swift 104 文件语法检查通过。此前 Kotlin/JVM **82 tests/0 failures**，本轮未重跑。最新 UI、交付和正式构建尝试以全面复核目录为准；下面保留原八阶段的验证历史。正式 Native 集成未通过，不能称产品正式完成。

## 证据边界

| 层级 | 已取得的证据 | 尚不能证明的内容 |
| --- | --- | --- |
| 共用 Swift Runtime | 实际 production 源的 XCTest，包括真实文件/图片/PDF、持久化、子进程与传输 fixture；下表记录最新受影响批次 | 排除 Shared/正式组合的测试不能证明生成 header、Native 链接或真实 provider |
| Kotlin/JVM | 官方 Kotlin 2.3.21 与 serialization 插件编译真实桥/测试，最新 82 tests/0 failures | 使用本机缓存依赖，不等于 Gradle 全量重建或 Mac Native |
| 原生 Preview | 较早同源隔离窗口已实际打开；最终交付包已构建/ad hoc 签名，但锁屏下未 launch；各自证据如下 | 本地示例没有向真实模型请求，不能证明工具/外部账号/正式数据链 |
| 同源原生离屏组件 | NSHostingView/NSWindow 真实 bitmap；六图与源码 SHA-256 已存档，独立逐张复核通过 | 非 key、无 Shared 的临时 fixture；不证明最终 App toolbar、弹层/Tab 交互或模型链 |
| 正式 AmberMac/iOS 回归 | 构建命令实际尝试，保存下述阻塞日志 | 尚无正式 Mac Shared、Swift 消费、真实模型及 iOS 回归通过证据 |

## 最新自动验证

最新整套共用 Runtime 为 **253/0**，日志保存于 `comprehensive-review/evidence/final-runtime.log`；本轮新增 26 条回归。下面的 227/0 与其他批次是前次八阶段历史，有重叠，不相加为总数。

该 Swift 套件编译真实共用 Runtime、原 iOS 生图/MCP/WebDAV 可移植源码及 Markdown parser；**排除**依赖 Shared 的 `DesktopProvider`、`DesktopConversationStorage`、`DesktopLiveWorkspace`、`DesktopKMPModelCatalog`、`DesktopGeminiPrimitives`、`DesktopSearchTransport`、`DesktopAgentProvider`、`DesktopEngineLedger` 与真实 KMP provider 集成测试。它验证 Workspace 持久确认消费者，不证明 formal AgentProvider/原 engine Native 执行。SwiftUI/原生数学布局另由 Preview 与组件检查覆盖，不能混入 227 项结论。

| 批次 | 结果及日志 | 核心覆盖 |
| --- | --- | --- |
| 整套共用 Runtime | 227/0，`/tmp/amber-mac-all-runtime-delivery.log` | 当前所有可移植源与测试，包含最后 queue 保存重试、生图、语音、5 项真实 Workspace 辅助消费者、命令/MCP/文件等；排除范围如上 |
| Workspace/文件/备份/Recipe | 54/0，`/tmp/amber-workspace-phase-final.log` | 摘要/按需全文、分支、owner、原子文件、接受的附件任务、协作结果、恢复 rollback、Recipe owner |
| 生成中指令队列/关联 Runtime | 16/0，`/tmp/amber-workspace-queue-final.log` | 文本终态后原 owner 新请求、工具边界一次 lease、写盘后确认、停止/失败保留、撤回草稿、stale/删除失败、已提交未保存的显式重试、未消费 pending 在原回复保存失败后的用户重试只发一次 |
| 最新 Runtime 消费者 | 28/0，`/tmp/amber-workspace-consumers-fixed.log` | durable ack、原 owner、消息失败不确认/metadata 失败不误阻、停止最终 transcript、备份退出取消、真实用量、通知不重复/不误报、备份与协作 |
| KMP 最新桥及相关原有用例 | 82/0，`/tmp/amber-kmp-overrides-check.log` | canonical parts/变体/blob、摘要/全库搜索、原始图片消息、已知记忆引用重映射、历史未决工具的请求副本处理、模型 overrides 与搜索设置传递 |
| 生图适配 | 8/0，`/tmp/amber-image-generation-final-tests.log` | 复用原 iOS 生图 repo/Models/Codex request builder；OpenAI fixture→原 owner 文件/真实 ImageIO/清 staging、失败/取消、重试校验替换旧错误和忙态；Codex SSE/poll headers fixture；未登录外部账号 |
| 文件与可读导出 | 11/0，`/tmp/amber-mac-files-tests.log` | DOCX/RTF/PPTX/中文 HTML/PDF、图片解码、TIFF 剪贴板转 PNG 名称/实际 bytes、Markdown 图片 URL 与 PDF 真嵌图/远程链接/无效图提示 |
| 模型/协作/通知/语音 | 50/0，`/tmp/amber-mac-model-speech-tests.log` | 多模型与辅助路由、配置/凭证隔离、协作持久状态、通知开关与消费者、真实系统语音适配的注入测试 |
| 知识 | 9/0，`/tmp/amber-knowledge-isolated-tests.log` | 技能/Soul/记忆持久化、来源、删除/重开、ID 高水位、恢复 ID/link/source 映射与回滚 |
| Recipe | 7/0，`/tmp/amber-recipes-tests.log` | 强类型输入、真实复用执行路径、失败/取消；已确认原子结果保留 completed 且不再启动下一步 |
| MCP/WebDAV 传输 | 18/0，`/tmp/amber-mcp-webdav-final.log` | MCP 10 + WebDAV 8；真实 stdio 父子进程退出/取消、HTTP/SSE 与备份传输 fixture、已取消 caller 不上传；不是外部真实账号/服务验收 |

独立子代理已亲读 Workspace/存储/备份/知识/Recipe 和真实 engine 调用路径。最新工具前效检查确认：轮完成后先等待 canonical 写盘；删除/stale token 不确认；异步停止即使在 writer 等待期间发生，BatchExecutor 和 Executor 在派发前仍检查取消，不继续执行副作用。没有为正常最终快照增加多余停止 guard。最后允许的工具 step 不再 lease 无法进入下一模型轮的 steer；该原 engine 定点修复已做独立源码复核，iOS fixture 执行仍受下述权限阻塞。

## 八阶段验收进度

| 阶段 | 实现与已验 | 正式目标待验 |
| --- | --- | --- |
| 1 基础 | 完整 canonical、变体/资源、导入导出、保存/终态归属；Preview 顶部修复 | Mac Shared/header/链接、实际 Keychain/provider、iOS 消费 |
| 2 聊天 | 编辑/删除/重生成/变体、摘要/按需读取/全库搜索、预算与回顾/建议/压缩、阅读组件；860×600 浅深色组件离屏 | 860pt 整窗交互与真实长流式性能 |
| 3 模型 | 多服务商/多模型、发现/参数、标题/视觉等辅助消费者、协议/OAuth 与搜索配置测试 | 外部 OAuth 登录/刷新/退出、真实协议/辅助模型请求及 Keychain |
| 4 文件 | 原始媒体 parts、文档解析、文件库、Markdown/PDF/canonical 导出及 owner；生图适配与产物文件 | 新图片/Office/PDF/生图 UI 闭环、真实视觉/生图模型与授权 |
| 5 Agent | 原 engine、逐调用批准、真实工作区/命令工具、任务/停止/恢复、durable ack | 实际模型混合多工具→批准/拒绝→回填→续轮 |
| 6 知识/MCP | 实际 stdio、HTTP 传输与知识持久化测试；原生新增中文记忆 | 外部 MCP、Skill/Soul 原生导入与正式请求消费 |
| 7 协作/Recipe | 持久协作、多模型议会、结果文件+消息、Recipe 共用 executor/审批；相关测试、UI 类型检查与面板离屏 | 新界面原生操作、外部多模型并行/超时/取消 |
| 8 使用/数据 | 真加密备份、新 ID 副本恢复、rollback、WebDAV 传输、退出等待、通知/用量消费者、偏好 | 新通知/存储/同步/偏好 UI、正式系统权限/生命周期、Release/安装 |

## 原生 Preview 已验证的交互

以下来自实际原生窗口，图片由 CUA 实时返回；没有保存整套应用截图文件。独立 table/math 图不能当最终整窗矩阵证据。

- Phase 1：短/长/空会话浅深色顶部完整，预览提示固定 footer；默认 1180×800 和约 1121×653 外框已检查。系统窗口操作没有取得有效 860pt 宽证据。
- Phase 2：编辑重发/变体/停止、切旧变体保后文、删除确认/取消、下一步定位、回顾、压缩 2034→159→恢复 2034 且保留 8 条历史；Return 两行与 ⌘Return 发送；浅深色停止状态可辨。
- Phase 3：真实 Settings 页改名后切页提示未保存，取消保草稿；新增 alias/wire ID/context 8192/temp 0.3/max 1024，保存并使用后 toolbar/composer/sidebar 模型计数更新。
- Phase 4：实际 `/tmp/notes_zh.md` 导入→pending 全文/bytes 预览→发送清草稿→会话文件保留原件。新的多媒体可读导出单测已过，整窗交互尚待最终二进制复核。
- Phase 5：任务空态与文件列表排版可见，没有将该检查算作真实模型工具执行。
- Phase 6：新增中文记忆并置顶→保存为真实 ID 1000→列表可见；Skills/Soul 仍待原生消费验收。
- Phase 8：实际导出备份→选该文件恢复为副本，结果 8 会话/1 配置/1 记忆；恢复资料 owner 可见，长状态及完成按钮完整。

最终同源 SwiftPM Preview 交付包构建 exit 0，独立签名校验 exit 0，文件时间为 **2026-10-23 20:40:22 CST（UTC+08:00）**；日志 `/tmp/amber-interface-delivery-build.log`，纳入的 Runtime/UI/Preview 源与快照逐文件 0 差异。该包包含队列三态、语音设置/菜单、生图 owner facade、标题操作与搜索设置。Mac 锁屏使该最终 App 尚未 launch，新包交互复拍未执行；下面的真实离屏图只验对应组件，不替代该项。

## 最终同源原生离屏复核

使用生产 Runtime/UI 源码快照，通过 NSHostingView/NSWindow 原生 bitmap 绘制，使用隔离 fixture/内存会话，知识导入与备份恢复实际在临时目录执行。独立子代理已逐张亲看六图，无剩余布局 finding。截图及 SHA-256 清单见 [screenshots/README.md](screenshots/README.md)。

| 原生组件 | 已验内容 |
| --- | --- |
| 860×600pt 工作区，浅/深色 | 审批自然参数摘要、三条排队摘要、输入区完整；非 key 停止按钮对比清晰 |
| 1280×1000pt 阅读，深色 | 中文表格自然行高与底句、长代码及真实 iosMath 完整 |
| 620×440pt 备份面板，浅色 | 真实恢复后的长状态与操作完整可见 |
| 820×670pt Recipe 面板，浅色 | 导入的 Recipe、长名称与输入布局完整 |
| 820×700pt 协作面板，深色 | 三名成员和模型选择布局完整 |

本轮据实际 860pt 图精准修复审批 ScrollView 空白、三条队列挤压输入区及浅色非 key 停止图标对比；使用自然摘要与全文/三态详情 popover，没有加最小高度或偏移掩盖。弹层实际点击、窗口 toolbar、Knowledge/Settings Tab 选择器与真实 provider 均未在该离屏 bridge 验收，继续留待解锁后的 App 交互检查。

## 备份与迁移的准确范围

Mac 容器为 `amber.mac.backup.v1`，不宣称兼容 iOS 整机备份容器。会话导入复用原 canonical 格式。可选加密使用真实 AES-GCM 与 PBKDF2-HMAC-SHA256（210000 次、16-byte salt、32-byte key）；密码保留原始字节，空格不是无密码。错误密码、损坏/重复记录、越界路径均在正式数据写入前拒绝。

恢复为新会话/模型 UUID，原数据不覆盖；失败或取消删除本次新增记录、文件、insights、配置与记忆。记忆重新分配数值 ID，并映射来源会话及已知 canonical 引用。Keychain 不导出/恢复；Skill/Soul 是待显式导入启用的恢复资料，通用偏好保存在 `configuration/preferences.json` 等待手动应用。WebDAV 每次推送独立备份对象，不宣称实时双向合并。

## 尚未通过的正式构建

Gradle 在任务配置前创建文件锁监听 socket 失败：

```text
FileLockContentionHandler
java.net.SocketException: Operation not permitted
```

证据：`/tmp/amber-mac-phase1-gradle.log`、`/tmp/amber-kmp-gradle-phase5.log`。官方 Native 编译器可启动，但本机缺 macos_arm64 第三方 KLIB，依赖下载受现有代理连接阻断。没有生成替身 framework、替换 iOS slice 或绕过权限。因此 Mac Shared/Header/正式链接/原生存储 actual 尚未通过。

iOS 受影响回归实际运行失败于 SwiftPM manifest 缓存/模块缓存写权限以及 CoreSimulator 服务连接不可用，未执行到测试。证据：`/tmp/amber-ios-final-impact-tests.log`、`/tmp/amber-ios-engine-regression.log`、`/tmp/amber-ios-sync-tests.log`、`/tmp/amber-ios-steer-review-tests.log`（最新轮边界 guard fixture 尝试 exit 74，执行前阻塞）。这不是 iOS 测试通过或代码失败的证据。

真实外部 provider、OAuth、WebDAV/MCP 账号、系统通知授权、正式沙盒文件授权和完整退出/后台行为均需在正式应用中补验。没有读取用户已有凭证发起外部请求。

## 可重复执行入口

```bash
macApp/scripts/test-runtime.sh --disable-sandbox -j 2 -Xswiftc -Xfrontend -Xswiftc -disable-sandbox
macApp/scripts/build-preview.sh
./gradlew :desktop-shared:jvmTest :desktop-shared:linkDebugFrameworkMacosArm64 --console=plain
macApp/scripts/test-provider.sh
macApp/scripts/build.sh test
CONFIGURATION=Release macApp/scripts/build.sh
```

Swift 附加参数只针对当前嵌套宏沙盒的单次检查，未写入产品配置或关闭 App Sandbox。正式框架输出应为 `desktop-shared/build/bin/macosArm64/debugFramework/Shared.framework`。当前本地 ad hoc 签名不等于 Developer ID/公证；Release 和安装验收仍保留。
