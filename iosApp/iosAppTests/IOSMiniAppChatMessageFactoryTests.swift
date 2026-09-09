import XCTest
import Shared
@testable import iosApp

@MainActor
final class IOSMiniAppChatMessageFactoryTests: XCTestCase {
    func testMightContainMiniAppRequiresCoreFieldsOrHTMLDocument() {
        XCTAssertTrue(IOSMiniAppChatMessageFactory.mightContainMiniApp(
            #"{"title":"计时","description":"番茄钟","html":"<!DOCTYPE html><html></html>"}"#
        ))
        XCTAssertTrue(IOSMiniAppChatMessageFactory.mightContainMiniApp(
            "<!DOCTYPE html><html><body>hello</body></html>"
        ))
        XCTAssertFalse(IOSMiniAppChatMessageFactory.mightContainMiniApp(
            #"{"title":"计时","html":"not really"}"#
        ))
    }

    func testAssistantCandidateSkipsTrailingNoticeAndStaysInCurrentTurn() {
        let priorPayload = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(
                text: #"{"title":"旧应用","description":"不应命中","html":"<!DOCTYPE html><html></html>"}"#,
                metadata: nil
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let user = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.user,
            parts: [UIMessagePart.Text(text: "做一个番茄钟小应用", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let payload = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(
                text: #"{"title":"计时","description":"番茄钟","html":"<!DOCTYPE html><html></html>"}"#,
                metadata: nil
            )],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let notice = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [UIMessagePart.Text(text: "模型连续重复调用工具，已停止本轮。", metadata: nil)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let messages = [priorPayload, user, payload, notice]
        XCTAssertEqual(
            IOSMiniAppChatMessageFactory.assistantCandidateIndex(in: messages, afterUserIndex: 1),
            2
        )
    }

    func testUpdatedAssistantReplacesJSONWithStatusAndMiniAppPart() throws {
        let json = #"{"title":"计时器","description":"一个番茄钟","category":"tool","permissions":[],"html":"<!DOCTYPE html><html><body>ok</body></html>"}"#
        let assistant = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Text(text: "先说明一下\n\(json)", metadata: nil),
            ],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let record = IOSMiniAppRecord(
            id: "app-1",
            title: "计时器",
            description: "一个番茄钟",
            htmlContent: "<!DOCTYPE html><html><body>ok</body></html>",
            sourceConversationId: nil,
            sourceMessageId: nil,
            iconEmoji: "⏱",
            category: "tool",
            permissions: [],
            pinned: false,
            runCount: 0,
            boardSummary: nil,
            version: 1,
            htmlHash: "abc",
            createdAt: 1,
            updatedAt: 1,
            lastRunAt: nil
        )

        let updated = IOSMiniAppChatMessageFactory.updatedAssistant(
            assistant,
            textPartIndex: 0,
            statusText: "已生成小应用：计时器",
            record: record
        )

        XCTAssertEqual(updated.parts.count, 2)
        let text = try XCTUnwrap(updated.parts[0] as? UIMessagePart.Text)
        XCTAssertEqual(text.text, "已生成小应用：计时器")
        let miniApp = try XCTUnwrap(updated.parts[1] as? UIMessagePart.MiniApp)
        XCTAssertEqual(miniApp.appId, "app-1")
        XCTAssertEqual(miniApp.title, "计时器")
        XCTAssertEqual(miniApp.description_, "一个番茄钟")
        XCTAssertEqual(miniApp.iconEmoji, "⏱")
        XCTAssertEqual(miniApp.version, 1)
        XCTAssertEqual(miniApp.htmlHash, "abc")
    }

    func testPersistedConversationReferencesRequireExactVersionAndHash() {
        let v1 = IOSMiniAppRecord(
            id: "app-1",
            title: "计时器",
            description: "一个番茄钟",
            htmlContent: "<!DOCTYPE html><html><body>ok</body></html>",
            sourceConversationId: nil,
            sourceMessageId: nil,
            iconEmoji: "⏱",
            category: "tool",
            permissions: [],
            pinned: false,
            runCount: 0,
            boardSummary: nil,
            version: 1,
            htmlHash: "hash-v1",
            createdAt: 1,
            updatedAt: 1,
            lastRunAt: nil
        )
        var v2 = v1
        v2.version = 2
        v2.htmlHash = "hash-v2"
        let assistant = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [IOSMiniAppChatMessageFactory.miniAppPart(from: v2)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )

        let references = IOSMiniAppChatMessageFactory.persistedConversationReferences(in: [assistant])

        XCTAssertTrue(references.contains(IOSMiniAppConversationReference(record: v2)))
        XCTAssertFalse(references.contains(IOSMiniAppConversationReference(record: v1)))
    }

    func testColdStartReconciliationKeepsMutationReferencedByPersistedConversation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-reconcile-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "miniapp-reconcile-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let repository = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        let mutation = try repository.saveGeneratedMutation(
            IOSMiniAppGeneratedOutput(
                title: "冷启动闭环",
                description: "已写入聊天",
                html: "<!DOCTYPE html><html><body>ok</body></html>"
            )
        )
        let conversationStore = IOSConversationStore(
            baseDirectory: root.appendingPathComponent("conversations", isDirectory: true)
        )
        await conversationStore.bootstrap()
        let conversationId = try XCTUnwrap(conversationStore.currentConversation?.id)
        let assistant = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [IOSMiniAppChatMessageFactory.miniAppPart(from: mutation.record)],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: chatNowLocalDateTime(),
            modelId: nil,
            usage: nil,
            translation: nil
        )
        let didSaveConversation = await conversationStore.save(messages: [assistant], to: conversationId)
        XCTAssertTrue(didSaveConversation)

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: IOSSharedSettingsStore(userDefaults: defaults),
            miniAppRepository: repository,
            autoGenerateResponses: false
        )
        viewModel.conversationStore = conversationStore
        await viewModel.reconcilePendingMiniAppMutationsAfterConversationBootstrap()

        let relaunched = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        XCTAssertEqual(relaunched.get(mutation.record.id), mutation.record)
        XCTAssertFalse(relaunched.hasPendingConversationMutations)
    }

    func testRevisionPromptIncludesAppIdAndUserRequest() {
        let prompt = IOSMiniAppChatMessageFactory.revisionPrompt(
            appId: "app-9",
            title: "计时器",
            version: 2,
            request: "按钮改小一点"
        )
        XCTAssertTrue(prompt.contains("修改小应用"))
        XCTAssertTrue(prompt.contains("appId: app-9"))
        XCTAssertTrue(prompt.contains("currentVersion: 2"))
        XCTAssertTrue(prompt.contains("按钮改小一点"))
    }

    func testRevisionChangeNoteStopsBeforeBaseInstruction() {
        let note = IOSMiniAppChatMessageFactory.revisionChangeNote(from: """
        修改小应用
        appId: app-1
        currentVersion: 1
        title: 计时器

        用户修改意见：
        增加今日统计

        请基于这个已保存小应用生成新版，并保留适合的能力声明。
        """)
        XCTAssertEqual(note, "增加今日统计")
    }

    func testAppliedMiniAppRollbackRemovesRepositoryAndWorkspaceWrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-chat-rollback-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "miniapp-chat-rollback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        sharedSettings.updateMiniAppRuntime { _ in MiniAppSettingPatch(enabled: true) }
        let repository = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        let workspace = IOSWorkspaceStore(baseDirectory: root)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            miniAppRepository: repository,
            workspaceStore: workspace,
            autoGenerateResponses: false
        )
        let output = IOSMiniAppGeneratedOutput(
            title: "计时器",
            description: "一个番茄钟",
            html: "<!DOCTYPE html><html><body>ok</body></html>"
        )
        let payload = try XCTUnwrap(String(data: JSONEncoder().encode(output), encoding: .utf8))
        let application = try XCTUnwrap(viewModel.applyMiniAppOutputIfPresentPublic(
            to: [
                UIMessage.companion.user(prompt: "请创建一个小应用"),
                UIMessage.companion.assistant(prompt: payload),
            ],
            conversationId: nil
        ))

        XCTAssertEqual(repository.apps.count, 1)
        XCTAssertTrue(workspace.artifacts.isEmpty, "Workspace sync must wait until conversation persistence succeeds.")
        XCTAssertTrue(application.rollback())
        XCTAssertTrue(repository.apps.isEmpty)
        XCTAssertTrue(workspace.artifacts.isEmpty)
        XCTAssertTrue(application.rollbackMessages.last?.toText().contains("未保留") == true)
    }

    func testAppliedMiniAppSyncsWorkspaceOnlyAfterConversationCommitHook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-chat-workspace-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "miniapp-chat-workspace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        sharedSettings.updateMiniAppRuntime { _ in MiniAppSettingPatch(enabled: true) }
        let repository = IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false)
        let workspace = IOSWorkspaceStore(baseDirectory: root)
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            miniAppRepository: repository,
            workspaceStore: workspace,
            autoGenerateResponses: false
        )
        let output = IOSMiniAppGeneratedOutput(
            title: "计时器",
            description: "一个番茄钟",
            html: "<!DOCTYPE html><html><body>ok</body></html>"
        )
        let payload = try XCTUnwrap(String(data: JSONEncoder().encode(output), encoding: .utf8))
        let application = try XCTUnwrap(viewModel.applyMiniAppOutputIfPresentPublic(
            to: [
                UIMessage.companion.user(prompt: "请创建一个小应用"),
                UIMessage.companion.assistant(prompt: payload),
            ],
            conversationId: nil
        ))

        XCTAssertTrue(workspace.artifacts.isEmpty)
        XCTAssertNil(application.syncWorkspaceAfterConversationPersistence())
        XCTAssertEqual(workspace.artifacts.count, 1)
        XCTAssertEqual(workspace.artifacts.first?.sourceId, repository.apps.first?.id)
    }

    func testExplicitMiniAppWithoutPayloadReturnsFailedApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-chat-invalid-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "miniapp-chat-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        sharedSettings.updateMiniAppRuntime { _ in MiniAppSettingPatch(enabled: true) }
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            miniAppRepository: IOSMiniAppRepository(baseDirectory: root, seedOnMissingStore: false),
            workspaceStore: IOSWorkspaceStore(baseDirectory: root),
            autoGenerateResponses: false
        )

        let application = try XCTUnwrap(viewModel.applyMiniAppOutputIfPresentPublic(
            to: [
                UIMessage.companion.user(prompt: "请创建一个番茄钟小应用"),
                UIMessage.companion.assistant(prompt: "我暂时无法生成。"),
            ],
            conversationId: nil
        ))

        XCTAssertEqual(application.outcome, .failed)
        XCTAssertTrue(application.messages.last?.toText().contains("没有返回完整的 MiniApp JSON") == true)
    }

    func testMiniAppStreamingCodePreviewPrefersHTMLAndUnescapesJSONField() {
        let rawHTML = ChatMiniAppStreamingCard.codePreview(
            from: "preamble\n<!DOCTYPE html><html><body>ok</body></html>"
        )
        XCTAssertTrue(rawHTML.hasPrefix("<!DOCTYPE html>"))

        let fromJSON = ChatMiniAppStreamingCard.codePreview(
            from: #"{"title":"计时","description":"番茄钟","html":"<!DOCTYPE html>\n<html>\n<body>hi</body>\n</html>"}"#
        )
        XCTAssertTrue(fromJSON.contains("<!DOCTYPE html>"))
        XCTAssertTrue(fromJSON.contains("\n<html>"))
        XCTAssertFalse(fromJSON.contains("\\n"))
    }

    func testMiniAppStreamingCodePreviewKeepsLatestWindowAndReportsOmittedCharacters() {
        let html = "<!DOCTYPE html>" + String(repeating: "旧", count: 2_300) + "<p>最新</p></html>"
        let preview = ChatMiniAppStreamingCard.codePreview(from: html)
        let omittedCount = html.count - 2_000
        let notice = IOSAppLocalization.formatted(
            "已省略 %lld 字", defaultValue: "已省略 %lld 字",
            arguments: [Int64(omittedCount)]
        ) + "\n"

        XCTAssertTrue(preview.hasPrefix(notice))
        XCTAssertEqual(String(preview.dropFirst(notice.count)), String(html.suffix(2_000)))
    }

    func testMiniAppStreamingCodePreviewDecodesJSONEscapesAndUnicode() {
        let json = #"{"title":"计时","description":"番茄钟","html":"<div>line\n\u4F60\u597D\u0065\u0301😀</div>"}"#
        let preview = ChatMiniAppStreamingCard.codePreview(from: json)

        XCTAssertEqual(preview, "<div>line\n你好é😀</div>")
        XCTAssertEqual(preview.count, "<div>line\n你好é😀</div>".count)
        XCTAssertFalse(preview.contains("\\u"))
    }

    func testMiniAppStreamingCodePreviewWindowTracksGrowthAndReplacement() {
        let initialHTML = "<html>" + String(repeating: "a", count: 2_050) + "-initial</html>"
        let grownHTML = initialHTML + "-grown"

        let initialPreview = ChatMiniAppStreamingCard.codePreview(from: initialHTML)
        let grownPreview = ChatMiniAppStreamingCard.codePreview(from: grownHTML)
        let replacement = ChatMiniAppStreamingCard.codePreview(from: "<html>replacement</html>")

        XCTAssertTrue(initialPreview.hasSuffix(String(initialHTML.suffix(2_000))))
        XCTAssertTrue(grownPreview.hasSuffix(String(grownHTML.suffix(2_000))))
        XCTAssertFalse(grownPreview.hasSuffix(String(initialHTML.suffix(2_000))))
        XCTAssertEqual(replacement, "<html>replacement</html>")
    }

    func testMiniAppStreamingPreviewStateDecodesEscapesAcrossChunks() {
        var state = IOSMiniAppStreamingCodePreviewState()
        let first = "{\"html\":\"<p>\\"
        let second = first + "n\\uD83D"
        let third = second + "\\uDE00</p>\"}"

        state.update(first)
        state.update(second)
        state.update(third)
        state.finish()

        XCTAssertEqual(state.displayText, "<p>\n😀</p>")
    }

    func testMiniAppStreamingPreviewStateResetsOnReplacementAndKeepsTail() {
        var state = IOSMiniAppStreamingCodePreviewState()
        let oldHTML = String(repeating: "旧", count: 2_100) + "尾"
        let oldPrefix = "{\"html\":\"" + String(repeating: "旧", count: 2_100)

        state.update(oldPrefix)
        state.update(oldPrefix + "尾\"}")

        let omittedCount = oldHTML.count - 2_000
        let notice = IOSAppLocalization.formatted(
            "已省略 %lld 字", defaultValue: "已省略 %lld 字",
            arguments: [Int64(omittedCount)]
        ) + "\n"
        XCTAssertTrue(state.displayText.hasPrefix(notice))
        XCTAssertTrue(state.displayText.hasSuffix(String(oldHTML.suffix(2_000))))

        state.update(#"{"html":"新😀"}"#)
        state.finish()

        XCTAssertEqual(state.displayText, "新😀")
    }

    func testMiniAppStreamingPreviewStateCountsLiteralGraphemeAcrossChunks() {
        var state = IOSMiniAppStreamingCodePreviewState()
        let expected = String(repeating: "a", count: 1_999) + "e\u{301}"
        let first = "{\"html\":\"" + String(repeating: "a", count: 1_999) + "e"

        state.update(first)
        state.update(first + "\u{301}")
        state.update(first + "\u{301}\"}")
        state.finish()

        XCTAssertEqual(state.displayText, expected)
    }

    func testMiniAppStreamingPreviewStateCountsEscapedGraphemeAcrossChunks() {
        var state = IOSMiniAppStreamingCodePreviewState()
        let expected = String(repeating: "a", count: 1_999) + "e\u{301}"
        let first = "{\"html\":\"" + String(repeating: "a", count: 1_999) + "\\u0065"

        state.update(first)
        state.update(first + "\\u0301")
        state.update(first + "\\u0301\"}")
        state.finish()

        XCTAssertEqual(state.displayText, expected)
    }
}
