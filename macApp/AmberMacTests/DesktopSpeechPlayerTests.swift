import XCTest
@testable import AmberMac

@MainActor final class DesktopSpeechPlayerTests: XCTestCase {
    private final class Backend: DesktopSpeechBackend {
        var requests: [DesktopSpeechRequest] = []
        var callbacks: [UUID: @MainActor @Sendable (UUID, DesktopSpeechCompletion) -> Void] = [:]
        var stopCount = 0
        var fails = false
        func voices() async -> [DesktopSpeechVoice] { [DesktopSpeechVoice(id: "voice", name: "System Voice", language: "zh-CN")] }
        func speak(_ request: DesktopSpeechRequest,
            completion: @escaping @MainActor @Sendable (UUID, DesktopSpeechCompletion) -> Void) throws {
            if fails { throw DesktopRuntimeError.message("backend private detail") }
            requests.append(request); callbacks[request.id] = completion
        }
        func stop() { stopCount += 1 }
        func complete(_ id: UUID, outcome: DesktopSpeechCompletion = .finished) { callbacks[id]?(id, outcome) }
    }
    private func settings(_ defaults: UserDefaults? = nil) -> DesktopSettings {
        DesktopSettings(defaults: defaults ?? UserDefaults(suiteName: "amber.speech.tests.\(UUID())")!, credentials: DesktopMemoryCredentials())
    }

    func testSavedVoiceAndRateAreConsumedByActualPlayerAfterReopen() {
        let defaults = UserDefaults(suiteName: "amber.speech.tests.\(UUID())")!
        let settings = settings(defaults)
        settings.speechVoiceIdentifier = "voice"; settings.speechRate = 0.35
        let reopened = self.settings(defaults), backend = Backend()
        let player = DesktopSpeechPlayer(settings: reopened, backend: backend), owner = UUID()
        XCTAssertTrue(player.speak(text: "  公开正文  ", messageID: owner))
        XCTAssertEqual(backend.requests.first?.text, "公开正文")
        XCTAssertEqual(backend.requests.first?.voiceIdentifier, "voice")
        XCTAssertEqual(backend.requests.first?.rate, 0.35)
        XCTAssertEqual(player.currentMessageID, owner)
        XCTAssertTrue(player.isSpeaking)
    }

    func testLateCompletionForSameMessageCannotStopReplacementUtterance() throws {
        let backend = Backend(), player = DesktopSpeechPlayer(settings: settings(), backend: backend), owner = UUID()
        player.speak(text: "first", messageID: owner)
        let first = try XCTUnwrap(backend.requests.last?.id)
        player.speak(text: "second", messageID: owner)
        let second = try XCTUnwrap(backend.requests.last?.id)
        backend.complete(first, outcome: .cancelled)
        XCTAssertTrue(player.isSpeaking)
        XCTAssertEqual(player.currentMessageID, owner)
        backend.complete(second)
        XCTAssertFalse(player.isSpeaking)
        XCTAssertNil(player.currentMessageID)
    }

    func testStopClearsOwnerAndLateCallbackDoesNotReviveIt() throws {
        let backend = Backend(), player = DesktopSpeechPlayer(settings: settings(), backend: backend)
        player.speak(text: "body", messageID: UUID())
        let id = try XCTUnwrap(backend.requests.last?.id)
        let before = backend.stopCount
        player.stop()
        XCTAssertEqual(backend.stopCount, before + 1)
        backend.complete(id)
        XCTAssertFalse(player.isSpeaking)
        XCTAssertNil(player.currentMessageID)
    }

    func testDefaultVoiceAndRateBoundsHaveRealConsumer() {
        let settings = settings(), backend = Backend(), player = DesktopSpeechPlayer(settings: settings, backend: backend)
        settings.speechRate = .infinity
        player.speak(text: "default", messageID: UUID())
        XCTAssertNil(backend.requests.last?.voiceIdentifier)
        XCTAssertEqual(backend.requests.last?.rate, 0.5)
        settings.speechRate = 10
        player.speak(text: "bounded", messageID: UUID())
        XCTAssertEqual(backend.requests.last?.rate, 0.6)
    }

    func testUnavailableBackendFailsVisiblyWithoutLeakingDetails() {
        let backend = Backend(); backend.fails = true
        let player = DesktopSpeechPlayer(settings: settings(), backend: backend)
        XCTAssertFalse(player.speak(text: "body", messageID: UUID()))
        XCTAssertFalse(player.isSpeaking)
        XCTAssertNotNil(player.error)
        XCTAssertFalse(player.error?.contains("private") ?? true)
    }

    func testVoiceDiscoveryAndEmptyTextDoNotStartAudio() async {
        let backend = Backend(), player = DesktopSpeechPlayer(settings: settings(), backend: backend)
        await player.loadVoices()
        XCTAssertEqual(player.availableVoices.map(\.id), ["voice"])
        XCTAssertFalse(player.speak(text: " \n", messageID: UUID()))
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertFalse(player.isLoadingVoices)
    }
}
