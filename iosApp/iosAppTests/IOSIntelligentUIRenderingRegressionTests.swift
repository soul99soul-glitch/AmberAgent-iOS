import SwiftUI
import XCTest
import Vision
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSIntelligentUIRenderingRegressionTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var markdown: String
        @Published var liveRenderingEnabled = true
        @Published var frozenMarkdownSnapshot: String?
        let settings: GenerativeUiSetting

        init(markdown: String, settings: GenerativeUiSetting) {
            self.markdown = markdown
            self.settings = settings
        }
    }

    private struct Harness: View {
        @ObservedObject var model: Model

        var body: some View {
            ChatAssistantMarkdownView(
                markdown: model.markdown,
                renderCacheNamespace: "task-ui-rendering-regression:text:0",
                generativeUiSetting: model.settings,
                isStreaming: true,
                hasEverStreamed: true,
                liveRenderingEnabled: model.liveRenderingEnabled,
                frozenMarkdownSnapshot: model.frozenMarkdownSnapshot,
                isSourceMessageComplete: false
            )
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private final class Fixture {
        let model: Model
        let window: UIWindow
        let host: UIHostingController<Harness>
        private let previousKeyWindow: UIWindow?
        private let evidenceID = UUID().uuidString
        private var previousEvidenceText: String?

        init(model: Model, scene: UIWindowScene) {
            self.model = model
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            host = UIHostingController(rootView: Harness(model: model))
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_600)
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        func entries() -> [RenderedEntry] {
            host.view.layoutIfNeeded()
            // Match the snapshot to the actual content, as in the visual fixture.
            // A fixed 1600pt root vertically centers this intrinsic-height view and
            // makes Vision downscale an unnecessarily tall mostly empty image.
            let fit = host.sizeThatFits(in: CGSize(width: 393, height: 5_000))
            window.frame.size.height = fit.height + window.safeAreaInsets.top + window.safeAreaInsets.bottom
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let entries = IOSIntelligentUIRenderingRegressionTests.renderedEntries(in: image)
            let text = entries.map(\.text).joined(separator: "\n")
            if text != previousEvidenceText {
                previousEvidenceText = text
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("task-ui-rendering-\(evidenceID).png")
                do { try image.pngData()?.write(to: file) }
                catch { XCTFail("Unable to save rendering evidence: \(error)") }
                print("TASK_UI_RENDERING_EVIDENCE \(file.path) size=\(image.size)\n\(text)")
            }
            return entries
        }
    }

    private struct RenderedEntry {
        let text: String
        let frame: CGRect
    }

    func testFreezingWithoutExternalSnapshotKeepsLatestCard() async throws {
        let fixture = try makeFixture(markdown: taskBlock(id: "initial"))
        defer { fixture.tearDown() }
        try await waitForCard("initial", in: fixture)

        fixture.model.markdown = try taskBlock(id: "latest")
        try await waitForCard("latest", absent: "initial", in: fixture)
        fixture.model.liveRenderingEnabled = false
        // The live view's initial local snapshot still contains "initial". Freezing
        // must first capture the latest displayed text, then derive task segments.
        try await waitForCard("latest", absent: "initial", in: fixture)
        try await Task.sleep(for: .milliseconds(100))
        assertCard("latest", absent: "initial", in: fixture)
    }

    func testReplacingExternalFrozenSnapshotReplacesVisibleCard() async throws {
        let model = try makeModel(markdown: taskBlock(id: "live"))
        model.liveRenderingEnabled = false
        model.frozenMarkdownSnapshot = try taskBlock(id: "frozen-a")
        let fixture = try makeFixture(model: model)
        defer { fixture.tearDown() }
        try await waitForCard("frozen-a", absent: "live", in: fixture)

        // Neither markdown nor liveRenderingEnabled changes: the external snapshot
        // is itself the input that must invalidate the visible task definition.
        model.frozenMarkdownSnapshot = try taskBlock(id: "frozen-b")
        try await waitForCard("frozen-b", absent: "frozen-a", in: fixture)
        XCTAssertFalse(fixture.entries().contains { $0.text == cardTitle("live") })
    }

    func testTablesOnBothSidesOfTaskCardSurviveColdReentry() async throws {
        ChatStableStreamingMarkdownCacheTestSupport.reset()
        defer { ChatStableStreamingMarkdownCacheTestSupport.reset() }
        let before = "| BEFORE_HEADER | Value |\n| --- | --- |\n| BEFORE_CELL | 11 |\n\n"
        let after = "\n| AFTER_HEADER | Value |\n| --- | --- |\n| AFTER_CELL | 22 |\n"
        let markdown = try before + taskBlock(id: "between-tables") + after
        let warm = try makeFixture(markdown: markdown)
        do {
            try await waitForCard("between-tables", in: warm)
            try await waitForTables(in: warm)
            assertTableOrder(in: warm)
            // Allow the real Markdown controllers to populate their identity caches.
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            warm.tearDown()
            throw error
        }
        warm.tearDown()

        // New hosting/view/controller instances share only the production cache.
        // Assert actual rendered cell text and geometry, rather than reproducing namespace
        // construction in the test or inspecting source strings.
        let cold = try makeFixture(markdown: markdown)
        defer { cold.tearDown() }
        try await waitForCard("between-tables", in: cold)
        try await waitForTables(in: cold, rejectCrossedCache: true)
        assertTableOrder(in: cold)
    }

    private func makeModel(markdown: String) throws -> Model {
        let suite = "TaskUIRenderingRegression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        return Model(markdown: markdown, settings: settings.snapshot.agentRuntime.generativeUi)
    }

    private func makeFixture(markdown: String) throws -> Fixture {
        try makeFixture(model: makeModel(markdown: markdown))
    }

    private func makeFixture(model: Model) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return Fixture(model: model, scene: scene)
    }

    private func taskBlock(id: String) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IOSIntelligentUIProtocol.exampleJSON.utf8)) as? [String: Any])
        object["card_id"] = id
        object["goal"] = cardTitle(id)
        var options = try XCTUnwrap(object["options"] as? [[String: Any]])
        options[0]["title"] = optionTitle(id)
        object["options"] = options
        let data = try JSONSerialization.data(withJSONObject: object)
        return "```task-ui\n\(String(decoding: data, as: UTF8.self))\n```\n"
    }

    private func waitForCard(_ id: String, absent: String? = nil, in fixture: Fixture) async throws {
        try await eventually {
            let entries = fixture.entries()
            return entries.contains { $0.text == cardTitle(id) }
                && entries.contains { $0.text == optionTitle(id) }
                && (absent == nil || !entries.contains { $0.text == cardTitle(absent!) })
        }
    }

    private func assertCard(_ id: String, absent: String, in fixture: Fixture,
                            file: StaticString = #filePath, line: UInt = #line) {
        let entries = fixture.entries()
        XCTAssertTrue(entries.contains { $0.text == cardTitle(id) }, file: file, line: line)
        XCTAssertTrue(entries.contains { $0.text == optionTitle(id) }, file: file, line: line)
        XCTAssertFalse(entries.contains { $0.text == cardTitle(absent) }, file: file, line: line)
    }

    private func waitForTables(in fixture: Fixture, rejectCrossedCache: Bool = false) async throws {
        try await eventually {
            let entries = fixture.entries()
            if rejectCrossedCache,
               let cardTop = entries.filter({ $0.text == cardTitle("between-tables") && !$0.frame.isEmpty })
                .map(\.frame.minY).min() {
                XCTAssertFalse(entries.contains { $0.text.hasPrefix("AFTER CELL") && $0.frame.midY < cardTop },
                               "Cold reentry must never show the second table above the task card")
            }
            return entries.contains { $0.text.hasPrefix("BEFORE CELL") }
                && entries.contains { $0.text.hasPrefix("AFTER CELL") }
        }
    }

    private func assertTableOrder(in fixture: Fixture,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let entries = fixture.entries()
        let before = entries.filter { $0.text.hasPrefix("BEFORE CELL") && !$0.frame.isEmpty }
        let after = entries.filter { $0.text.hasPrefix("AFTER CELL") && !$0.frame.isEmpty }
        XCTAssertEqual(before.count, 1, "The first table must retain its own cached content", file: file, line: line)
        XCTAssertEqual(after.count, 1, "The second table must retain its own cached content", file: file, line: line)
        if let before = before.first, let after = after.first {
            XCTAssertLessThan(before.frame.midY, after.frame.midY, file: file, line: line)
        }
    }

    private func eventually(_ condition: () -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected visible card or table content did not appear", file: file, line: line)
        throw NSError(domain: "IOSIntelligentUIRenderingRegressionTests", code: 1)
    }

    private func cardTitle(_ id: String) -> String { "TASK " + id.replacingOccurrences(of: "-", with: " ").uppercased() }
    private func optionTitle(_ id: String) -> String { "NATIVE " + id.replacingOccurrences(of: "-", with: " ").uppercased() }

    // SwiftUI virtual AX nodes are not reliably exposed by this hosting test runner
    // even when the card is visible. Read rasterized text and table-cell geometry.
    private static func renderedEntries(in image: UIImage) -> [RenderedEntry] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) }
        catch { XCTFail("Unable to inspect rendered text: \(error)"); return [] }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let normalized = text.replacingOccurrences(of: "_", with: " ").uppercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let box = observation.boundingBox
            return RenderedEntry(text: normalized,
                                 frame: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }
}
