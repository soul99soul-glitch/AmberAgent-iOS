import Foundation

enum IOSAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"

    static let explicitLanguages: [IOSAppLanguage] = [
        .english,
        .simplifiedChinese,
        .traditionalChinese,
        .japanese,
        .korean,
        .russian,
    ]

    var id: String { rawValue }

    var nativeDisplayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .russian: "Русский"
        }
    }

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .system
    }

    func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> IOSAppLanguage {
        guard self == .system else { return self }

        for identifier in preferredLanguages {
            if let language = Self.supportedLanguage(matching: identifier) {
                return language
            }
        }
        return .english
    }

    func resolvedLocale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        Locale(identifier: resolvedLanguage(preferredLanguages: preferredLanguages).rawValue)
    }

    private static func supportedLanguage(matching identifier: String) -> IOSAppLanguage? {
        let canonical = Locale.identifier(.bcp47, from: identifier)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if canonical == "en" || canonical.hasPrefix("en-") { return .english }
        if canonical == "ja" || canonical.hasPrefix("ja-") { return .japanese }
        if canonical == "ko" || canonical.hasPrefix("ko-") { return .korean }
        if canonical == "ru" || canonical.hasPrefix("ru-") { return .russian }
        if canonical == "zh" || canonical.hasPrefix("zh-") {
            let parts = Set(canonical.split(separator: "-").map(String.init))
            if !parts.isDisjoint(with: ["hant", "tw", "hk", "mo"]) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }
        return nil
    }
}

enum IOSAppLanguagePreference {
    static let defaultsKey = "app.amber.ios.language"

    static func selected(from defaults: UserDefaults = .standard) -> IOSAppLanguage {
        guard let storedValue = defaults.string(forKey: defaultsKey) else { return .system }
        return IOSAppLanguage(storedValue: storedValue)
    }

    static func set(_ language: IOSAppLanguage, in defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }

    static func normalize(in defaults: UserDefaults = .standard) {
        guard let storedValue = defaults.string(forKey: defaultsKey),
              IOSAppLanguage(rawValue: storedValue) == nil else {
            return
        }
        set(.system, in: defaults)
    }
}

enum IOSAppLocalization {
    static func string(
        _ key: String,
        table: String? = nil,
        defaultValue: String? = nil,
        language: IOSAppLanguage = IOSAppLanguagePreference.selected(),
        preferredLanguages: [String] = Locale.preferredLanguages,
        bundle: Bundle = .main
    ) -> String {
        let resolved = language.resolvedLanguage(preferredLanguages: preferredLanguages)
        guard let localizationPath = bundle.path(forResource: resolved.rawValue, ofType: "lproj"),
              let localizedBundle = Bundle(path: localizationPath) else {
            return defaultValue ?? key
        }
        return localizedBundle.localizedString(forKey: key, value: defaultValue, table: table)
    }

    static func formatted(
        _ key: String,
        defaultValue: String? = nil,
        arguments: [CVarArg],
        language: IOSAppLanguage = IOSAppLanguagePreference.selected(),
        preferredLanguages: [String] = Locale.preferredLanguages,
        bundle: Bundle = .main
    ) -> String {
        let format = string(
            key,
            defaultValue: defaultValue,
            language: language,
            preferredLanguages: preferredLanguages,
            bundle: bundle
        )
        let locale = language.resolvedLocale(preferredLanguages: preferredLanguages)
        return String(format: format, locale: locale, arguments: arguments)
    }
}
