# amberd 派活回执、模型超时与失败可见性

## 交付范围与边界

工作区 `/Users/arquiel/.synara/worktrees/31066dc083d0`，源码基线 `ecff3e3c7685c28eb73c49bbfc2adfcf141660ee`。仅修改本仓云端及两个 provider 的 JVM 工厂，不修改 iOS。线上只读调查，无重启、配置修改或部署；真实 DeepSeek 请求与手机验收留待用户授权部署后进行。

## 当前线上证据

- 主机 `49.233.86.10`，进程 PID `1283126`，启动于 2026-11-04 08:45:05 +08:00。
- 运行入口：`app.amber.cloud.MainKt`，监听 `127.0.0.1:47822`。
- JAR：`/home/ubuntu/amber-cli-trial-20261101-a84a2ed9/releases/amberd-async-33797c6c/amberd-all.jar`。
- JAR SHA256：`e273026cd557f42f2f78737993ee60071c0fcb3e388f503cfafe8e4fed2154c5`。
- JAR 未嵌入 Git SHA。已将线上 JAR 与基线本地编译结果比较：`NativeDialogueService`、`KmpProviderModelClient`、`CloudRouter`、`OrchestrationRollupCoordinator`、`CloudSoulStore` 五个关键类逐字节一致，不能仅凭发布目录名判断版本。
- 日志：`pairing-run/async-33797c6c.log`；无 SLF4J provider，输出仅启动记录。时间线来自以只读模式打开的 `data/orchestration.db` 及会话 JSON，没有读取凭据库内容。

所有下述时间均为 2026-11-05，Asia/Shanghai。服务端 `source_messages.created_at_ms` 记录入站路由时间；主对话 JSON 的 createdAt 为本地时间。

| 用户消息 / 事件 | 服务端时间 | 真实行为与证据 |
|---|---|---|
| 你的服务器里有 ai memory 的数据吧 | 21:39:11.123 | 增量事件 seq 18；主对话 21:39:13.233 写出回复，seq 19。 |
| 你现在去查一查 | 21:39:22.501 | seq 20；持久计划 `dialogue-plan:trig:native:f7a20494-54b0-44f4-a194-fe920b827664` 的 reply=null、dispatch=ai_memory_probe。 |
| 首次后台任务启动 | 21:39:25.655 | `work:f01468c81fb44f38af38f3b5` 入队并启动；没有该派活回合的 assistant_reply。 |
| 怎么不理我 | 21:40:23.411 | seq 32；21:40:24.649 产出“活已经派出去了”回复，seq 33。 |
| 首任务失败 | 21:42:35.305 | worker_settled=FAILED，failureReason 为 `Socket timeout has expired [url=https://api.deepseek.com/chat/completions, socket_timeout=unknown] ms`；结算回调写入 task_result seq 53。 |
| 首任务汇总回合 | 21:42:39.839 | 主历史出现“详情俺翻不开”回复；task_result 正文未写入主历史，汇总输入仅数量与文档路径。此汇总回合没有对应的原生 assistant_reply。 |
| 咋了 | 22:01:09.976 | seq 54；22:01:11.843 回复“详情俺翻不开”，seq 55。 |
| 再派一次 | 22:01:23.436 | seq 56；持久计划 `dialogue-plan:trig:native:974b2acb-42c2-4762-83d5-59442bcfc4c0` 的 reply=null、dispatch=scan_ai_memory。 |
| 重派任务启动 | 22:01:25.400 | `work:cd80d37e5b29dad9df7f7d17` 启动；同样没有派活回合的 assistant_reply。 |
| 重派任务完成 | 22:03:40.342 | worker_settled=COMPLETED，task_result seq 76，正文含实际扫描结论。 |
| 重派任务汇总回合 | 22:03:42.593 | 主历史反而出现“只有主人本人可以安排新任务”：完成事件触发模型再次提出派活，但事件没有新用户授权。 |

`dialogue_events` 旧表没有事件时间字段；上表没有将 seq 当时间使用。线上 Caddy 无访问日志，数据库也未记录 GET events 的拉取游标，因此无法还原手机何时请求或取走 seq 53/76，不能认定客户端未拉取。可确认两次用户消息均已进入服务端并实际派活。

## 根因与修复

1. `CloudRouterIngress` 使用 postAck=false，预期连接器发送返回的即时回执；`NativeDialogueService.enqueue` 丢弃了这个返回值。模型仅返回 dispatch_work 时 reply=null，后续也没有补回复。现在原生入口在启动模型前将稳定 ID 的自然回执写入主历史与事件流。
2. Router 的 drain 循环串行等待模型，后续原生消息只能排队。现在独立调度原生回合，保留各自的计划与 requestId 幂等边界；上下文裁到自身用户消息，避免旧回合读到较新的请求。
3. 旧云端 KMP 客户端创建默认 HttpClient，没有安装 HttpTimeout。日志中的 unknown 与此一致，不能由 unknown 单独推出服务器故障或网络中断。现在仅云端 JVM 注入显式超时客户端：连接 15s，请求/socket 180s；超时最多两次尝试、间隔 500ms。取消不重试，工具不随模型重试重放。Ktor 对三种超时的定义见[官方文档](https://ktor.io/docs/client-timeout.html)。
4. task_result 仅写事件流，主模型看不到正文；另一次汇总只给文档引用，且可能诱发无授权重派。现在结算正文幂等写回主历史，直接保留 task_result 的 outcome 并主动送入事件流，原生任务不再追加猜测性的模型汇总。已有任务召回摘要也包含 outcome 与 failureReason。
5. 默认 Worker 异常直接成为公开 summary。现在错误先经 CredentialRedactor 写持久诊断，公开结果使用明确的人话失败说明；超时失败说明包含已经重试的次数。

## 验证记录

没有运行全量测试，也没有启动真实付费模型请求。复用的定点检查覆盖以下行为：

- `NativeDialogueReliabilityTest`：先在旧代码复现三个失败；修复后通过。新增配对 HTTP 路径同时验证派活前回执、Worker 等待时独立问题仍获得答复、失败自动出现且不暴露原始异常、下一轮读到失败原因、再次派活成功与完成事件。
- `CloudModelRequestsTest`：真实本地 HTTP 响应延迟 10.5 秒仍一次成功；socket 超时后仅重试一次；请求超时耗尽后有安全失败说明；取消不重试。
- `DialogueSettlementTest`：未消费输入仍阻止普通终态结算。
- `NativeTaskHttpTest`：OpenAI/Claude 原有配对任务、幂等重放、持久结果与取消路径。
- `CloudRouterIngressTest`：IM 先回执、隔离 Worker、共享历史恢复。其旧夹具仅返回“检查完成”却期待 COMPLETED，用线上原 JAR 运行也同样失败；已改为调用现有 task_finish 协议，保留原有效断言。
- `CloudOrchestrationInteractionAndInspectionTest` 中 grok_bot 与 two_layer 两个定点方法：IM 状态更新与任务诊断/召回。

组合检查共 17 项，其中 16 项通过；唯一失败来自新增 HTTP 夹具遗漏 active_tasks 上下文前缀。修正夹具匹配后，仅复跑 `NativeDialogueReliabilityTest`，四项全部通过，其余已通过结果复用。由这两次结果覆盖的上述检查均通过，未再次整组重跑。

构建 `:cloud-daemon:fatJar` 成功；产物中的全部 820 个 daemon 类均与本轮编译输出一致，两个新增 JVM 工厂也已进入产物。`git diff --check` 通过。维护性检查限定本轮 diff，核对了独立回合的归属、取消透传、稳定事件去重与结算回调不在 SQLite monitor 内挂起，没有追加重构。

原始定点日志位于本工作区 `cloud-daemon/build/evidence/`：

- `dialogue-before.log`：旧代码三个回归失败。
- `ingress-baseline-failure.log`：旧线上 JAR 下旧夹具同样失败。
- `affected-checks.log`：组合检查，16 项通过与单一 HTTP 夹具失败。
- `native-dialogue-final.log`：修正后四项通过。
- `artifact-class-check.json`：产物与编译输出一致性核对。

## 待部署产物与后续闸门

JAR：`cloud-daemon/build/libs/amberd-all.jar`。

SHA256：`950df0ac9a5476ce688b729303043c358318d16e7577993035b08e375b926583`。

部署需要协调者转达用户授权。授权后须保留当前 JAR、现有数据与启动方式以便回滚，保持配对、vault、模型配置和隔离策略；再做真实派活即时回执、长请求、成功/失败主动反馈与下一轮可读结果的验收。当前证据只证明本地受控路径与构建产物，未证明生产 DeepSeek 或 iPhone 已接受修复。
