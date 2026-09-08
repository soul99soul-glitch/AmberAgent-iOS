# Amber Watch 真机覆盖安装记录

日期：2026-09-08

## 已完成

- iPhone Air 上的 `app.amber.ios` 已覆盖安装并成功启动；采用原应用标识，没有卸载或清空数据。
- 构建方案：`iosAppExperimentalGPL`，包含本轮 Watch 完善与复审修复。
- 最终签名构建 `BUILD SUCCEEDED`，`devicectl` 返回安装成功、启动成功及新的应用安装记录。
- 包内存在内嵌 iSH rootfs（busybox 与 rootfs 元数据）；后台模式包含 `audio` 与 `processing`。
- iPhone 包内包含 `app.amber.ios.watchkitapp` 和 `app.amber.ios.watchkitapp.widgets`，Watch 图标已配置。
- 已安装包通过 `codesign --verify --deep --strict`。实际 Watch 签名包含 `group.app.amber.ios.experimental-gpl.watchkit`。
- Apple Watch Series 10 的开发者模式已确认开启，针对该手表的签名构建通过。`devicectl` 已返回 `app.amber.ios.watchkitapp` 安装成功及启动成功，新包包含 Watch 小组件。
- 音频保活已开启：仅通过进程内 CFPreferences 写入 `app.amber.ios.execution.audioKeepAlive = true`，同步保存并读回，验证表达式返回 `(int) $0 = 1`。没有导出偏好文件或读取其他设置。
- 已正常分离调试器，随后重新启动 iPhone 上的 Amber，设备工具返回启动成功。

## 安装中解决的问题

新加入的 App Groups 起初不在本地签名描述文件中。用户登录开发者账号后，将三个目标的共享组注册并关联到覆盖安装所用的应用标识，签名构建通过。六份正式/实验版 entitlement 文件中的共享组改为对应的完整组名，方便 Xcode 的能力面板识别与注册；同一版本的应用、手表和组件组名保持一致。

临时签名配置仅用于在 Xcode 中选择覆盖安装标识；最终安装脚本已重新从 `iosApp/project.yml` 生成工程，实验版默认标识仍保持独立。

## 验证边界

- 本轮完成包内容、真机构建、签名、安装与音频开关持久化验证。尚未使用真实长任务验证后台持续运行时长。
- 手表最初关闭开发者模式，重启期间连接不稳定；待新状态确认已开启开发者模式、应用查询成功、真机构建通过后，才重新提交安装并获得成功结果。

## 日志

- 手机最终构建、安装与启动：`/private/tmp/amber-watch-device-install-20260908.log`
- Watch 真机目的地检查：`/private/tmp/amber-watch-physical-build-20260908.log`
- Watch 安装结果：`/private/tmp/amber-watch-device-install-result.json`
- Watch 启动结果：`/private/tmp/amber-watch-device-launch-result.json`

[前一轮审查与模拟器证据](2026-09-08-amber-watch-followup-review.md)
