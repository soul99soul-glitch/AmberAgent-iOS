#if DEBUG && INTELLIGENT_UI_COMPONENT_ACCEPTANCE
import SwiftUI
import Observation

/// Fixed, opt-in fixtures for system AX checks. Never compiled into normal builds.
struct IOSIntelligentUIAcceptanceFixtureView: View {
    enum Kind: String, CaseIterable {
        case summary, continueGate, untitledInputs, study, numeric

        static var requested: Kind? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-amber-intelligent-ui-component-fixture"),
                  arguments.indices.contains(flag + 1) else { return nil }
            return Kind(rawValue: arguments[flag + 1])
        }
    }

    let kind: Kind
    @State private var values: [String: String] = [:]
    @State private var canSubmit = false
    @State private var inputKind = IOSIntelligentUIComponent.Kind.toggle
    @State private var submitCount = 0
    @State private var resetCount = 0
    @State private var studyOwner = CardOwner()
    @State private var numericOwner = CardOwner(kind: .numeric)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Intelligent UI AX fixture: \(kind.rawValue)")
                    .font(.headline)
                    .accessibilityIdentifier("intelligent-ui-acceptance-fixture")
                switch kind {
                case .summary: summaryFixture
                case .continueGate: continueFixture
                case .untitledInputs: inputFixture
                case .study: studyFixture
                case .numeric: numericFixture
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("intelligent-ui-fixture-scroll")
        .background(AmberTheme.background)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
    }

    private var summaryFixture: some View {
        IOSIntelligentUIComponentView(
            component: .init(id: "summary", kind: .decisionSummary, items: ["capabilities"]),
            draftValues: .constant(["capabilities": #"["offline"]"#]), isEnabled: true,
            fieldLabels: ["capabilities": "需要的能力"],
            fieldComponents: ["capabilities": .init(id: "choice", kind: .multiChoice,
                options: [.init(id: "offline", label: "离线可用")], fieldID: "capabilities")],
            onSubmit: {}, onReset: {})
    }

    private var continueFixture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(canSubmit ? "关闭提交条件" : "满足提交条件") { canSubmit.toggle() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("fixture-toggle-submit-gate")
            Text("提交次数：\(submitCount)").accessibilityIdentifier("fixture-submit-count")
            Text("重置次数：\(resetCount)").accessibilityIdentifier("fixture-reset-count")
            IOSIntelligentUIComponentView(component: .init(id: "actions", kind: .column, children: [
                .init(id: "group", kind: .buttonGroup, children: [
                    .init(id: "continue", kind: .button, title: "CONTINUE_ONLY", action: .continue),
                    .init(id: "submit", kind: .submitButton, title: "SUBMIT_ONLY"),
                    .init(id: "reset", kind: .button, title: "RESET_DRAFT", action: .reset),
                    .init(id: "reset-native", kind: .resetButton, title: "RESET_NATIVE")
                ])
            ]), draftValues: $values, isEnabled: true, canSubmit: canSubmit,
            onSubmit: { submitCount += 1 }, onReset: { values = [:]; resetCount += 1 })
        }
    }

    private var inputFixture: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([IOSIntelligentUIComponent.Kind.toggle, .textField, .slider, .stepper], id: \.self) { target in
                Button("检查 \(target.rawValue)") { values = [:]; inputKind = target }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("fixture-input-\(target.rawValue)")
            }
            Text("输入状态")
                .accessibilityIdentifier("fixture-input-value")
                .accessibilityValue(values["value"] ?? "UNANSWERED")
            IOSIntelligentUIComponentView(component: .init(id: "untitled-\(inputKind.rawValue)", kind: inputKind,
                fieldID: "value", min: inputKind == .slider || inputKind == .stepper ? 0 : nil,
                max: inputKind == .slider || inputKind == .stepper ? 100 : nil,
                step: inputKind == .slider || inputKind == .stepper ? 5 : nil),
                draftValues: $values, isEnabled: true,
                fieldLabels: ["value": "用户补充约束"], requiredFieldIDs: ["value"],
                onSubmit: {}, onReset: { values = [:] })
                .id(inputKind)
        }
    }

    private var studyFixture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("学习草稿")
                .accessibilityIdentifier("fixture-study-draft")
                .accessibilityValue(studyOwner.store.draft(for: studyOwner.source, definition: studyOwner.definition)
                    .values[IOSIntelligentUIStudySession.storageKey] ?? "EMPTY")
            Text("提交次数：\(studyOwner.capture.submissions.count)")
                .accessibilityIdentifier("fixture-study-submit-count")
            Text("已保存结果")
                .accessibilityIdentifier("fixture-study-receipt")
                .accessibilityValue(studyOwner.host.receipts[studyOwner.source]?.prompt() ?? "EMPTY")
            Text("原会话来源")
                .accessibilityIdentifier("fixture-study-source")
                .accessibilityValue(studyOwner.capture.submissions.last.map {
                    "\($0.source.conversationID)/\($0.source.messageID)/\($0.source.cardID)"
                } ?? "EMPTY")
            ChatIntelligentUIBlock(definition: studyOwner.definition, isMessageComplete: true,
                                  messageID: studyOwner.source.messageID)
                .environment(\.intelligentUIHost, studyOwner.host)
                .environment(\.intelligentUIConversationID, studyOwner.source.conversationID)
        }
    }

    private var numericFixture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数字草稿")
                .accessibilityIdentifier("fixture-numeric-draft")
                .accessibilityValue(numericOwner.store.draft(for: numericOwner.source, definition: numericOwner.definition)
                    .values["chapters"] ?? "UNANSWERED")
            Text("提交次数：\(numericOwner.capture.submissions.count)")
                .accessibilityIdentifier("fixture-numeric-submit-count")
            Text("已保存数字")
                .accessibilityIdentifier("fixture-numeric-receipt")
                .accessibilityValue(numericOwner.host.receipts[numericOwner.source]?.inputs.first(where: { $0.id == "chapters" })?.value ?? "EMPTY")
            ChatIntelligentUIBlock(definition: numericOwner.definition, isMessageComplete: true,
                                  messageID: numericOwner.source.messageID)
                .environment(\.intelligentUIHost, numericOwner.host)
                .environment(\.intelligentUIConversationID, numericOwner.source.conversationID)
        }
    }

    @MainActor @Observable fileprivate final class SubmissionCapture {
        var submissions: [IOSIntelligentUISubmission] = []
    }

    @MainActor private final class CardOwner {
        let definition: IOSIntelligentUICardDefinition
        let source: IOSIntelligentUISource
        let store: IOSIntelligentUIStateStore
        let host: IOSIntelligentUIHost
        let capture: SubmissionCapture

        init(kind: Kind = .study) {
            // This immutable fixture is validated by the same decoder as production messages.
            if kind == .numeric {
                let example = try! IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.numericExploreExampleJSON)
                definition = IOSIntelligentUICardDefinition(cardID: example.cardID, kind: example.kind,
                    goal: example.goal, question: example.question, options: example.options, fields: example.fields,
                    submit: example.submit, components: example.components + [.init(id: "reset-numeric", kind: .resetButton, title: "清空数字卡")])
                try! IOSIntelligentUIProtocol.validate(definition)
            } else {
                definition = try! IOSIntelligentUIProtocol.decode(#"""
                {"version":1,"card_id":"ming-study","kind":"study","goal":"明朝十六帝 · 互动记忆卡","question":"","options":[],
                 "study":{"items":[
                   {"id":"hongwu","prompt":"朱元璋的年号是什么？","answer":"洪武。朱元璋建立明朝，口诀从「洪」起。","detail":"洪建永洪宣，正景天成；弘正嘉隆，万泰天崇。",
                    "options":[{"id":"hongwu","label":"洪武"},{"id":"yongle","label":"永乐"}],"correct_option_id":"hongwu"},
                   {"id":"yingzong","prompt":"明英宗朱祁镇用了哪两个年号？","answer":"正统与天顺，同一位皇帝两次在位。",
                    "options":[{"id":"two-reigns","label":"正统与天顺"},{"id":"wrong","label":"洪武与建文"}],"correct_option_id":"two-reigns"}]},
                 "components":[{"id":"reset","kind":"resetButton","title":"清空学习卡"}],
                 "submit":{"label":"针对错题继续练习","intent":"continue"}}
                """#)
            }
            source = IOSIntelligentUISource(conversationID: kind == .numeric ? "numeric-origin" : "study-origin",
                                            messageID: kind == .numeric ? "numeric-message" : "study-message",
                                            textPartIndex: 0, cardID: definition.cardID)
            // A nil fileURL means no disk persistence and no access to user drafts.
            store = IOSIntelligentUIStateStore()
            capture = SubmissionCapture()
            let capture = capture
            host = IOSIntelligentUIHost(stateStore: store, action: {
                capture.submissions.append($0)
                return .saved
            })
        }
    }
}
#endif
