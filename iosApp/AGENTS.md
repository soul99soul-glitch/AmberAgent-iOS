# AmberAgent iOS Instructions

本文件适用于 `iosApp/` 下的原生 iOS 应用、测试、脚本和 vendor 集成。先遵守仓库根 `AGENTS.md`，再应用以下局部规则。

## Architecture Boundaries

- 默认聊天列表主路径是 `NativeChatTimelineView`。`ChatSwiftUIMessageList` 与 UICollectionView 路径只保留非默认回归用途，不能替当前生产路径背书。
- UI、状态、持久化、provider 请求和 KMP 共享逻辑应各自保留清晰所有者；不要把补偿逻辑堆进 `ChatView` 或单个 ViewModel。
- 修改 provider 时区分 KMP provider、iOS 配置桥、认证状态、请求构造和候选模型列表；沿真实调用链验证，不根据 UI 文案推断。
- 修改 vendor 时保持默认值等于旧行为，只在 AmberAgent 调用点显式启用新行为，除非用户明确要求改变共享默认值。
- 修改小说创作前继续读取 `iosApp/iosApp/NovelCreation/AGENTS.md`，遵守候选稿、项目状态、注入和生成终态的局部契约。

## Chat, Streaming, And Scrolling

- 不使用 `scrollTo(y:)`、直接写 `contentOffset` 或魔法高度补偿掩盖滚动、测量或锚定错误。
- 用户查看历史时不得被自动拉回底部；主动回底后流式内容必须继续实时更新。
- 屏幕内可见动画只能升级不能降级。只有确定不可见的内容可以降级解析或渲染，而且必须能在回到可见区时恢复。
- 表格、Markdown 和公式问题先区分解析、rewrite、renderable cache、布局测量与滚动策略，不把不同层的症状混成一个修复。
- 流式事件必须检查 chunk、complete、error、cancel、background handoff 的 FIFO 与最终快照语义，避免 pending chunk 或 partial 内容丢失。

任何触碰聊天滚动、布局、消息投影、Markdown/表格渲染或 viewport 策略的改动，至少运行：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests test
```

根据改动补跑 `ChatRowContentHashCacheTests`、`ChatMessageProjectionTests` 或对应定点测试。模拟器通过后仍不得把视觉和手感标记为真机已验证。

## State, Storage, And Background Work

- 会话消息、title、pin、metadata owner 字段和后台 completion 可能由不同路径写入；任何复合读改写都要防止旧快照覆盖较新的字段。
- 切会话或进入后台后，错误、OCR 结果、workspace 保存状态和生成结果必须回到原始会话，不得串到当前会话，也不得静默丢弃。
- 用户可见操作不能以 silent return 收口。无法执行时给出可理解的状态或错误，并保留重试路径。
- 修改存储或后台生成时，覆盖 success、partial、error、cancel、expiration、retry 和 stale-write 路径。

后台运行与 Live Activity 以 `runId` 为所有权标识：

- 页面退出只解除 UI 观察，不得据此取消仍由 App 级 owner 持有的运行。
- completion、cancel、expiration、系统卡片移除和深链恢复只能作用于匹配的 run；旧回调不得结束或抢回新 run。
- 结束系统任务前先写入该 run 的 durable terminal 或可恢复 checkpoint；不把“已提交系统任务”表述成“系统保证持续运行”。
- 只有真实支持服务端持久化与游标恢复的 provider 路径才可声明跨进程恢复；其他 provider 仍是 iOS best-effort 本地续跑。

优先运行受影响的测试类，例如：

- `IOSConversationStoreTests`
- `IOSConversationStoreBranchingTests`
- `IOSParityRedLightTests`
- `IOSAgentToolEngineTests`
- `IOSDeepReadPipelineTests`

触碰 KMP conversation storage 时，同时运行对应 Gradle 测试，不以 Swift 层测试代替共享层验证。

## Settings And Providers

- 设置项完成的最低闭环是：可见控件、持久化读写、运行时消费。缺任一项都不算接线完成。
- 新增或修改设置接线时更新 `IOSSettingsWiringTests` 或同等行为测试。
- provider 配置问题要核对 credential source、auth mode、base URL、request path/body/headers 和 fallback；候选模型列表不等于已经持久化的模型配置。
- 认证成功、失败、退出和恢复不得破坏用户已有 endpoint 或模型配置，除非产品契约明确要求重置。

## UI And Device Evidence

- UI 改动优先沿现有视觉系统实现，不顺手重写导航、主题或组件体系。
- 固定格式组件应有稳定尺寸约束，长文本、动态状态和辅助功能字号下不得重叠或撑坏布局。
- 需要真实触感、120Hz 时序、键盘、安全区、后台能力或系统权限证据时，安排真机验证；设备不可用时明确记录为待验证。
- 装机或发布前先汇报本轮变量、预期改善、预期不变和已知残余。

## SwiftUI 失效与主线程纪律

- 通过 `.environment` 传递的值必须可判等或身份稳定；禁止每次 body 求值新建闭包注入环境——新建闭包不可判等，会让所有消费者判定环境变化并重算（用身份稳定的 handler 容器或可判等的值代替）。
- 被 SwiftUI 观察的集合/属性只在内容真的变化时写入；原地 `removeAll`/`append` 即使结果无变化也会通知观察者——多步增删改在不受观察的工作副本上做，最后比较后再发布一次。
- body 及 body 读取的计算属性内禁止磁盘 IO、JSON 解码、系统权限/授权查询等阻塞调用；这些调用会在每次重算时重复执行，需要时缓存结果或移到事件/后台路径。
- 用户交互事件处理里不做同步系统 IPC（AVAudioSession/AVAudioEngine、ActivityKit、权限探测）；放到后台队列或动画落位之后，避免阻塞点击响应。
- 根视图/父视图不直接读流式或高频变化的原始集合（如 `viewModel.messages`）；改读可判等投影，原始集合的读取留给点击/事件闭包这类不受 body 重算频率约束的路径。
- 自定义 `Layout` 若 `makeCache` 做测量，必须实现 `updateCache`；默认实现会在每次布局都重新调用 `makeCache`，抵消缓存的意义。
- 一次请求准备或一次渲染内会重复执行的纯计算（token 估算、记忆打分、文件读取）应缓存或只算一次；涉及性能的改动须附前后测量（见 `iosApp/scripts/perf/`）。
