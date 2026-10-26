# Amber 搜索工具与搜索服务审查

日期：2026-10-25。范围：当前 iOS/KMP 工作区，`main`，HEAD `bd51719c4bf265f5e63fabed1f337c26fefd2c77`，包含当前未提交代码。审查保持业务代码只读，未提交、推送、安装或改动已有工作。报告中的行号以本次工作区为准。

## 结论与调用链

搜索工具已有完整的注册、执行、结果输出链路，但设置与执行之间存在多处不一致。确认 11 项有实际影响的问题：1 项 P1、10 项 P2。Jina 无 Key 失败、免费聚合阈值、URL 去重和 DNS 取消有可执行证据；其余结合当前源码、可达 UI 路径及独立复核确认。没有将静态审查或边界 stub 说成 App/真机验收。

实际主链路：

```text
SearchServicesView / SearchProviderView
  -> IOSSharedSettingsStore
  -> IosSettingsMutations / Settings + Keychain + 本机 provider mirror
  -> ChatGenerationRequestBuilder 注册 search_web / scrape_web
  -> 前台 ChatToolRuntime / 后台本地 executor
  -> ChatLocalToolOperations 的审批判断
  -> IOSSearchToolDispatch
  -> IOSSearchExecutor.searchProviderSelection
     -> 一个已选 API provider，或免费聚合
     -> API 请求失败时只可能退免费聚合
  -> IOSSearchToolOutput：模型消费文本，图片写展示 metadata
  -> 原始 conversation/run 的消息结果
```

免费聚合内部查询 Bing、Brave、DuckDuckGo、夸克、360、Wikipedia；非中文查询还查询 Hacker News。Google WebView 是结果不足时的补充。`scrape_web` 使用公网验证抓取，启用 Jina Reader 时可在直连失败后代读正文。

## 已确认问题

### 1. P1：搜索逐能力权限没有进入执行判断

位置：`iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatLocalToolOperations.swift:6`、同文件 `:188`；`iosApp/iosApp/IOSSearchToolDispatch.swift:55`。

权限页提供 `ios.network.search_tools` 的禁用、每次询问、自动批准，运行快照也记录该策略；前台搜索执行和后台搜索准入却只读取全局/高风险自动批准，最终 dispatch 只检查网络搜索总开关。

复现：开启 Agent 网络搜索，将“搜索与网页读取”设为禁用，并开启全局自动批准。模型调用 `search_web` 或 `scrape_web` 时仍会直接外发请求。反向场景中，只给搜索能力设自动批准、关闭两个全局自动批准，前台仍弹审批，后台仍拒绝。

已排除上游统一过滤：声明搜索工具只依赖总开关，工具分发直接进入 `.search`；recipe 和旧子代理入口也不会补回该检查。同仓其他能力优先拒绝 `.disabled`，因此不能解释成全局批准有意覆盖禁用。每次询问被全局批准覆盖属于其他工具也有的既有语义，没有另列缺陷。

建议：在搜索共享执行 owner 使用 run 内能力策略统一判定拒绝、需批准、允许，前后台及嵌套调用消费同一结果。

### 2. P2：Jina 搜索要求 Key，但当前配置页没有输入入口

位置：`iosApp/iosApp/SearchProviderView.swift:100`、`:295`、`:321`；`iosApp/iosApp/IOSSearchExecutor.swift:534`、`:981`。

`.jina` 的 `requiresAPIKey` 为 false，导致 Key 输入框完全隐藏；切换供应商还会清空草稿 Key。保存后的 Jina 搜索因此不带 Authorization，页面仍宣称 Key 可选。

本轮以与实现一致的无凭据 `POST https://s.jina.ai/`、body `{"q":"Swift concurrency"}` 实测得到 HTTP 401 / `AuthenticationRequiredError`，服务端要求有效 API Key。Jina Search 与允许无 Key 的 Jina Reader 是两个服务。[官方说明](https://docs.jina.ai/)、[Reader/Search 费率表](https://jina.ai/reader/)也区分了这一点。

影响：当前正常 UI 新增的 Jina 搜索必先失败，再退免费聚合；关闭免费回退时直接失败。`IOSSearchExecutorTests.swift:430` 的无 Key 成功 mock 不能验证真实认证契约。

建议：给 Jina Search 提供 Key 输入与必要凭据校验，Reader 的免 Key 行为单独保留。

### 3. P2：拖动供应商“优先级”不改变正常请求的首选服务

位置：`iosApp/iosApp/SearchServicesView.swift:150`、`:342`；`shared/src/commonMain/kotlin/shared/IosSettingsMutations.kt:1321`；`iosApp/iosApp/IOSSearchExecutor.swift:227`。

复现：先新增 Tavily，再新增 Brave，Brave 自动成为 selected；把 Tavily 拖到第一位，页面显示它优先级最高，正常搜索仍走 Brave。源码抽取 harness 确认排列变化后 route 仍是 `brave_api`。

KMP 排序方法明确保留原 selected ID，这个方法本身符合其注释；问题落在 iOS 的优先级 UI 与实际路由契约。iOS 也没有单独选择已有默认供应商的入口。列表顺序只在 selected 被禁用、缺凭据或不支持时参与选择。

相关限制：selected 请求发生 401/429/500 等运行错误后，dispatch 只可能退免费聚合，不会逐个尝试其他已启用 API 服务（`IOSSearchToolDispatch.swift:114`、`:143`）。没有把“所有付费供应商应并发聚合”作为额外缺陷，因为缺少明确契约。

建议：明确选中服务与优先级的关系，使 UI 操作能改变实际首选；是否依序失败切换按产品契约实现，不应仅修改 KMP 排序保留 ID 的逻辑。

### 4. P2：删除服务会误改选择，甚至重新启用已关闭的服务

位置：`shared/src/commonMain/kotlin/shared/IosSettingsMutations.kt:1198`、`:1207`。

删除后只把旧 selected 索引 clamp 到新数组，没有按原 selected ID 重定位；删除选中项之前的条目，会改为选择后一个服务。另一个分支在 enabled IDs 为空时强制启用剩余 selected。

可达复现：新增 Brave、Tavily，关闭默认 Bing、Brave、Tavily，再到配置页删除 Brave。Tavily 会被重新启用并持久化，下一次请求可走之前关闭的付费服务。用户只做了删除操作。

`setSearchServiceEnabled` 明确允许空列表，不能用“必须至少开启一个”解释。默认 seed 中类似 consistency 逻辑不在当前 decode/restore 路径，未扩大为“重启就会重新启用”。

建议：按服务 ID 保持未删除的选择，保留显式空启用集合；只为被删除的 selected 决定新的默认项。

### 5. P2：关闭免费聚合开关后，仍可从默认 Bing 配置进入全部免费源

位置：`iosApp/iosApp/SearchServicesView.swift:110`；`iosApp/iosApp/IOSSearchExecutor.swift:227`、`:954`。

前提是默认“Bing HTML 兜底”配置仍启用。聚合开关只关闭 builtin DuckDuckGo/Bing 两个字段；已选 BingLocal 的描述符直接路由 `.freeAggregate`，不检查这两个字段，实际仍查询 Brave、夸克等全部免费源。当前默认配置满足这一前提。

源码抽取 harness 确认两个 builtin 字段为 false、默认 Bing 配置启用时，实际 route 仍为 `free_aggregate`。不能表述成“所有服务都关闭后仍搜索”；这是同一执行能力两处控制与命名冲突。

建议：让免费聚合能力有一致的启停语义；若配置项有独立覆盖能力，应明确展示其范围，避免把多源聚合称为单一 Bing 兜底。

### 6. P2：结果数量 11–50 可保存，但运行时都截为 10

位置：`iosApp/iosApp/SearchServicesView.swift:269`；`shared/src/commonMain/kotlin/shared/IosSettingsMutations.kt:1304`；`iosApp/iosApp/IOSSearchExecutor.swift:1188`。

设置页与持久化允许 1–50，所有搜索请求经 `sanitizedMaxResults` 后上限为 10；免费聚合也二次限制为 10。当前源码函数的 harness 确认设置默认数量 20、50 时，生成请求都为 10。

建议：统一 UI、工具 schema、各供应商支持范围与运行时上限。无需为了让设置成立而直接扩大所有供应商请求。

### 7. P2：只要 1–2 条结果时，Google 兜底会被无条件触发

位置：`iosApp/iosApp/IOSFreeSearchAggregator.swift:97`。

聚合先按用户 limit 截断，再用 `< 3` 判定结果不足。免费源已有足够命中、用户只要 1 或 2 条、Google 兜底开启时，依然必须等隐藏 WebView 完成，最终结果仍可能是此前已有的 1/2 条。WebView 页面阶段默认等待最多 12 秒，其后的跳转解析还有独立等待。

原聚合文件 harness 中，免费源给出 4 条：limit 1/2 的 Google 调用均为 1 次；limit 3/5 均为 0 次。这是明确的额外请求和延迟。

建议：按截断前的有效召回判断，或让判断阈值不超过用户所需数量。

### 8. P2：普通公网抓取的 DNS 等待不响应取消与请求超时

位置：`iosApp/iosApp/Search/IOSSearchHTTPTransport.swift:52`；`iosApp/iosApp/IOSVerifiedHTTPScrapeTransport.swift:51`；`iosApp/iosApp/IOSSearchExecutor.swift:699`。

`sendPublic` 直接等待 detached resolver 的 `.value`。父任务取消不会结束这个等待，URLRequest 的超时还没有进入生效的 URLSession 阶段。即使 HTTPS 已做有界 DNS 预检，普通公网地址仍回到这里再次解析；HTTP 抓取和 Jina Reader 也会走到这里。

使用原 transport 文件编译，注入 3 秒 resolver，请求超时设 0.2 秒，100ms 后取消；本轮独立重跑仍在约 3.001 秒后才得到 CancellationError。现有 verified DNS waiter 测试没有覆盖这一后续解析。

建议：复用已有可取消、带 deadline 的 DNS 等待机制；目标是让调用方及时停止等待，不是要求停止 libc worker。

### 9. P2：Google 跳转解析没有传播取消，聚合还能在取消后返回成功

位置：`iosApp/iosApp/IOSGoogleWebViewSearch.swift:79`；`iosApp/iosApp/IOSFreeSearchAggregator.swift:95`。

WebView 的 `load` 有取消处理，但其后每条 `/goto` 的解析使用非结构化 Task，等待它们时没有取消处理。父任务被停止后，这些请求仍可执行到各自 6 秒超时；聚合只在 fallback 之前检查取消，返回后没有再次检查。

使用原聚合实现和与 Google 相同 Task 结构的 fallback 复现：取消父任务后 child 的 `isCancelled=false`，约 259ms 后聚合仍返回 `success=1`。证据能证明停止延迟、额外请求与执行器成功返回；没有据此宣称已停止聊天必然发生错误回写。真实 WKWebView 生命周期尚未实机验收。

建议：向跳转任务传播取消，并在 fallback 完成及最终返回前检查取消。

### 10. P2：恢复备份后的供应商在管理页失联，无法删除

位置：`iosApp/iosApp/IOSSyncBackup.swift:79`；`iosApp/iosApp/SyncBackupView.swift:763`；`iosApp/iosApp/IOSSharedSettingsStore.swift:276`、`:1103`；`iosApp/iosApp/SearchProviderView.swift:174`。

备份包含 Settings 的真实服务列表，但不包含本机 `customSearchProviders` mirror；恢复只调用 `restoreSnapshot`，不重建 mirror。主服务页按 snapshot 显示恢复的条目，名称/类型会退化为“搜索服务/search”；唯一删除页面只遍历 mirror，因此新设备恢复出的服务没有删除入口。

这是管理数据来源不一致的问题。凭据刻意不进入备份是既有设计，没有将脱敏本身列为缺陷。

建议：管理入口以真实 service ID/类型为准，避免删除能力依赖未随 Settings 恢复的另一份列表。

### 11. P2：完整 URL 小写化去重会误删不同页面

位置：`iosApp/iosApp/IOSFreeSearchAggregator.swift:156`。

去重对整个 URL 调用 `lowercased()`，而 path/query 可以区分大小写。对原 `roundRobinMerge` 输入 `https://example.org/Case`、`https://example.org/case`，实际仅保留 1 条。路径或查询参数大小写对应不同资源时，会丢掉有效结果。

建议：只对 scheme/host 做适用的规范化，保留 path/query 的语义。

## 已核查通畅与未计入缺陷的部分

- 支持的新增菜单与原生 route 对应：免费 Bing/聚合、Tavily、Exa、智谱、Brave、Serper、SerpAPI、Jina。SearXNG、LinkUp、Metaso、Ollama、Perplexity、Firecrawl、Bocha、AmberAgent、Grok 为显式不支持且不在新增菜单；隐藏 SearXNG 字段未传参没有列成当前可达缺陷。
- 新增服务会构造真实 KMP subtype，加入 Settings 并 selected/enabled。凭据成功写入 Keychain 后才提交脱敏配置；失败会回滚，revision 用于更新视图。启停状态正常持久化，未证实普通重启会恢复关闭的服务。
- `search_web` / `scrape_web` 的 schema、Swift 参数解析、常驻工具曝光与前后台注册有对应入口。图片通过 metadata 展示，模型收到文本；结果按原始 conversation/run 回写。run 内冻结工具/权限快照有明确设计，没有报成中途切设置不生效。
- 免费源并发和单源失败隔离可达；403/429/验证码有 10 分钟冷却。Brave 本轮返回 429，按预期隔离，未报为应用 bug。
- Exa 的 Bearer 认证有[官方支持](https://exa.ai/docs/reference/search)；Tavily 的逐结果 images 是[当前官方响应形态](https://docs.tavily.com/documentation/api-reference/endpoint/search)；智谱 endpoint、Bearer、`search_std`、count 与[官方文档](https://docs.bigmodel.cn/api-reference/%E5%B7%A5%E5%85%B7-api/%E7%BD%91%E7%BB%9C%E6%90%9C%E7%B4%A2)一致。上述疑点均排除。
- 抓取路径已有公网 host/IP 检查、逐跳重定向校验、HTTPS 降级阻断、响应体限额和内容类型判断。没有将已有防护仅凭存在推断为完整安全验收。

另有两项观察，未混入 11 项确认问题：

1. 开启总搜索开关还会给模型加 `BuiltInTools.Search`（`ChatGenerationRequestBuilder.swift:303`），OpenAI Responses 路径据此声明供应商原生 `web_search`（`ai-provider-openai/src/commonMain/kotlin/app/amber/ai/provider/openai/OpenAIKmpProvider.kt:1028`）。这条出口不经过本地搜索聚合供应商、数量和审批。代码事实确定，但是否应与聚合共用开关需要明确产品契约；未推断兼容服务一定会 400。
2. 页面总服务数使用 `6 + configuredProviders.count`，内置启用计数却只计算 3 个可见开关（`SearchServicesView.swift:350`、`:362`），统计口径不一致，优先级低于请求链问题。

## 实际验证与限制

本轮执行了：

- 配置路由 harness：逐字抽取当前 Swift 的 12 个函数，Settings/provider/UUID 仅提供边界 stub。确认免费开关绕过、排序后仍使用 selected、20/50 都截成 10。没有使用 9 月旧 macOS Shared.framework 作为当前实现证据。
- 免费聚合 harness：原 `IOSFreeSearchAggregator.swift` 文件逐字复制，SHA-256 与工作区一致，验证结果不足阈值、取消语义与 URL 大小写去重。
- 免费公开源的有限查询，原解析器得到 DuckDuckGo 10、Bing 10、360 5、夸克 9、Wikipedia 2、HN 5 条；Brave 返回 429。这证明本次 Mac 网络返回数据能被当前解析器消费，不代表 iOS 网络环境或每个查询的质量验收。
- Jina 无 Key 请求：HTTP 401；没有使用用户 Key 或付费额度。
- 原 HTTP transport + resolver 注入：0.2 秒请求超时、100ms 取消，仍等待约 3 秒 DNS 返回。主审独立重跑得到相同现象。
- 设置、工具接线、供应商、免费聚合分别审查，并独立复核主要候选。Kotlin 删除逻辑为当前源码与可达步骤复核，未执行 Kotlin 测试。

临时证据：

```text
/tmp/amber-search-settings-audit-20261025/output.txt
/tmp/amber-search-settings-audit-20261025/build_harness.py
/tmp/amber-search-settings-audit-20261025/source-manifest.json
/tmp/amber-free-aggregator-harness/report.txt
/tmp/amber-free-aggregator-harness/Aggregator.swift
/tmp/amber-search-provider-audit/report.txt
/tmp/amber-search-provider-audit/Stubs.swift
```

未运行既有 XCTest、全量 Xcode 构建、付费供应商真实凭据请求、Google WKWebView/模拟器/真机交互。尝试枚举模拟器时，本机 `xcrun simctl` 停在其启动的 `xcodebuild -runFirstLaunch`，本次命令已中断，没有将未启动的测试记为通过。没有新增或修改产品代码。

建议修复顺序：先补搜索能力权限和 Jina 认证；再统一供应商选择、删除、免费开关与数量语义；最后处理聚合阈值、取消、去重及备份后的管理入口。每项修复应增加对应行为验证，不能沿用当前会把错误服务端契约 mock 成成功的 Jina 测试。
