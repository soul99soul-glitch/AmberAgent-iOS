# Amber iOS：Codex 交叉验证记录

任务：c2c_b94e。审查说明：REVIEW_BRIEF_6PRO.md。只读审查，未实施产品修复。

## 第 1 轮（本地验证已结束）

### 基线

- 工作区：/Users/arquiel/Downloads/AI/AmberAgent/ios；main；HEAD 888f42fc5221010b23b33aae2d0ca9d923459041。
- 原有 6 个修改文件保持不变；本任务仅新增审查说明和本记录。
- 未 fetch 远端；任何 ahead/behind 只能视为本地 remote-tracking 状态，不代表实时远端新鲜度。

### B01：邮箱消费的跨会话归属

6 Pro 初审：P1，高置信度、完整静态调用链，尚无运行复现。潜在影响为 A 的待消费信封进入当前 B 的消息及保存路径；不宣称已证明永久数据丢失。

Codex 已交叉核对：

- ChatViewModel.swift:1954 开始的 drainMailbox 在 await 前检查当前会话，等待返回后才读取 currentConversationId，并向当前 messages 追加，再安排 persistMessages。
- ChatKernelRunHost.swift 的 mailboxDrain 通过独立 MainActor Task 调用 ViewModel binding；父任务取消不能自动当作该闭包已经取消的证据。
- IOSMailboxStore.swift 使用真实 MailboxDao 和 continuation；只允许注入 DAO，没有可控的 drain 回调屏障。
- MailboxDao.kt 的 drainPending 是查询和标投递的事务，返回 Swift 前已 markDelivered。简单增加 await 后不匹配就返回的 guard 可能静默丢弃信封。
- IOSMailboxDeliveryTests 使用独立会话目录、临时 Room 数据库及合成内容，但现有 5 个用例不包含 DAO 返回前切换会话的目标时序。
- 因缺少现有可控回调注入点，未增加测试或修改生产代码来构造复现；保持“静态链路支持，运行复现待验证”的证据等级。

### 已执行验证

- 环境：Xcode 26.6（17F113）；已有 Homebrew JDK 17.0.18。
- `JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew --offline :core:agent-store-room:jvmTest --tests app.amber.core.agent.store.MailboxDaoTest`：BUILD SUCCESSFUL。
- JUnit XML：9 tests，0 failures，0 errors，0 skipped；真实执行，非仅编译通过。
- 日志通过 C2C execution_output 发布后，供 6 Pro 独立复核。
- 用户授权后启动 iPhone 17 Pro / iOS 26.5 模拟器，使用现有项目执行 test_sim；编译成功，115 项实际执行，110 通过、5 失败、0 跳过。工具预发现数为 104，以执行结果 115 为准。
- 范围：IOSMailboxDeliveryTests、4 个 IOSChatKernelRunHostTests 交接/取消用例、ChatSwiftUIStreamReplayTests、NativeTimelineScrollCoreTests、ChatViewportPolicyTests、ChatToolTimelineWidthOverflowTests；禁用并行、自动包解析，未运行 xcodegen。
- 5 个失败均属 ChatToolTimelineWidthOverflowTests：testShortWebMountCapsulesHugStableVisibleTitleWithoutHiddenSentinel、testStatefulToolCapsulesKeepOneAdaptiveTitleAcrossLifecycle、testWebMountCapsuleActionTitleDoesNotDependOnInputShape、testWebMountCapsuleRedactsTypedTextAndURLQuery、testWebMountCapsuleUsesStableActionTitleInsteadOfRawJSON。
- 这 5 项共 19 条失败断言都是英文实际标题与硬编码中文预期不等。测试类没有 setUp/tearDown 来固定语言；生产 localized 方法调用 IOSAppLocalization.string，默认遵循 IOSAppLanguagePreference.selected()/Locale.preferredLanguages。因此当前证据支持测试语言前提未隔离，不支持把它们记作 5 个产品 UI bug。未改变语言掩盖首次失败，未复跑。
- 其余尺寸、流式和交接断言通过，不等于覆盖 B01 的目标竞态。
- 结果包：/tmp/c2c-b94e-ios-tests.xcresult；完整结构化结果：/tmp/c2c-b94e-ios-tool-result.json。

### UI 证据边界

- 现有 ChatSwiftUIStreamReplayTests 使用 393×852 pt 窗口，实际宿主为 NativeChatTimelineView。
- ChatToolTimelineWidthOverflowTests 包含 393 pt、320 pt 以及 accessibility3 场景。
- 所读测试没有 XCTAttachment / screenshot 输出；尺寸断言不能替代可见胶囊边界、命中范围和截图证据。
- 尚未宣称视觉通过或真机验证通过。
- 测试结束后获取了一张模拟器截图，实际是主屏幕，未显示目标聊天测试场景；不能用于证明胶囊视觉正确。当前测试宿主未提供可暂停并输出目标场景截图的现有入口，截图/点击命中验证仍欠缺。

## 第 2 轮（2026-09-05，本地验证已结束）

6 Pro 返回 PLAN iteration 2，并确认已读取 iteration 1 执行输出。由于第一份结果被长警告列表截断，本轮补交独立精简输出：5 个失败测试的 19 条断言、JVM JUnit 的 9/0 计数及原始 Gradle 日志尾部。没有重跑第一轮。

元数据更正：第一份 C2C 记录的 iOS 数字退出码 65 是 Codex 填入，结构化 test_sim 本身未暴露数字退出码；可直接观察的是 didError=true、status=FAILED。JVM 原始 shell 调用返回 exit_code=0。不得把推定数字当独立运行证据。

### 新增源码问题及交叉核对

- B02（6 Pro：P1）：已显示的当前轮 partial 没进入 Adapter working；取消发布旧 working 会覆盖 provisional。Codex 核对 ChatRunKernelAdapter.swift:419–436、578–598，支持此静态链路。现有 testStreamingProvisionalBubbleProjection 在出现首片后等待正常 complete，没有触发 cancel/error，因此其通过不证明取消保留 partial。运行复现仍缺少可控的首片后取消/失败驱动。
- B03（6 Pro：P1）：Host handoff 入口不排除 didFinalizeTerminal；teardownRun 从当前字段取归属并 clearRunIdentity，没有核对所传 runId 是否仍为当前。Codex 核对 ChatKernelRunHost.swift:1135–1155、2378–2415，支持静态归属风险。beforePersistForTesting 确实可暂停 Store 保存，但现有测试只组合了 Store 的并发写入，没有在这个窗口完成 A 终态、后台接管、B 新运行、A 恢复的 Host 全链；不能用局部 hook 的存在宣称已复现。
- B04（6 Pro：P2）：IOSConversationStore.swift:458–483 的 differenceIsOnlyDrain 分支使用 current + freshSuffix。对 current=[U,M]、completed=[U,T,M,A]，可静态推导得到 [U,M,T,A]，偏离引擎顺序。现有 IOSThreadMessagingTests.swift:812–860 构造 base+drained+final，没有先于 M 的工具轮 T，也不检查完整 ID 顺序；因此去重用例通过不能排除此问题。
- 已发现 LLDB attach/command 工具，但现有 test_sim 接口没有在上述测试局部变量可用处预设断点或注入事件的参数，首片间隔只有 150ms；本轮没有临时改写测试、生成新驱动或把未经执行的调试设想称为复现。以上三项维持源码级证据。
- 后续实际尝试 debug_attach_sim(bundleId=app.amber.ios, waitFor=true, continueOnAttach=false)，工具立即返回 No running process found，未能建立等待测试进程启动的调试会话。没有成功附加或执行取消注入，也没有为此重复跑原测试；这是当前调试方案的具体阻塞。

### 第 2 轮实际测试

沿用 iosApp/Debug、iPhone 17 Pro/iOS 26.5，合并执行 6 项；实际耗时约 81 秒，4 通过、2 失败、0 跳过，未修改工程或测试。

- 通过：IOSChatKernelRunHostTests 的 testCompletedRunTerminalSequence、testTerminalCASFailureReleasesLocalOwnerAndSuppressesExternalCompletion、testStreamingProvisionalBubbleProjection；IOSThreadMessagingTests/testDrainFoldedEnvelopePersistsExactlyOnceOnTerminalSaveWithoutNotice。
- 失败：IOSConversationStoreTests/testBackgroundCompletionWriteBaselineDoesNotOverwriteForegroundMessage、testBackgroundCompletionRetriesAfterForegroundWriteAndKeepsResult。
- 两项失败均为背景完成 notice 的英文实际值与中文预期值不等。实际数组均保留 background base、new foreground message、notice、late background result 及其顺序；未观察到测试所针对的前台消息覆盖或后台结果丢失。完整测试仍标 FAILED，暂不把两次语言断言失败计作新的产品 bug。
- 结果包：/tmp/c2c-b94e-round2-ios-tests.xcresult；精简完整结构化结果：/tmp/c2c-b94e-round2-result.json。

### 覆盖与待办

累计 B01–B04 均有源码证据，目标运行复现尚缺；没有新增产品或测试改动。现有工程定义的 stable/ExperimentalGPL 隔离已由 6 Pro 检查，最终包体未验证。后续优先扩展设置→运行时、provider/认证、附件/OCR，再覆盖小说、浏览器/文件、MCP/权限、架构与现代方案。UI 截图/命中范围、真机、真实 provider、性能实测仍是独立缺口，不标记全面完成。

## 第 3 轮与按用户要求收敛结论

用户要求现在给出审查结论，停止继续扩展轮次。网页最新已完成 PLAN iteration 3（思考 11m43s），两份 iteration 2 输出均被独立读取，接受退出码更正和语言失败分类。本轮末段连接器返回 502，未开展其后续测试或修复。

- B05（P2，高可信源码缺陷）：非视觉聊天模型依赖视觉模型先识图，识别结果仅在 ChatViewModel 内存字典缓存（最多 16 项）；重启或淘汰后重新生成，上传会以“[图片未能识别]”替换原先成功识别的上下文。原图没有被删除。6 Pro 追踪成功识别→缓存→重新生成→上传转换；Codex 最后核对 ChatViewModel.swift:2705–2739、3277–3305 及缓存引用，支持其根因。尚无重启目标复现。
- H05（候选 P1）：Codex OAuth 刷新与退出登录之间缺少共同失效边界，旧刷新成功后可能重新保存已退出账号的凭据。定位 CodexLoginView.swift:84–99、IOSCodexOAuthClient.swift:196–237、IOSCodexProviderResolver.swift:215–240。Codex 最后确认 signedInView:256 调用了 logout，但仍未完成全仓统一失效机制排查和目标时序验证，保留候选等级。
- H06（候选 P2）：SyncBackupView 的远端同步开关读取固定 true 的兼容 gate，setter 无操作；设置首页最后导航入口尚未复核，保留候选。没有自动上传或数据外传证据。
- D01（设计/契约问题）：Google API Key 自定义地址切入 OAuth 再切回时被恢复为默认地址；尚未确认是否为产品明确接受的配置重置，不算已确认 bug。关键文件 shared/src/commonMain/kotlin/shared/IosSettingsMutations.kt:303–348。

结论：5 项高可信源码缺陷（B01–B05），2 项候选，1 项配置设计问题。全部缺陷均未完成目标运行复现，不能称为 5 项已在真机复现的问题。两轮 iOS 合计 121 项实际测试：114 通过、7 失败；7 项已观察失败均为语言预期不一致。JVM MailboxDaoTest 9 项通过。用户已有 6 个 WIP 未被本任务修改。

架构评估：已审 Engine/Adapter/Host/Projection/Store 分工可保留，优先收紧运行归属、partial 与终态快照、保序持久化及识别结果恢复；没有证据支持大规模重写。UI 错位/间距/命中范围尚无目标截图结论，开源替代与完整架构横向比较也未完成，未覆盖模块不能视为无问题。

## 用户要求恢复全面审查后的补核

来源区分：B01–B05、H05/H06、D01 最初均来自网页版 6 Pro；Codex 负责上述本地交叉核对与实际测试，不把本地判断冒称为新一轮 Pro 结论。

- H06 的生产入口已由 Codex 补齐：PlaceholderViews.swift:3735–3740 的 dataEntries 含 .syncBackup，body:3779 渲染该组，按钮:3833 调用 router.navigate；AppShell.swift:902 创建 SyncBackupView。控件绑定→IOSSharedSettingsStore.swift:309–321→固定 true/no-op gate:94–102 闭环完整，支持将无效开关提升为源码确认问题，留待 Pro 独立复核编号。
- H05 已补齐退出按钮→logout 调用。logout 只取消 loginTask，IOSCodexResolveCoordinator 的 inFlight 只有 resolve，没有退出失效入口；OAuth refresh 在 await 后仍直接 save。当前检查未发现版本校验，仍不声称受控运行已复现。
- D01 注释与 mutation 明确承认 pre-OAuth 自定义地址不保留；未见此次模式往返的备份恢复字段。仍按配置行为/设计契约单列。
- 无新测试、无源码修改。当前 HEAD 仍为 888f42f，原六个 WIP 文件仍在。
- 恢复连接状态：本地 bridge 与 MCP/OAuth 自检已恢复正常；公开临时连接未运行。自动审批拒绝 doctor 自动修复，要求用户明确授权临时连接/必要连接器配置恢复。未绕过、未重发审查请求。

下一步：恢复同一工作区只读连接后，让 6 Pro 先补齐浏览器/文件/MCP/权限、小说、Deep Read/Council/MiniApp、UI/可访问性、构建包体与性能/现代方案的覆盖矩阵。每个模块须列实际入口、已走通链路、发现/排除/缺口；不再将阶段性发现称为全面报告，不重复前两轮基线测试。

### 用户授权后的连接恢复进度

- 用户明确允许恢复。已删除 ios 旧连接并按原名称重建；其他工作区连接未改动。
- 本地自检 bridge/mcp/oauth/tunnel 均为正常，chatgptRepair.needed=false。但网页仍显示登录按钮禁用及配对待完成，不能把本地自检当作网页授权成功。
- 点击同名连接登录后，独立授权窗口未出现在内置浏览器可操作标签页列表；当前接口没有弹窗接管能力。没有绕过浏览器、提取认证会话或切换外部浏览器。
- 原审查对话保留，尚未发送新一轮 EXECUTED；后续全面审查仍待网页配对完成。
