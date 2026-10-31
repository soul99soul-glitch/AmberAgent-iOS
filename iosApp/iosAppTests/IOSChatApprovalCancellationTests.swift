import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSChatApprovalCancellationTests: IOSChatKernelRunHostTestCase {
    @MainActor
    private final class ClaimGate {
        var started = false
        var observedCancellation = false
        var continuation: CheckedContinuation<Void, Never>?

        func resume() async -> Bool {
            started = true
            await withCheckedContinuation { continuation = $0 }
            observedCancellation = Task.isCancelled
            return true
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testCancelWhileClaimingApprovedToolKeepsCancelledSnapshot() async {
        await assertStoppedApprovalClaim(detach: false)
    }

    func testBackgroundDetachWhileClaimingApprovedToolDoesNotPublishLateResult() async {
        await assertStoppedApprovalClaim(detach: true)
    }

    private func assertStoppedApprovalClaim(detach: Bool) async {
        let harness = makeHarness(exposedToolNames: ["ask_user"])
        let runtime = makeHost(harness: harness, provider: HostScriptedProvider(rounds: [])).toolRuntimeForTesting
        let provider = HostScriptedProvider(rounds: [
            toolRound("approved-question", "ask_user", #"{"question":"继续吗？"}"#),
            textRound("must not continue after stop")
        ])
        let gate = ClaimGate()
        defer { gate.release() }
        var terminals: [String] = []
        var published = harness.messages
        var publications = 0
        var callbacks = ChatRunKernelAdapter.Callbacks()
        callbacks.onRunResumed = { await gate.resume() }
        callbacks.onRunTerminal = { terminals.append($0) }
        callbacks.onMessagesUpdated = {
            publications += 1
            published = $0
        }
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: harness.ledger, callbacks: callbacks)
        let task = Task { @MainActor in
            await adapter.run(.init(
                provider: provider, providerSetting: harness.providerSetting, params: harness.params,
                runId: "approval-claim-stop", startedAt: 1, inputDigest: "test",
                conversationId: harness.conversationId, initialMessages: harness.messages,
                toolExposureBridge: harness.toolExposureBridge, maxToolResumeCount: 4,
                drainSteer: nil, mailboxDrain: nil, citationTracker: nil,
                prepareUploadMessages: nil, nestedToolRunner: nil,
                approvalDecider: { _ in .answer("已批准的回答") }
            ))
        }
        let claiming = await waitForCondition { gate.started }
        XCTAssertTrue(claiming)
        runtime.dynamicToolLifecycle.sshArguments.stage(runId: "approval-claim-stop", toolCallId: "pending-key",
            arguments: #"{"private_key":"fixture-private"}"#)
        if detach {
            adapter.detachForBackgroundHandoff()
        } else {
            adapter.cancel()
        }
        XCTAssertEqual(runtime.dynamicToolLifecycle.sshArguments.count, 0, "Cancel and handoff immediately erase pending credentials")
        let frozenOutput = F.toolOutputText(toolCallId: "approved-question", in: published)
        let frozenPublications = publications
        if !detach {
            XCTAssertTrue(frozenOutput.contains("User cancelled."))
            XCTAssertEqual(terminals, [AgentRunStatus.cancelled.wireName])
        }

        gate.release()
        _ = await task.value

        XCTAssertTrue(gate.observedCancellation, "Approval execution must receive the run's cancellation")
        XCTAssertEqual(publications, frozenPublications, "Late resolution cannot replace the stopped snapshot")
        XCTAssertEqual(F.toolOutputText(toolCallId: "approved-question", in: published), frozenOutput)
        XCTAssertEqual(provider.callCount, 1, "Stopped approval cannot restart the model loop")
        XCTAssertEqual(terminals, detach ? [] : [AgentRunStatus.cancelled.wireName])
        XCTAssertTrue(harness.log.snapshot().contains(.toolCallFinished(
            tool: "ask_user", outcome: "not_executed_cancelled"
        )))
    }

    func testAdapterCancellationReachesUploadPreparationBeforeAuxiliaryWorkContinues() async {
        let harness = makeHarness()
        let runtime = makeHost(harness: harness, provider: HostScriptedProvider(rounds: [])).toolRuntimeForTesting
        let provider = HostScriptedProvider(rounds: [textRound("must not upload")])
        let gate = ClaimGate()
        defer { gate.release() }
        var auxiliaryCalls = 0
        let adapter = ChatRunKernelAdapter(runtime: runtime, ledger: harness.ledger, callbacks: .init())
        let task = Task { @MainActor in
            await adapter.run(.init(
                provider: provider, providerSetting: harness.providerSetting, params: harness.params,
                runId: "upload-preparation-stop", startedAt: 1, inputDigest: "test",
                conversationId: harness.conversationId, initialMessages: harness.messages,
                toolExposureBridge: harness.toolExposureBridge, maxToolResumeCount: 4,
                drainSteer: nil, mailboxDrain: nil, citationTracker: nil,
                prepareUploadMessages: { messages in
                    _ = await gate.resume()
                    try Task.checkCancellation()
                    auxiliaryCalls += 1
                    return messages
                },
                nestedToolRunner: nil, approvalDecider: { _ in nil }
            ))
        }
        let preparing = await waitForCondition { gate.started }
        XCTAssertTrue(preparing)
        adapter.cancel()
        gate.release()
        _ = await task.value

        XCTAssertTrue(gate.observedCancellation)
        XCTAssertEqual(auxiliaryCalls, 0)
        XCTAssertEqual(provider.callCount, 0)
    }
}
