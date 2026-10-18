import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct HomePressStateStyle: ButtonStyle {
    @Binding var pressed: Bool
    let scale: CGFloat
    /// E 版会话行 `transform-origin: left center`；其它控件保持中心。
    var scaleAnchor: UnitPoint = .center
    var haptic: AmberHapticEvent? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1, anchor: scaleAnchor)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, isPressed in
                pressed = isPressed
                guard isPressed, let haptic else { return }
                AmberHaptics.trigger(haptic)
            }
            // 行在按压中被回收/重建时，避免 pressed 残留导致按压垫底卡住。
            .onDisappear { pressed = false }
    }
}

enum HomeCardSlice: Equatable { case top, middle, bottom, single }

struct HomeSliceShape: Shape {
    let slice: HomeCardSlice
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = AmberTheme.homeCardRadius
        switch slice {
        case .top: return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous).path(in: rect)
        case .bottom: return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous).path(in: rect)
        case .single: return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        case .middle: return Rectangle().path(in: rect)
        }
    }
}

/// 会话空态：与列表一体卡同圆角/投影。
struct HomeEmptyCard: View {
    let title: LocalizedStringKey
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let ambient = AmberTheme.cardShadowAmbientGeometry(for: colorScheme)
        Text(title)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(AmberTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background {
                if AmberThemeRuntime.shared.emptyArt == .character {
                    Group {
                        switch AmberThemeRuntime.shared.canvasStyle {
                        case .lineGrid:
                            // Keep quieter than page gutters; match HomeCardCanvasTexture scale.
                            AmberLineGridOverlay()
                                .opacity(HomeCardCanvasTexture.lineGridOpacity)
                        case .paperGrain:
                            AmberPaperGrainOverlay()
                                .opacity(HomeCardCanvasTexture.paperGrainOpacity)
                        case .dotGrid, .flat:
                            AmberDotGridOverlay()
                                .opacity(HomeCardCanvasTexture.dotGridOpacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AmberTheme.homeCardRadius, style: .continuous))
                }
            }
            .background(HomeSliceShape(slice: .single).fill(AmberTheme.card))
            .overlay { HomeSliceShape(slice: .single).stroke(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
            .shadow(color: AmberTheme.cardShadowContact, radius: 1, y: 1)
            .shadow(color: AmberTheme.cardShadowAmbient, radius: ambient.radius, y: ambient.y)
            .padding(.horizontal, 16)
    }
}

struct HomeShortcut: View {
    let entry: HomeShortcutEntry
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var shortcutLabelSize: CGFloat = 11
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Icon skin from theme pack; VStack layout frozen.
                HomeShortcutIconView(entry: entry, size: 20)
                Text(
                    verbatim: IOSAppLocalization.string(
                        entry.title,
                        defaultValue: entry.title
                    )
                )
                    // Chrome typeface from theme pack; not chat body IOSChatFont.
                    .font(AmberChromeFont.system(size: shortcutLabelSize, weight: .semibold))
                    .tracking(0.11)
                    .lineLimit(2)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(hovering || pressed ? AmberTheme.foreground : AmberTheme.muted)
            .frame(
                minWidth: dynamicTypeSize.isAccessibilitySize ? 144 : nil,
                maxWidth: dynamicTypeSize.isAccessibilitySize ? 144 : .infinity,
                minHeight: 44
            )
            .background(hovering || pressed ? AmberTheme.press : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStateStyle(pressed: $pressed, scale: 0.92, haptic: .selection))
        .onHover { hovering = $0 }
    }
}

struct HomeContinueButton: View {
    let model: HomeContinueCardModel
    let action: (HomeContinueCardModel.Destination) -> Void
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var continueTitleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption2) private var continueMetaSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var continueCTAFontSize: CGFloat = 13
    var body: some View {
        Button { action(model.destination) } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 14) {
                            featureIcon
                            titleBlock
                        }
                        continueCTA(expands: true)
                    }
                } else {
                    HStack(spacing: 14) {
                        featureIcon
                        titleBlock
                        continueCTA(expands: false)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .background(pressed ? AmberTheme.press : (hovering ? AmberTheme.hoverCard : Color.clear))
        }
        .buttonStyle(HomePressStateStyle(pressed: $pressed, scale: 0.985, haptic: .lightImpact))
        .onHover { hovering = $0 }
        .accessibilityLabel("\(model.title)，\(model.meta)，\(model.ctaTitle)")
    }

    private var featureIcon: some View {
        HomePhosphorIcon(model.feature.icon, size: 22)
            .foregroundStyle(AmberTheme.avatarActiveInk)
            .frame(width: 44, height: 44)
            .background(
                AmberTheme.avatarActive,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.title)
                .font(.system(size: continueTitleSize, weight: .semibold))
                .tracking(0.075)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Text(model.meta)
                .font(.system(size: continueMetaSize, weight: .regular))
                .tracking(0.11)
                .foregroundStyle(AmberTheme.muted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
        }
        .foregroundStyle(AmberTheme.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func continueCTA(expands: Bool) -> some View {
        // 续接 CTA：浅强调色底 + 主墨字（次级动作）；主强调留给右下「新对话」混色玻璃。
        let label = Text(model.ctaTitle)
            .font(.system(size: continueCTAFontSize, weight: .semibold))
            .tracking(0.26)
            .foregroundStyle(AmberTheme.foreground)
        let fill = hovering || pressed ? AmberTheme.avatarActive : AmberTheme.accentTint
        if expands {
            label
                .padding(.vertical, 7)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(fill, in: Capsule())
        } else {
            label
                .padding(.vertical, 7)
                .padding(.horizontal, 18)
                .frame(minHeight: 32)
                .background(fill, in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct HomeCascade: ViewModifier {
    let delay: Double
    /// false 时跳过动画直接呈现：级联是一次性入场，List 行回收/搜索重建不得重播。
    var enabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .onAppear {
                guard !reduceMotion else { appeared = true; return }
                guard enabled else { appeared = true; return }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.48).delay(delay)) { appeared = true }
            }
    }
}

extension View {
    func homeCascade(delay: Double, enabled: Bool = true) -> some View { modifier(HomeCascade(delay: delay, enabled: enabled)) }
}

/// 首页展开搜索条的中性玻璃表面；按钮使用原生玻璃按钮样式。
/// iOS 26+：原生 Liquid Glass（skill: 真 `glassEffect`，轻垫底保证暖灰画布上可读，不做假 solid chip）。
/// 更早系统：ultraThinMaterial + E 版描边/投影回退。
private struct HomeGlassControlModifier: ViewModifier {
    let cornerRadius: CGFloat
    var interactive: Bool = true

    private var padOpacity: Double {
        switch AmberThemeRuntime.shared.glassChrome {
        case .standard: 0.28
        case .quieter: 0.18
        case .solid: 0.52
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let control = content
            .contentShape(shape)
        if #available(iOS 26.0, *) {
            // 垫底极轻：帮助折射；强度由主题 glassChrome 弱控。
            control
                .background(AmberTheme.homeGlassTop.opacity(padOpacity), in: shape)
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            control
                .background(.ultraThinMaterial, in: shape)
                .background(
                    LinearGradient(
                        colors: [
                            AmberTheme.homeGlassTop.opacity(padOpacity / 0.28),
                            AmberTheme.homeGlassBottom.opacity(padOpacity / 0.28),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: shape
                )
                .overlay { shape.strokeBorder(AmberTheme.homeGlassEdge, lineWidth: 0.5) }
                .overlay(alignment: .top) {
                    shape.strokeBorder(AmberTheme.homeGlassHighlight, lineWidth: 0.5)
                        .frame(height: 1)
                        .clipShape(shape)
                }
                .shadow(color: AmberTheme.homeGlassShadowAmbient, radius: 14, y: 10)
                .shadow(color: AmberTheme.homeGlassShadowContact, radius: 4, y: 2)
        }
    }
}

extension View {
    func homeGlassControl(cornerRadius: CGFloat, interactive: Bool = true) -> some View {
        modifier(HomeGlassControlModifier(cornerRadius: AmberTheme.controlRadius(cornerRadius), interactive: interactive))
            .overlay { RoundedRectangle(cornerRadius: AmberTheme.controlRadius(cornerRadius)).strokeBorder(AmberTheme.border, lineWidth: AmberTheme.designBorderWidth).allowsHitTesting(false) }
    }

    /// iOS 26 原生 glass morph 标记；旧系统 no-op。
    @ViewBuilder
    func homeGlassEffectID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// 首页齿轮钮保持原生圆形轮廓，主题圆角不参与系统按钮的按压形变。
struct HomeGlassCircleButton: View {
    let icon: HomePhosphor
    let accessibilityLabel: String
    var size: CGFloat = 38
    var iconSize: CGFloat = 20
    var tint: Color = AmberTheme.muted
    var glassNamespace: Namespace.ID? = nil
    var glassEffectID: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            AmberHaptics.trigger(.lightImpact)
            action()
        } label: {
            HomePhosphorIcon(icon, size: iconSize)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .amberGlassButton(cornerRadius: size / 2, borderShape: .circle, sizing: .fitted)
        .controlSize(.mini)
        .frame(width: size, height: size)
        .modifier(HomeOptionalGlassEffectID(id: glassEffectID, namespace: glassNamespace))
        .accessibilityLabel(accessibilityLabel)
    }
}

struct HomeOptionalGlassEffectID: ViewModifier {
    let id: String?
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let id, let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}
