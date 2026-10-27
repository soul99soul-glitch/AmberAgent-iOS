# Amber macOS 独立阶段评审

最新状态：后续[全面复核与修复](comprehensive-review/review.md)又确认并修复六个问题，253 项 Swift Runtime 回归通过，各阶段均由独立 subagent 复核。该目录记录最新 UI、构建与交付证据；下面是之前八阶段的历史记录，正式 Native 集成仍待验收。

日期：2026-10-23。范围为本仓新增桌面工程、KMP 桥、Swift runtime、UI 与测试；未读取其他产品仓库，未覆盖既有 iOS 未提交改动。

本页运行日志和构建时间按实际宿主CST（UTC+08:00）记录，例如20:27:15相当于UTC12:27:15；未标注的历史时间同样按宿主本地时间解读。

## 结论与验收状态

原生 SwiftUI macOS 外壳，加本仓 `desktop-shared` 生成的 Mac `Shared.framework`，符合当前最小可复用边界。iOS 的 `shared` 聚合入口、XcodeGen 工程和平台专用扩展保持原路径；本轮没有宣称 Core 已独立发布。

当前按 `implementation-plan.md` 的八阶段计划验收。已按阶段独立阅读对应新增实现、修复、生成工程配置与测试记录，并在可用时亲自操作真实预览窗口。亲读20:36:45的最终全套实际Swift Runtime **227项、0 failures**，以及最新Kotlin桥 **82项JVM测试通过**；两者均不包含正式Mac Shared/Swift adapter链接与真实provider验收。下面的“已修复”表示具体缺陷在相应证据范围内闭环，不表示整个应用已通过原生验收。

| 当前计划阶段 | 独立评审结论 |
| --- | --- |
| Phase 1：正式基础与数据契约 | canonical/变体/导入等已随当前227 Swift与82 JVM测试复核；原生Preview关键状态已亲验。正式Mac Shared/header/link、HTTP、Keychain、受影响iOS回归仍未验，阶段blocked |
| Phase 2：完整聊天工作区 | 分支/搜索/回顾/压缩/按需加载及队列源码已读；两处队列保存错误已修并复核。搜索定位、编辑/版本/删除确认、Return/⌘Return、压缩/恢复、深浅停止图标已亲验。表格/公式、860×600审批+3队列上下裁剪、非key深浅stop对比度均已按实际组件复核修复；最新整窗仍待验 |
| Phase 3：服务商与模型 | 配置/目录/OAuth/headers-body/vision与六类aux源码、回归已读；真实Settings旧版草稿切页取消、新模型保存和主窗选择已亲验。新字段UI、真实HTTP/OAuth/Keychain及Shared消费未验 |
| Phase 4：文件与成果 | 文档/真实图片MD-PDF/生图owner文件层已复核，相关测试随227全套通过；真实中文文档导入/全文预览/发送/文件库已亲验，实际媒体PDF3页已逐页查看。真实图片provider/远端生图及新sheet交互未验 |
| Phase 5：Agent 与工具 | 原iOS engine边界、journal/审批/前效持久确认/未知结果和旧Tool防重放已复核；原生任务空态通过。正式engine/Shared多轮执行、审批UI仍未验 |
| Phase 6：知识与 MCP | 记忆高水位/来源/坏文件保护、MCP confirmed-result/取消/owned-process强杀已修并复核，真实stdio父子退出测试通过；原生记忆新增/置顶/保存已亲验。Knowledge Tab最新整窗、外部MCP网络未验 |
| Phase 7：协作与 Recipe | 并发/超时/持久终态/保存原owner/逐步审批已复核；Recipe sheet静默拒绝、confirmed-output取消丢失均已修复，调用详情可读。新页面原生交互和真实多模型/扩展执行未验 |
| Phase 8：备份与持续使用 | 加密/副本恢复/回滚/生命周期/通知/存储/朗读偏好源码已读；WebDAV href身份及已取消调用不再上传已修并复核。旧版原生本地导出恢复/长状态通过，新文案Backup与存储组件完整；其余新UI交互、正式Native、真实同步/音频/通知/分发未验 |

### 历史：最初四阶段口径

下表及后面的早期记录保留当时证据，不再作为当前八阶段计划的完成状态；本轮新结论见文末。

| 阶段 | 当前证据 | 结论 |
| --- | --- | --- |
| Phase 0：路线与范围 | 核查现有 iOS-only KMP/Rust/Python 产物与 UIKit/系统扩展依赖；计划明确桌面聊天产品范围 | 路线评审通过 |
| Phase 1：构建骨架 | XcodeGen 生成成功；实际核对 Debug/Release 配置、嵌入签名标记与测试宿主；新增桥接/存储 JVM 测试 4 项通过 | Mac framework、Swift 消费及最终打包尚未验收 |
| Phase 2：桌面状态与设置 | 设置持久化、独立 Keychain namespace、原生菜单/侧栏及文件权限调用链已读；实际 Swift UI/App/runtime 在仅替换 KMP 边界时通过 Swift 6 typecheck；设置/状态隔离 XCTest 共 14 项通过 | 源码 review 与隔离验证完成；真实 Keychain、窗口与集成验证待完成 |
| Phase 3：聊天与文件闭环 | provider→KMP accumulator→事件队列→原会话消息→串行存储链路已读；停止/重试/错误所有权等修正经隔离 XCTest 验证；生产 Markdown parser 独立编译运行 8 项断言通过 | 源码 review 与隔离验证完成；真实 Mac KMP HTTP 集成测试待运行 |
| Phase 4：产品验收 | 独立 AmberMacPreview 已实际构建、签名核验、启动，并取得默认浅色窗口截图；正式 KMP app 尚未运行 | 预览窗口核验通过；完整产品验收仍未通过 |

## 已发现并逐项复核的修复

| 问题与实际影响 | 修复后的代码证据 | 复核结果 |
| --- | --- | --- |
| 测试 target 写死 `debugFramework`，Release test 会缺少或误用 framework | `macApp/project.yml` 将 framework configuration 放在全局 Debug/Release 映射；app/tests 都使用该变量 | 已读源码与生成 pbxproj，修复已落地 |
| XcodeGen 默认测试宿主仍为 `AmberMac.app/.../AmberMac`，实际产品名为 Amber | tests 显式 `TEST_HOST=$(BUILT_PRODUCTS_DIR)/Amber.app/Contents/MacOS/Amber`；`BUNDLE_LOADER=$(TEST_HOST)`；module 明确为 AmberMac | 已核对生成 pbxproj 的两个配置，路径一致 |
| 停止后没有错误 banner，无法重试；关闭失败 banner 后也失去重试入口 | `DesktopTranscript` 基于最后一条 assistant 的 failed/cancelled 持久状态显示重新生成按钮；回调接到 `workspace.retry()` | 已读显示条件与回调；retry 保留原用户消息且替换未完成 assistant |
| 侧栏折叠时 Cmd+F 只设焦点，搜索框不可见 | `DesktopWorkspaceView` 处理搜索请求时先将 column visibility 设为 all，再设搜索焦点 | 源码闭环；原生焦点与动画仍需运行核对 |
| 首启默认 provider 没有模型，但欢迎页不提示配置 | 欢迎页以所选 provider 的空模型判断配置入口；composer 给出未选择模型文案 | 源码已核对 |
| Keychain 读取失败后编辑器把 key 置空，再保存可能删除原 key | 设置编辑器记录 `credentialLoadFailed`，禁用保存，显示“重新读取”；新建 provider 重置该状态 | 已读失败分支、保存禁用与重试入口；真实 Keychain 交互未验证 |
| Claude 默认/示例地址缺 `/v1`，KMP 直接追加 `/messages` 会请求错误路径 | Claude 默认与提示统一为 `https://api.anthropic.com/v1`；Swift 保存与 KMP 配置桥清理空白和尾斜线 | 已沿 UI→配置桥→`ClaudeKmpProvider` 请求路径复核 |
| 启动加载期间导入可被异步 load 覆盖，新建/发送会静默忽略 | 主界面显示读取进度；composer、新建与导入入口使用 `isLoading` 禁用；App 菜单同样禁用 | 源码入口均已核对 |
| 模型 Picker 用嵌套 `$workspace.settings` 绑定穿透只读 settings，实际 Swift 编译失败 | Picker 改为显式读取/写入 `selectedProviderID` 的 Binding，仍写入同一 settings owner | 已独立读修正源码；实际 UI 的隔离 Swift 6 typecheck 通过 |
| Quit 未消费持久化队列，最后 partial/checkpoint 可能丢失 | `AmberMacAppDelegate.applicationShouldTerminate` 先 stop，再 await flush，使用 flush Bool 回复终止；失败保留窗口；flush 重试未保存会话 | 已读 App delegate 与 runtime 接线；真实应用终止流程待运行 |
| 连续读附件、删除附件或发送期间，异步回调会用旧附件快照覆盖状态 | runtime 按原 owner 在读取完成时合并最新附件；读取计数阻止提前发送；删除原会话后不再回填；UI 展示读取进度并禁用发送 | 已核对所有权、合并与限制；新增并发附件测试已读 |
| 删除持久化失败时 UI 已移除会话，内容未恢复 | 删除失败恢复会话、草稿与附件并显示具体错误；成功删除清理先前 unsaved 标记，避免 flush 永远失败 | 已核对成功/失败分支及对应失败存储测试 |
| A 会话生成失败时，B 会话显示 A 的错误且重试目标错误 | 生成与保存错误按 conversation ID 记录；只投影到对应选中会话，切回原会话恢复错误 | 已读 `recordError`、apply 与 select；对应所有权测试已读 |
| Markdown 表格吞掉 Windows 路径/正则反斜杠，四字符 fence 被内部三字符 fence 提前关闭，末尾转义 pipe 误删单元格 | parser 保留普通反斜杠和 code 内容；按开 fence 长度匹配纯关闭标记；仅移除真实尾分隔产生的空项 | 独立编译当前生产 parser，8 项断言实际通过；包含先前复现失败的 `A | B\\|` 案例 |

## 调用链与边界复核（早期记录）

- 服务商配置只将非凭证参数写入 defaults；API key 使用独立 Mac Keychain service。发送时捕获 provider、key、model 和系统提示词，运行期间更改设置不会改写已开始的请求。
- Swift 显式消费本仓 KMP OpenAI/Claude provider 与 `MessageStreamAccumulator`，没有另写平行 SSE 协议实现。信号队列在 terminal 后拒绝迟到事件；Stop 先取消再 drain，保留已接受的 partial，已经排队的 complete 优先于后到的 stop。
- run 使用 conversation ID、assistant ID 和 generation token 定向回填；切会话只保存/恢复当前草稿，不解除 app owner。重试不重复追加用户消息。
- 会话使用 canonical KMP JSON 存储；Swift 串行 writer 保持 save/delete 顺序，metadata 单独写入。导入分配新会话与消息 ID；启动恢复把 streaming checkpoint 转为 cancelled 并保留正文。
- 文件读写使用用户选择的 URL，并在后台读取/编码；security-scoped access 在同一操作中结束。文本附件有大小、数量、编码边界；导出不包含 provider/key。
- 当前产品范围是桌面聊天闭环。手机控制、Watch、Live Activity、AlarmKit、iSH、嵌入式 iOS Python 与未实现的 agent 工具不会展示为空能力入口，也没有计入已完成能力。

## 实际验证与阻塞（早期记录）

本评审独立运行了当前生产 `DesktopMarkdownParser.swift` 的 Swift 编译与 8 项断言，输出为 `Independent production Markdown parser: 8 checks passed`。覆盖未闭合代码块、关闭后的正文、长 fence 内嵌短 fence、表格 pipe/反斜杠、尾部转义 pipe、普通段落及空输入。

已读取 `/tmp/amber-mac-runtime-test.log`：实际 Swift runtime 的 11 项 workspace 测试和 3 项 settings 测试，共 14 项 XCTest、0 failures。独立比较临时测试工程与产品源码，`DesktopModels`、`DesktopSettings`、`DesktopWorkspace`、`DesktopFixtures` 完全一致；KMP provider/storage 与凭证使用测试替身。因此它验证停止/终态/切会话/重试/恢复/错误归属/删除失败/保存失败/附件并发与设置接线，不代表真实 KMP adapter 或 Keychain 验证。

实际 App、所有 UI、models/settings/workspace/fixtures 在仅 KMP provider/storage 使用替身的配置中，Swift 6 typecheck 已通过；修复了真实编译发现的初始化和 Picker Binding 问题。这保留了真实 SwiftUI 类型检查，仍未覆盖新 `Shared.framework` 的 Objective-C header、链接与运行。

已读取 `/tmp/amber-kmp-direct-check.log`：Kotlin 2.3.21 直接编译新增桥和测试，JUnit `OK (4 tests)`。其平台与依赖限制见 `kmp-validation.md`；这不是 Mac framework 测试，也未重新编译所有既有 KMP 依赖。

已读取 `/tmp/amber-mac-xcode-build.log`：Xcode 构建实际失败于 Gradle 启动本地文件锁服务，错误为 `FileLockContentionHandler` / `java.net.SocketException: Operation not permitted`。失败发生在 Mac framework 编译与 Swift 消费之前，不能据此判断后续编译正确性。SwiftUI 的独立 typecheck 起初被宏子进程的 `sandbox_apply` 限制阻断，调整编译器宏执行选项后，上述仅隔离 KMP 边界的 typecheck 取得通过证据。

仍需正常环境中的真实证据：Mac `Shared.framework` 编译与架构、Swift 头文件消费与链接、正式 app 内嵌 framework 签名和最终 entitlement、真实 Mac KMP provider fixture 测试、Keychain/文件选择器权限、现有 iOS Swift 消费回归，以及正式 KMP app 的窗口运行。

## UI 验收的明确限制（早期记录）

已从源码核对默认/最小窗口尺寸、原生标题栏、侧栏约束、正文与输入器共用 860pt 最大宽度和横向 24pt 边距、长标题省略/tooltip、图标可访问名称，以及明暗主题选择接线。

本轮继续推进后，已由独立评审者通过 CUA 只读 `getApp` 与 `getScreenshot` 亲自查看实际 AmberPreview 原生窗口，未点击或改变状态。当前默认浅色窗口中，正文、代码块与输入器的左右边缘一致；表格列和边框未见错位；侧栏搜索、列表与底部设置对齐；顶部预览提示完整可读且未遮挡工具栏；长会话标题及模型名按预期省略，AX/help 保留完整模型说明；输入器按钮未重叠，空输入的发送按钮为禁用态。当前截图未发现需要修复的确定性布局缺陷。

上述结论仅覆盖这张默认浅色预览窗口截图。最小/宽窗口、深色、设置、键盘焦点、文本选择、滚动历史中的增量更新与回底手感尚未独立验收；没有作出“所有 UI 状态没有错位”或“正式 KMP 产品已交付”的结论。

## 独立原生界面预览的边界与运行证据（早期记录）

`AmberMacPreview` 是独立应用 target，bundle ID 为 `app.amber.macos.preview`，显示名为“Amber 界面预览”。已独立核对生成的工程：该 target 仅有 Sources/Resources 阶段，没有 Gradle phase、Shared.framework 依赖或正式 app 的构建依赖；两个配置都显式定义 `AMBER_MAC_PREVIEW`。正式 `AmberMac` 的生产调用链仍为 `DesktopWorkspace()` → `DesktopLiveWorkspace` → 真实 Settings/KMP provider/KMP storage，原数据目录未改。

预览直接复用相同的 Workspace、Generation、storage protocol、models 和正文/输入器/侧栏视图，只排除生产 composition 与两个 KMP adapter。独立 Preview `@main` 无条件注入 `uiFixture`，使用内存 provider/storage/credentials 和独立 `app.amber.macos.ui-fixture` defaults suite；没有默认回落到真实配置或 Keychain 的路径。预览设置不提供真实 API Key 输入，并明确说明本地示例与本次预览语义。屏幕常驻“界面预览 · 会话仅保留本次运行 · 未连接模型服务”。

本评审已独立检查实际文件 `macApp/build/Build/Products/Debug/AmberPreview.app/Contents/MacOS/AmberPreview` 为 Mach-O arm64；独立执行 `codesign --verify --deep --strict` 通过，读取实际 entitlement 包含 app sandbox 和 user-selected read-write。随后通过 CUA 看到真实可访问性树与窗口截图，因此“预览已构建且能打开界面”已有实际证据，不再只是 typecheck 或源码判断。

主代理随后验证 Cmd+N 可实际新建会话；后续输入/发送操作期间 UI transport 与执行环境再次断联，发送 smoke 未完成。本报告不把该操作记为通过，也不把预览成功当作真实 KMP、外部 provider 或持久化产品已完成。

## 完整 TODO 续推：Phase 1 源码复核

本节记录续推计划中的本轮修改，不表示正式应用阶段已验收。

- **生成归属入口通过源码复核**：`DesktopComposer` 只在 `isGenerating && generationConversationID == selectedID` 时显示停止；其他会话显示返回原任务的入口，调用 `select(owner)`。`DesktopWorkspaceView` 的列表运行指示使用同一个 owner ID。已连同 Workspace 的 start/apply/terminal/select 路径独立阅读，未发现确定性逻辑缺陷；这不是运行中布局的截图验收。
- **可复现隔离测试边界已核对**：`scripts/test-runtime.sh` 复制当前真实 Runtime 源码，排除两个 KMP adapter 和 live composition，并排除 KMP integration tests；没有生成假的 Shared API。module cache 默认落在临时测试目录且尊重外部设置。本评审独立运行该脚本，20 项 XCTest（parser 6、settings 3、workspace 11）通过；这是后续 settings 新增测试之前的源快照。执行仅关闭 SwiftPM/Swift 宏的嵌套沙盒，外层执行权限不变。该结果不覆盖 Shared、真实 provider、Keychain、SwiftUI 布局或正式链接。
- **设置本轮源码复核通过**：切换服务商前的保存、放弃、取消分别处理，保存失败不切换；“保存并设为当前”先保存配置和凭证，再持久化所选 ID；字段改动撤销旧成功提示。凭证读取失败时，保存、设为当前与切换对话框的保存入口均禁用。Model ID 在凭证写入和 providers 修改之前 trim 并校验，发送与重试入口仍有独立校验。
- **设置重复出现保护已复核**：`DesktopProviderSettings` 使用局部 `@State didLoad`，只在首次 `onAppear` 执行 `applySelection`，后续出现不因无条件重载覆盖本地编辑。它没有引入新的编辑框架或生产 target。

本评审已独立阅读最新 6 项 `RuntimeSettingsTests` 与产品调用方；作者报告该 6 项执行和真实 Settings View/依赖 Swift 6 typecheck 通过。本评审未新增 harness，也未把作者的 typecheck 视为正式窗口证据。真实 Keychain、正式服务商编辑器交互和视觉仍待验收；Preview 的设置页面不包含该编辑器。完整 canonical 消息契约和正式 KMP 构建仍由后续独立 review 验收。

## 本轮最终复核：canonical、footer 与任务归属

### 完整消息调用链

已独立阅读最终 Swift Models、Generation、真实 KMP provider/storage adapter、Workspace、全部协议实现及 Kotlin DesktopBridge，与本仓原 Conversation/UIMessage/accumulator/storage 连接核对。`responseID` 从 assistant 占位传至 snapshot，同时修改外层与内层消息 ID；四字段 snapshot 保留完整 canonical payload，终态与 checkpoint 经同一 owner 和 FIFO 队列保存。保存返回的 canonical baseline 可回写，但只有当前消息仍等于提交快照时才补回该消息 payload，旧保存结果不会覆盖新流内容。

Kotlin 以现存完整 Conversation 为保存 base，用原 `updateCurrentMessages` 保留 node ID、隐藏 variants 及其他消息字段；重试的新 assistant ID 成为同槽 variant，旧 assistant 不再加入该次 provider 请求。普通消息写入与 title/pin metadata 更新分别排队、分别记录失败；首条消息自动标题也走 metadata 路径。导入只分配新 conversation ID，保留内部 message/node/toolCall ID；保存成功后才发布副本。导出先排空已接受事件，合并当前内存内容和完整 baseline；保存失败仍可生成备份，异步导出失败归原会话。

本轮独立发现并复核修复了旧 v1 导入缺陷：当 envelope 的 title/pin 比内层 canonical 新时，导入曾恢复旧 metadata。现在仅在 `normalizeImport` 的 v1 分支应用外层 title/pin；普通 `save(existing)` 仍保留磁盘 metadata owner。新增测试同时检查导入 metadata 正确，以及后续旧快照保存不能覆盖磁盘新 metadata。未扩大为新的迁移或编辑框架。

已亲读 `/tmp/amber-kmp-canonical-check.log`：官方 Kotlin 2.3.21 编译新增桥与测试，JUnit **13 项通过**。已亲读 `/tmp/amber-mac-runtime-canonical-test.log`：实际 Swift 6 源码的 **31 项 XCTest 通过**（Workspace 17、Settings 6、canonical envelope 2、Markdown 6）。本评审还独立读取真实 serializer 生成的 `Fixtures/CanonicalEnvelope.json`：2 个 nodes，末 node 有 2 个 variants、selectIndex 为 1；消息有序包含 Text/Reasoning/Image/Text/Document/Tool，并带 model、usage、annotations、时间和 metadata。Swift 测试逐字保留 conversation/message opaque JSON，不在产品 Swift 中另建平行 parts schema。

这些证据覆盖 canonical 数据保真、协议传递与隔离状态机；Kotlin 测试使用 JVM 和本机缓存依赖，Swift 测试明确排除三个 Shared adapter/composition 文件及真实 provider 集成测试。**它们不证明 Mac framework、Objective-C header、Swift 真实 adapter 编译/链接、HTTP 或 Keychain 已通过。** MAC-002 保持待正式集成验收。

### footer 与真实窗口复拍

本评审通过 CUA 操作已运行的原生 Preview，亲自取得以下 AX 与截图。它复用产品界面，仍使用独立内存示例和预览设置。

| 实际状态 | 独立观察 |
| --- | --- |
| 浅色空态、浅色短会话 | 输入器、快捷键与底部预览说明相互独立；短会话首条“你”的图标、身份及卡片完整可见 |
| 深色空态、深色短会话 | 同样未见原顶部灰条覆盖首条身份；输入器与 footer 无重叠 |
| 深色长会话，滚动条为 0 | 首条身份完整，正文、表格与输入器左右边界一致 |
| 深色长会话，滚动条为 1 | 最后正文完整结束于输入器之前，输入区和预览说明未覆盖末段 |
| 最终构建的结构化本地示例 | “系统”“你”“Amber”“工具”身份各自正确；“另有 3 项内容暂未显示，原始数据已保留”完整可读且未与正文重叠 |

本轮截图为约 1121×653 pt 窗口（2242×1306 像素）；没有取得或宣称 860pt 最小宽验收通过。上述顶部覆盖缺陷在这些实拍状态中已修复，不代表所有尺寸、正式设置编辑器或真实 provider 流式窗口已通过。

### 恢复后的本地交互证据

前文保留了早期 transport 断联导致发送 smoke 中断的历史。环境恢复后，主代理已执行本地完整示例发送；本评审随后只读看到同一用户消息“体验桌面版的输入和会话交互。”、明确声明未连接真实模型的 assistant 回复，以及清空的输入与禁用发送按钮。该本地补验通过，不能视为网络请求或正式持久化证据。

最终构建中，本评审亲自执行新建→输入“独立检查运行归属与停止后的内容保留。”→发送→再新建。AX 和截图显示原会话行有 busy 标记，当前新会话输入器只有“查看生成中的会话”入口。点击该入口再按 ⌘.，成功回到原 owner 并停止；已收到的部分示例回复保留，“已停止”和“重新生成”可见，busy 消失，空输入发送禁用。footer 始终说明未连接模型服务。示例 Task 的取消只取消本地 Task，终态由原 Generation 队列发布，未执行外部工具。

评审结束时保持该浅色停止会话窗口打开。本轮没有剩余未修复的确定性源码缺陷；当前八阶段计划的 Phase 1 仍受正式 Native 集成验收阻塞，Phase 2~8 尚未验收。

## 八阶段续推：Phase 2 独立检查（进行中）

本节为后续检查的新证据；前文阶段状态和测试数保留其当时范围。独立评审者重新阅读分支 storage/Swift 消费、搜索投影/定位、Markdown、Insights/controller/退出接线，以及后续 summary 按需读取实现，没有把作者截图当作独立截图。

### 逻辑与调用链

- 编辑/重生成会先持久化新分支，再发布消息并启动请求；版本切换保留后续消息，删除仅移除目标节点的全部版本。孤立 assistant 的重生成在 Swift/Kotlin 两端明确拒绝；消息保存成功不再清除尚未保存的 metadata 错误。
- Insights 结果按原会话和 source message IDs 验证；压缩覆盖较早前缀，最近两个实际用户轮次保留。`prepare` 只改变后续 provider 输入，不重写 transcript。取消不发布部分摘要；会话持久删除后才移除 sidecar，晚回调不能复活记录。普通聊天 stop 不取消辅助请求，应用退出专门 cancelAll 并等待 flush。
- 本评审发现“压缩结果可能比原文更长”后，作者将实际注入摘要的同一 `compactMessage` 用于 token 比较，只有估算用量严格减少才保存；否则保留原摘要和完整原消息。已独立复读源码及旧 compact 保留、clear 恢复完整输入的回归断言。此处是估算，不是 tokenizer 或正式 provider 预算保证。
- 后续长历史实现以 summaries 初载，仅按选择读取完整文档；读取完成用当前 summary 的 title/pin，删除以 summary 存在检查阻断晚读复活。搜索读取全库正文投影，已加载会话使用实时缓存覆盖旧结果，失败有明确重试入口。

亲自读取 `/tmp/amber-mac-phase2-current-test.log`：对应源快照 **60 项 XCTest，0 failures**。亲读 `/tmp/amber-history-tests.log`：6 项按需读取/搜索测试通过；`/tmp/amber-workspace-phase4-tests.log`：history + Workspace 共 23 项通过。以上运行均为真实 Runtime 源码的隔离测试，不包含正式 Shared adapter、HTTP、Keychain 或 SwiftUI 布局。后续并发修改不自动继承旧测试结论。

### 原生 Preview 交互与精准问题

评审者通过正常 CUA 退出/重开最终 Preview，并亲自完成以下操作。所有内容均为明确标注的内存示例，未连接外部模型。

| 实际操作 | 独立结果 |
| --- | --- |
| 搜索 `nextStep`，点击消息匹配结果 | 摘要清理 Markdown，命中词可见；主区定位到含代码的 assistant 消息，未跳回底部 |
| 用户消息“编辑并重新发送” | sheet 明确显示后续 1 条将移除；编辑后生成，用户版本 2/2、忙状态与原会话对应 |
| 停止新回复，再切上一个用户版本 | 已收到 partial 保留，重生成入口出现；用户恢复 1/2，后续 assistant 保留，符合按钮说明 |
| 删除 2 版本消息并取消 | 确认框准确说明“全部 2 个版本将被删除，其他消息会保留”；取消后数据未变 |
| 会话回顾生成 | 忙状态、停止入口、禁用生成入口到完成结果/日期均实际出现；示例回复仍明确说明未连接真实模型 |
| 阅读排版 fixture | 有序/嵌套列表、嵌套引用与长代码横向滚动结构可见；长表格单元格实际被省略号截断，已交作者按固有高度修复 |
| 空新会话输入第一行后按 Return | 原生 TextField 将第一行全选；继续输入会替换第一行，未换行。已交作者精准修复按键行为，保留 ⌘Return 与 IME 路径 |
| 浅色生成中停止按钮 | 黑色按钮上的 stop 符号近黑，辨识度不足；已交作者修正符号前景对比度 |

表格固有高度和 Return 源码修复已落盘，待统一新构建亲自复拍；停止按钮同样待复验。尚未完成 860pt 最小窗口、宽窗口及完整深浅色矩阵；公式/语法高亮也不能由当前 Markdown 实现代为宣称完成。popover 的应用窗口截图会裁掉超出窗口的原生浮层部分，AX 控件可达，当前证据不足以把该截图边界判作产品越界缺陷。

后续统一新构建复拍：评审者亲自输入“独立第一行”→Return→“独立第二行”，AX 与截图均保留两行，再按 ⌘Return 成功发送并清空草稿；该修复已在普通输入下闭环，真实 IME 组合输入未验。长会话压缩实际显示 **2,034→159 tokens**，点击“恢复完整上下文”后回到 **2,034 tokens**，8 条历史仍保留。表格第二次复拍仍有缺陷：省略号消失后文本确实换行，但父 Grid/水平 ScrollView 行高仍只给单行，后续文字被底边裁掉；已交作者继续修父测量。浅色停止按钮的新构建仍为近黑符号/黑底，外层 foregroundStyle 未解决，已交作者调整图标自身样式。因此这两项未冒记为通过。

## 八阶段续推：Phase 3 独立检查（源码与隔离验证）

已独立阅读 provider/model configuration 的旧单模型迁移、稳定 UUID、启用选择、参数字符串转换/校验、目录 merge/取消、辅助模型选择及其 Workspace 消费；KMP params 确实收到同一 selected model 的 ID、名称、temperature、max output、reasoning 和 context window，已知模型能力来自现存 registry。Swift 继续复用原 OpenAI/Claude KMP provider、Responses 开关，以及本仓 Foundation Gemini client，没有新增平行 SSE 实现。

Codex 登录与发送使用同一小写 provider UUID 对应 Mac 独立钥匙串 namespace；真实 resolver 在请求前刷新 token 并使用 Codex backend/必需 headers，不改写持久保存的 endpoint。目录使用 OrThrow 路径，不把失败冒作 fallback 成功；连接测试执行真实最小生成调用而非只取目录。普通 auth/协议匹配在保存前验证。

独立发现并复核了连接测试的状态错映：测试 A 模型期间编辑为 B，原实现未取消，旧结果会在新配置下显示成功。作者将连接测试单独标记，编辑模型/参数时只清除该测试，目录请求仍独立；已重读修复。设置切换 provider/tab 的保存、放弃和取消，以及失败不切换已读。删除入口先等待该 provider 旧登录任务终止，再清除 OAuth 凭证，成功后才删除 API Key/配置；取消登录后的旧 task 仍被跟踪，避免晚写 token 复活。

亲读 `/tmp/amber-kmp-phase3-check.log` **25 项 JVM 测试通过**，后续 Phase 4 桥快照为 29 项；这只覆盖真实 Kotlin 桥/原消息结构。亲读 `/tmp/amber-mac-phase3-and7-isolated-tests.log` 对应真实相关 Swift 源最小包 **26 项通过**（含模型/OAuth/目录和协作），以及最终 SettingsView 的 typecheck 记录。设置 View 仍需复用真实页面的原生截图/交互；简化 Preview 设置页不能替正式服务商页验收。正式 Mac Shared/header、HTTP、Keychain、真实网页登录/刷新/退出均未验收。

## 八阶段续推：Phase 4 独立检查（源码与文件证据）

已阅读文件选择/拖入/粘贴图片→后台读取→附件预览 DTO→原 owner 合并→provider.userMessage→KMP 原 UIMessagePart 的调用链。图片保持真实 MIME/data URL 和缩略图；文档按文字进入上下文。PDF 逐页提取并明确报告扫描页无 OCR；DOCX/RTF 使用原生解析；PPTX 按 presentation.xml 与 relationships 的真实幻灯片顺序，支持 stored/deflate 并校验 CRC。原文件归每会话 Workspace 保存，导入同名自动另名，路径/符号链接边界在同一 actor 处理。

独立发现可读导出漏图：KMP 的 unsupported count 已排除 Image，而 Markdown/PDF 未输出图片。作者现按真实 images 投影输出数量/名称和完整 JSON 保真说明；已重读小修及 image-only/mixed 回归。亲读 `/tmp/amber-mac-files-tests.log` 最新 **9 项通过**。评审者另外独立编译真实 Models/ModelConfiguration/MarkdownParser/ConversationExport 四份源，用临时 harness 生成真实 4 页 PDF，并亲看 PDFKit 渲染首张：中文、标题、身份、列表/引用缩进、表格转可读标签、长代码换行与页脚无截断/重叠；此证据只覆盖该导出样例。

独立发现 Workspace 文件操作在 A 发起、切 B 后失败会被静默丢弃。作者已按原 owner 记录 fileErrors，并在切回/重新读取时投影；成功读取只清读取错误，不清未完成的操作错误。已重读该修复；对应最新测试及真实文件选择器/权限、图文发送、Preview 文件面板仍需补验。之前 history 6 项和 Workspace/history 23 项通过不覆盖之后所有新文件 facade。正式图片 provider 与 Shared 数据往返仍未运行。

## 后续原生补验（20:04 CST（UTC+08:00））

所有操作由独立评审者通过 CUA 亲自完成，仍在明确标注的本地 Preview，内存消息/设置和真实临时文件不代表正式生产持久化或网络。

- Phase 2：图标自身 foreground 修复后，浅色黑底白色 stop、深色白底黑色 stop 均亲眼可辨。普通 Return 两行及 ⌘Return 发送保持通过；真实 IME 和 860pt 最小宽未验。有限列宽版本的表格第三行仍被父 Grid 裁掉；作者后续用完整 NSHostingView/ScrollView/LazyVStack 复现并换自然测量的专用 Layout，尚待下一统一 binary 亲验，未将作者截图记作独立证据。
- Phase 3：原 DesktopSettingsView 实际显示服务商/通用页面，预览 banner 清楚说明不提供网络。改服务商名后切通用，保存/放弃/取消提示出现；取消保留草稿。手动添加 `independent-review-model`，设置 context 8192、temperature 0.3、max output 1024，保存并使用后实际 2 个启用模型与当前 checkmark 正确，主窗口模型同步；重新打开保留参数。新 MCP/同步 tabs 尚未包含在本轮 binary。
- Phase 4：原生 NSOpenPanel 选择实际 `notes_zh.md`，附件预览显示正确文件名、253 bytes、136 字符和完整中文/Markdown 源文。发送“请核对这份中文附件。”后，消息包含命名附件完整内容，附件草稿清空；文件库显示真实原文件及字节/日期，行布局无错位。未测试真实图片 provider。
- Phase 5：任务工作台为真实空态，没有虚构调用记录；标题、说明、完成按钮和空态居中无重叠。它不证明审批/工具执行已经原生运行。
- Phase 6：原生新增中文记忆、置顶、保存后，列表出现真实 ID 1000 的内容与置顶状态。发现知识页 Tab 条被压成仅约25pt的“S…”入口，三个页面视觉不可辨；AX 均存在。已交作者仅修该控件宽度/标签，待下一构建复拍。
- Phase 8：通过原生保存面板导出实际 `independent-ui-review.ambermacbackup`，再从原生打开面板选择该文件恢复。完成结果明确报告 8 个会话副本、1 个配置副本、1 条记忆，原记录保留，另有恢复资料会话。约150字的成功状态在620×440面板全部可见，完成按钮可见，没有为假设溢出新增滚动容器。

## 八阶段续推：Phase 5 独立检查（源码闭环）

已独立阅读 DesktopAgentProvider → 原 IOSAgentToolEngine → DesktopAgentExecutor/EngineLedger → DesktopAgentJournal/审批 → Workspace transcript 的实际调用链。Live composition 对 tasks/files/knowledge/MCP/collaborations 注入同一实例，任务与协作使用真实 Application Support 目录。工具目录、暴露发现和执行器同名接线；memory 来源在 executor 写入真实 owner/最后 user message，编辑不允许模型改写来源。

新 run 对旧历史中空输出 Tool 仅在 provider 请求副本填 `not_resumed`，防止原 engine 将历史未确认副作用自动执行；原 canonical 和已完成 output 不改，当前 run 审批 resume 不经过该 helper。原子 journal 在执行前记录 prepared/started，未知结果不自动重放。独立发现 MCP 未知结果曾进入普通 failed、以及 cancelled 抢先覆盖 unknown 后，root 已加入专门 outcomeUnknown 并优先于 cancellation 分类；最终代码已重读确认。

CommandRunner 使用 posix_spawn process group、并发排空限量输出、超时/取消终止进程组，并在 shell 退出后清子进程，避免普通后台进程继续占管道。未要求 daemon 能力。iOS 平台边界 diff 已读；被抽出的 JSON object 和 Stage/policy 原定义与旧体逐字一致，iOS 条件真分支保留原逻辑。正式 Shared header/link、Mac engine 执行和受影响 iOS 运行回归仍未验证。

## 八阶段续推：Phase 6 独立检查（知识与 MCP）

已读 Knowledge Store/Tools 实际持久化、SKILL/SOUL 文件、启用状态、记忆字段/有效期/查询/来源及上下文消费。记忆 scope 先过滤再 limit；允许有 title 的空 summary 主题，保持原 iOS 语义。独立发现删除最高 ID 后会重用旧 ID 并误关联 supersedes；作者现先原子预留独立 high-water，再写主体，失败只跳号，删除同时清 supersedes/member，恢复 merge 复用同一计数，已复读回归。

MCP manager 对配置代次/工具目录有 owner 检查；实际确认结果不能因晚取消被丢弃。独立发现成功 result 后检查 cancellation 会丢已确认输出，作者已去除 result 之后的 guard；连接目录仍保留代次检查。损坏 Store 原来可能在读取失败后被编辑覆盖，现独立 loadFailed 阻写，缺 credential 的可恢复状态另行处理，原坏 bytes 保留。stdio 使用真实子进程；HTTP/SSE 目前为协议 fixture，不冒作外部 server 成功。

亲读 `/tmp/amber-knowledge-recipes-highlights-tests.log`：Knowledge 9 + Recipe 6 + code highlights 2，共17项通过。亲读 `/tmp/amber-mcp-webdav-tests.log` 20:05:56快照：15项通过，包含真实 stdio 子进程与取消退出，以及 WebDAV fixture；不包含真实远端服务器。

## 八阶段续推：Phase 7 独立检查（协作与 Recipe）

协作 route 在开始前解析每位成员的启用模型、参数和 key；每次 execution 使用独立 UUID，避免同 member 跨 run 相互取消。全局队列限并发，取消清等待者，超时终止 generation；只复制公开 text，不把 reasoning 当公开结果。议会先席位并行，再以标注状态的资料做真实综合；部分成功/全部失败分类明确。持久 store 开始保存成功后才调用 provider，终态等待保存，重启将未结束记录明确中断且不重放。

Workspace 保存协作结果等待终态和原 parent 完整加载，进入同一串行 writer，写真实 markdown 产物、保存会话成功后才发布引用；run UUID 为消息 ID，重试幂等；错误留在该 run/原 owner。删除 owner 取消其协作/Recipe；flush 等已接受的保存任务。Recipe 为同 amber.recipe.v1 wire 的固定顺序流程，注册工具/绑定/输入类型先验证；每一步沿用真实工具审批和 journal；失败、未知、取消、超时不执行后续步骤，结果写持久任务。嵌套 JSON 属 literal，与原 iOS 顶层 binding grammar 相同，未扩展新语法。

亲读 `/tmp/amber-mac-phase3-and7-unified-tests.log`：32项通过（配置/凭证/协作/偏好相关）。亲读 `/tmp/amber-workspace-phase-final.log`：最新54项 Workspace/文件/附件/备份/协作保存等相关测试全部通过。不同源快照不直接相加为覆盖率。新 Collab/Recipe 页面尚待统一 binary 亲验；已向作者报告 Recipe facade 拒绝运行时 sheet 丢弃 optional、错误藏在主窗口的问题，待精准修复。

## 八阶段续推：Phase 8 独立检查（备份与 WebDAV）

本地格式明确为独立 Mac backup，复用 PBKDF2-SHA256 210000/AES-GCM 参数，不冒称 iOS 整体 backup 互通。先完整 decode/验证所有会话、配置、路径/重复项和 sidecar，再 stage/分配新 UUID/写副本，全部成功后 publish；失败回滚本次新增项。凭证不包含在内；SOUL/skill/preferences 资料副本需检查后导入，未自动覆盖本机值为明确产品约定。

独立发现全空格密码曾被 trim 为明文，与界面“已加密”矛盾；现只以 isEmpty 判断，空格作为真实密码，相关回归已读。退出先 cancel backup/WebDAV/协作/Recipe/tasks/Insights/chat，再等待 backup/Recipe/协作/Insights/workspace，未把 backup task 放进会自等待的 flush。WebDAV 必须加密 archive、上传新 UUID 文件且 If-None-Match:* 禁覆盖，配置密码独立 Keychain，下载先离线 decode 预览再明确导入副本。

新 WebDAV source 独立发现真实资源身份问题：Mac 使用旧 helper 的 displayName 作为文件地址，合法 displayname 与 href 不同时会漏列/请求错路径，href 的 percent 编码还可能二次编码。已交作者给 Mac 增加从 href decode 恰一次的真实文件名，保留 iOS 旧默认行为，待源码与回归复核。真实 Keychain/同步网络/通知/正式分发仍未验证。

亲读 `/tmp/amber-kmp-final-check.log`：真实桥与原依赖由 Kotlin 2.3.21 编译，80项 JVM 测试通过，包含 pending-tool 防重放；这是 JVM 证据，不是 Mac Native/正式 Swift 消费。所有阶段继续区分源码闭环、隔离测试、原生 Preview 和正式集成，当前不宣称整个产品已验收。

## 最终增量复核（20:10 CST（UTC+08:00），持续中）

- Phase 5 新增前效 checkpoint：已独立读 `DesktopRunContext.persistTurns` → AgentProvider 的 `onAssistantTurnCompleted`/`prepareRequestMessages` → Workspace。token/owner/prefix 在 provider start 前建立；只传新增 turns，保原完整 history，串行写入并等待该 captured writer，写失败返回 false 阻断后续工具/模型轮；完成后再查 token/owner/消息保存状态，未调用可能自等待的 flush。metadata 错误独立保留，不误阻断已保存的消息。3项新 spy 测试源码已读，执行日志待收。
- Phase 7 Recipe invocation 在任何工具执行前，以真实 KMP typed Tool 构造、准备事务并保存 canonicalInvocation，重启可保留真实 args；Tasks 已新增“调用详情”可展开原文，不把 digest 当参数。此前 facade optional 丢弃反馈问题，作者已在当前 sheet 显示具体错误，并禁用 selected loading/unavailable；独立复读确认。
- Phase 8 WebDAV 真实身份修复已复读：新增 `remoteFileName` 从 href 的 percentEncodedPath 末组件 decode 恰一次，仅 Mac filter/GET/DELETE 使用；displayName 与原 iOS `.fileName` 不改。新测试同时覆盖中文显示名无扩展名、误导显示名、空格和 literal `%20`，断言 GET/DELETE 实际 URL。亲读 `/tmp/amber-mcp-webdav-tests.log` 20:08:14：16项通过。
- Phase 6 新发现 stdio 取消泄漏：close 丢 process 引用后只 SIGTERM，明确忽略 SIGTERM 的 server 将继续驻留。已向作者给出 `signal.signal(SIGTERM,SIG_IGN)` 的具体 Python 场景，请最小加入有限宽限后的 owned-child SIGKILL 和真实退出回归；此修复尚未复核。
- Phase 8 通知/存储用量增量源码已读：通知默认关闭，只有设置显式启用请求授权，发送不再弹授权、按 run UUID 防重复、只含泛化文字与原 owner IDs，保存成功后才调用。存储统计在后台读取实际目录，不扫描凭证，不跟随符号链接；未知位置明确未统计。亲读 `/tmp/amber-mac-model-collab-notification-tests.log`：41项通过，包含通知 spy 与协作持久结果后通知。未触发真实系统授权或通知送达，不将 spy 视作系统验收。

20:16补充：亲读 `/tmp/amber-workspace-consumers-fixed.log` 28项通过，包含前效持久确认3项、通知consumer3项、备份生命周期1项、存储3项与备份10项。停止期间前效 writer 可保存最后已接受 turns，真实 BatchExecutor 在派发前再次检查 Task.isCancelled 并记录 cancelled_before_execution 后返回，不因 token 为 async stop 暂留而继续执行。无需额外 isStopping guard 将正常取消误报为 durability failure。

MCP 取消泄漏修复已复读并闭环：只将成功launch后 getpgid(pid)==pid 且非宿主进程组的值记为 owned group；TERM 后500ms仍存活则 KILL，未满足条件时仅处理直接child。Manager保留termination task并提供shutdown等待，退出delegate也已awaitshutdown。真实Python fixture 的父/子都忽略TERM且stdin EOF后继续sleep，回归断言两PID实际消失；亲读 `/tmp/amber-mcp-webdav-final.log` 20:16:28，18项通过。WebDAV真实身份修复仍通过该轮回归。

Recipe确认输出后取消的小修也已复读：取消timer返回nil，不抢先吞已确认primitive结果；先登记completed步骤，再终止后续步骤。新增实际回归及 `/tmp/amber-recipes-tests.log` 20:12:35的7项通过已读。

最新完整同源Preview含真实iosMath、表格自然测量Layout、Knowledge tabs及新页面，于20:14:59构建/签名成功。但CUA随后报告Mac locked，需要physical input恢复；尚未重启新binary，不将该构建记为本评审最终整窗复拍。独立查看作者生成的实际Native组件PNG表明该表格样例末“一致。”及同行边框完整、行内/块公式/中文基线和代码/货币符号正常；这只作组件渲染产物证据，不代替最终app验收。

20:18 Phase 4增量：MD现输出真实Image URL/data URL，PDF用CTRunDelegate预留实际自然高度并绘CGImage，带EXIF方向转换；远程图只保留链接不自动下载，不能解码的图明确说明。独立发现全部图片原尺寸解码并留在AttributedString会令常见照片导出占用过大，作者现按最大650pt×3限制ImageIO解码最长1950px；实际PDF XObject尺寸、红色像素和图后文字回归已读。角色/图名仅在页尾独占时回退，与后文同页，offset前进保护已核对。亲读 `/tmp/amber-mac-files-tests.log` 20:18:52，11项通过。生成图文件导入保持实际转换后的MIME、名称和bytes，unique落盘、sourceURL=nil，await后owner删除仍拒写有真实回归；模型生图/Workspace消费为后续新增任务，未随这层测试冒称完成。

## 补齐 TODO 后的增量独立评审（20:26 CST（UTC+08:00））

本轮重新对照TODO，不将“已有一份源码”冒作条目全部完成；正式Shared、网络与新增最终UI均仍有明确未验边界。

- **MAC-037 队列**：已读composer → 原owner/run队列 → Agent drainSteer/真实engine → canonical持久确认，以及纯文本完成后的下一请求。独立发现已提交指令写失败仍永久显示“提交中”；作者增加awaitingSave，仅重试原消息保存，不撤回/重发；真正saved含同ID才移除。另发现原response写失败时pending队列“发送”静默返回；显式发送现先保存原owner并仅await captured writer，再以同slot/UUID fence启动一次，自动followup不隐式重试。停止取消延迟followup，删除fence保留；附件不混入文本steer。亲读 `/tmp/amber-workspace-queue-final.log` 20:26:15：queue7 + durability3 + transcript6，共16项通过。最新source无确定残留，原生键盘/队列条仍未复拍。
- **MAC-018 系统朗读**：已完整读AVSpeech真实backend、request UUID和utterance identity、voice/rate重开持久化，以及同一workspace.speech的Settings试听与user/assistant正文菜单；reasoning/tool raw不朗读。旧cancel回调不清新播放，停止入口跨消息可达，错误alert属于row。已读6项backend spy与最新 `/tmp/amber-mac-model-speech-tests.log` 50项通过（含原配置/协作/通知41 + 模型3 + Speech6）。未实际听到系统音频，不记播放验收通过。
- **MAC-011/012 参数与辅助模型**：已读customHeaders字符串字典/customBody对象校验、JSON草稿保存/取消、旧record decodeIfPresent和supportsVision三态、六类aux选择消费；UI明确覆盖配置随备份，API Key使用独立钥匙串字段。Swift实际source/typecheck与相应回归通过；真实KMP headers/body请求仍需Native消费。标题/视觉/搜索增量另由非作者files agent独立review，尚不以其单测替网络证据。
- **MAC-018 生图**：已读DesktopImageGeneration → 原IOSImageGenerationRepository → 真实staging → 生成图片owner文件转换 → 原owner预览/草稿；iOS默认outputDirectory=nil保持原路径，CodexCoordinator仅原样移动，不另写平行生图协议。Preview强制不可联网，正式Live显式enabled且共享files/settings；owner删除cancel，备份与生图互斥，退出cancel并awaitshutdown，原草稿去重/预算同一owner。亲读 `/tmp/amber-image-generation-tests.log` 20:22:03，6项实际repository fixture通过，覆盖OpenAI body/header、原Codex SSE/pending GET、实际图片落盘/暂存清理、多图失败回滚、取消与Preview不联网。完整Codex登录/POST、真实远端生成及新sheet原生交互仍未验。
- **PDF产物**：已独立逐页查看最新 `/tmp/amber-media-export-review-1.png` 至`-3.png`，对应真实3页PDF：第2页图名与完整比例图片同页，边距/页脚无覆盖；第3页角色与图后文本24680同页。第1页保留标题/提问，图需自然另页，没有为填空白把图片强行缩小。

20:25:39完整同源Preview再次build/signverify成功，路径 `macApp/build/swiftpm-preview/AmberPreview.app`。CUA所有权已移交本评审，但系统仍报告Mac锁屏，需要physical input恢复，未绕过或反复重试；新binary没有实际重启/整窗复拍。此前已验收的旧Backup长状态只覆盖当时文案；现在首段新增headers/body敏感信息披露，旧截图不能替该新版本面板验收。最终Table/Math、Knowledge tabs、Collab/Recipe、MCP/同步、字体/存储/朗读/生图/队列新状态继续明确待原生复拍。

20:30:12源码对齐的最新同源Preview包，本评审独立读取实际二进制为Mach-O arm64，`codesign --verify --deep --strict`实际exit0；真实iosMath字体资源bundle存在，实际entitlements为app sandbox、user-selected read-write和network client。这是最终包的构建/签名/资源证据，仍没有因锁屏而取得新包启动证据。

最后搜索日志小修已独立阅读：`IOSSearchExecutor.jsonResponse` 的iOS DEBUG分支原样保留provider/HTTPstatus/body前400字；Mac DEBUG只记录provider和HTTPstatus，不记body/URL/headers，Release仍不记录此处日志。Mac scrape走实际sendPublic，iOS verifiedTransport支路以平台条件保留。没有新增redactor或网络fallback；该Shared消费路径不在225项隔离Runtime测试内，当前仅source与parser证据，真实搜索网络未验。

## 离屏原生组件布局补验（20:34 CST，UTC+08:00）

独立评审者逐张查看 `/tmp/amber-offscreen-review/captures/` 的以下6张实际同源Native组件bitmap；源码manifest为该目录上一层 `source-manifest.tsv`。画面顶部已明确“非交互窗口截图”，本评审同样不将它们当作最终App的CUA交互证据。

| 组件样例 | 独立观察 |
| --- | --- |
| backup-restored-light | 使用实际恢复结果与新版敏感字段披露文案，620×440面板的长状态/说明/完成按钮全部可见，无需猜测性加ScrollView |
| workspace-queue-860-light | 同时有真实生成状态、审批卡和3条pending队列时，860×600组件整体上下裁掉，侧栏顶端和composer底部均不完整；已交作者精准修布局优先级/可滚动区域，未记为通过 |
| workspace-reading-1280-dark | 长表格末“一致。”完整、邻列同高，长代码保持横向区域；行内/块公式与中文可读，无覆盖输入器 |
| recipes-light | 首屏长名称、说明、开关/JSON编辑、布尔/文本输入与运行入口无相互覆盖；没有实际点击或执行验证 |
| collaboration-dark | 首屏成员字段/模型/职责/增减/超时与开始入口布局完整；原生分段选择交互及真实多模型请求未验 |
| knowledge-skills-light | 技能长说明/工具声明/启停编辑删除布局完整；原生Tab桥未出现在离屏bitmap，不能由此证明三个Tab可见或记忆页已验 |

标题重试仅清相同历史title错误、保留无关保存错误的小修已重读；`/tmp/amber-auxiliary-title-retry-final.log` 20:33:21的5项通过已亲读。生图UI对当前安全validation错误优先，其他仅用generator安全分类/通用提示，不展示raw provider body；该source小修已读，其新增回归尚待收取，225项旧全套不自动为它背书。

## 最终源码与组件复核（20:38 CST，UTC+08:00）

亲读 `/tmp/amber-image-generation-final-tests.log` 20:35:47，8项通过；新增两个实际repository用户序列已读：HTTP500失败后清除生图aux再重试，最新校验文案替换旧错误且不发第二个网络请求；真实async transport挂起时重入，不清原owner/status/isRunning，取消并等待后收敛。未用模拟器状态替真实repository调用。亲读 `/tmp/amber-mac-all-runtime-delivery.log` 20:36:45，最终 **227项、0 failures**，包含这两项及title重试错误修复；旧225项作为历史快照保留。该全套仍排除依赖Shared的正式adapter，搜索日志与真实provider链不能据此宣称已跑通。

860布局精修已独立复读：审批卡保留原位置与原runID允许/拒绝，摘要自然显示，完整reason/arguments在可滚动、可选择文本的浮层；队列主区仅显示数量/待保存状态，浮层保留pending撤回、delivering提示、awaitingSave重试及终态发送入口。没有改最小窗口、缩字体或使用偏移抵消溢出。独立亲看去掉harness额外26pt标签后的完整860×600生产root组件图：brand/侧栏底部、审批按钮、队列摘要、输入器与停止按钮外框均完整，上下裁切已闭环。1280深色queue及reading图已重看，表格末句/同高边框、真实公式与长代码无布局回归。此结论是实际同源组件bitmap，不冒作最终App的交互截图；浅色非key组件图的stop白底白icon另已交作者局部核对。

另亲看 `image-form-light.png`、`storage-dark.png` 和最新 `backup-restored-light.png`：生图描述/比例/数量/风格/提示/底部入口未相互覆盖；存储统计列表、未知位置说明、刷新与完成按钮完整；新版Backup敏感字段披露和实际恢复长状态在面板内完整。Knowledge的原生Tab桥仍没有由此获得交互证据。系统锁屏状态未解除，未绕过限制、未重启最新App，正式Native与最后一轮整窗验收继续单列待验。

20:40最终组件复核：stop改为原生bordered按钮与primary符号，实际调用和⌘.快捷键不变。独立逐张亲看最新 `workspace-queue-860-light.png` 和 `workspace-queue-860-dark.png`：浅色白按钮/黑方块、深色灰按钮/白方块均可辨，header/审批/队列摘要/composer仍完整，非key对比缺陷闭环。此两行视觉改动不需要重写Runtime测试；前述227项仍对应Runtime最终冻结快照，UI由同源Native渲染和最后完整构建分别验证。

最后实际交付构建日志 `/tmp/amber-interface-delivery-build.log` 已亲读，20:40完整编译与签名输出成功；本评审再次对实际新包独立执行 `codesign --verify --deep --strict`，exit0，实际二进制为arm64 Mach-O。六张已读组件图与source manifest现已归档到本仓 `docs/product/macos/screenshots/`，README明确其离屏证据范围。CUA已明确交还root/interface，未操作锁屏或关闭旧窗口；本轮独立检查未留下已知未修的确定源码/组件缺陷，正式集成和交互待验项仍按顶部八阶段表保留。
