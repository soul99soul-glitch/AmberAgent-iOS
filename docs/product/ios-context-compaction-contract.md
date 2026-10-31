# iOS 上下文压缩：阈值与保真契约

本文记录 iOS 端当前真实行为，避免 UI 设置、KMP 默认值与 Swift 运行时再次分叉。

## 单一触发阈值（I2.1）

- `ContextCompactionSetting` 仍保留 `precompactRatio`（KMP 默认 0.70）与 `forceRatio`（默认 0.85），但 **iOS 只用 `forceRatio`**。
- `IOSCompactPolicy.triggerRatio` 直接取 `setting.forceRatio`；`precompactRatio` 在 iOS 不参与任何判断。
- 原因：iOS 在每次上传前同步准备上下文，没有可延后到下一轮的“预压”窗口。把 0.70 也当触发点只会更早丢弃原文，而不减少一次压缩请求；95% 的强制兜底仍由 `planForceCompaction` 在预算超限时负责。
- 锁定测试：`IOSContextCompactionCoordinatorTests.testSingleThresholdIgnoresLegacyPrecompactRatio`
  - 10k 窗口、7 条 4k 字符消息（约 70%）不压缩，reason = `below_threshold`；
  - 9 条（约 90%）压缩，reason = `force_threshold`。
- 压缩失败（含保真闸门拒绝）不会每轮重试：`failedCompactionHistoryCount` 记住失败时的历史上限，直接走预算裁剪，历史增长后才允许再试。

## 保真闸门（I2.2）

- 生成摘要前，宿主从**实际发送给压缩模型的源消息**中提取 12 类高置信实体：
  `file`、`command`、`error`、`exit_code`、`date`、`number`、`url`、`commit`、`constraint`、`approval`、`rejected`、`decision`。
- 每类最多 4 个、总计最多 24 个；单条消息扫描上限 24k 字符，整批 240k 字符。值只做裁剪，不做改写。
- 提取结果写入压缩 prompt 的 `must_not_lose` 清单，要求 `handoff_markdown` 逐字保留。
- 归一化（小写、空白折叠）后逐项校验；任何一项缺失 → 本次摘要作废 → 既有的一次重试 → 仍失败则降级为预算裁剪，不保存半成品摘要。
- 校验通过的摘要把 `must_not_lose` 写进 schema v2 payload（`IOSConversationCompact.summary`），后续可审计。
- 如果最老的源消息因为超出压缩模型窗口而被中间截断（`takeMiddle`），本次不启用 `must_not_lose` 校验：模型没见过被截掉的头部/尾部，不能要求它保留。
- 基线测试：`IOSContextCompactionFidelityTests` 对 12 类各扣 1 项独立计分；全量存在时通过，逐类缺失时只命中对应类。

## 原始 transcript

压缩只改请求投影（`editPreparedContext` 的占位标记），不改会话存储；`history_search` / `history_fetch` 读取的始终是原始消息。

## 记忆召回与缓存观测（I2.4）

- 记忆召回按当前 query 变化，注入位置在所有稳定 system 片段之后（soul / media / MCP / skills / workspace / 主 system prompt），不修改这些片段本身。`IOSJevMemoryRecallTests.testMemoryRecallKeepsStableSystemPrefixUnchanged` 逐字比较两次不同召回的稳定前缀。
- `ProviderSetting.Claude.promptCaching` 默认 **false**（KMP 显式默认）；开启后 Claude provider 才会在 tools / system / 倒数第二条消息上写 `cache_control: ephemeral`。默认关闭是因为它改变计费与缓存行为，需要用户在 provider 设置里显式开启。
- `cachedTokens` 已从 provider usage 进入 `ChatContextSnapshot`：上下文统计页展示缓存命中率（无缓存时显示 —），`ChatRunProgressPresentation` 记录 `cache_hit_ratio` 供日志/性能排查。真实缓存收益需要真实 API 数据，本阶段不做收益承诺。
- 已知边界：Claude 的原生 system 更新会把全部 system 片段合并进一个 checkpoint text part，缓存断点落在该 part；记忆召回变化时该断点会移动。这是 provider 合同层的限制，不在本阶段用客户端标记硬改，留待 provider/合同阶段评估。

## 历史检索（I2.3）

- `history_search`：只搜 run 所属会话的持久化原始消息（后台/唤醒运行不会误读用户当前打开的会话；`session_search` 仍是跨会话）。参数 `query`、`limit`（1–8，默认 5）；每条消息最多一条命中，按新→旧，输出预算约 4k 字符。
- `history_fetch`：按 `message_id` 分页读取原文，返回 `source=original_transcript`、`stale`、`anchor`；`next_offset` 为 null 表示读完。参数校验和输出上限复用 `session_read` 的实现。
- `stale=true` 表示该消息已被某个 completed compact 覆盖、不在当前请求投影里；原消息仍可从存储读取。
- 两者是常驻工具（放进每轮 params.tools），压缩注入文本末尾附带宿主提示，告诉模型何时调用。
- 检索与读取会包含工具调用的 `input`（≤1k 字符）和 `output`（≤2k 字符）投影，命令/错误/退出码/文件路径可从原文恢复；未调用的工具仍以 `[tool: name status]` 一行表示。
- 工具结果带 `anchor={conversation_id,message_id}`；时间线压缩分界是该分界的可视锚点。工具卡片内“一键跳转到原文”尚未接线，留待 P5 UI 阶段。

## 阶段路由（I2.5）

- `IOSContextStageRouter` 默认返回 `.continueCurrent`；`pendingToolRoundTrip`、`pendingApproval`、`hasUnsavedChanges` 任一为真都硬阻断建议。
- 只有 `completedStage` 非空且 `acceptanceEvidence` 非空（去掉空白项）才返回 `.suggestNewConversation`，且只是建议，不自动切会话。
- 该状态机目前是策略模块，生产代码尚无调用方；后续阶段接入“阶段完成”证据后再展示建议。
- iOS 当前没有自动新建/切换会话的执行路径；状态机单测覆盖默认、建议与三条负向用例。

## 扫描版 PDF 的 OCR 回退（I3.5）

- 有文本层的 PDF 仍走 PDFKit 文本提取；只有整份 PDF 没有一个可提取字符时，才对**前 8 页**渲染缩略图并调用 Vision 文本识别（accurate、自动语言、语言校正），按阅读顺序拼接并受 `maxPreviewCharacters` 限制。
- OCR 仍为空才报错，提示改用可复制文本的 PDF 或把扫描件作为图片附件交给视觉模型。
- 图片文件本身不进入“文本上下文”OCR；图片走聊天视觉模型路径。OCR 在 `DocumentAccessStore.readPreview` 的 detached task 内执行，不阻塞主线程。
