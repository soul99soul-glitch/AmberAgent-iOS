import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct SettingsHomeView: View {
    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore

    @Environment(RouterPath.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage(IOSAppearancePreferenceKeys.mode) private var appearanceMode = IOSAppearanceMode.system.rawValue
    @AppStorage(IOSAppLanguagePreference.defaultsKey) private var appLanguage = IOSAppLanguage.system.rawValue

    // 方案 B：全表统一 accent 图标 + accentTint 浅底，取消彩虹 per-row 色。
    private var generalEntries: [SettingsHomeEntry] {
        [
            .init(title: "外观", value: appearanceModeTitle, systemImage: "circle.lefthalf.filled", route: .appearance),
            .init(
                title: IOSAppLocalization.string("language.title", language: selectedLanguage),
                value: languageTitle,
                systemImage: "globe",
                route: .language
            ),
            .init(title: "显示与字体", systemImage: "slider.horizontal.3", route: .displayFont),
            .init(title: "Apple Watch", systemImage: "applewatch", route: .appleWatch),
            .init(title: "Mac Gateway", systemImage: "desktopcomputer", route: .macGateway)
        ]
    }

    private var agentEntries: [SettingsHomeEntry] {
        [
            .init(title: "灵魂与记忆", systemImage: "cylinder.split.1x2", route: .memory),
            .init(title: "运行环境", systemImage: "terminal", route: .execution),
            .init(title: "技能", systemImage: "wrench.and.screwdriver", route: .skills),
            .init(title: "权限与批准", systemImage: "shield", route: .toolPermissions)
        ]
    }

    private var modelServiceEntries: [SettingsHomeEntry] {
        [
            .init(title: "服务商", systemImage: "server.rack", route: .providers),
            .init(title: "模型与提示词", systemImage: "cpu", route: .modelDefaults),
            .init(title: "搜索服务", systemImage: "magnifyingglass", route: .searchServices),
            .init(title: "语音服务", systemImage: "speaker.wave.2", route: .ttsSettings)
        ]
    }

    private var advancedFeatureEntries: [SettingsHomeEntry] {
        [
            .init(title: "WebMount", systemImage: "globe", route: .webMount),
            .init(title: "子代理", systemImage: "person.2", route: .subagents),
            .init(title: "模型议会", systemImage: "bubble.left.and.bubble.right", route: .council),
            .init(title: "小应用", systemImage: "square.grid.2x2", route: .miniApps),
            .init(title: "小说创作", systemImage: "text.book.closed", route: .novelCreation),
            .init(title: "深度阅读", systemImage: "book.pages", route: .board)
        ]
    }

    private var dataEntries: [SettingsHomeEntry] {
        [
            .init(title: "Amber Pro", subtitle: "订阅与恢复购买", systemImage: "checkmark.seal", route: .subscription),
            .init(title: "Workspace", systemImage: "folder.badge.gearshape", route: .workspace),
            .init(title: "同步备份", systemImage: "icloud", route: .syncBackup),
            .init(title: "对话存储", systemImage: "tray.full", route: .conversationStorage)
        ]
    }

    private var appearanceModeTitle: String {
        let title = (IOSAppearanceMode(rawValue: appearanceMode) ?? .light).title
        return IOSAppLocalization.string(title, defaultValue: title)
    }

    private var selectedLanguage: IOSAppLanguage {
        IOSAppLanguage(storedValue: appLanguage)
    }

    private var languageTitle: String {
        if selectedLanguage == .system {
            return IOSAppLocalization.string("language.follow_system", language: .system)
        }
        return selectedLanguage.nativeDisplayName
    }

    /// 与首页顶栏账户入口同源：昵称首字，空昵称回落 "A"。
    private var accountInitial: String {
        let trimmed = sharedSettings.displaySetting.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "A" : trimmed).prefix(1)).uppercased()
    }

    var body: some View {
        // snapshot 为 @ObservationIgnored；读 revision 才能在改昵称后刷新头像首字。
        let _ = sharedSettings.revision
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                    settingsSection("通用设置", entries: generalEntries)
                    settingsSection("Agent 设置", entries: agentEntries)
                    settingsSection("模型与服务", entries: modelServiceEntries)
                    settingsSection("高级功能", entries: advancedFeatureEntries)
                    settingsSection("数据设置", entries: dataEntries)
                }
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            Text("设置")
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            // 右上点缀：与首页头像同组件、同 .account 路由；44 占位与返回钮对称，头像本体 38。
            Button {
                router.navigate(to: .account)
            } label: {
                HomeAccountAvatar(initial: accountInitial, size: 38)
            }
            .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.92, haptic: .lightImpact))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("我的账户")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private func settingsSection(_ title: LocalizedStringKey, entries: [SettingsHomeEntry]) -> some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: title)
            AmberFormGroup {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    AmberFormRow(
                        systemImage: entry.systemImage,
                        iconColor: AmberTheme.accent,
                        iconUsesAccentPlate: true,
                        title: entry.title,
                        subtitle: entry.subtitle,
                        trailing: entry.value,
                        showsChevron: true
                    ) {
                        router.navigate(to: entry.route)
                    }

                    if index < entries.count - 1 {
                        Divider()
                            .overlay(AmberTheme.borderSoft)
                            // 与行内文字起点对齐：hPad 14 + icon 28 + spacing 12
                            .padding(.leading, 54)
                    }
                }
            }
        }
    }

    private func placeholder(_ title: String, _ subtitle: String, _ systemImage: String) -> Route {
        .settingsPlaceholder(title: title, subtitle: subtitle, systemImage: systemImage)
    }
}

private struct SettingsHomeEntry: Identifiable {
    var id: Route { route }
    let title: String
    let subtitle: String?
    let value: String?
    let systemImage: String
    let route: Route

    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        systemImage: String,
        route: Route
    ) {
        self.title = IOSAppLocalization.string(title, defaultValue: title)
        self.subtitle = subtitle.map {
            IOSAppLocalization.string($0, defaultValue: $0)
        }
        self.value = value
        self.systemImage = systemImage
        self.route = route
    }
}
