# 本机控制验证边界

这是隔离的技术探针，不是 Amber 正式产品入口。当前同机 RemotePairing 未通过，完整进度见 `../../docs/iphone-self-control-plan.md`。三个本轮设备验证 App 已按用户纠正清理；不要将此目录的存在视为继续安装真机测试程序的授权。

`project.yml` 定义 Probe 与只含可逆状态的 Target。Probe 链接本仓 `native/iphone-control` 和 `Packages/AmberPhoneControl`；runner 在 `../PhoneControlRunner`，有固定来源清单。构建前先生成 native 制品与 Xcode 工程，没有自动安装脚本。

- `--probe-network`：仅检查 loopback、已知 VPN 地址和手机自身 Wi-Fi 地址的 TCP 入口，不读取 UI 树。
- `--prepare-pairing`：显式请求标准系统 RemotePairing；已有 Keychain 记录时不再创建配对。失败不自动改变路由或服务。
- `--pairing-over-wifi`：仅与首次配对参数组合，用手机自身 Wi-Fi 地址进行显式对照，不扫描其他设备。
- `--probe-control`：使用已保存材料新建 XCTest 会话；仅允许靶场；签名 status、未签名 401、树、计数一次、新树验证；最终释放连接。

配对材料只保存于此 App 专属 `ThisDeviceOnly` Keychain。一次性导入文件的名称为 `Documents/amber-pairing.plist`，仅在 Keychain 写入成功后移除该任务文件。日志不包含配对 XML 或 token。`Preparation` 是需要已有 usbmux 信任的一次性电脑助手，不维持 runner，不输出密钥，不覆盖现有输出文件。

Probe 使用有限 UIKit 后台短窗；它不能验证正式 Amber 的 continued task 或 Agent 多轮后台控制。普通字号截图已看过；新配对界面与最大辅助字号的最终效果未验收。


## 一次性 Mac 准备助手的只读预检

`Preparation` 仍仅用于首次初始化，正式 Amber 的现有导入入口消费结果；它不会安装或维持任何手机测试 App、XCTest 或模型循环。

```sh
cargo run --locked --manifest-path iosApp/PhoneControlProbe/Preparation/Cargo.toml -- --check-device <device-UDID>
```

该模式只发送 usbmuxd `ListDevices` 并按显式 UDID 选择目标，不读取配对记录、不连接设备服务、不创建文件。只输出条目数、连接类型及脱敏错误；与实际准备共用 `USBMUXD_SOCKET_ADDRESS` 的选择规则。

正常准备命令保持 `<device-UDID> <new-output-plist>`，只有另获设备初始化授权后才执行。输出以 `0600` 和 `create_new` 创建，禁止覆盖；失败时当前身份仅供私下核查，空、部分或未验证文件保留，禁止导入，不能据此认为配对成功或自动再次创建身份。协议错误正文和密钥不输出；verify 的传输或解析错误直接停止，只有 typed `PairVerifyFailed` 才进入一次 setup。生成的身份使用独立 attempt 名称，避免替换其他安装的配对身份。材料在 Mac 上应放入本机私有临时目录，导入手机时使用正式产品入口，并保持材料不进入聊天、同步或备份。


## 正式 Amber 的 USB 首次初始化与导入

初始化使用已有 USB 信任，通过 idevice 现成的 `RemotePairingLockdownService` 请求固定服务 `com.apple.dt.remotepairingdeviced.lockdown`，显式完成初始材料及设备保存两段流程。该入口与固定版本官方 idevice_pair 的创建路径一致；不扫描端口、不猜协议版本、不维持 XCTest。只有 typed `PairVerifyFailed` 允许一次 setup，其余错误直接停止，日志只记固定阶段及数字错误。

用户授权的本次初始化已完成，脱敏证据见 `../../docs/iphone-control-evidence/mac-initialization.json`。材料只放在 `0700` 本机临时目录内的 `0600` 新文件；失败的旧路线材料不能导入。

正式 Amber 增加一个复用既有设置组件的“导入 USB 准备的配对材料”按钮。经 USB `devicectl device copy to` 送到 `appDataContainer / app.amber.ios / Library/Caches/amber-phone-control-usb.plist` 前，先确认保留路径不存在，禁止覆盖。该私有缓存不放进 Documents、聊天、App Group 或云端。按钮只读最多 1 MB 的普通文件，拒绝 symlink，复用 Ed25519 密钥匹配验证；保存到非同步 `AfterFirstUnlockThisDeviceOnly` Keychain 后再次比较原始内容，仅删除同一任务文件。保存失败或文件已变化时保留暂存并显示错误。

初始化和导入不授予控制、不启动 runner。手机本机服务接受材料、手机自己启动 XCTest 和真实跨 App 验收仍需分别取得设备证据。


`--check-runner-auth <device-UDID>` 是独立的只读验收模式。仅在手机自己已启动 runner 后运行：通过既有 USB 信任连接固定的 runner 8100 端口，只发送一次无 token 的 `GET /status`，读取最多 1024 字节的第一行，必须返回 401。只输出状态数字，不读取或记录响应正文；5 秒整体超时，没有重试、配对材料读写、XCTest 启动或 Mac 模型循环。

`--read-pairing-service-errors <device-UDID>` 是独立的只读系统诊断模式。先读取环境变量 `AMBER_PAIRING_SERVICE_PID`（必须是正的十进制 `u32`），再通过已有 USB 信任连接 `OsTraceRelay`，只请求该 PID 的 trace，接受最多 32 条且 `filename` basename 精确为 `remotepairingdeviced` 的记录。20 秒整体超时；输出只含 PID、level、固定原因布尔值和数值 `errorCode`，不输出 message、image name/path、DNS/IP、pairing 正文、key 或 token。原因布尔值只是 trace message 中明确关键词的线索，不能单独视为根因。诊断结束即关闭 trace 连接，不创建 archive、不启动或维持控制会话。
