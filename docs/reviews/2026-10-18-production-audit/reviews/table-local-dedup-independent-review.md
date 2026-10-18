# TableLayout 局部测量去重实验：独立审查

结论：**限定范围的源码审查 PASS，未发现阻塞该实验的具体语义缺陷。真实渲染等价及性能结果仍待 Root 执行。** 这不是已确认的根因修复，也不表示 Native 性能门禁已经通过。

只读审查 `/tmp/amber-audit-20261018-current/table-measurement-experiment.owned.diff`、对应 original.swift 与当前 vendor `TableView.swift`，并检查当前 border、fade modifier 和真实 `TableView` 组成。另一位独立审查者交叉核对了 LayoutValueKey 层级与动画状态，源码结论同为无阻塞发现。审查者均未改源码/测试、未构建或运行测试、未操作设备。Root 正执行旧二进制 before-control，本报告不干预该运行。

本次审查快照 SHA-256：owned diff `ec35c0b4fc1ba4489de96662df7b9a41aa672489de0f524d4ef04ded8c2a8178`；实验 `TableView.swift` `5c7b97eec3b4649350e57a0d6be45aa9d14ca9f4b4c039ed443f9b542cf3cc44`。结论限于此版本。

## 去重边界与几何

生产文件：`iosApp/vendor/SwiftStreamingMarkdown/Sources/MarkdownText/UI/TableView.swift`。

- 143–147 行只给 plain body text 设置 layout value；header 和 attachment 没有 key。启用 legacy SwiftUI fade 时也没有 key。`nil` 路径仍逐个调用原来的 `LayoutSubview.sizeThatFits`，没有用普通文本尺寸替代标题、引用附件或暂时空内容。
- 475–476 行两个字典均在单次 `makeCache` 内创建。没有跨更新、跨表格、跨环境的新增缓存；下一次实际 `makeCache` 会重新测量。该实验没有改变 SwiftUI 决定何时重建 Layout cache 的既有行为。
- 第一遍仅在 `.unspecified` proposal 下复用同一个完整 `AttributedString` 的尺寸。body 的 foreground、frame、padding、multiline alignment 等测量环境在同一表格内相同。不同 row/column 的 border 是 overlay，不改变 base view 报告的尺寸；逐 cell 的 accessibility value 与 ID 不参与几何。
- 第二遍的 `ConstrainedTextMeasurementKey` 同时包含完整 `AttributedString` 和 `columnWidths[col]`（458–461、500–508 行）。同文本出现在不同实际列宽时不会复用受限高度。key 使用实际计算的 proposal width，未用最大列宽或全表宽代替。
- 列宽 clamp、逐行取最大高度、非有限高度的既有处理、`CacheData` 结构、总尺寸计算和每个 subview 的 placement 均保留。实验仅减少同一次构建内的重复测量调用，未减少实际放置的 cell 数量。

## 属性、无障碍与逐 cell 身份

key 直接使用 renderer 正在传给 `Text` 的完整 `AttributedString`，没有转为裸字符串、characters 或规范化文本。相同可见文字但不同字体、链接、baseline 等属性不被主动合并；已有 NSAttributedString → AttributedString 转换路径未改变。

字典保存的是 `CGSize`，并不保存或复用 `View`、UILabel、动画 state 或 accessibility element。每个原 cell 的 `.id`、位置 accessibility value、border、文字和 link 属性仍存在。header 与 attachment 本身也仍保留各自真实视图。由此未发现源码上合并可访问节点、丢失行列位置或串用 cell 身份的路径；真实渲染/A11y 结果尚未运行验证。

## LayoutValueKey 层级

key 放在 plain-text 分支最外层，位于 frame、padding、id 和 border 之后。`gridCellViewFor` 外部只有 ViewBuilder 的分支和嵌套 ForEach；VStack 包裹的是整个 TableLayout，而不是单个 cell。原算法已按 `row * columnCount + col` 遍历展开后的 LayoutSubview。

源码没有发现新容器在 key 与直接 layout subview 之间隔断读取。其实际可见性仍须由真实 `TableView` 渲染验证：只测试独立 dictionary 或把 key 直接挂到一个简化 Text 上，不能证明生产 ViewBuilder/ForEach 路径能够命中。若 key 在生产层级不可见，预期主要后果是回到原测量路径、无收益；本报告不把静态层级判断当作实际命中证明。

## 动画状态

`TableCellTextView` 的 `layerAnimationCompleted` 仍逐 cell 保存，没有进入共享字典。layer-backed 分支的 primary `Text` 始终存在：动画前只是 opacity 0 加 secondary UILabel overlay，完成后返回同一文本布局。overlay 自身的 reveal mask/transform 不决定 primary Text 的报告尺寸。外部 frame/padding 在两个阶段相同。

legacy fade 的 modifier 存在 `show == false` 时的空 ZStack，所以同一文本在不同 cell 的暂时几何可能不同。实验已通过 `shouldAnimate && !usesLayerBackedTableAnimation ? nil : attributedString` 排除整个路径，未根据某个已完成 cell 的测量替代另一个尚未出现的 cell。

最终 placement 仍遍历所有 subview。源码没有发现复用尺寸会共享 `layerAnimationCompleted`、省略某个 cell 或禁用动画的路径；是否保持首次出现、追加和完成期间的真实显示，仍需下面的渲染控制。

## 最小必要的真实渲染等价验证

建议沿现有 UIHostingController/实际 vendor TableView 设施完成少量控制，不新增性能框架，也不靠纯 key/dictionary 单测替代：

1. **真实层级命中与几何对照。** 在真实 `TableView` 中放置多行重复的相同完整 AttributedString，并把相同长文本放入“第一列宽、第二列窄”的不同实际列宽。与 original binary/结果对照实际表格尺寸、窄列换行高度和可见行列边界。窄列应决定相应 row height；不要只放“第一列窄、第二列宽”，因为错误复用较高尺寸可能被 row max 掩盖。使用本轮 trace 或窄范围临时计数确认 production LayoutSubview 读到 key 且重复测量减少；否则即使渲染通过，也尚未证明实验生效。
2. **属性和非文本控制。** 同一 fixture 加一组相同 characters、不同字体/强调或 baseline 的文本，以及 header 和 citation attachment。核对样式、换行和附件位置；所有重复 cell 都仍可单独访问，行列 accessibility value 保留。可复用既有 renderer/citation fixture，不需要枚举假想自定义属性。
3. **动画与更新控制。** 对重复文本 fixture 运行 static 与 layer-backed 两种模式，核对首次 reveal、已有 cell 已完成而新 cell 尚在动画时、动画结束后的几何一致。复用 `testLayerBackedTableEntranceDoesNotChangeLayoutWhenAnimationCompletes`，但现有“总高度前后相等”不能单独覆盖不同列宽或全部 cell 可见性。再保留一个 legacy-fade 控制，确认未采用尺寸 key，文字仍逐 cell 出现；最后进行一次列宽或字体环境变化并重测，确认没有新增跨构建的旧尺寸复用。

这些控制用来验证本次实验的等价边界。性能收益另由 Root 按原 p95/max 门禁、旧二进制 before-control 和实验二进制结果判断；不调整阈值或关闭动画来使实验通过。

## 审查状态

- 源码与 owned diff：PASS，无具体阻塞发现。
- LayoutValueKey 在生产层级的实际命中：pending。
- 真实渲染、A11y、属性与动画等价：pending。
- Native 性能收益及门禁：pending；未声称修复完成。
