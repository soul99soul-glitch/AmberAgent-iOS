# Phase 6 UI 独立审查

状态：**Phase 6 UI 范围最终签字通过**。无诊断完整 Main r6 与 Novel r2 均已通过，六条真实产品导航及截图布局签字仍有效。本 reviewer 只读本期源码、测试、映射、日志、AX 文本和已导出的截图，不运行构建、测试或 GUI；仅写本报告。

## 本期改动与 UI 调用链

Phase 6 的实施范围是 `PhoneRunnerClientTests`、`IOSPhoneControlControllerTests`、`IOSPhoneGoalLoopTests`、`IOSParityRedLightTests`、`IOSSkillMcpToolsTests` 五个大测试文件按职责拆分、迁移一处日志源码 guard、收紧物理行门禁；没有追加生产 UI 改动。新文件仍以原 XCTestCase 的 extension 收纳测试方法，没有复制测试类或另建继承基类。`phase-6-phone-test-audit.json` 将 Phone 228 个原方法及 68 个 helper、18 个支持类型映射到单一 owner，方法和 helper/type 正文 SHA 全同；`phase-6-parity-skill-test-moves.json` 的 Parity/Skill 99 个方法中 98 个正文相同，唯一差异是旧 Board 文件日志 guard 改查实际 Hotlist/DeepRead owner，原断言及七个日志 marker 保留。`phase-6-coverage-static.json` 还核对了这些原方法的声明、类名及 target membership；它是静态证据，不能代替实际 XCTest discovery。

与 UI 相关的分层也未因测试搬迁改写：PhoneRunnerClient 的观察、引用失效、视觉点按与滑动测试仍调用同一客户端和同一个 `FixtureProtocol.Registry`；Controller 的 readiness 与设置 owner 测试仍调用原 controller，凭据 actor 与 HTTP fixture 各有单一 owner；GoalLoop 的候选选择/恢复测试仍用同一个 `IOSPhoneGoalLoopTests.Fixture`；Skill 测试的 `tempDirs`、`tempRoot()` 和异步 `tearDown()` 仍在原 XCTestCase。拆分只调整测试间可见性，不产生新的产品绑定、Sheet、滚动 owner 或用户可达页面。Phase 4 Novel 和 Phase 5 Provider/Runtime/Council/MiniApp 的既有 UI 签字及其范围，分别见 `phase-4-ui-review.md` 与 `phase-5-ui-review.md`；Phase 6 不以测试类重新排列推定新的视觉行为。

## 实际证据与验收边界

主 App 首轮 `/tmp/amber-phase6-main-r1.xcresult` 为 5089 total、5057 passed、15 failed、17 skipped。三条旧 fixture/source guard 失败后来已定点修正。另 12 条 SavedTasks 当时停在单元 hosting 的首次 AX 标签查找，未执行动作。产品 `IOSPhoneControlSavedTasksView.swift`、两份相关测试和原 fixture 与本期前基线字节一致，故首轮 AX 空树不能归因为 Phase 6 UI 搬迁回归。

Root 保留原数据重启模拟器后，先以只读外部 AX query 看到桌面 ready 时 13 个元素，再运行**未修改的** SavedTasks 两个原 suite；`/tmp/amber-phase6-main-savedtasks-r6-summary.json` 和 tests 清单记录 16/16 passed、0 failed、0 skipped、0 runtime warning。原交互断言由此实际走过保存/运行/删除确认、错误保留和示例填充等路径；这只证明该次独立运行环境下原 fixture 可工作。随后完整 Main r2 仍有 12 条 SavedTasks 在首次 AX 查找失败，失败期间外部 AX query 返回屏幕 `0×0pt`、0 元素。先看见 ready 桌面 AX、六条独立产品导航全过，以及单独 r6 的 16/16，均不能外推为完整单元测试顺序稳定；历史 AX 空树的唯一成因没有被证实，也未发现产品 SavedTasks UI 发生本期回归。

完整 Main r3 日志又提供了一次不同结果：`IOSIntelligentUIComponentInteractionTests.testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission` 在 SavedTasks 前已于 0.199 秒通过；SavedTasks 原两个 suite 随后 12 个交互方法、4 个视觉方法全部记录 passed。该次仅在 SavedTasks hosting fixture 加入临时窗口/scene **日志诊断**，可见前台 scene 与 key window 有非零 frame。可是 r3 测试进程收尾挂起、退出码 73，结果 bundle 无法完成保存，因此不是完整 Main 通过；这些日志也未建立诊断代码与 AX 成功之间的因果。Root 已反向移除临时诊断，SavedTasks 测试文件 SHA 恢复到原 `31e87e0c066331a9416a252f927bfb4e1ac8ae72d282034bdc7f5be822fce137`，不采用新 test bundle 候选，也不改产品 SavedTasks UI。

无诊断代码的完整 Main r4 已正常结束。`/tmp/amber-phase6-main-r4-summary.json` 为 5089 total、5072 passed、1 failed、16 skipped；tests 清单逐项记录 SavedTasks 原 12 个交互方法和 4 个视觉方法 **16/16 passed**，IUI 原 AX 交互 `testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission` 也 passed。唯一失败为 `NovelBatchPolishTests.testBindingChangeCancelsRunningBatchWithoutStartingNextChapter` 的占位 run ID / 分支选择旧测试问题，修正限于测试 readiness 和 selected 断言，未改生产/UI。后续 r5 因 test daemon 未就绪，零用例执行；Root 受控停止后保留数据重启模拟器，以只读桌面 AX query 再见 13 个元素，然后执行完整 r6。r3 的 ResultKit 结果写入错误不能据此定为 r5 停机根因，也不能据 r6 成功反推历史 AX 空树的唯一根因。

最终 `/tmp/amber-phase6-main-r6-summary.json` 为 **5089 total、5073 passed、0 failed、16 skipped**；我从 tests 清单逐项核对 SavedTasks 原 12 个交互和 4 个视觉方法全部 Passed、IUI 原 AX 交互 Passed，前述 NovelBatchPolish 方法也 Passed。当前 `IOSPhoneControlSavedTasksTests.swift` SHA 经只读核对仍为原 `31e87e0c066331a9416a252f927bfb4e1ac8ae72d282034bdc7f5be822fce137`。Novel r2 full 摘要为 **1048 total、1045 passed、0 failed、3 skipped**。Main r6 摘要仍列出 Council archive 测试的 QoS 与 ProvidersWriteBack 测试的未安装 View State 两条 runtime warning；本 UI 导航签字不以这些单元测试作产品绑定验收。

我复核了 r6 导出的 393pt/large 深色列表与编辑器、320pt/AX3 浅色空态与编辑器，以及从长表单底部触发“保存任务”“运行任务”前后的四张 320pt/AX3 图。长文本在卡片内换行，控件与说明文字不横向越界；底部动作被点击后，红色错误消息回到可读视口，输入值仍在表单中。滚动后的顶部卡片内容从顶栏下方继续出现，是该时刻的滚动位置，不是固定顶栏覆盖初始内容。`IOSPhoneControlSavedTasksVisualTests` 的对应断言核对滚动内容宽度不超过视口、动作触发前按钮与视口相交，以及触发后完整错误 AX frame 被视口包含；四项视觉测试随上述 16/16 一同通过。这些是单元 hosting 的像素与 AX/几何证据，不能等同真实产品导航、VoiceOver 操作或真机中文 IME 验收。

本期最终导航 `/tmp/amber-phase6-navigation-r1-summary.json` 与 tests 清单记录 iPhone 17 Pro / iOS 26.5 模拟器上原六个 `SwiftModularizationNavigationUITests` 方法 **6/6 passed、0 failed、0 skipped、0 runtime warning**。我按 `SwiftModularizationNavigationUITests.swift` 核对了入口、动作和退出，再查看 `/tmp/amber-phase6-navigation-r1-attachments/manifest.json` 对应的实际截图和 AX 文本：Home → 设置 → Workspace/深度阅读与 WebMount 站点列表可达；聊天 composer 草稿进入键盘后输入框和发送键在键盘上方、欢迎标识低于顶栏，清空草稿后附件菜单的文件入口可达；Novel 本地项目的创作/正文/设定三分段、44pt 目标边缘点击、项目控制两分段可达；Provider 配置 → 模型 → 手动添加编辑器及取消返回可达；Runtime 的 SSH Profile sheet 能滚到未验证 Host 指纹和检查按钮，MiniApp 列表/设置、Council 房间/成员/设置可达。页头元素在屏内且互不重叠的原断言全过；已看截图未见本期可达错位、遮挡或裁切回归。WebMount 9 个站点的现存数据和 Workspace 中的一个旧 artifact 出现在图中，属于保留数据展示，不是本测试创建的内容。

六个导航方法没有清理、重置或写入设置的测试调用。聊天只输入并清空英文草稿，不发送；WebMount 不切换、恢复或删除站点；Provider 手动模型编辑器以“取消”退出，未点保存；SSH Profile 只打开、滚动、关闭，未保存凭据或触发 Host 指纹探测；MiniApp 权限开关和 Council 设置只展示，未触发更改。Novel 方法包含“已有同名本地项目则复用，否则创建 `Modularization UI Review`”分支，故不能笼统称整个导航零写入；本次 Home 截图已显示该项目存在。测试没有前后持久化差异审计，正常页面加载的内部写入也不能仅凭导航动作排除。

签字范围是当前构建的模拟器产品入口与原六条本地导航动作、已导出截图的布局，以及 SavedTasks 原 hosting suite 在无诊断完整 Main r6 顺序中通过；单轮通过不证明所有未来运行零波动。聊天附件截图中欢迎装饰已不可见，但附件 AX debugDescription 仍列出 `chat-empty-state-mark`，本次并未用 VoiceOver 验证它是否可聚焦；该边界与 Phase 3 既有记录一致，不能宣称 AX 隐藏。其余未覆盖项包括真机中文 IME、真实 provider/SSH 连通与指纹确认、MiniApp 完整管理 Sheet、系统权限弹窗、Council 实际生成和物理设备触感；这些不包含在本期模拟器 UI 签字内。
