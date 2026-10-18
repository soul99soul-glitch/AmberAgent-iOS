import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionStreamingPerformanceTests: NovelSessionViewModelTestCase {
    func testStartingRunKeepsLongSessionLayoutResponsive() async throws {
        var document = try NovelTestFixtures.document()
        let longMarkdown = "# 第一章\n\n" + String(repeating: "破庙里的风裹着雨气，众人压低声音商议下一步。\n\n", count: 180)
        document.sessions[0].messages = (0..<8).map { index in
            NovelSessionMessageRecord(
                id: NovelMessageID(),
                sequence: Int64(index),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                mode: index.isMultiple(of: 2) ? .discussPlan : .writeProse,
                kind: index.isMultiple(of: 2) ? .userInput : .discussion,
                content: index.isMultiple(of: 2) ? "继续" : longMarkdown,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                runID: nil,
                candidateID: nil
            )
        }
        document.sessions[0].revision = Int64(document.sessions[0].messages.count)
        try NovelDocumentValidator.validate(document)

        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let settings = makeNovelTestSettings(
            userDefaults: UserDefaults(suiteName: "NovelSessionLayout-\(UUID().uuidString)")!
        )
        let host = UIHostingController(rootView: NovelSessionLayoutHarness(
            workspace: harness.workspace,
            session: harness.session,
            settings: settings
        ))
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))

        let startedAt = ContinuousClock.now
        let didStart = await harness.session.send(text: "继续写下一段")
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        let elapsed = startedAt.duration(to: .now)

        XCTAssertTrue(didStart)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "Adding the live tail must not force the long lazy history through a watchdog-scale layout pass."
        )
        await harness.session.stop()
    }

    /// 思考密集流 cadence 探针（真机 bug：小说创作里思考框出现时整体卡顿，收起思考即恢复）。
    ///
    /// 长 reasoning 按真机 chunk 率（25ms/块 ≈ 40 块/s）高频灌入，挂真实 NovelSessionView
    /// 于窗口，display link 逐帧采样帧间隔：断言 p95 ≤ 40ms、无 >80ms 长停顿（与 Chat
    /// 思考卡 cadence 门禁同阈值）。修复前红证据：reasoning 每个 chunk 原样合并进
    /// row.reasoningContent（网络节奏直上 UI），消费端饱和——探针实测 p95 88ms、
    /// max 1.38s、93/147 帧 >50ms；卡片内所有优化（尾段整体淡入、sizeThatFades 去
    /// layoutIfNeeded、内部滚动 540pt/s、cadence 门禁）都以「每拍一次 append」为前提，
    /// 逐 chunk 触发整行重建+测量。
    ///
    /// 确定性发布预算（与正文 burst 合并契约同型）：tail renderRevision（≈SwiftUI 可见
    /// 发布次数）必须小于 chunk 数——reasoning 必须走与正文同源的 48ms 拍合并，
    /// 不能逐 chunk 发布。
    func testReasoningDenseStreamKeepsDisplayLinkResponsive() async throws {
        var document = try NovelTestFixtures.document()
        let longMarkdown = "# 第一章\n\n" + String(repeating: "破庙里的风裹着雨气，众人压低声音商议下一步。\n\n", count: 180)
        document.sessions[0].messages = (0..<8).map { index in
            NovelSessionMessageRecord(
                id: NovelMessageID(),
                sequence: Int64(index),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                mode: index.isMultiple(of: 2) ? .discussPlan : .writeProse,
                kind: index.isMultiple(of: 2) ? .userInput : .discussion,
                content: index.isMultiple(of: 2) ? "继续" : longMarkdown,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                runID: nil,
                candidateID: nil
            )
        }
        document.sessions[0].revision = Int64(document.sessions[0].messages.count)
        try NovelDocumentValidator.validate(document)

        // 后缀 chunk（真机 provider 的增量语义）+ 真机 chunk 节奏（25ms/块）。
        let chunkCount = 120
        let chunkGap: TimeInterval = 0.025
        let fragment = "思考推进剧情的关键分歧点在于双方对风险与收益的权衡取舍"
        let chunks = (0..<chunkCount).map { "\(fragment)第\($0)段" }
        let expectedReasoning = chunks.joined()
        var steps: [NovelModelScriptStep] = []
        for chunk in chunks {
            steps.append(.reasoningDelta(chunk))
            steps.append(.delay(chunkGap))
        }
        steps.append(.pause)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: steps)]
        )
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let settings = makeNovelTestSettings(
            userDefaults: UserDefaults(suiteName: "NovelReasoningCadence-\(UUID().uuidString)")!
        )
        let host = UIHostingController(rootView: NovelSessionLayoutHarness(
            workspace: harness.workspace,
            session: harness.session,
            settings: settings
        ))
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))

        let probe = DisplayLinkGapProbe()
        let didStart = await harness.session.send(text: "写一段")
        XCTAssertTrue(didStart)

        // 预热 ~300ms：run 启动、思考卡首帧挂载/展开、scroll driver 启动都发生在
        // 这里——它们是每场 run 一次的一次性布局瞬态（非本门禁对象）。探针只测
        // 思考密集流稳态（用户报告「思考框出现后整体卡」的持续窗口）。
        try? await Task.sleep(for: .milliseconds(300))
        probe.start()

        // 泵到思考内容全部合并（120 块 × 25ms ≈ 3s 灌入窗）。
        let caughtUp = await eventually(timeout: 10) {
            harness.session.transientTail?.reasoningContent == expectedReasoning
        }
        XCTAssertTrue(caughtUp, "思考流应完整合并，不丢 chunk。")
        try? await Task.sleep(for: .milliseconds(300))
        probe.stop()

        let gapMilliseconds = probe.gaps.dropFirst(2).map { $0 * 1_000 }.sorted()
        let maxGap = try XCTUnwrap(gapMilliseconds.last)
        let p95Index = min(
            gapMilliseconds.count - 1,
            Int((Double(gapMilliseconds.count) * 0.95).rounded(.up)) - 1
        )
        let p95Gap = gapMilliseconds[max(0, p95Index)]
        let over50ms = gapMilliseconds.filter { $0 > 50 }.count
        let slowFrameIndices = probe.gaps.dropFirst(2).enumerated()
            .filter { $0.element > 0.05 }
            .map { "\($0.offset)@\(String(format: "%.0f", $0.element * 1_000))ms" }
        let bucket = { (upper: Double) in gapMilliseconds.filter { $0 <= upper }.count }
        print(String(
            format: "[PERF-HITCH] novelReasoning samples=%d p50=%.2fms p95=%.2fms max=%.2fms over50ms=%d " +
                "buckets<=8ms:%d <=16ms:%d <=24ms:%d <=40ms:%d <=80ms:%d slowFrames=%@",
            gapMilliseconds.count,
            gapMilliseconds[gapMilliseconds.count / 2],
            p95Gap,
            maxGap,
            over50ms,
            bucket(8),
            bucket(16),
            bucket(24),
            bucket(40),
            bucket(80),
            slowFrameIndices.isEmpty ? "none" : slowFrameIndices.joined(separator: ",")
        ))
        XCTAssertGreaterThan(
            gapMilliseconds.count,
            20,
            "探针采样数过少，无法形成帧间隔分布（display link 未在灌入窗内驱动）。"
        )
        XCTAssertLessThanOrEqual(
            p95Gap,
            40,
            "reasoning 密集流期间至少 95% 的可见帧间隔应 ≤40ms——reasoning 不得逐 chunk 直上 UI（应走 48ms 拍合并）。"
        )
        XCTAssertLessThanOrEqual(
            maxGap,
            80,
            "reasoning 密集流不得造成肉眼可见的连续主线程停顿。"
        )
        if caughtUp {
            let presentationRevision = try XCTUnwrap(harness.session.transientTail?.renderRevision)
            XCTAssertLessThan(
                presentationRevision,
                UInt64(chunkCount),
                "Provider chunk 数不得直接决定 reasoning 的 SwiftUI 发布次数（必须走 48ms 拍合并）。"
            )
        }

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        await harness.session.stop()
    }

    /// P7 性能核查（2026-09-29，ios-perf worktree）：`ChatTextWindow` 分段滑动
    /// 修复的量化证据。用真实长正文流式节奏和 DEBUG 钩子直接统计 TextKit 1 追加快路径
    /// (`ParagraphUIView.setParagraphContents` 里的
    /// `appendedTailRange(toBecome:)` 命中)而不是依赖外部 Time Profiler
    /// attach，可在普通 `xcodebuild test` 里确定性拿到命中率。修复前
    /// `ChatTextWindow` 每个 delta 都让窗口前移，`text` 不再是上一帧的前缀
    /// 扩展，几乎每次发布都落到整段替换（miss，实测命中率 7.9%）；修复后多数
    /// delta 只是纯追加，仅在窗口真正滑动时才 miss（实测命中率 ~95%）。
    func testChatTextWindowAppendFastPathHitRateForLongProseStream() async throws {
        // 150 块 × 约 35 字/块 ≈ 5,200 字，累计超过
        // limit(2,000)+2*step(1,000)=4,000，保证 ChatTextWindow 在这条流里
        // 至少滑动两次，同时把整条用例压到 10s 内；这里只统计命中率。
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: {
            var steps: [NovelModelScriptStep] = []
            let fragment = "檐下的雨还没停，烛火在穿堂风里晃了晃，把满室的影子都晃碎了。"
            for index in 0..<150 {
                steps.append(.delta("\(fragment)第\(index)段"))
                steps.append(.delay(0.03))
            }
            steps.append(.pause)
            return steps
        }())])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let settings = makeNovelTestSettings(
            userDefaults: UserDefaults(suiteName: "NovelAppendHookProse-\(UUID().uuidString)")!
        )
        let host = UIHostingController(rootView: NovelSessionLayoutHarness(
            workspace: harness.workspace,
            session: harness.session,
            settings: settings
        ))
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()

        // 短前置静默:避免 harness 布线与首个 delta 的启动竞态（曾观察到
        // transientTail 提前清空），跟上面压缩后的灌入节奏无关，不必是 3s。
        try? await Task.sleep(for: .seconds(1))

        ParagraphUIViewAppendPathTestHook.reset()

        let didStart = await harness.session.send(text: "继续写下去")
        XCTAssertTrue(didStart)

        // 150 块 × 30ms ≈ 4.5s 灌入窗 + 结尾追平余量。
        try? await Task.sleep(for: .seconds(6))
        XCTAssertNotNil(harness.session.transientTail, "流式窗口内 tail 不应提前清空。")

        let hit = ParagraphUIViewAppendPathTestHook.appendHitCount
        let miss = ParagraphUIViewAppendPathTestHook.fallbackMissCount
        let total = hit + miss
        let hitRate = total > 0 ? Double(hit) / Double(total) : 0
        print(String(
            format: "[PERF-APPEND-HOOK] prose hit=%d miss=%d hitRate=%.1f%% missReasons=%@",
            hit, miss, hitRate * 100,
            "\(ParagraphUIViewAppendPathTestHook.missReasonCounts)"
        ))
        XCTAssertGreaterThanOrEqual(
            hitRate, 0.8,
            "ChatTextWindow 分段滑动修复后追加快路径命中率应远高于修复前的 7.9%（实测 ~95%）。"
        )

        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.adapter.resume(runID: runID)
        await harness.session.stop()
    }

}
