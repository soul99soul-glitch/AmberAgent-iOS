import SwiftUI
import XCTest
@testable import iosApp

final class IOSIntelligentUIComponentTests: XCTestCase {
    func testCatalogHasEightyDistinctSemanticComponents() {
        let kinds = IOSIntelligentUIComponent.Kind.allCases
        XCTAssertEqual(kinds.count, 80)
        XCTAssertEqual(Set(kinds.map(\.rawValue)).count, 80)
        let families = Dictionary(grouping: kinds, by: \.family)
        XCTAssertEqual(families.mapValues(\.count), ["layout": 10, "text": 12, "status": 10, "input": 14, "data": 10, "media": 8, "task": 8, "action": 8])
        XCTAssertTrue(kinds.filter(\.requiresField).allSatisfy { $0.valueSemantics != nil })
        XCTAssertEqual(Set(kinds.filter(\.isPresentationField)), [.disclosure, .tabs, .accordion])
    }

    func testUnknownComponentsAndArbitraryActionsFailDecoding() {
        for json in [#"{"id":"x","kind":"javascript"}"#, #"{"id":"x","kind":"button","action":"run_tool"}"#,
                     #"{"id":"x","kind":"title","style":{"tone":"rainbow"}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(IOSIntelligentUIComponent.self, from: Data(json.utf8)))
        }
    }

    func testEveryCatalogSamplePassesRealBindingValidation() throws {
        for kind in IOSIntelligentUIComponent.Kind.allCases {
            let node = Self.sample(kind)
            try IOSIntelligentUIComponentCatalog.validate([node], allowedFieldIDs: ["value", "open"])
        }
    }

    func testDuplicateIDsAndUndeclaredBindingsAreRejected() {
        let label = IOSIntelligentUIComponent(id: "same", kind: .body, text: "label")
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate([label, label], allowedFieldIDs: []))
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate([.init(id: "input", kind: .toggle)], allowedFieldIDs: []))
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate([.init(id: "input", kind: .toggle, fieldID: "other")], allowedFieldIDs: ["value"]))
    }

    func testMobileContentBudgetRejectsExcessDepthAndNodes() throws {
        var node = IOSIntelligentUIComponent(id: "leaf", kind: .body, text: "leaf")
        for depth in 1..<8 { node = .init(id: "level-\(depth)", kind: .column, children: [node]) }
        try IOSIntelligentUIComponentCatalog.validate([node], allowedFieldIDs: [])
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate([.init(id: "too-deep", kind: .column, children: [node])], allowedFieldIDs: []))
        let nodes = (0..<160).map { IOSIntelligentUIComponent(id: "node-\($0)", kind: .body, text: "text") }
        try IOSIntelligentUIComponentCatalog.validate(nodes, allowedFieldIDs: [])
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate(nodes + [.init(id: "overflow", kind: .body)], allowedFieldIDs: []))
    }

    func testNumericAndChartPayloadsDoNotAcceptUnrenderableData() {
        for node in [IOSIntelligentUIComponent(id: "range", kind: .slider, fieldID: "value", min: 5, max: 2),
                     .init(id: "range", kind: .slider, fieldID: "value", step: 0),
                     .init(id: "progress", kind: .progress, min: -5, max: -1),
                     .init(id: "rating", kind: .rating, fieldID: "value", max: 1e30),
                     .init(id: "chart", kind: .lineChart, rows: [.init(label: "missing")]),
                     .init(id: "chart", kind: .barChart, rows: [.init(label: "infinity", value: .infinity)])] {
            XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate([node], allowedFieldIDs: ["value"]))
        }
    }

    func testSelectionSerializationIsStableAndSummaryUsesLabels() throws {
        var selection = Set<String>()
        selection = IOSIntelligentUIComponentValues.toggling("b", in: selection)
        selection = IOSIntelligentUIComponentValues.toggling("a", in: selection)
        XCTAssertEqual(IOSIntelligentUIComponentValues.encodeSelection(selection), #"["a","b"]"#)
        XCTAssertEqual(IOSIntelligentUIComponentValues.decodeSelection(#"["a","b"]"#), selection)
        selection = IOSIntelligentUIComponentValues.toggling("a", in: selection)
        XCTAssertEqual(selection, ["b"])
        let component = IOSIntelligentUIComponent(id: "choose", kind: .multiChoice, options: [.init(id: "a", label: "保留离线能力"), .init(id: "b", label: "优先性能")], fieldID: "value")
        XCTAssertEqual(IOSIntelligentUIComponentValues.summary(#"["b"]"#, for: component), "优先性能")
        try IOSIntelligentUIComponentCatalog.validateDraftValues(["value": #"["b"]"#], components: [component])
        for invalid in ["b", #"["b","b"]"#, #"["unknown"]"#] {
            XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validateDraftValues(["value": invalid], components: [component]))
        }
    }

    func testCommittedValuesValidateWithoutSilentlyClamping() throws {
        let slider = IOSIntelligentUIComponent(id: "budget", kind: .slider, fieldID: "value", min: 10, max: 20)
        try IOSIntelligentUIComponentCatalog.validateDraftValues(["value": "15"], components: [slider])
        for invalid in ["9", "21", "nan", "Infinity", "abc"] {
            XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validateDraftValues(["value": invalid], components: [slider]))
        }
        let toggle = IOSIntelligentUIComponent(id: "toggle", kind: .toggle, fieldID: "value")
        XCTAssertEqual(IOSIntelligentUIComponentValues.summary("", for: toggle), "")
        try IOSIntelligentUIComponentCatalog.validateDraftValues(["value": "false"], components: [toggle])
        XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validateDraftValues(["value": "yes"], components: [toggle]))
    }

    func testDateAndTimeValuesRoundTripAndRejectInvalidDates() {
        let day = "2026-10-11"
        let time = "09:45"
        XCTAssertEqual(IOSIntelligentUIComponentValues.dateString(IOSIntelligentUIComponentValues.date(from: day, timeOnly: false), timeOnly: false), day)
        XCTAssertEqual(IOSIntelligentUIComponentValues.dateString(IOSIntelligentUIComponentValues.date(from: time, timeOnly: true), timeOnly: true), time)
        XCTAssertTrue(IOSIntelligentUIComponentValues.isValidDateString(day, timeOnly: false))
        XCTAssertFalse(IOSIntelligentUIComponentValues.isValidDateString("2026-02-30", timeOnly: false))
        XCTAssertFalse(IOSIntelligentUIComponentValues.isValidDateString("25:00", timeOnly: true))
    }

    func testMediaReferencesAndButtonsRespectHostBoundary() throws {
        try IOSIntelligentUIComponentCatalog.validate([.init(id: "image", kind: .image, url: "https://example.com/image.png")], allowedFieldIDs: [])
        for node in [IOSIntelligentUIComponent(id: "bad", kind: .image, url: "file:///etc/passwd"),
                     .init(id: "bad", kind: .linkCard, url: "https://user:secret@example.com"),
                     .init(id: "bad", kind: .body, url: "https://example.com"),
                     .init(id: "bad", kind: .button),
                     .init(id: "bad", kind: .body, action: .continue),
                     .init(id: "bad", kind: .submitButton, action: .reset)] {
            XCTAssertThrowsError(try IOSIntelligentUIComponentCatalog.validate([node], allowedFieldIDs: []))
        }
    }

    /// The view is attached before measurement and ignores test-window safe areas,
    /// so a status-bar inset cannot crop the last native control in the PNG.
    @MainActor
    func testCatalogNativeLayoutEvidence() async throws {
        for kind in IOSIntelligentUIComponent.Kind.allCases {
            try await captureEvidence(Self.sample(kind), name: kind.rawValue)
        }
    }

    @MainActor
    func testLongLabelsFitNarrowAccessibilityLayout() async throws {
        for kind in [IOSIntelligentUIComponent.Kind.row, .grid, .singleChoice, .multiChoice, .segmented, .colorChoice, .rating, .tabs, .buttonGroup] {
            var node = Self.sample(kind)
            node.title = "这是需要完整阅读的较长中文标题，不能覆盖输入或相邻组件"
            if node.options != nil { node.options = [.init(id: "a", label: "优先保留已有状态和输入草稿的完整性", detail: "这里包含较长的补充说明，用来检查窄屏和辅助功能字号时的布局。"), .init(id: "b", label: "先完成端到端验证，再检查体验")] }
            if node.children != nil {
                node.children = node.children?.map { child in
                    var child = child
                    child.title = "较长的操作或分页标题，需要完整显示"
                    if child.kind == .body { child.text = "用户阅读较长的内容时，组件需要在窄屏和辅助功能字号下完整换行。" }
                    return child
                }
            }
            try await captureEvidence(node, name: "\(kind.rawValue)-accessibility", type: .accessibility3)
        }
    }

    @MainActor
    func testFilledStylesKeepSymbolsAndLabelsVisibleInLightAndDarkMode() async throws {
        for kind in [IOSIntelligentUIComponent.Kind.icon, .tag, .rating] {
            var node = Self.sample(kind)
            node.style = .init(tone: .accent, emphasis: .filled, padding: .medium)
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                try await captureEvidence(node, name: "\(kind.rawValue)-filled-\(appearance == .dark ? "dark" : "light")", appearance: appearance)
            }
        }
    }

    // Component AX labels, traits and actions are checked by the dedicated
    // IOSIntelligentUIComponentAXAcceptanceTests target; unit hosting can omit SwiftUI AX.

    private struct AccessibleEntry {
        let label: String?
        let traits: UIAccessibilityTraits
    }

    @MainActor @discardableResult
    private func captureEvidence(_ component: IOSIntelligentUIComponent, name: String,
                                 type: DynamicTypeSize = .large,
                                 appearance: UIUserInterfaceStyle = .light,
                                 canSubmit: Bool = true,
                                 fieldLabels: [String: String] = [:],
                                 fieldComponents: [String: IOSIntelligentUIComponent] = [:],
                                 requiredFieldIDs: Set<String> = [],
                                 initialValues: [String: String] = [:]) async throws -> [AccessibleEntry] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let root = IOSIntelligentUIComponentEvidenceHarness(component: component, canSubmit: canSubmit,
            fieldLabels: fieldLabels, fieldComponents: fieldComponents, requiredFieldIDs: requiredFieldIDs, initialValues: initialValues)
            .environment(\.dynamicTypeSize, type).environment(\.locale, Locale(identifier: "zh-Hans"))
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = appearance == .dark ? .black : .white
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.overrideUserInterfaceStyle = appearance
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(40))
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        XCTAssertTrue(size.height.isFinite && size.height > 0 && size.height < 10_000, name)
        XCTAssertLessThanOrEqual(size.width, 320.5, name)
        let canvas = CGSize(width: 320, height: ceil(size.height))
        window.frame = CGRect(origin: .zero, size: canvas)
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "task-ui-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("intelligent-ui-components", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        print("INTELLIGENT_UI_COMPONENT_EVIDENCE \(output.path)")
        var entries: [AccessibleEntry] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if object.accessibilityLabel != nil { entries.append(.init(label: object.accessibilityLabel, traits: object.accessibilityTraits)) }
            if let view = object as? UIView { view.subviews.forEach(visit) }
            let elements = object.accessibilityElements
            elements?.compactMap { $0 as? NSObject }.forEach(visit)
            let count = object.accessibilityElementCount()
            if count > 0 && count != NSNotFound {
                for index in 0..<count { if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) } }
            }
        }
        visit(host.view)
        return entries
    }

    static func sample(_ kind: IOSIntelligentUIComponent.Kind) -> IOSIntelligentUIComponent {
        var node = IOSIntelligentUIComponent(id: "sample-\(kind.rawValue)", kind: kind, title: "\(kind.rawValue) · 任务组件", text: "先完成一条可靠的任务路径，再按实际需要扩展。")
        if kind.requiresField { node.fieldID = kind.isPresentationField ? "open" : "value" }
        if kind.allowsChildren {
            node.children = [.init(id: "child-a", kind: .body, title: "方案 A", text: "保留本地草稿"), .init(id: "child-b", kind: .body, title: "方案 B", text: "准确提交选择")]
        }
        switch kind {
        case .singleChoice, .multiChoice, .segmented, .picker, .colorChoice, .menu, .comparison:
            node.options = [.init(id: "a", label: "本地状态", detail: "操作立即响应", color: "green"), .init(id: "b", label: "明确提交", detail: "再进入模型推理", color: "blue")]
        case .metric: node.value = 42
        case .progress: node.value = 42; node.max = 100
        case .stepProgress: node.value = 2; node.items = ["目标", "选择", "继续"]
        case .slider, .stepper: node.min = 0; node.max = 100; node.step = 5
        case .rating: node.max = 5
        case .bulletList, .numberedList, .diagram, .assumptions, .checklist: node.items = ["明确目标", "保留输入", "提交快照"]
        case .decisionSummary: node.items = ["value"]
        case .barChart, .lineChart, .timeline, .steps, .list: node.rows = [.init(label: "方案 A", value: 3, detail: "采用现有链路"), .init(label: "方案 B", value: 7, detail: "增加维护成本")]
        case .table: node.items = ["方案", "预计成本"]; node.rows = [.init(label: "A", cells: ["原生", "3 天"]), .init(label: "B", cells: ["网页", "7 天"])]
        case .button: node.action = .continue
        case .buttonGroup: node.children = [.init(id: "continue", kind: .submitButton, title: "继续"), .init(id: "reset", kind: .resetButton, title: "重置")]
        case .metricGrid: node.children = [.init(id: "metric-a", kind: .metric, title: "计划", value: 3), .init(id: "metric-b", kind: .metric, title: "完成", value: 1)]
        case .imageGrid: node.children = [.init(id: "image-a", kind: .image, title: "参考图 A"), .init(id: "image-b", kind: .image, title: "参考图 B")]
        case .codeBlock: node.text = "let choice = draft.selectedOption\nsubmit(choice)"
        case .linkCard: node.url = "https://example.com/reference"
        default: break
        }
        return node
    }
}

@MainActor
private struct IOSIntelligentUIComponentEvidenceHarness: View {
    let component: IOSIntelligentUIComponent
    var canSubmit: Bool = true
    var fieldLabels: [String: String] = [:]
    var fieldComponents: [String: IOSIntelligentUIComponent] = [:]
    var requiredFieldIDs: Set<String> = []
    @State private var values: [String: String]

    init(component: IOSIntelligentUIComponent, canSubmit: Bool = true,
         fieldLabels: [String: String] = [:], fieldComponents: [String: IOSIntelligentUIComponent] = [:],
         requiredFieldIDs: Set<String> = [], initialValues: [String: String] = [:]) {
        self.component = component
        self.canSubmit = canSubmit
        self.fieldLabels = fieldLabels
        self.fieldComponents = fieldComponents
        self.requiredFieldIDs = requiredFieldIDs
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        IOSIntelligentUIComponentView(component: component, draftValues: $values, isEnabled: true,
            canSubmit: canSubmit, fieldLabels: fieldLabels, fieldComponents: fieldComponents,
            requiredFieldIDs: requiredFieldIDs, onSubmit: {}, onReset: { values = [:] })
            .padding(14).frame(maxWidth: .infinity, alignment: .topLeading).ignoresSafeArea()
    }
}
