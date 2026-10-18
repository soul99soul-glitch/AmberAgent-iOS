# Swift 模块化：构建、测试与行数门禁审查

审查日期：2026-10-18。只读检查当前 dirty worktree；HEAD `b98bd6f0f2f82dd9492ff021e53d03bfe26d2dce`。子审没有生成项目、运行构建/测试，也未修改产品源码或构建配置；本报告由整合阶段写入仓库。统计按 Git 跟踪文件加未跟踪且未忽略文件，Swift 物理行数包含空行、注释，既有本地构建和依赖缓存不纳入。主审的最终分类口径：生产 Swift >1000 为 101，测试/fixtures >1000 为 53；>1500 为生产 51 + 测试 29。本子审逐一核实测试超限为 iosAppTests 28 + AmberPhoneControl package 1。

## 结论与必须纳入 plan 的风险

1. **先同 target 按职责重组文件，再评估独立 Swift package。** 当前大量 Swift 跨应用共享靠 XcodeGen source membership，而非已有独立编译模块。主 app 的 `path: iosApp` 自动递归纳入源文件（iosApp/project.yml:60-68），experimental 同样扫描（:438-447）；NovelApp 和 DeepReadApp 则以显式单文件列表共享入口（iosApp/NovelApp/project.yml:35-113、iosApp/DeepReadApp/project.yml:30-44）。例如同时拆 `ChatAssistantMarkdownView`、`IOSAgentToolEngine`、`IOSDocumentExportSupport`、`IOSSearchExecutor` 后，主 app 编译绿不能证明 Novel/DeepRead 仍能编译。按现有 framework/target 先拆的收益更直接，不在这轮引入 KMP 制品独立发布或大量 public interface。
2. **测试本身也存在职责混合，而不只是数据量大。** `ChatViewModelSelectedFileContextTests` 还覆盖 OCR、memory CRUD、search approval 和 WebMount（:126、899、1022、1510、1634）；`IOSLocalToolExecutorTests` 同时覆盖 terminal、grant、WKWebView frame、批量动作、site memory、workspace（:91、338、1213、2098、2976、4139）。应按行为和 owner 拆 suite，保留真实集成链，不能每 1500 行切一刀。
3. **源码字符串接线测试是确定存在的迁移成本。** `ChatMessageProjectionTests.swift:1206-1227` 固定读 `ChatAssistantMarkdownView.swift` 并按 private 类型声明切源码；`NovelSessionReplayTests.swift:389-424` 固定读 `NovelSessionView.swift` 并断言 eager stacks、分离历史/active run；`IOSParityRedLightTests.swift:1821-1832、1922-1959` 根据 coordinator 中函数文本和顺序断言；`IOSSettingsWiringTests.swift:135-139` 按 `#filePath` 上溯两级查源码。移动测试目录或源实现后要同步真实归属路径；既有断言保留原契约，不能把源文本拼成一个字符串让任何层命中即通过。能够通过现有行为 interface 精确验证的断言可等价替换，否则保留有针对性的接线检查，不为行数删除有效测试。
4. **测试 helper 已存在跨 suite 共享，不能只改类名/可见性。** `IOSChatKernelRunHostTests.swift:1476、1503` 引用 `IOSAgentToolEngineTests.InterruptedStreamingProvider/ThrowingProvider`；`IOSPhoneControlHandoffExecutorTests.swift:113` 引用该类 `RecordingLedger`。`IOSPhoneControlSettingsVisualTests.swift:25-27、165-170` 使用定义在 `IOSPhoneControlControllerTests.swift:1440、1487` 的 `ReadinessSessionStub/ReadinessHTTPFixture`。先提取职责明确的测试支持，再迁 suite；跨文件 private extension / fileprivate 不能原样平移。测试依赖只在测试 target 内暴露，不扩大生产 API 为拆测试服务。
5. **独立 Novel 测试的 source membership 是最容易漏的门禁。** NovelApp/project.yml:199-246 显式列 46 个共享测试/支持文件；本次 11 个 Novel 超限测试及 IOSNovelProjectToolExecutorTests 均在列表中。每个拆分必须新增所有测试与 fixture 到 NovelTests；主 app 的 iosAppTests 目录扫描（iosApp/project.yml:260-268）会掩盖此遗漏。
6. **既有 CI 并不完成本次需要的门禁。** `.github/workflows/ios-shared-export-check.yml:40-69` 执行 Shared framework、export 脚本、Python helper 测试、CPython 准备、XcodeGen 和常规模拟器 `build`，没有 Swift XCTest、SwiftLint、Novel/DeepRead 或 experimental 编译。此次应计划一个不依赖 Xcode 的行数检查步骤和按改动 owner 运行测试；不能说已有 CI 足够。
7. **当前未跟踪 `.swiftlint.yml` 与目标冲突，且尚未接入门禁。** :1-3 为数千行集中式文件辩护；:17-19 设 warning 2500 / error 4000；:49-53 只排除 build/.build/Ish resources。后续应在确认用户当前未提交内容后按新目标替换此策略。本轮没有改它。

## 29 个超限测试文件的拆分清单

以下都是建议结果组，不是承诺最终文件名。每个结果组保持单一行为主题，通常 300-1000 行，硬上限 1500；fixture 也遵守同一上限。表中 `file.swift:L` 都是当前源码的真实起点，可用来定位拟迁的行为。

| 当前文件、物理行数 | 建议行为组与源码依据 | 共享/迁移重点 |
|---|---|---|
| ChatMessageProjectionTests.swift — 2624 | message/timeline projection (:536、1522、1748)；composer/input hosting (:134、182、270)；Markdown parse/cache/render (:717、963、1238)；phone grouping 独立现有类 (:2213) | 保留 UI hosting 断言；源码接线测试 :1206 同步新 renderer 路径；phone grouping 已是完整 class 可优先整类迁移 |
| ChatSwiftUIStreamReplayTests.swift — 3132 | replay harness/support (:44-472)；entry/history/switch (:817-1010、2747、2883)；live follow (:1013-1826、2916)；completion/terminal (:1829-2744)；performance replay (:552-769) | :8-20 明确驱动默认 Native timeline，不可改去旧 UICollectionView；保持 @MainActor/window/teardown 和 timing 标准。拆为多类后必须更新 iosApp/AGENTS.md:三套 only-testing 及使用它们的脚本，避免只跑旧类 |
| ChatViewModelSelectedFileContextTests.swift — 2462 | composer/OCR (:8-667)；selected file lifecycle (:668-898)；memory context/tools/approval (:899-1509)；search/WebMount/tool batch (:1510-2030) | :2182 起 provider/transport fakes 按使用者归属；设置/UserDefaults 隔离不变 |
| IOSAgentToolEngineTests.swift — 2460 | core tool loop/budget/approval/catalog (:696-1300)；streaming/terminal/Grok (:1324-1674)；pending handoff/idempotency/human handback (:1684-2207)；sandbox/citation (:2208-2326)；test support (:17-693) | 跨 suite 使用嵌套 provider/RecordingLedger；先变成 EngineTestSupport 中明确命名的 test-only 支持，更新真实引用 |
| IOSChatKernelRunHostTests.swift — 1956 | phone reasoning/progress (:470-778)；terminal/approval/stream upload (:784-1343)；cancellation/handoff/direct image (:1345-1894)；host harness/support (:30-469) | 所有 cancel/handoff 测试继续验证 owner 与 terminal 持久化；复用迁移后的 engine fixture |
| IOSConversationStoreTests.swift — 1587 | selection/visibility/import/resume (:67-710)；durable roundtrip/blob (:711-930)；background merge/stale write/delete/title (:931-1587) | 保留真实持久化重启和竞争写断言；复用同一受控数据库创建/销毁支持，不把整类复制两份 |
| IOSCouncilRunnerMechanicsTests.swift — 3752 | streaming/pacing/follow (:98-769)；live presentation/catalog/settings (:770-1172)；seat planning/research/provider (:1173-1583)；run terminal/ownership (:1584-2317)；resume/archive/checkpoint (:2318-3023)；support (:3285+) | 源码接线断言 :12、54、435 要指向拆后真实 owner；performance sample :2700 保留显式 opt-in |
| IOSJevWebMountLoopTests.swift — 1639 | off/shadow/action/progress/retry (:114-696)；replay/observation cache (:701-1091)；candidate/input/output/injection contract (:1092-1639) | 将 SettingsBox/Recorder 放同域 loop test support；保留 unknown 不重试和 scope 下调的行为用例 |
| IOSLocalToolExecutorTests.swift — 4763 | generic permission/grant (:29-471)；shell/workspace/terminal (:91-294、4139-4480)；station/URL/redaction (:472-840)；WK runtime/frame/read/target (:841-1749)；session ownership/TTL (:1750-2093、2626-2975)；batch action (:2098-2625)；site memory (:2976-3490)；visual read/approval/handoff (:3491-4036) | `MockWebMountRuntime` :4590 和 cookie :4565 按实际复用提取 WebMountTestSupport；保留真实 WKWebView 测试，不替换成假的 executor pass-through |
| IOSNovelProjectToolExecutorTests.swift — 1653 | project/material/plan operations (:232-415、770-999)；chapter reads/edits/deletes (:416-769)；proposal/ghostwrite guards (:1002-1485)；adapter assembly (:1488-1616) | harness :10-229 抽到 NovelProjectToolTestSupport；同时更新 NovelTests 显式 source 列表 |
| IOSOrchestrationToolTests.swift — 2540 | spawn/bootstrap/capacity (:294-982)；model routing/shadow (:983-1508)；list/interrupt/terminal mailbox (:1511-2154)；linked conversation/scope (:2159-2539) | background fake :16、fixtures :52-291 复用；保持 run conversation 非当前 selection 的 owner 断言 |
| IOSParityRedLightTests.swift — 2181 | DeepRead/Council route parity (:130-352)；credentials/backup/redaction (:366-1347)；recovery/background terminal (:441-612、1399-1966)；foreground FIFO (:1967-2047) | 不再往“parity”大杂烩里增测试；保留每个原 test identifier 的迁移映射和 security 断言，源码检查 :1348、1820、1921 精确更新 |
| IOSPhoneControlControllerTests.swift — 1577 | configuration/pairing/app query (:8-656)；readiness (:657-849)；handoff ownership (:850-1139)；external transport (:1140-1316) | ReadinessSessionStub :1440 和 HTTPFixture :1487 已被视觉测试消费，提为 PhoneControlReadinessTestSupport；各 fake 仍有独立 registry/port |
| IOSPhoneGoalLoopTests.swift — 1632 | listed/legacy execution and budgets (:8-507、712-794)；live goal flow (:508-711)；sequence (:795-1104)；Jev candidate/failure/recovery (:1205-1632) | Fixture :1105 不复制；保持未知结果与无效目标时零 dispatch 的契约 |
| IOSRecipeIntegrationTests.swift — 3268 | recipe lifecycle/validation (:26-150)；plugin security/health/runtime/signature (:151-1098)；recipe hot-reload/version pin/rollback (:1099-1621)；approval/checkpoint/handoff (:1622-2282)；fixtures/manifest builders (:2283-2969) | :2295 tempRoot 和 :2311 Room DB 初始化的顺序保留；不要把所有 fixture 抽成另一个 3000 行 Utils |
| IOSSkillMcpToolsTests.swift — 1838 | builtin seed/upgrade (:16-343)；skill import/use/soul transaction (:344-857、1328-1447、1496-1617)；MCP import/config/schema/catalog/test (:858-1327、1448-1495、1556-1617) | 低成本按 skill/MCP 两个 owner 先拆，再抽 shared fixture；保留 stale base/candidate 与 disabled network 用例 |
| IOSWebMountDesktopBackendTests.swift — 2010 | gateway transport/schema/mapping (:64-311、491-780)；semantic targets/approval/stale identity (:312-490、781-1079)；remote session/postcondition/ownership (:1080-1752)；MCP/runtime fakes (:1753+) | visual evidence :1340 与网络 stub suite 可分；异步 resolver gate :1753 保留 race 实现 |
| NovelCollaborationModeTests.swift — 2660 | mode/plan contract (:5-345、488-1050)；ghostwrite single/batch flow (:346-487)；highlights/arc/budget (:1066-1235、2312)；quality/continuity/retry/resume (:1236-2095)；next plan proposal (:2096-2311) | 同时覆盖 Novel app；Fixture 内容按计划/ghostwrite 分组，测试生产完整章收录与事实同步的组合不拆断 |
| NovelContinuityAuditTests.swift — 1810 | audit planning/evidence/chunk/decode (:18-679)；repair planning/apply/runtime (:682-957)；ViewModel owner/cancel 独立现有 class (:1477+)；fixture/model samples (:958-1476) | 现有 NovelContinuityAuditViewModelTests 可整类迁；不混新 UI owner 与 audit adapter |
| NovelCreationPresentationTests.swift — 1591 | copy/presentation/IME (:6-619)；composer/actions/material/collection (:620-1175)；composition/history/selection (:1176-1499) | 字符串展示验证保留；UIKit marked text 行为与模型纯投影分开，独立 actor fake :1500+ |
| NovelCreationViewModelTests.swift — 2541 | chapter draft ownership (:6-204)；selection/draft/busy/list (:205-572)；background inventory (:573-785)；material/branch/import/export (:786-1152、2052-2276)；quickstart (:1153-1606)；state-sync (:1607-2051) | :2277+ gates 按用例群归属；保留 original project/branch late callback 防串写断言 |
| NovelFactTransactionLifecycleTests.swift — 2951 | collect/adjudication/atomic commit (:6-289、680-1341)；manual repair/timeouts (:290-679)；manual chunks/model policy/retry (:1342-1799)；cancel/expiration/final persistence (:1800-2016)；evidence normalization (:2017-2300)；fixture/support (:2301+) | Test-owned repository :2819+ 与 Harness 分属事实事务支持；phase 可拆文件但不把一个原始 transaction integration test 切成多个近似断言 |
| NovelGenerationLifecycleTests.swift — 2752 | start/terminal/ask-user/proposal (:5-492)；cancel/start races (:493-802)；durable Responses cursor/detach/resume (:803-1385)；persistence/recovery/reservation (:1386-2136)；support (:2139+) | 已有 ScriptedNovelModelAdapter 在 NovelTestSupport.swift:41，优先复用；私有扩展 :2139 与私有 actor :2378+ 跨文件迁移需最窄 test module visibility |
| NovelGenerationReducerTests.swift — 1534 | begin/complete/proposal/ask-user (:8-491)；interrupt/failure/replay/validation (:492-1158)；fixture builders 独立 | 纯 reducer suite 拆成 generation transition 与 receipt/validation 两个主题；不要为了低于阈值压缩 fixture 字面量 |
| NovelLiveModelAdapterTests.swift — 1866 | route/provider/policy/request preparation (:31-389、793-986)；stream/tool loop (:390-792)；cancel/durable response lifecycle (:987-1329)；fixture/providers (:1330+) | KMP/Codex/Grok/Gemini 分发仍用原真实入口；这是 adapter stub 测试，不能表述成真实 provider 验收 |
| NovelManualEditSyncTests.swift — 1595 | request/repair/evidence (:7-430)；immutable working revision/commit/shape (:431-1064)；receipt compatibility/pending identity (:1065-1125)；fixture builders | 聚焦手改同步契约，shared builders 与 NovelFact fixtures 只有真实共用才合并 |
| NovelSessionReplayTests.swift — 2803 | pacing/buffer/graphemes (:6-388)；history/archive/projection (:389-932)；candidate/polish/retry actions (:933-1995)；follow/viewport/history window (:1996-2540、2769+)；Fixture (:2541+) | #filePath 源码接线检查分散多处（:389、2127、2157、2384、2489、2505），搬目录和生产文件时必须一起迁 |
| NovelSessionViewModelTests.swift — 5713 | archive/identity/composer (:8-406)；performance/window hosting (:407-729)；stream/tail/ask-user (:730-1740)；attach/stop/branch/route ownership (:1741-2759)；quickstart/recovery (:2761-3300)；collect/manual-sync (:3301-4063、4265-4332)；chapter approval (:4064-4264)；retry/polish/regeneration (:4333-4785)；fixtures/gates (:4788+) | 当前一个文件超过 9 个行为族；不要生成 SessionTestsPart1...。大 fixture :4819 只抽共同 session assembly，special race actors :5299+ 按主题归属，layout harness :4789 留 performance 支持 |
| Packages/AmberPhoneControl/Tests/AmberPhoneControlTests/PhoneRunnerClientTests.swift — 2098 | signing/token (:10、18、1881)；observe/ref/element action/alerts (:39-694)；guards/unknown/shutdown/concurrency (:696-1288)；screenshot/settling (:1297-1550)；visual gestures (:1551-1880)；fixture (:1903+)；已有 timing class (:2089) | 保留每个 request 数量、动作 unknown 不重试断言；FixtureProtocol registry :2037+ 只抽一份，维持端口隔离；package 自有源和测试同受1500门禁 |

## 构建和模块的事实地图

- Xcode 项目是生成物，README.md:124-138 写明 XcodeGen/JDK17/CPython；`.gitignore:26-29` 忽略 `.xcodeproj`、`.xcworkspace`、DerivedData 和 build。更改 `project.pbxproj` 不是持久配置修复，必须改对应 `project.yml` 并生成。
- 正规/experimental app 都依赖 `Shared.framework`（iosApp/project.yml:230-249、640-660），prebuild 通过 `./gradlew :shared:link${build_type}Framework${kotlin_target}` 生成（:107-129、516-538），postbuild 自本仓 shared/build 复制（:139-159）。`shared/build.gradle.kts:47-68` 规定 dynamic framework 是 bundled SQLite native symbol 的链接约束。
- 当前自有本地 SPM 只有 `AmberPhoneControl`（iosApp/Packages/AmberPhoneControl/Package.swift:4-11），iOS26/macOS14 同时可用。另一个本地 package `vendor/SwiftStreamingMarkdown` 是 vendor integration（iosApp/project.yml:47-48）。不能把它计作已建立全 app feature package 架构。
- Activity widget 单文件共享在 iosApp/project.yml:300-305、340-345；Watch 共享文件在 :736-745、770-779；PhoneControlProbe 单独引用 PhoneControlRuntime 和 package（PhoneControlProbe/project.yml:10-21）。移动共享源要逐一保持 membership 和平台可编译性。
- NovelApp 的 `PRODUCT_MODULE_NAME: iosApp` 在 project.yml:129，所以共享测试 `@testable import iosApp` 在 Novel scheme 下仍正确；不能为了目录整理随意更名 module。DeepRead 是独立 module `AmberDeepRead`（DeepReadApp/project.yml:53），其共享 test 显式列表在 :120-122。
- 默认主 scheme tests 是 iosAppTests（iosApp/project.yml:255-268）；IntelligentUI UI tests 属于单独 `IOSIntelligentUIAcceptance`（:804-822），常规 `test` 通过不会自动证明这条 UI 验收跑过。

## 1500 行硬门禁建议

1. 用独立 Python 标准库脚本做唯一物理行数判断，不把成功条件依赖于 SwiftLint 版本、嵌套配置、disable 注释或忽略 comment-only 选项。输入：`git ls-files -z --cached --others --exclude-standard`，去重、跳过不存在文件，只处理 `.swift`；计数 LF 换行且末尾无 LF 的最后一行仍计一行。输出路径、行数、所属 owner；发现 >1500 非零退出。
2. 覆盖生产、tests、fixtures、UITests、App/Watch/Widget/Probe/Runner、本地 package 的自有 Swift。不能只扫 `iosApp/iosApp`。当前所有 vendor Swift 最大 928（ParagraphUIView.swift），没有必要为达标借第三方豁免；全仓 tracked vendor 也可直接检查并在表里单独报告。忽略的 DerivedData、SourcePackages checkouts、build/KMP 生成物不属于源代码库存。任何未来生成 Swift 例外必须列明确路径、生成入口和理由，不能把难拆自有文件改名为 Generated 来逃避门禁。
3. 批次迁移期间可有一次基线清单（80 个现有 >1500 路径，记录当前最大行数、owner、移除批次/期限），新增超限文件立即失败，存量不得继续增长；某个文件完成拆分立刻去掉其基线条目。最后一期移除全部存量基线，门禁零超限，不把基线变永久许可。
4. SwiftLint 可保留一般 lint，同时将 `file_length` 与 1500 保持一致、预警约 1200；它作为编辑期提示，硬验收以独立脚本为准。只改 `.swiftlint.yml` 不等于已实施门禁；脚本接 CI，workflow paths 应覆盖脚本自身与规则配置（当前 workflow :6-15 没有 `.swiftlint.yml` 路径）。
5. 目录划分/文件数量不是完成标准。验收还要有旧文件职责→新文件职责的映射、owner 未改变、编译目标 source membership 完整、test identifiers 迁移清单、全量行数结果。不要通过压缩空行注释、源码拼接生成、无语义 `PartN` extensions 达标。

## 建议实施顺序与验收计划（以下命令均未在本轮运行）

先冻结 dirty baseline，记录目标源/test 内容与 git diff；在用户批准实施后再做各批。先建行数报告/限期存量清单和多 target source membership 核对，随后测试按 owner 随生产批次迁移。大 suite 的公共 test support 可以先独立迁一批，为生产拆分提供稳定观察面。每批仅一项职责迁移，保留行为，编译+定点 XCTest，最后仅本 diff 做有限维护性 review。

项目生成（对应使用了共享源的目标都生成）：

```bash
xcodegen generate --spec iosApp/project.yml
xcodegen generate --spec iosApp/NovelApp/project.yml
xcodegen generate --spec iosApp/DeepReadApp/project.yml
```

主 app 定点测试（实际运行前从可用模拟器中固定 destination；新拆出的所有 suite 都应列入）：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/<受影响Suite> test
```

聊天滚动/布局/投影/Markdown 仍须遵守 iosApp/AGENTS.md 原门禁：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:iosAppTests/ChatSwiftUIStreamReplayTests \
  -only-testing:iosAppTests/NativeTimelineScrollCoreTests \
  -only-testing:iosAppTests/ChatViewportPolicyTests test
```

如果 `ChatSwiftUIStreamReplayTests` 拆成新类，则这一命令必须改成涵盖所有 replay 行为组，或者改用一个包含所有这些类的 test plan；保持老类名的命令通过而新类未执行不算通过。拆分前后测试方法清单要一一对应（允许合理类名变化，不删、跳过或改断言逃绿）。

独立产品与 package：

```bash
xcodebuild -quiet -project iosApp/NovelApp/AmberNovel.xcodeproj -scheme Novel \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:NovelTests/<受影响Suite> test
xcodebuild -quiet -project iosApp/DeepReadApp/AmberDeepRead.xcodeproj -scheme DeepRead \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:DeepReadTests/<受影响Suite> test
swift test --package-path iosApp/Packages/AmberPhoneControl
```

常规与 experimental 编译至少在相应共享/条件编译批次运行，最后全项集成执行（同时覆盖 app 的 Watch/widget 依赖）：

```bash
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosAppExperimentalGPL \
  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO build
```

只在实际改变 KMP/runtime/storage/导出或 Swift 消费接口时加对应 Gradle `jvmTest` 与 Shared bridge 验证，不机械为纯 Swift 文件搬迁跑全 KMP suite：

```bash
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64
python3 scripts/check_shared_export_reachability.py
./gradlew :<受影响模块>:jvmTest --tests '<对应测试类>'
```

`check_shared_export_reachability.py:27-44、47-69` 读取已构建的 `Shared.h` 验证 10 个类型族，是必要的桥检查但不是所有导出的完整证明。Swift app 编译和实际消费入口仍要验证。

若真的改 vendor Markdown，先遵守 vendor/AGENTS.md，再运行该 package Makefile:52-57 的 iOS `xcodebuild test`；它包含 UIKit 路径，不能用主机 `swift test` 泛称验证。PhoneControlProbe/Runner 仅源修改影响它们时生成并 build-for-testing，真实 XCTest runner/UI permission/同机 tunnel 另属设备验收。

本轮结论边界：完成静态源码/配置/测试组成 review；没有运行重构后构建、XCTest、真机安装、provider 或性能验收。后续纯文件组织如果保留界面/状态 owner，也仍应按高风险聊天、小说存储恢复、后台交接、真实 provider 分类给证据，不能把行数全绿替代行为证明。
