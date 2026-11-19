import XCTest
import Shared
@testable import iosApp

@MainActor
final class IOSDialogueTimelineResidualTests: XCTestCase {
    func testChildCardBreaksMainAssistantHeaderAcrossProjectionPaths() throws {
        let user = UIMessage.companion.user(prompt: "question")
        let first = UIMessage.companion.assistant(prompt: "main before child")
        let child = IosMailboxMessageBridge.shared.makeMessage(
            authorThreadId: "/synthetic/child", type: "FINAL_ANSWER", payload: "child report")
        let answer = UIMessage.companion.assistant(prompt: "main after child")
        var messages = [user, first, child, answer]
        let cache = NativeTimelineProjectionCache()
        let renderStore = ChatRenderStateStore()
        var revision = 0
        func project(_ event: ChatEvent) -> NativeTimelineProjection {
            revision += 1
            cache.prepareDisplayTexts(messages: messages)
            return cache.projection(messages: messages, event: event, sourceRevision: revision,
                startIndex: 0, configurationIssue: nil, isGenerationActive: true, isLoading: false,
                isRecognizingImages: false, contextCompactState: .idle, contextCompactBoundaries: [],
                viewportState: ChatViewportState(), displaySettingSignature: 0, generativeUiSettingSignature: 0,
                renderStateRevision: 0, reasoningLevelLabel: nil, streamedMessageIDs: [],
                renderStateStore: renderStore, variantInfoProvider: { _ in nil }, contentHashProvider: { _, _ in 0 })
        }
        func flags(_ projection: NativeTimelineProjection) -> [Bool] {
            projection.entries.filter { $0.kind == .message }.map(\.isAssistantContinuation)
        }
        let full = NativeTimelineProjector.build(messages: messages, event: .conversationLoaded)
        XCTAssertEqual(flags(full), [false, false, false, false])
        XCTAssertEqual(flags(NativeTimelineProjector.build(messages: messages,
            event: .conversationLoaded, startIndex: 2)), [false, false])
        XCTAssertEqual(flags(project(.conversationLoaded)), [false, false, false, false])
        XCTAssertEqual(flags(project(.toolResultAppended)), [false, false, false, false])
        XCTAssertEqual(flags(try XCTUnwrap(NativeTimelineProjector.replacingStreamingTail(
            in: full, messages: messages, event: .assistantStreamDelta,
            isGenerationActive: true, viewportState: ChatViewportState()))), [false, false, false, false])
        messages += [UIMessage.companion.user(prompt: "next question"),
            UIMessage.companion.assistant(prompt: "next main before child"),
            IosMailboxMessageBridge.shared.makeMessage(authorThreadId: "/synthetic/other-child",
                type: "FINAL_ANSWER", payload: "next report"),
            UIMessage.companion.assistant(prompt: "next main after child")]
        XCTAssertEqual(flags(project(.userMessageAppended)), [false, false, false, false, false, false, false, false])
    }

    func testTailDisplayPreparationDoesNotWalkHistoryAndStructuralEventsInvalidate() throws {
        ChatRenderProbe.enabled = true
        defer { ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        for historyCount in [8, 512] {
            let updates = ChatTimelineUpdates()
            let owner = UUID()
            var messages = (0..<historyCount).map { UIMessage.companion.user(prompt: "history \($0)") }
            let tail = UIMessage.companion.assistant(prompt: "part")
            messages.append(tail)
            updates.publish(.init(revision: 1, reason: .initialLoad), messages: messages)
            updates.attach(owner: owner) { _, _ in true }
            defer { updates.detach(owner: owner) }
            ChatRenderProbe.reset()
            for revision in 2...5 {
                let changed = UIMessage(id: tail.id, role: .assistant,
                    parts: [UIMessagePart.Text(text: "part \(revision)", metadata: nil)], annotations: [],
                    createdAt: tail.createdAt, finishedAt: nil, modelId: nil, usage: nil, translation: nil)
                messages[messages.count - 1] = changed
                XCTAssertFalse(updates.publish(.init(revision: revision, reason: .streamDelta), messages: messages))
                XCTAssertEqual(updates.projectionCache.displayTexts(for: changed)[0], "part \(revision)")
                XCTAssertEqual(updates.projectionCache.displayTexts(for: tail)[0], "part")
            }
            let visits = ChatRenderProbe.counts["display-facts:visit"]?["all"] ?? 0
            print("DISPLAY_FACTS history=\(historyCount) deltas=4 visits=\(visits)")
            XCTAssertEqual(visits, 4, "Display facts preparation must visit only the changed tail")
            let replaced = UIMessage.companion.assistant(prompt:
                #"{"structured_summary":{"conclusion":"replacement"},"run_ended":true}"#)
            messages[0] = replaced
            updates.publish(.init(revision: 6, reason: .toolResultAppended), messages: messages)
            XCTAssertEqual(updates.projectionCache.displayTexts(for: replaced)[0], "replacement")
            messages = [replaced]
            updates.publish(.init(revision: 7, reason: .branchChange), messages: messages)
            XCTAssertEqual(updates.structuralMessages.count, 1)
            XCTAssertEqual(updates.projectionCache.displayTexts(for: replaced)[0], "replacement")
        }
    }
}
