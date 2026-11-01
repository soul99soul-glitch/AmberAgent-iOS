import Foundation
import Testing
@testable import AmberMac

@MainActor
struct DesktopIntelligentUITests {
    private static let decisionFormCardJSON = #"""
    {
      "version": 1,
      "card_id": "release-plan-v1",
      "kind": "decision",
      "goal": "确定 macOS 原生智能 UI 交付方案",
      "question": "请选择优先推进的交互路径并补充验收范围：",
      "options": [
        {
          "id": "native-swiftui",
          "title": "复用 task-ui v1 协议 + DesktopTheme 原生渲染",
          "summary": "与 iOS/移动端共享协议模型与状态存储，桌面端使用琥珀含光视觉。",
          "tradeoffs": ["零重复协议定义", "支持直接提交与填入输入框草稿"],
          "recommended": true
        },
        {
          "id": "markdown-only",
          "title": "仅渲染静态代码块",
          "summary": "不支持组件级交互与状态回传。",
          "tradeoffs": ["实现简单但缺少闭环体验"]
        }
      ],
      "fields": [
        { "id": "scope", "label": "覆盖组件族", "required": true, "type": "multiChoice" },
        { "id": "verify_light_dark", "label": "同时验证浅色与深色", "required": true, "type": "bool" },
        { "id": "notes", "label": "补充说明", "placeholder": "可选备注", "required": false, "type": "text" }
      ],
      "components": [
        {
          "id": "form-section",
          "kind": "card",
          "title": "验收配置",
          "children": [
            {
              "id": "scope-choice",
              "kind": "multiChoice",
              "field_id": "scope",
              "title": "选择本次验证的组件族",
              "options": [
                { "id": "layout_text", "label": "布局与文本" },
                { "id": "input_data", "label": "输入与数据图表" },
                { "id": "study_action", "label": "学习卡与动作组" }
              ]
            },
            {
              "id": "theme-toggle",
              "kind": "toggle",
              "field_id": "verify_light_dark",
              "title": "浅色/深色双外观快照"
            },
            {
              "id": "summary-preview",
              "kind": "decisionSummary",
              "title": "当前配置摘要",
              "items": ["scope", "verify_light_dark", "notes"]
            }
          ]
        }
      ],
      "submit": {
        "label": "按所选方案继续",
        "intent": "continue"
      }
    }
    """#

    @Test func catalogSupportsAll80MobileComponentKindsAnd4CardKinds() throws {
        #expect(IOSIntelligentUIComponent.Kind.allCases.count == 80)
        let card = try IOSIntelligentUIProtocol.decode(Self.decisionFormCardJSON)
        try IOSIntelligentUIProtocol.validate(card)
        #expect(card.cardID == "release-plan-v1")
        #expect(card.kind == "decision")
        #expect(card.options.count == 2)
        #expect(card.fields.count == 3)

        let exploreCard = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.numericExploreExampleJSON)
        try IOSIntelligentUIProtocol.validate(exploreCard)
        #expect(exploreCard.kind == "explore")
    }

    @Test func streamingPreviewAndInvalidBlockIsolationPreserveSurroundingMarkdown() {
        let intro = "## 方案分析\n\n先看前文说明。"
        let partialFence = """
        \(intro)

        ```task-ui
        {
          "version": 1,
          "card_id": "stream-card",
          "kind": "decision",
          "goal": "流式生成中的任务卡",
          "question": "正在逐步输出选项",
          "options": [
            { "id": "opt-a", "title": "方案 A", "summary": "已完成首个方案解析" }
          ]
        """
        let streamingSegments = IOSIntelligentUIProtocol.parse(partialFence, isStreaming: true)
        #expect(streamingSegments.count == 2)
        if case .text(let prefix) = streamingSegments.first {
            #expect(prefix.contains("方案分析"))
        } else {
            Issue.record("Expected leading Markdown text segment before streaming task-ui fence")
        }
        #expect(streamingSegments.last == .loading)

        var scanner = IOSIntelligentUIStreamingPreviewScanner()
        scanner.update(with: partialFence)
        #expect(scanner.preview?.goal == "流式生成中的任务卡")
        #expect(scanner.preview?.options.first?.title == "方案 A")

        let invalidWithTrailingMarkdown = """
        \(intro)

        ```task-ui
        { "version": 99, "card_id": "bad", "kind": "unknown" }
        ```

        ### 后续结论

        | 指标 | 结果 |
        | --- | --- |
        | 隔离性 | 正常渲染 |
        """
        let completedSegments = IOSIntelligentUIProtocol.parse(invalidWithTrailingMarkdown, isStreaming: false)
        #expect(completedSegments.count == 3)
        if case .invalid(_, let reason) = completedSegments[1] {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected middle segment to be .invalid")
        }
        if case .text(let trailing) = completedSegments[2] {
            #expect(trailing.contains("后续结论"))
            #expect(trailing.contains("正常渲染"))
        } else {
            Issue.record("Expected trailing Markdown after invalid task-ui fence to remain intact")
        }
    }

    @Test func numericExploreBindingsAndStudySessionRoundTrip() throws {
        let explore = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.numericExploreExampleJSON)
        let values = ["chapters": "3"]
        #expect(IOSIntelligentUIComponentValues.hasValidNumericDraftValues(values, components: explore.components))

        let boundChapters = try #require(explore.boundComponent(for: "chapters"))
        let fieldMap = ["chapters": boundChapters]
        let resolvedMetric = IOSIntelligentUIComponentValues.resolveNumber(
            value: 1,
            valueFieldID: "chapters",
            draftValues: values,
            fieldComponents: fieldMap
        )
        #expect(resolvedMetric == 3)
        #expect(IOSIntelligentUIComponentValues.numericDisplayString(resolvedMetric ?? 0) == "3")

        let studyCard = try IOSIntelligentUIProtocol.decode(IOSIntelligentUIProtocol.studyExampleJSON)
        let studyDef = try #require(studyCard.study)
        var session = IOSIntelligentUIStudySession()
        try session.reveal(definition: studyDef)
        try session.setMode(.quiz, definition: studyDef)
        try session.answer(optionID: "yuanzhang", definition: studyDef)

        let source = IOSIntelligentUISource(
            conversationID: UUID().uuidString,
            messageID: UUID().uuidString,
            textPartIndex: 0,
            cardID: studyCard.cardID
        )
        let store = IOSIntelligentUIStateStore()
        try store.update(
            source: source,
            definition: studyCard,
            selectedOptionID: nil,
            values: [IOSIntelligentUIStudySession.storageKey: try session.encodedValue()]
        )
        let draft = store.draft(for: source, definition: studyCard)
        let submission = try DesktopIntelligentUISubmission(source: source, definition: studyCard, draft: draft)
        #expect(submission.studySummary?.correctCount == 1)
        #expect(submission.prompt().contains("【任务卡交互结果】"))
    }

    @Test func workspaceDraftInsertionPreservesExistingDraftAndAttachmentsAndSubmitStartsTurn() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("amber-smart-ui-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let defaults = UserDefaults(suiteName: "amber.test.smartui.\(UUID().uuidString)")!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var providerConfig = try #require(settings.selectedProvider)
        providerConfig.modelID = "smart-ui-test-model"
        try settings.saveProvider(providerConfig, apiKey: "test-key")

        let assistantMessage = DesktopMessage(
            role: .assistant,
            text: "请选择方案：\n\n```task-ui\n\(Self.decisionFormCardJSON)\n```\n\n以上为候选方案。",
            state: .complete
        )
        let conversationA = DesktopConversation(title: "会话 A", messages: [
            DesktopMessage(role: .user, text: "帮我规划智能 UI 方案"),
            assistantMessage
        ])
        let conversationB = DesktopConversation(title: "会话 B", messages: [
            DesktopMessage(role: .user, text: "另一个独立会话"),
            assistantMessage
        ])

        let stateURL = tempDir.appendingPathComponent("intelligent-ui-state.json")
        let receiptsURL = tempDir.appendingPathComponent("intelligent-ui-receipts.json")
        let fakeProvider = SmartUITestProvider()
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage([conversationA, conversationB]),
            provider: fakeProvider,
            initialConversations: [conversationA, conversationB],
            intelligentUIStateStore: IOSIntelligentUIStateStore(fileURL: stateURL),
            intelligentUIReceiptsFileURL: receiptsURL
        )
        workspace.select(conversationA.id)

        // Verify capability prompt injection in requestMessages
        let requestMsgs = try workspace.requestMessages(
            conversationA.messages,
            conversationID: conversationA.id,
            configuration: try #require(settings.selectedProvider)
        )
        #expect(requestMsgs.first?.role == .system)
        #expect(requestMsgs.first?.text.contains("task-ui") == true)

        let card = try IOSIntelligentUIProtocol.decode(Self.decisionFormCardJSON)
        let sourceA = IOSIntelligentUISource(
            conversationID: conversationA.id.uuidString,
            messageID: assistantMessage.id.uuidString,
            textPartIndex: 0,
            cardID: card.cardID
        )
        let sourceB = IOSIntelligentUISource(
            conversationID: conversationB.id.uuidString,
            messageID: assistantMessage.id.uuidString,
            textPartIndex: 0,
            cardID: card.cardID
        )

        try workspace.intelligentUIStateStore.update(
            source: sourceA,
            definition: card,
            selectedOptionID: "native-swiftui",
            values: [
                "scope": #"["input_data","layout_text"]"#,
                "verify_light_dark": "true",
                "notes": "保留现有输入框草稿与附件"
            ]
        )
        try workspace.intelligentUIStateStore.update(
            source: sourceB,
            definition: card,
            selectedOptionID: "markdown-only",
            values: [
                "scope": #"["study_action"]"#,
                "verify_light_dark": "false"
            ]
        )
        try await workspace.intelligentUIStateStore.flush()

        // Reload state store from disk to verify persistence round-trip
        let reloadedStore = IOSIntelligentUIStateStore(fileURL: stateURL)
        reloadedStore.register(source: sourceA, definition: card)
        let reloadedDraftA = reloadedStore.draft(for: sourceA, definition: card)
        #expect(reloadedDraftA.selectedOptionID == "native-swiftui")
        #expect(reloadedDraftA.values["notes"] == "保留现有输入框草稿与附件")

        // Verify composer draft insertion preserves existing composer text AND pending attachments
        workspace.draft = "我已准备好以下补充材料："
        let attachment = DesktopImportedDocument(
            id: UUID(),
            name: "architecture.md",
            sourceURL: nil,
            kind: .document,
            byteCount: 128,
            text: "# Architecture Notes",
            image: nil,
            pageCount: nil,
            note: nil
        )
        workspace.pendingAttachments = [attachment]

        let insertResult = workspace.intelligentUIHost.insertIntoDraft(source: sourceA, definition: card)
        #expect(insertResult == .draftInserted)
        #expect(workspace.draft.hasPrefix("我已准备好以下补充材料：\n\n【任务卡选择】"))
        #expect(workspace.draft.contains("所选方案：复用 task-ui v1 协议 + DesktopTheme 原生渲染"))
        #expect(workspace.draft.contains("覆盖组件族：布局与文本、输入与数据图表"))
        #expect(workspace.draft.contains("同时验证浅色与深色：是"))
        #expect(workspace.pendingAttachments.map(\.id) == [attachment.id])

        // Verify direct card submission starts next turn WITHOUT clobbering composer draft or pending attachments
        workspace.draft = "这段未发送草稿不应被卡片直接提交清空"
        let submitResult = await workspace.intelligentUIHost.submit(source: sourceA, definition: card)
        #expect(submitResult == .started)
        #expect(workspace.draft == "这段未发送草稿不应被卡片直接提交清空")
        #expect(workspace.pendingAttachments.map(\.id) == [attachment.id])
        #expect(workspace.intelligentUIHost.receipts[sourceA] != nil)

        // Duplicate submission of identical draft is rejected until modified
        let duplicateResult = await workspace.intelligentUIHost.submit(source: sourceA, definition: card)
        if case .failure(let reason) = duplicateResult {
            #expect(reason.contains("已经提交"))
        } else {
            Issue.record("Expected duplicate submission of unchanged draft to fail")
        }

        // Complete the active generation on Conversation A, then delete Conversation A and verify state cleanup
        fakeProvider.latestRun?.yield(.snapshot(text: "收到任务卡结果，正在执行。", reasoning: ""))
        fakeProvider.latestRun?.yield(.complete)
        _ = await workspace.flush()

        workspace.delete(conversationA.id)
        _ = await workspace.flush()

        #expect(workspace.intelligentUIStateStore.draft(for: sourceA, definition: card).selectedOptionID == nil)
        #expect(workspace.intelligentUIHost.receipts[sourceA] == nil)
        // Conversation B's state remains isolated and intact
        #expect(workspace.intelligentUIStateStore.draft(for: sourceB, definition: card).selectedOptionID == "markdown-only")
    }
}

@MainActor
private final class SmartUITestProvider: DesktopTextProvider {
    var latestRun: DesktopGeneration?

    func start(
        configuration: DesktopProviderConfiguration,
        apiKey: String,
        messages: [DesktopMessage],
        responseID: UUID
    ) throws -> DesktopGeneration {
        let run = DesktopGeneration()
        latestRun = run
        return run
    }
}
