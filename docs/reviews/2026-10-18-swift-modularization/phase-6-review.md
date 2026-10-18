# Phase 6：严格门禁与全产品验证

> 本报告是模块化完成时的快照。后续经用户授权精简测试，当前清理与验证结果见 [必要测试清理](../2026-10-18-test-cleanup.md)。

状态：Phase 0–6 全部完成。最终消费方门禁、独立运行链、UI、测试发现和WIP审查均通过，证据边界见末节。

## 最终结构

原952个Git可见Swift中，51个业务文件和29个测试文件超过1500行，最大8429行。当前1318个（业务765、测试447、vendor106），全部不超过1500；最大为未改的 `AmberThemePack.swift`（1500），测试最大1490。总物理行549292，含空行、注释及多行字符串，不靠压行达标。完整文件/SHA清单见 `phase-6-final-swift-inventory.csv`。

这是现有target内部按职责组织的逻辑模块。入口、状态与副作用owner、测试入口、共享target约束见 [模块导航](module-guide.md)；`Shared.framework` 仍由本仓Gradle工程生成。没有为拆文件复制运行状态、添加通用context或引入新的模块发布框架。

Phase6仅拆剩余五个大测试文件、迁移日志源码guard并收口CI。Phone228个原测试、Parity/Skill99个原测试保留原类与方法ID；另有89个helper函数、24个支持类型逐项映射，fixture registry、actor、tempDirs与async tearDown保持唯一owner。327个方法中326个正文SHA相同；唯一日志guard从旧Board聚合文件改查Hotlist/DeepRead真实owner，原7个日志marker、DEBUG判断helper及断言保留。详见两份 `phase-6-*-test-moves.json` 和 `phase-6-phone-test-audit.json`。

迁移baseline文件已移除，CI无条件运行 `python3 scripts/check_swift_file_lengths.py`，无文件或vendor豁免；门禁4项单测通过。保留的本地baseline参数不参与CI。Shared导出检查确认10组Swift消费类型均在Shared.h。

## 实际验证

| 门禁 | 当前证据 |
| --- | --- |
| 严格物理行检查 | 1318文件，0超限，0问题 |
| Phone SwiftPM | 105/105通过；104Client+1Timing唯一发现，独立日志审查通过 |
| Main全部iosAppTests | 最终r6：5089项，5073通过、0失败、16跳过；SavedTasks16项与IUI原生AX交互实际通过；`/tmp/amber-phase6-main-r6.xcresult` |
| 独立NovelTests | 最终r2：1048项，1045通过、0失败、3原跳过；`/tmp/amber-phase6-novel-r2.xcresult` |
| 独立DeepReadTests | 109/109通过；`/tmp/amber-phase6-deepread-r1.xcresult` |
| GPL及Watch/Widget/ActivityWidget/PhoneTunnel构建 | GPL及其依赖构建exit0；`/tmp/amber-phase6-gpl-r1.xcresult`，仅构建证据 |
| 最终六条实际导航 | 6/6通过；真实截图与AX已有独立复核，`/tmp/amber-phase6-navigation-r1.xcresult` |
| 原测试清单与实际discovery | 最终r6/r2联合审计通过：原341文件/5368方法名归档；1612项映射+actor发现修复1项；跨Main/Novel/Phone2202个观察全部找到，2198通过/4原手动性能跳过，缺失、重复、声明和target membership缺口均0，见coverage-final |

旧测试最初未配置target的 `AmberControlUITests` 仍按原状保留，未添加到runner制造“全发现”数字。P4原本写在actor里的export测试已迁回真正XCTestCase扩展，并要求实际发现。当前文件有声明、映射和target membership只是静态证据，不能代替实际执行；最终审计同时核对同包重复ID及缺失项。

Main r3 中，Novel foreground取消测试等待的请求continuation没有生产者。现场存在其他测试残留的受保护租约，与测试默认读取全局租约后、生命周期守卫跳过中断的路径一致；缺少守卫内部日志，不能唯一确定命中入口还是expire分支，原五秒deadline也是另一可达早退。线程采样未发现Novel忙循环。修复仅隔离该测试的租约依赖与无关deadline，用现有eventually在两秒内明确报告缺失请求，并在断言前清理cycle/gate；原foreground取消和无中断断言保留，生产保活规则没有改变。ViewModel与生命周期接线整集75/75通过，独立源码审查见 [fixture复核](phase-6-novel-gate-fixture-review.md)。历史迁移SHA保留，当前正文例外另记 `phase-6-novel-gate-fixture-repair.json`。

无诊断Main r4执行5089项，只有原始BatchPolish测试1项失败；该测试仅等占位runID就切分支，并忽略选择返回值。修复使其等待已有session启动状态与真实分支按钮相同的选择门禁开放，再明确断言`.selected`；原binding、progress、请求次数与durable run状态断言全部保留。独立审查见 [Batch fixture复核](phase-6-batch-polish-fixture-independent-review.md)。两项fixture均在最终Main r6和Novel r2通过，生产选择及保活规则未改。

完整失败历史保留：r1为15项失败，r2为12项SavedTasks首次AX查询失败；r3 SavedTasks通过但存在Batch失败及Novel无界等待，Root中止；r4仅Batch失败；r5没有实际用例，日志显示test daemon not ready，Root中止后出现ResultKit收尾写入错误。保留数据重启模拟器后，r6完整通过。早期AX差异没有唯一可证实触发原因，未保留诊断、放宽标签、增加跳过或采纳独立test bundle候选。

## 分期审查

[Phase 0](phase-0-review.md)、[Phase 1](phase-1-review.md)、[Phase 2](phase-2-review.md)、[Phase 3](phase-3-review.md)、[Phase 4](phase-4-review.md)、[Phase 5](phase-5-review.md)均先完成实现、实际门禁和独立复核，再进入下一期。最终独立证据见 [运行链](phase-6-runtime-review.md)、[UI](phase-6-ui-review.md)、[测试发现](phase-6-coverage-final.md)。全部subagent按用户要求使用 `gpt-6-sol` / `high`。

## 保护与证据边界

独立 [WIP审查](phase-6-wip-review.md)核对原HEAD→原WIP→当前调用链。26个原WIP文件逐字节一致；八个tracked混改及原untrackedSwiftLint配置按原意逐项核对。初始untracked CSV缺内容快照，只能确认仍存在，不能声称逐字节校验。最后构建完成后，vendor Package.resolved已精确恢复原HEAD字节（SHA-256 `897e3291769528073e3ec4e93a99a32209b7ed26c16f91155d5e304a468e9439`）。最终对账确认HEAD/index未变。改动保留在 `codex/swift-modularization-1500` 工作区，未提交、推送、合并或发布。

模拟器截图、AX和本地fixture不证明真实provider、SSH认证/信任、OS权限、物理设备触感或系统后台执行保证。Phase6没有追加产品UI改动；最终UI审查复用Phase5已签图与六条真实导航结果，按实际范围记录。
