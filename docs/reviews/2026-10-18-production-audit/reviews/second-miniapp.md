# MiniApp 六项候选独立复核

2026-10-18。仅复核 audit-miniapp.md 给定六项；读取当前源码、消费者、构建声明，并用 Apple 官方框架文档与 DOM 标准确认语义。未改产品代码、未运行测试/构建，未扩大扫新问题。

## M1 大浮点转 Int trap — ACCEPTED / P1

复核 IOSMiniAppBridgeRuntime.swift:1027-1044，ai.generate:476-478、host context:494-496、sensor:594-600，及 MiniAppBridge.handle:137-168 的 JSONSerialization 入口。

`raw = Int(value)` 在 clamp 之前；有限且合法 JSON 数 `1e100` 无法被 Int 条件转换表示，但可作为 Double，随后强制 `Int(Double)` 超出范围是 trap，do/catch 不收 Swift precondition。参数解析早于真实 AI handler/传感器启动，不需真实 provider。require 权限确实位于解析前，故前提是已授权 MiniApp；这不消除合法入参能杀宿主的缺陷。

最小 owner：intParam 的 Double 路径先限定到最终 range 再转 Int；明确非有限值策略（可用默认值/现有错误接口），普通有限小数继续向零截断，保留既有 clamp 契约。无需重做 parser 或改设备 capability 的严格整数语义。以 JSONSerialization 的大数 fixture 覆盖正负越界、普通小数和 range 边界。

框架依据：[Swift Int 文档](https://developer.apple.com/documentation/swift/int) 区分浮点转换与可失败 exact 转换；本仓 IOSMiniAppDeviceCapabilities.integerParam:884-900 已在 Int 前做有效范围检查，可作实现参照。

## M2 图片代理 MutationObserver 自激 — ACCEPTED / P1

复核 MiniAppRunnerWebView.swift:150-163 的 externalImages 安装门禁与 bootstrap:749-763。

rewrite 对 src/srcset/style 无条件调用原生 setAttribute；observer 订阅这些 attributes，回调再次 rewrite 同 target。proxy 对已经代理值返回原值，不代表 setAttribute 没有原生 mutation；DOM 标准的 change attribute 算法没有“新旧相等则不排队”的分支。外链图片权限打开后，普通 img[src] 或任何 [style] 元素都会启动循环，甚至不需要网络成功。

最小 owner：rewrite 每个属性在 transformed != current 时才写回；STYLE textContent 同理无变化不写。不要关 observer、放宽 CSP 或添加重试。测试用真实 WK bootstrap + 有限回调保护，验证初始与动态 rewrite 后事件循环能继续；不用公网。

标准依据：[DOM Standard — attributes](https://dom.spec.whatwg.org/#concept-element-attributes-change) 定义 change attribute 必须处理 attribute changes、排 attributes mutation record；原算法不比较字符串是否不同。

## M3 Location 状态不区分能力范围 — ACCEPTED / P2（普通构建影响范围收窄）

复核 IOSSystemPermissionRequests.swift:240-288、IOSSystemPermissionCoordinator.staticStatus:347-348 / preflight:325-328，及 capability registry 的三个独立定位能力。

当前 mapCLAuthorizationStatus 对 whenInUse/always 都返回 authorized，且 static locationStatus 完全不读 accuracyAuthorization。ordinary Info.plist 169-172 只有 processing background mode，而 always capability 要求 location mode，所以**普通构建的 always 查询会先报 missingUsageDescription**，不能声称普通构建已误报 Always。temporary_precise 所需 plist dictionary 正常存在，普通构建 reduced accuracy 仍会被误报 authorized，这是已闭合的用户可见错误。experimental project.yml:486 才使 Always 范围错误可达。

最小 owner：locationStatus/requestLocation 的映射接收 capability ID、authorizationStatus、accuracyAuthorization。whenInUse 对两类合法位置授权均 authorized；always 对 whenInUse 为 limited；temporary precise 对 reduced 为 limited。denied/restricted/notDetermined 不变，不因部分授权虚构另一权限。读取 request 后的真实 accuracy 用同一映射，避免状态刷新前后打架。只需纯映射矩阵测试，不弹系统权限。

官方依据：[accuracyAuthorization](https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization) 定义 full/reduced 是独立授权维度；[Core Location 授权说明](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services) 区分 When in Use 与 Always，并说明 whenInUse 在开启持续定位时也能维持前台启动的后台服务，故不要把所有 whenInUse 描述成完全不能后台。

## M4 Calendar writeOnly 被 full 能力标 authorized — ACCEPTED / P2

复核 IOSSystemPermissionRequests.swift:eventKitStatus:431-432、mapEventKitStatus:462-467，registry full:472-488 / write_only:491-504。二者明确是不同能力。当前 enum 合并为 authorized，使仅写入时 calendar.full 的 UI/permissions_status 显示全允许；实际数据工具仍受 EventKit 系统权限约束，不是越权。

最小 owner：EventKit mapper 只在 full capability + writeOnly status 时返回 limited；write_only+writeOnly 与 fullAccess 既有合法组合继续 authorized。保留其余状态。纯状态矩阵足够，别抽象整个 framework。

官方依据：[EKAuthorizationStatus](https://developer.apple.com/documentation/eventkit/ekauthorizationstatus) 明确 fullAccess 含读取和写入，writeOnly 仅写入；[authorized 弃用说明](https://developer.apple.com/documentation/eventkit/ekauthorizationstatus/authorized) 要求按所需访问级别检查。

## M5 联系人请求后 limited 被 Bool 提升为 authorized — ACCEPTED / P2

复核 requestContacts:405-406、mapContactStatus:416-423、coordinator request 末尾结果缓存:294，以及 ToolPermissionsView:368-378。

请求成功 Bool 仅表明允许访问，不能区分部分/全量；iOS18 用户可在请求流选 limited。当前把 success true 写入 authorized 并缓存；同文件静态查询却已正确识别 limited，所以此行为不是产品故意合并，且手动 refresh 会改变显示。

最小 owner：requestAccess 完成后从 CNContactStore.authorizationStatus(.contacts) 读真实状态，用已有 mapContactStatus 生成 result。无需新增权限流程；现有通知请求后重读模式可参照。若加 seam，限 contacts request/status 两点，不泛化所有 framework。

官方依据：[Accessing the contact store](https://developer.apple.com/documentation/contacts/accessing-the-contact-store) 说明请求时可授 limited/full，分别得到 limited/authorized；[requestAccess](https://developer.apple.com/documentation/contacts/cncontactstore/requestaccess(for:completionhandler:)) 的 Bool 是“允许访问”，并无代表 full 的语义。

## M6 文档失去 trust 后 sensor subscriptions 未释放 — ACCEPTED / P2

复核 MiniAppBridge.setTrustedMainDocument:76-81、runtime.close/cancelPendingRequests:643-660、MiniAppRunnerWebView:599 / :646-667，以及实际 owner MiniApp/MiniAppSystemBridge.swift:54-149。

合法订阅完成后已不属于 inFlightTasks；导航 about/data/blob 时桥清 generation map、cancelPendingRequests，但不移除 runtime sensorSubscriptionIds，也不调 sensorUnsubscribeHandler。deviceCapabilities.suspend 是另一个 owner，不包含 IOSMiniAppSystemBridge 的 CoreMotion。真实 CoreMotion manager 的 updates 在 .main 分发，直到 unsubscribe 或 Runner.close 才 stop，因此形成可达的后台资源占用。generation gate 会丢旧事件，所以不是给新文档泄漏传感器数据。

最小 owner：runtime 增加/提取“撤销当前文档订阅”小方法，在 true→false trust 转换时调用，清 event bus 与 sensor IDs、cancel pending，但不永久 isClosed。close 复用清理保证幂等。测试成功订阅后撤销 trust，unsubscribe一次；迟到事件继续被拒，close不二次unsubscribe，重新加载可信文档仍可发新请求。

## 收口

六项均 ACCEPTED；M3 的 Always 只在 experimental location build 可达，普通构建必须以 temporary_precise 的错误为核心。各项只修改参数转换、DOM写入、权限映射/请求结果、文档订阅 owner，不增加权限、通用兜底或资源状态机。以上仍是源代码与官方语义复核，Root需用限定 seam 建立失败证据后实施；无真机、TCC或CoreMotion验收结论。
