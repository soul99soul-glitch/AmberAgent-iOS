# iOS memory wiki 与展示数据约定

本轮基于 `76676f78`，只实现记忆核心与数据接口，不修改展示页、聊天时间线或渲染。

## 数据源与 wiki 编辑

- `memories/memories.json` 中的 `MemoryRecord` 继续作为用户事实的权威数据源。
- `index.md`、`topics/<id>-<slug>.md` 是记录的派生视图；读取时按当前记忆范围开关、归档和有效期过滤。
- agent 编辑的是独立的页面笔记层，原子写入 `memories/wiki-notes.json`。每个版本保留 `id / path / content / reason / source / restoredFrom / createdAt`，再合并进派生 Markdown。下次整理或重建 Markdown 不会覆盖笔记。
- `source` 为 `agent:memory_tool`，不冒充用户原话。笔记不会自动晋升为用户事实、置顶或核心记忆。主题笔记按数字 id 归属，标题/slug 改名后保留版本。
- `wiki_revert` 追加恢复版本，不删除历史；`revision_id:""` 撤回到无笔记。`expected_revision` 过期会拒绝写入，要求重新读取。

主 agent 复用 `memory_tool`，新增动作：

| 动作 | 输入 | 返回要点 |
| --- | --- | --- |
| `wiki_read` | `path`，可选 `from_path / offset` | `content / links / revision / editable_note / next_offset`；每段最多 6000 字 |
| `wiki_search` | `query` | 命中页面相对路径与预览，最多 20 个 |
| `wiki_edit` | `path / content / expected_revision / reason` | 替换该页的笔记层，返回新版本 |
| `wiki_history` | `path` | 该页完整笔记版本及来源 |
| `wiki_revert` | `path / revision_id / expected_revision / reason` | 新增恢复版本 |

读操作免写审批；编辑和撤销沿用现有 memory-write 审批。可创建 `notes/<name>.md` 笔记页。已有记录的内容仍须通过原记录编辑路径处理。

## 链接和 UI 读取

使用标准相对路径 Markdown：

```markdown
[习惯](topics/3-习惯.md)       <!-- 从 index.md 出发 -->
[返回索引](../index.md)       <!-- 从 topics/3-习惯.md 出发 -->
[主机经验笔记](../notes/host.md)
```

agent 按链接继续读取时，传链接原文为 `path`，所在页为 `from_path`。只允许 wiki 内 `index.md / topics/*.md / notes/*.md`，拒绝外部 URL 和越界。片段 `#标题` 不影响页面定位。

展示页继续使用 `IOSMemoryPersistence.memoryDocuments()` 和 `memoryDocumentText(relativePath:)`；文档列表已包含 `notes/`。UI 分支 `30534d6f` 的 `MemoryWikiLinkResolver` 可以继续包装为 `amber-memory-doc://open?href=...`，核心层不依赖这个 UI scheme。

差异：UI resolver 对 `index.md` 和 `topics/...` 有额外的“从根目录解释”兼容规则；agent 的 `from_path` 严格按标准相对路径。生成的跨层链接使用 `../`，两者一致；从主题页链接到另一个根下目录请使用 `../notes/...`。

## 每日模型纠错与待确认提示

沿用现有每日整理预算、环境条件和 `dreamModelEnabled`（默认关闭），在主题/画像整理前执行一次纠错。

对照范围有界：最多 80 条有效记录，当前及最多 8 个列表会话中的最近 8 个封存 Episode，最多 32 条/12000 字用户原文。不把 Episode 摘要、助手回复、工具输出或 mailbox 合成消息当用户事实证据。

模型建议还须通过本地复核：逐字 quote 真实存在、来源时间晚于记忆版本、记录和来源在等待期间未改变、范围和写权限仍开启。普通记忆只归档，不删除，继续使用现有恢复入口；核心/置顶只生成待确认提示。

`IOSMemoryPersistence.events` 是持久化的 `MemoryEvent` 镜像。纠错先记 `dream_planned`，归档成功后记 `memory_archived`；`message` JSON 保留 `memoryVersion / conversationId(事件字段) / episodeId / messageId / quote / reason / kind / decision`。写入失败保留提议但不伪造成功事件。

UI 获取待确认项：`persistence.events.pendingCorrectionReviews(records: persistence.records)`。每项包含 `memoryId / conversationId / detail.episodeId / detail.messageId / detail.quote / detail.reason`；原记忆改过版本或已归档后不再返回旧提示。

## 经验记忆

复用现有成功完成任务后的 `scheduleMemoryExtraction / enqueue` 作业、提炼模型、权限和每日预算，不增加模型请求或调度器。在同一次提炼响应里独立返回 `experiences`（0–2 条），用户事实 `memories` 的逐字证据规则不变。

`memories/experiences.json` 是独立类别，保存工具观测、任务范围、`conversationId / sourceMessageId / completionMessageId / toolCallId` 来源。现有 `AgentRunSummary` 是轻量状态投影、`IOSJevRunSummary` 是显示统计，不含可提炼的执行事实，因此使用它们完成路径上的实际工具观测，而非从显示统计猜经验。

只接受已执行工具的可核对 quote；去除凭据，校验新引入的英文/数字来源。相同工具、范围和规范化文本去重，默认 30 天、最长 90 天有效。关闭长期记忆、受污染会话或来源变更时不写入。

经验不进入常驻索引、画像、用户事实或 always-eligible 集合。只在当前任务范围匹配，或当前工具与任务词同时相关时召回，最多 2 条/800 字，并使用本轮事实召回后余下的条数和字符预算。原 `MemoryRecallSetting` 的 24 条/6000 字默认值未改。工具名相同本身不够触发主机经验召回。

## 体检数据与 UI 对接

核心 API：`persistence.memoryHealthSnapshot() -> IOSMemoryHealthData`。四个同名字段可直接填 UI 分支现有模型，无需重定义它：

```swift
let data = persistence.memoryHealthSnapshot()
let snapshot = MemoryHealthCheckSnapshot(
    supersededRatio: data.supersededRatio,
    citedRatio: data.citedRatio,
    residentInjectedChars: data.residentInjectedChars,
    maxPromptCharsBudget: data.maxPromptCharsBudget
)
```

- `supersededRatio`：已知被取代或明确作废且尚未恢复的原子记录 / 当前原子记录与 `supersedesIds` 已知历史记录的并集。排除主题；作废依据为纠错或自动提炼的 `memory_archived` 事件。普通过期、久未使用归档不当成错误。没有记录时为 `nil`。
- `citedRatio`：已保存 `MemoryEventType.memoryUpdated` 使用事件中，同一 `(runId, memoryId)` 先被注入又被隐藏引用标记引用的对数 / 已注入的对数。重复工具轮次去重，未注入的主动工具引用不虚增分子。无观测为 `nil`，不会给旧会话倒推统计。
- `residentInjectedChars`：最近一次实际组装进请求的常驻 **wiki 导航** `String.count`，不包含按需事实、经验、深层页面或历史正文。未组装过为 `nil`，禁用/无内容后为 0。
- `maxPromptCharsBudget`：此常驻导航的 1000 字上限。它与事实召回的 24/6000 不是同一个预算；字段名与 UI 一致，UI 辅助文案宜显示“导航上限”。

如 UI 想显示全部 memory 区块而非仅常驻导航，可另读 `persistence.health.latestPrompt?.totalMemoryPromptChars`；这个值包含原召回提示词包装，不能当作 `MemoryRecallSetting.maxPromptChars` 的条目正文预算。

统计从本轮代码开始观测。事件文件不可读/保存失败时比例返回 `nil`，不将缺失证据显示为高质量；原文件保留。所有统计读取均使用已加载内存数据，不在 UI body 里读文件。
