import ActivityKit
import Foundation
import os
import Shared
import UIKit
import XCTest
@testable import iosApp

@MainActor
final class StartupAndResourceLifecyclePerfTests: XCTestCase {
    private actor Gate {
        private var entered = false
        private var released = false
        private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        func markEntered() {
            entered = true
            let pending = enteredContinuations
            enteredContinuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredContinuations.append($0) }
        }

        func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { releaseContinuations.append($0) }
        }

        func release() {
            released = true
            let pending = releaseContinuations
            releaseContinuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    private func iosAppRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func makePNGData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testAppShellReusesChatViewModelRuntimeDatabaseAcrossStartupConsumers() async throws {
        let appShellURL = iosAppRootURL().appendingPathComponent("iosApp/AppShell.swift")
        let source = try String(contentsOf: appShellURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("IOSDurableRunStore()"),
            "AppShell must reuse chatViewModel.runStore instead of creating extra Room databases at launch"
        )
        XCTAssertTrue(source.contains("durableRunStore: chatViewModel.runStore"))
        XCTAssertTrue(source.contains("dao: chatViewModel.agentRuntimeDao"))
        XCTAssertTrue(source.contains("await AgentLiveActivityController.shared.restoreExistingActivity("))

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-reuse-\(UUID().uuidString).db")
            .path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(atPath: "\(dbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(dbPath)-shm")
        }

        let dao = IosDatabaseFactory.shared.createDatabase(atFilePath: dbPath).agentRuntimeDao()
        let runStore = IOSDurableRunStore(dao: dao)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)

        let pendingRunID = "pending-startup-\(UUID().uuidString)"
        let interruptedRunID = "interrupted-startup-\(UUID().uuidString)"

        try await runStore.startRun(
            runId: pendingRunID,
            descriptorId: IOSDurableRunStore.Descriptor.chat,
            descriptorVersion: IOSDurableRunStore.Descriptor.chatVersion,
            conversationId: "conv-pending",
            startedAt: nowMs,
            inputDigest: IOSDurableRunStore.inputDigest("pending"),
            inputSnapshotRef: "tool_call:call-1"
        )
        try await runStore.transition(
            runId: pendingRunID,
            expected: .running,
            to: .awaitingPermission,
            inputSnapshotRef: "tool_call:call-1",
            detail: "awaiting_permission",
            at: nowMs + 1
        )

        try await runStore.startRun(
            runId: interruptedRunID,
            descriptorId: IOSDurableRunStore.Descriptor.chat,
            descriptorVersion: IOSDurableRunStore.Descriptor.chatVersion,
            conversationId: "conv-running",
            startedAt: nowMs + 2,
            inputDigest: IOSDurableRunStore.inputDigest("running")
        )

        let pendingDescriptors = await IOSRunRecovery.recoverPendingApprovalDescriptors(runStore: runStore)
        XCTAssertEqual(pendingDescriptors?.map(\.runId), [pendingRunID])

        let candidateSnapshots = try await runStore.recoverableRuns()
        let candidateRunIDs = Set(candidateSnapshots.map(\.runId))
        let unfinishedPairs = await IOSRunRecovery.unfinishedRunConversationPairs(
            candidateRunIds: candidateRunIDs,
            excludingRunIds: [pendingRunID],
            runStore: runStore
        )
        XCTAssertEqual(unfinishedPairs?.map(\.runId), [interruptedRunID])

        let recoveredCount = await IOSRunRecovery.recoverInterruptedRuns(
            candidateRunIds: candidateRunIDs,
            excludingRunIds: [pendingRunID],
            runStore: runStore
        )
        XCTAssertEqual(recoveredCount, 1)

        let settled = try await runStore.snapshot(runId: interruptedRunID)
        XCTAssertEqual(settled?.status, .interrupted)
    }

    func testLiveActivityRestoreUsesAsyncSnapshotAndToolHeartbeatCancelsImmediately() async {
        let snapshotFetchCount = OSAllocatedUnfairLock(initialState: 0)
        let heartbeatGate = Gate()
        let endedCount = OSAllocatedUnfairLock(initialState: 0)

        let controller = AgentLiveActivityController(
            fetchSystemSnapshot: {
                snapshotFetchCount.withLock { $0 += 1 }
                return AgentLiveActivityController.ActivitySystemSnapshot(enabled: true, activities: [])
            },
            requestSystemCard: { runId, _, _, _, presentation in
                AgentLiveActivityController.SystemCardHandle(
                    id: "test-card-\(runId)",
                    activityState: { .active },
                    currentPresentation: { presentation },
                    currentUpdatedAt: { Date() },
                    performUpdate: { _ in },
                    performEnd: { _, _ in endedCount.withLock { $0 += 1 } }
                )
            },
            terminalLinger: { _ in },
            lingerAllowance: { 0 },
            heartbeatSleep: { _ in
                await heartbeatGate.markEntered()
                await heartbeatGate.waitForRelease()
            },
            phoneHandoffState: { _ in nil }
        )

        let runID = "live-perf-\(UUID().uuidString)"
        controller.start(
            runId: runID,
            conversationId: "conv-live",
            presentation: .response(stage: .preparing)
        )
        await waitUntil { controller.ownsActivity(runId: runID, conversationId: "conv-live") && endedCount.withLock { $0 } == 0 }
        try? await Task.sleep(for: .milliseconds(30))

        // Transitioning into a tool stage starts one heartbeat task.
        await controller.update(runId: runID, presentation: .runningTool(toolName: "generate_image"), force: true)
        await heartbeatGate.waitUntilEntered()
        XCTAssertEqual(controller.activeToolHeartbeatCountForTesting, 1)

        // Leaving tool stage immediately cancels and clears the heartbeat entry without waiting for sleep.
        await controller.update(runId: runID, presentation: .response(stage: .generating), force: true)
        XCTAssertEqual(controller.activeToolHeartbeatCountForTesting, 0)

        // Calling async restore while a run is already active routes through fetchSystemSnapshot and keeps ownership.
        let countBeforeRestore = snapshotFetchCount.withLock { $0 }
        await controller.restoreExistingActivity(ownedRunIds: [])
        XCTAssertEqual(snapshotFetchCount.withLock { $0 }, countBeforeRestore + 1)
        XCTAssertTrue(controller.ownsActivity(runId: runID, conversationId: "conv-live"))

        // Ending a run directly from a tool stage also clears its heartbeat immediately.
        await controller.update(runId: runID, presentation: .runningTool(toolName: "generate_image"), force: true)
        XCTAssertEqual(controller.activeToolHeartbeatCountForTesting, 1)
        await controller.end(runId: runID, presentation: .completed())
        XCTAssertEqual(controller.activeToolHeartbeatCountForTesting, 0)
        XCTAssertEqual(endedCount.withLock { $0 }, 1)

        await heartbeatGate.release()
    }

    func testDataImageLoaderDeduplicatesCachesAndPreservesFullPixelDimensions() async throws {
        let decodeCount = OSAllocatedUnfairLock(initialState: 0)
        let loader = ChatDataImageLoader(onDecode: {
            decodeCount.withLock { $0 += 1 }
        })

        let pngData = Self.makePNGData(width: 320, height: 240)
        let validURL = "data:image/png;base64," + pngData.base64EncodedString()

        let cancelledTask = Task {
            await loader.resolve(urlString: validURL)
        }
        let sharedTask1 = Task {
            await loader.resolve(urlString: validURL)
        }
        let sharedTask2 = Task {
            await loader.resolve(urlString: validURL)
        }
        let sharedTask3 = Task {
            await loader.resolve(urlString: validURL)
        }
        cancelledTask.cancel()

        _ = await cancelledTask.value
        let results = await [sharedTask1.value, sharedTask2.value, sharedTask3.value]
        XCTAssertEqual(decodeCount.withLock { $0 }, 1, "Concurrent data URL requests must coalesce into a single decode")

        for state in results {
            guard case .success(let image) = state else {
                return XCTFail("Expected non-cancelled consumers to receive decoded UIImage")
            }
            XCTAssertEqual(image.cgImage?.width, 320)
            XCTAssertEqual(image.cgImage?.height, 240)
        }

        // Subsequent sequential resolve hits in-memory cache without decoding again.
        let cachedState = await loader.resolve(urlString: validURL)
        guard case .success(let cachedImage) = cachedState else {
            return XCTFail("Expected sequential resolve to hit memory cache")
        }
        XCTAssertEqual(cachedImage.cgImage?.width, 320)
        XCTAssertEqual(cachedImage.cgImage?.height, 240)
        XCTAssertEqual(decodeCount.withLock { $0 }, 1)

        // Invalid payloads must fail cleanly and not poison cache.
        if case .failure = await loader.resolve(urlString: "data:image/png;base64,not-valid") {
            // expected
        } else {
            XCTFail("Invalid data URL must resolve to .failure")
        }
    }

    func testGeneratedImageDisplayAndURLAvoidRepeatedJSONAndRedundantFileStat() {
        ChatGeneratedImageRequestDisplay.clearCacheForTesting()
        let toolInput = #"{"aspect_ratio":"9:16","count":4}"#
        var jsonParseCount = 0

        let first = ChatGeneratedImageRequestDisplay.parse(toolInput: toolInput) {
            jsonParseCount += 1
        }
        let second = ChatGeneratedImageRequestDisplay.parse(toolInput: toolInput) {
            jsonParseCount += 1
        }
        let third = ChatGeneratedImageRequestDisplay.parse(toolInput: toolInput) {
            jsonParseCount += 1
        }

        XCTAssertEqual(jsonParseCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        XCTAssertEqual(first.requestedCount, 4)
        XCTAssertEqual(first.singleCardMaxWidth, 236)

        // Plain file URLs and current-container `/image-generation/` URLs must not touch disk stat().
        var statCallCount = 0
        let plainURL = ChatGeneratedImageURL.resolvedImageURL(from: "file:///tmp/plain-example.png") { _ in
            statCallCount += 1
            return false
        }
        XCTAssertEqual(plainURL?.path, "/tmp/plain-example.png")
        XCTAssertEqual(statCallCount, 0)

        let docsImageGeneration = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("image-generation", isDirectory: true)
            .appendingPathComponent("current-container.png", isDirectory: false)
        let sameContainer = ChatGeneratedImageURL.resolvedImageURL(from: docsImageGeneration.absoluteString) { _ in
            statCallCount += 1
            return true
        }
        XCTAssertEqual(sameContainer?.standardizedFileURL, docsImageGeneration.standardizedFileURL)
        XCTAssertEqual(statCallCount, 0)

        // Stale container `/image-generation/` path repairs to current container when target exists.
        let stalePath = "file:///var/mobile/Containers/Data/Application/OLD-UUID/Documents/image-generation/repaired.png"
        let repaired = ChatGeneratedImageURL.resolvedImageURL(from: stalePath) { path in
            path.hasSuffix("/image-generation/repaired.png") && !path.contains("OLD-UUID")
        }
        XCTAssertEqual(repaired?.lastPathComponent, "repaired.png")
        XCTAssertFalse(repaired?.path.contains("OLD-UUID") ?? true)
    }
}
