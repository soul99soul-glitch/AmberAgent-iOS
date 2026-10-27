# macOS 结构化消息契约

日期：2026-10-23。对应 `ios-parity-todo.md` 的 MAC-002。本文件记录当前已落盘接口，取代最初独立 document/codec 容器的设计草案；不表示整个产品 Phase 1 或正式 Mac KMP 构建已通过。

## 模型边界

领域模型继续使用 KMP 的 `Conversation`、`MessageNode`、`UIMessage`、`UIMessagePart`，编码使用现有 `JsonInstant`。Swift 不新增图片、工具或 parts 的平行 Codable schema，也不解析和修改 canonical 内部节点。

现有 Swift `DesktopConversation`、`DesktopMessage` 保留为轻量跨语言 envelope：文字、思考、状态用于展示，`canonicalJSON: String?` 承载完整的原模型。消息已有 canonical 时，Kotlin 以完整消息为内容源；不会用 Swift 的 text/reasoning 重建并覆盖混合 parts。没有 canonical 的新文字消息和旧 v1 消息才由桥转换为原模型。

| Envelope 字段 | 语义 |
| --- | --- |
| Conversation.canonicalJSON | 完整 Conversation，包括未选中 variants、node IDs、selectIndex、会话 metadata 与原始时间精度 |
| Message.canonicalJSON | 完整 UIMessage，包括全部 parts 顺序、metadata、annotations、modelId、usage、时间和 translation |
| Message.text / reasoning | 同一 UIMessage 的顶层 Text / Reasoning 汇总，仅供页面展示 |
| Message.role | user、assistant、system、tool；工具身份不显示为用户 |
| Message.state | 桌面 complete/streaming/cancelled/failed 状态；由 Kotlin 合入 Text.metadata.desktopState，保留其他 metadata |
| Message.unsupportedPartCount | 顶层 parts 中非 Text、非 Reasoning 的数量，默认 0；供页面说明还有未渲染内容，不参与内容重建 |
| Message.variantIDs | 当前 node 全部候选的消息 ID，默认空数组；Swift 由当前 id 派生零起始 variantIndex 与至少为 1 的 variantCount |
| Message.editableTextPartIndex / editableText | 首个真实 Text part 的位置与文字；编辑只更新这一段，保留同消息其他 parts 及 metadata |
| Message.estimatedTokens | Kotlin 从真实 parts 推导的可选近似预算；缺失时使用 Swift 文本估算，不作为 tokenizer 精确用量 |

`unsupportedPartCount` 不递归统计工具 output；工具 part 本身算一个。Swift 对旧 JSON 用自定义 decodeIfPresent 将缺失字段解为 0，可选 canonicalJSON 缺失时为 nil。未知 sealed part 或损坏 JSON 由原 Kotlin serializer 报错，不通过过滤 parts 伪装成功。

## 复用源

| 源码 | 实际复用方式 |
| --- | --- |
| `core/types/src/commonMain/kotlin/app/amber/core/model/Conversation.kt` | 使用 `currentMessages` 得到选中分支，使用 `updateCurrentMessages` 合回节点并保留兄弟 variants |
| `ai-core/src/commonMain/kotlin/app/amber/ai/ui/Message.kt` | 原 UIMessage / UIMessagePart serializer；完整工具 input/output、approvalState、图片及其他已知 parts 原样保留 |
| `ai-core/src/commonMain/kotlin/app/amber/ai/ui/MessageStreamAccumulator.kt` | 正式 provider chunk 经原累加器产生完整快照，不另写 HTTP/SSE 或 parts 累加器 |
| `core/agent-utils/src/commonMain/kotlin/app/amber/core/agent/utils/Json.kt` | 使用 iOS 存储同源 `JsonInstant`，包括 UUID、时间与 sealed serial name |
| `core/conversation-storage/src/commonMain/kotlin/app/amber/core/storage/conversation/JsonConversationStorage.kt` | 原文件/index/锁/原子写/metadata owner 与图片 blob 外置、加载还原 |
| `desktop-shared/src/commonMain/kotlin/desktop/DesktopBridge.kt` | 仅提供 Swift envelope 与原 KMP 模型之间的薄转换，未引入 Room/native/iOS 后台聚合依赖 |

iOS 的 `shared/.../IosChatBackgroundPayloadJsonBridge.kt` 已有 parts 编解码与消息快照语义，但该文件属于 iOS 后台聚合。desktop-shared 直接调用相同原模型/serializer，不为几个 JSON helper 拉入整套 iOS 依赖。iOS 分支/备份逻辑仍是后续桌面功能的参考，本阶段没有宣称完整桌面分支 UI 或 `.amberbackup` 恢复已经接通。

## 已实现接口

Swift 声明位于 `macApp/AmberMac/Runtime/DesktopConversationStorageProtocol.swift`：

```swift
@MainActor protocol DesktopConversationStorage {
    func loadAll() async throws -> [DesktopConversation]
    func load(_ id: UUID) async throws -> DesktopConversation?
    func save(_ conversation: DesktopConversation) async throws -> DesktopConversation
    func updateMetadata(_ id: UUID, title: String?, isPinned: Bool?) async throws
    func normalizeImport(_ document: String) async throws -> DesktopConversation
    func exportDocument(_ conversation: DesktopConversation) async throws -> String
    func delete(_ id: UUID) async throws
}
```

正式适配器 `DesktopKMPConversationStorage` 对接同一个 `DesktopConversationRepository`：

```kotlin
suspend fun loadAll(): String                  // envelope 数组
suspend fun load(id: String): String?          // 单个 envelope
suspend fun save(json: String): String         // 实际保存后的 envelope
suspend fun updateMetadata(id: String, title: String?, pinned: Boolean?)
suspend fun normalizeImport(document: String): String // envelope
suspend fun exportDocument(json: String): String      // raw canonical Conversation
suspend fun delete(id: String)
```

以上 Kotlin suspend 入口均声明 `@Throws(Throwable::class)`，存储 lazy 初始化，读写和较大 JSON 工作放入 `withContext(Dispatchers.Default)`。Swift 文件读写在 detached task 中，使用 security-scoped URL，导出采用原子写。

Provider 的实际 Swift 协议与事件：

```swift
func start(configuration: DesktopProviderConfiguration, apiKey: String,
           messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration

case snapshot(text: String, reasoning: String,
              canonicalJSON: String? = nil, unsupportedPartCount: Int = 0)
```

正式 provider 通过以下现有桥入口消费 envelope，随后调用原 OpenAI/Claude provider：

```kotlin
fun messages(json: String): List<UIMessage>
fun snapshot(messages: List<UIMessage>, assistantId: String? = null): String
```

二者均可被 Swift catch。`snapshot` 对最后一条 assistant 先复制成指定 responseID，再同时生成外层 envelope 和内层 canonicalJSON；避免 Workspace 占位 ID 与累加器原 ID 不一致。配置/params 仍使用 `DesktopProviderBridge.configuration` 和 `params`，不新增另一套请求模型。

## 保存、流式与身份

`save` 的完整 Conversation base 优先选磁盘 existing，其次 envelope.canonicalJSON，最后才是旧格式新建模型。当前可见消息逐条使用 canonical payload；没有 payload 时保留可找到的原消息其他 parts，再更新旧文字内容。随后用 `updateCurrentMessages` 合并完整选中路径。显式变短的可见路径会截掉尾部节点；同一位置的新 message ID 成为 sibling variant，已有 node ID、其他 variants 与选中索引继续保留。

普通消息保存遵循原 storage 的 metadata owner，保留磁盘已有 title/pin。重命名、置顶以及首条消息自动标题分别排队调用 `updateMetadata`，不在每个 checkpoint 后用旧快照回写 metadata。正文与 metadata 各自记录失败并单独重试，正文保存成功不能清掉 metadata 保存失败。

保存返回实际 envelope。Workspace 只更新完整 canonical baseline；仅在当前可见 message 仍等于该次提交快照时，才补回其 canonical payload/unsupported count，避免较旧异步保存覆盖较新的流式内容。

每次 run 在创建 assistant 占位时确定 responseID。原 FIFO 队列接受并排空完整快照，stop 保留已接受内容，再写 cancelled；complete/error 与 cancel 以已排队的终态为准。切换会话后，快照、失败和存储仍归原会话。重试移除失败/中断的可见 assistant 后再构造 provider 输入，因此旧 canonical assistant 不会出现在本次请求；保存到原节点的新 assistant 成为 variant。

重启发现 streaming 时，Swift 先标记 cancelled，再通过同一存储入口同步 canonical 的 desktopState。恢复写盘完成后才结束 loading，不执行导入文档里的待处理工具。

## Phase 2 消息操作

Workspace 已提供 `regenerate(messageID)`、`editAndResend(messageID,text:)`、`deleteMessage(messageID)`、`selectVariant(messageID,index:)`。入口只在聊天 idle 且无分支写入时接受；它先等待此前 checkpoint，捕获原会话，再调用存储操作。存储成功返回实际 envelope 后才发布新分支或启动 provider，保存失败仍显示原分支，错误回到原会话。等待写入时禁止发送/重复改分支及删除该会话；切换会话仍可继续。

正式 KMP repository 增加四个 `suspend @Throws` 入口，均接受当前 envelope JSON、以完整模型修改并保存，成功后返回完整 envelope：

```kotlin
suspend fun regenerate(json: String, messageId: String, responseId: String): String
suspend fun editMessage(json: String, messageId: String, textPartIndex: Int,
                        text: String, responseId: String): String
suspend fun deleteMessage(json: String, messageId: String): String
suspend fun selectVariant(json: String, messageId: String, variantId: String): String
```

| 操作 | 已实现的数据语义 |
| --- | --- |
| assistant 重新生成（含失败重试） | 原 node 保留所有候选，追加新的空 streaming assistant 并选中，截去其后节点；provider 只接收该回复之前的上下文，不含旧 assistant。目标前没有 user 时在修改前拒绝，不产生空输入 |
| user 编辑重发 | 复制原完整消息为新 ID，仅替换指定真实 Text part，追加为原 user node 的候选并选中；截去其后节点并新建 assistant。原候选、其它 parts、metadata 保留 |
| 删除消息 | 对齐 iOS，删除整个目标 node（含该节点候选），保留所有其他 nodes；不是清空之后的上下文 |
| 切换版本 | 对齐 iOS，仅修改该 node 的 selectIndex，保留全部后续节点；后续请求使用新选中的完整消息 |

编辑/重新生成中间消息会移除后续上下文，UI 在执行前说明影响；版本箭头不静默截去后续。尚未启动 provider 的分支写入遇到 stop/退出时，成功保存后的新 placeholder 转为 cancelled 并 checkpoint，不在 stop 之后再启动生成。普通 stop 不取消独立的会话回顾请求，普通导出也不等待其他会话的辅助网络生成。

Preview 内存存储用本地候选缓存模拟这四条调用链，不解析 opaque canonical。它可编辑普通文字消息；结构化消息的 part 修改只由正式 KMP adapter 完成。该缓存不是另一套正式磁盘 schema，也不替代真实 variants 持久化测试。

## 导入、导出与旧数据

现有 Mac 磁盘文件已经是 KMP Conversation JSON，直接由新桥读取，不扫描重写目录或添加迁移标记。旧实现早前未保存的字段无法恢复；已有 canonical 字段必须继续保留。

`normalizeImport(document:)` 仅接受两种明确结构：

1. 原生 canonical Conversation（有 messageNodes），由原 serializer 解码并校验选中索引。
2. 精确 `format == "amber.mac.conversation.v1"` 的旧单会话导出 envelope；缺少 canonical 时才转换旧文字/思考/state/身份，不伪造 model/usage 历史。导入时始终采用外层当前 title/pin，避免旧 canonical baseline 的 metadata 覆盖导出时可见值；这项覆盖仅属于导入，普通保存仍遵守磁盘 metadata owner。

Swift 文件入口只生成新的 Conversation.id，保留内部 message/node/toolCall IDs 和全部 variants。先 normalize，再 await save 成功，最后发布到列表；失败不会覆盖或发布已有会话。当前入口是单会话复制导入，不是批量事务恢复或全量同步备份。

正式 `exportDocument` 以最新磁盘 Conversation 为 base，再合并当前完整 envelope 的消息，把当前 title/pin 仅用于导出结果；它不写回会话。storage.load 会将可读图片 blob 还原 inline data URL，因此正常导出是自包含 canonical JSON。读盘/保存失败时仍允许用内存已有完整 canonical baseline 加当前消息生成备份；取消异常继续向上传播。缺失 blob 沿原 storage 的诊断语义处理，不声称丢失资源能够恢复；直接复制内部磁盘 JSON 及其 amber-blob 引用不等同正式导出。

Workspace 在导出前排空该 run 已接受事件并 checkpoint，等待串行 writer；写盘失败不阻止内存备份导出。导出异步失败记录到原会话，切到另一个会话时不会串显示。

Preview / 内存存储始终导出当前 v1 envelope，并只导入该 envelope。它不解析 opaque canonical，也不会把旧 canonical 字符串当成后来 mock 消息的完整文档。此明确隔离路径不读正式数据、Keychain，也不替代正式 KMP 消费验证。

## 验证与完成门槛

本轮实际检查：

- Kotlin bridge 及原 storage 路径通过独立 JVM 编译/JUnit 13 项，覆盖完整 mixed parts/metadata/model/usage/annotations、隐藏 variants、稳定 assistant ID、旧 v1 及其外层 metadata、状态恢复、保存 metadata owner、真实 data URL 外置/blob 字节/重开、保存失败后的完整备份导出。
- `macApp/scripts/test-runtime.sh --disable-sandbox -j 2 -Xswiftc -Xfrontend -Xswiftc -disable-sandbox` 实际 Swift 6 编译并执行 31 项 XCTest，包含 Workspace、Settings、Markdown、canonical envelope。
- `macApp/AmberMacTests/Fixtures/CanonicalEnvelope.json` 来自本次实际 Kotlin serializer，包含 mixed parts、隐藏 variant 和完整 canonical。Swift 实际 decode→encode→decode，逐字保留 conversation/message opaque payload，并在测试中核实 fixture 的 parts/model/usage/annotations 和非零 selectIndex；产品 Swift 不解析内部结构。
- `KMPProviderIntegrationTests.swift` 已同步 responseID 与四参数 snapshot 事件，并加入内外稳定 ID 断言；此真实 Swift→Shared→本机 HTTP 测试尚未运行。

独立 Swift 测试排除三个 Shared 适配/组合文件与真实 provider 集成测试，证明状态机、Codable 和实际 JSON schema 传输兼容，不证明 ObjC header、Shared.framework 链接或正式 Mac app 可以运行。本轮完整 Gradle/macOS Shared 构建仍受本机 socket 权限限制；正式 Swift adapter typecheck、真实 provider/storage 集成以及受影响 iOS 回归仍是关闭 MAC-002 的必要门槛。现有 Preview 的可构建/视觉结果也不能替代该门槛。
