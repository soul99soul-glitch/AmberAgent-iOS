# macOS KMP 接入验证记录

日期：2026-10-23。

## 当前结论

当前检查点：用官方 Kotlin 2.3.21 JVM 编译器及同版本 serialization 插件编译实际桌面桥、原消息/工具 helper 和测试，**82 项 JVM 测试通过**，日志 `/tmp/amber-kmp-overrides-check.log`。覆盖 canonical/分支/搜索/附件/参数、历史未知工具不重放、typed Recipe invocation、原 MCP 输出、工具暴露，以及新增 headers/body/图片能力覆盖和原 Settings 搜索服务配置。下文 4/13 项是历史检查点，不能相加。Gradle 尚未进入工程配置／编译阶段；macOS `Shared.framework` **尚未得到构建验证**。

`desktop-shared` 是本仓本地 Gradle 工程模块，framework 名称为 `Shared`。它复用现有 provider、消息累加器与 canonical conversation storage；没有宣称 AmberAgent Core 已独立发布。原 iOS `:shared` 的依赖与导出未改。

## 初版四项验证记录

执行方式：`python3 /tmp/amber-kmp-direct-check.py`。这是临时验证脚本，并非新增产品构建流程。

编译器通过 JDK 21 直接调用 `org.jetbrains.kotlin.cli.jvm.K2JVMCompiler`，参数包括 `-jvm-target 17`、`-no-stdlib`、`-no-reflect`、Kotlin 2.3.21 serialization 编译插件及 UUID opt-in。源码包含 `desktop-shared/src` 下的桥和新增测试。编译 classpath 使用本机缓存的标准库／序列化／协程／日期／JUnit，以及本仓已经存在的各模块 JVM jar。

随后直接调用官方 `org.junit.runner.JUnitCore` 执行：

| 测试 | 已验证内容 |
| --- | --- |
| `DesktopProviderBridgeTest.providerProtocolAndModelReachRealKmpConfiguration` | OpenAI Responses／Claude 分派、endpoint 空白与尾斜线规范化、key 与 model ID 进入实际 KMP 配置，未知协议可捕获失败 |
| `DesktopProviderBridgeTest.messageProjectionRetainsIdentityReasoningAndPartialTerminal` | 消息 ID、正文、思考与 cancelled 终态经过 DTO → KMP → DTO 保留 |
| `DesktopProviderBridgeTest.invalidRolesAndMalformedIDsAreCatchableAtJsonBoundary` | 非法角色与 UUID 在带 `@Throws` 的 JSON 边界失败 |
| `DesktopConversationRepositoryTest.cancelledContentSurvivesRestartAndStaleSavePreservesMetadata` | cancelled 部分内容写入 canonical KMP conversation 文件，重启恢复，旧内容快照不覆盖重命名／置顶，删除后列表为空 |

实际日志 `/tmp/amber-kmp-direct-check.log` 摘要：

```text
Compiling DesktopBridge and tests with cached Kotlin 2.3.21
Running actual JVM repository and provider tests
JUnit version 4.13.2
....
Time: 0.414

OK (4 tests)
```

上述日志来自 endpoint 规范化修正后的第二次完整编译与执行。

## Gradle 的实际阻塞

第一次使用默认 Gradle 用户目录启动时，本会话不能写入用户全局缓存的 wrapper 锁文件：

```text
java.io.FileNotFoundException:
/Users/mi/.gradle/wrapper/dists/gradle-9.4.1-bin/arn2x92ynaizyzdaamcbpbhtj/gradle-9.4.1-bin.zip.lck
(Operation not permitted)
```

把 Gradle 缓存复制到允许写入的临时目录后，Gradle 9.4.1 能启动，但在创建本地文件锁监听器时被本会话的 socket 权限阻断。`/tmp/amber-mac-kmp-build-v2.log` 的实际错误：

```text
Gradle could not start your build.
> Could not create service of type FileLockContentionHandler
  using BasicGlobalScopeServices.createFileLockContentionHandler().
  > java.net.SocketException: Operation not permitted
```

这发生在任务配置与 Kotlin 编译之前，不能据此判定 macOS 目标编译成功或失败。没有修改 Gradle 内部实现、禁用安全边界或绕过 sandbox。

环境另有两项已确认事实：原 JDK 17 的 `bin/java` 已不存在，因此本次直接 JVM 验证使用实际可用的 Homebrew JDK 21；临时 Konan 目录复制因执行环境断联未完成，`/tmp/amber-macos-konan` **不能作为完整可用工具链交付**。

## 尚未验证及下一次正常构建

- 新增 macOS Gradle 目标的配置、依赖变体选择及 macOS framework 链接。
- macOS Foundation／CoreCrypto／POSIX 文件 actual 的编译和原生测试。
- Swift 对新生成 Objective-C header 的真实消费与链接。
- 现有 provider／conversation storage 的完整 Gradle 测试；直接验证使用其已有 JVM jar，未重新编译这些依赖。
- 真实 provider 网络请求、Mac UI 与系统权限。

在具备正常本地构建权限、可用 JDK 和完整 Kotlin/Native 工具链的环境中应执行：

```bash
./gradlew \
  :desktop-shared:linkDebugFrameworkMacosArm64 \
  :desktop-shared:jvmTest \
  :core:conversation-storage:macosArm64Test \
  :ai-provider-openai:jvmTest \
  :ai-provider-claude:jvmTest \
  :core:conversation-storage:jvmTest \
  --console=plain
```

预期 framework 输出：`desktop-shared/build/bin/macosArm64/debugFramework/Shared.framework`。只有该任务和 Swift 消费构建取得成功证据后，才能把 Phase 1 的 Mac 构建验收标为通过。

## 独立子代理复核

由 `mac_runtime_audit/kmp_bridge_review` 对本阶段 KMP diff 进行只读复核。结果：未发现需要新增修复的确定性问题。

复核覆盖依赖闭包、Foundation actual 共享、Swift `@Throws` 边界、消息部分终态往返、metadata 所有权与后台存储初始化。包括 `desktop-shared` 在内共 18 个模块具备 macOS arm64 target；没有使用 iOS 二进制替代 Mac 产物。

该复核同样不替代原生构建验收。这里的“实现”仅指早期 KMP 基础桥；当前完整产品计划的 Phase 1 仍为进行中，不能以 JVM 桥测试关闭 Mac 原生验收。

## 官方 Kotlin/Native standalone 路线评估

为确定能否在不依赖 Gradle 本地 socket 的情况下完成真实 Mac 产物，直接运行本机官方 Kotlin/Native 2.3.21 的 `konanc -help`。命令成功返回，编译器明确支持 `-target <target>`、`-produce framework`、`-library` 及响应文件。因此 standalone 本身是合法的工具链路径；它仍需要真正的 Mac 第三方 KLIB，不能用 iOS KLIB 替换。

独立子代理 `mac_klib_inventory` 对以下两个 Maven 缓存中的全部 `.klib` 逐个读取 ZIP `manifest`：

- `/Users/mi/.gradle/caches/modules-2/files-2.1`
- `/tmp/amber-macos-gradle/caches/modules-2/files-2.1`

每个缓存均为 84 个第三方 KLIB，目标分布一致：

| manifest 的 `native_targets` | 数量 |
| --- | ---: |
| `ios_arm64` | 42 |
| `ios_simulator_arm64` | 42 |
| `macos_arm64` | **0** |

原始缓存已存在部分 Mac 模块的 `.module`／`.pom`，但元数据声明的二进制均缺失：

| 依赖 | 缺失文件 |
| --- | --- |
| Ktor Darwin 3.4.3 | `ktor-client-darwin-macosArm64Main-3.4.3.klib` |
| Ktor client core 3.4.3 | `ktor-client-core-macosArm64Main-3.4.3.klib` |
| Ktor content negotiation 3.4.3 | `ktor-client-content-negotiation-macosArm64Main-3.4.3.klib` |
| Ktor JSON serialization 3.4.3 | `ktor-serialization-kotlinx-json-macosArm64Main-3.4.3.klib` |
| kotlinx-coroutines-core 1.10.2 | `kotlinx-coroutines-core-macosArm64Main-1.10.2.klib` |
| kotlinx-serialization-core 1.11.0 | `kotlinx-serialization-core-macosArm64Main-1.11.0.klib` |
| kotlinx-serialization-json 1.11.0 | `kotlinx-serialization-json-macosArm64Main-1.11.0.klib` |
| kotlinx-datetime 0.7.1 | `kotlinx-datetime-macosArm64Main-0.7.1.klib` |

例如 Darwin 元数据位于：

```text
/Users/mi/.gradle/caches/modules-2/files-2.1/io.ktor/ktor-client-darwin-macosarm64/3.4.3/fff22b611bf2235277b69158595c4c42b44da5c5/ktor-client-darwin-macosarm64-3.4.3.module
```

它声明 `ktor-client-darwin-macosArm64Main-3.4.3.klib`，对应 Maven URL 文件名 `ktor-client-darwin-macosarm64-3.4.3.klib`。缓存中只有该 `.module` 和 `.pom`，没有 `.klib`。其他 Ktor HTTP／IO／SSE 等 Mac 依赖也同样没有二进制。

正常请求官方 Maven artifact URL 的 HEAD 检查失败于当前既有代理：

```text
curl: (7) Failed to connect to 127.0.0.1 port 7897 after 0 ms: Couldn't connect to server
```

因此，**仅凭本机现有缓存无法构建真正的 macOS Shared.framework**。未创建替身 framework、未使用 iOS slice、未篡改 Gradle或切换宿主绕过权限。没有交付一份未经验证、缺依赖的 standalone 构建脚本。取得官方 Mac KLIB 后，仍优先恢复既有正式 Gradle 构建并验证 Swift 消费。


## canonical 完整契约修复后的最新验证

初版的纯正文／思考 DTO 已修正为**完整 KMP canonical JSON + Swift 展示投影**。`DesktopMessage` 与 `DesktopConversation` 均携带可选 `canonicalJSON`；旧格式仍可读。UI 展示文本不再成为完整消息的存储源。

- 流快照包含完整 `UIMessage`，`assistantId` 在投影与 canonical 内容中同步保持稳定。
- provider 输入还原完整有序 parts、工具参数／结果／批准态、metadata、annotations、模型、usage 与时间信息；包括 `tool` 角色。
- 保存以已有 canonical Conversation 为基准，复用 `updateCurrentMessages` 保留节点 ID、选中分支和隐藏候选；重试向原节点追加新 assistant 变体。
- cancelled／failed／streaming 仅更新 Text metadata 的 `desktopState`，保留其他 metadata；未变的原始时间保留纳秒精度。
- `unsupportedPartCount` 只用于展示提示，不参与重建 parts。
- `load(id:)`、`normalizeImport(document:)`、`exportDocument(json:)` 都在后台 dispatcher；导入支持原始 KMP JSON 与旧 `amber.mac.conversation.v1` envelope。
- 导出合并最新磁盘基准和当前未保存消息，保留隐藏候选；保存失败后仍可导出内存快照。导出不保存会话，取消错误继续传播。

实际重新执行官方 Kotlin 2.3.21 + serialization 编译插件后，通过 JUnitCore 跑两类测试共 **13 项**。日志 `/tmp/amber-kmp-canonical-check.log`：

```text
Compiling DesktopBridge and tests with cached Kotlin 2.3.21
Running actual JVM repository and provider tests
JUnit version 4.13.2
.............
Time: 0.403

OK (13 tests)
```

新增测试覆盖：

| 场景 | 证据 |
| --- | --- |
| 完整消息快照 | mixed text／reasoning／image／document／tool 的顺序及完整字段结构相等；提示数量为 3 |
| 稳定 assistant ID | DTO 和 canonical message 的 ID 同时改为指定运行占位 ID |
| 取消终态 | 原 metadata 与混合 parts 保留，仅状态键改变 |
| tool 角色 | 完整 tool-role message 进入 provider 前往返相等 |
| 会话重启 | canonical 保存、读回、旧显示 DTO 回写、再次重开后完整 Conversation 相等 |
| 实际图片外置 | 有效 1px GIF 的合法 comment 块跨既有 16 KiB 阈值；磁盘为 `amber-blob://`，blob 文件字节等于原 data URL 解码结果；重开恢复完整 inline URL |
| 重试候选 | 原 node ID／两个旧候选不变，新 assistant 成为第三候选；后续快照只更新该候选 |
| 导入兼容 | 原始 KMP JSON、旧 v1 envelope、导入副本保留隐藏消息 ID；未知格式与无效 selectIndex 可捕获失败 |
| 旧 v1 可见 metadata | wrapper 的较新标题／置顶覆盖其旧 canonical 值，仅发生于导入；后续普通旧快照保存仍不能覆盖新磁盘 metadata |
| 保存失败后备份 | 存储路径被普通文件占用使保存失败，导出仍包含当前未保存问答、取消终态、原隐藏候选与用户 metadata；原文件未改 |

独立子代理 `kmp_bridge_review` 对 canonical 修复复查后未发现新的确定性问题。原生框架、Swift 对实际生成 header 的类型检查及真实 provider 链路仍未通过验收；上述 JVM 验证没有改变该限制。

供 Swift 端共同验证的 fixture 由**实际已编译 KMP 类型及 serializer**生成：

- `/tmp/amber-canonical-conversation-fixture.json`：完整 Conversation，48,985 字节。
- `/tmp/amber-canonical-envelope-fixture.json`：展示 envelope，74,715 字节。

对应可重建来源为 `desktop-shared/src/commonTest/kotlin/desktop/DesktopCanonicalFixtures.kt`，临时输出文件并非产品数据或独立存储格式。


### 旧 v1 导入 metadata 的独立审查修正

后续只读审查发现：旧 v1 envelope 的标题／置顶可能由 Preview 修改，而其 `canonicalJSON` 仍包含较旧值。已仅在 `normalizeImport` 的 v1 分支应用 wrapper 的 `title`／`isPinned`，正常 `save(existing)` 的磁盘 metadata 所有权保持不变。

新增 `legacyEnvelopeImportUsesVisibleMetadataWithoutChangingExistingSaveOwner` 回归测试后，官方 Kotlin 编译与 **13 项 JUnit 测试全部通过**。独立子代理复查确认修改范围精准，没有发现新问题。
