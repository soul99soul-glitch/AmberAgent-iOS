# Amber iOS A 类集成版真机无线覆盖安装与启动验证报告

- **日期**：2026-11-08
- **唯一工作区**：`/Users/arquiel/.synara/worktrees/ce201253131e`
- **基线状态**：`HEAD = 84176fde736d3056e7a30fb1df66e44b7d378f5c`，`MERGE_HEAD = 6e89805b2667098e8ef523545915ca77c7b5f4a2`（完整保留 pending merge、staged/unstaged 及全部 WIP，未因装机重新构建或修改源码）
- **目标设备**：`iPhone (2)`（`iPhone 18 Pro`，iOS 27.2 `24B119`，Xcode UDID `00008160-001939111420000A`，CoreDevice ID `C10C4C93-308E-570D-B516-67F402942C86`）

---

## 1. 安装前产物复核

对已准备的签名包 `/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADeviceBuild20261108/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app` 进行字节级哈希与严格签名复核（全部匹配）：

- **Bundle ID / Application Identifier**：`app.amber.ios` / `TY4JTL3V2M.app.amber.ios`
- **签名团队（Team ID）**：`TY4JTL3V2M`
- **主可执行文件 SHA-256**（`iosAppExperimentalGPL`）：`0e8f174d0b9c471fc1dbc6cd31a9b5c05290039a07ba0228d0f0892e1749c881`
- **内嵌 `Shared.framework` 二进制 SHA-256**：`c299292be0760a12a5fdc3fd7c94dc05b4797d5cd4d921e4a39cd131dfee7f29`
- **源集成增量补丁 SHA-256**（[2026-11-08-ios-group-a-integrated-delta.patch](2026-11-08-ios-group-a-integrated-delta.patch)）：`ff8241702f038e0035f3a8ead7ae3ec0eb91a97f068b9729f745a4106e33da31`
- **`codesign --verify --deep --strict`**：通过（exit **0**）

---

## 2. 实际安装、前台启动与进程存活核验命令及结果

### 2.1 执行命令

```bash
# 1. 无线保数据覆盖安装（不卸载、不清数据）
xcrun devicectl device install app \
  --device C10C4C93-308E-570D-B516-67F402942C86 \
  --timeout 180 \
  --json-output iosApp/build/GroupADevicePrep20261108/install-result.json \
  /Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADeviceBuild20261108/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app

# 2. 前台启动 app.amber.ios
xcrun devicectl device process launch \
  --device C10C4C93-308E-570D-B516-67F402942C86 \
  --terminate-existing \
  --timeout 30 \
  --json-output iosApp/build/GroupADevicePrep20261108/launch-result.json \
  app.amber.ios

# 3. 核验新进程 PID 存活及可执行路径
xcrun devicectl device info processes \
  --device C10C4C93-308E-570D-B516-67F402942C86 \
  --filter 'processIdentifier == 33615' \
  --timeout 20 \
  --json-output iosApp/build/GroupADevicePrep20261108/process-verification.json
```

### 2.2 原始安装与启动证据

- **无线覆盖安装结果**（[install-result.json](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADevicePrep20261108/install-result.json)，exit **0**）：
  - `bundleID`：`app.amber.ios`
  - **安装前 Bundle 容器路径**：`file:///private/var/containers/Bundle/Application/A69199D9-6D1C-4549-8F6C-438AACA2BB25/iosAppExperimentalGPL.app/`
  - **安装后新 Bundle 容器路径**：`file:///private/var/containers/Bundle/Application/D235000B-82CF-412D-A931-568EAE7A3861/iosAppExperimentalGPL.app/`
  - `databaseUUID`：`14914597-0AC5-4C9D-9E54-4D10AB79E1D7`
  - **`databaseSequenceNumber`**：**`3160`**
- **数据容器保留元数据核验**（[pre-install-app-info.json](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADevicePrep20261108/pre-install-app-info.json)、[post-install-app-info.json](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADevicePrep20261108/post-install-app-info.json)）：
  - 同 Bundle ID（`app.amber.ios`）与同开发团队（`TY4JTL3V2M`）覆盖安装，未执行卸载或清数据操作。
- **前台启动与进程存活核验**（[launch-result.json](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADevicePrep20261108/launch-result.json)、[process-verification.json](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADevicePrep20261108/process-verification.json)，exit **0**）：
  - 启动进程 PID：**`33615`**
  - 进程存活核对：`running_processes_matched = 1`
  - 运行中可执行文件 URL：`file:///private/var/containers/Bundle/Application/D235000B-82CF-412D-A931-568EAE7A3861/iosAppExperimentalGPL.app/iosAppExperimentalGPL`（确认指向本次新安装的 `D235000B-82CF-412D-A931-568EAE7A3861` 容器）。

---

## 3. 边界说明

- 本轮严格保数据覆盖安装：未卸载 App、未清理数据、未重新配对、未改动系统设置或 Keychain，未读取或贴出任何用户私密对话内容，未调用真实付费模型接口。
- 工作树 `HEAD`、`MERGE_HEAD` 与全部 WIP 原样保留。
