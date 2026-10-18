# Watch / Live Activity / DeepRead 系统集成只读审查

基线为当前脏工作树；已读 `iosApp/AGENTS.md`，已检查现有 production-audit（目前仅 plan.md，没有重复 findings）。未修改源码，未运行测试或构建。本报告的确认依据是生产调用链与状态读写；下面的测试建议尚待实施执行。

## 已确认

### SYS-1 / P2：被 run 排序拒绝的旧 Watch 审批仍会破坏新 run 的内部决策

- 位置：`iosApp/iosApp/WatchTaskCoordinator.swift:492`、`:510`，关联 `:395-398`、`:1207-1209`、`:1263-1266`。
- 触发：已注册旧 run A 与新 run B；B 当前等待 ask_user 时，A 随后到达普通审批；或 B 当前等待普通审批时，A 随后到达 ask_user。`publish` 正确拒绝旧 run，但包装方法在调用 `publish` 前已分别清除 `pendingAskUser` / `currentApprovalPrompt`。
- 实际影响：Watch 仍显示 B 原决策（`currentDecision` 未被替换），用户点回答/审批却被拒绝，分别报“当前没有等待回答的问题”或“这个操作不支持在 Apple Watch 上确认”。只影响内部状态，不要求恶意/伪造请求。
- 可达性：`Chat/Generation/Kernel/ChatRunApprovalSession.swift:102-114` 是生产发布入口。Coordinator 明确支持 foreground VM 与 headless VM 同时持有各自 run（`:57-61`、`:883-888`），旧 run 仍有效但不是最新 Watch 卡片的情况下可晚到。`isCurrentRun` 检查仅保证它属于原 VM，不保证它是 Coordinator 当前最新 run。
- 二次复核：不是“旧 run 本就应被拒绝”的 by design；旧 run 被拒绝符合设计，但拒绝必须不更改 B 的决策数据。对称清理应只在 `publish` 接受后进行。
- 最小修复：将两处反向字段清理放到 `if accepted` 内，连同各自 prompt/request 的赋值一起完成。无需引入新状态机或重试。
- 测试 seam：已有 `WatchTaskCoordinator` 可注入 bridge/companionService/VM；注册 A/B 起始时间，发布 B 决策、A 的相反类型旧决策，随后提交 B 正确 request，验证仍交给 B owner。两个方向均覆盖；同时断言卡片仍是 B。

### SYS-2 / P2：DeepRead 失败重试恢复旧文章时丢失 Workspace 未保存标记与补存入口

- 位置：`iosApp/iosApp/DeepReadCreateView.swift:9-12`、`:80-86`、`:674-679`，关联 `DeepReadCore/IOSDeepReadStore.swift:145`、`:208`；可见入口在 `DeepRead/IOSDeepReadTaskDetailView.swift:389-415`。
- 触发：已有部分成功文章（有 missingSections），同时 Workspace 保存失败而 `workspaceSyncFailed != nil`。用户点击补齐缺失段落；重试因无可用模型/模型失败等失败。Launcher 把先前正文、JSON、missingSections 放入 PriorCompletion，却未存 Workspace 失败标记；prepareRetry 清标记，失败恢复再调用 complete 清标记。
- 实际影响：旧文章恢复 succeeded，但并未存入 Workspace，也没有再次尝试存入 Workspace；告警和“仅重试保存到 Workspace”按钮消失。重启后同样丢失，用户无法通过既有补存入口完成原操作。
- 二次复核：新文章成功后重试 Workspace 应使用新正文，清旧标记符合设计；问题限定在**本轮失败而恢复原文章**的路径。恢复原文章必须恢复它的同步状态。无模型失败路径在任何新 Workspace 保存调用前返回，故不是重复存入后清理标记。
- 最小修复：PriorCompletion 同时快照 `workspaceSyncFailed`，只在恢复旧文章时将其一起恢复；或提供 store 内单次原完成快照恢复操作。保持成功新文章的现有 Workspace 保存流程，不新增兜底或自动重试。
- 测试 seam：扩展 `IOSDeepReadPipelineTests.testFailedRetryRestoresPriorCompletionInsteadOfDestroyingArticle`，给原完成状态写入 Workspace 失败，prepareRetry(preservingResult:true) 后用未配置模型触发失败，重载磁盘，验证正文与同步告警都恢复，再执行现有 retryWorkspaceSync 验证有入口且可成功。相同 PriorCompletion 也用于系统 expiration，可复用恢复 seam 验证。

### SYS-3 / P1：DeepRead 历史加载失败被视为首次空库，下一次创建会覆盖原文件

- 位置：`iosApp/iosApp/DeepReadCore/IOSDeepReadStore.swift:284-290`，关联初始化 `:40`、创建 `:97-104`、落盘 `:278-281`。
- 触发：已存在 `deep_read/tasks.json`，但文件读取失败或任意一条记录 JSON 解码失败。loadTasks 将“不存在”和“已有文件无法读取/解码”都返回 []；当前对象仍允许 createTask。
- 实际影响：原历史从 UI 消失；下一次创建成功时用仅含新任务的数组原子覆盖原 tasks.json，丢失可恢复的旧历史/源文/文章。临时读取失败后恢复可读也不会自动重载。
- 二次复核：原子写只能保护一次写入完整性，不能保护加载失败后空快照覆盖。当前 store 没有损坏状态/只读门；与同仓 `IOSWatchCompanionService.load` 对 invalid storage 禁止覆盖原文件的处理不同。仅缺失文件返回空库是正确设计；已有文件失败不应继续写空库。
- 最小修复：加载结果明确区分 missing、loaded、failed；failed 时展示可理解错误，并阻止持久化覆盖该文件，保留原文件供重新读取/恢复。不要自动删文件、无上限备份或添加通用恢复框架。
- 测试 seam：临时目录写入 malformed tasks.json，构造 IOSDeepReadStore，调用 createTask 应失败且原字节逐字保持。再覆盖合法历史构造新 store 应正常读写，证明正常路径未被阻断。可另用不可读路径覆盖读取失败分支。
- 范围：本仓 DeepReadApp 也直接消费此 store，因此实现时除主 App 的 IOSDeepReadPipelineTests 外，应补 standalone 受影响的 store/runtime 验证；不用读取任何兄弟产品仓库。

## 复核后排除 / 暂不报问题

- DeepRead 页面退出不会取消 App 级任务。RunRegistry 由单例 coordinator 持有，不是 View 的 `.task`；没有退出时取消链。
- DeepRead 系统 expiration 的 generationID 捕获与 cancel/finish 精确匹配；旧回调不能取消后来同 taskId 的新 owner。operationTask 的 defer 仅在 finish 接受本 generation 时结束 KeepAlive。
- UIKit 短后台窗口到期不取消 DeepRead run 是明确设计（ExpirationHandlers 为 nil）；不能当作缺少取消回调。
- Live Activity start 在途时 end/stopCurrent 记录 revocation，落地后立即结束；同 run 再 start 撤销 revocation 是明确“最新意图”设计，已有 pending-start 测试。
- Live Activity per-card write 队列保证正常 update/end FIFO；noteProgress 排队前重新核对 card id / 最新展示，避免旧 heartbeat 覆盖新步骤。
- Live Activity `ownsActivity` 对仍留锁屏的 ended 卡片可能返回 true，但调用方仅用于校验该 run 的深链目标对话；不会据此批准或恢复旧任务，因此未报问题。
- 启动恢复只保留 backgroundRunIds 的系统卡片：可能与启动过程中刚建立的新前台/DeepRead run 存在交错，但没有取得稳定生产触发，暂不列缺陷。若修复 startup recovery 相关内容，应检查是否仍可能扫描新 run；不建议先加额外框架。
- 系统实际后台时长、ActivityKit 授权、Watch 配对/可达性，以及真机长期运行均未验证；缺证据不当作缺陷。
