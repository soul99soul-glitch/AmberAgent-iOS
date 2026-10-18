# 验证记录与证据边界

本记录只汇总实际执行结果。不同运行覆盖的测试有重叠，数量不能累计成一次全量执行。生产问题、误报和 by design 的判定见 [逐项清单](findings.md)，每个阶段的独立复核链接保存在对应阶段报告。

## 最终消费方验证

| 入口 | 实际结果 | 证据与覆盖重点 |
| --- | --- | --- |
| 主 App 最终构建 | `build-for-testing` exit 0；包含本仓 Gradle 生成的 Shared.framework、Chat 最终边界、Home v2 和 MCP-1，临时性能代码已撤回 | [构建状态](delivery-final-build.status.json)。构建没有执行测试，不能把摘要中的零项当作测试通过。最后的 Novel 测试等待修正另按下文记录。 |
| 主 App 全量单元测试 | 第三轮 5144 项：5135 通过、1 失败、8 跳过，保留 Failed；唯一失败是 Novel quick-start 测试在操作锁释放前接受建议 | [第三轮摘要](main-integration-third-summary.json) / [分组](main-integration-third-groups.json)。MCP、保活整组及原表格门禁均通过，Novel fixture 修正后按受影响范围验证，结果见下文。第二轮同为 5144 项、唯一 KeepAlive fixture 失败的 [摘要](main-integration-second-summary.json) / [分组](main-integration-second-groups.json)，首轮 5143 项、2 失败的 [原摘要](main-integration-first-summary.json) 与 [分组](main-integration-first-groups.json) 均保留。主 scheme 单元测试不等于独立 UI acceptance target。 |
| Novel 独立 App | 构建 exit 0；全量 1059 项：1057 通过、2 跳过、零失败 | [构建](novel-consumer-build.status.json)、[测试摘要](novel-consumer-green-summary.json)、[分组](novel-consumer-green-groups.json)。覆盖小说状态、事务、Workspace、流式、adapter、生命周期和真实消费接线。 |
| DeepRead 独立 App | 构建及全量测试通过，109/109，零跳过 | [测试摘要](deepread-consumer-green-summary.json)。独立模块实际消费同一 Store，验证补齐失败保全和损坏库拒绝覆盖。 |
| PhoneControl SwiftPM | 107 项全部通过 | [日志摘要](phone-green-summary.json)。范围校验和输入等待期间取消/人工接管均有失败反例；不代表物理手机动作验收。 |
| OpenAI KMP JVM | 全模块 81 项通过，零失败/错误/跳过 | [摘要](kmp-green-summary.json)。包含 Responses 与 Chat Completions refusal 的非空正文与流式回归。 |
| Shared KMP JVM | 最终全模块 56 项通过，零失败/错误/跳过 | [摘要](shared-baseline-green-summary.json)。包含 Gemini 合法属性名及独立 run 基线、显式空基线、旧格式 payload。Swift 另经原生构建和 Host/后台消费测试验证。 |

主 App 的 [8 个跳过项及原因](main-skipped-tests.json) 保持原条件：五项依赖真实 provider/搜索/抓取环境的测试（含两项 Intelligent UI）、一项需要系统 Reduce Motion 的检查，以及两个真机项目包检查。没有配置真实 provider 或补造外部数据。首轮另有两个 runtime warning，分别定位测试文件 `IOSCouncilRoomArchiveStoreTests.swift` 的 QoS 等待和 `IOSSharedSettingsStoreProvidersWriteBackTests.swift` 的脱离 View 读取 State；未把警告本身升级为已确认产品缺陷。

Novel 的两个跳过保持既有条件：`testDeviceZhaodalaiPackageLoadsAndValidates` 缺少 `/tmp/amber-novel-device/project`，`testApplyRelinkOnDeviceZhaoDaPackage` 缺少 `/tmp/amber-repro-pkg`。未伪造外部真机项目数据。

## 风险相关回归与真实 UI

- 第 1 阶段 iOS 248/248、第 2 阶段 86/86 实际通过；原有失败、编译设施问题和控制项分开记录在 [阶段 1](phase-1.md)、[阶段 2](phase-2.md)。
- Chat/Tools 最后聚焦运行 304 项中 302 通过、2 失败；两个失败分别是测试取错原始基线与 ledger 恢复的读改写基线误用。校正后，两组套件 [17/17 实际通过](phase3-final-failures-green-summary.json)。原失败摘要保留，未改写成整轮绿色。
- C1/C2/R1–R3 回归覆盖同 run 续跑、checkpoint 身份、服务端重放、跨模型轮后失败保存；T1 实际经过 Host、后台 writer 和两个生产 consumer，检查本轮 partial、终态 metadata、长报告引用及幂等。
- Markdown 实际 renderer 的源文本与单元格检查通过；Native Timeline/viewport 六个要求套件在前一轮共 96 项通过，最终组合结果另按主 App 全量摘要核对。SwiftUI 或非默认列表用例不代替 Native 生产路径证据。
- Search PLAT-1 已完成普通模拟器 App 的真实交互：有效目标打开、损坏目标留在结果页并显示错误、关闭错误保留查询/命中、恢复同一目标后原命中直接重试成功；失败后取消回 Home，原 current 会话仍保留。[步骤及截图/AX 索引](reviews/search-real-ui/green-verification.md)。
- Home PLAT-2 首修提交通过，但取消/点外后重开留下原生输入内容，真实 UI 推翻首轮源码推断。失败记录保留于 [home-validation.md](reviews/search-real-ui/home-validation.md)；v2 在显式意图恢复立即清空，仅失焦暂留提交查询。[v2 真实交互](reviews/search-real-ui/home-v2-verification.md) 已通过：提交保留 TARGET；取消、点外后重新展开为空；各自继续输入一次 TARGET 可匹配且无文字拼接。普通 List 滚动未收起键盘，不扩称纯收键盘验收；空库数据未移动。

Search 的首次进程内 AX 测试无法枚举真实 SwiftUI 控件，连正常对照也不成立，故不作为产品失败证据。任务新增的无效设施已原样归档，普通安装 App 的真实 RED/GREEN 替代其验收；未删除用户既有测试或削弱有效业务断言。

## 最终组合中发现的验证问题

MCP 首轮 plain HTTP 404 不能证明生产恢复失败。全局 FIFO 响应脚本预设两个 tools/call 均在 initialize 前，而 20ms 延迟不能保证该顺序；[诊断](reviews/mcp-concurrent-expiry-diagnosis.md) 和 [确定性 fixture 修复](reviews/mcp-concurrent-expiry-fixture-fix.md) 保留全部输出、恢复/刷新/断开次数及最终状态断言，另断言两个原 session 调用确实进入。修后 [两组 suite 50/50 通过](mcp-final-green-summary.json)，[独立复核](reviews/final-mcp-fixture-independent-review.md) PASS，生产代码未因此增加兜底或重试。

实际 Client FIFO 的另一个三调用边界取得 [确定性 RED](mcp-queued-real-red-summary.json)：C 在恢复清空配置后抛出 invalidResponse。正式确认 MCP-1，修复为同一 FIFO slot 内的原子 reconnect；[第 7 阶段](phase-7.md) 独立 review PASS，构建 exit 0，两组 suite [51/51 通过](mcp-atomic-reconnect-green-summary.json)。旧 red、fixture 假阳性及真实产品故障分开保留。

Native 长表格首轮 p95 43.81ms，冷进程单例 [再次失败](cold-native-r1-summary.json)，p95 41.38ms、max 94.58ms，原门禁为 p95≤40ms、max≤80ms。早轮同源码路径 p95 35.57ms 通过；[独立二次判定](reviews/final-performance-second-review.md) 未将失败预判为波动或 C6/C7 退化。Root 当时采集 Time Profiler 并按实际热点检验修复假设，没有放宽阈值。带自动重复/重启选项的一次 XCTest 会话未启动任何用例，已保留启动日志、正常空闲主线程 sample 并只中断该任务；它不计为产品 RED。

[完整诊断](reviews/table-performance-diagnosis.md) 区分了 Perf 方法栈、setup/warmup 与实际帧窗口，未把全局 AttributeGraph 耗时归属为某个 cell 的根因。单次 makeCache 内测量去重实验经独立源码 review 后实际测得 [p95 97.04ms，仍失败](table-local-dedup-after-summary.json)，不具有保留依据；Root 已用改前/改后 SHA256 守卫 [恢复 vendor 原始字节](table-measurement-experiment-withdrawal.json)。对应几何测试草稿未落地、未执行，不计作回归通过。随后仅使用同夹具空闲对照区分实际追加成本与模拟器帧节奏，没有继续叠加缓存。

同一原版生产代码加入临时 0.5s 空闲对照后，[空闲有效 gap 仅 2 个、均处于约 94ms，追加 p95 89.49ms](table-idle-control-summary.json)。这批样本很小，不能作为可靠的空闲 p95 分布。只重启任务自建模拟器、保留数据及原有模拟器后，同一二进制的 [空闲有效 gap 26 个，16.67ms；追加 p95 36.04ms，max 99.30ms](table-idle-control-after-device-restart-summary.json)。p95 达标但 max 仍失败，没有把它描述为全门禁通过。[独立二次判定](reviews/final-table-performance-adjudication.md) 保留“运行状态影响明显，产品根因未定，不能判彻底假阳性”。临时诊断已按哈希恢复，最终完整测试使用原表格代码及原测试阈值。

第二轮完整组合中的该原始用例已实际通过：[74 个 gap，p95 37.61ms、max 73.27ms](table-final-combination-metrics.json)，保持 p95≤40ms/max≤80ms 原断言。该整轮唯一失败是下段的 KeepAlive fixture；此前失败没有改写为绿色，亦未宣称所有潜在性能问题不存在。本轮没有保留 vendor 性能改动，也未据未定根因新增缺陷编号。

第三轮完整组合的同一原始用例再次通过：[79 个 gap，p95 34.29ms、max 58.94ms](table-third-combination-metrics.json)，原阈值和源码哈希保持不变。该整轮唯一失败位于 Novel quick-start 测试，不是性能门禁。

第二轮主 App 5144 项完整运行的唯一失败为 `BackgroundGenerationKeepAliveTests/testSubmitFailureRetryDoesNotLoopForever`：固定等待 100ms 后只记录 1 次提交，预期为 2。该批次 testcase 耗时 1.703s；生产重试 Task 要先获得 MainActor 执行权才开始自己的 20ms 延迟，测试的等待可先结束。[窄诊断与独立 review](reviews/keepalive-submit-retry-fixture-review.md) 确认是夹具时序，生产单次 retry 集合门禁未改。修正仅让测试等待真实第二次提交结束，再用 inverted expectation 观察五个 retry 间隔；exact2、lease 保留、零成功请求、begin1 业务断言全部保留。[修正构建](delivery-final-build.status.json) exit 0，同一产物的 [保活整组 43/43 实际通过](keepalive-fixture-restarted-summary.json)，零跳过。

该保活整组的第一次 launch 停在 XCTest `AcquiredPID`，没有测试方法开始；进程 sample 只有正常 App RunLoop，没有 XCTest image。Root 仅中断该任务 xcodebuild，保留 [取消状态](keepalive-xctest-startup-cancelled.status.json)，只重启任务设备后用同一产物取得 43/43。xcresult 将取消登记为一个进程错误，不能拿它当一个业务用例失败或产品 RED；也没有把未执行记为通过。

第三轮唯一失败是 `NovelCreationQuickStartTests/testQuickStartAndBranchOverrideUseRealModuleActions` 在接受建议后读取到空素材。测试仅等四条建议进入快照，可以先于 Quick Start 初次 operation owner 释放调用接受方法；真实候选卡受 `canMutate` 控制，写入按钮在 `isPerforming` 时禁用。[诊断](reviews/novel-quickstart-ready-diagnosis.md) 与 [独立复核](reviews/novel-quickstart-fixture-independent-review.md) 判定为夹具 readiness 竞态，仅将第一用例改为等待四条建议与 `.idle`，保留所有原行为断言。原失败没有采集锁状态和接受方法返回值，结论是源码支持的可达时序判定，未冒称该次 debugger 取证。

最后的测试修正已编译，同一产物的 [Quick Start 全类 8/8 通过](novel-quickstart-fixture-restarted-summary.json)，零跳过。第一次聚焦启动同样停在 `AcquiredPID`，没有业务测试开始；仅中断对应 xcodebuild 并保存 [启动取消状态](novel-quickstart-xctest-startup-cancelled.status.json) 与 `/tmp` 下的进程 sample，只重启任务设备后执行 `test-without-building` 得到上述通过结果。没有新增产品兜底，也没有把启动取消或未执行记为业务失败/通过。

最终采用“完整组合结果＋最后测试修正的受影响整组复测”交付。最后一次完整运行仍是 5135 通过、1 失败、8 跳过，未改写为全量绿色；其唯一失败修正后整组通过。最后一次修正只改测试 readiness，生产源码与完整运行时一致，未再重复完整测试。

## 检查、工作树与未验证项

最终 [检查记录](delivery-final-checks.json) 实际通过：Swift 物理行数 strict 为 1331 文件、零超限，Shared 的 10 组 Swift 消费类型均可达，`git diff --check` 无问题。[源码与工作树核对](delivery-completed-checks.json) 确认 1608 个源文件相对完整运行仅变更最后的 Quick Start 测试，生产源码无变化，19 条已记录同期修改均保留，分支与 HEAD 未变。构建对 vendor lockfile 未用 pins 的自动裁剪已用改前/改后 SHA 与结构守卫 [恢复原始字节](final-lockfile-cleanup.json)，未变更任何依赖版本。

检查前后对照任务开始时的 Git 状态、3488 个 Git 可见文件 SHA256 及完整 tracked WIP patch，原始证据位于 `/tmp/amber-audit-20261018-current`。不把其他会话同期的模块化测试与文档改动归为本任务修复；未 reset、stash、clean、stage、commit 或 push。

使用任务自建 iOS 26.5 模拟器 `B3C3F24B-7D39-4695-86BB-588EEC6469A4`，与原有 booted 模拟器及物理设备隔离。UI 复现仅操作任务自建会话，损坏测试后恢复有效字节；证据保存后已 [仅删除本任务模拟器](final-device-cleanup.json)，原有 `F3D5299E-EEA6-4098-BF61-AB1C516933C0` 清理前后均保持 Booted，未操作物理设备。

上述结果不替代真实 provider 的网络恢复、iOS 系统后台调度/任务到期、真实 TCC 授权、Watch 配对、desktop 后端或物理设备滚动与输入法验收。Search/Home 普通模拟器 UI 已单独验收的具体行为按对应步骤记录，不扩大到未实测的快速点击/离场竞态。没有据测试数量宣称所有潜在缺陷已清零。
