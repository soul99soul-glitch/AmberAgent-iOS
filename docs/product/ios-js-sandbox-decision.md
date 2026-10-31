# iOS JavaScript 沙箱（exec / wait）默认关闭决策

- 工具：`exec`（JavaScriptCore 隔离求值）与 `wait`（cell 续取结果）同开关。
- 默认：**关闭**。`@AppStorage(IOSExecutionPreferenceKeys.execJavaScriptEnabled) = false`（`ExecutionSettingsView`）。
- 开启条件：用户显式在「设置 › 执行 › 脚本执行 › JavaScript 沙箱执行」打开；每轮请求由 `IOSExecutionPolicySnapshot.execJavaScriptEnabled` 固化，后台/子运行不继承未授权的放宽。
- 关闭时：`ChatGenerationRequestBuilder` 不声明 `exec`/`wait`；`pendingKindForForegroundTool` 不把名字归入 advanced；执行器表不注册。模型调用按未知名失败，不落静默兜底。
- 能力边界：无网络、无文件系统、无宿主私有 API；只有显式传入的嵌套工具桥。权限/能力声明在工具描述与设置副标题中一致。
- 测试：`IOSForegroundToolExecutorsTests.testExecAndWaitAreNotRegisteredWhenSandboxIsOff`（关闭时无执行器）；既有开启路径测试 `testExecNestedOutcomeUnknownReturnsTypedOuterOutcome`。
