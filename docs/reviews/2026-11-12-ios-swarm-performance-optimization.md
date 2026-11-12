# Amber iOS 基线无线装机、原生 Swarm 性能治理与真机交付报告（2026-11-12）

## 1. 基线对齐与首轮未修改真机覆盖安装

- **代码基线**：工作树分支 `synara/amber-ios-performance-optimization` 快进对齐 `origin/synara/ios-redesign`（`04402ec7fd8aa580197b745542c885d3260f4a14`），未混入其他工作树 WIP，未执行破坏性清理。
- **首轮基线构建与严格签名**：
  - Scheme / Bundle ID：`iosAppExperimentalGPL` -> `app.amber.ios`（Automatic Signing，Team `TY4JTL3V2M`，`ENABLE_DEBUG_DYLIB=NO`）
  - `codesign --verify --deep --strict --verbose=2`：`valid on disk` / `satisfies its Designated Requirement`
  - 基线可执行文件 SHA-256：`b169361cb7f967da3b7427461577fa52764a14de8082fef4b2d1a5ebd006ec0d`
  - 基线 `Shared.framework/Shared` SHA-256：`cc58463ff91828aa2038efeecda4c083abb2669f02c2b0a1a1a7fa2fd9747abb`
- **首轮无线保数据覆盖安装**：
  - 目标设备：物理真机 `00008160-001939111420000A`（CoreDevice `C10C4C93-308E-570D-B516-67F402942C86`，`iOS 27.2`）
  - 结果：`outcome = "success"`，`databaseUUID = "14914597-0AC5-4C9D-9E54-4D10AB79E1D7"`，`databaseSequenceNumber: 3408 -> 3640`（未卸载、未清空用户容器）。

## 2. Gemini 4 Carbon High 3 路只读原生 Swarm 审查发现

通过原生 `swarm` 启动 `timeline`（聊天流式与 Markdown/代码渲染）、`surfaces`（根容器观测隔离、`3+1` Liquid Glass 导航与产物架）、`runtime`（Handoff 持久化、手机工具提示词与运行账本）3 路只读审查，在单写者主会话统一落地 5 组零视觉降级优化：

1. **流式根视图 `@Observable` 观测隔离**：
   - `ChatViewScreenSignals.conversationTitleForIsland` 原本在存在封存段落（`episodeBoundaryIndex != nil`）时直接读取 `viewModel.messages`，导致每次流式 token 更新穿透失效 `ChatView.body`、`ChatTopBarView`、`ComposerView` 与 `AmberDuetBottomSwitcher`。
   - 改为在 `ChatListSummarySnapshot` 维护增量 `isAtEmptyEpisodeBoundary`，彻底切断流式 token 对根视图与顶底栏的无效刷新。
2. **流式文本扫描、分页历史窗口外元数据截断与代码块语言提示**：
   - `IOSMiniAppChatMessageFactory.mightContainMiniApp(_:)` 改用零分配 `Darwin.memchr`/`memcmp` ASCII 字节折叠匹配，替代整段 `text.lowercased()` 分配与标量遍历；`MessageBubbleView.partAnimationKey` 仅对活跃流式尾气泡执行该探测并按 UTF-8 字节桶分片。
   - `NativeTimelineProjectionCache` 与 `ChatTimelineUpdates` 增加 `streamingUnchangedHistoryMetadataCutoff(messageCount:)`，对分页可视窗口外的已完结历史消息直接采用 $O(1)$ 引用相等（`===`）快速短路，不再逐轮跨 Kotlin/ObjC 桥接扫描全部历史工具 `output` 元数据。
   - `CodeBlockView` 向 `HighlightSwift` 透传归一化显式语言标识（失败自动回退自动识别），并将未着色前缀截取切换为 UTF-8 字节索引。
3. **`3+1` 底部胶囊与任务/中心内联面板投影记忆化**：
   - 新增 `AmberUnifiedTaskProjectionCache`（100 行），在不破坏 `@Observable` 属性依赖追踪的前提下，按各 Store CoW 快照记忆化 `AmberUnifiedTaskBuilder.Groups`，并将 `AmberDuetChrome.swift` 从 `1602` 行缩减至 `1593` 行。
4. **多工具轮次产物架 `BuilderState` 增量折叠与无变化短路**：
   - `ConversationArtifactIndex` 将构建状态提取为纯值类型 `BuilderState`，在 `ConversationArtifactContentCache` 保存前缀与完整切片增量快照（精确命中 $O(N)$ 指针比对即返，追加或尾消息流式变化仅折叠新增尾部，历史编辑或分支切换自动全量重建并 `prune()`），同时 `ChatArtifactShelfState.update` 对未变化索引短路返回。
5. **主线程 Handoff 内联截图无损外置、手机观测提示词动态对齐与账本轮次缓存**：
   - `IOSChatBackgroundPayloadCodec` 将 `>= 4KB` 且无额外元数据的内联 `data:` 截图原子外置至 `ChatBackgroundJobs/<requestId>.blobs/<sha256>.dat`，配合 `NSMapTable` 弱引用缓存避免每轮重复编码数 MB Base64 JSON；`loadHandoff` 校验 64 位十六进制摘要后 **100% 字节级无损还原**原始 `data:` URL（缺文件 fail-closed 报错，绝不静默丢图），`removePayload` 同步清理 `.json` 与 `.blobs/`。
   - `IOSPhoneControlToolExecutor.observationResult` 根据 `IOSPhoneAutomationRequestPolicy.liveGoalPlanningActiveProvider()` 动态输出 `next_step_hint`，消除 Jev 目标路由未激活时工具提示词仍诱导调用 `phone_run_goal` 的冲突。
   - `IOSAgentRunLedger.recordRequestSnapshot` 增加带跨实例写入代数（`RequestSnapshotWriterEpoch`）校验的 `roundIndex` 缓存，消除单轮多步运行重复调用 `dao.listEventsForRun` 的 $O(N^2)$ 历史事件反序列化。

## 3. 同构基准前后量化对比（Simulator `iPhone 17 Pro`，`F3D5299E-EEA6-4098-BF61-AB1C516933C0`）

前后均在同一模拟器、同一未改动测试文件 `iosAppTests/AmberSwarmPerfVerificationTests.swift` 及仓库既有性能测试下采集（原始日志保存在本地 `iosApp/build/PerfComparison20261112/before-perf.log` 与 `after-perf.log`）：

| 测试项 | 指标 | 优化前 (`04402ec7`) | 优化后 | 变化 |
| --- | --- | --- | --- | --- |
| `miniAppScan` (1,200 次流式扫描, 峰值 8,854B) | 主线程 CPU / 单次对耗时 | `337.928 ms` (`563.21 µs`) | `0.439 ms` (`0.73 µs`) | **-99.87% (770x)** |
| `paginatedTailStream` (180 条工具历史 + 40 次尾流式) | 主线程 CPU / 每 delta | `78.401 ms` (`1.960 ms`) | `62.555 ms` (`1.564 ms`) | **-20.21%** |
| `sealedEpisodeStream` (含封存段落 25 次流式 delta) | `chat/topBar/composer/duet` 重算次数 | `25 / 25 / 25 / 25` (`296.674 ms`) | **`0 / 0 / 0 / 0`** (`190.856 ms`，热态 `54.408 ms`) | **根视图与顶底栏重算 -100%** |
| `duet120HzScrub` (120 帧面板拖拽布局) | `AmberUnifiedTaskBuilder` 重算次数 | `30` (`166.826 ms`, 15 次布局批次) | **`0`** (`199.831 ms`, 19 次 UIKit 布局批次) | **任务树重算 -100%** |
| `artifactIncrementalRefresh` (25 步 / 50 次产物索引刷新) | 主线程 CPU | `86.654 ms` | `2.265 ms` | **-97.39% (38.3x)** |
| `handoffCheckpointPersist` (8 张 ~180KB 截图 × 6 轮检查点) | 主线程 CPU / JSON 体积 | `318.289 ms` (`53.048 ms/轮`) / `2,932,892 B` | `12.613 ms` (`2.102 ms/轮`) / `15,500 B` | **CPU -96.04% (25.2x)，JSON -99.47%，8 张截图字节级无损恢复** |
| `PERF-LONG-HISTORY` (18 轮长 Markdown 历史 + 30 次流式) | 每轮主线程 CPU | `14.321 ms` | `12.570 ms`（热态 `7.770 ms`） | **-12.23% ~ -45.75%** |
| `PERF-HITCH` (动态增长大表格流式渲染) | `p95` / `over50ms` | `16.67 ms` / `0` | `16.67 ms` / `0` | **零 >50ms 掉帧** |
| `endToEnd[tables24KB]` (24KB 表格 60 次流式 delta) | 总耗时 / 每 delta | `4879 ms` (`81.32 ms`) | `4620 ms` (`77.00 ms`) | **-5.31%** |

## 4. 定向回归、视觉核验与最终真机覆盖安装

- **定向功能与卫生回归**：`PerformanceHygieneTests`、`ChatTimelineUpdatesTests`、`ConversationArtifactIndexTests`、`ChatArtifactShelfStateTests`、`ChatEpisodeTests`、`IOSChatDurableOwnershipTests`、`IOSPhoneAutomationRequestPolicyTests`、`IOSPhoneControlCatalogTests` 共 **64 项测试全部通过（0 failures）**。
- **行数门禁核验**：全部新增/修改文件均 `<= 1468` 行（上限 `1500` 行）；既有超长文件 `AmberDuetChrome.swift` 由 `1602` 行缩减至 `1593` 行。
- **模拟器零 API 视觉核验**：通过 Synara `device_*` 安装并冷启动 `app.amber.ios`（`settled: true`），核验主对话视图与展开态 `任务` 内联面板，顶部形象岛、输入栏与底部 `3+1` Liquid Glass 胶囊无遮挡、无重叠、无材质或圆角阴影降级。
- **最终优化包真机无线覆盖安装与冷启动烟雾核验**：
  - `codesign --verify --deep --strict --verbose=2`：`valid on disk` / `satisfies its Designated Requirement`
  - 优化后可执行文件 SHA-256：`62b9096793f29c57c9f430201fe228e83c4aeaad25385192d545786446ee35d5`（与基线 `b169361c...` 明确区分）
  - 无线保数据覆盖安装：`outcome = "success"`，`databaseUUID = "14914597-0AC5-4C9D-9E54-4D10AB79E1D7"`，`databaseSequenceNumber = 3656`（高于基线 `3640`）
  - 零 API 真机前台冷启动烟雾核验：`devicectl device process launch --terminate-existing app.amber.ios` 返回 `outcome = "success"`，`processIdentifier = 47983`。

## 5. 诚实边界与未验证项说明

- 本轮严格遵守零真实 API Key / 零付费模型调用约束，所有性能基准均在受控确定性夹具与本地模拟器/真机冷启动下测得。
- 手机控制方向仅消除了本地 Handoff 检查点写盘放大、账本轮次查询放大与 Jev 未启用时 `next_step_hint` 的提示词冲突；**上述合成基准不构成真实多邻国（Duolingo）在线模型 + Jev `phone_run_goal` 端到端时延下降的证明**，后者仍需在用户授权真实模型与 Jev 服务下单独实测。
- 工作树按要求保留未提交状态（未执行 `git commit`、`git push`、PR 或云端部署）。
