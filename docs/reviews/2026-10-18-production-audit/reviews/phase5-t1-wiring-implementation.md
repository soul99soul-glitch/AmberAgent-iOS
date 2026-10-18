# Phase5 T1 第2步接线实施（冻结）

状态：T1服务/API与前后台接线已完成并冻结，等待Root统一编译、绿色测试与独立review。没有自行构建或运行测试，没有改C1/C2 checkpoint/adoption/phone claim逻辑；共享文件均在当前版本以精确回调patch合入，保留其它owner WIP。

## 生产接线

- 前台 `ChatGenerationBindings.onRunTerminal` 增加明确的冻结显示基线。`ChatKernelRunHost.finishCancelledRun` 与 `teardownRun` 在 `clearRunIdentity()` 前捕获既有 `displayBaseline`，与full terminalMessages一同发回调；完整消息仍供原消费者使用。
- `ChatRunComposition` 将显式baseline交编排服务，同时从同一runId的durable snapshot读取terminalReason；继续使用Host传来的durable terminalStatus，不猜UI当前会话。
- 后台 `IOSChatBackgroundGenerationCoordinator.onRunTerminal` 增加baseline参数；`IOSChatBackgroundTerminalWriter.notifyRunTerminal` 从当前job取 `displayMessages`，沿原callback传递。后台完整transcript与已有archive owner不变。
- `ChatViewModel` 后台consumer显式把baseline和原本已读取的durable status/reason传编排服务。
- 第1步既有服务/control用 `IOSSubAgentOutputProjection.generatedMessages` 筛本轮，仅本轮assistant用于报告/长文引用；状态JSON与runId幂等保持。

两个真实生产service caller（foreground composition/background VM）现在均显式传baseline。可选nil接口仅保留已scoped transcript的旧直接调用兼容，不用于生产完整history路径。

## 准确本轮路径

生产（第1+2步）：

```
iosApp/iosApp/IOSThreadOrchestrationToolService.swift
iosApp/iosApp/AgentRuntime/Orchestration/IOSOrchestrationControlCommands.swift
iosApp/iosApp/ChatGenerationSupport.swift
iosApp/iosApp/ChatKernelRunHost.swift
iosApp/iosApp/IOSChatBackgroundGenerationCoordinator.swift
iosApp/iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift
iosApp/iosApp/ChatViewModel.swift
iosApp/iosApp/Chat/Session/ChatRunComposition.swift
```

测试：

```
iosApp/iosAppTests/IOSOrchestrationTerminalOwnershipTests.swift
iosApp/iosAppTests/IOSChatForegroundTerminalBoundaryTests.swift
iosApp/iosAppTests/IOSChatBackgroundTerminalBoundaryTests.swift
iosApp/iosAppTests/IOSChatKernelRunHostTests.swift
```

最后一项旧测试只改两处callback arity，原assertions不变。其余三个为本轮新职责测试；Root需确保新增foreground/background两个文件被工程收录。

## 测试入口与证据

Root已有 `pending-domains-red-summary.json`：原T1前三项真实失败，长报告控制已通过。第1步四项断言保留，仅显式给本轮baseline。

第2步新增：

- `iosAppTests/IOSChatForegroundTerminalBoundaryTests`：真实Host完成/取消回调携原冻结baseline，full transcript保留旧历史；projection只含新输出或为空。证明capture在identity clear前完成。
- `iosAppTests/IOSChatBackgroundTerminalBoundaryTests`：真实coordinator.start→cancel/complete→terminal writer→新增callback→真实service→父mailbox；验证upload-only system不进入baseline、旧报告不重投、durable终态正确。
- `IOSOrchestrationTerminalOwnershipTests` 追加两条实际consumer测试：真实 `makeGenerationBindings` closure 与 VM注册的background callback，把显式baseline及durable status/reason转入父mailbox；UI当前会话已切到父，结果仍归child run。

建议Root首先运行以上三个类与 `IOSOrchestrationListInterruptTerminalTests`，并带现有 `IOSChatKernelRunHostTests` / `IOSChatKernelRunHostHandoffTests` / `IOSChatBackgroundExecutionTests` 验证callback与生命周期兼容。

## 有限自审与边界

按code-simplifier对本轮T1改动完成一次有限检查：基线沿既有owner回调传递，无第二状态、缓存、文本启发式、retry/fallback或URL状态。为守文件长度，Host只将同一终态的messages/baseline捕获并列在一行，没有删有用说明或压缩无关代码。当前Host1497行、Coordinator1491行；`python3 scripts/check_swift_file_lengths.py` 实际通过（1332 Swift文件，0超过1500）。本轮路径 `git diff --check` 无输出。

本组没有运行构建或测试，不宣称green。真实provider与设备验收不在本组完成范围。T2与WM1–3此前Root已green，详见各自报告；本次不据此替代T1验证。
