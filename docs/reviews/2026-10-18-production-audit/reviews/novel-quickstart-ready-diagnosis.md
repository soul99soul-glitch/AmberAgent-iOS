# Quick Start 第三轮完整测试失败诊断

范围仅为 `NovelCreationQuickStartTests/testQuickStartAndBranchOverrideUseRealModuleActions`。没有运行 build、test、XcodeGen 或模拟器，没有修改生产代码。使用 diagnosing-bugs 的证据优先方法；反馈来自 Root 已实际执行的完整测试，不另开测试进程。

## 证据与判断

Root 第三轮完整测试为 5144 项、5135 通过、1 失败、8 跳过；唯一失败是本例 resolveProposal 后对 activeMaterials.first 的 XCTUnwrap。相同生产代码在前两轮通过本例。原始证据由 Root 保存为 `main-integration-third-summary.json` / groups / status。

判定为测试等待条件不完整引入的夹具竞态，不是建议接受事务失败的产品修复项。原测试只等待 durable proposals 数量为 4；这证明建议已落盘并进入快照，不证明持有 Quick Start 操作 owner 的 UI 生命周期已结束。

当前可达时序：

1. startQuickStartSuggestions 通过 acquireOperation 占用 isPerforming，并启动 runQuickStart。
2. 快速脚本完成生成后，runQuickStart 在初次 refreshCurrentSelection 中可以读到带四条建议的 completed project。
3. reloadSelection 发布 projectSnapshot/branchSnapshot；其异步调用返回到 runQuickStart、执行 releaseOperation 之前，测试只凭 count==4 即可恢复执行。
4. resolveProposal 自身通过 perform 执行真实领域 action；perform 在没有 reserved owner 时调用 acquireOperation，若 Quick Start 仍持 owner，则报告 projectBusy 并返回 false。原测试忽略该 Bool，随后 activeMaterials.first 仍为空。
5. Quick Start completed 消费路径再次刷新 selection，随后清除 quickStartStatuses 并完成本 run 的 UI 收口。等到 quickStartStatus==idle 才是本测试应等待的状态。

生产约束可定位在：

- `NovelQuickStartViewModel.swift`：请求取得 owner；171–188 行初次刷新在 releaseOperation 之前；278–297 行 completed 刷新后才清状态并 finish。
- `NovelMutationViewModel.swift:76–81`：perform 不能抢占尚未释放的 operation owner；204–219 行可见快照发布。
- `NovelCreationViewModel.swift:371–389`：acquireOperation 检查 isPerforming，canMutate 同时受该状态约束。
- `NovelMaterialsView.swift:874–879`：真实“写入”按钮 disabled 条件包含 viewModel.isPerforming；资料编辑入口也使用 canMutate。因此实际 UI 不会在上述初次 owner 尚未释放的窗口提交接受操作。若直接调用 API 过早，返回忙碌是既有保护行为。

原失败没有单独记录 isPerforming/resolveProposal 返回值；本次未把源码分析冒充 debugger 取证。现有生产时序、UI 门禁和相同代码两次通过一次失败共同支持夹具 readiness 竞态，不支持修改生产 guard。该文件第三个测试本来就用 `count==4 && quickStartStatus==idle` 等待同一生命周期。

## 最小测试修正

仅将第一项的 count 轮询替换为现有 eventually helper，条件为 `settingProposals.count == 4 && quickStartStatus == .idle`，并明确断言等待成功。模型请求、接受前 materials 为空、真实 resolveProposal、branch override、落盘 revision/seed 与最终无错误等全部原行为断言保留。没有改动同文件其他测试，没有放宽断言或修改生产逻辑。

文件 SHA-256：

- 修改前：`c7c6837284a1bea359d368b913b7fd3f0d6e5c3cbb9dd17ed59654d8545b87a1`
- 修改后：`bacd94327107e782f956ecd978ecae328d588beb3285111f3c8d29b0ca8d48a9`

目标 whitespace 检查无输出。修正后实际执行由 Root 统一进行，当前不声称已 GREEN。
