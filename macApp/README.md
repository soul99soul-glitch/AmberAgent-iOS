# Amber for macOS

Apple Silicon、macOS 15+ 的原生 SwiftUI 客户端。在本仓复用 KMP 消息、provider、会话存储，以及 iOS 原有工具引擎、搜索、OAuth、MCP、WebDAV 和生图代码。Shared.framework 仍由本仓 Gradle 生成，Core 没有独立发布。

实现和独立 review 记录见 ../docs/product/macos/。本机已能构建真实 Shared.framework 和正式 Native 应用；最新[审查与性能验证](../docs/product/macos/performance-review/review.md)记录本轮修复、测试、测量和剩余边界。早期云端记录中的 Xcode/Gradle 权限阻塞不代表当前本机状态。

## 打开界面

正式 Release 应用在 `macApp/build/Build/Products/Release/Amber.app`。在仓库根执行：

~~~bash
open macApp/build/Build/Products/Release/Amber.app
~~~

可选 Preview 位于 `macApp/build/swiftpm-preview/AmberPreview.app`，共用 Runtime/UI，使用隔离的示例会话、内存凭证和示例回复，不连接模型、登录或生图服务。文件导入、导出、知识编辑和备份仍会按操作实际读写，示例会话不写入正式会话库。Preview 和离屏组件图用于界面验证，真实 provider 与 Shared 接线另由正式 Native 测试验证。

可重复构建使用与 iOS 相同锁定 revision 的真实 iosMath：

~~~bash
macApp/scripts/build-preview-swiftpm.sh
~~~

仓库已有该 revision 的正常 checkout 时可以复用缓存：

~~~bash
macApp/scripts/build-preview-swiftpm.sh \
  --iosmath-path macApp/build/SourcePackages/checkouts/iosMath
~~~

脚本校验依赖 revision，编译同源 SwiftUI 与真实公式组件，复制字体资源，并按 Preview 的 App Sandbox 权限签名。它不生成假的 Shared，也不解除应用沙盒。Xcode 可选择 AmberMacPreview scheme；受限环境中固定 SwiftPM manifest 缓存目录可能不可写，同源 SwiftPM 入口不依赖该目录。

## 当前实现边界

| 领域 | 已接线的行为 |
| --- | --- |
| 聊天与上下文 | 流式/停止/重试、编辑重发/删除/重生成/变体、按需加载历史、消息搜索定位、确定性请求预算裁剪、0.85 自动阈值与链式上下文检查点（schema v2 + 12 类 needle 保真校验）、只读历史检索（`history_search` / `history_fetch` 含凭据脱敏）、回顾/建议、原会话指令队列 |
| 模型 | OpenAI 兼容、Responses、Claude（含可选 `promptCaching` 前缀缓存与 `cachedTokens` 观测）、Gemini；多模型、目录、参数及模型级 headers/body；Codex/Grok 登录和已有 Antigravity token 解析；独立辅助模型、视觉回退和标题生成 |
| 阅读与文件 | 中文 Markdown、列表/引用/表格、代码高亮、真实 iosMath；拖放/粘贴图片，PDF/DOCX/PPTX/RTF/文本解析预览；Workspace 与 Markdown/PDF/JSON 导出 |
| 工具与审批 | 复用 IOSAgentToolEngine；工具发现、原 run 审批、持久事务、搜索、会话目录读写和本地命令；高风险工具（`terminal_exec`、`workspace_artifact_delete`、`mcp_call_tool`、`interrupt_agent` 及插件写工具）仅允许在 Mac 端批准，通知栏与手机 Gateway 端仅可拒绝；不自动重放结果未知的调用 |
| 插件与工作流 | 5 项核心能力开关与 `amber.plugin.v2` 扩展体系：内置 `feishu_calendar`（日历 CalDAV + 机器人 Webhook/OpenAPI + `feishu_meeting_loop` 会后闭环 Recipe）、内置 `apple_schedule`（本机 EventKit 日历与提醒事项读写）、内置 `watchtower`（纯 JS 快照/diff + `watchtower_check` 网页变更巡检 Recipe）；第三方 JS 插件严格限定在纯计算与持久 KV 状态，不开放沙箱网络、工作区文件写入或宿主模块 |
| 外部服务与知识 | MCP HTTP/SSE/stdio、工具启停；Skills/SOUL/记忆与来源；技能可收紧工具范围；内嵌 `amber-gateway` 支持手机配对、四栏任务看板与远程审批（协议冻结见 `docs/architecture/gateway-contract-c3.md`） |
| 协作与定时任务 | 有并发/超时/取消和只读工具循环的子代理、议会多轮讨论与综合、结果回原会话；Recipe 固定工具步骤共用审批与事务链；定时与事件触发任务支持独立无人值守审批策略与睡眠唤醒补跑 |
| 媒体 | 系统语音、声音/语速与消息朗读；OpenAI 兼容/Codex 生图复用原 repository，结果保存至原会话文件 |
| 数据与隐私 | 任务生命周期、可选通知、加密备份/副本恢复、WebDAV 快照、实际存储用量；原始对话历史永不被压缩投影覆盖；服务商 API Key、MCP 敏感头、WebDAV 密码与插件密钥仅存系统 Keychain（拒绝脱敏占位符覆盖），并在历史检索、压缩摘要与任务账本落盘时自动脱敏 |

当前测试计数、正式 Native/local provider、KMP/iOS 回归及性能测量统一见[最新审查](../docs/product/macos/performance-review/review.md)。流式 provider 在约 30Hz 发布完整快照，终态、失败和停止前保留最后已接受内容；MCP 分片只扫描新增字节，长会话保存后的消息查找使用线性索引。

固定产物架、议会多轮和 iOS 会话备份导入已有入口。仍保留的边界包括子代理独立会话、专门的 SSH 配置、单次请求参数覆盖、Antigravity 首次登录、iOS 全量备份/CloudKit 互导、多语言与 Mac 订阅。真实 OAuth 账号登录、系统通知授权/点击及 Developer ID 公证需各自的账号、权限和证书验证。

按约定排除小说创作、深度阅读、小应用、WebMount。手机控制、Watch、Live Activity、AlarmKit、iSH、嵌入式 Python 未搬入 Mac。

## 正式构建与验证

需要完整 Xcode/macOS SDK、XcodeGen、JDK 17 或 21，以及可正常构建 Kotlin/Native 的环境。在仓库根执行：

~~~bash
macApp/scripts/build.sh
macApp/scripts/build.sh test
CONFIGURATION=Release macApp/scripts/build.sh
~~~

默认 Debug 构建路径为 `macApp/build/Build/Products/Debug/Amber.app`；设置 `CONFIGURATION=Release` 后生成 `macApp/build/Build/Products/Release/Amber.app`。XcodeGen 工程 macApp/AmberMac.xcodeproj 的 AmberMac scheme 连接真实 desktop-shared Mac framework，iOS 继续使用原 shared 模块。

Swift Runtime、真实 provider 和 Gradle 验证入口分别为：

~~~bash
macApp/scripts/test-runtime.sh
macApp/scripts/test-provider.sh
./gradlew :desktop-shared:jvmTest :desktop-shared:compileKotlinMacosArm64
~~~

当前环境的 Swift 宏有嵌套沙盒限制，Runtime 测试可仅对本次编译附加：

~~~bash
macApp/scripts/test-runtime.sh --disable-sandbox -j 2 \
  -Xswiftc -Xfrontend -Xswiftc -disable-sandbox
~~~

该参数只用于编译器，不写入产品设置。隔离测试不涵盖 Shared 适配器，不替代 Swift/Native 链接、真实 provider 或系统权限验证。正式分发还需要 Developer ID 签名和公证；本地 ad hoc 校验不是公证。

## 使用与数据

正式版首次在设置中添加服务商、模型和凭证。凭证使用本机 Keychain；会话、文件和任务由各自 owner 写入应用沙盒，与 iOS 数据分离。备份可选择密码加密；钥匙串 API Key/登录凭证不导出，自定义 headers/body 属于模型配置，会随备份保存，填写敏感值时应注意这一点。

- ⌘N：新会话；⌘F：搜索；⌘,：设置。
- ⌘Return：发送或排队文本；Return：换行。
- ⌘.：停止当前会话生成。切换会话后可通过运行入口返回原会话。

关闭窗口后任务由 App 持有；退出会取消任务并等待已接受的结果、文件和记录写入，保存失败时保留窗口以便处理。未确认的外部副作用不会自动重放。
