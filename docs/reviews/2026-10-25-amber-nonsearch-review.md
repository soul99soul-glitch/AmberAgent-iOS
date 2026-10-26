# Amber 整体审查与修复（排除搜索）

## 范围与完成标准

用户纠正本轮 prompt 后，以当前 iOS/KMP 产品为整体审查对象；搜索由另一 session 负责，本组不再审查或推进搜索修复。覆盖聊天生成与工具运行、状态/持久化/同步、provider/认证桥、后台/系统集成、小说等生产流程。

候选必须二次复核可达条件、契约和影响，区分真实问题、假阳性与设计行为；按依赖形成修复阶段，每阶段由未参与实现的 subagent 复审。先跑受影响验证，达到标准即收尾，不新增假想需求的兜底/抽象/重试。

## 基线、授权与保护

- 当前目录 `/Users/arquiel/Downloads/AI/amberagent-ios`，独立产品根；`main`，HEAD `bd51719c4bf265f5e63fabed1f337c26fefd2c77`。
- 用户纠正范围时的 tracked diff/status 另存 `/tmp/amber-full-review-20261025/`。保护所有 WIP，尤其另一会话负责的搜索内容；不 reset/stash/clean，不提交/推送/发布。
- 搜索本组之前的工作交接见 `2026-10-25-search-session-handoff.md`，不把半成品写成验收完成。
- 已知系统门禁：Xcode 27.1 要求 CoreSimulator1174.9.2，系统1171.7；XCTest未能启动。继续做可用的源码/KMP/编译验证，不升级系统组件。

## 审计工作包

1. 聊天生成/流式/取消/终态/审批状态。
2. 会话持久化、索引、媒体、同步与备份。
3. 模型/provider请求、认证/凭据、Swift/KMP桥接。
4. 后台任务、系统集成、手机控制、自动化所有权。
5. 小说领域、生成/事务/项目状态与运行边界。
6. 主 agent 集成、候选二次复核、阶段划分与验证。

所有包初始只读，发现真实问题先报告可达证据。搜索文件不在本组修改范围；共享混合文件只可修改与搜索无关且已核实的owner路径。

## 状态

整体审计和二次复核已收敛：确认31项问题，代码修复及Phase A–E独立复审均已完成。Phase F当前进行最终集成编译；尚未据此宣称App XCTest或设备验收通过。

## 修复阶段

1. Phase A：聊天取消/迟到结果、后台终态通知与wake状态所有权。阻止已取消批准继续副作用或覆盖取消，修复旧Jev结果覆盖新状态、已落失败终态漏通知及确认后的wake阻塞问题。
2. Phase B：会话与线程持久化一致性。修复fork携带pending工具、污染状态旧快照回写；队列消费耐久候选仅在二次证实且可作owner级修复后纳入。
3. Phase C：provider协议与认证归属。修复已证实的Claude thinking版本协议、logout/refresh迟到状态覆盖，继续复核具体credential写入失败路径。
4. Phase D：小说与独立功能。修复已证实的讨论工具后重试、候选粒度持久化、导入同revision误判成功、同run重附payload和legacy恢复候选；修复DeepRead选择/重复启动与Council过时事实。
5. Phase E：工具恢复/取消与必填输入。修复MCP只读刷新取消恢复、等待取消、OpenAPI DNS预算与文件写入缺必填内容误清空。
6. Phase F：集成检查及一次当前改动维护性审查。复用通过的证据，只重跑受新改动影响的检查；明确App XCTest、设备和真实provider边界。

并行实现包按文件所有权隔离，阶段完成不等于其他阶段已验证。未确认候选不提前列入最终问题清单。

## 已有基线验证

- `swift test --package-path iosApp/Packages/AmberPhoneControl --scratch-path /tmp/amber-full-review-20261025/PhoneControlBuild`：126个现有package测试通过。它验证host端PhoneRunnerClient当前行为，不代表真机runner/手机操作验收。

## 确认问题台账（已完成代码修复）

审计按真实owner和用户可见失败拆分，二次核对上游门禁/现有设计；同一问题的多个入口不重复计数。下表31项均已修复。C01为P1，其余为P2；批准后取消、输入/文件耐久性等高代价失败优先处理。

| ID | Phase | 问题与可达影响 |
| --- | --- | --- |
| A01 | A | 审批后的工具执行没有独立可取消owner，停止后副作用继续，迟到结果覆盖取消快照 |
| A02 | A | 上传准备的非结构化Task不传播取消，辅助网络/识图/压缩继续且拖延退出 |
| A03 | A | Jev旧轮完成校验迟到，覆盖新轮notice ID并隐藏正确提示 |
| A04 | A | 后台失败/截断终态被expiration抢占时，已保存failed却漏终态通知，父线程/wake收不到完成 |
| A05 | A | 同expiration分支在未保存/仍需恢复时finish，提前摘除checkpoint task-map/payload |
| A06 | A | wake终态队列写入一次失败后不再对账，旧running堵塞后续due任务 |
| B01 | B | 当前会话手动恢复memory后，普通旧消息快照再次写为polluted |
| B02 | B | fork(all)继承pending父工具，子引擎可能重放spawn或其他未授权操作 |
| B03 | B | steer先清唯一sidecar再异步保存，保存失败丢失排队用户输入 |
| B04 | B | mailbox先ACK再异步保存，保存失败后父线程报告不再投递 |
| B05 | B | WebDAV PUT无ETag用本地hash冒充remoteRevision，下一次误报自己的快照冲突 |
| B06 | B | WebDAV多层Path仅MKCOL末级，父级不存在时首次list/upload失败 |
| C01 | C | Antigravity旧onboarding在logout/换号后复活或覆盖旧账号凭据 |
| C02 | C | Grok/Antigravity旧refresh的invalid_grant清空后来登录的新会话 |
| C03 | C | OAuth保存失败被忽略，UI报告成功但本机未持久化凭据 |
| C04 | C | Claude旧模型被统一发送adaptive thinking，合法reasoning选择产生无效协议 |
| C05 | C | provider create/apply工具endpoint验证互不一致，也与聊天实际policy不一致 |
| C06 | C | 当前固定API版本下，特定现代Claude型号仍携带不支持的temperature/top_p，合法MiniApp/聊天参数导致400 |
| D01 | D | 小说工具已写入后仍整轮重试，可能重复新建资料/修改 |
| D02 | D | 小说same-ID重附复用retry payload，丢askUser/suppression导致hash冲突无法恢复订阅 |
| D03 | D | 小说导入同revision不同内容时，安装前写失败被误认late success |
| D04 | D | legacy损坏current的previous只读恢复会自动迁移/发布，绕过显式恢复变可写 |
| D05 | D | 已完成run被prune后旧候选粒度丢失，收录默认目标误用后来生成粒度 |
| D06 | D | DeepRead WebMount/文件入口忽略页面所选版式 |
| D07 | D | DeepRead恢复auto/其他合法模板但Picker只有两个tag，显示与执行选择脱节 |
| D08 | D | DeepRead文件入口绕过busy，可在来源读取期间启动第二个任务 |
| D09 | D | Council prompt否认实际跨供应商路由，强制写入过时的单供应商事实 |
| E01 | E | MCP只读目录刷新无条件断连，取消并行正在恢复的工具调用 |
| E02 | E | MCP共享恢复Task等待不响应当前caller取消，停止后仍可长等初始化 |
| E03 | E | OpenAPI插件DNS等待不响应取消，也不计入插件timeout预算 |
| E04 | E | workspace_file_write缺失/非String content被默认为空，overwrite会清零已有文件 |

### 重要排除与修复约束

- 已明确撤回“Opus5/Haiku5.5 OFF一定非法”：官方脚注允许effort不高于high时disabled，当前OFF不发effort，默认high合法。原临时错误断言不作为门禁。C04/C06仅按[当前官方型号/版本约束](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting)与[采样约束](https://platform.claude.com/docs/en/build-with-claude/thinking#sampling-parameters)精准处理，保留旧型号合法参数及固定API版本。
- DeepRead保留部分结果并定向补齐、Council追问失败保留上次完成结论、ordinary后台流不能安全跨进程重放、outcomeUnknown禁止重放，均有明确设计与已有测试。
- 会话标题/置顶合并、import epoch、删除tombstone、子线程恢复run ID等已有实际防护，未按“异步即有bug”泛报。
- workspace_file_search只搜preview有明确工具契约；JS abandon/terminate行为有明确边界。
- 修复不删除既有死代码。若因本轮替换入口导致旧private helper无caller，单独标记，保留给用户决定。

## 阶段复审进展

- Phase A：聊天三项由 `full_chat_audit` 独立复审并重跑当前源harness通过；后台三项由 `full_background_audit` 独立复审通过。复审纠正了两处将active投影当durable task-map的测试误断言，未改变生产属性语义。
- Phase B：memory/fork/WebDAV四项由 `full_storage_audit` 独立复审通过；Inbox两项由 `full_chat_audit` 最终复审并重跑通过。复审发现并收口重生成variant、后台frozen snapshot、切会话提交任务归属及提交期间取消的边界，无新持久化协议。
- Phase C：auth/endpoint/thinking及C06新增采样hunk均由 `full_provider_audit` 独立复审通过。修复本轮legacy matcher对dotted4.6误识别的回归并补真实请求fixture；原Opus5 OFF误报已撤回。
- Phase D：DeepRead/Council由 `audit_settings` 独立复审通过；小说runtime/storage由 `full_novel_audit` 独立复审通过。额外用真实repository验证quiet-rest与重附交叉缺口，attach只在同run已结束时刷新canonical结果，无provider重启。
- Phase E：四项工具修复由 `full_tools_audit` 独立复审并重跑MCP/插件/Workspace当前源harness通过。
- Phase F：已运行xcodegen，11个新增Swift测试文件均已纳入本机生成项目。根agent按 `code-simplifier` 对任务diff做一次有限维护性审查；状态归属、取消与提交顺序清楚，未追加无关重构。保留已无caller的既有 `request(for:run,draft:)` 私有helper并标记在此，未违反删除需授权规则。生成项目为ignored，未改用户Git暂存区。
- 最终证据审查由未参与实现的 `audit_settings` 独立完成：核对31项唯一计数、真实XML、Native/Shared二进制hash、generic149项源hash、host测试日志及11个新测试清单；没有发现实质过度声称。确认App构建失败、测试target未编译与App XCTest未运行，待跨会话编译阻塞收口。

## 已执行验证与证据边界

- 当前 `:ai-core:jvmTest` 154项、最终 `:ai-provider-claude:jvmTest` 31项、`:core:conversation-storage:jvmTest` 66项均0失败/错误/跳过；validation独立核对并归档真实XML与最终源码hash，未重复无风险检查。
- `:shared:linkDebugFrameworkIosArm64` 已成功，1m25s；起止Kotlin生产源hash无漂移，生成的Shared.framework二进制/头文件hash已记录。当前Swift仍消费本仓Gradle生成framework，没有假设独立Core制品。
- PhoneControl macOS package126项通过，属本轮基线，并未改其原有WIP。
- 小说5个新回归测试在使用真实domain/repository生产源的macOS SwiftPM target实际通过；另真实repository17条断言通过，覆盖同revision早/晚失败、连续degraded读取、显式恢复、prune+后续不同粒度+reload。
- WebDAV真实provider/parser/conflict代码与仓库相同测试方法构成的host XCTest5项通过；不代表真实WebDAV服务。
- 聊天取消/上传/乱序提示、Inbox保存/ACK失败、后台expiration、Wake写失败、OAuth会话竞态、MCP共享恢复、插件DNS与Workspace内容校验均有原源码或完整生产owner的host红→绿证据，并由独立复审者重跑受影响场景。它们不冒充App XCTest。
- 任务源62个Swift文件frontend parse通过，11个新测试manifest登记核对通过，`git diff --check`通过。parse不等于完整类型检查或App运行。
- generic iOS `build-for-testing` 已实际执行到主App Swift模块编译，exit65。当前唯一编译错误位于另一搜索session新增的 `IOSSearchProviderCredentialEditor.swift:41:54`：动态 `String` 传给 `AmberSectionLabel` 的 `LocalizedStringKey` 参数。测试target尚未开始编译，因此App构建/测试编译不能标为通过；已向用户请求跨会话单行接线授权，等待或交对方修复。Shared、控制桥、CPython检查均已通过，起止源hash无漂移；日志、xcresult与JSON在 `/tmp/amber-full-review-20261025/validation/`。不签名、不安装、不运行App XCTest。

### 主要证据目录

- `/tmp/amber-full-review-20261025/phase-a/`、`upload-recall-cancel/`、`background-fix/`：取消、迟到结果、终态/恢复。
- `/tmp/amber-full-review-20261025/storage-fix/`、`inbox-fix/`、`webdav-fix/`：持久化、队列与同步。
- `/tmp/amber-auth-fix-20261025/`、`/tmp/amber-provider-endpoint-fix-20261025/`、`/tmp/amber-full-review-20261025/claude-*-green.log`：认证、endpoint与Claude请求协议。
- `/tmp/amber-full-review-20261025/novel-runtime/`、`/tmp/amber-novel-storage-fix/`、`/tmp/amber-full-review-20261025/deepread-create/`、`/tmp/amber-council-prompt-20261025/`：小说和独立功能。
- `/tmp/amber-full-review-20261025/mcp-recovery-fix/`、`plugin-dns-audit/`、`workspace-required-content/`：工具恢复、DNS与文件写入。
- `/tmp/amber-full-review-20261025/validation/`：模块XML、source hash、Native framework和最终App编译。

## 主要代码入口

| 范围 | owner入口 |
| --- | --- |
| 审批取消、上传与提示 | `ChatRunKernelAdapter.swift:154/1024`、`ChatKernelApprovalResolver.resumeApprovalExecution`、`ChatRunUploadPreparation`、`ChatConversationInbox.swift:239` |
| 后台终态与唤醒 | `Chat/Background/IOSChatBackgroundTerminalWriter.swift`、`Automation/IOSWakeScheduler.swift` |
| 会话与队列 | `JsonConversationStorage.mergeMessageWriteWithExistingMetadata`、`ConversationFork`、`IOSConversationStore.refreshCurrentMemoryMode`、`ChatConversationInbox.swift:68/330`、`IOSMailboxStore` |
| 同步 | `IOSSyncBackup.swift`中的 `IOSWebDAVSyncProvider` |
| 认证与请求协议 | `IOSAntigravityOAuthClient.swift:117/143/164`、`IOSGrokOAuthClient.swift:144/169`、`IOSCodexOAuthClient`、`IOSProviderConfigToolService`、`ClaudeKmpProvider.kt:413/462/853` |
| 小说 | `NovelCreation.swift:780`、`Session/NovelSessionRunLifecycle.swift:686`、`NovelDiscussionTransport`、`NovelProjectRepository.swift:446`、`NovelProjectRepositoryStorage`、`NovelSessionRecords.swift:120` |
| DeepRead/Council | `DeepReadCreateView.swift`自定义来源表单、`Council/CouncilRoomPlanning.hostSystemPrompt` |
| 工具 | `IOSMcpManager`、`ChatPluginExecution.executePluginRemote`、`Infrastructure/Workspace/IOSWorkspaceStore.workspaceFileWriteJSON` |
