# Standards 审查

范围：HEAD b98bd6f0f2f82dd9492ff021e53d03bfe26d2dce 到当前 WIP（包含相关 untracked）。只读审查根、iosApp 与 NovelCreation 的 AGENTS，未读 vendor。

## 结果

未确认本轮新引入、具明确行为/维护后果的 Standards 缺陷。主要差异是职责文件迁移、访问级别调整，以及独立 target 清单和测试入口同步；不将这些本身判为 Feature Envy、Middle Man 或 Shotgun Surgery。ChatView 对原始 messages 的读取位于事件方法，body 使用可判等 chatListSummary；环境闭包采用稳定 handler；共享列表生产入口仍为 NativeChatTimelineView。

## 现存规则问题（非确认功能 bug）

`iosApp/iosApp/DeepRead/IOSDeepReadTaskDetailView.swift:581-584,626-635,762-767` 对同一 structuredJSON 同步 JSONDecoder 解码。body:71 → coverImageURL；body:81 → masthead:281 → kicker:555 → decodeStructured；body:88 → content:359 → articleContent:369 → articleHTML:742 → editorialHTML。违反 iosApp/AGENTS.md「body 及 body 读取的计算属性内禁止磁盘 IO、JSON 解码」。closeReading/templateArticle 已按 task 变化缓存，普通 IOSDeepReadOutput 未同样缓存。

二次复核：HEAD 的 iosApp/iosApp/BoardView.swift:1051 起原 IOSDeepReadTaskDetailView 已有相同实现，属现存规则违例，非模块化回归；未经性能测量，不能推定可见卡顿或按功能 bug 排优先级。最窄改法是将普通结构化结果纳入现有 onChange(task) 缓存；性能类变更应附前后测量。本任务未运行构建/测试。
