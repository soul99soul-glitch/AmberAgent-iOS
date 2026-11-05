import XCTest
import SwiftUI
import Shared
@testable import SwiftStreamingMarkdown
@testable import iosApp

/// Same private search capture, now including send, foreground drain and bottom
/// settling. Three fresh timelines run in one process; caches are not cleared.
@MainActor
final class ChatSearchEndToEndReplayTests: ChatNativeTimelineReplayTestCase {
    private var artifact: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/StreamingPerfEvidence")
    }

    func testThreeConsecutiveCapturedRoundsThroughVisibleCompletion() throws {
        let input = artifact.appendingPathComponent("replay-input-private.json")
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw XCTSkip("Local device capture is required")
        }
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [[String: Any]])
        let firstUser = try XCTUnwrap(records.firstIndex { ($0["createdAt"] as? String ?? "") >= "2026-11-05T23:55:58" })
        var rounds: [[String: Any]] = []
        for round in 1...3 {
            var result = try autoreleasepool { try runRound(round, records: records, firstUser: firstUser) }
            pump(seconds: 1)
            result["afterTeardownFootprintBytes"] = try XCTUnwrap(ChatReplayMemoryProbe.read()).footprint
            rounds.append(result)
            let data = try JSONSerialization.data(withJSONObject: rounds, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: artifact.appendingPathComponent("end-to-end-three-rounds.json"))
        }
        XCTAssertEqual(rounds.count, 3)
    }

    private func runRound(_ round: Int, records: [[String: Any]], firstUser: Int) throws -> [String: Any] {
        let messages = try records.map { record -> UIMessage in
            let data = try JSONSerialization.data(withJSONObject: record["parts"] ?? [])
            let parts = try IosToolOutputJsonBridge.shared.decode(json: String(decoding: data, as: UTF8.self))
            return UIMessage(id: KotlinUuid.companion.random(),
                role: record["role"] as? String == "user" ? .user : .assistant,
                parts: parts, annotations: [], createdAt: chatNowLocalDateTime(),
                finishedAt: chatNowLocalDateTime(), modelId: nil, usage: nil, translation: nil)
        }
        var acknowledgedAt: TimeInterval?
        let feedback = ChatCompletionFeedback { acknowledgedAt = ProcessInfo.processInfo.systemUptime }
        feedback.setForegroundVisible(true)
        let fixture = makeFixture { $0.completionFeedback = feedback }
        defer { fixture.tearDown() }
        fixture.model.messages = Array(messages.prefix(firstUser))
        fixture.model.send(.initialLoad)
        pump(seconds: 6)
        XCTAssertTrue(pumpUntil(timeout: 4) { fixture.model.latestViewport.isAtBottom })
        let scroll = try XCTUnwrap(fixture.scrollView)
        let baselineMemory = try XCTUnwrap(ChatReplayMemoryProbe.read())
        let memory = ChatReplayMemoryProbe()
        let frameCPU = ChatReplayFrameCPUProbe()
        let gaps = DisplayLinkGapProbe()
        memory.start()
        frameCPU.start()
        gaps.start()
        let start = ProcessInfo.processInfo.systemUptime
        let epoch = Date().timeIntervalSince1970
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let processCPU = Self.processCPUSeconds()
        var turnStart = start
        var currentRun = ""
        var anchor = ""
        var turns: [[String: Any]] = []
        print("[E2E] round=\(round) pid=\(getpid()) start")

        func progress(_ title: String, kind: ChatActivityIslandState.Kind = .tool) -> ChatTimelineActivity {
            ChatTimelineActivity(anchorMessageID: anchor, hasAssistant: true,
                presentation: .activity(kind: kind, title: title, systemImage: "magnifyingglass", tint: .amber),
                tool: nil, taskSlot: nil, plannedStages: [], stagePlanStartedUptime: nil,
                liveReasoningSummary: nil, tracksTaskLiveness: false, showsThought: false)
        }
        for index in firstUser..<messages.count {
            let message = messages[index]
            if message.role == .user {
                acknowledgedAt = nil
                currentRun = "perf-\(round)-\(index)"
                feedback.begin(runID: currentRun)
                anchor = message.id.toHexDashString()
                turnStart = ProcessInfo.processInfo.systemUptime
                fixture.model.isGenerationActive = true
                fixture.model.activity = progress("正在搜索网页")
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
                fixture.model.send(.assistantStreamClosed)
                pump(seconds: 0.5)
            }
            let closesTurn = index == messages.count - 1 || messages[index + 1].role == .user
            if closesTurn {
                let sourceClosed = ProcessInfo.processInfo.systemUptime
                fixture.model.isGenerationActive = false
                fixture.model.activity = nil
                fixture.model.send(.generationCompleted)
                let parts = Dictionary(uniqueKeysWithValues: message.parts.enumerated().compactMap { partIndex, part -> (Int, String)? in
                    guard let text = part as? UIMessagePart.Text, !text.text.isEmpty else { return nil }
                    return (partIndex, text.text)
                })
                feedback.complete(runID: currentRun, messageID: message.id.toHexDashString(), textParts: parts)
                print("[E2E] round=\(round) turn=\(turns.count + 1) sourceClosed=\(sourceClosed - turnStart)")
                let suffix = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(32))
                var firstVisibleAt: TimeInterval?
                var stableSince: TimeInterval?
                var previousGeometry: [CGFloat]?
                let completed = pumpUntil(timeout: 90) {
                    guard acknowledgedAt != nil,
                          let paragraph = Self.finalParagraph(in: fixture.host.view, suffix: suffix) else { return false }
                    let caret = paragraph.caretRect(for: paragraph.endOfDocument)
                    let rect = paragraph.convert(caret, to: scroll)
                    let visibleBounds = scroll.bounds.inset(by: scroll.adjustedContentInset)
                    guard rect.intersects(visibleBounds), rect.maxY <= visibleBounds.maxY + 1 else {
                        stableSince = nil
                        return false
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if firstVisibleAt == nil { firstVisibleAt = now }
                    let target = max(-scroll.adjustedContentInset.top,
                                     scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    let geometry = [scroll.contentOffset.y, scroll.contentSize.height, scroll.bounds.height]
                    let atBottom = abs(scroll.contentOffset.y - target) <= 1
                    let unchanged = previousGeometry.map { zip($0, geometry).allSatisfy { abs($0 - $1) <= 0.5 } } ?? false
                    if !atBottom || !unchanged { stableSince = nil }
                    previousGeometry = geometry
                    if atBottom, stableSince == nil { stableSince = now }
                    return stableSince.map { now - $0 >= 1 } ?? false
                }
                let settled = ProcessInfo.processInfo.systemUptime
                turns.append(["turn": turns.count + 1, "sourceClosedSeconds": sourceClosed - turnStart,
                              "renderAcknowledgedSeconds": acknowledgedAt.map { $0 - turnStart } ?? -1,
                              "lastTextVisibleSeconds": firstVisibleAt.map { $0 - turnStart } ?? -1,
                              "bottomSettledSeconds": settled - turnStart, "completed": completed,
                              "settleConfirmationSeconds": 1, "textUTF16Count": text.utf16.count])
                print("[E2E] round=\(round) turn=\(turns.count) settled=\(settled - turnStart) completed=\(completed)")
                if !completed { break }
            }
        }
        let wall = ProcessInfo.processInfo.systemUptime - start
        let mainCPUMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6
        let processCPUSeconds = Self.processCPUSeconds() - processCPU
        gaps.stop()
        frameCPU.stop()
        let memoryResult = memory.stop()
        let endMemory = try XCTUnwrap(ChatReplayMemoryProbe.read())
        var result: [String: Any] = [
            "round": round, "pid": getpid(), "startEpochSeconds": epoch,
            "endToEndSeconds": wall, "mainCPUMs": mainCPUMs, "mainCPUPercent": mainCPUMs / (wall * 10),
            "processCPUSeconds": processCPUSeconds,
            "maxFrameGapMs": (gaps.gaps.max() ?? 0) * 1000,
            "frameGapsOver50ms": gaps.gaps.filter { $0 > 0.05 }.count,
            "frameGapsOver100ms": gaps.gaps.filter { $0 > 0.1 }.count,
            "frames": frameCPU.frames, "turns": turns,
            "baselineFootprintBytes": baselineMemory.footprint, "endFootprintBytes": endMemory.footprint,
            "lifetimePeakFootprintBeforeBytes": baselineMemory.lifetimePeakFootprint,
            "lifetimePeakFootprintAfterBytes": endMemory.lifetimePeakFootprint
        ]
        result.merge(memoryResult) { _, new in new }
        XCTAssertEqual(fixture.model.messages.last?.toText(), messages.last?.toText())
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns.allSatisfy { $0["completed"] as? Bool == true }, "Visible completion or actual bottom settling timed out")
        print("[E2E] round=\(round) total=\(wall) mainCPU=\(mainCPUMs) peak=\(memoryResult["sampledPeakFootprintBytes"] ?? 0)")
        return result
    }

    private static func finalParagraph(in view: UIView, suffix: String) -> ParagraphUIView? {
        if let paragraph = view as? ParagraphUIView,
           paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(suffix) { return paragraph }
        for child in view.subviews {
            if let paragraph = finalParagraph(in: child, suffix: suffix) { return paragraph }
        }
        return nil
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
