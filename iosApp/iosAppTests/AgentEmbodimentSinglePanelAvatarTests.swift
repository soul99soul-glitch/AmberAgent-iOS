import Foundation
import XCTest

/// 形象人设面板的结构契约测试（源文本不变量，沿用 NovelSessionTranscriptProjectionTests 的做法）。
///
/// 用户真机实测纠偏：外层「形象人设」sheet 上又盖一层「形象设定」sheet，
/// 同一 Agent 头像出现两次、上下各有一个「完成」。本测试锁死修复后的三条硬性约束：
/// 1. 形象编辑必须留在同一面板内，不得再 present 第二层 sheet；
/// 2. 全面板只能有一个头像来源，嵌入态必须关闭内容自带的头像；
/// 3. 「完成」出口唯一，「恢复默认」降级进编辑工具区。
final class AgentEmbodimentSinglePanelAvatarTests: XCTestCase {

    private func sourceText(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // iosAppTests/
            .deletingLastPathComponent()   // iosApp/
            .deletingLastPathComponent()   // repo root (AmberAgent/ios)
        let url = root.appendingPathComponent("iosApp/iosApp/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 取 `start` 标记之后、`end` 标记之前的片段；`end` 为空则取到文件末尾。
    private func slice(_ source: String, from start: String, to end: String?) -> String {
        guard let startRange = source.range(of: start) else { return "" }
        let tail = source[startRange.upperBound...]
        guard let end, let endRange = tail.range(of: end) else { return String(tail) }
        return String(tail[..<endRange.lowerBound])
    }

    func testAvatarEditingStaysInsideEmbodimentPanel() throws {
        let sheet = try sourceText("AgentSoul/AgentEmbodimentHomeSheet.swift")

        XCTAssertFalse(
            sheet.contains("AmberPersonaStudioSheet"),
            "更换形象不得再 present 第二层 sheet（sheet-on-sheet 是本次纠偏的根因）。"
        )
        XCTAssertFalse(
            sheet.contains("isShowingPersonaStudio"),
            "形象编辑必须由面板内联状态驱动，不能保留 sheet 呈现开关。"
        )
        XCTAssertTrue(
            sheet.contains("AmberPersonaStudioContent("),
            "形象编辑必须在同一面板的内容区内嵌 AmberPersonaStudioContent。"
        )
        XCTAssertTrue(
            sheet.contains("transitionAvatarMode(to: true)"),
            "头像与更换形象入口必须走同一个原位编辑态切换。"
        )
        XCTAssertTrue(
            sheet.contains("accessibilityIdentifier(\"embodiment.avatarBackButton\")"),
            "编辑态必须提供唯一明确的返回出口，与主「完成」区分开。"
        )
    }

    func testEmbeddedContentDrawsNoSecondAvatarAndNoSecondDone() throws {
        let sheet = try sourceText("AgentSoul/AgentEmbodimentHomeSheet.swift")
        XCTAssertTrue(
            sheet.contains("showsAvatar: false"),
            "嵌入态必须关闭内容自带头像，全面板只保留外层那一个头像。"
        )
        XCTAssertTrue(
            sheet.contains("showsInlineReset: true"),
            "「恢复默认」必须降级进编辑工具区，不与面板标题争层级。"
        )

        let studio = try sourceText("Navigation/AmberPersonaStudio.swift")

        let content = slice(studio, from: "struct AmberPersonaStudioContent: View {", to: "struct AmberPersonaStudioSheet: View {")
        XCTAssertFalse(content.isEmpty, "缺少可嵌入的 AmberPersonaStudioContent。")
        XCTAssertTrue(
            content.contains("if showsAvatar {"),
            "内容头像必须受 showsAvatar 开关控制。"
        )
        XCTAssertFalse(
            content.contains(".navigationTitle"),
            "嵌入内容不得自带标题栏，否则面板出现第二个标题。"
        )
        XCTAssertFalse(
            content.contains("dismiss()"),
            "嵌入内容不得自带「完成」出口，主出口只能由外层面板提供。"
        )
        XCTAssertTrue(
            content.contains("if showsInlineReset, store.canResetToDefault {"),
            "嵌入态的「恢复默认」必须留在内容工具区内。"
        )

        let standalone = slice(studio, from: "struct AmberPersonaStudioSheet: View {", to: nil)
        XCTAssertTrue(
            standalone.contains(".navigationTitle"),
            "独立入口（顶部栏直连、双栏抽屉）仍保留自己的标题与完成出口。"
        )
    }

    func testSingleScrollContainerAndContinuousDismissalInvariants() throws {
        let sheet = try sourceText("AgentSoul/AgentEmbodimentHomeSheet.swift")
        let bodySlice = slice(sheet, from: "var body: some View {", to: "// MARK: - 顶部导航栏")

        // 1. 形象头卡与下方内容必须共处同一个顶层 ScrollView，避免上下半区割裂导致下滑收起在交界处顿挫。
        guard let scrollRange = bodySlice.range(of: "ScrollView(.vertical, showsIndicators: false)"),
              let headerRange = bodySlice.range(of: "personaHeroHeader"),
              let idRange = bodySlice.range(of: ".id(isEditingAvatar ? Self.avatarEditorScrollID") else {
            XCTFail("AgentEmbodimentHomeSheet.body 缺少统一 ScrollView 或 personaHeroHeader。")
            return
        }
        XCTAssertLessThan(
            scrollRange.lowerBound,
            headerRange.lowerBound,
            "personaHeroHeader 必须位于唯一 ScrollView 内部，保证全区域下滑与系统 sheet 手势一致衔接。"
        )
        XCTAssertLessThan(
            headerRange.lowerBound,
            idRange.lowerBound,
            "Tab/编辑态切换的 .id(...) 必须挂在内部内容容器而非 ScrollView 本身，防止重建 UIScrollView 丢失系统手势绑定。"
        )

        // 2. 全面板只允许一个动态 AmberAgentPersonaMedallionView（快照列表统一用轻量 SnapshotMiniAvatar）。
        let medallionCount = sheet.components(separatedBy: "AmberAgentPersonaMedallionView(").count - 1
        XCTAssertEqual(
            medallionCount,
            1,
            "AgentEmbodimentHomeSheet 内只能存在 1 个 AmberAgentPersonaMedallionView。"
        )

        // 3. 形象人设与独立形象设定 sheet 均只使用 [.large] 停靠档，不设 .medium 中间档阻断下滑收起。
        let chatView = try sourceText("ChatView.swift")
        let personaSheetSlice = slice(
            chatView,
            from: ".sheet(isPresented: $isPresentingEmbodimentHome)",
            to: ".sheet(isPresented: $isPresentingCloudGatewaySettings)"
        )
        XCTAssertFalse(
            personaSheetSlice.contains(".medium"),
            "形象人设与形象设定面板不应设置 .medium 中间停靠档位，避免下滑收起中途卡停。"
        )
    }

    func testLiquidGlassLensForegroundMaterialAndSharedFloatingSheetInvariants() throws {
        // 1. 底部 3+1 导航：单一持久化 AmberDuetBottomSwitcher + 原生 Liquid Glass 透镜 ID 与 matchedGeometry 过渡 + 横滑连续手势
        let composer = try sourceText("Chat/Composer/ChatViewComposer.swift")
        let switcherOccurrences = composer.components(separatedBy: "AmberDuetBottomSwitcher(").count - 1
        XCTAssertEqual(
            switcherOccurrences,
            1,
            "ChatViewComposer 必须只挂载单一持久化的 AmberDuetBottomSwitcher，避免切换标签时销毁重建丢失 @Namespace 与玻璃容器身份。"
        )

        let duetChrome = try sourceText("Navigation/AmberDuetChrome.swift")
        XCTAssertTrue(
            duetChrome.contains(".glassEffectID(\"duetActiveTabLens\""),
            "底部模式切换器选中透镜必须使用原生 .glassEffectID 以支持连续移动与透镜形变。"
        )
        XCTAssertTrue(
            duetChrome.contains(".glassEffectTransition(.matchedGeometry)"),
            "底部模式切换器选中透镜必须声明 .glassEffectTransition(.matchedGeometry)。"
        )
        XCTAssertTrue(
            duetChrome.contains("modeScrubGesture"),
            "底部模式切换器必须支持手指横滑连续透镜跟随与形变。"
        )
        let trackWellSlice = slice(duetChrome, from: "private struct DuetBottomTrackWellSurface: ViewModifier {", to: "private struct DuetActiveModeLensModifier")
        XCTAssertTrue(
            trackWellSlice.contains("AmberTheme.surface2") && trackWellSlice.contains("AmberTheme.homeGlassHighlight") && trackWellSlice.contains("AmberTheme.homeGlassShadowAmbient"),
            "底部左侧三段式切换轨必须具备清晰可辨的完整外层液态玻璃胶囊轮廓（凹槽填充、镜面高光环与环境阴影），避免三个标签看起来像孤立按钮。"
        )

        // 2. 前后台恢复首帧玻璃连续性：composerDockGlass 与 ComposerDockCircleGlass 必须具备半透材质衬底，且不靠 asyncAfter 延时掩盖
        let dockComponents = try sourceText("ComposerDockComponents.swift")
        let dockGlassSlice = slice(dockComponents, from: "func composerDockGlass(cornerRadius: CGFloat)", to: "struct ChatScrollToBottomButton")
        XCTAssertTrue(
            dockGlassSlice.contains(".ultraThinMaterial"),
            "composerDockGlass 必须垫有半透材质底，确保从后台回前台首帧（CABackdropLayer 重连前）玻璃材质连续可见。"
        )
        let circleGlassSlice = slice(dockComponents, from: "struct ComposerDockCircleGlass: ViewModifier", to: "struct ContextRingButton")
        XCTAssertTrue(
            circleGlassSlice.contains(".ultraThinMaterial"),
            "ComposerDockCircleGlass 必须垫有半透材质底，确保后台回前台首帧圆钮材质不缺失。"
        )

        // 3. 共享悬浮面板下滑收起：统一走 .amberFloatingSheet + .scrollBounceBehavior(.basedOnSize) + 底层画布静默环境键
        let designSystem = try sourceText("AmberDesignSystem.swift")
        XCTAssertTrue(
            designSystem.contains("struct AmberFloatingSheetModifier: ViewModifier"),
            "AmberDesignSystem 必须提供统一的 AmberFloatingSheetModifier。"
        )
        XCTAssertTrue(
            designSystem.contains(".scrollBounceBehavior(.basedOnSize)"),
            "共享悬浮面板修饰器必须配置 .scrollBounceBehavior(.basedOnSize) 以消除下滑手势交接顿挫。"
        )
        let chatView = try sourceText("ChatView.swift")
        XCTAssertTrue(
            chatView.contains(".environment(\\.amberIsUnderlyingSheetPresented, isAnyFloatingSheetPresented)"),
            "ChatView 必须在悬浮面板呈现期间标记 amberIsUnderlyingSheetPresented，暂停底层高频几何与周期重绘。"
        )
        XCTAssertFalse(
            chatView.contains(".opacity(composerState.activeDuetTab == .chat ? 1.0 : 0.35)"),
            "切换底部模式时不得将 topBar 压暗至 0.35，确保顶栏按钮与头像在所有模式下保持清晰可读。"
        )

        // 4. 顶栏前景可读性底线：左右圆钮与中央头像必须将前景内容作为玻璃修饰器主体（禁止 ZStack 兄弟 .glassEffect 遮挡/模糊前景）
        let composerViews = try sourceText("ChatComposerViews.swift")
        let toolbarButtonSlice = slice(composerViews, from: "struct ChatToolbarIconButton: View", to: "enum ComposerReasoningOption")
        XCTAssertTrue(
            toolbarButtonSlice.contains(".modifier(ChatToolbarCircleGlass())"),
            "ChatToolbarIconButton 必须直接将 Image 作为 ChatToolbarCircleGlass 的前景主体，禁止 ZStack 背景圆独立调用 .glassEffect 遮挡图标。"
        )
        XCTAssertFalse(
            toolbarButtonSlice.contains("ZStack"),
            "ChatToolbarIconButton 不得使用 ZStack 兄弟玻璃层叠加前景图标。"
        )

        let trailingDock = try sourceText("ChatTopBarTrailingDock.swift")
        let dockButtonSlice = slice(trailingDock, from: "private var dockButtonContent: some View", to: "private func noticePreview")
        XCTAssertTrue(
            dockButtonSlice.contains(".modifier(ChatTopBarDockGlass(tint: dockTint))"),
            "ChatTopBarTrailingDock 必须将前景图标作为 ChatTopBarDockGlass 主体，并将 badge 置于玻璃层之后的 .overlay。"
        )
        XCTAssertFalse(
            dockButtonSlice.contains("ZStack"),
            "ChatTopBarTrailingDock 不得使用 ZStack 兄弟玻璃层遮挡图标或角标。"
        )

        let medallion = try sourceText("Navigation/AmberPersonaMedallionView.swift")
        let medallionSlice = slice(medallion, from: "struct AmberAgentPersonaMedallionView: View", to: "private struct PersonaMedallionBackdropGlass")
        XCTAssertTrue(
            medallionSlice.contains("PersonaMedallionBackdropGlass("),
            "AmberAgentPersonaMedallionView 必须通过 PersonaMedallionBackdropGlass 将材质置于 content 背景，保证头像在前景最上层。"
        )
        XCTAssertFalse(
            medallionSlice.contains("ZStack"),
            "AmberAgentPersonaMedallionView 不得将玻璃圆作为 ZStack 兄弟节点叠加在头像前景之前。"
        )
    }
}
