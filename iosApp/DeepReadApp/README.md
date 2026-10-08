# 深度阅读 iOS 应用

独立应用目标 `DeepRead`，模块 `AmberDeepRead`，Bundle ID `app.amber.deepread`。支持 iPhone 和 iPad，最低 iOS 26。应用使用自己的沙盒、设置和 Keychain service，不自动读取 AmberAgent 的文章或认证信息。

## 构建

从本仓库根执行：

```sh
xcodegen generate --spec iosApp/DeepReadApp/project.yml
xcodebuild -project iosApp/DeepReadApp/AmberDeepRead.xcodeproj \
  -scheme DeepRead -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

XcodeGen 工程是可重新生成的本地产物。`project.yml` 是工程定义。设备构建需在 Xcode 中设置开发团队和签名。

Swift 继续由本仓 Gradle 构建的 `Shared.framework` 提供 KMP 类型及 provider；Markdown 使用本仓 `AmberNative.xcframework`。这一步完成的是独立 application target 和功能装配，工程还依赖当前仓库中的共享源码与构建产物。

## 功能与使用

- 发现：原热榜来源、跨榜主题聚合、缓存、关键词过滤、Wi-Fi 刷新限制、可选标题翻译。
- 创建：主题、粘贴文本、多网页链接、多文件。文件支持 txt、md、json、csv、文本 PDF、DOCX 等；内容超过 40,000 字符时明确记录截断。扫描 PDF 无可提取文本时显示错误。
- 阅读库：完整本机历史、标题和正文搜索、任务状态筛选。
- 阅读器：原结构化杂志排版、原始来源与采集状态、失败与部分章节重试、保留段落和列表的文本/Markdown/PDF 分享，随系统深浅外观显示。
- 设置：多个模型和搜索服务、凭据保存、阅读字体字号、内置及自定义模板；支持模型生成模板草稿，再编辑、预览及保存。字号范围为 70%–180%；新建模板按手机宽度展示，并适配系统深色外观。

首次使用先在“设置”配置并选定阅读模型，点击“保存并应用”。当前模型入口支持 API Key 的 OpenAI 兼容 API（Chat Completions 或 Responses）与 Claude API。原应用的 OAuth 登录入口、Gemini 独立协议入口及 Live Activity 尚未迁入这个 application target。

搜索继续使用原 `IOSSearchExecutor`：免费聚合、Tavily、Exa、智谱、Brave、Serper、SerpAPI、Jina。原 Shared 搜索配置类型能够保存，执行器尚未实现的类型在界面中明确标注。免费搜索保留原多引擎并发、Google WebView 补充搜索、Jina Reader 正文补充读取及相关开关。阅读管线保留多角度查询、来源去重、正文及图片采集、分阶段生成。每个搜索角度使用已保存的结果数量设置；全部用户来源持久化，生成沿用最多 10 条有效来源的消费预算。补充搜索失败会保存并展示原因，重试只清理上一轮自动搜索警告。

文章任务由应用级 runtime 持有；离开页面不取消。iOS 后台执行为 best effort，系统期限到达时保存中断状态并释放执行权。冷启动保留已有文章、标记中断并提供重试，不宣称跨进程自动续生成。

## 验证

```sh
xcodebuild -project iosApp/DeepReadApp/AmberDeepRead.xcodeproj \
  -scheme DeepRead -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO test
```

独立测试覆盖：搜索配置和凭据恢复、采集查询与正文复用、文件解析、规划与四阶段生成、截断修复、缺失章节重试、旧稿保护、取消/系统过期/旧回调、模板拒写、字体资源和深浅阅读排版。真实 provider 的请求与文章质量、真机后台行为需要分别验收。

2026-10-03 验证结果：iPhone 17 Pro / iOS 26.5 模拟器构建及安装启动成功，57 个测试全部通过，其中包括本应用独立 Keychain 的真实写入、更新与删除，以及采集、分阶段生成和全部来源持久化的组合测试。已检查发现页真实热点加载、创建页多来源入口、阅读库、设置、模板编辑预览、iPad 布局和辅助功能大字号。修复后复核手机模板预览的宽度及深浅外观、来源说明的对比度，并使用临时验收文章确认 HTTPS 图片和搜索警告可见；验收文章随后移除。未使用真实模型凭据生成文章；真机后台及软件键盘交互尚未验收。

原 AmberAgent 的深度阅读、模板及存储回归共 80 项全部通过。扩展回归共 176 项，174 通过、1 跳过、1 个聊天长文滚动距离测试失败（36 pt 超过 24 pt 阈值）；该项单独复测仍失败（列表高度发布 61 pt 超过 40 pt 阈值），本轮未修改聊天滚动逻辑。
