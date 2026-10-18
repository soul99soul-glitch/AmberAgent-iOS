# Phase5 T1 独立服务/API实施（第1步冻结）

已完成，未触碰共享Chat/Host/Background/GenerationBindings/VM/composition文件，未构建或运行测试。

授权范围内改动：

- `IOSThreadOrchestrationToolService.notifyRunTerminal` 新增 `displayBaseline` 可选入参，连同已有terminalStatus/reason转交既有control owner。nil仅供已提供本轮scoped transcript的直接调用；生产owner最终必须显式传其冻结baseline。
- `IOSOrchestrationControlCommands.notifyRunTerminal` 用已有 `IOSSubAgentOutputProjection.generatedMessages(finalMessages:displayMessages:)` 从full transcript选择本轮输出。长报告引用取本轮assistant message，不再从full history取。没有最后user、文本前缀、当前UI会话或其它启发式。
- 显式terminalStatus被写入独立可读JSON行（`run_ended`, `terminal_status`，有原因时`terminal_reason`）；长报告沿用原excerpt/session_read metadata并合入终态字段。没有本轮正文时保留短的no-output说明并给出真实终态。原mailbox/runId幂等与完整会话存储不变。
- `IOSOrchestrationTerminalOwnershipTests` 原四测试仅加入明确fixture baseline（有partial/长正文时baseline不含当前新assistant），原断言保留。未执行测试，Root此前已取得原三红+长报告控制绿。

一次有限code-simplifier检查完成：投递owner保持单一，数据流直接，没有新增状态、run缓存、迁移或fallback。对以上两个生产文件/新测试执行 `git diff --check` 无输出。

## 待第2步释放

前台 `displayBaseline`、后台 `job.displayMessages` 需要沿现有terminal callback显式交给服务；当前共享接线仍未修改，因此本报告只声明独立API可用，不声明T1生产端到端完成。Root确认Chat owner冻结后再写：ChatGenerationSupport bindings、ChatKernelRunHost两个terminal callbacks、BackgroundCoordinator/TerminalWriter callback、ChatViewModel与ChatRunComposition consumer closures，并补前后台边界测试。

Root下一次可先执行 `iosAppTests/IOSOrchestrationTerminalOwnershipTests`，再跑 `IOSOrchestrationListInterruptTerminalTests` 保留既有直接调用/幂等/长报告行为。
