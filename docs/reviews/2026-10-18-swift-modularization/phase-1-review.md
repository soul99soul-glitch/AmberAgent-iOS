# Phase 1 独立审阅

结论：Phase 1 的类型迁移、共享 target、测试迁移和本阶段可取得的模拟器视觉证据均已闭环；未发现可定位到本轮迁移的逻辑或 UI 回归。原 suite 的五处既有失败已在原文件诊断复现，测试按现行契约修正后，完整阶段门禁通过。本审阅未改产品代码。

## 范围和方法

对照 `/tmp/amber-swift-modularization-baseline-20261018-010059/files` 中的原文件与当前工作树，只审 `PlaceholderViews`、`MemoryToolApprovalCard`、`BoardView`、`IOSTerminalRuntime`、`IOSRecipeFileStore`、`IOSRecipeIntegrationTests` 的 Phase 1 迁移，以及四个由 Root 更新的源码路径断言。HEAD 上的用户 WIP 与其他 phase 并行改动未计入本轮。按本仓 AGENTS 约束和一次有限 code-simplifier 检查，追踪入口、状态 owner、跨文件可见性和副作用；未重设计或删除死代码。

## 迁移与调用闭环

- `PlaceholderViews.swift` 只剩真正占位视图。Home、Search、Settings、Workspace、SharedUI 的完整视图类型及布局表达式迁入职责目录；`AppShell` 的 Home、Search、Settings、Workspace 入口继续引用这些类型。逐行对照仅见跨文件需要的 16 处 `private` 类型/扩展声明放宽及各文件 import。
- 审批卡迁入 `Chat/Presentation/Approvals`，主题试穿条迁入 `DesignSystem`。原卡片主体与布局表达式保留；仅共用的 `WebMountApprovalChip` 和 View 扩展放宽文件私有可见性。
- Board 与 DeepRead 迁入各自目录。五个跨文件行视图/组件声明放宽；各新文件补齐 `#if canImport` 和 import。`AppShell` 的 Board、DeepRead detail 路由仍在，视图主体逐行对照未见布局改写。
- terminal 的 `IOSTerminalRuntime` 仍是唯一 `jobs` 字典与状态更新 owner；共享 `remoteSSHTargetDigest` 为供两个 executor 调用而放宽可见性。`IOSAdvancedTaskStore.shared` 的持久化和 AppShell 恢复入口仍连通。recipe/plugin 迁移仅将跨文件使用的 `rank` 放宽可见性，其他实现行保留。
- 检查了本轮 49 个新生产/测试 Swift 文件，均在生成后的 `AmberAgent.xcodeproj` Sources 中；`project.yml` 的 app 与测试 target 按目录收源。四个源码定位测试已指向迁后文件，原关键断言保留。

原 recipe 大 suite 初始迁移保留 45/45 个方法名称、394/394 条 XCTest/断言行，临时目录创建、Room 初始化与 `tearDown` 清理顺序不变。集成发现五个原 suite 同样失败后，测试期待作了有证据的修正：首轮搜索只要求未发布 recipe 不出现；disabled Apple 的策略贯穿执行及审批恢复；过期快照理由匹配当前文案且仍要求无执行记录；双变更账本计入 fixture 写入的 outer pause，并增加两次暂停到完成的顺序断言；WebMount 使用绑定快照的 `wm:` target，分开验证高风险自动批准直接执行和逐次询问预检暂停。生产权限页与执行门对应这些行为。旧 45 项映射记录于 `/tmp/amber-phase1-recipe-test-map.json`，其中 WebMount 原项更名并新增一项，现为 46 项。没有删掉用来保护写入、归属或终态的断言。

## 实际验证与视觉检查

- `/tmp/amber-phase1-final.xcresult`：iPhone 17 Pro、iOS 26.5 模拟器，365 项中 364 通过、0 失败、1 项原有手动性能测试跳过。结果树中五个修正用例及新增 WebMount 用例均通过；长文跟随测试在完整门禁中也通过，阈值未放宽。
- `/tmp/amber-phase1-navigation.xcresult`：真实 app 导航 UI XCTest 1/1 通过。实际打开 `/tmp/amber-phase1-navigation-attachments` 的 Home、Settings、Workspace、Board 四张截图并查 Workspace AX 几何：首页继续卡、会话行及入口；设置分组行；Workspace 统计卡、空态和 Artifact 行；Board 页眉及榜单行，均未见错位、重叠或异常边距。Workspace 截图中返回按钮为 44×44 pt，Artifact 行完整位于 402 pt 窗口内；这是普通字号的真实页面证据。
- `/tmp/amber-phase1-layout-before-shots` 与 `/tmp/amber-phase1-layout-after-shots`：38 对审批卡/站点记忆 `window.drawHierarchy` 截图，覆盖 320/393 宽、普通/辅助功能字号、短聊天容器、八项长变更滚动和明暗模式。逐对比较尺寸与全部像素，38/38 完全一致；实际查看窄屏大字号、长内容底部、生产聊天和深色卡片，审批按钮保持对齐、长内容可滚动到底且按钮可见。320 宽辅助功能字号短视口的上方正文裁切与基线完全相同，本轮没有加重。

DeepRead reader/detail 没有现成任务且未调用真实 provider，本轮只证明 Board 入口与源码迁移保真、相关 pipeline/持久化测试通过，不能宣称正文实际渲染或真实 provider 已验收。Home、Settings、Workspace、Board 的真实页面截图为 iPhone 17 Pro 普通字号；这些页面未逐一在 320/393 与辅助功能字号下实拍。未做真机安装、触感或物理设备验收。
