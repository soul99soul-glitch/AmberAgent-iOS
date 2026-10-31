---
name: plugin-development
description: >
  指导在 Amber macOS 中设计、编写、自检与手动导入 amber.plugin.v2 扩展插件（含受控 HTTPS、工作区前缀读写、检查器卡片与高风险审批规范）。
allowed-tools: [skills_list, use_skill, workspace_list, workspace_read, workspace_write]
---

# Amber macOS 插件开发技能（`plugin-development`）

本技能用于指导为 Amber macOS 编写符合 `amber.plugin.v2` 协议与 Arquiel Design 2.0 规范的扩展插件。

## 一、核心铁律（必须遵守）

1. **严禁静默安装或直接启用插件**：
   - 协助用户编写插件时，**只能在当前会话工作区**（例如 `<id>/plugin.json` 与 `<id>/main.js`）生成插件草稿。
   - **绝不允许**直接读写或拷贝到 `~/Library/Application Support/Amber/plugins/`，也绝不允许尝试替用户自动安装或启用插件。
   - 草稿生成并完成 6 项自检后，必须引导用户通过 **「设置 (`⌘,`) → 插件 → + 导入插件」** 手动导入，或在修改后点击 **「↻ 重新加载」**。
2. **保留 ID 与核心插件边界**：
   - 官方内置扩展插件保留 ID 为 `feishu_calendar`、`apple_schedule`、`watchtower`，第三方插件禁止使用。
   - 5 个一级核心插件 ID 为 `task_board`、`knowledge`、`collaborations`、`recipes`、`image_generation`。
   - `capabilities.hostModules`（如 `["calendar"]`）**仅供官方内置插件使用**，第三方插件若声明 `hostModules` 会在导入和加载时被直接拒绝。
3. **高风险审批边界**：
   - 工具 `effect` 仅支持 `"pure"`、`"networkRead"`、`"idempotent"`、`"sideEffect"`。
   - `"pure"` 与 `"networkRead"` 为只读工具，免审批直接执行，但**严禁调用 `amber.workspace.write`**。
   - `"idempotent"` 与 `"sideEffect"` **均属于高风险操作（High Risk）**：必须在 Mac 桌面端主窗口由用户人工批准，不受普通「自动批准」开关豁免；通知横幅、锁屏界面与手机端远程审批对高风险工具**只能拒绝、不能批准**。

---

## 二、`plugin.json` 规范与字段定义

每个插件是一个独立文件夹，文件夹名必须与 `plugin.json` 中的 `id` 完全一致：

| 字段 | 类型 | 必填 | 规范说明 |
| --- | --- | --- | --- |
| `schema` | `string` | 否 | 固定写 `"amber.plugin.v2"`（兼容 `"amber.plugin.v1"`）。 |
| `id` | `string` | 是 | 2–32 位，符合 `^[a-z][a-z0-9_]*$`，与目录名完全一致，且不可占用保留 ID。 |
| `name` | `string` | 是 | 插件中文/显示名称。 |
| `version` | `string` | 是 | 语义化版本号，如 `"1.0.0"`。 |
| `description` | `string` | 是 | 一句话清晰描述插件用途。 |
| `icon` | `string` | 否 | SF Symbols 图标名，默认 `"puzzlepiece.extension"`。 |
| `capabilities` | `object` | 否 | `{ "networkDomains": [], "workspaceReadPrefixes": [], "workspaceWritePrefixes": [] }`。第三方插件不得声明 `hostModules`。 |
| `settings_schema` | `array` | 否 | 配置项数组：`{ key, title, kind, placeholder, defaultValue, help, group }`。`kind` 支持 `"string"`、`"secret"`、`"boolean"`、`"integer"`。 |
| `tools` | `array` | 否 | 工具数组：`{ name, description, effect, entry, input_schema }`。模型侧完整工具名为 `plugin__<id>__<name>`。 |
| `ui` | `object` | 否 | 界面槽位：`{ inspectorCards: [], workspaceViews: [], commands: [] }`。 |

### Arquiel Design 2.0 界面与配置规范

- **设置页分层降噪**：Amber 会将 `settings_schema` 自动归类为「连接设置（含 `secret` / URL / Key）/ 通用设置 / 高级设置（`group: "advanced"`，默认折叠）」。敏感凭据必须标记 `"kind": "secret"`（自动存入 macOS Keychain，绝不进 `UserDefaults` 或 JS 沙箱，且保存时拦截把 placeholder 占位符当真凭据的误操作）。
- **右侧检查器卡片（`ui.inspectorCards`）**：声明 `{ id, title, symbol, entry }`。宿主在 `rebuildProjections()` 中调用 `entry` 函数并将结果缓存为 `DesktopInspectorCardSnapshot`（SwiftUI 渲染期零 JS 调用、零磁盘/钥匙串 IO）。条目采用双行零截断布局。
- **主工作区视图（`ui.workspaceViews`）**：声明 `{ id, title, symbol, subtitle }`。侧栏显示入口与 `badgeCount`（可通过 `storage` 的 `badge:<viewID>` / `badge_count` 控制，或默认取检查器卡片条目数），主画布提供 `< 返回对话` 按钮、标题/副标题与快捷命令列表；插件停用时由 `reconcilePluginState()` 自动切回 `.chat`。
- **斜杠命令（`ui.commands`）**：声明 `{ id, title, slash, symbol, prompt_template }`，`slash` 必须以 `/` 开头，同时注入底部输入框 `/` 补全与 `⌘K` 命令面板。

---

## 三、JavaScript 沙箱注入 API（`amber.*`）

每次工具执行都在后台队列的独立 `JSContext` 中运行，不阻塞 `@MainActor`。沙箱内注入且仅注入以下 6 个冻结接口：

| 注入 API | 签名与行为说明 |
| --- | --- |
| `amber.settings.get` | `amber.settings.get(key)`：读取非敏感配置项值（或内置 `"today"` / `"mode"`）。**绝不返回 `secret` 字段**（读取 `secret` 键恒返回 `""`）。 |
| `amber.storage.get` | `amber.storage.get(key)`：读取插件专属 `storage.json` 中的字符串值，不存在时返回 `""`。 |
| `amber.storage.set` | `amber.storage.set(key, val)`：写入插件专属 `storage.json`（对象/数组自动 JSON 序列化），工具返回后原子落盘并触发 `rebuildProjections()`。 |
| `amber.http.fetch` | `amber.http.fetch(url, options)`：受控 HTTPS 请求。仅允许 `https://`，目标主机必须匹配 `capabilities.networkDomains`（精确匹配或子域名），固定 20 秒超时。返回 `{ ok, status, body, text, json }`。 |
| `amber.workspace.read` | `amber.workspace.read(path)`：读取当前会话工作区内匹配 `capabilities.workspaceReadPrefixes` 的 UTF-8 文本文件；拒绝 `..` 路径穿越、绝对路径与符号链接。 |
| `amber.workspace.write` | `amber.workspace.write(path, content)`：向当前会话工作区内匹配 `capabilities.workspaceWritePrefixes` 的相对路径原子写入 UTF-8 文本；仅允许 `sideEffect` 或 `idempotent` 工具调用，拒绝 `..` 与符号链接。 |

### 对话流工具卡片的结构化预览字段

工具返回 JSON 对象时，若包含以下字段，`DesktopToolCallCard` 会自动渲染高亮摘要：
- `event: { summary, start_time, location }` → 📅 日程摘要
- `count` + `events` 数组 → 📅 日程列表计数
- `free_slots` 数组 → 🕒 可约空闲时段计数
- `message_id` + `title` (+ `target`) → ✈️ 消息推送回执
- `count` + `messages` 数组 (+ `chat_id`) → 💬 群聊消息拉取计数
- `document_id` + `title` → 📄 文档读写摘要

---

## 四、最小完整示例（`note_helper`）

### 1. `note_helper/plugin.json`

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

### 2. `note_helper/main.js`

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

---

## 五、交付前 6 项自检清单与常见错误排查

### 6 项必做自检

1. [ ] 文件夹名与 `plugin.json` 的 `id` 完全一致，符合 `^[a-z][a-z0-9_]*$`（2–32 位），且未占用 `feishu_calendar`、`apple_schedule`、`watchtower`。
2. [ ] 所有敏感密码/Token 在 `settings_schema` 中均标记为 `"kind": "secret"`，且脚本未试图通过 `amber.settings.get` 读取密钥。
3. [ ] `capabilities.networkDomains` 仅填写纯域名（不含 `https://`、端口或斜杠），读写工作区文件已声明 `workspaceReadPrefixes` / `workspaceWritePrefixes`，且未声明 `hostModules`。
4. [ ] 凡调用 `amber.workspace.write` 或产生外部变更的工具，`effect` 均已声明为 `"sideEffect"` 或 `"idempotent"`。
5. [ ] 每个工具的 `input_schema` 顶层均为 `"type": "object"`，字段附带清晰中文 `description`。
6. [ ] 已向用户说明：请前往 **设置 (`⌘,`) → 插件 → + 导入插件** 手动选择工作区中的插件文件夹完成安装。

### 常见错误排查表

| 报错现象 | 原因分析 | 修复方法 |
| --- | --- | --- |
| `插件目录名与 plugin.json id 不一致` | 文件夹名与 `id` 字段不匹配 | 将文件夹重命名为与 `id` 完全相同的名称 |
| `插件域名白名单格式无效` | `networkDomains` 含 `https://`、`:` 或 `/` | 改为纯域名，例如 `"api.example.com"` |
| `hostModules 仅供官方内置插件使用` | 第三方插件声明了 `hostModules` | 从 `capabilities` 中移除 `hostModules` |
| `插件仅允许访问 HTTPS 地址` | 调用 `amber.http.fetch` 传入了 `http://` | 改用 `https://` 地址 |
| `未授权访问域名` | 请求域名未列入 `networkDomains` | 将目标域名加入 `capabilities.networkDomains` |
| `未授权访问工作区路径` | 路径未命中 `workspaceReadPrefixes` / `workspaceWritePrefixes` | 在 `capabilities` 中补充对应子目录前缀（如 `"notes/"`） |
| `只读工具禁止调用 amber.workspace.write` | 工具 `effect` 为 `pure` 或 `networkRead` | 将工具 `effect` 改为 `"sideEffect"` 或 `"idempotent"` |
