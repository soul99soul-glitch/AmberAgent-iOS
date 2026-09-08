# WebMount 自动化审计与回归记录

日期：2026-09-08。工作区：`/Users/arquiel/Downloads/AI/AmberAgent/ios`。

后续用户要求继续修复 Fake-IP，新增的 HTTPS 兼容实现与最新验证记录见 [WebMount Fake-IP 续修](WEBMOUNT_FAKEIP_FIX.md)。本文以下的“Fake-IP 尚未修复”描述保留为初轮审计状态。

本报告针对用户提供的 A–F 测试记录及当前源码。没有取得原测试的完整工具 payload、设备日志、WKNavigationAction/Response、DNS 答案、视觉请求与服务端请求 ID，不能将当前代码缺陷自动认定为原设备上的全部根因。已有工作树改动保留；本次没有发布、安装真机、操作账号或更改 DNS/白名单。

## 第一阶段：实际调用链

| 层 | 文件与真实入口 | 作用与边界 |
|---|---|---|
| 工具声明 | `ai-core/src/commonMain/kotlin/app/amber/ai/core/Tool.kt`：`createWebMount*ToolDeclaration`、`putWebMountSessionId`、`putWebMountSnapshotId`、`putWebMountPostcondition`、`webMountTargetParameters`、`webMountWaitParameters` | JSON schema、参数说明；不负责最终信任判定。 |
| 搜索与声明暴露 | `feature/tools/api/src/commonMain/kotlin/app/amber/feature/tools/IosToolExposureBridge.kt`：`executeToolSearch`，`ToolSearch.kt` | WebMount 为延迟工具，命中后保留导航/观察/等待工具及 workflow hint。工具被暴露不等于权限、后端或视觉模型可用。 |
| 工具风险 | `feature/tools/api/src/commonMain/kotlin/app/amber/feature/tools/ToolRegistry.kt`：WebMount metadata/risk/concurrency 分支 | 交互动作 Sensitive、需批准、按 session 分组，禁止并发突变；不能仅从声明的 `needsApproval` 单字段判断权限。 |
| Swift Agent 执行 | `iosApp/iosApp/ChatToolRuntime.swift`：`executeWebMountToolCall`、`dispatchWebMountToolCall`、`webMountToolExecutionOutput`；`IOSLocalToolExecutor.swift`：`executionRequest`、`execute`、`resolveWebMount`、`webMountActionPreflight` | 生成 scope/payload digest、权限策略及高风险预检。当前正常 ambiguous 留在模型循环以便只读观察；中断的 `unknown_after_action` 进入恢复流程。 |
| 控制器 | `iosApp/iosApp/IOSLocalToolExecutor.swift`：`IOSWebMountController.execute`/`executeResult`、`sessionRuntime`、`preflightUserAction`、`interactionGateOutput` | 解析参数、run/conversation/session 所有权、target/snapshot 绑定、敏感字段与副作用批准；Agent 不允许 CSS/坐标突变。 |
| URL 策略 | 同文件 `IOSWebMountURLPolicy.validate`、`validateResolvedPublicHost`；`openResult`、`localSessionPolicyFailure`、`remoteURLIsAllowed` | 协议、凭据、站点白名单以及未注册域名的公开 DNS 判定。注册主机保留原可信白名单路径；并未声称注册主机也做公开 DNS 判定。 |
| WK 桥接 | 同文件 `IOSWebMountWKRuntime.interact`、`state`、`observe`、`get`、`evaluateJSON` | 固定命名的 isolated `WKContentWorld`，执行受限生成脚本，不向 Agent 开放任意 JS。 |
| DOM 引用 | 同文件 `IOSWebMountBridgeScripts.semanticPrelude`：`amberBridge`、`refFor`、`resolve`、`refreshFrames` | `wm:<documentId>:<counter>`、WeakMap/refs 注册；检查文档、连接状态、frame。动作在 JS 内检查快照；失效时拒绝，不猜 CSS/坐标。 |
| 动作和等待 | 同文件 `IOSWebMountBridgeScripts.interact`、`waitProbe`；`IOSWebMountWKRuntime.waitForCondition`；控制器 `webMountPostconditionOptions`、`webMountStateDiff` | 分开派发、真实页面变化、具体条件验证；快照版本本身不能证明 DOM 变化。 |
| 观察与脱敏 | 同文件 `IOSWebMountBridgeScripts.extract/get`、`observeResult`、`getResult`、`IOSWebMountRedactor` | DOM 可见信息、非敏感输入值、字段级裁剪；URL query/fragment、敏感字段和令牌脱敏。 |
| 二次输出预算 | `iosApp/iosApp/ChatToolSupport.swift`：`ChatToolOutputFormatter.cappedToolOutputParts`、`cappedStructuredJSON`；消费于 `ChatToolRuntime.messagesByFinishingToolCall` 与 `IOSContextCompactionCoordinator` | 工具结果落盘及上下文压缩都会再次裁剪。原通用最长字符串减半算法不保护 URL。 |
| 截图与视觉 | `IOSLocalToolExecutor.swift`：`IOSWebMountWKRuntime.screenshot` → `WKWebView.takeSnapshot` → PNG；`visualReadResult` 检查截图前后 snapshot；`IOSWebMountVisionReader.swift`：`read`、`resolveVisionModel`、`RequestFailure` | `UIMessagePart.Image(data:image/png;base64,...)` → `IOSAgentTextProvider.generateText`；支持 native chat vision 或配置的 OCR 模型。截图分析完成也不等于动作目标达成。 |
| Provider 图片编码 | `iosApp/iosApp/IOSAgentToolEngine.swift`：`OpenAIKmpProviderAdapter.generateText`；`ai-provider-openai/src/commonMain/kotlin/app/amber/ai/provider/openai/OpenAIKmpProvider.kt` 图片分支；`iosApp/iosApp/IOSGeminiProvider.swift` | Provider 决定 Responses/ChatCompletions 等请求格式；本轮不改已有 provider WIP，不推断 HTTP 400 的具体服务端原因。 |
| 导航事件 | `IOSLocalToolExecutor.swift`：`IOSWebMountWKRuntime` 的 `WKNavigationDelegate` / `WKUIDelegate` 回调 | 记录新窗口请求、策略拒绝、下载线索和失败；未自动创建额外会话或重新点击。 |
| 远程后端 | `iosApp/iosApp/IOSWebMountDesktopBackend.swift`：`connect`、`execute`、`semanticTarget`、`mappedTarget`、`actionPreflightOutput`、`normalizedObservation`、`mappingIsAvailable` | 远程工具 schema 能力、snapshot/document/semantic identity 复核；只有 selector 的 gateway 不再宣称支持 Agent semantic target。 |
| 中断与恢复 | `iosApp/iosApp/IOSAgentToolEngine.swift`：`executeBatch` 的 `.outcomeUnknown`；`ChatToolRuntime.isWebMountInterruptedOutcome` | 中断调用记为结果未知，已有 ledger 不自动重放；普通等待超时允许模型继续观察，不等于授权重试。 |

## 证据表与优先级

| 记录/优先级 | 归类 | 结论与证据状态 |
|---|---|---|
| A / P1 | 外部环境，兼有明确的策略分层 | **已证实（代码）**：未注册域名解析到保留/私网地址会 `dns_non_public_address`；注册主机保留白名单路径。`siteFromArgs` 对 direct URL 也按 host 查站点，因此不是 `site_id` 字段专属豁免。**待复现**：Wikipedia/example.com 当时的 DNS；**推测**：VPN Fake-IP。不同域名不能构成对照实验。 |
| B / P1 | 工具实现缺陷 | **已证实（代码）**：controller、preflight、JS driver/get 使用 `selector ?? target`，空字符串遮蔽 target。**待对照原设备版本**：这是否解释全部原始调用。双填是线索，修复后最短调用只填 target。 |
| B / P0 安全不变量 | 工具契约 | **已证实（代码）**：动作的 snapshot/document/ref 校验已存在；冲突字段过去不一致，可能按不同字段预检和执行。本轮统一冲突拒绝，不借 CSS/坐标绕过引用。 |
| C / P1 | Agent 验证条件设计错误 | **已证实（用户记录与代码语义）**：原页已 complete，不能证明点击成功；“搜索结果”与真实页面“结果: 找到…”不一致，wait 失败不代表搜索失败。没有对 A9VG 硬编码文本。 |
| C / P1 | 工具实现能力缺口 | **已证实（代码）**：旧 diff 不含 document_id；revision 被动作人工增加；等待缺少新文档/URL baseline，超时缺少实际内容摘要。 |
| C / P1 | 站点/导航环境，工具诊断不足 | **待复现**：帖子未打开原因；**已证实（代码）**：原无 WKUIDelegate 新窗口处理，targetFrame=nil 归入 main-frame，事件诊断不足。不能据此断言帖子链接是 `_blank`、事件被取消或策略拒绝。 |
| D / P1 | 工具输出缺陷 | **已证实（代码）**：通用 JSON 裁剪可把 URL/title/visible_text 反复减到 12 字；页面提取又有自己的 slice，缺字段级标记。ref/id 等已有保护继续保留。 |
| D / P1 | 工具能力缺口 | **已证实（代码）**：观察列表不展示非敏感 input 当前值，虽已有 `wm_get(kind=value)`。输入动作本身已经做立即值相等校验；它只证明输入值，不能证明搜索业务目标。 |
| E / P1 | 服务拒绝；请求构造需审查 | **已证实（记录）**：HTTP 400/request_rejected，视觉未完成。**未确认根因**：具体模型能力、图片 payload、custom body 或 provider 服务。DOM 仍可用。本轮补模型/PNG 预检与安全诊断，不编造服务端错误细节。 |
| F / P1 | 工具语义缺陷 | **已证实（代码）**：anonymous 固定 logged_in；cookie marker 存在也被写 logged_in，均不足以证明有效登录。本轮区分 not_required、unknown、cookie_present_unverified，`login_verified=false`。 |
| P2 | 后续环境证据 | 公开 A9VG、真实 VPN/代理、实际视觉服务、真机及真实远程 MCP 必须单列证据，不用 fixture 或 mock 结果背书。 |

### Fake-IP 补充审计

用户指出 Fake-IP VPN 会令非白名单站点普遍不可用。这是当前公开 DNS 策略的真实兼容缺陷，不能只归类为用户网络配置错误。本轮不以添加白名单或放行 `198.18.0.0/15` 掩盖它。

本机 iOS SDK `WebKit.framework/Headers/WKWebsiteDataStore.h` 明确提供 iOS 17+ `proxyConfigurations`，可为使用该 data store 的 WKWebView 指定代理；公开依据为 [Apple WKWebsiteDataStore.proxyConfigurations](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/proxyconfigurations-6g21z?language=objc)。因此并非没有 WebKit 代理 API，也并非必须开发 Network Extension。当前项目没有接入此 API，也没有能证明实际目标地址的受信代理。

安全的兼容方向是让 WKWebView 通过明确配置的可信代理出站，并在代理建立到源站的连接时执行公网地址校验，覆盖重定向及后续连接；Fake-IP 只作为 VPN 映射，不作为源站地址证据。仅另外查询一次 DoH 再允许系统 Fake-IP 路径，无法证明两次解析/实际连接一致。本轮缺少实际 VPN 类型、可用代理 endpoint 与代理端目标校验能力，尚未实施此网络路径。当前仍可能拒绝 Fake-IP 下的非白名单站点，不能宣称完整兼容。

## 最小修改计划及实现范围

1. 统一 target/selector：空白 selector 当省略，相同值规范化，冲突拒绝；仍保持 session/snapshot/ref 绑定。复用已有引用和权限机制。
2. 增量回执：`dispatched`、`page_changed`、`goal_verified`；无法观测则用 null，不将未知写成 false/success。`ready_state`、`dom_stable`、单独文档/URL 变化仅证明准备状态/变化；具体目标由 Agent 提供 text/selector/url 条件或输入值验证。
3. 新增真实 `dom_revision`，与快照失效版本分离；wait 支持 document_changed/url_changed，具体后置条件可要求 page change。失败附一次有界最终观察和禁止自动重试提示。
4. 观察提供普通输入值、局部 get、源字段裁剪标记；WebMount 输出预算优先丢弃完整低优先级候选项，保留机器引用、URL 和关键文本。
5. 新窗口/下载只记录明确事件和当前不支持的动作；不自动换会话、重载、重新派发。视觉预检和 HTTP 400 测试不发送真实页面或凭据。
6. 修改匿名/未知认证语义；现有 DNS 拦截保持并用同域名、同配置直接 URL/site_id 对照测试。

## 回执阅读规则

- `tool_available=true` 仅表示该工具有实现；权限、站点和后端能力仍看具体拒绝码，视觉能力仍需预检。
- `dispatched=false`：本次未派发；先修正参数/权限再重新观察。`true`：动作已派发；`null`：中断或后端未提供足够证据。
- `page_changed=true`：观察到文档、URL、真实 DOM 或可见状态变化，不能推断业务成功；`null` 表示缺少可比较观察。
- `goal_verified=true`：本次声明的具体后置条件或动作值验证成立；它不验证 Agent 没有声明的更大目标。
- `ok=true` 不代表端到端成功。`final_observation` 是有限、脱敏且不可信的页面内容；后续操作仍使用其新 snapshot 或重新观察。
- 失败等待条件不自动重试动作；`retry.automatic_retry_allowed=false`。对可能重复发布/提交/购买等动作必须先核对效果。

## 第二阶段：实际验证

### 修改文件与关键 diff

| 文件 | 本轮修改 |
|---|---|
| `ai-core/src/commonMain/kotlin/app/amber/ai/core/Tool.kt` | 规范 target/selector 说明；observe 预算；document/URL 基线等待、require_page_change；回执阅读规则。该文件已有的其他工具改动不属于本轮。 |
| `iosApp/iosApp/IOSLocalToolExecutor.swift` | 统一参数与冲突拒绝；独立派发/变化/目标/准备状态；有界最终观察和重试提示；JS 文档/URL/DOM 证据；非敏感输入值；导航事件；登录和视觉错误语义。 |
| `iosApp/iosApp/ChatToolSupport.swift` | WebMount 专用预算优先级，完整保留 URL/ref/id，字段级裁剪元数据；无法兼顾预算与机器证据时明确 budget_exceeded。 |
| `iosApp/iosApp/IOSWebMountDesktopBackend.swift` | target 优先且忽略空 alias；冲突拒绝；只暴露能保持 semantic target 的远程映射。 |
| `iosApp/iosApp/IOSWebMountVisionReader.swift` | PNG signature/IHDR 尺寸预检；拒绝明确 text-only OCR；未知能力不冒充已证实的图片能力。保留用户原有的错误文案改动。 |
| `IOSWebMountAutomationContractTests.swift`、`IOSWebMountRuntimeEvidenceTests.swift`、`IOSWebMountOutputBudgetTests.swift` | 新增 9 个测试方法，合并覆盖本次必需的参数、快照、页面、值与输出证据。 |
| `IOSLocalToolExecutorTests.swift`、`IOSWebMountDesktopBackendTests.swift`、`IOSWebMountVisionReaderTests.swift`、`WebMountToolDeclarationsTest.kt` | 复用并增补 DNS 同域名对照、登录、远程能力、视觉 400/不可用与 schema 断言。 |

### 回归结果

模拟器：iPhone 17 Pro / iOS 26.5，测试串行执行。先运行 `xcodegen generate`。Kotlin：`:ai-core:jvmTest --tests app.amber.ai.core.WebMountToolDeclarationsTest`。

| 测试组 | 实际结果 |
|---|---|
| WebMountToolDeclarationsTest | 7/7 通过（JVM） |
| IOSWebMountAutomationContractTests | 3/3 通过 |
| IOSWebMountRuntimeEvidenceTests | 3/3 通过 |
| IOSWebMountOutputBudgetTests | 3/3 通过 |
| IOSWebMountDesktopBackendTests | 33/33 通过（模拟 MCP，非真实远端） |
| IOSWebMountVisionReaderTests | 13/13 通过（模拟 provider，未调用真实视觉服务） |
| IOSLocalToolExecutorTests | 72/72 通过，含已有 WebMount 与执行器回归；不是 72 个新增测试 |
| IOSToolRuntimeTests/testWebMountOutputTruncationPreservesActionReferences | 1/1 通过 |

**最终当前原始生产源码：Swift 128/128 通过，0 失败、0 跳过**，结果为 `/tmp/amber-webmount-final-20260908.xcresult`，日志为同名 `.log`；这次没有使用任何 VFS 源码替换。Kotlin 7/7 的明细为 `ai-core/build/test-results/jvmTest/TEST-app.amber.ai.core.WebMountToolDeclarationsTest.xml`。

前序验证曾被并行 WIP 的 Board 初始化与 ChatViewModel 调用签名阻塞；临时副本隔离后，首轮执行为 126/128，通过修正新增测试中“未启用站点”和“缺少文档基线”的设置后为 128/128。并行开发随后修好了原工作树的两处编译错误，因此最终重新使用原始生产源码验证，结果以上述 final xcresult 为准。未覆盖的全项目测试不计为已通过。

公开站点只读探针在 fixture 通过后实际执行，结果单列，不并入 128 项：

| 公开站点 | 实际结果 |
|---|---|
| `https://example.com/` | `wm_open` 返回 `dns_non_public_address`；页面未加载、未观察，页面验证受阻。 |
| `https://www.wikipedia.org/` | 同样返回 `dns_non_public_address`；页面未加载、未观察，页面验证受阻。 |

该探针使用真实解析器和控制器/WK 路径，开启 allowUnlistedHosts，未放宽 DNS 策略。临时编译副本仅把 WK 数据存储替换为 `.nonPersistent()`，导航前明确断言 isPersistent=false、Cookie 为空；它不是生产源码修改。默认数据存储版本曾被自动审批拒绝，因为可能携带已有 Cookie；改为上述隔离存储后获准运行。结果 `/tmp/amber-webmount-public-20260908.xcresult`：1 个探针为 **Skipped**，不是通过；test-details 明确记录上述两个拒绝码。由此证实当前模拟器环境也发生非白名单 DNS 拦截，但没有记录实际 DNS 答案或 VPN 配置，仍不能将 Fake-IP 认定为原设备的唯一根因。

| 用户要求的覆盖项 | 实际证据 |
|---|---|
| target-only / 空 selector / 同值 / 冲突 | 真实 WK fixture 点击计数为 3；冲突 dispatched=false 且不再点击；远程映射 mock 也通过。 |
| 过期 snapshot / 跨 session / DOM 引用失效 | 真实 WK 分别拒绝 stale_snapshot、跨文档 stale_ref、已移除节点 stale_ref；Agent CSS/坐标拒绝保留。 |
| 普通导航 / 同 URL 新文档 / SPA / 新窗口 | 既有导航、frame 与 fragment fixture 通过；相同 URL 的两次 loadHTMLString 产生不同 document_id；hash SPA 由同文档 url_revision 识别；真实 WK 新窗口请求记录 new_window_unsupported，未新建 session。 |
| 已派发但等待条件错误 | fixture 实际文本显示 PS5 结果，错误等待返回 postcondition_not_met、dispatched=true、page_changed=true、goal_verified=false，并附最终 DOM 摘要；点击计数证明没有自动重复派发。 |
| complete 已存在 / 准备状态 | 点击返回 postcondition_preexisting；单独 ready_state 等待 readiness_met=true，但 goal_verified=false。具体文本配 require_page_change 可验证本次变化。 |
| 输入后值验证 | wm_type 校验 PS5；wm_get 读取普通值；过期 get snapshot 拒绝；password 值拒绝或脱敏。 |
| 观察裁剪与脱敏 | 预算测试保持 URL/ref/id；描述和数组有字段级裁剪记录；普通输入短值可见，长值长度标记与敏感字段保护通过。 |
| 视觉不可用 / HTTP 400 | 缺 reader、缺模型、text-only、PNG 错误和 400 安全诊断通过；DOM-only 和 visual_verified=false 断言通过；原始 provider 错误中的秘密未外泄。 |
| DNS 拦截 / site_id 对照 | 198.18 Fake-IP、私网混合答案、空答案失败；同一已注册并启用主机通过 direct URL/site_id 的行为一致；非白名单 Fake-IP 仍拒绝。解析器为受控 mock，不能证明真实 VPN 已兼容。 |
| 未验证登录 | anonymous=not_required；cookie marker=unknown/cookie_present_unverified；所有这些路径 login_verified=false。 |

### 未解决事项及证据边界

- **Fake-IP 兼容尚未修复。** 需要实际 VPN 客户端、可用 HTTP CONNECT/SOCKS5 endpoint 及其连接目标校验能力。没有关闭 DNS/SSRF、增加白名单或放行保留网段。
- **A9VG 帖子跳转根因未复现。** 新窗口、策略/下载事件现在能提供线索，不能反推原链接一定是 `_blank`。A9VG 原搜索/帖子链路、原 iPhone/VPN 环境：**未运行**。
- **原视觉 HTTP 400 根因未确认。** 已检查 PNG→Image part→provider 参数路径；assistant/model custom bodies 仍会传给 provider，可能覆盖请求字段，但没有真实请求证据，不能认定这是原因。真实模型服务视觉验证：**未运行**。
- **真实远程 MCP / 真机安装和运行：未运行。** 远程无法提供本地同等的 document/DOM 证据时 page_changed=null；require_page_change 目前在派发前明确拒绝。远程未附加自动最终 DOM 抓取，需再次 wm_observe；本轮有界最终观察覆盖本地 WK 交互和失败打开。控制权已经丢失或调用取消时，不强行读取后来由用户控制的页面。
- 字段级裁剪覆盖本轮的可见文本、链接、输入值及输出预算；已有节点 name/nearby_text 的源端长度限制没有逐一新增长度元数据。预算在机器证据无法继续缩减时可能超限，并明确标记。
- 没有提交、推送、真机安装或真实账号写操作。工作区存在并行 WIP；上述清单不代表整个 git diff 都属于本轮。

## 修复后最短操作流程

1. 搜索/加载工具，`wm_tab_list` 取 session；`wm_open(session_id, url 或 site_id)`，区分权限/DNS 拒绝和派发后的未知结果。
2. `wm_observe(session_id)`，优先选 `interactive_elements` 中的语义 ref；保留同一 session、snapshot、target。
3. 调用动作时只填 `target`，省略 selector。输入后核对 `goal_verified` 的值验证；必要时重新观察或 `wm_get(kind=value)`。
4. 点击前依据已观察 DOM 设置具体 text/selector/url 后置条件；需要动作后的变化时加 `require_page_change=true`。完整加载/DOM 稳定只能用作准备条件。
5. 读取三个独立字段。未验证时先读 `final_observation`，或观察/局部读取实际结果，再修正验证条件；不盲重试原动作。
6. 视觉是额外证据。`dom_only=true` 时明确视觉未验证，继续报告有 DOM 证据的结果。
