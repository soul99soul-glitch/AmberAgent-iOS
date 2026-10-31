import XCTest
@testable import AmberMac

/// P2 independent review fixes exercised by the SwiftPM host: B1 (needle gate), B2 (cooldown accounting),
/// the history-tool fixes, the prefix fingerprint and the scheduled history snapshot.
/// B3 (prompt caching) and the tool-mode overflow message live in the provider, which this host cannot compile;
/// they are covered by `DesktopAgentProviderPathTests` in the Xcode target.
@MainActor final class DesktopPhase2ReviewFixTests: XCTestCase {

    // MARK: - B1: the needle gate must be usable on a real tool-heavy conversation

    /// A real 12-turn conversation with tools carries dozens of numbers, paths and dates. A compliant handoff
    /// cannot repeat all of them, so the old all-or-nothing gate rejected it forever. Only the mechanically
    /// checkable, bounded classes stay a hard gate.
    private let realisticSource = """
    Started the phase 3 work at 2026-10-31 in /Users/arquiel/.synara/worktrees/d104f2c37f52.
    Ran macApp/scripts/test-runtime.sh and it printed 485 tests with 2 skipped.
    Step 1 opened DesktopPlugins.swift:2632 and DesktopEventKitCalendarService.swift:118.
    Step 2 read DesktopWatchtower.swift at 2026-10-31 with line 42.
    Step 3 checked /Users/arquiel/Library/Logs/DiagnosticReports/xctest-2026-10-31-180822.ips
    Step 4 referenced commit e3837594 and counted 1999 lines in DesktopWorkspace.swift.
    Step 5 saw 3383 items, 4865 records and 3411 entries across three platforms.
    Step 6 measured a 245 ms frame and a 12.5 second run at 2026-10-30.
    Step 7 looked at /tmp/amber-ui-snapshot/Sources/AmberSnapshot line 61.
    Step 8 re-read DesktopContextBudget.swift line 65 and DesktopScheduledTasks.swift line 212.
    Step 9 confirmed the number 2048 and 8192 limits on 2026-10-29.
    Step 10 found /Users/arquiel/Downloads/AI/amber-macos/docs/plugins.md at 488 lines.
    Step 11 logged exit code 65 and a second exit code 1.
    Error: Command PhaseScriptExecution failed with a nonzero exit code
    Step 12 wrote /Users/arquiel/.synara/worktrees/d104f2c37f52/docs/product/macos/phase3/README.md
    """

    /// What a model actually writes when told to keep the verbatim classes: the error, the exit codes and the
    /// commit are quoted; the incidental paths, numbers and dates are summarised. That has to pass.
    private let compliantHandoff = """
    Progress: Phase 3 landed. Ran the runtime test script and it passed.
    Constraints: keep the original transcript.
    Current State: Error: Command PhaseScriptExecution failed with a nonzero exit code；exit code 65；exit code 1。
    Decisions: committed as e3837594 and moved on to P4.
    Relevant Files: the worktree docs, the plugin store and the runtime test script were edited.
    Next Steps: continue with P4.
    """

    /// The old gate would reject this (dozens of paths/numbers/dates cannot all be repeated verbatim).
    func testCompliantHandoffPassesTheHardGateOnARealisticConversation() {
        let missing = DesktopNeedleFidelity.missingCritical(handoff: compliantHandoff, source: realisticSource)
        XCTAssertTrue(missing.isEmpty,
            "a compliant handoff must not be rejected just for dropping paths, numbers or dates; still missing: \(missing.map { "\($0.kind.rawValue)=\($0.value)" })")
        // The bounded, mechanically checkable classes stay gated: this handoff still keeps the exact error text.
        let withoutError = "Progress: the build failed. Next Steps: retry."
        XCTAssertTrue(DesktopNeedleFidelity.missingCritical(handoff: withoutError, source: realisticSource)
            .contains { $0.kind == .errorText })
    }

    /// Only classes the host can verify exactly, and whose count stays small, are hard-gated.
    func testOnlyBoundedVerifiableClassesAreHardGated() {
        XCTAssertEqual(Set(DesktopNeedleClass.allCases.filter(\.isHardGated)),
            [.errorText, .exitCode, .commit, .approval, .rejection],
            "paths/numbers/dates are unbounded in real sessions and must not block compaction")
        // Scoring still covers them: the report is the artefact, not a veto.
        let report = DesktopNeedleFidelity.report(handoff: compliantHandoff, source: realisticSource)
        XCTAssertGreaterThan(report.total(.path), 0)
        XCTAssertGreaterThan(report.total(.number), 0)
    }

    /// `exit_code`, `exit-code` and `exit code` are the same needle; the old regex missed `exit_code`.
    func testExitCodeRegexAcceptsUnderscoreAndHyphenForms() {
        for text in ["exit_code 65", "exit-code 65", "exit code 65", "退出码 65", "ExitCode: 65"] {
            let found = DesktopNeedleFidelity.needles(in: text)
            XCTAssertTrue(found.contains { $0.kind == .exitCode }, "missed exit code in: \(text)")
        }
    }

    /// A bare hex run is not a commit: request ids and file digests are 12–40 hex chars too.
    func testCommitClassDoesNotClaimRequestIDsOrFileDigests() {
        let noise = """
        call-id 8f3c1d2a9b7e4f56a1b2c3d4e5f60718
        sha256 9f2c1a7b4d3e5061827c9a4b1d0e2f4a6c8b0d2e4f6a8c0b2d4e6f8a0c2e4b6d
        request_id 6E4B5A62-0000-4000-8000-00000000C0DE
        """
        let found = DesktopNeedleFidelity.needles(in: noise)
        XCTAssertFalse(found.contains { $0.kind == .commit }, "hex blobs are not commits: \(found.filter { $0.kind == .commit })")
        // A commit that is actually labelled still counts.
        let labelled = DesktopNeedleFidelity.needles(in: "已提交 e3837594，父提交 bd53f2d。")
        XCTAssertEqual(labelled.filter { $0.kind == .commit }.count, 2)
    }

    // MARK: - B2: the failed-attempt cooldown must not reset itself

    /// The old check asked "is there a summary?", which is always true once one exists, so every later turn
    /// re-summarised. It must ask whether this attempt produced a *new* checkpoint.
    func testCompactionAttemptIsJudgedByWhetherItProducedANewCheckpoint() {
        let owner = UUID()
        let existing = DesktopCompactCheckpoint(level: 1, coveredMessageIDs: [UUID(), UUID()],
            coveredCompactIDs: [], handoff: "旧 handoff", modelID: nil)
        var policy = DesktopAutoCompactionPolicy(cooldown: 90)
        let start = Date(timeIntervalSince1970: 2_000_000)

        // Failed attempt: the checkpoint count did not grow.
        let before = [existing].count
        policy.record(owner, succeeded: DesktopAutoCompactionOutcome(before: before, record: [existing]).succeeded,
            now: start)
        XCTAssertFalse(policy.mayCompact(owner, now: start.addingTimeInterval(30)),
            "a failed attempt must cool down even though a summary already exists")

        // Success: a new checkpoint appeared.
        let after = [existing, DesktopCompactCheckpoint(level: 2, coveredMessageIDs: [UUID()],
            coveredCompactIDs: [existing.id], handoff: "新 handoff", modelID: nil)]
        let next = Date(timeIntervalSince1970: 2_000_100)
        policy.record(owner, succeeded: DesktopAutoCompactionOutcome(before: after.count - 1, record: after).succeeded, now: next)
        XCTAssertTrue(policy.mayCompact(owner, now: next.addingTimeInterval(1)), "a success clears the cooldown")
    }

    func testOutcomeComparesTheActiveCheckpointNotJustItsExistence() {
        let old = DesktopCompactCheckpoint(level: 1, coveredMessageIDs: [UUID()], coveredCompactIDs: [],
            handoff: "旧", modelID: nil)
        // Same single checkpoint, replaced in place by a retry that also failed → not a new checkpoint.
        XCTAssertFalse(DesktopAutoCompactionOutcome(before: 1, record: [old]).succeeded)
        XCTAssertTrue(DesktopAutoCompactionOutcome(before: 0, record: [old]).succeeded)
        XCTAssertTrue(DesktopAutoCompactionOutcome(before: 1, record: [old, old]).succeeded)
    }

    /// The reviewed build asked `insights.value(.compact) != nil`, which is true whenever *any* summary exists, so a
    /// retry that produced nothing still recorded "succeeded" and the cooldown never engaged. This mirrors the
    /// real call site: count the checkpoints before, count them after.
    func testFailedRetryWithAnExistingCheckpointStillCoolsDown() {
        var policy = DesktopAutoCompactionPolicy(cooldown: 90)
        let owner = UUID()
        let start = Date(timeIntervalSince1970: 3_000_000)

        // One checkpoint already on disk, and the retry produced no new one.
        let existing = 1
        let outcome = DesktopAutoCompactionOutcome(before: existing, after: existing)
        XCTAssertFalse(outcome.succeeded, "an existing summary must not be read as this attempt's success")
        policy.record(owner, succeeded: outcome.succeeded, now: start)
        XCTAssertFalse(policy.mayCompact(owner, now: start.addingTimeInterval(10)))
        XCTAssertFalse(policy.mayCompact(owner, now: start.addingTimeInterval(89)))
        XCTAssertTrue(policy.mayCompact(owner, now: start.addingTimeInterval(91)))
    }

    // MARK: - Should fix: history tools

    /// Tool output is where the exact error/exit code usually lives; the old search only looked at arguments.
    func testHistorySearchFindsToolOutputAndNotJustArguments() {
        let message = DesktopMessage(role: .assistant, text: "已运行构建。", tools: [
            DesktopToolCall(id: "t1", name: "terminal_exec", input: #"{"command":"xcodebuild"}"#,
                output: "error: PhaseScriptExecution failed with exit code 65", status: .complete)
        ])
        let hits = DesktopHistoryTools.search(query: "exit code 65", in: [message], covered: [])
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.first?.snippet.contains("exit code 65") == true)
    }

    /// The same message must not appear once per matching field.
    func testHistorySearchDeduplicatesRepeatedHits() {
        let message = DesktopMessage(role: .assistant, text: "phase3 phase3 phase3", tools: [
            DesktopToolCall(id: "t1", name: "phase3_tool", input: "phase3", output: "phase3", status: .complete)
        ])
        let hits = DesktopHistoryTools.search(query: "phase3", in: [message], covered: [])
        XCTAssertEqual(hits.map(\.messageID), [message.id], "one message must yield one hit")
    }

    /// `history_fetch` returns stored text that may contain a key the user pasted; it must be redacted the same
    /// way every other tool output is.
    func testHistoryFetchRedactsCredentials() throws {
        let message = DesktopMessage(role: .user,
            text: "我的 key 是 sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789，帮我配置。")
        let payload = try DesktopHistoryTools.fetch(message.id, in: [message], covered: [])
        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertFalse(text.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"), text)
        XCTAssertTrue(text.contains("我的 key 是"), "surrounding text is preserved")
        XCTAssertEqual(payload["redacted"] as? Bool, true)
    }

    // MARK: - Should fix: prefix fingerprint

    /// Every message gets a fresh UUID, so mixing ids into the fingerprint made it change every turn and no
    /// prefix cache could ever hit.
    func testPrefixFingerprintIgnoresMessageIDs() {
        let system = DesktopMessage(role: .system, text: "始终使用中文。")
        let rebuilt = DesktopMessage(role: .system, text: "始终使用中文。")
        XCTAssertNotEqual(system.id, rebuilt.id)
        XCTAssertEqual(DesktopContextBudget.prefixFingerprint([system]),
            DesktopContextBudget.prefixFingerprint([rebuilt]),
            "the same system text must fingerprint the same across turns")
        XCTAssertNotEqual(DesktopContextBudget.prefixFingerprint([system]),
            DesktopContextBudget.prefixFingerprint([DesktopMessage(role: .system, text: "换一段系统提示")]),
            "changing the text must still change the fingerprint")
    }

    // MARK: - Should fix: scheduled runs need a history snapshot

    /// A scheduled run used to build its context without `historySnapshot`, so `history_search` answered
    /// "没有可检索的历史记录" even though the transcript was right there.
    func testScheduledRunContextCarriesAHistorySnapshot() {
        let conversation = DesktopConversation(title: "scheduled", messages: [
            DesktopMessage(role: .user, text: "第一轮"),
            DesktopMessage(role: .assistant, text: "第一轮回答"),
        ])
        let context = DesktopRunContext(conversationID: conversation.id, toolsEnabled: true)
        XCTAssertNil(context.historySnapshot, "the default stays nil for callers that do not opt in")
        let withHistory = DesktopRunContext(conversationID: conversation.id, toolsEnabled: true,
            historySnapshot: { (conversation.messages, []) })
        XCTAssertEqual(withHistory.historySnapshot?().messages.count, 2)
    }
}
