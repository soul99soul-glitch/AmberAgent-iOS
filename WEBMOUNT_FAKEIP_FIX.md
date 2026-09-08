# WebMount HTTPS Fake-IP 兼容修复

日期：2026-09-08。工作区：`/Users/arquiel/Downloads/AI/AmberAgent/ios`。

## 实现边界

沿用现有高风险自动批准和 DNS 预检模型，在可信 VPN 下恢复未注册 HTTPS 站点的访问。只有本地 WK 路径显式开启兼容；远程 MCP 保持严格 DNS 策略。

1. 原 URL 的协议、凭据、私网/保留地址字面量校验先执行。
2. 已注册站点沿用原信任路径；普通公网 DNS 答案沿用原路径。
3. 未注册 HTTPS 主机的系统答案至少包含一个 `198.18.0.0/15` 地址，且其它答案均为数值公网地址，才进行公共加密 DNS 补验。Fake-IP 和真实公网 IPv6 混合可接受，Fake-IP 和私网混合不可接受。
4. 使用固定 `https://dns.google/resolve` 查询 A 和 AAAA；两次响应均须 HTTP 200、`Status == 0`、显式 `TC == false`，合并结果必须非空，所有地址均为有效数值公网 IP。空结果、私网、保留地址、截断或服务错误均拒绝，返回 `fake_ip_public_dns_failed`。
5. WK 保留原 URL/主机名、TLS 校验和系统 VPN 出站，不重写成 IP 地址，不修改共享 website data store、Cookie 或 Grok 网络配置。

公共解析请求使用独立 ephemeral URLSession、无 Cookie/凭据存储、禁止重定向、请求时限 8 秒、响应上限 64 KiB。A/AAAA 并发查询，未添加多服务回退、重试或缓存。`edns_client_subnet=0.0.0.0/0` 避免向权威 DNS 附加用户网段；Google Public DNS 仍会收到域名和请求来源 IP。API 及 ECS 行为依据 [Google 官方 JSON DoH 文档](https://developers.google.com/speed/public-dns/docs/doh/json)。

## 信任与限制

这是 DNS 预检兼容，不是实际连接 IP 固定。原实现也在预检后让 WK 自行解析/连接；本轮额外依赖用户信任 VPN 按原主机名进行映射。它不提供抵御恶意 VPN、私有根证书或 split DNS 将公网域名导向内网的连接级保证。设置文案及 Agent schema 已说明可信 VPN 与 Google Public DNS 域名查询。

HTTP Fake-IP、非标准自定义 Fake-IP 网段、Fake IPv6 ULA 仍拒绝。纯私网答案、字面私网目标和公共 DNS 明示非公网地址仍拒绝。导航 delegate 的既有检查继续执行，但不能把它表述为涵盖每个子资源 socket 的防火墙。

若以后需要连接级公网约束，需要专用 WK data store 和可校验实际连接目标的代理。当前 `.default()` 同时被 WebMount 与 Grok 使用，直接修改代理会影响共享数据存储；迁移还涉及已有登录/存储数据，不属于这次最小兼容实现。Apple 明确说明代理配置作用于使用该 data store 的全部 WKWebView：[WKWebsiteDataStore API](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStore.h)。

## 修改文件

- `iosApp/iosApp/IOSLocalToolExecutor.swift`：标准 Fake-IP 分类、HTTPS/高风险/本地范围、公网补验、独立拒绝码。
- `iosApp/iosApp/IOSWebMountPublicDNS.swift`：固定公共加密 DNS 解析器。
- `iosApp/iosApp/ToolPermissionsView.swift`、`Localizable.xcstrings`：在原 WebMount 权限说明中交代新数据流与可信 VPN 前提。
- `ai-core/src/commonMain/kotlin/app/amber/ai/core/Tool.kt`：Agent 使用说明。
- `IOSWebMountFakeIPTests.swift`、`IOSWebMountPublicDNSTests.swift`、`IOSLocalToolExecutorTests.swift`：失败关闭边界与真实 WK fixture。

本轮之前的 WebMount 参数/回执/观察改动以及其它并行 WIP 均保留；这些文件的完整 git diff 不全属于本次 Fake-IP 续修。

## 实际验证

最终源码在 iPhone 17 Pro / iOS 26.5 模拟器上通过 133 项 Swift 定点回归，0 失败、0 跳过；Kotlin WebMount 声明测试 7 项通过。Swift 结果：`/tmp/amber-webmount-fakeip-regression3-20260908.xcresult`。验证覆盖本轮 Fake-IP 放行/拒绝、DNS 响应解析、真实 WK fragment 导航，以及前轮参数、观察、回执、远程后端、视觉和输出裁剪回归。

公开页面验证使用当前真实系统 DNS、生产公共 DNS 解析器和真实 WebMount controller/WKWebView。仅通过临时编译映射把测试浏览器改为空 Cookie 的非持久化 data store，并加入只读公开页面测试；未改生产 data store，未调整 VPN/DNS 配置，未降低 TLS 校验。

| 页面 | 实测系统 DNS 答案 | 实测页面结果 |
|---|---|---|
| `https://example.com/` | `198.18.2.26` | `wm_open` 为 `ready`，`wm_observe` 读到 `Example Domain` 及用途说明正文。 |
| `https://www.wikipedia.org/` | `198.18.2.128` | `wm_open` 为 `ready`，`wm_observe` 读到 `Wikipedia`、中文/English 等语言入口与正文。 |

该公开页面测试实际通过，0 失败、0 跳过，两页均按正文断言确认成功。结果：`/tmp/amber-webmount-fakeip-public-20260908.xcresult`；原始 JSON 附件及 manifest：`/tmp/amber-webmount-fakeip-public-attachments/`。临时测试映射：`/tmp/amber-webmount-fakeip-public-validation/overlay.json`。

此前未修复版本对相同两个页面均返回 `dns_non_public_address`，未读到正文，证据为 `/tmp/amber-webmount-public-20260908.xcresult`。本轮验证证明当前 VPN 下标准 HTTPS Fake-IP 的实际访问已恢复，不只是 DNS mock 或 `wm_open.ok` 成功。

早一轮独立构建在修改尚未全部结束时启动，133 项中 1 项截断响应拒绝测试未通过；所有编辑结束后的上述统一重跑为 133/133 通过。最初默认 DerivedData 被其它并行构建占用，已改用独立目录完成验证。未安装真机、未提交或推送；真实设备仍未验证。
