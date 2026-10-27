# Amber macOS 实施计划与进度

更新：2026-10-23。八阶段主链均已推进实现和受影响验证，随后[全面复核](comprehensive-review/review.md)又按四阶段修复六个确认问题，最新共用 Swift Runtime 253/0、正式 Swift 104 文件语法检查通过；此前 Kotlin/JVM 82/0，本轮未重跑。最新 Preview 构建、UI 与交付证据以该复核目录为准，下面保留原八阶段历史。正式 Native 集成仍有环境阻塞，尚不能标记产品正式完成。范围见 `validation.md`，差距编号见 `ios-parity-todo.md`。

## 目标与范围

在本独立 iOS/KMP 构建根内，以 iOS 已有消费者为依据，完成原生 macOS 聊天、会话与文件、工具任务、知识、协作及数据管理。目标为 Apple Silicon、macOS 15+。Shared.framework 继续由本仓 Gradle 生成，AmberAgent Core 尚未独立发布。

明确排除小说创作、深度阅读、小应用、WebMount 及其专属运行时。手机控制、Watch、Live Activity、AlarmKit、NFC、iSH 和 iOS 嵌入式 Python 不作为 Mac 通用功能验收项。

## 八阶段状态

“实现”指真实入口已接到状态、持久化及消费者；单测、Preview 实拍和正式 Native 验收分别记录。下表不以隔离测试关闭正式目标的验收门槛。

| 阶段 | 已实现与复核的主链 | 当前验收状态 |
| --- | --- | --- |
| Phase 1 · 基础与数据契约 | 本地 KMP Mac 聚合模块；canonical 会话/parts/隐藏变体透传；旧 Mac/iOS 会话导入；流式终态、保存失败与原会话归属；顶部遮挡修复 | Swift 与 Kotlin/JVM 隔离验证、独立 review 及 Preview 窗口通过；正式 Shared/Header/链接/provider 待验 |
| Phase 2 · 完整聊天工作区 | 编辑、删除、重生成、变体；摘要初载与按需全文；全库搜索/定位；预算、回顾/建议/压缩；Markdown 代码/表格/数学与阅读偏好；生成中文本指令队列 | 测试及独立逻辑 review 通过；队列按工具轮边界消费，普通文本在终态后发新请求；Preview 已验聊天/搜索/压缩，860×600 浅深色审批/队列/输入区及宽窗阅读离屏复核通过，整窗交互仍待解锁检查 |
| Phase 3 · 服务商与模型 | 多服务商/多模型、目录发现/连接测试；OpenAI Chat/Responses、Claude、Gemini；OAuth、参数、标题/视觉等辅助模型实际路由与搜索设置 | 配置/请求分派有隔离测试，Preview 已验真实设置草稿与模型切换；外部账号、Keychain 与正式协议请求待验 |
| Phase 4 · 文件与成果 | 图片/文档解析、拖放/剪贴板、预览；真实生图适配与系统语音入口；KMP 原始附件 parts；会话文件库；Markdown/PDF 可读导出与 canonical JSON 导出 | 文件/解码/路径/保存/owner/取消测试通过；Preview 已验真实文本附件到发送/文件库；新图片及 PDF 分享待最终窗口复核，视觉模型调用待 Native |
| Phase 5 · Agent 执行 | 复用原 iOS engine 的工具发现、逐调用审批、多轮回填；工作区读写/删除、网页搜索/抓取、真实 shell；任务记录、停止与审批恢复 | 工具/取消测试与独立链路 review 通过；副作用及下一模型轮前必须获 canonical 写盘确认；真实模型—工具完整往返待验 |
| Phase 6 · MCP/Skills/记忆 | 真实 MCP HTTP/stdio；技能导入/启停与调用范围；Soul、长期记忆、来源、召回/审批；持久 ID 高水位 | MCP 真子进程与知识持久化测试通过；Preview 已验中文记忆保存；Skills/Soul UI 与外部服务实际消费待验 |
| Phase 7 · 子代理/议会/Recipe | 多模型子任务/Council、并发/超时/取消、持久 run；父会话成果文件与消息；Recipe 复用同一 executor/审批/台账 | 协作/Recipe 测试、owner/幂等保存及独立 review 通过；新界面已类型检查，Recipe/协作面板离屏布局通过；原生交互和真实多模型运行待验 |
| Phase 8 · 持续使用与交付 | 备份恢复副本、可选密码加密、WebDAV 备份传输；窗口/退出生命周期；通知终态消费者；真实磁盘用量及阅读/主题偏好 | 取消/rollback/错误密码/引用重映射测试通过；Preview 已实际导出并恢复副本；通知/用量/同步新 UI、正式权限/Release/安装待验 |

## 必须保持的闭环

- 未打开会话不伪造空 `messages`；操作先加载完整文档，全文搜索查持久库。
- canonical KMP 消息为存储源；Swift 投影不重建媒体/工具/变体。压缩只改变请求副本。
- 生成、附件、工具、协作、文件、错误均捕获原 owner。切会话、删除及迟到回调不能串写或复活会话。
- `persistTurns` 按 run token 保存原历史与新增 turns，只等待对应串行 writer。消息写失败不确认；metadata 失败保留 owner 错误但不误阻已落盘消息。
- 生成中队列只接文本，绑定原 owner/run；撤回恢复草稿，停止/失败保留可见，已提交但未写盘单独显示并仅重试保存，避免重复发送。
- 停止允许 engine 排出最后 canonical partial；退出取消并等待已接受生成、附件、协作保存、Recipe、备份快照及写盘任务。备份快照独立登记，避免遗漏或 self-await。
- 文件限制在会话目录，拒绝越界及符号链接穿越；原子写入，覆盖遵循工具参数；真实落盘后才发布成功。
- 恢复先验证/暂存，再创建新会话与模型 ID；失败/取消回滚本次副本。记忆 ID、来源会话及已知 canonical citation 定点映射，不泛替换数字。
- 备份不含 Keychain。记忆用新 ID 合并；Skill/Soul 等显式导入启用，通用偏好作为资料待手动应用，不覆盖当前配置。
- 通知仅在已启用且结果写盘成功后发送；取消不通知，普通生成与工具任务不重复。磁盘用量后台扫描真实路径，内存会话不估成磁盘文件。

## 复核与精准修复

各阶段均已交独立子代理检查逻辑、调用链和可运行 UI。已修复实际定位的顶部遮挡、窄窗对齐、附件并发、文件错误归属、临时预览失效路径、图片导出遗漏、剪贴板编码扩展、密码语义、记忆 ID 重用、备份取消等待及工具前效持久确认。同源 Preview 已构建并签名；860pt 原生组件检查定位的审批滚动空白与队列挤压输入区已改为自然参数摘要/全文弹层及三态队列摘要/弹层，未增加最小高度或偏移；六张最终同源离屏图已独立逐张复核通过，含浅深色非 key 停止按钮对比与真实恢复长状态；Mac 锁屏继续阻塞整窗交互、toolbar、弹层和 Knowledge/Settings Tab 验收；未获正式目标证据的条目继续待验。

不新增平行 provider/执行器、泛化文件版本框架或空同步开关；不改指定排除模块与用户已有 iOS WIP。

## 剩余正式验收

1. 运行 Gradle JVM/Native 任务，产出真实 Shared.framework，验证 header 与正式 Swift 消费。
2. 在 AmberMac 验证各协议、图片输入、工具审批/多轮、MCP 与多模型协作。
3. 补齐 Keychain、文件授权、通知、关闭/退出写盘、最小/默认/宽窗、明暗和长流式检查。
4. 完成受影响 iOS engine/备份网络消费者的 Xcode 回归。当前 manifest 缓存写权限与 CoreSimulator 服务不可用阻塞该步。
5. 完成 Release/本地安装与签名验收；Developer ID/公证按实际分发方式另验，ad hoc 签名不能替代。

Gradle 当前在 FileLockContentionHandler 创建 socket 即报 Operation not permitted，未进入工程编译。官方 standalone Native 缺 Mac 第三方 KLIB，下载受现有代理阻断。此限制保留为验收债，不以 Preview 或替身 framework 绕过，也不再串行阻止其余阶段实现。

重复入口：`macApp/scripts/test-runtime.sh`、`macApp/scripts/test-provider.sh`、`macApp/scripts/build-preview.sh`、`macApp/scripts/build.sh test`。执行范围和日志见 `validation.md`。
