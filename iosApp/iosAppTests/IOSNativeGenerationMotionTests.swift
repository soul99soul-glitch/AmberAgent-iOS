import SwiftUI
import XCTest
import Vision
@testable import iosApp

@MainActor
final class IOSNativeGenerationMotionTests: XCTestCase {
    private struct Harness: View {
        let key: String?
        var body: some View {
            Text("RECEIVED RESULT")
                .font(.title2).padding(18)
                .frame(width: 280, height: 100)
                .background(Color.white)
                .foregroundStyle(.black)
                .nativeGenerationReveal(key: key)
                .environment(\.scenePhase, .active)
        }
    }

    func testRevealPreservesLayoutAndRemountDoesNotReplay() async throws {
        let key = UUID().uuidString
        let fixture = try show(Harness(key: key))
        defer { fixture.close() }
        let before = fixture.host.sizeThatFits(in: CGSize(width: 320, height: 400))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(ChatLiveEntranceRegistry.hasRevealed("native-generation:\(key)"))
        try save(fixture.image(), name: "native-ui-wireframe")
        try await Task.sleep(for: .milliseconds(500))
        let after = fixture.host.sizeThatFits(in: CGSize(width: 320, height: 400))
        XCTAssertEqual(before.width, after.width, accuracy: 0.5)
        XCTAssertEqual(before.height, after.height, accuracy: 0.5)
        XCTAssertTrue(try recognizedText(fixture.image()).contains("RECEIVED RESULT"))
        try save(fixture.image(), name: "native-ui-revealed")

        // A fresh SwiftUI subtree with the same key must be visible on its first frame.
        let replay = try show(Harness(key: key))
        defer { replay.close() }
        XCTAssertTrue(try recognizedText(replay.image()).contains("RECEIVED RESULT"))
    }

    func testHistoryIsImmediatelyVisible() throws {
        let fixture = try show(Harness(key: nil))
        defer { fixture.close() }
        XCTAssertTrue(try recognizedText(fixture.image()).contains("RECEIVED RESULT"))
    }

    func testSystemReducedMotionShowsContentWithoutReveal() throws {
        try XCTSkipUnless(UIAccessibility.isReduceMotionEnabled, "Run with the simulator's Reduce Motion setting enabled")
        let key = UUID().uuidString
        let fixture = try show(Harness(key: key))
        defer { fixture.close() }
        XCTAssertTrue(try recognizedText(fixture.image()).contains("RECEIVED RESULT"))
        XCTAssertFalse(ChatLiveEntranceRegistry.hasRevealed("native-generation:\(key)"))
    }

    private final class Fixture {
        let window: UIWindow
        let host: UIHostingController<Harness>
        let previous: UIWindow?
        init(window: UIWindow, host: UIHostingController<Harness>, previous: UIWindow?) {
            self.window = window; self.host = host; self.previous = previous
        }
        func close() { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func image() -> UIImage {
            host.view.layoutIfNeeded()
            return UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }
    }

    private func show(_ view: Harness) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return Fixture(window: window, host: host, previous: previous)
    }

    private func recognizedText(_ image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
    }

    private func save(_ image: UIImage, name: String) throws {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("NATIVE_UI_MOTION_EVIDENCE \(url.path)")
    }
}
