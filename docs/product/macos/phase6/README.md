# macOS Phase 6：发布准备、签名公证边界与已知限制

> 更新日期：2026-10-31
> 范围：计划 §5 `M6.1`–`M6.4`（Release 构建与签名配置、公证外部阻塞清单、自启/日志/诊断导出、文档与隐私说明对齐）

## 1. Release 构建、签名与公证状态（M6.1 / M6.2）

| 验收项 | 状态 | 证据 / 外部依赖说明 |
| --- | --- | --- |
| XcodeGen 工程与 `Amber.entitlements` / `Info.plist` 权限配置 | **PASS** | [`macApp/project.yml`](../../../../macApp/project.yml)、[`macApp/AmberMac/Amber.entitlements`](../../../../macApp/AmberMac/Amber.entitlements)、[`macApp/AmberMac/Info.plist`](../../../../macApp/AmberMac/Info.plist) 已补齐 `NSCalendarsFullAccessUsageDescription` 与 `NSRemindersFullAccessUsageDescription`，并内嵌 `amber-gateway` 与 `Shared.framework`。 |
| Developer ID Application 正式签名（`AMBER_DISTRIBUTION=1`） | **CONDITIONAL** | 脚本入口已就绪（[`macApp/scripts/build.sh`](../../../../macApp/scripts/build.sh#L33-L52)），依赖外部 Apple Developer ID Application 证书与签名钥匙串，按规则标记为 CONDITIONAL 交由用户环境执行。 |
| Apple `notarytool` 公证、`stapler` 票据装订与 DMG 分发校验 | **CONDITIONAL** | 依赖外部 Apple Developer 账号公证凭据（`xcrun notarytool` / `xcrun stapler`），标记为 CONDITIONAL。 |
| 真实 macOS TCC 日历/提醒事项/系统通知弹窗授权与 APNs 真机推送 | **CONDITIONAL** | 依赖签名应用首次系统弹窗交互与 APNs 生产/沙盒密钥及配对真机，标记为 CONDITIONAL。 |

## 2. 登录自启、审计日志与诊断/备份导出（M6.3）

- **内嵌 `amber-gateway` 登录自启（`SMAppService`）**：
  - LaunchAgent plist 位于 `macApp/AmberMac/LaunchAgents/`，随应用打包至 `Contents/Library/LaunchAgents`；由 [`DesktopGateway.swift`](../../../../macApp/AmberMac/Runtime/DesktopGateway.swift) 通过 `SMAppService.agent(plistName:)` 管理启停与状态巡检。
- **审计与运行日志路径**：
  - Gateway 状态与审计日志：`~/Library/Application Support/AmberGateway/audit.jsonl`（由 `AuditLog` 记录配对、吊销、远程审批决定、推送与监控变更）。
  - 工具事务账本：`~/Library/Application Support/Amber/tasks/<run-uuid>.json`（由 `DesktopAgentJournal` 原子写入，自动脱敏凭据并在冷启动时将未决运行恢复为 `interrupted` / `outcome_unknown`）。
- **备份与诊断导出**：
  - 会话与完整工作区备份：`DesktopBackupCoordinator` 支持 AES-GCM 密码加密导出 `.ambermacbackup`（[`DesktopBackup.swift`](../../../../macApp/AmberMac/Runtime/DesktopBackup.swift)），保留原始 `DesktopConversation`、链式 `compacts` 检查点、长期记忆与内部工作区文件，绝不导出 Keychain 凭据。
  - 损坏设置恢复导出：当检测到设置文件无法解码时，自动保留 `desktop.settings.recovery.v1` 并在设置页顶部提供「导出原始设置…」（[`DesktopSettingsView.swift`](../../../../macApp/AmberMac/UI/DesktopSettingsView.swift#L173-L194)）。

## 3. 文档、插件能力与隐私说明更新（M6.4）

- [`docs/plugins.md`](../../../plugins.md)：已对齐 3 个保留内置插件 ID（`feishu_calendar`、`apple_schedule`、`watchtower`）、8 个飞书工具（4 个网络只读 + 4 个外部写入）、高风险审批规则（`sideEffect` / `idempotent` 插件工具不被普通自动批准放行，手机端仅可拒绝）及第三方 JS 插件真实边界（无沙箱网络、无沙箱文件 IO、无第三方 `hostModules`）。
- [`macApp/README.md`](../../../../macApp/README.md)：已同步上下文链式检查点、历史检索（`history_search` / `history_fetch`）、三大内置插件/Recipe 工作流、Gateway C3 合同与数据保留/隐私边界。
