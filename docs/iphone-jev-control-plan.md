# iPhone 自动化与 Jev：效果检查和短目标循环

日期：2026-10-11。用户授权两项一起实现；保留当前隧道、授权、runner 和已有未提交工作。此轮不改 Loon 接入、不提交或推送。

## 2026-10-12 通用连续操作修复

目标：修复真实运行中批量路径未执行、重复主模型往返的问题；不按 App 包名、题型或固定按钮文字分支。

- 保留 `phone_run_goal` 一个入口。省略 `actions` / `steps` 时，从每轮新观察生成具名点击候选，Jev 在目标范围内连续选择；明确步骤仍使用 `steps`，准确输入仍由主模型提供。空数组或 null 不作为自动模式的别名。
- 目标匹配先筛选动作支持的控件，再判断真实歧义；显式类型允许已有单步支持的 `StaticText` / `Other`。两个真实同名目标不能随意选第一个。
- 可选 `target.region` 使用屏幕比例矩形，匹配元素中心；让「内容在目标区域出现」成为可核验条件，避免把「原文字仍可见」误当选中。它同样适用于列表移动、分栏选择等场景。
- 无验收条件的成功 `phone_act` 也返回一次新观察，保留执行回执但不声称业务成功。后置读屏失败不能抹去已执行事实。
- 参数继续严格校验；未知的外层 `identifier` 明确指出应放进 `target`，不自动猜测或改写参数。
- 自由选择仍使用现有 Jev 模式、数据范围、版本和预算。新树截断、App/进程/屏幕上下文变化、无进展、未知回执及人工接手均停止；不会靠放宽这些条件提速。

本轮收口：

- Swift package 74 项测试通过；App 七组定点测试 123 项全部通过，覆盖声明/解析往返、前后台目录、人工接手、Jev 请求构造、循环、验收与真实 Runner 客户端的 HTTP 边界。
- 明确序列两次点击使用三次观察；live 两次点击使用三次观察及两次派发前内容复核，均在一次工具调用内完成。Jev 的 HTTP 响应由受控 transport 提供，不能据此声称真实决策准确率或速度已改善。
- 独立 review 确认并修复：动态决策期间换页仍匹配同名按钮、完成条件未传给 Jev、区域锚点在派发前丢失约束、弹窗覆盖下误报完成。加载/弹窗只读等待及 handoff 截图检查已贯通。
- 初次运行发现两处新增 fixture 计数断言不符，后续统一接口时发现测试闭包与参数顺序编译错误；均已修正后完整重跑，没有削弱生产验收条件。
- 最新 App 结果：`Test-iosApp-2026.10.12_17-00-09-+0800.xcresult`，构建日志 `/tmp/amber-general-phone-fixes-closure.log`。`git diff --check` 通过。
- Live 模式生成点击候选；输入和滑动仍使用已有显式 actions/steps 或滚动工具。没有新增 App 特例、设置或依赖。
- 修复版 Release 已原位安装到 iPhone18Pro 并启动，签名/五个组件标识与既有安装一致，375 个会话索引条目保留，Jev 与手机控制四项设置字节一致，当前模型仍为 deepseek-flash。两项全局 JSON 启动后重写，只有安装前字节哈希，未据此声称所有配置逐字段相同。安装证据在 `iosApp/build/PhoneSequenceDevice-20261012/install-verification-live/`。真实 Jev 决策质量、页面切换时序和端到端速度仍待实测；未提交或推送。

## 17:17 真机复测后的定点修复

真实运行 `9ECB29CE-DE27-4FFC-9B5B-371916EA39AA` 未进入 live 路径：三次 root actions、一次 steps；三次 actions 中一次因省略 type 的 Other 词块被拒，另外两次在第一个词之后用最终 completion 做远端中间复核而 handback；steps 的题干同时匹配 Other 和 StaticText，被误判 page_changed。单步观察复用已生效，但没有消除这些返回主模型的路径。

本次只修正现有共享路径：

- 删除非 sequence loop 的中间 advise 分支，候选清单与 live 共用后续选择及派发前上下文复核。中间未达到最终 completion 不等于无法继续；界面无变化、unknown、预算和作用域检查仍有效。
- 共享目标匹配只合并真实祖先控件及其同 label、包含在控件内的 StaticText；兄弟或跨分支重名仍是歧义。点击、锚点、验收、live 候选共用，显式 type 仍精确匹配。
- 具名 Other/StaticText 无需模型补 type 才能点击。新工具声明收敛为目标模式和 steps；旧 root actions 请求仍可执行，用于承接既有参数和冻结任务。
- 按最新明确的模式契约分流：live 目标已达成时可零动作 completed；显式旧 actions 在尚未派发动作时发现 completion 已满足，返回 completion_already_satisfied handback，保留新观察并提示修正结果条件或使用 steps。visible/disabled verifier 不变。
- 不猜测或改写模型写错的区域；工具描述要求基于真实 rect/屏幕尺寸计算，并选择能证明目标完成的条件。

验证状态：已加入真实失败形状的 root actions 三动作回归。源码编译通过；测试事件流显示新增集成 fixture 的 JSON 格式有误，已改用 JSONSerialization 构造。用户明确要求停止继续测试、安装真机手测，已停止模拟器测试，不宣称本轮测试全部通过。真机 Release 包已原位安装并启动，运行进程已核对；376 个会话索引条目保留，6 项关键设置按解析后的内容比较一致。安装证据位于 `iosApp/build/PhoneSequenceDevice-20261012/install-verification-continuation/`；功能与提速效果按用户要求留待手动测试。

## 完成标准

- `phone_act` 可附带明确的界面验收条件，执行回执与效果核验分别返回；执行后用新观察核验，并返回给主模型。不为了取前态而覆盖已有 ref / screenshot observation。
- `phone_run_goal` 接受目标 App、小目标、有限动作清单和结构化完成条件；只从当前观察能唯一定位的清单项中用 Jev 选择动作。每步重新观察、核验，遇到视觉需求、歧义、无进展、预算或 Jev 不可用时交回主模型。
- 明确可判断的条件本地核验，Jev 只辅助决定未达成后的下一步，不能把缺失证据变成成功。空树、截断树、未出现过的目标不能证明弹窗已关闭。
- 未知动作结果沿现有 `outcomeUnknown` / Ledger 终止链处理，禁止自动重放。取消、权限撤销、App 切换、设置变更后不得继续派发。
- 新增 Jev「手机效果检查」「手机快速操作」独立用途及「手机界面文字」数据范围；默认 off，沿用固定版本、预算、出站和设置 revision 约束。shadow 会出站但不驱动手机动作。普通手机工具仍可使用。
- 灵动岛补充核验、局部决策和等待界面阶段；状态取自执行事件，不猜百分比，不展示任务私密内容。

## 设计

- 主模型提供精确 label/identifier（可选元素类型）定位目标及动作清单；输入内容由主模型提供，Jev 不生成字符串、坐标或 Bundle ID。
- 验收条件使用 `visible`、`absent`、`value_equals`。消失条件需原观察存在该目标、后观察完整并存在明确 anchor。同名歧义交回主模型。
- `phone_run_goal` 限同一前台 App，默认最多 6 步、可指定最多 12 步。循环继续及新动作派发检查 60 秒预算；已在途的请求仍遵循 runner 自身超时，因此不是严格 60 秒强制返回。首版只用于导航、搜索和草稿填写；最终发送、付款等交回主模型原工具链。它不启动或添加其他 App。
- 两项复用一个证据判断模块与既有 PhoneRunnerClient。原始回执、验证结果、已执行步骤和最新观察分开，失败后不谎称整段未执行。
- 不把动态手机观察加入现有“可重读恢复原文”上下文裁剪。

## 阶段与验证

1. 证据与契约：目标匹配、后置条件、最新观察读取、设置持久化及数据范围；单元测试和独立 review。
2. 生产接线：Jev 判断、短循环、phone_act / phone_run_goal、前后台 executor、未知结果与取消；定点测试和独立 review。
3. 产品收尾：设置/灵动岛及多语言布局检查、受影响回归、构建；有限可维护性审查。真机及真实 Jev 验收分别记录，不以模拟器/fixture 代替。

## 当前进度

- 已核对基线 HEAD `69c2144`，既有大量未提交/未跟踪工作已记录至本地 build 目录。
- Phase 1 已实现并完成独立 review：加入实际屏幕尺寸检查；换采集后端不能作为目标消失证据。Package 52 项测试通过。
- Phase 2 已实现并完成独立 review：Jev 仅从当前界面可唯一定位的清单项选择；每项至多执行一次，每步取得新 ref。配置 revision 在判断返回和动作状态回调之后再次检查；值缺失的输入框不视为空；旋转后旧树不附新截图尺寸。未知回执仍进入既有 Ledger，未新增恢复/重放机制。
- App 定点与调用链回归共 219 个不同用例，最新结果全部通过。首轮 service 样本缺 screenBounds，补齐后通过；扩跑发现旧设置接线断言未包含已有 `input` 参数，改为在对应执行块检查完整调用后通过，未删减断言。
- 补充修复并独立复核 `launch + expectation`：先确认请求的 App 已在前台，再核验新界面；不再将旧 App 的观察误用于比较，也不能用旧 App 证明目标消失。对应核验、循环、executor 与接线的 45 项回归全部通过。
- Phase 3 实际渲染已检查中文默认字号、320pt AX3 和俄语 AX1 的两项设置：没有重叠或文字省略。发现无效系统图标并将设置行及核验阶段统一修为 `checkmark.circle`，复看已正常显示。模拟器灵动岛紧凑态及锁屏卡片的核验状态也已截图并经独立 review。证据在 `build/jev-phone-control-20261011/ui-review-final/`；预览已结束。
- 已对本轮模型、核验、循环、service、executor 接线做一次有限可维护性检查：职责分离且复用现有设置/账本/runner，无需再建抽象或恢复状态机。
- 三个实现阶段已完成。Release 签名构建及严格签名校验通过，已原位安装到当前 iPhone 的 `app.amber.ios` 并正常启动，进程路径与本次安装一致。安装前后 368 个会话文件条目均保留，大小无变化；未读取消息正文、未卸载、未提交或推送。
- 真实 Jev 延迟、手机内导航/填写闭环、后台与灵动岛动态更新仍待实际验收，不能由 fixture 或安装成功代替。未自动开启两项 Jev 用途及新增出站范围。
- 本轮交付证据：[jev-control-20261011.json](iphone-control-evidence/jev-control-20261011.json)。
- 后续按用户指定模型完成四路独立 review，确认并修复两项：通用压缩大纲泄漏手机工具参数、等待界面期间设置 revision 变化后仍继续动作。3 项新增行为回归均先复现失败，再随 89 项相关回归通过；模式截图 fixture 隔离后重跑通过。修复版 Release 已原位安装并确认正常启动，会话文件元数据 368 项保留。详见[复核报告](reviews/iphone-jev-review-20261011.md)及[复核交付证据](iphone-control-evidence/jev-review-20261011.json)。本轮新增决策/等待的锁屏布局有截图，紧凑灵动岛未捕获到有效显示，继续标为未验证。

## 使用入口与验收边界

设置 → 运行环境 → Jev 快速判断，分别启用「手机效果检查」「手机快速操作」，开放「当前任务文本」「手机界面文字」。沿用已有连接配置；Active 必须有固定模型版本，设置页会说明 Shadow 降级状态。两项不会随推荐配置自动开启。

主模型可在原有 `phone_act` 上附加验收条件，也可把当前 App 内的小目标交给 `phone_run_goal`。Jev 只判断下一项候选，定位、执行和证据判定由本机负责。完成条件只说明所指定的界面条件成立，不能据此推断消息已送达或付款成功。

未开启两项时没有新增 Jev 出站；`phone_act` 的本地验收仍可用。截图在必要时返回主模型，不发送给 Jev。不能唯一定位、效果不清或候选用尽时返回最新观察，不自动重放短循环。

### 最小回归补齐（源码，尚未运行或重装）

按用户指定四点更新已有用例，不增加测试框架：

1. legacy actions 共三个动作，可执行候选按 2→1→1 变化；只在首轮分支调用一次 choose，后两步本地执行，零中间 advise，最终由本地 completion 验收。
2. legacy/live 均要求派发前上下文复核；选中目标自身不变、另一节点在 Jev 返回后变化时，`/source` 检查拒绝动作，零点击。
3. 初始已可见且 disabled：live 返回 completed；显式旧 actions 返回 completion_already_satisfied handback。均零动作，并保留新观察；只读等待后尚未派发动作的情况按同一模式契约处理。
4. sequence 的同标签 Other/StaticText 父子锚点可折叠；同级 Button、跨分支同标签仍有歧义且不点击。Catalog 继续断言无 root actions，原 parser 用例继续保留。

只执行 Swift 语法检查与 diff 格式检查，遵守用户停止长时间模拟器测试的要求。本节变更尚未安装，真机仍是前一修复包。

后续范围收敛：恢复 legacy 原有的 bundleID/PID guard，backend/screenBounds 一致性仅约束 live；派发前 `requireUnchangedObservation`、verifier 的原有证据要求及空候选 handback 保留。新增一个参数化回归，覆盖旋转发生在动作后/只读等待后：legacy 使用新 ref 继续，live 保持原有边界。只做语法和 diff 检查，未运行 XCTest、未重新装机。

结果诊断补齐：非 sequence loop 在当前观察含 alert 时返回空 candidate_diagnostics，不再把弹窗下的 legacy actions 标为 eligible。新增同一回归覆盖直接 handback 和等待预算耗尽，执行/等待策略不变。仅语法及 diff 检查，未运行 XCTest 或重装。

唯一候选执行规则按后续用户优先级统一：Active 下 legacy/live/sequence 仅有一个可执行候选时本地执行；多个候选继续交给 Jev，Shadow 仍只观察。live 单候选也不再额外调用 Jev 判断目标相关性。集成用例断言 selection_calls=1、local_actions=2、candidateIDs 仅一批 [a0,a1]；需要 Jev 回调的取消/超时/等待用例改为双候选，派发前上下文检查不变。仅语法和 diff 检查，未运行 XCTest 或重新装机。

单候选回归断言已同步：NavigationAndTyping 的 chooseCount=0；LiveCandidatesFollow 的候选数为 1→2→1，chooseCount=1、local_actions=2。无进展、alert、Shadow 和 unknown 的用例按相同规则更新。语法/diff 检查通过，未运行 XCTest、未装机，实际速度与决策效果待手测。

最终模式分流已同步到 loop 枚举、结果文案和回归断言；executor 沿用 steps.isEmpty 输出 not_sent/retry_safe，并由 status 输出 goal_satisfied=false。没有修改 visible verifier，也不在 live 目标已达成时强制点击。仅语法/diff 检查，未运行 XCTest 或重装。
