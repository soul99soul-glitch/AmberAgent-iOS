# Phase5 T2 实施冻结

只修改两个生产职责点；新测试保持原断言不变。没有修改Chat/Host/Background/GenerationBindings或其它组文件，没有构建/运行测试。

- `IOSJevWebMountLoop.legalActionCandidates` 不再从只有role、没有确定option value的观察提出select候选。checkbox/radio不再错误进入wm_select；直接wm_select工具和既有PlannedAction.select类型保留。
- `ChatWebGoalTool.webMountLoopActionCall` 对select要求明确非nil value，并原样写入payload.value。空字符串仍可表达原生SELECT的空option value，首尾空白不清理；没有猜值或新增表单解析机制。

Root已在 `pending-domains-red-summary.json` 实测三个原始失败：无值候选仍出现、nil仍映射、明确值丢失。受影响selector：

```
iosAppTests/IOSJevWebMountSelectCandidateTests
```

建议同批回归现有 `IOSJevWebMountContractTests`、`IOSJevWebMountLoopTests` 和 `IOSWebMountAutomationContractTests`（直接wm_select控制项）。绿色结果由Root集成运行后补充，当前不宣称已通过。

按code-simplifier完成一次有限维护性自审：选择职责仍在既有planner和mapper；未引入新状态、抽象、兼容分支或重试。`git diff --check` 对两个生产文件与新测试无输出。源码冻结，等待独立phase review。
