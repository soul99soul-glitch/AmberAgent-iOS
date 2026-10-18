# Platform 候选独立二次复核

只读复核当前 working tree 的 production 调用链；未修改源码、未跑测试/构建。结论均为 accepted，但 Search 的时序描述和 DeepRead storage 的恢复范围应收窄如下。

| 候选 | 判断 | 定级建议 |
| --- | --- | --- |
| PLAT-1 Search 导航失败/缺 request owner | accepted | P2 |
| SYS-1 旧 Watch run 清空当前 pending 决策字段 | accepted | P2 |
| SYS-2 失败重试恢复旧文章却丢 Workspace 失败标记 | accepted | P2 |
| SYS-3 DeepRead 历史读取/解码失败后创建覆盖 | accepted | P1 |

## PLAT-1：accepted

`Search/SearchView.swift:227–234` 对每次点击新建不保留的 Task，`selectConversation` 返回 Void，随后无条件 `router.navigate(.chat)`。`IOSConversationStore.swift:536–574` 明确把失败保留当前会话作为契约，并提供 Bool + `commitIf`；因此目标B被删/加载失败时导航到当前A是直接可达错误。`chatViewModel.prepareForConversationChange` 只检查当前run能否切换，不检查B是否存在或load成功。

时序问题也成立：用户点B后在load挂起期间取消Search，原Task没有生命周期owner，后续仍会提交B并导航；快速多次点击每个Task都会导航，多push可达。现有Home `Home/ConversationsView.swift:717–735` 实现取消旧Task、commitIf、确认currentID后才navigate，确立了当前目标应该采用的局部既有模式。

**收窄**：KMP storage 自身operationMutex会串行load，因此不能仅凭两个delay就把“B一定晚于C完成并夺回”当必现现象；不需依赖该极端顺序才能确认bug。证明“load失败不导航”及“dismiss/后一次点击取消旧选择”的回归已足够，不增加新的导航框架。

## SYS-1：accepted

`WatchTaskCoordinator.swift:492`、`:510` 在 `publish` 返回acceptance前修改相反类型字段。`publish` 在`:395–398`可因run排序早退，早退保留B的currentRunId/currentDecision/currentPresentation，却已经被包装方法清掉B的 `pendingAskUser` 或 `currentApprovalPrompt`。随后`:1207–1209`/`:1263–1266`实际消费这些字段并拒绝动作。

跨run晚到可达：`ChatRunApprovalSession.swift:72–114` 在mark durable/persist/liveActivity多个await后发布，isCurrentRun只归属该session；coordinator同时识别foreground和headless owners（`:57–61`、`:883–888`）。旧run仍有效、更新run已成为Watch当前卡片的情况受现有排序契约明确支持。

**最小修复同意**：只把反向清理放入`if accepted`，保留现有publish拒绝策略。需要两个方向反例，不做额外run状态机。

## SYS-2：accepted

`IOSDeepReadPriorCompletion`只存markdown/JSON/missingSections（DeepReadCreateView.swift:9–12，构造:80–85），store.prepareRetry(:208)先清workspaceSyncFailed。失败（例如未配置模型，Launcher:175–185）直接走failRun→restorePriorCompletion(:669–679)→store.complete，后者`:145`再次置nil；这条失败路径尚未执行Workspace保存(:408)，因此不能用“新文章已保存，旧标记应清理”排除。

UI banner和Workspace-only retry按钮完全依赖done + workspaceSyncFailed（DeepRead/IOSDeepReadTaskDetailView.swift:389–415）。字段明确声明是持久化的Workspace同步失败状态（DeepReadCore/IOSDeepReadModels.swift:111–114），与上一版文章一起恢复符合现有契约。

**最小修复同意**：快照这个字段，只在恢复先前文章时同一次store更新写回；新内容生成成功的complete仍清旧标记。不要增加自动保存/自动重试。Standalone DeepReadRuntime虽使用同一个store但没有主App Workspace同步流程，本项主影响为主App launcher；无需为了统一抽象同时改standalone runtime。

## SYS-3：accepted，真实写链及备份复核

`DeepReadCore/IOSDeepReadStore.swift:284–290`把不存在、Data读取失败、任何array item decode失败全部折叠为[]。init(:40)不记录失败；下一次`createTask`(:97–104)从空tasks append，再persist(:278–281)把新数组原子写到原tasks.json。read failure已经恢复可写（如首次访问受保护，稍后解锁）或schema解码失败但目录仍可写时，会直接覆盖原可恢复历史。JSON文件原本可能只需修正一个记录/字段，后续原子替换会删除所有旧内容。

**备份/恢复契约复核**：该store无backup/quarantine/reload/load-error state；DeepReadCore和Standalone sources未发现另一份tasks历史自动备份或修复流程。`IOSSyncBackup.swift:64–94`支持settings及conversations.zip，conversation bundle来源conversations目录，不含deep_read/tasks.json；因此现有产品备份链不补偿该覆盖。不能把“用户可能另有设备备份”作为此写入安全的证据。

主App真实入口 `IOSDeepReadLauncher.createAndGenerate`先store.createTask；独立DeepRead `DeepReadRuntime.create`也直接调用同store，且`DeepReadApp/project.yml:28`共享DeepReadCore。两端可达，非测试专属。

**最小修复同意**：区分missing/loaded/failed；failed时保留读失败状态并在persist入口拒绝覆盖，create将错误显示给用户。维持缺文件首次创建正常。可支持显式重新加载但不要自行实现数据修复、任意条目忽略或额外备份体系；至少保留源字节，恢复工作另有明确入口时再做。

**测试应覆盖**：malformed现存文件→init空展示但可见读取错误→create抛错且磁盘字节不变；合法/缺文件仍正常；同store的write guard足以覆盖主App和standalone，两target都需编译验证。现有IOSDeepReadPipelineTests的blockTasksFile仅测写失败，不包含启动读取失败后文件可写覆盖这个窗口。
