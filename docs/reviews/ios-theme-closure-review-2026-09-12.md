# iOS 主题扩展 review · 2026-09-12

审阅时结论：正常单次生成、试穿、保存与重载路径基本闭环，但多会话审批归属、错误收尾和部分 UI 几何消费仍有遗漏。

后续修复状态：R1–R6 已完成最小修复，验证结果见文末。下文保留原审查触发条件与证据，不代表这些问题仍未修复。

本轮由三个独立子代理分别检查审批生命周期、设计渲染、UI 几何；主代理复核源码并在 iPhone 17 Pro / iOS 26.5 Simulator 检查真实首页、外观页与聊天页。未调用真实 provider 生成主题，未做真机验收。

## 需要修复的问题

### R1 · P1 · 多会话试穿可能保存 A、实际提交 B

- 触发：会话 A 生成主题 A 并等待审批，再在另一个会话生成主题 B，随后批准 A。
- `ChatToolRuntime` 各自持有 `IOSThemePackToolService`，服务缓存自己的 `prepared`；全局 `AmberThemeRuntime` 却只有一个候选。第二次 `beginTryOn` 覆盖全局候选。
- `commitPreparedImport()` 用自己的 `prepared` 入库，然后无参数调用 `runtime.commitTryOn()`，后者提交全局当前候选。因此入库配方、实际画面、成功返回 id 可以不一致；旧审批的还原也可能撤掉新试穿。
- 位置：`iosApp/iosApp/IOSThemePackToolService.swift:60-72`、`iosApp/iosApp/PlaceholderViews.swift:640-664`、`iosApp/iosApp/ChatToolRuntime.swift:382`。
- 建议：候选绑定 conversation/run/toolCall 的审批身份，提交与还原都核验 owner 和 candidate；不能只依赖主题 id。
- 证据：源码可达调用链；尚未以两个真实 provider 会话运行复现。

### R2 · P1 · 切换会话后顶部试穿条绕过原审批

- 触发：A 中存在待批准主题，切换到没有该审批的 B，再点击顶部试穿条的套用或还原。
- `AppShell` 只查询当前 `chatViewModel.pendingMcpApproval`。查不到时直接操作全局主题，原会话的审批等待者没有被完成。返回 A 后会留下旧审批卡，可能报 `noActiveTryOn`，也可能碰到另一个候选。
- 位置：`iosApp/iosApp/AppShell.swift:356-395`，外观 takeover 通知也只处理当前审批（222-226）。
- 建议：试穿条携带原审批归属，通过原 Host 的统一批准/拒绝入口完成；明确区分真正无 owner 的本地试穿与暂时不在当前会话的审批。
- 证据：源码可达调用链；不是正常单会话测试已经覆盖的场景。

### R3 · P2 · 套用失败后顶部操作可能一直禁用

- 触发：通过顶部条确认一个有待审批请求的主题，主题库写入发生权限/磁盘等错误。
- 顶部条先设 `isResolvingThemeTryOn = true`；审批异常分支只返回工具错误，没有清理试穿。解锁逻辑只在 `isTryOnActive` 变为 false 时触发，失败后仍 active，顶部条无法直接重试或还原。
- 位置：`iosApp/iosApp/ChatToolRuntime.swift:1849-1858`、`iosApp/iosApp/AppShell.swift:195-204,367-372`。
- 建议：错误结果必须结束 resolving 状态，并明确恢复 baseline 或保留可操作的重试/还原状态；同时保证 R1 的候选身份一致性。
- 证据：错误分支源码；本轮未注入磁盘写入失败。

### R4 · P2 · 议会用户气泡长按预览仍固定 18 pt

- 触发：`components.bubbleRadius = 0` 或 `28`，在模型议会长按用户消息。
- 气泡本体已复用动态 `ChatUserBubble`，议会的 `.contextMenuPreview` 仍自行创建 18 pt 形状；主聊天已统一，议会漏接。
- 位置：`iosApp/iosApp/CouncilChatRuntimeView.swift:947-959`；对照 `iosApp/iosApp/ChatMessageListSupport.swift:75-93`。
- 建议：与主聊天一样复用 `ChatUserBubble.bubbleShape`。
- 证据：静态形状参数确定；本轮未在议会实际长按截图。

### R5 · P2 · 搜索焦点环没有跟随控件圆角

- 触发：`components.controlRadius = 0` 或 `28`，首页展开搜索框并获得焦点。
- 本体通过 `homeGlassControl` 读取自定义圆角，焦点环仍固定 14 pt，焦点边缘与玻璃轮廓不贴合。
- 位置：`iosApp/iosApp/PlaceholderViews.swift:2638-2644`。
- 建议：本体和焦点环使用同一 resolved radius。
- 证据：矩形搜索框已在模拟器看到；焦点环不匹配由可达源码确定，本轮截图未捕获已聚焦高亮。

### R6 · P2 · 自定义主题卡的标题底仍使用旧纸色

- 触发：安装一份自定义 surface/foreground 的主题，尤其其深色配色与基础 paper 差别很大时。
- 小预览已经按 `document.design` 和当前明暗模式绘制，上方预览下面的名称区域却始终取 `paper.lightPalette`。同一主题卡呈现两套配色，无法准确预览完整主题。
- 位置：`iosApp/iosApp/AppearanceSettingsView.swift:280-302,310-316`。
- 建议：有 design 的卡片 footer 与预览用同一套 resolved palette；旧内置主题保留原轻量预览策略。
- 证据：源码；本轮实际外观截图中只有内置主题卡，没有单独构造已安装自定义主题的 footer 截图。

## UI 观察、边界与未能归因的现象

- 默认首页没有观察到明显重叠、对齐错位。允许范围内的直角、粗描边、大阴影已在实际首页/聊天控件显示。
- 15 个中文字符、40 pt 字号、6 pt 字距时，首页品牌会缩小并截断，但没有挤压搜索/设置/头像。这属于现有单行限制，不单独算 bug。
- 缩略图将卡片圆角按比例缩小是预览策略，不把“13 pt 对 26 pt”本身算作缺陷。
- 首页上方控制卡有粗描边，会话列表没有。这是当前文档已明确的部分覆盖，属于可继续开放的设计范围，不能据此声称所有卡片已经统一。
- 聊天模型按钮的视觉圆角随主题改变，点击区域仍使用 15 pt 形状和 44 pt 最小高度（`ChatView.swift:1508-1512`）。最小触控区域扩大是合理设计，角落命中是否产生实际可感知问题仍需专门点击验证，不列为高优先级确定性 bug。
- 工具缺省 scope 为 shell、旧文件缺省为 homeOnly，是已有兼容策略；工具导出会写明 scope，不把缺省差异直接当作导出/导入断链。
- 测试模拟器通过四个 UserDefaults 主题键加载样本，首页显示了渐变与点阵，外观与聊天截图却显示纯色；首页也有横向色调带。由于未同时读取进程内 runtime 状态，且源码未找到确定遮挡层，本轮只能确认现象，不能断言 `appWide` 渲染实现有 bug。临时样本是 design 子对象，不是通过文件导入入口导入的完整主题包，不能用文件缺省 scope 直接解释现象。
- 小应用内部 HTML 没有同步完整 design，许多业务组件还保留固定样式，属于本轮已声明的范围边界。

截图：

- [默认首页](/tmp/amber-theme-review-20260912/home-baseline.jpg)
- [极端参数首页](/tmp/amber-theme-review-20260912/home-boundary.jpg)
- [外观浅色](/tmp/amber-theme-review-20260912/appearance-light.jpg)
- [外观深色](/tmp/amber-theme-review-20260912/appearance-dark.jpg)
- [聊天控件](/tmp/amber-theme-review-20260912/chat-boundary.jpg)

## 本轮实际修改与验证

用户追加要求移除“生成并试穿”的星星图标，已仅将该按钮改为纯文字。其余 review 问题未自动修复。

该 Swift 文件语法检查与 `git diff --check` 通过。完整模拟器编译遇到当前并行 SSH 改动的 `IOSSSHPrivateKey` 未入作用域及 `IOSSSHRuntimeBackendProtocol` 不符合问题，本轮没有修改这些文件，因此不能声明去图标后的完整构建通过。

临时修改的四个模拟器主题偏好已恢复并逐值核对，外观模式恢复 Follow System；重新启动确认首页字标恢复 Amber 后停止 App。当前未重跑上一轮已通过的 78 项主题测试；本轮也没有完成真实模型、真机或长表格性能的新增验收。


## 后续精准修复与验证

- R1：每次试穿生成一个实例 id，service 只保留该 id，提交从匹配的 session 取 candidate；旧 service 的提交会明确报已替换，旧取消不会影响新试穿。
- R2：session 保存已有 runId/requestId。顶部条和外观 takeover 按这两个标识定位原 Host，复用现有审批清理入口；不再根据当前选中会话猜测 owner。
- R3：保存失败时仅清理本 service 的试穿、恢复 baseline；顶部 resolving 随 session 身份变更解除。取消/终态清理也调用现有的主题清理入口，避免批准后立即取消留下孤立试穿。
- R4：议会长按预览直接复用 `ChatUserBubble.bubbleShape`。
- R5：搜索焦点环使用与控件本体相同的 `AmberTheme.controlRadius(14)`。
- R6：自定义主题卡 footer 根据当前浅深模式解析 design 配色，旧主题保持原 light 预览策略。
- “生成并试穿”继续使用纯文字按钮。

未新增审批框架、锁、轮询、重试或持久化恢复层；只增加试穿实例/审批归属字段及现有入口的核验和收尾。

验证：

- 最终代码的模拟器编译通过。
- 新增最少行为用例覆盖交错 service、写盘失败，以及真实 ChatViewModel/Host 中跨会话批准归属与批准后取消。只替换 provider 为可控脚本，没有真实网络生成。
- 首轮主题、会话切换和规定的三个聊天回归测试组执行 176 项，只有长文高度发布的时序阈值未通过；删除一项与实际路由测试重复的字段赋值测试后，最终相关 18 项定点复测全部通过，包括取消收尾补丁和该长文用例。没有改动时序阈值或动画。
- 实际模拟器外观页已确认自定义主题的深色 footer 与预览一致，且生成按钮无星星：[修复后截图](/tmp/amber-theme-fix-appearance-dark.jpg)。临时主题库和外观模式已恢复。
- 真机、真实 provider 仍未验收；单次复测通过不代表已证明所有设备上的长文时序稳定性。
