# 长表格性能门禁：独立二次判定

状态：**门禁失败真实存在；原因未定，等待全量结束后以原断言做冷进程独立复测。** 当前证据不能把失败归因为 C6/C7 退化，也不能将其判为 flaky。主 App 全量仍在运行，本报告不声明全量最终结果。

本次仅只读分析 C6/C7、目标性能测试及其前序 fixture、已有 stdout 和任务前快照。审查者未改源码/测试、未构建或运行测试、未接触 B3C3；只从已经完成的早轮 xcresult 导出诊断文件，并保存本报告。

## 两轮实际测量

目标为 `ChatNativeTimelineReplayPerformanceTests/testPerfGrowingTableStreamingKeepsDisplayLinkResponsive()`。

| 指标 | 早轮 `phase4-rendering-green` | 本轮 `final-main-green` |
| --- | ---: | ---: |
| samples | 80 | 78 |
| p95 | 35.57 ms | 43.80870843306184 ms |
| max | 70.16 ms | 73.91 ms |
| over50ms | 2 | 2 |
| 测试耗时 | 3.647 s | 5.213 s |
| 原断言结果 | 通过 | p95 > 40 ms 失败；max ≤ 80 ms 通过 |

早轮原始输出：

```text
[PERF-HITCH] growingTable samples=80 p95=35.57ms max=70.16ms over50ms=2
```

本轮原始输出与失败：

```text
[PERF-HITCH] growingTable samples=78 p95=43.81ms max=73.91ms over50ms=2
XCTAssertLessThanOrEqual failed: ("43.80870843306184") is greater than ("40.0")
```

本轮只触发 `ChatNativeTimelineReplayPerformanceTests.swift:254` 的 p95 断言；max 断言未失败。上述差值是两次实际观测，尚不是某一实现或 fixture 导致退化的因果证明。

早轮数值从完成后的 `phase4-rendering-green.xcresult` 通过 `xcresulttool export diagnostics` 取回，不是根据分组测试通过结果推测。原始 stdout 位于：

```text
/tmp/amber-audit-20261018-current/perf-comparison-readonly-diagnostics/0_Test_Amber Audit 20261018_Diagnostics/iosAppTests-40B8D910-A3B1-4A95-B47F-35CA5599E248-Configuration-Test Scheme Action-Iteration-1/iosAppTests-2E991EC6-64F6-4680-95A4-9865D3535A7B/StandardOutputAndStandardError.txt
```

其中 244–249 行记录前序测试、appearance 警告及本用例 PERF 输出。本轮读取的是运行中的既有文件：

```text
/tmp/amber-audit-20261018-current/final-main-green.xcresult/Staging/1_Test/Diagnostics/iosAppTests-21DCB605-2D5E-45FC-BC17-49472D6B49DA-Configuration-Test Scheme Action-Iteration-1/iosAppTests-58158368-10E4-4E26-82DB-74B0D706DD6B/StandardOutputAndStandardError.txt
```

读取时 1399–1405 行记录相应前序测试、警告、PERF 输出及失败。运行结束后 Staging 路径可能由 xcresult 收纳；以上关键原始输出保留在本报告。

## C6/C7 在该输入上的执行路径

目标 fixture 生成普通无反斜杠三列表格：初始 80 行，再以 12 次更新追加到 92 行；保留表格视觉和动画。probe 前已有 2 秒渲染等待，随后按原测试热身、采样及计算 p95，未改变门禁。

- `iosApp/iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownBlockParser.swift:225`：C6 的 `renderedRowLine` 仍每行调用一次 splitter。新增参数为 `preservingPipeEscapes: true`，新增的反斜杠 append 只在 `\` 后接 pipe 的分支执行（239–245 行）。目标输入没有这种转义，该分支不执行；普通三列行仍在 226 行原样返回，不进入 padding/join。
- C6 没有在该分支新增一次整行 split；原有字符数组、trim、cell 构建与规范化调用次数未因本修复增加。
- 同文件 121 行：`parseTable` 消费完整表格后，`parseBlocks` 一次跳过已消费的全部行。C7 没有给内部 80–92 行额外增加逐行 fence 检查。
- 同文件 16–28 行：普通 pipe 开头的行在 marker 检查后直接返回 false，不进入 fence run length 或关闭行尾部扫描。HEAD 旧实现也已每行 trim 并检查 fence 前缀。
- `iosApp/iosApp/Chat/Rendering/Markdown/ChatStreamingMarkdownDetection.swift:78`：incremental detector 在 header/delimiter 识别表格后 latch 为 `containsTable`，后续 update 直接返回。C7 未新增后续 chunk 的全表重扫。

另一位未实施 C6/C7 的审查者独立对照 HEAD 原 `ChatAssistantMarkdownView.swift` 中 parser，得到相同的路径结论。这个结论只说明没有在目标输入上找到新增频繁扫描/分配或重组的具体路径，不表示已经通过 profiler 证明两版本耗时等价。

## 前序 fixture 的可观察生命周期现象

两轮均先执行 `testLayerBackedTableEntranceDoesNotChangeLayoutWhenAnimationCompletes()`，紧接着执行目标性能测试。

| 现象 | 早轮 | 本轮 |
| --- | --- | --- |
| 前序 LayerBacked 测试 | 0.552 s，通过 | 0.680 s，通过 |
| 目标测试开始后 | 同类型 appearance warning | 同类型 appearance warning |

两轮警告的 controller 类型均为前序测试创建的独立 `DocumentView` hosting controller：

```text
Unbalanced calls to begin/end appearance transitions for
<UIHostingController<ModifiedContent<SwiftStreamingMarkdown.DocumentView, ...>>>
```

它不是目标性能 fixture 的 `ChatNativeTimelineReplayTestCase.Harness` host。前序测试在 `ChatNativeTimelineReplayPerformanceTests.swift:285` 创建独立 window，调用 `makeKeyAndVisible`，等待 0.5 秒后检查动画完成布局；其 290–293 行 defer 仅隐藏 window 并移除 root，没有等待 appearance transition 完成。紧随的性能 fixture 又创建并显示一个窗口。

因此，可以确认存在跨测试边界出现的 UIKit 生命周期警告。不能确认它导致此次 p95 超限：早轮通过时也出现了相同 controller 类型的警告，现有日志没有将警告或具体前序任务与 probe 的慢帧逐一关联。未发现或声称该 fixture 存在已证实的泄漏。

## 源码与任务前快照核对

- 目标性能方法与前序 LayerBacked 方法的函数体，均与 HEAD 原 `iosApp/iosAppTests/ChatSwiftUIStreamReplayTests.swift` 对应函数逐字一致，包括采样过程、动画和断言。
- 两方法当前 body 的 SHA-256 分别为 `0f04e7a3e7d7e14cf33bffe32327aff5f71d52b977f94e52d2b56258a2694074`、`ec5f473e504f69c1438d5972f4c8bd17f2f640f1b517e7bdd6dc4d7ae06ed851`。
- 共享 `ChatNativeTimelineReplayTestCase.swift` 当前 SHA-256 与任务前 `baseline-files.json` 一致：`22028e63e487d9de44309b9ab579a5205bb7e7887c9890f2e466081a11aff9d1`。其中 fixture teardown 仍仅隐藏 window/移除 root，DisplayLinkGapProbe 停止时 invalidate，未增加新的 timer/probe。
- vendor `SwiftStreamingMarkdown/Sources/MarkdownText/UI/TableView.swift` 当前 SHA-256 与同一任务前快照一致：`4a5902ac98f925b8c3e77ba9b4e35e481fed8d2809e767f840568362f99ac0ca`。现有 table entrance 动画为 0.34 秒 UIView/Core Animation 路径，不因本轮 C6/C7 引入新的 CADisplayLink。
- 整个拆分后的 PerformanceTests 文件 hash 与任务前快照不同；以上“函数体一致”结论仅针对这两个被核对方法，不据此宣称整个测试文件未变。parser 的对照来自现有源码与 HEAD 旧实现，未把 HEAD 当作任务前未提交内容的完整替代。

## 待执行复测与判定边界

由 Root 等当前全量结束后，冷进程单独运行原 selector：

```text
iosAppTests/ChatNativeTimelineReplayPerformanceTests/testPerfGrowingTableStreamingKeepsDisplayLinkResponsive
```

保留 p95 ≤ 40 ms、max ≤ 80 ms 原断言、原动画和原 PERF 输出。当前证据不支持先改 C6/C7、放宽阈值、延长等待或修补 fixture 后再测。

若单例通过但仍需定位组合影响，再以新进程只运行该 Performance suite，保留前序 fixture 顺序作对照；不重复扩大到全部六组。独立通过可作为新的测量证据，不能抹去本轮实际失败，也不能单独证明 fixture 就是原因。

本报告截至保存时仍为 **未定因 / 冷进程复测 pending**。Root 后续补充实际结果；未宣称生产退化、flaky、fixture 因果关系或最终性能 GREEN。
