import SwiftUI

struct LanguageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(IOSAppLanguagePreference.defaultsKey)
    private var appLanguage = IOSAppLanguage.system.rawValue

    private var selectedLanguage: IOSAppLanguage {
        IOSAppLanguage(storedValue: appLanguage)
    }

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header

                    AmberSectionLabel(verbatim: localized("language.section"))
                    AmberFormGroup {
                        ForEach(Array(IOSAppLanguage.allCases.enumerated()), id: \.element.id) { index, language in
                            languageRow(language)

                            if index < IOSAppLanguage.allCases.count - 1 {
                                Divider()
                                    .overlay(AmberTheme.borderSoft)
                                    .padding(.leading, 14)
                            }
                        }
                    }

                    Text(verbatim: localized("language.change_applies"))
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
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
            AmberGlassCircleButton(
                systemImage: "chevron.left",
                accessibilityLabel: localized("language.back_to_settings"),
                size: 44,
                symbolSize: 20
            ) {
                dismiss()
            }

            Spacer()

            Text(verbatim: localized("language.title"))
                .font(.title2.weight(.bold))
                .foregroundStyle(AmberTheme.foreground)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private func languageRow(_ language: IOSAppLanguage) -> some View {
        let isSelected = language == selectedLanguage
        let subtitle = language == .system ? localized("language.follow_system_detail") : nil

        return Button {
            appLanguage = language.rawValue
            Task { @MainActor in
                await AgentLiveActivityController.shared.refreshLanguage()
                WatchTaskCoordinator.shared.refreshLanguage()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: optionTitle(language))
                        .font(.body)
                        .foregroundStyle(AmberTheme.foreground)

                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AmberTheme.accent)
                    .frame(width: 24, height: 24)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: subtitle == nil ? 52 : 64)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmberPressFeedbackStyle(pressedScale: 0.985, haptic: .selection))
        .accessibilityLabel(optionTitle(language))
        .accessibilityValue(isSelected ? localized("language.selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func optionTitle(_ language: IOSAppLanguage) -> String {
        if language == .system {
            return localized("language.follow_system")
        }
        return language.nativeDisplayName
    }

    private func localized(_ key: String) -> String {
        IOSAppLocalization.string(key, language: selectedLanguage)
    }
}
