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
}
