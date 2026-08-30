import XCTest
@testable import iosApp

final class IOSAppLanguageTests: XCTestCase {
    func testExplicitLanguagesMatchAndroidSupportedSet() {
        XCTAssertEqual(
            IOSAppLanguage.explicitLanguages.map(\.rawValue),
            ["en", "zh-Hans", "zh-Hant", "ja", "ko", "ru"]
        )
    }

    func testSystemLanguageResolutionUsesSupportedScriptAndRegionMappings() {
        XCTAssertEqual(IOSAppLanguage.system.resolvedLanguage(preferredLanguages: ["zh-Hant-HK"]), .traditionalChinese)
        XCTAssertEqual(IOSAppLanguage.system.resolvedLanguage(preferredLanguages: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(IOSAppLanguage.system.resolvedLanguage(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(IOSAppLanguage.system.resolvedLanguage(preferredLanguages: ["fr-FR", "ja-JP"]), .japanese)
        XCTAssertEqual(IOSAppLanguage.system.resolvedLanguage(preferredLanguages: ["fr-FR"]), .english)
    }

    func testPreferencePersistsAndNormalizesInvalidStoredValue() throws {
        let suiteName = "IOSAppLanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(IOSAppLanguagePreference.selected(from: defaults), .system)

        IOSAppLanguagePreference.set(.russian, in: defaults)
        XCTAssertEqual(IOSAppLanguagePreference.selected(from: defaults), .russian)

        defaults.set("legacy-unknown", forKey: IOSAppLanguagePreference.defaultsKey)
        IOSAppLanguagePreference.normalize(in: defaults)
        XCTAssertEqual(defaults.string(forKey: IOSAppLanguagePreference.defaultsKey), IOSAppLanguage.system.rawValue)
        XCTAssertEqual(IOSAppLanguagePreference.selected(from: defaults), .system)
    }

    func testCatalogResolvesAllSupportedLanguages() {
        let expected = [
            IOSAppLanguage.english: "Language",
            .simplifiedChinese: "语言",
            .traditionalChinese: "語言",
            .japanese: "言語",
            .korean: "언어",
            .russian: "Язык",
        ]

        for (language, value) in expected {
            XCTAssertEqual(
                IOSAppLocalization.string("language.title", language: language),
                value,
                "Missing catalog value for \(language.rawValue)"
            )
        }
    }
}
