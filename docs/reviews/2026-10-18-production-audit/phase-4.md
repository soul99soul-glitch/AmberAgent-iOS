# 第 4 阶段：小说修复与回归收口

N1–N5 已完成：分支删章不再废弃共享章节，四条写入路径保留或重建逐章剧情，失败 run 保留精确重试链，流式正文保留 raw 围栏上下文，reasoning 明确区分 delta 与 replacement。

首次扩展检查的失败与根因完整保留在 [集成记录](phase-4-integration.md)。校验器收口后，`NovelDocumentValidationTests` 38、`NovelDomainIntegrityRegressionTests` 5、`NovelManualEditSyncTests` 23、`NovelWorkspaceRepositoryTests` 24 共 90 项实际全部通过；未修改正文数量期望来掩盖问题。

其余未再变动的 Novel 流式、adapter、领域、生命周期和重试相关测试已在前一轮通过；Native Timeline/viewport 六个必跑 suite 的 96 项亦通过。外部真机项目包未提供的一项 ledger 检查保留原跳过条件，不伪造数据。

[首次独立源码复核](reviews/phase-4-independent-review.md) 与 [实测失败后的独立收口复核](reviews/phase4-followup-independent-review.md) 均留档。后者重点核对两个 validator 的强约束、历史 undo、显式全局 discard 对照，以及正文与剧情文件各自的断言。

独立 Novel 应用已使用最终 Shared.framework 与同一组小说生产源完成 [build-for-testing](novel-consumer-build.status.json)（exit 0），随后 [全量测试](novel-consumer-green-summary.json) 实际执行 1059 项：1057 通过、2 跳过、零失败。两个跳过项分别依赖未提供的 `/tmp/amber-novel-device/project` 与 `/tmp/amber-repro-pkg` 真机项目包，保持原条件，未补造数据。分组见 [suite 结果](novel-consumer-green-groups.json)。上述结果不代表真实 provider、物理设备长文手感或后台系统能力验收。
