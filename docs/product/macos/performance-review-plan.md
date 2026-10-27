# macOS 性能 review 与执行计划

2026-10-27，承接 `review-round3-plan.md`。此前 R1–R9/U1–U6 保留，最终集成验证合并到本计划末阶段。范围为 Mac 正式 SwiftUI、实际使用的 KMP provider/storage 与 MCP，不改其他产品仓库、不新增依赖；提交和推送按用户明确授权执行。

## 判断依据

先读实际调用路径，扫描器仅提供线索；每项优化保留前后同输入测量、行为回归和独立 review。不得为测速跳过错误、终态、取消或耐久写盘。保持普通会话 eager/长历史 lazy、现有滚动跟随、消息身份和可见动画策略。

| ID | 已复核热点 | 规模与方案 | 风险/验证 |
| --- | --- | --- | --- |
| P1 | MCP stdio 每次分片从 buffer 开头查换行，未完成的大 JSON 行被重复扫描 | 原算法约 O(B²/chunk)，改为只扫新增字节 O(B)。8 MiB/8 KiB 分片的独立优化构建基准：现有扫描 17.797 s，增量扫描 0.02584 s；这是 framing 微基准，不等于整次工具耗时 | 小范围 scan offset；覆盖跨分片/多行/空行/断开、保持 16 MB 限额和 generation 检查 |
| P2 | Workspace 保存完成后，对每条消息再线性查两份消息数组 | 每秒 checkpoint 可触发，O(N²)→O(N)；每份数组只建一次 ID 索引，保留首次匹配语义和 current==previous 防旧快照覆盖 | 用真实 Runtime 的长历史保存基准测量，覆盖并发流式/取消/分支元数据同步 |
| P3 | 普通 KMP provider 每 chunk 都生成完整快照、Kotlin 编码、Swift 解码，UI 30Hz 合并发生得太晚 | 高频 chunk 下 O(累计输出长度) 反复复制。保持每 chunk 累积，最多约 30Hz 发布完整快照；首次可见内容和终态/失败/停止必须强制提交最后已接收内容 | 高风险：先基准和契约测试；不能牺牲 Stop partial、canonical、usage 或 FIFO。若节流方案需要复杂新框架，退回更小的 active-message projection 优化 |
| P4 | 未变代码块、行内公式/Markdown 在父视图变化时重复高亮/解析/渲染 | 先测正则编译与渲染成本；复用已安装组件/原有局部缓存，只缓存有稳定 key 的未变结果；缓存必须有清晰失效条件和界限 | 字号/浅深色/语言/内容改变必须刷新，错误公式仍显示原文。以原生截图与 replay 核对尺寸、基线、对齐和流式稳定性 |

## 暂不改的项目

- 全文历史搜索无正文索引时必须扫描正文。已确认是大数据机会，但新增持久化全文索引属于另一项存储设计，不能用无界 Swift 文本缓存替代。记录冷/暖查询证据后保留为后续设计项。
- KMP checkpoint 全量写 JSON 是当前耐久格式；不通过减少必要 checkpoint 或批量延迟落盘提高分数。
- SwiftUI 根视图失效、token 估算、查找监听、表格宽度等先测量。只有明确的重复热点纳入 P4，不泛化 Equatable、全局缓存或重写导航。
- 32 MB 图片首次解码是单次重活，尚无当前卡顿测量，不优先引入新的媒体后台处理层。

## Phase 与验收

1. **Perf 1 · framing 与保存查找**：完成 P1/P2 的前后测量、最小实现和回归。独立 subagent 复核错误/取消/旧快照链；UI 无布局变化也核对主窗口、任务与错误消费者。
2. **Perf 2 · 流式发布**：先测 P3，复核设计后实现。真实本地 provider 验证最后 chunk、usage、complete/error/cancel 与首次输出；独立 review 后跑原生 replay，拒绝高度/变体/跟随回归。
3. **Perf 3 · 渲染热点**：按测量选择 P4 的最小有效优化。覆盖字号/主题/内容失效、代码固定和复制；浅深色与宽窄窗新图，独立 review。
4. **Perf 4 · 集成与交付**：完整 Runtime、正式 Mac、local provider、受影响 KMP/iOS 回归，Release 构建/签名/可运行证据；最终性能数字、真实限制、全部问题关闭状态更新。独立收敛 review 后结束，不把微基准倍数当整体 App 提速。

## 记录

- 六路先前 correctness review 已完成，R8 新增真实 Native 本地 provider 隐藏写文件回归已通过；mock provider 共 6/6。
- R9 MCP/工具进程组/取消/超时组 22 项（1 skip）零失败，PATH 已复用后台进程组执行器并限制探测时间。
- 性能审查分为 Workspace、KMP/storage、provider/渲染、SwiftUI 四路只读复核，复杂度扫描仅对 `macApp` 执行，未据扫描告警直接修改代码。
- 计划经 `audit_data` 独立复核通过后进入 Perf 1。原 UI review 最后发现文件读取失败仍显示“还没有文件”，已限制为空态仅在无错误时出现。
- Perf 1 完成：MCP 14 项（1 skip）零失败；实际子进程分片响应包含前后空行及 100,000 行中文。保存的同输入 Release 基准，500/1000/2000 消息从 3.734/14.124/55.330 ms 降至 0.514/0.947/1.851 ms；两名独立 reviewer 确认 first-match 和 stale-write 语义保留。相关 Runtime 回归及 17 项 Release Workspace 通过。两项固定 Task.yield 次数的时序测试改为有界等待真实终态，业务断言不变。
- Perf 2 基线已实测：正式 Shared、本地 SSE fixture，1,000 chunks 产生 1,002 snapshots、170 ms；5,000 chunks 产生 5,002 snapshots、1,333 ms。每 chunk 为 1 字符，最终 usage、canonical ID 均验证通过；此结果不是 100 KB 或外部模型实网基准。
- Perf 2 完成：相同 Native fixture 后测 1,000 chunks 为 3 snapshots/63 ms，5,000 为 8 snapshots/228 ms；8/0，停止/失败的 partial canonical、最终 usage 和 ID 均通过。取消期间终态映射已覆盖 flush 中同步 complete 的回归。独立 reviewer 复核 FIFO、锁顺序、定时器和引用释放。所谓“同步 startKMP 创建 job 与安装取消之间 UI 可插入”的候选经 MainActor 实际调用链复核为假阳性，删除额外 job/task 锁 box。
- Perf 2 原生 replay：plain/reasoning/regenerate 均回到底部（final=0），variantDrops 均为 0。reasoning 软折叠出现一次高度减少，作为原有行为基线保留；未修改滚动策略，未将采样数字冒充真机帧率验收。
- Perf 3 原型基线：6,379 字符稳定 Swift 代码重复高亮 1,000 次约 2.75–2.81 s；公式重复渲染 500 次约 485–502 ms。单条 cache 原型分别约 2.8 ms、1.1 ms。进入生产实现后仍需同输入复测，不能直接用原型数字宣称产品收益。
- Perf 3 完成：实际生产 cache 相同构建测量，代码 1,000 次 hit 18.33 ms/交替 miss 2,848.82 ms；公式 500 次 hit 21.20 ms/交替 miss 533.25 ms。独立 reviewer 复核单条生命周期、key 和错误回退，并检查同 owner 的代码 42→43、公式 mc²→mc³、字号与主题切换、860/1440 窗口，无新增错位或陈旧内容。
- Perf 4 完成：Runtime 297（2 skip）零失败；正式 Mac 322（304 pass/18 skip）零失败；Native local provider 8/8；Release Workspace 18/18；KMP 65/38/6、iOS 共用两类 32/32。Release 构建与 Shared/App 严格签名通过，CUA 主窗和实际 Release 进程路径确认可运行。最终 UI 矩阵、代码/文档独立收敛 review 完成，已修 README 默认 Debug/交付 Release 路径歧义。完整记录见 [最终报告](performance-review/review.md)。
