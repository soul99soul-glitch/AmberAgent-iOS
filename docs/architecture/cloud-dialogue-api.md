# Cloud dialogue v1 — native 接线契约

基线 d752de94；本轮本地实现及受控Main HTTP验收已通过，生产与客户端尚未接线验收。仅用户显式选定“已配对云主对话”后使用，不迁移/替换本地聊天。所有请求沿现有 HTTPS/SPKI + paired device Bearer，配置/JWE API不变。

| Route | Body / 返回 |
|---|---|
| `POST /v2/dialogue/messages` | `{ "requestId":"UUID", "text":"…" }`；新消息交现有Router。服务端分配稳定topicId，任务派发关联该topic。 |
| `POST /v2/work-items/{id}/inputs` | `{ "requestId":"UUID", "text":"补充…" }`；仅给指定未终态任务补充，复用workItem/session，不新建任务。 |
| `POST /v2/work-items/{id}/stop` | `{ "requestId":"UUID" }`；独立控制路径，先取消/清理实际进程，再结算与慢通知。旧cancel接口保留。 |
| `GET /v2/dialogue/receipts/{requestId}` | 获取当前设备该requestId的接收/消费状态与关联任务。 |
| `GET /v2/dialogue/events?after=0&limit=100` | 增量主时间线：`{"items":[…],"nextCursor":42}`，seq单调递增；after为上次nextCursor，空页不推进；limit 1..100。客户端可每秒轮询；本轮不要求SSE。 |

接收回执：`{"eventId":"UUID","requestId":"UUID","topicId":"UUID","workItemIds":[],"state":"received","replayed":false}`。主消息/补充首次202、同请求重试200；stop在实际清理后200。state为received、consumed或cancelled：补充只有被Worker本轮模型请求成功消费后才变consumed；若用户先停止任务则未消费补充标cancelled，不能显示成已执行。ACK不是语义回复/成功。派单后GET receipt可取得workItemIds。

时间线item：`{"seq":1,"id":"稳定事件ID","kind":"user_message","role":"user","text":"…","topicId":"UUID","workItemId":null,"outcome":null}`。kind包括user_message、followup、stop_requested、assistant_reply、input_consumed、input_cancelled、process_event、task_result。task_result含workItemId及completed/blocked/failed/cancelled outcome；完整结果/产物继续用现有work-item detail/artifact API。process_event只返回人话状态，原始stdout/参数保留后台，不出现在公开时间线。UI按任务更新同一进度区域，不把process_event或工具轨迹逐条画成卡片。GET events是增量传输日志，展示可按kind归并；输入的received/consumed/cancelled必须区分。

requestId在设备内跨上述写入口唯一；相同动作/目标/文本重试复用原eventId/topicId，不重复派单或补充；不同语义返回409 request_id_conflict。无Bearer401；任务不存在404；首次补充终态任务409 task_terminal（已经接收的同请求仍可查询/重试）；无效参数400。requestId限制[A-Za-z0-9._:-]、1..128，text 1..24000。设备身份由Bearer决定，不接受客户端伪造sender/agent权限。

后端先将输入和用户时间线原子写现有SQLite，再快速回执，语义回复后续增量获取。Router规划与派单使用持久结果幂等；补充在推理边界消费，未消费输入阻止正常结算。实际后台进程完成/失败/停止会投回原任务并唤醒；重启保留未消费输入、任务与结果，不自动重放结果不明的旧进程命令。结果先落主时间线，再通知。

原生最窄接缝：沿现有配对连接新增上述方法；云主对话发送用messages；收到workItemIds后补充/停止明确指向该任务；本地会话继续旧生成器。以seq保存同步位置，按稳定id去重，主消息ACK、语义回复和任务完成分别呈现。真实环境部署/真机接线不在本轮验收范围。

## 2026-11-05 回执与失败可见性修复

- 原生消息写入主对话后、调用 Router 模型前，持久化一条 `assistant_reply` 自然回执，稳定 ID 为 `ack:<inputId>`。它只表示已经接手，不表示完成；相同 requestId 重放不重复回复或派活。
- 每条原生消息独立运行 Router 决策，旧模型请求不会阻塞后续消息；各回合只读取截至自身用户消息的历史。回复仍以各自 topicId 关联，seq 按实际落盘顺序递增。
- 原生任务结算将同一个稳定 `result:<workItemId>` 同时写入主对话历史和 `task_result` 事件，保留 outcome。后续主对话可直接读到结果和失败原因，不再另跑一轮只有文档路径的模型汇总，也不会因完成事件而自行重派。
- 云端模型客户端显式设置连接 15 秒、请求总时长及 socket 空闲 180 秒。仅超时重试一次，间隔 500ms；取消及其他异常不重试。重试发生在模型返回之前，已经执行的工具不会随之重放。策略仅注入 JVM 云端客户端，Darwin/Swift 默认入口不变。
- 模型超时耗尽后，用户看到“模型接口响应超时，已自动重试 1 次仍未成功……可以再试一次”等说明；原始异常保留在 `worker_execution_failed` / `router_model_failed` 等持久诊断事件中，不直接进入失败卡片。
