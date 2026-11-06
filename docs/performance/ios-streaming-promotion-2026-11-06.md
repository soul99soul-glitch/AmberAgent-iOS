# 流式移动与 ProMotion（2026-11-06 晚）

**本轮只完成证据支持的定点修复，全局 <20% 主线程 / <50ms 最长间隔目标仍未达到。** 当前提交的父基线为 349128d5（含闪退修复），性能对照 UI 基线为 a0cb5c01。用户反馈上一版明显改善，但流式整体移动仍像 60Hz。本轮保留既有 Liquid Glass、16ms 吐字节拍、0.14s 匀速上移、收尾不提速与完成反馈逻辑。

## 已确认的限制与修复

- NativeTimelineScrollDriver 原来在流式跟随时设置 maximum/preferred=60；现在所有实际运动帧驱动请求 60–120、preferred=120，原来的空闲/用户接管停表语义保留。普通 SwiftUI sizeChanges 贴底期间原生驱动仍会停用，解除这一上限本身不等于解决默认路径的动画成本。
- 原生三点 CAAnimationGroup 和扫光 CABasicAnimation 原来没有帧率偏好，现在也请求 60–120、preferred=120。颜色、相位、路径、周期与暂停/Reduce Motion 行为保留。
- 默认时间线生长从自定义 GeometryEffect 换为系统 offset：自然高度照常增长，正向补偿立即应用，逆向 offset 按原有 0.14s 线性动画落位。geometryGroup 将即时与动画变换隔开，避免合并为静态零位移。没有改变 scroll contentSize、contentOffset 策略或吐字参数。
- Info.plist 原本已设置 CADisableMinimumFrameDurationOnPhone=true，无需补权限或更改用户设置。系统仍可调整实际刷新率。

## 对照与边界

手机原黑匣子 23:03:07–23:03:11（UTC 15:03）5 个窗口中，主线程 CPU 93.42%，主运行循环约 68.56 次回调/秒，最长间隔 112.68ms；同一文件也有 8.3ms 回调。不能把它描述为整个 App 全局固定 60Hz，更不能把回调频率当实际呈现帧率。

独立、无网络、无用户数据的真机小探针确认设备 maximum=120、低电量关闭、thermal=fair。在正确开启高刷许可后，显示回调中位约 8.33ms，自定义 GeometryEffect 调用中位约 15.51ms；effect 调用还混有状态提交，不能直接换算屏幕 FPS。临时 App 已移除。第二次呈现坐标 A/B 因锁屏未能运行，没有将其当成有效证据。

相同晚间私有输入，原生生产时间线的单轮模拟器回放（iPhone 17 Pro/iOS 26.5/Debug）：

| 指标 | a0cb5c01 | 最终独立进程回放 |
|---|---:|---:|
| 发送至最后文字显示、贴底停稳 1 秒 | 13.294s | 13.250s |
| 主线程 CPU | 59.52% | 45.46% |
| 最长帧间隔 | 328.09ms | 222.43ms |
| >50ms 间隔 | 6 | 6 |
| 采样内存峰值 | 241.42MiB | 224.80MiB |

数据来源为 `e2e-before.json` 与 `e2e-final-fresh-process.json`，最终独立进程回放 1/1 通过、无跳过，起始 footprint 192.60MiB / 192.82MiB。最终最后一字可见 12.200s，贴底稳定满 1 秒于 13.248s；1928 UTF-16 正文全部显示。最终运行打开了逐阶段计数，较早基线未统一开计数，因此这是相同输入的方向性比较，不是某个单一修改的精确归因；存在运行噪声；模拟器不能验证真机 120Hz。最长帧缩短而 >50ms 次数未下降，不能宣称所有卡顿已消除。正文满载期间及最终结构切换的剩余热点，仍需真机呈现/CPU 栈证据。

## 失败实验与回归保护

- 单纯制造生长动画、保持全部历史内容不变的探针，没有复现历史布局扩散。因此没有将“生长动画使所有历史每帧重排”当成已证实根因，也没有保留该无区分力的测试。
- 没有 geometryGroup 的双 offset 虽将单轮 CPU 降至 39.45%，却使首行 intermediate=0、直接跳到位；真实 CALayer presentation 坐标连续性用例失败，该版本被拒绝。最终版本同一连续性用例与整轮最后文字可见/实际贴底用例均通过（2/2）。
- 帧率定点先运行原实现，两项均失败：跟随值为 60，CA 动画未设置 120 偏好。修改后相应定点通过；暂停/重挂载/短回复与用户接管滚动断言保留。

此前受影响六组等合并运行结果为 112 通过、7 失败（`final-regression.xcresult`）。其中 6 项已有早前基线记录。恢复阶段在干净 tracked HEAD 349128d5 定点实跑，另外确认 `testLiveTailSingleTokenAndChunkHeightGrowthLayoutMeasurements` 的 4>3 与 `testStreamingTableBlockUsesVendorMarkdownRendererAndAsyncBlockController` 的源码形状断言也都会失败（`existing-failures-baseline.xcresult`，2/2 失败），不属于本轮新增。没有改动或放宽失败断言，也没有把整个回归组描述为全绿。临时基线对照前已保存全部 WIP 补丁与逐文件 SHA256，对照后恢复并逐项校验一致；原 stash 未删。按最新要求不重跑已完成的 generationActive 与淡入验证。

## 2026-11-07 同线程恢复与状态隔离

恢复时 HEAD 为 349128d5；闪退修复已提交、推送和装机（seq 2872）。这里的性能修改尚未装机。用户已获准拔 USB，本阶段不再进行真机操作。

- 上一次 `direct-paragraph-control.log` 是 `BUILD INTERRUPTED`，结果包缺失 Info.plist，不能视为通过。恢复后相同两个定点通过 2/2；原生正文直达实验的整轮结果为 13.405s、60.97% 主线程、212.49ms 最大间隔、9 次 >50ms。没有证明整体收益，已撤回该额外通路，实验补丁与源码保存在忽略的 `promotion-120/direct-paragraph-rejected.patch` 等文件中。原有 WIP stash 完整保留。
- 黑匣子中 `row-diff-independentTasks` 在两段分别出现 279、395 次。生产 `ChatTimelineRows.messageBubble` 仅在 `row.isLast && !isTaskLive` 的分支消费这一模式。现将 chunk 签名和行模型中的该值都限制到此类尾行，显式独立 live-task 行保持自己的状态。真实生产时间线窗口定点在修复前仅切模式就重建 23 条历史行，连 chunk-0 都重算；修复后同一测试历史 body=0、无关 chunk-0 body=0，两个方向切换均通过。
- 已完成的生成状态隔离保留：纯历史正文不消费全局 generation 标志，历史图片、小程序的修改控制以及尾行/live-task 行继续消费。先前定点 3/3，通过时历史开始/收尾 body 43→2、44→1；并非删除生成状态。
- 已完成的原生淡入保留：仅 Amber 明确 opt-in 的 TextKit 1 尾部整段淡入使用绘制透明度，不再逐帧写 NSTextStorage 的颜色属性。字色、文本、选择/可访问性和淡入曲线保持；默认 vendor TextKit 2/逐词模式不改变。先红后绿验证了属性编辑次数降为 0，且像素渲染确有透明度变化；5 个相关定点已通过，恢复后未重复运行。Glyph-fade 单轮 13.211s、45.66%、194.47ms，仍未达到目标。
- 现有采样未将 `listAllRuns` 指认为头部热点，本轮不改 DAO 或持久化。

恢复后的最终组合定点：`independent-mode-green.xcresult` 3/3 通过（独立任务模式、原捕获扇出、晚间整轮）。同一捕获中挂载 95 条历史行：

| 事件 | 历史 body | 历史 sizeThatFits 请求 / 实测 | 历史 placeSubviews |
|---|---:|---:|---:|
| 单字更新 | 0 | 0 / 0 | 0 |
| 单次工具事件 | 0 | 0 / 0 | 0 |
| 进度文案切换 | 0 | 0 / 0 | 0 |
| 换行增长 | 0 | 0 / 0 | 380（95 行各 4 次） |

不能把 body 隔离等同于布局完全消失：换行增长仍有 placement 遍历，当前尾行单字仍实测 4 次。组合运行整轮 13.230s、46.01%、203.68ms、>50ms 5 次、峰值 274.88MiB；起始 footprint 已有 241.97MiB，因为前一个捕获测试在同进程留下缓存。此值单列，不拿它与新进程基线的内存直接归因比较。

完整场景目标仍为主线程 <20%、最长帧间隔 <50ms；任何已有单轮改善均不等于达标。默认模拟器不具备真机 120Hz 呈现证据。没有改短吐字时间、收尾提速、跳过贴底或关闭屏内动效换数据。

## 复现

私有对话输入只保留本机忽略目录，不进入 Git、Library 或云端记忆。

```sh
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/StreamingPerfBaseline -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests/testFirstTwoStreamingLinesUseContinuousNativeBottomFollow \
  -only-testing:iosAppTests/ChatSearchEndToEndReplayTests/testEveningCapturedRoundThroughVisibleCompletion test
```

定点请求测试：ChatTimelineReviewRegressionTests/testFrameDriverRequests120HzDuringStreamingAndInteractions 与 ChatTimelineAnimationIsolationTests/testProgressLayerAnimationsRetainGeometryAndPauseTheirClock。结果目录 promotion-120 保留原始/最终 e2e、independent-mode-red/green、existing-failures-baseline、final-fresh-process 结果包，以及被撤回 direct-paragraph 的补丁和源文件。失败实验不进入产品编译。所有原始私有输入仍仅在本机忽略目录。

Apple 原始资料：[ProMotion 帧率提示与系统调度](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays)、[geometryGroup 的几何边界](https://developer.apple.com/documentation/swiftui/view/geometrygroup())。

交付边界：本次不再安装、采样或导出真机。手机仍为 349128d5 / databaseSequenceNumber 2872，含 46071c9b 震动修复；新性能改动的真机 120Hz 呈现、实际调研全流程和关闭完成震动后无震动，均待用户重新授权连接后验收。下一步应针对仍存在的尾行 4 次测量和换行布局遍历取得同场景呈现/CPU 证据，不能把此次局部改善记成全部完成。

## 首滑查看历史的所有权修复（2026-11-07）

真实 Simulator pan（170,610→170,675，800ms）：原版已离底 52pt，仍被96pt返回容差重新开启贴底，followPaused=false，定点失败。修复后相同手势离底54.33pt、followPaused=true，单次真实pan用例通过。这个静态输入对照验证了错误恢复状态，未把它说成已录到用户完整弹回过程。

手指落下时记录现有UIScrollView的纵向位置；释放和后续几何恢复均检查实际滚动方向。离开底部的拖动保留暂停，真实回到物理底部仍可恢复；从历史向底部返回保留原96pt容差。判断不使用内容增长导致的距底变化，以免正在生成的回复反向污染用户拖动方向。没有新增偏移写入。共享策略新增参数默认false，其他现有消费者保持旧行为。

新方向边界及原NativeTimelineScrollCoreTests共61项通过；额外真实pan通过1项。一次中间运行因未及时注入外部手势而失败，不计通过；随后test-without-building及时注入相同手势通过。手势诊断仅显式armed时运行，普通测试自动skip，不依赖用户配合。pin modifier移到已有ChatTimelinePolicies.swift以保持主文件1486行，行为未改。没有真机连接操作。核心性能目标仍待继续处理。
