import SwiftUI

/// Novel-flavored theme presets. Each is an ordinary `AmberThemePack` (paper ×
/// accent, flat canvas), so applying one goes through `AmberThemeRuntime` and
/// every `AmberTheme.*` color in the app follows.
struct NovelTheme: Identifiable {
    let name: String
    let note: String
    let pack: AmberThemePack

    var id: String { pack.id }

    init(_ id: String, _ name: String, _ note: String, paper: AmberThemeRuntime.Paper, accent: AmberAccentOption) {
        self.name = name
        self.note = note
        self.pack = AmberThemePack(id: id, displayName: name, paper: paper, accent: accent)
    }

    /// Single-hue canvases keep their colors in both appearances, so system
    /// chrome (status bar, titles, controls) must match the canvas instead.
    static var pinnedColorScheme: ColorScheme? {
        let paper = AmberThemeRuntime.shared.paper
        guard paper.isImmersive else { return nil }
        let hex = paper.lightPalette.background
        let luminance = 0.2126 * Double(hex >> 16 & 0xFF) + 0.7152 * Double(hex >> 8 & 0xFF) + 0.0722 * Double(hex & 0xFF)
        return luminance < 128 ? .dark : .light
    }

    static let all: [NovelTheme] = [
        NovelTheme("novel-sujian", "素笺", "暖灰纸 · 琥珀金", paper: .neutral, accent: .amberGold),
        NovelTheme("novel-xuanzhi", "宣纸", "米黄宣纸 · 陶土红", paper: .paper, accent: .terracotta),
        NovelTheme("novel-gaozhi", "稿纸", "奶油稿纸 · 钢青", paper: .pi, accent: .steelBlue),
        NovelTheme("novel-zhuqing", "竹青", "素白 · 竹叶绿", paper: .white, accent: .sage),
        NovelTheme("novel-yanzhi", "胭脂", "暖白 · 胭脂红", paper: .notion, accent: .rose),
        NovelTheme("novel-ouhe", "藕荷", "藕粉画布 · 紫藤", paper: .lotus, accent: .wisteria),
        NovelTheme("novel-mobai", "墨白", "素白 · 只留墨色", paper: .white, accent: .ink),
        NovelTheme("novel-jiangye", "绛夜", "深绛画布 · 琥珀金", paper: .garnet, accent: .amberGold)
    ]
}

struct NovelAppearanceView: View {
    @AppStorage(IOSAppearancePreferenceKeys.mode) private var appearanceMode = IOSAppearanceMode.system.rawValue
    private let runtime = AmberThemeRuntime.shared

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        Form {
            Section {
                Picker("外观模式", selection: $appearanceMode) {
                    ForEach(IOSAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(NovelTheme.pinnedColorScheme != nil)
            } header: {
                Text("外观模式")
            } footer: {
                if NovelTheme.pinnedColorScheme != nil {
                    Text("当前主题自带画布颜色，明暗随主题固定。")
                }
            }

            Section {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(NovelTheme.all) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { runtime.apply(theme.pack) }
                            AmberHaptics.trigger(.selection)
                        } label: {
                            NovelThemeCard(theme: theme, isSelected: theme.pack.matches(runtime: runtime))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("主题")
            } footer: {
                Text("主题改变纸色与强调色，作用于整个应用。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AmberTheme.background)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A miniature page in the theme's own colors: title line, a card, an accent
/// button and the vermilion seal dot.
private struct NovelThemeCard: View {
    let theme: NovelTheme
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = colorScheme == .dark ? theme.pack.paper.darkPalette : theme.pack.paper.lightPalette
        let accent = Color(hex: theme.pack.accent.accentHex)
        let foreground = Color(hex: palette.foreground)

        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule()
                    .fill(foreground)
                    .frame(width: 44, height: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(foreground.opacity(0.35)).frame(height: 3)
                    Capsule().fill(foreground.opacity(0.35)).frame(height: 3)
                    Capsule().fill(foreground.opacity(0.35)).frame(width: 40, height: 3)
                }
                .padding(9)
                .background(Color(hex: palette.surface), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                HStack {
                    Capsule()
                        .fill(accent)
                        .frame(width: 36, height: 12)
                    Spacer()
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(AmberTheme.accentRed)
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(-6))
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: palette.background), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? accent : AmberTheme.border, lineWidth: isSelected ? 2 : 0.75)
            }

            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.name)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(AmberTheme.foreground)
                    Text(theme.note)
                        .font(.caption2)
                        .foregroundStyle(AmberTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.name)，\(theme.note)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
