# Native cloud dialogue / asynchronous task loop delivery

基线 d752de94，本轮只修改cloud-daemon后端、受影响fixture与协议文档。既有8ed树中上轮未跟踪的审计报告保留，不混入实现提交。技能：implement、synara-task-skills；diagnosing-bugs复用既有审计并以实际Main HTTP旧入口404锁定接缝；完成后对本次diff做了一次code-simplifier有限检查，整理Worker续跑入口及公开进度/后台输出边界，无独立review或全量测试。

实现结果：

- 原生主消息由现配对Bearer鉴权，接收输入/用户时间线在原orchestration.db同事务提交后ACK，再交现有CloudRouterIngress/Router。Router计划持久化，重试/重启的派单身份稳定；同设备requestId跨消息/补充/stop幂等。
- 指定workItem补充走SQLite收件箱；Worker推理边界读入，模型请求成功后才标consumed。推理中有新输入则先消费再执行旧工具计划；正常结算与新输入接收共用数据库monitor，避免已经ACK的补充越过终态。若先被用户停止则未消费输入标cancelled，不冒充执行。Router steer亦复用此收件箱。
- process_run默认后台返回真实进程ID，完成、失败或停止输出投回原任务并唤醒Worker；无工具响应且后台仍活跃时挂起等待事件，不自动结算。process_wait被新输入提前打断。旧同步使用显式background=false，旧CSV验收fixture已明确设置。
- 新stop及旧cancel都先标记停止、取消Worker、清理实际任务进程，再写取消结算与通知；后续任务工具不能继续启动。取消后只读产物仍可下载。重启时只清理PID+进程开始时间匹配的已记录后台进程，并投中断事件，不自动重放旧命令。
- 增量主时间线以单调seq读取，包含接收、语义回答、补充消费、取消及终态结果；结果先落盘再走慢通知。后台原始stdout仅进模型收件箱，公开process_event为人话状态，UI应按任务更新同一行，不能逐工具画卡。
- 原生只有显式选中已配对云主对话才使用新API；没有改iOS/macOS UI、迁移本地聊天或变更配置/JWE端点。Router控制工具补结构化schema，取消/steer实际执行仍检查主人来源。

契约：`docs/architecture/cloud-dialogue-api.md`，Library `contracts/cloud-dialogue-api.md`。POST /v2/dialogue/messages；POST /v2/work-items/{id}/inputs、/stop；GET /v2/dialogue/receipts/{requestId}；GET /v2/dialogue/events?after=seq&limit=100。客户端保存cursor并按稳定id去重，received/consumed/cancelled分开呈现；task_result详情/产物继续原API。

验证：

1. 旧d752打包Main的POST /v2/dialogue/messages实际返回404，新实现无Bearer401；不是只看类名。最终复现命令：

   `python3 cloud-daemon/scripts/smoke-async-dialogue.py --jar cloud-daemon/build/libs/amberd-all.jar --java /opt/homebrew/opt/openjdk@21/bin/java`

2. 上述唯一端到端场景通过：实际Main HTTP、临时配对/数据、loopback OpenAI HTTP替身；OS Seatbelt内真实Python读取小CSV并启动长父/子进程A；A仍存活时B独立语义回答；指定A补充触发平均值2.5的真实重算；短后台进程完成事件实际被唤醒的Worker读取。接收另一次补充后，在模型仍未返回、receipt仍received时强杀daemon；重启同一data，补充恢复消费、同requestId重送不重复，workItem/session不变。旧进程树清理并投中断事件后，受控provider显式决定启动一个不同的续作调用（不是daemon自动重放旧命令）；stop实际停止新父/子进程。A的cancelled结果与B回答归各自topic及主时间线，产物仍可读，终态补充拒绝且终态不回滚。
3. 最终单次本机观测：A接收ACK 11.91ms，B接收ACK 6.16ms，B语义回答51.18ms，补充接收ACK 5.25ms，补充消费52.10ms，重启前补充ACK 5.37ms，stop HTTP45.61ms，实际父/子进程停止55.33ms。指标含本机轮询/ps开销，不是目标值、统计benchmark或真实provider/网络时延承诺。
4. 受影响检查：DialogueSettlementTest（ACK补充阻止旧结果结算、消费后才进终态、终态拒绝/重试/不回滚）、NativeTaskHttpTest（原生任务provider协议/重启幂等/鉴权取消/拒绝失败）、TaskToolsTest（文件隔离/真实退出/超时/子进程清理）、TaskRuntimeHttpTest（旧CSV产物与blocked语义）共8项通过；fatJar通过；Python语法与git diff --check通过。没有运行全部测试或旧P2.5测试套件，不以历史总绿作当前证据。

部署与回滚边界：

- Java21，原同用户、data/master/identity/tls/token/managed provider配置全部复用；443 TLS代理→127.0.0.1:47822不变。命令仍 `java -jar amberd-all.jar --host 127.0.0.1 --port 47822 --data-dir /EXISTING/DATA_DIR`，示例只供runtime审阅，本轮未执行生产部署。
- 在原SQLite增量创建dialogue_inputs/dialogue_events/dialogue_plans/task_processes四张表，无旧表破坏性迁移，无新真实凭据或依赖安装。SQL提交已覆盖daemon强杀重启，不承诺断电/磁盘损坏exactly-once，外部副作用未知时不自动重放旧进程。
- 回滚到d752前由runtime用本版stop明确停完本轮任务、保留数据库/WAL及原加密vault备份；旧jar忽略新增表且不提供新对话API，客户端应提示不可用而非回退成本地执行。不要删除表/会话/配对；回到8809等配置管理前版本仍须遵守原provider/baseURL与Key版本一致性约定。
- Linux线上隔离前置未改变：已知目标没有bwrap且用户namespace受限，不能据本机Seatbelt通过宣称Linux可执行；仍须runtime另轮安装/配置并实测，失败继续拒绝裸执行。本轮不动AppArmor、sudo、主机网络或全局Python。

未验收：腾讯部署、真实付费provider、真实IM、iOS/macOS接线与真机、线上Linux隔离/进程清理、断电恢复。本轮重点为原生入口；原IM入站仍有上轮审计所列的非持久Router输入队列/话题关联边界，未声称IM全部迁为此持久接收协议。同步HTTP/搜索/安装仍是受取消的工具调用，未将每一种工具都改为后台start；当前验证的真正异步执行是process后台路径。

下一步：由原iOS owner在显式云主对话模式接合同，保留本地聊天路径；以同一长A→问B→补充A→停止→结果归位场景做端侧验收。协调者再将此包交原runtime审阅部署/隔离前置，线上不会随本地提交自动更新。
