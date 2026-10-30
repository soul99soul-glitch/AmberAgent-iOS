# 搜索工作交接（用户纠正范围后停止）

用户说明搜索由另一 session 同步 review，本组停止继续搜索实现与审计，转向 Amber 整体非搜索审查。所有已落修改保留，未回滚其他工作。

## 已落修改

- Phase1 设置/KMP：SearchServicesView、SearchProviderView、IOSSharedSettingsStore搜索段、Settings/IOSSharedAgentFeatureSettings getter、IosSettingsMutations.removeSearchService；IOSSearchExecutor的Jina必需Key及selected/fallback免费总开关gate；新IOSSearchSettingsTests/KMP IosSettingsMutationsSearchTest与IOSSearchExecutorTests对应断言。
- Phase1独立复审通过；真实 `:shared:jvmTest --tests shared.IosSettingsMutationsSearchTest` 6场景通过。Swift只parse/source harness，无App XCTest。
- Phase2部分：ChatLocalToolOperations搜索权限owner、ChatToolApprovalCompletion批准传递、ChatToolExecutorAdapters后台/novel gate、ChatAdvancedToolOperations旧子代理、ChatRecipeExecution步骤gate。此包被中断，未完整验证；native搜索出口和Novel hook未实现。仅要求作者收口自身中断时的runner作用域编译问题及parse，随后停止。
- Phase3：IOSFreeSearchAggregator、IOSGoogleWebViewSearch、Search/IOSSearchHTTPTransport、IOSVerifiedHTTPScrapeTransport普通公网分支remaining deadline；新IOSSearchNetworkRegressionTests。尚未完成独立复审，不算验收通过。
- 两个新增Swift测试文件尚未加入pbxproj，本组未运行xcodegen。

## 明确剩余项

1. dedupeKey最后对完整URL裁尾`/`，`?next=/`与`?next=`仍会误去重；应仅处理path，保留query语义。
2. verified HTTPS传递剩余deadline补丁已落，但未验证。
3. Google父取消到全部redirect网络请求缺直接执行证据；aggregator迟到成功已改抛取消并有host证据。
4. Phase2搜索权限未完成native出口及整体调用链测试；请接续审查，不把半成品认定完成。
5. Xcode/CoreSimulator版本不匹配导致App XCTest无法启动；未安装/运行/真机验收。

## 证据

- `/tmp/amber-search-audit-20261025/validation-status.md`、`phase1-kmp-green.log/.xml`。
- `/tmp/amber-search-audit-20261025/kmp-remove/` 原函数精确抽取red4/修后green6；`phase1-kmp-red.log`仅为启动命名，内容实际修后通过，不是red。
- `/tmp/amber-search-audit-20261025/route-check.swift` 验证Jina与免费gate真实源函数；真实匿名Jina POST401证据`jina-no-key.*`。
- `/tmp/amber-search-network-audit-20261025/` 原网络复现；`/tmp/amber-search-phase3-green/`修后host证据（限额1/2不再Google、URL case保留、聚合取消、DNS约0.104秒取消/0.214秒超时）。
- `/tmp/amber-search-audit-20261025/permissions/` 原权限红证据。
- `/tmp/amber-search-audit-20261025/SourcePackages`为本仓完整依赖cache的隔离APFS副本，可用于后续generic iOS编译；没有改原cache或系统。

## 后续非搜索集成构建的诊断

最终generic iOS编译在主App阶段失败（exit65），唯一当前compiler error是搜索session新建的 `iosApp/iosApp/IOSSearchProviderCredentialEditor.swift:41:54`：`AmberSectionLabel(text: provider.name)` 将String传给LocalizedStringKey。可机械改为 `AmberSectionLabel(text: "\(provider.name)")`。本组按用户“搜索由另一session负责”的边界，准备了 `/tmp/amber-full-review-20261025/search-compile-only.patch` 并请求单行跨scope授权，尚未应用。

完整日志 `/tmp/amber-full-review-20261025/validation/final-generic-ios.log`，Shared Native构建已通过。修复这一行后可复用本轮隔离DD/SPM缓存增量编译；首轮测试target尚未编译，不能把非搜索修复等同于App构建完成。
