# Amber macOS 插件体系架构设计（`amber.plugin.v3`）

> 状态：第一波已实现（Wave 1 Implemented） · 第二波已设计（Wave 2 Designed）
> 基线分支：`synara/expand-macos-plugin-capabilities`（基于 `6fb96c14`）
> 目标：对标 Obsidian Plugin API，在保持 Amber 安全边界与高风险工具门禁的前提下，将 macOS 插件从纯声明式（`amber.plugin.v2`）升级为支持自定义 WebView 界面、双向 Promise RPC 桥、后台常驻生命周期与细粒度权限模型的 `amber.plugin.v3`。

---

## 一、背景与设计目标

在 `amber.plugin.v2` 中，插件能力局限于：
- `workspaceViews` 仅支持 `{ id, title, symbol, subtitle }` 四个声明字段，主画布只能由宿主渲染固定标题与快捷命令列表，无法承载自定义 DOM 或交互组件（例如拖拽看板、可视化图表、分栏编辑器）；
- `inspectorCards` 仅支持静态键值快照；
- 每次工具执行都在临时新建的 `JSContext` 中同步跑完即销毁，没有后台常驻脚本生命周期（`onload` / `onunload`），也不支持动态注册工具、命令或监听会话/文件/主题事件。

`amber.plugin.v3`（第一波）的核心目标：
1. **自定义界面（Custom WebView Surfaces）**：支持插件通过 `WKWebView` 注册主工作区标签页（`workspace`）、左右侧栏面板（`left_sidebar` / `right_sidebar`）、右侧检查器面板（`inspector`）、模态弹窗（`modal`）与自定义设置页（`settings`）。支持包内任意静态前端资源（HTML/CSS/JS），自动同步宿主亮暗色主题与 Amber「琥珀含光 · 2.0」CSS 变量 token。
2. **Promise 风格 JS API 桥（`window.amber.*` & 后台 `amber.*`）**：基于 `WKScriptMessageHandler` 与统一 RPC 调度器（`DesktopPluginBridgeDispatcher`），提供 `storage`、`workspace`、`http`、`commands`、`events`、`ui`、`agent`、`settings` 八大命名空间。
3. **常驻生命周期与热重载（Lifecycle & Hot Reload）**：提供独立于视图的后台常驻主脚本运行时（`onload` / `onunload`），以及开发模式下的文件监听自动热重载。
4. **细粒度权限与高风险门禁（Permission & High-Risk Gate）**：Manifest 显式声明所需权限（如 `ui.views`、`workspace.read`、`workspace.write`、`http:<domain>`、`agent.tools`、`storage`），安装与升级时生成人类可读的中文权限说明由用户批准；未声明即调用当场拒绝；凡涉及写工作区或外部 HTTP 变更的插件 Agent 工具一律纳入高风险（High Risk）门禁。
5. **零回归向下兼容**：`amber.plugin.v2` 与 `amber.plugin.v1` 插件无需修改即可继续运行。

---

## 二、Manifest Schema（`plugin.json`）

### 2.1 版本区分与兼容规则

宿主通过以下规则识别插件协议版本：
- **`amber.plugin.v3`**：当 `schema == "amber.plugin.v3"`，或 `manifest_version == 3`，或 `version` 主版本为 `3.x` 且包含 v3 扩展字段（`permissions`、带 `entry`/`html` 的自定义视图）时，按 v3 协议加载。
- **`amber.plugin.v2` / `amber.plugin.v1`**：当 `schema` 为 `"amber.plugin.v2"`（默认）或 `"amber.plugin.v1"` 且未声明 `manifest_version: 3` 时，保持 v2 行为不变。

### 2.2 `amber.plugin.v3` 完整 Schema 示例

```json
{
  "schema": "amber.plugin.v3",
  "manifest_version": 3,
  "id": "kanban-board",
  "name": "任务看板 (Kanban Board)",
  "version": "3.0.0",
  "description": "可拖拽分列看板，支持持久化到工作区 JSON 与 Markdown 文件，并提供智能体读写工具。",
  "icon": "rectangle.split.3x1",
  "main": "main.js",
  "dev_reload": true,
  "permissions": [
    "ui.views",
    "storage",
    "workspace.read",
    "workspace.write",
    "agent.tools",
    "commands",
    "events",
    "settings"
  ],
  "capabilities": {
    "networkDomains": [],
    "workspaceReadPrefixes": ["kanban/"],
    "workspaceWritePrefixes": ["kanban/"]
  },
  "settings_schema": [
    {
      "key": "board_file",
      "title": "工作区看板文件路径",
      "kind": "string",
      "defaultValue": "kanban/board.json",
      "help": "看板数据在当前会话工作区中的持久化 JSON 路径。"
    },
    {
      "key": "markdown_mirror",
      "title": "同步导出 Markdown 看板",
      "kind": "string",
      "defaultValue": "kanban/BOARD.md",
      "help": "每次看板变更时自动同步生成的 Markdown 文件路径。"
    }
  ],
  "tools": [
    {
      "name": "kanban_list_cards",
      "description": "读取看板所有列与卡片数据。",
      "effect": "pure",
      "entry": "kanbanListCards",
      "input_schema": {
        "type": "object",
        "properties": {
          "column": { "type": "string", "description": "可选列 ID 过滤（todo / doing / done）" }
        },
        "additionalProperties": false
      }
    }
  ],
  "ui": {
    "views": [
      {
        "id": "kanban_main",
        "title": "项目看板",
        "slot": "workspace",
        "symbol": "rectangle.split.3x1",
        "subtitle": "拖拽卡片流转状态，自动同步工作区 JSON 与 Markdown。",
        "entry": "index.html"
      },
      {
        "id": "kanban_inspector",
        "title": "看板概览",
        "slot": "inspector",
        "symbol": "rectangle.split.3x1",
        "entry": "index.html?slot=inspector"
      }
    ],
    "commands": [
      {
        "id": "open_kanban",
        "title": "打开项目看板",
        "slash": "/kanban",
        "symbol": "rectangle.split.3x1",
        "prompt_template": "请调用看板工具查看当前项目看板进度，并梳理进行中与待办任务："
      }
    ]
  }
}
```

### 2.3 字段规范说明

右侧栏／检查器默认提供方形展开态和约 60 点、18 点圆角的 mini 收起态。未声明 `compact_height` 的旧 WebView 保持挂载但在收起时隐藏，mini 显示清单标题、真实启用状态和打开入口；页面内容在展开态可滚动。插件可声明 `compact_height`（48–160 点）提供自定义 mini，宿主通过根节点的 `data-amber-presentation` 通知同一文档变形；`aspect_ratio`（宽 ÷ 高，0.5–2）可调整展开比例，默认 1:1。收起态左侧空白区域可展开，右侧预留 52 点给插件自己的交互控件；进度横道只在确有可用数据时显示。

需要在两态间连续移动的同一 DOM 元素可标记 `data-amber-morph`；宿主桥在切换时按元素的新旧位置执行约 240ms 的可打断过渡，不复制业务节点。系统启用减少动态效果时跳过位移和缩放。插件仍需自行处理次要内容、搜索面板淡变及焦点，并确保没有数据时不显示进度占位。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schema` | `string` | 否 | `"amber.plugin.v3"`（兼容 `"amber.plugin.v2"` / `"amber.plugin.v1"`）。 |
| `manifest_version` | `integer` | 否 | 协议主版本号，v3 插件填 `3`。 |
| `id` | `string` | 是 | 2–32 位小写字母、数字、下划线或连字符（`^[a-z][a-z0-9_-]*$`，不以 `-` 结尾、不含连续 `--`）。保留 ID：`feishu_calendar`、`apple_schedule`、`watchtower`。 |
| `name` / `version` / `description` | `string` | 是 | 插件显示名称、语义化版本号与功能简介。 |
| `main` | `string` | 否 | 后台常驻脚本相对路径，默认 `"main.js"`。 |
| `dev_reload` | `boolean` | 否 | 开发模式下是否监听插件目录文件变更并自动热重载，默认 `false`。 |
| `permissions` | `string[]` | 否 | v3 权限声明列表（见第三节权限矩阵）。 |
| `capabilities` | `object` | 否 | 细粒度路径前缀与域名白名单：`networkDomains`、`workspaceReadPrefixes`、`workspaceWritePrefixes`。若 `permissions` 中包含 `"http:<domain>"`、`"workspace.read:<prefix>"`、`"workspace.write:<prefix>"`，解析时会自动合并入 `capabilities`。 |
| `ui.views` | `array` | 否 | v3 自定义视图列表，每项支持 `{ id, title, slot, symbol, subtitle, entry, width, height }`。`slot` 取值：`workspace`（主区标签页）、`left_sidebar`（左侧栏面板）、`right_sidebar`（右侧栏面板）、`inspector`（检查器面板）、`modal`（模态弹窗）、`settings`（自定义设置页）。同时向下兼容 `ui.workspaceViews` 与 `ui.inspectorCards`。 |

---

## 三、权限模型与审批矩阵（Permission Model）

### 3.1 权限标识符与人类可读映射

| 权限声明 (`permissions`) | 人类可读名称 | 详细说明（安装/升级弹窗与设置页展示） | 风险等级 | 未声明时调用的后果 |
| --- | --- | --- | --- | --- |
| `ui.views` | 自定义界面视图 | 允许插件在主工作区、侧栏、检查器或模态弹窗中渲染受控 WebView 界面。 | 普通 | 拒绝挂载 WebView 并拒绝 `amber.ui.openView` / `openModal`。 |
| `storage` | 插件私有键值存储 | 允许插件读写专属 `storage.json` 持久化状态（与其他插件及工作区隔离）。 | 普通 | 调用 `amber.storage.*` 立即抛出未声明权限错误。 |
| `workspace.read`（或 `workspace.read:<prefix>`） | 读取会话工作区文件 | 允许读取当前会话工作区内已授权前缀（默认工作区根或指定子目录）下的文件与目录列表。 | 普通 | 调用 `amber.workspace.read` / `list` / `watch` 立即拒绝。 |
| `workspace.write`（或 `workspace.write:<prefix>`） | 写入会话工作区文件 | 允许在当前会话工作区内已授权子目录创建、修改或保存文件。 | **高风险** | 调用 `amber.workspace.write` / `delete` 立即拒绝。 |
| `http:<domain>` | 访问指定外部域名 | 允许通过 `amber.http.fetch` 或 WebView 受控连接访问 `https://<domain>`（含子域名）。 | **高风险**（写请求）/ 普通（只读） | 未声明域名或非 HTTPS 请求当场拦截。 |
| `agent.tools` | 智能体工具与会话桥接 | 允许动态注册 Agent 工具、读取当前对话消息摘要、向输入框插入草稿。 | **高风险**（含写工具时） | 调用 `amber.agent.*` 立即拒绝。 |
| `commands` | 注册命令与斜杠指令 | 允许向 `/` 补全浮层与 `⌘K` 命令面板动态注册命令。 | 普通 | 调用 `amber.commands.register` 立即拒绝。 |
| `events` | 订阅宿主事件通知 | 允许监听会话切换、新消息、工作区文件变更与亮暗色主题切换事件。 | 普通 | 调用 `amber.events.on` 立即拒绝。 |
| `settings` | 读写插件配置项 | 允许读取非敏感配置项（`secret` 凭据始终隔离在钥匙串中，不进入 JS）。 | 普通 | 调用 `amber.settings.get` / `set` 立即拒绝。 |

### 3.2 安装与升级时的用户批准流程

1. **安装前预检（`inspectPluginPackage(at:)`）**：
   - 解析并校验 `plugin.json`，汇总该插件申请的全部权限条目，生成结构化中文审批清单 `[DesktopPluginPermissionDescriptor]`。
   - 若为已安装插件的升级版本，对比已批准的权限集合（持久化于 `UserDefaults` `desktop.plugins.approvedPermissions.v3.<pluginID>`），高亮标注「新增申请的权限」。
2. **明确批准后落盘**：
   - 在设置页通过 UI 导入时，弹出权限确认卡片，列出每项权限的中文标题、用途说明与高风险标记，用户点击「批准并安装」后才写入已批准权限表并启用插件。
   - 若插件在升级后新增了未经批准的权限，在用户重新批准前，未批准的权限调用会被权限守卫（Capability Guard）直接拒绝。

### 3.3 Agent 工具高风险门禁规则

插件（无论是通过 `plugin.json` 的 `tools` 静态声明，还是通过 `amber.agent.registerTool` 动态注册）向智能体暴露的工具，遵循以下强制分级：
- **只读工具（`effect: "pure"` 或 `"networkRead"`）**：
  - 免人工审批直接执行；
  - 运行期沙箱强制锁定：**严禁调用 `amber.workspace.write`、`amber.workspace.delete` 以及非 `GET`/`HEAD` 的 `amber.http.fetch`**。一旦越权调用，当场报错终止。
- **写入/变更工具（`effect: "sideEffect"` 或 `"idempotent"`，或未显式声明为只读的动态工具）**：
  - `DesktopToolRegistry.isHighRisk("plugin__<pluginID>__<toolName>")` 恒为 `true`；
  - **普通「自动批准工具」开关不能放行**（仅当用户显式开启高风险自动批准或在 Mac 主窗口手动点「批准」时才放行）；
  - **系统通知横幅、锁屏界面、手机端 Gateway 远程审批卡片对高风险插件工具只能拒绝（Deny）、绝不能批准（Approve 返回 403 / false）**。

---

## 四、JS API 清单与桥协议（Bridge Protocol）

### 4.1 统一 RPC 消息协议（`WKScriptMessageHandler` + Promise）

在 `WKWebView` 中，宿主通过 `WKUserContentController` 注册名为 `amberBridge` 的 `WKScriptMessageHandler`，并在 `atDocumentStart` 注入 `window.amber` 客户端 SDK：

1. **请求（WebView JS → Swift Host）**：
   ```json
   {
     "requestId": "req_1",
     "pluginId": "kanban-board",
     "viewId": "kanban_main",
     "namespace": "workspace",
     "method": "write",
     "args": ["kanban/board.json", "{\"columns\":[]}"]
   }
   ```
2. **响应（Swift Host → WebView JS）**：
   - 成功：`window.__amberBridgeResolve("req_1", <resultJSON>)`
   - 失败：`window.__amberBridgeReject("req_1", "插件未声明权限 workspace.write")`
3. **事件推送（Swift Host → WebView JS & 后台常驻 `JSContext`）**：
   - `window.__amberBridgeEmit("<eventName>", <payloadJSON>)`

### 4.2 `window.amber.*` 与后台 `amber.*` API 清单

| 命名空间 | 方法签名 | 所需权限 | 行为与返回值说明 |
| --- | --- | --- | --- |
| **`storage`** | `amber.storage.get(key)` | `storage` | 读取插件专属 `storage.json` 中的键（不存在返回 `""`）。WebView 中返回 `Promise<string>`，后台脚本同时兼容同步读取与 `await`。 |
| | `amber.storage.set(key, value)` | `storage` | 写入键值（对象自动 JSON 序列化），原子落盘并广播 `storage:changed` 事件。 |
| | `amber.storage.remove(key)` | `storage` | 删除指定键并落盘。 |
| | `amber.storage.keys()` / `all()` | `storage` | 返回所有键名数组或完整键值字典。 |
| **`workspace`** | `amber.workspace.read(path)` | `workspace.read` | 读取会话工作区内授权前缀下的 UTF-8 文本文件。 |
| | `amber.workspace.write(path, content)` | `workspace.write` | 原子写入会话工作区内授权前缀下的 UTF-8 文件（自动创建父目录），触发 `workspace:changed` 事件。 |
| | `amber.workspace.list(path?)` | `workspace.read` | 列出工作区授权子目录下的文件与文件夹条目 `[{ name, path, isDirectory, size, modifiedAt }]`。 |
| | `amber.workspace.watch(prefix, callback)` | `workspace.read` | 监听工作区子目录文件变更，变更时回调 `{ path, event }`，返回取消监听函数。 |
| **`http`** | `amber.http.fetch(url, options?)` | `http:<domain>` | 受控 HTTPS 请求（20s 超时），仅允许已声明域名及其子域名，返回 `{ ok, status, body, text, json }`。 |
| **`commands`** | `amber.commands.register(cmd)` | `commands` | 动态注册命令 `{ id, title, slash, symbol, promptTemplate, callback }`，注入 `/` 补全与 `⌘K` 面板。 |
| | `amber.commands.list()` | `commands` | 列出当前插件已注册的所有命令。 |
| **`events`** | `amber.events.on(event, handler)` | `events` | 订阅宿主事件：`conversation:changed`、`message:received`、`workspace:changed`、`theme:changed`、`storage:changed`、`settings:changed`。 |
| | `amber.events.off(event, handler)` | `events` | 取消订阅事件。 |
| | `amber.events.emit(event, payload)` | `events` | 在同一插件的后台主脚本与各挂载 WebView 之间广播自定义事件。 |
| **`ui`** | `amber.ui.notice(message, kind?)` | `ui.views`（可选） | 在宿主窗口显示轻量通知横幅（`info` / `success` / `warning` / `error`）。 |
| | `amber.ui.confirm(options)` | `ui.views` | 弹出确认框 `{ title, message, confirmText, cancelText }`，返回 `Promise<boolean>`。 |
| | `amber.ui.openView(viewId, state?)` | `ui.views` | 切换或打开插件注册的视图（主区标签页、侧栏、检查器或模态弹窗）。 |
| | `amber.ui.closeModal()` | `ui.views` | 关闭当前打开的插件模态弹窗。 |
| **`agent`** | `amber.agent.registerTool(toolDef)` | `agent.tools` | 动态注册智能体工具 `{ name, description, effect, inputSchema, execute }`，执行体在插件 JS 运行时内运行。 |
| | `amber.agent.getConversation()` | `agent.tools` | 读取当前选中会话的只读摘要 `{ id, title, messageCount, messages: [{ id, role, content }] }`。 |
| | `amber.agent.insertToComposer(text)` | `agent.tools` | 将文本插入或追加到当前对话输入框草稿中。 |
| **`settings`** | `amber.settings.get(key)` | `settings` | 读取插件非敏感配置项值（`secret` 字段绝不暴露给 JS）。 |
| | `amber.settings.set(key, value)` | `settings` | 更新插件非敏感配置项并持久化到 `UserDefaults`。 |
| | `amber.settings.getAll()` | `settings` | 返回当前插件所有非敏感配置字典。 |

---

## 五、安全边界与主题融合（Security & Theme Integration）

### 5.1 WebView 资源隔离与 CSP 策略

1. **自定义协议 `amber-plugin://<pluginID>/<path>`**：
   - 插件 `WKWebView` 一律通过 `DesktopPluginURLSchemeHandler` 加载 `amber-plugin://<pluginID>/<entry>`，**禁用 `loadFileURL` 与任何 `file://` 导航**，从根源杜绝利用符号链接或相对路径读取宿主机任意本地文件。
   - Scheme Handler 内部使用规范化路径与逐级符号链接检测（与 `resolveAuthorizedWorkspaceFileURL` 同级防护），只允许读取当前插件安装目录下的静态资源。
2. **强制 Content Security Policy (CSP)**：
   - 宿主在返回的每个 HTML 文档头部自动注入 CSP：
     ```http
     default-src 'self' amber-plugin:;
     script-src 'self' 'unsafe-inline' amber-plugin:;
     style-src 'self' 'unsafe-inline' amber-plugin:;
     img-src 'self' data: blob: amber-plugin: <已声明的 https://domain>;
     connect-src 'self' amber-plugin: <已声明的 https://domain>;
     font-src 'self' data: amber-plugin:;
     frame-src 'none';
     object-src 'none';
     base-uri 'self' amber-plugin:;
     ```
   - `WKNavigationDelegate` 拦截一切跳出 `amber-plugin://<pluginID>/` 的顶层或子框架导航请求。
3. **非持久独立数据存储（DataStore Isolation）**：
   - 每个插件 `WKWebView` 使用 `WKWebsiteDataStore.nonPersistent()`，禁止跨插件共享 Cookie 或缓存，所有持久化数据必须走受权限管控的 `amber.storage` 或 `amber.workspace`。

### 5.2 宿主主题与 Amber 设计 Token 注入

宿主在 `WKWebView` 文档初始化及系统外观变化时，自动设置 `document.documentElement.dataset.theme = "light" | "dark"` 并注入 `AmberTheme` CSS 变量：

| CSS 变量名 | 浅色模式（Light） | 深色模式（Dark） | 语义 |
| --- | --- | --- | --- |
| `--amber-paper` | `#FAF8F3` | `#161512` | 主画布暖羊皮纸背景 |
| `--amber-paper-side` | `#F3F0E8` | `#1B1916` | 侧栏与次级面板背景 |
| `--amber-paper-deep` | `#EFECE3` | `#22201C` | 槽位、代码块与胶囊底色 |
| `--amber-hover` | `#EAE6DB` | `#282520` | 悬停态背景 |
| `--amber-card` | `#FFFFFF` | `#1E1C18` | 卡片表面背景 |
| `--amber-field` | `#FFFFFF` | `#22201C` | 输入框表面背景 |
| `--amber-ink` | `#191815` | `#F0EDE6` | 一级正文墨色 |
| `--amber-ink-secondary` | `#45433D` | `#C6C2B8` | 二级正文墨色 |
| `--amber-ink-tertiary` | `#68645C` | `#9E998E` | 三级辅助文字墨色 |
| `--amber-hairline` | `rgba(25,24,21,0.085)` | `rgba(255,248,235,0.08)` | 细分割线边框 |
| `--amber-hairline-strong` | `rgba(25,24,21,0.14)` | `rgba(255,248,235,0.14)` | 卡片与控件强边框 |
| `--amber-accent` | `#A65E26` | `#DAA972` | 琥珀主强调色 |
| `--amber-accent-ink` | `#784012` | `#ECCB9E` | 琥珀深色/高亮文字 |
| `--amber-honey-soft` | `rgba(222,150,72,0.12)` | `rgba(213,160,100,0.11)` | 琥珀柔光底色 |
| `--amber-honey-edge` | `rgba(166,94,38,0.30)` | `rgba(218,169,114,0.32)` | 琥珀描边高光 |
| `--amber-danger` | `#B3261E` | `#E5736B` | 危险/删除语义色 |
| `--amber-success` | `#2A7B4C` | `#68C78E` | 成功/完成语义色 |

---

## 六、与 Obsidian Plugin API 的能力对照表

| 能力维度 | Obsidian Plugin API | Amber `amber.plugin.v2` | Amber `amber.plugin.v3`（第一波已实现） | 差距与第二波规划（Wave 2） |
| --- | --- | --- | --- | --- |
| **自定义视图槽位** | `registerView`（WorkspaceLeaf 主区、左右侧栏、浮窗） | 仅主区静态标题+命令列表，无自定义 DOM | **已对齐**：支持 `workspace`、`left_sidebar`、`right_sidebar`、`inspector`、`modal`、`settings` 六类 `WKWebView` 槽位 | Wave 2 支持多标签分屏拖拽停靠（Split Leaf Docking） |
| **模态弹窗与通知** | `Modal`、`Notice` | 无 | **已对齐**：支持 `amber.ui.openModal`、`amber.ui.confirm`、`amber.ui.notice` | Wave 2 支持 `SuggestModal` 模糊搜索选择器 |
| **文件读写与监听** | `app.vault.read / modify / create / delete / adapter.list` + `vault.on('modify')` | 仅工具执行期同步 `read` / `write`，无 `list` / `watch` | **已对齐**：`amber.workspace.read / write / list / delete / watch`，严格限定在会话工作区授权前缀内 | Wave 2 支持二进制文件流与跨会话共享知识库 Vault 挂载 |
| **插件私有存储** | `loadData()` / `saveData()` (`data.json`) | `amber.storage.get / set` | **已对齐**：`amber.storage.get / set / remove / keys / all`（Promise + 同步双模） | 已完全满足 |
| **命令与快捷键** | `addCommand`（命令面板） | 仅 `plugin.json` 静态声明 `ui.commands` | **已对齐**：支持静态声明 + `amber.commands.register` 动态注册 `/` 斜杠指令与 `⌘K` 面板动作 | Wave 2 支持自定义全局快捷键绑定（Hotkeys） |
| **生命周期与后台脚本** | `Plugin.onload()` / `onunload()` | 无（仅调用工具时临时创建 `JSContext`） | **已对齐**：后台常驻 `main.js` 实例，支持 `onload()` / `onunload()` 与开发模式自动热重载 | 已完全满足 |
| **AI 智能体协同** | 无原生内置（需第三方插件） | 静态声明 `tools` | **超越 Obsidian**：原生支持静态与 `amber.agent.registerTool` 动态注册工具、读取当前会话、写入输入框，并集成高风险审批流与远程手机拒批门禁 | Wave 2 支持插件注册自定义 Context Provider 与 Prompt 钩子 |
| **安全与权限隔离** | 无沙箱（Electron Node.js 全盘权限，社区插件有供应链风险） | JSC 沙箱 + 域名/路径前缀守卫 | **超越 Obsidian**：显式 `permissions` 声明、安装/升级中文权限审批、WebView CSP + `amber-plugin://` 协议隔离、Keychain 密钥零暴露 | Wave 2 支持插件签名校验 |
| **插件间通信** | `app.plugins.plugins[id].api` | 无 | Wave 1 暂不开放直接内存共享 | **Wave 2**：受控跨插件服务调用（`amber.plugins.call`） |
| **编辑器内部扩展** | CodeMirror 6 ViewPlugin / MarkdownPostProcessor | 无 | Wave 1 通过 `amber.agent.insertToComposer` 与主区视图交互 | **Wave 2**：消息流代码块自定义渲染器与 Composer 内联扩展 |

---

## 七、第二波架构设计（Wave 2 — 只设计、不实现）

### 7.1 插件之间互相调用（Inter-Plugin Service RPC）

- **目标**：允许插件 A 向宿主暴露受控只读或写服务接口（如 `kanban-board` 暴露 `createCard`），供插件 B（如 `feishu_calendar` 或会议纪要插件）在获得用户授权后调用，而无需共享 JS 内存空间。
- **Manifest 声明**：
  - 提供方声明 `"exports": [{ "method": "addCard", "effect": "sideEffect", "schema": {...} }]`；
  - 调用方在 `"permissions"` 中声明 `"plugin:kanban-board:addCard"`。
- **桥接口**：
  - 提供方：`amber.plugins.registerService(method, handler)`；
  - 调用方：`await amber.plugins.call("kanban-board", "addCard", payload)`。
- **安全边界**：跨插件写调用同样经过宿主 `DesktopPluginBridgeDispatcher` 鉴权与 schema 校验，防止未授权插件横向提权。

### 7.2 插件市场与从 URL / Git 安装（Plugin Marketplace & URL Installer）

- **目标**：支持从官方精选索引（Registry JSON）或指定 HTTPS Release 包 / Git 仓库一键下载、校验并安装插件。
- **流程设计**：
  1. 下载归档包到临时隔离目录 `/tmp/amber-plugin-staging-<uuid>/`；
  2. 校验 SHA-256 摘要（若提供签名则校验开发者 Ed25519 签名）；
  3. 调用 `inspectPluginPackage(at:)` 提取 `DesktopPluginInstallPlan` 与中文权限请求列表；
  4. 在 UI 弹出权限审批卡片（同时展示来源 URL、版本号与权限变更对比），用户点击「批准并安装」后才移入 `plugins/<id>/`。

### 7.3 编辑器与对话流扩展点（Composer & Transcript Extensions）

- **目标**：对标 Obsidian 的 `registerMarkdownCodeBlockProcessor` 与 `EditorSuggest`：
  1. **消息流代码块渲染器（Code Block Renderer）**：插件可注册特定语言围栏（如 ```` ```kanban ```` 或 ```` ```mermaid-interactive ````）的只读/交互式 WebView 卡片渲染器；
  2. **输入框内联选择器（Composer Mention / Trigger）**：除了 `/` 斜杠命令外，允许插件注册 `@kanban:` 等触发前缀，在 Composer 浮层中实时返回候选条目（如看板卡片标题）并插入上下文引用。

### 7.4 原生 Swift 扩展点（Host-Native Plugin Bridge）

- **目标**：对于需要访问系统级能力（如局域网服务发现、音频采集、AppleScript 自动化）的高阶插件，提供基于 macOS XPC Service 的进程外原生扩展协议（`amber.plugin.native.v1`）：
  - 原生扩展运行在独立沙盒 XPC 进程中，崩溃不影响 `Amber.app` 主进程；
  - 全部能力通过与 `amber.plugin.v3` 相同的 `permissions` 清单与高风险审批门禁统一管控。
