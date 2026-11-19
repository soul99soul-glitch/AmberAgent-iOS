# Codex 接续：真实运行诊断与验证边界

工作树仅 ce201253131e；HEAD 84176fde736d3056e7a30fb1df66e44b7d378f5c / MERGE_HEAD 6e89805b2667098e8ef523545915ca77c7b5f4a2 保留。无提交、推送、云端部署或付费模型调用。

## 当前直接证据

2026-11-11 只读复制已配对真机 Documents 内运行数据库及 WAL、帧日志与对应会话到 gitignore 的 `iosApp/build/CodexTakeover20261111/`。原始文件仅本机，不上传 Library；下述数字来自真实运行，不是合成回放。数据库与 WAL 分别复制，属于活动文件快照，不能保证覆盖复制后的事件；本次分析的 run 已终态 cancelled。

该次运行起止 08:16:47.756–08:21:45.308（UTC+8），297552ms，取消。运行账本有15个 request_snapshot、9次 phone_act、4次 phone_observe、1次 phone_status，没有 phone_run_goal。不能称为一页完成，也不能称为优化后连续循环的生产验收。

- 14个 request_snapshot→下一 tool_started 区间依次 15660、12700、15840、3615、12329、10883、11973、12831、13599、18787、8777、17686、19585、32750ms。该区间含主模型往返、流式解析、调度及可能审批，不能冒充纯 LLM RTT。
- 最后 request_snapshot→取消为36809ms；所有14次已启动工具都有 finished 事件，没有遗留未完成工具。这次最后等待位于下一工具启动前。
- 工具总区间38461ms，工具外259091ms（约87.1%）；首个 phone_act 16280ms，另一次 failed 155ms。其余 phone_act 1431–5098ms。逐动作开始偏移和持续时间见 `performance-summary.json`。
- 可见动作诊断7组：点按/动作请求约184–493ms；动作后观察约577–986ms；7次稳定检查中3次达预算仍不稳定，waitedMs为316–774ms，不能因此关闭稳定性核验。
- 有一次 verification.needs_screenshot，后续补图成本缺独立阶段。可见诊断合计80个 runner HTTP 请求。没有 chooseAction 的 start/end 与 Jev RTT，不能断言 Jev 调用为0，也不能把工具外耗时全部归因于网络。
- 同区间287条帧汇总；最大帧间隔1484.47ms。证明存在帧停顿，尚无堆栈或动作阶段相关性，不能直接归因于主线程时间线。

结论：此次实际未进入 phone_run_goal，先前连续循环的合成收益没有覆盖这次生产路径。优先检查实际 planning prompt/tool exposure 和模型为何仍逐步 phone_act；网络、两类模型合作与渲染各自占比仍待细分。当前不做猜测性性能改动。

## 最短后续采集

由用户自行开始一次原有真实任务（本线程不调用真实 Key/付费服务）。在现有 phone_run_goal metrics 上，对通用模型请求、Jev chooseAction、截图编码/上传补独立开始/结束单调时钟和 run/tool/step 关联；记录 waitForUI、anchor核验、补图、handback、重试及timeout计数。一次页面内子目标即可，发生卡住时保留最后阶段，然后停止。无需全量性能回归。未采集前不宣称真实提速。

## 云端测试

原中断 xcresult `Test-iosApp-2026.11.11_08-41-55-+0800.xcresult` 有 Cannot find IosSettingsMutations in scope，0测试。新增测试缺 import Shared；本线程补导入后，两套云端配置测试在 `CodexTakeover20261111/red.xcresult` 实际37通过，含 Store→加密Client→受控API响应→刷新快照。此命名 red 指启动时预期的回归阶段，云端测试本身是通过的，不是云端按钮红灯证据。

按钮真实触达、服务端实际持久化和真实云端端到端尚未验收；现有 transport测试直接调用Store。不可称为按钮闭环完成。

## 等待文案与布局

固定文案直接来自 ChatAsyncTaskSlot.keepaliveDefaultText；evaluateTaskKeepaliveIfNeeded 在60s后追加正文；coalescer明确放行keepalive，且单消息和首轮接话跳过普通等待过滤。旧持久消息也走原始正文投影。

发现未跟踪 IOSDialogueTimelineResidualTests.swift 不在 Xcode pbxproj 测试目标内；选它不会执行。新回归已放入实际目标 ChatMessagePresentationTests，等待取得实际失败与修复结果。不得复用此前该文件的声称通过作为证据。


## 本线程新增修复（验证进行中）

- `IOSCloudConfigTransportTests.swift`：补 Shared 导入，原测试才得以编译执行。
- `ChatAsyncTaskIsolation.swift`：统一识别精确保活文案与普通无信息等待；单消息、首条、纯正文也不再豁免；保活事件依然60秒生成且仍保留在原始记录。
- `IOSSubAgentOutput.swift` 与 `NativeTimelineProjection.swift`：准备显示文本与可见正文事实使用相同等待规则，历史持久文本重投影也不再产生正文，原始模型/持久化内容不改。
- `ChatView.swift`：本机时间线由透明 top safeAreaBar 改为既有顶栏高度的实际布局空间，防止滚动内容画在胶囊背后。没有内容偏移补偿、没有改字号。
- `ChatMessagePresentationTests.swift`：新增准确文案、首条纯等待、conversationLoaded 的回归，`wait-red2.xcresult` 实际执行1例失败（coalescer和投影断言均失败）。`wait-red.xcresult` 是同树另一旧进程占用 build.db 导致的编译取消，不属于红灯。

上述为本轮新增变化；云端四处前序实现、其他 staged/unstaged/untracked WIP 均保留，不将整树diff算成本轮成果。

## 对照结果与按钮触达

- `green.xcresult`：142通过、7失败；新文案回归已通过。1项保活计数失败由本轮 coalescer 清空原事件导致，已改回保留 keepalive 原记录，只由显示投影隐藏。回归断言明确区分“记录保留”和“正文不可见”，不以丢事件满足UI。
- `baseline.xcresult`：只撤回本轮4个应用文件增量（逐文件备份、finally完整恢复），其余WIP不变；其余6项回放失败全部复现，断言一致。包括续答标题间距、跨工具轮胶囊间距、首两行连续跟随、长推理完成、离底尾行恢复、终态推理收缩。属于接续前已有基线失败，不在本轮扩大修复。原命令选择的这些检查确实运行，不能报告整组全绿。
- 首张真实ChatView渲染fixture被onAppear绑定清空了消息，因此不作为视觉验收；修正为挂载后再注入，并断言真实存在3条消息再截图，最终结果待补。
- 模拟器已实际导航到云端配置，选择Claude后，捕获可点击“切换并使用”；实际tap后状态从当前opencode变为Claude/claude-sonnet-4-5的“已在使用”，成功提示出现。脱敏快照和tap结果保存为 `cloud-button-proof.json`。这是 `AMBER_CLOUD_CONFIG_FIXTURE=1` 的无网络分支，只证明真实Button action命中；不把它同受控transport拼接声称为完整按钮→真实API→服务端持久化闭环。原按钮红灯未做运行态复现，旧MacGatewayRow.trailing位于Button外的结论仍是代码证据。

## 最终定点结果

`final-focused.xcresult` 实际14通过、0失败：准确等待文案/首条纯等待/历史投影、有效ChatView渲染与viewport bounds，以及ChatAsyncReActLoopTests（包括60秒两次静默窗口的原始保活事件计数）。此前保活计数回归已修复。

最终截图 `iosApp/build/CodexTakeover20261111/final-attachments/6CB304CB-AB1D-4847-814A-F3EB42E9488D.png`：393×852pt真实ChatView、真实3条fixture消息，顶部后台运行胶囊、用户红色标题及正文没有重叠；只有单行等待执行状态，没有固定保活正文及重复裁切片段。fixture未配置真实Key，保留正常配置提示卡，不能作为真实provider/物理设备验收。

本轮一次有限维护性审查已完成：等待识别由单一规则供coalescer与投影使用，去除重复分支，保持原始持久记录；未扩大架构或改安全核验。原单消息早退取消后 `strippingCommentaryTags(in:)` 已无调用，按项目规则保留并标记，未擅自删除。

## 构建与交付

首次构建遗漏 AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER=app.amber.ios，在provisioning阶段失败，未产生可安装新包。核对2026-11-08既有成功命令后，使用原Bundle、自动签名、原Team、原无线目标和原依赖目录完成一次成功增量构建（device-build-corrected.log，exit0），没有改工程签名/权限设置。

新主二进制SHA256：`4be1d220705fd58a77283b1d3daba7e144647b0f3309c0120911c623ae92923c`。Bundle app.amber.ios。codesign --verify --deep --strict通过。无线保数据覆盖安装成功，install-result.json 的 info.outcome=success，databaseSequenceNumber=3408（前版3376），安装路径41673FD2-5BB0-41C7-9CAA-651DAFF37E1C/iosAppExperimentalGPL.app。仅一次安装，无卸载清数据。未执行真机启动/真实provider/真实多邻国行为验收；未以旧包或前次seq3376冒充本次安装。

最终四个应用源文件与基线对照前保存的修复候选逐字节相同，HEAD/MERGE_HEAD未变化。未commit/push/reset/结束merge；未卸载、清数据、重配对、部署云端、调用付费模型或关闭核验。所有真机原始材料仅在gitignore构建目录本地分析。
