# 后台工具工厂 actor 隔离闪退（2026-11-06）

用户在 iPhone 18 Pro 上按流式卡顿采样步骤执行真实调研时发生闪退。系统报告两次终止：2026-11-06 23:42:03.905（PID25599）和 23:42:55.182（PID25610）。手机运行 a0cb5c01 / databaseSequenceNumber2800，本轮 ProMotion/offset 性能改动尚未安装。

## 证据

两份 systemCrashLogs 报告的异常完全一致：EXC_BREAKPOINT/SIGTRAP，SIGNAL 5；出错线程是 user-initiated cooperative。不是 Jetsam。共同栈：

```text
_dispatch_assert_queue_fail
_swift_task_checkIsolatedSwift
closure #3 in ChatToolRuntime.backgroundToolExecutorsWithCurrentPolicy
_ArrayProtocol.filter
ChatToolRuntime.backgroundToolExecutorsWithCurrentPolicy
ChatToolRuntime.backgroundToolExecutors
makeExecutors in IOSChatBackgroundGenerationCoordinator.handle
IOSAgentToolEngine.runInternal
```

原始报告与崩溃前黑匣子在本机忽略目录 build/StreamingPerfEvidence/promotion-120/crash-234205.ips、crash-234256.ips、phone-crash-prev.jsonl。没有把原始设备日志、对话、标识或凭据写入仓库/云端。

## 根因与修复

后台协调器是 MainActor owner，其 makeExecutors 调用 MainActor ChatToolRuntime。引擎把工厂保存为普通同步闭包，工具发现扩展后在非隔离 runInternal 中直接调用，丢失执行器边界。运行时直到 messages.filter 的 actor 隔离闭包才检查主线程并触发断言。前台 Kernel 的同类工厂存在相同边界。

工厂类型现在显式带 @MainActor，重建时通过 MainActor.run 切换执行器。仅将新建 registry 的所有权交回当前单一 run，用私有 Sendable 传输盒承载协议存在值；没有扩大 IOSToolExecutor 的 Sendable 保证、移除隔离检查或把整个引擎搬到主线程。原有前后台执行器、权限、冻结策略快照与工具扩展保持原语义。

## 验证

IOSAgentToolEngineTests/testExposedToolGetsExecutorOnNextRoundViaRebuilder 使用实际多轮引擎与 mock tool_search → wm_type → 终答。在工厂回调断言 Thread.isMainThread，原实现实际失败，能够复现本次错误边界；修复后 IOSAgentToolEngineTests + IOSForegroundToolExecutorsTests 共 28 项全部通过（actor-green-3.xcresult）；定点先红后绿。并验证同一工具扩展后可执行、输出完整以及前台审批/执行行为，不访问真实服务或 Key。

本项修复不代表已达到完整流式主线程 <20%、最长帧 <50ms 的性能目标。安装与源码版本以本机交付清单和云端 daily/2026-11-06-ios-streaming-perf.md 最新记录为准。
