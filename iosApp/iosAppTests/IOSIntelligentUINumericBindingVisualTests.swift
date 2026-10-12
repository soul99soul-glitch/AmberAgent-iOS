import SwiftUI
import UIKit
import Vision
import XCTest
@testable import iosApp

@MainActor
final class IOSIntelligentUINumericBindingVisualTests: XCTestCase {
    @MainActor
    private final class Model: ObservableObject {
        @Published var values: [String: String] = [:]
        @Published var selection: String?
        var submissions = 0
    }

    private struct Harness: View {
        let definition: IOSIntelligentUICardDefinition
        @ObservedObject var model: Model
        let largeText: Bool
        let dark: Bool

        var body: some View {
            IOSIntelligentUICard(definition: definition, selectedOptionID: $model.selection,
                values: $model.values, isSubmitEnabled: true, onSubmit: { model.submissions += 1 })
                .padding(12)
                .dynamicTypeSize(largeText ? .accessibility3 : .large)
                .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    @MainActor
    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let controller: UIHostingController<Harness>
        private let previousKeyWindow: UIWindow?

        init(definition: IOSIntelligentUICardDefinition, largeText: Bool, dark: Bool, width: CGFloat = 393) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            controller = UIHostingController(rootView: Harness(definition: definition, model: model, largeText: largeText, dark: dark))
            window.rootViewController = controller
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1_600)
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        func snapshot(name: String) throws -> [Entry] {
            let fitting = controller.sizeThatFits(in: CGSize(width: window.frame.width, height: 8_000))
            window.frame.size.height = fitting.height + window.safeAreaInsets.top + window.safeAreaInsets.bottom
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-ui-numeric-\(name)-\(UUID().uuidString).png")
            try data.write(to: url)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "task-ui-numeric-\(name)"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: name) { $0.add(attachment) }
            let entries = try IOSIntelligentUINumericBindingVisualTests.entries(in: image)
            print("TASK_UI_NUMERIC_EVIDENCE \(url.path) size=\(image.size)\n\(entries.map(\.text).joined(separator: "\n"))")
            for entry in entries {
                XCTAssertGreaterThanOrEqual(entry.frame.minX, -1, entry.text)
                XCTAssertLessThanOrEqual(entry.frame.maxX, image.size.width + 1, entry.text)
                XCTAssertGreaterThanOrEqual(entry.frame.minY, -1, entry.text)
                XCTAssertLessThanOrEqual(entry.frame.maxY, image.size.height + 1, entry.text)
            }
            return entries
        }
    }

    private struct Entry {
        let text: String
        let frame: CGRect
    }

    func testLiveNumericOutputsRenderUpdatedValuesAndErrorsWithoutSubmittingPreview() async throws {
        let definition = try visualDefinition()
        let fixture = try Fixture(definition: definition, largeText: false, dark: false)
        defer { fixture.tearDown() }
        try await Task.sleep(for: .milliseconds(250))
        let initial = try fixture.snapshot(name: "initial-preview")
        XCTAssertTrue(initial.contains { $0.text.contains("317") })
        XCTAssertTrue(initial.contains { $0.text.contains("预览") })
        XCTAssertEqual(fixture.model.values, [:])
        XCTAssertEqual(fixture.model.submissions, 0)

        // Drive the same binding owned by the native controls; capture real rendered output.
        fixture.model.values = ["chapters": "3", "budget": "689"]
        try await Task.sleep(for: .milliseconds(250))
        let changed = try fixture.snapshot(name: "changed-to-689-three-steps")
        XCTAssertTrue(changed.contains { $0.text.contains("689") })
        XCTAssertFalse(changed.contains { $0.text.contains("317") })
        XCTAssertFalse(changed.contains { $0.text.contains("预览") })
        XCTAssertEqual(fixture.model.submissions, 0)

        fixture.model.values = ["chapters": "NaN", "budget": "bad"]
        try await Task.sleep(for: .milliseconds(250))
        let invalid = try fixture.snapshot(name: "invalid-number")
        XCTAssertTrue(invalid.contains { $0.text.contains("不合法") })
        XCTAssertFalse(invalid.contains { $0.text.contains("689") })
        XCTAssertEqual(fixture.model.values, ["chapters": "NaN", "budget": "bad"])
        XCTAssertEqual(fixture.model.submissions, 0)
    }

    func testLinkedOutputsRemainWithinCardAtAccessibilityTextSizeInDarkMode() async throws {
        let fixture = try Fixture(definition: visualDefinition(), largeText: true, dark: true, width: 320)
        defer { fixture.tearDown() }
        fixture.model.values = ["chapters": "3", "budget": "689"]
        try await Task.sleep(for: .milliseconds(250))
        let entries = try fixture.snapshot(name: "dark-accessibility-320pt-689")
        XCTAssertTrue(entries.contains { $0.text.contains("689") })
        XCTAssertTrue(entries.contains { $0.text.contains("章节") })
        XCTAssertTrue(entries.contains { $0.text.contains("上限") }, "The final line-chart reference label must remain visible at 320pt accessibility size.")
        XCTAssertTrue(entries.contains { $0.text.contains("复盘") }, "The final step label must remain visible when the line-chart labels wrap.")
        XCTAssertEqual(fixture.model.submissions, 0)
    }

    private func visualDefinition() throws -> IOSIntelligentUICardDefinition {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IOSIntelligentUIProtocol.numericExploreExampleJSON.utf8)) as? [String: Any])
        var fields = try XCTUnwrap(object["fields"] as? [[String: Any]])
        fields.append(["id": "budget", "label": "预算", "required": true, "type": "number"])
        object["fields"] = fields
        var components = try XCTUnwrap(object["components"] as? [[String: Any]])
        components.insert(["id": "budget-input", "kind": "slider", "title": "预算", "field_id": "budget", "min": 0, "max": 999, "value": 317], at: 1)
        components.insert(["id": "budget-metric", "kind": "metric", "title": "当前预算", "value_field_id": "budget"], at: 2)
        components.append(["id": "budget-line", "kind": "lineChart", "title": "预算参照", "rows": [
            ["label": "下限", "value": 100], ["label": "当前", "value_field_id": "budget"], ["label": "上限", "value": 900]
        ]])
        object["components"] = components
        return try IOSIntelligentUIProtocol.decode(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private static func entries(in image: UIImage) throws -> [Entry] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Entry(text: candidate.string, frame: CGRect(x: box.minX * image.size.width,
                y: (1 - box.maxY) * image.size.height, width: box.width * image.size.width, height: box.height * image.size.height))
        }
    }
}
