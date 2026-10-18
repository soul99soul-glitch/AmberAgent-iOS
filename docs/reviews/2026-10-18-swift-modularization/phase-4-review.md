# Phase 4 — Novel 职责拆分与验证

状态：完成。最终 Main 64/64 与独立 NovelTests 1045 passed /0 failed /3 原 skipped；运行链和 UI 独立 review 均通过。Phase 5 可正式开始。

原 16 个超限生产文件与 12 个大测试文件均已按领域、运行、投影、界面和测试职责拆分。Session 的 binding/run/FIFO/terminal drain、Creation 的 actor/attempt、repository 的提交 writer、编辑字段的 IME/dirty/revision/save task 继续由原实例拥有。此次没有迁移观察框架、持久化格式或发布独立 Core 制品。

迁前快照 `/tmp/amber-phase4-source-baseline` 包含用户 WIP。Session/Generation/Domain/UI 四份迁移清单、两个测试方法映射和完整 helper 审计均归档于本目录。347+241=588 个迁移测试在 Main r2 全部被实际发现且各执行一次，587 passed、1 个原手动采样 skipped。提示文本的 50 个 kind/version 组合中，46 个 UTF-8 内容摘要与迁前相同，其余 4 个保持原 nil。

## 失败复核与精准修复

Main r2 共 1221 项，1205 passed、12 failed、4 skipped。保留该次结果，不将其记为通过。8 个非迁移 suite 的失败在隔离的完整迁前 Novel 消费者树中全部复现；成员及源码 SHA 见 `phase-4-baseline-eight-source-proof.json`，断言原文见 `phase-4-baseline-eight-results.json`。

- Batch 4 项是已有可达生产竞速：采用中间章后，workspace 自动接受后续 stale 剧情记录仍占用操作锁，下一章便开始正式生成。只在每章 durable refresh 后等待既有 task，并在等待前后核对取消、binding token、项目和分支；不新增 writer、重试或绕过 gate。
- 3 项 repository fixture 仍读写旧 `projects/<id>.json`，改为实际 `layout.json` / `previous-layout.json`；只读、显式恢复、账本及损坏证据保留断言逐条不变。
- Chapter replacement fixture 在两次 without-sync 收录后请求正式整章生成，触发正确的 needsSync 禁令。改用绑定当前 head/source version 的文档层候选，继续真实收录、替换和同步 reducer；原断言保留，并补充最终事实重建检查。
- 一个原导出测试藏在 repository 测试替身 actor 内，从未被 XCTest 发现。完整方法与注释逐字移回实际 XCTestCase extension，focused 已确认执行并通过。
- 新建 unit hosting 布局探针无法取得任何 AX 元素。移除该探针中不可工作的 AX 激活设施，保留渲染、真实滚动和 viewport 几何检查；截图与实际页面点击分开留证，没有据此改产品按钮。
- Main r3 暴露另一项既有恢复竞速：恢复等待 lease 时，旧本地 stream 的结束回调可能误报 `stream_ended`。新增回归用初始 stream 的第二次 pull 与 lease 屏障固定交错；迁前红测 r2 唯一失败为恢复请求 0≠1。只给现有 actor runtime 增加本地 stream 身份，在 detach 后撤销旧回调权限，并校验断连重连及 sidecar 后的身份；不提前取消 durable response，也没有新增重试。

定点结果 `/tmp/amber-phase4-focused-r1.xcresult`：19 项中 16 passed、3 新布局设施 failed。通过部分包括 Batch 全 10 项、上述 4 个 fixture、导出方法及原 48pt 阈值的首段 Native 滚动用例。新探针修正后，`/tmp/amber-phase4-stream-red.xcresult` 的 3 个布局用例、原 40ms 表格 canary、五章/十章代笔及旧 late-detach 共 7 项通过，新增恢复回归作为红测失败。校准真实消费屏障后的单例红测 r2 仅在恢复请求 0≠1 失败；生产修复后 `/tmp/amber-phase4-generation-green.xcresult` 的 generation/recovery/disconnect、代笔、批量润色、源码接线共 127/127 通过。

Main r3 共 1254 项，1247 passed、3 failed、4 skipped。原 1024 个 Novel 方法全部各发现一次，无遗漏/重复；一项 late-detach 已由上述红转绿覆盖。表格 canary 当次 P95=44.72ms>40ms，Phase3 也曾同类失败；源码与可达渲染路径未变，后续同阈值定点通过，保留不稳定记录，不归因为环境噪音。独立 Novel r1/r2 中五章或十章代笔曾停止于第二章启动前。失败诊断确认上一章 durable 已完成、branch activeRunID 已清，但 Session 的旧 tail 仍占启动门禁。修复复用已有 300ms 可取消候选等待：等原 consumer 完成终态展示和 durable handoff 后再继续；保存失败仍走原失败 grace，离页仍走原 start gate 与暂停路径。不等待整个 consumer Task，不新增状态机、重试或计时器。最终 Main 64/64 通过，新增长生成交接回归也在独立 NovelTests 全量通过。

## 构建与界面证据

- 独立 Novel ARM64 production build r4 成功，build-results 为 succeeded、0 errors；`/tmp/amber-phase4-novel-build-r4.xcresult`。
- 实际 Home→小说创作→本地项目→创作/正文/设定→项目控制的 UI 用例 1/1 通过；7 对 PNG/AX 已由独立 reviewer 检查。三个页签的中心 ±21pt 实际点击均切换到目标页，不能仅按 AX 标签 38pt 高误判触控区域。
- 最终 unit render 范围为 320/393pt × large/AX3：candidate 底部 4 图、Ask User 顶/底 8 图、收录表单 editor/真实末尾 8 图。三项渲染探针通过，独立 reviewer 已逐张看完 20 图并签字；该探针不验证 AX 激活、物理触控或 onAction。索引见 `phase-4-final-layout-artifacts.json`。
- 独立 NovelTests r2：1047 total /1043 passed /1 十章代笔 failed /3 原 skipped；该次失败保留。r3 完整通过：1047 total /1044 passed /0 failed /3 原 skipped，包含最终布局和新增 stream 所有权回归。该结果在最后无 consumer 刷新退役布尔修正之前取得；最终 r4 全量为 1048 total /1045 passed /0 failed /3 原 skipped，最终 Main64 也全数通过。独立 Novel 的 1022 个原方法各执行一次、无遗漏重复；两个 Main-only Amber Settings 方法已在 Main r3 通过。

运行链独立审查见 `phase-4-runtime-review.md`；UI 独立审查见 `phase-4-ui-review.md`。模拟器构建、单测、截图和导航不替代真实 provider、真机中文 IME、VoiceOver 或实际系统后台验收。

最后原方法发现核对：独立 Novel1022/1022，1019 passed/3原skipped；2个Main-only AmberSettings桥方法保留在主App并于Mainr3通过。见`phase-4-final-novel-discovery.json`。
