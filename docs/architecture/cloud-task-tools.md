# 云端任务工具与部署契约

范围：基于 4d940b18 的 cloud-daemon，不变更配对/模型凭据协议，不修改四端 UI。本轮本地实现与 stub/真实子进程验收；腾讯部署与真实模型使用仍由 runtime 线程处理。

## 实际入口与权限

既有 `POST /v2/work-items` → `NativeTaskApi` → 默认 main Agent/受管 Worker → `ModelWorkerTurnRunner` → `DefaultCloudOrchestrationKernel.executeWorkerTool` → `CloudToolRegistry.executeGate`。保持每设备 requestId 幂等、原 Agent 路由/权限交集、取消/终态不可回滚。

任务身份只由已验证 Worker principal 创建，携带 workItemId/agentId/sessionId/allowedTools；模型参数不能选择工作目录或覆盖该身份。recipe_run 的 `{"tool":"...","args":{...}}` 沿用原调用者域和授权集合，最多4层；它不是命名配方库。不再把子调用切换为更宽的 RECIPE 权限。历史工具也继承当前 Worker session，不能跨会话。

普通任务工具归入 TASK_LOCAL（或 NETWORK_READ），可以给 SUBAGENT 使用；宿主终端、SSH 配置和原 SIDE_EFFECT/高风险仍被拒绝。自定义 Agent 的 toolScope 不会自动扩权；main 默认取得已注册可用任务工具。task_finish 是所有 Worker 可用的结算控制动作。

## 工具表

| 工具 | 行为/关键参数 |
| --- | --- |
| workspace_file_list/read/write/search/edit | 当前 workItem 私有目录；相对 path，read 的 maxChars，write 的 content，search 的 query，edit 的 old/replacement（唯一匹配）。list 最多200文件/深度8；文本最多100k字符；单文件32MiB。openat/dir_fd/O_NOFOLLOW、常规文件检查，在OS沙箱内执行。 |
| process_run | argv 字符串数组，timeoutSeconds 1..600（默认60），background bool；直接执行，Shell 用 `["/bin/sh","-c","..."]`，Python 使用 runtime_info 返回路径；返回 id/state/exitCode/stdout/stderr/truncated。非0退出不是成功。 |
| process_wait / process_stop | id 只能属于当前任务；wait.seconds 1..60。后台进程可查询；停止返回 cancelled。同步运行完成后结果直接返回，不长期保留其进程句柄。 |
| host_info | 真正JDK/OS CPU数、负载、物理内存、根盘容量/可用空间、最多100条进程pid/名称/累计CPU；sampledAt 与 errors 标记缺失值。不含环境变量或命令参数，不访问远端监控。 |
| runtime_info | OS/架构、Python路径、隔离器检测及限制；隔离器存在不代表 namespace 已放行，必须做预检。 |
| http_request | 公网GET/HEAD，url/method；真实HTTP状态、contentType、text；最多2MB响应。没有通用带凭据POST/浏览器登录权限。 |
| scrape_web | url；Jsoup解析正文/标题/链接，不执行网页JS；正文最多60k字符。 |
| download_file | url/path；公网下载到任务文件，最多32MiB，返回SHA256/大小/类型。 |
| search_web | query/count(1..20)/mode(fallback或aggregate)/sources/exa/brave；逐源状态、title/url/snippet/sources/images/publishedDate；尝试保存 search-results.json，文件能力不可用时保留检索结果并给 artifactError。 |
| toolchain_status / toolchain_install | 检测路径/版本/managed；install.name=ffmpeg或yt-dlp，update默认false复用已有项。固定发布源、校验SHA256，写专用toolchain目录；不sudo、不装全局包、不接受自定义安装命令或URL。 |
| toolchain_run | name=ffmpeg/ffprobe/yt-dlp，args数组、timeoutSeconds；同一任务OS隔离内真实执行。yt-dlp默认ignore-config/no-plugin-dirs，受相同无网络限制。 |
| task_finish | outcome=completed/blocked/failed，summary非空，artifacts为真实文件相对路径数组；不得有活动进程，产物必须实际存在。 |

原 terminal_exec、js_sandbox_eval 没有真实宿主执行器，现在明确返回错误，不能再以 ok:true 回显命令/代码冒充执行。任务脚本用 process_run。

## Linux 隔离与当前部署前置条件

生产仅使用 bubblewrap：user/pid/net/ipc/uts 等命名空间，移除 capabilities，die-with-parent/new-session；只读运行时目录 /usr /bin /sbin /lib /lib64，单任务目录挂载 /workspace，可写临时目录 /tmp，专用工具目录只读。不挂载 daemon data、HOME、凭据或用户目录；不传递 daemon 环境；不提供无沙箱回退。进程有CPU/文件大小/FD/地址空间/NPROC限制，最多每任务2个活动进程，输出每流256k。不是完整的cgroup磁盘/内存配额平台。

脚本不能联网。HTTP由daemon受校验工具代发，只允许80/443、公网DNS实际连接地址；拒绝回环/私网/link-local/CGNAT/fake-IP、URL内嵌凭据，关闭环境代理，最多3次重定向并每跳重新检查，跨源去掉认证头。下载不通过脚本绕过该边界。没有交互浏览器、登录cookie、SSH远程管理或云metadata访问能力。网络写入/API管理不属于这批只读网络工具。

runtime只读盘点：Ubuntu24.04.5 x86_64，Python3.12.3/pip24，FFmpeg/ffprobe6.1.1已在系统；bwrap/yt-dlp/容器缺，venv有但ensurepip缺。unshare uid_map 实测失败，AppArmor restrict_userns=1。**不能仅上传新jar便宣称Python执行可用。** 后续管理员需安装bubblewrap并核对仅 `/usr/bin/bwrap` 的发行版AppArmor userns配置，用 `python3 scripts/task-runtime-preflight.py` 在实际daemon用户/服务上下文验收；不建议关闭全局AppArmor限制。预检只读，不安装或读data/key。参考 [Ubuntu发行说明](https://documentation.ubuntu.com/release-notes/24.04/) 与 [bubblewrap项目](https://github.com/containers/bubblewrap)。具体主机profile尚未实施，本轮没有为远端做权限变更。

macOS使用sandbox-exec仅作本机同类边界验证；最小系统/受信任Python动态库只读、当前任务可写、网络默认拒绝，不能把本机结果等同Linux真机隔离验收。

## 搜索与配置

沿用既有 CloudConfigLoader / EnvelopeCredentialVault，不另建凭据仓。新增非secret配置：

```properties
search.sources=bing,duckduckgo
search.mode=fallback
```

环境变量 `AMBER_SEARCH_SOURCES`（有序逗号列表，支持bing/duckduckgo/exa/brave）和 `AMBER_SEARCH_MODE`（fallback/aggregate）覆盖配置；不配Key也有免费源。付费源必须在sources中显式启用，凭据库键 `search.exa_key` / `search.brave_key`，安全导入环境名 `AMBER_SEARCH_EXA_KEY` / `AMBER_SEARCH_BRAVE_KEY`。不要把真实Key放进任务或聊天。测试未使用真实Exa/Brave Key或收费请求。

Exa POST /search、x-api-key，保留type/category/includeDomains/excludeDomains/startPublishedDate/endPublishedDate/contents；强制本次query/numResults。Brave GET /res/v1/web/search、X-Subscription-Token，保留country/search_lang/ui_lang/freshness/safesearch/extra_snippets；强制q/count。provider端点固定；模型不能改为任意凭据接收站。来源状态区分ok/empty/missing_key/rate_limited/http_error/error，不静默漏掉失败源。聚合取消会取消HTTP请求；去重保留路径大小写和query，合并来源/图片。

官方协议：[Exa](https://exa.ai/docs/reference/search)、[Brave](https://api-dashboard.search.brave.com/api-reference/web/search/get)。参考已交付macOS bd74a15c 的源顺序/并发/归一化设计；仓内Shared只有设置类型，未发现可直接复用的JVM执行器，没有搬Swift或重做Shared架构。

## CLI 安装来源、更新与边界

- Linux FFmpeg：FFmpeg官网指向的 [BtbN FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds/releases)，按amd64/aarch64选择当前release静态LGPL包，校验checksums.sha256，只提取常规ffmpeg/ffprobe成员，不展开archive路径/链接。现云机优先复用6.1.1，无须下载。Linux包安装尚未实机执行。
- macOS本地FFmpeg：第三方 [Martin Riedl构建站](https://ffmpeg.martin-riedl.de/)，按arm64/amd64选择release zip及.sha256；这是用于本机验证的第三方分发，不能称为FFmpeg官方二进制。
- yt-dlp：采用[官方Python zip分发](https://github.com/yt-dlp/yt-dlp#release-files)和同release SHA2-256SUMS，不需pip/venv，但需满足其Python版本要求（本次官方包要求>=3.10；云机3.12符合）。更新重新下载/校验/实际探测后原子切换current。系统已有项仅探测复用，update不会覆盖系统文件，而是安装专用版本优先使用。
- toolchain/<name>/<sha256> 保留已装二进制，current为可执行副本，manifest.json记录分发源/版本/sha/安装时间。校验基于HTTPS发布者清单，未另做GPG签名验证。专用目录只能由daemon安装器写，脚本只读。
- 同一无网络沙箱内可对已下载公开文件调用FFmpeg、yt-dlp本地fixture；这**不代表真实视频网站下载已打通**。不读取浏览器Cookie/用户媒体，不调用sudo/系统包管理器。

## 客户端结果与鉴权下载

保持原请求：`POST /v2/work-items` body `{requestId,text,agentId?,title?}`（agentId默认main），首次202，原设备相同requestId原文重试200，不同请求409；所有查询/取消/产物沿现有设备Bearer。

新增：

- `GET /v2/work-items/{id}` 的可选 `outcome`：completed/blocked/failed/cancelled；原state八态不变，blocked对旧客户端投影FAILED。旧记录outcome可能缺失。普通文字结束不再COMPLETED；显式task_finish表示模型对目标结果的结构化声明，仍需调用者验收其内容。
- `GET /v2/work-items/{id}/artifacts` → `[{path,sizeBytes,sha256,contentType}]`。不返回宿主绝对路径。
- `GET /v2/work-items/{id}/artifacts/download?path=<URL编码相对路径>` → 二进制附件，401无设备Bearer，404未知任务，400无效路径/不可读/缺隔离能力。单文件<=32MiB，列表/下载使用同一安全文件层。
- 原取消 `POST /v2/work-items/{id}/cancel` 保持。取消Worker时清理活动子进程，晚到结果不改终态。没有新增SSE，继续轮询既有结果接口。

最窄原生消费：任务详情显示outcome差异，加载产物列表，携带当前配对Bearer下载到客户端沙箱并校验SHA；搜索图片/来源可读取search-results.json。此轮未修改iOS/Android/鸿蒙/macOS，手机端产物UI尚未验收。

## 升级与回滚

Java21。原data目录、AMBER_MASTER_KEY_FILE、model/provider配置和443 TLS reverse proxy→127.0.0.1:47822保持；同原命令/用户替换jar，**不重新配对、不重建identity/tls、不清token/data**。仅新增任务目录/工具目录，work_items.record_json新增可选settlementOutcome，无破坏性SQL迁移，旧记录可读。新增JVM依赖仅Jsoup 1.23.2（[官方发布](https://jsoup.org/download)），随fatJar打包。

部署前保存旧jar及原配置/数据库备份，停止旧进程后换新jar；回滚恢复原jar/非secret配置，保留原data及新目录。原始4d940b18对未知JSON字段使用ignoreUnknownKeys，但旧Worker仍有“文本即completed”语义；不要把回滚当作新任务能力保留。工具版本可将保留hash文件复制到current回滚，只改专用目录，不变系统包。停止/重启时Linux进程依赖bwrap die-with-parent清理；强杀/断电及真实服务器资源限制仍需runtime验证。
