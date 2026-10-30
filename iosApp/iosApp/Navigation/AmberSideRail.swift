import SwiftUI

/// 侧轨上的一个按钮。
struct AmberSideRailItem: Identifiable {
    let id: String
    let systemImage: String
    let accessibilityLabel: String
    var prominent = false
    let action: () -> Void
}

/// iPhone Duo 外屏右侧竖条（状态栏 / 摄像头所在的 84pt 安全区外带）承载关键操作。
///
/// 只在「竖持且尾侧安全区够宽」时启用：普通 iPhone 横屏的刘海侧 verticalSizeClass 为
/// compact，不会误触发。按钮避开系统 occlusion 保留区（摄像头、状态栏），
/// 上组从保留区下沿开始，下组贴近底部拇指区。
private struct AmberSideRailModifier: ViewModifier {
    @Binding var isActive: Bool
    let top: [AmberSideRailItem]
    let bottom: [AmberSideRailItem]

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 低于此宽度的尾侧安全区放不下 44pt 按钮外加呼吸边距。
    static let minimumRailWidth: CGFloat = 60
    private static let buttonDiameter: CGFloat = 44
    private static let spacing: CGFloat = 14

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                // 只给外屏（compact 宽）用；内屏 regular 宽走双栏，不需要竖条。
                let layout = horizontalSizeClass == .compact
                    ? Self.layout(for: proxy, verticalSizeClass: verticalSizeClass)
                    : nil
                ZStack(alignment: .topLeading) {
                    if let layout {
                        VStack(spacing: 0) {
                            rail(top)
                            Spacer(minLength: Self.spacing)
                            rail(bottom)
                        }
                        .frame(width: layout.width, height: layout.bottomY - layout.topY)
                        .offset(x: layout.minX, y: layout.topY)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onChange(of: layout != nil, initial: true) { _, active in
                    if isActive != active { isActive = active }
                }
            }
            // 不能 ignoresSafeArea：那样 proxy 读到的尾侧安全区为 0。竖条画在安全区外，
            // 坐标原点仍是安全区左上角。
        }
    }

    private func rail(_ items: [AmberSideRailItem]) -> some View {
        VStack(spacing: Self.spacing) {
            ForEach(items) { item in
                if item.prominent {
                    Button(action: item.action) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AmberTheme.fabInk)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .amberGlassButton(
                        cornerRadius: Self.buttonDiameter / 2, prominent: true,
                        tint: AmberTheme.accent, borderShape: .circle, sizing: .fitted
                    )
                    .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                    .accessibilityLabel(item.accessibilityLabel)
                } else {
                    ChatToolbarIconButton(
                        systemImage: item.systemImage,
                        accessibilityLabel: item.accessibilityLabel,
                        size: Self.buttonDiameter, symbolSize: 18,
                        action: item.action
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    private struct Layout: Equatable {
        let minX: CGFloat
        let width: CGFloat
        let topY: CGFloat
        let bottomY: CGFloat
    }

    private static func layout(
        for proxy: GeometryProxy,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> Layout? {
        let trailing = proxy.safeAreaInsets.trailing
        guard verticalSizeClass == .regular, trailing >= minimumRailWidth else { return nil }
        // proxy 坐标：原点为安全区左上角，竖条从安全区右缘开始。
        let minX = proxy.size.width
        var topY: CGFloat = 12
        if #available(iOS 27.1, *) {
            // 系统元素（摄像头、状态栏）遮挡的区域：上组从最低遮挡下沿之后开始。
            for region in proxy.reservedRegions(kind: .occlusion) where region.frame.maxX > minX {
                topY = max(topY, region.frame.maxY + 16)
            }
        }
        let bottomY = proxy.size.height - 12
        guard bottomY - topY >= buttonDiameter * 2 else { return nil }
        return Layout(minX: minX, width: trailing, topY: topY, bottomY: bottomY)
    }
}

extension View {
    /// 在尾侧竖条可用时挂侧轨，并通过 `isActive` 告知宿主隐藏被搬走的重复按钮。
    func amberSideRail(
        isActive: Binding<Bool>,
        top: [AmberSideRailItem],
        bottom: [AmberSideRailItem] = []
    ) -> some View {
        modifier(AmberSideRailModifier(isActive: isActive, top: top, bottom: bottom))
    }
}
