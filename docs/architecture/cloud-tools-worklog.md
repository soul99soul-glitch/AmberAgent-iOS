# 云端任务工具实现记录

基线 4d940b18；范围 cloud-daemon。用户授权真实任务文件、隔离进程、主机只读信息、HTTP/搜索、FFmpeg/yt-dlp 检测安装更新；不改腾讯、四端 UI、本机全局软件或真实 Key。

## 选择

- 不另建调度器/凭据库/模型框架；工具执行显式携带 workItem/agent/session/工具授权集合，recipe 继承同一上下文。
- 任务可写目录按 workItem 独立。拒绝路径越界/符号链接，结果文件复用配对鉴权查询和下载。
- Linux bubblewrap namespace 沙箱；macOS sandbox-exec 仅本地同类边界验收。无可用隔离器时明确 blocked，不裸执行。脚本无网络；HTTP 工具独立校验 DNS/IP/重定向。
- Worker 必须调用结构化 task_finish(outcome,summary,artifacts) 结算；纯文本结束不代表成功。保留既有八态，对 blocked 使用 FAILED + 可选 outcome 字段。
- 当前 KMP 只有搜索设置模型，无 JVM 搜索执行器；参考 macOS bd74a15c 的源顺序/fallback/parallel/去重/图片字段，JVM 实现任务网络适配器。
- 搜索 Key 通过既有 vault；免费源无需 Key。付费协议用 stub，实际只验最小免费检索。
- 工具链在专用目录安装固定发布者分发（Linux采用官方指向的构建，macOS采用明确标注的第三方构建）；不执行任意安装脚本、不 sudo/改全局 Python。脚本内调用 CLI 仍受同一沙箱。

## 交付顺序

1. 上下文权限、任务文件、隔离执行、主机指标、显式结算；状态查询和 Python CSV 产物闭环。
2. HTTP/正文/下载、免费源聚合与 Exa/Brave 协议。
3. CLI 检测/安装/更新，合成媒体和受控 yt-dlp fixture。
4. 必要定点检查、一次维护性检查、最终 fatJar/包清单/Library。

## 环境与待验证

- 本机 Darwin arm64，有 sandbox-exec/yt-dlp/Python，无 docker/podman/bwrap/ffmpeg 命令。
- 已读取runtime盘点：Ubuntu24.04.5 x86_64，有Python3.12.3/pip24和FFmpeg/ffprobe6.1.1；bwrap/yt-dlp缺，venv缺ensurepip；AppArmor限制userns，unshare实测失败。未变更远端。
- 官方依据：Exa https://exa.ai/docs/reference/search；Brave https://api-dashboard.search.brave.com/api-reference/web/search/get；yt-dlp https://github.com/yt-dlp/yt-dlp#installation；bubblewrap https://github.com/containers/bubblewrap；FFmpeg 分发需核对 https://ffmpeg.org/download.html 指向的构建站。

## 最终本地验证

- 必要定点批次通过（TaskTools、TaskRuntimeHttp、SearchNetwork、TaskExternalAcceptance、NativeTaskHttp、AgentCentricApi、ConfiguredDaemonRecovery）。CSV真实脚本sum=5，鉴权下载与SHA元数据、任务/Agent/recipe权限、读写宿主/符号链接/网络拒绝、取消/超时/子PID清理；普通文本结算blocked、显式completed/failed和取消终态不回滚。
- Exa/Brave使用loopback stub验证原生参数/Key头/图片/去重、限流/缺Key/空结果；免费公网Bing3条，DDG本次202空，逐源可观察。本机TUN fake-IP被生产门禁拒绝，公网验收使用仅测试的公开DNS解析注入，仍校验公网实际连接；未改系统DNS/代理。
- 专用build目录安装FFmpeg/ffprobe9.0.2及官方yt-dlp2026.10.26 Python zip（更新+复用），经真实toolchain_run生成0.2秒音频、ffprobe读元数据、yt-dlp解析本地HTML媒体fixture。首次macOS yt-dlp独立包探测超时，未发布，最终使用官方Python zip；未动系统工具。没有真实站点媒体验收。
- code-simplifier仅本轮diff一次：统一Worker上下文门禁、HTTP逐跳重定向状态、进程结果生命周期与安装探测超时清理。无独立review/全量测试。
- 最终fatJar一次通过，实际Main+loopback OpenAI provider完成6次工具调用（主机信息→写CSV/脚本→真实Python→读结果→结算），下载sum=5产物；重启查询/幂等重试不重跑，identity/证书/token复用。
- 未验收：真实模型/收费搜索、Linux bwrap执行/包安装、AppArmor配置、腾讯部署、手机产物UI、强杀断电。Linux前置条件和回滚见cloud-task-tools.md。
