# Phase 5 UI、表单与呈现独立审查

审查以 `/tmp/amber-phase5-source-baseline/manifest.json` 所列 Phase 5 前未提交源码为迁前基线，不以 `HEAD` 代替。范围为 Provider、Runtime SSH、Council 和 MiniApp 的页面/子视图拆分及新增 Settings/Council/MiniApp hosting 布局探针。本 reviewer 只读产品、测试和 Root 交付的证据，只写本报告；不执行构建、测试或 GUI。已核对迁后截图、定点修复和指定的实际产品导航。

## 状态与调用归属

- `ProviderDetailView` 仍持有选中页、配置草稿、登录 Sheet、模型抓取状态与 task、模型编辑 draft；迁出的 `ProviderModelEditorSheet` 只持有它原有的编辑中 draft，`onSave` 仍回到页面的 `saveModelDraft`。页面中的 `saveConfig`、请求头持久化、`fetchModels`/`cancelModelFetch` 及登录回调保持同一个 owner。`/tmp/amber-phase5-editors-audit.md` 将 Provider 页面、模型/endpoint helper、编辑组件逐段与基线核对，除跨文件可见性外未列出行为改动。静态核对未见模型页或保存入口断链；真实登录、远端模型发现及持久化消费要按集成结果另判。
- `RuntimeEnvironmentView` 的 SSH profile、密码/私钥、公钥、端口、指纹 probe/status、验证 task 与 `activeSheet` 仍在页面 `@State` 中；迁出的 SSH editing extension 直接读写这一份状态，`saveSSHProfile` 和 Host 信任操作仍经原 `SettingsStore`。`RuntimeSheetChrome` 仍由页面 `.sheet(item:)` 构造，关闭时调用原 `clearSSHDrafts()`。基线的 iSH policy/status card WIP 及远程命令实现由编辑者逐段核对为保留；未发现因拆文件而出现第二套表单草稿。
- `CouncilChatRuntimeView` 保留唯一 `CouncilChatViewModel`、composer 焦点、Native scroll driver/follow 状态、附件选择状态和底部 `.safeAreaInset`；`send()`、附件回调、`showMembers()` 及 `.sheet(item: viewModel.activeSheet)` 都仍从页面进出。`CouncilMembersSheet` 接收原 `selectedMode` binding、成员、状态 provider、失败席位及重开闭包；行内编辑 draft 留在 `CouncilTranscriptViews` 对应行内。`/tmp/amber-phase5-council-audit.json` 覆盖两份原源文件全部原行，标明少量跨文件可见性/包装差异；静态核对未见新会话状态 owner 或回调断链。实际流式跟随与键盘空间仍需运行证据。
- `MiniAppRunnerView` 仍持有页面加载状态、`presentedSheet`、本地 repository、Host 确认和系统 bridge owner；管理按钮仍设置 `.management`，完整管理 Sheet 仍由页面构造。AI run recovery、system bridge、Host confirmation 的搬迁块与基线文本一致，页面逻辑未发现行为搬迁。管理 Sheet 本体未被本期单元布局探针直接挂载，不能由 grants 子组件截图为完整 Sheet 签字。

## 新布局探针的证据边界

`SwiftModularizationHostingFixture` 使用真实 `UIWindowScene`、320/393pt 窗口和 `.large`/`.accessibility3` SwiftUI/ UIKit 字号，保存实际 `drawHierarchy` PNG；它断言滚动视口和内容宽度、部分输入控件在滚动后与视口相交。它不枚举 AX，也不调用按钮并核对业务副作用；`scrollRectToVisible` 和 `UIView` 相交不能证明完整 hit area、焦点/中文 IME 或 VoiceOver。

- Settings 三项覆盖 Provider 配置/模型页、单独挂载的模型编辑 Sheet、Runtime 概览和单独挂载的待信任指纹卡。Provider 模型编辑器由测试直接构造，未从模型页实际点击进入；指纹卡也未经过真实 SSH probe/信任事务。测试首个已挂载输入控件及部分 AX3 的最后输入控件，不能据此断言每个字段均可编辑或远端抓取成功。
- Council/MiniApp 三项用本地数据挂载真实 Council 页面、成员 Sheet、本地 MiniApp runner/权限区域和系统权限页。hosting 探针直接调用 `viewModel.showMembers()`；后述产品导航另已实际点击模式胶囊进入成员 Sheet。本地 HTML 加载及隔离 repository allow/deny 状态可验证本地 fixture，不代表 Host bridge 或系统权限请求。系统权限页只检查布局，不触发 OS 授权。

## 迁后截图与定点复核

`phase-5-layout-artifacts-r6.json` 记录了 primary-r6 xcresult 导出的 68 张新 hosting PNG，已逐张查看。Council transcript 的长正文与底部 composer、MiniApp runner、系统权限页、Provider 与 Runtime 页面在 320/393pt、large/AX3 对应画面中，未见可确认的本次搬迁新增横向越界或正文/按钮重叠。Provider 模型 AX3 底图可见第 10 项和“自动获取”“手动添加”，模型编辑 AX3 底图可见第 3 个请求头以及“添加 Header”。这些新增 fixture 与迁前旧测试的种子文案及模型数量不同，不能做逐像素对照。

**r6 MiniApp 权限区域的 AX3 图不可作为真实分支证据。** 当时的测试创建未安装的 `MiniAppRunnerView` 后直接调用其 `grantsSection(app)`，但决定 HStack/VStack 的 `@Environment(\.dynamicTypeSize)` 属于尚未安装的 runner；r6 因此有 outside installed View 的 RuntimeWarning，AX3 图也进入错误的横排分支。这是探针失效，不是已证实的产品故障。后续将权限区域提成没有新状态的 `MiniAppPermissionGrantsSection`，由组件自身读取字号环境；生产 `managementSheet` 和 fixture 都挂载此 View，授权仍由 runner 的 `setGrant` 处理。r6 的 16 张 grants 图仅作为失效探针历史，不用于最终签字。

另将 `/tmp/amber-phase5-baseline-attachments/manifest.json` 的 22 张迁前旧测试 PNG 与 `/tmp/amber-phase5-primary-r6-attachments/manifest.json` 中同名迁后 PNG 一一核对。22 组尺寸完全相同；19 组的 RGB 通道差异均未超过 5/255，另三组的明显差异仅局限左上返回圆钮：`provider-defaults-narrow-large`、`miniapp-settings-regular-scrolled`、`miniapp-settings-compact-scrolled`。逐对目视可见按钮明暗/渲染轻差，正文、表单、开关、分组和滚动位置一致；旧测试的迁后画面未见新裁切或错位。

`council-members-scrolled-*` 在 `List` 的懒加载成员行中并未显示最后一个成员，探针只断言滚动发生，不能据此称所有成员到底可达。原 `settings-host-fingerprint-320-ax3.png` 顶图把底部按钮留在视口之外；final-r1 新增的 320/393pt AX3 底图均显示完整的“信任此 Host”和“取消”按钮。对应测试先滚到实际 `contentSize` 末端，断言末端进入可见视口，再截图；320pt 的信任按钮文案换成窄幅多行，但未裁切。这确认 fixture 中按钮可通过滚动看到，不证明真实 SSH 指纹探测或信任点击。

Council transcript 顶栏在 r6 的 320pt 图中，“自由群聊”胶囊遮挡右侧历史圆钮及图标；源码块虽与迁前基线一致，仍是本次受影响页面的真实视觉缺陷。Council owner 改用按三个子视图实际尺寸放置的 `CouncilHeaderLayout`，在左右控件之间夹取胶囊中心，并保留原按钮动作和 glass。已逐张复核 final-r1 的 320/393pt × large/AX3 四张顶栏图：320pt 胶囊与历史按钮明确分离，393pt 仍居中，四图均未见顶栏重叠。此定点缺陷的视觉复核已闭环；截图不证明历史按钮的真实点击。

MiniApp 修正后的 r3 定点测试由 Root 汇总为 184/184 passed、0 warnings；`phase-5-layout-artifacts-miniapp-final.json` 索引 70 张新布局图和 10 张旧 visual 图。本 reviewer 逐张看了更改所及的 16 张 grants 图：320/393pt × large/AX3 × allow/deny 的顶图和滚动图。AX3 的授权胶囊均在权限说明下方，确认进入正确的 VStack 分支；large 下本地存储行在两种宽度都保持横排，320pt 说明文案按可用宽度换行。全局系统交互关闭提示与系统权限行的灰色“未设置 · 全局关闭”完整，本地存储行随 allow/deny 显示绿/红。滚动图可见最后的“打开外部链接”完整行和胶囊，没有可见的横向裁切或行间重叠。测试断言真实 scroll 视口宽度、内容宽度以及溢出时 offset 发生移动；这些图证明该 fixture 中末行可见，不证明完整管理 Sheet 的授权菜单可点或 VoiceOver 焦点。另将 r3 的两张旧系统权限 visual 图与迁前同名图复核，同状态下提示、行序及竖排结构一致，未见搬迁造成的裁切。

## 实际产品导航与签字

`/tmp/amber-phase5-navigation-r2.xcresult` 的两项导航为 1 passed、1 failed。通过的 Provider 测试实际从 Home 进入设置、服务商列表、现有 OpenAI 的配置与模型页，点“手动添加”打开“添加模型” Sheet，再取消返回模型页。已看这一路的六张产品 PNG 与 AX 树；配置/模型分段、模型卡、Sheet 标题、可见字段和标题栏按钮均有完整边界，未见错位。它证明这些入口和取消返回在本次模拟器运行中可达；测试未编辑保存、发送 provider 请求或验证凭据。

另一项 r2 导航曾到达设置→运行环境→Runtime 与任务 overview，但随后选择器以 `label CONTAINS "SSH Profile"` 匹配到了上方 Remote SSH 选项，未打开目标 Sheet；失败附件只有 overview。该误点把已选中的 Remote SSH 再次设为同值，仍经过 setter/save，不能称 r2 全程零写入。r3 将选择器限定为 `label BEGINSWITH "SSH Profile、"`，在 `/tmp/amber-phase5-navigation-r3.xcresult` 实际 1/1 passed。本 reviewer 逐张看了 r3 的 SSH Profile 顶部、滚动后的未验证指纹卡和 probe 按钮，以及 MiniApp 列表/设置、Council 房间/成员/设置的产品 PNG 和对应 AX 树。

SSH Profile 实际 Sheet 显示标题、关闭按钮、名称/Host/端口/用户名与密码分段；滚动后“尚未验证 Host 指纹”和“检查 Host 指纹”均进入视口且测试断言可触达。probe 控件在截图中紧贴视口下沿，文字完整且 AX 为 hittable；测试未点击 probe，未连接 SSH，也未保存凭据。MiniApp 当前本地列表为空；空态文案与设置入口可见，点击进入设置后总开关及系统交互等权限行可见，再返回列表。Council 房间的模式胶囊、历史和设置按钮在 AX 中各有独立边界；实际点胶囊进入成员 Sheet，完成返回后打开议会设置 Sheet。成员 Sheet 首屏未包含所有懒加载席位，产品导航只验入口与当前可见内容。当前房间缺少可用聊天模型，空房间提示和未测试连通性是此测试状态，不能当成生成流程验收。上述截图未见影响辨识或操作的控件重叠。

Root 提供的 final-r1 主测试汇总为 995 total、993 passed、0 failed、2 skipped，`phase-5-layout-artifacts-final-r1.json` 索引 70 张导出 PNG。本 reviewer 对其中 Council 顶栏四图和 Host 指纹卡底部两图作上述定点复核；其余布局结论仍以已逐张检查的 r6 68 图和迁前后同名 22 对为限。MiniApp r3 的修正探针已为其 320/393pt、large/AX3 截图签字；结合 Provider r2 与本地 Runtime/Council/MiniApp r3 的实际导航，本期指定 UI/呈现范围签字通过。真机触控、中文 IME、远端 provider/SSH、系统权限、MiniApp 完整管理 Sheet 和真实 Council 生成/流式跟随的行为验收仍分别在证据范围外。
