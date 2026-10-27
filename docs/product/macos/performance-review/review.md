# macOS 审查、性能修复与验证结果

2026-10-27。完成本轮 correctness 与性能计划中的实现、分阶段独立 review 和本机集成验证。基线为 `d57c7a5`；用户在验证完成后已授权提交，本轮未推送或发布。原有未跟踪的定时任务计划未修改。

范围是 macOS 正式产品、它实际使用的共享 Swift/KMP 路径及原生 UI。按单用户本地客户端评估，并用 500–2000 条消息、分片大响应和高频流式输入做规模验证。不将无关 iOS 专属功能或其他产品仓库纳入重构。

执行计划见 [correctness 计划](../review-round3-plan.md) 和 [性能计划](../performance-review-plan.md)。每个阶段均由未负责该实现的 subagent 复核调用链、错误/取消语义与相关界面；只处理确认问题。

## 性能结果

| 测量 | 原行为 / 缓存失效 | 优化 / 缓存命中 | 证据范围 |
| --- | ---: | ---: | --- |
| MCP 8 MiB 单行、8 KiB 分片换行扫描 | 17.797 s | 25.84 ms | `swiftc -O` framing 微基准，仅扫描，不含 JSON 与网络 |
| 500 条历史的终态保存 | 3.734 ms | 0.514 ms | Release Runtime，5 次中位数，排除初始化和首次 checkpoint |
| 1000 条历史的终态保存 | 14.124 ms | 0.947 ms | 同上 |
| 2000 条历史的终态保存 | 55.330 ms | 1.851 ms | 同上，增长由近二次变为近线性 |
| 1000 个 SSE chunk | 1002 snapshots / 170 ms | 3 snapshots / 63 ms | 正式 Shared + 本地 provider，每 chunk 1 字符 |
| 5000 个 SSE chunk | 5002 snapshots / 1333 ms | 8 snapshots / 228 ms | 最终 text、usage、canonical ID 均验证 |
| 6379 字符代码高亮 1000 次 | 交替失效 2848.82 ms | 稳定命中 18.33 ms | 同一生产 cache 实现、同一构建；不是整 App 耗时 |
| 行内公式渲染 500 次 | 交替失效 533.25 ms | 稳定命中 21.20 ms | 同一生产 cache 实现、同一构建 |

这些是指定输入的本机测量，不是全部界面的帧率、真实模型网速或整体 App 提速倍数。原型缓存数字未用于上表。原始测量及可复现基准保存在 [evidence](evidence/)；provider 前后数据分别见 [before](evidence/provider-before.txt)、[after](evidence/provider-after.txt)。

## 已完成的性能改动

- **P1 · MCP framing**：维护已扫描偏移，只搜索新增字节；消费完整行和断开后归零。跨分片、多行、空行、16 MiB 限额、FIFO 与 generation 保护保留。实际子进程 fixture 使用 1 KiB 分片及 100,000 行中文回归。
- **P2 · 保存后同步**：为提交快照与实际保存结果分别构建首次匹配的消息 ID 索引，将元数据回填从 O(N²) 降为 O(N)。不覆盖仍在变化的可见消息，旧快照保护和队列耐久 ID 语义不变。
- **P3 · provider 发布**：每个 chunk 仍累积，昂贵的 canonical 快照约每 33 ms 发布；首次与 complete/error/cancel 前强制提交。停止前先 flush，取消期间到达的终态保持 cancelled，已排队终态仍优先。未对消费端 FIFO 简单丢事件。
- **P4 · 渲染**：代码块、行内公式与公式合法性检查使用视图生命周期内的单条缓存；内容、语言、字号、主题按各自依赖失效。公式 NSView 未变时不重复设置 LaTeX/布局。不新增全局大缓存、依赖或渲染框架，不改变 eager/lazy 分界和滚动跟随。

主要代码位于 `DesktopMCPStdioTransport.swift`、`DesktopWorkspace.swift`、`DesktopProvider.swift`、`DesktopGeneration.swift`、`DesktopMarkdown.swift` 和 `DesktopMathView.swift`。

## 同期确认并修复的问题

| ID | 确认问题 | 修复结果 |
| --- | --- | --- |
| R1 | 设置解码失败立即覆盖原配置 | 原 bytes 保留恢复副本，启动不覆盖损坏主记录；保存新配置后仍可导出副本 |
| R2 | 产物架损坏记录旁路路径冲突/移动失败后覆盖原件 | UUID 旁路名；移动失败时阻止覆盖，保留本次内存内容和可见错误 |
| R3 | 产物架恢复落盘失败仍报告恢复成功 | 抛错进入既有回滚；多副本与清理失败反馈完整；删除会话也反馈清理失败 |
| R4 | 同大小损坏 blob 被继续复用 | 绑定已验证文件版本；首次/版本改变校验 hash，有内存原图时修复；无原图仍保留原引用 |
| R5 | 文件工具先全量加载再截断，导入/导出也先装入 Data | 有界 UTF-8 文本前缀；文件复制保留完整导出和原子覆盖语义；备份完整 bytes 接口未改变 |
| R6 | WebDAV 目录点段可越出 base 路径 | 保存与真实请求入口一致校验；空目录、中文及字面百分号名称保留 |
| R7 | 第 81 条待保存生图记录被普通历史上限淘汰 | Mac 待保存 store 显式不淘汰；iOS 默认历史 80 条不变，跨重启回归覆盖 |
| R8 | 仅开子代理也暴露普通/知识/MCP 工具 | 分离 engine 与普通工具开关，四种组合明确；真实 Native fixture 伪造写文件被拒、无审批和文件副作用 |
| R9 | MCP 首次连接在 UI actor 同步等待登录 shell | 后台共享 PATH 探测复用已有有界进程组执行器，超时回退原 PATH，取消不启动 MCP |
| U1 | Inspector 附件 token 预算少算 | 与展开内容使用同一输入 |
| U2 | Inspector 文件/任务读取失败显示中性空态 | 显示 loading/error，保留文件与任务工作台入口 |
| U3 | 折叠卡片内隐藏控件仍可获得焦点 | 禁用折叠内容并从辅助功能隐藏 |
| U4 | 发送方式菜单被标成“工具” | 工具开关、子代理、发送方式各有正确 AX label/value |
| U5 | 发送/排队 hover 提示与用户快捷键不一致 | 跟随当前 sendShortcut，键盘行为保留 |
| U6 | 文件操作“重试”实际只重新列文件 | 文案改为“刷新文件列表” |
| U7 | 文件读取失败同时显示“还没有文件” | 有错误时不显示空状态 |

## 复核排除与未扩大范围

- 编辑和变体切换会改变消息 ID 路径，旧摘要会失效；没有再造摘要版本层。
- 队列已有串行写盘与 awaitingSave，不把启动失败直接报成消息丢失。
- MainActor 同步 startKMP 与安装取消之间，当前生产取消方无法插入；删除了为理论窗口新增的可变 job/task box。
- `%2e%2e` 目录被 Foundation 编码为 `%252e%252e`，属于字面目录名；未拒绝全部百分号或 MCP 合法 query 参数。
- Antigravity 首次登录是既有能力边界，文档已澄清，不伪造登录入口。
- 全文历史搜索索引、checkpoint 格式、SwiftUI 根状态拆分仍是后续扩展方向。本轮没有足够测量支持持久化全文索引或架构改造；不引入无界文本缓存、不减少必要耐久 checkpoint。
- 整体备份仍按既有格式在内存构建，不以任意文件/总量阈值冒充流式备份实现。

## 实际验证

| 检查 | 结果 |
| --- | --- |
| `macApp/scripts/test-runtime.sh -j 4` | 297 项，295 通过、2 跳过、0 失败 |
| `macApp/scripts/build.sh test` | 正式 Mac 322 项，304 通过、18 跳过、0 失败 |
| `AMBER_MAC_PERFORMANCE_BENCHMARK=1 macApp/scripts/test-provider.sh` | 8/8，真实 Shared、本地 SSE，含能力隔离、错误/取消、burst 与 usage |
| Release Workspace 定向回归 | 18/18；原固定 Task.yield 等待改为有界等待真实终态，业务断言未削弱 |
| KMP storage JVM / desktop JVM / KMP iOS Simulator | 65 / 38 / 6 项，零失败；最终 Gradle 验证包含缓存命中 |
| iOS 共用 WebDAV/生图两类 | 32/32，iPhone 17 Pro 模拟器 |
| `CONFIGURATION=Release macApp/scripts/build.sh` | 构建成功，真实 Shared.framework，arm64 |
| Release app 与 Shared 严格签名验证 | 均通过，未进行公证或发布 |
| Release 启动 | 本仓 Release 可执行文件实际运行；CUA 读取到主窗口、正确发送方式与 Return 提示 |
| 原生截图与 replay | 860/1180/1440/1920、浅深色及恢复/错误/折叠/字体/内容失效场景；独立视觉 review 通过 |
| `git diff --check` | 通过 |

正式全套默认跳过的是无环境变量的外部网关、公开搜索、真实 npx、local provider 和性能基准。local provider 与性能基准已另行显式运行，外部账号/付费网络测试未运行。iOS 首次测试因 GitHub TLS/缓存缺失失败，复用已有依赖缓存后通过，未改代理、依赖版本或安全设置。

Native 全套有一条与基线相同的 QoS 诊断，尚无因果测量支持另行调整优先级。新公式缓存的 AppKit 隔离提示已用准确的 MainActor 标注处理，Release 编译不再出现该新增提示。

## UI 与运行证据边界

截图使用同源真实 SwiftUI/AppKit 组件和隔离 fixture。字体、主题、源内容在同一 owner 内切换；代码 42→43、公式 mc²→mc³ 验证了实际缓存失效。独立 reviewer 检查基线、按钮、边距、宽窄布局和 Inspector。代码固定/复制仍使用原始内容。

代表图：[860pt 主窗口](ui/chat-860-light.png)、[1440pt 深色](ui/chat-1440-dark.png)、[字号切换](ui/cache-font-light.png)、[内容失效](ui/cache-content-dark.png)、[文件读取失败](ui/files-error-light.png)、[设置恢复](ui/settings-recovery-dark.png)。

三个流式 replay 均 final=0、variantDrops=0；plain/regenerate 无高度回落，reasoning 保留既有软折叠的一次高度变化。没有用这些样本宣称 120Hz、所有真实模型或真机触感已验。

真实 OAuth 账号登录、系统通知授权/点击、外部网关与 Developer ID 公证仍需对应账号、权限或证书；本轮没有请求这些授权、读取真实凭据或发起付费模型调用。正式运行窗仅作只读检查，未操作用户会话。

## 交付

应用：`macApp/build/Build/Products/Release/Amber.app`。可重复构建与使用边界见 [macApp/README](../../../../macApp/README.md)。测试、性能原始记录与截图存于本目录；不把历史 Preview 或早期云端构建阻塞作为当前 Native 状态。

最终独立收敛结论：本轮确认问题、四个性能阶段与可执行的集成验证均关闭。保留的账号、系统权限、外部 provider 和公证边界如上；没有将其标记为已验。
