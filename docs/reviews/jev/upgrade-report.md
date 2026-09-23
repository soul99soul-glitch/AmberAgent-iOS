# Jev 升级执行报告

日期：2026-09-24。依据：`docs/product/jev-upgrade-plan.md`。本报告把源码/离线验证、真实 Jev API、模拟器和真机证据分开记录。

## 代码状态

| 阶段 | 状态 | 主要变更 |
|---|---|---|
| Phase 0 | 源码与模拟器验证完成 | 模型题目使用候选 UUID；客户端本地拒绝重复题目 ID；工具发现的关键词回退改为惰性执行，active 只应用 ranked 暴露。真实 API 延迟基线仍待 Key/蜂窝网络。 |
| Phase 1 | 源码与模拟器验证完成 | `decideBatch` 按 part 分别检查模式和范围、分节出站、分回答案；active/shadow 独立通道；等待预算与网络 deadline 分离；迟到结果只进缓存/指标；策略 v3 迁移 active 到 shadow；内容型缓存键；设置/Key 变更 epoch；内存指标缓冲并批量落盘。 |
| Phase 2 | 源码与模拟器验证完成 | T1 记忆 Score 与注入 Noul 同请求并提前启动；T2 输出投影按会话/调用/内容/策略固定并重放；T3 spawn 一次请求合并模型、角色和对齐题，followup 仅模型题。 |
| Phase 3 | 源码与模拟器验证完成 | 工具发现增加用户原话和合适工具题；记忆筛查阈值 0.8；上下文块合并及结构化强保留；模型事实及单独数据范围；审批优先静态事实；网页候选/state 对齐、handback 与工具说明更新。 |
| Phase 4 | 主要 UI 与模拟器视觉验证完成 | 推荐配置需确认，五用途设为 shadow；用量区展示已采集的逐用途差异、等待与回退；当前会话的 composer 用量面板展示本轮 Jev 摘要。缺数据的指标显示“暂无数据”，具体未采集口径见下文。 |
| Phase 5 | 待真实观测 | 需要 Key、3–7 天 shadow 样本和真机蜂窝/弱网/后台证据。尚未逐用途改为 active。 |

## 外部契约与资料核对

[TypeSafe 官方 API 参考](https://docs.typesafe.ai/api)把 `questions` 定义为题目 ID 到题目的映射，Choice 最多 255 个选项、Score 最多 10 级；页面未公布单请求总题数上限。代码保留本地 `policy.maxQuestions = 32`，超过时拆批并行，不把 32 表述为供应商限制。

记忆筛查没有按 `kind` 排除：`IOSMemoryExtractionCoordinator.save` 允许的 user/feedback/project/routine 内容来自用户原话；手动编辑可保存 note/project 并保留或修改 kind；`memory_tool` 可在审批后写入显式 kind；topic 由现有记忆汇总，仍可能包含偏好。现有 `sourceConversationId`/`sourceMessageIds` 只记录来源关联，不能证明某 kind 不含用户偏好。

## 验证分层

- KMP：`:ai-core:jvmTest` 118 项、`:feature:tools:api:jvmTest` 28 项、`:shared:jvmTest` 38 项通过，失败/错误/跳过均为 0；`:shared:linkDebugFrameworkIosSimulatorArm64` 通过，Swift 头文件导出审批静态事实接口。
- iOS 模拟器：`/private/tmp/jev-upgrade-focused-6.xcresult` 实际执行 453 项，453 通过、0 失败、0 跳过。包含 Jev 定点、模型池/记忆/压缩/后台/ledger、聊天滚动回归及设置/审批视觉证据；目标为 iPhone 17 Pro、iOS 26.5、arm64。已目视检查设置页默认、320pt AX3 和 composer 摘要截图，未见重叠或截断。
- 真实 Jev API：本次未取得可用于合成压测与冻结集对比的 Key；1/8/32 题、两种 API 形态、Wi-Fi/蜂窝各 30 次的 p50/p95 基线未执行。等待预算采用文档允许的临时 400 ms。
- 真机：未取得蜂窝、弱网、锁屏/后台的运行证据；不能由模拟器推断真机验收。

## 逐用途启用结论

| 用途 | 当前结论 | 待补证据 |
|---|---|---|
| 工具发现 | 保持 off；用户可手动加入推荐 shadow | 真实 API 的 Recall@5、下一步工具调用与暴露集合比较。 |
| 记忆召回 | 保持 off；用户可手动加入推荐 shadow | 真实任务收益、偏好误报、首字时延。 |
| 模型调度 / 意图路由 | 保持 off；用户可手动加入推荐 shadow | 真实子任务完成率与负载选择差异。 |
| 上下文筛选 | 保持 off；用户可手动加入推荐 shadow | 必要证据漏失、隐藏后重读率、prompt 缓存命中比例。 |
| 审批分诊 | 保持 off | 静态事实与真实审批样本一致性。 |
| 网页操作 | 保持 off | 冻结网页集、真实账户/真机动作与 handback 率。 |

所有用途默认仍为 off；推荐配置仅在用户确认后设五用途 shadow，不自动批准、拒绝或启用 active。

## 已知限制

- 为保证当前会话历史中已应用的上下文投影逐字节不变，长会话仍存在的输出决策键可能超过 `cacheMaxEntries`；超出可用容量的新输出固定为全文，不继续外发。
- 数字指标已覆盖首个可见流式 chunk、模型步骤、缓存命中比例、T1/T2/T3 等待与 late/drop、工具 top1 差异、记忆 ID 重合/筛查命中、上下文隐藏占比、模型与角色选择差异、网页 handback/完成率。尚未自动采集“新暴露工具下一步是否使用”、隐藏后重读率及子任务终态成功/失败/超时；这些门槛在 Phase 5 评估前仍需补齐，面板对缺数据项显示“暂无数据”。
- 未有真实 Key 与冻结集时，逐用途收益、校准阈值、缓存命中不下降等结论无法建立。Phase 5 的 active 启用门槛尚未满足。
- 仓库中原有 provider/Codex 登录改动属于独立工作，未作为 Jev 升级提交范围。
