# Phase 1 独立 review

结论：**PASS，无已确认 blocking findings。** 本 reviewer 未参与本阶段实现，只读最终代码、关键测试及已提供的 red/green 证据；未运行构建或测试。S1 另由原 audit_kmp 做窄范围只读 peer，结论同为 PASS，详情见 phase1-s1-peer.md。Root 的 iOS 统一 green 结果由 Root 补齐后收口。

范围仅 S1/S2/CRED-1/CRED-2/KMP-1/KMP-2/PHONE-1/PHONE-2。凭证补丁用 credentials-before 快照对照；其他部分沿本轮窄改与调用链检查，未把既有模块化 WIP 或 concurrent-changes.json 中并行删除的 visual tests 算作本阶段变动，也没有恢复/修改这些文件。

## 逐项判断

| 项目 | 判断 | 最终实现及关键证据 |
|---|---|---|
| S1 分支/消息快照并发 | PASS | 单会话 branch owner 在领域操作首个 await 前取得；defer 覆盖读取、persist、current 发布及相关 refresh。普通 save 外层 snapshot 计数覆盖加载到 current 发布，persist 内层计数覆盖持久化窗口，配对释放；二者虽嵌套但没有提前释放到零。竞争分支/快照失败使用已有可见错误并返回 false/nil，不排队重放旧 index。 |
| S2 PPTX numeric 顺序 | PASS | 仅将 trailingInt 读取目标改为删除扩展名后的 basename，slide1/2/10 按数值排序；未改 presentation.xml、ZIP、解析/预览格式。 |
| CRED-1 未提交模型返回成功 | PASS | updateProviderChatModels/upsertProviderChatModel/removeProviderChatModel 均 guard restoreSnapshot，失败 nil，成功只返回 snapshot 中已提交 provider。全部生产调用点均处理 nil，编辑器保留 draft，不执行默认模型切换等成功副作用。 |
| CRED-2 删除前丢凭据 | PASS | 移除旧的 model/catalog 提前删 Keychain；沿 restoreSnapshot 唯一事务先写 proposed 凭据，失败 rollback，成功提交 masked config/snapshot 后清 previous−proposed。旧凭据不再先于事务提交消失。 |
| KMP-1 refusal | PASS | Responses refusal.delta 复用 text delta；refusal.done 正确读取 refusal 字段但仍经原 normalizer 清除 final 重放。普通正文处理未改变；Chat Completions 新增非空 refusal Text，不覆盖 content。 |
| KMP-2 Gemini property 名 | PASS | 只在 properties 名称映射层保留 key，对 value 的 schema 继续原递归；unsupported keyword 集合未改，nested properties/items 仍清理 schema keyword。 |
| PHONE-1 dismiss scope | PASS | dismissKeyboard 与 home 复用相同 activeApp/checkScope；共用 beginOperation/checkCanContinue/最终发送检查。范围外在 keyboard POST 前拒绝；未增加 runner 协议、状态或授权。 |
| PHONE-2 type 后人工接管 | PASS | 自动 dismiss 前复查 Task cancellation 与现有 controller.canDispatchAction；typed text 的 completed receipt 保留，由既有 handoff 流进入暂停/新观察。正常 typing 仍 dismiss，不把已执行 type 改报未发送。 |

## 重点复核

**S1 状态窗口与恢复。** `IOSConversationBranching.swift:23-50` 的 branch set 与 snapshot count 仅表示当前读改写占用；所有成功和失败路径通过 defer 释放。`IOSConversationStore.save:594-659` 的外层 count 不随 persist 返回提前释放，所以 branch 无法在 save 的 current 发布前抢入；`persist:1291-1347` 内层 count 也不改变其外层占用。分支操作各自冻结 conversation ID，只有仍匹配 current 时发布，不写入后来切换的会话。

四个新增 concurrency 回归覆盖 branch→branch、save→branch、branch→save 的已 reservation 窗口，以及忙时 send 保留 draft；包含重启读取和占用结束后的重试。现有 cross-conversation/import/deletion/failure 测试仍保留。peer 复核也未发现失败路径遗留占用。

排除的假阳性：ViewModel branch 方法先创建 Task，store owner 要到 Task 运行时取得；合成同同步 turn 先 delete 再 send 可构造一个入口前窗口，但未找到当前生产调用链会在取得 owner 前连调两动作，不能把测试调度推演当 blocking。后台冲突同理：实际 branch UI 入口均 guard !isGenerationActive，该属性包含 active background generation；不能用 store 直调绕过生产门禁制造背景丢写。保存失败仍保留现有 recoveryPending 记录路径，不新增重试/锁框架。

**凭据错误传播与保留。** `ProviderDetailView` 模型保存、拉取后添加、删除、Antigravity seed 均停止成功副作用并展示现有 configurationSaveFailed；模型 sheet 接手 alert，父页只在无 modelDraft 时展示，避免同一错误两个 presenter。`ProviderDetailComponents:242` 仅在 onSave 返回 true 时 dismiss，失败保持编辑状态。`IOSProviderConfigToolService:398` replace_chat 失败返回结构化 fail。三个 mutation 的所有当前生产调用点均已核对，未找到漏接的 nil。新增测试使用随机 provider 范围的真实 Keychain 条目，注入写失败并从重启 store 校验旧 headers；成功删除控制校验余下模型重索引后的凭据。未把既有未改的其他 settings helper 顺带扩大为本阶段问题。

**KMP/Phone 测试有效性。** OpenAIRefusalGenerationTest 经真实 provider + MockEngine + accumulator，包含完整 refusal delta/done/output_item.done/completed、Codex generateText、Chat stream/non-stream，以及普通正文不重复控制；Gemini 新测试同时覆盖根、nested 与 items 中的 keyword 同名参数和 required，原清 keyword 行为仍有覆盖。Phone package 测范围外零 keyboard POST、允许应用正常发送；iOS handoff 测试实际挂起 type 回执后接手，再确认没有第二个 mutation，resume 后保留原 completed receipt，另有正常 typing 控制。

## 验证边界

已阅读 Root 的 phase1-red-summary.json：关键回归在修复前按预期失败，PPTX 后续仅把既有 flat preview 格式对齐，仍保留明确 1→2→10 内容顺序断言。已提供的 kmp-green-summary.json 记录 ai-provider-openai 81、shared 53 项均无失败；本 reviewer 未独立重跑。iOS green、Phone package 最终结果及 Shared/Swift 消费构建由 Root 统一提供，不用本次源码 review 代替。

真实 provider、模型编辑器人工 alert、物理设备权限/手机交互仍不由这些注入测试或 review 证明。KMP metadata/import IO 继续作为未测量验证候选，未混入八项修复。
