# 本机控制验证边界

这是隔离的技术探针，不是 Amber 正式产品入口。当前同机 RemotePairing 未通过，完整进度见 `../../docs/iphone-self-control-plan.md`。三个本轮设备验证 App 已按用户纠正清理；不要将此目录的存在视为继续安装真机测试程序的授权。

`project.yml` 定义 Probe 与只含可逆状态的 Target。Probe 链接本仓 `native/iphone-control` 和 `Packages/AmberPhoneControl`；runner 在 `../PhoneControlRunner`，有固定来源清单。构建前先生成 native 制品与 Xcode 工程，没有自动安装脚本。

- `--probe-network`：仅检查 loopback、已知 VPN 地址和手机自身 Wi-Fi 地址的 TCP 入口，不读取 UI 树。
- `--prepare-pairing`：显式请求标准系统 RemotePairing；已有 Keychain 记录时不再创建配对。失败不自动改变路由或服务。
- `--pairing-over-wifi`：仅与首次配对参数组合，用手机自身 Wi-Fi 地址进行显式对照，不扫描其他设备。
- `--probe-control`：使用已保存材料新建 XCTest 会话；仅允许靶场；签名 status、未签名 401、树、计数一次、新树验证；最终释放连接。

配对材料只保存于此 App 专属 `ThisDeviceOnly` Keychain。一次性导入文件的名称为 `Documents/amber-pairing.plist`，仅在 Keychain 写入成功后移除该任务文件。日志不包含配对 XML 或 token。`Preparation` 是需要已有 usbmux 信任的一次性电脑助手，不维持 runner，不输出密钥，不覆盖现有输出文件。

Probe 使用有限 UIKit 后台短窗；它不能验证正式 Amber 的 continued task 或 Agent 多轮后台控制。普通字号截图已看过；新配对界面与最大辅助字号的最终效果未验收。
