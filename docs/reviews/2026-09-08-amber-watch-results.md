# Amber Watch：成果首页落地与复查

日期：2026-09-08。

用户选定暖白纸页成果卡。原生首页现在将真实任务结果放到首位，以黑底、暖白卡片、铜橙状态和主按钮呈现；近期动态保存终态与记事，当前运行或等待回答的任务仍优先。已有草稿、记事、快捷动作和设置保留，主提问按钮在首页底部始终可见。

## 数据与操作闭环

1. 手机的 WatchTaskCoordinator 在真实终态发布时先记录历史，再判断当前 run 所有权；旧 run 的完成不会抢走新 run 的当前操作。
2. IOSWatchCompanionService 原子保存最多 20 项终态，runId 去重，重复发布不改写首次完成时间；每次库更新投影最新 10 条。Watch 记事独立标明来源和同步状态。
3. 可选 activities 字段兼容旧 payload；WatchConnectivity 的既有序列与缓存机制继续传输完整 library。Widget 缓存仍去掉 library 和结果正文。
4. 手表按时间显示活动。已读版本以 epoch 秒数保留子秒精度，重启不丢；兼容缺字段的已发布缓存和开发过程中 ISO 日期格式的缓存。
5. 详情路由直接持有活动值，列表更新不会换掉正在看的结果；追问和手机接力沿用原 conversationId。读过不删除结果。
6. 冷恢复只承认 durable run 的明确终态和 finishedAt。缓存摘要仅在 runId、终态都一致时复用，不拿后来消息冒充结果。

## 独立复查与修复

- UI reviewer 查看原始参考及实际 40mm／46mm／大字号截图，发现并推动修复了插画挤窄标题、主按钮离开首屏的问题。最终复查无新增 P0/P1/P2。
- State reviewer 新增 11 项行为测试，主线程补上子秒读标记和旧日期迁移 2 项测试；没有用源码包含某字符串代替行为验证。
- Chain reviewer 检查终态落库、传输、缓存、详情、追问和接力。旧任务摘要的边界通过准确匹配缓存增强；不能准确关联的旧任务继续用通用状态。
- 主线程解决了 KMP callback 直接跨 actor 返回非 Sendable AgentRunEntity 的编译问题；回调内提取不可变 Swift 值后再交给主 actor。

## 验证结果

- 第一轮定向集：96 项通过，0 失败。
- 收尾复跑：34 项通过，0 失败；包括最后新增的日期兼容迁移与匹配缓存摘要恢复。共 98 个不同用例通过，并非将两轮数量相加。
- 覆盖 Watch 状态/存储、手机伴生服务、通信顺序与超时、冷启动、任务操作与后台生命周期、通知。未改 KMP provider/runtime/storage 行为；主应用测试仍通过仓库现有 Gradle 阶段生成 Shared。
- 实验 Watch App 与 Widget 已在 40mm、46mm 模拟器构建运行，视觉详情见 [design-qa](../../design-qa.md)。六语言新增文案与 JSON 解析、git diff --check 通过。

测试日志：

- `/Users/mi/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/logs/test_sim_2026-09-08T10-45-40-432Z_pid63831_9c8d5d3c.log`
- `/Users/mi/Library/Developer/XcodeBuildMCP/workspaces/ios-396633e5a58a/logs/test_sim_2026-09-08T10-53-44-531Z_pid63831_8941ba22.log`

首轮 MCP 调用在 300 秒超时，但本地 xcodebuild 继续执行，日志明确记录 96 项通过及 TEST EXECUTE SUCCEEDED；没有把外层超时直接算为通过。收尾由 MCP 返回 34 项全通过。保留仓库既有非 Sendable closure 和无效 discardableResult 编译警告。

## 覆盖边界与设备状态

- 实时摘要来自现有 WatchTaskCoordinator 的聊天、后台任务及接入该协调器的成果。独立功能的专用成果页没有因新增历史自动全部接入。
- 不具备可靠摘要关联的旧 durable run 只恢复状态、时间和可获得的会话标题。历史摘要至多 280 字；全文走手机原会话。
- 视觉截图使用隔离 DEBUG 夹具；中段和底部通过默认滚动锚点取证。CUA 点击尝试遇到 AXError.cannotComplete，没有将其视为真实手势导航成功。
- 本次连接查询中，iPhone 和 Apple Watch 均为 paired、Developer Mode Enabled、device unavailable；新版本真机覆盖安装尚未完成。此前已安装的 iSH 实验版及音频保活设置沿用，未读取或重写整份偏好文件。
- 本轮没有新增依赖、提交、推送，也没有覆盖无关 MiniApp 工作。

主要变更：WatchTaskRootView、WatchResultCard、WatchTaskViewModel、WatchLocalStore、WatchTaskModels、IOSWatchCompanionService、WatchTaskCoordinator、Localizable.xcstrings、纸页图片资源，以及对应行为测试和产品文档。

## 真机产物准备

- iPhone 实验版 generic iOS 构建成功：`/private/tmp/amber-watch-results-phone-build.log`。
- 配套 Watch generic watchOS 构建成功：`/private/tmp/amber-watch-results-watch-build.log`。
- Bundle ID 分别为 `app.amber.ios`、`app.amber.ios.watchkitapp`，用于覆盖既有安装。
- 两个包均通过系统钥匙串环境下的 `codesign --verify --deep --strict`。沙盒内首次检查返回 trust 服务错误，使用系统信任服务只读复核后均为 exit 0，没有更改证书或信任设置。
- iPhone 包含 IshEmbed/CIshEmbed 构建依赖及 fs 资源；最终 Info.plist 含 audio、processing 后台模式。现有音频开关偏好由此前安装保留，本轮没有重写。
- 最后设备查询仍显示两台物理设备 unavailable，因此本轮未执行覆盖安装；构建包已保存在 `iosApp/build/ExperimentalDeviceBuild/Build/Products/Debug-iphoneos/iosAppExperimentalGPL.app` 与 `Debug-watchos/AmberWatchAppExperimentalGPL.app`。
