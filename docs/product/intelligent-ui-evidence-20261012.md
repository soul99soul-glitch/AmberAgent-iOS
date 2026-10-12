# 智能 UI：任务界面、生成预览与参数联动

日期：2026-10-12。源码、独立审查、受影响测试及最终签名构建已完成。最终版尚未安装到真机：设备状态为 unavailable，CoreDevice 返回 4016，无法取得连接及电源断言。真实 provider、真机卡片操作和完整持久化验收仍未通过。

## 本轮交付

- 在原有 80 种组件上增加 form、explore、study，与 decision 一起支持四类任务。学习内容直接在消息内翻卡、答题、判分、重练；填写与浏览任务不要求选择虚构方案。
- Agent 提示按任务判断是否使用原生界面。明确要求智能 UI 的时间线请求不会再被旧 SVG 强制规则拒绝；普通 SVG、HTML、PPT 等明确媒体请求保留原路径，拒绝智能 UI 的请求也保留原行为。
- 生成中逐段显示已经收到、结构闭合且通过校验的内容和真实项目数量。预览只读，不保存草稿或注册活动来源；成功终态后才开放操作。重写、取消、失败和来源切换均清理预览。
- 本卡数字字段可直接驱动指标、比例、步骤进度、柱状图和折线图。预览初值不算用户填写；非法输入显示原因并阻止提交，不将错误数值画成零。
- 学习与数值交互复用原有来源隔离、草稿保存、显式提交和 agent 继续链路。实际修复了答案显示对比度、非法学习项提前预览、数字精度丢失、父标识覆盖子控件，以及窄屏大字号图表与步骤标签截断。

计划与原则见 [实施计划](intelligent-ui-adaptive-plan.md)。

## 实际验证

| 验证 | 实际结果 | 证据与范围 |
| --- | --- | --- |
| 默认配置的任务、状态、提交、生成预览、参数联动及规定聊天回归 | 236 通过，0 失败，2 跳过 | `/tmp/amber-task-ui-process-final-regression-r3.xcresult` |
| 最后一处步骤标签修复后的视觉及四个规定聊天类 | 109 通过，0 失败，1 跳过 | `/tmp/amber-task-ui-final-caption-regression.xcresult`；320pt OCR 确认“上限”和“复盘”均可见 |
| 实际系统 UI 控件验收 | 5 个案例闭环 | r3 的 3 个案例通过；两个查询失败修复后 r4 2/2 通过。覆盖来源、禁用提交、学习操作、数字联动、重置及显式提交 |
| 各阶段独立 review | 已完成并修复确认问题 | 协议、状态、调用链、生成预览、数值绑定及代表性视觉分别复核 |
| 最终 GPL Release | succeeded，0 errors，48 warnings | `/tmp/amber-task-ui-final-device-build-r2.xcresult`；代码签名 strict/deep 验证通过 |
| 最终真机安装、启动与设置对照 | 未执行 | 安装前设置快照读取被 CoreDevice 4016 阻断，设备仍 unavailable |

两个默认跳过项分别为显式开启的 reasoning 性能采样，以及 hosted 单元测试无法激活的旧 AX 案例。实际系统 UI 用例另行验证了代表性生产控件，但固定 DEBUG fixture 不使用真实 provider，也不替代磁盘持久化和真机验收。

Shared 主题路由的定点 JVM 测试此前 14/14 通过；Study 持久化验收脚本的离线自检此前 10 组通过。后者只是工具自检，实际两轮 provider 及落盘产物 gate 尚未执行。

## 最终产物与设备边界

产物：`iosApp/build/IntelligentUIAdaptiveDevice/Build/Products/Release-iphoneos/iosAppExperimentalGPL.app`。

主可执行文件 SHA256：`64f30534b6b6a1620c01449ee0cd3d9a56a0eb3627c0a96f240107f44db70ed2`。

正式 Bundle ID 为 `app.amber.ios`，App Group 为 `group.app.amber.ios.watchkit`；主 App URL 为 `amber`，Watch URL 为 `amber-watch`。签名、Watch companion identity、entitlement 诊断镜像均核对通过。Release 中没有专用 AX fixture 标记，构建前后本轮生产源码哈希一致。

此前四类任务的中间版已原位安装并正常启动；该记录见 [中间版交付](intelligent-ui-evidence/adaptive-20261012/interim-device-delivery.json)。它不包含本轮最终的生成预览、数值联动和最后修复，不能算最终版已经装机。

真实 provider 仍有独立阻断：模拟器复制的配置仅包含脱敏凭据，无法用于实际调用；此前真机 XCTest runner 在测试方法开始前与 IDE 断开。没有改用其他 provider 或修改用户配置来代替验收。

最终构建身份、测试计数和设备状态见 [结构化记录](intelligent-ui-evidence/adaptive-20261012/final-verification.json)。本轮没有提交或推送，也没有操作公共 Git index。

## 视觉证据

- [收到第一组件](intelligent-ui-evidence/adaptive-20261012/stream-preview-first-object.png)、[收到第二组件](intelligent-ui-evidence/adaptive-20261012/stream-preview-second-object.png)、[成功终态后的正式任务卡](intelligent-ui-evidence/adaptive-20261012/stream-preview-authoritative-terminal.png)。这些是生产 renderer 的分片回放。
- [学习卡复习](intelligent-ui-evidence/adaptive-20261012/task-ui-study-review.png)、[测验反馈](intelligent-ui-evidence/adaptive-20261012/task-ui-study-quiz-feedback.png)、[实际点击后的来源与提交](intelligent-ui-evidence/adaptive-20261012/native-study-frozen-receipt.png)。
- [数字输入更新后的图形](intelligent-ui-evidence/adaptive-20261012/task-ui-numeric-changed-to-689-three-steps.png)、[非法输入](intelligent-ui-evidence/adaptive-20261012/task-ui-numeric-invalid-number.png)、[320pt 暗色辅助功能字号](intelligent-ui-evidence/adaptive-20261012/task-ui-numeric-dark-accessibility-320pt-689.png)、[实际点击与显式提交](intelligent-ui-evidence/adaptive-20261012/native-numeric-graphics-and-submit.png)。

截图检查包含对齐、边距、尺寸和长文本，未将 hosting 截图或 DEBUG fixture 当作真实真机体验证明。生成预览的纯计算微测见 [成本记录](intelligent-ui-evidence/adaptive-20261012/streaming-preview-cost.txt)，它不证明完整 SwiftUI 或 provider 性能。
