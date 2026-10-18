import XCTest
@testable import iosApp

@MainActor
final class NovelCreationPresentationTests: XCTestCase {
    func testCompendiumRoutesTheDisplayedEffectiveRevisionToItsOwningEditor() throws {
        let initial = try NovelTestFixtures.document()
        let withMaterial = try NovelReducer.apply(
            NovelTestFixtures.materialAction(
                document: initial,
                title: "项目世界观",
                content: "项目共享规则。"
            ),
            to: initial
        ).document
        let material = try XCTUnwrap(withMaterial.materials.first)
        let overrideRevisionID = NovelMaterialRevisionID()
        let overridden = try NovelReducer.apply(.setBranchMaterialOverride(
            NovelSetBranchMaterialOverrideCommand(
                context: NovelTestFixtures.context(
                    projectRevision: withMaterial.project.revision,
                    configRevision: withMaterial.project.configRevision,
                    branchHeadRevision: withMaterial.branches[0].headRevision
                ),
                projectID: withMaterial.project.id,
                branchID: withMaterial.branches[0].id,
                materialID: material.id,
                change: .createRevision(
                    revisionID: overrideRevisionID,
                    title: "当前分支世界观",
                    content: "仅当前分支采用的规则。",
                    tags: [],
                    injectionMode: .smart
                )
            )
        ), to: withMaterial).document
        let project = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: overridden,
            access: .readWrite
        ))
        let branch = overridden.branches[0]
        let branchSnapshot = NovelBranchSnapshot(
            projectID: overridden.project.id,
            projectRevision: overridden.project.revision,
            configRevision: overridden.project.configRevision,
            branch: branch,
            session: try XCTUnwrap(overridden.sessions.first { $0.id == branch.sessionID }),
            headCheckpoint: try XCTUnwrap(overridden.checkpoints.first {
                $0.id == branch.headCheckpointID
            }),
            currentState: try XCTUnwrap(overridden.stateSnapshots.first {
                $0.id == branch.currentStateSnapshotID
            }),
            chapterSelections: branch.workingChapterSelections,
            activeSettingProposals: [],
            access: .readWrite
        )

        XCTAssertEqual(
            NovelCompendiumMaterialEditTarget.resolve(
                material: material,
                project: project,
                branch: branchSnapshot
            ),
            .branchOverride
        )
        XCTAssertEqual(
            NovelCompendiumMaterialEditTarget.resolve(
                material: material,
                project: project,
                branch: nil
            ),
            .projectRevision
        )
        XCTAssertEqual(
            NovelProposalAcceptanceSheet.targetMaterialTitle(
                for: material,
                in: project
            ),
            "项目世界观",
            "接纳建议会写项目全局 revision，目标标题也必须显示全局版本"
        )
    }

    func testWorkspacePromotesManuscriptToTheMiddleTopLevelTab() {
        XCTAssertEqual(
            NovelWorkspaceSection.allCases,
            [.creation, .manuscript, .compendium]
        )
        XCTAssertEqual(
            NovelWorkspaceSection.allCases.map(\.title),
            ["创作", "正文", "设定"]
        )
        XCTAssertEqual(
            NovelCompendiumSection.allCases.map(\.title),
            ["角色", "世界观", "剧情", "更多"]
        )
    }

    func testFactValidationErrorsExplainTheActualReason() {
        XCTAssertEqual(
            NovelPresentation.operationErrorMessage(NovelError.invalidInput(
                "Unknown entity '朱重八' must be listed as unresolved."
            )),
            "模型提取的人物称谓没有和资料对齐，候选正文仍然保留，可以重新同步。"
        )
        XCTAssertEqual(
            NovelPresentation.operationErrorMessage(NovelError.invalidInput(
                "A derived fact contains evidence outside the authoritative manuscript."
            )),
            "模型提取的事实依据与正文不一致，候选正文仍然保留，可以重新同步。"
        )
    }

    func testChinesePipelineErrorPassesThroughInsteadOfGenericReload() {
        // 回归：代笔等链路直接抛中文 invalidInput，曾被统一抹成「请重新载入后再试」。
        // 中文详情原样透传；英文未知详情仍走兜底。
        XCTAssertEqual(
            NovelPresentation.operationErrorMessage(NovelError.invalidInput(
                "本章已收录，但未能清除计划。请手动清除后再继续。"
            )),
            "本章已收录，但未能清除计划。请手动清除后再继续。"
        )
        XCTAssertEqual(
            NovelPresentation.operationErrorMessage(NovelError.invalidInput(
                "Some unmatched invariants."
            )),
            "当前操作的内容或项目状态不匹配，请重新载入后再试。"
        )
    }

    func testInterruptedDraftOnlyNormalizesManuscriptRunKinds() {
        let discussion = "```markdown\n先讨论人物动机。\n```"
        XCTAssertEqual(
            NovelSessionPresentation.durableDisplayContent(
                for: .interruptedDraft,
                runKind: .discussion,
                content: discussion
            ),
            discussion
        )
        XCTAssertEqual(
            NovelSessionPresentation.durableDisplayContent(
                for: .interruptedDraft,
                runKind: .prose,
                content: discussion
            ),
            "先讨论人物动机。"
        )
    }

    func testStateSyncFailureMessageKeepsActionableDetail() {
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(for: NovelError.invalidInput(
                "The working manuscript does not form a valid manual-edit suffix."
            )),
            "剧情同步失败：目录结构已变（如删过章节），正在按新规则处理。请再点重试。"
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage("状态不符，请重试。"),
            "剧情同步失败：正文与检查点不一致（常见于删章后）。请点重试；仍失败再点「重新载入」。"
        )
        XCTAssertEqual(
            NovelError.invalidInput("本章计划未确认。").errorDescription,
            "本章计划未确认。"
        )
    }

    func testAskUserAlreadyAnsweredMapsToActionableCopy() {
        XCTAssertEqual(
            NovelPresentation.operationErrorMessage(NovelError.invalidInput(
                "This Ask User prompt has already been answered."
            )),
            "这个问题已经回答过了。请直接发送新消息继续，或换个问法。"
        )
    }

    func testNetworkNSURLErrorDumpIsHumanizedNotShownRaw() {
        let dump = """
        Exception in http request: Error Domain=NSURLErrorDomain Code=-1005 "网络连接已中断。" \
        UserInfo={_kCFStreamErrorCodeKey=-4, NSErrorFailingURLKey=https://api.deepseek.com/v1/chat/completions}
        """
        XCTAssertTrue(NovelPresentation.looksLikeTechnicalFailureDump(dump))
        XCTAssertTrue(NovelPresentation.looksLikeTransportFailure(dump))
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "provider_stream_failed",
                message: dump,
                isRetryable: true
            )),
            "网络连接中断，已保留当前回复，可以重试。若反复出现，请换一个创作模型。"
        )
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "discussion_provider_failed",
                message: dump,
                isRetryable: true
            )),
            "网络连接中断，请重试。若反复出现，请到小说设置换一个创作模型。"
        )
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "unknown_transport",
                message: dump,
                isRetryable: true
            )),
            "网络连接中断，请重试。若反复出现，请到小说设置换一个创作模型。"
        )
        // Short plain Chinese without dump markers still passes through.
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "custom",
                message: "上游限流，请稍后再试。",
                isRetryable: true
            )),
            "上游限流，请稍后再试。"
        )
    }

    func testMalformedPersistedStateSyncFailureHasActionableCopy() {
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage("The model returned malformed JSON."),
            "剧情同步模型返回的格式无法读取，请重试；若反复出现，请更换剧情同步模型。"
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "The model output is missing required fields: stateSummary, events."
            ),
            "剧情同步模型返回的格式无法读取，请重试；若反复出现，请更换剧情同步模型。"
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "The fact synchronization was cancelled and can be retried."
            ),
            "剧情状态同步已取消，可以重试。"
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "Manual-sync receipt input evidence is incomplete."
            ),
            "剧情状态同步失败，请重试。"
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage("请求失败：upstream timeout"),
            "剧情状态同步失败，请重试。"
        )
        // "revision accounting" must not be misread as a stale-reload guard.
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "Manual synchronization revision accounting failed."
            ),
            "剧情状态同步失败，请重试。"
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "The working chapter revision is stale."
            ),
            "项目版本已更新，请点「重新载入」后再同步。"
        )
    }

    func testPendingPresentationDistinguishesWaitingFromStreaming() {
        let waitingEarly = NovelSessionPendingPresentation.label(
            for: .waitingForFirstToken,
            elapsed: 1
        )
        let waitingLate = NovelSessionPendingPresentation.label(
            for: .waitingForFirstToken,
            elapsed: 12
        )
        let streaming = NovelSessionPendingPresentation.label(
            for: .streaming,
            elapsed: 12
        )

        XCTAssertEqual(waitingEarly, "正在连接模型")
        XCTAssertEqual(waitingLate, "模型思考中 12 秒")
        XCTAssertNotEqual(
            waitingLate,
            streaming,
            "waitingForFirstToken and streaming must render visibly different copy."
        )
        XCTAssertNotEqual(
            waitingEarly,
            streaming,
            "waitingForFirstToken and streaming must render visibly different copy."
        )
    }

    func testTextInputCommitterUnmarksBeforeDeferredAction() async {
        let textField = UITextField()
        textField.text = "赵"
        let end = textField.endOfDocument
        textField.selectedTextRange = textField.textRange(from: end, to: end)
        textField.setMarkedText("大来", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(textField.markedTextRange)
        XCTAssertTrue(NovelTextInputCommitter.hasMarkedText(firstResponder: textField))
        let action = expectation(description: "committed action runs after binding flush turns")
        var ranSynchronously = false

        NovelTextInputCommitter.perform(firstResponder: textField) {
            XCTAssertNil(textField.markedTextRange)
            XCTAssertEqual(textField.text, "赵大来")
            XCTAssertFalse(
                NovelTextInputCommitter.hasMarkedText(firstResponder: textField)
            )
            ranSynchronously = true
            action.fulfill()
        }

        XCTAssertNil(textField.markedTextRange)
        XCTAssertFalse(
            ranSynchronously,
            "Action must wait for yield flush so SwiftUI bindings can catch unmarkText"
        )
        await fulfillment(of: [action], timeout: 1)
        XCTAssertTrue(ranSynchronously)
    }

    func testTextInputCommitterCommitMarkedTextDoesNotRequireAction() {
        let textField = UITextField()
        textField.text = "李"
        let end = textField.endOfDocument
        textField.selectedTextRange = textField.textRange(from: end, to: end)
        textField.setMarkedText("雷", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(textField.markedTextRange)

        NovelTextInputCommitter.commitMarkedText(in: textField)

        XCTAssertNil(textField.markedTextRange)
        XCTAssertEqual(textField.text, "李雷")
    }

    func testCommitAndReadActiveUIKitTextReturnsUnmarkedValue() {
        let textField = UITextField()
        textField.text = "第"
        let end = textField.endOfDocument
        textField.selectedTextRange = textField.textRange(from: end, to: end)
        textField.setMarkedText("3章", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(textField.markedTextRange)

        let committed = NovelTextInputCommitter.commitAndReadActiveUIKitText(
            firstResponder: textField
        )

        XCTAssertEqual(committed, "第3章")
        XCTAssertNil(textField.markedTextRange)
    }

    @MainActor
    func testIMEFieldBankCommitAllFlushesMarkedTextIntoBinding() {
        final class Host: NovelIMEFieldHosting {
            var text: String
            var marked: String?
            init(text: String, marked: String?) {
                self.text = text
                self.marked = marked
            }
            var hasMarkedText: Bool { marked != nil }
            func flushMarkedTextIntoBinding() {
                if let marked {
                    text += marked
                    self.marked = nil
                }
            }
        }

        let bank = NovelIMEFieldBank()
        let placement = Host(text: "第", marked: "3章")
        let goal = Host(text: "冲突", marked: nil)
        bank.register(placement)
        bank.register(goal)
        XCTAssertTrue(bank.hasAnyMarkedText)

        bank.commitAll()

        XCTAssertEqual(placement.text, "第3章")
        XCTAssertNil(placement.marked)
        XCTAssertEqual(goal.text, "冲突")
        XCTAssertFalse(bank.hasAnyMarkedText)
    }

    func testPresentationUsesHistoricalCharacterNamesAsEffectiveAliases() throws {
        var document = try NovelTestFixtures.document()
        let materialID = NovelMaterialID()
        document = try NovelReducer.apply(.reviseMaterial(NovelReviseMaterialCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            materialID: materialID,
            revisionID: NovelMaterialRevisionID(),
            kind: .character,
            title: "赵旧名",
            content: "旧的人物设定。",
            tags: [],
            injectionMode: .smart,
            aliases: []
        )), to: document).document
        document = try NovelReducer.apply(.reviseMaterial(NovelReviseMaterialCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            materialID: materialID,
            revisionID: NovelMaterialRevisionID(),
            kind: .character,
            title: "赵大来",
            content: "当前人物设定。",
            tags: [],
            injectionMode: .smart,
            aliases: []
        )), to: document).document
        let project = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: document,
            access: .readWrite
        ))
        let material = try XCTUnwrap(document.materials.first { $0.id == materialID })

        XCTAssertEqual(
            NovelPresentation.effectiveAliases(
                for: material,
                project: project,
                branch: nil
            ),
            ["赵旧名"]
        )
    }

    func testPendingPresentationFallsBackToDefaultCopyForNonQuickStartPhases() {
        // Phases outside the quickStart streaming disclosure (or no phase at all) must keep
        // rendering the exact same copy ChatAssistantPendingResponseView already used, so
        // Chat/Council callers that never pass a phase see zero behavior change.
        for elapsed in [0, 1, 2, 9] {
            XCTAssertEqual(
                NovelSessionPendingPresentation.label(for: nil, elapsed: elapsed),
                ChatAssistantPendingResponseView.defaultLabel(elapsed: elapsed)
            )
            XCTAssertEqual(
                NovelSessionPendingPresentation.label(for: .terminalAwaitingRefresh, elapsed: elapsed),
                ChatAssistantPendingResponseView.defaultLabel(elapsed: elapsed)
            )
        }
    }

    func testStateSyncOnlyShowsPercentageAfterDurableProgressExists() {
        let projectID = NovelProjectID()
        let branchID = NovelBranchID()
        let pendingID = NovelPendingOperationID()
        let waiting = NovelStateSyncActivity(
            projectID: projectID,
            branchID: branchID,
            pendingID: pendingID,
            phase: .analyzing,
            startedAt: Date(),
            requestStartedAt: Date(),
            completedCharacters: 0,
            totalCharacters: 12_800,
            completedChunks: 0
        )
        let progressed = NovelStateSyncActivity(
            projectID: projectID,
            branchID: branchID,
            pendingID: pendingID,
            phase: .analyzing,
            startedAt: Date(),
            requestStartedAt: Date(),
            completedCharacters: 40,
            totalCharacters: 100,
            completedChunks: 1
        )
        let preparing = NovelStateSyncActivity.preparing(
            projectID: projectID,
            branchID: branchID,
            pendingID: pendingID,
            startedAt: Date()
        )

        XCTAssertEqual(waiting.completionFraction, 0)
        XCTAssertNil(waiting.displayedCompletionFraction)
        XCTAssertNil(waiting.displayedPercent)
        XCTAssertEqual(waiting.estimatedTotalSegments, 2)
        XCTAssertEqual(
            waiting.progressDetail(elapsedSeconds: 42),
            "正文共 12800 字 · 约 2 段 · 正在处理第 1 段 · 已等待 42 秒 · 本段完成后才会更新进度"
        )
        XCTAssertEqual(
            waiting.progressDetail(elapsedSeconds: 42, streamedCharacters: 517),
            "正文共 12800 字 · 约 2 段 · 正在处理第 1 段 · 已等待 42 秒 · 本段已生成 517 字"
        )
        XCTAssertEqual(progressed.displayedCompletionFraction, 0.4)
        XCTAssertEqual(progressed.displayedPercent, 40)
        XCTAssertEqual(
            progressed.progressDetail(elapsedSeconds: 90),
            "正文已处理 40% · 已完成 1 段 · 已等待 90 秒"
        )
        let multiProgressed = NovelStateSyncActivity(
            projectID: projectID,
            branchID: branchID,
            pendingID: pendingID,
            phase: .analyzing,
            startedAt: Date(),
            requestStartedAt: Date(),
            completedCharacters: 10_000,
            totalCharacters: 25_000,
            completedChunks: 1
        )
        XCTAssertEqual(
            multiProgressed.progressDetail(elapsedSeconds: 120),
            "正文已处理 40% · 已完成 1 段 / 约 4 段 · 已等待 120 秒"
        )
        XCTAssertEqual(preparing.statusTitle, "正在准备剧情状态")
        XCTAssertEqual(
            preparing.progressDetail(elapsedSeconds: 5),
            "已等待 5 秒 · 正在准备请求"
        )

        let singleChunk = NovelStateSyncActivity(
            projectID: projectID,
            branchID: branchID,
            pendingID: pendingID,
            phase: .analyzing,
            startedAt: Date(),
            requestStartedAt: Date(),
            completedCharacters: 0,
            totalCharacters: 4_000,
            completedChunks: 0
        )
        XCTAssertEqual(singleChunk.estimatedTotalSegments, 1)
        XCTAssertEqual(
            singleChunk.progressDetail(elapsedSeconds: 12),
            "正文共 4000 字 · 全文分析中 · 已等待 12 秒 · 模型返回后才会更新进度"
        )
        XCTAssertEqual(
            singleChunk.progressDetail(elapsedSeconds: 12, streamedCharacters: 88),
            "正文共 4000 字 · 全文分析中 · 已等待 12 秒 · 本段已生成 88 字"
        )
        XCTAssertEqual(
            progressed.progressDetail(elapsedSeconds: 90, streamedCharacters: 12),
            "正文已处理 40% · 已完成 1 段 · 已等待 90 秒 · 本段已生成 12 字"
        )
        let streamProgress = NovelStateSyncStreamProgress()
        let streamPendingID = NovelPendingOperationID()
        XCTAssertEqual(streamProgress.count(pendingID: streamPendingID), 0)
        streamProgress.set(pendingID: streamPendingID, characters: 640)
        XCTAssertEqual(streamProgress.count(pendingID: streamPendingID), 640)
        streamProgress.clear(pendingID: streamPendingID)
        XCTAssertEqual(streamProgress.count(pendingID: streamPendingID), 0)
        XCTAssertEqual(
            NovelManualSyncChunker.estimatedSegmentCount(manuscriptCharacterCount: 25_000),
            4
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "The model returned more than one JSON object.",
                completedChunkCount: 2
            ),
            "剧情同步模型返回的格式无法读取，请重试；若反复出现，请更换剧情同步模型。 已保存 2 段进度，重试从第 3 段继续。"
        )

        // 结构化输出失败按类别透出具体原因，不再折叠成通用文案。
        let duplicateKeyFailure = NovelStructuredModelExecutionFailure(
            code: "invalid_structured_output",
            message: "The model output contains a duplicate key.",
            isRetryable: true,
            structuredOutputFailure: NovelStructuredOutputFailure(
                category: .duplicateKey,
                path: "$.events[0]",
                message: "The model output contains a duplicate key."
            )
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(for: duplicateKeyFailure),
            "剧情同步模型返回的 JSON 存在重复字段；若反复出现，请更换剧情同步模型。"
        )
        let missingFieldFailure = NovelStructuredModelExecutionFailure(
            code: "invalid_structured_output",
            message: "The model output is missing required field 'evidence'.",
            isRetryable: true,
            structuredOutputFailure: NovelStructuredOutputFailure(
                category: .missingField,
                path: "$.events[0]",
                message: "The model output is missing required field 'evidence'."
            )
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(for: missingFieldFailure),
            "剧情同步模型返回的 JSON 缺少必需字段；若反复出现，请更换剧情同步模型。"
        )
        let malformedFailure = NovelStructuredModelExecutionFailure(
            code: "invalid_structured_output",
            message: "The model returned malformed JSON.",
            isRetryable: true,
            structuredOutputFailure: NovelStructuredOutputFailure(
                category: .malformedJSON,
                path: "$",
                message: "The model returned malformed JSON."
            )
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(for: malformedFailure),
            "剧情同步模型返回的 JSON 无法解析，输出可能被截断；若反复出现，请更换剧情同步模型。"
        )
        // 分类文案经字符串路径（durable lastError → banner）原样透出，不加双重前缀。
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(
                "剧情同步模型返回的 JSON 存在重复字段；若反复出现，请更换剧情同步模型。",
                completedChunkCount: 0
            ),
            "剧情同步模型返回的 JSON 存在重复字段；若反复出现，请更换剧情同步模型。"
        )
        // 无结构化详情的失败仍走原有 message 映射。
        let plainFailure = NovelStructuredModelExecutionFailure(
            code: "structured_no_output_timeout",
            message: "模型持续无输出，请稍后重试。",
            isRetryable: true
        )
        XCTAssertEqual(
            NovelPresentation.stateSyncFailureMessage(for: plainFailure),
            "模型持续无输出，请稍后重试。"
        )
    }

    func testChapterTitleUsesTheGeneratedMarkdownHeadingInsteadOfAGenericStoredTitle() {
        XCTAssertEqual(
            NovelPresentation.chapterDisplayTitle(
                storedTitle: "第 1 章",
                content: "# 第一章 破庙里的活人气\n\n雨是昨夜才停的。",
                ordinal: 1
            ),
            "破庙里的活人气"
        )
        XCTAssertEqual(
            NovelPresentation.chapterDisplayTitle(
                storedTitle: "第二章",
                content: "## 第二章：风雪夜归人\n\n城门将闭。",
                ordinal: 2
            ),
            "风雪夜归人"
        )
    }

    func testChapterTitlePreservesAnExplicitStoredTitleAndFallsBackWithoutAHeading() {
        XCTAssertEqual(
            NovelPresentation.chapterDisplayTitle(
                storedTitle: "夜雨入城",
                content: "# 第一章 破庙里的活人气",
                ordinal: 1
            ),
            "夜雨入城"
        )
        XCTAssertEqual(
            NovelPresentation.chapterDisplayTitle(
                storedTitle: "第 3 章",
                content: "雨是昨夜才停的。",
                ordinal: 3
            ),
            "第 3 章"
        )
    }

    func testCharacterEventMatcherPrefersNormalizedNameMatches() {
        XCTAssertTrue(NovelCharacterEventMatcher.matches(
            characterName: "沈 雾",
            entityReferences: ["沈雾"]
        ))
        XCTAssertTrue(NovelCharacterEventMatcher.matches(
            characterName: "沈雾",
            entityReferences: ["年轻时的沈雾"]
        ))
        XCTAssertFalse(NovelCharacterEventMatcher.matches(
            characterName: "沈雾",
            entityReferences: []
        ))
    }

    func testCharacterEventMatcherSupportsOneEventReferencingMultipleCharacters() {
        let event = NovelStoryEventRecord(
            id: NovelEventID(),
            sequence: 1,
            kind: "关系变化",
            summary: "沈雾与林澈达成同盟",
            entityReferences: ["沈雾", "林澈"],
            createdAt: Date()
        )

        XCTAssertEqual(
            NovelCharacterEventMatcher.events(for: "沈雾", in: [event]).map(\.id),
            [event.id]
        )
        XCTAssertEqual(
            NovelCharacterEventMatcher.events(for: "林澈", in: [event]).map(\.id),
            [event.id]
        )
    }

    func testComposerIntentMapsToTheExistingRequestContract() {
        XCTAssertEqual(NovelComposerIntent.discussionOptions, [.discuss])
        XCTAssertEqual(
            NovelComposerIntent.proseOptions,
            [.continueProse, .wholeChapter]
        )
        XCTAssertEqual(NovelComposerIntent.discuss.title, "讨论")
        XCTAssertEqual(NovelComposerIntent.continueProse.title, "写一段")
        XCTAssertEqual(NovelComposerIntent.wholeChapter.title, "写整章")
        XCTAssertEqual(NovelComposerIntent.discuss.requestValues.mode, .discussPlan)
        XCTAssertEqual(NovelComposerIntent.continueProse.requestValues.mode, .writeProse)
        XCTAssertEqual(
            NovelComposerIntent.continueProse.requestValues.granularity,
            .continuation
        )
        XCTAssertEqual(NovelComposerIntent.wholeChapter.requestValues.mode, .writeProse)
        XCTAssertEqual(
            NovelComposerIntent.wholeChapter.requestValues.granularity,
            .wholeChapter
        )
    }

    func testComposerIntentProjectsCurrentSessionState() {
        XCTAssertEqual(
            NovelComposerIntent(mode: .discussPlan, granularity: .continuation),
            .discuss
        )
        XCTAssertEqual(
            NovelComposerIntent(mode: .writeProse, granularity: .continuation),
            .continueProse
        )
        XCTAssertEqual(
            NovelComposerIntent(mode: .writeProse, granularity: .wholeChapter),
            .wholeChapter
        )
    }

    func testComposerIntentDefaultsToDiscussionAndRemembersWriteAPassage() {
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: nil,
                collaborationMode: .cocreation,
                hasConfirmedChapterPlan: false
            ),
            .discuss
        )
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: .continueProse,
                collaborationMode: .ghostwrite,
                hasConfirmedChapterPlan: false
            ),
            .continueProse
        )
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: .continueProse,
                collaborationMode: .cocreation,
                hasConfirmedChapterPlan: false,
                branchNeedsSync: true
            ),
            .discuss
        )
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: .wholeChapter,
                collaborationMode: .cocreation,
                hasConfirmedChapterPlan: true,
                branchNeedsSync: true
            ),
            .discuss
        )
    }

    func testComposerIntentFallsBackFromWholeChapterWhenGhostwriteHasNoPlan() {
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: .wholeChapter,
                collaborationMode: .ghostwrite,
                hasConfirmedChapterPlan: false
            ),
            .discuss
        )
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: .wholeChapter,
                collaborationMode: .ghostwrite,
                hasConfirmedChapterPlan: true
            ),
            .wholeChapter
        )
        XCTAssertEqual(
            NovelComposerIntentPreference.resolve(
                stored: .wholeChapter,
                collaborationMode: .cocreation,
                hasConfirmedChapterPlan: false
            ),
            .wholeChapter
        )
    }

    func testComposerIntentPreferenceRoundTripsPerProject() {
        let defaults = UserDefaults(suiteName: "composer-intent-\(UUID().uuidString)")!
        let projectID = NovelProjectID()
        XCTAssertNil(NovelComposerIntentPreference.stored(for: projectID, defaults: defaults))
        NovelComposerIntentPreference.store(.continueProse, for: projectID, defaults: defaults)
        XCTAssertEqual(
            NovelComposerIntentPreference.stored(for: projectID, defaults: defaults),
            .continueProse
        )
        XCTAssertNil(
            NovelComposerIntentPreference.stored(for: NovelProjectID(), defaults: defaults)
        )
    }

    func testGhostwriteSheetChromeKeepsToolbarLabelsShort() {
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.leadingActionTitle(canAbandonBatch: true),
            "结束"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.leadingActionTitle(canAbandonBatch: false),
            "关闭"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.trailingActionTitle(
                isGhostwriting: true,
                pauseReason: nil,
                shouldContinueSameBatch: true
            ),
            "暂停"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.trailingActionTitle(
                isGhostwriting: false,
                pauseReason: .planProposedForNewBatch,
                shouldContinueSameBatch: true
            ),
            "确认"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.trailingActionTitle(
                isGhostwriting: false,
                pauseReason: .acceptanceFailed,
                shouldContinueSameBatch: true
            ),
            "继续"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.trailingActionTitle(
                isGhostwriting: false,
                pauseReason: .blockingContinuity,
                shouldContinueSameBatch: true
            ),
            "处理"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.trailingActionTitle(
                isGhostwriting: false,
                pauseReason: .batchCompleted,
                shouldContinueSameBatch: false
            ),
            "下一批"
        )
        XCTAssertEqual(
            NovelGhostwriteSheetChrome.trailingActionTitle(
                isGhostwriting: false,
                pauseReason: nil,
                shouldContinueSameBatch: false
            ),
            "开始"
        )
    }

    func testComposerSubmissionUsesTheSameGateForButtonAndKeyboard() {
        XCTAssertTrue(NovelSessionComposerPolicy.canSubmit(canSend: true, text: "继续写"))
        XCTAssertFalse(NovelSessionComposerPolicy.canSubmit(canSend: false, text: "继续写"))
        XCTAssertFalse(NovelSessionComposerPolicy.canSubmit(canSend: true, text: " \n "))
    }

}
