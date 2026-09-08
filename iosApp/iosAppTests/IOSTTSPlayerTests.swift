import XCTest
import AVFoundation
@testable import iosApp

final class IOSTTSPlayerTests: XCTestCase {
    @MainActor
    func testStaleUtteranceCallbackDoesNotStopCurrentSpeech() async {
        let player = IOSTTSPlayer()
        defer { player.stop() }

        player.speak(text: "旧试听文本")
        player.speak(text: "新试听文本")
        player.speechSynthesizer(
            AVSpeechSynthesizer(),
            didCancel: AVSpeechUtterance(string: "已结束的旧试听文本")
        )

        await Task.yield()
        await Task.yield()

        XCTAssertTrue(player.isSpeaking)
    }

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
