# KMP / Phone 独立二次技术复核

2026-10-18，只读源码与协议文档；未改源码/测试，未构建、未运行测试或性能测量。阅读 audit-kmp.md 后独立追生产入口和现有设计。

| 项目 | 二次结论 | 说明 |
|---|---|---|
| KMP-01 Responses refusal 消失 | **accepted / P2** | 真实生产链丢内容；与现有终态去重设计可兼容修复 |
| KMP-01 Chat Completions refusal 消失 | **accepted / P2** | stream/non-stream 共用 parseMessage，均忽略 refusal |
| KMP-02 Gemini properties 合法同名字段被删除 | **accepted / P2** | schema node 与名称映射混淆，非有意禁止参数名 |
| KMP-03 metadata/import 主线程 IO 卡顿 | **uncertain；仅验证候选** | 同步工作/无 dispatcher 的代码证据成立；当前运行线程、耗时和可见影响未测，不列 confirmed bug |
| Phone dismissKeyboard 跨 scope 发送 | **accepted / P2** | client 与 runner 均缺少允许应用范围检查 |
| Phone 自动 type 后暂停仍发 dismissKeyboard | **accepted / P2** | 现有 handoff owner 已有状态，await 后遗漏复查；无需新状态机 |

## 1. Responses / Chat Completions refusal

生产链：`IOSAgentProviderAdapter.swift:13,125-135` 的 OpenAIKmpProviderAdapter → KMP streamTextCancellable → `OpenAIKmpProvider.kt:224,827-853` responsesStreamText → parseResponsesStreamData → parseResponseDelta。`1267` 起仅 output_text.delta、output_text.done 等分支，没有 refusal.delta/done。`1544-1552` 的 parseResponseOutput 确实从 message.content[].refusal 构造可见 Text，但 `899-915` 的 normalizeResponseStreamAssistant 将此 message 变成空 delta，所以完整拒答事件流只留下空消息。Codex OAuth 一次性请求在 `789-811` 复用此流和 accumulator，也受影响。

反证：非流 Responses 已把 refusal 当 Text，不是产品有意隐藏拒答。OpenAI Docs 官方协议明确区分 refusal.delta 的 delta 和 refusal.done 的 refusal：[Responses streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events)。本次实际打开并核对相关定义。后台专用 final-response transport 不走此 normalizer，不把影响扩大到所有后台路径。

最小修复：让 refusal.delta 复用普通 Text delta 形状；done 保持与正文 done 相同的最终快照/去重边界，不取消 completed 去重。`parseMessage:630-664` 同时映射 Chat Completions 的非空 refusal，保证 content 为 null 时仍展示，也不覆盖已有 content。

必要回归：经 MockEngine 驱动公开流消费者，多个 refusal delta → refusal.done → output_item.done → completed 最终恰好一次文本；普通正文不重复；Codex generateText 拒答不为空；Chat Completions stream/non-stream refusal 均保留。只测 parseResponseOutput 不足以验证真缺陷。

**rejected 扩大修复**：直接保留 completed 的全部 final message 会重复正常 delta+done 文本，破坏原契约；无需新输出状态机或通用 fallback。

## 2. Gemini schema properties

生产链：`IOSAgentProviderAdapter.swift:75-91` Google 路由 → IOSGeminiClient → `IOSGeminiProvider.swift:423` makeBody → `327-333` functionDeclarations → `GeminiWireToolMapper.kt:39-56,75-81`。filterKeys 对每一个 JsonObject 无差别删除 unsupported 集合；所以 `properties: {format: {type: string}}, required: [format]` 在递归中变成空 properties，required 仍留下 format。nested properties 同样受影响。

[JSON Schema object 文档](https://json-schema.org/understanding-json-schema/reference/object) 明确 properties 的各 key 是实例属性名，value 才是 schema；properties.format 并非 format schema keyword。当前测试仅用 name/choice/range/tags；末尾对所有 object key 一律禁止关键词的断言，把名称映射上下文抹掉了。

最小修复：仅在 schema node 过滤既有 unsupported key；遇到 properties 名称映射时保留每个名称，再对各 value 的 schema 递归；items/nested/arrays 保留现有递归。增加根和 nested format/enum/const/additionalProperties 名称及 required 保留测试；原 keyword 断言限定 schema node。

**rejected 扩大修复**：不借此改变既有 enum/format 兼容取舍，不增加 schema 框架或扩大支持范围。

## 3. JsonConversationStorage IO

`IOSConversationStore.swift:77,230` 是 MainActor 并直接构造 JsonConversationStorage；`:395` import、`:1095/1102/1126` 标题/置顶、`:899/915` pollution 直接 await KMP。KMP import `253`、metadata `389`、conditional title `402`、memory `417` 的锁内同步 load/encode/write 未显式 dispatcher；list/load/save 已用 Default，并有同步 IO 注释（`:73-115`）。这些代码说明 suspend 不构成后台保证，但实际当前线程、主线程阻塞时长和可见卡顿仍未观测。

结论：**uncertain，仅验证候选**。先用现有 hook 或线程日志验证 Swift→Kotlin/Native 调用所在线程，再用已有大 blob 会话记录 rename/import 耗时。若确认为主线程高成本工作，最窄方案是在现有 operationMutex 全读改写窗口内使用与 save 相同的 Default dispatcher，保留串行及 rollback 契约。当前不按 confirmed P2 计入，不据理论直接修复。

## 4. Phone scope 与自动键盘操作

`PhoneRunnerClient.swift:289-296` 的 home 先 activeApp/checkScope，dismissKeyboard 直接发 `/wda/keyboard/dismiss`。runner `RunnerWDA.swift:1019-1037` 取得当前 foregroundTree，找到 Done/Return/Hide keyboard 后 tapPoint；它不保存 run 允许应用范围，也不接收 expected_pid，故没有内层校验。type 自动调用在 `IOSPhoneControlToolExecutor.swift:161-165`，同样进入此 client 分支。

**scope 最小修复足够精确**：在 dismissKeyboard 分支加入与 home 完全相同的 `try checkScope(try await activeApp())`；保留 beginOperation/checkCanContinue/最终 dispatch 检查。可阻止已切到范围外应用时的动作，无需新增 run/app 状态。query→POST 间仍有与其他动作相同的时间窗口，不声称原子设备身份校验，也不借机改 runner 协议或新增状态机。验证范围外 unsent 且零 keyboard POST、允许应用正常 POST 即可。

**独立已证实的 handoff 门禁遗漏**：MainActor 在 await runner.act(.type) 挂起期间，`IOSPhoneControlController.swift:544-551` requestHumanTakeover 可把 handoffState 改为 pausing；它不停止 runner。返回 completed 后 executor 不复查 canDispatchAction，仍调用 dismissKeyboard；runner 的 stopped/cancellation 不知道 controller pausing。Return 可能提交当前表单，因此不是无害清理。

最小补充：自动 dismiss 条件增加 `!Task.isCancelled && controller.canDispatchAction(runID: runID)`，复用现有暂停/接手状态和 receipt。补受控 type 挂起→requestHumanTakeover→type completed 回归，确认无 keyboard POST。保留原 type completed receipt；既有 performWithHandoff 后续进入 handback，不把成功 type 改报未发送。
