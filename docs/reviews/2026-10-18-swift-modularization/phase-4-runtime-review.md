# Phase 4 — Novel 领域与运行链独立审查

状态：**源码职责与运行链行为审查通过。** 最终 Main 定点和独立 NovelTests 全量均有实际 xcresult 通过；Root 仍负责原方法 discovery 总核与 Phase 5 放行。本 reviewer 没有运行构建或模拟器。

审查以 `/tmp/amber-phase4-source-baseline/files` 为迁前基线；它包含用户 WIP，不能用 HEAD 替代。核对了 Session、Generation、Domain 的迁移清单和当前生产调用链，并追踪了本阶段暴露的真实竞态。UI、布局截图和测试发现数由其他 reviewer 与 Root 验证。

## 职责与行为

`NovelSessionViewModel` 仍独占 binding token、当前 run、consumer、终态展示和批次进度。Session 拆出的 extension 分别处理启动、流消费、终态呈现、代笔、批量润色及恢复；没有第二套 run writer 或仅按行数搬出的万能 context。72 个字段可见性变化逐个有跨文件调用，原 `private(set)` 中开放写入的字段也有实际跨文件赋值；不应再一概扩大其它 `private`。

`NovelCreationViewModel` 把命令送入 `DefaultNovelCreation` 的 actor。生成 runtime 以 run/attempt 归属事件，按 FIFO 处理模型帧，并在持久化前核对取消、绑定及 terminal claim；领域 reducer/validator 决定合法转移，`NovelFileProjectRepository` 是唯一持久化 writer，以现有 revision/CAS 和 commit 授权完成写入。候选正文在收录前不等于 manuscript；collect、replace、polish 与后续 `needsSync` 门禁仍分别走原命令。状态回执、证据和注入取同一 canonical state；中文输入法的组合文本先落为意图，再进入事务。没有在界面 extension 内复制领域状态。

Session/Generation/Domain 的原声明映射、字串、数值与提示文本分别有迁前后审计。Generation 的 50 个 accepted prompt kind/version 中 46 个 UTF-8 内容 SHA 完全相同，4 个原 `nil` 保持 `nil`；Domain 687 个声明映射和 71 项定向可见性变化均有跨文件使用依据。独立 Novel ARM64 production build r4 已成功，但它本身不证明运行时交错正确。

## 可达竞态及收口

迁前隔离消费者树重现 8/8 项旧 Novel 失败。BatchPolish 的四项是下一章与既有 workspace 自动同步 task 竞争；修复只在每章 durable refresh 后等待该 task，并在 await 前后检查取消及绑定。路径 fixture 与 needsSync fixture 的修订保持生产门禁，未通过放松断言掩盖失败。

旧 stream 在前台恢复的 lease await 窗口可结束并误把替代 stream 标为终态。确定性第二次 pull 屏障红测固定了该交错；生成 actor 增本地 `modelStreamID`，detach 撤销旧回调权限，事件、结束和断线回调只接受当前身份。我核查了涉及该字段的 runtime copy 写回：response frame 在首个 await 前写回，detach 与 resume 在 await 后重新取当前 runtime，sidecar 与 terminal catch 也不拿旧 snapshot 覆盖新身份。修复后的 Generation/Recovery/Ghostwrite/Batch 接线定点 127/127 通过。

代笔的另一项时序问题是候选已经 durable，而 Session 的上一章 consumer 尚在 terminal drain，下一章 `startBlockerMessage` 因旧 tail 拒绝启动。最终方案复用 `awaitGhostwriteCandidate` 已有的 300 ms 可取消轮询和超时，不等待可能尚未结束的整个 `consumerTask.value`：候选只在 `activeRunID == nil && !isStarting && !terminalAwaitingRefresh` 后返回。轮询捕获原 binding/token，在 await 后重查取消与归属；真正启动仍由原 `startBlockerMessage` 判定。

等待方在 live consumer 的 terminal drain/refresh 期间跳过自身 durable refresh，避免提前退役旧 tail 或洗掉 consumer 的 refresh 错误。其它时段仅在 `consumerTask == nil` 时允许轮询补退役；有 consumer 时终态交接归原 consumer。失败宽限维持既有 5 秒/900 秒时限，但不把长时间生成后刚进入正常终态 drain 的窗口误判为已落定；真实 refresh 错误仍可走 5 秒失败路径。页面离开时 `detachConsumer` 不取消整个代笔背景任务，候选继续走原返回和原 start gate/暂停契约，避免无 consumer 时空等 900 秒。该修复没有新增 writer、状态机、重试或计时器。

## 实际证据与待闭合门禁

- Main r2 的 588 个迁移方法全部各发现一次，587 passed、1 个原手动用例 skipped；Main r3 的 1024 个原 Novel 方法也全部各发现一次。两次 broad run 的既有失败均保留原记录，不记成通过。
- 独立 NovelTests r2 为 1047 total /1043 passed /1 代笔 failed /3 原 skipped；该次失败明确早于候选等待修复。r3 在最后的 consumer 退役布尔修正前为 1044 passed /0 failed /3 skipped，仅作中间证据。
- 最终 Main 定点 [`/tmp/amber-phase4-ghostwrite-handoff-final.xcresult`](/tmp/amber-phase4-ghostwrite-handoff-final.xcresult) 实际 64/64 passed，含新增长生成后候选先于 terminal drain 落盘、下一章仍能启动的回归；测试使用现有可注入 settle grace 压缩时间，不改变生产 timeout。最终独立 [`/tmp/amber-phase4-novel-tests-r4.xcresult`](/tmp/amber-phase4-novel-tests-r4.xcresult) 实际 1048 total /1045 passed /0 failed /3 原 skipped，覆盖最后源码与新增回归。以上数字由 `xcresulttool get test-results summary` 只读复核。

模拟器构建与脚本模型测试不能替代真实 provider、真机输入法、系统后台或 VoiceOver 验收。
