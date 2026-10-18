# Phase 3 Runtime 与调用链独立审阅

结论：以 Phase 3 开工前的源码快照、四份迁移映射及 r10 与 focused 两轮实际 XCTest 结果核对，ChatViewModel → ChatKernelRunHost → ChatRunKernelAdapter → IOSAgentToolEngine → ChatToolRuntime → IOSThreadOrchestrationToolService 的状态归属与关键时序保持一致；未发现可定位到本次拆分的 Runtime/调用链行为回归。本结论可作为这一审阅范围的签字，不代表整个 Phase 3 的全量测试、视觉或设备门禁已通过。本审阅未修改产品代码、配置或测试，也未自行运行 Xcode 或模拟器。

## 范围与源码核对

对照基线 `/tmp/amber-phase3-source-baseline/files`，它包含 Phase 2 必要的 `phoneSessionIsActive` 注入及用户既有 WIP，未以 HEAD 代替迁前源。迁移范围和职责记录在 [Session 映射](phase-3-session-moves.json)、[Kernel 映射](phase-3-kernel-moves.json)、[Runtime 映射](phase-3-runtime-moves.json) 与 [Engine/Orchestration 映射](phase-3-engine-orchestration-moves.json)。

- `ChatViewModel` 仍是 App 持有的可观察入口；`ChatConversationRunRegistry` 唯一保存会话到 run 的映射，每个 `ChatConversationRunState` 保存对应会话的呈现与输入状态。Composer 附件任务和建议请求各有具体 owner；会话保存通过同一 snapshot/CAS/variant 事务。剩余的 VM extensions 按会话收件箱、生成和 composer 调用分组，没有另造消息、loading 或审批的第二份权威状态，也没有以一个通用 context 容纳原 VM 全部字段。
- `ChatKernelRunHost` 独占当前 `runId`、取消原因、终态认领和身份清理；`ChatRunTerminalCommit` 只处理已认领 run 的持久化及系统结果发布。消息与 durable run 记录在 Watch/LiveActivity 终态之前完成。异步上传、图片、durable response 回调继续核对原 `runId` 和会话归属，旧 run 的迟到回调不能写入新 run。
- `ChatRunKernelAdapter` 独占审批交接、快照序号与回填终态；首轮及后续轮边界均先折入 mailbox，再消费 steer。`ChatRunApprovalSession` 只持一个 prompt/continuation，claim 后即清空；暂停先记 durable waiting 与删敏消息快照，再公布审批卡。`ChatKernelApprovalResolver` 保持 Started → 恢复认领 → finisher → Finished 的账本顺序；副作用结果未知走 expected-started 的恢复 CAS，不重放工具。嵌套审批队列按 FIFO 逐一展示。
- `IOSAgentToolEngine` 保留唯一 working transcript 与工具执行器表；每轮 provider 调用前保存请求快照，轮边界重建工具暴露及 mailbox/steer 折入顺序未变。新 batch executor 从当前表执行，不持第二份 registry。`ChatToolRuntime` 仍是工具策略和分发入口，Plugin/Recipe owner 各自按 `toolCallId` 存储、一次性取走准备候选；Recipe checkpoint 先于审批暂停落盘，完成/拒绝时清理。前台、后台和 Novel 的工具注册及审批能力边界仍分别处理；后台不获得前台 `ask_user`/Council 审批路径。
- 编排服务仍以目标会话的同一个 FIFO gate 串行化 `followup_task`、用户追加和终态 `resumePendingTasks` 的活跃检查、入队与 bootstrap；容量占用由服务唯一计算，失败启动保留信封以供恢复。已有 `testConcurrentUserAppendAfterTerminalResumeStartsOnlyOneRun` 实际并发恢复与用户追加，后者直接复用 `followupTask`，验证只启动一个 run；取消 `wait_agent` 另有定点测试。`list_agents` 的容量仍在异步查询后取样，未因拆分提前读旧值。

对 Runtime 原文件与拆出的 12 个文件做去注释词法复核：字符串字面量 1122 对 1122、数字字面量 97 对 97，未发现缺失或新增；原成员链的三处表面差异是新增 `runtime.` 接收者。迁移中一度漏掉的两处 Plugin `manifest.runtime` 成员引用已恢复为基线表达式；抽查大方法和关键分支未发现编译可通过的字串、数值或成员链语义漂移。Session/Kernel 的抽出对象持有明确业务状态；跨文件可见性调整按真实调用边界核对，未见需要为行数批量放宽 `private` 的理由。

## 实际验证与边界

Root 的 `/tmp/amber-phase3-integration-r10.xcresult` 在 iPhone 17 Pro、iOS 26.5 arm64 模拟器完成主工程构建和 1475 项 XCTest：1466 通过、7 失败、2 跳过。依据 [209 项渲染/会话映射](phase-3-render-session-test-identifiers.json)、[118 项 Engine/Kernel 映射](phase-3-engine-test-identifiers.json) 与 r10 结果树，327 个原测试方法各实际执行一次：325 通过、1 项长表格流式帧间隔 canary 超过原 40 ms 阈值（42.57 ms）、1 项手动性能采样跳过。随后的 `/tmp/amber-phase3-focused.xcresult` 以原阈值复跑该 canary，连同两项源码 owner guard 均通过（3/3）。合并两轮后，327 项迁移方法为 326 项通过、1 项原有手动采样跳过，无缺失或重复。118 项 Engine/Host/Orchestration 在 r10 全通过；Runtime、Recipe、JS、Session Read/Status 及多会话相关行为测试未报告失败。[辅助声明审计](phase-3-engine-helper-audit.json)和[渲染/会话辅助声明审计](phase-3-render-session-support-hashes.json)补充核对了拆分后非测试 helper/fixture 的归属。

r10 的另外六项失败中，两项是固定旧源码 owner 路径的断言，Root 已按实际 owner 修正且 focused 复跑通过；四项 Novel setting proposal fixture 与本次 Runtime 拆分无源码差异，已由原过滤契约核对。因此 r10 整轮仍是失败结果，不能用 focused 的 3 项通过把它改写为全量通过。Novel 独立 arm64 构建由 Root 报告通过（`/tmp/amber-phase3-novel-build.log`）。主产品导航在原实现和键盘/附件 overlay 修复后均为 1/1 通过，后者见 `/tmp/amber-phase3-navigation-overlay.xcresult`；三张 UI 图仍由 UI reviewer 复核，六个 scroll suite 的 `/tmp/amber-phase3-scroll-overlay.xcresult` 尚未完成。模拟器 XCTest 与构建也不构成真实 provider、系统后台或物理设备验收。
