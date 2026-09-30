import XCTest
@testable import iosApp

/// Siri entry points, quick-action templates, note hand-off and reply length.
@MainActor
final class WatchAssistantEntryTests: XCTestCase {
    func testTemplateFillsEveryPlaceholderAndPlainPromptIsNotATemplate() {
        let template = WatchQuickAction(id: "t", title: "翻译", prompt: "把 {输入} 翻译成英文，并解释 {input}")
        XCTAssertTrue(template.isTemplate)
        XCTAssertEqual(template.filled(with: "早上好"), "把 早上好 翻译成英文，并解释 早上好")

        let plain = WatchQuickAction(id: "p", title: "番茄", prompt: "用三句话解释番茄工作法。")
        XCTAssertFalse(plain.isTemplate)
        XCTAssertNil(plain.filled(with: "x"))
    }

    func testTemplateDraftKeepsOnlyTheFillAcrossReopen() throws {
        let model = WatchTaskViewModel(bridge: WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000), store: makeStore())
        let template = WatchQuickAction(id: "t", title: "翻译", prompt: "把 {输入} 翻译成英文")

        // A full-prompt draft left from before the action became a template.
        _ = model.store.ensureDraft(key: "quick:t", mode: .ask, quickActionId: "t", initialText: "旧的完整问题")

        model.compose(mode: .ask, quickAction: template)
        XCTAssertNil(model.store.draft(forKey: "quick:t"), "the legacy full-prompt draft is not reused as a fill-in")
        XCTAssertEqual(model.store.draft(forKey: "quick-fill:t")?.text, "", "a template starts with an empty blank")
        model.store.updateDraftText(key: "quick-fill:t", text: "早上好")

        model.compose(mode: .ask, quickAction: template)
        let draft = try XCTUnwrap(model.store.draft(forKey: "quick-fill:t"))
        XCTAssertEqual(draft.text, "早上好")
        XCTAssertEqual(draft.quickActionId, "t")
    }

    func testPhoneRunsPlainPromptOrFillsTemplateAndAppendsReplyLengthVisibly() {
        let template = WatchQuickAction(id: "t", title: "翻译", prompt: "把 {输入} 翻译成英文")
        XCTAssertEqual(template.prompt(forSent: "早上好"), "把 早上好 翻译成英文")
        XCTAssertEqual(template.prompt(forSent: template.prompt), template.prompt, "older Watches send the raw prompt")
        let plain = WatchQuickAction(id: "p", title: "番茄", prompt: "解释番茄工作法")
        XCTAssertEqual(plain.prompt(forSent: "解释番茄工作法"), "解释番茄工作法")
        XCTAssertNil(plain.prompt(forSent: "被改过的问题"), "an edited plain action is rejected")

        XCTAssertEqual(ChatViewModel.watchMessage("问题", replyInstruction: nil), "问题")
        XCTAssertEqual(ChatViewModel.watchMessage("问题", replyInstruction: "请用一句话回答。"), "问题\n\n请用一句话回答。")
    }

    func testSiriAskPrefillsNewQuestionAndNoteSavesDirectly() {
        let model = WatchTaskViewModel(bridge: WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000), store: makeStore())

        model.startAsk(prefill: "明天会下雨吗")
        XCTAssertEqual(model.path, [.compose("ask")])
        XCTAssertEqual(model.store.draft(forKey: "ask")?.text, "明天会下雨吗")

        XCTAssertNotNil(model.saveNote(text: "   "), "blank notes are rejected")
        XCTAssertNil(model.saveNote(text: "买牛奶"))
        XCTAssertEqual(model.store.notes.map(\.text), ["买牛奶"])
        XCTAssertNil(model.store.notes.first?.syncedAt)
    }

    func testNoteHandOffCreatesReviewableQuestionWithoutTouchingTheNote() throws {
        let model = WatchTaskViewModel(bridge: WatchConnectivityBridge(actionTimeoutNanoseconds: 1_000_000_000), store: makeStore())
        let note = WatchNote(id: "n1", text: "周五前交报告\n约牙医", createdAt: Date())
        XCTAssertTrue(model.store.saveNote(note))

        model.composeFromNote(note, instruction: "请从这条记事中提取待办事项：")
        let draft = try XCTUnwrap(model.store.draft(forKey: "note-ask:n1"))
        XCTAssertEqual(draft.composerMode, .ask)
        XCTAssertTrue(draft.text.hasSuffix(note.text))
        XCTAssertTrue(draft.text.hasPrefix("请从这条记事中提取待办事项："))
        XCTAssertNil(draft.pendingRequest, "nothing is sent until the user confirms")
        XCTAssertEqual(model.path.last, .compose("note-ask:n1"))
        XCTAssertEqual(model.store.note(id: "n1")?.text, note.text)
    }

    func testReplyLengthPersistsAndStandardAddsNothing() throws {
        let suite = "WatchAssistantEntryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let service = IOSWatchCompanionService(baseDirectory: root, defaults: defaults)
        XCTAssertEqual(service.replyLength, .standard)
        XCTAssertNil(IOSWatchReplyLength.standard.instruction)
        service.setReplyLength(.oneSentence)
        XCTAssertEqual(IOSWatchCompanionService(baseDirectory: root, defaults: defaults).replyLength, .oneSentence)
        XCTAssertNotNil(IOSWatchReplyLength.bullets.instruction)
    }

    private func makeStore() -> WatchLocalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-entry-" + UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return WatchLocalStore(fileURL: url)
    }
}
