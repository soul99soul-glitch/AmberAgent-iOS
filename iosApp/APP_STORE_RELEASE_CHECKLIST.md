# Amber iOS App Store 发布清单

这份清单只记录代码无法替代的 Apple 账号、域名和审核动作。仓库内的静态发布
基线由 `scripts/validate-release-readiness.sh` 持续校验。

## 账号与签名

- [x] 在 Xcode 登录有付费 Apple Developer Program 团队权限的账号（2026-09-15 已验证）。
- [ ] 为 `app.amber.ios`、`app.amber.ios.activity`、`app.amber.ios.watchkitapp`、
  `app.amber.ios.watchkitapp.widgets` 创建并确认 App ID；实验 GPL target 不进入
  App Store 构建。
- [ ] 四个稳定版 target 使用同一个付费 Team。开发装机使用 Development 签名；
  TestFlight 导出/上传使用 App Store Connect 分发签名，不使用 Personal Team。
- [x] 主 App、Watch App 和 Watch Widgets 的 App ID 均关联
  `group.app.amber.ios.watchkit`（2026-09-16 已补齐主 App 绑定）。
- [x] 本次分发已刷新 provisioning profile，并验证主 App、Watch 和 Widget 的签名
  包含对应 App Group entitlement。
- [x] 在 App Store Connect 创建 `AmberAgent` App 记录并匹配 `app.amber.ios`。
  App ID 为 `6812412419`，见 [TestFlight](https://appstoreconnect.apple.com/teams/68ed2ac5-9fb2-4b47-96c3-108768e0b08c/apps/6812412419/testflight)。

## TestFlight 首次上传

1. 在 Xcode > Settings > Apple Accounts 登录已加入 Apple Developer Program 的账号，
   确认有目标 Team 的上传权限；在 App Store Connect 创建或找到 `app.amber.ios`。
2. 以 `project.yml` 为配置来源，运行 `xcodegen generate --spec iosApp/project.yml`
   （以下命令均从仓库根目录执行）。使用稳定版 `iosApp` scheme，Archive 配置为 Release。
3. 确认主 App 的现有 entitlements 在开发者后台可用，包括 HealthKit、CloudKit、
   Push Notifications、Sign in with Apple、App Attest、Journaling Suggestions 和
   WeatherKit。CloudKit container 为 `iCloud.app.amber.ios`。
4. 设置实际 Team ID 和未上传过的构建号后归档；命令行参数会统一主 App 和扩展的签名
   Team、构建号，避免只修改生成的 Xcode 工程后被下次生成覆盖。

   ```bash
   # 先设置 AMBER_TEAM_ID 和 AMBER_BUILD_NUMBER，再运行以下命令。
   xcodebuild -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath build/testflight/AmberAgent.xcarchive \
     -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
     DEVELOPMENT_TEAM="${AMBER_TEAM_ID:?set the paid developer Team ID}" \
     CURRENT_PROJECT_VERSION="${AMBER_BUILD_NUMBER:?set an unused build number}" archive
   ```

5. 在 Xcode Organizer 打开归档，选择 Distribute App > App Store Connect，完成验证和
   上传。Apple 处理完成后，在 App Store Connect 的 TestFlight 页面完成出口合规并
   分配测试组。外部测试的首个构建需要 Beta App Review；内部测试者必须是有访问权限的
   App Store Connect 用户。

`CODE_SIGNING_ALLOWED=NO` 的归档仅验证编译和包结构，不能作为已经完成 TestFlight
签名或上传的证据。初次上传前核对所有嵌入 App/扩展的版本号和构建号一致。

Apple 官方说明：[上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)、
[TestFlight 流程](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)。

### 2026-09-16 首次上传记录

- `AmberAgent 1.0.0 (1)` 已上传，Apple 处理及出口合规已完成；个人内测组状态为“正在测试”。
- 首次外部测试已填写 Beta 描述、审核联系信息和测试重点并提交，当前“正在等待审核”。
- 已补齐 `NSHealthUpdateUsageDescription` 和小说文档类型的 `LSHandlerRank`；两项对应
  发布检查包含失败反例验证。
- 已核对四个分发签名 bundle 的完整 Release entitlements、生产环境、版本、描述文件
  和嵌套签名，并补入匹配 UUID 的 Shared.framework dSYM。
- CPython/stdlib 原制品缺少可恢复的 dSYM，Apple 返回非阻塞符号化警告。
- 使用未签名归档导出时，必须先保留源码 entitlements 再让 Xcode 分发重签；直接导出
  会丢失 App Group、HealthKit、CloudKit 等能力。优先使用正常签名 Archive 流程。

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
