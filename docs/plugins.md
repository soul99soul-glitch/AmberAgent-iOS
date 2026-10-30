# 编写插件 · Amber 文档

**目录**
- [概览](#overview)
- [五分钟写一个插件](#quickstart)
- [Amber 如何运行插件](#runtime)
- [包的结构](#structure)
- [配置与凭据 (`settings_schema`)](#settings)
- [给每个会话的工具 (`tools`)](#tools)
- [窗口里的界面槽位 (`ui`)](#ui-slots)
- [插件能拿到什么 (`amber.*`)](#sandbox-api)
- [实战范例：内置「飞书（日历 & 机器人）」插件](#feishu-case)
- [核心插件 (`Core Plugins`)](#core-plugins)
- [测试与调试](#testing)
- [宿主协议与内部机制](#host-protocol)
- [答疑](#faq)

---

## 概览 {#overview}

插件把外部服务、领域工具或工作流装进 Amber。开启插件后，它的工具会进入对话、子代理和 Recipe 自动流程；它的界面槽位会挂进左侧边栏、右侧检查器（Inspector）、主工作区画布、底部输入框的 `/` 斜杠命令以及 `⌘K` 全局命令面板。

**一段话说清楚。** 一个插件就是一个文件夹，里面放一份声明清单 `plugin.json`（协议为 `amber.plugin.v2`，向后兼容 `amber.plugin.v1`）和一份脚本 `main.js`。Amber 在原生 JavaScriptCore 沙箱里按需执行 `main.js` 中的入口函数。`plugin.json` 决定五件事：

- **`capabilities`** 声明插件被允许访问哪些 HTTPS 域名、允许读写会话工作区下的哪些子目录前缀。
- **`settings_schema`** 声明插件的配置项。普通字段存进 `UserDefaults`；标记为 `secret` 的字段自动加密存进 macOS 系统钥匙串（Keychain），永不落盘成明文，也不会暴露给大模型。
- **`tools`** 把 JavaScript 函数注册成智能体工具（命名为 `plugin__<插件id>__<工具名>`），并按 `effect`（`pure`、`networkRead`、`idempotent`、`sideEffect`）自动接入 Amber 的工具审批流与账本（Ledger）。
- **`ui.inspectorCards`** 在右侧栏挂一张折叠卡片（例如「今日飞书日程」），点卡片上的动作按钮就能把预设 Prompt 带入对话输入框并自动聚焦。
- **`ui.workspaceViews` 与 `ui.commands`** 在左侧边栏挂出主工作区视图入口，并向底部输入框 `/` 和 `⌘K` 命令面板注入快捷命令。

---

## 五分钟写一个插件 {#quickstart}

下面这个例子写一个「会议纪要助手（`note_helper`）」插件：它提供一个配置项（纪要标题前缀）、一个只读工具 `format_note`、以及一条斜杠命令 `/note-format`。整个例子已在 Amber 插件单测套件中跑通。

### 1. 创建文件夹与 `plugin.json`

新建文件夹 `note_helper/`，写入 `plugin.json`：

```json
{
  "schema": "amber.plugin.v2",
  "id": "note_helper",
  "name": "会议纪要助手",
  "version": "1.0.0",
  "description": "统计纪要字数、附加统一前缀并记录处理次数。",
  "icon": "doc.text.magnifyingglass",
  "capabilities": {
    "networkDomains": [],
    "workspaceReadPrefixes": [],
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
    }
  ],
  "ui": {
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

### 2. 编写 `main.js`

在同一文件夹下创建 `main.js`：

```javascript
function formatNote(input) {
  const prefix = amber.settings.get("prefix") || "【纪要】";
  const rawText = String((input && input.text) || "").trim();
  const runs = Number(amber.storage.get("runs") || "0") + 1;
  amber.storage.set("runs", String(runs));

  return {
    ok: true,
    formatted: prefix + rawText,
    char_count: rawText.length,
    run_count: runs
  };
}
```

### 3. 导入到 Amber 并试用

1. 打开 Amber，按 `⌘,` 进入 **设置 → 插件**。
2. 点击左下角 **「+ 导入插件」**，选中刚才创建的 `note_helper` 文件夹（或里面的 `plugin.json`）。
3. 左侧「扩展插件」列表会出现 **会议纪要助手 `v1.0.0`**，状态圆点为琥珀色（已启用）。
4. 回到主窗口：
   - 在底部输入框输入 `/note`，补全浮层会列出 `/note-format`，回车即可填入提示词；
   - 或直接对 Amber 说：「用会议纪要助手格式化这段话：确认周五上线 v2.0」。因为 `format_note` 的 `effect` 是 `pure`，智能体会直接执行而无需弹窗审批。

---

## Amber 如何运行插件 {#runtime}

- **JavaScriptCore 沙箱。** Amber 使用 macOS 原生的 `JavaScriptCore`（`JSContext`）执行插件脚本，无需安装 Node.js 或 Bun。每次工具调用都在全新创建的独立 `JSContext` 中运行，执行完毕即销毁，插件之间不共享任何全局变量。
- **零主线程阻塞。** 所有涉及外部网络的动作都在 Swift Concurrency 后台任务中完成；用于 SwiftUI 渲染的界面数据（右侧栏卡片、侧栏视图徽章、斜杠命令列表）全部在 `DesktopPluginStore.rebuildProjections()` 中预先计算缓存，视图渲染期零磁盘 IO、零钥匙串 IPC。
- **安装与热重载。**
  - 在 **设置 → 插件** 点 **「+ 导入插件」** 选择文件夹或 `plugin.json`，Amber 会校验清单并将 `plugin.json` 与 `main.js` 原子拷贝到应用支持目录下。
  - 修改了插件目录中的文件后，点设置面板左下角的 **「↻ 重新加载」** 按钮（或把插件关掉再打开），修改立即生效。
- **网络白名单守卫（Capability Broker）。** 插件不能访问任意网址。宿主层的 `performAuthorizedHTTP` 只允许 `https://` 协议，且请求的目标主机必须精确匹配 `capabilities.networkDomains`（或其子域名）。未声明的域名会被立即拦截并报错，请求超时固定为 20 秒。

Amber 在应用支持目录（`~/Library/Application Support/Amber/plugins/`）与系统存储中保存这些内容：

| 位置 | 内容 |
| :--- | :--- |
| `plugins/<id>/plugin.json` | 已安装扩展插件的清单文件（上限 256 KB）。 |
| `plugins/<id>/main.js` | 插件的 JavaScript 入口脚本。 |
| `plugins/<id>/storage.json` | 插件通过 `amber.storage.set` 写入的键值存储（JSON 字典，按键排序原子写入）。 |
| `UserDefaults` (`desktop.plugins.settings.v1.<id>`) | 插件的非敏感配置项（`string`、`boolean`、`integer`）。 |
| `Keychain` (`app.amber.macos.plugins.credentials`) | 插件的 `secret` 类型凭据，按 `SHA256("amber.plugin.secret.<id>.<key>")` 派生确定性 UUID 独立存放在 macOS 钥匙串中。 |

---

## 包的结构 {#structure}

### Amber 从哪里加载

每个扩展插件独占 `~/Library/Application Support/Amber/plugins/<id>/` 下的一个同名子文件夹：
- 清单固定为 `plugin.json`；
- 脚本固定为同级目录下的 `main.js`（纯 UI 或配置型插件可以没有 `main.js`）。

文件夹名字必须与 `plugin.json` 里的 `id` 完全一致，否则加载时会被拒绝。

### `plugin.json` 顶层字段

| 字段 | 类型 | 必填 | 含义 |
| :--- | :--- | :--- | :--- |
| `schema` | `string` | 否 | 协议版本，默认 `"amber.plugin.v2"`，兼容 `"amber.plugin.v1"`。 |
| `id` | `string` | 是 | 插件唯一标识：2–32 位，以小写字母开头，仅含小写字母、数字和下划线（`^[a-z][a-z0-9_]*$`）。`feishu_calendar` 为官方内置插件保留 ID。 |
| `name` | `string` | 是 | 设置页、侧栏和命令面板里展示的插件名称。 |
| `version` | `string` | 是 | 版本号字符串，例如 `"2.0.0"`。 |
| `description` | `string` | 是 | 插件的一句话功能说明。 |
| `icon` | `string` | 否 | SF Symbols 图标名，默认 `"puzzlepiece.extension"`。 |
| `capabilities` | `object` | 否 | 权限与沙箱边界：`{ networkDomains: [], workspaceReadPrefixes: [], workspaceWritePrefixes: [] }`。 |
| `settings_schema` | `array` | 否 | 插件配置项定义数组（见[配置与凭据](#settings)）。 |
| `tools` | `array` | 否 | 提供给智能体的工具数组（见[给每个会话的工具](#tools)）。 |
| `ui` | `object` | 否 | 界面扩展声明：`{ inspectorCards: [], workspaceViews: [], commands: [] }`（见[窗口里的界面槽位](#ui-slots)）。 |

### `capabilities` 规则

- `networkDomains`：字符串数组，每一项为不含协议头、斜杠和端口的纯域名（例如 `["caldav.feishu.cn", "open.feishu.cn"]`）。允许匹配该域名本身及其任意子域名（`*.open.feishu.cn`）。
- `workspaceReadPrefixes` / `workspaceWritePrefixes`：声明插件在会话工作区中可读写的文件路径前缀（例如 `["meetings/", "feishu/"]`），展示在「设置 → 插件 → 权限与沙箱边界」卡片中。

---

## 配置与凭据 (`settings_schema`) {#settings}

用户在 **设置 → 插件** 选中你的插件时，Amber 会根据 `settings_schema` 自动渲染双列配置表单。

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

### 字段说明

| 字段 | 含义 |
| :--- | :--- |
| `key` | 配置项键名，读取配置时用作参数。 |
| `title` | 输入框上方显示的中文标签。 |
| `kind` | 取值 `"string"`（默认）、`"secret"`、`"boolean"` 或 `"integer"`。 |
| `placeholder` | 输入框占位提示文本。 |
| `defaultValue` | 未填写时的默认值（兼容 snake_case 写法 `default_value`）。 |
| `help` | 输入框下方最多两行的辅助说明文字。 |
| `group` | 可选分组标识（例如 `"calendar"` 或 `"bot"`），用于在设置面板顶部将复杂插件的配置拆分为分段 Tab。 |

### 四种 `kind` 的行为差异

- **`string` / `integer`**：渲染为标准桌面文本框（`.textFieldStyle(.desktop)`），保存在 `UserDefaults` 中，插件脚本可通过 `amber.settings.get(key)` 直接读取。
- **`boolean`**：渲染为开关控件，值为 `"true"` 或 `"false"`。
- **`secret`**：渲染为掩码密码框（`SecureField`），标题旁自动带上 `钥匙串加密` 徽章。保存时：
  1. 自动从 `UserDefaults` 字典中剔除该键；
  2. 去首尾空白后写入 macOS Keychain；
  3. **不会**注入到 JavaScript 沙箱的 `amber.settings.get(key)` 中，防止脚本或提示词注入把密钥拼进工具返回值发给大模型。

---

## 给每个会话的工具 (`tools`) {#tools}

插件在 `tools` 数组里声明的每个工具，开启后都会注册进 Amber 的 `DesktopToolRegistry`，对话、子代理（Subagent）和自动流程（Recipe）都能直接调用。

- **工具命名。** 为了防止不同插件或内置工具重名，智能体看到的完整工具名固定为 `plugin__<插件id>__<工具name>`（双下划线分隔）。例如插件 `feishu_calendar` 下的 `list_events`，注册名为 `plugin__feishu_calendar__list_events`。
- **工具描述。** Amber 会自动在描述前加上 `[<插件name>]` 前缀，方便大模型识别工具归属。

### `tools` 条目写法

参数 Schema 支持三种写法（任选其一，Amber 在解码时自动归一化）：
1. **`input_schema`（推荐）**：直接写标准 JSON Schema 对象；
2. **`parameters_json`**：写转义后的 JSON Schema 字符串；
3. **`inputs`（兼容 `v1` 简写）**：写 `{"city": "string", "days": "integer"}`，Amber 会自动展开成全字段必填的 JSON Schema object。

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

### 副作用等级（`effect`）与审批规则

每个工具必须声明准确的 `effect`（不填默认为 `"pure"`）。Amber 的智能体引擎和定时任务调度器完全按它决定是否需要人工点「批准」：

| `effect` 值 | 设置页标签 | 智能体调用时是否需要用户批准 | 适用场景 |
| :--- | :--- | :--- | :--- |
| `"pure"` | `只读` | **免批准**，直接执行 | 本地计算、格式化、读取插件自己的 `storage.json`。 |
| `"networkRead"` | `网络读取` | **免批准**，直接执行 | 查询日历列表、拉取忙闲状态、拉取群聊历史、读取云文档。 |
| `"idempotent"` | `幂等变更（需批准）` | **需用户批准**（除非开启自动批准普通变更） | 覆盖更新已有状态或配置。 |
| `"sideEffect"` | `外部写入（需批准）` | **需用户批准** | 创建日历日程、通过飞书机器人向群里发卡片、新建云文档。 |

### 对话流工具卡片的结构化预览

当工具执行完毕返回 JSON 对象时，对话流中的 `DesktopToolCallCard` 会自动识别常见字段并在展开区顶部渲染一条琥珀色高亮摘要，无需写任何 UI 代码：

| 返回 JSON 中包含的字段 | 自动生成的预览徽章 |
| :--- | :--- |
| `event: { summary, start_time, location }` | 📅 `<summary>（<start_time> · <location>）` |
| `count` + `events` 数组 | 📅 `共读取 <count> 项飞书日历日程` |
| `free_slots` 数组 | 🕒 `发现 <N> 个可约空闲时段` |
| `message_id` + `title` (+ `target`) | ✈️ `已推送至 <target>：<title>` |
| `count` + `messages` 数组 (+ `chat_id`) | 💬 `已拉取 <chat_id> 近 <count> 条消息` |
| `document_id` + `title` | 📄 `<title>（<document_id>）` |

---

## 窗口里的界面槽位 (`ui`) {#ui-slots}

除了让大模型调用工具，插件还可以把自己的入口挂进 Amber 窗口的四个位置：

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

- 插件开启后，右侧栏（Inspector）会在「当前回合」下方渲染你的插件卡片。
- 当窗口宽度窄于 `1100pt` 自动收起右侧栏时，顶部工具栏会出现一个日历快捷气泡按钮，点开即可在浮层（`DesktopPluginInspectorPopoverView`）里看到同一张卡片。
- 每张卡片展示标题、状态角标（`statusBadge`）、条目列表（双行零截断布局：第一行时间/状态胶囊 + 右侧动作按钮，第二行完整标题与副标题）以及底部跳转主工作区视图的链接。
- 点击条目右侧的动作按钮（如「准备」），Amber 会自动切回对话视图、将 `prompt` 填入输入框、开启工具开关并聚焦光标。

### 2. 主工作区视图（`workspaceViews`）

- 一个插件可以声明一个或多个 `workspaceViews`（例如内置「飞书」插件同时声明了 `calendar_board`「飞书日历」和 `bot_studio`「飞书机器人」）。
- 插件开启后，左侧边栏底部「插件视图」分组会列出每个视图及其数字徽章（`badgeCount`）。
- 点击侧栏条目，主画布会从 `.chat` 切换到 `.pluginView(pluginID:viewID:)`，左上角固定提供 `< 返回对话` 按钮。
- **自动回退保护：** 如果用户正在浏览某个插件的主工作区视图，此时在设置中停用或卸载了该插件，`DesktopWorkspace.reconcilePluginState()` 会立即把主画布平滑切回 `.chat`，绝不会停留在失效页面。

### 3. `/` 斜杠命令与 `⌘K` 命令面板（`commands`）

- `slash` 必须以 `/` 开头（例如 `"/feishu-today"`）。
- 用户在底部输入框以 `/` 开头输入时，`DesktopComposer` 会在输入框上方弹出斜杠命令补全浮层，支持按命令名或中文标题实时过滤。
- 按 `⌘K` 打开全局命令面板（`DesktopCommandPaletteView`）时，插件的所有 `workspaceViews` 和 `commands` 都会自动进入检索列表，支持上下方向键选择、回车执行、`ESC` 关闭。

---

## 插件能拿到什么 (`amber.*`) {#sandbox-api}

在 `main.js` 中，Amber 注入了一个冻结的全局对象 `amber`（`Object.freeze`）：

| 调用 | 给出什么 / 做什么 |
| :--- | :--- |
| `amber.settings.get(key)` | 返回该插件在 `settings_schema` 中对应非敏感配置项的字符串值（用户未填时返回 `defaultValue`）。不会返回 `kind: "secret"` 的字段。 |
| `amber.settings.get("today")` | 宿主自动注入的当前日期字符串，格式固定为 `yyyy-MM-dd`（例如 `"2026-10-30"`）。 |
| `amber.settings.get("mode")` | 宿主注入的运行模式：已配置远端凭据时为 `"feishu"`，否则为 `"local"`。 |
| `amber.storage.get(key)` | 从该插件专属的 `storage.json` 中读取字符串值；键不存在时返回空字符串 `""`。 |
| `amber.storage.set(key, val)` | 将值写入该插件的 `storage.json`。`val` 是字符串时原样保存，是对象或数组时自动 `JSON.stringify(val)`。工具返回后，若检测到 `storage` 发生过写入，宿主会自动落盘并刷新所有 UI 投影。 |

### 入口函数的参数与返回值

```javascript
function myToolEntry(input) {
  // input 是大模型传入的 JSON 参数对象（已解析为 JS Object）
  return {
    ok: true,
    result: "..."
  };
}
```

- 入口函数名由 `tools[i].entry` 指定（不填 `entry` 时默认与 `tools[i].name` 同名）。
- 返回任意可 JSON 序列化的对象或数组，宿主会自动调用 `JSON.stringify` 将其转为字符串传回给智能体。
- 脚本加载或执行期间若抛出未捕获异常，宿主会捕获异常信息并以工具错误形式返回给模型（同时不会污染宿主进程）。

---

## 实战范例：内置「飞书（日历 & 机器人）」插件 {#feishu-case}

Amber 内置的 **「飞书」插件（`id: "feishu_calendar"`, `v2.0.0`）** 是 `amber.plugin.v2` 的完整参考实现。它把桌面端使用飞书最高频的两类场景拆分为两个正交模块：

### 模块一：📅 飞书日历（为什么首选 CalDAV）

在企业飞书租户里，普通员工通常没有管理员权限去给自建应用审批日历作用域，而且机器人 `tenant_access_token` 默认读写的是机器人自己的主日历而非个人日历。

因此，「飞书」插件的日历模块优先采用 **标准 CalDAV 协议（`https://caldav.feishu.cn`）**：
1. **免管理员审批：** 用户在「飞书客户端 → 设置 → 日历 → CalDAV 同步」里点一下就能生成专用的服务器地址、用户名与密码。
2. **拉取日程（`REPORT`）：** 同步时携带 `Authorization: Basic base64(username:password)` 与 `Depth: 1` 发送 `<c:calendar-query>` XML，直接拉取并解析 RFC 5545 `.ics`（`BEGIN:VEVENT ... END:VEVENT`）中的 `UID`、`SUMMARY`、`DTSTART`、`DTEND`、`LOCATION`、`DESCRIPTION`。
3. **创建日程（`PUT`）：** 在 Amber 中新建日程时，自动组装标准 `VCALENDAR / VEVENT` 文本并通过 `PUT <caldav_server>/<uid>.ics` 写回个人飞书日历。
4. **平滑回退：** 如果用户没有填 CalDAV 账号，但在机器人模块填了 `app_id` + `app_secret`（或 `personal_access_token`），日历模块会自动回退到 `https://open.feishu.cn/open-apis/calendar/v4/` 接口。

### 模块二：🤖 飞书机器人（Webhook + 自建应用 OpenAPI）

当你手头有飞书机器人时，可以在「飞书 → 飞书机器人 (Bot)」配置页同时或任选接入两种通道：

| 机器人通道 | 需填配置 | 支持的能力 |
| :--- | :--- | :--- |
| **群自定义机器人 Webhook** | `bot_webhook_url` + 可选 `bot_webhook_secret` | 向指定飞书群一键推送文本或结构化交互式消息卡片（`msg_type: "interactive"`）。开启签名校验时，Amber 自动使用 `CryptoKit` 计算 `HMAC-SHA256(timestamp + "\n" + secret)` 并附带 `timestamp` 与 `sign`。 |
| **企业自建应用机器人 OpenAPI** | `app_id` + `app_secret` + 可选 `default_receive_id` | 自动换取 `tenant_access_token`，支持：<br>1. `bot_send_message`：按 `chat_id`（`oc_xxx`）、`open_id`（`ou_xxx`）或邮箱发送私聊/群聊卡片；<br>2. `bot_fetch_chat_history`：拉取群聊近期讨论记录供 AI 生成会议纪要；<br>3. `bot_read_doc`：传入飞书云文档链接（`https://.../docx/...`）直接读取文档纯文本；<br>4. `bot_create_doc`：将 AI 生成的方案直接创建为飞书云文档并返回链接。 |

---

## 核心插件 (`Core Plugins`) {#core-plugins}

除了外部扩展插件，Amber 还借鉴 Obsidian 的设计，把 5 项内置一级能力设计为可独立开关的 **核心插件（`DesktopCorePlugin`）**。用户可以在 **设置 → 插件 → 核心插件** 中随时关闭不需要的模块，保持工作台极简：

| 核心插件 ID | 名称 | 停用后自动隐藏的智能体工具 (`governedToolNames`) |
| :--- | :--- | :--- |
| `task_board` | 任务看板与定时任务 | `schedule_list`、`schedule_create`、`schedule_update`（同时隐藏侧栏「任务看板」入口） |
| `knowledge` | 知识与长期记忆 | `skills_list`、`use_skill`、`skill_enable`、`skill_disable`、`memory_tool` |
| `collaborations` | 多模型协作与议会 | `subagent_dispatch`、`list_agents`、`interrupt_agent`、`model_council_run` |
| `recipes` | Recipe 自动流程 | 停用 Recipe 自动化流程面板与执行入口 |
| `image_generation` | 图片生成工作台 | 停用图像模型生成工作台与生图入口 |

当某个核心插件被停用时：
1. `DesktopToolRegistry.agentDeclarations(...)` 会在构造模型请求时直接剔除它管辖的工具；
2. 如果 Recipe 或外部调用尝试强行执行已停用核心插件的工具，`DesktopAgentProvider` 会立即拦截并返回明确的中文提示（`核心插件「xxx」当前已停用`）。

---

## 测试与调试 {#testing}

### 在应用中调试

1. 将开发中的插件文件夹通过 **设置 → 插件 → 导入插件** 导入。
2. 每次修改 `plugin.json` 或 `main.js` 后，点击设置面板左下角的 **「↻ 重新加载」**。
3. 如果 `plugin.json` 校验失败（例如 `id` 含非法字符、工具 `input_schema` 不是 JSON object、域名白名单含斜杠）或 `main.js` 存在语法错误，设置页顶部会立即显示红色错误横幅说明具体原因。

### 编写自动化单元测试

在 `AmberMacTests/DesktopPluginTests.swift` 中，你可以注入内存版 `UserDefaults`、`DesktopMemoryCredentials`（替代真实 Keychain）以及 `MockPluginHTTPTransport`（替代真实 `URLSession`），在不触碰真实用户配置与外部网络的前提下完成端到端测试：

```swift
let transport = MockPluginHTTPTransport()
let store = DesktopPluginStore(
    directory: tempDirectory,
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

运行插件测试套件：

```bash
xcodebuild test -project macApp/AmberMac.xcodeproj -scheme AmberMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:AmberMacTests/DesktopPluginTests
```

---

## 宿主协议与内部机制 {#host-protocol}

写普通插件用不到这一节，它是给开发 Amber 本身或调试插件运行时的人看的。

| 核心类型 (`macApp/AmberMac/`) | 职责 |
| :--- | :--- |
| `Runtime/DesktopPlugins.swift` (`DesktopPluginStore`) | 插件生命周期管理、清单校验、Keychain 凭据隔离、JavaScriptCore 沙箱执行、受控 HTTPS 传输（`performAuthorizedHTTP`）、飞书 CalDAV / Bot 原生加速通道，以及零 IO 视图投影（`rebuildProjections()`）。 |
| `Runtime/DesktopToolRegistry.swift` | 维护线程安全的插件工具副作用表 `registeredPluginEffects`，在 `agentDeclarations(...)` 中合并已启用扩展插件工具并过滤已停用的核心插件工具。 |
| `Runtime/DesktopAgentProvider.swift` | 在对话回合（`start`）与 Recipe 步骤（`performRecipeTool`）中拦截 `plugin__*` 调用，根据 `toolEffect` 决定直接执行还是挂起等待用户批准（`requestApproval`）。 |
| `Runtime/DesktopToolActivity.swift` | 将 `plugin__*` 工具调用翻译为自然语言状态（如 `正在通过飞书机器人发送通知`、`已创建飞书日程`）。 |
| `UI/DesktopPluginsSettingsView.swift` | 设置面板中的「插件」标签页：管理扩展插件与核心插件开关、分组渲染 `settings_schema`、显示权限边界与已注册槽位。 |
| `UI/DesktopPluginWorkspaceView.swift` | 主工作区插件画布（含飞书日历看板与飞书机器人工作台）以及 `⌘K` 全局命令面板（`DesktopCommandPaletteView`）。 |
| `UI/DesktopInspector.swift` | 右侧栏插件卡片渲染与窄窗口下的气泡浮层（`DesktopPluginInspectorPopoverView`）。 |

---

## 答疑 {#faq}

### 为什么大模型看到的工具名叫 `plugin__xxx__yyy`？
为了避免多个插件声明同名工具（例如都叫 `search` 或 `list`）产生冲突，Amber 统一使用 `plugin__<插件id>__<工具name>` 作为完整工具名。你在 `plugin.json` 的 `tools` 里只需要写短名字（如 `list_events`），如果你在 `commands` 的 `prompt_template` 里显式引导模型调用工具，可以写完整名或自然语言描述。

### 我在 `settings_schema` 里定义了 `kind: "secret"` 的字段，为什么 `amber.settings.get` 返回空字符串？
这是有意设计的安全边界。`secret` 凭据保存在系统钥匙串（Keychain）中，只供宿主侧受控网络层读取，不会放进 JavaScript 沙箱，防止第三方脚本或恶意提示词把 API Key / 密码拼进工具返回文本里泄露给远端大模型。

### 旧的 `amber.plugin.v1` 插件不改能直接用吗？
可以。`DesktopPluginManifest` 同时接受 `"amber.plugin.v2"` 和 `"amber.plugin.v1"`，并且兼容 `v1` 的 `script` 字段（自动映射为 `entry`）和简写的 `inputs` 参数表（自动转换为标准 JSON Schema）。

### 为什么我的插件请求外部接口时报「未授权访问域名」？
所有外部网络请求都会经过 `performAuthorizedHTTP` 校验：
1. 必须是 `https://` 地址；
2. 目标域名必须列在 `plugin.json` 的 `capabilities.networkDomains` 数组中（只写域名如 `"open.feishu.cn"`，不要带 `https://` 或路径）。

### 怎么让 Amber 立即看到我对插件文件的修改？
如果是通过「导入插件」装进去的插件，它的副本在 `~/Library/Application Support/Amber/plugins/<id>/` 下。直接编辑该目录下的 `plugin.json` 或 `main.js`（可在设置页查看路径，或重新导入覆盖），然后点 **设置 → 插件** 左下角的 **「↻ 重新加载」** 按钮即可立即生效。

### 如果用户正打开着插件的主工作区页面，这时去设置里把插件关了会发生什么？
`DesktopPluginStore` 触发 `onStateChanged` 后，`DesktopWorkspace.reconcilePluginState()` 会检查当前主画布打开的 `.pluginView(pluginID:viewID:)` 是否仍然在 `activeWorkspaceViews` 中；如果不在，主画布会自动切回当前对话（`.chat`），不会留下空白或报错页。
