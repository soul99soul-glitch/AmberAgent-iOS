import CoreGraphics

enum ChatTopBarLayout {
    static let controlsHeight: CGFloat = 54
    static let toolbarButtonDiameter: CGFloat = 38
    /// 停靠位自绘面板与岛上回顾的系统 popover 圆角保持一致。
    static let dockPanelCornerRadius: CGFloat = 30
    /// 每侧保留 44pt 命中区和 12pt 间距，鼓动后的岛也不能进入按钮区域。
    static let islandSideGutter: CGFloat = 56
    static func availableIslandWidth(in width: CGFloat) -> CGFloat {
        min(islandMaxWidth, max(0, width - islandSideGutter * 2) / 1.06)
    }
    /// Design max width for the activity / mode capsule shell.
    static let islandMaxWidth: CGFloat = 268
    /// Max title text width inside the island (shell − horizontal pad − optional orb).
    static let islandTitleMaxWidth: CGFloat = 200
    /// 顶栏 `safeAreaBar` 在控件下方的透明延伸，驱动原生 soft edge 几何。
    /// 模拟器会把 soft edge 画满整段 bar（易显「模糊带偏长」）；真机 Liquid Glass 更短。
    /// 取小延伸：盖住按钮下沿即可，避免 Simulator 上大面积雾带。
    static let softEdgeExtension: CGFloat = 8
}
