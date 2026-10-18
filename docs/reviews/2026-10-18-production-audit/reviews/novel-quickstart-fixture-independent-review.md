# Novel Quick Start 测试等待修正独立复核

结论：PASS，无阻断问题。当前证据支持测试提前调用真实 mutation 的 readiness 竞态；不支持将这次失败列为真实 UI 可达的产品缺陷。生产操作锁及 UI 门禁无需修改。

## 范围与证据边界

只读核对 `NovelCreationQuickStartTests.swift` 的冻结完整差异、Quick Start 生命周期、mutation 入口与真实接受 UI。未构建、运行测试、操作模拟器或修改源码/测试。实际第三轮结果来自 `delivery-final-main-summary.json`：5144 项，5135 通过、1 失败、8 跳过，唯一失败为本测试接受建议后的 `NovelMaterialRecord` 非空断言（旧文件第 55 行，当前第 57 行）。本独立复核不声称修正后已 GREEN。

## 独立调用链核对

1. `NovelQuickStartViewModel.swift:92` 先取得 operation owner；`122` 发布 starting；`129–132` 只创建后台 MainActor Task 后返回。`createProject` 在 `NovelCreationViewModel.swift:1113–1117` 启动它后即返回项目 ID，因此测试必须等待后续生命周期。
2. `NovelQuickStartViewModel.swift:174–188` 先设 generating，等待初次 `refreshCurrentSelection`，然后才 `releaseOperation`。该 refresh 经 `NovelProjectActionViewModel.swift:23` 调到 `NovelMutationViewModel.swift:190–218`；后者在 `212–215` 发布 project/branch snapshot。快速脚本可以让此时读取的 durable project 已含四条建议，但快照发布本身没有保证外围 owner 已释放；原 count-only 等待缺少此保证。
3. `resolveProposal`（`NovelProjectActionViewModel.swift:428–453`）仍走真实 `perform(.resolveSettingProposal)`。`NovelMutationViewModel.swift:76–80` 在无法取得 owner 时报告 projectBusy 并返回 false；测试旧版未检查此 Bool，后续 activeMaterials 为空符合这条时序。
4. 真实候选卡 `NovelCompendiumView.swift:813` 使用 `.disabled(!viewModel.canMutate)`；`canMutate`（`NovelCreationViewModel.swift:386–390`）检查 isPerforming、starting placeholder、reload 与 running run。即使接受 sheet 已打开，真实写入按钮 `NovelMaterialsView.swift:874–877` 也在 isPerforming 时禁用。直接从测试调用方法绕过 UI 门禁，不能据此要求生产 mutation 抢占 owner。
5. 成功 completed 路径在 `NovelQuickStartViewModel.swift:279–298` 再次刷新后才清除显式状态并同步 finish；此前 `187` 已释放初次 owner。`quickStartStatus`（`NovelCreationViewModel.swift:580–632`）优先返回显式 generating，继而检查 running run；对本例既有四条建议的固定流程，等待 idle 能跨过上述窗口。

原失败未记录当时 isPerforming 或 resolveProposal 返回值，因此不能把源码推导写成该单次失败的 debugger 实录。现有实际失败位置与可达时序一致，真实 UI 有门禁；判断应限定为夹具等待条件不足，不扩展为产品 bug 或额外状态机。

## 冻结差异与断言

逐字比较 `quickstart-ready-before.swift` 与当前文件，仅第一测试一个 hunk：将 count-only 轮询替换为既有 eventually helper，等待 `count == 4 && quickStartStatus == .idle`，新增等待成功断言。复用 helper 默认 2 秒上限；没有固定追加 sleep、伪造状态、放宽 count 或跳过失败。

模型请求 purpose、接受前 materials 为空、world proposal 来源、真实 resolveProposal、真实 branch override、持久化 creationMode/genre、全局 revision 不变、恰一条独立 override revision、最终 error 为 nil 均原样保留；同文件其它测试无差异。此修改增强 readiness 条件，没有删除业务行为断言或替换生产路径。

冻结 SHA-256：before `c7c6837284a1bea359d368b913b7fd3f0d6e5c3cbb9dd17ed59654d8545b87a1`；current `bacd94327107e782f956ecd978ecae328d588beb3285111f3c8d29b0ca8d48a9`。后续实际测试结果由 Root 补充。
