import XCTest
import ActivityKit
@testable import iosApp

final class AgentActivityPresentationTests: XCTestCase {
    func testActivityCopyReadsEverySupportedLanguageFromItsLocalizedTable() {
        let expected: [String: String] = [
            "en": "Generating",
            "zh-Hans": "正在生成",
            "zh-Hant": "產生中",
            "ja": "生成中",
            "ko": "생성 중",
            "ru": "Генерация",
        ]

        for (languageCode, value) in expected {
            XCTAssertEqual(
                AgentActivityCopy.text(
                    "agent.activity.stage.generating",
                    languageCode: languageCode
                ),
                value,
                languageCode
            )
        }
        XCTAssertEqual(AgentActivityStage.waitingForConfirmation.localizedCompactTitle(languageCode: "en"), "Confirm")
        XCTAssertEqual(AgentActivityStage.failed.localizedCompactTitle(languageCode: "en"), "Failed")
    }

    func testIndeterminateAgentWorkHasNoProgress() {
        let presentation = AgentActivityPresentation.generatingResponse(
            modelName: "private-model-name"
        )

        XCTAssertEqual(presentation.kind, .response)
        XCTAssertEqual(presentation.phase, .running)
        XCTAssertEqual(presentation.stage, .generating)
        XCTAssertEqual(presentation.metric, .none)
        XCTAssertNil(presentation.progressFraction)
        XCTAssertFalse(presentation.showsProgressRing)
        XCTAssertFalse(String(describing: presentation).contains("private-model-name"))
    }

    func testResponseLifecycleStartsConnectingThenTracksReasoningAndText() {
        XCTAssertEqual(AgentActivityResponseStagePolicy.initialStage, .preparing)
        XCTAssertNil(AgentActivityResponseStagePolicy.updatedStage(
            hasReasoningDelta: false,
            hasTextDelta: false
        ))
        XCTAssertEqual(
            AgentActivityResponseStagePolicy.updatedStage(
                hasReasoningDelta: true,
                hasTextDelta: false
            ),
            .thinking
        )
        XCTAssertEqual(
            AgentActivityResponseStagePolicy.updatedStage(
                hasReasoningDelta: true,
                hasTextDelta: true
            ),
            .thinking,
            "同一 delta 仍有 reasoning 内容时，应与 Chat 的 open reasoning 状态保持一致"
        )
        XCTAssertEqual(
            AgentActivityResponseStagePolicy.nextPublishedStage(
                current: .preparing,
                candidate: .thinking
            ),
            .thinking
        )
        XCTAssertEqual(
            AgentActivityResponseStagePolicy.nextPublishedStage(
                current: .thinking,
                candidate: .generating
            ),
            .generating
        )
        XCTAssertNil(
            AgentActivityResponseStagePolicy.nextPublishedStage(
                current: .generating,
                candidate: .thinking
            ),
            "交错 reasoning chunk 不得把系统状态从生成态拉回思考态"
        )
    }

    func testDisplayStageNormalizesPhaseOverridesForEverySystemSurface() {
        XCTAssertEqual(
            AgentActivityPresentation.response(stage: .thinking)
                .displayStage(isStale: false),
            .thinking
        )
        // 失联时保留最后一步动作，只由 displayPhase 表达"后台暂停"。
        XCTAssertEqual(
            AgentActivityPresentation.response(stage: .thinking)
                .displayStage(isStale: true),
            .thinking
        )
        XCTAssertEqual(
            AgentActivityPresentation.waitingForUser().displayStage(isStale: false),
            .waitingForConfirmation
        )
        XCTAssertEqual(
            AgentActivityPresentation.completed().displayStage(isStale: false),
            .completed
        )
    }

    func testMeasurableWorkUsesOnlyRealNumeratorAndDenominator() throws {
        let presentation = AgentActivityPresentation.measurablePreview(
            kind: .document,
            completed: 12,
            total: 30,
            unit: .item
        )

        XCTAssertEqual(
            presentation.metric,
            .progress(completed: 12, total: 30, unit: .item)
        )
        XCTAssertEqual(
            try XCTUnwrap(presentation.progressFraction),
            0.4,
            accuracy: 0.000_001
        )
        XCTAssertTrue(presentation.showsProgressRing)
        XCTAssertEqual(presentation.percentValue, 40)
    }

    func testInvalidMetricsDegradeToNoMetric() {
        XCTAssertEqual(
            AgentActivityMetric.validatedProgress(completed: -1, total: 0, unit: .item),
            .none
        )
        XCTAssertEqual(
            AgentActivityMetric.validatedProgress(completed: 31, total: 30, unit: .item),
            .none
        )
        XCTAssertEqual(
            AgentActivityMetric.count(completed: -1, unit: .source).validated,
            .none
        )
    }

    func testToolFactoryMapsRawNamesToFinitePublicSemantics() {
        XCTAssertEqual(
            AgentActivityPresentation.runningTool(toolName: "search_web").kind,
            .research
        )
        XCTAssertEqual(
            AgentActivityPresentation.runningTool(toolName: "scrape_web").stage,
            .readingWeb
        )
        XCTAssertEqual(
            AgentActivityPresentation.runningTool(toolName: "generate_image").kind,
            .imageGeneration
        )

        let privateTool = AgentActivityPresentation.runningTool(
            toolName: "curl https://internal.example.com?token=secret"
        )
        XCTAssertEqual(privateTool.kind, .workflow)
        XCTAssertEqual(privateTool.stage, .runningTool)
        XCTAssertFalse(String(describing: privateTool).contains("internal.example.com"))
        XCTAssertFalse(String(describing: privateTool).contains("secret"))
    }

    func testStateFactoriesSelectOnlySafeActions() {
        XCTAssertEqual(AgentActivityPresentation.waitingForUser().action, .openConfirmation)
        XCTAssertEqual(AgentActivityPresentation.waitingForUser(kind: .memory).kind, .memory)
        XCTAssertEqual(AgentActivityPresentation.waitingForUser(kind: .research).kind, .research)
        XCTAssertEqual(AgentActivityPresentation.waitingForUser(kind: .document).kind, .document)
        XCTAssertEqual(AgentActivityPresentation.completed().action, .viewResult)
        XCTAssertEqual(AgentActivityPresentation.failed().action, .openTask)
        XCTAssertEqual(AgentActivityPresentation.selectedFileReadFailed.action, .openTask)
        XCTAssertNil(AgentActivityPresentation.cancelled().action)
    }

    func testLockScreenDoesNotDuplicateTheWholeCardOpenTaskAction() {
        XCTAssertFalse(AgentActivityAction.openTask.showsLockScreenLabel)
        XCTAssertTrue(AgentActivityAction.openConfirmation.showsLockScreenLabel)
        XCTAssertTrue(AgentActivityAction.viewResult.showsLockScreenLabel)
    }

    func testTerminalPresentationPreservesTheRunKind() {
        let running = AgentActivityPresentation.runningTool(toolName: "generate_image")

        XCTAssertEqual(
            AgentActivityPresentation.failed().preservingKind(from: running).kind,
            .imageGeneration
        )
        XCTAssertEqual(
            AgentActivityPresentation.cancelled().preservingKind(from: running).kind,
            .imageGeneration
        )
    }

    func testStaleDisplayOverridesOnlyActivePhases() {
        XCTAssertEqual(
            AgentActivityPresentation.defaultRunning.displayPhase(isStale: true),
            .stale
        )
        XCTAssertEqual(
            AgentActivityPresentation.reconnecting().displayPhase(isStale: true),
            .stale
        )
        XCTAssertEqual(
            AgentActivityPresentation.completed().displayPhase(isStale: true),
            .completed
        )
    }

    func testStaticSystemMarkersDistinguishEveryNonRunningPhase() {
        let markers = [
            AgentActivityPresentation.reconnecting().displaySymbolName(isStale: false),
            AgentActivityPresentation.waitingForUser().displaySymbolName(isStale: false),
            AgentActivityPresentation.defaultRunning.displaySymbolName(isStale: true),
            AgentActivityPresentation.completed().displaySymbolName(isStale: false),
            AgentActivityPresentation.failed().displaySymbolName(isStale: false),
            AgentActivityPresentation.cancelled().displaySymbolName(isStale: false)
        ]

        XCTAssertEqual(Set(markers).count, markers.count)
    }

    func testLifecyclePolicyMakesOnlyActiveWorkStale() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            AgentActivityLifecyclePolicy.staleDate(for: .running, now: now),
            now.addingTimeInterval(180)
        )
        XCTAssertEqual(
            AgentActivityLifecyclePolicy.staleDate(for: .reconnecting, now: now),
            now.addingTimeInterval(60)
        )
        XCTAssertNil(AgentActivityLifecyclePolicy.staleDate(for: .waitingForUser, now: now))
        XCTAssertGreaterThan(
            AgentActivityLifecyclePolicy.relevanceScore(for: .waitingForUser),
            AgentActivityLifecyclePolicy.relevanceScore(for: .running)
        )
    }

    func testRestoreRequiresBothDurableOwnershipAndUpdatableActivityState() {
        let ownedRunIds: Set<String> = ["background-run"]

        XCTAssertTrue(AgentActivityLifecyclePolicy.shouldRestore(
            runId: "background-run",
            ownedRunIds: ownedRunIds,
            activityState: .active
        ))
        XCTAssertTrue(AgentActivityLifecyclePolicy.shouldRestore(
            runId: "background-run",
            ownedRunIds: ownedRunIds,
            activityState: .stale
        ))
        XCTAssertFalse(AgentActivityLifecyclePolicy.shouldRestore(
            runId: "orphan-run",
            ownedRunIds: ownedRunIds,
            activityState: .active
        ))
        XCTAssertFalse(AgentActivityLifecyclePolicy.shouldRestore(
            runId: "background-run",
            ownedRunIds: ownedRunIds,
            activityState: .ended
        ))
    }

    func testTerminalDismissalClearsFailuresQuicklyWithoutLingeringBanner() {
        XCTAssertEqual(
            AgentActivityLifecyclePolicy.lockScreenDismissalDelay(for: .completed),
            12
        )
        XCTAssertEqual(
            AgentActivityLifecyclePolicy.lockScreenDismissalDelay(for: .failed),
            30
        )
        XCTAssertEqual(
            AgentActivityLifecyclePolicy.lockScreenDismissalDelay(for: .cancelled),
            4
        )
        // Failures should not outrank ongoing work on the system surface.
        XCTAssertLessThan(
            AgentActivityLifecyclePolicy.relevanceScore(for: .failed),
            AgentActivityLifecyclePolicy.relevanceScore(for: .running)
        )
    }

    func testInlineControlsOnlyAppearForConfirmationAndRetry() {
        let controls = { (presentation: AgentActivityPresentation, isStale: Bool, hasConversation: Bool) in
            AgentActivityInlineControlPolicy.controls(
                presentation: presentation,
                isStale: isStale,
                hasConversation: hasConversation
            )
        }
        let approval = AgentActivityApproval(requestId: "req-1", title: "终端命令")

        XCTAssertEqual(controls(.generatingResponse(modelName: "model"), false, true), [])
        XCTAssertEqual(controls(.generatingResponse(modelName: "model"), true, true), [])
        XCTAssertEqual(controls(.waitingForUser(approval: approval), false, true), [.deny, .approve])
        XCTAssertEqual(
            controls(.waitingForUser(), false, true),
            [],
            "没有审批请求 id（例如提问）时只能轻点整岛回到对话"
        )
        XCTAssertEqual(controls(.failed(retryable: true), false, true), [.retry])
        XCTAssertEqual(controls(.failed(retryable: false), false, true), [])
        XCTAssertEqual(controls(.completed(), false, true), [])
        XCTAssertEqual(controls(.failed(retryable: true), false, false), [])
        XCTAssertEqual(controls(.waitingForUser(approval: approval), false, false), [])
    }

    func testLegacyContentStateWithoutNewFieldsStillDecodes() throws {
        let legacy = """
        {"kind":"research","phase":"running","stage":"thinking","metric":{"none":{}},"action":"openTask"}
        """
        let decoded = try JSONDecoder().decode(
            AgentActivityPresentation.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.stage, .thinking)
        XCTAssertNil(decoded.recentSteps)
        XCTAssertNil(decoded.failureReason)
        XCTAssertNil(decoded.approval)
    }

    func testNewFieldsRoundTrip() throws {
        var presentation = AgentActivityPresentation.failed(retryable: true)
        presentation.failureReason = .network
        presentation.recentSteps = [
            AgentActivityStep(stage: .searching, detail: "京都红叶"),
            AgentActivityStep(stage: .readingWeb, count: 3),
        ]
        let decoded = try JSONDecoder().decode(
            AgentActivityPresentation.self,
            from: JSONEncoder().encode(presentation)
        )
        XCTAssertEqual(decoded, presentation)

        let waiting = AgentActivityPresentation.waitingForUser(
            approval: AgentActivityApproval(requestId: "req-1", title: "终端命令")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AgentActivityPresentation.self, from: JSONEncoder().encode(waiting)),
            waiting
        )
    }

    func testStepHistoryKeepsTheLastTwoFinishedToolSteps() {
        typealias Policy = AgentActivityStepHistoryPolicy
        var history: [AgentActivityStep] = []
        var previous: AgentActivityPresentation? = nil
        func advance(_ next: AgentActivityPresentation) {
            history = Policy.history(after: previous, current: history, next: next)
            previous = next
        }

        advance(.response(stage: .preparing))
        advance(.response(stage: .thinking))
        advance(.runningTool(toolName: "search_web", input: #"{"query":"京都红叶"}"#))
        XCTAssertEqual(history, [], "思考只作为当前一步显示，不进历史")
        advance(.response(stage: .thinking))
        XCTAssertEqual(history, [AgentActivityStep(stage: .searching, detail: "京都红叶")])
        advance(.runningTool(toolName: "memory_tool"))
        advance(.response(stage: .generating))
        advance(.runningTool(toolName: "generate_image"))
        XCTAssertEqual(history, [
            AgentActivityStep(stage: .searching, detail: "京都红叶"),
            AgentActivityStep(stage: .updatingMemory),
        ])
        advance(.response(stage: .generating))
        XCTAssertEqual(history.map(\.stage), [.updatingMemory, .generatingImage], "只保留最近两步")
        advance(.waitingForUser())
        advance(.response(stage: .generating))
        XCTAssertEqual(history.map(\.stage), [.updatingMemory, .generatingImage], "等待确认不算一步")
    }

    func testClosingHistoryRecordsTheLastToolStep() {
        typealias Policy = AgentActivityStepHistoryPolicy
        let history = [AgentActivityStep(stage: .searching, detail: "京都红叶")]
        XCTAssertEqual(
            Policy.closing(last: .runningTool(toolName: "scrape_web", input: #"{"url":"https://a.com"}"#), current: history),
            [AgentActivityStep(stage: .searching, detail: "京都红叶"), AgentActivityStep(stage: .readingWeb, detail: "a.com")],
            "结束时正在进行的工具步骤也算做完"
        )
        XCTAssertEqual(Policy.closing(last: .response(stage: .generating), current: history), history)
        XCTAssertEqual(Policy.closing(last: nil, current: history), history)
    }

    func testStepBeforeAnApprovalIsKeptInHistory() {
        typealias Policy = AgentActivityStepHistoryPolicy
        let read = AgentActivityPresentation.runningTool(toolName: "scrape_web", input: #"{"url":"https://a.com"}"#)
        let waiting = AgentActivityPresentation.waitingForUser(
            approval: AgentActivityApproval(requestId: "r1", title: "npm install")
        )
        var history = Policy.history(after: read, current: [], next: waiting)
        history = Policy.history(after: waiting, current: history, next: .runningTool(toolName: "run_command"))
        XCTAssertEqual(history, [AgentActivityStep(stage: .readingWeb, detail: "a.com")], "批准后的卡片仍列出审批前读过的网页")
    }

    func testReadsSeparatedByThinkingStillMergeIntoACount() {
        typealias Policy = AgentActivityStepHistoryPolicy
        var history: [AgentActivityStep] = []
        var previous: AgentActivityPresentation? = nil
        func advance(_ next: AgentActivityPresentation) {
            history = Policy.history(after: previous, current: history, next: next)
            previous = next
        }
        for url in ["https://a.com/1", "https://www.b.com/2", "https://c.com/3"] {
            advance(.response(stage: .thinking))
            advance(.runningTool(toolName: "scrape_web", input: #"{"url":"\#(url)"}"#))
        }
        advance(.response(stage: .generating))

        XCTAssertEqual(
            history,
            [AgentActivityStep(stage: .readingWeb, detail: nil, count: 3)],
            "每轮工具之间隔着思考，连续读三个网页仍合并成「读 3 个网页」"
        )
    }

    func testStepDetailComesOnlyFromToolArgumentsAndIsShort() {
        func detail(_ tool: String, _ input: String?) -> String? {
            AgentActivityPresentation.runningTool(toolName: tool, input: input).stepDetail
        }
        XCTAssertEqual(detail("search_web", #"{"query":"  京都\n红叶  "}"#), "京都 红叶")
        XCTAssertEqual(detail("scrape_web", #"{"url":"https://www.example.com/a?b=1"}"#), "example.com")
        XCTAssertEqual(detail("workspace_read", #"{"path":"notes/2026/旅行计划.md"}"#), "旅行计划.md")
        XCTAssertNil(detail("memory_tool", #"{"content":"私密内容"}"#), "没有对象的步骤不带内容")
        XCTAssertNil(detail("search_web", "not json"))
        XCTAssertNil(
            detail("workspace_read", #"{"path":"a.md","pad":"\#(String(repeating: "x", count: 5_000))"}"#),
            "超长参数不解析"
        )
        let write = AgentActivityPresentation.runningTool(
            toolName: "workspace_file_write",
            input: #"{"path":"secret.md","content":"正文"}"#
        )
        XCTAssertEqual(write.stage, .runningTool, "写入不显示成「正在读」")
        XCTAssertNil(write.stepDetail)
        XCTAssertNil(detail("search_web", nil))

        let long = String(repeating: "长", count: 60)
        let clipped = try? XCTUnwrap(detail("search_web", #"{"query":"\#(long)"}"#))
        XCTAssertEqual(clipped?.count, AgentActivityStepDetailPolicy.maxLength)
        XCTAssertEqual(clipped?.last, "…")
    }

    func testEveryDetailedStageHasContentLabelsInEveryLanguage() {
        for language in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru"] {
            for stage in AgentActivityStepDetailPolicy.detailedStages {
                for prefix in ["now", "doneDetail"] {
                    let key = "agent.activity.\(prefix).\(stage.rawValue)"
                    let value = AgentActivityCopy.text(key, languageCode: language)
                    XCTAssertNotEqual(value, key, "\(language) 缺 \(key)")
                    XCTAssertTrue(value.contains("%@"), "\(language) \(key) 需要占位符")
                }
            }
            for stage in AgentActivityStepDetailPolicy.countableStages {
                let key = "agent.activity.doneCount.\(stage.rawValue)"
                let value = AgentActivityCopy.text(key, languageCode: language)
                XCTAssertNotEqual(value, key, "\(language) 缺 \(key)")
                XCTAssertTrue(value.contains("%ld"), "\(language) \(key) 需要数量占位符")
            }
        }
    }

    func testEveryRunningStageHasAFinishedLabelInEveryLanguage() {
        let stages: [AgentActivityStage] = [
            .thinking, .searching, .readingSources, .readingWeb, .generating,
            .generatingImage, .organizing, .readingDocument, .updatingMemory, .runningTool,
        ]
        for language in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru"] {
            for stage in stages {
                let key = "agent.activity.done.\(stage.rawValue)"
                XCTAssertNotEqual(AgentActivityCopy.text(key, languageCode: language), key, "\(language) 缺 \(key)")
            }
        }
    }

    func testIslandLingerOnlyForCompletionAndFailure() {
        XCTAssertGreaterThan(AgentActivityLifecyclePolicy.islandLingerDuration(for: .completed), 0)
        XCTAssertGreaterThan(AgentActivityLifecyclePolicy.islandLingerDuration(for: .failed), 0)
        for phase in [AgentActivityPhase.running, .reconnecting, .waitingForUser, .stale, .cancelled] {
            XCTAssertEqual(AgentActivityLifecyclePolicy.islandLingerDuration(for: phase), 0)
        }
        // 完成后至少在岛上停留 20 秒；又要短于系统给的约 30 秒后台时间，才能在挂起前按时收起。
        XCTAssertGreaterThanOrEqual(AgentActivityLifecyclePolicy.islandLingerDuration(for: .completed), 20)
        XCTAssertLessThanOrEqual(AgentActivityLifecyclePolicy.islandLingerDuration(for: .completed), 28)
    }

    func testWriteToolNamesMatchTheWorkspaceAccessList() {
        XCTAssertEqual(AgentActivityStepDetailPolicy.writeToolNames, IOSWorkspaceToolCatalog.writeToolNames)
    }

    func testKeylineOnlyTintsConfirmationAndFailure() {
        XCTAssertEqual(AgentActivityPhase.waitingForUser.keylineRole, .attention)
        XCTAssertEqual(AgentActivityPhase.failed.keylineRole, .failure)
        for phase in [AgentActivityPhase.running, .reconnecting, .stale, .completed, .cancelled] {
            XCTAssertNil(phase.keylineRole, "\(phase) 保持系统默认描边")
        }
    }

    func testRetryOwnershipAllowsOnlyLatestFailedRunForTheConversation() {
        let latest = AgentActivityDurableRunIdentity(
            runId: "run-new",
            conversationId: "conversation-a",
            status: "failed"
        )

        XCTAssertTrue(AgentActivityRetryOwnershipPolicy.allows(
            sourceRunId: "run-new",
            conversationId: "CONVERSATION-A",
            latestRun: latest
        ))
        XCTAssertFalse(AgentActivityRetryOwnershipPolicy.allows(
            sourceRunId: "run-old",
            conversationId: "conversation-a",
            latestRun: latest
        ))
        XCTAssertFalse(AgentActivityRetryOwnershipPolicy.allows(
            sourceRunId: "run-new",
            conversationId: "conversation-b",
            latestRun: latest
        ))
        XCTAssertFalse(AgentActivityRetryOwnershipPolicy.allows(
            sourceRunId: "run-new",
            conversationId: "conversation-a",
            latestRun: AgentActivityDurableRunIdentity(
                runId: "run-new",
                conversationId: "conversation-a",
                status: "completed"
            )
        ))
    }

    func testElapsedTimerFreezesOnlyForTerminalPhases() {
        let updatedAt = Date(timeIntervalSince1970: 1_120)

        XCTAssertNil(
            AgentActivityElapsedTimePolicy.frozenEndDate(
                for: .running,
                updatedAt: updatedAt
            )
        )
        XCTAssertEqual(
            AgentActivityElapsedTimePolicy.frozenEndDate(
                for: .running,
                updatedAt: updatedAt,
                isStale: true
            ),
            updatedAt
        )
        XCTAssertNil(
            AgentActivityElapsedTimePolicy.frozenEndDate(
                for: .waitingForUser,
                updatedAt: updatedAt
            )
        )
        XCTAssertEqual(
            AgentActivityElapsedTimePolicy.frozenEndDate(
                for: .completed,
                updatedAt: updatedAt
            ),
            updatedAt
        )
        XCTAssertEqual(
            AgentActivityElapsedTimePolicy.frozenEndDate(
                for: .failed,
                updatedAt: updatedAt
            ),
            updatedAt
        )
        XCTAssertEqual(
            AgentActivityElapsedTimePolicy.frozenEndDate(
                for: .cancelled,
                updatedAt: updatedAt
            ),
            updatedAt
        )
    }

    func testRestoreRetainsNewestActivityForEveryOwnedRun() {
        let candidates = [
            AgentActivityOwnershipCandidate(
                id: "run-a-old",
                runId: "run-a",
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            AgentActivityOwnershipCandidate(
                id: "run-a-new",
                runId: "run-a",
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            AgentActivityOwnershipCandidate(
                id: "run-b",
                runId: "run-b",
                updatedAt: Date(timeIntervalSince1970: 15)
            ),
            AgentActivityOwnershipCandidate(
                id: "orphan",
                runId: "orphan-run",
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
        ]

        XCTAssertEqual(
            AgentActivityOwnershipPolicy.retainedActivityIDs(
                from: candidates,
                ownedRunIds: ["run-a", "run-b"]
            ),
            ["run-a-new", "run-b"]
        )
    }

    func testNewPayloadDoesNotEncodeLegacyTextFields() throws {
        let data = try JSONEncoder().encode(AgentActivityPresentation.defaultRunning)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("statusText"))
        XCTAssertFalse(json.contains("toolTitle"))
        XCTAssertFalse(json.contains("steps"))
    }
}
