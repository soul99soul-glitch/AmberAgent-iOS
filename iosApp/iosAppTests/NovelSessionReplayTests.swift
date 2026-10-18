import Foundation
import XCTest
@testable import iosApp

final class NovelSessionReplayTests: NovelSessionReplayTestCase {
    func testPresentationBufferPreservesFIFOReplacementAndRunIdentity() {
        let runID = NovelRunID()
        let messageID = NovelMessageID()
        let bindingToken = UUID()
        var buffer = NovelSessionPresentationBuffer(
            runID: runID,
            messageID: messageID,
            bindingToken: bindingToken,
            baseContent: "已显示"
        )

        buffer.append("旧前缀")
        buffer.replace(with: "完整替换")
        buffer.append("与后续")

        XCTAssertEqual(buffer.targetContent, "完整替换与后续")
        XCTAssertTrue(buffer.matches(
            runID: runID,
            messageID: messageID,
            bindingToken: bindingToken
        ))
        XCTAssertFalse(buffer.matches(
            runID: NovelRunID(),
            messageID: messageID,
            bindingToken: bindingToken
        ))
    }

    func testIncrementalPresentationBufferMatchesStatelessPacer() {
        let runID = NovelRunID()
        let messageID = NovelMessageID()
        let bindingToken = UUID()
        var buffer = NovelSessionPresentationBuffer(
            runID: runID,
            messageID: messageID,
            bindingToken: bindingToken,
            baseContent: "已显示"
        )
        var referenceDisplayed = "已显示"

        func drain(
            mode: NovelSessionPresentationPacer.Mode = .streaming,
            fixedAdvance: Int? = nil
        ) {
            var ticks = 0
            while true {
                let expected = NovelSessionPresentationPacer.step(
                    displayedContent: referenceDisplayed,
                    targetContent: buffer.targetContent,
                    mode: mode,
                    fixedTerminalAdvance: fixedAdvance
                )
                let actual = buffer.step(mode: mode, fixedTerminalAdvance: fixedAdvance)
                XCTAssertEqual(actual, expected)
                referenceDisplayed = expected.content
                if expected.isCaughtUp { return }
                ticks += 1
                if ticks >= 100 {
                    XCTFail("Incremental pacer did not catch up.")
                    return
                }
            }
        }

        for chunk in [
            "文本",
            "e",
            "\u{301}",
            "🇺",
            "🇸",
            "👩",
            "\u{200D}",
            "💻",
            String(repeating: "长", count: 240),
        ] {
            buffer.append(chunk)
            drain()
        }

        buffer.replace(with: "重写后分段" + String(repeating: "替", count: 90))
        drain()
        buffer.append("追加在重写之后")
        drain()

        // Append after a paced step, while the displayed index is inside the
        // target. Appending must leave that earlier index usable.
        buffer.replace(with: referenceDisplayed + String(repeating: "积", count: 700))
        let expectedFirstStep = NovelSessionPresentationPacer.step(
            displayedContent: referenceDisplayed,
            targetContent: buffer.targetContent
        )
        let actualFirstStep = buffer.step()
        XCTAssertEqual(actualFirstStep, expectedFirstStep)
        XCTAssertFalse(actualFirstStep.isCaughtUp)
        referenceDisplayed = expectedFirstStep.content

        for chunk in [
            String(repeating: "突", count: 80),
            String(repeating: "发", count: 120),
            String(repeating: "流", count: 160),
        ] {
            buffer.append(chunk)
        }
        drain()
    }

    func testFullTextPaginationPreservesGraphemeBoundariesAndSource() {
        let composed = "e\u{301}"
        let family = "👨‍👩‍👧‍👦"
        let source = String(repeating: family, count: 1_999) + composed + "尾"

        let pages = NovelSessionFullTextPagination.pages(source)

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.first?.count, ChatTextWindow.limit)
        XCTAssertEqual(
            pages.first,
            String(repeating: family, count: 1_999) + composed
        )
        XCTAssertEqual(pages.last, "尾")
        XCTAssertTrue(pages.allSatisfy { $0.count <= ChatTextWindow.limit })
        XCTAssertEqual(pages.joined(), source)
        XCTAssertEqual(NovelSessionFullTextPagination.pages(""), [""])
    }

    func testPresentationPacerSplitsLightBacklogIntoBoundedSteps() {
        let target = "已显示" + String(repeating: "字", count: 36)
        var displayed = "已显示"
        var steps = 0
        var intermediateAdvances: [Int] = []

        while displayed != target {
            let step = NovelSessionPresentationPacer.step(
                displayedContent: displayed,
                targetContent: target
            )
            let advanced = step.content.count - displayed.count
            intermediateAdvances.append(advanced)
            displayed = step.content
            steps += 1
            XCTAssertLessThanOrEqual(
                advanced,
                NovelSessionPresentationPacer.maximumTextAdvance
            )
            XCTAssertGreaterThan(advanced, 0)
            if steps > 20 {
                return XCTFail("Pacer failed to catch up within expected ticks.")
            }
        }

        XCTAssertGreaterThan(steps, 1, "A multi-line backlog must not publish in one frame.")
        XCTAssertEqual(
            intermediateAdvances.dropLast().allSatisfy {
                $0 >= NovelSessionPresentationPacer.minimumTextAdvance
            },
            true
        )
        XCTAssertEqual(displayed, target)
    }

    func testPresentationPacerAcceleratesWithLargeBacklogButStaysCapped() {
        let largeBacklog = 2_000
        XCTAssertEqual(
            NovelSessionPresentationPacer.textAdvance(backlogCount: 8),
            NovelSessionPresentationPacer.minimumTextAdvance
        )
        XCTAssertEqual(
            NovelSessionPresentationPacer.textAdvance(backlogCount: largeBacklog),
            NovelSessionPresentationPacer.maximumTextAdvance
        )

        let target = String(repeating: "章", count: largeBacklog)
        let first = NovelSessionPresentationPacer.step(
            displayedContent: "",
            targetContent: target
        )
        XCTAssertEqual(first.content.count, NovelSessionPresentationPacer.maximumTextAdvance)
        XCTAssertFalse(first.isCaughtUp)

        // Drain-window adaptive: backlog of preferredDrainTicks * minAdvance stays at floor.
        let light = NovelSessionPresentationPacer.preferredDrainTicks
            * NovelSessionPresentationPacer.minimumTextAdvance
        XCTAssertEqual(
            NovelSessionPresentationPacer.textAdvance(backlogCount: light),
            NovelSessionPresentationPacer.minimumTextAdvance
        )
    }

    func testPresentationPacerPacesNonPrefixReplacementInsteadOfSnapping() {
        let target = "最终前缀与结尾" + String(repeating: "续", count: 40)
        let first = NovelSessionPresentationPacer.step(
            displayedContent: "应被替换的旧文",
            targetContent: target
        )
        XCTAssertTrue(target.hasPrefix(first.content))
        XCTAssertLessThan(
            first.content.count,
            target.count,
            "Divergent replacement must not dump the full target in one frame."
        )
        XCTAssertLessThanOrEqual(
            first.content.count,
            NovelSessionPresentationPacer.maximumTextAdvance
        )
        XCTAssertFalse(first.isCaughtUp)

        var displayed = first.content
        var ticks = 0
        while displayed != target, ticks < 20 {
            let step = NovelSessionPresentationPacer.step(
                displayedContent: displayed,
                targetContent: target
            )
            displayed = step.content
            ticks += 1
        }
        XCTAssertEqual(displayed, target)
    }

    func testManuscriptPresentationContentStripsStreamingFence() {
        let body = "巷口旧雨。"
        let fenced = "```markdown\n\(body)\n"
        XCTAssertEqual(
            NovelSessionPresentationPacer.presentationContent(fenced, runKind: .prose),
            body
        )
        XCTAssertEqual(
            NovelSessionPresentationPacer.presentationContent(fenced, runKind: .discussion),
            fenced,
            "Discussion keeps raw text; only manuscript kinds strip fences."
        )
    }

    func testGenerationStatusStaysVisibleThroughTerminalPresenting() {
        XCTAssertTrue(
            NovelSessionComposerPolicy.showsGenerationStatus(
                isRunning: false,
                isTerminalPresenting: true,
                activeRunKind: .prose
            )
        )
        XCTAssertFalse(
            NovelSessionComposerPolicy.showsGenerationStatus(
                isRunning: false,
                isTerminalPresenting: true,
                activeRunKind: .discussion
            )
        )
        XCTAssertFalse(
            NovelSessionComposerPolicy.showsGenerationStatus(
                isRunning: false,
                isTerminalPresenting: false,
                activeRunKind: .prose
            )
        )
    }

    /// 终态大积压与 Chat 共用连续 whoosh 曲线：24k 字 ≤64 拍、锚速间隔护栏 ≤0.6s。
    /// 2026-08-15 契约变更（用户拍板，与 IOSParityRedLightTests 同款更新）：排空
    /// 收尾必须连续减速到打字节奏、末拍以完整淡入落定（「最后一个字优雅地逐字
    /// 淡入结束」）。拍速 = min(锚速, max(12, 剩余/8))：中段 whoosh 不变，末段
    /// 多拍减速——拍数与耗时上限随之放宽（恒速口径的 16 拍/0.5s 不再是耗时代理，
    /// 实际 ~52 拍/≈1s）。
    func testTerminalDrainWhooshesLargeBacklogWithinBoundedRealtime() {
        let backlog = 24_000
        let advance = NovelSessionPresentationPacer.terminalDrainAdvance(backlogCount: backlog)
        let delayNanos = NovelSessionPresentationPacer.terminalDrainDelayNanos(advance: advance)
        XCTAssertEqual(
            advance,
            StreamPresentationPacingPolicy.terminalDrainAdvance(backlogCount: backlog),
            "Novel terminal drain advance must match Chat shared policy."
        )
        XCTAssertEqual(
            delayNanos,
            StreamPresentationPacingPolicy.terminalDrainDelayNanos(advance: advance)
        )

        let target = String(repeating: "章", count: backlog)
        var displayed = ""
        var ticks = 0
        var caughtUp = false
        while !caughtUp, ticks < 100 {
            let step = NovelSessionPresentationPacer.step(
                displayedContent: displayed,
                targetContent: target,
                mode: .terminalDrain,
                fixedTerminalAdvance: advance
            )
            displayed = step.content
            caughtUp = step.isCaughtUp
            ticks += 1
        }

        XCTAssertTrue(caughtUp)
        XCTAssertEqual(displayed, target)
        XCTAssertLessThanOrEqual(ticks, 64, "减速收尾下 2.4 万字积压应在 ~52 拍内排空")
        // 恒速 delayNanos 只代表锚速拍间隔；真实耗时按逐拍间隔积分远小于此
        // 上限，此处仍用它做量级护栏。
        let realtimeSeconds = Double(ticks) * Double(delayNanos) / 1_000_000_000
        XCTAssertLessThanOrEqual(
            realtimeSeconds,
            0.6,
            "锚速拍间隔护栏：\(realtimeSeconds)s"
        )
    }

    /// 小积压终态仍按流式上限分多拍，避免收尾半句一拍跳出。
    func testTerminalDrainPacesSmallBacklogLikeStreaming() {
        let displayed = "已显示"
        let tail = "需要我调整到更精确的 500 字、换主题，或者换个风格再写吗？"
        let target = displayed + tail
        var current = displayed
        var ticks = 0
        var caughtUp = false
        var maximumAdvance = 0
        while !caughtUp, ticks < 100 {
            let before = current.count
            let step = NovelSessionPresentationPacer.step(
                displayedContent: current,
                targetContent: target,
                mode: .terminalDrain
            )
            current = step.content
            maximumAdvance = max(maximumAdvance, current.count - before)
            caughtUp = step.isCaughtUp
            ticks += 1
        }
        XCTAssertTrue(caughtUp)
        XCTAssertEqual(current, target)
        XCTAssertLessThanOrEqual(
            maximumAdvance,
            NovelSessionPresentationPacer.maximumTextAdvance,
            "小积压终态排空单拍不得超流式上限"
        )
        XCTAssertGreaterThan(ticks, 1, "小积压应分多拍排空")
    }

    func testTerminalPacingBaseStripsStreamingFenceWhenTargetIsNormalized() {
        let body = String(repeating: "围城旧雨。", count: 20)
        let fenced = "```markdown\n\(body)\n```"
        let base = NovelSessionPresentationPacer.terminalPacingBase(
            displayedContent: fenced,
            targetContent: body,
            runKind: .prose
        )
        XCTAssertEqual(base, body)
        let step = NovelSessionPresentationPacer.terminalStep(
            displayedContent: fenced,
            targetContent: body + "续",
            runKind: .prose,
            fixedTerminalAdvance: 12
        )
        XCTAssertTrue(step.content.hasPrefix(body))
        XCTAssertFalse(step.content.hasPrefix("```"))
    }

    func testTerminalPacingDropsLeadingWhitespaceBeforeAdvancingPlainProse() {
        let raw = "\n　" + String(repeating: "旧巷落雨。", count: 40)
        let visible = String(repeating: "旧巷落雨。", count: 40)
        let target = NovelPromptCatalog.normalizedCandidateProse(
            raw + String(repeating: "续", count: 80)
        )
        XCTAssertEqual(
            NovelSessionPresentationPacer.presentationContent(raw, runKind: .prose),
            visible
        )
        XCTAssertTrue(target.hasPrefix(visible))
        let base = NovelSessionPresentationPacer.terminalPacingBase(
            displayedContent: raw,
            targetContent: target,
            runKind: .prose
        )
        XCTAssertEqual(base, visible)
        let first = NovelSessionPresentationPacer.terminalStep(
            displayedContent: raw,
            targetContent: target,
            runKind: .prose,
            fixedTerminalAdvance: 12
        )
        XCTAssertTrue(first.content.hasPrefix(visible))
        XCTAssertLessThan(first.content.count, target.count)
    }

}
