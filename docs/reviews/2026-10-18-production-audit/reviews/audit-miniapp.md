# MiniApp / System Permissions 只读审查

范围：当前工作树的 MiniAppBridge / IOSMiniAppBridgeRuntime / MiniAppRunnerWebView / MiniAppRunnerView / MiniAppHostConfirmation / IOSMiniAppSystemBridge / IOSMiniAppRepository / IOSSystemPermissionCoordinator / IOSSystemPermissionRequests / IOSPermissionPolicyStore 及相关测试。已读 iosApp/AGENTS.md。没有修改生产文件、没有运行构建或测试，没有读取其他产品仓库。以下是代码路径二次复核；尚不能称为运行时复现。

## 1. P1 — MiniApp 的大浮点整数参数会触发 Swift trap，退出整个 App

- Owner：iosApp/iosApp/IOSMiniAppBridgeRuntime.swift:1037-1038（intParam），最终 clamp 在 1044，来不及保护转换。
- 可达链：生成 JS 调用 Amber.ai.generate({prompt:'x',maxOutputChars:1e100}) → bootstrap JSON.stringify → MiniAppBridge.handle 的 JSONSerialization → dispatchOpen ai.generate:476-478 → aiGenerateRequest:1000 → intParam → Int(1e100) trap。host.getConversationContext maxChars（494-496）和 sensor.subscribe intervalMs（594-600）同样受影响。前提为相应 MiniApp 权限与设置允许；无需调用真实 provider/系统传感器，解析发生在 handler 之前。
- 真实影响：合法 JSON 可表达的大数能从 WKWebContent 进入主 App 进程，直接终止宿主；不只是 Promise 失败。Swift 的 Int(Double) 对越界、非有限值转换属于 runtime trap，do/catch 无法捕获。
- 反证复核：并非 clamp 已覆盖；它在转换之后。device capability 独立的 integerParam（IOSMiniAppDeviceCapabilities.swift:884-900）在 Int 转换前已经验证有限值、整数性、范围，所以不受这个问题影响，也提供本仓惯例。
- 最小修复：仅修 intParam 的 Double 路径，在转换前按最终的小范围做有限值与范围处理，保留现有普通值 clamp / 小数截断契约；不要新增重试或统一解析框架。
- Test seam：IOSMiniAppBridgeRuntimeTests；通过 JSONSerialization 解析 {maxOutputChars:1e100} / -1e100 / 边界 Int.max 转 Double，dispatch 到注入 ai/host/sensor handler，验证错误或已限制值与无崩溃；无需 provider 或设备。重点至少正负越界和现有有限小数行为。

## 2. P1 — 外链图片代理的 MutationObserver 会因自己的属性写入持续循环

- Owner：iosApp/iosApp/MiniAppRunnerWebView.swift:749-763，尤其 751-754。
- 可达链：MiniApp 声明 externalImages 并获得允许 → makeUIView:150-163 安装 IOSMiniAppImageSchemeHandler.bootstrapScript → 普通 <img src='https://example.com/a.png'> 或 <div style='color:red'> 插入/DOMContentLoaded → rewrite → originalSetAttribute → observer attributes record → rewrite 同一元素 → 再次 setAttribute 相同值。
- 真实影响：setAttribute 即使新旧值相同也排入 DOM 属性 mutation；代理 URL 首次改写之后每轮仍无条件重写，形成持续 microtask 循环，网页无法正常处理后续交互/渲染。任意 style 属性也触发，无需实际图片请求成功。网络代理上限不解决 DOM 自激。
- 反证复核：proxy 对已有 amber-miniapp-image URL 返回原值，但 rewrite 没有比较；observer 明确订阅 src/srcset/style，且使用原始 setAttribute 绕过 shim 也依然产生原生 DOM mutation。现有 testRunnerCSPOnlyAllowsProxiedImagesWhenExternalImagesIsEnabled 只验证 CSP 与脚本字符串含 encodeURIComponent，不执行观察器，因此没有覆盖。
- 最小修复：属性值只有发生变化时才 originalSetAttribute；同样避免 STYLE textContent 无变化重写，保持 proxy 行为和 CSP 不变。
- Test seam：补 IOSMiniAppBridgeRuntimeTests 的真实 WKWebView + bootstrapScript。建议测试里包装 MutationObserver，记录回调数并设有限回调保护，避免旧实现让整个测试挂死；断言正常 DOMContentLoaded 后事件循环可继续、src/srcset/style 只改写必要次数、动态后续属性更新仍成功。可用 dummy scheme handler，无需公网。

## 3. P2 — Location 权限状态丢失 Always / 精确度能力范围，向真实 permission_status 报假授权

- Owner：iosApp/iosApp/Infrastructure/Permissions/IOSSystemPermissionRequests.swift:240-244、283-288；调用 owner IOSSystemPermissionCoordinator.swift:347-348 将 ios.location.when_in_use / always / temporary_precise 全部路由到同一个映射。
- 可达链：用户仅允许使用时定位并关闭精确位置 → IOSLocalToolExecutor.permissionsStatus:698-717 → cachedStatus → staticStatus → locationStatus。when-in-use 映射为 authorized 后，被同时用于“始终定位”和“临时精确定位”。Info.plist 声明包括 Always usage 与 temporary dictionary，临时精确定位在普通构建可达。二次核对发现普通 Info.plist 的 background mode 只有 processing，所以 Always 会先被 preflight 标 missingUsageDescription；Always 的错误映射仅在 project.yml:486 配置 location mode 的 experimental build 或直接调用 locationStatus 时可达，不应把它说成普通构建已误报。
- 真实影响边界：普通构建的模型权限状态快照会说 precise 已授权，实际只有大致定位；experimental build 还会误报 Always。这是可见诊断契约错误；不能据此声称绕过系统位置权限或已证实后台位置丢失。当前简化权限 UI 只显示 when-in-use，因此主要影响 permissions_status 与协调器消费者。
- 反证复核：catalog 将三个能力独立声明（IOSCapabilityRegistry.swift:252-294）；requestTemporaryPreciseLocation:268-273 也明确用 accuracyAuthorization 区分 .authorized/.limited，证明把 reduced accuracy 的 static snapshot 标 authorized 不符合本仓现有契约。
- 最小修复：映射接受 capability.id、authorizationStatus 和 accuracyAuthorization；Always 在 authorizedWhenInUse 时返回 limited，temporary precise 在 reducedAccuracy 时 limited，保留 denied/restricted/notDetermined。requestLocation 返回也使用同一能力范围映射。
- Test seam：把映射保留在 coordinator 内作为可测试纯函数；IOSSystemPermissionCoordinatorTests 传入 when-in-use/always × full/reduced 的小矩阵，另验证 temporary request 结果与 refresh 结果一致。无需弹 TCC。

## 4. P2 — 日历只有写入授权时，“日历完全访问”仍报 Authorized

- Owner：iosApp/iosApp/Infrastructure/Permissions/IOSSystemPermissionRequests.swift:431-432、462-467。
- 可达链：用户只授予 EventKit writeOnly → 权限页面刷新（ToolPermissionsView 的 ios.calendar.full）或 permissions_status → eventKitStatus(.event) → mapEventKitStatus(.writeOnly) → authorized。
- 真实影响边界：UI 的“日历”项显示“已允许”，agent 快照把 full-read/update/delete 能力声明的系统状态标成 Authorized，用户仍没有读取日历权限。实际 Apple 数据工具仍应另行检查系统权限，本报告不声称数据越权。
- 反证复核：catalog 明确把 calendar.full（472-488）与 calendar.write_only（491-504）分为不同能力；同一 .writeOnly 对 write_only 是 authorized，对 full 必须 limited。不是 intentionally merged catalog。
- 最小修复：eventKitStatus 的映射使用 capability.id，只对 full+writeOnly 返回 limited；保持 fullAccess 对两个能力均 authorized。
- Test seam：IOSSystemPermissionCoordinatorTests 对 full/write_only 能力分别映射 .writeOnly 和 .fullAccess，不需真实日历。

## 5. P2 — 有限联系人授权在请求完成后被覆盖为全授权

- Owner：iosApp/iosApp/Infrastructure/Permissions/IOSSystemPermissionRequests.swift:405-406。
- 可达链：ToolPermissionsView → requestContacts → iOS 18+ 用户选择有限联系人 → requestAccess 返回成功 Bool → result authorized → coordinator.results[capability.id] 缓存该值 → ToolPermissionsView:368-378 显示“已允许”而非“部分允许”；permissions_status 也读取该缓存。
- 反证复核：同文件 mapContactStatus:416-423 已正确支持 limited，因此不是项目不区分。请求路径扔掉真实授权枚举是唯一偏差；下次手动 refresh 又会修正，说明这是请求完成时可观察的错误而非永久存储问题。
- 最小修复：requestAccess 结束后读 CNContactStore.authorizationStatus 并使用 mapContactStatus，类似 requestNotifications 已有“请求后重新读真实状态”的做法。不要因 Bool 成功就提升为 full。
- Test seam：纯状态映射已有 seam；若要覆盖 request 路径，可只增加 contacts request/status 注入 seam，或在测试模拟系统 limited 状态后检查实际 request result。避免为整个协调器抽象一套所有 framework。

## 6. P2 — 文档失去 bridge trust 后已有传感器订阅继续运行

- Owner：iosApp/iosApp/MiniAppBridge.swift:76-81；IOSMiniAppBridgeRuntime.swift:657-660；资源的正常 teardown 只在 close:643-654。
- 可达链：sensor.subscribe 成功 → CoreMotion manager 启动 → 小应用 window.location 导航到 about:blank/data/blob（MiniAppRunnerWebView:646-667 允许导航但置 trusted=false）→ bridge 只清理 generation 和取消 in-flight task → 已完成请求的 sensorSubscriptionIds 仍保留，sensorUnsubscribeHandler 从未调用。
- 真实影响边界：旧文档的传感器事件确实会被 generation gate 丢弃，避免新页面收到旧事件；但 CoreMotion 仍保持活动并持续唤醒主线程，直到关闭整个 Runner。不是数据泄漏，是可触发的资源生命周期错误。
- 反证复核：Coordinator:599 的 suspend 只处理 IOSMiniAppDeviceCapabilities（speech/brightness/share 等），传感器属于另一个 IOSMiniAppSystemBridge owner，不在它的 suspend 内。runtime.cancelPendingRequests 只取消当前任务，不清订阅。
- 最小修复：失去文档 trust 时清理该文档 event/sensor subscriptions，并保留 runtime 可加载新 host 文档的能力；可复用 close 里的小段清理而不把整个 runtime 永久关闭。
- Test seam：IOSMiniAppBridgeRuntimeTests 注入 subscribe/unsubscribe handlers、成功订阅、bridge.setTrustedMainDocument(true→false)，断言 unsubscribe 一次、事件不再发出、随后 close 不重复清理；无需 CoreMotion 硬件。

## 已复核并排除 / 未升级为缺陷

- MiniApp.host.getConversationContext 只返回 app title/description/boardSummary/source refs 是明确最小化上下文设计（MiniAppHostConfirmation 提示已说明），不能当作“没有提供完整聊天上下文”缺陷。
- 使用 OpenAIKmpProviderAdapter 不意味着 MiniApp AI 只能用 OpenAI；该 adapter 源码按 OpenAI / Claude / Google / Grok 和认证 resolver 分发。
- grant 生命周期已在 require 里检查 Task cancellation、isClosed、HTML/version/declared permissions 和并发 deny；已有测试覆盖“关闭 runner 不把取消持久化成 deny”，不重复报旧问题。
- MiniAppBridge 已按文档 generation 丢弃迟到 response/event；不把结果发到新文档认作缺陷。第 6 条仅指没有释放的底层资源。
- MiniAppRepository.persistAndPublish 在失败时回滚 committedState；没有把单纯写失败当成状态提前提交。
- HostConfirmationOwner 的取消不能立即解除 CheckedContinuation 有可疑路径，但 Runner close 会 resolve(false)，共享 permission coalescing 也有明确意图；未拿到比现有生命周期测试更强的可见损害证据，因此不列正式问题。

修复优先建议：先修 1、2 并独立 review；再合并处理 3、4、5 的能力范围映射与真实 request 状态，然后 review；6 作为文档资源 owner 的小修独立 review。所有文件都含/邻接当前拆分 WIP，必须在现有文件上精准修改，不能回退模块化。
