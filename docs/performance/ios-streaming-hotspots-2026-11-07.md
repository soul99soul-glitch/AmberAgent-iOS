# iOS 流式热点修复与未达标边界（2026-11-07）

目标仍是整轮主线程 CPU <20%、最长帧间隔 <50ms，同时保持原有视觉、16ms 吐字节奏、0.14s 匀速上移、收尾不提速和真实贴底。当前仅交付证据支持的修复，不能记为全部达标。没有真机连接、安装、采样或导出操作；手机仍为349128d5/seq2872。

## 已保留的修复

1. **首滑查看历史**（78e2ce2b）：离底方向的真实拖动不会被96pt返回容差抢回贴底。相同Simulator pan从修前52pt却followPaused=false，到修后54.33pt且followPaused=true。方向与既有滚动组61项通过，额外实际pan1项通过。Shared默认参数保留其他消费者行为，无新增contentOffset写入。
2. **运行记录轻量查询**（8583684c）：七个Swift消费者只读取所需字段，不再物化全部恢复快照。原listAllRuns保持给恢复/诊断路径使用；记录顺序、过滤和错误行为保持，notice投影保留审批inputSnapshotRef。没有改Room schema或迁移。真实Room投影测试1/1、Swift调用方与并发回归28/28通过。
3. **渲染层生长与稳定完成状态**（3bc7fa40）：用自然高度布局，在滚动内容容器layer上施加可续接的additive平移；原0.14s线性、120Hz preference、拖动暂停/短内容门控、重挂载高度基线及完成反馈保留。用值Preference合并pending标志，避免每字构造transformPreference闭包。呈现连续性与整轮2/2、完成反馈等7/7先前通过，最终必要回归另记。没有改模型层transform、scroll contentSize或contentOffset。

## 数据库热点的证据

辅助线程的旧真机CPU捕获中，listAllRuns包含子调用占21.761s、全进程样本37.38%；该trace跨闪退/重启，不能将37%当本版收益。当前源码的七个调用点确实只消费少数字段。已有真机DB导出经只读聚合有1683行、capability_snapshot共5580134字符、单行最多4288字符；input_snapshot_ref均空。本轮没有读取或输出字段正文。

- 真实Room/BundledSQLite测试用12行×32KiB无用快照，返回ID、字段、nullable值和同时间戳顺序等价；实际getText字符由394393降为summary501/notice571。
- Swift同二进制合成压力对照300行×64KiB，预热后各读取3次：全量CPU17.840922s/wall14.892632s；投影CPU0.045533s/wall0.032080s。采样footprint峰值166.86MiB/164.97MiB，RSS峰值617.22/616.22MiB；同进程顺序执行，内存峰值不能作为分配量下降的证据。
- 与真机已有DB相同数量、平均长度的脱敏fixture（1683行×3316字节）结果见最终测量一节。合成数据不包含真实提示词、密钥或用户正文。

## 整轮对照的测量边界

测试包含发送、捕获搜索/工具内容、正文reveal、最终完整文字显示和实际贴底稳定1秒。输入固定1928 UTF-16正文。原始私有输入不进Git、Library、云端。

原先测试开第二个UIWindow，会把原欢迎页动画留在下面；新测量显式替换keyWindow root，结束恢复原root/frame。修改测量宿主带来的差异不计为产品收益。相同独占宿主基线与候选如下：

| 版本/实验 | 整轮秒 | 主线程% | 最长间隔ms | >50ms |
|---|---:|---:|---:|---:|
| bc73dd1b 独占宿主基线 | 13.199 | 45.00 | 207.02 | 7 |
| 原生CA生长，修改测量宿主前 | 13.242 | 41.07 | 200.62 | 6 |
| CA+值Preference，独占宿主 | 13.106 | 39.37 | 214.35 | 5 |

这些是单轮方向性结果，存在进程/缓存噪声，不代表设备实际120Hz；最大间隔仍远高于50ms。上表的DAO查询压力没有进入纯时间线回放，不能相加收益。最终必要回归同进程结果另记，不能将暖缓存内存与新进程基线强行归因。

## 已撤回的实验

- 单/多Markdown节点直接发布：节点测量减少但整轮约41–45%，没有足够收益，撤回产品代码。
- 去外层scrollTargetLayout、chunk geometryGroup：约40%/187–200ms，未证明整体改善，撤回。
- 完整assistant turn缓存：43.79%/224.83ms，且variant边界新用例失败，撤回；两个既有投影用例也失败，未将整组称绿。
- 复用历史renderToken：42.54%/211.64ms，没有整体收益，撤回。新增fixture对同一tool输出写Swift空metadata map后，经KMP metadataString发生SIGSEGV；此路径不在最终产品diff中，不把它与用户先前真机闪退混为一谈，原诊断包保留。

精确首发送sample只有20个主线程点，其中14点在projection、13点在build、5点在工具分组。它可提出候选，但候选对照未证实整体改善，因此没有留下额外分组/签名缓存。尾部CPU样本以SwiftUI Graph更新为主；body=0不等于布局依赖传播=0。S7/S8以及吐字时钟方案没有擅自实施。

## 复现命令

```sh
./gradlew :core:agent-store-room:jvmTest --tests app.amber.core.agent.store.AgentRunProjectionTest --console=plain
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath iosApp/build/StreamingPerfBaseline -parallel-testing-enabled NO \
  -only-testing:iosAppTests/SubAgentConcurrencyPerfTests/testRunSummaryProjectionCostOnCapturedDatabaseShape \
  -only-testing:iosAppTests/ChatSearchCaptureReplayTests/testCapturedInvalidationFanout \
  -only-testing:iosAppTests/ChatSearchEndToEndReplayTests/testEveningCapturedRoundThroughVisibleCompletion test
```

三轮e2e本次未重跑。只在最终跑项目要求六组一次，加扇出、相关完成反馈和上述DAO规模定点。详细结果、签名与推送见下节。

## 最终测量与交付

产品HEAD为3bc7fa40，包含78e2ce2b、8583684c。最终必要回归结果包 `final-native-ca-required.xcresult`：106通过、6个已记录基线失败、无跳过。失败为续答间距、工具轮胶囊间距、24KB吐字合并阈值、长推理完成、历史尾行解除冻结、推理终态收缩；未改断言。连续首两行呈现与原滚动保护通过，未新增失败。此前独立测试28/28与Kotlin1/1证据继续复用，没有全量测试。

| 最终测量 | 独占宿主bc73dd1b基线 | 最终组合（必要回归同进程） |
|---|---:|---:|
| 发送→末字+真实贴底稳定1秒 | 13.199s | 13.167s |
| 主线程 CPU | 45.00% | 40.38% |
| 进程 CPU | 7.193s | 6.162s |
| 最大帧间隔 | 207.02ms | 163.23ms |
| >50ms | 7 | 4 |
| 起始footprint | 190.63MiB | 193.22MiB |
| 采样峰值footprint | 225.38MiB | 224.55MiB |

末字于12.120s可见，13.167s贴底确认完成，1928 UTF-16无截断。没有缩短吐字或跳过贴底。没有把组合与单轮噪声说成严格单变量因果。没有三轮稳定性/热降频/真机120Hz新证据。

当前真实生产时间线扇出窗口挂载95条历史行：token、工具、进度和换行增长的历史body/sizeThatFits请求/实际测量/placeSubviews全部为0。换行历史placement从先前380降为0；当前尾行仍每字实测4次，增长窗口实测51次/16tick，是未解决成本，不能说布局已经完全优化。

按已有DB规模的脱敏Room查询对照：1683行×3316字节，各读3次；CPU6.031091→0.241176s，wall4.657292→0.184178s，约25倍；ID/顺序相同。footprint174.16→174.07MiB、RSS874.30→873.69MiB，顺序采样无显著峰值下降，不宣称内存已解决。该查询压力并未进入上表纯时间线回放，因此两项收益不相加。

脱敏摘要与原始JSON SHA256在 [evidence/ios-streaming-hotspots-2026-11-07/summary.json](evidence/ios-streaming-hotspots-2026-11-07/summary.json)，原始对话/数据库/诊断留本机忽略目录。单文件主时间线1486行。当前不准备装机，也不新连手机；手机安装基线349128d5/seq2872仍含震动修复。

性能总目标未完成：结构事件仍有>50ms长帧，reveal阶段SwiftUI Graph更新和尾行多次测量仍占CPU。此前明确暂不做S7/S8；本轮没有擅自替换列表或引入增量解析器。下一阶段需要针对默认列表/尾行依赖传播选择结构对照，不能再把闭包、offset、分组缓存这类小改动重复当全局解决。
