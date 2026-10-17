# iOS timeline 富媒体交付计划

目标：搜索图片、独立视频卡片与 Markdown 配图可在默认 NativeChatTimelineView 使用，媒体加载和失败不改变预留尺寸，用户阅读历史时不抢滚动位置。复用 UIMessagePart、现有消息存储、原生预览及滚动策略。

授权：实现、测试、模拟器运行及逐阶段 subagent review；不提交、不推送、不新增系统权限。保护原有通知相关三个文件的未提交修改。

## Phase 1：搜索图片与通用图片展示

- 打通搜索 provider → 工具结果 Text.metadata → 持久化消息 → timeline 图集；保留模型可读摘要与图片来源，不把所有搜索缩略图作为模型视觉输入。
- 复用 Image / metadata，明确来源、标题和稳定身份；通用工具图片不依赖 generate_image 特例。搜索用 display-only metadata，其他原生工具图片仍用 Image。
- 固定比例图片容器、多图横向排列、全屏预览、加载失败和重试。生成图片保留既有专属操作。
- 验证搜索解析/调用输出、消息投影与尺寸；subagent 审查链路和 UI，修复已复核问题后进入下一阶段。

## Phase 2：视频卡片与播放

- Video part 单独可显示、可与文字混排；封面、播放按钮、可用标题/时长及来源。
- 用户点击才创建系统全屏播放器，关闭停止，保持 timeline 原卡片和滚动身份；失败可见且能重试。
- 支持提供给 Video part 的可播放 HTTP(S)/受支持本地媒体；普通网页链接仍走来源网页，不假装可播放。
- 验证数据入口、播放器生命周期和卡片尺寸；subagent 审查并修复。

## Phase 3：Markdown 配图与整体稳定性

- 完整 Markdown 图片语法转换为原生媒体块，保留前后文字、链接图片与代码块字面内容；流式未闭合语法不提前发请求，稳定块不随每个 chunk 重建。
- 用户图片、搜索图片和 Markdown 图片加载前后预留框稳定；缩略图按显示尺寸后台降采样，限制缓存开销。
- 验证流式/终态、历史重开、来源打开、重试、横竖图和长文本/动态字号；subagent 审查并修复。

## Phase 4：整体验证与交付

- 运行受影响定点测试与项目规定的 streaming replay / native scroll / viewport 三组回归，完成模拟器 build 和视觉检查。
- 每阶段记录实际检查、review 结果和精准修复；最终仅对本轮 diff 做一次有限可维护性审查。
- 检查现有用户 WIP 未改变。报告构建、模拟器、真机及真实 provider 验收各自证据，不把未测项目说成通过。

## 进度

- Phase 1 实现与独立静态 review 完成，模拟器验证进行中。图片来自 Brave、Tavily、Exa、Serper news、SerpAPI organic/news 的明确响应字段。前台、审批、后台均保存 metadata。review 修复了共享布局 modifier 访问级别和 body JSON 解码问题。首轮编译发现链接 helper 作用域错误，已改为媒体模块的 HTTP(S) helper；尚未把测试标为通过。
- Phase 2 实现与独立静态 review 完成，模拟器验证进行中。MCP 标准图片内容及明确 MIME 的视频 resource_link 接入 typed output。review 发现并修复：Video 未进入模型正文、长 JSON 截断丢媒体、封面重试嵌套播放按钮。内嵌 video blob 显示资源说明，不转换成巨大 data URL。
- Phase 3 实现与独立静态 review 完成。复用真实 AST，历史 StateObject 初始计划预留媒体高度；完整段落后提升流式图片。普通文字/图/文字按顺序拆分，复杂 inline 格式、列表、引用和表格保留原容器后附媒体。review 修复了格式标记残片、未提升 autolink/相对图丢失及空 alt 暴露源码的问题。
- Phase 4 唯一一次有限可维护性审查完成，无需新增框架。额外闭环视频音频：接既有 keep-alive suspend/resume owner，同串行后台队列配置播放 session；复用既有 session epoch 防旧 keep-alive 清理停掉新视频，覆盖取消/重试/失败和迟到清理回归。
- 全部本任务代码冻结，正在执行最终原项目统一验证（17 个受影响测试类，包含项目强制三组 streaming replay/native scroll/viewport）。待保存测试结果、模拟器截图与各 reviewer 的视觉复核；尚未声称真机或真实 provider 验收通过。
- 并行工作说明：初始 HEAD 为 657976c3，原有通知 WIP 三文件 SHA256 已在本轮工具输出保存，并在外部写入前复核一致。外部任务随后将包含本轮富媒体文件的内容混合提交于 0c746ced，又提交 99233fb0 并继续 PhoneControl 工作。本任务没有执行 commit/push/reset/stash/clean；不回滚外部提交，不覆盖通知、Live Activity 或 PhoneControl 改动。
