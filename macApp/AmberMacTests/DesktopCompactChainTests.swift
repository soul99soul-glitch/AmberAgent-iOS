import XCTest
@testable import AmberMac

/// Wave B (M2.4): chained, structured checkpoints — coverage, level, migration, injection, quality gate.
@MainActor final class DesktopCompactChainTests: XCTestCase {
    private func messages(_ count: Int, filler: Int = 0) -> [DesktopMessage] {
        (0..<count).map { index in
            let text = "第\(index)条" + String(repeating: "，保留目标与已确认的关键事实", count: filler)
            return DesktopMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: text)
        }
    }

    private func checkpoint(covering count: Int, of list: [DesktopMessage], level: Int = 1,
                            handoff: String = "目标：整理上下文。") -> DesktopCompactCheckpoint {
        DesktopCompactCheckpoint(level: level, coveredMessageIDs: list.prefix(count).map(\.id),
            coveredCompactIDs: [], handoff: handoff)
    }

    func testChainKeepsOnlyCheckpointsWhoseCoverageStillMatches() {
        let list = messages(8)
        let valid = checkpoint(covering: 4, of: list)
        let stale = DesktopCompactCheckpoint(coveredMessageIDs: [UUID(), UUID()], handoff: "旧摘要")
        let accepted = DesktopCompactChain.valid([stale, valid], messageIDs: list.map(\.id))
        XCTAssertEqual(accepted.map(\.id), [valid.id])
    }

    func testOnlyTheUncoveredSegmentAndThePreviousHandoffAreReadAgain() {
        let list = messages(10)
        let first = checkpoint(covering: 4, of: list, handoff: "第一份 handoff")
        let next = DesktopCompactChain.nextInput(messages: Array(list.prefix(8)), previous: first)
        XCTAssertEqual(next.handoff, "第一份 handoff")
        XCTAssertEqual(next.segment.map(\.id), list[4..<8].map(\.id), "covered turns are not re-summarised")
        XCTAssertEqual(DesktopCompactChain.nextInput(messages: list, previous: nil).segment.count, 10)
    }

    func testVersionOneSingleSlotMigratesToALevelOneCheckpoint() {
        let list = messages(6)
        let legacy = DesktopInsightValue(id: UUID(), text: "旧版纯文本摘要", sourceMessageIDs: list.prefix(4).map(\.id))
        let migrated = DesktopCompactChain.active([], legacy: legacy, messageIDs: list.map(\.id))
        XCTAssertEqual(migrated?.schema, 1)
        XCTAssertEqual(migrated?.level, 1)
        XCTAssertEqual(migrated?.coveredMessageIDs, legacy.sourceMessageIDs)
        XCTAssertEqual(migrated?.handoff, "旧版纯文本摘要")
        var broken = list
        broken[0].id = UUID()
        XCTAssertNil(DesktopCompactChain.active([], legacy: legacy, messageIDs: broken.map(\.id)),
            "a rewritten branch invalidates the migrated checkpoint")
    }

    func testHandoffIsInjectedAsAUserTurnWithItsExactCoverage() {
        let list = messages(8)
        let value = checkpoint(covering: 4, of: list, handoff: "Progress: 已写入 a.txt")
        let injected = DesktopCompactChain.injection(value)
        XCTAssertEqual(injected.role, .user)
        XCTAssertTrue(injected.text.contains("<context-handoff>"))
        XCTAssertTrue(injected.text.contains("Progress: 已写入 a.txt"))
        XCTAssertTrue(injected.text.contains("逐字") || injected.text.contains("以当时的原文为准"))
    }

    func testQualityGateRejectsAHandoffThatDoesNotShrinkTheSegment() {
        let segment = messages(4)
        XCTAssertTrue(DesktopCompactChain.reduces("目标：一句话。", comparedTo: segment, previous: nil))
        XCTAssertFalse(DesktopCompactChain.reduces(String(repeating: "冗长重复内容。", count: 500),
            comparedTo: segment, previous: nil))
    }

    /// End to end: the second compaction stores level 2 and keeps the chained coverage instead of restarting.
    func testSecondCompactionChainsInsteadOfRestarting() async throws {
        let provider = Provider()
        let controller = DesktopConversationInsights()
        let catalog = DesktopProviderConfiguration(name: "Test", kind: .openAI,
            baseURL: "http://localhost:8080/v1", modelID: "test-model")
        var transcript = DesktopConversation(messages: messages(8, filler: 3))
        controller.generate(.compact, conversation: transcript, configuration: catalog, apiKey: "k",
            provider: provider, isCurrent: { $0 == transcript.messages.map(\.id) })
        let first = try await waitForRun(provider, count: 1)
        XCTAssertEqual(provider.requests[0].first?.role, .system)
        XCTAssertEqual(provider.requests[0].dropFirst().map(\.id), transcript.messages.prefix(4).map(\.id))
        first.yield(.snapshot(text: "Goal: 整理上下文。\nProgress: 前四条已归档。", reasoning: ""))
        first.yield(.complete)
        await controller.waitUntilIdle(transcript.id)
        let level1 = try XCTUnwrap(controller.checkpoint(for: transcript))
        XCTAssertEqual(level1.level, 1)
        XCTAssertEqual(level1.coveredMessageIDs, transcript.messages.prefix(4).map(\.id))

        transcript.messages += messages(4)
        let grown = messages(4).map { message in
            DesktopMessage(id: message.id, role: message.role, text: message.text)
        }
        transcript.messages = Array(transcript.messages.prefix(8)) + grown
        controller.generate(.compact, conversation: transcript, configuration: catalog, apiKey: "k",
            provider: provider, isCurrent: { $0 == transcript.messages.map(\.id) })
        let second = try await waitForRun(provider, count: 2)
        XCTAssertTrue(provider.requests[1].contains { $0.role == .user && $0.text.contains("已有上下文 handoff") },
            "the previous handoff is handed forward")
        second.yield(.snapshot(text: "Goal: 整理上下文。\nProgress: 前八条已归档。", reasoning: ""))
        second.yield(.complete)
        await controller.waitUntilIdle(transcript.id)
        let level2 = try XCTUnwrap(controller.checkpoint(for: transcript))
        XCTAssertEqual(level2.level, 2)
        XCTAssertEqual(level2.coveredCompactIDs.first, level1.id, "the chain records what it folded in")
        XCTAssertEqual(level2.coveredMessageIDs.count, 8)
    }

    private func waitForRun(_ provider: Provider, count: Int) async throws -> DesktopGeneration {
        let deadline = Date().addingTimeInterval(2)
        while provider.runs.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(provider.runs.last)
    }

    private final class Provider: DesktopTextProvider {
        var requests: [[DesktopMessage]] = []
        var runs: [DesktopGeneration] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            requests.append(messages)
            let run = DesktopGeneration()
            runs.append(run)
            return run
        }
    }
}
