import XCTest
import SwiftUI
import Shared
import os
@testable import iosApp

/// Temporary, local-only diagnostic. The private device capture stays in ignored build output.
@MainActor
final class ChatSearchCaptureReplayTests: ChatNativeTimelineReplayTestCase {
    func testCapturedInvalidationFanout() throws {
        let artifact = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/StreamingPerfEvidence")
        guard FileManager.default.fileExists(atPath: artifact.appendingPathComponent("replay-input-private.json").path) else {
            throw XCTSkip("Local device capture is required")
        }
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            artifact.appendingPathComponent("replay-input-private.json"))) as? [[String: Any]])
        let messages = try records.map { record -> UIMessage in
            let data = try JSONSerialization.data(withJSONObject: record["parts"] ?? [])
            let parts = try IosToolOutputJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
            return UIMessage(id: KotlinUuid.companion.random(),
                role: record["role"] as? String == "user" ? .user : .assistant,
                parts: parts, annotations: [], createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(), modelId: nil, usage: nil, translation: nil)
        }
        let firstUser = try XCTUnwrap(records.firstIndex { ($0["createdAt"] as? String ?? "") >= "2026-11-05T23:55:58" })
        let historicalIDs = Set(messages.prefix(firstUser).map { $0.id.toHexDashString() })
        let fixture = makeFixture()
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        fixture.model.messages = Array(messages.prefix(firstUser + 2))
        fixture.model.isGenerationActive = true
        let anchor = messages[firstUser].id.toHexDashString()
        func progress(_ title: String) -> ChatTimelineActivity {
            ChatTimelineActivity(anchorMessageID: anchor, hasAssistant: true,
                presentation: .activity(kind: .tool, title: title, systemImage: "magnifyingglass", tint: .amber),
                tool: nil, taskSlot: nil, plannedStages: [], stagePlanStartedUptime: nil,
                liveReasoningSummary: nil, tracksTaskLiveness: false, showsThought: false)
        }
        fixture.model.activity = progress("正在搜索网页")
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        fixture.model.send(.toolCallStarted)
        pump(seconds: 6)
        let mountedHistory = Set((ChatRenderProbe.counts["layout-request"] ?? [:]).keys).intersection(historicalIDs)
        XCTAssertFalse(mountedHistory.isEmpty, "Layout instrumentation must observe mounted history")
        ChatRenderProbe.enabled = false
        var results: [[String: Any]] = []
        let signpostLog = OSLog(subsystem: "app.amber.ios.perf", category: .pointsOfInterest)
        func count(_ event: String, update: () -> Void) {
            ChatRenderProbe.reset()
            ChatRenderProbe.enabled = true
            let frameProbe = ChatReplayFrameCPUProbe()
            frameProbe.start()
            let start = ProcessInfo.processInfo.systemUptime
            let epoch = Date().timeIntervalSince1970
            let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            os_signpost(.begin, log: signpostLog, name: "FanoutEvent", "%{public}s", event)
            update()
            pump(seconds: 0.3)
            os_signpost(.end, log: signpostLog, name: "FanoutEvent", "%{public}s", event)
            let mainCPUMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startCPU) / 1e6
            let wallMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            frameProbe.stop()
            ChatRenderProbe.enabled = false
            let counts = ChatRenderProbe.counts
            let rows = counts["row"] ?? [:]
            let hist = rows.filter { historicalIDs.contains($0.key) }
            let layout = counts["layout-request"] ?? [:]
            let measures = counts["layout-measure"] ?? [:]
            let placements = counts["layout-place"] ?? [:]
            results.append(["event": event,
                "startUptime": start, "wallMs": wallMs, "mainCPUMs": mainCPUMs,
                "startEpochSeconds": epoch,
                "frames": frameProbe.frames,
                "mountedHistoricalRows": mountedHistory.count,
                "capturedHistoricalMessages": historicalIDs.count,
                "totals": counts.mapValues { $0.values.reduce(0, +) },
                "uniqueIDsByScope": counts.mapValues { $0.count },
                "historicalTotals": counts.mapValues { $0.filter { historicalIDs.contains($0.key) }.values.reduce(0, +) },
                "historicalRowBodies": hist.values.reduce(0, +), "historicalRowsReevaluated": hist.count,
                "historicalLayoutRequests": layout.filter { historicalIDs.contains($0.key) }.values.reduce(0, +),
                "historicalRowsLayoutRequested": layout.keys.filter { historicalIDs.contains($0) }.count,
                "historicalMeasurements": measures.filter { historicalIDs.contains($0.key) }.values.reduce(0, +),
                "historicalRowsMeasured": measures.keys.filter { historicalIDs.contains($0) }.count,
                "historicalPlacements": placements.filter { historicalIDs.contains($0.key) }.values.reduce(0, +),
                "historicalRowsPlaced": placements.keys.filter { historicalIDs.contains($0) }.count])
        }
        count("idle") {}
        count("progress-change") { fixture.model.activity = progress("正在核对网页") }
        let id = KotlinUuid.companion.random()
        let seed = "## 连续正文\n\n" + String(repeating: "这是当前回复。", count: 5)
        fixture.model.messages.append(makeAssistantMessage(id: id, text: seed, finished: false))
        fixture.model.send(.streamDelta)
        pump(seconds: 2)
        count("idle-with-live-tail") {}
        count("single-token-update") {
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: id, text: seed + "续", finished: false)
            fixture.model.send(.streamDelta)
        }
        pump(seconds: 0.5)
        count("stream-chunk-height-growth") {
            fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                id: id, text: seed + "续\n\n" + String(repeating: "换行后的连续回复。", count: 8), finished: false)
            fixture.model.send(.streamDelta)
        }
        pump(seconds: 1)
        let tool = try XCTUnwrap(messages.dropFirst(firstUser + 2).first {
            $0.parts.contains { $0 is UIMessagePart.Tool }
        })
        count("single-tool-event") {
            fixture.model.messages.append(tool)
            fixture.model.send(.toolResultAppended)
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact.appendingPathComponent("invalidation-fanout.json"))
        print("[FANOUT] \(String(decoding: data, as: UTF8.self))")
    }

    func testCapturedSearchProgressAndStream() throws {
        let artifact = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/StreamingPerfEvidence")
        let input = artifact.appendingPathComponent("replay-input-private.json")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Local device capture is required")
        }
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [[String: Any]])
        let messages = try records.map { record -> UIMessage in
            let data = try JSONSerialization.data(withJSONObject: record["parts"] ?? [])
            let parts = try IosToolOutputJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
            return UIMessage(id: KotlinUuid.companion.random(),
                role: record["role"] as? String == "user" ? .user : .assistant,
                parts: parts, annotations: [], createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(), modelId: nil, usage: nil, translation: nil)
        }
        let firstUser = try XCTUnwrap(records.firstIndex { ($0["createdAt"] as? String ?? "") >= "2026-11-05T23:55:58" })
        let fixture = makeFixture()
        defer { fixture.tearDown() }
        fixture.model.messages = Array(messages.prefix(firstUser + 2))
        fixture.model.isGenerationActive = true
        let anchor = ChatMessageProjector.messageId(for: messages[firstUser])
        func progress(_ title: String, kind: ChatActivityIslandState.Kind = .tool) -> ChatTimelineActivity {
            ChatTimelineActivity(anchorMessageID: anchor, hasAssistant: true,
                presentation: .activity(kind: kind, title: title, systemImage: "magnifyingglass", tint: .amber),
                tool: nil, taskSlot: nil, plannedStages: [], stagePlanStartedUptime: nil,
                liveReasoningSummary: nil, tracksTaskLiveness: false, showsThought: false)
        }
        fixture.model.activity = progress("正在搜索网页")
        fixture.model.send(.toolCallStarted)
        pump(seconds: 4)
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom },
            "Performance capture must start at the live bottom, not with the reply offscreen")

        var results: [[String: Any]] = []
        func measure(_ name: String, _ operation: () -> Void) {
            let probe = DisplayLinkGapProbe()
            probe.start()
            let frameCPU = ChatReplayFrameCPUProbe()
            frameCPU.start()
            let wall = ProcessInfo.processInfo.systemUptime
            let epoch = Date().timeIntervalSince1970
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            operation()
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6
            let seconds = ProcessInfo.processInfo.systemUptime - wall
            probe.stop()
            frameCPU.stop()
            let result: [String: Any] = ["phase": name, "wallSeconds": seconds,
                "startUptime": wall, "startEpochSeconds": epoch, "frames": frameCPU.frames,
                "mainCPUMs": cpuMs, "mainCPUPercent": cpuMs / (seconds * 10),
                "maxFrameGapMs": (probe.gaps.max() ?? 0) * 1000,
                "frameGapsOver50ms": probe.gaps.filter { $0 > 0.05 }.count]
            results.append(result)
            print("[SEARCH-CAPTURE] \(name): wall=\(seconds)s mainCPU=\(cpuMs)ms")
        }
        measure("progress-live") { pump(seconds: 5) }
        fixture.model.pausesDecorativeTimelines = true
        pump(seconds: 0.4)
        measure("progress-paused") { pump(seconds: 5) }
        fixture.model.pausesDecorativeTimelines = false
        pump(seconds: 0.4)

        measure("tools-and-stream") {
            for index in (firstUser + 2)..<messages.count {
                let message = messages[index]
                if message.role == .user {
                    fixture.model.messages.append(message)
                    fixture.model.send(.userAppend)
                    pump(seconds: 0.2)
                    continue
                }
                let text = message.toText()
                if text.isEmpty {
                    fixture.model.messages.append(message)
                    fixture.model.activity = progress(index % 2 == 0 ? "正在核对网页" : "正在思考")
                    fixture.model.send(.toolResultAppended)
                    pump(seconds: 0.15)
                } else {
                    fixture.model.messages.append(makeAssistantMessage(id: message.id, text: "", finished: false))
                    fixture.model.activity = progress("正在整理回复", kind: .generating)
                    let characters = Array(text)
                    for end in stride(from: 24, through: characters.count + 23, by: 24) {
                        fixture.model.messages[fixture.model.messages.count - 1] = makeAssistantMessage(
                            id: message.id, text: String(characters.prefix(min(end, characters.count))), finished: false)
                        fixture.model.send(.streamDelta)
                        pump(seconds: 0.03)
                    }
                    fixture.model.messages[fixture.model.messages.count - 1] = message
                    fixture.model.send(.generationCompleted)
                    pump(seconds: 0.5)
                }
            }
        }
        fixture.model.isGenerationActive = false
        fixture.model.activity = nil
        fixture.model.send(.generationCompleted)
        pump(seconds: 1)
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom },
            "Completion must preserve real bottom-follow")
        XCTAssertEqual(fixture.model.messages.last?.toText(), messages.last?.toText())
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact.appendingPathComponent("captured-replay-metrics.json"))
    }
}
