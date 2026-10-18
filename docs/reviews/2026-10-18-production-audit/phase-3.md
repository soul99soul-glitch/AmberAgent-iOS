# 第 3 阶段：聊天后台与 Markdown

C1–C7 已完成修复及独立源码复核，最终源码结论为 **PASS，无剩余可操作发现**。最后两组套件在校正后实际重跑 17 项全部通过；最终原生集成 `build-for-testing` 退出码为 0。此前的聚焦批次仍保留 302 通过、2 失败的原始结果，后续 GREEN 单独记录。这里的源码和测试结论不表示真实 provider 或物理设备验收已通过。

[实现报告](reviews/phase-3-chat.md) 保留修改路径、调用链与测试入口；[独立复核](reviews/phase-3-independent-review.md) 保留二次审查发现的 R1–R3、反证及最终收口；[Markdown 专项复核](reviews/phase-3-markdown-independent-review.md) 记录 C6/C7 的源文本与 full/incremental 契约。这些报告按最后测试前的冻结版本保留；最终执行状态见本页。独立审查者未参与本阶段实现，也未构建或运行测试；下述执行结果均来自 Root 保存的结果文件。

## 最终修复

| 问题 | 触发与最终行为 |
| --- | --- |
| C1：恢复出工具后，同 run 判重吞掉续跑 | durable response 完成且仍有未解决工具时，通过专用入口校验同一 run、response、持久 task map 及本地执行 owner。先成功持久化 `continueModel`，再替换 runtime 缓存并启动工具循环一次；失败保留原可恢复 owner。普通 `start` 的重复启动保护保留。前台接手已缓存但尚无执行 owner 的 continuation 时，显式完成 adoption。 |
| C2：新一轮交接恢复上一轮 response | 模型轮完成后，Engine 将 canonical messages 通过 awaited callback 交给 Host，先持久化轮次边界再执行工具；下一轮 upload 刷新包含已完成工具结果。Session 区分实际持久模式和当前 response，并以请求 token 拒绝旧回调回抢。持久化失败进入既有恢复路径，不允许使用旧 checkpoint detach。 |
| C3：失败或重连丢失已收到的 partial | durable failure 保留已发布的本轮正文、Reasoning、Tool、消息 ID，并按现有失败规则处理未完成工具。重连从事件零重放时，现有 snapshot 锁内保存最大服务端 sequence；accumulator 先接收 chunk，再在对应 checkpoint 达到水位时发布完整快照。较短重放和零 chunk 重试均不清空先前 partial；追平后正常更新，完成时使用本次 accumulator 的完整结果。 |
| C4：MiniApp 解析失败发布成功终态 | detached 完成路径把应用失败记录并发布为 failed，与普通后台路径一致。 |
| C5：MiniApp 保存后未同步 Workspace | 先保存会话，再提交应用并同步 Workspace。会话保存失败则回滚且不触发同步；Workspace 同步失败时按原消息 ID 保存替换提示。应用已成功的 run 保持 completed，这是现有前台和普通后台路径的设计。 |
| C6：表格补列/截列破坏转义管道 | 重组 Markdown 原文时保留管道转义，显示单元格仍保留解码后的管道字符；等宽行保留原文。回归经过实际 Markdown renderer，同时核对源文本和渲染单元格。 |
| C7：错误关闭代码 fence，暴露内部表格 | full parser 与 incremental detector 共用小型 fence 状态，记录 marker 和 opener 长度。只有同 marker、长度足够、尾部仅空白的行能够关闭；较短 fence、不同 marker 和带 info 的行仍是代码内容。 |

独立复核补出的三个边界已经取得实际 RED 后修复：

- **R1，属于 C2：** 同 response 的 sequence 更新原本会逐事件持久化并重建 hydrated runtime/tool bridge。现在只更新 Session 内存 cursor；首次或新 response、模式变化及 canonical snapshot 边界才持久化和刷新缓存。磁盘 cursor 不会独自越过尚未持久化的 partial，与从事件零重放的策略一致。回归核对 persist 次数、bridge 身份和磁盘 sequence，而非只检查最终请求是否发出。
- **R2，属于 C3：** 只移除 reconnect reset 仍不足以防止较短重放覆盖更完整 partial。最终使用真实 chunk → checkpoint 顺序及服务端 sequence 水位；不比较字符串长度、不拼接不同重放的 delta，也未引入新恢复框架。回归包含较短重放、随后再次零 chunk resume、追平后更新及单一 `ABCDEFG` 完成结果，并保留 parts 和消息身份断言。
- **R3，贯穿 C1 与终态输出：** response transfer 后，当前 display 已包含本 run 先前生成的内容。若把它当成整个 run 的合并基线，后续模型失败时会丢掉此前正文和已完成工具。现在以一个不可变 `runDisplayBaseline` 贯穿保存、归档、T1 回调、live subagent 输出、Intelligent UI 完成与 memory extraction。回归实际经过 transfer → 工具 → 下一次 provider 失败 → terminal save，并从全新 store 读盘，检查最初 assistant ID、正文、完成工具结果和一个本地错误；同时核对 live public output 保留首段。

## 当前轮与整个 run 的基线

| 数据 | 职责与更新边界 |
| --- | --- |
| `displayMessages` | 当前模型轮的 canonical 显示快照，随 response/轮次推进；负责当前轮累积和 suffix 边界。 |
| `uploadMessages` | 实际准备提交给 provider 的消息，可包含 system 注入、压缩或 transcript 转换；下一轮须包含工具结果。 |
| `runDisplayBaseline` | Host 从既有原始 `displayBaseline` 捕获的一份不可变 run 起点。handoff、Swift/KMP payload、retry/recovery 与 runtime hydration 保留它；整个 run 的成功、失败、取消合并及本轮输出选择使用它。 |
| ledger recovery 刚读取的 `messages` | 一次独立的读改写事务基线。恢复计划修改的是刚读到的会话，因此保存时必须与该快照比较；它不使用整个 run 的终态合并边界。 |

这几个值不能互换。工具专用的局部合并继续遵循既有 display 契约；当前轮 suffix 与 upload reconciliation 也未改成原始 run 基线。transfer 仍先完成一次 payload 持久化再交接执行权，未增加一次 conversation-first 写入。

新 payload 字段允许非空和显式空数组；旧 payload 缺少或为 null 时回落到旧 display checkpoint。兼容路径不按消息 ID、时间或数量猜测一个从未保存过的原始起点。KMP bridge 的独立基线、显式空值、实际移除旧格式字段后三种回归均包含在已执行的共享层测试中。

## 实际红绿证据

| 证据 | 实际结果与范围 |
| --- | --- |
| [C3–C7 初始 RED](phase3-prep-red-summary.json) | 11 项执行，3 通过、8 失败、零跳过。失败覆盖 partial、MiniApp 状态/Workspace，以及 escaped pipe 和 fence；控制项通过。 |
| [C1/C2 初始 RED](pending-domains-red-summary.json) | 此跨阶段批次整体 18 项、1 通过、17 失败；其中 C1/C2 原始四项回归全部按候选失败。不能把该批次全部失败归为 Chat。 |
| [adoption RED 与已有修复验证](boundary-red-and-independent-greens-r2-summary.json) | 31 项，28 通过、3 失败。原 C1/C2 四项及 checkpoint-failure 回归通过，七项 detached terminal 回归通过；新 cached foreground adoption 回归真实失败，其余两项失败属 Search 测试设施。 |
| [R1/R2/R3 及 T1 边界 RED](phase3-final-boundaries-red-summary.json) | 121 项，113 通过、8 失败。Chat 的 R1 一项、R2 三项、R3 一项及跨阶段 T1 partial-handoff 一项均在最终修复前失败；另两项属 Search。该轮也保留了原 C1/C2 六项、C3 七项等已通过控制。 |
| [Markdown 与 timeline 分组结果](phase4-rendering-green-groups.json) | Markdown 的 CodeBlock、Rendering、SourceIntegrity 三组共 46 项通过；要求的 SwiftUI replay、native history/completion/performance、scroll core、viewport 六组共 96 项通过。该文件还包含其他阶段结果，不能把整批称为全绿。 |
| [共享层基线 GREEN](shared-baseline-green-summary.json) | `:shared` 该批 56 项全部通过、零失败/错误/跳过，其中 `IosChatBackgroundPayloadJsonBridgeTest` 11 项。它验证序列化契约，不替代 Swift 消费入口验证。 |
| [Chat/Tools 聚焦执行](phase3-phase5-focused-green-summary.json) | 304 项，302 通过、2 失败、零跳过、无 runtime warning。R1/R2/R3 与 T1 partial-handoff 回归在此轮通过；下述两项失败经定位后作了最后校正。该摘要整体仍为 Failed。 |
| [最后两组 GREEN](phase3-final-failures-green-summary.json) / [分组结果](phase3-final-failures-green-groups.json) | 校正后实际重跑 17 项全部通过、零失败/跳过、无 runtime warning；DurableOwnership 8 项，BackgroundStaleSweep 9 项。 |
| [最终原生集成构建状态](final-integration-build.status.json) | `build-for-testing` 实际退出码 0。构建摘要没有执行测试、其 result 为 `unknown`；构建成功依据进程退出码，测试通过依据独立 GREEN 结果。 |

## 最后两项校正与重跑结果

`IOSChatDurableOwnershipTests/testForegroundHandoffStartsCachedContinuationBeforeNextCheckpoint()` 的失败来自测试比较对象：断言预期取自已经被 live callback 推进的 `harness.messages`，而被测值是原始 run 基线。测试现在在 `host.start` 前捕获 `originalDisplayBaseline`，用它核对原始 ID 和数量；磁盘、缓存、当前 display、工具结果及 adoption 的有效断言全部保留。此项只修正 fixture，没有改变生产基线行为。

`IOSChatBackgroundStaleSweepTests/testColdStartResumeResponseStopsBeforeUnknownLedgerReplay()` 的失败经既有 xcresult 定位到恢复 Tool output 为空的最后断言。此前 unknown descriptor、run/ledger 的 outcomeUnknown 和 task-map 清理断言均已通过；该 fixture 的 upload/display 相同，问题不在 C3 的 display 初始化。ledger recovery 刚读到空会话并生成一个 unknown Tool，却使用 payload 的一条消息 run 基线保存，导致唯一恢复消息被错误裁掉。最小生产修正是在 `reconcileDetachedResponseLedgerBeforeResume` 保存时恢复 `baseMessages: messages`，并注释说明这是刚读快照的读改写事务。未知副作用必须阻断 resumer 的门禁、终态迁移和严格输出断言均保留。

两处最终改动均已通过独立只读源码复核，随后 Root 实际重跑下列两组，**17/17 全部通过**：

- `iosAppTests/IOSChatDurableOwnershipTests`：8 项通过。
- `iosAppTests/IOSChatBackgroundStaleSweepTests`：9 项通过。

最终原生集成构建也已实际成功。上述模拟器及注入式 provider 测试不替代真实 Responses provider、进程终止/系统任务到期恢复、物理设备滚动或视觉验收；本阶段未据此声明这些用户行为已验收。
