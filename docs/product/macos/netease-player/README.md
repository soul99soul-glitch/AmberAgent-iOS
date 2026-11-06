# Amber macOS 网易云音乐插件：运行与验证

状态：**源码和受限宿主桥接已实现，尚未完成真实账号播放验收**。本页记录 2026-11-03 在此工作树的验证，不表示音频播放、搜索字段或版权处理已在真实账号下验证。

## 组成与运行

- 插件包位于 `examples/plugins/netease-music/`，包含工作区和右侧栏两个入口。必须使用包含本次 `music.netease` 桥接改动的 Amber；旧版 `/Applications/Amber.app` 不认识这个权限，不能直接导入。
- 用户自行准备 [网易云官方 ncm-cli](https://www.npmjs.com/package/%40music163/ncm-cli)（本次核对 0.1.7、Node.js ≥18）、官方支持的 `mpv` 播放后端，以及[网易云开放平台](https://developer.music.163.com/)的 App ID / Private Key。按官方流程在终端运行 `ncm-cli configure`、`ncm-cli login`；凭据由 CLI 管理，不写入插件或此仓库。
- 启动本工作树本轮构建的 `macApp/build/compact-v2/Build/Products/Debug/Amber.app`，在「设置 → 插件 → 导入扩展插件」选择 `examples/plugins/netease-music` 文件夹，并核对并批准权限。卡片通过「网易云音乐」工作区入口或右侧栏打开。
- 对 GUI 启动的 Amber，`ncm-cli` 与 Node/mpv 需要可在 `/opt/homebrew/bin`、`/usr/local/bin` 或应用进程的 PATH 中找到。CLI 找不到、未配置或未登录时卡片会显示错误；如果选用 mpv，需自行安装并配置它。
- 搜索后点击「播放」，可将其他可播放结果通过「加入队列」加入 CLI 队列，再使用上一首/下一首。进度定期读取 CLI 的 `state`；未获得数据时不推算进度。CLI 或歌曲服务返回的失败会显示在卡片中；不得绕过会员、地域或版权限制。

## 实现边界

`music.netease` 是新的需批准插件权限。仅 WebView RPC 可调用 `state`、`search song`、`play --song`、`queue add`、`pause`、`resume`、`prev`、`next`：宿主校验输入后将参数直接交给固定名称的 `ncm-cli`，不调用 shell、不接收命令行字符串，也不将密钥放到插件代码里。搜索结果与当前歌曲使用响应字段解析；由于没有可用账号，真实网易响应形状及正在播放的状态字段尚未核实，可能需要按真实输出修正。歌曲不可播的明确标志会禁用选择，播放端仍负责最终的权限裁定。

## 已执行的检查

1. 官方 `@music163/ncm-cli@0.1.7` 在 `/tmp` 隔离目录安装，关闭 npm 生命周期脚本；仅用隔离 HOME 中的占位配置查看 `--help` 和本地空队列状态，**未使用真实账号、未用占位凭据请求网易云搜索服务**。官方 CLI 的 `state` 实际返回 `success: true` 和 `status: stopped`。
2. 使用本次 Swift CLI 进程桥直接调用上述隔离的官方 CLI `state`：通过，返回真实的 `stopped`。这是本地空状态检查，不是播放证明。
3. `macApp/scripts/build.sh` 的 Debug 构建退出码 0；`codesign --verify` 通过。构建日志出现既有 Swift 警告和 Xcode 的“command failed with exit code 0”诊断，但构建脚本成功完成。
4. 仅执行 `DesktopPluginV3Tests/testNeteaseMusicPermissionAndCommandBoundary`：1 项通过。它验证安装权限未批准时拒绝桥接、搜索词作为独立参数、歌曲 ID 校验和拒绝未知命令。
5. `node --check`、插件清单 JSON 解析、`git diff --check` 和 Arquiel 静态 lint 通过。
6. 实际启动 Debug Amber 并导入插件，主工作区和右侧栏均能显示卡片；未找到 CLI 时显示对应提示并禁用播放控件。早期测试包已移入 `macApp/build/netease-music-ui-test-import`，后续 UI 验证重新将新版本导入共享插件目录；旧版 `/Applications/Amber.app` 无法识别新权限，切换旧版前需适当移走该测试导入。没有替换 `/Applications/Amber.app`。

## 仍需验证

本机没有全局 `ncm-cli`、`mpv` 或检测到官方 CLI 的本地配置；未取得开放平台凭据和扫码登录。**真实搜索 → 选曲 → 播放/暂停 → 将另一首加入队列 → 切歌 → 状态/封面/进度回传，及实际听到声音均未完成**。先由用户完成官方 CLI 安装、平台凭据配置及登录，再在 Debug Amber 中执行上述闭环，根据真实 JSON 字段修正兼容性。

已通过电脑控制工具目视检查原生窗口，因桌面随后被切换且本次无法安全保存该原生窗口截图，未向 Library 提供截图文件；不能用构建结果或视觉检查代替实际播放证据。


## 侧栏展开与 mini 收起态修正（本轮）

收到侧栏裁切与收起后只显示标题的反馈后，宿主新增可选的 `compact_height` 视图字段：声明此字段的右侧栏 / 检查器插件会保留同一个 WebView，通过根节点 `data-amber-presentation` 在 `expanded` 和 `compact` 之间切换；未声明该字段的旧 WebView 也保持挂载，使用宿主提供的真实启用状态 mini。网易云插件现按侧栏宽度以 1:1 展开，搜索使用二级视图；收起视图为 60 点、18 点圆角，保留封面、状态、歌曲和播放/暂停；仅真实播放且有有效时长和进度时显示细进度条。不可用时显示“播放器不可用”，进度未知时不伪造进度。

隔离 Debug 构建和 2 项定点测试通过：权限及命令边界；`compact_height`／`aspect_ratio` 清单解析编码与同一 JavaScript 文档中的展开/收起状态保持。本轮形状纠偏只再做 Debug 构建与静态检查，没有增加测试方法。

方形布局曾在 Debug Amber 原生窗口中目视确认封面、进度和控制未裁切；展开→收起→展开后，未提交的搜索输入仍在，缺依赖状态保持。最新包已重新导入，原生窗口的收起态目视确认是圆角矩形且无空态底轨；飞书日历的空态 mini 和方形展开态也已目视检查。电脑控制工具返回了窗口画面，但系统截图工具未能启动并保存文件，因此两种状态截图尚未归档。取得账号与播放器后仍需验证真实歌曲、播放/暂停、切歌及进度保持。

更具体的当前双规格见 [design-contract.md](design-contract.md)。

通用宿主规则及旧插件迁移清单见 [plugin-sidebar-contract.md](plugin-sidebar-contract.md)。本轮通用化后的 Debug 构建通过，并仅运行了现有飞书日历快照定点测试（1 项通过）；测试不等于真实飞书同步验收。

用户已明确撤回默认药丸外形：mini 采用与飞书一致的圆角矩形；此前看到的底部灰线是空态也渲染了进度底轨，现只在真实播放且时长及进度有效时显示，同时禁用 compact 滚动条。

## 动效修正与验证边界

宿主尺寸和插件主元素使用约 240 ms 过渡；自定义视图可用 `data-amber-morph` 标记同一 DOM 节点参与位置衔接，快速反向时取消旧动画。播放器搜索在卡片内展开并立即聚焦，结果短淡入；减少动态效果时跳过位移和缩放。现有状态定点测试已复测通过，覆盖反向取消、重复状态不重启动画及减少动态效果分支。

用户反馈收起没有动画且不够流畅后，复查发现曾在旧版插件资源上测试；更新资源后，又在原生窗口复现了收起态标题和控件互相叠压。WebKit 检查确认：旧次要控件在变为绝对定位后仍等待淡出，窗口不活跃时淡出可能停住。现改为收起时立即隐藏这些次要控件并显示 mini 状态，保留主元素的位置过渡；展开／收起状态使用内存状态直接驱动 SwiftUI 动画，并在同一事务中持久化。实际 WebKit 的定点样式检查确认收起态标题隐藏且状态文字可见。

本轮 Debug 构建与静态检查通过。已在修复前的原生窗口操作展开、收起、搜索、输入和返回；重新启动修复版时窗口未能正常出现，进程采样显示主线程停在原有飞书凭据的 macOS 钥匙串读取 `SecItemCopyMatching`，具体系统原因未确认。修复后的实际连续动效尚未完成目视验收，亦未取得录屏或关键帧。不能据此声称已验证动画中无裁切、白闪或点击漂移。真实音频与网易账号流程仍未验收。
