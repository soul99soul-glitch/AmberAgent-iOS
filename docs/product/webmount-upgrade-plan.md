# WebMount 升级计划（iOS）

日期：2026-09-25。范围：`ios/` 构建根内的 iOS WebMount（WKWebView 本地会话）。桌面远程后端只保持兼容，不在本计划内扩展。

参考：huashu-chrome（动作证据、站点经验）、webcmd（站点记忆）、browser-use/workflow-use 与 Stagehand（学一次、确定性重放、自愈）、reverse-api-engineer / peek-api（网页即接口）、alibaba/page-agent（纯页内 DOM 处理）、Midscene（运行报告）。

## 总原则

- 现有安全不变量不变：动作仍必须使用当前快照内的 ref；敏感字段、登录/验证码/支付仍交还用户；后果性动作（提交、发布、删除、支付）每次执行都走审批；页面与记忆内容一律按不可信数据对待。
- 精准实现：只做本计划列出的能力，每个新增字段都要有消费者；不加推测性的兜底、配置项或抽象层。
- 每个阶段都要有：KMP 声明（如涉及）+ Swift 执行入口 + 受影响的单元测试 + 可见 UI 入口（如有）。修改 KMP 时同时跑对应 Gradle 测试。
- 不新增依赖，不修改与本计划无关的在途改动。

## 阶段 0：度量基线与小修正

目标：让后续每个阶段的收益可以被量化，同时补三处已确认的缺口。

1. 运行度量：每次 WebMount 相关的 Agent 运行，按会话汇总调用次数、`wm_*` 调用次数、失败/拒绝次数、交还用户次数、墙钟时长。数据来自已有的工具调用记录，不新建遥测通道。
2. 运行报告：在 WebMount 会话页可打开“运行报告”，按时间线展示每一步的工具名、目标摘要、回执三元组（`dispatched` / `page_changed` / `goal_verified`）与错误码。只展示，不回放、不上传。
3. 基准任务清单：`docs/product/webmount-benchmark.md` 列出 15–20 个真实任务（只读、表单、翻页取数、canvas、需登录），每个任务写明站点、目标、完成判据、期望的最大轮数。清单用于手工/真机复测，不接入 CI。
4. 正文凭据隐去：`wm_extract` / `wm_get` 返回的可见文本中，成组出现的高熵字符串（恢复码、API key、token）替换为 `[已隐去 N 行疑似凭据]`，并在结果中标记 `credential_redacted`。
5. 目标附近归因：动作回执的 `page_changed` 只采信目标元素所在区域、文档/URL 变化、焦点变化或新出现的对话框；与目标无关的全局 DOM 变化（信息流、弹幕、计时器）不单独判为本次动作生效，并在回执中说明 `unattributed_page_activity`。
6. 页面漂移提示：会话在 Agent 最近一次观察后被用户或站点导航到别的 URL/文档时，不带 ref 的读取（`wm_extract`、`wm_get`、`wm_state`）在结果中给出 `page_drift` 及前后 URL。

完成标准：上述能力有单元测试；运行报告在模拟器中可见且布局正确；基准清单落盘。

## 阶段 1：语义定位（Locator）

目标：让“同一个元素”能够跨快照、跨刷新被重新找到，这是记忆与重放的地基。

1. 记录：每次对 ref 执行 click / tap / type / select 时，桥脚本同时生成该元素的语义指纹：`role`、可访问名称、可见文本（截断）、`name`/`placeholder`/`aria-label`/`data-testid` 等稳定属性、最近的地标祖先（form/nav/main/dialog 的名称）、同类序号，以及页面 URL 模式（去掉 query 值）。敏感字段不记录值。
2. 解析：`wm_find` 新增 `locator` 参数；解析规则是按指纹打分，恰好一个高置信候选才返回 ref；零个或多个时返回 `locator_not_found` / `locator_ambiguous` 及候选摘要，不猜。
3. 回执：动作回执中附带 `locator`，供后续阶段直接复用。
4. 不变量：locator 只用于找回 ref，动作本身仍经过快照/文档校验与审批。

完成标准：页面刷新、同结构重排、无关节点插入后仍能唯一找回；结构确实改变时明确失败。单元测试覆盖打分与歧义。

## 阶段 2：站点记忆

目标：同一站点第二次执行任务时少走弯路。

1. 存储：每个站点（host）一份结构化记忆，存在 App 本地（与站点设置同处），字段：`pages`（URL 模式与用途）、`actions`（名称 + locator + 说明）、`pitfalls`、`cannot_do`、`apis`（阶段 4 填充）、每条的 `updated_at` 与 `source`（agent/user）。
2. 读取：`wm_open` / 会话首次观察某 host 时，结果中附带该站点记忆摘要（有预算上限），标注 `untrusted_site_memory`，并说明“与页面实际不符时以页面为准”。
3. 写入：新增 `wm_site_memory`（`read` / `propose`）。Agent 只能提出修改；修改以卡片形式在会话中展示，用户确认后才写入。写入前去掉 URL query 值、邮箱、手机号、订单号等个人信息。
4. UI：站点详情页新增“站点记忆”分区，可查看、删除单条、清空。

完成标准：记忆的提出—确认—读取闭环有测试；站点详情页在模拟器中布局正确。

## 阶段 3：学一次、确定性重放、自愈

目标：重复任务不再每次都需要模型推理。

1. 提炼：一次运行中存在成功且 `goal_verified` 的 WebMount 动作序列时，`wm_recipe_candidates` 从该会话的工具调用记录生成 Recipe 草稿：ref 替换为阶段 1 的 locator（通过 `wm_find` + 绑定串联），用户输入的文本变为 Recipe 输入参数，等待条件保留。
2. 确认：草稿走现有 Recipe 的预览/保存/哈希流程；权限包络由步骤推导，不静默扩大。
3. 重放：Recipe 中 `wm_find(locator)` → 动作的链路按现有 Runner 执行；后果性动作每次仍审批。
4. 自愈：某步 `locator_not_found` / `locator_ambiguous` 时，Runner 停下并返回可修复信息；Agent 可用当前观察修正该步，修正后生成 Recipe 差异，用户确认后更新版本。不静默改写。
5. UI：Recipe 列表中标出来源为“从 WebMount 运行生成”，并显示最近一次重放结果。

完成标准：从运行记录到草稿、到重放、到定位失败时的修复提案，全链路有测试。

## 阶段 4：数据层

目标：拉列表/表格类任务从“点界面”变为“调接口”。

1. `wm_network_inspect`：在页面世界注入最小的 fetch/XHR 记录器（环形缓冲），只记录方法、去值 URL、状态码、内容类型、响应 JSON 的键结构；Agent 读取时得到端点目录。
2. `wm_signed_fetch`：在会话页面内对同源 URL 发起请求（随页面 cookie），仅限已注册站点；GET 直接执行，非 GET 按副作用走审批；支持 `page` / `cursor` 分页参数与页数上限；结果可写入 Workspace JSONL；响应经过凭据隐去与预算裁剪，标注不可信。
3. 站点记忆的 `apis` 字段可由 inspect 结果提案写入。
4. 不做：跨域请求、暴露 cookie/Authorization 值、`wm_eval`、`wm_fetch_replay` 的任意重放。

完成标准：同源限制、方法审批、分页终止、Workspace 落盘均有测试；工具从 unsupported 列表移出且声明与 Swift 执行一致。

## 阶段 5：收尾

1. 全链路 review：声明（`Tool.kt`）→ 暴露（ToolSearch/Registry）→ Swift 执行 → 回执 → UI。
2. UI 细节统一检查：运行报告、站点记忆、Recipe 来源标注与现有 WebMount 视觉一致。
3. 文档：更新 README 的 WebMount 段落和本计划的完成记录。

不在本计划内：视觉坐标动作、钥匙串代填凭据、与 Android 的格式统一（需另行决策）。

## 进度记录

- 2026-09-26：阶段 0、1、2 已实现并各经一轮 review 修复（未提交）。最终回归在只含阶段 0–2 文件的隔离检出中进行：KMP `:ai-core:jvmTest` + `:feature:tools:api:jvmTest` 149 通过 / 0 失败；WebMount 相关 XCTest 173 通过 / 0 失败。UI 以模拟器定点布局截图验收（浅/深色、常规/AX5），真实 App 导航、真机与真实 provider 尚未验收；`webmount-benchmark.md` 的手工基准尚未执行。
- 阶段 2 限制：`wm_site_memory` 暂不允许作为 Recipe 步骤（避免自动批准绕过逐次审批），阶段 3 需重新设计该约束。
- 阶段 3–5 未开始。
