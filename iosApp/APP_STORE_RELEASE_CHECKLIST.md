# Amber iOS App Store 发布清单

这份清单只记录代码无法替代的 Apple 账号、域名和审核动作。仓库内的静态发布
基线由 `scripts/validate-release-readiness.sh` 持续校验。

## 账号与签名

- [ ] 在 Xcode 登录已付费的 Apple Developer Program 个人账号。
- [ ] 为 `app.amber.ios`、`app.amber.ios.activity`、`app.amber.ios.watchkitapp`
  创建并确认 App ID；实验 GPL target 不进入 App Store 构建。
- [ ] 在 Signing & Capabilities 中选择同一个 Team，确认真机安装和 Archive 均使用
  Distribution profile，而不是 Personal Team。
- [ ] 在 App Store Connect 创建 Amber App 记录并匹配主 bundle ID。

## 能力开通（按路线图阶段）

- [ ] Phase 1：主 App ID 开启 HealthKit；真机确认步数读取授权。
- [ ] Phase 2：如启用 WeatherKit、Associated Domains，分别在 App ID 和目标中开通；
  Universal Links 上线前部署并验证 `apple-app-site-association`。
- [ ] Phase 3：建立生产 CloudKit container；如启用 Sign in with Apple、APNs、App
  Attest，先准备对应服务端校验链路和生产密钥。
- [ ] Phase 4：在 App Store Connect 创建与代码 product ID 一致的订阅，并完成付费
  App 协议、税务与银行信息；将公开可访问的隐私政策 HTTPS 地址写入 Info.plist
  的 `AmberPrivacyPolicyURL`（自定义条款可写入 `AmberTermsOfUseURL`）。缺少隐私政策
  地址时，App 会保留恢复购买但关闭新订阅购买。

## 隐私与审核材料

- [ ] 用 Release Archive 生成 Privacy Report，核对主 App 和第三方 SDK 的 manifest。
- [ ] 根据实际上线的 provider、CloudKit 和通知链路填写 App Privacy；本仓库不会替
  App Store Connect 猜测或代填收集声明。
- [ ] 隐私政策明确说明：HealthKit 数据仅在设备本地展示，不进入模型上下文、日志、
  备份或 CloudKit；HealthKit 数据不用于广告、画像或出售。
- [ ] 准备 HealthKit 授权前说明页、设置页、订阅页的审核截图与审核备注。
- [ ] 提交前在真机验证首次授权、拒绝、设置中撤销、离线、后台恢复、购买恢复。

## 发布门槛

- [ ] `xcodegen generate` 后 Debug 和 Release 构建通过。
- [ ] 受影响单元测试通过；稳定版包内无 `audio` background mode、无宽泛 ATS 例外。
- [ ] TestFlight 内测至少覆盖 iPhone 与 iPad；Watch companion 如随包发布则同时验证。
- [ ] App Store Connect 的出口合规、内容权利、年龄分级、支持网址和隐私政策网址均
  已填写且可公开访问。
