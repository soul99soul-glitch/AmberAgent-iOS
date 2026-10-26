# Amber macOS 完成计划（本机接手后）

日期：2026-10-26。基线提交 `fc8fcfa`（feat/macos）。本机已能运行 Gradle 并产出真实 Shared.framework，正式 Amber.app 链接通过，Mac 测试 254/0。云端遗留的「正式 Native 未验」从本计划起逐项实测关闭。

执行方式：每个 phase 由并发 haiku 子代理执行，主 agent 规划、裁决并集成；phase 结束由独立子代理 review 逻辑闭环、调用链与 UI（错位/对齐/边距/尺寸），只修确认的问题，不加防御性兜底或新抽象。

## Phase 1 · 回归基线

- iOS：xcodegen + xcodebuild build-for-testing，跑受共享 Swift 改动影响的测试（AgentToolEngine、MCP、搜索、备份/WebDAV、图片生成、Codex OAuth）。
- KMP：被改的 20 个模块 `build.gradle.kts` + `settings.gradle.kts` 后，跑 `:shared` iOS framework 链接、desktop-shared jvmTest、受影响模块 JVM 测试，Android `:app` 编译。
- 修复回归，记录证据。

## Phase 2 · 正式 Native 端到端

- 启动正式 Amber.app（非 Preview），配置真实 Claude 兼容服务商，验证：发送→流式→完成、停止保留 partial、失败重试、退出重开后消息/分支/变体、标题生成。
- Keychain 写入/读取/删除实测；Agent 工具多轮（工作区读写、网页搜索/抓取、审批/拒绝）。
- 发现即修。

## Phase 3 · 沙盒与本地执行

- 实测正式 App 内 stdio MCP（用户 PATH 里的 npx/python）与本地 shell 工具。
- 决策：Amber 定位为 Developer ID 分发的桌面 Agent（与同类桌面 Agent 一致），正式 target 关闭 App Sandbox、保留 Hardened Runtime；用户 PATH 解析为登录 shell 环境。Preview 保持沙盒。
- SSH 执行环境：复用原生进程执行器，`/usr/bin/ssh` 目标主机配置，审批/日志/取消同本地执行。

## Phase 4 · 功能缺口

依据 iOS 实际实现复核后（SubAgentRunner、CouncilRunner、ChatArtifactShelfPanel、IOSMemoryExtractionCoordinator、IOSGrokOAuthClient、IOSSyncBackup）定稿：

| 项 | iOS 依据 | Mac 目标 |
| --- | --- | --- |
| 子代理 | `SubAgentRunner.runViaEngine`：每角色 allowlist ∩ 只读工具策略，独立 `IOSAgentToolEngine`、`subagent_report` 捕获、默认 Skill 注入，步骤存任务元数据 | `DesktopCollaborations` 成员改走同一 engine（复用 `DesktopEngineTransport`/执行器），角色 allowlist 与默认 Skill，步骤记录可在协作面板查看 |
| 模型议会 | `CouncilRunner`：freeChat/debate 两模式、1–5 轮顺序发言、主持人点评与终稿、动态席位规划、可选研究 | Mac run 增 mode/rounds；顺序轮次 + 主持人点评/综合；动态席位由主持模型规划 |
| 产物架 | `IOSPinnedSnippet` + `artifact-shelf.json`，锚点定位原消息 | 消息/代码块固定、按会话持久化、面板列表、点击 `DesktopTranscriptFocus` 定位 |
| 选定消息导出/系统分享 | `IOSConversationExporter` + 系统分享 | 消息菜单导出单条、NSSharingServicePicker |
| 长历史 | 时间线加载更早消息 | 单会话初始渲染尾部窗口、上滚加载更早 |
| 会话内查找 | 桌面适配 | ⌘F 查找、上下一个、定位 |
| 记忆自动提取 | 终态提交后 `IOSMemoryExtractionCoordinator.enqueue`，默认开启、日预算 | 生成完成后用辅助模型提取候选记忆并写入（带来源），设置可关 |
| Grok OAuth | `IOSGrokOAuthClient` + resolver，已接生产 | 编入 Mac target，xAI 服务商登录与请求解析 |
| iOS 备份导入 | `.amberbackup`：stored zip + PBKDF2/AES-GCM | 备份页导入 iOS 备份：解密、读取会话 JSON → Mac 新 UUID 副本 |

经核实 iOS 没有单次请求参数覆盖（输入区推理等级写的是助手级设置），Mac 不新造此项；原 TODO 降为「输入区推理等级切换写回当前模型配置」。

不做：小说创作、深度阅读、小应用、WebMount；Watch/Live Activity/NFC/AlarmKit；Mac StoreKit 订阅与 CloudKit（iOS 私有容器权益，无 Mac 侧契约）。iOS 全量备份互导按 iOS 备份格式评估，格式可读则实现导入。

## Phase 5 · 整窗 UI 矩阵与交付

- 实窗：860pt 最小 / 默认 / 宽窗 × 浅深色 × 空/长会话/流式/审批/队列/设置各 Tab，截图逐张 review，精准修复。
- Release 构建、签名检查、本地安装启动；更新 ios-parity-todo 与 README。

## 完成口径

每项关闭需：UI 入口、状态 owner/持久化、真实消费者、匹配证据（测试/实窗截图/实网请求）。验证日志写入 `docs/product/macos/completion/`。

## 执行记录（2026-10-26）

| Phase | 结果 | 证据 |
| --- | --- | --- |
| 1 回归 | KMP 18 模块 jvmTest 365/0、desktop-shared 37/0；iOS 受影响 19 类 302/0；iOS 全量 5081 项中 13 项失败集中在 PhoneControlSavedTasks/BottomOverlay（与本分支改动文件无交集，main 复核见下） | 本节 |
| 2 正式 Native | 修 KMP 回调继承 MainActor 崩溃（d6c9a8d）、未登记模型丢工具（8eecab3）；真实网关 E2E：发送/重开、停止保留 partial、审批→写文件→续轮 3/3 | LiveGatewayE2ETests |
| 3 沙盒 | 正式 App 关沙盒（Developer ID 分发），登录 PATH 一次读取、MCP 直接 spawn；真实 npx MCP 连通 | DesktopUserToolchainTests |
| 4 功能 | iOS 备份导入、产物架/会话内查找/单条导出分享、Grok OAuth、子代理只读工具循环、议会多轮/辩论/主持规划席位 | 各提交测试 |
| 5 视觉与交付 | 方向 1「琥珀含光」+ 宋体杂志感，主窗口/输入器/审批卡/Markdown/二级面板主题化；页面切换、发光滑动、入场、流式光边、按压/开关/复制动效，彩蛋 3 个；Release 构建签名可启动 | visual-v2/native-after |

Mac 测试最终 277/0（8 项为需环境变量的在线测试，默认跳过）。

仍需人工：真实 Grok/Codex 账号登录、系统通知授权与点击、Developer ID 签名与公证（需证书）。
