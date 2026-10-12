import SwiftUI
import XCTest
import Vision
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUIStreamingPreviewRenderingTests: XCTestCase {
    @MainActor
    private final class Model: ObservableObject {
        @Published var markdown: String
        @Published var isStreaming = true
        @Published var isComplete = false
        @Published var live = true
        @Published var frozen: String?
        @Published var source = "preview-source"
        @Published var namespace = "preview-source:text:0"
        let settings: GenerativeUiSetting
        let owner: IOSIntelligentUIHost

        init(markdown: String, settings: GenerativeUiSetting, owner: IOSIntelligentUIHost) {
            self.markdown = markdown
            self.settings = settings
            self.owner = owner
        }
    }

    private struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            ChatAssistantMarkdownView(
                markdown: model.markdown, renderCacheNamespace: model.namespace,
                generativeUiSetting: model.settings, isStreaming: model.isStreaming,
                hasEverStreamed: true, liveRenderingEnabled: model.live,
                frozenMarkdownSnapshot: model.frozen, isSourceMessageComplete: model.isComplete,
                sourceMessageID: model.source
            )
            .environment(\.intelligentUIHost, model.owner)
            .environment(\.intelligentUIConversationID, "preview-conversation")
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private final class Fixture {
        let model: Model
        let window: UIWindow
        let host: UIHostingController<Harness>
        private let previous: UIWindow?

        init(model: Model, scene: UIWindowScene) {
            self.model = model
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            host = UIHostingController(rootView: Harness(model: model))
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 1_600)
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        func image() -> UIImage {
            host.view.layoutIfNeeded()
            let fit = host.sizeThatFits(in: CGSize(width: 320, height: 5_000))
            XCTAssertLessThanOrEqual(fit.width, 321)
            window.frame.size.height = fit.height + window.safeAreaInsets.top + window.safeAreaInsets.bottom
            host.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }

        func text() -> String {
            guard let cgImage = image().cgImage else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) }
            catch { XCTFail("Unable to inspect preview rendering: \(error)") }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").uppercased()
        }
    }

    func testReceivedContentBuildsVisiblyWithoutRegisteringDraftUntilTerminal() async throws {
        let first = #"{"id":"first","kind":"body","text":"FIRST RECEIVED COMPONENT"}"#
        let second = #"{"id":"second","kind":"body","text":"SECOND RECEIVED COMPONENT"}"#
        let prefix = header(goal: "RECEIVED GOAL") + #", "components":["#
        let fixture = try makeFixture(markdown: prefix + first + #", {"id":"second","kind":"body","text":"HIDDEN"#)
        defer { fixture.close() }
        try await visible("FIRST RECEIVED COMPONENT", absent: "HIDDEN", in: fixture)
        saveEvidence(fixture.image(), name: "stream-preview-first-object")

        fixture.model.markdown = prefix + first + "," + second
        try await visible("SECOND RECEIVED COMPONENT", in: fixture)
        XCTAssertTrue(fixture.text().contains("FIRST RECEIVED COMPONENT"))
        saveEvidence(fixture.image(), name: "stream-preview-second-object")

        let root = prefix + first + "," + second + #"], "submit":{"label":"CONTINUE READY","intent":"continue"}}"#
        fixture.model.markdown = root
        try await visible("SECOND RECEIVED COMPONENT", absent: "CONTINUE READY", in: fixture)
        let definition = try IOSIntelligentUIProtocol.decode(String(root.dropFirst("```task-ui\n".count)))
        let source = IOSIntelligentUISource(conversationID: "preview-conversation", messageID: fixture.model.source,
                                            textPartIndex: 0, cardID: definition.cardID)
        XCTAssertEqual(fixture.model.owner.stateStore.draft(for: source, definition: definition).definitionFingerprint, "")

        fixture.model.markdown = root + "\n```\n"
        try await visible("SECOND RECEIVED COMPONENT", absent: "CONTINUE READY", in: fixture)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.model.owner.stateStore.draft(for: source, definition: definition).definitionFingerprint, "")
        XCTAssertNil(fixture.model.owner.stateStore.activeSource(for: source.conversationID))
        XCTAssertTrue(fixture.model.owner.pending.isEmpty)

        fixture.model.isComplete = true
        fixture.model.isStreaming = false
        try await visible("CONTINUE READY", in: fixture)
        XCTAssertFalse(fixture.model.owner.stateStore.draft(for: source, definition: definition).definitionFingerprint.isEmpty)
        saveEvidence(fixture.image(), name: "stream-preview-authoritative-terminal")
    }

    func testFrozenSourceReplacementAndFinalPlainTextClearPreviousPreview() async throws {
        let fixture = try makeFixture(markdown: header(goal: "LIVE ORIGINAL"))
        defer { fixture.close() }
        try await visible("LIVE ORIGINAL", in: fixture)

        fixture.model.frozen = header(goal: "FROZEN RECEIVED")
        fixture.model.live = false
        try await visible("FROZEN RECEIVED", absent: "LIVE ORIGINAL", in: fixture)
        fixture.model.markdown = header(goal: "HIDDEN LIVE UPDATE")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fixture.text().contains("FROZEN RECEIVED"))
        XCTAssertFalse(fixture.text().contains("HIDDEN LIVE UPDATE"))

        fixture.model.source = "different-preview-source"
        fixture.model.namespace = "different-preview-source:text:0"
        fixture.model.frozen = header(goal: "REPLACED FROZEN")
        try await visible("REPLACED FROZEN", absent: "FROZEN RECEIVED", in: fixture)

        fixture.model.frozen = nil
        fixture.model.live = true
        fixture.model.markdown = "FINAL PLAIN TEXT"
        fixture.model.isStreaming = false
        try await visible("FINAL PLAIN TEXT", absent: "REPLACED FROZEN", in: fixture)
        XCTAssertNil(fixture.model.owner.stateStore.activeSource(for: "preview-conversation"))
    }

    private func makeFixture(markdown: String) throws -> Fixture {
        let suite = "TaskUIStreamingPreview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults).snapshot.agentRuntime.generativeUi
        let owner = IOSIntelligentUIHost(stateStore: IOSIntelligentUIStateStore(), action: { _ in
            XCTFail("A streaming preview must never submit")
            return .saved
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return Fixture(model: Model(markdown: markdown, settings: settings, owner: owner), scene: scene)
    }

    private func visible(_ expected: String, absent: String? = nil, in fixture: Fixture) async throws {
        for _ in 0..<80 {
            let text = fixture.text()
            if text.contains(expected), absent.map({ !text.contains($0) }) ?? true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected visible \(expected), absent \(absent ?? "none"); rendered \(fixture.text())")
        throw NSError(domain: "IOSIntelligentUIStreamingPreviewRenderingTests", code: 1)
    }

    private func header(goal: String) -> String {
        "```task-ui\n" + #"{"version":1,"card_id":"stream-render","kind":"explore","goal":""# + goal + "\""
    }

    private func saveEvidence(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
