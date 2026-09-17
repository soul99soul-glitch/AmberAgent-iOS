# Phase 1 — 工具发现与记忆召回

代码状态：完成
离线检查：passed
真实 API：blocked（无 TypeSafe API Key）
真实业务和真机：not_run（无 Key 无法产生真实判断流量）
用途模式：工具发现 off（默认）/ 记忆召回 off（默认）；shadow/active 代码路径已实现，启用依赖真实凭据
基线 commit 与工作区状态：基线 `4104daf`（拉取远端后），另有用户既有未提交修改（Apple Sign-In / Info.plist / project.yml 等，未触碰）；本阶段改动见下文变更清单

## 步骤完成情况

| 计划步骤 | 状态 | 说明 |
|---|---|---|
| 1.1 原行为与基线 | 完成 | 8 个基线套件 99/99 通过（基线 4104daf）；合成 fixture 建立（46 工具 / 40 记忆，tuning + frozen 分集，覆盖弱词面/中文同义/跨语言/否定/无答案/多正确/过期/归档/置顶/注入文本） |
| 1.2 可测试的直接调用 | 完成 | `IOSJevClient`（URLSession/Codable、typed questions/answers、deadline 竞速取消真实任务、429 Retry-After、暂时性错误单次重试、逐题校验、内存缓存 128 项 TTL 5min） |
| 1.3 设置与连接闭环 | 完成 | `IOSJevSettings`（版本化 Codable、每用途模式/范围、active 无 pinned 版本降级 shadow）；`IOSSharedSettingsStore` 持久化 + Keychain side-table 存 Key（写入成功才更新 UI）；设置页连接测试（合成数据、返回实际模型版本/耗时/错误，不自动启用任何用途） |
| 1.4 工具语义发现 | 完成 | KMP bridge 增加 `candidateSnapshot`（纯候选、只读）与 `executeToolSearch(argumentsJson:rankingOverride:)`（排序覆写、复用 recipe 富化/相关展开/暴露）；Swift `IOSJevToolDiscoveryService` 统一前台/后台/Recipe 三路径；精确名零 Jev bypass；仅 active 应用排序；低置信/失败回退原搜索 |
| 1.5 记忆语义召回 | 完成 | `IOSJevMemoryRecallService`（@MainActor 单例）：硬筛选先于外发、候选含词面+新近+补充、逐条 Score、pinned/core 强保留、预算由原 builder 执行；**一次计算选中集合**——`prepareUploadMessages` 经新 binding `prepareJevMemoryRecall` 计算，注入与 usage marking 都经 `ChatRuntimeContextBuilder.memoryRecallResult` 共用（turnKey = 最后 user 消息 id + 设置 revision + 记录指纹，steer/内容/配置变化自然失效）；shadow 不影响注入、不标记使用 |
| 1.6 阶段验收 | 部分完成 | off 零网络/零缓存/零指标足迹有测试证据；shadow 业务无变更有测试证据；active 超时回退有测试证据。跨会话切换/后台运行的真实场景验证被 Key 阻塞（见下） |

## 变更文件与理由

**新增（Swift，iosApp/iosApp/）**
- `IOSJevSettings.swift` — 版本化设置、每用途模式/数据范围、内部策略阈值（IOSJevPolicy）、7 天/5MiB 指标存储。
- `IOSJevClient.swift` — /v1/systemone 客户端；官方契约核对日期 2026-09-17（Choice criteria=option→rubric map、Score criteria=有序分级、Noul 无 confidence；429/529 退避）。Keychain ref `IOSCredentialSideTable.jevApiKey`。
- `IOSJevDecisionCoordinator.swift` — 唯一出站口：范围/预算（轮 6 次 256KiB、日 1000 次 16MiB）、并发（每 run 1 / App 3）、3 连败 60s 冷却、401/403 暂停至凭据变化、出站前后配置 revision 核对、指标记录、连接测试。
- `IOSJevToolDiscovery.swift` — 三路径统一异步搜索服务。
- `IOSJevMemoryRecall.swift` — 记忆召回服务 + 统一选中集合缓存。
- `IOSJevSettingsView.swift` — 设置页（Key 保存/清除、连接测试、每用途模式与数据范围、状态与开销、清除指标）。

**修改**
- `feature/tools/api/.../ToolSearch.kt` — `searchPayload` 增加 `rankingOverride`（逐名重验证、category 过滤仍生效、trace 标 ranked）；新增 `candidatePoolPayload`。
- `feature/tools/api/.../IosToolExposureBridge.kt` — `executeToolSearch` 重载（rankingOverride）与 `candidateSnapshot`（只读）；公共参数解析抽取。
- `iosApp/iosApp/IOSSharedSettingsStore.swift` — `jevSettings` 持久化、`storeJevApiKey`/`clearJevApiKey`（Keychain 失败不动原 Key）、轻量静态读取。
- `iosApp/iosApp/ChatContextSupport.swift` — `ChatMemoryContextBuilder.contextPromptResult` 增加 `orderedSelection` 入口（外部排序 → 原 prompt 契约 + 原条数/字符预算）；`ChatRuntimeContextBuilder.memoryRecallResult` 先查统一选中集合。
- `iosApp/iosApp/ChatGenerationSupport.swift` — bindings 增加 `prepareJevMemoryRecall`。
- `iosApp/iosApp/ChatKernelRunHost.swift` — `prepareUploadMessages` 在注入前调用记忆准备（off 零操作）。
- `iosApp/iosApp/ChatViewModel.swift` — 实现记忆准备 binding（turnBudgetKey = 会话 + 最后 user 消息 id）。
- `iosApp/iosApp/ChatToolRuntime.swift` — 前台 `executeToolSearchToolCall`（async 化）、后台 executor、Recipe discovery 三处改走统一服务；tools_list 永远直连 bridge。
- `iosApp/iosApp/ExecutionSettingsView.swift` — "快速判断"入口行 + sheet。

**测试与 fixture（iosApp/iosAppTests/）**
- `Fixtures/Jev/JevFixtures.swift`、`Fixtures/Jev/JevTestSupport.swift`
- `IOSJevClientTests`（14）、`IOSJevDecisionCoordinatorTests`（12）、`IOSJevSettingsTests`（10）、`IOSJevToolDiscoveryTests`（10）、`IOSJevMemoryRecallTests`（15）— 共 61 用例。

## 已执行检查

| 命令 | 结果 |
|---|---|
| 基线（改动前，4104daf）：8 套件 xcodebuild test | 99/99 通过 |
| `./gradlew :feature:tools:api:jvmTest` | 通过（bridge 改动后） |
| `./gradlew :feature:tools:api:jvmTest :shared:jvmTest` | 通过 |
| 新增 5 套件 xcodebuild test | **61/61 通过**（/tmp/jev_phase1.xcresult） |
| 回归 10 套件（ToolSearchExposure/AgentToolEngineKernelHook/SettingsWiring/MemoryRecallPolicy/MemoryCitation/MemoryUsageMarking/MemoryLibrary/ChatContextSnapshot/ContextCompactionCoordinator/AgentToolEngine） | **145/145 通过**（/tmp/jev_phase1_regression.xcresult） |
| `xcodegen generate` | 已执行（新文件入 target；.xcodeproj 不提交） |

> 回归结果占位：见报告末尾「回归执行记录」。

关键行为断言（全部由测试覆盖）：
- off = 零 transport 调用、零缓存写入、零指标记录。
- 范围未全部允许 = 零网络（工具/记忆各自独立范围）。
- 缓存命中不占轮次预算、不占并发槽位。
- 每轮 6 次请求 / App 日 1000 次预算耗尽 → 走原流程；新轮次获得新预算。
- 同 run 并发第 2 个判断被拒；App 全局上限 3。
- 3 连败（每次含 1 次重试，共 6 次出站）→ 60s 冷却；401 → 暂停至 resetAuthState（保存新 Key/连接测试触发）。
- 在途配置变化（revision）→ 结果丢弃、不写缓存、按已计费记录。
- deadline 200ms 时 5s 慢请求被取消且底层任务收到取消信号（总耗时 < 2s）。
- 排序覆写：未知名被丢弃、category 过滤仍生效、暴露仅经 bridge、快照只读。
- 记忆：高分入选/低分淘汰、pinned/core 缺失时插队保证存在性、topic 行保留、归档/过期永不注入、注入与 usage marking 共用同一选中集合。

## 对照结果

- 样本量：工具冻结集 20 例（含 1 例精确名 bypass）、记忆冻结集 12 例。调参集另存不参与验收。
- 模型/问题/策略版本：`jev-latest`（连接与实验口径）；策略 `IOSJevPolicy(policyVersion=1)`（deadline 1200ms、每题 Score 0–3 分量表、minScore 1.0）。
- 基线（关键词路径）在冻结集上的表现由 `testFrozenToolCasesRunThroughKeywordBaseline` / `testFrozenEvalCasesBaselineViaSyncPath` 输出（print 行：`[Jev Phase 1 baseline] ...`），仅记录、不作为达标手段。
- **无法给出 Jev 侧 Recall@5 / 必要召回率对比**：无 API Key，所有 shadow/active 流量未发生。基线数字与天花板分析待真实凭据就绪后补测；不会为达标修改冻结集金标准。
- 延迟 / usage / 费用：无真实请求，无数据。费用估算日期：不适用。

## 阻塞、回退与下一步

- **阻塞（真实 API 验证）**：需要用户在设置页配置 TypeSafe API Key（Keychain 存储）后，方可执行合成数据连接测试、shadow 冻结集评估与 active 对照。在此之前工具发现与记忆召回保持 off，不冒充收益。
- **阻塞（真机）**：移动网络/弱网/锁屏场景的 p50/p95 与后台行为待真机证据；当前仅模拟器测试证据。
- **回退**：关闭对应用途（设置页切换 off）即回到原关键词搜索与原记忆 builder；不迁移、不删除任何记忆/会话数据。旧配置（无 jevSettings key / 无 Keychain 项）默认全 off。
- **下一步（进入 Phase 2）**：复用本阶段的客户端/协调器/身份/预算契约，实现长工具输出筛选投影与恢复引用；恢复路径采用「原工具重读 + session_read」（iOS 无 conversation_expand 执行器，已核实），无安全重读路径的类型一律硬保留。
