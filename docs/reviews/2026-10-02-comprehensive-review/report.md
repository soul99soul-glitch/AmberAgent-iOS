# 全面审查与分阶段修复（2026-10-02）

审查基线：`main` / `ec93292148a9a1db4c028d10a55484b77a43b5f8`，工作区干净。范围仅本独立 iOS/KMP 仓库；不读取其他产品源码。六路只读审查分别覆盖 Chat/runtime、Novel、storage/settings/sync/memory、provider、tools、Watch/Council/DeepRead/Workspace。候选均追真实入口并反证已有保护与 by design；没有把大文件、`try?` 或泛化防御建议列为 bug。

验证基线：iPhone 17 Pro / iOS 26.5 Simulator、Xcode 27，8 个相关测试类 **197/197 通过**。结果 `/tmp/amber-review-baseline-20261002.xcresult`，日志同名前缀 `.log`。通过的既有测试未覆盖下述新增失败窗口。

当前状态：**31组真实问题全部完成修复与独立复审；最终50类整合1443 passed / 0 failed / 3手动采样skipped，受影响JVM合计288/288通过。**

## 确认问题与修复责任

P1 表示可导致正文/配置/运行所有权错误，P2 表示局部功能或状态错误；不是按理论最坏情况定级。下表定位是审查基线，修复后行号可能移动。

| ID | 优先级 | 真实问题、触发与影响 | 基线定位 | Phase |
|---|---|---|---|---|
| N1 | P1 | 导入目标按完整文档计算 hash/equality，实际 FileRepository 裁剪 terminal runs/receipts；正常 workspace/history 导入落盘后仍 pending，重试与重启阻塞后续操作 | NovelProjectLifecycle:326/375/435/499；LifecycleOperations:277/292 | 1 |
| N2 | P1 | export 给重名 branch slug 加后缀，manifest/authority/adopt 仍用裸 slug；外部正文被忽略或映射错误分支 | NovelWorkspaceBackup:83/143；Authority:228；ProjectStore:471/516 | 1 |
| N3 | P1 | package opaqueFiles 相对路径未验证，`../../` 可越出 staging 覆写其他小说文件；checksum 不提供路径边界 | NovelWorkspaceBackup:423/563；NovelDocumentValidator | 1 |
| N4 | P2 | 唯一定位搜索跳到首匹配末尾，漏掉 `哈哈` 在 `哈哈哈` 等自重叠重复，错误补丁可进入正文 | NovelContinuityRepair:137 | 1 |
| S1 | P1 | customBodies 使用 header token 子串规则，误抹 `max_tokens:2048`；非字符串敏感 JsonElement 未入 side-table，重启变空字符串 | IOSCredentialRedactor:161 | 1 |
| S2 | P1/P2 | 主设置忽略 Keychain 写失败，先发布 snapshot 再持久化 mask；保存看似成功，重启丢新 key 或恢复旧值；请求头多凭据写入及配置工具复合保存同样可能部分提交 | IOSSharedSettingsStore:286/299/308/320；IOSProviderRequestHeaders:82；IOSProviderConfigToolService | 1 |
| S3 | P1/P2 | 会话批量 import 逐文件原位写，第二条 IO 失败后第一条已覆盖，Swift 仍保留旧当前会话 | JsonConversationStorage:164；IOSConversationStore:420 | 1 |
| W1 | P1 | reparse 跨 await 保留数组下标，期间删除/插入/移动可越界或覆盖其他记录；普通与 AmberShell write/edit/touch/copy/move 等待解析后也可复活旧记录或抹掉其他成功提交 | DocumentAccessStore:318/852；普通及 shell writer | 1 |
| W2 | P1/P2 | 普通 Workspace UI/tool 改磁盘和内存后 persist 失败不回滚，移动/编辑/删除/新建结果与索引矛盾 | DocumentAccessStore:329/341/382/954/999/1184 | 1 |
| W3 | P1/P2 | selected document 仍先截到 64KB 再猜编码，中文 UTF-8 断字落入 UTF-16、GB18030 也被误解码；长文本与既有完整读取契约不符 | DocumentAccessStore readTextPreview/decodeText；3 项现有行为测试实际失败 | 1 |
| C1 | P1 | Chat stream 当前轮只在正常 complete 进入 working；cancel/error 权威快照抹掉已显示 partial，尚未发布尾 chunk 同样丢失 | IOSAgentToolEngine:915/1371/1394；ChatRunKernelAdapter:420/580 | 2 |
| C2 | P1 | terminal persist await 期间 Host 仍允许 background handoff/durable detach，重复请求并产生双 owner | ChatKernelRunHost:1169/1300/2154 | 2 |
| F1 | P1 | Council 身份 guard 后 await durable 操作，返回未再校验便清空新 discussion；旧 ensureRunning 失败也可解除新 owner | CouncilChatRuntimeView:2595/2697 | 2 |
| F2 | P1/P2 | DeepRead store 保存失败仅 print，create/complete 仍成功，启动计费或 durable completed 后重启丢任务/文章 | IOSBoardPersistence:2961/3067 | 2 |
| N5 | P1 | 计划面板关闭 autosave 捕获草稿而不捕获 origin，等待旧 save 后按新 selection 把 A 草稿写 B | NovelSessionSheets:1299；NovelCreationViewModel:1895 | 2 |
| N6 | P2 | 审批成功只记内存 answer，切分支/冷启动重现待审批；已写入完成态丢失 | NovelSessionViewModel:1644；Presentation:1326 | 2 |
| N8 | P2 | QuickStart回答/精确重试已接受启动，新run在bind await期间快速完成，activeRunID变nil被误报false；答复仍落盘却撤销本地已回答态 | NovelSessionViewModel:1739/2151；startQuickStartSuggestions accepted-ID契约 | 2（整合追加） |
| N7 | P2 | 计划面板关闭 autosave 失败只报错，六字段随异步任务结束丢失，重开回到旧计划；独立复审追加并二次确认 | NovelSessionSheets onDisappear / plan field loading | 2 |
| S4 | P2 | memory 去抖实例全局而非 run 内，同集合跨 run 不刷新用户可见 lastUsedAt；不影响召回排序 | IOSMemoryPersistence:990；ChatViewModel:4277 | 2 |
| P1 | P1 | Gemini 丢弃服务端 functionCall id，返回结果不带原 id，同名调用不能正确配对 | IOSGeminiProvider:532/1121/280 | 3 |
| P6 | P1 | Gemini 多帧 calls 以局部 part index 聚合会覆盖；parallel 回放拆成不同 model/user 轮次，改变同轮与签名语义 | IOSGeminiProvider:519/631/246 | 3 |
| P2 | P1/P2 | Gemini candidate SAFETY/MALFORMED_FUNCTION_CALL 等 finishReason 被当成功，partial/空结果正常完成 | IOSGeminiProvider terminal finish | 3 |
| P3 | P2 | Gemini request 忽略已持久化且消费入口传入的 customBody，设置对实际请求不生效 | IOSGeminiProvider:406 | 3 |
| P4 | P1 | Claude 丢弃 redacted_thinking；空 reasoning 的 opaque signature/encrypted metadata 还会被 accumulator 去掉，工具续轮无法原样回放 | ClaudeKmpProvider:868；MessageStreamAccumulator:351 | 3 |
| P5 | P1/P2 | OpenAI 非流式 Responses 仅看 HTTP 状态，status failed/incomplete(content_filter) 被当成功，和流式处理不一致 | OpenAIKmpProvider:822 | 3 |
| P7 | P1/P2 | 切 provider 或切 Responses 后保留的非空推理历史直接按新协议回放：Claude 缺必需 signature、Responses 缺必需 reasoning id；普通 Chat Completions 无 metadata 推理也可触发请求失败 | Claude toContentBlock；OpenAI addResponsesAssistantItems；Chat model Picker / provider config tool / PromptTranscript | 3 |
| T1 | P1 | remote adapter await fresh snapshot 时用户接管，恢复后尚未派发的 mutation 仍发送，事后才报 unknown | IOSWebMountDesktopBackend:485/546；IOSLocalToolExecutor:6751 | 4 |
| T2 | P1/P2 | remote 新建浏览任务 UI 不传已注册 site_id，Playwright/CDP 必定 site_binding_required | WebMountDesktopBackendsView:514 | 4 |
| T3 | P2 | MCP tools/list 忽略 nextCursor，后页工具无法发现与调用 | IOSMcpClient:663 | 4 |
| T4 | P2 | HTTP SSE 取首 JSON 而不是匹配 id 响应，通知遮蔽结果；CRLF 分帧失败 | IOSMcpClient:371 | 4 |
| T5 | P2 | SSH channel-data 每帧独立 UTF-8 解码，分包中文/emoji 永久变替换字符 | IOSSSHRuntimeBackend:607 | 4 |

## 二次复核与排除

- Watch 动作、离线笔记和快照已有 durable receipt / ACK / ordering，未找到绕过保护的具体入口。
- DeepRead 缺段重试已有 priorCompletion；全文成功稿不可随意整篇重试，不报草稿必丢。
- Council streamer late callback 有 guard，真正问题是 guard 之后的数据库 await。
- 小说 terminal 裁剪是设计，N1 是 import 不使用同一投影；非主分支文件保留 opaque 是交换协议。
- 审批再次主动点击仍是用户授权；N6 仅是明确完成态丢失，不报自动越权。
- needsSync 正文门禁、marked text 提交、collect owner/事务已有保护。
- Settings backup 不带凭据、HealthKit conversation 不导出是既有契约。
- ProviderRegistry 旧编辑入口当前不在正式 UI 主路径，不修静态 legacy 风险；SettingsStore scalar projection 仍可达，凭据阶段局部改为原位 update。
- 已有 side-table update、title/pin metadata merge、unreadable memory guard、聊天 image data URL 与 restore active-run gate 不重复报。
- MCP 修改工具断线不自动重试是正确设计；工具分页 2024-11-05 已支持；HTTP SSE 通知由 2025-03-26 transport 允许。
- SSH auth 等待由 production waitJob 超时取消，不能报永久 running。
- 后台 output-limit 源码 canary 是假阳性：生产已使用 typed recordedStatus 与统一 failed/retryable presentation；旧断言只寻找内联 ternary 和 `.failed()` 字面。更新 canary 到现有失败策略调用链，未改正确生产行为。
- exec JSC abandon、超时后关闭 nested call、远程不支持登录站点/坐标截图属于既有能力边界。

外部协议依据：[MCP tools 2024-11-05](https://modelcontextprotocol.io/specification/2024-11-05/server/tools)、[MCP transports 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports)、[Gemini function calling](https://ai.google.dev/gemini-api/docs/generate-content/function-calling)、[Gemini finishReason](https://ai.google.dev/api/generate-content)、[Claude thinking 回放](https://platform.claude.com/docs/en/build-with-claude/thinking)。

## 分阶段计划与执行结果

每期均完成真实失败路径复现、局部修复、主 agent 串行验证、非实现者 subagent 独立复审，以及复审增量闭环。不为通过放宽阈值，不新增自动重试、明文兜底或 provider provenance 框架；不删除死代码，不创建未请求的 commit/PR/push。

| Phase | 问题组 | 修复目标 | 状态 |
|---|---|---|---|
| 1 | N1–N4、S1–S3、W1–W3（10组） | 文件、正文、配置与凭据耐久性 | 实现、独立复审、365项Swift和42项JVM通过 |
| 2 | C1–C2、F1–F2、N5–N8、S4（9组） | partial保留、owner收口、审批与草稿恢复 | 实现、独立复审完成；N8整合追加，最终全类回归通过 |
| 3 | P1–P7（7组） | 真实工具身份、opaque reasoning、协议失败与请求设置 | 实现及增量独立复审通过；246项JVM与真实Shared/Swift消费验证 |
| 4 | T1–T5（5组） | 正确派发、可用创建入口、工具分页与Unicode输出 | 实现、三路独立复审及101项受影响测试通过 |

## 已落地的修复行为

Phase 1：

- N1：导入目标使用真实仓库的持久化投影计算 hash、比较及重试；保留完整交换文档身份校验，原 full-hash pending 只在完整原包与已落盘目标精确匹配时恢复。
- N2/N3：统一 export/manifest/authority/adopt 的 branch slug 分配，兼顾 Mac 文件系统大小写碰撞；两种 package writer 都在触碰 staging 前批量验证 opaque 相对路径。
- N4：第二次匹配搜索从首匹配的下一个字符开始，正确识别重叠重复。
- S1/S2：精确 credential key 规则与类型保真的 side-table sentinel；设置、多个请求头及配置工具先完成凭据写入，再提交整体 snapshot。失败不发布成功，回滚失败如实报错；scalar Keychain 原位 update，保留已有凭据。
- S3：会话批量导入先全部 stage，再以同文件系统 atomic move 提交；后续失败按逆序恢复，cache 与 canonical 文件一致。
- W1/W2：跨 await 重新核对原 record/文件/路径权限；本次修改先持久化候选索引再发布，失败只恢复本次影响的 payload，避免回滚其他成功提交。普通 UI/tool 与 AmberShell 路径均覆盖。
- W3：selected document 保持既有 20MB 输入上限，取消额外 64KB 预览截断；完整解码后按 decoded UTF-8 字节预算截 Workspace preview，保持完整字符；识别 UTF-8/明确 BOM/GB18030，不任意猜 UTF-16。

Phase 2：

- C1/C2：stream error/cancel 使用同一 accumulator 的精确最新快照，保留正文、推理和尚未发布尾段，未完成工具不执行；guard 收尾保留 PromptTranscript。工具执行期维持及时取消，terminal persist 窗口禁止重复 handoff/detach。
- F1：Council 的 durable await 返回后再次核验 generation owner，旧启动/失败/完成不清空新 discussion。
- F2：DeepRead create/run/complete/retry 的保存失败阻断后续计费或导出，保留旧稿且错误可见；Workspace retry 只复用实际 source/title/正文完全匹配的 artifact，正文修订仍可另存。
- N5/N7：计划面板固定原 project/branch owner，关闭异步保存不追随新 selection；失败草稿的六字段在 ViewModel 内保留、重开恢复、手动重试，旧保存不能清掉新草稿。仅承诺 ViewModel 生命周期内恢复。
- N6：审批答复与对应领域修改在同一 durable document commit 中写入；checkpoint 游标与重复回答门禁一致。
- S4：记忆使用去抖归属原会话与 run，跨 run 同集合刷新 lastUsedAt；只有真实持久化成功才推进去抖，force 路径保留。
- N8（整合追加）：QuickStart 回答与精确重试按非 nil accepted ID 返回启动已接受，不以绑定返回时仍 active 判成功；保留 busy/eligibility、同步拒绝及 retry 新旧 ID 门禁。任务后续失败仍走已有状态管线。

Phase 3：

- P1/P6：Gemini 保留实际 wire call ID，跨帧完整调用独立聚合，同一轮多个调用与结果分别成组回放；省略 args 的合法无参调用使用独立槽，仍兼容旧字符串 JSON fragments、name restatement 和 EOF flush。
- P2：明确的失败 finishReason 在派发 pending tools 前抛出，已收 partial 保留；STOP/MAX_TOKENS 与未知终态沿用正常兼容语义。
- P3：customBody 经 Kotlin CustomBody owner 的 JSON 序列化进入真实 Swift request，保留对象、数组、标量类型与有序覆盖。
- P4：保留原 redacted thinking、signed/encrypted opaque metadata 与块 identity；上传资格包含原生 opaque-only，Swift 仅隐藏空 opaque 卡片，正文与工具次序不变。
- P5/P7：Responses 非流式失败终态与流式一致；请求投影按目标协议要求筛选 reasoning（Claude 原 redacted 或有效 signature，Responses 有 reasoning_id），不修改 canonical history，不虚构签名/ID、不强求 encrypted content。

Phase 4：

- T1：fresh snapshot await 后，在实际交给 MCP callTool 的派发点重新检查 controller ownership；未派发返回 rejected/control_unavailable/false，已派发后失去控制权仍保留 unknown_after_action/true。
- T2：创建 UI 选择启用的匿名站点，与真实 controller 测试共用 request builder；每次创建带选中 site_id，原绑定权限继续由 controller 执行。
- T3/T4：按 opaque nextCursor 取完整工具目录，原 schema/annotations 保留；HTTP SSE 归一化 LF/CRLF/CR，选严格匹配请求 ID 的 result/error，无匹配显式失败，不增加修改工具自动重试。
- T5：stdout/stderr 各用项目已有 UTF-8 decoder，字符完整解码后进入原 redactor；所有结束路径先 finish decoder 再 finish redactor，保持两通道与 secrets 边界。

## 验证结果与证据

最终50个受影响测试类整合 **1446：1443 passed / 0 failed / 3 skipped**，运行器退出0：`/tmp/amber-review-final-integration-green3-20261002.xcresult`。小说完整Session类 **107 passed / 1手动采样 skipped**，N8回答/重试确定性用例均通过。聊天规定的三个布局/滚动/viewport类、全部前期持久化与本期工具修复均在同一最终结果包中。受影响JVM四模块合计 **288/288**。

三项skipped是未开启`AMBER_PERF_SAMPLE`的手动性能夹具：Reasoning stream cost、Council long stream profiler、Novel long prose profiler。普通回归没有通过skip绕开失败。xcresult还记录一条测试夹具在未安装View外访问State的runtime warning（SharedSettings writeback测试）；没有将其声称为真实UI或无warning验收。

[机器可读验证摘要](evidence/final-validation.json) 包含全部50类计数、skip名字、JVM模块结果和最终结果包路径。

| 验证 | 实际结果 | 证据 |
|---|---|---|
| 最终整合Swift | **1443 passed / 0 failed / 3 手动采样 skipped** | `/tmp/amber-review-final-integration-green3-20261002.xcresult` |
| 审查前基线 | 197 passed / 0 failed | `/tmp/amber-review-baseline-20261002.xcresult` |
| Phase1完整Swift | 365 passed / 0 failed | `/tmp/amber-review-phase1-green4-20261002.xcresult` |
| conversation-storage JVM | 42 passed / 0 failed | `/tmp/amber-review-phase1-import-green.log` |
| 最终ai-core/Claude/OpenAI JVM | 145 + 25 + 76 = 246 passed / 0 failed | `/tmp/amber-review-phase3-final-green-20261002.log` |
| Gemini真实Shared/Swift消费 | 全类53/53；包含Kotlin JSON对象/数组桥、wire ID与无参调用 | `/tmp/amber-review-phase3-final-green-20261002.xcresult`内该类 |
| Phase4工具组 | 101/101（MCP35+11+11、SSH2+4、WebMount38） | `/tmp/amber-review-phase4-green-20261002.xcresult`内相关类 |
| N8确定性RED→GREEN | 旧源码2/2失败 → 最终两项通过；busy、完成、内容控制保持 | `/tmp/amber-review-n8-red-20261002.xcresult` |

可复查的主要旧源码RED：

- Phase1 conversation import真实IO失败、Keychain两项故障、Workspace中文/长文与复合配置保存。
- Phase2 stream cancel/error/terminal handoff **4/4失败**：`/tmp/amber-review-phase2-chat-red3-20261002.xcresult`；工具期间及时取消 **1/1失败**：`/tmp/amber-review-phase2-toolcancel-red4-20261002.xcresult`。
- Phase3核心/provider **8个失败断言**：`/tmp/amber-review-phase3-provider-red-20261002.log`；Gemini初次6项失败、后续合法省略args与真实对象/数组桥失败，经两次复核才闭环；P7 Claude两项、Responses三项原生回放资格失败，native ID无encrypted控制通过。
- Phase4 MCP6、SSH1、WebMount3，共 **10个真实失败**：`/tmp/amber-review-phase3-gemini-green-phase4-red-20261002.xcresult`。Gemini53/53同时通过，不把混合包称GREEN。

复核中修正的测试问题与判断：

- 12项旧fixture/格式假设与当前调用链不符：toText换行、并行HTTP计数、已经不用的monofile损坏方式、已有原子正文/剧情同步、terminal刷新可操作窗口、倒退Date。只修接线与等待，保留业务结果断言。
- UI首行追底首次48.333333略超原48阈值，同binary隔离与后续整期通过；未改生产、未放宽阈值，不把一次临界调度波动列为确定bug。
- 主agent曾误读QuickStart失败行号，把`XCTAssertTrue(didAnswer)`误记为didFinish；两路重新追证后撤回“fixture-only解决该失败”的判断，追加真实N8并用绑定gate稳定复现回答/重试两条路径。原proposals终态等待校正合理，但不能代替生产返回值修复。
- 最终首轮50类 **1446：1441 passed / 2 failed / 3 skipped**。两项新增范围中的旧fixture：搜索noop仅返回旧DDG Lite HTML，默认免费聚合实际进入Google WKWebView；local tools fileSync早在AmberShell提交即为true，Swift旧assert漏同步。分别改为局部Brave JSON传输与当前已实现契约，保留业务断言，未改生产。两项测试修正通过独立复审，最终全范围GREEN。
- 第二轮整合green2在已完成编译后未加载XCTest bundle：输出为空、应用采样仅主循环。停止本任务运行器、shutdown/boot模拟器保留数据，以同一已编译binary执行test-without-building green3；green2不计RED/GREEN。
- 前期编译取消、测试bundle未加载和后置诊断收集不计产品RED。诊断仅停止本任务运行器，模拟器重启保留数据，未erase/reset工作区。

## 独立复审与视觉证据

Phase1小说/Workspace、KMP/redactor、主配置三路；Phase2逐组及N7/F2/C1增量；Phase3三provider和P4/P7两方向资格增量；Phase4 MCP、SSH、WebMount三个非实现者。N8另由非实现者复核确定性gate、accepted-ID合同和两处最终返回值，实际RED→GREEN及全类回归闭环，未发现未闭合的源码阻断。

主agent已实际查看以下完整View hosting渲染图。393×852、320×640的window/host bounds和横向内容宽度断言通过，顶部及滚动后站点Picker与创建按钮可见且可达，中文文字未横向溢出：

- [393顶部](evidence/webmount-desktop-creation-393-top.png) / [393创建控件](evidence/webmount-desktop-creation-393-creation-controls.png)
- [320顶部](evidence/webmount-desktop-creation-320-top.png) / [320创建控件](evidence/webmount-desktop-creation-320-creation-controls.png)

无合格站点时禁用创建的路径仅源码验证，没有实际操作该negative UI场景。

## 证据边界与交付范围

结论覆盖本轮识别并修复的31组真实问题，不表示整个产品再无bug。修复、测试与本报告由本轮提交交付；未创建PR，未读取其他产品源码。当前默认生产聊天路径按本次源码核对为NativeChatTimelineView，未用旧记忆中的入口替代验证。

模拟器和JVM验证不证明真实收费provider接受、真机后台/系统权限、物理Watch链路、实际外部SSH/MCP服务、IME手感或120Hz性能。协议请求和工具验证分别使用真实serializer/URLRequest、离线MCP回应、SSH loopback与完整View hosting；这些边界未声称已人工/真机验收。
