import CoreGraphics

enum ChatTopBarLayout {
    static let avatarDiameter: CGFloat = 76
    static let islandTopOffset: CGFloat = 8
    static let avatarCapsuleOverlap: CGFloat = 8
    static let islandCapsuleTopOffset: CGFloat = avatarDiameter - avatarCapsuleOverlap // 68
    static let islandCapsuleHeight: CGFloat = 32
    static let islandHeight: CGFloat = islandCapsuleTopOffset + islandCapsuleHeight // 100
    static let controlsHeight: CGFloat = islandTopOffset + islandHeight // 108
    static let horizontalInset: CGFloat = 18
    static let toolbarButtonDiameter: CGFloat = 40
    static let toolbarTopPadding: CGFloat = 10
    static let toolbarHeight: CGFloat = toolbarTopPadding + 44
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
    /// 给静息消息与顶栏主体保留的额外间距。
    static let softEdgeExtension: CGFloat = 6
}
