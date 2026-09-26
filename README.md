<p align="center">
  <img src="docs/assets/readme/social-preview.png" width="100%" alt="AmberAgent for iOS：Models. Tools. Workflows. 品牌分享图">
</p>

<h1 align="center">AmberAgent for iOS</h1>

<p align="center">原生 iPhone / iPad AI 助手，模型自己选，工具执行需要你点头。</p>
<p align="center"><sub>A native AI assistant for iPhone and iPad, with configurable models, approval-based tools, and an Apple Watch companion.</sub></p>
<p align="center"><sub>SwiftUI · Kotlin Multiplatform · iOS 26+ · watchOS 11+</sub></p>

<p align="center">
  <a href="#功能">功能</a> ·
  <a href="#上手">上手</a> ·
  <a href="#数据与隐私">数据与隐私</a> ·
  <a href="#构建">构建</a> ·
  <a href="#许可与反馈">许可与反馈</a>
</p>

<p align="center">
  <img src="docs/assets/readme/iphone/home.png" width="230" alt="iPhone 对话首页，展示最近会话与工作入口">
  <img src="docs/assets/readme/iphone/chat.png" width="230" alt="iPhone 聊天界面，展示对话、Markdown 表格和输入区">
  <img src="docs/assets/readme/iphone/providers.png" width="230" alt="iPhone 模型服务商设置列表">
</p>
<p align="center"><sub>首页 · 聊天 · 服务商设置<br>iPhone 17 Pro / iOS 27 模拟器截图，对话内容为演示数据（<a href="docs/assets/readme/iphone/README.md">截图说明</a>）</sub></p>

## 功能

### 聊天

- 流式输出，支持 Markdown、代码块和多轮工具调用
- 拍照、从相册选图或从“文件”App 附加文件，发送前可以移除
- 消息可编辑、删除、重新生成，同一条回答的多个版本可以来回切换
- 当前模型不支持图片时，可以单独指定一个视觉模型

### 模型服务

不绑定厂商。OpenAI 兼容接口、Gemini、Claude 都能接，模型列表可以拉取也可以手填。聊天和各类辅助任务可以用不同的模型。

App 不附带任何模型账号，需要填你自己的 API Key 和接口地址。

### 工具与审批

Agent 能搜索、读文件、管理 Workspace、调用你接好的外部服务。每类能力都有开关；敏感操作执行前会在聊天里列出要做什么，由你批准或拒绝。被拒绝、失败或中断的调用都会留在记录里。

### 子代理、技能与 MCP

<p align="center">
  <img src="docs/assets/readme/iphone/subagents.png" width="260" alt="iPhone 子代理并发、进度与角色设置">
  <img src="docs/assets/readme/iphone/skills.png" width="260" alt="iPhone 本机技能列表与扩展入口">
</p>

- **子代理**：把独立的活儿交给一个角色去做，比如查资料，你在原对话里继续。进度显示在输入框上方，结果回到原对话。并发数、超时，以及每个角色的提示词、模型、工具和默认技能都能改。
- **技能**：以本地文件保存，可以启用、编辑，并分配给子代理角色。
- **MCP**：手动添加或导入服务器，支持 Streamable HTTP 和 SSE，服务器和单个工具都能单独开关。

子代理能用的工具同样受能力开关和审批规则约束。

### Deep Read 与 Workspace

<p align="center">
  <img src="docs/assets/readme/iphone/deep-read.png" width="290" alt="iPhone Deep Read 演示文章的标题、段落与要点排版">
</p>

**Deep Read** 把一个主题整理成一篇能读下去的长文。材料可以是手动粘贴的文字、当前对话、搜索结果、你选的文件，或 WebMount 里打开的网页。成文包含摘要、时间线、关键脉络、图解、分析、延伸阅读和来源，可以存进 Workspace。

**Workspace** 放你导入的文件和 App 生成的内容，聊天、工具、Mini App、Deep Read 都往这里写。单个文件上限 20 MB，可预览 txt、md、json、csv、pdf、docx 等格式。

### WebMount 浏览器

<p align="center">
  <img src="docs/assets/readme/iphone/webmount.png" width="290" alt="iPhone WebMount 浏览器站点与 Agent 浏览任务">
</p>

在 App 内打开你添加的站点，Agent 可以读取页面、在限定范围内操作。整个过程你都能看到，随时可以接手；遇到登录、验证码、支付会停下来交给你。

也能连接远程桌面浏览器，前提是对应的 MCP 服务有一个 iPhone 能访问到的 HTTPS 地址。

### Mini App

在聊天里描述一个小工具，比如计时器或信息看板，AmberAgent 会生成一个本地 Mini App。每个 Mini App 有自己的版本、授权和调用记录。联网搜索、HTTPS 请求、AI 生成、剪贴板等能力逐项申请；访问本机或内网地址的请求会被拦下。

### 模型议会

把一个问题交给多个席位讨论，最后由主持流程汇总结论。每个席位可以配不同的模型、角色和讨论方式，也可以让系统自动组队。可选开启联网调研（需要先配置搜索服务，会更慢、调用更多）。讨论记录可以回看。

### 小说创作

一个小说项目包含世界观、人物、大纲、章节、创作对话和剧情状态，分讨论、正文、设定三个入口。

- **分支**：从任意检查点开一条新剧情线，原线不动；每章都有版本记录
- **共创与代笔**：共创模式下，AI 给出的故事种子、设定和候选正文要你确认才会写入；代笔模式按确认过的章节合同往下写
- **长篇维护**：人物与世界观管理、章节计划、连续性检查、单章或批量润色
- **导入导出**：整个项目可以打包迁移；写作和审阅可以用不同模型

### Apple Watch

<p align="center">
  <img src="docs/reviews/assets/amber-watch-typographic/home-46mm.jpg" width="210" alt="Apple Watch AmberAgent 首页，展示最近任务与快捷提问入口">
</p>

在手表上看最近任务的进度和结果，或者快速问一句。会话、模型和工具都跑在配对的 iPhone 上。

## 上手

1. **接入模型**：设置 → 服务商，选一家，填 API Key 和接口地址（部分服务商支持直接登录）。
2. **选默认模型**：拉取或手动添加模型，在“模型与提示词”里设好聊天默认模型，回首页就能开聊。
3. **按需加能力**：要联网就配搜索服务，要外部工具就加 MCP 服务器，要分工就设置子代理角色。

## 数据与隐私

- 会话保存在本机 `Documents/conversations` 下的 JSON 文件里，不进系统备份
- Workspace 文件保存在 App 本地目录
- 服务商 API Key 和 MCP 的凭据类请求头存放在系统 Keychain
- 对话内容、图片和上下文只发给你选定的模型服务商；搜索和 MCP 请求只发往你配置的服务

## 已知限制

- 项目仍在开发中
- 切到其他 App 后，后台还能跑多久由 iOS 决定
- 部分工具需要先打开能力开关、授予系统权限或连上外部服务才能用

## 构建

环境：macOS、带 iOS 26 SDK 的 Xcode、XcodeGen、JDK 17。

Xcode 工程由 `iosApp/project.yml` 生成，不入库。两个 scheme 都会调用本仓的 Gradle 工程构建并嵌入 `Shared.framework`（KMP 目前仍是本仓内的过渡实现）。

**`iosApp`**：常规 scheme，包含 iPhone/iPad、Watch、Widget 和 CPython 集成。以 Apple Silicon Mac 构建模拟器版本为例：

```bash
# 首次需要准备固定版本的 CPython iOS 制品
iosApp/scripts/prepare-ambershell-python.sh

(cd iosApp && xcodegen generate)

xcodebuild -project iosApp/AmberAgent.xcodeproj \
  -scheme iosApp -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO build
```

**`iosAppExperimentalGPL`**：实验 scheme，使用独立的 bundle ID 和 entitlement，额外集成 iSH 运行时和 `IshEmbed`。同样依赖上面的 CPython 制品：

```bash
xcodebuild -project iosApp/AmberAgent.xcodeproj \
  -scheme iosAppExperimentalGPL -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO build
```

只构建共享框架：

```bash
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
```

### 仓库结构

| 路径 | 内容 |
| --- | --- |
| [`iosApp/`](iosApp/) | SwiftUI 应用、Watch App、Widget、XcodeGen 配置 |
| [`shared/`](shared/) · [`ai-core/`](ai-core/) · [`ai-provider-openai/`](ai-provider-openai/) · [`ai-provider-claude/`](ai-provider-claude/) | KMP 共享层与各 provider 实现 |
| [`core/`](core/) · [`feature/`](feature/) | 过渡期的共享能力与功能模块 |
| [`native/`](native/) | 原生组件与 iOS framework |

## 许可与反馈

本仓采用分段双重许可，适用条件按用途和用户规模区分，商业使用需另行授权。使用、修改或分发前请先读 [LICENSE](LICENSE)。

问题和建议请提到 [Issues](https://github.com/soul99soul-glitch/AmberAgent-iOS/issues)，并附上 iOS 版本、App 版本、复现步骤和预期结果；截图和日志请先去掉个人信息和密钥。提交代码请遵守 [AGENTS.md](AGENTS.md)，并附上对应的验证结果。
