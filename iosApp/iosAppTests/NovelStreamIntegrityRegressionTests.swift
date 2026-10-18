import XCTest
@testable import iosApp

@MainActor
final class NovelStreamIntegrityRegressionTests: NovelSessionViewModelTestCase {
    func testSplitOpeningFenceDoesNotLeakLanguageIntoStreamingProse() async throws {
        try await assertStreamingProse(
            chunks: ["```", "markdown\n围城旧雨。"],
            expected: "围城旧雨。"
        )
    }

    func testSplitClosingFenceDoesNotLeakIntoStreamingProse() async throws {
        try await assertStreamingProse(
            chunks: ["```markdown\n围城", "旧雨。\n```"],
            expected: "围城旧雨。"
        )
    }

    func testReplacementFenceRetainsRawSourceForSubsequentDelta() async throws {
        try await assertStreamingProse(
            steps: [.delta("旧正文"), .replacement("```markdown\n围城"), .delta("旧雨。\n```")],
            expected: "围城旧雨。"
        )
    }

    func testRepeatedReasoningDeltasPreserveEveryOccurrence() async throws {
        try await assertReasoningDeltas(["思", "思", "思"])
    }

    func testPrefixRelatedReasoningDeltasPreserveEveryOccurrence() async throws {
        try await assertReasoningDeltas(["甲", "甲乙", "甲"])
    }

    func testReasoningReplacementCanBeFollowedByDelta() async throws {
        let prose = "巷口的雨停了。"
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .reasoningDelta("替换前的较长思考"),
            .pause,
            .reasoningReplacement("改"),
            .reasoningDelta("后"),
            .pause,
            .delta(prose),
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        let started = await harness.session.send(text: "写一段正文")
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let initialReasoning = await eventually {
            harness.session.transientTail?.reasoningContent == "替换前的较长思考"
        }
        XCTAssertTrue(initialReasoning)

        await harness.adapter.resume(runID: runID)
        let replacedReasoning = await eventually {
            harness.session.transientTail?.reasoningContent == "改后"
        }
        XCTAssertTrue(replacedReasoning)
        XCTAssertEqual(harness.session.transientTail?.reasoningContent, "改后")

        await harness.adapter.resume(runID: runID)
        let completed = await eventually {
            harness.session.durableMessages.last?.content == prose
                && harness.session.transientTail == nil
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(harness.session.availableProseCandidates.first?.content, prose)
    }

    private func assertStreamingProse(
        chunks: [String],
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await assertStreamingProse(
            steps: chunks.map { .delta($0) },
            expected: expected,
            file: file,
            line: line
        )
    }

    private func assertStreamingProse(
        steps: [NovelModelScriptStep],
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let harness = try await makeHarness(scripts: [NovelModelScript(
            steps: steps + [.pause, .complete]
        )])
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        let started = await harness.session.send(text: "续写正文")
        XCTAssertTrue(started, file: file, line: line)
        let runID = try XCTUnwrap(harness.session.activeRunID, file: file, line: line)
        // Wait for the final body fragment and the pacer to catch up, so an
        // earlier correct-looking prefix cannot hide a later leaked closer.
        let caughtUp = await eventually {
            guard let tail = harness.session.transientTail,
                  let buffer = harness.session.presentationBuffer else { return false }
            return tail.content.contains(expected)
                && buffer.displayedCharacterCount == buffer.targetCharacterCount
        }
        XCTAssertTrue(caughtUp, file: file, line: line)
        XCTAssertEqual(harness.session.transientTail?.content, expected, file: file, line: line)

        await harness.adapter.resume(runID: runID)
        let completed = await eventually {
            harness.session.durableMessages.last?.content == expected
                && harness.session.transientTail == nil
        }
        XCTAssertTrue(completed, file: file, line: line)
        XCTAssertEqual(harness.session.availableProseCandidates.first?.content, expected, file: file, line: line)
    }

    private func assertReasoningDeltas(
        _ chunks: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let prose = "巷口的雨停了。"
        let harness = try await makeHarness(scripts: [NovelModelScript(
            steps: chunks.map { .reasoningDelta($0) } + [.pause, .delta(prose), .complete]
        )])
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        let started = await harness.session.send(text: "写一段正文")
        XCTAssertTrue(started, file: file, line: line)
        let runID = try XCTUnwrap(harness.session.activeRunID, file: file, line: line)
        let expectedReasoning = chunks.joined()
        let caughtUp = await eventually {
            harness.session.transientTail?.reasoningContent == expectedReasoning
        }
        XCTAssertTrue(caughtUp, file: file, line: line)
        XCTAssertEqual(
            harness.session.transientTail?.reasoningContent,
            expectedReasoning,
            file: file,
            line: line
        )

        await harness.adapter.resume(runID: runID)
        let completed = await eventually {
            harness.session.durableMessages.last?.content == prose
                && harness.session.transientTail == nil
        }
        XCTAssertTrue(completed, file: file, line: line)
        XCTAssertEqual(harness.session.availableProseCandidates.first?.content, prose, file: file, line: line)
    }
}
