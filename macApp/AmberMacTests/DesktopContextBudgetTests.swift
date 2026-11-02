import XCTest
@testable import AmberMac

final class DesktopContextBudgetTests: XCTestCase {
    private func model(window: Int?, maxOutput: Int? = nil) -> DesktopModelConfiguration {
        var value = DesktopModelConfiguration(modelID: "budget-model")
        value.contextWindowTokens = window
        value.maxOutputTokens = maxOutput
        return value
    }

    private func turn(_ index: Int, text: String = "message") -> DesktopMessage {
        DesktopMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: text)
    }

    private func filler(tokens: Int) -> String {
        // The estimator charges one token per four ASCII scalars.
        String(repeating: "a", count: tokens * 4)
    }

    func testPromptBudgetReservesTheReplyHeadroom() throws {
        XCTAssertEqual(DesktopContextBudget.promptBudget(for: model(window: 100_000, maxOutput: 4_096)), 95_904)
        XCTAssertEqual(DesktopContextBudget.promptBudget(for: model(window: 200_000)), 200_000 - 8_192)
        // A window smaller than the reserve keeps half of it instead of a negative budget.
        XCTAssertEqual(DesktopContextBudget.promptBudget(for: model(window: 5_000)), 2_500)
        XCTAssertEqual(DesktopContextBudget.promptBudget(for: model(window: 2_000)), 1_024)
        XCTAssertNil(DesktopContextBudget.promptBudget(for: model(window: nil)))
        XCTAssertNil(DesktopContextBudget.promptBudget(for: model(window: 0)))
    }

    func testCompactionBoundaryKeepsTheLastTwoUserTurnsVerbatim() throws {
        let messages = (0..<8).map { turn($0) }
        let boundary = try XCTUnwrap(DesktopContextBudget.compactionBoundary(messages))
        XCTAssertEqual(boundary, 4)
        XCTAssertEqual(messages[boundary].role, .user)
        // Fewer than three user turns leaves nothing to fold in.
        XCTAssertNil(DesktopContextBudget.compactionBoundary((0..<4).map { turn($0) }))
    }

    func testCompactionBoundaryNeverCutsInsideAToolRoundTrip() throws {
        let call = DesktopMessage(role: .assistant, text: "", tools: [DesktopToolCall(id: "t1", name: "shell", status: .running)])
        let result = DesktopMessage(role: .tool, text: "ok")
        let messages = [
            DesktopMessage(role: .user, text: "first"),
            call, result,
            DesktopMessage(role: .assistant, text: "done"),
            DesktopMessage(role: .user, text: "second"),
            DesktopMessage(role: .assistant, text: "ok"),
            DesktopMessage(role: .user, text: "third"),
            DesktopMessage(role: .assistant, text: "final")
        ]
        let boundary = try XCTUnwrap(DesktopContextBudget.compactionBoundary(messages))
        XCTAssertEqual(boundary, 4)
        XCTAssertEqual(messages[boundary].role, .user)
        // The folded prefix holds the call and its result together; the retained tail starts at a user turn.
        let folded = Array(messages.prefix(boundary))
        XCTAssertTrue(folded.contains(call))
        XCTAssertTrue(folded.contains(result))
        XCTAssertFalse(folded.last?.role == .tool, "a tool result is never the last folded message")
    }

    func testNeedsCompactionUsesOneBlockingRatioAndRequiresAWindow() throws {
        let messages = [DesktopMessage(role: .user, text: "q"), DesktopMessage(role: .assistant, text: filler(tokens: 8_700))]
        XCTAssertTrue(DesktopContextBudget.needsCompaction(messages, model: model(window: 10_000)))
        let lighter = [DesktopMessage(role: .user, text: "q"), DesktopMessage(role: .assistant, text: filler(tokens: 8_000))]
        XCTAssertFalse(DesktopContextBudget.needsCompaction(lighter, model: model(window: 10_000)))
        XCTAssertFalse(DesktopContextBudget.needsCompaction(messages, model: model(window: nil)))
    }

    func testFittingDropsOldestTurnsAndKeepsTheNewestUserTurn() throws {
        let messages = [
            DesktopMessage(role: .user, text: filler(tokens: 4_000)),
            DesktopMessage(role: .assistant, text: filler(tokens: 4_000)),
            DesktopMessage(role: .user, text: filler(tokens: 4_000)),
            DesktopMessage(role: .assistant, text: "short"),
            DesktopMessage(role: .user, text: "now")
        ]
        let window = model(window: 12_000)
        let fit = DesktopContextBudget.fitting(messages, model: window)
        XCTAssertTrue(fit.trimmed)
        XCTAssertEqual(fit.messages.first?.role, .user)
        XCTAssertEqual(fit.messages.last?.text, "now")
        XCTAssertEqual(Array(fit.messages.suffix(2)).map(\.text), ["short", "now"])
        XCTAssertEqual(fit.droppedCount, 2)
        XCTAssertLessThanOrEqual(DesktopContextBudget.estimate(fit.messages), DesktopContextBudget.promptBudget(for: window)!)
    }

    func testFittingNeverDropsTheNewestUserTurnEvenWhenItAloneExceedsTheWindow() throws {
        let messages = [
            DesktopMessage(role: .user, text: "old"),
            DesktopMessage(role: .assistant, text: "old answer"),
            DesktopMessage(role: .user, text: filler(tokens: 20_000))
        ]
        let fit = DesktopContextBudget.fitting(messages, model: model(window: 5_000))
        XCTAssertEqual(fit.messages.map(\.text), [filler(tokens: 20_000)])
        XCTAssertEqual(fit.droppedCount, 2)
    }

    /// B1 regression: the leading system block (stable prefix and compaction summary) is never trimmed, even
    /// though the budget is otherwise exceeded, and the recall message before the newest user turn survives.
    func testFittingNeverDropsTheLeadingSystemBlockOrTheRecallTurn() throws {
        let system = DesktopMessage(role: .system, text: "始终使用中文，并在动手前先确认范围。")
        let recall = DesktopMessage(role: .user, text: "<memory-context>用户偏好简洁的结论。</memory-context>")
        let messages = [
            system,
            DesktopMessage(role: .user, text: filler(tokens: 4_000)),
            DesktopMessage(role: .assistant, text: filler(tokens: 4_000)),
            DesktopMessage(role: .user, text: "第二问"),
            DesktopMessage(role: .assistant, text: "第二答"),
            recall,
            DesktopMessage(role: .user, text: "最新一问")
        ]
        let fit = DesktopContextBudget.fitting(messages, model: model(window: 12_000),
            extraText: "始终使用中文，并在动手前先确认范围。")
        XCTAssertTrue(fit.trimmed)
        XCTAssertEqual(fit.messages.first, system, "the system prefix must survive every trim")
        XCTAssertTrue(fit.messages.contains(recall))
        XCTAssertEqual(fit.messages.last?.text, "最新一问")
        XCTAssertGreaterThan(fit.droppedCount, 0)
    }

    func testFittingLeavesRequestsAloneWithoutAWindowOrWithinBudget() throws {
        let messages = (0..<4).map { turn($0) }
        XCTAssertEqual(DesktopContextBudget.fitting(messages, model: model(window: nil)), .init(messages: messages, droppedCount: 0))
        XCTAssertEqual(DesktopContextBudget.fitting(messages, model: model(window: 100_000)), .init(messages: messages, droppedCount: 0))
    }

    /// M2.2: a failed compaction must not fire again on the next turn while the cooldown lasts.
    func testAutoCompactionCooldownSuppressesRepeatedFailures() {
        let owner = UUID()
        var policy = DesktopAutoCompactionPolicy(cooldown: 90)
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(policy.mayCompact(owner, now: start))
        policy.record(owner, succeeded: false, now: start)
        XCTAssertFalse(policy.mayCompact(owner, now: start + 30))
        XCTAssertTrue(policy.mayCompact(owner, now: start + 91))
        policy.record(owner, succeeded: true, now: start + 120)
        XCTAssertTrue(policy.mayCompact(owner, now: start + 121), "a success clears the cooldown")
        policy.forget(owner)
        XCTAssertTrue(policy.mayCompact(owner, now: start))
    }

    /// M2.3: the turn-invariant prefix keeps the same fingerprint across turns and changes with the summary.
    func testPrefixFingerprintTracksTheSystemBlockOnly() {
        let system = DesktopMessage(role: .system, text: "始终使用中文。")
        let summary = DesktopMessage(role: .system, text: "较早对话摘要")
        let firstTurn = [system, DesktopMessage(role: .user, text: "第一问"), DesktopMessage(role: .assistant, text: "第一答")]
        let secondTurn = firstTurn + [DesktopMessage(role: .user, text: "第二问")]
        XCTAssertEqual(DesktopContextBudget.prefixFingerprint(firstTurn),
            DesktopContextBudget.prefixFingerprint(secondTurn))
        XCTAssertNotEqual(DesktopContextBudget.prefixFingerprint(firstTurn),
            DesktopContextBudget.prefixFingerprint([summary, system] + firstTurn.dropFirst()))
    }

    func testContextOverflowDetectionCoversProviderWordings() {
        XCTAssertTrue(DesktopContextBudget.isContextOverflow("This model's maximum context length is 200000 tokens"))
        XCTAssertTrue(DesktopContextBudget.isContextOverflow("prompt is too long: 210000 tokens > 200000 maximum"))
        XCTAssertTrue(DesktopContextBudget.isContextOverflow("Input is too long for requested model"))
        XCTAssertFalse(DesktopContextBudget.isContextOverflow("429 rate limit"))
        XCTAssertFalse(DesktopContextBudget.isContextOverflow("invalid api key"))
    }

    func testTokenUsageReadsProviderReportedCacheCounts() throws {
        let cached = DesktopMessage(role: .assistant, text: "answer", canonicalJSON: #"""
        {"role":"assistant","parts":[],"usage":{"promptTokens":1000,"completionTokens":40,"cachedTokens":900,"totalTokens":1040}}
        """#)
        let uncached = DesktopMessage(role: .assistant, text: "older", canonicalJSON: #"{"usage":{"promptTokens":500,"cachedTokens":0}}"#)
        let usage = try XCTUnwrap(DesktopTokenUsage.decode(cached))
        XCTAssertEqual(usage, DesktopTokenUsage(promptTokens: 1_000, cachedTokens: 900))
        XCTAssertEqual(try XCTUnwrap(usage.cacheHitRatio), 0.9, accuracy: 0.0001)
        XCTAssertNil(DesktopTokenUsage.decode(uncached)?.cacheHitRatio)
        XCTAssertNil(DesktopTokenUsage.decode(DesktopMessage(role: .assistant, text: "plain")))
        // Newest first: a later reply without usage must not hide the previous one.
        let transcript = [cached, DesktopMessage(role: .user, text: "next"), DesktopMessage(role: .assistant, text: "no payload")]
        XCTAssertEqual(DesktopTokenUsage.latest(in: transcript), usage)
    }
}
