# Phase 5 WebMount WM1–3 independent implementation review

结论：**PASS，无 blocking findings**。

基线使用 `/tmp/amber-audit-20261018-current/webmount-before/`，逐项对比指定的5个生产文件并读取3个新增回归测试；未改源码、未跑测试/构建、未读取兄弟产品。实际red/green由Root统一报告。

## WM1 多个本地持久会话恢复

`IOSWebMountSessionStore.swift:251–258`仍先为本地session保留一个槽位，再从持久化列表按剩余额度补充未恢复ID；删除的只是“补充项必须remote”限制。因此3个本地会话可以全部恢复，纯remote列表仍留一个新local位置，总数继续受maxSessions约束。

恢复后原有ownerRun清理、controlOwner=none、lease清理、needsReopen=true保持；没有自动导航、恢复网页动作或延续旧agent权限。`currentSessionId`仍优先有效的persisted current local ID。

`IOSWebMountPersistentSessionRestoreTests`通过两个不同站点的persistent local、原agent绑定、当前第二session，以及restore→普通touch→再次restore检查，覆盖原始丢失及随后落盘抹掉第二项的故障。未见新生命周期/容量回归。

## WM3 desktop typed literal

`Desktop/IOSWebMountDesktopMapping.swift:230`只将text/value读取从trim+nilIfBlank helper改为String原值；target语义、安全门、ref映射、remote schema检查和submit/slowly字段策略保持原流程。空text优先于value alias是明确的literal payload，允许清空而不误退到另一值。

`IOSWebMountLiteralDesktopInputTests`经adapter execute→remote browser_type检查首尾空白/换行、空字符串、单空格和value alias，且确认目标ref正确、未额外带submit。没有为其他标识字段取消trim，改动边界精准。

## WM2 refresh原始目的地

`WebMountSiteView`根据地址栏focus分流：编辑地址时走原openTypedURL；普通refresh走reloadCurrentPage→controller.reloadForUser。controller明确要求local runtime、user owner及无需reopen，失败返回可见banner，不接管agent owner、不重新构造脱敏URL。

`IOSWebMountWKRuntime.reload`将完整request所有权留在现有WKWebView，通过native reload发起；只在公开snapshot记录redacted requestedURL。没有新增raw URL镜像、持久化或把query/hash带入tab list。后续导航仍由runtime现有WKNavigationDelegate处理，reload没有替换delegate或绕开URL policy入口。

`IOSWebMountReloadDestinationTests`通过真实WK历史URL变更后，分别验证controller path与WebKit原生reload的request/navigationType，并检查公开snapshot/tab list无query/hash。agent owner拒绝和无页面失败断言覆盖控制权与交互边界。测试probe在目标请求发出前取消网络，故这些证据证明reload接线和request目标，不声称外网站点加载成功。

本次实现复用了已有session cap、permission/control gate、navigation delegate和错误呈现，没有加入新的URL缓存、重试队列或泛化兼容分支。未发现需扩大修复范围的具体可达问题。
