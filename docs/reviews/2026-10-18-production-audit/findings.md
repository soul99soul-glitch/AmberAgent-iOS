# 问题清单与多阶段修复计划

当前状态：本轮 37 项确认问题的修复、七阶段独立审查与有限可维护性检查已完成；Search/Home v2 真实模拟器交互已通过。最终集成新增的 MCP-1 已有真实三调用 RED，修后 Client/Manager 51/51 通过。最后一次完整运行的唯一失败为 Quick Start fixture readiness，修正后整组 8/8 通过，生产源码未变，保留整轮 Failed。表格性能门禁多次真实失败，运行状态和采样窗口有明显影响，产品根因仍未定；未据机制猜测新增问题编号，也未将其判为彻底假阳性。无收益的表格实验及临时诊断均已恢复原始字节。各消费方和最终组合结果见 [verification.md](verification.md)。完整证据及排除项见 [reviews](reviews/)。

| 阶段 | 范围 | 问题编号 | 精准修改边界 |
| --- | --- | --- | --- |
| [1](phase-1.md) | 数据、配置与 provider | S1 / S2 / CRED-1 / CRED-2 / KMP-01 / KMP-02 / PHONE-1 / PHONE-2 | 会话消息写入占用、PPTX数字排序、模型凭据事务、拒答文本、Gemini参数名、键盘操作范围和人工接管门禁 |
| [2](phase-2.md) | MiniApp 与系统权限 | MINI-1–6 | 数值转换崩溃、图片DOM自激、定位/日历/联系人授权范围、失信文档释放订阅 |
| [3](phase-3.md) | 聊天后台与 Markdown | C1–C7 | durable续跑/轮次身份、partial与MiniApp终态及Workspace、表格转义与fence语法 |
| [4](phase-4.md) | 小说事务与流式 | N1–N5 | 分支删章、逐章剧情snapshot、失败run重试、正文围栏分包、reasoning增量语义 |
| [5](phase-5.md) | 工具编排与 WebMount | T1 / T2 / WM-1–3 | 本轮child输出、可执行候选、多local恢复、真实刷新与原样文字输入 |
| [6](phase-6.md) | Search、Watch 与 DeepRead | PLAT-1 / PLAT-2 / SYS-1–3 | 导航任务归属、首页提交查询保全、旧run审批隔离、Workspace失败标记、损坏历史禁止覆盖 |
| [7](phase-7.md) | 最终集成暴露的并发边界 | MCP-1 | Client 请求队列内原子重连，保留 Manager 既有只读重放规则 |

每阶段流程：失败测试/复现 → owner 内修复 → 受影响测试 → 未参与实现的 subagent review → 必要收口。无关阶段不重复全量测试，最后按实际影响面验证共享消费方。

## 额外问题编号

- PHONE-1：dismissKeyboard 未检查当前应用范围，type 后自动收键盘也可触发。Root 已取得失败测试。
- PHONE-2：type 等待期间用户接管或取消，返回后仍自动发收键盘动作。
- MINI-1–6 对应 [MiniApp 报告](reviews/audit-miniapp.md) 的六项，独立二次复核全部接受。

## 不计为产品缺陷的项

- MCP 原并发过期测试的 plain HTTP 404：固定 FIFO 响应脚本加 20ms 延迟预设了不保证的顺序，属于测试假阳性；[夹具诊断与修正](reviews/mcp-concurrent-expiry-fixture-fix.md) 保留全部业务断言。与真实 Client 三调用 MCP-1 分开计。
- KeepAlive 的一次重试断言：固定等待 100ms 不保证 retry Task 已开始，属于测试假阳性；[独立复核](reviews/keepalive-submit-retry-fixture-review.md) 后仅修事件等待，整组 43/43 通过，生产重试策略未改。
- Novel quick-start 接受建议测试：只等四条建议进入快照，可抢在初次操作锁释放前调用接受；真实 UI 在该窗口禁用写入。[诊断](reviews/novel-quickstart-ready-diagnosis.md) 与 [独立复核](reviews/novel-quickstart-fixture-independent-review.md) 支持夹具竞态，仅补齐到 idle 的就绪条件，保留真实接受及分支落盘断言，整组 8/8 通过。原失败未采集当时锁状态，不冒称该次直接取证。
- Native 长表格帧时长：失败数值真实，但运行状态和采样窗口影响明显，[独立判定](reviews/final-table-performance-adjudication.md) 未确认独立产品根因，也未称彻底假阳性。无收益实验已撤回，最终组合中的原门禁已实际通过，保留原阈值和全部失败记录。
- 删除当前模型后不自动改选：UI 明确要求重新选择，属于现有设计。
- DeepRead body 内 JSON 重复解码：现存规则问题，未经性能测量，不称为确认卡顿，不顺手追加性能重构。
- KMP metadata/import 的同步 IO：线程路径有依据，缺运行测量；仅列验证候选，不据此宣称用户可见卡顿。
- completed 小说历史裁剪：有明确性能设计，当前仅修有重试消费者的 failed run。
- 真机、系统后台、权限、真实 provider 未验收本身不等于代码缺陷。

## 验证和保护

基线所有 Git 可见文件 SHA256 与 tracked WIP patch：`/tmp/amber-audit-20261018-current/baseline-files.json`、`baseline.patch`。Root 统一串行构建；不提交、推送或发布。修改完成按基线核对实际改动范围。

## 逐项问题列表

| 编号 | 用户影响与根因 | 证据 |
| --- | --- | --- |
| S1 | 并发分支操作或普通消息保存，用旧整份快照覆盖前一次成功修改。 | [调用链与反证](reviews/audit-storage.md) |
| S2 | PPTX 文件名末尾是 .xml，页码解析恒为 0，正文随 ZIP 条目顺序错排。 | [调用链与反证](reviews/audit-storage.md) |
| CRED-1 | 模型凭据写失败仍返回未提交配置，编辑页可能关闭并选中不存在模型。 | [调用链与反证](reviews/audit-credentials-backup.md) |
| CRED-2 | 删模型或换目录在事务提交前删 Keychain，后续失败回滚不能找回原凭据。 | [调用链与反证](reviews/audit-credentials-backup.md) |
| KMP-01 | OpenAI Responses / Chat Completions 的 refusal 被吞成空答复。 | [调用链与反证](reviews/audit-kmp.md) |
| KMP-02 | Gemini schema 清理把 format 等合法参数名误当 keyword 删除。 | [调用链与反证](reviews/audit-kmp.md) |
| PHONE-1 | 收起键盘动作不检查前台应用范围，可能操作范围外应用。 | [调用链与反证](reviews/second-kmp-phone.md) |
| PHONE-2 | 输入期间用户接管或取消，输入返回后仍自动收起键盘。 | [调用链与反证](reviews/second-kmp-phone.md) |
| MINI-1 | 合法大浮点参数先转 Int 后限制范围，触发 Swift trap。 | [调用链与反证](reviews/audit-miniapp.md) |
| MINI-2 | 图片代理监听属性后无条件写回相同值，MutationObserver 持续自激。 | [调用链与反证](reviews/audit-miniapp.md) |
| MINI-3 | 定位能力映射丢失精确度；experimental 中也丢失 Always 范围。 | [调用链与反证](reviews/audit-miniapp.md) |
| MINI-4 | 日历只有写权限，完全访问能力也显示已授权。 | [调用链与反证](reviews/audit-miniapp.md) |
| MINI-5 | 联系人有限授权在请求完成后被 Bool 映射成全授权。 | [调用链与反证](reviews/audit-miniapp.md) |
| MINI-6 | 文档失去 bridge trust 后，已建立传感器订阅未释放。 | [调用链与反证](reviews/audit-miniapp.md) |
| C1 | durable 回复恢复出工具调用后，被同 run 的 activeJobs 判重吞掉续跑。 | [调用链与反证](reviews/audit-chat.md) |
| C2 | 多模型轮复用上一轮 checkpoint，新轮交接可恢复旧 response。 | [调用链与反证](reviews/audit-chat.md) |
| C3 | durable 最终失败或再次断线，已收到的正文/思考/工具 suffix 丢失。 | [调用链与反证](reviews/audit-chat.md) |
| C4 | durable MiniApp 解析失败，却发布成功终态。 | [调用链与反证](reviews/audit-chat.md) |
| C5 | durable MiniApp 成功保存后漏同步 Workspace。 | [调用链与反证](reviews/audit-chat.md) |
| C6 | Markdown 表格补列/截列将转义管道重组为裸管道，改变单元格。 | [调用链与反证](reviews/audit-chat.md) |
| C7 | Markdown fence 未记录长度和关闭语法，代码里的表格被当真实表格。 | [调用链与反证](reviews/audit-chat.md) |
| N1 | 分支删章写全局 discardedAt，兄弟分支和回退正文被隐藏。 | [调用链与反证](reviews/audit-novel.md) |
| N2 | 四条新 snapshot 路径漏 chapterPlots，剧情模块丢失且 stale 门禁可被解除。 | [调用链与反证](reviews/audit-novel.md) |
| N3 | workspace 静置裁剪失败 run，错误消息失去精确重试入口。 | [调用链与反证](reviews/audit-novel.md) |
| N4 | 流式正文规范化写回原始 buffer，跨 chunk 围栏与语言标签漏到正文。 | [调用链与反证](reviews/audit-novel.md) |
| N5 | reasoning delta 被当累计快照去重，重复/前缀增量丢字。 | [调用链与反证](reviews/audit-novel.md) |
| T1 | child 新轮尚无输出就取消时，把旧轮答复冒充本轮 FINAL_ANSWER。 | [调用链与反证](reviews/audit-tools.md) |
| T2 | wm_run_goal 提出无选项值或后端不支持的 select 动作。 | [调用链与反证](reviews/audit-tools.md) |
| WM-1 | 多个已选择持久化的本地会话，重启仅恢复第一个。 | [调用链与反证](reviews/audit-webmount.md) |
| WM-2 | 浏览器刷新以脱敏显示 URL 重新导航，丢 query/fragment/真实路径。 | [调用链与反证](reviews/audit-webmount.md) |
| WM-3 | desktop wm_type trim 实际输入文本，并拒绝空字符串清空。 | [调用链与反证](reviews/audit-webmount.md) |
| PLAT-1 | 搜索打开会话忽略加载失败，离场后旧导航任务仍可提交。 | [调用链与反证](reviews/audit-platform.md) |
| PLAT-2 | 首页键盘提交搜索前，失焦折叠先清空查询，导致全局搜索打开空查询。 | [真实 UI 与独立二次判定](reviews/second-home-search-submit.md) |
| SYS-1 | Watch 拒绝旧 run 审批之前已清新 run 决策数据。 | [调用链与反证](reviews/audit-platform-system.md) |
| SYS-2 | DeepRead 补齐失败恢复原文章，却丢失 Workspace 未保存标记。 | [调用链与反证](reviews/audit-platform-system.md) |
| SYS-3 | DeepRead 历史读取/解码失败当空库，创建新任务覆盖原文件。 | [调用链与反证](reviews/audit-platform-system.md) |
| MCP-1 | 同一 MCP 会话过期，断开操作在请求队列外清空配置，第三个已排队只读调用在重连前收到 invalidResponse 并失败。 | [真实 Client 确定性反例](reviews/mcp-real-client-queued-recovery-candidate.md) |
