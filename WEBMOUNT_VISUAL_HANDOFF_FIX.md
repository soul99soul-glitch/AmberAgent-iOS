# WebMount 视觉读取与任务交接修复

验证日期：2026-09-08。工作区：`/Users/arquiel/Downloads/AI/AmberAgent/ios`。

## HTTP 400 的原因与修复

使用现有 ChatGPT 登录和纯色测试图片，直接请求官方 Codex 端点得到：

| 请求 | 实际结果 |
| --- | --- |
| `stream=false`，`max_output_tokens=1200` | HTTP 400：`Stream must be set to true` |
| `stream=true`，保留 `max_output_tokens` | HTTP 400：`Unsupported parameter: max_output_tokens` |
| `stream=true`，移除 `max_output_tokens` | HTTP 200，完成图片识别 |

WebMount 视觉读取调用一次性 `generateText`，原实现按普通 Responses JSON 请求发送。Codex OAuth 服务端要求 SSE，并且拒绝输出 token 上限参数。

现在 Codex OAuth 的一次性调用复用已有 SSE 解析与消息累积器，返回完整消息和 usage。请求构造在合并自定义 body 后强制 `stream=true`、移除 `max_output_tokens`。普通 API Key 的 Responses 请求保持原行为。错误与取消继续向调用方传播。

视觉错误诊断识别 JSON 和 SSE 的 HTTP 状态前缀，只显示格式受限的错误码、参数名，以及已知协议错误的固定解释；不会把服务端自由文本、图片或凭证回显给用户。

## 卡片行为

| 情况 | 行为 |
| --- | --- |
| Agent 运行中 | 保持任务卡片和现有控制权规则 |
| Agent 本轮结束 | 释放 Agent 控制权，默认显示精简条，支持展开与接管 |
| 后续聊天 | 从最近使用起保留五个后续用户回合，第六个后续回合移除；实际使用该会话刷新活动时间 |
| 用户正在接管 | 保留入口，不按聊天回合自动隐藏 |
| 点击卡片 × | 仅隐藏卡片；网页会话仍在管理页中，普通观察不会使卡片重新出现 |
| 从管理页打开或本地 `wm_open` | 恢复显示卡片 |
| 网页因 TTL / LRU 回收 | 保留轻量管理入口并显示需要重新打开；显式重开才创建运行时，不恢复旧页面动作 |

五回合边界沿用工具发现的用户消息分段语义。内部工具轮次、重试不另算用户回合。卡片显示与 Agent 租约分开，保留入口不会占住 Agent 控制权。

运行时仍受现有会话容量、15 分钟空闲回收和用户接管规则约束。`wm_tab_list` 继续只列活动运行时。回收入口没有新增跨进程持久化能力：未开启持久会话的记录仅在当前进程保留。

## 验证结果

- Kotlin provider：19 项测试通过，0 失败、0 跳过。包含真实本地 HTTP/SSE 路径的一次性调用、图片输入、最终内容不重复、usage 与 HTTP 失败传播；普通 API 请求参数保持原行为。
- Swift：182 项仓库测试通过，另有 1 项临时真实模型测试通过，共 183 项，0 失败、0 跳过。覆盖 WebMount 会话、五回合边界、隐藏与回收重开，以及聊天布局要求的三个回归测试类。
- 真实视觉链路：本地静态 HTML → `WKWebView` 截图（1170 × 2532）→ `IOSWebMountVisionReader` → KMP provider → GPT‑6 Astra，返回 `WebMount OK`。使用电脑已有登录在内存中构造认证，不修改 App 配置；未验证真机 Keychain 认证链路。
- 模拟器构建和启动通过。临时入口使用生产卡片、会话管理和页面组件，已确认结束态精简条可显示；点击交互检查目前被 Mac 锁屏阻挡，尚未计为通过。检查后已去掉临时编译覆盖，重新构建并启动正常应用入口。

证据保存在 `/tmp/amber-webmount-400-20260908/`：

- `protocol-results.json`：服务端三组协议对照。
- `TEST-*.xml`：19 项 Kotlin 回归结果。
- `swift-tests.xcresult`：183 项 Swift 结果，其中 1 项是临时真实视觉检查。
- `live-swift-attachments/4C1F0603-EC4C-43C6-9542-4F9D90FDD768.txt`：真实视觉回答与截图尺寸。

临时真实模型测试和界面检查入口均放在 `/tmp`，通过编译覆盖使用，没有加入仓库或保存凭证。以上为提交前验证记录；本轮未覆盖安装到真机。
