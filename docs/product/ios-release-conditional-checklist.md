# Amber iOS 发布前外部条件（CONDITIONAL）核验清单

> 更新日期：2026-10-31  
> 适用范围：Amber iOS (`app.amber.ios`) 生产归档、真机联调与 App Store Connect / TestFlight 提审前必检项  
> 说明：以下条目依赖实体 iPhone / Apple Watch 真机、Apple Developer 付费团队签名凭据、APNs 生产推送凭据或 App Store Connect 后台配置，无法在无签名沙箱模拟器内闭环，标记为 `CONDITIONAL` 并在发布窗口逐项勾选。

---

## 1. 签名、Provisioning Profile 与归档（Apple Developer 账号依赖）

| 编号 | 核验项 | 依赖条件 | 验证命令 / 操作步骤 | 通过判据 | 当前状态 |
|---|---|---|---|---|---|
| `C-SIGN-01` | 5 个生产 Target 正式签名与 Archive | Apple Developer Team 证书 + Provisioning Profiles | `xcodebuild archive -project iosApp/AmberAgent.xcodeproj -scheme iosApp -configuration Release -archivePath /tmp/AmberAgent.xcarchive` | 归档成功产出 `.xcarchive`，主包与 `activity` / `phone-control-tunnel` / `watchkitapp` / `watchkitapp.widgets` 签名 Team 一致 | `CONDITIONAL` |
| `C-SIGN-02` | 受限 Entitlements 生产 Profile 授权核对 | Apple Developer Portal 启用 CloudKit、HealthKit、WeatherKit、Journal Suggestions、NetworkExtension、Time-Sensitive Notifications、App Attest | 检查 `.xcarchive` 内 `embedded.mobileprovision` 的 `Entitlements` 字典与 [`iosApp/iosApp/AmberAgent.entitlements`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/AmberAgent.entitlements) | Profile 包含全部 11 项受控 Entitlements，`aps-environment` 与 `com.apple.developer.devicecheck.appattest-environment` 均为 `production` | `CONDITIONAL` |
| `C-SIGN-03` | App Group 容器真机读写隔离验证 | 真机安装 Release / TestFlight 包 | 在真机触发对话状态更新并检查 Watch 小组件 / ActivityWidget 读取 `group.app.amber.ios.watchkit` | 主应用与 Widget / Watch 扩展可正常读写共享容器，无 `cfprefsd` 权限拒绝日志 | `CONDITIONAL` |

---

## 2. APNs 生产推送与 Mac Gateway 真机联调（真机 + APNs 凭据依赖）

| 编号 | 核验项 | 依赖条件 | 验证命令 / 操作步骤 | 通过判据 | 当前状态 |
|---|---|---|---|---|---|
| `C-APNS-01` | Release 包 APNs 生产环境 Token 注册与投递 | 实体 iPhone（蜂窝或局域网）+ 已配置 `.p8` APNs Auth Key 的 Mac Gateway | 1. 真机安装 Release 包并在「设置 › Mac Gateway」扫码配对；<br>2. 点击「测试」发送测试推送；<br>3. 检查 `amber-gateway` 日志中 `apnsEnvironment == "production"` | 真机锁屏/横幅在 3 秒内收到推送，Gateway 日志显示投递至 `api.push.apple.com` 且无 `BadDeviceToken` | `CONDITIONAL` |
| `C-APNS-02` | 锁屏推送审批动作与高风险只拒绝边界（真机） | 实体 iPhone（启用 Face ID / 锁屏密码）+ 配对 Mac | 1. 在 Mac 触发普通工具审批推送，长按通知点击「批准」（验证 `.authenticationRequired` 触发 Face ID 解锁后放行）；<br>2. 触发高风险工具（如 `shell_run`）推送，验证仅可拒绝、不可从通知直接批准 | 普通工具需解锁后方可批准；高风险工具在通知与看板中均无法在手机端批准 | `CONDITIONAL` |

---

## 3. 真机系统硬件、灵动岛与 Apple 生态集成（真机依赖）

| 编号 | 核验项 | 依赖条件 | 验证命令 / 操作步骤 | 通过判据 | 当前状态 |
|---|---|---|---|---|---|
| `C-DEVICE-01` | 灵动岛（Dynamic Island）与锁屏实时活动（Live Activity） | 支持灵动岛的实体 iPhone（iOS 26+） | 启动多步工具运行后切至桌面与锁屏，观察灵动岛紧凑态/展开态与锁屏实时活动卡片；待运行完成或进入审批等待后点击卡片跳转 | 状态流转（运行中 → 等待批准 → 已完成）实时刷新，无残留僵尸卡片，点击深链精准定位到对应会话 | `CONDITIONAL` |
| `C-DEVICE-02` | `BGContinuedProcessingTask` 切后台续跑与系统通知恢复 | 实体 iPhone（非连接调试器状态） | 发起长耗时深度阅读或模型生成后立即锁屏/切后台，等待任务完成或系统预算到期 | 任务在后台预算内完成并弹出本地完成通知，或预算耗尽时安全写入可恢复点且重回前台不丢消息 | `CONDITIONAL` |
| `C-DEVICE-03` | HealthKit / WeatherKit / EventKit / AlarmKit 真机授权流 | 实体 iPhone | 在「设置 › Apple 集成」及对话工具中分别触发健康步数读取、实时天气查询、日历冲突检查与闹钟设置 | 系统权限弹窗文案正常显示，只读/写入权限边界与用户授权状态一致 | `CONDITIONAL` |
| `C-DEVICE-04` | Apple Watch 真机伴侣同步与快捷审批 | 配对的实体 iPhone + Apple Watch（watchOS 11+） | 在真机发起需审批的工具调用，在 Apple Watch 端查看待办快照并执行批准/拒绝 | `WCSession` 正常连通，Watch 端普通风险审批结果幂等回传至 iPhone 当前 `runId`，高风险工具在 Watch 端仅可拒绝 | `CONDITIONAL` |
| `C-DEVICE-05` | 手机自控（RemotePairing / Loopback Tunnel）与多形态真机矩阵 | 实体 iPhone / iPad（启用本地网络、辅助功能与 `AmberPhoneControlTunnel` VPN 配置） | 1. 在真机完成无线配对（RemotePairing）并启用本机 Loopback Packet Tunnel；<br>2. 执行屏幕快照与动作回放，验证断连重连恢复；<br>3. 在 iPhone / iPad（及折叠形态真机）核对安全区、分栏与侧边栏布局 | 动态端口连通稳定，动作回执与失败恢复符合预期，多设备形态无遮挡或截断 | `CONDITIONAL` |

---

## 4. App Store Connect / TestFlight 提交门禁（发布后台依赖）

| 编号 | 核验项 | 依赖条件 | 验证命令 / 操作步骤 | 通过判据 | 当前状态 |
|---|---|---|---|---|---|
| `C-ASC-01` | Transporter / Xcode Organizer 上传静态扫描 | App Store Connect 账号权限 | 将 Release `.ipa` 上传至 App Store Connect，检查 Apple 后台自动邮件与构建状态 | 无 Missing Privacy Manifest（ITMS-91053）、无未声明后台模式（ITMS-90034）、出口合规由于 `ITSAppUsesNonExemptEncryption = false` 自动通过 | `CONDITIONAL` |
| `C-ASC-02` | App Store Connect 后台隐私营养标签与审核备注对齐 | App Store Connect 后台 | 核对后台 App Privacy 问卷与 [`iosApp/iosApp/PrivacyInfo.xcprivacy`](file:///Users/arquiel/.synara/worktrees/a3fe5a52e207/iosApp/iosApp/PrivacyInfo.xcprivacy) 一致，并在审核备注中附上自托管模型配置说明与演示凭据 | 审核备注清晰说明本地沙箱/网关按需连接机制，避免审核员因未配置模型 API Key 卡在空状态 | `CONDITIONAL` |
