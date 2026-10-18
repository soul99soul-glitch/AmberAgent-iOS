# KMP / provider 只读审查（2026-10-18）

范围：独立 iOS/KMP 根内 `ai-provider-openai/`、`ai-provider-claude/`、`ai-core/`、`shared/`、`core/conversation-storage/`、`core/agent-runtime/`、`core/agent-store-room/` 及 Swift 消费入口。保护现有 dirty/untracked，未编辑生产/测试文件，未运行构建或 Gradle。下面两项可直接进入修复；第三项有代码层线程证据，但仍建议 root 结合运行证据定级。

## KMP-01 [P2] OpenAI 拒答被吞成空成功消息

**位置**：`ai-provider-openai/src/commonMain/kotlin/app/amber/ai/provider/openai/OpenAIKmpProvider.kt:1267`（Responses event dispatch）及 `:899–915`（终态 message 清空）；Chat Completions 同类缺口在 `:630–664`。

**触发**：前台 Responses（含 CODEX_OAUTH）收到 `response.refusal.delta` / `response.refusal.done`，最终 `response.completed` 的 output message content 为 `{"type":"refusal","refusal":"I cannot help with that."}`。Chat Completions 的标准拒答则在 `message.refusal` / `delta.refusal`，content 通常为 null。

**调用链/结果**：`OpenAIKmpProviderAdapter.streamText` → `streamTextCancellable` → `responsesStreamText` → `parseResponsesStreamData` → `parseResponseDelta` 没有 refusal 分支，因此增量为 null。completed 通过 `parseResponseOutput` 确实拿到 refusal Text（:1548–1552），但 `normalizeResponseStreamAssistant` 将所有 final message 的 parts 清空，最终完成回调返回空 assistant，用户看不到服务端拒答原因。`responsesGenerateText` 对 Codex 也复用该流，因此一次性 Codex 子代理同样受影响。Chat Completions `parseMessage` 完全不读 refusal，流/非流均丢失。

**二次反证**：不能按 unknown event/by design 排除：同一 provider 的非流 Responses 明确把 refusal 作为文本处理，说明产品契约是展示拒答；foreground 最终清空是用于避免 output_text.done/response.completed 重放，不代表拒答应消失。官方 OpenAI background transport 直接交付 final message，不经过该 normalizer，因此它的 Responses 最终拒答有显示，不把影响扩大到该路。

**最小修复**：让 Responses refusal.delta 进入普通文本增量（done 仍只作最终快照避免重复），Chat Completions 在 content 为空或并行可见文本规则下保留 refusal 文本。不要取消现有 done 去重设计；补至少 foreground 完整事件序列回归，覆盖 refusal 多 delta + done + completed恰好出现一次、普通正文不重复；补 chat refusal 流/非流映射。

**现有测试缺口**：`OpenAIKmpProviderResponsesStreamTest` 测 output cap/error/tool call done，但没有 refusal；`OpenAISseLineParserTest` 无拒答。仅测试 `parseResponseOutput` 终态 refusal 会漏掉真正缺陷，回归必须经 `responsesStreamText` / MockEngine 最终消费者。

## KMP-02 [P2] Gemini schema 清理误删合法同名参数

**位置**：`shared/src/commonMain/kotlin/shared/GeminiWireToolMapper.kt:75–81`，尤其 `.filterKeys { it !in GEMINI_UNSUPPORTED_SCHEMA_KEYS }`。

**触发**：用户启用的 MCP/dynamic tool 合法 schema 包含名为 `format`、`enum`、`const`、`additionalProperties` 等参数。例如 `properties: { format: {type: "string"} }, required: ["format"]`；nested object 同样受影响。

**调用链/结果**：Swift `IOSGeminiProvider.functionDeclarations` (:327–333) → `GeminiWireToolMapper.functionDeclarationsJson` (:39–58) → recursive `strippedForGemini`。递归把 `properties` 的属性字典也当 schema node 过滤，合法 `format` 参数被删除，required 仍指向 format。请求 schema 不一致，可被 provider 拒绝，或模型无法形成工具需要的字段。

**二次反证**：删除 schema keyword 是现有兼容行为，保留；问题是属性名与 keyword 的上下文混淆。MCP schema 允许任意正常属性名，`properties.format` 并非 schema 的 format 关键字，因此不属有意禁止参数。

**最小修复**：对 schema node 删除指定 keyword；对 `properties` 这一名称映射保持每个 key，只对各 value 的 schema 递归。保持 items、nested properties/数组schema 现有递归能力，不额外引入新schema兼容框架。

**现有测试缺口**：`shared/src/commonTest/kotlin/shared/GeminiWireToolMapperTest.kt` 的 recursive 测试只包含 name/choice/range/tags 之类属性；断言还错误要求整个输出树所有 object key 永不出现 keyword，需将断言限定 schema node，并增加 properties 同名字段 required 正常保留（含nested）。

## KMP-03 [P2 待运行测量] metadata 和 import 路径同步工作仍在 Swift MainActor

**位置**：`core/conversation-storage/src/commonMain/kotlin/app/amber/core/storage/conversation/JsonConversationStorage.kt:253` import、`:389` updateMetadata、`:402` updateTitleIfCurrentTitleMatches、`:417` updateMemoryMode。仅 listSummaries/loadConversation/saveConversation 使用 `withContext(Dispatchers.Default)`（:73/:108/:173）。

**触发/链**：`IOSConversationStore` 是 `@MainActor`，恢复、rename、pin、mark/reset pollution分别直接 `try await storage.importConversations` (:395)、updateMetadata (:1102/:1126)、conditional title (:1095)、updateMemoryMode (:899/:915)。锁无竞争时 `Mutex.withLock` 不发生线程切换，Kotlin suspend 导出也不自动移至 Default；这些方法内同步读正文、JSON编码、blob处理、整文件写/索引写因此可在主线程执行。大截图会话/整批restore会明显放大此工作。

**二次反证**：已有 save/load 主动 dispatcher 设计及注释明确承认 ConversationFile/serializer 为同步，不能以“suspend所以异步”排除。互斥只解决并发读写，不提供后台线程。未运行设备耗时/主线程钩子测试，不声称已实测卡顿。

**最小修复/验证**：保持 mutex 覆盖整个读改写窗口，与现有 save 一致包住 Default dispatcher。建议先记录 storage hook 所在线程证明主线程路径，或用现有大blob夹具测 rename/import 前后耗时；并重跑 metadata/import/rollback/记忆污染既有Gradle测试。无须新增调度框架。

## 已排除及跨组反馈

- `removeProviderChatModel` 不清理当前模型引用：初看可疑，已撤回。`ProviderDetailView.deleteModel` 主动检测当前模型并展示 `.currentModelDeleted`，`Settings/Providers/ProviderDetailModelSupport.swift:264–267` 明确要求用户重新选择；属当前设计，不自动改变选择策略。
- Responses output cap max_output_tokens 已有专门正常截断契约和测试，不把 `response.incomplete` 一律当失败。
- 已向 storage 组确认：KMP `saveConversation` 仅 merge metadata owner，`messageNodes` 全量随 incoming 覆盖；operationMutex 不会防 caller stale snapshot。Swift 分支操作如缺baseline须在其owner修复，不能在KMP随意merge消息树。
- Blob missing placeholder、保留失败blob和imports先全批验证/备份/rollback均有明确契约；未基于理想化完整性另造兜底。
- 未将 dead code /未被Swift消费的接口能力不足报bug；agent-runtime主体目前为协议，Room durable DAO 的单SQL event sequence + transaction写计数有明确并发设计。
