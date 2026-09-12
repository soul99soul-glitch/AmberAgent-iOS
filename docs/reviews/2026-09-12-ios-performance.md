# iOS 性能审查与优化（2026-09-12）

范围：当前 iOS 仓库，重点是用户确认的长回复生成、表格与聊天滚动，同时审查小说工作区、动画、WebMount、图片、文档和持久化。当前默认聊天路径为 `ChatView → NativeChatTimelineView`。现有 SSH/终端/SettingsStore 未提交改动不属于本轮修改。

本轮没有调整字体、图片分辨率、模糊、透明度、动画时长、帧率、粒子数量、表格发布间隔或滚动跟随策略。源码确认的冗余与模拟器结果分开记录；不把主机或模拟器结果当成 iPhone Air 的温度、功耗或手感验收。

## 已修复

| 路径 | 实际触发与成本 | 修改及保留的契约 |
| --- | --- | --- |
| 正文布局 | `ParagraphUIView.layoutSubviews` 每次都失效 intrinsic size；SwiftUI 使用 `sizeThatFits` 时，原来的 intrinsic cache 还可能一直为空，不能充当“宽度已稳定”的判断依据 | 记录真正布局过的宽度；Amber 显式使用的 TextKit 1 在宽度、容器没有变化时不再追加失效请求。文本追加、宽度修正、复用重置仍按原契约处理；TextKit 2 继续原有 intrinsic 失效行为 |
| 正文测量一致性 | 既有 TextKit 1 全量测量使用整行分配矩形，增量测量使用实际内容矩形；24KB 正文同一宽度下分别返回 361pt 和 359pt | 全量测量也按实际使用的行片段取边界，统一与增量快路径的口径。原始实现对照复现后修复，保留严格相等断言；增长高度、换行、宽度变更与表格回归均通过 |
| 长正文渲染 | `SingleBlockView` 每次渲染合并正文，都重新遍历整段 attributed string 查找附件 | `coalescedText` 的生产构造入口已经排除了附件，直接使用该契约；普通段落、附件与公式路径继续原来的检查 |
| 流式引擎 | `ChatKernelRunHost` 使用消息快照，没有注册累计正文/思考文本回调，但 `StreamStepState` 仍维护另一份累计字符串 | 按实际 callback 需求收集；KMP accumulator、48ms 快照、完整终态消息及后台/小说/子代理的累计回调保持不变。这里只确认删除无消费者的工作，不宣称每个 Swift append 都是全量复制 |
| 记忆引用 | 每个流式 chunk 都从已经捕获的全部引用重新 `flatMap + Set` | 只吸收新完成的引用；跨 chunk 标签解析、finish、去重和同步锁不变 |
| 历史消息投影 | 即使没有压缩分界线，也遍历全部会话 ID 做校验并查找空锚点；空的渲染器记忆也会扫描历史 | 空边界、空记忆及会话重置直接跳过无用扫描。存在压缩边界时仍验证覆盖范围；保持分页的绝对索引、分支、消息身份和末尾锚点 |
| 工具排序 | 比较器每次执行都重建同一个 WebMount 工具名 union | 使用静态不可变集合，排序等级和工具声明不变 |
| 思考球 | 每次 SwiftUI 更新重建 preset 字典；每帧在粒子循环内重复读相同字典值，并扩容 dot 数组 | preset 按真实输入变化更新；帧内常量提到循环外、预留数组容量。数学公式、绘制顺序、密度和帧率不变 |
| 顶部光效 | 每帧重新构造 5 个相同胶囊路径；无关 SwiftUI 更新也触发额外重绘 | 路径随 bounds 缓存；相同配置不重复提交绘制，尺寸变化仍通过 `.redraw` 重绘静态光效。原有显示时钟、旋转、呼吸和渐变不变 |
| WebMount 导航 | 页面提前完成或被新导航取代后，旧超时 Task 仍等待到期再唤醒 | 持有并取消已无用途的超时 Task；导航 ID、完成/error、URL 策略和超时结果契约不变 |
| 小说工作区 | 导出/保存中对每章、素材、事件、剧情模块反复线性搜索；还有一个没有消费方的全量素材分类计数 | 每次操作建立局部索引，消除相乘的查找成本；保持输出次序、同时间戳版本选择、first-match 行为、校验和原子提交流程 |
| 独立性能回放 | `ChatPerfReplayView` 仍渲染旧 `ChatSwiftUIMessageList`，无法代表生产列表 | 改接 `NativeChatTimelineView`，复用已有输入夹具；默认 App 入口不变 |

关键实现：

- `iosApp/vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/UIKit/ParagraphUIView.swift`
- `iosApp/vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/BlockView.swift`
- `iosApp/iosApp/IOSAgentToolEngine.swift`、`IOSMemoryCitationStripper.swift`
- `iosApp/iosApp/ChatMessageProjection.swift`、`ChatCollectionMessageList.swift`、`ChatPerformanceSupport.swift`
- `iosApp/iosApp/ThinkingOrbEngine.swift`、`ThinkingOrbView.swift`、`IslandEdgeGlowView.swift`
- `iosApp/iosApp/IOSLocalToolExecutor.swift`、`ChatRunKernelAdapter.swift`
- `iosApp/iosApp/NovelCreation/NovelWorkspaceBackup.swift`、`NovelWorkspaceAuthority.swift`、`NovelWorkspaceProjectStore.swift`

## 没有采用的改动

- 没有通过降帧、降低粒子密度、减少文字动画或放慢流式发布换取更低开销。
- 没有改写历史 Markdown 的 UTF-8 索引：临时主机实验没有支持其收益，额外字节副本与大面积签名修改不值得保留。
- 没有强加 16MB 的 AST 缓存预算：现有缓存由 NSCache 管理；在未测实际占用、命中率前缩小缓存，可能增加长历史的同步重解析。
- 没有改变代码块高亮调度或代码复制行为。
- `makeTextKit1View` 在初始化结束后才设置容器高度，原设置顺序正确；“setupView 覆盖配置”的怀疑已排除。

## 仍需专项处理的路径

以下是本次审查发现的具体成本，不等于已证明它们造成用户这次卡顿，也不包含在已修复项中。

1. **静态聊天页面的轮询**：`NativeTimelineScrollViewResolver.Coordinator` 用常驻 60Hz display link 检查布局指标。其实际能耗需要 Time Profiler/Energy 数据。替换为事件通知需要同时覆盖聊天、小说、议会、键盘和异步 Markdown 布局；本轮保留以免破坏跟随时序。
2. **普通启动时创建 WebView**：`AppShell → IOSLocalToolExecutor → IOSWebMountController.shared → IOSWebMountSessionStore → IOSWebMountWKRuntime` 会在使用浏览器前创建默认 runtime。适合单独验证延迟创建后的会话恢复和工具首用行为。
3. **图片返回后的主线程工作**：`IOSImageGenerationRepository` 是 MainActor，响应解析、base64 解码和原子落盘仍有同步工作。后续可把计算与 IO 移离主线程，保持原始像素及输出文件；不建议通过降分辨率解决。历史记录之外的图片还可能被聊天引用，不能直接按记录淘汰删除文件。
4. **大规模 Workspace/Deep Read 持久化**：`IOSWorkspaceStore` 和 Deep Read 历史仍有完整 JSON 编码/同步写入；PDF 预览有每页重新拼接并计数的冗余。大文档预览解析已在 utility task，不能把它误报为主线程解析。异步持久化需要同时处理写入顺序、退出与恢复，未在本轮引入额外协调层。
5. **会话终态扫描**：`IOSConversationStore.save → refreshSummaries → JsonConversationStorage.listSummaries` 仍校验全库文件版本。已有缓存可避免未变化文件的重复解码；刷新还承担外部/后台变化可见性，不能直接删掉。
6. **实验版音频保活**：当前在 generation 开始时启动，前台也可能有成本；它属于已有后台运行策略，本轮没有削弱该能力。

Recipe registry 的主要刷新在独立 actor 中，当前证据不足以把它归为主要卡顿原因。

## 验证记录

按用例 ID 去重并取本轮最后一次结果：**382 项通过，1 项跳过，无未解决失败**。这是多组受影响用例的汇总，不是一次全仓测试；没有用重复运行增加通过数量。

- 使用 `iosApp/project.yml` 重新生成 Xcode 工程，Swift 继续通过本仓 Gradle 工程生成并消费 Shared.framework；本轮没有修改 KMP 源码。
- 首轮 iPhone 17 Pro / iOS 26.5 模拟器：183 项中 178 通过。3 项中文文案断言遇到英语测试环境；长表格 P95 为 40.42ms，超过已有 40ms 门槛；另有一项受到 FrontBoard `force-quit(0xfbfbfbfb)` 中断。保留原断言，在专用中文模拟器复测。
- 首轮结果：`/private/tmp/amber-performance-20260912-chat.xcresult`。
- 专用中文 iPhone 17 Pro / iOS 26.5 模拟器综合回归：380 项中 378 通过、1 跳过、1 失败。跳过的是未提供 `/tmp/amber-repro-pkg` 真机小说包的现有用例；唯一失败是正文增量与全量测量宽度相差 2pt。原始 ParagraphUIView 对照也复现相同失败，随后修复并通过后续回归。综合结果：`/private/tmp/amber-performance-20260912-final.xcresult`；原始实现对照：`/private/tmp/amber-performance-20260912-paragraph-baseline.xcresult`。
- 修复测量差异后，最终渲染回归 **207 / 207 通过**，覆盖仓库要求的聊天回放、Native scroll core、viewport，以及投影、内容 hash、增量正文、CJK、代码块、正文边距和表格布局。结果：`/private/tmp/amber-performance-20260912-render-final.xcresult`。
- 最终动画回归 **33 / 33 通过**，并完成包含静态光效尺寸重绘设置的增量构建。结果：`/private/tmp/amber-performance-20260912-animation-final.xcresult`。
- 最后一次 80 行表格追加测量：84 个帧间隔样本，P95 **34.92ms**、最大 **57.78ms**，通过现有 40ms / 80ms 门槛；没有修改断言。前一轮对应值为 27.12ms / 77.60ms，表明仍有运行波动；不使用这些不同运行结果推算真机提升比例。
- 思考球 HEAD / 当前引擎配对检查：6 状态 × 2 preset × 3 时间点 × 明暗，共 **72 帧 raw pixels 完全一致**。同一 macOS CoreGraphics `-O` 主机基准，每版各运行 3 次 3000 帧，中位数 **974.953ms → 943.944ms**（约 3.18%）；该数字仅覆盖这个独立绘制引擎，不代表整个 App 或 iPhone Air。详细记录：`/private/tmp/amber-orb-paired-bench-report.txt`。
- iPhone Air 显示已配对，但读取进程时 CoreDevice 连接被重置。没有安装本轮构建到真机，没有测得其 CPU、GPU、内存、能耗或温度变化。
- `git diff --check` 通过；本轮修改保留在工作树，没有提交或推送。
