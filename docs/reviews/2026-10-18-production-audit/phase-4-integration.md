# 第 4 阶段集成检查记录

首次扩展回归：512 项中 503 通过、8 失败、1 跳过。不能按源码 review 的 PASS 提前宣称阶段完成。

失败根因：

- 分支删章移除全局 `discardedAt` 写入后，两处既有校验器仍要求该全局副作用，四项新旧测试因此被文档校验拒绝。校验器必须与分支局部操作的合同同步，并检查目标章节记录保持不变、精确移除目标 selection、workingRevision 增量和 outcome 对齐。
- 四项 workspace 测试用 `contains("/chapters/")` 统计正文，同时计入了修复后恢复的 `plot/chapters/*.md`。应按正文规范路径统计并独立核对剧情文件，保留原正文数量断言；不将 2 改成 4 来绕过失败。

本轮通过的证据：六个 Native Timeline/viewport 必跑 suite 共 96 项通过；Markdown 解析、渲染与代码块 46 项通过；消息投影与 hash 44 项通过；后台 partial/MiniApp 终态 6 项通过。小说流式六项、adapter 33 项和其余相关领域/生命周期测试通过。逐 suite 结果见 `phase4-rendering-green-groups.json`。

唯一跳过项为 `NovelWorkspaceLedgerTests/testApplyRelinkOnDeviceZhaoDaPackage`，依赖未提供的外部项目包；未删除、改阈值或补假数据让其通过。

最终收口与后续 green 以 `phase-4.md` 为准。
