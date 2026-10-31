# iOS 本机 SSH 密钥与跳板

本次实现位于 `synara/amber-ios-baseline-fixes`，接手基线 `2ad9326e`。只修改 iOS 构建根；不包含 `-L`，不安装手机、不连接真实服务器。

## 工具 schema

所有 schema 的外层均为 `type: object`。密钥生成、导入、删除沿用 SSH 高风险审批：普通自动批准不放行，高风险自动批准开启时可运行；远端表面只能拒绝，子代理/Council/exec 不得调用写工具。

```json
[
  {"name":"ssh_key_list","parameters":{"type":"object","properties":{}}},
  {"name":"ssh_key_generate","parameters":{"type":"object","properties":{
    "name":{"type":"string","description":"唯一名称，1–64 字符"},
    "type":{"type":"string","enum":["ed25519","ecdsa-p256-se"],"description":"省略时使用 ed25519"},
    "require_user_presence":{"type":"boolean","description":"省略时为 false"}
  },"required":["name"]}},
  {"name":"ssh_key_import","parameters":{"type":"object","properties":{
    "name":{"type":"string"},"private_key":{"type":"string","description":"最大 64 KiB"},
    "passphrase":{"type":"string","description":"可选，仅导入时解密"}
  },"required":["name","private_key"]}},
  {"name":"ssh_key_delete","parameters":{"type":"object","properties":{
    "key_id":{"type":"string"}
  },"required":["key_id"]}}
]
```

返回只含公钥、SHA256 指纹、key_id 与非敏感元数据。Ed25519 私钥使用本机 Keychain `WhenUnlockedThisDeviceOnly`；Secure Enclave P-256 仅保存受本机硬件保护的 blob。带口令 OpenSSH（bcrypt + AES-CTR）在导入时解密，Keychain 中只保存未加密格式的私钥，不保留口令；RSA 仍不支持。

`ssh_profile_create/update` 新增可选 `key_id`、`jump_profile_id`。认证方式规范值为 `password` / `key`，兼容 `private_key` / `privateKey`；旧 `private_key` 原文参数仍可用，内部导入本机密钥后绑定 key_id。既有内联私钥在首次使用时惰性迁移，写入新密钥并核对非敏感引用后才删除旧条目。

无密钥时先调用 `ssh_key_generate`，将公钥交给用户加入服务器的 `authorized_keys`，再创建 profile。设置页可生成、导入、选择密钥和复制公钥；复制公钥不要求先保存有效的主机地址。

## 路由、信任和生命周期

- 最多 3 个跳板，连同目标最多 4 段。解析返回 `[最外跳板, …, 目标]`，拒绝环路、悬空引用及使反向依赖超深的更新。
- 被引用的密钥和跳板禁止删除，不级联删除。host、port 或 jump_profile_id 改变时，本跳旧指纹失效。
- 每层使用 direct-tcpip 子通道承载下一层 NIOSSHHandler，不执行跳板 shell。`terminal_execute`、`terminal_job_*` 使用同一条路由。
- 每跳在认证前校验指纹。首次信任可在设置或前台卡确认；卡上标注第 N 跳。首次信任卡只保存该跳指纹，随后重新调用原工具继续，尚未执行命令。指纹变化卡无批准按钮，只能在设置人工核对并替换。
- 审批摘要包含完整路由，批准后任一跳改变都会使原批准失效。锁屏/通知/手表不能批准首次信任或密钥/profile 写入。
- 跳板路由共享截止时间；TCP、KEX、认证、打开通道各阶段受截止时间约束，单阶段最多 15 秒。取消先关闭最外层 TCP，再释放内层会话。
- 所有跳的密码/私钥都进入流式输出脱敏器。工具参数、解析失败诊断、审批快照和导出用输入均先脱敏；不完整 JSON 也不回显原文。

审批原始参数仅保存在 `ChatDynamicToolLifecycle.sshArguments`，按 run_id/tool_call_id 隔离：

| 终态路径 | 清理位置 |
|---|---|
| 批准完成 | finishMcpApproval 取走后执行；本地变量随调用释放 |
| 用户拒绝 | 同一 finisher 在处理拒绝前取走 |
| 取消 | ChatRunKernelAdapter.cancel 立即清除本 run |
| 新消息中断 / 后台交接 | cancel / detachForBackgroundHandoff 立即清除本 run |
| outcome_unknown / 持久化失败 / 其他返回 | run 的 defer 清除本 run |
| 冷启动恢复 | 不恢复内存参数，脱敏占位符被写入校验拒绝 |

## 验证

以下结果来自本次实际命令与 xcresult，构建、签名、安装和真实服务器验收分别报告。

- 共享 schema：`:ai-core:jvmTest --tests app.amber.ai.core.SSHProfileToolDeclarationTest` 已通过。
- bcrypt_pbkdf：直接编译生产 Swift 文件，对照 [OpenBSD 标准向量](https://github.com/openbsd/src/blob/master/regress/lib/libutil/bcrypt_pbkdf/bcrypt_pbkdf_test.c)，32 字节和 64 字节输出均通过。完整上游许可证随 App 资源打包。
- Docker：当前环境未发现 Docker CLI。已提供 `tools/ssh-it/compose.yml`、sshd 配置、合成密钥准备脚本和运行步骤；compose 可解析，shell 脚本语法通过。尚未执行 Docker 容器验收。
- XCTest：第一组 50 项通过、零失败、零跳过；最新源码的 `IOSSSHJumpIntegrationTests` 与 `IOSSSHProfileToolTests` 定点复跑 27 项再次通过。其余未改变的测试沿用第一组证据，27 项不另计为新增覆盖。
- 真实进程内跳板链验证：密钥/密码混合认证、两层 direct-tcpip、逐跳 TOFU、第 2 跳指纹变化时该跳零认证且目标零连接、流式多凭据脱敏，以及从 IOSTerminalRuntime job 入口停止后整链连接归零。
- 密钥与门禁验证：OpenSSH 公钥格式及 ssh-keygen 指纹金样例、带口令导入后去除口令、引用禁止删除、路由上限与环路/反向依赖、审批恢复/拒绝/取消/后台交接/冷恢复、截断 JSON 与共享前缀凭据跨帧脱敏。
- 真机目标 Debug：`generic/platform=iOS` 构建退出 0，`CODE_SIGNING_ALLOWED=NO`，产物为 `Debug-iphoneos/iosApp.app`，bundle id `app.amber.ios`，Mach-O arm64。只验证编译与链接，没有签名或安装。
- Xcode 27 的编译诊断存在“exit code 0 but produced no further output”误报。本次验证命令加 `SWIFT_SUPPRESS_WARNINGS=YES` 后通过；这是单次命令参数，项目 warning 配置未改动，编译错误和测试断言仍保持失败门禁。

主要命令（均在本 worktree 内）：

```sh
HOME=/Users/arquiel JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ./gradlew :ai-core:jvmTest --tests app.amber.ai.core.SSHProfileToolDeclarationTest

HOME=/Users/arquiel xcodebuild -quiet -jobs 4 -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -parallel-testing-enabled NO SWIFT_SUPPRESS_WARNINGS=YES \
  -only-testing:iosAppTests/IOSSSHJumpIntegrationTests -only-testing:iosAppTests/IOSSSHProfileToolTests test

HOME=/Users/arquiel xcodebuild -quiet -jobs 4 -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO SWIFT_SUPPRESS_WARNINGS=YES build
```

结果包：

- 第一组：`Test-iosApp-2026.11.01_03-09-17-+0800.xcresult`。
- 最新定点复跑：`Test-iosApp-2026.11.01_03-15-57-+0800.xcresult`。
- 两者位于 `/Users/arquiel/Library/Developer/Xcode/DerivedData/AmberAgent-epjrjsakhdwbmwgsjkfybxjqorfc/Logs/Test/`。
- 未进行手机安装、真实服务器连接、Secure Enclave 真机签名或人工 UI 验收；未访问宿主用户的 Keychain 数据。

## 文件与行数

相对接手基线 `2ad9326e`，包含接续的半成品。行数为交付时文件总行数；增删为相对基线的 diff。下表不含本报告自身，旧的 `HANDOFF-2026-10-31.md` 未修改、未纳入提交。新文件均低于 1000 行；既有超长 `Tool.kt` 已缩短，将 SSH 声明移至独立文件。

| 文件 | 当前行数 | 增删 |
|---|---:|---:|
| `ai-core/src/commonMain/kotlin/app/amber/ai/core/SSHConfigToolDeclarations.kt` | 298 | +298 / −0 |
| `ai-core/src/commonMain/kotlin/app/amber/ai/core/Tool.kt` | 4652 | +6 / −153 |
| `ai-core/src/commonTest/kotlin/app/amber/ai/core/SSHProfileToolDeclarationTest.kt` | 163 | +51 / −3 |
| `iosApp/Resources/Licenses/OpenBSD-SSH.txt` | 52 | +52 / −0 |
| `iosApp/iosApp/AgentRuntime/ToolEngine/IOSAgentToolBatchExecutor.swift` | 517 | +4 / −1 |
| `iosApp/iosApp/AgentRuntime/Tools/Approval/ChatToolApprovalModels.swift` | 478 | +21 / −3 |
| `iosApp/iosApp/AgentRuntime/Tools/Approval/ChatToolApprovalRequestBuilder.swift` | 391 | +4 / −1 |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatAdvancedToolOperations.swift` | 621 | +6 / −0 |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatDynamicToolLifecycle.swift` | 553 | +19 / −22 |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatLocalToolOperations.swift` | 588 | +13 / −0 |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatToolApprovalCompletion.swift` | 816 | +27 / −2 |
| `iosApp/iosApp/AgentRuntime/Tools/Runtime/ChatToolExecutorAdapters.swift` | 888 | +16 / −0 |
| `iosApp/iosApp/Chat/Generation/ChatGenerationRequestBuilder.swift` | 724 | +4 / −1 |
| `iosApp/iosApp/Chat/Generation/Kernel/ChatRunApprovalSession.swift` | 196 | +8 / −3 |
| `iosApp/iosApp/Chat/Presentation/Approvals/IshHandoffToolApprovalCard.swift` | 292 | +27 / −17 |
| `iosApp/iosApp/Chat/Presentation/Approvals/McpToolApprovalCard.swift` | 378 | +6 / −6 |
| `iosApp/iosApp/Chat/Tools/Presentation/ChatToolStepModel.swift` | 1221 | +13 / −0 |
| `iosApp/iosApp/ChatRunKernelAdapter.swift` | 1220 | +8 / −0 |
| `iosApp/iosApp/ChatToolDetailSheet.swift` | 1001 | +3 / −0 |
| `iosApp/iosApp/ChatToolRuntime.swift` | 1153 | +10 / −3 |
| `iosApp/iosApp/IOSAgentRunLedger.swift` | 1421 | +1 / −1 |
| `iosApp/iosApp/IOSJevContextSelection.swift` | 1236 | +2 / −2 |
| `iosApp/iosApp/IOSLocalToolExecutor.swift` | 1152 | +1 / −1 |
| `iosApp/iosApp/IOSPendingSSHArguments.swift` | 23 | +23 / −0 |
| `iosApp/iosApp/IOSSSHBcryptPBKDF.swift` | 451 | +451 / −0 |
| `iosApp/iosApp/IOSSSHHopTransport.swift` | 630 | +630 / −0 |
| `iosApp/iosApp/IOSSSHHostTrustApproval.swift` | 81 | +81 / −0 |
| `iosApp/iosApp/IOSSSHKeyStore.swift` | 381 | +381 / −0 |
| `iosApp/iosApp/IOSSSHKeyTools.swift` | 439 | +439 / −0 |
| `iosApp/iosApp/IOSSSHModels.swift` | 435 | +140 / −13 |
| `iosApp/iosApp/IOSSSHOutputRedactor.swift` | 297 | +49 / −12 |
| `iosApp/iosApp/IOSSSHPrivateKey.swift` | 656 | +416 / −92 |
| `iosApp/iosApp/IOSSSHProfileTools.swift` | 855 | +387 / −140 |
| `iosApp/iosApp/IOSSSHRouteResolver.swift` | 219 | +219 / −0 |
| `iosApp/iosApp/IOSSSHRuntimeBackend.swift` | 816 | +131 / −11 |
| `iosApp/iosApp/IOSSecretArgumentRedaction.swift` | 133 | +44 / −3 |
| `iosApp/iosApp/Infrastructure/Terminal/IOSAgentTerminalJobExecutor.swift` | 856 | +119 / −31 |
| `iosApp/iosApp/Infrastructure/Terminal/IOSRemoteTerminalExecuteExecutor.swift` | 305 | +76 / −15 |
| `iosApp/iosApp/Infrastructure/Terminal/IOSTerminalCommandPolicy.swift` | 145 | +20 / −10 |
| `iosApp/iosApp/Infrastructure/Terminal/IOSTerminalModels.swift` | 237 | +4 / −1 |
| `iosApp/iosApp/Infrastructure/Terminal/IOSTerminalRuntime.swift` | 841 | +188 / −28 |
| `iosApp/iosApp/RuntimeEnvironmentView.swift` | 1226 | +13 / −126 |
| `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentComponents.swift` | 989 | +7 / −2 |
| `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentSSHKeyViews.swift` | 266 | +266 / −0 |
| `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentSSHProfileEditing.swift` | 318 | +94 / −91 |
| `iosApp/iosApp/SettingsStore.swift` | 441 | +180 / −8 |
| `iosApp/iosApp/SubAgentRunner.swift` | 880 | +4 / −1 |
| `iosApp/iosAppTests/IOSChatApprovalCancellationTests.swift` | 129 | +3 / −0 |
| `iosApp/iosAppTests/IOSSSHJumpIntegrationTests.swift` | 215 | +215 / −0 |
| `iosApp/iosAppTests/IOSSSHKeysAndRoutesTests.swift` | 149 | +149 / −0 |
| `iosApp/iosAppTests/IOSSSHProfileToolTests.swift` | 837 | +55 / −0 |
| `iosApp/project.yml` | 829 | +4 / −0 |
| `tools/ssh-it/.gitignore` | 1 | +1 / −0 |
| `tools/ssh-it/Dockerfile` | 10 | +10 / −0 |
| `tools/ssh-it/README.md` | 24 | +24 / −0 |
| `tools/ssh-it/compose.yml` | 18 | +18 / −0 |
| `tools/ssh-it/prepare.sh` | 11 | +11 / −0 |
| `tools/ssh-it/sshd_jump.conf` | 17 | +17 / −0 |
| `tools/ssh-it/sshd_target.conf` | 12 | +12 / −0 |
