# 小说创作 iOS 应用

独立应用目标 `Novel`，产品 `AmberNovel`，显示名「小说创作」，Bundle ID `app.amber.novel`，支持 iPhone 与 iPad，最低 iOS 26。应用使用自己的沙盒、设置（UserDefaults suite `app.amber.novel.settings`）和 Keychain service（`app.amber.novel.credentials`），不读取 AmberAgent 的项目或凭据。

AmberAgent 里的小说创作保留不变，两个应用编译同一份 `iosApp/iosApp/NovelCreation/` 源码。

## 构建与测试

从仓库根执行：

```sh
xcodegen generate --spec iosApp/NovelApp/project.yml
xcodebuild -project iosApp/NovelApp/AmberNovel.xcodeproj -scheme Novel \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project iosApp/NovelApp/AmberNovel.xcodeproj -scheme Novel \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO test
```

`project.yml` 是工程定义，`.xcodeproj` 为本地生成物。构建前置脚本用本仓 Gradle 生成 `Shared.framework`，Markdown 解析链接本仓 `AmberNative.xcframework`。设备构建需在 Xcode 中设置开发团队。

模块名刻意设为 `iosApp`：`iosApp/iosAppTests/` 下的 45 个小说测试文件（含测试支持文件）以 `@testable import iosApp` 原样被本应用的 `NovelTests` 共享，不另维护副本。新增或删除小说测试文件时同步 `project.yml` 的 `NovelTests` 源列表。只依赖 Amber 自身设置存储的测试放在 `NovelAmberSettingsPresentationTests.swift`，不进入本应用；两边各有一份 `NovelTestSettingsFactory.swift` 提供测试用设置来源。

## 代码边界

- `Sources/App`：应用入口与 App 级持有者（创作视图模型、会话视图模型、后台生命周期协调器），对应 AmberAgent `AppShell` 中小说的那部分接线；`NovelAppToolHost` 为讨论 Agent 提供 Ask User、小说项目写工具和联网搜索，与 Amber `ChatToolRuntime.novelDiscussionToolExecutors` 同一工具集。
- `Sources/Settings`：模型服务（OpenAI 兼容含 Responses API、Claude、Gemini 的 API Key）、默认模型、联网搜索服务与结果数；保存后生成 KMP `Settings` 快照，通过 `IOSSettingsSnapshotSource` 供小说运行时与搜索执行器消费。
- `Sources/Design`：冷启动「开卷」动画（书页翻开、笔尖落墨、标语逐字出现；深夜、十一月写作月、元旦各有一句；点击跳过；开启减弱动态效果或旁白时不显示），以及设置页底部的关于区（1.2 秒内连点标记 5 次，墨点飞溅并逐字写出一句写作箴言）。
- `Sources/Support`：`IOSToolEffectClassMapping` 占位。本应用不给工具引擎挂运行账本，Amber 的完整分类表不需要编入。
- 共享源码清单见 `project.yml`。为让本应用不编译聊天、终端、MCP、小程序等子系统，原应用中小说依赖的小类型已原样搬到独立文件，原应用行为不变，例如 `AmberDesignSystem.swift`、`ChatAssistantMarkdownView.swift`、`ComposerDockComponents.swift`、`IOSSearchToolDispatch.swift`。依赖关系为：`NovelCreation` 只依赖 `IOSSettingsSnapshotSource` 与 `NovelDiscussionToolHost` 两个窄接口，Amber 与本应用各自提供实现（Amber 侧胶水在 `iosApp/iosApp/NovelCreationAmberBridge.swift`）。

## 数据与迁移

项目存放在本应用沙盒的 Application Support 中。要把 AmberAgent 里的已有项目带过来：在 AmberAgent 打开项目，于项目设置中「导出项目包」（`.ambernovel`，生成结束后可用），再在本应用的项目列表点「导入项目」选择该文件。两个应用都声明了同一个 `app.amber.ios.novel-project` 类型。

## 当前范围与限制

- 模型接入只支持 API Key。AmberAgent 的 Codex / Grok / Gemini Code Assist 等 OAuth 登录入口没有迁入；相关运行时代码仍编译在内，但本应用没有入口创建这类服务。
- 生成任务由应用级持有者负责，离开页面不会取消；iOS 后台执行属尽力而为，系统收回后台时间时保存中断状态，回到前台继续或提供重试。
- Live Activity、手表、记忆、工作区、终端等 Amber 能力不在本应用范围内。
- 只支持单窗口；iPad 不开启多窗口。
- 界面文案以中文为主，英文系统下独立应用自身的设置页仍显示中文。

## 验证

2026-10-03，在 iPhone 17e、iPad Air 11 英寸（iOS 26.5 模拟器）上验证：

- 构建、安装、冷启动成功；启动动画、深夜标语、点击跳过、设置提示卡片（iPad 居中）、深色模式均已目视确认。
- 用本机模拟的 OpenAI 兼容服务（`http://127.0.0.1`）走通「添加模型服务 → 新建项目 → 讨论」：请求携带所选模型、流式输出，以及 Ask User、联网搜索和全部小说项目工具；回复按 Markdown 正常渲染，重启后对话保留。
- 关于区彩蛋触发并显示箴言。
- 测试结果见本次交付说明。共享测试中有 12 项失败，在不含本次改动的 `HEAD` 上同样失败，属于既有问题，与拆分无关。

未覆盖：真实模型服务的长篇生成质量、真机后台续跑、软件键盘与中文输入法、VoiceOver 全流程。
