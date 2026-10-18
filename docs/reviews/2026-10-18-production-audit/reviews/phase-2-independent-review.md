# Phase 2 独立 review

结论：**PASS，无已确认 blocking findings。** 本 reviewer 未参与本阶段实现，只读最终生产代码、三个新测试、audit-miniapp.md / second-miniapp.md 及 Root 提供的失败证据；未改源码、未运行测试或构建。DOM observer 幂等性另请未参与本阶段实现的 audit_kmp 做窄范围只读 peer，结论同为 PASS，证据见 phase2-miniapp-image-peer.md。完整 green 由 Root 补齐后收口。

范围限定为数值转换、图片代理 observer、Location scope/precision、Calendar scope、Contacts 请求后状态、文档订阅生命周期六项。保留既有模块化 WIP；未把并行 visual tests 删除、无关权限或旧网络兼容限制归入本阶段。

## 逐项判断

| 项目 | 判断 | 最终实现与证据 |
|---|---|---|
| MINI-1 大浮点 Int trap | PASS | intParam Double 路径先 isFinite，再限制到调用方业务小范围，最后才 Int；普通有限小数向零截断，最终 default/clamp 语义保留。当前三个范围最大 60000，Double 上界转 Int 安全。 |
| MINI-2 图片代理 observer 自激 | PASS | src/srcset/style 仅在变换后字符串变化时写回，STYLE textContent 同理；srcset 每个 candidate 先 trim，已代理候选重组稳定，1x/2x suffix 保留。原 CSP、权限安装门禁和代理 transport 不变。 |
| MINI-3 Location scope/precision | PASS | locationStatus 使用具体 capability ID、当前授权和 accuracy；Always + whenInUse 为 limited，temporary precise + reduced 为 limited，普通 whenInUse + reduced 仍 authorized。requestLocation 完成后复用同一实际状态入口；既有 preflight 未放宽。 |
| MINI-4 Calendar scope | PASS | 仅 full capability + writeOnly 从 authorized 改为 limited；write_only + writeOnly、fullAccess 和其余状态保留原含义。 |
| MINI-5 Contacts limited 缓存 | PASS | requestContacts await 请求后从 contactsAuthorizationStatus 读取实际 CNAuthorizationStatus，经既有 mapper 返回；coordinator.request 缓存该 result，未再用成功 Bool 提升为 full。 |
| MINI-6 文档失去 trust 后订阅清理 | PASS | true→false trust 时提升 generation、清 bridge 订阅归属并调用 runtime.invalidateDocument；它取消 pending、释放 EventBus/sensor IDs，但不永久 isClosed。close 复用同一路径，已清订阅不重复释放，新可信文档可继续订阅。 |

## 调用链与边界核对

**数值。** `MiniAppBridge.handle` 仍通过 JSONSerialization 接入 params，真实 dispatch 的 ai.generate、host.getConversationContext、sensor.subscribe 分别消费 1...16000、200...8000、250...60000 范围。`IOSMiniAppBridgeRuntime.swift:1043` 在转换前完成有限值/范围处理；非有限值走既有 default 后最终 clamp。没有把 device capability 的严格整数协议改成宽松转换，也没有新增统一 parser。`IOSMiniAppNumericParametersTests` 由 JSON 数字进入三个正式 dispatch，覆盖正负 1e100、越 Int 边界、普通有限小数、负值、零及常规上界，检查实际 handler 收到的业务值，不只测 helper。

**DOM 幂等与 descriptor。** `MiniAppRunnerWebView.swift:725-775` 的 proxy 对 amber-miniapp-image scheme 返回原值；proxyCSS 仅匹配 https url，改成代理 scheme 后不再变化。rewriteAttribute 比较 transformed/current，STYLE 比较新旧文本。srcset 非匹配候选现在也 trim，因而代理后候选的 `join(', ')` 在下一轮稳定；匹配候选原 descriptor suffix 保留。没有引入新的 srcset parser、断开生产 observer、放宽 CSP 或轮次上限。

真实 WK 测试在 documentStart 安装正式 bootstrap、使用 dummy scheme handler，初始及动态 DOM 变更后均检查事件循环能到达 snapshot。保护仅在测试注入中 >32 callbacks 或 >64 records 后断开，两个 snapshot 都严格断言 guarded=false 和 callbacks<32，因此保护被触发不能伪装通过；初始 1x/2x 与动态 src/srcset/style URL 仍有具体行为断言。Root 报告旧实现 709 微任务采样以及 first fix 仍 guarded 的历史，符合原循环和 srcset 空格自增根因；没有把这些历史失败算成当前 green。

**trust 与资源 owner。** `MiniAppBridge.swift:76-84` 只在原可信文档失去信任时清理 runtime。`IOSMiniAppBridgeRuntime.swift:643-668` 的 close 先设置 isClosed，再复用 invalidateDocument；文档 invalidation 本身不设置 isClosed，符合 Runner 重用契约。已经完成的 sensor 不再依赖 inFlightTasks 才能清理，底层 unsubscribe handler 会实际调用；尚在确认的 sensor 请求被 cancel，confirmSensitive 在 await 后的 Task.checkCancellation 保留，不能在 trust loss 后迟到再创建订阅。桥的 generation 检查继续丢弃旧 response/event。测试验证 unsubscribe 各一次、旧 EventBus ID 无效、新可信文档可订阅、重复 close 幂等；未声称用注入 handler 验证 CoreMotion 真机耗电。

**权限 scope 与缓存。** 静态 status 仍先执行 preflight，普通构建缺 location background mode 时 Always 仍被预检挡住，本阶段不将普通构建影响扩大到 Always；普通构建真实修复范围是 temporary_precise 的 reduced accuracy。experimental 可进入 Always 范围映射。Calendar 继续区分 full/write_only 两个 catalog 能力。Contacts 的两个注入点默认分别调用真实 requestAccess 和静态 authorizationStatus，范围仅 Contacts；request 的结果仍由统一 coordinator 在 `results[capability.id]` 发布。新测试通过公开 coordinator.request，断言请求结束后才读状态一次，limited/full 结果与 cachedStatus 一致，不是只测试 mapper。

## 验证边界

已读取本阶段 Root 的 red/sensor/Contacts summary；实际证明与具体变化一致。数值旧 trap→新限界、旧 scope 矩阵、真实 WK 循环以及 final green 的执行归 Root，本 reviewer 没有另启测试进程。完整 green 尚待 Root 最终补入。

不把纯状态矩阵当作弹系统权限验收，不把真实 WK fixture 当成真实外链网络服务验收，不把注入 sensor handler 当成物理传感器或设备功耗验收。六项修复没有增加权限、重试器、永久关闭状态或通用兜底框架。
