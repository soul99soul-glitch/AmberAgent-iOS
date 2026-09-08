# WebMount 登录链路与 UI review

范围：当前工作区 `IOSLocalToolExecutor.swift`、`WebMountView.swift` 及对应测试的未提交改动。基线为 `76a40de`。

验收目标：检查人工与 Agent 浏览权限、登录窗口、网页对话框、会话生命周期和 UI 布局是否形成完整调用链。三个 subagent 分别审查运行时、调用链和 UI；主 agent 核实并整合修复。

## Finding Ledger

| 状态 | 风险 | 发现与处理 |
| --- | --- | --- |
| fixed，定向测试通过 | P1 | 高风险 Agent 可通过 `wm_site_add/remove` 修改站点配置。入口现在要求真实用户确认，公共网站浏览仍直接绕过域名白名单；截图等已有高风险批准行为保留。 |
| fixed，定向测试通过 | P1 | 人工首页与地址栏采用不同策略。模拟器复现未启用给 Agent 的微博站点能打开首页，但手输认证 URL 被拒。现统一走 `openForUser(site:sessionId:url:)`，校验公共地址并消费返回错误。 |
| fixed，定向测试通过 | P1 | 无效 session 可能回退到当前 session；未登记观看站点的合成 ID 可能污染真实站点绑定。现无效 session 直接失败，合成站点不写 registry binding。 |
| fixed，定向测试通过 | P1 | JS 对话框只覆盖网页区域、多个可见层重复呈现、旧回调可能回答新对话框。现只在顶层容器呈现，覆盖工具栏，并按 dialog ID 回答。 |
| fixed，定向测试通过 | P1 | 离页、后台、popup 进程终止时 JS 对话框可能永久等待。现按可见 presentation host 管理等待；无可见页面、窗口进程退出、最后宿主离开均取消对应回调。 |
| fixed，定向测试通过 | P1 | `wm_state/observe/extract/visual_snapshot` 把底层错误包装为成功。现透传 `ok=false`、错误码和原因。 |
| fixed，定向测试通过 | P2 | 会话移除后旧 runtime 仍可持有公共导航权限。现关闭 runtime、取消挂起加载并拒绝后续导航。 |
| fixed，源码复核通过 | P2 | inspector 与 popup 的两个 sheet 竞争；多窗口没有选择入口。现单 sheet 状态与待呈现队列，保留原 WKWebView，支持窗口选择；观看模式关闭仅隐藏窗口。 |
| fixed，卡片截图与源码复核通过 | P2 | popup 错误提示盖住网页，按钮触控区域不足，窄屏地址栏拥挤，提交后键盘不收起，长文本与大字体卡片可能超高。现安全区留白、44pt 触控区域、窄屏双行、键盘焦点管理与可滚动模态。 |
| fixed，源码复核通过 | P2 | 接管后旧提示覆盖新状态，popup 未关闭时 Cookie 摘要不刷新。现清理旧提示并在 popup 导航完成后刷新摘要。 |
| fixed，定向测试通过 | P2 | SPA 使用 History API 切换地址不触发完整加载，原生地址栏及导航状态可能滞后。现观察同源 URL 变化同步脱敏地址与 WebKit 导航状态；不改变跨域授权策略。 |
| needs-specialist / 时序验证缺口 | P2 | 同一 popup 并发跨域校验可能导致单槽批准记录误拒。静态审查提出风险，尚无真实 WebKit 顺序复现；不以推测扩大授权缓存。仍需复杂 SSO 并发跳转实测。 |
| not-reproducible / 既有契约 | P2 | lease 到期后保留 run 绑定。既有 `testWebMountSessionTTLAndPersistentMetadataRestoreFreshRuntimeOnly` 明确要求保留绑定供同一 run 续用，结束 run 才释放，因此未按误报清空。 |

## Verification

- 改动前模拟器实测：微博首页与访客认证跳转可加载；人工地址栏失败已复现。
- `git diff --check`：通过。
- 最新综合定向测试：100 项，98 项通过；1 项既有 SVG/输入焦点失败，1 项新增 SPA 测试的断言前提有误（URL 片段会脱敏，且 loadHTMLString 在 iOS 27 不保证生成返回历史项）。SPA 测试改为验证 pushState / replaceState 后的安全路径和 WebKit 实际导航状态，避免依赖 HTML fixture 不稳定的历史条目。最终运行时套件 18/18 通过；结合综合回归，当前唯一未通过项为前述输入焦点测试。
- 最终运行时证据：`Test-iosApp-2026.09.08_12-31-48-+0800.xcresult`；综合回归证据：`Test-iosApp-2026.09.08_12-19-10-+0800.xcresult`。
- 小屏 320×360pt 与辅助功能大字体 320×568pt 实际渲染截图已复核：左右边距、卡片宽度与按钮对齐正常；长文本滚动，操作按钮可见。证据：[紧凑布局](assets/webmount-compact-dialog.png)、[大字体布局](assets/webmount-large-text-dialog.png)。
- 真机 Experimental GPL 构建和严格签名检查通过；包标识为 app.amber.ios，包含 iSH fs，UIBackgroundModes 为 audio、processing。真机当前 unavailable，本轮修复尚未覆盖安装。
- 前一轮广泛回归：180/183 通过，两个既有聊天滚动测试和一个网页输入框测试失败；本轮不修改聊天滚动代码。

## Changed Files

- `iosApp/iosApp/IOSLocalToolExecutor.swift`：权限入口、人工打开、原生 WebKit 窗口/对话框与会话生命周期、底层错误透传。
- `iosApp/iosApp/WebMountView.swift`：统一 sheet 状态、对话框遮罩、可见宿主管理、地址栏与紧凑布局。
- `iosApp/iosAppTests/IOSLocalToolExecutorTests.swift`、`iosApp/iosAppTests/IOSWebMountRuntimeEvidenceTests.swift`：调用链回归、真实 WKWebView 行为与渲染截图。
- 简化：人工首页和地址栏复用同一入口；两个竞争的 sheet 合并为单一状态；删除废弃 JSON 辅助函数。未新增依赖。

## Still Open

- 既有 `testWebMountDecorativeSVGClickIsRejectedWithoutInterruptingInput` 仍失败：focus 返回成功，但重新 observe 未发现可输入元素。失败发生在本轮未修改的输入桥接路径；缺少精确基线，不能断言无关或已经修复。已交由 subagent 核实，尚不能区分 iOS 27 焦点事件兼容性与 DOM 更新时序。
- 标准系统 OAuth 仍缺网站注册的 client ID、授权地址、回调与业务消费配置；没有宣称已接通，也不支持读取 Safari 任意 Cookie。
- Cookie 摘要/清理按目标站点域名过滤。不能把第三方身份提供方的 Cookie 当成目标站点已登录，也不能为此自动扩大白名单或清理其他站点数据。
- 真实账号登录、复杂 SSO 跳转和真机键盘手感仍需实测。Mac 当前锁屏且 CUA 无法自动解锁，最后一轮手动地址栏/键盘交互未完成；前述渲染截图复核已经完成。

Verdict：PARTIAL。主要调用链修复已有定向回归证据，紧凑/大字体卡片已有截图证据；既有输入焦点失败、复杂 SSO 与真实账号/真机验证仍未关闭。
