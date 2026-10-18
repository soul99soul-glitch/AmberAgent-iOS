# Phase 3 集成验收

Phase 3 已完成。独立审查分别见 [Runtime 与调用链](phase-3-runtime-review.md)和 [渲染与 UI](phase-3-ui-review.md)；原 13 个生产大文件和六个大测试 suite 已按职责拆分。当前物理行迁移门禁为 1150 个 Swift、48 个存量超限、0 个问题，本期解决 19 个超限项。

327 个原测试方法各实际执行一次，321 个正文逐字节一致，六个固定源码 guard 按真实 owner 更新；152 个非测试 helper/type/fixture 均有完整审计。r10 主集成结果保留为 1466 passed / 7 failed / 2 skipped；两项源码路径断言修复和原 40ms 表格 canary 定点复跑 3/3 通过。四项未改动的 Novel fixture 失败有现有领域过滤契约证据，作为 Phase 4 基线处理。不能把定点复跑写成 r10 全量通过。

本期另修复实际截图确认的既有空聊天欢迎态重叠：移除非内容的 bottom180 留白，将欢迎装饰放在 Native 列表的可用视口 overlay，空间不足时不绘制欢迎态。empty 投影、底锚、driver、offset 和消息跟随状态不变。用户原有 ChatMiscViews WIP 已先单独快照，除这项调整和标识的 AX 测试定位外保留原内容。

- 独立 Novel ARM64 模拟器构建通过：`/tmp/amber-phase3-novel-build.log`。
- 实际产品聊天输入、系统英文键盘、附件菜单及几何通过 1/1：`/tmp/amber-phase3-navigation-overlay.xcresult`；三张截图位于同名前缀的 `-attachments` 目录。
- 最终六个强制 Native/viewport/replay 类通过：96 passed / 0 failed / 1 原手动采样 skipped，`/tmp/amber-phase3-scroll-overlay.xcresult`。前一轮 padding-only 的 first-line 51.67pt/48pt 失败仍保留历史；原基线曾同样失败，最终复跑未调整阈值。
- 迁移后 20 张布局图、九张迁前对应图与三张实际产品图已由独立 reviewer 检查。最后修复的三态截图也已复核。

附件态未绘制的欢迎候选仍出现在 AX debugDescription，尚无 VoiceOver 聚焦验收。模拟器构建、测试与截图不代表真机中文 IME、真实 provider、系统后台或 120Hz 性能验收。后续按 Phase 4→6 继续，未提交或推送。
