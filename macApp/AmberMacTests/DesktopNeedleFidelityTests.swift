import XCTest
@testable import AmberMac

/// M2.5: the twelve needle classes a compaction must not lose, scored per class, with a hard gate on the
/// verbatim ones. The synthetic corpus is the fixed baseline every checkpoint is measured against.
@MainActor final class DesktopNeedleFidelityTests: XCTestCase {
    private let corpus = """
    Goal: 修复 macOS 打包失败。
    Progress: 运行 xcodebuild 后失败。
    Error: Command PhaseScriptExecution failed with a nonzero exit code
    exit code 65
    日志在 /Users/arquiel/Library/Logs/Build/build.log
    结论提交 e3837594 引入了该问题。
    2026-10-30 复现一次。
    model claude-sonnet-4-5 返回 1024 tokens。
    DesktopContextBudgetTests.testFittingDropsOldestTurnsAndKeepsTheNewestUserTurn 失败。
    at DesktopWorkspace.startGeneration(DesktopWorkspace.swift:753)
    用户说「不要重置历史，保留原始记录」。
    用户拒绝：不允许删除 verify 目录。
    用户批准：允许在 /tmp/验收 写入。
    """

    private let faithfulHandoff = """
    Goal: 修复 macOS 打包失败。
    Constraints: 不允许删除 verify 目录。
    Progress: Error: Command PhaseScriptExecution failed with a nonzero exit code；exit code 65。
    Decisions: 用户批准：允许在 /tmp/验收 写入。
    Critical Context: 日志 /Users/arquiel/Library/Logs/Build/build.log；提交 e3837594；2026-10-30；
    claude-sonnet-4-5；DesktopContextBudgetTests.testFittingDropsOldestTurnsAndKeepsTheNewestUserTurn；
    at DesktopWorkspace.startGeneration(DesktopWorkspace.swift:753)；1024 tokens；「不要重置历史，保留原始记录」
    """

    private let lossyHandoff = """
    Goal: 修复打包。
    Progress: 构建失败过一次，之后按用户要求继续。
    Next Steps: 重新构建。
    """

    func testEveryNeedleClassIsDetectedInTheCorpus() {
        let found = DesktopNeedleFidelity.needles(in: corpus)
        let classes = Set(found.map(\.kind))
        XCTAssertEqual(classes, Set(DesktopNeedleClass.allCases), "the baseline corpus must exercise all 12 classes; missing \(Set(DesktopNeedleClass.allCases).subtracting(classes))")
    }

    /// The per-class table is the acceptance artefact: a faithful handoff keeps every class, the lossy one does not.
    func testFaithfulHandoffKeepsEveryClassWhileTheLossyOneDropsVerbatimClasses() {
        let baseline = DesktopNeedleFidelity.report(handoff: corpus, source: corpus)
        XCTAssertEqual(baseline.regressed(below: baseline), [])

        let faithful = DesktopNeedleFidelity.report(handoff: faithfulHandoff, source: corpus)
        for kind in DesktopNeedleClass.allCases {
            XCTAssertEqual(faithful.rate(kind), 1.0, "faithful handoff lost \(kind.rawValue)")
        }

        let lossy = DesktopNeedleFidelity.report(handoff: lossyHandoff, source: corpus)
        XCTAssertGreaterThan(lossy.regressed(below: faithful).count, 0, "the scorer must see the loss")
        XCTAssertTrue(DesktopNeedleFidelity.missingCritical(handoff: lossyHandoff, source: corpus)
            .contains { $0.kind == .exitCode })
        // Paths are scored, not gated: a real session has dozens of them and no compliant handoff repeats them all.
        // The loss still shows up in the report, which is the artefact.
        XCTAssertGreaterThan(lossy.regressed(below: faithful).filter { $0 == .path || $0 == .number || $0 == .date }.count, 0,
            "dropping paths/numbers/dates must still be visible in the per-class table")
        XCTAssertFalse(DesktopNeedleFidelity.missingCritical(handoff: lossyHandoff, source: corpus)
            .contains { $0.kind == .path }, "paths must not veto a checkpoint")
    }

    func testCriticalLossRejectsTheCheckpointAndKeepsThePreviousView() async throws {
        let provider = Provider()
        let controller = DesktopConversationInsights()
        let configuration = DesktopProviderConfiguration(name: "Test", kind: .openAI,
            baseURL: "http://localhost:8080/v1", modelID: "test-model")
        let transcript = DesktopConversation(messages: (0..<8).map { index in
            DesktopMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: index == 1 ? corpus
                : "第\(index)条普通对话内容，用于凑出可压缩的历史。")
        })
        controller.generate(.compact, conversation: transcript, configuration: configuration, apiKey: "k",
            provider: provider, isCurrent: { $0 == transcript.messages.map(\.id) })
        let run = try await waitForRun(provider)
        run.yield(.snapshot(text: lossyHandoff, reasoning: ""))
        run.yield(.complete)
        await controller.waitUntilIdle(transcript.id)
        XCTAssertNil(controller.value(.compact, for: transcript), "a handoff that drops verbatim facts is rejected")
        XCTAssertTrue(controller.errors[transcript.id]?.contains("必须逐字保留") == true)
    }

    private func waitForRun(_ provider: Provider) async throws -> DesktopGeneration {
        let deadline = Date().addingTimeInterval(2)
        while provider.runs.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(provider.runs.last)
    }

    private final class Provider: DesktopTextProvider {
        var runs: [DesktopGeneration] = []
        func start(configuration: DesktopProviderConfiguration, apiKey: String,
            messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
            let run = DesktopGeneration(); runs.append(run); return run
        }
    }
}
