# macOS 全面 review 与修复（2026-10-26 第三轮）

基线 `d57c7a5`。范围是 macOS 正式产品、实际消费的共享 Swift/KMP 链路和原生 UI。继续保留既有产品边界，不新增小说、Deep Read、Mini App、WebMount 等功能，不触碰未跟踪的定时任务计划；提交和推送按用户明确授权执行。

完成条件：候选问题逐条核实；确认缺陷完成最小修复及匹配回归；各 phase 经独立 subagent review 逻辑、调用链和相关 UI；最终正式构建、测试和新截图有据可查。不能把测试全绿表述为所有账号、系统权限和真机场景已验。

## 已确认与待复现

| ID | 问题与证据 | 最小处理 |
| --- | --- | --- |
| R1 · P1 | `DesktopSettings.init` 解码失败后立即 persist 默认值，覆盖全部原配置。两次源码复核确认 | 保留原 bytes 的恢复副本，启动时不覆盖损坏主键，设置页明确提示；正常新配置仍可保存 |
| R2 · P2 | 产物架损坏文件的秒级旁路路径冲突后，pin 覆盖原 bytes，且错误清空。独立 Swift 复现输出 originalPreserved=false | 唯一旁路路径；旁路失败禁止覆盖原文件，保留可见错误 |
| R3 · P2 | 备份恢复调用 shelf.restore，落盘失败只写 errorMessage，恢复流程仍成功；重启后 pins 丢失 | 恢复持久化失败抛错并接入已有回滚；不新建事务框架 |
| R4 · P2 | KMP blob externalize 只检查存在/大小，同大小损坏文件继续复用，随后加载变占位 | 对首次/文件版本变化的 blob 校验 hash，损坏时由内存原图修复；保持未变文件的 memo 快路径 |
| R5 · P2 | workspace_file_read 完整读入文件后才截断到 48,000 字符，终端生成大文件时内存使用无界 | 在现有文件 owner 内有界读取 UTF-8 前缀；文件导入/导出使用文件复制，避免先全量装入内存；不新增任意工作区总配额 |
| R6 · P2 | WebDAV 配置目录接受 `..`，请求可越出 base URL 路径；filename 保护不能覆盖目录 | 配置与真实请求入口校验目录点段，覆盖原有空路径、中文与百分号合法路径 |
| R7 · P2 | Mac 把生图历史当待保存索引，但共用 store 超过 80 条会淘汰尚未落盘记录 | Mac 专用 store 显式保留全部待保存记录；共享默认历史上限保持 80，覆盖第 81 条及重启 |
| R8 · P1 | 仅开启子代理时，Workspace 把 toolsEnabled OR subagentsEnabled 传入 context，provider 无条件暴露普通工具和 MCP | 分离引擎启用与普通工具授权，按两个开关构建声明及执行目录；覆盖四种开关组合 |
| R9 · P2 | stdio MCP 首次连接在 MainActor 同步执行登录 shell，慢启动脚本使整个窗口失去响应 | 在非主线程异步取得一次缓存 PATH，再启动原进程；覆盖慢 shell 与取消 |
| U1 · P2 | Inspector token badge 漏算待发送附件文字，与展开的预算不一致 | 统一使用同一预算输入 |
| U2 · P2 | Inspector 文件卡把载入中/读取失败显示为空，任务卡漏显 journal 读取错误 | 复用现有 loading/error 与重试入口 |
| U3 · P2 | Inspector 折叠只隐藏像素，实测隐藏按钮仍在键盘链中 | 折叠内容禁用并从辅助功能隐藏 |
| U4 · P2 | composer 把“工具”label/value误加到发送方式菜单 | 移回工具开关，保留菜单本身的发送方式语义 |
| U5 · P3 | 发送/排队 hover 提示硬编码 ⌘Return，与用户选择的 Return/⇧Return 不一致 | 使用现有 sendShortcut 提示文案，保留既有键盘行为 |
| U6 · P2 | 文件操作错误旁“重试”仅重新列文件，不会重试原导入/导出 | 改为准确的“刷新文件列表”，不新增操作重放状态机 |

UI 新截图覆盖 860/1180/1440/1920 浅深色与二级面板，未发现可确认的错位/重叠；只修有行为证据的问题，不做审美重写。

## 复核排除与范围裁决

- 摘要按消息 ID 判有效：编辑和变体切换改变路径 ID，现有测试覆盖，不改。
- 队列启动失败：前置占位写盘串行完成，失败会标 awaitingSave，不能据此报数据丢失。
- Antigravity 首次登录：既有 MAC-010 明确只消费已有 token；修正文档表述，不新造登录流程。
- `ConversationFile.delete()` iOS/JVM 差异：现有契约/测试明确，Mac 使用 iOS actual，普通删除失败会抛错；不扩大为平台改造。
- 生图暂存清理失败：最终图片已在原会话文件中，不报结果丢失，不为低风险残留文件引入 cleanup 状态机。
- 不设拍脑袋的备份总量/条目数上限。整体内存式备份是现有格式限制，不能用任意阈值冒充完整流式解决方案。
- MCP query 参数可以属于合法 endpoint，不据“可能包含密钥”一律禁止；大 JSON 主线程处理尚缺卡顿测量，不凭猜测添加并发架构。

## Phase 顺序

1. **持久化与恢复**：R1–R3。先补损坏配置/旁路失败/恢复写失败回归，再修复；独立 review 配置 UI 提示与恢复回滚。
2. **文件、共享层与网络边界**：R4–R7。各自明确 owner；跑共享存储 JVM/Native 与 Swift 消费测试，核对文件读取输出与 WebDAV 实际 URL；独立 review。
3. **UI 与工作流**：处理独立审查确认的工具/界面问题；宽窄窗口、浅深色、设置和二级面板新截图复核；补必要行为测试，独立 review 后修正。
4. **集成与交付**：全套 Swift Runtime、正式 Mac 测试、mock provider、KMP 受影响测试、Release 构建签名与启动；最终 subagent 复核全部 diff 和截图，记录确认/排除项、实际计数与剩余验证限制。

## 基线与执行记录

- Runtime：281 项，1 项跳过，0 失败。
- 正式 Mac：303 项，289 通过、14 跳过、0 失败；正式 mock provider 单独运行 5/5 通过。
- desktop-shared JVM 基线成功（增量缓存命中）；存储 agent 运行 desktop-shared + conversation-storage JVM 成功。
- 首次截图脚本因两个审查任务共用固定临时目录竞争失败；已统一由 UI agent 本次生成，不作为产品缺陷。
- 计划经独立 `audit_chat` 逐条复核后执行。R3 明确要求 restore 与 cleanup 都反馈失败，R5 保留完整 bytes 读取给备份/预览；R6 编码点段按真实 URL 编码语义验证，不能误拒合法百分号目录。
- Phase 1 完成：R1/R2 先红后绿；Settings/Shelf/Backup 合跑 28/0。`audit_chat` 复核初始化、旁路保护及恢复回滚，`audit_ui` 检查浅深色恢复横幅/产物架错误场景并发现删除会话忽略 shelf 清理失败，已补可见错误与回归。恢复副本在正常保存及重启后仍可导出。
- R6 实际 Foundation URL 试验：原始 `..` 保留为路径点段；输入 `%2e%2e` 会被编码成 `%252e%252e`，是合法的字面目录名。只拒原始点段，不误拒百分号目录。
- Phase 2：Swift 文件/文件 facade/WebDAV/生图定向 40/0；KMP storage JVM 65/0、desktop-shared JVM 38/0、KMP iOS Simulator 6/0，Mac Native 编译通过。iOS 共用 WebDAV/生图两类 32/0。首次 iOS 默认依赖缓存缺失且 GitHub TLS 失败，复用本机已有相同工程依赖缓存后正常完成，未更改网络或依赖版本。
- Phase 2 独立复核补出 R5 导出未接 copy、非法 UTF-8 可能读到 EOF 以及额外尾部字符误判，已修为固定字节上限与最多回退 3 字节；删除了自写 UTF-8 parser。`audit_chat` 最终复核通过；`audit_ui` 复核 UI 消费者并补出 U6，纳入 Phase 3。
- Phase 3 完成：R8 四种开关、真实 Native 隐藏写文件隔离与 R9 PATH/取消链通过；U1–U6 已修。独立 UI reviewer 补出文件读取失败仍显示空态，增加无错误条件后新截图确认。后续性能审查作为用户追加目标继续推进，未遗失此前修复。
- Phase 4 与追加性能计划的 Perf 4 合并收口：完整 Runtime、正式 Mac、local provider、共享回归、Release 构建/严格签名/实际主窗均已完成；每阶段独立 review 完成。各项计数、排除项和真实账号/系统能力边界见 [最终报告](performance-review/review.md)。
