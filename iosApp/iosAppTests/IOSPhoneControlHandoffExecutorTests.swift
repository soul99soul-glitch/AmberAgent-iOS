import AmberPhoneControl
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSPhoneControlHandoffExecutorTests: XCTestCase {
    func testReturnToolUsesCurrentLeaseAndReportsUnknownWithoutRetry() async throws {
        for unknown in [false, true] {
            let harness = try await Harness(unknownMutation: unknown)
            defer { harness.dispose() }
            _ = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
            let outcome = await harness.executor.execute(name: "phone_return_to_amber", arguments: "{}", isUserInitiated: true)
            if unknown {
                guard case .outcomeUnknown(let parts) = outcome,
                      let text = parts.first as? UIMessagePart.Text else { return XCTFail("Lost activation receipt must remain unknown") }
                XCTAssertEqual(try object(text.text)["outcome"] as? String, "unknown")
                _ = await harness.executor.execute(name: "phone_return_to_amber", arguments: "{}", isUserInitiated: true)
            } else {
                guard case .filled(let text) = outcome else { return XCTFail("A current return tool lease must be allowed to return") }
                let fields = try object(text)
                XCTAssertEqual(fields["verified"] as? Bool, true)
                XCTAssertEqual(fields["observed_bundle_id"] as? String, Bundle.main.bundleIdentifier)
                XCTAssertEqual(fields["fresh_observation_available"] as? Bool, false)
            }
            XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
            await harness.controller.stop(runID: harness.runID)
        }
    }

    func testSystemToolCanObserveAndGoHomeWithoutPersistingSystemScope() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        _ = await harness.executor.execute(name: "phone_system", arguments: #"{"action":"observe"}"#, isUserInitiated: true)
        XCTAssertTrue(harness.controller.statusText(runID: harness.runID).contains("com.apple.springboard"))
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        let outcome = await harness.executor.execute(name: "phone_system", arguments: #"{"action":"home"}"#, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome else { return XCTFail("Home should return a receipt and the fresh system screen") }
        XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains("com.apple.springboard") })
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/homescreen"])
        XCTAssertEqual(harness.controller.selectedBundleIDs, ["app.test"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testHomeCanStartFromAmberWithoutSelectingAnUnrelatedApp() async throws {
        let harness = try await Harness(selectedBundleIDs: [])
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_system", arguments: #"{"action":"home"}"#, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome else { return XCTFail("A system-only task needs no installed-app selection") }
        XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains("com.apple.springboard") })
        XCTAssertTrue(harness.controller.selectedBundleIDs.isEmpty)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/homescreen"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testExplicitLockIsVerifiedAndCompletionKeepsPhoneLocked() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_system", arguments: #"{"action":"lock"}"#, isUserInitiated: true)
        guard case .filled(let text) = outcome else { return XCTFail("Lock should return state verification") }
        XCTAssertEqual(try object(text)["locked"] as? Bool, true)
        let stopped = await harness.executor.execute(name: "phone_stop", arguments: "{}", isUserInitiated: true)
        guard case .filled = stopped else { return XCTFail("Cleanup should succeed while preserving the lock") }
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/lock"])
    }

    func testStopReportsReturnReceiptRespectsLeaveAppAndPreservesUnknown() async throws {
        for mode in ["return", "leave", "unknown"] {
            let harness = try await Harness(unknownMutation: mode == "unknown")
            defer { harness.dispose() }
            IOSPhoneControlReturnPreference.set(true, harness.defaults)
            _ = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
            let arguments = mode == "leave" ? #"{"return_to_amber":false}"# : "{}"
            let outcome = await harness.executor.execute(name: "phone_stop", arguments: arguments, isUserInitiated: true)
            if mode == "unknown" {
                guard case .outcomeUnknown = outcome else { return XCTFail("Unknown return must reach the engine ledger") }
            } else {
                guard case .filled(let text) = outcome else { return XCTFail("Stop should retain cleanup and return receipts") }
                let fields = try object(text)
                XCTAssertEqual(fields["cleanup_complete"] as? Bool, true)
                if mode == "return" {
                    XCTAssertEqual((fields["return_to_amber"] as? [String: Any])?["verified"] as? Bool, true)
                } else { XCTAssertNil(fields["return_to_amber"]) }
            }
            XCTAssertEqual(harness.http.mutationPaths, mode == "leave" ? [] : ["/wda/apps/activate"])
            XCTAssertNil(harness.controller.ownerRunID)
        }
    }

    func testSuccessfulActionWithoutExpectationReturnsReceiptAndFreshTree() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        let initial = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .filledParts = initial else { return XCTFail("Initial observation must use the real runner") }
        let runner = try await harness.session.runner(runID: UUID())
        let beforeObservation = await runner.latestObservation
        let before = try XCTUnwrap(beforeObservation)

        let outcome = await harness.executor.execute(name: "phone_act", arguments: launchArguments,
                                                     isUserInitiated: true)
        guard case .filledParts(let parts) = outcome,
              let receiptText = parts.first as? UIMessagePart.Text else {
            return XCTFail("A completed action must retain its receipt and attach the fresh tree")
        }
        let receipt = try object(receiptText.text)
        XCTAssertEqual(receipt["outcome"] as? String, "completed")
        XCTAssertEqual(receipt["retry_safe"] as? Bool, false)
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true)
        XCTAssertNotNil(receipt["observation_id"] as? String)
        XCTAssertNil(receipt["verification"], "No expectation must not claim business verification")
        XCTAssertTrue(parts.dropFirst().compactMap { ($0 as? UIMessagePart.Text)?.text }
            .contains { $0.contains("screen-2") })
        XCTAssertEqual(harness.http.sourceCount, 2)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        let afterObservation = await runner.latestObservation
        let after = try XCTUnwrap(afterObservation)
        XCTAssertNotEqual(before.observationID, after.observationID)
        await harness.controller.stop(runID: harness.runID)
    }

    func testFailedPostActionReadKeepsAcknowledgedReceipt() async throws {
        let harness = try await Harness(firstSourceError: .cannotConnectToHost)
        defer { harness.dispose() }

        let outcome = await harness.executor.execute(name: "phone_act", arguments: launchArguments,
                                                     isUserInitiated: true)
        guard case .filled(let text) = outcome else {
            return XCTFail("A failed follow-up read must not hide the action receipt")
        }
        let receipt = try object(text)
        XCTAssertEqual(receipt["outcome"] as? String, "completed")
        XCTAssertEqual(receipt["retry_safe"] as? Bool, false)
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, false)
        XCTAssertFalse(try XCTUnwrap(receipt["observation_error"] as? String).isEmpty)
        XCTAssertNil(receipt["verification"])
        XCTAssertEqual(harness.http.sourceCount, 1)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testBatchingTwoKnownStepsRemovesOneProviderRoundWithTheSameActions() async throws {
        let full = try object(flowArguments)
        let steps = try XCTUnwrap(full["steps"] as? [[String: Any]])
        var first = full
        first["steps"] = [steps[0]]
        first["completion"] = steps[0]["expectation"]
        var second = full
        second["steps"] = [steps[1]]
        func call(_ input: [String: Any]) throws -> UIMessage {
            IOSChatForegroundFixtures.assistantMessage(parts: [UIMessagePart.Tool(
                toolCallId: UUID().uuidString, toolName: "phone_run_flow",
                input: String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self), output: [],
                approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)])
        }
        let split = try await Harness(flowMode: .completes)
        let batched = try await Harness(flowMode: .completes)
        defer { split.dispose(); batched.dispose() }
        let done = IOSChatForegroundFixtures.assistantText("done")
        let baseline = PhonePlanningProvider(script: [try call(first), try call(second), done])
        let combined = PhonePlanningProvider(script: [try call(full), done])
        for (harness, provider) in [(split, baseline), (batched, combined)] {
            let result = await phonePlanningEngine(harness: harness, provider: provider).run(
                providerSetting: IOSChatForegroundFixtures.makeProviderSetting(),
                messages: [IOSChatForegroundFixtures.userMessage("Advance the two known steps")],
                params: IOSPhoneAutomationRequestPolicyTests.params())
            XCTAssertFalse(result.hitStepLimit)
            XCTAssertNil(result.toolOutcomeUnknown)
            XCTAssertEqual(result.messages.last?.toText(), "done")
            let toolResults = result.messages.flatMap(\.parts).compactMap { $0 as? UIMessagePart.Tool }
            XCTAssertTrue(try toolResults.allSatisfy { tool in
                let text = try XCTUnwrap(tool.output.first as? UIMessagePart.Text)
                return try object(text.text)["status"] as? String == "completed"
            })
            await harness.controller.stop(runID: harness.runID)
        }
        XCTAssertEqual(baseline.uploads.count, 3, "Two decisions plus the final reply")
        XCTAssertEqual(combined.uploads.count, 2, "One Flow decision plus the final reply")
        XCTAssertEqual(split.http.mutationPaths, batched.http.mutationPaths)
        XCTAssertEqual(batched.http.mutationPaths, ["/elements", "/element/FRESH/click", "/elements", "/element/FRESH/click"])
        XCTAssertEqual(split.http.sourceCount, 4)
        XCTAssertEqual(batched.http.sourceCount, 3)
    }

    func testPhoneAutomaticReasoningStartsAfterRealObservationAndSurvivesEngineHandoff() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        let params = IOSPhoneAutomationRequestPolicyTests.params()
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let provider = PhonePlanningProvider(script: [phoneObservationCall(), IOSChatForegroundFixtures.assistantText("ready")])
        let ledger = IOSAgentToolEngineTests.RecordingLedger()
        let engine = phonePlanningEngine(harness: harness, provider: provider, ledger: ledger)
        let budgetInputs = PhoneBudgetRecorder()
        let result = await engine.run(
            providerSetting: providerSetting, messages: [IOSChatForegroundFixtures.userMessage("Read this exercise")], params: params,
            prepareRequestMessages: { messages in
                let policyCount = messages.filter(IOSPhoneAutomationRequestPolicy.isPlanningMessage).count
                await MainActor.run { budgetInputs.counts.append(policyCount) }
                return messages
            })
        XCTAssertEqual(provider.params.map(\.reasoningLevel), [.high, .low])
        XCTAssertTrue(harness.controller.hasRequestedSession(runID: harness.runID))
        XCTAssertEqual(budgetInputs.counts, [1, 1])
        XCTAssertTrue(provider.uploads.allSatisfy { $0.filter(IOSPhoneAutomationRequestPolicy.isPlanningMessage).count == 1 })
        XCTAssertFalse(result.messages.contains(where: IOSPhoneAutomationRequestPolicy.isPlanningMessage))
        let snapshots = await ledger.snapshots()
        XCTAssertEqual(snapshots.count, provider.params.count)
        for index in snapshots.indices {
            let expected = IOSRunRequestSnapshot.make(roundIndex: index + 1, providerSetting: providerSetting,
                messages: provider.uploads[index], params: provider.params[index])
            XCTAssertEqual(snapshots[index].generationParamsDigest, expected.generationParamsDigest)
            XCTAssertEqual(snapshots[index].requestDigest, expected.requestDigest)
        }

        // A fresh engine receives completed phone calls as history on handoff.
        // The same active owner, rather than historical text, retains the policy.
        let continued = PhonePlanningProvider(script: [IOSChatForegroundFixtures.assistantText("continued")])
        _ = await phonePlanningEngine(harness: harness, provider: continued).run(
            providerSetting: providerSetting, messages: result.messages, params: params)
        XCTAssertEqual(continued.params.map(\.reasoningLevel), [.low])
        XCTAssertEqual(params.reasoningLevel, .high)
        await harness.controller.stop(runID: harness.runID)

        let next = try await Harness()
        defer { next.dispose() }
        let ordinary = PhonePlanningProvider(script: [IOSChatForegroundFixtures.assistantText("ordinary")])
        _ = await phonePlanningEngine(harness: next, provider: ordinary).run(
            providerSetting: providerSetting, messages: result.messages + [IOSChatForegroundFixtures.userMessage("Explain a word")], params: params)
        XCTAssertEqual(ordinary.params.map(\.reasoningLevel), [.high], "Past phone results and a new claim do not lower ordinary chat")
        await next.controller.stop(runID: next.runID)
    }

    func testRevokedPhoneOwnerAndExplicitReasoningKeepOriginalEffort() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        _ = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        XCTAssertTrue(harness.controller.hasRequestedSession(runID: harness.runID))
        let providerSetting = IOSChatForegroundFixtures.makeProviderSetting()
        let params = IOSPhoneAutomationRequestPolicyTests.params()
        let explicit = PhonePlanningProvider(script: [IOSChatForegroundFixtures.assistantText("explicit")])
        _ = await phonePlanningEngine(harness: harness, provider: explicit, automatic: false).run(
            providerSetting: providerSetting, messages: [IOSChatForegroundFixtures.userMessage("continue")], params: params)
        XCTAssertEqual(explicit.params.map(\.reasoningLevel), [.high])
        harness.controller.revoke(runID: harness.runID)
        let revoked = PhonePlanningProvider(script: [IOSChatForegroundFixtures.assistantText("stopped")])
        _ = await phonePlanningEngine(harness: harness, provider: revoked).run(
            providerSetting: providerSetting, messages: [IOSChatForegroundFixtures.userMessage("continue")], params: params)
        XCTAssertEqual(revoked.params.map(\.reasoningLevel), [.high])
        await harness.controller.stop(runID: harness.runID)
    }

    private func phonePlanningEngine(
        harness: Harness, provider: PhonePlanningProvider,
        ledger: IOSAgentRunLedgering? = nil, automatic: Bool = true
    ) -> IOSAgentToolEngine {
        let controller = harness.controller
        return IOSAgentToolEngine(
            provider: provider, executors: ["phone_observe": harness.executor, "phone_run_flow": harness.executor], configuration: .init(maxSteps: 4),
            ledger: ledger, ledgerRunId: harness.runID, phoneAutomaticReasoning: automatic,
            phoneSessionIsActive: { runID in
                controller.handoffState(runID: runID) != nil && controller.hasRequestedSession(runID: runID)
            })
    }

    private func phoneObservationCall() -> UIMessage {
        IOSChatForegroundFixtures.assistantMessage(parts: [UIMessagePart.Tool(
            toolCallId: UUID().uuidString, toolName: "phone_observe", input: "{}", output: [],
            approvalState: ToolApprovalState.Auto.shared, streamIndex: nil, metadata: nil)])
    }

    private final class PhonePlanningProvider: IOSAgentTextProvider, @unchecked Sendable {
        var script: [UIMessage]
        private(set) var params: [TextGenerationParams] = []
        private(set) var uploads: [[UIMessage]] = []
        init(script: [UIMessage]) { self.script = script }
        func generateText(providerSetting: ProviderSetting, messages: [UIMessage], params: TextGenerationParams) async throws -> MessageChunk {
            self.params.append(params)
            uploads.append(messages)
            return IOSChatForegroundFixtures.chunk(with: script.removeFirst())
        }
    }

    @MainActor
    private final class PhoneBudgetRecorder {
        var counts: [Int] = []
    }

    func testTreeObservationDoesNotCaptureOrRecognizeScreenTextByDefault() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .filledParts(let parts) = outcome else { return XCTFail("Native observation must succeed without screenshot support") }
        XCTAssertTrue(parts.allSatisfy { $0 is UIMessagePart.Text })
        XCTAssertFalse(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains("screen_text") })
        XCTAssertFalse(harness.http.paths.contains("/screenshot"))
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
    }

    func testScreenTextOnlyUsesOneCapturedObservationWithoutSendingAnImage() async throws {
        let harness = try await Harness(screenshotPNG: makeTextScreenshot())
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(
            name: "phone_observe", arguments: #"{"include_screen_text":true}"#, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome else { return XCTFail("Explicit OCR must return native and recognized text evidence") }
        XCTAssertTrue(parts.allSatisfy { $0 is UIMessagePart.Text }, "OCR-only must not consume an image input slot")
        let objects = parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        let metadata = try XCTUnwrap(objects.first { $0["screenshot_observation_id"] != nil })
        let recognized = try XCTUnwrap(objects.first { $0["screen_text"] != nil }?["screen_text"] as? [String: Any])
        let screenshotID = try XCTUnwrap(metadata["screenshot_observation_id"] as? String)
        XCTAssertEqual(recognized["observation_id"] as? String, screenshotID)
        XCTAssertEqual(recognized["source"] as? String, "ocr")
        XCTAssertEqual(recognized["coordinate_space"] as? String, "screenshot_normalized_top_left")
        let items = try XCTUnwrap(recognized["items"] as? [[String: Any]])
        XCTAssertTrue(items.contains { ($0["text"] as? String)?.contains("Amber Search 42") == true }, "Recognize pixels from the fixture, rather than native tree labels")
        XCTAssertTrue(items.allSatisfy { $0["ref"] == nil })
        let runner = try await harness.session.runner(runID: UUID())
        let latest = await runner.latestObservation
        XCTAssertEqual(latest?.observationID, screenshotID)
        XCTAssertEqual(harness.http.paths.filter { $0 == "/screenshot" }.count, 1)
        XCTAssertEqual(harness.http.sourceCount, 1)
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
    }

    func testLongPressFreshLookupRunsOnceAndReturnsNewReferences() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        let initial = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        guard case .filledParts = initial else { return XCTFail("Initial observation must succeed") }
        let runner = try await harness.session.runner(runID: UUID())
        let previous = await runner.latestObservation
        let old = try XCTUnwrap(previous)
        let ref = try XCTUnwrap(old.nodes[1].ref)
        let outcome = await harness.executor.execute(
            name: "phone_act", arguments: #"{"action":"long_press","ref":"\#(ref)"}"#, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome,
              let receipt = parts.first as? UIMessagePart.Text else { return XCTFail("A completed long press must include fresh effect evidence") }
        let fields = try object(receipt.text)
        XCTAssertEqual(fields["outcome"] as? String, "completed")
        XCTAssertEqual(fields["retry_safe"] as? Bool, false)
        XCTAssertEqual(fields["fresh_observation_available"] as? Bool, true)
        let latest = await runner.latestObservation
        let fresh = try XCTUnwrap(latest)
        XCTAssertNotEqual(fresh.observationID, old.observationID)
        XCTAssertNotEqual(fresh.nodes[1].ref, ref)
        XCTAssertEqual(fresh.nodes[1].label, "screen-2")
        let freshRef = try XCTUnwrap(fresh.nodes[1].ref)
        XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains(freshRef) })
        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/wda/element/FRESH/touchAndHold"])
        XCTAssertEqual(harness.http.sourceCount, 2)
        XCTAssertEqual(harness.http.paths.filter { $0 == "/wda/settle" }.count, 1)
    }

    func testListCollectionUsesBoundedSwipeAndMergesOnlyAdjacentOverlap() async throws {
        for maxSwipes in [0, 1] {
            let harness = try await Harness(listPages: true)
            defer { harness.dispose() }
            let outcome = await harness.executor.execute(
                name: "phone_collect_list",
                arguments: #"{"container":{"identifier":"list"},"direction":"up","max_swipes":\#(maxSwipes)}"#,
                isUserInitiated: true)
            guard case .filledParts(let parts) = outcome,
                  let receipt = parts.first as? UIMessagePart.Text else { return XCTFail("Collection must return rows and its latest tree") }
            let fields = try object(receipt.text)
            XCTAssertEqual(fields["status"] as? String, "completed")
            XCTAssertEqual(fields["reason"] as? String, "swipe_budget_exhausted")
            XCTAssertEqual(fields["coverage"] as? String, "observed_screens_only")
            XCTAssertEqual(fields["screen_count"] as? Int, maxSwipes + 1)
            XCTAssertEqual(fields["swipe_count"] as? Int, maxSwipes)
            XCTAssertEqual(fields["outcome"] as? String, maxSwipes == 0 ? "not_sent" : "completed")
            XCTAssertEqual(fields["retry_safe"] as? Bool, maxSwipes == 0)
            let rows = try XCTUnwrap(fields["items"] as? [[String: Any]])
            let expected = maxSwipes == 0 ? ["A", "B"] : ["A", "B", "C"]
            XCTAssertEqual(rows.compactMap { $0["text"] as? String }, expected)
            XCTAssertEqual(rows.compactMap { $0["identifier"] as? String }, expected.map { "row-\($0)" })
            XCTAssertEqual(harness.http.sourceCount, maxSwipes + 1)
            XCTAssertEqual(harness.http.paths.filter { $0 == "/wda/settle" }.count, maxSwipes)
            XCTAssertEqual(harness.http.mutationPaths, maxSwipes == 0 ? [] : ["/elements", "/wda/element/FRESH/swipe"])
            XCTAssertFalse(harness.http.paths.contains("/screenshot"))
            let runner = try await harness.session.runner(runID: UUID())
            let fresh = await runner.latestObservation
            XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains(fresh?.observationID ?? "missing latest observation") })
            await harness.controller.stop(runID: harness.runID)
        }
    }

    func testOrderedFlowCompletesTwoVerifiedStepsAndReturnsLatestTree() async throws {
        let harness = try await Harness(flowMode: .completes)
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_run_flow", arguments: flowArguments, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome,
              let receipt = parts.first as? UIMessagePart.Text else { return XCTFail("A completed flow must return its verified receipt and latest tree") }
        let fields = try object(receipt.text)
        XCTAssertEqual(fields["status"] as? String, "completed")
        XCTAssertEqual(fields["outcome"] as? String, "completed")
        XCTAssertEqual(fields["retry_safe"] as? Bool, false)
        XCTAssertEqual(fields["goal_satisfied"] as? Bool, true)
        XCTAssertEqual(fields["fresh_observation_available"] as? Bool, true)
        let steps = try XCTUnwrap(fields["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.compactMap { $0["index"] as? Int }, [0, 1])
        XCTAssertEqual(steps.compactMap { $0["outcome"] as? String }, ["completed", "completed"])
        XCTAssertTrue(steps.allSatisfy { ($0["verification"] as? [String: Any])?["status"] as? String == "satisfied" })
        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/element/FRESH/click", "/elements", "/element/FRESH/click"])
        XCTAssertEqual(harness.http.sourceCount, 3, "Each following step must use the prior step's fresh verified tree")
        XCTAssertEqual(harness.http.paths.filter { $0 == "/wda/settle" }.count, 2)
        XCTAssertFalse(harness.http.paths.contains("/screenshot"))
        let runner = try await harness.session.runner(runID: UUID())
        let latest = await runner.latestObservation
        let fresh = try XCTUnwrap(latest)
        XCTAssertTrue(fresh.nodes.contains { $0.identifier == "done" })
        XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains(fresh.observationID) })
    }

    func testAcknowledgedFlowStepWithUnmetPostconditionRequiresReplanBeforeNextStep() async throws {
        let harness = try await Harness(screenshotPNG: makeTextScreenshot(), flowMode: .unmetAfterFirstStep)
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_run_flow", arguments: flowArguments, isUserInitiated: true)
        guard case .replanRequired(let parts) = outcome,
              let receipt = parts.first as? UIMessagePart.Text else { return XCTFail("Failed postconditions must create a typed replan barrier") }
        let fields = try object(receipt.text)
        XCTAssertEqual(fields["status"] as? String, "handback")
        XCTAssertEqual(fields["reason_code"] as? String, "step_verification_failed: target_not_visible")
        XCTAssertEqual(fields["outcome"] as? String, "completed", "A failed business condition cannot erase the first action's acknowledged receipt")
        XCTAssertEqual(fields["retry_safe"] as? Bool, false)
        XCTAssertEqual(fields["goal_satisfied"] as? Bool, false)
        let steps = try XCTUnwrap(fields["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?["outcome"] as? String, "completed")
        XCTAssertEqual((steps.first?["verification"] as? [String: Any])?["status"] as? String, "unmet")
        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/element/FRESH/click"])
        XCTAssertGreaterThanOrEqual(harness.http.sourceCount, 2)
        XCTAssertLessThanOrEqual(harness.http.sourceCount, 5, "Read-only postcondition checks must stay bounded")
    }

    func testHumanTakeoverStopsOriginalFlowAndPreservesAcknowledgedStepReceipt() async throws {
        let gate = HandoffReplyGate()
        let paused = expectation(description: "Flow receipt acknowledges the requested pause")
        let harness = try await Harness(postGate: gate, flowMode: .completes, onHandoff: { _, state in
            if state == .paused { paused.fulfill() }
        })
        defer { harness.dispose(); gate.release() }
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_run_flow", arguments: flowArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .pausing)
        gate.release()
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertNil(execution.outcome)
        XCTAssertEqual(harness.http.sourceCount, 1, "Paused flow must not read or dispatch its remaining steps")
        try harness.controller.resumeAutomation(runID: harness.runID)
        await fulfillment(of: [execution.finished], timeout: 2)
        let receipt = try handback(XCTUnwrap(execution.outcome))
        let prior = try XCTUnwrap(receipt["prior_tool_receipt"] as? [String: Any])
        XCTAssertEqual(prior["kind"] as? String, "filled")
        let original = try object(XCTUnwrap(prior["result"] as? String))
        XCTAssertEqual(original["outcome"] as? String, "completed")
        XCTAssertEqual(original["retry_safe"] as? Bool, false)
        let acknowledged = try XCTUnwrap(original["steps"] as? [[String: Any]])
        XCTAssertEqual(acknowledged.count, 1)
        XCTAssertEqual(acknowledged.first?["index"] as? Int, 0)
        XCTAssertEqual(acknowledged.first?["outcome"] as? String, "completed")
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.http.sourceCount, 2, "Resume returns new evidence without continuing the old flow")
        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/element/FRESH/click"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testUnknownFlowStepDoesNotObserveReplayOrDispatchNextStep() async throws {
        let harness = try await Harness(unknownMutation: true, flowMode: .completes)
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_run_flow", arguments: flowArguments, isUserInitiated: true)
        guard case .outcomeUnknown(let parts) = outcome,
              let receipt = parts.first as? UIMessagePart.Text else { return XCTFail("Dispatched flow uncertainty must remain a typed unknown") }
        let fields = try object(receipt.text)
        XCTAssertEqual(fields["outcome"] as? String, "unknown")
        XCTAssertEqual(fields["retry_safe"] as? Bool, false)
        let steps = try XCTUnwrap(fields["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?["outcome"] as? String, "unknown")
        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/element/FRESH/click"])
        XCTAssertEqual(harness.http.sourceCount, 1)
        XCTAssertFalse(harness.http.paths.contains("/wda/settle"))
        XCTAssertFalse(harness.http.paths.contains("/screenshot"))
    }

    func testAcknowledgedActionReturnsFreshReferencesWithoutAnotherModelRound() async throws {
        let harness = try await Harness()
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_act", arguments: launchArguments, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome,
              let receipt = parts.first as? UIMessagePart.Text else { return XCTFail("Action must return its receipt and fresh tree") }
        let fields = try object(receipt.text)
        XCTAssertEqual(fields["outcome"] as? String, "completed")
        XCTAssertEqual(fields["retry_safe"] as? Bool, false)
        XCTAssertEqual(fields["fresh_observation_available"] as? Bool, true)
        XCTAssertTrue(parts.compactMap { ($0 as? UIMessagePart.Text)?.text }.contains { $0.contains("screen-1") })
        XCTAssertEqual(fields["visual_actions_available"] as? Bool, false)
        XCTAssertFalse(parts.contains { $0 is UIMessagePart.Image })
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        XCTAssertEqual(harness.http.sourceCount, 1)
        XCTAssertEqual(harness.http.paths.filter { $0 == "/wda/settle" }.count, 1)
    }

    func testReadFailureAfterActionKeepsCompletedReceiptAndDoesNotReplay() async throws {
        let harness = try await Harness(firstSourceError: .networkConnectionLost)
        defer { harness.dispose() }
        let outcome = await harness.executor.execute(name: "phone_act", arguments: launchArguments, isUserInitiated: true)
        guard case .filled(let text) = outcome else { return XCTFail("An acknowledged action must survive a failed effect read") }
        let fields = try object(text)
        XCTAssertEqual(fields["outcome"] as? String, "completed")
        XCTAssertEqual(fields["retry_safe"] as? Bool, false)
        XCTAssertEqual(fields["fresh_observation_available"] as? Bool, false)
        XCTAssertNotNil(fields["observation_error"])
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        XCTAssertEqual(harness.http.sourceCount, 1)
    }

    func testIdleTakeoverThenResumeReplacesLateTapCoordinatesAndGoalWithFreshEvidence() async throws {
        for kind in ["tap", "tap_point", "goal", "sequence"] {
            let harness = try await Harness()
            defer { harness.dispose() }
            let initial = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
            guard case .filledParts = initial else { return XCTFail("Initial observation must use the real runner") }
            let runner = try await harness.session.runner(runID: UUID())
            let oldObservation = await runner.latestObservation
            let old = try XCTUnwrap(oldObservation)
            let arguments: String
            let name: String
            switch kind {
            case "tap":
                name = "phone_act"
                arguments = #"{"action":"tap","ref":"\#(try XCTUnwrap(old.nodes[1].ref))"}"#
            case "tap_point":
                name = "phone_act"
                arguments = #"{"action":"tap_point","observation_id":"\#(old.observationID)","x":0.5,"y":0.5}"#
            case "sequence":
                name = "phone_run_goal"
                arguments = #"{"goal":"Open the item","bundle_id":"app.test","steps":[{"page_anchor":{"label":"screen-1"},"actions":[{"action":"tap","target":{"identifier":"item"}}],"expectation":{"kind":"visible","target":{"identifier":"done"}}}],"completion":{"kind":"visible","target":{"identifier":"done"}}}"#
            default:
                name = "phone_run_goal"
                arguments = #"{"goal":"Open the item","bundle_id":"app.test","actions":[{"action":"tap","target":{"identifier":"item"}}],"completion":{"kind":"visible","target":{"identifier":"done"}}}"#
            }
            try harness.controller.requestHumanTakeover(runID: harness.runID)
            XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
            try harness.controller.resumeAutomation(runID: harness.runID)
            let outcome = await harness.executor.execute(name: name, arguments: arguments, isUserInitiated: true)
            let receipt = try handback(outcome)
            XCTAssertEqual(receipt["outcome"] as? String, "not_sent", kind)
            XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true, kind)
            XCTAssertNil(receipt["prior_tool_receipt"], kind)
            let freshObservation = await runner.latestObservation
            let fresh = try XCTUnwrap(freshObservation)
            XCTAssertNotEqual(fresh.observationID, old.observationID, kind)
            XCTAssertEqual(fresh.nodes[1].label, "screen-2", kind)
            XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .automated)
            XCTAssertEqual(harness.http.sourceCount, 2)
            XCTAssertTrue(harness.http.mutationPaths.isEmpty, "The late \(kind) request must never dispatch")
            await harness.controller.stop(runID: harness.runID)
        }
    }

    func testTakeoverDuringMutationWaitsForReceiptThenPreservesItAndObservesAfterResume() async throws {
        let gate = HandoffReplyGate()
        let paused = expectation(description: "Receipt ends the tool and acknowledges pause")
        let harness = try await Harness(postGate: gate, onHandoff: { _, state in
            if state == .paused { paused.fulfill() }
        })
        defer { harness.dispose(); gate.release() }
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .pausing)
        XCTAssertThrowsError(try harness.controller.resumeAutomation(runID: harness.runID))
        XCTAssertNil(execution.outcome)
        XCTAssertEqual(harness.http.sourceCount, 0)
        gate.release()
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        XCTAssertNil(execution.outcome, "The receipt must not resume automation on its own")
        try harness.controller.resumeAutomation(runID: harness.runID)
        await fulfillment(of: [execution.finished], timeout: 2)
        let receipt = try handback(XCTUnwrap(execution.outcome))
        let prior = try XCTUnwrap(receipt["prior_tool_receipt"] as? [String: Any])
        XCTAssertEqual(prior["kind"] as? String, "filled")
        let original = try object(XCTUnwrap(prior["result"] as? String))
        XCTAssertEqual(original["outcome"] as? String, "completed")
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        XCTAssertEqual(harness.http.sourceCount, 1)
        let startCount = await harness.session.startCount
        XCTAssertEqual(startCount, 1, "Resume must reuse the owner session")
        await harness.controller.stop(runID: harness.runID)
    }

    func testTakeoverDuringTypingDoesNotDismissKeyboardAfterReceipt() async throws {
        let gate = HandoffReplyGate()
        let paused = expectation(description: "Typing receipt acknowledges human takeover")
        let harness = try await Harness(postGate: gate, textInput: true, onHandoff: { _, state in
            if state == .paused { paused.fulfill() }
        })
        defer { harness.dispose(); gate.release() }
        _ = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        let runner = try await harness.session.runner(runID: UUID())
        let observed = await runner.latestObservation
        let ref = try XCTUnwrap(observed?.nodes.first { $0.type == "XCUIElementTypeTextField" }?.ref)
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act",
                                   arguments: #"{"action":"type","ref":"\#(ref)","text":"hello"}"#)
        defer { task.cancel() }

        await fulfillment(of: [gate.started], timeout: 2)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .pausing)
        gate.release()
        await fulfillment(of: [paused], timeout: 2)

        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/element/FRESH/value"],
                       "An acknowledged type must not dispatch a second mutation after takeover")
        XCTAssertEqual(harness.http.sourceCount, 1, "The paused tool must wait before reading again")
        XCTAssertNil(execution.outcome)
        try harness.controller.resumeAutomation(runID: harness.runID)
        await fulfillment(of: [execution.finished], timeout: 2)
        let receipt = try handback(XCTUnwrap(execution.outcome))
        let prior = try XCTUnwrap(receipt["prior_tool_receipt"] as? [String: Any])
        let original = try object(XCTUnwrap(prior["result"] as? String))
        XCTAssertEqual(original["outcome"] as? String, "completed", "The typed text receipt must be preserved")
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.http.mutationPaths, ["/elements", "/element/FRESH/value"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testSuccessfulTypingStillDismissesKeyboardAndReturnsFreshTree() async throws {
        let harness = try await Harness(textInput: true)
        defer { harness.dispose() }
        _ = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
        let runner = try await harness.session.runner(runID: UUID())
        let observed = await runner.latestObservation
        let ref = try XCTUnwrap(observed?.nodes.first { $0.type == "XCUIElementTypeTextField" }?.ref)

        let outcome = await harness.executor.execute(name: "phone_act",
            arguments: #"{"action":"type","ref":"\#(ref)","text":"hello"}"#, isUserInitiated: true)
        guard case .filledParts(let parts) = outcome,
              let text = parts.first as? UIMessagePart.Text else {
            return XCTFail("Typing must retain its receipt and attach a fresh tree")
        }
        let receipt = try object(text.text)
        XCTAssertEqual(receipt["outcome"] as? String, "completed")
        XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.http.mutationPaths,
                       ["/elements", "/element/FRESH/value", "/wda/keyboard/dismiss"])
        XCTAssertEqual(harness.http.sourceCount, 2)
        await harness.controller.stop(runID: harness.runID)
    }

    func testUnknownMutationReceiptOverridesRequestedPauseWithoutWaitingOrObserving() async throws {
        let gate = HandoffReplyGate()
        var handoffStates: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(postGate: gate, unknownMutation: true,
                                       onHandoff: { _, state in handoffStates.append(state) })
        defer { harness.dispose(); gate.release() }
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        gate.release()
        await fulfillment(of: [execution.finished], timeout: 2)
        guard case .outcomeUnknown(let parts) = try XCTUnwrap(execution.outcome),
              let text = parts.first as? UIMessagePart.Text else {
            return XCTFail("Dispatched uncertainty must reach the real engine outcome")
        }
        let receipt = try object(text.text)
        XCTAssertEqual(receipt["outcome"] as? String, "unknown")
        XCTAssertEqual(receipt["runner_code"] as? String, "unknown error")
        XCTAssertEqual(receipt["retry_safe"] as? Bool, false)
        XCTAssertEqual(handoffStates, [.pausing])
        XCTAssertNil(harness.controller.handoffState(runID: harness.runID))
        XCTAssertThrowsError(try harness.controller.resumeAutomation(runID: harness.runID))
        XCTAssertEqual(harness.http.sourceCount, 0)
        XCTAssertEqual(harness.http.mutationPaths, ["/wda/apps/activate"])
        await harness.controller.stop(runID: harness.runID)
    }

    func testStopOrTaskCancellationReleasesPausedToolWithoutStartingRunner() async throws {
        for stopsRun in [true, false] {
            let harness = try await Harness()
            defer { harness.dispose() }
            try harness.controller.requestHumanTakeover(runID: harness.runID)
            let execution = PendingExecution()
            let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
            defer { task.cancel() }
            // This task runs on MainActor through lease creation into the first
            // suspended resume wait before this test can regain the actor.
            await fulfillment(of: [execution.started], timeout: 2)
            XCTAssertNil(execution.outcome)
            XCTAssertTrue(harness.http.paths.isEmpty)
            if stopsRun { await harness.controller.stop(runID: harness.runID) }
            else { task.cancel() }
            await fulfillment(of: [execution.finished], timeout: 2)
            let receipt = try handback(XCTUnwrap(execution.outcome))
            XCTAssertEqual(receipt["outcome"] as? String, "not_sent")
            XCTAssertEqual(receipt["fresh_observation_available"] as? Bool, false)
            XCTAssertNotNil(receipt["resume_error"])
            XCTAssertTrue(harness.http.paths.isEmpty)
            let starts = await harness.session.startCount
            XCTAssertEqual(starts, 0)
            if stopsRun { XCTAssertNil(harness.controller.ownerRunID) }
            else {
                // Cancelling the wait must release its slot, rather than denying
                // every subsequent tool as busy for this still-valid owner.
                try harness.controller.resumeAutomation(runID: harness.runID)
                let followup = await harness.executor.execute(name: "phone_observe", arguments: "{}", isUserInitiated: true)
                XCTAssertEqual(try handback(followup)["fresh_observation_available"] as? Bool, true)
                await harness.controller.stop(runID: harness.runID)
            }
        }
    }

    func testSecondTakeoverDuringResumeObservationCannotBeConsumedByOlderGeneration() async throws {
        let gate = HandoffReplyGate()
        var handoffStates: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(sourceGate: gate, onHandoff: { _, state in handoffStates.append(state) })
        defer { harness.dispose(); gate.release() }
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        try harness.controller.resumeAutomation(runID: harness.runID)
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .resuming)
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        gate.release()
        let runner = try await harness.session.runner(runID: UUID())
        // Wait for publication of the first tree, using actor reads rather than
        // a wall-clock delay. Publication occurs after all observation requests.
        var first: PhoneObservation?
        for _ in 0..<500 {
            first = await runner.latestObservation
            if first != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.nodes[1].label, "screen-1")
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        XCTAssertNil(execution.outcome)
        try harness.controller.resumeAutomation(runID: harness.runID)
        await fulfillment(of: [execution.finished], timeout: 2)
        XCTAssertEqual(try handback(XCTUnwrap(execution.outcome))["fresh_observation_available"] as? Bool, true)
        let fresh = await runner.latestObservation
        XCTAssertEqual(fresh?.nodes[1].label, "screen-2")
        XCTAssertNotEqual(fresh?.observationID, first?.observationID)
        XCTAssertEqual(harness.http.sourceCount, 2)
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        XCTAssertEqual(handoffStates, [.paused, .resuming, .paused, .resuming, .automated])
        await harness.controller.stop(runID: harness.runID)
    }

    func testFailedResumeSourcePausesAndRequiresUserResumeBeforeAnotherRead() async throws {
        var states: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(firstSourceError: .cannotConnectToHost,
                                       onHandoff: { _, state in states.append(state) })
        defer { harness.dispose() }
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        try harness.controller.resumeAutomation(runID: harness.runID)
        let failed = await harness.executor.execute(name: "phone_act", arguments: launchArguments, isUserInitiated: true)
        XCTAssertEqual(try handback(failed)["fresh_observation_available"] as? Bool, false)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .paused)
        let reason = try XCTUnwrap(harness.controller.handoffFailure(runID: harness.runID))
        XCTAssertTrue(reason.contains("重新读取界面失败"))
        XCTAssertTrue(harness.controller.statusText(runID: harness.runID).contains(reason))
        XCTAssertEqual(harness.http.sourceCount, 1)
        XCTAssertFalse(harness.controller.canDispatchAction(runID: harness.runID))

        let pending = PendingExecution()
        let task = pending.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [pending.started], timeout: 2)
        XCTAssertNil(pending.outcome)
        XCTAssertEqual(harness.http.sourceCount, 1, "A new model tool must not implicitly retry the failed read")
        let status = await harness.executor.execute(name: "phone_status", arguments: "{}", isUserInitiated: true)
        guard case .filled(let statusText) = status else { return XCTFail("Status remains available while paused") }
        XCTAssertTrue(statusText.contains(reason))
        XCTAssertEqual(harness.http.sourceCount, 1)
        try harness.controller.resumeAutomation(runID: harness.runID)
        XCTAssertNil(harness.controller.handoffFailure(runID: harness.runID))
        await fulfillment(of: [pending.finished], timeout: 2)
        XCTAssertEqual(try handback(XCTUnwrap(pending.outcome))["fresh_observation_available"] as? Bool, true)
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .automated)
        XCTAssertEqual(harness.http.sourceCount, 2)
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        XCTAssertEqual(states, [.paused, .resuming, .paused, .resuming, .automated])
        await harness.controller.stop(runID: harness.runID)
    }

    func testCancellationDuringResumeReadDoesNotRecordFailureOrChangeHandoffState() async throws {
        let gate = HandoffReplyGate()
        var states: [IOSPhoneControlHandoffState] = []
        let harness = try await Harness(sourceGate: gate, onHandoff: { _, state in states.append(state) })
        defer { harness.dispose(); gate.release() }
        try harness.controller.requestHumanTakeover(runID: harness.runID)
        try harness.controller.resumeAutomation(runID: harness.runID)
        let execution = PendingExecution()
        let task = execution.start(executor: harness.executor, name: "phone_act", arguments: launchArguments)
        defer { task.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        task.cancel()
        gate.release()
        await fulfillment(of: [execution.finished], timeout: 2)
        XCTAssertEqual(try handback(XCTUnwrap(execution.outcome))["fresh_observation_available"] as? Bool, false)
        XCTAssertNil(harness.controller.handoffFailure(runID: harness.runID))
        XCTAssertEqual(harness.controller.handoffState(runID: harness.runID), .resuming)
        XCTAssertEqual(states, [.paused, .resuming])
        XCTAssertTrue(harness.http.mutationPaths.isEmpty)
        await harness.controller.stop(runID: harness.runID)
    }

    private var launchArguments: String { #"{"action":"launch","bundle_id":"app.test"}"# }

    private var flowArguments: String {
        #"{"goal":"Advance two ordered steps","bundle_id":"app.test","steps":[{"operation":{"action":"tap","target":{"identifier":"item"}},"expectation":{"kind":"visible","target":{"identifier":"stage-1"}}},{"operation":{"action":"tap","target":{"identifier":"item"}},"expectation":{"kind":"visible","target":{"identifier":"done"}}}],"completion":{"kind":"visible","target":{"identifier":"done"}}}"#
    }

    private func makeTextScreenshot() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 402, height: 874, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 402, height: 874))
        let font = CTFontCreateWithName("Helvetica" as CFString, 32, nil)
        let text = NSAttributedString(string: "Amber Search 42", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 50, y: 650)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func handback(_ outcome: IOSAgentToolOutcome) throws -> [String: Any] {
        let text: String
        switch outcome {
        case .replanRequired(let parts): text = try XCTUnwrap(parts.first as? UIMessagePart.Text).text
        default: throw NSError(domain: "Expected real executor handback", code: 1)
        }
        let receipt = try object(text)
        XCTAssertEqual(receipt["status"] as? String, "handback")
        XCTAssertEqual(receipt["reason_code"] as? String, "human_intervened")
        XCTAssertEqual(receipt["retry_safe"] as? Bool, false)
        return receipt
    }

    @MainActor
    private final class PendingExecution {
        let started = XCTestExpectation(description: "Tool task entered executor")
        let finished = XCTestExpectation(description: "Real executor returned")
        var outcome: IOSAgentToolOutcome?

        func start(executor: IOSPhoneControlToolExecutor, name: String, arguments: String) -> Task<Void, Never> {
            Task { [self] in
                started.fulfill()
                outcome = await executor.execute(name: name, arguments: arguments, isUserInitiated: true)
                finished.fulfill()
            }
        }
    }

    @MainActor
    private final class Harness {
        let runID: String
        let suite: String
        let defaults: UserDefaults
        let http: HandoffHTTPFixture
        let session: HandoffSessionStub
        let controller: IOSPhoneControlController
        let executor: IOSPhoneControlToolExecutor

        init(postGate: HandoffReplyGate? = nil, sourceGate: HandoffReplyGate? = nil,
             unknownMutation: Bool = false, firstSourceError: URLError.Code? = nil,
             listPages: Bool = false, screenshotPNG: Data? = nil, textInput: Bool = false,
             flowMode: HandoffFlowMode? = nil, selectedBundleIDs: Set<String> = ["app.test"],
             onHandoff: @escaping @MainActor (String, IOSPhoneControlHandoffState) -> Void = { _, _ in }) async throws {
            let runID = "handoff-\(UUID().uuidString)"
            let suite = "IOSPhoneControlHandoffExecutorTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let http = HandoffHTTPFixture(postGate: postGate, sourceGate: sourceGate,
                                          unknownMutation: unknownMutation, firstSourceError: firstSourceError,
                                          listPages: listPages, screenshotPNG: screenshotPNG, textInput: textInput,
                                          flowMode: flowMode)
            let session = HandoffSessionStub(fixture: http)
            let key = Curve25519.Signing.PrivateKey()
            let pairing = try PropertyListSerialization.data(fromPropertyList: [
                "public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation,
                "identifier": UUID().uuidString,
            ], format: .binary, options: 0)
            let controller = IOSPhoneControlController(defaults: defaults, credentials: HandoffPairingStore(data: pairing),
                session: session, localTunnel: PhoneControlTunnelStub(), onReturnToConversation: { _, _ in }, onHandoffChange: onHandoff)
            self.runID = runID
            self.suite = suite
            self.defaults = defaults
            self.http = http
            self.session = session
            self.controller = controller
            executor = IOSPhoneControlToolExecutor(runID: runID, controller: controller, reportActivity: { _ in })
            await controller.refreshPreparation()
            controller.enabled = true
            controller.selectedBundleIDs = selectedBundleIDs
            XCTAssertTrue(controller.claim(runID: runID, onStop: {}))
        }

        func dispose() {
            http.unregister()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private actor HandoffPairingStore: IOSPhoneControlCredentialStoring {
    let data: Data
    init(data: Data) { self.data = data }
    func loadPairing() -> Data? { data }
    func savePairing(_ data: Data) {}
    func deletePairing() {}
}

private actor HandoffSessionStub: IOSPhoneControlSessionServing {
    let fixture: HandoffHTTPFixture
    private var client: PhoneRunnerClient?
    private(set) var startCount = 0
    init(fixture: HandoffHTTPFixture) { self.fixture = fixture }
    func start(runID: UUID, configuration: PhoneControlLaunchConfiguration) async throws -> PhoneRunnerStatus {
        startCount += 1
        let http = URLSessionConfiguration.ephemeral
        http.protocolClasses = [HandoffHTTPProtocol.self]
        let runner = try PhoneRunnerClient(token: String(repeating: "a", count: 64),
            allowedBundleIDs: configuration.allowedBundleIDs, port: fixture.port, sessionConfiguration: http)
        client = runner
        return try await runner.status()
    }
    func runner(runID: UUID) throws -> PhoneRunnerClient { try XCTUnwrap(client) }
    func stop(runID: UUID) async { await client?.stop() }
    func launchStatus(runID: UUID) -> PhoneControlLaunchStatus? { nil }
    func cachedApplications(runID: UUID) -> [PhoneControlInstalledApp] { [] }
}

private enum HandoffFlowMode {
    case completes, unmetAfterFirstStep
}

private final class HandoffHTTPFixture: @unchecked Sendable {
    let port: UInt16
    private let postGate: HandoffReplyGate?
    private let sourceGate: HandoffReplyGate?
    private let unknownMutation: Bool
    private let firstSourceError: URLError.Code?
    private let listPages: Bool
    private let screenshotPNG: Data?
    private let textInput: Bool
    private let flowMode: HandoffFlowMode?
    private let lock = NSLock()
    private var requests: [(String, String)] = []
    private var sources = 0
    private var clicks = 0
    private var activeBundleID = "app.test"
    private var locked = false
    var paths: [String] { lock.withLock { requests.map { $0.1 } } }
    var mutationPaths: [String] { lock.withLock { requests.filter { $0.0 == "POST" }.map { $0.1 } } }
    var sourceCount: Int { lock.withLock { sources } }

    init(postGate: HandoffReplyGate?, sourceGate: HandoffReplyGate?, unknownMutation: Bool,
         firstSourceError: URLError.Code?, listPages: Bool, screenshotPNG: Data?, textInput: Bool,
         flowMode: HandoffFlowMode?) {
        self.postGate = postGate
        self.sourceGate = sourceGate
        self.unknownMutation = unknownMutation
        self.firstSourceError = firstSourceError
        self.listPages = listPages
        self.screenshotPNG = screenshotPNG
        self.textInput = textInput
        self.flowMode = flowMode
        port = HandoffHTTPProtocol.nextPort()
        HandoffHTTPProtocol.register(self)
    }
    func unregister() { HandoffHTTPProtocol.remove(port) }

    func reply(_ request: URLRequest) throws -> (String, HandoffReplyGate?) {
        let path = try XCTUnwrap(request.url?.path)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("IPU-HMAC-SHA256 ") == true)
        let sourceIndex = lock.withLock {
            requests.append((request.httpMethod ?? "", path))
            if path == "/source" { sources += 1 }
            return sources
        }
        switch path {
        case "/status": return (#"{"value":{"ready":true,"sessionId":"handoff","auth":{"required":true,"scheme":"IPU-HMAC-SHA256"}}}"#, nil)
        case "/wda/activeAppInfo":
            let bundle = lock.withLock { activeBundleID }
            return (#"{"value":{"bundleId":"\#(bundle)","pid":42}}"#, nil)
        case "/window/size": return (#"{"value":{"width":402,"height":874}}"#, nil)
        case "/wda/settle": return (#"{"value":{"stable":true,"blank":false,"waited_ms":160,"frames":4,"changed_px":0,"capture_ms":2,"budget_ms":700}}"#, nil)
        case "/source":
            if sourceIndex == 1, let firstSourceError { throw URLError(firstSourceError) }
            if listPages { return (try listSource(index: sourceIndex), nil) }
            if let flowMode { return (try flowSource(mode: flowMode), nil) }
            let nodeType = textInput ? "XCUIElementTypeTextField" : "XCUIElementTypeButton"
            let body = #"{"value":{"type":"XCUIElementTypeApplication","rect":{"x":0,"y":0,"width":402,"height":874},"children":[{"type":"\#(nodeType)","rawIdentifier":"item","label":"screen-\#(sourceIndex)","rect":{"x":20,"y":100,"width":80,"height":44},"children":[]}]}}"#
            return (body, sourceIndex == 1 ? sourceGate : nil)
        case "/elements":
            XCTAssertEqual(request.httpMethod, "POST")
            let fields = try requestObject(request)
            XCTAssertEqual(fields["using"] as? String, "predicate string")
            XCTAssertTrue((fields["value"] as? String)?.contains(listPages ? "list" : "item") == true)
            return (#"{"value":[{"element-6066-11e4-a52e-4f735466cecf":"FRESH"}]}"#, nil)
        case "/wda/element/FRESH/touchAndHold":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try requestObject(request)["duration"] as? Double, 0.75)
            return (#"{"value":null}"#, nil)
        case "/element/FRESH/click":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(flowMode)
            lock.withLock { clicks += 1 }
            return (unknownMutation ? #"{"value":{"error":"unknown error","message":"tap receipt lost"}}"# : #"{"value":null}"#, postGate)
        case "/wda/element/FRESH/swipe":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try requestObject(request)["direction"] as? String, "up")
            return (#"{"value":null}"#, nil)
        case "/screenshot":
            let data = try XCTUnwrap(screenshotPNG, "Only explicit screenshot/OCR tests supply image support")
            return (#"{"value":"\#(data.base64EncodedString())"}"#, nil)
        case "/wda/locked":
            let state = lock.withLock { locked }
            return (#"{"value":\#(state ? "true" : "false")}"#, nil)
        case "/wda/lock", "/wda/unlock":
            XCTAssertEqual(request.httpMethod, "POST")
            lock.withLock { locked = path == "/wda/lock" }
            return (#"{"value":null}"#, nil)
        case "/wda/homescreen":
            XCTAssertEqual(request.httpMethod, "POST")
            lock.withLock { activeBundleID = "com.apple.springboard" }
            return (#"{"value":null}"#, nil)
        case "/wda/apps/activate":
            XCTAssertEqual(request.httpMethod, "POST")
            let bundle = try XCTUnwrap(try requestObject(request)["bundleId"] as? String)
            if !unknownMutation { lock.withLock { activeBundleID = bundle } }
            return (unknownMutation ? #"{"value":{"error":"unknown error","message":"activation receipt lost"}}"# : #"{"value":null}"#, postGate)
        case "/element/FRESH/value":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(textInput)
            XCTAssertEqual(try requestObject(request)["text"] as? String, "hello")
            return (#"{"value":null}"#, postGate)
        case "/wda/keyboard/dismiss":
            XCTAssertEqual(request.httpMethod, "POST")
            return (#"{"value":null}"#, nil)
        default:
            XCTFail("Unexpected runner request \(path)")
            throw URLError(.badURL)
        }
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func listSource(index: Int) throws -> String {
        let labels = index == 1 ? ["A", "B"] : ["B", "C"]
        let rows: [[String: Any]] = labels.enumerated().map { offset, label in
            ["type": "XCUIElementTypeCell", "rawIdentifier": "row-\(label)", "label": label,
             "rect": ["x": 20, "y": 140 + offset * 80, "width": 320, "height": 60], "children": []]
        }
        let source: [String: Any] = ["value": [
            "type": "XCUIElementTypeApplication", "rect": ["x": 0, "y": 0, "width": 402, "height": 874],
            "children": [["type": "XCUIElementTypeScrollView", "rawIdentifier": "list",
                          "rect": ["x": 10, "y": 100, "width": 380, "height": 600], "children": rows]],
        ]]
        return String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
    }

    private func flowSource(mode: HandoffFlowMode) throws -> String {
        let count = lock.withLock { clicks }
        var children: [[String: Any]] = [
            ["type": "XCUIElementTypeButton", "rawIdentifier": "item", "label": "Advance",
             "rect": ["x": 20, "y": 100, "width": 120, "height": 44], "children": []],
        ]
        if mode == .completes, count >= 1 {
            children.append(["type": "XCUIElementTypeStaticText", "rawIdentifier": "stage-1", "label": "First step complete",
                             "rect": ["x": 20, "y": 180, "width": 300, "height": 44], "children": []])
        }
        if mode == .completes, count >= 2 {
            children.append(["type": "XCUIElementTypeStaticText", "rawIdentifier": "done", "label": "Finished",
                             "rect": ["x": 20, "y": 250, "width": 300, "height": 44], "children": []])
        }
        let source: [String: Any] = ["value": [
            "type": "XCUIElementTypeApplication", "rect": ["x": 0, "y": 0, "width": 402, "height": 874], "children": children,
        ]]
        return String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self)
    }
}

private final class HandoffReplyGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Runner request awaits its real response")
    private let lock = NSLock()
    private var send: (@Sendable () -> Void)?
    func enqueue(_ send: @escaping @Sendable () -> Void) {
        lock.withLock { self.send = send }
        started.fulfill()
    }
    func release() {
        let reply = lock.withLock { let reply = send; send = nil; return reply }
        reply?()
    }
}

private final class HandoffHTTPProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var port: UInt16 = 36_000
        var fixtures: [UInt16: HandoffHTTPFixture] = [:]
    }
    private static let registry = Registry()
    static func nextPort() -> UInt16 { registry.lock.withLock { registry.port += 1; return registry.port } }
    static func register(_ fixture: HandoffHTTPFixture) { registry.lock.withLock { registry.fixtures[fixture.port] = fixture } }
    static func remove(_ port: UInt16) { _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: port) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.registry.lock.withLock({ request.url?.port.flatMap { Self.registry.fixtures[UInt16($0)] } }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        do {
            let (body, gate) = try fixture.reply(request)
            let send: @Sendable () -> Void = { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["X-IPU-Pid": "42", "X-IPU-Backend": "private-ax", "X-IPU-Truncated": "0"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            if let gate { gate.enqueue(send) } else { send() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
