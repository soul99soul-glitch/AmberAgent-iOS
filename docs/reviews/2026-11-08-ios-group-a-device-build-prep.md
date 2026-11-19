# Amber iOS A 类集成版真机签名设备构建准备报告（待 GO INSTALL）

- **日期**：2026-11-08
- **唯一工作区**：`/Users/arquiel/.synara/worktrees/ce201253131e`
- **基线状态**：
  - `HEAD`：`84176fde736d3056e7a30fb1df66e44b7d378f5c`
  - `MERGE_HEAD`：`6e89805b2667098e8ef523545915ca77c7b5f4a2`（完整保留 pending merge、staged/unstaged 及全部 WIP，未修改源码）
  - 集成增量补丁：[2026-11-08-ios-group-a-integrated-delta.patch](2026-11-08-ios-group-a-integrated-delta.patch)，SHA-256 为 `ff8241702f038e0035f3a8ead7ae3ec0eb91a97f068b9729f745a4106e33da31`（构建前后 `git apply -R --check` 均 `exit 0`）
- **当前执行状态**：**已完成 arm64 `iphoneos` 真机签名 `.app` 构建与严格签名/Bundle 核验；按指令尚未执行真机安装、卸载、清数据或重新配对，等待协调者 `GO INSTALL`。**

---

## 1. 实际构建命令与输出目录

沿用既有 Xcode 无线装机签名参数（`scheme = iosAppExperimentalGPL`、`AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER = app.amber.ios`、`DEVELOPMENT_TEAM = TY4JTL3V2M`），在独立 DerivedData 目录 `iosApp/build/GroupADeviceBuild20261108` 构建：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
xcodebuild -quiet -jobs 2 -project iosApp/AmberAgent.xcodeproj \
  -scheme iosAppExperimentalGPL -configuration Debug \
  -destination 'platform=iOS,id=00008160-001939111420000A' \
  -derivedDataPath iosApp/build/GroupADeviceBuild20261108 \
  -clonedSourcePackagesDirPath iosApp/build/ExperimentalDeviceBuild/SourcePackages \
  -disableAutomaticPackageResolution -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=TY4JTL3V2M CODE_SIGN_STYLE=Automatic \
  AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER=app.amber.ios \
  AGENT_ACTIVITY_URL_SCHEME=amber ENABLE_DEBUG_DYLIB=NO \
  build > iosApp/build/GroupADevicePrep20261108/iphoneos-build.log 2>&1
```

- **构建退出码**：`0`（`DEVICE_BUILD_EXIT_0`）
- **构建日志**：`iosApp/build/GroupADevicePrep20261108/iphoneos-build.log`

---

## 2. 产物路径、Bundle / 签名与 SHA-256 证据

- **真机签名 `.app` 路径**：
  `/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/GroupADeviceBuild20261108/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app`
- **元数据与签名核验结果**（保存在 `iosApp/build/GroupADevicePrep20261108/signed-iphoneos-build-metadata.json` 与 `signature-verification.log`）：
  - `CFBundleIdentifier`：`app.amber.ios`
  - `CFBundleExecutable`：`iosAppExperimentalGPL`
  - `DTPlatformName`：`iphoneos`（arm64）
  - `CFBundleShortVersionString` / `CFBundleVersion`：`1.0.0` / `1`
  - `com.apple.developer.team-identifier`：`TY4JTL3V2M`
  - `application-identifier`：`TY4JTL3V2M.app.amber.ios`
  - `com.apple.security.application-groups`：`["group.app.amber.ios.experimental-gpl.watchkit"]`（与真机已安装版本完全一致，后续可直接同 bundle 保数据覆盖安装）
  - `codesign --verify --deep --strict --verbose=2`：通过（exit **0**）
  - **主可执行文件 SHA-256**（`iosAppExperimentalGPL.app/iosAppExperimentalGPL`）：
    `0e8f174d0b9c471fc1dbc6cd31a9b5c05290039a07ba0228d0f0892e1749c881`
  - **内嵌 `Shared.framework` 二进制 SHA-256**（`Frameworks/Shared.framework/Shared`）：
    `c299292be0760a12a5fdc3fd7c94dc05b4797d5cd4d921e4a39cd131dfee7f29`
  - **源集成增量补丁 SHA-256**（`docs/reviews/2026-11-08-ios-group-a-integrated-delta.patch`）：
    `ff8241702f038e0035f3a8ead7ae3ec0eb91a97f068b9729f745a4106e33da31`

---

## 3. 验证与待命边界

- 复用本轮集成已完成验证证据：KMP `ConversationForkTest` **11 / 11 通过**，iOS 模拟器定点测试集合 **112 / 113 通过**（仅 1 项已知基线失败 `IOSSubAgentOutputTests/testReportSummaryAcceptsOnlyCompletePublicFields`）。
- **未执行项**：未安装至真机 `iPhone (2)`（`iPhone 18 Pro`，CoreDevice `C10C4C93-308E-570D-B516-67F402942C86`），未卸载或清理任何真机数据，未跑全量测试或调用真实付费模型接口。待收到 `GO INSTALL` 后即可直接执行同 bundle 保数据覆盖安装与前台启动核验。
