import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatRunUploadCancellationTests: IOSChatKernelRunHostTestCase {
    @MainActor
    private final class RecallGate {
        var started = false
        var observedCancellation = false
        var continuation: CheckedContinuation<Void, Never>?

        func recall() async -> ChatMemoryContextBuilder.RecallResult? {
            started = true
            await withCheckedContinuation { continuation = $0 }
            observedCancellation = Task.isCancelled
            return nil
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testCancellationWhileAwaitingRecallCancelsChildAndSkipsImagePreparation() async {
        let harness = makeHarness()
        let gate = RecallGate()
        var refreshedLinks = false
        var imagePreparations = 0
        var uploadsPrepared = 0
        harness.bindings.prepareJevMemoryRecall = { _, _ in await gate.recall() }
        harness.bindings.refreshOrchestrationLinks = { refreshedLinks = true }
        harness.bindings.prepareImageAttachments = { messages, _, _, _ in
            imagePreparations += 1
            return messages
        }
        let preparation = ChatRunUploadPreparation(
            runId: "cancel-awaiting-recall",
            conversationId: harness.conversationId,
            settings: harness.dependencies.sharedSettings.snapshot,
            toolExposureBridge: harness.toolExposureBridge,
            mcpEnabled: { false },
            bindings: harness.bindings,
            isCurrentRun: { true },
            onPreparedUpload: { _, _, _ in uploadsPrepared += 1 }
        )
        let task = Task { @MainActor in
            do {
                _ = try await preparation.prepareUploadMessages(
                    harness.messages,
                    provider: harness.providerSetting,
                    params: harness.params
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Expected cancellation, received \(error)")
                return false
            }
        }
        let waitingForRecall = await waitForCondition { gate.started && refreshedLinks }
        XCTAssertTrue(waitingForRecall)
        task.cancel()
        gate.release()

        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(gate.observedCancellation, "The parallel recall belongs to the cancelled upload")
        XCTAssertEqual(imagePreparations, 0, "Cancellation must stop the next auxiliary request")
        XCTAssertEqual(uploadsPrepared, 0)
    }

    func testPreCancelledUploadDoesNotStartRecallOrImagePreparation() async {
        let harness = makeHarness()
        var recallCalls = 0
        var imagePreparations = 0
        harness.bindings.prepareJevMemoryRecall = { _, _ in
            recallCalls += 1
            return nil
        }
        harness.bindings.prepareImageAttachments = { messages, _, _, _ in
            imagePreparations += 1
            return messages
        }
        let preparation = ChatRunUploadPreparation(
            runId: "pre-cancelled-upload",
            conversationId: harness.conversationId,
            settings: harness.dependencies.sharedSettings.snapshot,
            toolExposureBridge: harness.toolExposureBridge,
            mcpEnabled: { false },
            bindings: harness.bindings,
            isCurrentRun: { true },
            onPreparedUpload: { _, _, _ in XCTFail("Cancelled upload cannot be published") }
        )
        let task = Task { @MainActor in
            do {
                _ = try await preparation.prepareUploadMessages(
                    harness.messages,
                    provider: harness.providerSetting,
                    params: harness.params
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Expected cancellation, received \(error)")
                return false
            }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(recallCalls, 0)
        XCTAssertEqual(imagePreparations, 0)
    }
}
