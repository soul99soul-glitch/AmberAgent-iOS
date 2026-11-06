# Amber macOS 记忆中心

## 使用

- macOS 应用：构建后的 `Amber.app` 内置 `memory_hub` v3 工作区视图；插件静态资源随应用打包，依靠宿主专用桥接访问记忆。
- 独立 Web 面板：在此工作树运行 `python3 macApp/tools/memory_hub_web.py --open`。服务仅绑定 `127.0.0.1`，启动时生成临时访问链接；停止进程后令牌失效。可用 `--port` 指定本机端口。Web 面板管理研发记忆；本机 Amber 对话记忆须在 Amber 内使用。
- 研发记忆默认 `default/amber`，可手动切换工作区和项目。面板使用本机已配置的 `ai-memory mcp-bridge --no-session-id`，不把服务凭据注入网页。需要本机已安装并配置 ai-memory。
- 页面保存使用读取时的版本 ID 防止覆盖其他设备的新改动；新建使用仅创建约束。删除、交接作废和版本恢复须在界面确认。列表默认显示最近 100 条，可搜索更早页面。
- Amber 本机记忆读取并修改 `DesktopKnowledgeStore`，来源原话只展示能从来源会话和消息 ID 找到的内容。污染状态显示共享会话存储已有标记，清理时只复位仍为 `polluted` 的记录，不更改已禁用会话。

## 已验证

- 指定工作树已更新到 `origin/main` 的 `b8a57b31`（fast-forward 检查）。
- `:desktop-shared:jvmTest --tests desktop.DesktopConversationRepositoryTest.pollutedConversationsAreListedAndResetWithoutEnablingDisabledConversations`：通过 1 项定点方法。
- `JAVA_HOME=/opt/homebrew/opt/openjdk@21 macApp/scripts/build.sh build`：Debug 构建通过，插件文件存在于生成的应用资源目录。
- 通过本机 Web HTTP 接口实际只读查询 `default/amber`，返回 200 和记录；未授权跨站请求返回 403。Arquiel 静态 lint 与 JavaScript 语法检查通过。

## 未完成的依赖和验证

- 当前 ai-memory 服务对该账号的 Checkpoint 查询返回“admin operation is root-only”；本机 CLI 的项目列表管理路由亦返回 403/404。未提权或改变凭据。历史恢复需要服务端管理员开放对应权限后再验证。
- 当前实际服务的 `memory_read_page` 对 `scope: profile` 返回 unknown scope。客户端保留 Profile 操作入口，但此服务端版本/权限尚不支持完整 Profile 管理；需要协调服务端能力后再验收。
- macOS 目前没有接入 iOS 的 Jev 自动提炼和自动污染标记链。面板可以管理 macOS 已存在的记忆与已存的污染标记，但不会自动生成这些标记或声称能展示不存在的证据。若目标包含自动提炼，需要另行移植并验证 macOS 运行链。
- 当前运行环境的 Synara 浏览器宿主不可用，原生窗口自动化返回 `cgWindowNotFound`，未能观察真实 WKWebView 画面。云端写入、删除、交接创建/作废和恢复未对真实用户数据执行端到端验证；只读联通不代表写操作已验收。
- 未运行整套 macOS 测试，也未安装或替换 `/Applications/Amber.app`，未提交、未推送。测试中原有未跟踪文件未改动。
