# 编写插件 · Amber 开发者指南（`amber.plugin.v3`）

**一段话说清楚：** Amber macOS 插件体系在 `amber.plugin.v3` 中升级为对标 Obsidian Plugin API 的完整微应用与智能体扩展运行时。一个 v3 插件就是一个文件夹，包含清单文件 `plugin.json`、后台常驻脚本 `main.js`，以及可选的自定义前端资源（`index.html`、`styles.css`、`board.js` 等）。Amber 同时提供 **常驻后台 JavaScriptCore 运行时**（生命周期钩子 `onload` / `onunload`、动态工具与命令注册、事件监听、开发态热重载 `dev_reload`）与 **隔离式 `WKWebView` 自定义视图容器**（通过自定义协议 `amber-plugin://<plugin-id>/<path>` 加载，注入宿主暗色/亮色主题 CSS 变量与 Promise 风格的 `window.amber.*` Bridge）。同时，`amber.plugin.v3` 100% 向下兼容所有旧版 `amber.plugin.v2` 与 `amber.plugin.v1` 插件。

- 架构设计详单请参阅：[docs/architecture/plugin-v3.md](file:///Users/arquiel/.synara/worktrees/b7e9786ccbf0/docs/architecture/plugin-v3.md)
- 完整参考示例插件请参阅：[examples/plugins/kanban-board/](file:///Users/arquiel/.synara/worktrees/b7e9786ccbf0/examples/plugins/kanban-board)

---

## 目录

1. [十分钟快速上手：从零剖析 `kanban-board` 任务看板插件](#1-十分钟快速上手从零剖析-kanban-board-任务看板插件)
2. [`plugin.json` Manifest Schema（`amber.plugin.v3`）](#2-pluginjson-manifest-schemaamberpluginv3)
3. [`window.amber.*` / `amber.*` 全量 26 项 API 参考手册](#3-windowamber--amber-全量-26-项-api-参考手册)
4. [权限声明、最小权限原则与用户安装审批体验](#4-权限声明最小权限原则与用户安装审批体验)
5. [插件生命周期（`onload` / `onunload`）与开发态热重载（`dev_reload`）](#5-插件生命周期onload--onunload与开发态热重载dev_reload)
6. [主题同步与 CSS 设计变量目录（Design Tokens）](#6-主题同步与-css-设计变量目录design-tokens)
7. [调试方法与故障排查](#7-调试方法与故障排查)
8. [打包、安装与验证（`plugin_install` / `plugin_list` 与设置页导入）](#8-打包安装与验证plugin_install--plugin_list-与设置页导入)
9. [从 `amber.plugin.v2` 迁移到 `amber.plugin.v3`](#9-从-amberpluginv2-迁移到-amberpluginv3)
10. [Amber Plugin v3 与 Obsidian Plugin API 对照表](#10-amber-plugin-v3-与-obsidian-plugin-api-对照表)
11. [旧版（`amber.plugin.v2`）完整规范与参考](#11-旧版amberpluginv2完整规范与参考)

---

## 1. 十分钟快速上手：从零剖析 `kanban-board` 任务看板插件

仓库自带的 [examples/plugins/kanban-board/](file:///Users/arquiel/.synara/worktrees/b7e9786ccbf0/examples/plugins/kanban-board) 是一个开箱即用的 `amber.plugin.v3` 标杆插件：
- 在主工作区渲染一个支持 HTML5 拖拽排序、卡片增删改查的交互式看板（`WKWebView`）；
- 自动将看板数据持久化到当前会话工作区的 `kanban/board.json` 并同步生成人类可读的 `kanban/BOARD.md`；
- 在后台 `onload()` 中向智能体动态注册 6 个看板工具（`kanban_list_cards`、`kanban_add_card`、`kanban_move_card`、`kanban_update_card`、`kanban_delete_card`、`kanban_export_markdown`），让用户在对话中说一句「帮我把高优卡片移到进行中」即可实时驱动看板 UI 更新。

### 1.1 目录结构

```text
examples/plugins/kanban-board/
├── plugin.json    # v3 插件清单：声明权限、自定义视图槽位、工具与配置项
├── main.js        # 后台常驻入口：onload/onunload、动态工具与命令实现
├── index.html     # WebView 视图入口（通过 amber-plugin://kanban-board/index.html 加载）
├── styles.css     # 看板样式（直接复用宿主注入的 --amber-* CSS 变量）
└── board.js       # WebView 前端交互逻辑（调用 window.amber.* Promise API）
```

### 1.2 第一步：编写 `plugin.json`

```json
{
  "manifest_version": 3,
  "schema": "amber.plugin.v3",
  "id": "kanban-board",
  "name": "任务看板 (Kanban Board)",
  "version": "3.0.0",
  "description": "基于 amber.plugin.v3 的交互式任务看板：支持多列拖拽、卡片新建/编辑/删除、工作区 JSON 与 Markdown 自动落盘，以及智能体对话直接增删改查卡片。",
  "icon": "rectangle.split.3x1",
  "main": "main.js",
  "dev_reload": true,
  "permissions": [
    "ui.views",
    "workspace.read",
    "workspace.write",
    "agent.tools",
    "storage",
    "commands",
    "events",
    "settings"
  ],
  "capabilities": {
    "networkDomains": [],
    "workspaceReadPrefixes": ["kanban/"],
    "workspaceWritePrefixes": ["kanban/"]
  },
  "ui": {
    "views": [
      {
        "id": "kanban_main",
        "slot": "workspace",
        "title": "任务看板",
        "icon": "rectangle.split.3x1",
        "entry": "index.html",
        "subtitle": "拖拽式多列任务看板，实时同步会话工作区 kanban/board.json 与 kanban/BOARD.md"
      },
      {
        "id": "kanban_sidebar",
        "slot": "right_sidebar",
        "title": "看板速览",
        "icon": "list.bullet.rectangle.portrait",
        "entry": "index.html"
      }
    ],
    "commands": [
      {
        "id": "open_kanban_board",
        "title": "打开任务看板视图",
        "slash": "/kanban",
        "symbol": "rectangle.split.3x1",
        "prompt_template": "请调用 plugin__kanban-board__kanban_list_cards 查看当前任务看板，并帮我梳理待办事项优先级。"
      }
    ]
  }
}
```

### 1.3 第二步：编写后台常驻入口 `main.js`

在 `main.js` 中，你可以定义 `onload()` 和 `onunload()`，并在 `onload()` 里初始化默认数据、监听工作区变更或动态注册工具与命令：

```javascript
function onload() {
  const existing = amber.storage.get("board");
  if (!existing) {
    const initial = defaultBoard();
    amber.storage.set("board", initial);
  }

  // 动态注册命令面板指令
  amber.commands.register({
    id: "kanban_quick_create",
    title: "看板：快速新建任务卡片",
    slash: "/kanban-add",
    callback: function () {
      amber.ui.openView("kanban_main");
      amber.events.emit("kanban:open_new_card_dialog", {});
    }
  });

  // 监听会话工作区 kanban/ 目录文件变更
  amber.workspace.watch("kanban/", function (event) {
    amber.events.emit("kanban:file_changed", event);
  });
}

function onunload() {
  // 宿主会自动回收监听器、定时器与动态注册项，此处可执行自定义清理
}
```

### 1.4 第三步：在 `index.html` 与 `board.js` 中构建交互式界面

前端 HTML 使用 `amber-plugin://<plugin-id>/` 协议加载同包静态资源，并直接调用 `window.amber.*` 的异步 Promise 接口：

```javascript
async function persistBoard(boardState) {
  await window.amber.storage.set("board", boardState);
  await window.amber.workspace.write("kanban/board.json", JSON.stringify(boardState, null, 2));
  await window.amber.events.emit("kanban:board_updated", boardState);
  await window.amber.ui.notice("看板已保存并同步至工作区", "info");
}
```

---

## 2. `plugin.json` Manifest Schema（`amber.plugin.v3`）

### 2.1 顶层字段完整定义

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `manifest_version` | `integer` | 推荐 | 填 `3`（或通过 `schema: "amber.plugin.v3"` 标识 v3 插件）。 |
| `schema` | `string` | 否 | `"amber.plugin.v3"`（兼容 `"amber.plugin.v2"` 与 `"amber.plugin.v1"`）。 |
| `id` | `string` | 是 | 插件唯一标识：2–32 位，以小写字母开头，仅含小写字母、数字、下划线 `_` 或连字符 `-`（`^[a-z][a-z0-9_-]*$`），必须与插件文件夹名完全一致。不可占用官方保留 ID（`feishu_calendar`、`apple_schedule`、`watchtower`）。 |
| `name` | `string` | 是 | 插件显示名称。 |
| `version` | `string` | 是 | 语义化版本号，如 `"3.0.0"`。 |
| `description` | `string` | 是 | 插件功能简介。 |
| `icon` | `string` | 否 | SF Symbols 图标名，默认 `"puzzlepiece.extension"`。 |
| `main` | `string` | 否 | 后台 JS 入口文件相对路径，默认 `"main.js"`。 |
| `dev_reload` | `boolean` | 否 | 开发态热重载开关（默认 `false`）。开启后宿主会监听插件目录文件变更并自动热重载。 |
| `permissions` | `string[]` | v3 必填 | v3 细粒度权限声明列表（如 `["ui.views", "workspace.read", "workspace.write", "http:api.github.com", "agent.tools", "storage", "commands", "events", "settings"]`）。未声明的权限在调用对应 API 时立即报错拒绝。 |
| `capabilities` | `object` | 否 | 路径前缀与网络域名进一步收窄边界：`{ "networkDomains": [], "workspaceReadPrefixes": [], "workspaceWritePrefixes": [] }`。第三方插件严禁声明 `hostModules`。 |
| `settings_schema` | `array` | 否 | 插件配置项定义数组（支持 `"string"`、`"secret"`、`"boolean"`、`"integer"`）。 |
| `tools` | `array` | 否 | 静态声明的智能体工具列表（也可在 `onload` 中通过 `amber.agent.registerTool` 动态注册）。 |
| `ui` | `object` | 否 | 界面槽位声明：`{ "views": [], "inspectorCards": [], "workspaceViews": [], "commands": [] }`。 |

### 2.2 `ui.views` 自定义 WebView 视图槽位

`ui.views` 数组中的每一项声明一个基于 `WKWebView` 的自定义视图：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | `string` | 是 | 视图在插件内的唯一标识（如 `"kanban_main"`）。 |
| `slot` | `string` | 是 | 挂载位置枚举：`"workspace"`（主工作区独立标签页）、`"left_sidebar"`（左侧边栏）、`"right_sidebar"`（右侧边栏）、`"inspector"`（右侧检查器内嵌 WebView 面板）、`"modal"`（模态弹窗）、`"settings"`（插件设置内嵌面板）。 |
| `title` | `string` | 是 | 视图标题。 |
| `icon` | `string` | 否 | SF Symbols 图标名称（兼容 `symbol` 字段）。 |
| `entry` | `string` | 是 | 插件包内的 HTML 相对路径（如 `"index.html"`），禁止 `..` 或绝对路径。 |
| `subtitle` | `string` | 否 | 视图副标题说明。 |

---

## 3. `window.amber.*` / `amber.*` 全量 26 项 API 参考手册

在 WebView 前端中，所有接口挂载在 `window.amber.<namespace>.<method>` 下并统一返回 **Promise**（支持 `async / await`）；在 `main.js` 后台运行时中，同名接口挂载在全局 `amber.<namespace>.<method>` 下（既可同步获取返回值，也可 `await`）。

### 通用错误码规范（Bridge Error Codes）

当调用失败时，Promise 会 reject 一个包含 `code` 与 `message` 的 `Error` 对象：
- `E_PERMISSION_DENIED`：插件未在 `plugin.json` 的 `permissions` 中声明所需权限，或用户尚未批准。
- `E_INVALID_ARGUMENT`：参数缺失、类型不匹配或超出工作区子目录前缀 / HTTPS 域名边界。
- `E_NOT_FOUND`：目标文件、视图或插件不存在。
- `E_EXECUTION_FAILED`：底层文件 IO、网络请求或脚本执行异常。

---

### 3.1 `amber.storage`（插件专属键值存储，需权限 `"storage"`）

每个插件独占 `~/Library/Application Support/Amber/plugins/<id>/storage.json`，支持存储任意 JSON 可序列化值（对象、数组、数字、布尔、字符串），单插件配额上限为 10 MB。

#### 1) `amber.storage.get`
- **签名**：`window.amber.storage.get(key: string): Promise<any>`
- **参数**：`key`（必填，非空字符串）
- **返回值**：已反序列化的 JSON 值（若存的是对象则直接返回对象，键不存在返回 `null` / `""`）
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
const board = await window.amber.storage.get("board");
```

#### 2) `amber.storage.set`
- **签名**：`window.amber.storage.set(key: string, value: any): Promise<{ ok: boolean }>`
- **参数**：`key`（非空字符串），`value`（任意 JSON 可序列化值）
- **返回值**：`{ ok: true }`（落盘后自动广播 `"storage:changed"` 事件并刷新宿主投影）
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`、`E_EXECUTION_FAILED`
- **可运行代码片段**：
```javascript
await window.amber.storage.set("board", { title: "研发看板", cards: [] });
```

#### 3) `amber.storage.remove`
- **签名**：`window.amber.storage.remove(key: string): Promise<{ ok: boolean }>`
- **参数**：`key`（要删除的键名）
- **返回值**：`{ ok: true }`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
await window.amber.storage.remove("draft_card");
```

#### 4) `amber.storage.keys`
- **签名**：`window.amber.storage.keys(): Promise<string[]>`
- **参数**：无
- **返回值**：按字典序排列的所有键名数组 `string[]`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const allKeys = await window.amber.storage.keys();
```

#### 5) `amber.storage.all`
- **签名**：`window.amber.storage.all(): Promise<Record<string, any>>`
- **参数**：无
- **返回值**：当前插件存储的完整键值对象副本
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const snapshot = await window.amber.storage.all();
```

---

### 3.2 `amber.workspace`（会话工作区文件读写与监听，需权限 `"workspace.read"` / `"workspace.write"`）

所有路径均相对于当前活跃会话的工作区根目录，严格拦截 `..` 路径穿越、绝对路径与符号链接（symlink）逃逸，且必须命中 `capabilities.workspaceReadPrefixes` / `workspaceWritePrefixes`（若声明了非空前缀列表）。

#### 6) `amber.workspace.read`
- **签名**：`window.amber.workspace.read(path: string): Promise<string>`
- **所需权限**：`"workspace.read"`
- **参数**：`path`（工作区内相对路径，如 `"kanban/board.json"`）
- **返回值**：文件 UTF-8 文本内容
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`、`E_NOT_FOUND`
- **可运行代码片段**：
```javascript
const rawJSON = await window.amber.workspace.read("kanban/board.json");
```

#### 7) `amber.workspace.write`
- **签名**：`window.amber.workspace.write(path: string, content: string): Promise<{ ok: boolean, path: string }>`
- **所需权限**：`"workspace.write"`（若在工具内调用，工具 `effect` 必须为 `"sideEffect"` 或 `"idempotent"`）
- **参数**：`path`（工作区内相对路径），`content`（UTF-8 字符串内容）
- **返回值**：`{ ok: true, path }`（自动创建父目录、原子写入，并触发 `"workspace:file_changed"` 事件）
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`、`E_EXECUTION_FAILED`
- **可运行代码片段**：
```javascript
await window.amber.workspace.write("kanban/BOARD.md", "# 任务看板\n");
```

#### 8) `amber.workspace.list`
- **签名**：`window.amber.workspace.list(prefix?: string): Promise<string[]>`
- **所需权限**：`"workspace.read"`
- **参数**：`prefix`（可选相对目录前缀，默认 `""` 列出工作区所有受许文件）
- **返回值**：匹配的相对文件路径数组 `string[]`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
const files = await window.amber.workspace.list("kanban/");
```

#### 9) `amber.workspace.watch`
- **签名**：`window.amber.workspace.watch(prefix: string, callback?: (event: { path: string }) => void): Promise<{ ok: boolean, prefix: string }>`
- **所需权限**：`"workspace.read"`
- **参数**：`prefix`（要监听的工作区子路径前缀），`callback`（可选回调函数，同时可通过 `amber.events.on("workspace:file_changed", ...)` 接收通知）
- **返回值**：`{ ok: true, prefix }`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
await window.amber.workspace.watch("kanban/", (evt) => {
  console.log("工作区文件变更:", evt.path);
});
```

---

### 3.3 `amber.http`（受控 HTTPS 网络请求，需权限 `"http:<domain>"`）

#### 10) `amber.http.fetch`
- **签名**：`window.amber.http.fetch(url: string, options?: { method?: string, headers?: Record<string, string>, body?: string }): Promise<{ ok: boolean, status: number, body: string, text: string, json: any }>`
- **所需权限**：`permissions` 中声明 `"http:<domain>"`（例如 `"http:api.github.com"` 或 `"http:*.feishu.cn"`），或 `capabilities.networkDomains` 包含目标域名。仅允许 `https://` 协议，单次超时 20 秒。
- **参数**：`url`（必填 HTTPS URL），`options`（可选 `{ method, headers, body }`）
- **返回值**：`{ ok, status, body, text, json }`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`、`E_EXECUTION_FAILED`
- **可运行代码片段**：
```javascript
const res = await window.amber.http.fetch("https://api.github.com/zen", {
  method: "GET",
  headers: { "Accept": "application/json" }
});
```

---

### 3.4 `amber.commands`（命令面板与斜杠指令，需权限 `"commands"`）

#### 11) `amber.commands.register`
- **签名**：`window.amber.commands.register(command: { id: string, title: string, slash?: string, symbol?: string, prompt_template?: string, callback?: Function }): Promise<{ ok: boolean, id: string }>`
- **参数**：`command` 对象（`id` 与 `title` 必填，`slash` 可选如 `"/kanban-add"`）
- **返回值**：`{ ok: true, id }`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
await window.amber.commands.register({
  id: "quick_export",
  title: "导出看板为 Markdown",
  slash: "/kanban-export"
});
```

#### 12) `amber.commands.list`
- **签名**：`window.amber.commands.list(): Promise<Array<{ id: string, title: string, slash: string, symbol: string, prompt_template: string }>>`
- **参数**：无
- **返回值**：当前插件已注册的所有静态与动态命令列表
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const cmds = await window.amber.commands.list();
```

---

### 3.5 `amber.events`（宿主与插件跨视图事件总线，需权限 `"events"`）

支持订阅宿主生命周期事件（`conversation:changed`、`message:received`、`workspace:file_changed`、`theme:changed`、`storage:changed`、`settings:changed`）以及插件自定义事件（如 `kanban:board_updated`），在同一插件的后台 `main.js` 与多个 `WKWebView` 实例之间实时广播。

#### 13) `amber.events.on`
- **签名**：`window.amber.events.on(event: string, handler: (payload: any) => void): Promise<() => void>`
- **参数**：`event`（事件名称），`handler`（事件回调）
- **返回值**：取消订阅函数 `unsubscribe()`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
await window.amber.events.on("kanban:board_updated", (board) => {
  console.log("收到最新看板状态:", board.updatedAt);
});
```

#### 14) `amber.events.off`
- **签名**：`window.amber.events.off(event: string, handler?: Function): Promise<{ ok: boolean }>`
- **参数**：`event`（事件名称），`handler`（可选指定移除的回调；不传则移除该事件全部回调）
- **返回值**：`{ ok: true }`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
await window.amber.events.off("kanban:board_updated");
```

#### 15) `amber.events.emit`
- **签名**：`window.amber.events.emit(event: string, payload?: any): Promise<{ ok: boolean }>`
- **参数**：`event`（事件名称），`payload`（任意 JSON 可序列化负载）
- **返回值**：`{ ok: true }`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
await window.amber.events.emit("kanban:board_updated", { updatedAt: new Date().toISOString() });
```

---

### 3.6 `amber.ui`（宿主通知、确认框、视图跳转与模态窗，需权限 `"ui.views"`）

#### 16) `amber.ui.notice`
- **签名**：`window.amber.ui.notice(message: string, level?: "info" | "warning" | "error"): Promise<{ ok: boolean }>`
- **参数**：`message`（通知文案），`level`（可选级别，默认 `"info"`）
- **返回值**：`{ ok: true }`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
await window.amber.ui.notice("看板已同步至 kanban/BOARD.md", "info");
```

#### 17) `amber.ui.confirm`
- **签名**：`window.amber.ui.confirm(options: { title?: string, message: string }): Promise<boolean>`
- **参数**：`options`（含 `title` 与 `message`）
- **返回值**：布尔值（用户点击确认返回 `true`，取消返回 `false`）
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const confirmed = await window.amber.ui.confirm({
  title: "删除卡片",
  message: "确定要删除这张卡片吗？"
});
```

#### 18) `amber.ui.openView`
- **签名**：`window.amber.ui.openView(viewId: string): Promise<{ ok: boolean, viewId: string }>`
- **参数**：`viewId`（在 `ui.views` 或 `ui.workspaceViews` 中声明的视图 ID）
- **返回值**：`{ ok: true, viewId }`（宿主自动切换主工作区或对应侧栏到该视图）
- **错误码**：`E_PERMISSION_DENIED`、`E_NOT_FOUND`
- **可运行代码片段**：
```javascript
await window.amber.ui.openView("kanban_main");
```

#### 19) `amber.ui.openModal`
- **签名**：`window.amber.ui.openModal(options: { viewId?: string, title?: string, entry?: string, width?: number, height?: number }): Promise<{ ok: boolean, viewId: string }>`
- **参数**：`options`（指定 `viewId` 或 `entry` HTML 路径及弹窗宽高）
- **返回值**：`{ ok: true, viewId }`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
await window.amber.ui.openModal({
  viewId: "kanban_modal",
  title: "卡片详情",
  entry: "index.html",
  width: 680,
  height: 500
});
```

#### 20) `amber.ui.closeModal`
- **签名**：`window.amber.ui.closeModal(): Promise<{ ok: boolean }>`
- **参数**：无
- **返回值**：`{ ok: true }`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
await window.amber.ui.closeModal();
```

---

### 3.7 `amber.agent`（智能体工具注册与当前会话联动，需权限 `"agent.tools"`）

#### 21) `amber.agent.registerTool`
- **签名**：`window.amber.agent.registerTool(definition: { name: string, description: string, effect?: "pure" | "networkRead" | "idempotent" | "sideEffect", entry?: string, input_schema?: object, handler?: Function }): Promise<{ ok: boolean, qualifiedName: string }>`
- **参数**：工具定义对象。写工作区或写外部接口的工具必须声明 `effect: "sideEffect"` 或 `"idempotent"`，执行时自动接入宿主高风险人工审批门禁。
- **返回值**：`{ ok: true, qualifiedName: "plugin__<id>__<name>" }`
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
await window.amber.agent.registerTool({
  name: "kanban_summary",
  description: "统计各列卡片数量",
  effect: "pure",
  input_schema: { type: "object", properties: {}, additionalProperties: false },
  handler: function () {
    return { ok: true, total: 3 };
  }
});
```

#### 22) `amber.agent.getConversation`
- **签名**：`window.amber.agent.getConversation(): Promise<{ id: string | null, title: string, messageCount: number }>`
- **参数**：无
- **返回值**：当前活跃会话的脱敏元信息摘要
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const conv = await window.amber.agent.getConversation();
```

#### 23) `amber.agent.insertToComposer`
- **签名**：`window.amber.agent.insertToComposer(text: string): Promise<{ ok: boolean }>`
- **参数**：`text`（要填入底部对话输入框的提示词文本，不会未经用户确认自动发送）
- **返回值**：`{ ok: true }`
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
await window.amber.agent.insertToComposer("请帮我梳理当前看板中的高优先级任务。");
```

---

### 3.8 `amber.settings`（插件配置读取与更新，需权限 `"settings"`）

#### 24) `amber.settings.get`
- **签名**：`window.amber.settings.get(key: string): Promise<string>`
- **参数**：`key`（`settings_schema` 中定义的配置键，或内置 `"today"` / `"mode"`）
- **返回值**：非敏感配置项的字符串值（标记为 `kind: "secret"` 的钥匙串凭据永不返回给 JS，恒返回 `""`）
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const boardPath = await window.amber.settings.get("board_file_path");
```

#### 25) `amber.settings.set`
- **签名**：`window.amber.settings.set(key: string, value: any): Promise<{ ok: boolean }>`
- **参数**：`key`（非敏感配置键名），`value`（新配置值；禁止在 JS 中直接写入 `secret` 类型字段）
- **返回值**：`{ ok: true }`（更新后自动广播 `"settings:changed"` 事件）
- **错误码**：`E_PERMISSION_DENIED`、`E_INVALID_ARGUMENT`
- **可运行代码片段**：
```javascript
await window.amber.settings.set("auto_sync_markdown", "true");
```

#### 26) `amber.settings.getAll`
- **签名**：`window.amber.settings.getAll(): Promise<Record<string, string>>`
- **参数**：无
- **返回值**：所有非敏感配置项的键值对字典（自动剔除 `secret` 字段）
- **错误码**：`E_PERMISSION_DENIED`
- **可运行代码片段**：
```javascript
const allSettings = await window.amber.settings.getAll();
```

---

## 4. 权限声明、最小权限原则与用户安装审批体验

### 4.1 权限矩阵与人类可读中文摘要

在 `amber.plugin.v3` 中，插件必须在 `plugin.json` 的 `permissions` 字段中显式声明所需权限。未声明任何权限的 API 调用会在 Bridge 层被当场拒绝（抛出 `E_PERMISSION_DENIED`）：

| 权限标识符 (`permissions`) | 用户在安装/升级弹窗中看到的中文摘要 | 风险等级 | 详细说明 |
| --- | --- | --- | --- |
| `ui.views` | **渲染自定义界面视图** | 中（需确认） | 允许在主工作区、左右侧栏、检查器或模态窗中加载沙箱 WebView 视图。 |
| `workspace.read` | **读取会话工作区文件** | 中（需确认） | 允许读取当前会话工作区（受 `workspaceReadPrefixes` 限制）内的文件与目录。 |
| `workspace.write` | **写入会话工作区文件** | **高风险** | 允许在当前会话工作区（受 `workspaceWritePrefixes` 限制）内创建或覆盖文件。 |
| `http:<domain>` | **访问外部网络域名 (`<domain>`)** | **高风险** | 仅允许向指定 HTTPS 域名（如 `http:api.github.com`）发起网络请求。 |
| `agent.tools` | **向智能体注册可调用工具** | **高风险** | 允许注册供大模型在对话、子代理和 Recipe 中调用的工具。 |
| `storage` | **读写插件本地键值存储** | 低 | 允许在插件专属 `storage.json` 中持久化数据（上限 10 MB）。 |
| `commands` | **注册斜杠命令与命令面板动作** | 低 | 允许向 `/` 斜杠补全与 `⌘K` 命令面板注册快捷指令。 |
| `events` | **订阅与派发插件事件** | 低 | 允许监听当前会话切换、主题变化、工作区文件变更及派发插件内部事件。 |
| `settings` | **读写插件非敏感配置项** | 低 | 允许读取或修改插件自身的普通配置项（不含 Keychain `secret` 密钥）。 |

### 4.2 安装与升级时的用户审批流程

1. **首次导入安装**：当用户在 **设置 → 插件 → + 导入插件** 选择 v3 插件文件夹时，Amber 调用 `DesktopPluginStore.inspectPluginPackage(at:)` 生成安装计划（`DesktopPluginInstallPlan`），弹出 **权限审批表单（`DesktopPluginPermissionConsentSheet`）**，向用户逐条展示中文权限摘要与高风险徽章。只有用户点击「批准并安装」后，插件才会被拷贝激活。
2. **版本升级新增权限重审**：如果插件升级时新增了此前未批准过的权限（例如从只读升级为包含 `workspace.write`），`hasAllPermissionsApproved(for:)` 会返回 `false`，宿主在设置页展示琥珀色「权限变更待确认」横幅，并在用户点击「审查并批准新增权限」前冻结未授权能力。
3. **写操作工具的高风险门禁（High-Risk Gate）**：插件注册的工具若声明 `effect: "sideEffect"` 或 `"idempotent"`（包含写工作区或外部网络写入），在对话中被智能体调用时**强制走高风险审批**——不受普通「自动批准工具」开关豁免，必须在 Mac 桌面端主窗口由用户人工批准；通知横幅、锁屏界面与手机端远程卡片对该类工具**只能拒绝、不能批准**。

---

## 5. 插件生命周期（`onload` / `onunload`）与开发态热重载（`dev_reload`）

### 5.1 常驻后台运行时生命周期

与 v2「每次工具调用临时创建并销毁 `JSContext`」不同，v3 插件在启用时会启动一个独立的常驻后台宿主 `DesktopPluginRuntimeHost`：

1. **启动与 `onload()`**：插件启用或 Amber 启动时，后台加载 `main.js` 并调用全局 `onload()`（支持返回 Promise）。在 `onload()` 中注册的定时同步、工作区监听（`amber.workspace.watch`）、事件回调（`amber.events.on`）、动态工具（`amber.agent.registerTool`）与命令（`amber.commands.register`）在整个插件启用期间持续有效，**不依赖插件 WebView 页面是否处于打开状态**。
2. **停用/卸载与 `onunload()`**：当用户在设置页关闭插件、卸载插件或触发热重载时，宿主先调用 `onunload()`（限时优雅清理），随后自动清空该插件的所有事件订阅、文件监视器、动态工具/命令注册表以及关联的 `WKWebView` 实例，确保零内存泄漏与零幽灵回调。
3. **异常隔离**：单个插件在 `onload()`、工具执行或事件回调中抛出的未捕获异常会被宿主捕获并记录到插件卡片的错误状态横幅（`lastError`），绝不会导致 Amber 主进程崩溃或阻塞其他插件。

### 5.2 开发态热重载（`dev_reload`）

在 `plugin.json` 中设置 `"dev_reload": true` 后：
- 宿主会使用 `DispatchSourceFileSystemObject` 监听插件安装目录；
- 当你修改 `main.js`、`index.html`、`styles.css`、`board.js` 或 `plugin.json` 保存时，宿主会在 150ms 防抖后自动执行 `onunload()` → 重新读取清单与脚本 → 执行 `onload()` → 刷新已打开的 `WKWebView` 视图；
- 你也可以随时在 **设置 → 插件** 中点击插件卡片上的 **「↻ 热重载」** 按钮（或调用 `store.reloadPlugin(id:)`）立即重载单个插件。

---

## 6. 主题同步与 CSS 设计变量目录（Design Tokens）

每个自定义 `WKWebView` 在文档加载起始阶段（`atDocumentStart`）都会自动注入宿主样式表与根属性 `document.documentElement.dataset.theme = "dark" | "light"`。当 macOS 系统外观或 Amber 主题切换时，宿主会实时更新 `--amber-*` 变量并派发 `theme:changed` 事件。

在你的 `styles.css` 中直接使用以下 CSS 变量即可获得原生的 Arquiel Design 2.0 视觉质感：

| CSS 变量名 | 暗色模式默认值 (`dark`) | 亮色模式默认值 (`light`) | 用途说明 |
| --- | --- | --- | --- |
| `--amber-bg-primary` | `#121316` | `#FAF8F5` | 视图主背景色 |
| `--amber-bg-secondary` | `#1A1C20` | `#F2EFE9` | 栏位/次级容器背景色 |
| `--amber-bg-card` | `rgba(255, 255, 255, 0.05)` | `rgba(255, 255, 255, 0.85)` | 卡片表面背景色 |
| `--amber-bg-elevated` | `#23262C` | `#FFFFFF` | 浮层/弹窗抬升表面背景色 |
| `--amber-text-primary` | `#F3F4F6` | `#1C1917` | 主标题与正文文字颜色 |
| `--amber-text-secondary` | `#9CA3AF` | `#57534E` | 次要说明文字颜色 |
| `--amber-text-muted` | `#6B7280` | `#A8A29E` | 弱化占位与辅助编号颜色 |
| `--amber-accent` | `#F59E0B` | `#D97706` | Amber 品牌琥珀强调色 |
| `--amber-accent-soft` | `rgba(245, 158, 11, 0.16)` | `rgba(217, 119, 6, 0.12)` | 强调色柔和背景胶囊 |
| `--amber-border` | `rgba(255, 255, 255, 0.09)` | `rgba(28, 25, 23, 0.10)` | 标准分割线与卡片描边 |
| `--amber-danger` | `#EF4444` | `#DC2626` | 危险/删除状态色 |
| `--amber-success` | `#10B981` | `#059669` | 成功/完成状态色 |
| `--amber-radius-sm` | `6px` | `6px` | 小号圆角（徽章、按钮） |
| `--amber-radius-md` | `10px` | `10px` | 中号圆角（卡片、输入框） |
| `--amber-radius-lg` | `14px` | `14px` | 大号圆角（面板、弹窗） |
| `--amber-font-sans` | `-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif` | 同左 | 系统无衬线字体栈 |
| `--amber-font-mono` | `"SF Mono", ui-monospace, Menlo, monospace` | 同左 | 等宽代码字体栈 |

---

## 7. 调试方法与故障排查

1. **查看运行时错误横幅**：如果 `plugin.json` 字段校验失败、`onload()` 抛出异常或工具执行报错，前往 **设置 (`⌘,`) → 插件**，对应插件卡片顶部会显示红色诊断横幅（来自 `store.runtimeErrors[pluginID]`）。
2. **WebKit 开发者工具（Web Inspector）**：在 Debug 构建下，自定义插件 `WKWebView` 已开启 `isInspectable = true`。你可以在插件视图上右键打开 Web Inspector（或通过 Safari「开发」菜单连接），直接查看 DOM 结构、CSS 变量、Console 日志以及 `window.amber.*` Bridge 调用栈。
3. **热重载快速验证**：开启 `"dev_reload": true` 后直接保存代码，或点击插件详情页的 **「↻ 热重载」** 按钮，即可在不重启应用的情况下验证修改。
4. **单元测试沙箱验证**：参考 `macApp/AmberMacTests/DesktopPluginV3Tests.swift`，通过 `DesktopPluginStore` 在临时目录中直接测试插件安装、权限拦截、Bridge RPC 调用与工具执行。

---

## 8. 打包、安装与验证（`plugin_install` / `plugin_list` 与设置页导入）

### 8.1 插件包结构检查

打包前请确认目录名与 `plugin.json` 的 `id` 完全一致，且所有静态资源均位于该目录内：

```text
<plugin-id>/
├── plugin.json
├── main.js
└── (可选) index.html / styles.css / board.js / assets/...
```

### 8.2 安装与验证方式

- **方式一：通过智能体工具 `plugin_install` 安装并用 `plugin_list` 验证（推荐会话内自装闭环）**
  1. 在当前会话工作区内生成插件目录（如 `kanban-board/plugin.json`、`kanban-board/main.js`、`kanban-board/index.html` 等），严禁越界或使用符号链接逃逸；
  2. 调用高风险工具 `plugin_install`，传入工作区相对路径 `{"path": "kanban-board"}`（若升级或覆盖已安装的同名插件，需核对新旧版本差异并显式传入 `{"path": "kanban-board", "overwrite": true}`）；
  3. Amber 会在 Mac 主窗口弹出审批卡片（展示插件名称、新旧版本对比、中文权限摘要及 `networkDomains` / `workspaceReadPrefixes` / `workspaceWritePrefixes` 边界，通知栏/锁屏/手机端仅可拒绝不可批准）；
  4. 用户在 Mac 上点击批准后，宿主复用 `DesktopPluginStore.importPlugin(from:approvePermissions: true)` 完成清单校验、原子落盘与 `reload()`；
  5. 随后调用只读工具 `plugin_list`（无需参数 `{}`），核实返回的插件列表中对应 `id`、`version`、`enabled: true`、`permissions` 及已注册的 `tools` / `views` 均已就绪。
- **方式二：通过桌面端设置页手动导入**
  1. 打开 **设置 (`⌘,`) → 插件**，点击左下角 **「+ 导入插件」**；
  2. 选择插件文件夹（如 `examples/plugins/kanban-board`）；
  3. 在弹出的「安装插件权限确认」面板中核对权限清单，点击 **「批准并安装」**；
  4. 在左侧「扩展插件」列表确认插件处于「已启用」状态，点击侧栏「任务看板」即可打开自定义视图。

---

## 9. 从 `amber.plugin.v2` 迁移到 `amber.plugin.v3`

现有的 `amber.plugin.v2` 插件**无需任何修改即可继续在 Amber 中正常运行**。如果你想为现有 v2 插件添加自定义交互界面、常驻后台任务或动态工具，只需按以下 4 步升级到 v3：

1. **更新协议标识**：在 `plugin.json` 中将 `"schema"` 改为 `"amber.plugin.v3"`，并添加 `"manifest_version": 3` 与 `"main": "main.js"`。
2. **补充显式 `permissions` 数组**：将原 `capabilities` 中隐含的能力显式写入 `permissions`：
   - 用到了 `amber.storage.*` → 添加 `"storage"`
   - 用到了 `amber.settings.*` → 添加 `"settings"`
   - 用到了 `amber.workspace.read` → 添加 `"workspace.read"`（保留 `capabilities.workspaceReadPrefixes` 以收窄子目录）
   - 用到了 `amber.workspace.write` → 添加 `"workspace.write"`（保留 `capabilities.workspaceWritePrefixes`）
   - 用到了 `amber.http.fetch` → 为每个目标域名添加 `"http:<domain>"`
   - 声明了 `tools` → 添加 `"agent.tools"`
   - 声明了 `ui.commands` → 添加 `"commands"`
   - 新增了 `ui.views` → 添加 `"ui.views"`
3. **添加生命周期钩子（可选）**：在 `main.js` 中添加 `function onload() { ... }` 和 `function onunload() { ... }`。
4. **添加自定义 WebView 视图（可选）**：在 `ui.views` 中声明 `{ id, slot, title, icon, entry: "index.html" }`，并在 `index.html` 中使用 `amber-plugin://<plugin-id>/...` 引用脚本与样式，通过 `await window.amber.<ns>.<fn>(...)` 与宿主通信。

---

## 10. Amber Plugin v3 与 Obsidian Plugin API 对照表

| 能力维度 | Obsidian Plugin API | Amber Plugin v3 (`amber.plugin.v3`) | 架构差异与安全设计 |
| --- | --- | --- | --- |
| **插件清单** | `manifest.json` (`id`, `name`, `version`, `minAppVersion`) | `plugin.json` (`manifest_version: 3`, `schema: "amber.plugin.v3"`, `permissions`, `ui.views`, `tools`) | Amber 强制在清单中声明细粒度 `permissions` 与 `capabilities` 前缀。 |
| **生命周期** | `Plugin.onload()` / `Plugin.onunload()` | `onload()` / `onunload()` + `dev_reload` 文件监听热重载 | Amber 宿主自动追踪并回收事件监听、文件 watcher、动态工具与 WebView。 |
| **自定义视图** | `ItemView` (`registerView` + Workspace Leaf) | `ui.views` (`workspace` / `left_sidebar` / `right_sidebar` / `inspector` / `modal` / `settings`) + `amber.ui.openView` | Obsidian 插件与宿主共享同一个 Electron DOM；Amber 采用每视图独立沙箱 `WKWebView` + `amber-plugin://` 协议隔离。 |
| **模态弹窗** | `Modal` (`open()` / `close()`) | `amber.ui.openModal` / `amber.ui.closeModal` / `amber.ui.confirm` / `amber.ui.notice` | Amber 支持轻量原生确认框与完整自定义 HTML 模态窗。 |
| **文件读写与监听** | `Vault` (`read`, `modify`, `create`, `adapter.list`) | `amber.workspace.read` / `write` / `list` / `watch` | Amber 限制在当前会话工作区与授权子目录前缀内，防 `..` 与 symlink 逃逸。 |
| **本地持久化** | `loadData()` / `saveData()` | `amber.storage.get` / `set` / `remove` / `keys` / `all` | Amber 提供键值级原子读写，单插件 10 MB 配额。 |
| **命令与快捷键** | `addCommand({ id, name, callback })` | `ui.commands` + `amber.commands.register` / `list` | Amber 命令同时注入 `⌘K` 全局命令面板与底部输入框 `/` 斜杠指令。 |
| **事件总线** | `Events` (`on`, `off`, `trigger`, `registerEvent`) | `amber.events.on` / `off` / `emit` | Amber 支持跨后台 `JSContext` 与多个前端 `WKWebView` 实时广播。 |
| **网络请求** | `requestUrl()` | `amber.http.fetch` | Amber 强制仅允许 HTTPS 且目标域名必须在 `http:<domain>` 白名单中声明。 |
| **AI 智能体原生集成** | 无内置标准（需第三方插件自行接 LLM） | `tools` + `amber.agent.registerTool` / `getConversation` / `insertToComposer` | Amber 原生将插件工具注入对话、子代理与 Recipe，写操作强制走桌面端高风险人工审批。 |

---

## 11. 旧版（`amber.plugin.v2`）完整规范与参考

> 以下章节完整保留 `amber.plugin.v2`（兼容 `v1`）开发规范，供维护现有 v2 插件参考。

### 11.1 v2 概览

一个 `amber.plugin.v2` 插件是一个包含 `plugin.json` 和 `main.js` 的文件夹：
- `capabilities`：声明允许访问的 HTTPS 域名白名单（`networkDomains`），以及允许读写的会话工作区子目录前缀（`workspaceReadPrefixes` / `workspaceWritePrefixes`）。`hostModules` 仅供官方内置插件使用，第三方插件声明会被拒绝。
- `settings_schema`：声明插件配置项。普通字段存 `UserDefaults`；标记为 `secret` 的字段自动加密存入 macOS 钥匙串（Keychain），不落明文、不进 JS 沙箱。
- `tools`：把 JS 函数注册成智能体工具（`plugin__<插件id>__<工具名>`），按 `effect` 等级自动接入审批流与工具账本。
- `ui.inspectorCards`：在右侧检查器挂一张折叠卡片，由 `rebuildProjections()` 调用卡片的 `entry` 函数预先计算并缓存快照。
- `ui.workspaceViews`：在左侧边栏「插件视图」挂出静态主工作区入口。
- `ui.commands`：向底部输入框 `/` 斜杠补全浮层与 `⌘K` 全局命令面板注入快捷指令。

### 11.2 v2 五分钟示例：`note_helper`（会议纪要助手）

#### `note_helper/plugin.json`

```json
{
  "schema": "amber.plugin.v2",
  "id": "note_helper",
  "name": "会议纪要助手",
  "version": "1.0.0",
  "description": "统计纪要字数、附加统一前缀并归档到当前会话工作区。",
  "icon": "doc.text.magnifyingglass",
  "capabilities": {
    "networkDomains": [],
    "workspaceReadPrefixes": ["notes/"],
    "workspaceWritePrefixes": ["notes/"]
  },
  "settings_schema": [
    {
      "key": "prefix",
      "title": "纪要标题前缀",
      "kind": "string",
      "placeholder": "【项目纪要】",
      "defaultValue": "【项目纪要】",
      "help": "每次格式化会议纪要时自动加在最前面的前缀。"
    }
  ],
  "tools": [
    {
      "name": "format_note",
      "description": "格式化会议纪要文本并统计累计运行次数。",
      "effect": "pure",
      "entry": "formatNote",
      "input_schema": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "原始会议记录内容"
          }
        },
        "required": ["text"],
        "additionalProperties": false
      }
    },
    {
      "name": "save_note",
      "description": "将整理好的会议纪要写入当前会话工作区 notes/ 目录。",
      "effect": "sideEffect",
      "entry": "saveNote",
      "input_schema": {
        "type": "object",
        "properties": {
          "filename": {
            "type": "string",
            "description": "保存在 notes/ 下的文件名，例如 weekly.md"
          },
          "text": {
            "type": "string",
            "description": "纪要正文内容"
          }
        },
        "required": ["filename", "text"],
        "additionalProperties": false
      }
    }
  ],
  "ui": {
    "inspectorCards": [
      {
        "id": "note_summary",
        "title": "纪要助手状态",
        "symbol": "doc.text.magnifyingglass",
        "entry": "renderNoteInspector"
      }
    ],
    "workspaceViews": [
      {
        "id": "note_board",
        "title": "纪要工作台",
        "symbol": "doc.text",
        "subtitle": "查看已格式化的纪要统计与快捷整理命令。"
      }
    ],
    "commands": [
      {
        "id": "cmd_format_note",
        "title": "格式化当前会议纪要",
        "slash": "/note-format",
        "symbol": "doc.badge.gearshape",
        "prompt_template": "请调用 plugin__note_helper__format_note 工具，帮我将以下会议记录整理为标准纪要：\n"
      }
    ]
  }
}
```

#### `note_helper/main.js`

```javascript
function formatNote(input) {
  const prefix = amber.settings.get("prefix") || "【纪要】";
  const rawText = String((input && input.text) || "").trim();
  const runs = Number(amber.storage.get("runs") || "0") + 1;
  const formatted = prefix + rawText;
  amber.storage.set("runs", String(runs));
  amber.storage.set("last_note", formatted);

  return {
    ok: true,
    formatted: formatted,
    char_count: rawText.length,
    run_count: runs
  };
}

function saveNote(input) {
  const name = String((input && input.filename) || "summary.md").replace(/^\/+/, "");
  const path = name.indexOf("notes/") === 0 ? name : "notes/" + name;
  const content = String((input && input.text) || "");
  amber.workspace.write(path, content);
  return {
    ok: true,
    saved_path: path,
    read_back: amber.workspace.read(path)
  };
}

function renderNoteInspector() {
  const runs = Number(amber.storage.get("runs") || "0");
  const lastNote = amber.storage.get("last_note");
  if (!lastNote) {
    return {
      statusBadge: "待命",
      emptyMessage: "尚未整理纪要，输入 /note-format 即可快速开始。",
      items: []
    };
  }
  return {
    statusBadge: "已处理 " + runs + " 次",
    emptyMessage: "暂无纪要记录",
    items: [
      {
        id: "latest_note",
        badge: "最近纪要",
        title: lastNote,
        subtitle: "累计执行 " + runs + " 次",
        actionTitle: "继续润色",
        prompt: "请基于以下纪要继续提炼行动项：\n" + lastNote
      }
    ]
  };
}
```

### 11.3 官方内置扩展插件与核心插件

- **官方内置扩展插件（保留 ID）**：`feishu_calendar`（飞书日历与机器人）、`apple_schedule`（系统日历与提醒）、`watchtower`（网页观察哨）。
- **5 个核心插件（Core Plugins）**：`task_board`（任务看板与定时任务）、`knowledge`（知识与长期记忆）、`collaborations`（多模型协作与议会）、`recipes`（Recipe 自动流程）、`image_generation`（图片生成工作台）。
