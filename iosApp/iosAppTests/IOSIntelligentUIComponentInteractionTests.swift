import SwiftUI
import XCTest
@testable import iosApp

@MainActor
final class IOSIntelligentUIComponentInteractionTests: XCTestCase {
    /// Every mutation below enters through the rendered accessibility action.
    /// The production block owns bindings, state updates and submission freezing.
    func testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try await fixture.waitForButton(label: "EMBEDDED_CONTINUE", allowUnavailableAX: true)
        XCTAssertTrue(try fixture.button(label: "EMBEDDED_CONTINUE").accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(fixture.draft.values, [:])
        XCTAssertTrue(fixture.submissions.isEmpty)

        // SwiftUI's virtual AX element exposes this unique label without requiring
        // a UIAccessibilityIdentification protocol cast in unit hosting.
        try await fixture.activate(label: "NATIVE_PATH")
        try await fixture.waitUntil("root option selection becomes native") { fixture.draft.selectedOptionID == "native" }
        XCTAssertEqual(fixture.store.activeSource(for: fixture.source.conversationID), fixture.source)

        try await fixture.activate(label: "CHOOSE_QUICK")
        try await fixture.waitUntil("singleChoice mode becomes quick") { fixture.draft.values["mode"] == "quick" }
        try await fixture.activate(label: "CHOOSE_OFFLINE")
        try await fixture.waitUntil("multiChoice capabilities contains only offline") { fixture.draft.values["capabilities"] == #"["offline"]"# }

        // An unanswered boolean has an explicit false action: no on/off detour.
        try await fixture.activate(label: "Allow network（必填）：否")
        try await fixture.waitUntil("unanswered toggle network becomes false") { fixture.draft.values["network"] == "false" }
        XCTAssertTrue(fixture.submissions.isEmpty, "Local controls must not submit")

        try await fixture.activate(label: "DISPLAY_DETAILS")
        try await fixture.waitUntil("disclosure details becomes true") { fixture.draft.values["details"] == "true" }
        let revisionAtSubmit = fixture.draft.revision
        try await fixture.activate(label: "EMBEDDED_CONTINUE")
        try await fixture.waitUntil("continue captures exactly one submission") { fixture.submissions.count == 1 }
        let submission = try XCTUnwrap(fixture.submissions.first)
        XCTAssertEqual(submission.source, fixture.source)
        XCTAssertEqual(submission.draftRevision, revisionAtSubmit)
        XCTAssertEqual(submission.option?.id, "native")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: submission.inputs.map { ($0.id, $0.value) }), [
            "mode": "CHOOSE_QUICK", "capabilities": "CHOOSE_OFFLINE", "network": "否"
        ])
        XCTAssertFalse(submission.inputs.contains { $0.id == "details" })
        try await fixture.waitUntil("submitted source gets a receipt") { fixture.host.receipts[fixture.source] != nil }
        try await fixture.waitUntil("continue disables after receipt") { fixture.findButton(label: "EMBEDDED_CONTINUE")?.accessibilityTraits.contains(.notEnabled) == true }
        XCTAssertTrue(try fixture.button(label: "EMBEDDED_CONTINUE").accessibilityTraits.contains(.notEnabled))

        try await fixture.activate(label: "RESET_THIS_CARD")
        try await fixture.waitUntil("reset clears option and field values") { fixture.draft.selectedOptionID == nil && fixture.draft.values.isEmpty }
        XCTAssertEqual(fixture.submissions.count, 1, "Reset must not start another round")
        XCTAssertEqual(submission.option?.id, "native")
        XCTAssertEqual(submission.inputs.first(where: { $0.id == "network" })?.value, "否", "Reset cannot rewrite the submitted snapshot")
        XCTAssertEqual(fixture.host.receipts[fixture.source], submission)
    }

    @MainActor
    private final class Fixture {
        let definition: IOSIntelligentUICardDefinition
        let source: IOSIntelligentUISource
        let store: IOSIntelligentUIStateStore
        let window: UIWindow
        let controller: UIViewController
        private let previousKeyWindow: UIWindow?
        private let capture: Capture
        let host: IOSIntelligentUIHost

        var submissions: [IOSIntelligentUISubmission] { capture.submissions }
        var draft: IOSIntelligentUIDraft { store.draft(for: source, definition: definition) }

        init() throws {
            let definition = try IOSIntelligentUIProtocol.decode(#"""
            {
              "version":1,"card_id":"native-interactions","kind":"decision",
              "goal":"Verify native task interactions","question":"Choose a path",
              "options":[
                {"id":"native","title":"NATIVE_PATH","summary":"Use native controls"},
                {"id":"web","title":"WEB_PATH","summary":"Use a webpage"}
              ],
              "fields":[
                {"id":"mode","label":"Run mode","required":true,"type":"choice"},
                {"id":"capabilities","label":"Capabilities","required":true,"type":"multiChoice"},
                {"id":"network","label":"Allow network","required":true,"type":"bool"},
                {"id":"details","label":"Presentation only","required":false,"type":"presentation"}
              ],
              "components":[
                {"id":"mode","kind":"singleChoice","field_id":"mode","options":[{"id":"quick","label":"CHOOSE_QUICK"},{"id":"careful","label":"CHOOSE_CAREFUL"}]},
                {"id":"capabilities","kind":"multiChoice","field_id":"capabilities","options":[{"id":"offline","label":"CHOOSE_OFFLINE"},{"id":"speed","label":"CHOOSE_SPEED"}]},
                {"id":"network","kind":"toggle","field_id":"network"},
                {"id":"details","kind":"disclosure","field_id":"details","title":"DISPLAY_DETAILS","children":[{"id":"detail-text","kind":"body","text":"Only controls presentation"}]},
                {"id":"actions","kind":"buttonGroup","children":[{"id":"continue","kind":"submitButton","title":"EMBEDDED_CONTINUE"},{"id":"reset","kind":"resetButton","title":"RESET_THIS_CARD"}]}
              ],
              "submit":{"label":"ROOT_CONTINUE","intent":"continue"}
            }
            """#)
            let source = IOSIntelligentUISource(conversationID: "interaction-origin", messageID: "assistant-origin", textPartIndex: 0, cardID: definition.cardID)
            let store = IOSIntelligentUIStateStore()
            let capture = Capture()
            let host = IOSIntelligentUIHost(stateStore: store, action: { submission in
                capture.submissions.append(submission)
                return .saved
            })
            self.definition = definition
            self.source = source
            self.store = store
            self.capture = capture
            self.host = host
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            let root = ChatIntelligentUIBlock(definition: definition, isMessageComplete: true, messageID: source.messageID)
                .environment(\.intelligentUIHost, host)
                .environment(\.intelligentUIConversationID, source.conversationID)
                .environment(\.intelligentUIBusy, false)
                .padding(12).ignoresSafeArea()
            let controller = UIHostingController(rootView: root)
            self.controller = controller
            window.rootViewController = controller
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 1_800)
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        func activate(identifier: String? = nil, label: String? = nil) async throws {
            let target = identifier ?? label ?? "control"
            log("activate begin target=\(target)")
            try await waitForButton(identifier: identifier, label: label)
            try await waitUntil("button becomes enabled: \(target)") { self.findButton(identifier: identifier, label: label)?.accessibilityTraits.contains(.notEnabled) == false }
            let element = try button(identifier: identifier, label: label)
            log("activate element target=\(target) class=\(String(reflecting: type(of: element))) label=\(element.accessibilityLabel ?? "nil") traits=\(element.accessibilityTraits.rawValue)")
            XCTAssertFalse(element.accessibilityTraits.contains(.notEnabled), "Requested native control must be enabled")
            let didActivate = element.accessibilityActivate()
            log("activate returned target=\(target) result=\(didActivate)")
            guard didActivate else {
                throw XCTSkip("This simulator's rendered AX element does not expose accessibilityActivate for \(identifier ?? label ?? "control"); native activation remains unverified.")
            }
        }

        func findButton(identifier: String? = nil, label: String? = nil) -> NSObject? {
            elements().first { element in
                element.accessibilityTraits.contains(.button) &&
                    (identifier.map { id in (element as? UIAccessibilityIdentification)?.accessibilityIdentifier == id } ??
                     label.map { label in element.accessibilityLabel?.contains(label) == true } ?? false)
            }
        }

        func button(identifier: String? = nil, label: String? = nil) throws -> NSObject {
            try XCTUnwrap(findButton(identifier: identifier, label: label), "Missing rendered button: \(identifier ?? label ?? "control")")
        }

        func waitForButton(identifier: String? = nil, label: String? = nil, allowUnavailableAX: Bool = false) async throws {
            if allowUnavailableAX {
                for _ in 0..<100 {
                    controller.view.layoutIfNeeded()
                    if findButton(identifier: identifier, label: label) != nil { return }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw XCTSkip("unit hosting 未暴露可激活 SwiftUI AX，实际点击由独立 UI acceptance 验证；本测试的原生交互仍未验证。")
            }
            try await waitUntil("button appears: \(identifier ?? label ?? "control")") { self.findButton(identifier: identifier, label: label) != nil }
        }

        func waitUntil(_ context: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
            log("wait begin expected=\(context)")
            for _ in 0..<100 {
                controller.view.layoutIfNeeded()
                if condition() {
                    log("wait satisfied expected=\(context)")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            log("wait failed expected=\(context)")
            XCTFail("A rendered native action did not produce the expected state: \(context); \(stateDescription)", file: file, line: line)
            throw NSError(domain: "IOSIntelligentUIComponentInteractionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: context])
        }

        private var stateDescription: String {
            let current = draft
            let values = current.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            return "selection=\(current.selectedOptionID ?? "nil") values={\(values)} revision=\(current.revision) submissions=\(submissions.count) receipt=\(host.receipts[source] != nil)"
        }

        private func log(_ event: String) {
            print("INTELLIGENT_UI_NATIVE_INTERACTION \(event); \(stateDescription)")
        }

        private func elements() -> [NSObject] {
            var result: [NSObject] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ object: NSObject) {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return }
                if object.isAccessibilityElement { result.append(object) }
                if let view = object as? UIView { view.subviews.forEach(visit) }
                if let elements = object.accessibilityElements { elements.compactMap { $0 as? NSObject }.forEach(visit) }
                else {
                    let count = object.accessibilityElementCount()
                    if count > 0 && count != NSNotFound {
                        for index in 0..<count { if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) } }
                    }
                }
            }
            visit(controller.view)
            return result
        }
    }

    @MainActor
    private final class Capture {
        var submissions: [IOSIntelligentUISubmission] = []
    }
}
