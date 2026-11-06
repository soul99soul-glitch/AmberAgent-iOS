import XCTest
import SwiftUI
import Shared
@testable import iosApp

/// Focused controls for the 21:15 flight-recorder findings; no provider calls.
@MainActor
final class ChatTimelineAnimationIsolationTests: ChatNativeTimelineReplayTestCase {
    func testCapturedProgressAndCompletedHistoryControls() throws {
        let artifact = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/StreamingPerfEvidence/evening-2115")
        let deviceInput = artifact.appendingPathComponent("replay-2115-private.json")
        let usesEveningCapture = FileManager.default.fileExists(atPath: deviceInput.path)
        let input = usesEveningCapture ? deviceInput : artifact.deletingLastPathComponent()
            .appendingPathComponent("replay-input-private.json")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Local capture required") }
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [[String: Any]])
        let messages = try records.map { record -> UIMessage in
            let data = try JSONSerialization.data(withJSONObject: record["parts"] ?? [])
            return UIMessage(id: KotlinUuid.companion.random(),
                role: record["role"] as? String == "user" ? .user : .assistant,
                parts: try IosToolOutputJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self)),
                annotations: [], createdAt: chatNowLocalDateTime(), finishedAt: chatNowLocalDateTime(),
                modelId: nil, usage: nil, translation: nil)
        }
        let firstUser = try XCTUnwrap(records.firstIndex {
            ($0["createdAt"] as? String ?? "") >= (usesEveningCapture ? "2026-11-06T21:15:37" : "2026-11-05T23:55:58")
        })
        let activity = ChatTimelineActivity(
            anchorMessageID: messages[firstUser].id.toHexDashString(), hasAssistant: true,
            presentation: .activity(kind: .tool, title: "正在搜索网页", systemImage: "magnifyingglass", tint: .amber),
            tool: nil, taskSlot: nil, plannedStages: [], stagePlanStartedUptime: nil,
            liveReasoningSummary: nil, tracksTaskLiveness: false, showsThought: false)
        let fixture = makeFixture { model in
            model.messages = Array(messages.prefix(firstUser + 2))
            model.isGenerationActive = true
            model.activity = activity
            model.send(.toolCallStarted)
        }
        defer {
            fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset()
        }
        pump(seconds: 4)
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom })
        var results: [[String: Any]] = []
        func measure(_ phase: String, operation: () -> Void) throws {
            ChatRenderProbe.reset()
            ChatRenderProbe.enabled = true
            let frameCPU = ChatReplayFrameCPUProbe()
            let gaps = DisplayLinkGapProbe()
            frameCPU.start(); gaps.start()
            let start = ProcessInfo.processInfo.systemUptime
            let epoch = Date().timeIntervalSince1970
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            operation()
            let wall = ProcessInfo.processInfo.systemUptime - start
            let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6
            frameCPU.stop(); gaps.stop()
            ChatRenderProbe.enabled = false
            results.append(["phase": phase, "startEpochSeconds": epoch, "wallSeconds": wall,
                "pid": getpid(), "mainCPUMs": cpuMs, "mainCPUPercent": cpuMs / (wall * 10),
                "frames": frameCPU.frames, "maxFrameGapMs": (gaps.gaps.max() ?? 0) * 1000,
                "frameGapsOver50ms": gaps.gaps.filter { $0 > 0.05 }.count,
                "totals": ChatRenderProbe.counts.mapValues { $0.values.reduce(0, +) },
                "uniqueIDs": ChatRenderProbe.counts.mapValues { $0.count }])
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: artifact.appendingPathComponent("animation-controls.json"))
            print("[ANIMATION-CONTROL] \(phase) CPU=\(cpuMs / (wall * 10))%")
        }
        try measure("progress-live") { pump(seconds: 3) }
        fixture.model.pausesDecorativeTimelines = true
        pump(seconds: 0.3)
        try measure("progress-paused") { pump(seconds: 3) }
        fixture.model.pausesDecorativeTimelines = false
        pump(seconds: 0.3)
        try measure("progress-live-again") { pump(seconds: 3) }

        fixture.model.messages = messages
        fixture.model.isGenerationActive = false
        fixture.model.activity = nil
        fixture.model.send(.generationCompleted)
        pump(seconds: 4)
        try measure("completed-idle") { pump(seconds: 2) }
        try measure("completed-viewport-resize") {
            for height: CGFloat in [600, 852, 600, 852] {
                fixture.window.frame.size.height = height
                fixture.host.view.layoutIfNeeded()
                pump(seconds: 0.5)
            }
        }
        try measure("completed-presentation-environment") {
            for paused in [true, false, true, false] {
                fixture.model.pausesDecorativeTimelines = paused
                pump(seconds: 0.5)
            }
        }
        XCTAssertEqual(fixture.model.messages.count, messages.count)
    }

    func testProgressLayerAnimationsRetainGeometryAndPauseTheirClock() throws {
        let wave = ChatTaskWaveLayerView(frame: CGRect(x: 0, y: 0, width: 22.6, height: 16))
        wave.layoutIfNeeded()
        let dots = try XCTUnwrap(wave.layer.sublayers)
        XCTAssertEqual(dots.count, 3)
        for (index, dot) in dots.enumerated() {
            XCTAssertEqual(dot.bounds.size, CGSize(width: 5.2, height: 5.2))
            XCTAssertEqual(dot.position.x, 2.6 + CGFloat(index) * 8.7, accuracy: 0.001)
            let animation = try XCTUnwrap(dot.animation(forKey: "wave") as? CAAnimationGroup)
            XCTAssertEqual(animation.duration, 2 * Double.pi / 4.6, accuracy: 0.0001)
            XCTAssertEqual(animation.animations?.count, 3)
        }
        wave.setAnimationPaused(true)
        XCTAssertEqual(wave.layer.speed, 0)
        wave.setAnimationPaused(false)
        XCTAssertEqual(wave.layer.speed, 1)

        let shimmer = ChatTaskShimmerLayerView(frame: CGRect(x: 0, y: 0, width: 160, height: 22))
        shimmer.layoutIfNeeded()
        let band = try XCTUnwrap(shimmer.layer.sublayers?.first as? CAGradientLayer)
        XCTAssertEqual(band.bounds.width, 67.2, accuracy: 0.001)
        XCTAssertEqual(band.animation(forKey: "sweep")?.duration, 1.8)
        shimmer.setAnimationPaused(true)
        XCTAssertEqual(shimmer.layer.speed, 0)
        shimmer.setAnimationPaused(false)
        XCTAssertEqual(shimmer.layer.speed, 1)
    }

    func testViewportResizePreservesMountedScrollViewAndHistory() throws {
        let fixture = makeFixture { model in
            model.messages = longConversation(turns: 6)
            model.send(.initialLoad)
        }
        defer { fixture.tearDown(); ChatRenderProbe.enabled = false; ChatRenderProbe.reset() }
        XCTAssertTrue(pumpUntil(timeout: 5) { fixture.model.latestViewport.isAtBottom })
        pump(seconds: 0.4)
        let scrollView = try XCTUnwrap(fixture.scrollView)
        ChatRenderProbe.reset()
        ChatRenderProbe.enabled = true
        for height: CGFloat in [600, 852, 600, 852] {
            fixture.window.frame.size.height = height
            fixture.host.view.layoutIfNeeded()
            pump(seconds: 0.2)
            XCTAssertTrue(fixture.scrollView === scrollView,
                          "Viewport changes must preserve the mounted conversation")
        }
        XCTAssertEqual(ChatRenderProbe.counts["row"]?.values.reduce(0, +) ?? 0, 0,
                       "A bottom-follow policy change must not remount unchanged history")
        XCTAssertTrue(fixture.model.latestViewport.isAtBottom)
    }
}
