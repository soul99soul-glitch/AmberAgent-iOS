# Xcode 无线真机覆盖安装与启动

## 结果

**本轮已完成签名 iphoneos 构建、Xcode/CoreDevice 无线覆盖安装和前台启动。** 此报告更新上一轮仅因 Synara device_list 没有真机而停止的安装状态；此前的三树集成/测试证据仍保留。

- 实际物理设备：Xcode 名称 `iPhone (2)`，iPhone 18 Pro，iOS 27.2（24B119）。
- 当前实时发现的 UDID：`00008160-001939111420000A`；CoreDevice ID：`C10C4C93-308E-570D-B516-67F402942C86`。
- CoreDevice 明确记录 `reality=physical`、`pairingState=paired`、`transportType=localNetwork`、`tunnelState=connected`。不是 Simulator，也没有使用旧脚本中的默认 UDID 代替发现。
- 保持原安装变体 `iosAppExperimentalGPL`、bundle `app.amber.ios`、签名团队 `TY4JTL3V2M` 和 App Groups。
- 签名构建 exit **0**；`codesign --verify --deep --strict` exit **0**。
- 无线安装 exit **0**，CoreDevice JSON `outcome=success`，安装目标 `app.amber.ios`。
- 前台启动 exit **0**，`activatedWhenStarted=true`、`startStopped=false`；实际 PID **30619**，随后按该 PID 查询仍在运行，执行路径属于本轮新安装的 bundle container。

没有卸载、清数据、reset、commit/push；没有修改源码或重新跑全量测试，没有发送模型消息或执行 provider/云端连接测试。

## 构建与兼容性

唯一工作区：`/Users/arquiel/.synara/worktrees/ce201253131e`。

当前已集成源码完整 tracked WIP SHA-256 在构建、安装前后均为：

`0295dec165d00f4aba3b16b12cbf96a17df4ba94bb5c30d413e263c2d82c346b`。

HEAD 保持 `84176fde736d3056e7a30fb1df66e44b7d378f5c`；MERGE_HEAD 保持 `6e89805b2667098e8ef523545915ca77c7b5f4a2`。无线操作前后 Git status 逐字一致。没有结束 pending merge 的提交事务。

先通过 `xcodebuild -showdestinations` 和 `devicectl list devices` 实时确认唯一可用物理 iPhone，再用 `device info details` 连通局域网 tunnel。安装前只查询现有目标 App 元数据：现有 `app.amber.ios` 的实际 bundle 路径就是 `iosAppExperimentalGPL.app`。

比对本地此前真机包签名与新包：团队保持 `TY4JTL3V2M`。新包 application identifier 为 `TY4JTL3V2M.app.amber.ios`，App Groups 与设备现有安装记录一致。没有静默切换成默认 experimental bundle identifier 或另一个 App。

精确构建命令：

```bash
cd /Users/arquiel/.synara/worktrees/ce201253131e
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj \
  -scheme iosAppExperimentalGPL -configuration Debug \
  -destination 'platform=iOS,id=00008160-001939111420000A' \
  -derivedDataPath iosApp/build/ExperimentalDeviceBuild \
  -clonedSourcePackagesDirPath iosApp/build/ExperimentalDeviceBuild/SourcePackages \
  -disableAutomaticPackageResolution -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=TY4JTL3V2M CODE_SIGN_STYLE=Automatic \
  AMBER_EXPERIMENTAL_BUNDLE_IDENTIFIER=app.amber.ios \
  AGENT_ACTIVITY_URL_SCHEME=amber ENABLE_DEBUG_DYLIB=NO \
  build > iosApp/build/WirelessInstall20261108/iphoneos-build.log 2>&1
```

这只构建真机，不是复用 Simulator 产物，也没有调用会重写项目的 xcodegen/安装脚本。

签名 iphoneos App：

`/Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ExperimentalDeviceBuild/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app`

版本 `1.0.0`、build `1`；主 executable SHA-256：

`dd8a051f8258831c6e56504b1e95c6234790f568c3a6cd99d68d7fbc1d8d11a6`。

- [签名真机产物元数据](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/signed-iphoneos-build-metadata.json)
- [真机构建原始日志](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/iphoneos-build.log)
- [严格签名校验原始日志](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/signature-verification.log)

## 无线安装及启动

通过 Xcode 自带 CoreDevice 链路执行，没有卸载步骤：

```bash
xcrun devicectl device install app \
  --device C10C4C93-308E-570D-B516-67F402942C86 --timeout 180 \
  --json-output iosApp/build/WirelessInstall20261108/install-result.json \
  /Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/ExperimentalDeviceBuild/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app

xcrun devicectl device process launch \
  --device C10C4C93-308E-570D-B516-67F402942C86 \
  --terminate-existing --timeout 30 \
  --json-output iosApp/build/WirelessInstall20261108/launch-result.json \
  app.amber.ios

xcrun devicectl device info processes \
  --device C10C4C93-308E-570D-B516-67F402942C86 \
  --filter 'processIdentifier == 30619' --timeout 20 \
  --json-output iosApp/build/WirelessInstall20261108/process-verification.json
```

三条均 exit 0。启动没有附加诊断、自动发消息或模型测试参数；没有采用 start-stopped 冒充已正常启动。

- [无线安装原始结果](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/install-result.json)
- [前台启动原始结果](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/launch-result.json)
- [启动后 PID 仍在运行的原始结果](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/process-verification.json)

## 保数据核验及限制

安装前后均使用 `device info apps --bundle-id app.amber.ios --include-container-paths --include-app-group-identifiers`，没有读取任何正文或凭据。

实际观察：

- bundle identifier、App Groups 保持一致。
- bundle container 已替换为新安装路径，启动 executable 位于该新路径。
- App Group 的数据容器保持原路径。
- **App 自身的数据容器 UUID 被系统更换。** 初次将路径相等当作验证条件的本地断言因此失败，未据此声称数据已丢失或重复安装；后续改为检查实际保留文件的元数据。

在本轮手动启动之前，仅用 `devicectl device info files` 列出 `Documents/conversations`、`Documents/memories` 的非递归文件元数据。新数据容器中仍存在 **209 个非空历史会话 JSON 文件**；`memories.json` 与 `profile.json` 也非空。它们的修改时间均早于本次安装。这支持覆盖安装保留了既有用户数据，而不是一个空白新数据容器。

没有读取会话正文、记忆正文或用户凭据；没有安装前后的内容 checksum，因此**不宣称逐条记录或全部附件已经完成内容级一致性校验**。

- [容器变化与旧数据保留的元数据核验摘要](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/build/WirelessInstall20261108/data-preservation-verification.json)

本轮仅完成构建、覆盖安装、系统前台启动及进程存活检查。没有进行聊天发送、模型/云端连接测试，亦未审计 App 既有自动后台网络行为。没有进行完整真机视觉/手感验收：滚动、首帧、键盘、安全区、大字号、像素对齐、间距和 Reduce Motion 仍不能据本次安装成功宣称通过。

此前集成快照的 Swift 9/9、KMP 39/39 结果仍见 [三树集成报告](file:///Users/arquiel/.synara/worktrees/ce201253131e/docs/reviews/2026-11-08-ios-three-tree-integration.md)。相邻 continuation 标题失败仍单列，未顺手修复。上一报告中的“真机未安装”是当时状态，已被本报告的实际无线安装/启动结果更新。
