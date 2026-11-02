---
name: plugin-development
description: >
  指导在 Amber macOS 中设计、编写、自检与安装验证 amber.plugin.v3 扩展插件（默认使用 v3：含自定义 WebView 视图决策、最小权限原则、常驻生命周期、26 项 Bridge API、高风险审批门禁，以及 plugin_install / plugin_list 与设置页导入验证）。
allowed-tools: [skills_list, use_skill, workspace_file_list, workspace_file_read, workspace_file_write, workspace_list, workspace_read, workspace_write, plugin_install, plugin_list]
---

# Amber macOS 插件开发技能（`plugin-development` · 默认 `amber.plugin.v3`）

本技能指导为 Amber macOS 编写符合 **`amber.plugin.v3`** 协议（向下兼容 `amber.plugin.v2`）与 Arquiel Design 2.0 规范的扩展插件。Amber 自己编写新插件时**默认使用 `amber.plugin.v3`**。完整参考实现见仓库内的 `examples/plugins/kanban-board/`，开发者文档见 `docs/plugins.md`。

## 一、核心铁律与安全边界（必须遵守）

1. **严禁静默安装或直接启用插件**：
   - 在会话中起草插件时，先在当前会话工作区创建插件目录（如 `<id>/plugin.json`、`<id>/main.js` 及可选的 `<id>/index.html`），切勿直接散落写入 `~/Library/Application Support/Amber/plugins/`。
   - 草稿生成并完成自检清单后，优先调用高风险工具 `plugin_install`（传入工作区相对路径如 `{"path": "<id>"}`；若升级或覆盖已有同名插件，须核对新旧版本差异并显式传 `"overwrite": true`），由用户在 Mac 主窗口审批卡片上核对插件名称、版本与申请权限后批准安装，随后调用只读工具 `plugin_list` 验证插件状态、权限与已注册工具/视图（或引导用户通过 **「设置 (`⌘,`) → 插件 → + 导入插件」** 在权限审批弹窗中确认并安装）。
2. **保留 ID 与核心插件边界**：
   - 官方内置扩展插件保留 ID 为 `feishu_calendar`、`apple_schedule`、`watchtower`，第三方插件禁止使用。
   - 5 个一级核心插件 ID 为 `task_board`、`knowledge`、`collaborations`、`recipes`、`image_generation`。
   - `capabilities.hostModules`（如 `["calendar"]`）**仅供官方内置插件使用**，第三方插件声明会被直接拒绝。
3. **写类工具的高风险审批边界（High-Risk Gate）**：
   - 工具 `effect` 仅支持 `"pure"`、`"networkRead"`、`"idempotent"`、`"sideEffect"`。
   - `"pure"` 与 `"networkRead"` 为只读工具，免审批直接执行，但**严禁调用 `amber.workspace.write`**。
   - `"idempotent"` 与 `"sideEffect"`（含任何工作区写入或外部网络写入）**均属于高风险操作（High Risk）**：必须在 Mac 桌面端主窗口由用户人工批准，不受普通「自动批准」开关豁免；通知横幅、锁屏界面与手机端远程审批对高风险工具**只能拒绝、不能批准**。

---

## 二、架构决策：如何决定是否需要自定义 UI 與如何按最小权限原则选权限

### 1. 如何决定是否需要自定义 UI（`ui.views`）

| 场景需求 | 推荐方案 | 是否需要 `ui.views` (`WKWebView`) |
| --- | --- | --- |
| 纯数据处理、格式转换、单次外部 API 查询供大模型调用 | 仅声明 `tools` + `ui.commands` | **不需要**（保持轻量无界面） |
| 仅在右侧栏展示 1–5 条只读状态摘要与快捷提问按钮 | 使用声明式 `ui.inspectorCards` | **不需要**（零 WebView 开销） |
| 需要拖拽看板（Kanban）、可视化图表、多字段交互表单、富媒体预览或独立工作台 | 在 `ui.views` 中声明 `slot`（`workspace` / `left_sidebar` / `right_sidebar` / `inspector` / `modal` / `settings`）并提供 `index.html` | **需要**（同时声明 `"ui.views"` 权限） |

### 2. 如何按最小权限原则（Least Privilege）选择 `permissions`

在 `amber.plugin.v3` 中，未声明的权限在调用对应 Bridge API 时会立即被拦截（`E_PERMISSION_DENIED`）。请**只申请插件实际用到的权限**，并配合 `capabilities` 进一步收窄子目录与域名：

- **只读本地配置**：仅加 `"settings"`（绝不读取 `secret` 钥匙串字段）。
- **插件私有键值持久化**：仅加 `"storage"`（读写插件专属 `storage.json`）。
- **读取会话工作区特定子目录**：加 `"workspace.read"`，并在 `capabilities.workspaceReadPrefixes` 中明确列出最小子目录前缀（如 `["kanban/"]`，切勿无故申请整个工作区）。
- **写入会话工作区特定子目录**：加 `"workspace.write"`（高风险），并在 `capabilities.workspaceWritePrefixes` 中限定最小子目录前缀（如 `["kanban/"]`）。
- **访问外部 HTTPS 接口**：按目标域名逐个声明 `"http:<domain>"`（高风险，例如 `"http:api.github.com"`），同时填入 `capabilities.networkDomains`，严禁使用明文 `http://`。
- **向智能体暴露工具**：加 `"agent.tools"`（高风险）。
- **渲染自定义 WebView 界面或弹窗通知**：加 `"ui.views"`。
- **注册斜杠命令或事件通信**：按需添加 `"commands"`、`"events"`。

---

## 三、目录结构与模板规范（参考 `examples/plugins/kanban-board/`）

### 1. 标准 `amber.plugin.v3` 目录结构

```text
<plugin-id>/
├── plugin.json    # 必填：manifest_version: 3, schema: "amber.plugin.v3", permissions, tools, ui
├── main.js        # 必填：onload() / onunload() 生命周期与后台工具实现
├── index.html     # 可选（当声明 ui.views 时必填）：通过 amber-plugin://<id>/ 加载
├── styles.css     # 可选：直接使用宿主注入的 --amber-* 主题 CSS 变量
└── board.js       # 可选：前端交互脚本，通过 window.amber.* 调用 Promise Bridge API
```

### 2. 全量 26 项沙箱与 WebView Bridge API（`amber.*` / `window.amber.*`）

宿主在后台 `JSContext`（`amber.*`）与前端 `WKWebView`（`window.amber.*`）中统一注入以下 26 个冻结 API：

| 命名空间 | 注入 API 列表 | 所需权限与行为说明 |
| --- | --- | --- |
| `settings` | `amber.settings.get`、`amber.settings.set`、`amber.settings.getAll` | 需 `"settings"`。读取/修改非敏感配置项（或内置 `"today"` / `"mode"`）；`secret` 字段加密存于 macOS Keychain，对 JS 恒返回 `""`。 |
| `storage` | `amber.storage.get`、`amber.storage.set`、`amber.storage.remove`、`amber.storage.keys`、`amber.storage.all` | 需 `"storage"`。读写插件专属 `storage.json`（支持任意 JSON 对象/数组，上限 10 MB）。 |
| `workspace` | `amber.workspace.read`、`amber.workspace.write`、`amber.workspace.list`、`amber.workspace.watch` | 读/列目录/监听需 `"workspace.read"`；写入需 `"workspace.write"` 且工具 `effect` 必须为 `"sideEffect"` 或 `"idempotent"`。严格拦截 `..` 路径穿越、绝对路径与符号链接。 |
| `http` | `amber.http.fetch` | 需 `"http:<domain>"`。仅允许 `https://` 且目标域名必须命中白名单，20 秒超时，返回 `{ ok, status, body, text, json }`。 |
| `commands` | `amber.commands.register`、`amber.commands.list` | 需 `"commands"`。动态注册或列出 `/` 斜杠指令与 `⌘K` 命令面板动作。 |
| `events` | `amber.events.on`、`amber.events.off`、`amber.events.emit` | 需 `"events"`。监听宿主事件（`conversation:changed`、`workspace:file_changed`、`theme:changed` 等）或在后台与多个 WebView 之间广播自定义事件。 |
| `ui` | `amber.ui.notice`、`amber.ui.confirm`、`amber.ui.openView`、`amber.ui.openModal`、`amber.ui.closeModal` | 需 `"ui.views"`。发送通知提示、弹出原生确认框、切换主工作区/侧栏插件视图或开关自定义模态弹窗。 |
| `agent` | `amber.agent.registerTool`、`amber.agent.getConversation`、`amber.agent.insertToComposer` | 需 `"agent.tools"`。动态注册智能体工具、获取当前会话脱敏摘要、将提示词安全填入底部输入框。 |

---

## 四、最小完整可运行模板（`note_helper` · `amber.plugin.v3`）

### 1. `note_helper/plugin.json`

```json
{
  "manifest_version": 3,
  "schema": "amber.plugin.v3",
  "id": "note_helper",
  "name": "会议纪要助手",
  "version": "3.0.0",
  "description": "统计纪要字数、附加统一前缀并归档到当前会话工作区。",
  "icon": "doc.text.magnifyingglass",
  "main": "main.js",
  "dev_reload": true,
  "permissions": [
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

### 2. `note_helper/main.js`

```javascript
function onload() {
  amber.events.on("workspace:file_changed", function () {});
}

function onunload() {}

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

> 若需编写带拖拽自定义 WebView 界面的插件，请直接参考 `examples/plugins/kanban-board/` 中的 `plugin.json`、`main.js`、`index.html`、`styles.css` 与 `board.js`。

---

## 五、交付前自检清单与安装验证流程

### 1. 必做自检清单（6 项）

1. [ ] **ID 与目录名一致**：文件夹名与 `plugin.json` 的 `id` 完全一致，符合 `^[a-z][a-z0-9_-]*$`（2–32 位），且未占用 `feishu_calendar`、`apple_schedule`、`watchtower`。
2. [ ] **权限声明完整且遵循最小权限原则**：`permissions` 数组已完整覆盖代码中调用的每一个 `amber.*` 命名空间能力，未申请多余权限；敏感凭据在 `settings_schema` 中均标记为 `"kind": "secret"`。
3. [ ] **没有路径或域名越界**：`capabilities.workspaceReadPrefixes` / `workspaceWritePrefixes` 与实际读写子目录严格匹配，无 `..` 路径穿越或绝对路径；`http:<domain>` 与 `capabilities.networkDomains` 仅填写纯 HTTPS 域名，未声明 `hostModules`。
4. [ ] **写类工具走高风险审批**：凡调用 `amber.workspace.write` 或发起外部写入的工具（无论静态声明还是 `amber.agent.registerTool` 动态注册），`effect` 均已声明为 `"sideEffect"` 或 `"idempotent"`。
5. [ ] **Schema 与静态资源合规**：每个工具的 `input_schema` 顶层均为 `"type": "object"`；所有 `ui.views` 的 `entry` HTML 与静态资源均通过 `amber-plugin://<id>/` 引用且无内联外链脚本。
6. [ ] **安装与验证闭环**：通过 `plugin_install`（或引导用户前往 **设置 (`⌘,`) → 插件 → + 导入插件** 批准权限并安装），随后使用 `plugin_list` 验证插件已启用且工具与视图均已注册。
