# Jev 与 iPhone 自动化独立复核

日期：2026-10-11。四位 subagent 使用 GPT-6.1 Sol、high reasoning、priority 服务档，分别检查规范与维护性、需求与逻辑、生产调用链、UI 实际渲染。

范围为前一轮 Jev 实现相对任务起点的 33 个文件，已从既有手机控制 WIP 中隔离，见 `build/jev-review-20261011/task-only.patch`。HEAD 为 `69c2144`，未提交或推送。旧工作区内容完整保留。

## 确认并修复的问题

### P1：混合历史中的手机参数绕过专用数据范围

关闭手机 Jev 用途及 `phoneContent` 后，若普通 `file_read` 结果触发通用压缩保留判断，历史里的 `phone_act.expectation`、`phone_run_goal` 参数仍会被写入请求大纲，包含界面 label/value。旧实现只排除了手机结果候选，没有排除大纲参数。

修复在 `IOSJevContextSelection.swift` 的大纲构造入口：手机工具仅保留名称和结果字数，参数正文不进入通用请求；普通工具参数、结果采样和保留判断保持原行为。

两项混合历史回归分别覆盖 phone_act 与 phone_run_goal，均检查 Shadow/Active 下普通结果实际触发一次请求、普通样本仍存在，以及手机参数/结果标记不出现在 HTTP body。旧实现测试失败，修复后通过。请求由受控 transport 接收，本轮未向真实 Jev 服务发送数据。

### P2：等待期间更改设置后，短循环接受新配置继续派发

旧循环每次选择前重新读取配置 revision。在只读等待期间更改设置但保持 Active 时，下一轮会接受新 revision，继续执行动作，违反“设置变更终止本次调用”的约定。

修复在 `IOSPhoneGoalLoop.swift`：固定调用开始时的 revision，将其纳入已有 `canContinue()`；移除逐轮重新接受 revision 的逻辑。选择等待、效果等待、观察返回、效果建议返回与派发前使用同一约束。已完成步骤和 typed unknown 回执保留。

回归在 waitingForUI 回调中增加 revision，同时保持 Active 和 owner 有效；要求返回 handback、无动作、无步骤、不再请求下一次选择。旧实现失败，修复后通过。

## 分项结论

| 维度 | 结论及证据边界 |
| --- | --- |
| Standards | 未发现证据充分的规范问题。修复后仅做一次有限维护性复核，未追加抽象、配置或恢复状态机。 |
| Spec | 等待期间配置变化问题已修复。目标核验、候选唯一定位、步数/时间预算、Shadow 不派发与 unknown 停止链已静态复核并运行受影响测试。 |
| 调用链 | 已追踪设置持久化 → Jev 门控 → 前后台目录/executor → runner → 新观察核验 → 工具结果与 Ledger/Activity。手机参数出站问题已修复。未发现本轮新增的旧 run 覆盖、unknown 后续派发或自动重放路径。 |
| UI | 已看中文、320pt AX3、俄语 AX1 设置截图，以及新增“选择下一步”“等待界面更新”锁屏卡片，未发现确认的错位、重叠或截断。新用途 Off/Active/缺范围 fixture 单独渲染；最终截图结论见 `build/jev-review-20261011/ui.md`。 |

UI 首轮模式 fixture 复用 store，前一窗口延后的退出提交可能覆盖下一组配置，造成 Active 图与固定版本输入不一致。已改为各组独立 store/suite，并在渲染后检查实际模式与范围。这个问题属于测试夹具，不据此修改产品 UI。

决策与等待阶段的紧凑灵动岛本轮未成功捕获，不能按文件名认定通过；锁屏两阶段有有效系统渲染截图。菜单点按、VoiceOver、真实阶段切换及后台表现未在本轮验收。模拟器预览已结束。

## 实际验证

- Red：3 项新行为回归按预期失败，视觉测试通过；`red-and-ui.xcresult`。
- Green：89 项受影响测试全部通过，包含完整 GoalLoop、ToolRetention、JevPhoneControlService、JevSettings、PhoneControlToolExecutor 测试类；`green.xcresult`。
- 隔离模式 fixture 后视觉测试再次通过，含渲染后状态断言；`ui-final.xcresult`。最终模式截图在 `ui/settings-final/`。
- `git diff --check` 通过。未修改 KMP 或 runner package，未重复无关测试。
- `iosAppExperimentalGPL` Release 构建及严格签名校验通过，原位安装到 iPhone 的 `app.amber.ios`，正常启动并确认进程指向新安装路径。
- 安装前后会话文件元数据均为 368 项，无丢失、增加或大小变化；未读取消息正文，未卸载 App。

详细结果目录：`build/jev-review-20261011/`。独立审阅记录为 `standards.md`、`spec.md`、`callchain.md`、`ui.md`；机器可读交付记录见 [jev-review-20261011.json](../iphone-control-evidence/jev-review-20261011.json)。

## 尚未证明的行为

本轮没有自动启用新增 Jev 用途/出站范围，没有更改手机 VPN，也没有从 Mac 启动手机控制。真实 Jev 延迟、手机内导航/草稿填写、后台多轮运行和灵动岛动态变化仍需实际任务验收。发送/付款等交回主工具链属于工具使用约定，当前没有新增 tap 语义分类器。
