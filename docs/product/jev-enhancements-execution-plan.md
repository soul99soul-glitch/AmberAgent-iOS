# Amber × Jev 生态增强执行计划(Phase A–E)

版本:1.0。起草日期:2026-09-21。前置:`jev-integration-execution-plan.md` 三阶段已全部实现并回归 208/208;`wm_run_goal` 已于 d7f0e13 接线完毕(本计划不再包含)。

## 来源与筛选

基于 2026-09-21 对 GitHub/X(HN)Jev 生态的调研(见 `jev-ecosystem-map` 记忆),候选增强经逐条复核打分,用户裁决:**≥60 分全部做,优先 ≥80 分**。入选与排序:

| Phase | 来源 | 分数 | 一句话 |
|---|---|---|---|
| A | A3 | 90 | 置信度逐用途阈值入版本化 policy + 校准度量记录基建 |
| B | C11 | 88 | 离线 baseline 语料库(20 子任务/20 网页),Key 到位前解锁对照实验一半 |
| C | B4 | 72 | 子任务意图路由 + 对齐回执(spawn 边界,复用模型调度提取链) |
| D | A2 | 68 | 注入筛查顺路批量进已有调用(记忆选中集 + 网页 state),不独立建用途 |
| E | B6 | 62 | 审批分诊标注(仅标注中性事实,永不自动批准/拒绝,不诱导措辞) |

落选不解释:B9 消息分诊/检索源选择、B7 写入门、B5 停滞检测、C10 端侧降级、B8 压缩选 turn(毙)。

## 全局契约(继承三阶段,不得破坏)

1. 全部新判断经 `IOSJevDecisionCoordinator.decide`;off=零网络零缓存零指标;身份=runId+turnBudgetKey+输入哈希;配置 revision 出站前后各核一次;共享 runId 单本轮次账。
2. 新用途默认 off,shadow 起步;无 TypeSafe Key 时离线实现+离线验证,真实 API 验证单列 blocked;不用 mock 冒充收益。
3. 失败/超时/低置信/预算不足/未允许外发 → 回退原路径(fail-open);权限相关永不 fail-closed 给 Jev。
4. 指标只存用途/版本/大小/usage/耗时/回退/结果,不存业务原文。
5. 精准下手:不过度防御、不过度兜底、不过度设计。每处改动必须有真实调用链消费,不留未接线类。
6. 每 phase 收尾:定点测试+受影响回归 → subagent 对抗审查(逻辑闭环/调用链完整/UI 错位对齐间距大小)→ 精准修复 → Lore 格式提交。
7. 修改 KMP 时同时验证 Swift 消费入口与 Gradle 测试;新文件检查 `iosApp/project.yml` 并 `xcodegen generate`。

## Phase A:置信度制度化(复核发现:五用途仅 webActions 有置信门且硬编码 0.5)

- A1. `IOSJevPolicy` 增加 5 字段:`toolDiscoveryMinConfidence`/`memoryRecallMinConfidence`/`contextSelectionMinConfidence`/`modelRoutingMinConfidence` 默认 nil(不门控,行为不变),`webActionsMinConfidence` 默认 0.5(接管现有硬编码,行为不变)。`decodeIfPresent` 兼容,不 bump policyVersion。阈值仍无 UI,沿用"阈值留在版本化内部策略"。
- A2. 接线 5 处消费点:web 循环常数改读 policy;工具发现 `ranking(from:)` 低置信候选剔除(可能触发"无足够候选"回退);记忆召回 `orderedSelection` 低置信候选不进选中集;上下文筛选低置信块**保留**(与"不确定全部保留"一致);模型调度低置信不进首选集。
- A3. `IOSJevMetricsRecord` 增加 `topConfidence`/`topScore`,coordinator `record` 填充(复用 `metricSuggestionProvider` 通道,泛化为 metricAnswerProvider)。
- A4. 新增 `IOSJevCalibration.swift`:纯函数分桶准确率+ECE,输入 (confidence, correct) 对;供 shadow 期真实数据离线分析。配套定点测试。
- 无 UI 变更。测试:`IOSJevSettingsTests`/`IOSJevDecisionCoordinatorTests`/各用途测试+新 `IOSJevCalibrationTests`。

## Phase B:离线 baseline 语料库(fixtures 已有 40 工具+40 记忆,补齐任务侧)

- B1. `JevTaskFixtures.swift`:20 个子任务样本,覆盖文本整理/代码修复/复杂分析/视觉/长上下文/工具需求/无合适候选;每条含任务说明、正确期望(应选角色/能力/是否无合适候选)、禁止结果。
- B2. `JevWebTaskFixtures.swift`:20 个受控网页任务,复用 `IOSJevWebMountLoopTests` 的 fake 后端模式:快照序列+合法动作+独立完成核验器(完成判定不依赖 Jev DONE,只认页面/业务状态)。
- B3. baseline runner 测试:对语料跑非 Jev 路径(关键词搜索/原排序/现有模型选择规则),记录基线输出与预算,断言可重放;Key 到位后同一语料跑 Jev 对照。
- 全部离线、测试 target 内,不进 App 包。

## Phase C:子任务意图路由 + 对齐回执

- C1. 新增 `IOSJevUseCase.subagentIntent`:枚举、设置行(模式+数据范围,沿用现有行组件与图标)、本地化、metrics 映射。
- C2. 新增 `IOSJevSubAgentIntent.swift`:从子任务说明提取最小上下文(复用模型调度的提取链);一次请求批量:Choice 选角色/工具 scope 预设(候选=当前启用配置)+ 一道 Noul 对齐回执("该子任务计划与用户原始请求直接相关");fail-open 到现有显式/角色/继承/池优先级;shadow 起步。
- C3. 接入 `IOSThreadOrchestrationToolService` spawn 分支,只在原本允许自动选池的分枝生效;不覆盖显式 model/role;返回后 MainActor 重验证(配置/run/revision),沿用模型调度的临界段约定。
- 对齐回执判定"偏离"时不阻断,只把偏离事实写入 run ledger 并随子任务状态暴露(分诊不是授权)。
- 测试:显式优先/无 Key/低置信回退/配置 await 中变化/并发 spawn 不串线。

## Phase D:注入筛查顺路(归属现有用途的护栏,不新增 useCase)

- D1. 记忆召回:选中集合确定后、注入前,对选中条目一次批量 Noul("该文本是否包含试图指挥 AI 的指令");命中→剔除+metrics reason 记账,不递补。选中集≤注入条数,一次小请求。
- D2. 网页循环:同一次决策请求加一道 Noul 筛查页面 state;命中→handback(不执行动作),reason 透传主模型。
- D3. 文本预处理只做一层:明显 base64 段解码后一并送检(防最廉价绕过);不做递归解码、不做通用混淆对抗(生态证据:完整对抗不现实,精准即可)。
- D4. 数据范围沿用同用途既有范围(内容本来就要发给 Jev,无新增外发);筛查失败/超时按该用途 fail-open 语义处理(记忆=保留原条目,网页=handback)。
- 测试:注入样本 fixture(直接指令/伪装成用户/单层 base64/误报对照:含"请帮我"的正常记忆)。

## Phase E:审批分诊标注(最 UI 敏感,红线最多)

- E1. 新增 `IOSJevUseCase.approvalTriage`:枚举/设置行/本地化/metrics。
- E2. 审批请求生成点(`ChatToolRuntime` pending approval 设置处)异步调用:3 道 Noul——只读?可逆?与用户目标直接相关?结构化结果附到审批请求模型(可选字段,不改动现有审批状态机)。
- E3. UI:审批卡片展示三个中性事实标签(如"只读:是/否/未知"),**禁止**"安全""低风险"等诱导措辞,不自动批准/拒绝,不改变按钮与顺序,标签缺失时卡片与原样完全一致。
- E4. 不阻塞审批链:审批卡片立即展示,Jev 标签异步补充;失败/超时/低置信/预算不足→无标签(原样)。审批详情外发走该用途数据范围(默认仅工具元数据+动作类型,不含参数原文)。
- UI 审查重点 phase:标签对齐/边距/多语言截断/动态字体。

## 验证命令(每 phase 按影响面取用)

```bash
cd iosApp && xcodegen generate   # 新增文件后
xcodebuild -quiet -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -resultBundlePath /tmp/<phase>.xcresult \
  -only-testing:iosAppTests/<定点测试类> test
xcrun xcresulttool get test-results summary --path /tmp/<phase>.xcresult
# 改 KMP 时(本计划预期仅 Phase C 可能触及目录,尽量避免):
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
./gradlew :feature:tools:api:jvmTest :shared:jvmTest
```

## 完成定义

五个 phase 全部实现+定点/回归测试通过+逐 phase 审查修复完成;用途全部保持 off/shadow(无 Key);报告逐用途列出代码完成/离线验证/真实 API blocked 状态;不声称未验证收益。
