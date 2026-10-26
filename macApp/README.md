# Amber for macOS

Apple Silicon、macOS 15+ 的原生 SwiftUI 客户端。在本仓复用 KMP 消息、provider、会话存储，以及 iOS 原有工具引擎、搜索、OAuth、MCP、WebDAV 和生图代码。Shared.framework 仍由本仓 Gradle 生成，Core 没有独立发布。

八阶段实现和独立 review 记录见 ../docs/product/macos/。最新[全面复核与修复记录](../docs/product/macos/comprehensive-review/review.md)确认并修复六个问题，按四阶段完成受影响回归和独立 review。**正式版尚未完成 Native 集成验收**：正式构建仍在 Xcode/Gradle 缓存权限处受阻；真实模型、正式 Keychain 和沙盒内工具仍待验证。下面的 Preview 是共用页面的可运行开发产物，不能作为正式聊天应用使用。

## 打开界面

最新原生产物：macApp/build/swiftpm-preview/AmberPreview.app；打包文件为 macApp/build/AmberPreview.zip，已验证解压后的严格签名。双击应用或在仓库根执行：

~~~bash
open macApp/build/swiftpm-preview/AmberPreview.app
~~~

Preview 共用 Runtime/UI，使用隔离的示例会话、内存凭证和明确标注的示例回复，不连接模型、登录或生图服务。文件导入、可读导出、知识编辑和备份会按操作实际读写，示例会话不写入正式会话库。2026-10-23 全面复核后的最新包已构建、解压并完成严格 ad hoc 签名校验，79 个构建源与当前源码零差异；最终新包的实窗重启检查未通过当前执行环境，尚未验收。修复与交付边界见[最新审查](../docs/product/macos/comprehensive-review/review.md)。此前视觉取舍、24 个组件场景与实窗交互证据见 [design-refresh](../docs/product/macos/design-refresh/README.md)；这些证据不替代正式 Native 集成验收。

可重复构建使用与 iOS 相同锁定 revision 的真实 iosMath：

~~~bash
macApp/scripts/build-preview-swiftpm.sh
~~~

仓库已有该 revision 的正常 checkout 时可以复用缓存：

~~~bash
macApp/scripts/build-preview-swiftpm.sh \
  --iosmath-path iosApp/build/ExperimentalDeviceBuild/SourcePackages/checkouts/iosMath
~~~

脚本校验依赖 revision，编译同源 SwiftUI 与真实公式组件，复制字体资源，并按 Preview 的 App Sandbox 权限签名。它不生成假的 Shared，也不解除应用沙盒。Xcode 可选择 AmberMacPreview scheme；受限环境中固定 SwiftPM manifest 缓存目录可能不可写，同源 SwiftPM 入口不依赖该目录。

## 当前实现边界

| 领域 | 已接线的行为 |
| --- | --- |
| 聊天 | 流式/停止/重试、编辑重发/删除/重生成/变体、按需加载历史、消息搜索定位、上下文预算/压缩、回顾/建议、原会话指令队列 |
| 模型 | OpenAI 兼容、Responses、Claude、Gemini；多模型、目录、参数及模型级 headers/body；原 Codex/Antigravity OAuth；独立辅助模型、视觉回退和标题生成 |
| 阅读与文件 | 中文 Markdown、列表/引用/表格、代码高亮、真实 iosMath；拖放/粘贴图片，PDF/DOCX/PPTX/RTF/文本解析预览；Workspace 与 Markdown/PDF/JSON 导出 |
| 工具 | 复用 IOSAgentToolEngine；工具发现、原 run 审批、持久事务、搜索、会话目录读写和本地命令；不自动重放结果未知的调用 |
| 外部服务与知识 | MCP HTTP/SSE/stdio、工具启停；Skills/SOUL/记忆与来源；技能可收紧工具范围 |
| 协作 | 有并发/超时/取消的文本子任务、模型议会各席位与综合、结果回原会话；Recipe 固定工具步骤共用审批与事务链 |
| 媒体 | 系统语音、声音/语速与消息朗读；OpenAI 兼容/Codex 生图复用原 repository，结果保存至原会话文件 |
| 数据与偏好 | 任务生命周期、可选通知、加密备份/副本恢复、WebDAV 快照、实际存储用量、字体/字号/主题/昵称/思考展开/跟随生成 |

当前整套共用 Swift Runtime **253 项测试通过**，正式 Swift 104 文件语法检查通过；之前的 KMP/JVM 隔离验证 **82 项通过**，本轮未重跑。各项实际 UI 和正式 Native 状态见[最新审查](../docs/product/macos/comprehensive-review/review.md)、validation.md 与 ios-parity-todo.md，不能用这些计数替代真实原生集成。

明确保留的差距包括子代理独立对话和工具/技能角色配置、议会多轮模式、SSH、固定产物架、单次请求覆盖、iOS 全量备份/CloudKit 互导，以及多语言和 Mac 订阅；这些没有用空入口冒充实现。

按约定排除小说创作、深度阅读、小应用、WebMount。手机控制、Watch、Live Activity、AlarmKit、iSH、嵌入式 Python 未搬入 Mac。

## 正式构建与验证

需要完整 Xcode/macOS SDK、XcodeGen、JDK 17 或 21，以及可正常构建 Kotlin/Native 的环境。在仓库根执行：

~~~bash
macApp/scripts/build.sh
macApp/scripts/build.sh test
CONFIGURATION=Release macApp/scripts/build.sh
~~~

正式应用路径为 macApp/build/Build/Products/Debug/Amber.app。XcodeGen 工程 macApp/AmberMac.xcodeproj 的 AmberMac scheme 连接真实 desktop-shared Mac framework，iOS 继续使用原 shared 模块。

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
