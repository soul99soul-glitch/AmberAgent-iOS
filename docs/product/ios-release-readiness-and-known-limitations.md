# Amber iOS 发布准备、配置治理与已知限制（Phase 6）

> 更新日期：2026-10-31  
> 适用分支：`synara/amber-ios-baseline-fixes`  
> 对应阶段：四端五阶段对齐计划 Phase 6（I6.1–I6.4）

---

## 1. 构建配置与签名治理（I6.1）

### 1.1 目标（Targets）与 Bundle Identifier 矩阵
[`iosApp/project.yml`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/project.yml) 严格区分主构建（App Store / TestFlight 稳定发布线）与 Experimental GPL 构建线：

| Target | 用途 | 稳定发布 Bundle ID | Entitlements 文件 |
|---|---|---|---|
| `iosApp` | iPhone / iPad 主应用 | `app.amber.ios` | [`iosApp/iosApp/AmberAgent.entitlements`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/AmberAgent.entitlements) |
| `AmberAgentActivityWidget` | 灵动岛 / Live Activity 扩展 | `app.amber.ios.activity` | `iosApp/ActivityWidget/AmberAgentActivityWidget.entitlements` |
| `AmberPhoneControlTunnel` | 本机 Loopback Packet Tunnel | `app.amber.ios.phone-control-tunnel` | `iosApp/PhoneControlTunnel/AmberPhoneControlTunnel.entitlements` |
| `AmberWatchApp` | Apple Watch 伴侣应用 | `app.amber.ios.watchkitapp` | `iosApp/WatchApp/AmberWatchApp.entitlements` |
| `AmberWatchWidgets` | Apple Watch 表盘小组件 | `app.amber.ios.watchkitapp.widgets` | `iosApp/WatchWidgets/AmberWatchWidgets.entitlements` |

### 1.2 Debug / Release 环境自动切换
- **APNs 环境**：
  - `project.yml` 中 `Debug` 声明 `APS_ENVIRONMENT = development`，`Release` 声明 `APS_ENVIRONMENT = production`。
  - [`MacGatewayStore.apnsEnvironment`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/MacGatewayStore.swift#L20-L26) 在编译期按 `#if DEBUG` 自动汇报 `"sandbox"` 或 `"production"`，`amber-gateway` 守护进程据此将推送路由至 `api.sandbox.push.apple.com` 或 `api.push.apple.com`。
- **App Attest 环境**：
  - `Debug` 使用 `development`，`Release` 使用 `production`。
- **性能测试大体积夹具剥离**：
  - `Release` 配置通过 `EXCLUDED_SOURCE_FILE_NAMES` 自动排除 `chat-perf-growing-table.jsonl` 与 `chat-perf-long-prose.jsonl`，避免测试夹具进入生产包体。

---

## 2. 隐私清单、权限文案与合规门禁（I6.2）

### 2.1 `PrivacyInfo.xcprivacy` 覆盖
所有四个应用与扩展组件均包含独立且通过校验的 `PrivacyInfo.xcprivacy`，且全部声明 `NSPrivacyTracking = false`：
1. 主应用 [`iosApp/iosApp/PrivacyInfo.xcprivacy`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/PrivacyInfo.xcprivacy)：
   - `NSPrivacyAccessedAPICategoryUserDefaults`: `CA92.1`, `1C8F.1`（应用内偏好与 App Group 共享设置）
   - `NSPrivacyAccessedAPICategoryFileTimestamp`: `C617.1`, `3B52.1`（工作区文档与导出包时间戳）
   - `NSPrivacyAccessedAPICategorySystemBootTime`: `35F9.1`（流式渲染与运行耗时度量）
2. 灵动岛扩展 [`iosApp/ActivityWidget/PrivacyInfo.xcprivacy`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/ActivityWidget/PrivacyInfo.xcprivacy)：`CA92.1`
3. 手表应用 [`iosApp/WatchApp/PrivacyInfo.xcprivacy`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/WatchApp/PrivacyInfo.xcprivacy)：`CA92.1`, `1C8F.1`
4. 手表小组件 [`iosApp/WatchWidgets/PrivacyInfo.xcprivacy`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/WatchWidgets/PrivacyInfo.xcprivacy)：`CA92.1`, `1C8F.1`

### 2.2 `Info.plist` 合规项与构建期门禁脚本
每次构建 `iosApp` 时自动执行以下两个门禁脚本：
- [`iosApp/scripts/validate-entitlement-diagnostics.sh`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/scripts/validate-entitlement-diagnostics.sh)：校验 `Info.plist` 中的 `AmberAgentConfiguredEntitlements` 与 `AmberAgent.entitlements` 键值完全一致。
- [`iosApp/scripts/validate-release-readiness.sh`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/scripts/validate-release-readiness.sh)：
  - 禁止稳定版声明 `UIBackgroundModes = audio`（防止 App Store 2.5.4 审核驳回），仅保留 `processing`（供 `BGContinuedProcessingTask` 使用）。
  - 校验 `NSAppTransportSecurity` 未开启 `NSAllowsArbitraryLoads`，仅开启 `NSAllowsLocalNetworking`（供局域网配对 Mac Gateway 与本地服务发现使用）。
  - 校验 `ITSAppUsesNonExemptEncryption = false`（仅使用 Apple 操作系统内置 HTTPS/TLS、CryptoKit 与 Security 框架，符合出口合规豁免）。
  - 校验 `HealthKit`、`EventKit`（日历/提醒事项）、`AlarmKit`、本地网络、相机、麦克风、位置等 Usage Description 非空且准确描述按需授权语义。

---

## 3. 已知限制与架构边界说明（I6.3 & I6.4）

1. **KMP `Shared.framework` 过渡态**：
   - 当前 Swift 仍通过本仓库 Gradle 工程生成 `Shared.framework`（`:shared:embedAndSignAppleFrameworkForXcode`）。在双端消费契约稳定前，不应假装 Core 已拆分为独立远端制品。
2. **后台保活与系统挂起边界**：
   - 稳定版不启用后台静音音频保活，依赖 iOS 26 `BGContinuedProcessingTask` 与 `UIApplication.beginBackgroundTask` 预算。当系统预算耗尽或任务挂起时，由 [`ChatKernelRunHost`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/ChatKernelRunHost.swift) 与 [`IOSAgentRunLedger`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/IOSAgentRunLedger.swift) 将运行记入可恢复的 `waitingInput` / `interrupted` 终态，并在回到前台或通过 [`IOSWakeScheduler`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/Automation/IOSWakeTasksSection.swift) 时续跑。
3. **Mac Gateway 高风险工具只拒绝（Fail-Closed）**：
   - 手机端新建的 Mac 定时任务不携带任何自动批准配置；运行中若触发高风险工具（或旧网关未下发 `highRisk` 字段），手机端审批卡与推送通知均**仅允许拒绝（Deny）**，批准操作必须在 Mac 端核对后完成。
4. **JavaScript 沙箱内存与执行护栏**：
   - `javascript_eval` 运行在独立 `JSContext` Worker 线程，强制 1 MB 源码上限、64 KB 输出上限、5 秒超时及 `fetch` 默认关闭（开启时强制经过 `IOSOutboundHostPolicy` 阻断内网/云元数据地址）。由于 JavaScriptCore 公开 API 不支持 V8 风格的硬性 C 堆上限，通过预执行输入长度与 Array/String/repeat 静态与运行时守卫控制内存峰值（详见 [`docs/product/ios-js-sandbox-decision.md`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/docs/product/ios-js-sandbox-decision.md)）。
5. **手机自控（RemotePairing / Loopback Packet Tunnel）权限与审核边界**：
   - 本机自控依赖 `AmberPhoneControlTunnel`（`NEPacketTunnelProvider`）建立本机 Loopback 通道与无线配对服务，仅在用户主动开启手机自控能力并授予本地网络与 VPN 配置权限后按需启动，不拦截或转发任何外部公网流量；App Store 提审需在审核备注中说明其本地辅助自动化用途。
6. **外部条件受限验证项（`CONDITIONAL`）**：
   - 涉及 Apple Developer 生产证书归档、真机 APNs 生产通道、灵动岛真机锁屏交互、手机自控与多形态真机矩阵、Apple Watch 真机配对以及 App Store Connect 提交前检查的条目，已统一收口至 [`docs/product/ios-release-conditional-checklist.md`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/docs/product/ios-release-conditional-checklist.md) 及 Hub Library 归档文档。
