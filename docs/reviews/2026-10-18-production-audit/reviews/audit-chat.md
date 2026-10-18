# 聊天生产链只读审查（2026-10-18）

范围：当前工作区（包含未跟踪的拆分文件）中的 ChatViewModel、Chat/Session、Chat/Generation、ChatKernelRunHost、ChatRunKernelAdapter、默认 Native timeline/Markdown、Chat/Background。已读 iosApp/AGENTS.md。没有修改产品代码，没有构建或运行测试。Timeline 和 Background 分别由独立子代理只读审查，以下结论均追踪当前生产调用链并二次反证。

## 确认的问题

### C1 · P1 · 恢复 Responses 后带工具调用，继续运行被同 run 的 activeJobs 判重吞掉

- 位置：`iosApp/iosApp/Chat/Background/IOSChatBackgroundResponseResumer.swift:149-178`；`iosApp/iosApp/IOSChatBackgroundGenerationCoordinator.swift:367-368`。
- 触发：官方 OpenAI Responses durable response 在后台恢复完成，返回至少一个未执行工具调用。
- 调用链：resumeDetachedResponse 完成后构造同 runId 的 `.continueModel` handoff，调用 `start`。`job(for:)`/恢复路径已将原 `.resumeResponse` job 放进 `activeJobs[requestId]`，requestId 由同一 runId 派生。`start` 在第 368 行直接 `return true`，不会保存新 handoff，也不会执行 startLocalExecution。调用方当成接管成功直接 return，原 owner 没有终态。
- 影响：工具不执行，最终答复不再继续，run 保持运行状态；后续再次恢复仍读取原 response checkpoint。
- 二次复核：不是 dedupe 的正常意图。外部重复 start 同一活跃请求可以 no-op；此处明确是同一 owner 从 response transport 转入工具/模型执行的模式迁移。失败分支已写明“回复已恢复，但工具阶段未能继续”，说明产品契约要求继续工具阶段。安全 ledger reconcile 允许读取工具进入这里。
- 最小修复：提供明确的同 owner continuation 迁移，先保存新 `.continueModel` payload，再替换原 job 并启动本地执行；不要简单删除全部 dedupe 保护。迁移保存失败时保留原 checkpoint 与失败路径。
- 测试 seam：现有 coordinator `runtimeJob`/`activeJobs` 和 injected provider 支持创建同 run 的 resume job；将带工具的 response completion 后半段提成内部 continuation 方法，直接验证 payload.mode 变为 continueModel、provider 接收到工具结果、终态只一次。必须覆盖旧 activeJobs 已存在；只测全新 start 会漏掉 bug。

### C2 · P1 · 同一 run 多模型轮复用旧 checkpoint gate，可能交接到上一轮 response

- 位置：`iosApp/iosApp/Chat/Generation/Kernel/ChatDurableResponseSession.swift:14,34-51`；`iosApp/iosApp/ChatKernelRunHost.swift:858-881,1248-1274`。
- 触发：第 1 轮官方 Responses 已记录 checkpoint 并完成，工具执行后进入第 2 模型轮；第 2 轮新 response checkpoint 到达前，App 转后台/发生交接。
- 证据：一个 run 只创建一个 ChatDurableResponseSession；checkpointPersisted 初始化 false 后只在 checkpoint 置 true，轮间从不 reset。每轮上传前 onPreparedUpload 会 refreshBackgroundHandoff，builder 明确生成 `.continueModel`、responseId 默认为 nil。然而 detachDurableResponse 只检查旧 session.checkpointPersisted == true，无当前 handoff.mode/responseId 匹配，随后取消当前 stream、清空前台身份并调用 resumeDetachedResponsesIfNeeded。持久化 payload 仍是第 1 轮 response。
- 影响：第 2 轮本地流被取消，后台恢复却选中已结束的第 1 轮 response，丢失当前轮所有权。现有 C1 会令其挂起；修 C1 后仍可能错误续跑旧轮，故两个根因必须分别修。
- 二次复核：后台子代理独立确认；canHandoffActiveTool 在模型请求间/纯读工具时允许，不阻挡；cancel/terminal 的 discard 不发生在轮间；不能用 runId 相同证明 response 身份相同。
- 最小修复：在模型轮准备边界使 durable cursor/checkpoint gate 失效，并仅当 checkpoint 与当前 handoff 的 response 身份匹配时允许 durable detach。当前轮无 checkpoint 时沿现有普通 handoff 或等待新 checkpoint 路径处理，不能用上一轮的 persisted gate。避免新增通用恢复状态机。
- 测试 seam：让真实 Host 跑两轮 scripted streaming provider（第 1 轮 checkpoint+工具，第 2 轮暂停在新 checkpoint 前），触发 handoff，断言不会从第 1 轮 cursor detach；新 checkpoint 到达后才允许对应 response 接管。至少给 Session 增加按轮 gate 行为测试；只测首次 checkpoint 不足。

### C3 · P2 · durable Responses 恢复失败会丢弃已经收到的 assistant partial / reasoning

- 位置：`iosApp/iosApp/Chat/Background/IOSChatBackgroundResponseResumer.swift:95-100,205-211,228-238`；`iosApp/iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift:366-375`。
- 触发：恢复流已收到部分正文/推理后，收到 failed；或者断线重试后仍 disconnected。
- 证据：onChunk 正确将 accumulator 完整快照写到 job.messagesSnapshot。失败分支却传 partialAssistantText:nil 给 persistExpirationFailure。writer 只取 reconciledDisplayPrefix，而该 helper (`IOSChatBackgroundMessageProjection.swift:127-165`) 仅修 display baseline 内的工具输出，不携带生成 suffix，再拼错误泡。于是恢复 partial 完全不保存。
- 影响：用户已等待并实际收到的部分结果在失败后消失；reasoning/消息身份和结构也丢失。
- 二次复核：普通后台 provider failure 已显式保留 partial；该 writer 其他部分也有 preservedGeneratedSuffix 契约，因此不是故意只存错误。不能仅把 toText() 填入字符串参数，避免丢 reasoning/annotations/tool parts。
- 最小修复：durable failure 直接携带权威 messagesSnapshot 的生成 suffix，并在保存前按既有规则失败化未决工具，再追加本地错误。复用现有消息投影 helper，避免双插 partial/重放错误。
- 测试 seam：对 injected runtimeJob 设置 baseline+含 Text/Reasoning 的 partial snapshot，调用 durable failure writer，断言保存后保留各 parts 与 id，并追加一次错误；另覆盖再次 disconnected 分支和无 partial。

### C4 · P2 · durable Responses 的 MiniApp 解析失败仍写 completed 并发布成功

- 位置：`iosApp/iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift:17-59`。
- 触发：MiniApp 任务使用官方 OpenAI Responses，转入 durable 恢复，完成输出缺失 MiniApp JSON/HTML 或格式无效。
- 证据：saveMiniAppIfPresent 返回 `.failed` 时该方法只跳过 markCompleted（21 行），但第 41 行状态仅取决于 didSave，第 53-59 行发布 completed。`ChatMiniAppOutputCommitter.swift:43-78` 明确会返回失败 application；前台 terminal 和 ordinary background executor 已将 miniAppFailed 纳入终态。
- 影响：会话包含“小应用生成失败”而 durable run / Watch / Live Activity 显示成功；自动后续行为将失败当成功。
- 二次复核：ChatKernelDurableTextProvider.swift:143-155 没有 MiniApp 排除，所以 reachable；不是只用于普通文本的 dead branch。
- 最小修复：与当前前台/普通后台同样让成功条件为 didSave && !miniAppFailed，持久化 parse-failure 消息后写 failed 并发布失败。不要扩大为重构全部 terminal writers。
- 测试 seam：直接调用 completeDetachedResponse，注入返回 `.failed` application 的 saveMiniApp closure；验证 durable .failed、失败 presentation、parse failure 消息仍保存。另回归普通成功与保存失败 recoveryPending。

### C5 · P2 · durable Responses 成功保存 MiniApp 后没有执行 Workspace 同步

- 位置：同 `IOSChatBackgroundTerminalWriter.swift:34-37`；实际同步 closure 在 `iosApp/iosApp/Chat/Generation/ChatMiniAppOutputCommitter.swift:158-186`。
- 触发：与 C4 同 provider/恢复入口，生成合法 MiniApp。
- 证据：completeDetachedResponse 只 commit/rollback，从未调用 syncWorkspaceAfterConversationPersistence。Workspace 保存被延后封装在 application 的 syncWorkspace closure；前台/普通后台路径都显式调用。commit 本身不保存 Workspace。
- 影响：小应用会进入 MiniApp repository，但用户 Workspace 缺少对应产物；路径语义与前台/普通后台不一致。
- 二次复核：不是 transaction commit 自动完成的副作用；其 closure 明确只在 syncWorkspace handler 执行。
- 最小修复：会话持久化成功并 commit 后，调用已有 syncWorkspaceAfterConversationPersistence；同步失败按既有策略补写用户可见 workspace 错误，不应把成功生成的 MiniApp 误回滚。可与 C4 同 phase 修改同 owner。
- 测试 seam：注入 application 的 syncWorkspace closure，断言 durable success 恰调用一次、conversation save failure 不调用；真实 Workspace store 另验证新增 artifact 和同步失败消息持久化。

### C6 · P2 · Markdown 表格补列/截列时破坏 escaped pipe

- 位置：`iosApp/iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownBlockParser.swift:200-227`，特别是 209 行。
- 触发内容：`| 表达式 | 含义 |\n| --- | --- |\n| a \\| b |`，既可能是流式未补齐第二列，也可能是完成态缺列。
- 证据：splitTableCells 先将 `a \\| b` 解码为 `a | b`；renderedRowLine 发现列数不足时补列，再直接用 ` | ` 重组，得到 `| a | b |  |`。真实 renderer 再次把原单元格内部管道作为分隔符，列归属或内容改变。
- 二次复核：同文件注释明确要求保留 escaped pipe；现有 testStreamingTableBlockPreservesEscapedPipeForRealMarkdownRenderer 只覆盖等列数分支。默认 Native → ChatAssistantMarkdownView → ChatStreamingBlockMarkdownView 使用本 parser。
- 最小修复：重建 Markdown 行时保留原始 cell escapes（或专门保留 escapes 的 split）；不要用解码后的展示 cell 重建源码。
- 测试 seam：blocks 对流式/完成态缺列及截列检查 escapes；再交真实 MarkdownParserImpl/RenderableDocument 验证第一格仍为完整 `a | b`，第二格空。

### C7 · P2 · Markdown fence 只比较字符，误关闭长围栏并渲染代码中的表格

- 位置：`ChatStreamingMarkdownBlockParser.swift:13-17,80,268-272`；`ChatStreamingMarkdownDetection.swift:142`。
- 触发：四反引号 markdown 围栏内展示三反引号示例；或者三反引号代码中出现带非空 info 的 `\x60\x60\x60language` 伪关闭行。
- 证据：fence 状态只记 marker Character，没有长度；任意同 marker 行都被认为关闭，随后将本应位于 code fence 内的 `| A | B |` / separator 拆成 .table。按照当前 renderer 的正常 Markdown 语义，短于 opener 的 fence 或带 info 的行不能关闭外层 fence。
- 二次复核：现有 tests 明确要求 fence 内 table 不分块，但只覆盖不同 marker 的嵌套例；完整扫描和增量 detector 都存在同样状态缺失。
- 最小修复：一个小值类型记录 marker 与 opener 长度，仅在相同 marker、至少 opener 长度、后面只有空白时关闭。完整/增量两处复用语义，不引入新 Markdown 框架。
- 测试 seam：containsTable / blocks / incremental detector 同时覆盖四反引号含三反引号、伪关闭、较长合法关闭、普通 fence table。

## 已排除的误报 / 有明确设计依据

- ChatRunKernelAdapter 的消息回调已带 snapshotSeq，终态/取消将 lastAppliedSnapshotSeq 钉 max；round-start 也显式推进 epoch。不能仅因 Task 跳 MainActor 就报告“旧 delta 覆盖终态”。
- streaming cancellation 会等待 driver 的准确 accumulator tail，工具执行期间则冻结已知工具输出立即发布取消；现有 handoff/cancel tests 已覆盖不响应取消工具的迟到结果，不应笼统当数据丢失。
- Chat/Session generation bindings 捕获 conversation state；切会话不会把旧 run 的正常消息/审批写到新会话。branch 异步写回也已有 applyPersistedBranchIfCurrent。
- 原 Native timeline cache 保留 stale-prefix、离屏静态快照、terminal/speculative memory 有明确桥接，不能仅因缓存或 offscreen 不更新高频原始消息报 bug。
- 当前附件识别与文件请求有 request token，切会话使旧 token 失效，并对原 conversation 保存取消/错误；未发现足够证据报告串会话。

## 建议修复阶段（主 agent 整合）

1. Durable 请求身份与续跑交接：C1 + C2。先加真实失败 seam，再修 owner/轮次匹配，验证工具只执行一次、第二轮无旧 cursor detach、checkpoint 保存失败仍可恢复。
2. Durable 终态内容与 MiniApp 合同：C3 + C4 + C5。同 writer 统一已存在的 ordinary/foreground 合同；验证 partial parts/id、failed/ completed/recoveryPending，以及 Workspace 事务顺序。
3. 默认 Markdown parser：C6 + C7。最小源码保真与 fence grammar 修复，按 iosApp/AGENTS.md 跑默认 Native timeline/viewport 回归及 Markdown tests。

每个 phase 交由独立子 agent review；不并行构建。系统后台、真实 provider 跨进程恢复与真机视觉仍需设备/真实服务证据，模拟测试不能宣称已经验收。
