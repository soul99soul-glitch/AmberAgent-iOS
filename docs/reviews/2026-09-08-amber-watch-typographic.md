# Watch 文字成果卡与连接状态修复

当前设计以用户最后选定的深铜文字稿为准，替代此前暖白插画方案。所有截图都标明模拟器或真机来源，测试样例不是生产默认内容。

## 改动与数据契约

- 成果卡使用深铜渐变、细描边、暖白粗体标题、摘要和轻量完成图标。移除插画及其宽度竞争，标题使用完整内容宽度；预览最多两行，摘要一行，详情与辅助功能标签保留原文。
- 首页使用原生系统时间，品牌行不再额外占据导航工具栏的一行。46mm 卡片约 192×118 pt，顶部约 42 pt；近期动态为无底色入口，主按钮约 40 pt 高。40mm 与放大字号保留滚动访问，不能把它们描述为三项始终同屏。
- `WatchRecentActivity.resultTitle` 是可选的成果元数据；小应用生成成功并保存后才从 `IOSMiniAppRecord.title` 传入。前台、后台与保存期间过期的成功路径均接入；会话标题仍保留，普通任务回退到真实会话标题。
- 已保存的同 run 成果名在冷恢复中保留。旧记录没有成果名且没有 run→message 的可靠关联时不猜测回填，当前旧任务可能继续显示较长的原始标题。
- 固定“周末行程”以及长内容复现样例只在 DEBUG 且显式传入 `-amber-watch-preview=...` 时启用，使用隔离临时存储。装机正常启动不带这些参数。
- 连接提示区分当前可达、等待手机响应、本次同步失败和用户操作失败。连接恢复清除旧连接错误，有效快照清除旧同步失败；请求的发送结果待确认提示保留。首页与设置消费同一个连接展示状态。

## 独立检查

- 产品设计 subagent 量化新参考的卡片、字级、内边距和按钮比例；主线程使用实际截图对比。
- 传输 subagent 实施连接/同步/操作提示分离，并加入 5 项状态回归。
- 元数据 subagent 接入前后台成果名、历史兼容和同 run 冷恢复；另确认旧记录无法安全自动补齐名称。
- 主线程发现右上候选 SF Symbol 不存在，通过系统符号查询和实际渲染改为 `doc` 与 `checkmark` 组合，避免静默缺图。

## 验证

模拟器截图位于 `assets/amber-watch-typographic/`。

- 182 项扩展回归：180 通过、2 失败。其中 Watch 相关 91 项全部通过（含 5 项新的状态回归与旧 payload/成果名冷恢复）。日志 `test_sim_2026-09-08T13-48-20-799Z_pid63831_83163bc6.log`。
- 两项失败均为 `ChatSwiftUIStreamReplayTests` 的终态后滚动所有权释放：`testEveryGenerationTerminalReleasesBottomOwnershipAfterLateLayoutSettle`、`testTerminalBeforeFirstAttachSettlesThenReleasesBottomOwnership`；独立复跑仍失败，日志 `test_sim_2026-09-08T13-53-18-788Z_pid63831_14033c9c.log`。未修改无关聊天滚动代码，不能报告全部检查通过。
- iPhone 最终签名构建成功：`/private/tmp/amber-watch-typographic-phone-final-build.log`，包含最终 Watch 依赖重新编译。Watch 独立签名构建也成功：`/private/tmp/amber-watch-typographic-watch-build.log`（最终字级/图标微调由 phone-final 构建更新同一 Watch 产品）。
- 最终 iPhone 包 `codesign --verify --deep --strict` 通过；检查 `UIBackgroundModes=[audio,processing]` 与 iSH `fs` 资源仍在。
- iPhone 已覆盖安装成功，回执 `/private/tmp/amber-watch-typographic-phone-install.json`，sequence 2824。
- Watch 已覆盖安装成功，回执 `/private/tmp/amber-watch-typographic-watch-install.json`，sequence 1008；两端真实进程启动回执均成功。
- 通过 `devicectl device capture screenshot` 直接抓到 416×496 真机新首页，见 `assets/amber-watch-typographic/device-home-privacy.png`。品牌、深铜卡片、近期动态和 CTA 均为新布局；卡片正文被系统隐私遮罩，因此这张图不能作为具体任务内容/当前连接可用性的证明，也没有为了截图删除隐私保护。
- 两条聊天滚动失败已由独立 subagent 做只读因果核对：测试直接创建 NativeChatTimelineView 并手动发送 terminal/settingsRefresh，不调用 ChatViewModel、ChatKernelRunHost、后台 MiniApp 保存或 Watch 发布链路。本轮代码没有进入失败路径；真实缺口是程序化历史滚动没有释放尚未结束的底部 settle 所有权。未扩展修改聊天模块。

结论：新 Watch 设计、91 项 Watch 回归和两端签名覆盖安装已完成；扩展聊天回归保留 2 项明确失败。真机捕获到新布局，正文与连接恢复体验没有被这张隐私遮罩截图验证。
