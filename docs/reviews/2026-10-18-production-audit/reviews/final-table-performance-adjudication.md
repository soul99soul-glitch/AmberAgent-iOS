# 长表格性能项：新增对照数据后的独立判定

**当前结论：恢复原实现和原测试后的最终组合中，该长表格用例实际通过原 p95/max 门禁；整轮仍在运行，最终全量结果 pending。此前多次失败真实存在，结果对运行状态及采样窗口敏感。本轮未确认独立产品根因，保留门禁与诊断，不新增缺陷计数；没有保留性能产品补丁。** 这不表示此前观测均为假阳性，也不表示所有潜在性能问题不存在。

本次只读现有摘要、诊断 stdout 和恢复 SHA，未重复代码审查，未修改源码/测试、未构建或执行测试、未操作设备。以下执行与模拟器操作均由 Root 完成。

## 新增实际证据

| 执行 | 实际数据 | 结论边界 |
| --- | --- | --- |
| 原版 before-control | p95 45.4767 ms；原断言失败 | 原版已不能在该次运行满足 40 ms 门禁。见 `table-local-dedup-control-before-summary.json`。 |
| 单轮局部 dedup 实验 after | p95 97.0449 ms；原断言失败 | 未获得实验收益，实验已撤回。单次 before/after 不足以把变差全部归因于 dedup，也不支持保留该实验。见 `table-local-dedup-after-summary.json`。 |
| 原版、临时 0.5 s idle control，重启设备前 | idle 有效 gap 2，p95/max 均 94.2864 ms；append 有效 gap 56，p95 89.49 ms、max 115.68 ms、over50ms 8 | 不新增行的窗口也出现明显长间隔；append 的 p95 与 max 均触发原断言。该窗口样本很少，不能作为稳定 idle 分布。 |
| 同一诊断二进制，仅重启任务模拟器 B3C3 后 | idle 有效 gap 26，p95/max 均 16.6667 ms；append 有效 gap 83，p95 36.04 ms、max 99.30 ms、over50ms 1 | idle 节奏及 append 大部分间隔明显改善；p95 通过，但 max 99.2972 ms 仍超过 80 ms，整项仍为 Failed。 |
| 恢复原实现和原测试后的最终组合运行 | samples 74，p95 37.61 ms、max 73.27 ms、over50ms 2 | 该长表格用例实际通过原 p95 ≤ 40 ms、max ≤ 80 ms 门禁，随后已进入 `ChatReasoningCardTests`。这是该用例在最终组合中的结果，整轮尚未结束。 |

重启操作未 erase；原 F3D 模拟器保留。它是运行状态控制，不是产品代码修复。

idle control 在固定内容、不新增表格行的阶段采样，之后才执行原 append 负载。重启前后的诊断使用同一二进制；因此两者的明显差异不能由一次源码改动解释。但是，这个临时控制增加了 0.5 秒窗口，会改变相对 warm-up 时序，不能代替最终恢复原测试后的测量。

实际 stdout：

```text
# 重启前
[PERF-CONTROL-IDLE] samples=2 p95=94.286416657269ms max=94.286416657269ms
[PERF-HITCH] growingTable samples=56 p95=89.49ms max=115.68ms over50ms=8

# 同一诊断二进制，B3C3 重启后
[PERF-CONTROL-IDLE] samples=26 p95=16.66666683740914ms max=16.66666683740914ms
[PERF-HITCH] growingTable samples=83 p95=36.04ms max=99.30ms over50ms=1

# 恢复原实现、原测试后的最终组合
[PERF-HITCH] growingTable samples=74 p95=37.61ms max=73.27ms over50ms=2
```

摘要文件为 `table-idle-control-summary.json`、`table-idle-control-after-device-restart-summary.json`，两者均记录 1 项执行、0 通过、1 失败。重启后摘要唯一断言失败为 max 99.29720824584365 ms > 80 ms，不能因 p95 已通过而将该测试称为 GREEN。

最终组合的新增通过结果来自 Root 提供的 active Session 原始日志；它使用已恢复的 vendor `4a590…` 与原测试 `ee02…`，不是临时 idle control，也不是 dedup 实验。Root 将在整轮结束后补充完整摘要；此处只记录已实际完成的该用例。

诊断来源为下列目录内的 `StandardOutputAndStandardError.txt`：

- `/tmp/amber-audit-20261018-current/table-idle-control-diagnostics`
- `/tmp/amber-audit-20261018-current/table-idle-control-after-device-restart-diagnostics-final`

## 哪些判断已有支持

1. **长间隔并不只在新增行时发生。** 重启前固定内容的 idle 窗口已观测到约 94 ms 的 gap，不能把同轮所有 append 慢帧直接解释为“新增一行必然产生的布局代价”。
2. **结果受进程/模拟器运行状态及采样窗口影响。** 同一诊断二进制在设备重启后，idle 从极少有效样本和长 gap 变为 26 个正常约 16.67 ms 的间隔，append p95、长 gap 数量也改善。源码保持不变而结果变化，是运行状态参与影响的具体证据。
3. **重启前 idle 的 p95 不能当稳定基线。** 只有两个有效间隔，无法描述通常帧间隔的分布；94 ms 的实际长间隔仍是有效观测。有效样本数从 2 到 26 的变化也应与 p95 一起报告，不能只比较单个百分位数。
4. **本轮局部 dedup 没有取得可接受收益。** after 仍失败且没有支持保留实验的证据，按 guard 恢复原代码合理。源码审查曾允许开展实验，并不意味着优化有效；性能假设需要以实际数据判定。
5. **原版在最终组合的该次条件下满足原门禁。** 没有保留性能产品补丁，也未更改阈值、动画或采样测试，最终组合中的 p95/max 均通过。与此前失败一起看，适合将本项分类为“本轮未确认独立产品根因，保留门禁/诊断，不新增缺陷计数”，而不是新增一个已确认产品缺陷或宣称产品问题已经修复。

## 仍不能推出的判断

- **不能确定是操作系统或模拟器自身造成全部慢帧。** idle 不追加行，但仍包含已挂载的应用视图及其布局、动画或既有任务。重启也改变进程生命周期及既有任务状态；当前控制没有把这些因素进一步分离。
- **不能排除应用自身的某段工作。** 重启后 append 仍有一次约 99 ms 的长 gap；它可能关联应用工作或外部调度，但现有摘要不能把该 gap 精确归因。尚无证据将它归到 C6/C7 或某一具体生产函数。
- **不能判为彻底假阳性或直接标为 flaky。** 原版已反复违反原门禁，重启后的控制也仍 Failed。最终组合该用例通过不抹除此前长间隔；运行状态敏感说明需要保留上下文，不能推出所有运行条件均满足门禁。
- **不能认定实验造成了可重复退化。** 单次实验 after 变差、原版后续也出现更高间隔；缺少稳定的归因对照，能够确认的是实验没有通过，而不是已证明的因果链。
- **不能将该用例通过写成整轮通过或所有性能问题不存在。** idle 控制是临时诊断，最终组合则已使用恢复后的原测试与原阈值；后者证明该用例在该次条件下满足门禁。整轮仍在运行，尚不能给出完整组合最终结果，也不能据此排除所有潜在性能问题。

## 已恢复状态与最终报告措辞

只读核对当前文件，SHA 与恢复记录一致：

- vendor `TableView.swift`：`4a5902ac98f925b8c3e77ba9b4e35e481fed8d2809e767f840568362f99ac0ca`。局部 dedup 未保留，见 `table-measurement-experiment-withdrawal.json`。
- `ChatNativeTimelineReplayPerformanceTests.swift`：`ee02c871f87bf8fdac78489f3240cec34dcca8523a743ec1ff2bcd26bef7839e`。临时 idle 追加代码已恢复，见 `table-idle-control-source-before.json` 与 `table-idle-control-source-after.json`。
- p95 ≤ 40 ms、max ≤ 80 ms 的原门槛未调整，动画未通过本实验关闭。

建议当前对外措辞：

> 长表格性能门禁此前多次真实失败，固定内容采样及模拟器重启对照表明结果对运行状态和采样窗口敏感。局部去重实验未取得可接受收益，已恢复原实现及原测试，没有保留性能产品补丁。最终组合中该用例实际得到 samples 74、p95 37.61 ms、max 73.27 ms，通过原门禁；整轮尚未完成。本轮未确认独立产品根因，保留门禁与诊断，不新增缺陷计数。该次通过不抹除先前失败，也不代表所有潜在性能问题不存在。

后续只接收 Root 正在执行的原版完整组合数据，不建议继续堆缓存、改阈值或以临时诊断窗口替代原门禁。最终全量结果由 Root 追加；本报告只确认上述用例通过，不预判整轮结果。
