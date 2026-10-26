import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSAutomationIntentTests: IOSConversationStoreTestCase {
    func testReadingOtherConversationAnswerDoesNotChangeSelectedConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let firstID = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "第一项工作"),
            UIMessage.companion.assistant(prompt: "第一项结果"),
        ])
        _ = await store.newConversation()
        let selectedID = try XCTUnwrap(store.currentConversation?.id)
        await store.saveCurrent(messages: [
            UIMessage.companion.user(prompt: "当前工作"),
            UIMessage.companion.assistant(prompt: "当前结果"),
        ])

        let answer = try await IOSConversationAutomationResolver.latestAnswer(
            conversationID: firstID.toHexDashString().uppercased(), store: store
        )

        XCTAssertEqual(answer, "第一项结果")
        XCTAssertEqual(store.currentConversation?.id, selectedID)
        XCTAssertEqual(store.currentMessages.last?.toText(), "当前结果")
    }

    func testMissingExplicitConversationDoesNotFallBackToAnotherConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let selectedID = store.currentConversation?.id
        await store.saveCurrent(messages: [UIMessage.companion.assistant(prompt: "不能串到这个结果")])

        do {
            _ = try await IOSConversationAutomationResolver.latestAnswer(conversationID: UUID().uuidString, store: store)
            XCTFail("Missing conversation should fail")
        } catch IOSAppIntentError.missingConversation {
            XCTAssertEqual(store.currentConversation?.id, selectedID)
        }
    }

    func testQueryingAnEmptyStoreDoesNotCreateAConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)

        do {
            _ = try await IOSConversationAutomationResolver.conversation(id: nil, store: store)
            XCTFail("No conversation should be created by a query")
        } catch IOSAppIntentError.missingConversation {
            XCTAssertNil(store.currentConversation)
            XCTAssertTrue(store.summaries.isEmpty)
        }
    }

    func testLatestAnswerSkipsUserMessagesAndAssistantToolOnlyMessages() {
        let messages = [
            UIMessage.companion.assistant(prompt: "可供下游使用的回答"),
            UIMessage.companion.user(prompt: "之后的新问题"),
            assistantToolMessage(),
        ]
        XCTAssertEqual(IOSConversationAutomationResolver.latestAnswer(in: messages), "可供下游使用的回答")
        XCTAssertNil(IOSConversationAutomationResolver.latestAnswer(in: [
            UIMessage.companion.user(prompt: "用户文字"), assistantToolMessage(),
        ]))
    }

    func testEventPayloadValidationRejectsOversizeInputWithoutTruncatingIt() throws {
        XCTAssertEqual(try IOSWakeIntentResolver.validatedEvent("  grok.completed\n"), "grok.completed")
        XCTAssertThrowsError(try IOSWakeIntentResolver.validatedEvent(" \n"))
        XCTAssertThrowsError(try IOSWakeIntentResolver.validatedEvent(String(repeating: "a", count: 201)))
        XCTAssertNil(try IOSWakeIntentResolver.validatedEventContent(" \n"))
        XCTAssertEqual(try IOSWakeIntentResolver.validatedEventContent(" result "), "result")
        XCTAssertThrowsError(try IOSWakeIntentResolver.validatedEventContent(String(repeating: "a", count: 8_001)))
        XCTAssertEqual(try IOSWakeIntentResolver.validatedTaskPrompt(String(repeating: "a", count: 3_000)).count, 3_000)
        XCTAssertThrowsError(try IOSWakeIntentResolver.validatedTaskPrompt(String(repeating: "a", count: 8_001)))
    }

    func testTaskResultReadsOnlyTheSelectedCompletedExecution() throws {
        let first = wakeTask(status: .completed, result: "第一项任务结果")
        let selected = wakeTask(status: .completed, result: "  第二项任务结果\n")
        XCTAssertNotEqual(first.id, selected.id)
        XCTAssertEqual(try IOSWakeTaskResultResolver.result(task: selected), "  第二项任务结果\n")
        XCTAssertThrowsError(try IOSWakeTaskResultResolver.result(task: nil))
        XCTAssertThrowsError(try IOSWakeTaskResultResolver.result(task: wakeTask(status: .completed, result: nil)))
        XCTAssertThrowsError(try IOSWakeTaskResultResolver.result(task: wakeTask(status: .completed, result: " \n")))
    }

    func testUnfinishedAndFailedTasksNeverReturnOldOrPartialResults() {
        for status in [IOSWakeTask.Status.scheduled, .running, .failed, .cancelled, .interrupted] {
            var task = wakeTask(status: status, result: "不能当作本次完成结果返回的旧文字")
            task.lastMessage = "保留的真实状态说明"
            XCTAssertThrowsError(try IOSWakeTaskResultResolver.result(task: task)) { error in
                XCTAssertTrue(error.localizedDescription.contains("保留的真实状态说明"))
                XCTAssertFalse(error.localizedDescription.contains("不能当作本次完成结果返回的旧文字"))
            }
        }
    }

    func testWaitingReturnsEveryTerminalStateWithoutPollingAgain() async throws {
        for status in [IOSWakeTask.Status.completed, .failed, .cancelled, .interrupted] {
            let expected = wakeTask(status: status, result: nil)
            var reads = 0
            let task = try await IOSWakeTaskResultResolver.wait(timeoutSeconds: 20) {
                reads += 1
                return expected
            }
            XCTAssertEqual(task, expected)
            XCTAssertEqual(reads, 1)
        }
    }

    func testWaitingReturnsTheNewStateForTheSameTask() async throws {
        let running = wakeTask(status: .running, result: nil)
        var completed = running
        completed.status = .completed
        completed.resultText = "本次任务结果"
        var reads = 0
        let task = try await IOSWakeTaskResultResolver.wait(timeoutSeconds: 2) {
            reads += 1
            return reads == 1 ? running : completed
        }
        XCTAssertEqual(task.id, running.id)
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(try IOSWakeTaskResultResolver.result(task: task), "本次任务结果")
    }

    func testWaitingTimeoutReturnsPendingStateAndCancellationStopsWaiting() async throws {
        let pending = wakeTask(status: .scheduled, result: nil)
        let timedOut = try await IOSWakeTaskResultResolver.wait(timeoutSeconds: 1) { pending }
        XCTAssertEqual(timedOut, pending)
        let wait = Task {
            try await IOSWakeTaskResultResolver.wait(timeoutSeconds: 25) { pending }
        }
        wait.cancel()
        do {
            _ = try await wait.value
            XCTFail("Cancelled shortcut must stop waiting")
        } catch is CancellationError {}
    }

    func testWaitingRejectsInvalidBoundsAndMissingTask() async {
        for seconds in [0, 26] {
            do {
                _ = try await IOSWakeTaskResultResolver.wait(timeoutSeconds: seconds) { nil }
                XCTFail("Out-of-range wait should fail")
            } catch IOSWakeTaskResultError.invalidTimeout {} catch { XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await IOSWakeTaskResultResolver.wait(timeoutSeconds: 1) { nil }
            XCTFail("Missing task should fail")
        } catch IOSWakeTaskResultError.missingTask {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func wakeTask(status: IOSWakeTask.Status, result: String?) -> IOSWakeTask {
        var task = IOSWakeTask(
            id: UUID().uuidString, requestID: UUID().uuidString,
            conversationID: UUID().uuidString, sourceRunID: "shortcut-test",
            origin: IOSWakeOrigin(userMessageID: "user-test", userText: "整理本次资料"),
            title: "本次任务", prompt: "整理已授权的资料并交付结果。", createdAt: Date(),
            fireAt: nil, event: nil, requiresForeground: false
        )
        task.status = status
        task.resultText = result
        return task
    }
}
