# 第 2 阶段：完成

MINI-1–6 六项已修复。完整 MiniApp/permission 相关套件 86 项全部通过，零失败、零跳过、零 runtime warning；[独立 review](reviews/phase-2-independent-review.md) 与 [DOM peer](reviews/phase2-miniapp-image-peer.md) 均 PASS。

- 数值：受控 Swift 子进程沿生产函数执行合法大 JSON number，旧实现 trap；修复后 7 个边界与小数控制通过，正式 bridge dispatch 测试也通过。
- DOM：旧真实 WK 运行持续高 CPU，采样 709 次进入 MutationObserver 微任务/setAttribute，Root 受控停止本轮。初次按值比较仍触发测试 guard；定位 srcset 透传候选 join 时每次增长空格。候选 canonical trim 后，真实 WK 初始/动态 src/srcset/style/STYLE、1x/2x 均通过，guard 未触发。未延长超时或放宽断言。
- 文档资源：sensor 红测先失败；信任撤销后释放 sensor/eventBus，随后新文档仍可订阅、close 幂等均通过。
- 权限：Location/EventKit 原 mapper 受控矩阵先复现 scope 错误，再跑真实 SDK enum 的 iOS 单测；Contacts 保持旧 Bool 行为直到请求回读测试实际失败，才改为读取真实 authorization status 并缓存。

一次 Contacts red 构建因提前准备的 Chat 测试把 LocalDateTime 用在 Reasoning 的 KotlinInstant 字段而零用例失败。只修测试实际类型后，r2 的 Contacts 与 DOM 真实失败单独保留。权限 macOS harness 首次因 WhenInUse 不可用而编译失败，未当作产品缺陷；后续 source-mapper surrogate 与真实 SDK enum iOS 测试分开记录。

真实 TCC 操作、定位精度、CoreMotion 硬件与真机交互未由上述模拟器/注入证据替代。
