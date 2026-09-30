# Enid（@ios_dev_alb）iOS 26 以后的开发小技巧

整理自 [Enid](https://x.com/ios_dev_alb) 的公开帖。收录范围是 **2025-06-09（WWDC25，iOS 26 SDK）至 2026-09-29**。

他几乎每天发一条技巧，同一条会隔几个月重发。所以这里按技巧去重，不按帖子计数。

- 正文大约 **40 条**，是他明确标成 **iOS 26 / 26.x / iOS 27** 的新 API。
- 附录是同一时期他仍在发的更早版本 SwiftUI 技巧，也是去重后的，不是那 15 个月里每一条帖子。
- 他自己的付费图包在 2026 年 4 月写过「80+ / 90+ 条」，里面新旧 API 混在一起，而且之后还在加。那些付费图没有收进来。

他的配图和短视频里才有完整示例。下面的代码是按帖子正文里的 API 写成的用法示意，不是从配图逐行抄下来的。签名以他写出来的为准；他没写参数的地方，不补猜测。

课程和付费资料（[learnandcodewithenid.com](https://www.learnandcodewithenid.com)、SwiftUI Visual Tips Kit）没有收进来。

---

## 怎么用这份文档

- 先看下面的索引，按修饰符名跳到对应小节。
- 每条都有版本、他要解决的问题、用法，以及原帖。
- 「iOS 26 只换了外观」和文末附录，是同一时期他反复发、但**不是** iOS 26 新 API 的技巧。

## 索引

| API | 系统 | 做什么 |
| --- | --- | --- |
| [`buttonStyle(.glass)` / `.glassProminent`](#glass-button) | iOS 26 | 按钮套上 Liquid Glass |
| [`glassEffect()`](#glass-effect) | iOS 26 | 任意视图的玻璃效果、形状、染色、强度 |
| [`GlassEffectContainer`](#glass-container) | iOS 26 | 多块玻璃融成一块 |
| [半高 sheet 自动玻璃化](#partial-sheet) | iOS 26 | 越矮的 detent，边缘留白越大 |
| [`UIDesignRequiresCompatibility`](#compatibility-key) | Xcode 26 | 临时关回旧界面 |
| [`navigationSubtitle()`](#navigation-subtitle) | iOS 26 | 导航栏副标题 |
| [`ToolbarSpacer`](#toolbar-spacer) | iOS 26 | 把挤在同一块玻璃里的工具栏按钮拆开 |
| [`sharedBackgroundVisibility(_:)`](#shared-background) | iOS 26 | 去掉工具栏按钮的玻璃底 |
| [`badge()`](#toolbar-badge) | iOS 26 | 工具栏按钮上的角标 |
| [`Button` role `.confirm` / `.close`](#confirm-close) | iOS 26 | 对勾确认、关闭 |
| [`safeAreaBar()`](#safe-area-bar) | iOS 26 | 会参与滚动边缘效果的安全区条 |
| [`tabViewBottomAccessory()`](#bottom-accessory) | iOS 26 / 26.1 | Tab 栏上方的附属条，可按条件显示 |
| [`tabBarMinimizeBehavior()`](#tab-minimize) | iOS 26 | Tab 栏滚动时缩小，附属条跟着让位 |
| [`Tab(role: .search)`](#search-tab) | iOS 26 | 独立搜索 Tab |
| [`searchable` 的位置](#search-placement) | iOS 26 | 搜索框默认在底部，可挪回导航栏 |
| [`tabViewSearchActivation(_:)`](#search-activation) | iOS 26 | 点到搜索 Tab 就聚焦搜索框 |
| [`listSectionMargins()`](#section-margins) | iOS 26 | 列表分组的水平 / 垂直边距 |
| [`sectionIndexLabel()`](#section-index) | iOS 26 | 联系人式右侧字母索引 |
| [`labelIconToTitleSpacing()`](#icon-spacing) | iOS 26 | 图标和标题的间距 |
| [`labelReservedIconWidth()`](#icon-width) | iOS 26 | 图标占位宽度，文字才能对齐 |
| [`buttonSizing(.flexible)`](#button-sizing) | iOS 26 | 按钮沿主轴撑满 |
| [`sliderThumbVisibility()`](#slider-thumb) | iOS 26 | 隐藏滑块圆点，仍可拖 |
| [`SliderTick`](#slider-ticks) | iOS 26 | 滑块刻度 |
| [`symbolColorRenderingMode()`](#symbol-color) | iOS 26 | SF Symbol 纯色或渐变 |
| [`symbolEffect(.drawOn)`](#draw-on) | iOS 26 | 符号自己画出来 |
| [`TextEditor` + `AttributedString`](#rich-text) | iOS 26 | 系统富文本编辑 |
| [`backgroundExtensionEffect()`](#background-extension) | iOS 26 | 边缘镜像模糊，铺出安全区 |
| [`.concentric`](#concentric) | iOS 26 | 内层圆角跟着外层走 |
| [`scrollEdgeEffectStyle()` / `scrollEdgeEffectHidden()`](#scroll-edge) | iOS 26 | 滚动内容滑进导航栏时的模糊 |
| [`Chart3D`](#chart3d) | iOS 26 | 三维图表 |
| [`WebView` / `WebPage`](#webview) | iOS 26 | SwiftUI 里的网页 |
| [`openURL(_:prefersInApp:)`](#in-app-browser) | iOS 26 | 链接留在 App 内 |
| [`SubscriptionStoreView`](#subscription-store) | 付费墙 | 一行代码的订阅页，iOS 26 更新了外观 |
| [`SubscriptionOfferView`](#subscription-offer) | iOS 26 | 嵌在界面里的订阅优惠 |
| [`textSelection(.enabled)`](#text-selection) | iOS 27 | 可以只选中一段，而不是整段 |
| [`toolbarMinimizeBehavior(_:for:)`](#nav-minimize) | iOS 27 | 下滑时收起导航栏 |
| [`toolbarVisibility(.hidden, for: .statusBar)`](#status-bar) | iOS 27 | 隐藏状态栏 |
| [`Tab` role `.prominent`](#prominent-tab) | iOS 27 | 强调某一个 Tab |
| [`swipeActionsContainer()`](#swipe-container) | iOS 27 | 自定义行也能侧滑 |
| [`navigationTransition(.crossFade)`](#cross-fade) | iOS 27 | sheet 改为淡入 |
| [`presentationPlacement()`](#sheet-placement) | iOS 27 | sheet 靠左、居中或靠右 |
| [`LabeledContent` 放进 `Menu`](#menu-subtitle) | iOS 27 | 菜单项副标题 |
| [Xcode 27](#xcode-27) | Xcode 27 / 27.1 | Markdown 编辑器、Derived Data、iPhone Duo |

---

## Liquid Glass

### 玻璃按钮 {#glass-button}

**iOS 26。** 把 Liquid Glass 用在按钮上：普通玻璃用 `.glass`，强调按钮用 `.glassProminent`。

```swift
Button("Continue") { }
    .buttonStyle(.glass)

Button("Subscribe") { }
    .buttonStyle(.glassProminent)
```

原帖：[2025-06-09](https://x.com/ios_dev_alb/status/1932179540165435583) · [2025-06-10 `.glassEffect()`](https://x.com/ios_dev_alb/status/1932440070050435516)

### 视图上的玻璃效果 {#glass-effect}

**iOS 26。** `.glassEffect()` 默认是胶囊形，也可以换成自己的形状。染色他用的是 `.tint()`。强度三档：`.identity`、`.regular`、`.clear`，用来控制背后内容透出多少。

```swift
Text("Filter")
    .padding()
    .glassEffect()

Text("Filter")
    .padding()
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    .tint(.orange)

Label("Now Playing", systemImage: "music.note")
    .padding()
    .glassEffect(.clear)
```

原帖：[形状](https://x.com/ios_dev_alb/status/1977009998845911327) · [染色](https://x.com/ios_dev_alb/status/1957750493049999495) · [强度](https://x.com/ios_dev_alb/status/1974806832481775680)

### 把多块玻璃合成一块 {#glass-container}

**iOS 26。** 好几块玻璃各自成形时，包进 `GlassEffectContainer`，相邻的会融成一整块。

```swift
GlassEffectContainer {
    HStack(spacing: 12) {
        action("heart")
        action("star")
        action("square.and.arrow.up")
    }
}

func action(_ name: String) -> some View {
    Image(systemName: name)
        .padding()
        .glassEffect()
}
```

原帖：[2025-07-10](https://x.com/ios_dev_alb/status/1943278467358839071)

### 半高 sheet 会自己变成玻璃 {#partial-sheet}

**iOS 26。** 半高 sheet 不用再手动加玻璃。detent 越低，系统留出的边缘间距越大。这是呈现行为，没有新的修饰符。

原帖：[2025-08-12](https://x.com/ios_dev_alb/status/1955229165478637607)

### 暂时关掉 Liquid Glass {#compatibility-key}

**Xcode 26 / iOS 26。** 还没准备好适配时，在 Info.plist 里把 `UIDesignRequiresCompatibility` 设为 `YES`，界面会退回旧样式。他自己注明：Apple 说这个键是临时的，以后会删。

```xml
<key>UIDesignRequiresCompatibility</key>
<true/>
```

原帖：[2025-08-25](https://x.com/ios_dev_alb/status/1959926287880860011)

---

## 导航栏和工具栏

### 导航栏副标题 {#navigation-subtitle}

**iOS 26。** `navigationSubtitle()` 在大标题下面加一行说明，用来放编辑时间、状态或上下文。

```swift
NavigationStack {
    NotesView()
        .navigationTitle("Notes")
        .navigationSubtitle("Edited today")
}
```

原帖：[2025-07-01](https://x.com/ios_dev_alb/status/1939976106108756017)

### 拆开挤在一起的工具栏按钮 {#toolbar-spacer}

**iOS 26。** 工具栏按钮默认会合成同一块玻璃。中间插入 `ToolbarSpacer`，把它们分成两组。

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button("Edit", systemImage: "pencil") { }
    }
    ToolbarSpacer()
    ToolbarItem(placement: .topBarTrailing) {
        Button("Done", systemImage: "checkmark") { }
    }
}
```

原帖：[2025-09-10](https://x.com/ios_dev_alb/status/1965779277263368380)

### 去掉工具栏的玻璃底 {#shared-background}

**iOS 26。** 工具栏项默认带玻璃背景。`.sharedBackgroundVisibility(.hidden)` 把它去掉。

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button("Filter", systemImage: "line.3.horizontal.decrease") { }
        .sharedBackgroundVisibility(.hidden)
}
```

原帖：[2025-09-17](https://x.com/ios_dev_alb/status/1968293468108673432)

### 工具栏角标 {#toolbar-badge}

**iOS 26。** 原来的 `badge()` 现在也能用在工具栏按钮上，适合购物车数量、未读数。

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button("Inbox", systemImage: "tray") { }
        .badge(3)
}
```

原帖：[2025-08-02](https://x.com/ios_dev_alb/status/1951588776188182931)

### 确认和关闭按钮 {#confirm-close}

**iOS 26。** 新的按钮角色：`.confirm` 和 `.close`。

`.confirm` 默认是蓝色。不写标题时，工具栏里会显示对勾。颜色用 `tint()` 改。

```swift
ToolbarItem(placement: .confirmationAction) {
    Button(role: .confirm) { save() }
}

ToolbarItem(placement: .cancellationAction) {
    Button(role: .close) { dismiss() }
}
```

原帖：[`.confirm`](https://x.com/ios_dev_alb/status/1967983352104812599) · [不写标题得到对勾](https://x.com/ios_dev_alb/status/2025555339345551549) · [给对勾上色](https://x.com/ios_dev_alb/status/1981389874847420716) · [`.close` 与 `.confirm`](https://x.com/ios_dev_alb/status/1998747886931103956)

### 会跟着滚动边缘走的底栏 {#safe-area-bar}

**iOS 26。** 底部主操作更适合 `safeAreaBar()`，而不是 `safeAreaInset()`。差别是它会接上新的滚动边缘效果。

```swift
ScrollView {
    form
}
.safeAreaBar(edge: .bottom) {
    Button("Continue") { }
        .buttonSizing(.flexible)
}
```

原帖：[2026-03-14](https://x.com/ios_dev_alb/status/2032888947588661510)

---

## Tab 和搜索

### Tab 栏上方的附属条 {#bottom-accessory}

**iOS 26。** `tabViewBottomAccessory()` 把一块自定义视图钉在 Tab 栏上面，适合正在播放、筛选条这类一直要留着的操作。

**iOS 26.1** 增加了 `isEnabled`，可以按条件收起这块区域。

```swift
TabView {
    Tab("Listen", systemImage: "music.note") { LibraryView() }
    Tab("Search", systemImage: "magnifyingglass", role: .search) {
        SearchView()
    }
}
.tabViewBottomAccessory {
    NowPlayingBar()
}
.tabViewBottomAccessory(isEnabled: showNowPlaying) {
    NowPlayingBar()
}
```

原帖：[2025-07-28](https://x.com/ios_dev_alb/status/1949787144488157641) · [iOS 26.1 条件显示](https://x.com/ios_dev_alb/status/2026245535561101762)

### Tab 栏缩小，附属条跟着下去 {#tab-minimize}

**iOS 26。** `tabBarMinimizeBehavior()` 让 Tab 栏在滚动时缩小。上面那条 accessory 会自动下移，给内容让位。

```swift
TabView { /* tabs */ }
    .tabViewBottomAccessory { NowPlayingBar() }
    .tabBarMinimizeBehavior(.onScrollDown)
```

原帖：[2025-07-28](https://x.com/ios_dev_alb/status/1949787144488157641)

### 搜索 Tab {#search-tab}

**iOS 26。** `Tab(role: .search)` 配上 `searchable()`，搜索框会做进 Tab 栏，选中这个 Tab 时出现。

```swift
TabView {
    Tab("Home", systemImage: "house") { HomeView() }
    Tab("Search", systemImage: "magnifyingglass", role: .search) {
        SearchResults(query: query)
    }
}
.searchable(text: $query)
```

原帖：[2025-08-28](https://x.com/ios_dev_alb/status/1961065572889760167)

### 搜索框默认在底部 {#search-placement}

**iOS 26。** `searchable()` 的搜索框默认出现在底部。要放回导航栏区域，把 placement 设为 `.navigationBarDrawer`。

```swift
.searchable(
    text: $query,
    placement: .navigationBarDrawer(displayMode: .automatic)
)
```

原帖：[2025-10-14](https://x.com/ios_dev_alb/status/1978041842911293716)

### 选中搜索 Tab 就打开键盘 {#search-activation}

**iOS 26。** `.tabViewSearchActivation(.searchTabSelection)`：用户点到搜索 Tab 时，搜索框自动激活。

```swift
TabView { /* 含 role: .search 的 Tab */ }
    .searchable(text: $query)
    .tabViewSearchActivation(.searchTabSelection)
```

原帖：[2026-07-16](https://x.com/ios_dev_alb/status/2077551286619386116)。他后来有一条帖子把 “use” 打成了 “se”，API 相同。

---

## 列表

### 分组边距 {#section-margins}

**iOS 26。** `listSectionMargins()` 控制一个 section 四周的留白，水平、垂直都可以调。用来做卡片式内缩，或者反过来贴边。

```swift
List {
    Section("Inbox") {
        Text("Design review")
        Text("Ship notes")
    }
}
.listSectionMargins() // 水平、垂直留白见原帖配图
```

原帖：[2025-06-25](https://x.com/ios_dev_alb/status/1937848132756271514)。他后来写明水平和垂直都能调：[2026-02-27](https://x.com/ios_dev_alb/status/2027433043942686871)。

### 右侧字母索引 {#section-index}

**iOS 26。** 联系人那种 A–Z 快滑：每个 section 用 `sectionIndexLabel()`，List 上打开 `listSectionIndexVisibility(.visible)`。

```swift
List {
    Section("A") { Text("Amy") }
        .sectionIndexLabel("A")
    Section("B") { Text("Ben") }
        .sectionIndexLabel("B")
}
.listSectionIndexVisibility(.visible)
```

原帖：[2025-09-08](https://x.com/ios_dev_alb/status/1965018952624435540)

---

## 控件

### 图标和标题的间距 {#icon-spacing}

**iOS 26。** `labelIconToTitleSpacing()` 调整 `Label` 图标和文字之间的距离。

```swift
Label("Airplane Mode", systemImage: "airplane")
    .labelIconToTitleSpacing(12)
```

原帖：[2025-06-12](https://x.com/ios_dev_alb/status/1933094243205005476)

### 把图标宽度留齐 {#icon-width}

**iOS 26。** SF Symbol 宽窄不一样时，标题会对不齐。`labelReservedIconWidth()` 给图标留一段固定宽度。

```swift
VStack(alignment: .leading) {
    Label("Wi-Fi", systemImage: "wifi")
    Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
}
.labelReservedIconWidth(28)
```

原帖：[2025-09-08](https://x.com/ios_dev_alb/status/1965059211756454333)

### 让按钮撑满可用宽度 {#button-sizing}

**iOS 26。** `.buttonSizing(.flexible)` 让按钮沿主轴展开，占满容器。他特别提到主按钮和付费墙。

```swift
Button("Continue") { }
    .buttonSizing(.flexible)
    .buttonStyle(.glassProminent)
```

原帖：[2025-10-02](https://x.com/ios_dev_alb/status/1973692907832889386)

### 隐藏滑块圆点 {#slider-thumb}

**iOS 26。** `sliderThumbVisibility()` 控制圆点显不显示。藏起来之后，仍然可以在整条进度上拖，适合播放进度、亮度这种更干净的滑条。

```swift
Slider(value: $progress)
    .sliderThumbVisibility(.hidden)
```

原帖：[2026-02-16](https://x.com/ios_dev_alb/status/2023453634877403609)

### 滑块刻度 {#slider-ticks}

**iOS 26。** 用 ticks 参数，或 `SliderTick`，在滑条上标出刻度。适合亮度、音量、变焦这种有明确档位的值。

帖子正文只写出两处名字：`Slider` 的 ticks 参数，以及 `SliderTick`。刻度值怎么塞进去，在配图里。

原帖：[ticks 参数，2025-11-11](https://x.com/ios_dev_alb/status/1988212844928659753) · [`SliderTick`，2026-07-10](https://x.com/ios_dev_alb/status/2075410932411326745)

### 符号的纯色和渐变 {#symbol-color}

**iOS 26。** `symbolColorRenderingMode()`：`.flat` 是实心，`.gradient` 更有层次。

```swift
Image(systemName: "star.fill")
    .symbolColorRenderingMode(.gradient)

Image(systemName: "star.fill")
    .symbolColorRenderingMode(.flat)
```

原帖：[2026-02-16](https://x.com/ios_dev_alb/status/2023371133777526956) · [两个枚举值](https://x.com/ios_dev_alb/status/2033164409544052956)

### 让符号自己画出来 {#draw-on}

**iOS 26。** `.symbolEffect(.drawOn, isActive:)` 用在支持绘制动画的 SF Symbol 上，图标会沿笔画出现。

```swift
Image(systemName: "checkmark.circle")
    .symbolEffect(.drawOn, isActive: drawn)
```

原帖：[2026-09-24](https://x.com/ios_dev_alb/status/2103059557073211842)

### 富文本编辑器 {#rich-text}

**iOS 26。** `TextEditor` 绑到 `AttributedString` 上，就是系统富文本：粗体、斜体、下划线、颜色、对齐，都走系统工具。

```swift
@State private var note = AttributedString("Start writing")

TextEditor(text: $note)
```

原帖：[2025-07-18](https://x.com/ios_dev_alb/status/1946169598312644946)

### 把画面延伸进安全区 {#background-extension}

**iOS 26。** `backgroundExtensionEffect()` 把视图的边缘镜像出去再模糊，用来把英雄图铺满刘海和圆角外侧，画面不断开。

```swift
Image("cover")
    .resizable()
    .scaledToFill()
    .backgroundExtensionEffect()
```

原帖：[2025-07-24](https://x.com/ios_dev_alb/status/1948368106314670259)

### 内层圆角跟着外层走 {#concentric}

**iOS 26。** `.concentric` 让子视图的圆角顺着父视图的弧度，嵌套的角不会互相打架。

```swift
RoundedRectangle(cornerRadius: 28)
    .fill(.background)
    .overlay {
        RoundedRectangle(cornerRadius: .concentric)
            .padding(8)
    }
```

原帖：[2025-08-25](https://x.com/ios_dev_alb/status/1959979143707099213) · [2026-06-15 的 `.concentric` 写法](https://x.com/ios_dev_alb/status/2066556999387512872)

### 滚动边缘的模糊 {#scroll-edge}

**iOS 26。** 内容滑到导航栏、Tab 栏后面时，边缘会模糊。

- `scrollEdgeEffectStyle()`：`.soft` 更轻，`.hard` 更重。
- `scrollEdgeEffectHidden()`：把这层效果去掉，滚动时上下看起来一致。

**iOS 27 的变化：** 默认改成了 `.hard`。想要 iOS 26 那种更柔的边缘，显式加上 `.soft`。

```swift
ScrollView { content }
    .scrollEdgeEffectStyle(.soft)

ScrollView { content }
    .scrollEdgeEffectHidden()
```

原帖：[样式](https://x.com/ios_dev_alb/status/1979182308876767619) · [隐藏](https://x.com/ios_dev_alb/status/2023775312694198603) · [iOS 27 默认变 `.hard`](https://x.com/ios_dev_alb/status/2065763231130361879)

---

## 图表、网页、链接

### 三维图表 {#chart3d}

**iOS 26。** 用 `Chart3D` 在 SwiftUI 里直接画三维数据。配图里是具体的 mark，帖子正文只给了类型名。

原帖：[2025-08-27](https://x.com/ios_dev_alb/status/1960665443057770933)

### SwiftUI 的 WebView {#webview}

**iOS 26。** 终于有专门的 `WebView` 可以加载网页，再用 `WebPage` 和修饰符定制。初始化写在配图里，正文没有展开。

原帖：[`WebView`](https://x.com/ios_dev_alb/status/1959540035964878861) · [`WebPage`](https://x.com/ios_dev_alb/status/1945440366473494871)

### 在 App 内打开链接 {#in-app-browser}

**iOS 26。** `openURL` 支持 `prefersInApp`，链接可以留在 App 内的浏览器，而不是跳到 Safari。

```swift
@Environment(\.openURL) private var openURL

Button("Read more") {
    openURL(url, prefersInApp: true)
}
```

原帖：[2026-02-05](https://x.com/ios_dev_alb/status/2019471592032448709)

---

## StoreKit

### 订阅页 {#subscription-store}

`SubscriptionStoreView` 可以用很少的代码摆出整页订阅方案。外观用 `subscriptionStoreControlStyle()` 换。这个视图早于 iOS 26，他在 iOS 26 之后按新界面又发过一版视觉对照。

```swift
SubscriptionStoreView(groupID: "pro") {
    PaywallHeader()
}
.subscriptionStoreControlStyle(.buttons)
```

原帖：[控制样式](https://x.com/ios_dev_alb/status/1950866784770277437) · [iOS 26 视觉对照](https://x.com/ios_dev_alb/status/2049888790596985254)

`groupID` 的参数名以配图为准，上面只表达「把一组订阅交给系统视图」。

### 嵌进页面的订阅优惠 {#subscription-offer}

**iOS 26。** `SubscriptionOfferView` 是一块系统绘制的优惠卡片，可以放在付费墙以外的页面里，不必整页都是订阅。

原帖：[2026-02-23](https://x.com/ios_dev_alb/status/2025959623690264818)

---

## 只更新了 iOS 26 外观的旧 API

这两条不是新 API。他按 iOS 26 的键盘样式重画了对照图。

| 技巧 | 原帖 |
| --- | --- |
| `keyboardType()`：按字段弹出对应键盘 | [2026-03-21](https://x.com/ios_dev_alb/status/2035311483844706398) |
| `submitLabel()`：回车键改成 Send、Join、Search、Done | [2025-10-23](https://x.com/ios_dev_alb/status/1981323609345003816) |

---

## iOS 27

WWDC26 是 2026 年 6 月。下面这些他都标了 iOS 27 或 iOS 27.0 beta。27 正式版他在 2026-09-14 发过「Happy iOS 27 day」。

### 可以选择其中一段文字 {#text-selection}

**iOS 27 beta 2。** `.textSelection(.enabled)` 不再只能整段选中，用户可以拖出自己要的那一段。

```swift
Text(article)
    .textSelection(.enabled)
```

原帖：[2026-06-24](https://x.com/ios_dev_alb/status/2069739785543958745)

### 滚动时收起导航栏 {#nav-minimize}

**iOS 27。** `toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)` 在向下滚动时自动缩小导航栏。

```swift
NavigationStack {
    ScrollView { content }
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
}
```

原帖：[2026-06-11](https://x.com/ios_dev_alb/status/2065023702920519843) · [带两个参数的写法](https://x.com/ios_dev_alb/status/2092706966279745807)

### 隐藏状态栏 {#status-bar}

**iOS 27。**

```swift
.toolbarVisibility(.hidden, for: .statusBar)
```

原帖：[2026-06-12](https://x.com/ios_dev_alb/status/2065450982696161384)

### 强调某一个 Tab {#prominent-tab}

**iOS 27。** `role: .prominent` 让一个重要的 Tab 和其余 Tab 分开，视觉上更突出。

```swift
TabView {
    Tab("Home", systemImage: "house") { HomeView() }
    Tab("New", systemImage: "plus", role: .prominent) { Composer() }
}
```

原帖：[2026-06-09](https://x.com/ios_dev_alb/status/2064282647866552720)

### 自定义行的侧滑操作 {#swipe-container}

**iOS 27 beta。** `swipeActionsContainer()` 把 List 那种侧滑行为带到自定义行上。他点名的场景是 `ScrollView` 里的 `LazyVStack`，而不是系统 `List`。修饰符的内容闭包在配图里。

原帖：[2026-06-09](https://x.com/ios_dev_alb/status/2064463734555492678)

### sheet 改为淡入 {#cross-fade}

**iOS 27。** `.navigationTransition(.crossFade)` 让 sheet 淡入，而不是从底部滑上来。

```swift
.sheet(isPresented: $showInfo) {
    InfoView()
        .navigationTransition(.crossFade)
}
```

原帖：[2026-09-21](https://x.com/ios_dev_alb/status/2101989918046134631)

### 把 sheet 钉在左侧、中间或右侧 {#sheet-placement}

**iOS 27。** `presentationPlacement()` 取值 `.leading`、`.center`、`.trailing`。

```swift
.sheet(isPresented: $showInspector) {
    InspectorView()
        .presentationPlacement(.trailing)
}
```

原帖：[2026-09-18](https://x.com/ios_dev_alb/status/2100868676446454239)

### 菜单项的副标题 {#menu-subtitle}

**iOS 27。** 在 `Menu` 里放 `LabeledContent`，给一项加上副标题。

```swift
Menu("Account") {
    Button { } label: {
        LabeledContent("Notifications", value: "On")
    }
}
```

原帖：[2026-09-17](https://x.com/ios_dev_alb/status/2100579830395785417)。`LabeledContent` 在菜单项里的具体嵌法以配图为准。

滚动边缘在 iOS 27 默认变成 `.hard`，见 [滚动边缘](#scroll-edge)。

---

## Xcode 27 {#xcode-27}

这些不是 SwiftUI API，但是他在同一阶段发的开发技巧。

| 内容 | 说明 | 原帖 |
| --- | --- | --- |
| Markdown 编辑器 | Xcode 27 里 Markdown 有了真正的编辑器 | [2026-09-18](https://x.com/ios_dev_alb/status/2100881552917840166) |
| Delete Derived Data | Product 菜单里可以直接删 Derived Data | [2026-06-10 的回复](https://x.com/ios_dev_alb/status/2064699397569483130) |
| iPhone Duo | Xcode 27.1 beta 的模拟器可以跑 iPhone Duo | [2026-09-18](https://x.com/ios_dev_alb/status/2101011946090758626) |

**iPhone Duo 的内部操作条。** 2026-09-23 他发了一条隐藏开关：打开之后，Device Hub 里可以用真实折叠姿态去折这台设备。命令被他用方括号拆开，避免被吃掉；他自己补了一句，把方括号去掉再执行。

```bash
defaults write com.apple.dt.Devices com.apple.dt.coredevicepop.useInternalV68ActionBar -bool true
```

改完需要重新打开 Xcode。这是他公开贴出的内部开关，不是文档里的正式功能。

原帖：[说明](https://x.com/ios_dev_alb/status/2102689031687397783) · [命令在这条回复里](https://x.com/ios_dev_alb/status/2102689035273883801)

---

## 附录：同一时期反复出现的通用技巧

下面这些是 2025-06 之后他仍在发的 SwiftUI 技巧，帖子里**没有**写成 iOS 26 / 27 的新 API。他经常隔几个月重发同一条，这里每个只留一次。这不是那 15 个月里每一条非版本帖的全量存档；每天两条、内容重复的时间线，去重之后就是这些。

| 技巧 | 版本（以他的帖为准） | 原帖 |
| --- | --- | --- |
| 多层 `.shadow()` 叠出发光 | 通用 | [2026-09-27](https://x.com/ios_dev_alb/status/2104208936136065095) |
| `.hueRotation(.degrees())` 让渐变改色 | 通用 | [2026-09-28](https://x.com/ios_dev_alb/status/2104491420815855826) |
| `.symbolEffect(.variableColor.reversing, isActive:)` 用图标本身做加载态 | 支持可变颜色的符号 | [2026-09-26](https://x.com/ios_dev_alb/status/2103797870600114448) |
| `TimelineView(.animation)` 驱动 `MeshGradient` | iOS 18+ | [2026-09-25](https://x.com/ios_dev_alb/status/2103416111161106467) |
| `.transition(.blurReplace)` | iOS 17+ | [2026-09-24](https://x.com/ios_dev_alb/status/2103209265523810421) |
| `.contentTransition(.numericText())` 配 `.animation(.snappy, value:)`，数字像计数器一样滚 | 通用 | [2026-09-22](https://x.com/ios_dev_alb/status/2102314824898089461) |
| 来源上 `.matchedTransitionSource`，目标上 `.navigationTransition(.zoom)` | 他未标 26 | [2026-09-21](https://x.com/ios_dev_alb/status/2102118181615857870) |
| `.presentationSizing(.fitted)`，sheet 包住内容；他写明在 iPad 上特别有用 | iOS 18+ | [2026-04-09](https://x.com/ios_dev_alb/status/2042225681728204979) |
| `toolbarTitleDisplayMode(.inlineLarge)`，大标题但不占额外顶部空白 | iOS 17+ | [2025-09-24](https://x.com/ios_dev_alb/status/1970932362390478963) |
| `toolbarTitleMenu()`，点导航标题出菜单 | iOS 16+ | [2025-09-29](https://x.com/ios_dev_alb/status/1972666110802800903) |
| `navigationLinkIndicatorVisibility()` 隐藏 disclosure 三角 | iOS 17+ | [2025-09-20](https://x.com/ios_dev_alb/status/1969355006127046783) |
| `defaultScrollAnchor(.bottom)` 聊天从底部开始；`.center` 让不满一屏的内容居中 | iOS 17+ | [2025-11-28](https://x.com/ios_dev_alb/status/1994402132880204030) |
| `scrollClipDisabled()`，滚动内容可以画出边界，适合带阴影的卡片轮播 | 通用 | [2026-03-24](https://x.com/ios_dev_alb/status/2036404837793866180) |
| `contentMargins()` 给 `ScrollView` 或 `List` 加内边距，例如 `.contentMargins(.top, 0)` | iOS 17+ | [2026-05-02](https://x.com/ios_dev_alb/status/2050541014176161806) |
| `listSectionSpacing()` 调 section 之间的垂直间距 | iOS 17+ | [2026-01-31](https://x.com/ios_dev_alb/status/2017609127220945108) |
| `sectionActions()` 给 section 加操作 | iOS 18+ | [2025-07-27](https://x.com/ios_dev_alb/status/1949371957167665192) |
| `inspector()` 侧边检查器；`inspectorColumnWidth()` 定宽度 | iOS 17+ | [2026-04-27](https://x.com/ios_dev_alb/status/2048806149688889481) |
| `Tab` 的 `hidden()`，例如只在 iPhone 竖屏显示某个 Tab | iOS 18+ | [2026-05-28](https://x.com/ios_dev_alb/status/2059952625622155695) |
| `searchFocused()` 主动聚焦搜索框 | iOS 18+ | [2026-03-20](https://x.com/ios_dev_alb/status/2035045535946506374) |
| `.menuActionDismissBehavior(.disabled)`，选完菜单不关，方便多选 | iOS 16.4+ | [2026-05-25](https://x.com/ios_dev_alb/status/2058976748662882346) |
| `selectionDisabled()` 禁掉某个 `Picker` 选项 | iOS 17+ | [2026-05-21](https://x.com/ios_dev_alb/status/2057506270739919109) |
| `Color.mix()` 现场混出新颜色 | iOS 18+ | [2025-11-26](https://x.com/ios_dev_alb/status/1993676867723739397) |
| `MultiDatePicker` 一次选多天 | iOS 16+ | [2025-11-26](https://x.com/ios_dev_alb/status/1993731914159513697) |
| `Text` 直接显示正计时或倒计时 | 通用 | [2025-11-27](https://x.com/ios_dev_alb/status/1994109503659504070) |
| `Text` 里把 1000 显示成 1K | 通用 | [2025-07-25](https://x.com/ios_dev_alb/status/1948725954055938268) |
| Markdown 文本里的可点链接，`.tint()` 改颜色 | 通用 | 见他 2026-02 的系列帖 |
| popover 的 `arrowEdge` 决定箭头方向 | 通用 | [2025-11-27](https://x.com/ios_dev_alb/status/1994141340020691111) |
| `.lineLimit(_:reservesSpace:)` 短文本也占满固定行高 | 通用 | [2026-07-26](https://x.com/ios_dev_alb/status/2081399204564377788) |
| `.redacted(reason: .placeholder)` 骨架屏 | 通用 | [2026-07-25](https://x.com/ios_dev_alb/status/2081088578830930039) |
| 多层 `strokeBorder()` 做叠边 | 通用 | [2026-07-24](https://x.com/ios_dev_alb/status/2080788443030839782) |
| `resizable(resizingMode: .tile)` 平铺图片 | 通用 | [2025-07-29](https://x.com/ios_dev_alb/status/1950257014116143331) |
| `scaleEffect` 水平或垂直翻转 | 通用 | [2025-07-29](https://x.com/ios_dev_alb/status/1950142359196307542) |
| `controlSize()` 改圆形 `ProgressView` 的大小 | 通用 | [2025-11-30](https://x.com/ios_dev_alb/status/1995194972937781291) |
| `defaultMinListRowHeight` 统一行高 | 通用 | [2026-07-30](https://x.com/ios_dev_alb/status/2082833657627029961) |
| 工具栏 placement `.keyboard`，在键盘上方放操作 | 通用 | [2026-01-26](https://x.com/ios_dev_alb/status/2015798151286755452) |
| `Divider()` 给 `Menu` 分组 | 通用 | [2026-07-30](https://x.com/ios_dev_alb/status/2082762890331758681) |
| `confirmationDialog()` 确认删除 | 通用 | [2026-03-23](https://x.com/ios_dev_alb/status/2036094188220002437) |
| `OutlineGroup` 可展开的层级列表 | 通用 | [2026-05-23](https://x.com/ios_dev_alb/status/2058219851760468450) |
| `quickLookPreview()` 预览图片和 PDF | 通用 | [2026-05-20](https://x.com/ios_dev_alb/status/2057057643269661137) |
| `contentShape()` 扩大或修正点击区域 | 通用 | [2025-11-04](https://x.com/ios_dev_alb/status/1985670624908345728) |
| `Map` 显示可交互地图；`.mapStyle()` 切换标准 / 影像，并打开真实高程 | 通用 | [2026-09-07](https://x.com/ios_dev_alb/status/2096996851828310360) |
| sheet 的 detent、拖动指示、圆角、背景 | 通用 | [2026-03-31](https://x.com/ios_dev_alb/status/2038932862825648629) |
| `UIDevice` 配 `LabeledContent`，做一页设备信息 | 通用 | [2026-01-30](https://x.com/ios_dev_alb/status/2017258229160382602) |
| `LabeledContent` 把标题和进度、状态等内容对齐成一行 | 通用 | [2026-08-29](https://x.com/ios_dev_alb/status/2093769462214484322) |
| `listRowSpacing()` 调行与行之间的垂直间距 | 通用 | [2026-02-21](https://x.com/ios_dev_alb/status/2025181285413466564) |
| `.scrollContentBackground(.hidden)` 露出 List 后面的自定义背景 | 通用 | [2026-08-06](https://x.com/ios_dev_alb/status/2085418469667827904) |
| `.scrollDisabled(true)` 让短列表不再滚动 | 通用 | [2026-02-02](https://x.com/ios_dev_alb/status/2018369873760403961) |
| `ViewThatFits` 按可用空间自动换布局 | iOS 16+ | [2025-11-22](https://x.com/ios_dev_alb/status/1992288415220641829) |
| `ContentUnavailableView` 空状态，例如无搜索结果、无网络 | iOS 17+ | [2025-06-21](https://x.com/ios_dev_alb/status/1936375950368751687) |
| `TextRenderer` 自定义文字绘制效果 | iOS 17+ | [2025-06-22](https://x.com/ios_dev_alb/status/1936748287307964749) |
| `sensoryFeedback()` 触发系统触感 | iOS 17+ | [2025-11-03](https://x.com/ios_dev_alb/status/1985303015927284184) |
| `.buttonRepeatBehavior(.enabled)` 按住按钮连续触发 | iOS 17+ | [2026-02-02](https://x.com/ios_dev_alb/status/2018440964025790625) |
| `searchPresentationToolbarBehavior(.avoidHidingContent)`，搜索时不要藏起导航栏 | iOS 17.1+ | [2025-12-21](https://x.com/ios_dev_alb/status/2002767747801817346) |
| `findNavigator()` 调出系统查找和替换 | iOS 16+ | [2025-12-26](https://x.com/ios_dev_alb/status/2004534605911650593) |
| `.presentationCompactAdaptation(.none)`，iPhone 上 popover 不要变成 sheet | iOS 16.4+ | [2026-01-13](https://x.com/ios_dev_alb/status/2011128187992870921) |
| `navigationDocument()` 把文档 URL 挂到导航标题上，方便预览和分享 PDF | iOS 16+ | [2026-04-26](https://x.com/ios_dev_alb/status/2048387190913212446) |
| `lineLimit(2...4)` 让竖直 `TextField` 从 2 行长到 4 行再内部滚动 | iOS 16+ | [2026-05-02](https://x.com/ios_dev_alb/status/2050635460980981931) |
| `Gauge` 配 `gaugeStyle()` 显示区间内的一个值 | iOS 16+ | [2026-08-24](https://x.com/ios_dev_alb/status/2091834880514548104) |
| `tabViewSidebarBottomBar()` 给侧边栏样式的 TabView 加底部操作 | iOS 18+ | [2026-08-27](https://x.com/ios_dev_alb/status/2092939768975778223) |
| `symbolVariant()` 在 fill、circle、square、slash 之间换符号样式 | 通用 | [2026-08-10](https://x.com/ios_dev_alb/status/2086815242344894719) |
| `foregroundStyle()` 叠多层渐变，做更丰富的 SF Symbol | 通用 | [2026-08-11](https://x.com/ios_dev_alb/status/2087227717854896317) |
| `projectionEffect()` 做倾斜 | 通用 | [2026-02-01](https://x.com/ios_dev_alb/status/2018061129851760930) |
| 容器用负 `spacing` 代替 `offset()`，让视图重叠 | 通用 | [2025-06-24](https://x.com/ios_dev_alb/status/1937476910654562483) |
| `Spacer` 上加 `frame()`，把间距定死 | 通用 | [2025-06-15](https://x.com/ios_dev_alb/status/1934254233466908839) |
| 用 `frame()` 对齐，不必再用两个 `Spacer` 把内容挤到中间 | 通用 | [2026-04-22](https://x.com/ios_dev_alb/status/2046916519628521877) |
| `safeAreaInset()` 把「继续」这类按钮钉住，正文照样滚动 | 通用 | [2025-06-16](https://x.com/ios_dev_alb/status/1934644862910878120) |
| `contextMenu()` 长按出更多操作 | 通用 | [2025-06-18](https://x.com/ios_dev_alb/status/1935314901284561149) |
| `Menu` 按钮的 label 里再放一个 `Text`，系统会把它做成副标题 | 通用 | [2025-12-23](https://x.com/ios_dev_alb/status/2003479454039810363) |
| `ControlGroup` 放进 `Menu`，把一组相关操作收在一起 | 通用 | [2026-04-29](https://x.com/ios_dev_alb/status/2049442887763480868) |
| `Toggle` 的 label 可以放多行：标题、副标题、补充说明 | 通用 | [2026-04-25](https://x.com/ios_dev_alb/status/2048038165114474658) |
| `familyActivityPicker()` 弹出系统的 App 与类别选择表，适合屏幕使用时间 | 通用 | [2026-04-28](https://x.com/ios_dev_alb/status/2049098687184347391) |
| 用几行 UIKit 改 Tab 角标的普通色和选中色 | UIKit | [2025-12-16](https://x.com/ios_dev_alb/status/2000925510554042427) |

---

## 收录说明

- 正文那大约 40 条，只统计他写明是 iOS 26 或 iOS 27 的新 API。同期帖子远多于此：按每天大约一条、跨 15 个月估算，原始帖在三百条以上，其中大部分是同一技巧的重发。
- 附录是继续翻时间线时碰到的、不重复的更早 API。没有把每一天的帖子都翻完，所以附录不是「除了这 40 条以外一个不漏」。
- 他 2026 年 4 月说自己的付费 Visual Tips Kit 已经有 80 到 90 多条，之后还在加。那些图在付费包里，不在这份公开帖整理里。
- 配图里的完整工程代码没有OCR。用法示意只使用他在文字里写出的修饰符和枚举；`Chart3D`、`WebView`、`swipeActionsContainer()` 这几条他没在文字里给出初始化，文档也就没有编一个。
- 系统版本以他的帖子为准。Apple 后来如果改了默认值或把 beta API 改名，以当前 SDK 为准。
