# 编写插件 · Amber 开发者指南

**一段话说清楚：** 一个 Amber 插件就是一个文件夹，里面放一份声明清单 `plugin.json`（协议为 `amber.plugin.v2`，兼容 `v1`）和一份脚本 `main.js`。Amber 使用 macOS 原生 JavaScriptCore 沙箱按需执行入口函数，无需安装 Node.js 或 Bun。开启插件后，它的工具会进入对话、子代理和 Recipe 自动流程；它的界面槽位会挂进左侧边栏、右侧检查器、主工作区画布、底部输入框 `/` 斜杠命令以及 `⌘K` 命令面板。

## 概览

插件用来把外部服务、领域工具或团队工作流装进 Amber。你在 `plugin.json` 里声明的一切，决定了插件能读写什么数据、向大模型暴露什么工具，以及在窗口的哪个角落出现：

**🔒 能力、凭据与工具**

- `capabilities`：声明允许访问的 HTTPS 域名白名单（`networkDomains`），以及允许读写的会话工作区子目录前缀（`workspaceReadPrefixes` / `workspaceWritePrefixes`）。`hostModules` 仅供官方内置插件使用，第三方插件声明会被拒绝。
- `settings_schema`：声明插件配置项。普通字段存 `UserDefaults`；标记为 `secret` 的字段自动加密存入 macOS 钥匙串（Keychain），不落明文、不进 JS 沙箱。
- `tools`：把 JS 函数注册成智能体工具（`plugin__<插件id>__<工具名>`），按 `effect` 等级自动接入审批流与工具账本。

**🪟 窗口里的界面槽位**

- `ui.inspectorCards`：在右侧检查器挂一张折叠卡片（窄窗下自动变成顶栏气泡浮层），由 `rebuildProjections()` 调用卡片的 `entry` 函数预先计算并缓存快照，点按钮直接把预设提示词填入输入框。
- `ui.workspaceViews`：在左侧边栏「插件视图」挂出独立主工作区入口（含徽章计数 `badgeCount`、顶栏 `< 返回对话` 按钮、标题/副标题与快捷命令列表）。
- `ui.commands`：同时向底部输入框 `/` 斜杠补全浮层与 `⌘K` 全局命令面板注入快捷指令。

---

## 五分钟写一个插件

下面写一个「会议纪要助手（`note_helper`）」插件：它包含一个配置项（纪要标题前缀）、一个只读工具 `format_note`、一个写入会话工作区 `notes/` 的工具 `save_note`、一张右侧检查器卡片，以及一条斜杠命令 `/note-format`。这个例子在 Amber 的插件单测套件中可直接跑通。

### 第一步：创建文件夹与 `plugin.json`

新建文件夹 `note_helper/`，写入 `plugin.json`：

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

### 第二步：编写 `main.js`

在同一文件夹下创建 `main.js`：

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

### 第三步：导入到 Amber 并试用

1. 打开 Amber，按 `⌘,` 进入 **设置 → 插件**。
2. 点击左下角 **「+ 导入插件」**，选中刚才创建的 `note_helper` 文件夹（或里面的 `plugin.json`）。
3. 左侧「扩展插件」列表会出现 **会议纪要助手** `v1.0.0`，状态圆点为琥珀色（已启用）。
4. 回到主窗口试用：
   - 在底部输入框输入 `/note`，补全浮层会列出 `/note-format`，回车即可填入提示词；
   - 或直接对 Amber 说：「用会议纪要助手格式化这段话：确认周五上线 v2.0」。因为 `format_note` 的 `effect` 是 `pure`，智能体会直接执行，不会弹窗打断你；而调用 `save_note` 写入工作区文件时，Amber 会先弹出审批卡片供你确认。

---

## Amber 如何运行插件

- **原生 JavaScriptCore 沙箱：** Amber 直接调用 macOS 系统内置的 `JavaScriptCore`（`JSContext`）在后台队列运行插件工具脚本，绝不阻塞 `@MainActor`。每次工具调用都在全新创建的独立 `JSContext` 中执行，跑完立即销毁，插件之间不共享任何全局状态。
- **主线程零 IO 投影：** 所有外部网络请求都在后台任务中完成；用于 SwiftUI 渲染的界面数据（右侧栏卡片快照 `DesktopInspectorCardSnapshot`、侧栏徽章 `badgeCount`、斜杠命令列表）全部在 `DesktopPluginStore.rebuildProjections()` 中预先计算缓存，SwiftUI 视图渲染期零 JS 执行、零磁盘/钥匙串 IO。
- **安装与热重载：**
  - 在 **设置 → 插件** 点 **「+ 导入插件」** 选择文件夹或 `plugin.json`，Amber 校验通过后会将文件原子拷贝到应用支持目录。
  - 改完代码后，点设置面板左下角的 **「↻ 重新加载」** 按钮（或把插件关掉再打开），新逻辑立即生效。
- **网络白名单守卫（Capability Broker）：** 插件调用 `amber.http.fetch(url, options)` 或宿主 `performAuthorizedHTTP` 时，仅放行 `https://` 协议，且目标主机必须精确匹配 `capabilities.networkDomains`（或其子域名）。未声明的域名或明文 `http://` 会被当场拦截，单次请求超时固定为 20 秒。
- **会话工作区前缀守卫：** 插件调用 `amber.workspace.read(path)` / `amber.workspace.write(path, content)` 时，路径必须是当前会话工作区内的相对路径，且必须命中 `workspaceReadPrefixes` / `workspaceWritePrefixes` 声明的前缀；任何 `..` 路径穿越、绝对路径或符号链接（symlink）逃逸都会被立即拒绝。

Amber 在应用支持目录（`~/Library/Application Support/Amber/plugins/`）与系统存储中按以下结构管理插件数据：

| 存储位置 | 存放内容 |
| --- | --- |
| `plugins/<id>/plugin.json` | 已安装扩展插件的清单文件（体积上限 256 KB）。 |
| `plugins/<id>/main.js` | 插件的 JavaScript 入口脚本。 |
| `plugins/<id>/storage.json` | 插件通过 `amber.storage.set` 写入的键值字典（按键排序原子落盘）。 |
| `UserDefaults` (`desktop.plugins.settings.v1.<id>`) | 插件的非敏感配置项（`string`、`boolean`、`integer`）。 |
| `Keychain` (`app.amber.macos.plugins.credentials`) | 插件的 `secret` 凭据，按 `SHA256("amber.plugin.secret.<id>.<key>")` 派生确定性 UUID 独立存放在 macOS 钥匙串中。 |

---

## 包的结构

每个扩展插件独占 `~/Library/Application Support/Amber/plugins/<id>/` 下的一个同名子文件夹：

- 清单文件名固定为 `plugin.json`；
- 脚本文件名固定为同级目录下的 `main.js`（纯 UI 或快捷命令型插件可以不带 `main.js`）；
- **目录名校验：** 文件夹名称必须与 `plugin.json` 中的 `id` 完全一致，否则加载时会被拒绝。

### `plugin.json` 顶层字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schema` | `string` | 否 | 协议版本，默认 `"amber.plugin.v2"`，向下兼容 `"amber.plugin.v1"`。 |
| `id` | `string` | 是 | 插件唯一标识：2–32 位，以小写字母开头，仅含小写字母、数字和下划线（`^[a-z][a-z0-9_]*$`）。`feishu_calendar`、`apple_schedule`、`watchtower` 为官方内置插件保留 ID，第三方插件不可使用。 |
| `name` | `string` | 是 | 设置页、侧栏和命令面板里展示的插件名称。 |
| `version` | `string` | 是 | 版本号字符串，如 `"2.0.0"`。 |
| `description` | `string` | 是 | 一句话功能说明。 |
| `icon` | `string` | 否 | SF Symbols 图标名称，默认 `"puzzlepiece.extension"`。 |
| `capabilities` | `object` | 否 | 权限与沙箱边界：`{ networkDomains: [], workspaceReadPrefixes: [], workspaceWritePrefixes: [] }`（`hostModules` 仅限官方内置插件）。 |
| `settings_schema` | `array` | 否 | 插件配置项定义数组。 |
| `tools` | `array` | 否 | 注册给智能体的工具声明数组。 |
| `ui` | `object` | 否 | 界面槽位声明：`{ inspectorCards: [], workspaceViews: [], commands: [] }`。 |

---

## 配置与凭据 (`settings_schema`)

当用户在 **设置 → 插件** 选中你的插件时，Amber 会按 Arquiel Design 2.0 信息架构将配置项自动归类为「连接设置 / 通用设置 / 高级设置（默认折叠）」，或根据 `group` 字段拆分成顶部切换的分段 Tab（比如飞书插件拆成了「飞书日历」和「飞书机器人」两个模块）。

```json
{
  "key": "caldav_password",
  "title": "CalDAV 密码",
  "kind": "secret",
  "placeholder": "安全保存在系统钥匙串中",
  "defaultValue": "",
  "help": "飞书 CalDAV 专用密码，用于同步与新建个人飞书日程。",
  "group": "calendar"
}
```

| 字段 | 含义 |
| --- | --- |
| `key` | 配置项键名，读取配置时用作参数。 |
| `title` | 输入框上方显示的中文标签。 |
| `kind` | 取值 `"string"`（默认）、`"secret"`、`"boolean"` 或 `"integer"`。 |
| `placeholder` | 输入框占位提示文本（保存时会校验拦截把占位示例文字当真凭据保存的误操作）。 |
| `defaultValue` | 用户未填写时的默认值（兼容 snake_case 写法 `default_value`）。 |
| `help` | 输入框下方最多两行的辅助说明文字。 |
| `group` | 可选分组标识（如 `"calendar"` / `"bot"` / `"advanced"`），用于分组或归入高级折叠区。 |

**为什么在脚本里调用 `amber.settings.get()` 读不到 `secret` 字段？**
这是特意设计的安全边界。标记为 `kind: "secret"` 的字段在设置页渲染为掩码密码框（带「钥匙串加密」徽章），保存时会自动从 `UserDefaults` 剔除并写入 macOS Keychain。它**绝不会**注入到 JavaScript 沙箱中——这样即使遇到恶意第三方脚本或提示词注入，也无法把你的密码或 API Key 拼进工具返回值发给远端大模型。

---

## 给每个会话的工具 (`tools`)

插件在 `tools` 数组里声明的每个工具，开启后都会注册进 `DesktopToolRegistry`，对话、子代理（Subagent）和自动流程（Recipe）都能直接调用。

- **工具命名：** 为了防止不同插件或内置工具撞名，大模型看到的完整工具名固定为 `plugin__<插件id>__<工具name>`（双下划线分隔）。比如 `feishu_calendar` 下的 `list_events`，注册名为 `plugin__feishu_calendar__list_events`。
- **三种参数 Schema 写法（任选其一，自动归一化）：**
  1. `input_schema`（推荐）：直接写标准 JSON Schema 对象；
  2. `parameters_json`：写转义后的 JSON Schema 字符串；
  3. `inputs`（兼容 `v1` 简写）：写 `{"city": "string", "days": "integer"}`，Amber 会自动展开成全字段必填的 JSON Schema object。

```json
{
  "name": "list_events",
  "description": "查询飞书日历中的日程列表（可按日期 yyyy-MM-dd 或关键词筛选）。",
  "effect": "networkRead",
  "entry": "listEvents",
  "input_schema": {
    "type": "object",
    "properties": {
      "date": { "type": "string", "description": "可选日期 yyyy-MM-dd" },
      "query": { "type": "string", "description": "可选关键词过滤" }
    },
    "additionalProperties": false
  }
}
```

### 副作用等级（`effect`）与高风险审批规则

每个工具都要声明准确的 `effect`（不填默认为 `"pure"`）。Amber 的智能体引擎和后台定时任务严格按这个字段执行安全策略：

| `effect` 值 | 设置页徽章 | 风险等级与审批规则 | 典型场景 |
| --- | --- | --- | --- |
| `"pure"` | `只读` | **免批准**，直接执行（禁止调用 `amber.workspace.write`） | 本地文本处理、格式化、读写插件自己的 `storage.json`。 |
| `"networkRead"` | `网络读取` | **免批准**，直接执行（禁止调用 `amber.workspace.write`） | 查日历日程、算忙闲空档、拉群聊历史、受控读取外部 HTTPS 接口。 |
| `"idempotent"` | `幂等变更（需批准）` | **高风险（必须桌面端人工批准）** | 带幂等键覆盖更新状态、写入工作区文件或幂等同步。 |
| `"sideEffect"` | `外部写入（需批准）` | **高风险（必须桌面端人工批准）** | 创建日历日程、往群里发卡片、新建云文档、写入工作区文件。 |

> **安全边界说明：** 在 Amber 中，插件工具的 `"idempotent"` 与 `"sideEffect"` 均被归类为**高风险操作（High Risk）**——它们不受普通「自动批准工具」开关豁免，必须在桌面端主窗口由用户明确批准；通知横幅、锁屏界面及手机端远程卡片对高风险插件工具**只能拒绝、不能批准**。

### 对话流工具卡片的结构化预览

工具执行完返回 JSON 对象后，对话流里的 `DesktopToolCallCard` 会自动识别常见返回字段，在展开区顶部渲染一条琥珀色高亮摘要，不需要插件写任何 UI 代码：

| 返回 JSON 中包含的字段 | 对话流卡片自动渲染的摘要徽章 |
| --- | --- |
| `event: { summary, start_time, location }` | 📅 `<summary>（<start_time> · <location>）` |
| `count` + `events` 数组 | 📅 `共读取 <count> 项飞书日历日程` |
| `free_slots` 数组 | 🕒 `发现 <N> 个可约空闲时段` |
| `message_id` + `title` (+ `target`) | ✈️ `已推送至 <target>：<title>` |
| `count` + `messages` 数组 (+ `chat_id`) | 💬 `已拉取 <chat_id> 近 <count> 条消息` |
| `document_id` + `title` | 📄 `<title>（<document_id>）` |

---

## 窗口里的界面槽位 (`ui`)

除了给大模型注册工具，插件还可以把自己的交互入口挂进 Amber 窗口的四个位置：

```json
"ui": {
  "inspectorCards": [
    {
      "id": "today_agenda",
      "title": "今日飞书日程",
      "symbol": "calendar.badge.clock",
      "entry": "renderTodayInspector"
    }
  ],
  "workspaceViews": [
    {
      "id": "calendar_board",
      "title": "飞书日历",
      "symbol": "calendar",
      "subtitle": "通过 CalDAV 直连同步个人飞书日历，查看排期忙闲或将会议一键推送至飞书群。"
    },
    {
      "id": "bot_studio",
      "title": "飞书机器人",
      "symbol": "paperplane.circle",
      "subtitle": "通过飞书群 Webhook 或自建应用机器人发送消息卡片、拉取群聊纪要、读写飞书云文档。"
    }
  ],
  "commands": [
    {
      "id": "feishu_notify",
      "title": "通过飞书机器人发送群通知卡片",
      "slash": "/feishu-notify",
      "symbol": "paperplane",
      "prompt_template": "请将当前对话的核心结论整理成结构化要点，并调用飞书机器人工具（bot_send_message）发送一张飞书消息卡片到群里。"
    }
  ]
}
```

### 1. 右侧检查器卡片（`inspectorCards`）

- 插件启用后，`DesktopPluginStore.rebuildProjections()` 会调用卡片声明的 `entry` 函数，将返回的 `{ statusBadge, emptyMessage, footerActionTitle, items: [{ id, badge, title, subtitle, actionTitle, prompt }] }` 缓存为 `DesktopInspectorCardSnapshot`，在右侧栏（Inspector）「当前回合」下方直接渲染（SwiftUI 渲染期零 JS 调用、零 IO）。
- 当窗口宽度窄于 `1100pt` 自动收起右侧栏时，顶部工具栏会出现一个快捷气泡按钮，点开就能在浮层（`DesktopPluginInspectorPopoverView`）里查看同一张卡片。
- 条目采用**双行零截断布局**：第一行放时间/状态胶囊和右侧动作按钮（如「准备」），第二行完整显示标题与副标题。点动作按钮会自动切回对话视图、填入预设 `prompt`、开启工具开关并聚焦输入框。

### 2. 主工作区视图（`workspaceViews`）

- 一个插件可以声明一个或多个主工作区视图。
- 开启后，左侧边栏底部「插件视图」分组会列出每个视图及其数字徽章（`badgeCount`，可通过 `storage` 的 `badge:<viewID>` / `badge_count` 设置，或默认取检查器卡片条目数）。
- 点击侧栏条目，主画布会从 `.chat` 切换到 `.pluginView(pluginID:viewID:)`，左上角固定提供 `< 返回对话` 按钮，并展示插件标题、副标题与快捷命令列表（宿主不执行插件自定义动态 UI 渲染代码）。
- **状态对账保护：** 如果用户正停留在某个插件的主工作区页面，这时去设置里停用或卸载了该插件，`DesktopWorkspace.reconcilePluginState()` 会立即把主画布切回 `.chat`，不会留在失效页面。

### 3. `/` 斜杠命令与 `⌘K` 命令面板（`commands`）

- `slash` 必须以 `/` 开头（如 `"/feishu-today"`）。
- 用户在底部输入框以 `/` 开头打字时，`DesktopComposer` 会在输入框上方弹出补全浮层，支持按英文命令或中文标题实时过滤。
- 按 `⌘K` 呼出全局命令面板（`DesktopCommandPaletteView`）时，插件注册的所有 `workspaceViews` 和 `commands` 都会进入检索列表，支持上下方向键选择、回车执行、`ESC` 关闭。

---

## 插件能拿到什么 (`amber.*`)

在 `main.js` 中，Amber 注入了一个冻结的全局对象 `amber`（`Object.freeze`）：

| API 调用 | 作用与返回值 |
| --- | --- |
| `amber.settings.get(key)` | 返回 `settings_schema` 中对应非敏感配置项的字符串值（未填时返回 `defaultValue`）。**绝不返回 `secret` 字段**。 |
| `amber.settings.get("today")` | 宿主自动注入的当天日期，格式固定为 `yyyy-MM-dd`（如 `"2026-10-30"`）。 |
| `amber.settings.get("mode")` | 宿主注入的运行模式：已配置远端凭据时为 `"feishu"`，否则为 `"local"`。 |
| `amber.storage.get(key)` | 从该插件专属的 `storage.json` 中读取字符串值；键不存在时返回 `""`。 |
| `amber.storage.set(key, val)` | 将值写入该插件的 `storage.json`。`val` 为对象或数组时自动 `JSON.stringify(val)`。工具返回后若发生过写入，宿主会自动落盘并刷新所有 UI 投影。 |
| `amber.http.fetch(url, options)` | 受控 HTTPS 请求：仅允许 `https://` 且目标域名必须匹配 `capabilities.networkDomains`（精确匹配或子域名），超时固定 20 秒。返回 `{ ok, status, body, text, json }`；非 HTTPS 或未授权域名直接抛出异常。 |
| `amber.workspace.read(path)` | 读取当前会话工作区内匹配 `capabilities.workspaceReadPrefixes` 的 UTF-8 文本文件；拒绝 `..` 路径穿越与符号链接。 |
| `amber.workspace.write(path, content)` | 向当前会话工作区内匹配 `capabilities.workspaceWritePrefixes` 的路径原子写入 UTF-8 文本；仅允许 `effect` 为 `"sideEffect"` 或 `"idempotent"` 的工具调用，拒绝 `..` 路径穿越与符号链接。 |

入口函数名由 `tools[i].entry` 指定（不填时默认与 `tools[i].name` 同名），接收大模型传入的参数对象并返回任意可 JSON 序列化的结果：

```javascript
function myToolEntry(input) {
  // input 是大模型传入的 JSON 参数对象（已解析为 JS Object）
  return {
    ok: true,
    result: "处理完成"
  };
}
```

---

## 官方内置扩展插件与核心插件

### 1. 官方内置扩展插件（保留 ID）

Amber 内置了 3 个官方扩展插件，它们的 ID 为系统保留字，第三方插件不能使用同名 ID：

- `feishu_calendar`（**飞书** `v2.0.0`）：包含「飞书日历（CalDAV 免审批直连 + OpenAPI 回退）」与「飞书机器人（群 Webhook HMAC-SHA256 签名卡片推送、群聊纪要拉取、云文档读写及 `meeting_closeout` 幂等会后收口）」两大模块。
- `apple_schedule`（**系统日历与提醒**）：通过宿主原生 `EventKit`（`hostModules: ["calendar"]`）读写 macOS 日历与提醒事项，脚本不直接接触系统权限。
- `watchtower`（**网页观察哨**）：定期巡检指定网页变化并汇总摘要。

### 2. 核心插件 (`Core Plugins`)

除了外部扩展插件，Amber 借鉴 Obsidian 的思路，把 5 项内置一级功能做成了可独立开关的 **核心插件（`DesktopCorePlugin`）**。你可以在 **设置 → 插件 → 核心插件** 里关掉用不到的模块，让侧栏和模型的工具上下文保持干净：

| 核心插件 ID | 名称 | 停用后自动隐藏的智能体工具 (`governedToolNames`) |
| --- | --- | --- |
| `task_board` | 任务看板与定时任务 | `schedule_list`、`schedule_create`、`schedule_update`（同时隐藏侧栏「任务看板」入口） |
| `knowledge` | 知识与长期记忆 | `skills_list`、`use_skill`、`skill_enable`、`skill_disable`、`memory_tool` |
| `collaborations` | 多模型协作与议会 | `subagent_dispatch`、`list_agents`、`interrupt_agent`、`model_council_run` |
| `recipes` | Recipe 自动流程 | 停用 Recipe 自动化流程面板与执行入口 |
| `image_generation` | 图片生成工作台 | 停用图像模型生成工作台与生图入口 |

---

## 测试、调试与自检清单

### 编写自动化单元测试

在 `AmberMacTests/DesktopPluginTests.swift` 中，你可以注入内存版 `UserDefaults`、`DesktopMemoryCredentials`（替代真实钥匙串）以及 `MockPluginHTTPTransport`（替代真实网络），在不改动本机配置的前提下跑通端到端测试：

```swift
let transport = MockPluginHTTPTransport()
let store = DesktopPluginStore(
    directory: tempDirectory,
    workspaceDirectory: tempWorkspaceDirectory,
    defaults: defaults,
    credentials: credentials,
    httpTransport: transport,
    referenceDateProvider: { fixedDate }
)

let pluginID = try store.importPlugin(from: myPluginDirectoryURL)
let output = try await store.executeTool(
    qualifiedName: "plugin__\(pluginID)__my_tool",
    argumentsJSON: #"{"query":"hello"}"#
)
```

### 宿主核心代码索引

| 源码文件 (`macApp/AmberMac/`) | 职责 |
| --- | --- |
| `Runtime/DesktopPlugins.swift` | 插件生命周期、清单校验、Keychain 隔离、后台 JSC 沙箱、受控 HTTPS (`amber.http.fetch`)、受控工作区文件桥 (`amber.workspace`)、飞书 CalDAV / Bot 通道与零 IO 视图投影。 |
| `Runtime/DesktopToolRegistry.swift` | 维护插件工具副作用表 `registeredPluginEffects`，合并已启用扩展插件工具并过滤已停用的核心插件工具。 |
| `Runtime/DesktopAgentProvider.swift` | 在对话回合与 Recipe 步骤中拦截 `plugin__*` 调用，按 `toolEffect` 执行或请求用户审批。 |
| `UI/DesktopPluginsSettingsView.swift` | 设置面板「插件」标签页：管理核心/扩展插件开关、分组渲染配置表单、展示权限边界与能力矩阵。 |
| `UI/DesktopPluginWorkspaceView.swift` | 主工作区插件画布（飞书日历看板、飞书机器人工作台、通用插件视图）与 `⌘K` 全局命令面板。 |

### 插件发布前 6 项自检清单

- [x] 文件夹名称与 `plugin.json` 中的 `id` 完全一致，符合 `^[a-z][a-z0-9_]*$`（2–32 位），且不占用保留 ID（`feishu_calendar`、`apple_schedule`、`watchtower`）。
- [x] 所有敏感 Token / 密码在 `settings_schema` 中均已标记为 `"kind": "secret"`，不写入普通配置。
- [x] 外部请求的目标域名已全部填入 `capabilities.networkDomains`（仅写纯域名，不含 `https://` 或斜杠），工作区读写前缀已填入 `workspaceReadPrefixes` / `workspaceWritePrefixes`。
- [x] 每个工具都标注了准确的 `effect`：只读查询用 `pure` / `networkRead`，写操作（含 `amber.workspace.write`）必须标为 `sideEffect` 或 `idempotent`。
- [x] 每个工具的 `input_schema` 顶层均为 `"type": "object"`，字段带有清晰中文 `description`。
- [x] 在 **设置 → 插件** 点击「↻ 重新加载」无红色校验报错，`/` 斜杠命令、右侧检查器卡片与 `⌘K` 面板均可正常检索触发。

---

## 常见答疑（FAQ）

**Q1：为什么大模型看到的工具名叫 `plugin__xxx__yyy`？**
为了避免多个插件声明同名工具（比如都叫 `search` 或 `list`）产生冲突，Amber 统一使用 `plugin__<插件id>__<工具name>` 作为完整工具名。你在 `plugin.json` 的 `tools` 里只需要写短名字（如 `list_events`）。

**Q2：旧的 `amber.plugin.v1` 插件不改能直接用吗？**
可以。`DesktopPluginManifest` 同时接受 `"amber.plugin.v2"` 和 `"amber.plugin.v1"`，并且兼容 `v1` 的 `script` 字段（自动映射为 `entry`）和简写的 `inputs` 参数表（自动转换为标准 JSON Schema）。

**Q3：为什么我的插件请求外部接口时报「未授权访问域名」？**
所有外部请求都会经过受控 HTTPS 白名单校验：必须是 `https://` 地址，且目标域名必须列在 `plugin.json` 的 `capabilities.networkDomains` 数组中（只写纯域名如 `"open.feishu.cn"`，不要带协议头或路径）。

**Q4：怎么让 Amber 立即看到我对插件文件的修改？**
通过「导入插件」安装的插件，其运行副本位于 `~/Library/Application Support/Amber/plugins/<id>/`。直接编辑该目录下的 `plugin.json` 或 `main.js`（或重新导入覆盖），然后点 **设置 → 插件** 左下角的 **「↻ 重新加载」** 按钮即可立即生效。
