# Phase5 Main iosAppTests baseline / 集成选择器

范围：只筛选本期 13 个生产文件的直接 API 消费者、状态与持久化回归，以及必要的跨域接线。源代码当前还在多阶段集成中；这是执行清单，不是已通过记录。选择器 JSON 是按顺序排列的 XCTest **类名字符串数组**。

合计 38 个类、约 644 个 `func test…` 声明；声明数不是 Xcode 实际执行数，继承、条件与运行时跳过以 `.xcresult` 为准。所有类均在当前 `iosAppTests` 源码中找到。

| 消费者 / 风险 | 选择器（当前声明数） | 必须复核的行为 |
| --- | --- | --- |
| Provider 页面、凭据与设置写回 | `ProviderRegistryStoreTests` (16), `IOSSharedSettingsStoreProvidersWriteBackTests` (30), `ProviderCredentialAndHeaderTests` (8), `IOSSettingsWiringTests` (31) | ProviderDetailView、IOSSharedSettingsStore：服务与模型选择、凭据/自定义 header 保存、失败回滚、Keychain 引用清理、设置到运行时接线。`IOSSettingsWiringTests` 含源码字符串约束，迁移后核对语义再更新路径。 |
| 运行环境与系统权限 | `IOSRuntimeStatusToolTests` (11), `IOSSystemPermissionCoordinatorTests` (7), `IOSPermissionsStatusSnapshotTests` (11), `IOSPermissionStoreTests` (8) | RuntimeEnvironmentView、IOSPermissionModels、IOSSystemPermissionCoordinator：权限状态与前置条件、禁用/不可用、策略持久化；真实系统弹窗仍需设备或模拟器单独验收。 |
| MiniApp Runner 与异步桥接 | `IOSMiniAppBridgeRuntimeTests` (33), `IOSMiniAppSystemSDKTests` (5), `IOSMiniAppDeviceCapabilitiesTests` (10), `IOSMiniAppRepositoryTests` (23), `IOSMiniAppVisualEvidenceTests` (3), `IOSMiniAppThemeBridgeTests` (6) | MiniAppRunnerView：首次打开/恢复、桥接与设备能力权限、关闭时异步返回、撤销、源文档信任失效、主题与窄屏截图；截图断言不能代替目视。 |
| 生成式 Widget 解析 | `IOSGenerativeWidgetParserTests` (36), `IOSGenerativeWidgetSanitizerTests` (12), `IOSGenerativeWidgetPayloadDetectorTests` (7) | IOSGenerativeWidgetParser：流式识别、HTML/SVG 完整性与消毒、终态 repair，不让危险内容穿过解析边界。 |
| 文档、压缩与会话持久化 | `DocumentAccessStoreTests` (36), `IOSContextCompactionCoordinatorTests` (18), `IOSConversationStoreTests` (37), `IOSConversationStoreBranchingTests` (18), `IOSConversationStartupTests` (3), `IOSConversationRecapStoreTests` (8) | DocumentAccessStore、IOSContextCompactionCoordinator、IOSConversationStore：导入/编辑/删除与索引写失败回滚、压缩边界与失败降级、跨会话写入、分支、冷启动和旧结果隔离。原 `IOSConversationStoreTests` 37 项整类保留。 |
| SharedSettings 其余消费者 | `IOSSharedSettingsStoreSkillWriteBackTests` (7), `IOSSharedSettingsStoreCouncilSeatTests` (4), `IOSSharedSettingsStoreSubAgentOverrideTests` (6) | IOSSharedSettingsStore：MiniApp 选项、Council 席位与 SubAgent 覆盖的写回、重启恢复与删除；与 Provider 写回组互补。 |
| Council 运行与归档 | `IOSCouncilRunnerMechanicsTests` (89), `IOSCouncilRoomArchiveStoreTests` (18), `CouncilSourceMaterialsTests` (6) | CouncilChatRuntimeView、CouncilRunner：运行状态、任务与发言归属、终态、归档失败/恢复、素材输入；原 `IOSCouncilRunnerMechanicsTests` 89 项整类保留。 |
| 后台生成和 run 归属 | `IOSChatBackgroundExecutionTests` (9), `IOSChatBackgroundStaleSweepTests` (9), `IOSChatBackgroundPhoneActivityTests` (1), `IOSBackgroundCompletionMergeTests` (8), `IOSChatKernelRunHostHandoffTests` (15), `ChatViewModelConcurrentConversationTests` (4) | IOSChatBackgroundGenerationCoordinator：handoff/取消/过期、checkpoint、前后台恢复、迟到回调与 run ID 归属，避免旧 run 覆盖当前会话。 |
| 跨域 Home、Theme 和源码纪律 | `HomeDesignContractTests` (18), `AmberThemePackTests` (67), `PerformanceHygieneTests` (6) | Home/Theme/Settings/source guards：继续工作入口、主题应用/持久化、Provider 和 MiniApp 主题接线、SwiftUI 状态与主线程纪律。源码字符串测试拆分后需看实际契约，不应为了绿灯删断言。 |

## 执行方式

先完成 Phase5 源文件与测试拆分、重新生成 Main 工程，再在仓库根对当前类名运行一次集成选择器。若 worker 拆分类，更新 JSON 中对应类名并保持原覆盖语义；不要把文件名误当类名。

```sh
xcodegen generate --spec iosApp/project.yml
python3 - <<'PYRUN'
import json, subprocess
classes = json.load(open('/tmp/amber-phase5-test-selectors.json'))
cmd = ['xcodebuild', '-quiet', '-project', 'iosApp/AmberAgent.xcodeproj', '-scheme', 'iosApp', '-destination', 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0', '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES']
cmd += [f'-only-testing:iosAppTests/{name}' for name in classes]
subprocess.run(cmd + ['test'], check=True)
PYRUN
```

指定 simulator UDID 时不要同时传 `-arch`。`test` 会构建 Main 及其依赖；选择器结果不能替代最终 Main 全单测或 Novel/DeepRead/GPL/Watch/Widget 消费者门。

## 手动及 opt-in 边界

- `IOSCouncilRunnerMechanicsTests` 有 `AMBER_PERF_SAMPLE` 控制的 Time Profiler 采样方法；常规运行跳过它，报告应按 `.xcresult` 记实际执行/跳过。其他性能采样也使用此变量。
- `IOSLiveProviderSmokeTests` 需 `AMBERAGENT_IOS_LIVE_OPENAI_API_KEY`；`IOSIntelligentUILiveProviderTests` 和 UI acceptance 需 `AMBER_TASK_UI_LIVE_PROVIDER=1` 且应用配置可用模型。这些不在自动选择器中，真实 provider 行为另验。
- 免费搜索和网页抓取分别由 `AMBER_LIVE_FREE_SEARCH=1`、`AMBER_LIVE_PUBLIC_SCRAPE=1` 显式开启；不属于本次 Phase5 静态/本地回归。
- UI acceptance 的 fixture/bootstrap 使用 `AMBER_TASK_UI_COMPONENT_FIXTURE=1`、`AMBER_TASK_UI_UI_BOOTSTRAP=1`；本矩阵中的 `IOSMiniAppVisualEvidenceTests` 生成截图附件，但需目视核对。真机权限、后台运行时长、键盘和真实 provider 不由单测证明。
- `IOSChatBackgroundSuspensionTests.swift` 定义的类是 `IOSChatBackgroundStaleSweepTests` 和 `IOSChatBackgroundPhoneActivityTests`；`IOSGenerativeWidgetParserTests.swift` 同时定义 Parser 与 Sanitizer 类。

## 范围证据

来自当前 `iosApp/iosAppTests` 的类声明和测试方法；`iosApp/project.yml` 中 `iosApp` scheme 绑定 `iosAppTests`。本文件仅为只读分析产物，未运行构建或测试，也未修改仓库源码。
