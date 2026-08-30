import XCTest
@testable import iosApp

final class IOSTTSPlayerTests: XCTestCase {
    func testResolvedAppLanguageCodeUsesSelectedVoiceLanguage() {
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(selectedLanguage: .english),
            "en-US"
        )
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(selectedLanguage: .simplifiedChinese),
            "zh-CN"
        )
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(selectedLanguage: .traditionalChinese),
            "zh-TW"
        )
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(selectedLanguage: .japanese),
            "ja-JP"
        )
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(selectedLanguage: .korean),
            "ko-KR"
        )
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(selectedLanguage: .russian),
            "ru-RU"
        )
    }

    func testResolvedAppLanguageCodeResolvesSystemSelection() {
        XCTAssertEqual(
            IOSTTSPlayer.resolvedAppLanguageCode(
                selectedLanguage: .system,
                preferredLanguages: ["ja-JP", "en-US"]
            ),
            "ja-JP"
        )
    }
}
