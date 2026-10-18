import XCTest
@testable import iosApp

final class NovelGhostwriteRecoveryTests: NovelCollaborationModeTestCase {
    func testGhostwriteQualityFailureRequiresRewriteNotReaccept() {
        XCTAssertTrue(NovelGhostwritePauseReason.acceptanceFailed.requiresRewriteOnContinue)
        XCTAssertTrue(NovelGhostwritePauseReason.obviousRepetition.requiresRewriteOnContinue)
        XCTAssertTrue(NovelGhostwritePauseReason.blockingContinuity.requiresRewriteOnContinue)
        XCTAssertTrue(NovelGhostwritePauseReason.healBudgetExhausted.requiresRewriteOnContinue)
        XCTAssertTrue(NovelGhostwritePauseReason.acceptanceFailed.allowsAutomaticQualityHeal)
        XCTAssertTrue(NovelGhostwritePauseReason.obviousRepetition.allowsAutomaticQualityHeal)
        XCTAssertFalse(NovelGhostwritePauseReason.blockingContinuity.allowsAutomaticQualityHeal)
        XCTAssertFalse(NovelGhostwritePauseReason.syncFailed.requiresRewriteOnContinue)

        let binding = NovelSessionBinding(
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        let failedID = NovelCandidateID()
        var progress = NovelGhostwriteProgress(
            binding: binding,
            phase: .paused,
            pauseReason: .acceptanceFailed,
            candidateID: failedID,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 5,
            completedChapterCount: 0,
            currentChapterIndex: 1
        )
        XCTAssertTrue(progress.mustRewriteCandidateOnResume)
        XCTAssertTrue(progress.shouldContinueSameBatch)

        let receipt = NovelGhostwriteFailureReceipt.make(
            reason: .acceptanceFailed,
            summary: "缺必发生：主角心里不爽",
            missingMustHappen: ["主角觉得京娘有点碍事、心里不爽"],
            repetitionBeats: ["赵大放缓步子等京娘"],
            attemptIndex: 1,
            sourceCandidateID: failedID,
            planDigest: "digest-1"
        )
        let first = progress.registerQualityFailureForHeal(
            reason: .acceptanceFailed,
            receipt: receipt,
            failedCandidateID: failedID
        )
        XCTAssertTrue(first.willRewrite)
        XCTAssertFalse(first.blockedByFingerprint)
        XCTAssertEqual(progress.qualityAttemptIndex, 1)
        XCTAssertNil(progress.candidateID)
        XCTAssertTrue(progress.supersededCandidateIDs.contains(failedID))
        XCTAssertEqual(progress.phase, .writing)
        XCTAssertNil(progress.pauseReason)
        XCTAssertTrue(
            NovelGhostwriteHeal.writeUserText(receipt: receipt).contains("禁止再写")
                || NovelGhostwriteHeal.writeUserText(receipt: receipt).contains("赵大")
        )

        // 第 2 次失败仍可改写；第 3 次失败后（index==3）不再自动改写。
        // 使用不同 fingerprint 的 receipt，避免指纹熔断抢先挡住预算路径。
        let receipt2 = NovelGhostwriteFailureReceipt.make(
            reason: .acceptanceFailed,
            summary: "缺必发生：另一条",
            missingMustHappen: ["另一条节拍"],
            attemptIndex: 2,
            sourceCandidateID: nil,
            planDigest: "digest-1"
        )
        let second = progress.registerQualityFailureForHeal(
            reason: .acceptanceFailed,
            receipt: receipt2,
            failedCandidateID: NovelCandidateID()
        )
        XCTAssertTrue(second.willRewrite)
        XCTAssertEqual(progress.qualityAttemptIndex, 2)
        let receipt3 = NovelGhostwriteFailureReceipt.make(
            reason: .acceptanceFailed,
            summary: "缺必发生：第三条",
            missingMustHappen: ["第三条节拍"],
            attemptIndex: 3,
            sourceCandidateID: nil,
            planDigest: "digest-1"
        )
        let third = progress.registerQualityFailureForHeal(
            reason: .acceptanceFailed,
            receipt: receipt3,
            failedCandidateID: NovelCandidateID()
        )
        XCTAssertFalse(third.willRewrite)
        XCTAssertEqual(progress.qualityAttemptIndex, 3)
        XCTAssertFalse(
            NovelGhostwriteHeal.shouldAutoRewrite(
                afterFailureCount: 3,
                maxAttempts: 3,
                reason: .acceptanceFailed
            )
        )
    }

    func testContinuityAuditIncompleteRetainsAcceptedCandidateOnResume() {
        // 回归（2026-08-10 真实链路 review）：连续性审计未完整 ≠ 质量失败。
        // 继续时复验同一已验收候选，不强制重写、不消耗改写预算、不作废候选。
        XCTAssertFalse(NovelGhostwritePauseReason.continuityAuditIncomplete.requiresRewriteOnContinue)
        XCTAssertFalse(NovelGhostwritePauseReason.continuityAuditIncomplete.allowsAutomaticQualityHeal)
        XCTAssertFalse(NovelGhostwritePauseReason.continuityAuditIncomplete.resumesWithoutConfirmedPlan)
        XCTAssertTrue(
            NovelGhostwritePauseReason.continuityAuditIncomplete.displayMessage.contains("不会重写")
        )

        let keptID = NovelCandidateID()
        let progress = NovelGhostwriteProgress(
            binding: NovelSessionBinding(
                projectID: NovelProjectID(),
                branchID: NovelBranchID()
            ),
            phase: .paused,
            pauseReason: .continuityAuditIncomplete,
            candidateID: keptID,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 3,
            completedChapterCount: 0,
            currentChapterIndex: 1
        )
        XCTAssertFalse(progress.mustRewriteCandidateOnResume)
        XCTAssertTrue(progress.shouldContinueSameBatch)
        XCTAssertFalse(progress.supersededCandidateIDs.contains(keptID))
        XCTAssertTrue(progress.statusLabel.contains("检查未稳"))
        XCTAssertTrue(progress.boardStepSummary.contains("将再检"))
        XCTAssertFalse(progress.boardStepSummary.contains("将重写"))
        XCTAssertEqual(NovelGhostwriteContinuityGate.nearScopePriorChapterCount, 4)
        XCTAssertEqual(NovelGhostwriteContinuityGate.incompleteSilentRerunCount, 1)
    }

    func testBlockingContinuityUIMarksHardInjuryNotIncomplete() {
        let progress = NovelGhostwriteProgress(
            binding: NovelSessionBinding(
                projectID: NovelProjectID(),
                branchID: NovelBranchID()
            ),
            phase: .paused,
            pauseReason: .blockingContinuity,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 2,
            completedChapterCount: 0,
            currentChapterIndex: 1
        )
        XCTAssertTrue(progress.mustRewriteCandidateOnResume)
        XCTAssertTrue(progress.statusLabel.contains("情节硬伤"))
        XCTAssertTrue(progress.boardStepSummary.contains("情节硬伤"))
        XCTAssertFalse(progress.boardStepSummary.contains("将再检"))
    }

    func testBlockingContinuityOffersThreeEditableRepairDirections() {
        let recommended = "审稿意见：第 30 章与第 34 章称谓冲突。"
        let options = NovelGhostwriteRevisionStrategy.continuityOptions(
            recommendedBrief: recommended
        )

        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(Set(options.map(\.id)).count, 3)
        XCTAssertTrue(options[0].isDefault)
        XCTAssertEqual(options[0].brief, recommended)
        XCTAssertTrue(options[1].brief.contains("补充清楚、可信的解释"))
        XCTAssertTrue(options[2].brief.contains("重新建立因果"))
    }

    func testSilentRerunOnlyWhenChunksFailed() {
        // 规则恢复入口条件：仅 failedChunk 触发静默再扫；blocking 干净报告不进入。
        XCTAssertTrue(NovelGhostwriteContinuityGate.shouldSilentRerunIncomplete(failedChunkCount: 1, alreadyReran: 0))
        XCTAssertFalse(NovelGhostwriteContinuityGate.shouldSilentRerunIncomplete(failedChunkCount: 0, alreadyReran: 0))
        XCTAssertFalse(NovelGhostwriteContinuityGate.shouldSilentRerunIncomplete(failedChunkCount: 2, alreadyReran: 1))
    }

    func testInfrastructureFailureIsNotAQualityVerdict() {
        // 基建失败（传输/解码/执行故障）不是质量判定：
        // 不强制重写、不进自动改写、可续跑，且不得误标成 acceptanceFailed。
        let reason = NovelGhostwritePauseReason.infrastructureFailed
        XCTAssertFalse(reason.requiresRewriteOnContinue)
        XCTAssertFalse(reason.allowsAutomaticQualityHeal)
        XCTAssertTrue(reason.resumesWithoutConfirmedPlan)
        XCTAssertFalse(reason.displayMessage.isEmpty)

        // 批级语义：基建失败后可续跑同一批，且不丢当前候选。
        let keptID = NovelCandidateID()
        let progress = NovelGhostwriteProgress(
            binding: NovelSessionBinding(
                projectID: NovelProjectID(),
                branchID: NovelBranchID()
            ),
            phase: .failed,
            pauseReason: .infrastructureFailed,
            candidateID: keptID,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 3,
            completedChapterCount: 0,
            currentChapterIndex: 1
        )
        XCTAssertTrue(progress.shouldContinueSameBatch)
        XCTAssertTrue(progress.canResumeWithoutConfirmedPlan)
        XCTAssertFalse(progress.mustRewriteCandidateOnResume)
        XCTAssertFalse(progress.supersededCandidateIDs.contains(keptID))

        XCTAssertEqual(
            NovelGhostwritePauseReason.failedReason(
                from: NovelError.repositoryFailure("disk full")
            ),
            .infrastructureFailed
        )
        XCTAssertEqual(
            NovelGhostwritePauseReason.failedReason(
                from: NovelStructuredModelExecutionFailure(
                    code: "provider_stream_failed",
                    message: "上游断流",
                    isRetryable: true
                )
            ),
            .infrastructureFailed
        )
        XCTAssertEqual(
            NovelGhostwritePauseReason.failedReason(
                from: NovelError.invalidInput("本章正文不完整，需要重新生成。")
            ),
            .incompleteCandidate
        )
        XCTAssertEqual(
            NovelGhostwritePauseReason.failedReason(
                from: NovelError.invalidInput("这篇稿和当前合同对不上。")
            ),
            .planMismatch
        )
        XCTAssertEqual(
            NovelGhostwritePauseReason.failedReason(
                from: NovelError.invalidInput("无关键词错误")
            ),
            .infrastructureFailed
        )
    }

    func testGhostwriteInfraRetryRetriesOnlyRetryableNonCancelled() async throws {
        // 可重试失败：第二次成功；onRetry 恰好回调一次。
        let probe = GhostwriteRetryProbe()
        let value = try await NovelGhostwriteInfraRetry.run(onRetry: { attempt in
            probe.recordRetry(attempt)
        }) {
            probe.bumpAttempt()
            if probe.attempts == 1 {
                throw NovelStructuredModelExecutionFailure(
                    code: "provider_stream_failed",
                    message: "上游断流",
                    isRetryable: true
                )
            }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(probe.attempts, 2)
        XCTAssertEqual(probe.retries, [1])

        // 可重试但耗尽：抛原错误，总尝试次数 == maxAttempts。
        let burnout = GhostwriteRetryProbe()
        do {
            let _: Int = try await NovelGhostwriteInfraRetry.run {
                burnout.bumpAttempt()
                throw NovelStructuredModelExecutionFailure(
                    code: "provider_stream_failed",
                    message: "上游断流",
                    isRetryable: true
                )
            }
            XCTFail("重试耗尽后必须抛出原错误")
        } catch let failure as NovelStructuredModelExecutionFailure {
            XCTAssertEqual(failure.failure.code, "provider_stream_failed")
        }
        XCTAssertEqual(burnout.attempts, NovelGhostwriteInfraRetry.maxAttempts)

        // 取消：即使被标记 retryable 也绝不重试，立即透传。
        let cancelled = GhostwriteRetryProbe()
        do {
            let _: Int = try await NovelGhostwriteInfraRetry.run {
                cancelled.bumpAttempt()
                throw NovelStructuredModelExecutionFailure(
                    code: "cancelled",
                    message: "模型任务已取消，可以重试。",
                    isRetryable: true
                )
            }
            XCTFail("取消不得重试")
        } catch let failure as NovelStructuredModelExecutionFailure {
            XCTAssertEqual(failure.failure.code, "cancelled")
        }
        XCTAssertEqual(cancelled.attempts, 1)

        // 不可重试失败：立即抛出。
        let nonRetryable = GhostwriteRetryProbe()
        do {
            let _: Int = try await NovelGhostwriteInfraRetry.run {
                nonRetryable.bumpAttempt()
                throw NovelStructuredModelExecutionFailure(
                    code: "invalid_structured_output",
                    message: "格式错误",
                    isRetryable: false
                )
            }
            XCTFail("不可重试失败不得重试")
        } catch let failure as NovelStructuredModelExecutionFailure {
            XCTAssertEqual(failure.failure.code, "invalid_structured_output")
        }
        XCTAssertEqual(nonRetryable.attempts, 1)
    }

    func testGhostwriteWriteBudgetFollowsStructuredExecutorCeiling() {
        // 回归：代笔写稿预算曾硬编码 16_000，常驻资料一多必撞注入预算墙。
        // 现跟随结构化执行器内部上限，由 effectiveInputBudget 按窗口与输出留位再收敛。
        XCTAssertEqual(
            NovelGhostwriteBatch.writeInputBudgetTokens,
            NovelStructuredModelExecutor.maximumInternalInputBudgetTokens
        )
        XCTAssertGreaterThan(NovelGhostwriteBatch.writeInputBudgetTokens, 16_000)
    }


    func testGhostwriteFingerprintFuseStopsSameFailureLoop() {
        let binding = NovelSessionBinding(
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        var progress = NovelGhostwriteProgress(
            binding: binding,
            phase: .writing,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 5,
            maxQualityAttempts: 3
        )
        let same = NovelGhostwriteFailureReceipt.make(
            reason: .obviousRepetition,
            summary: "开篇复读",
            repetitionBeats: ["赵大放缓步子等京娘"],
            attemptIndex: 1,
            sourceCandidateID: nil,
            planDigest: "d"
        )
        let a = progress.registerQualityFailureForHeal(
            reason: .obviousRepetition,
            receipt: same,
            failedCandidateID: NovelCandidateID()
        )
        XCTAssertTrue(a.willRewrite)
        let b = progress.registerQualityFailureForHeal(
            reason: .obviousRepetition,
            receipt: same,
            failedCandidateID: NovelCandidateID()
        )
        // 连续相同 fingerprint → 熔断，即使预算未用尽。
        XCTAssertFalse(b.willRewrite)
        XCTAssertTrue(b.blockedByFingerprint)
        XCTAssertTrue(NovelGhostwriteHeal.isStuckOnSameFingerprint(progress.recentFailureFingerprints))

        progress.resetChapterHealState()
        XCTAssertEqual(progress.qualityAttemptIndex, 0)
        XCTAssertNil(progress.lastFailureReceipt)
        XCTAssertTrue(progress.supersededCandidateIDs.isEmpty)
    }

    func testBackgroundExpirationKeepsQualityPauseReason() {
        XCTAssertEqual(
            NovelGhostwritePauseReason.afterBackgroundExpiration(
                current: .acceptanceFailed
            ),
            .acceptanceFailed
        )
        XCTAssertEqual(
            NovelGhostwritePauseReason.afterBackgroundExpiration(
                current: nil
            ),
            .backgroundInterrupted
        )
        XCTAssertEqual(
            NovelGhostwritePauseReason.afterBackgroundExpiration(
                current: .syncFailed
            ),
            .syncFailed
        )
    }

    func testResumeRewritesWhenQualityReceiptIsMaskedAsInfrastructure() {
        let failedID = NovelCandidateID()
        let progress = NovelGhostwriteProgress(
            binding: NovelSessionBinding(
                projectID: NovelProjectID(),
                branchID: NovelBranchID()
            ),
            phase: .failed,
            pauseReason: .infrastructureFailed,
            candidateID: failedID,
            chapterPlanDigest: "f6270117",
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 6,
            completedChapterCount: 2,
            currentChapterIndex: 3,
            lastFailureReceipt: NovelGhostwriteFailureReceipt.make(
                reason: .acceptanceFailed,
                summary: "缺烧开水场面",
                missingMustHappen: ["烧开水规矩"],
                repetitionBeats: [],
                continuityNotes: [],
                attemptIndex: 1,
                sourceCandidateID: failedID,
                planDigest: "f6270117"
            )
        )
        XCTAssertTrue(progress.mustRewriteCandidateOnResume)
        XCTAssertTrue(progress.shouldDropCandidateBecauseConfirmedPlanChanged("wind-north"))
        XCTAssertFalse(progress.shouldDropCandidateBecauseConfirmedPlanChanged("f6270117"))
        XCTAssertFalse(progress.shouldDropCandidateBecauseConfirmedPlanChanged(nil))

        // 点继续后会清 pauseReason、开写；回执仍在，取稿时不得复用旧候选。
        let writing = NovelGhostwriteProgress(
            binding: progress.binding,
            phase: .writing,
            pauseReason: nil,
            candidateID: nil,
            chapterPlanDigest: "f6270117",
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 6,
            completedChapterCount: 2,
            currentChapterIndex: 3,
            lastFailureReceipt: progress.lastFailureReceipt,
            supersededCandidateIDs: [failedID]
        )
        XCTAssertTrue(writing.mustRewriteCandidateOnResume)
    }

    func testUpcomingBeatsSkipAlreadyWrittenChapterNumbersAndTitles() {
        let beats = [
            "第32章《践祚》：郭威受禅登殿",
            "第33章《承旨》：明日早朝随我来",
            "细冬甲：烧开水的规矩从西营扩到京城诸司",
            "细冬乙：朝局角力，柴荣替赵大转圜",
            "细冬丙：柴荣受命出镇一方，兄弟相送",
        ]
        let partitioned = NovelGhostwriteHeal.partitionUpcomingBeats(
            beats: beats,
            existingChapterTitles: ["践祚", "承旨", "沸水", "角力"],
            canonChapterCount: 37
        )
        XCTAssertTrue(partitioned.landed.contains(where: { $0.contains("第32章") }))
        XCTAssertTrue(partitioned.landed.contains(where: { $0.contains("第33章") }))
        XCTAssertTrue(partitioned.landed.contains(where: { $0.contains("细冬乙") }))
        XCTAssertEqual(partitioned.live, [
            "细冬甲：烧开水的规矩从西营扩到京城诸司",
            "细冬丙：柴荣受命出镇一方，兄弟相送",
        ])
    }

    func testGhostwriteRevisionUserTextIncludesSourceDraft() {
        let briefOnly = NovelGhostwriteProgress.writeUserText(
            receipt: nil,
            revisionBrief: "补写碍事情绪",
            sourceDraft: nil
        )
        XCTAssertTrue(briefOnly.contains("补写碍事情绪"))
        XCTAssertFalse(briefOnly.contains("上一稿正文"))

        let withDraft = NovelGhostwriteProgress.writeUserText(
            receipt: nil,
            revisionBrief: "补写碍事情绪",
            sourceDraft: "沈砚心里一沉，只觉京娘站在一旁碍眼。"
        )
        XCTAssertTrue(withDraft.contains("【上一稿正文】"))
        XCTAssertTrue(withDraft.contains("碍眼"))
        XCTAssertTrue(withDraft.contains("【润修要求】"))
        // 自动自愈也必须钉住上一稿：确定性部分由宿主固化，不从零重写。
        let auto = NovelGhostwriteProgress.writeUserText(
            receipt: NovelGhostwriteFailureReceipt.make(
                reason: .acceptanceFailed,
                summary: "缺拍",
                missingMustHappen: ["A"],
                attemptIndex: 1,
                sourceCandidateID: nil,
                planDigest: nil
            ),
            revisionBrief: nil,
            sourceDraft: "沈砚按着刀从柳林里出来。"
        )
        XCTAssertTrue(auto.contains("【上一稿正文】"))
        XCTAssertTrue(auto.contains("柳林"))
        XCTAssertTrue(auto.contains("缺拍") || auto.contains("必须补写"))
        XCTAssertTrue(auto.contains("不要从零重写") || auto.contains("已确定"))
        XCTAssertFalse(auto.contains("开篇换新"))
        XCTAssertFalse(auto.contains("不要再用同一开篇"))
    }

    func testGhostwriteAutoHealPinsDeterminedDraftAndDoesNotForceNewOpening() {
        XCTAssertEqual(
            NovelGhostwriteHeal.writeUserText(receipt: nil),
            "请按本章计划写完整一章正文。"
        )
        let receipt = NovelGhostwriteFailureReceipt.make(
            reason: .acceptanceFailed,
            summary: "缺必发生：半渡点火",
            missingMustHappen: ["半渡点火"],
            attemptIndex: 1,
            sourceCandidateID: NovelCandidateID(),
            planDigest: "digest"
        )
        let block = receipt.healInstructionBlock()
        XCTAssertTrue(block.contains("已确定") || block.contains("不确定"))
        XCTAssertFalse(block.contains("开篇换新"))
        let text = NovelGhostwriteHeal.writeUserText(
            receipt: receipt,
            sourceDraft: "赵大没有吹角。"
        )
        XCTAssertTrue(text.contains("【上一稿正文】"))
        XCTAssertTrue(text.contains("没有吹角"))
        XCTAssertTrue(text.contains("已确定") || text.contains("不要从零重写"))
        XCTAssertFalse(text.contains("开篇换新"))
        XCTAssertFalse(text.contains("不要再用同一开篇"))
    }

    func testGhostwriteCancellationPauseReasonPrefersUserPause() {
        // 契约：协作取消不得落到「取消本批」语义——由 progress 续跑字段表达。
        XCTAssertTrue(NovelGhostwritePauseReason.userPaused.requiresRewriteOnContinue == false)
        XCTAssertTrue(
            NovelGhostwriteProgress(
                binding: NovelSessionBinding(
                    projectID: NovelProjectID(),
                    branchID: NovelBranchID()
                ),
                phase: .paused,
                pauseReason: .userPaused,
                startedAt: Date(timeIntervalSince1970: 0),
                targetChapterCount: 5,
                completedChapterCount: 2
            ).shouldContinueSameBatch
        )
        XCTAssertFalse(
            NovelGhostwriteProgress(
                binding: NovelSessionBinding(
                    projectID: NovelProjectID(),
                    branchID: NovelBranchID()
                ),
                phase: .paused,
                pauseReason: .cancelled,
                startedAt: Date(timeIntervalSince1970: 0),
                targetChapterCount: 5,
                completedChapterCount: 2
            ).shouldContinueSameBatch
        )
    }

    func testGhostwriteRevisionBriefPrefillsFromReceipt() {
        let receipt = NovelGhostwriteFailureReceipt.make(
            reason: .obviousRepetition,
            summary: "开篇复读",
            repetitionBeats: ["赵大放缓步子等京娘"],
            attemptIndex: 2,
            sourceCandidateID: nil,
            planDigest: nil
        )
        let brief = receipt.recommendedRevisionBrief()
        XCTAssertTrue(brief.contains("赵大放缓步子等京娘"))
        XCTAssertFalse(brief.isEmpty)

        let binding = NovelSessionBinding(
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        let progress = NovelGhostwriteProgress(
            binding: binding,
            phase: .paused,
            pauseReason: .acceptanceFailed,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 5
        )
        XCTAssertTrue(progress.boardStepSummary.contains("将重写"))

        let exhausted = NovelGhostwriteProgress(
            binding: binding,
            phase: .waitingUser,
            pauseReason: .healBudgetExhausted,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 5,
            qualityAttemptIndex: 3
        )
        XCTAssertTrue(exhausted.boardStepSummary.contains("待润修"))
        XCTAssertTrue(exhausted.shouldContinueSameBatch)
        XCTAssertTrue(exhausted.mustRewriteCandidateOnResume)
        XCTAssertTrue(exhausted.shouldOfferRevisionSheet)

        let revisionText = NovelGhostwriteProgress.writeUserText(
            receipt: receipt,
            revisionBrief: "补写京娘碍事的内心；开篇禁止放缓步子。"
        )
        XCTAssertTrue(revisionText.contains("补写京娘碍事"))
        XCTAssertTrue(revisionText.contains("润修要求") || revisionText.contains("本章计划"))
    }

    func testGhostwriteBatchProgressRecordRoundTripAndColdStart() throws {
        let binding = NovelSessionBinding(
            projectID: NovelProjectID(),
            branchID: NovelBranchID()
        )
        let failedID = NovelCandidateID()
        var live = NovelGhostwriteProgress(
            binding: binding,
            phase: .writing,
            pauseReason: nil,
            detailMessage: "验收未过，自动定向改写 1/2…",
            candidateID: failedID,
            chapterPlanDigest: "digest",
            autoCollectedCandidateIDs: [NovelCandidateID()],
            startedAt: Date(timeIntervalSince1970: 100),
            targetChapterCount: 5,
            completedChapterCount: 2,
            currentChapterIndex: 3,
            lastCompletedPlanSummary: "Goal: x",
            pendingSyncChapterCredit: false,
            qualityAttemptIndex: 1,
            maxQualityAttempts: 3,
            lastFailureReceipt: NovelGhostwriteFailureReceipt.make(
                reason: .acceptanceFailed,
                summary: "缺拍",
                missingMustHappen: ["A"],
                attemptIndex: 1,
                sourceCandidateID: failedID,
                planDigest: "digest"
            ),
            supersededCandidateIDs: [failedID],
            recentFailureFingerprints: ["fp1"],
            revisionBriefOverride: nil,
            didThinContractAmendThisChapter: true,
            contractAmendments: [
                NovelGhostwriteContractAmendment(
                    kind: .appendMustNot,
                    detail: "复读 beat",
                    chapterIndex: 3,
                    beforeDigest: "a",
                    afterDigest: "b"
                ),
            ]
        )
        live.phase = .writing
        let encoded = NovelGhostwriteBatchProgressRecord.from(progress: live)
        XCTAssertTrue(encoded.shouldPersist)

        let data = try JSONEncoder().encode(encoded)
        let decoded = try JSONDecoder().decode(NovelGhostwriteBatchProgressRecord.self, from: data)
        XCTAssertEqual(decoded.completedChapterCount, 2)
        XCTAssertEqual(decoded.targetChapterCount, 5)
        XCTAssertEqual(decoded.qualityAttemptIndex, 1)
        XCTAssertEqual(decoded.contractAmendments.count, 1)

        let restored = decoded.makeProgress()
        // 写稿中杀进程 → 冷启动收成暂停可续。
        XCTAssertEqual(restored.phase, .paused)
        XCTAssertEqual(restored.pauseReason, .backgroundInterrupted)
        XCTAssertEqual(restored.completedChapterCount, 2)
        XCTAssertTrue(restored.shouldContinueSameBatch)
        XCTAssertTrue(restored.canResumeWithoutConfirmedPlan)
        XCTAssertTrue(restored.mustRewriteCandidateOnResume)
        XCTAssertTrue(restored.detailMessage?.contains("恢复") == true)

        var pending = encoded
        pending.phase = .syncing
        pending.pendingSyncChapterCredit = true
        pending.pauseReason = nil
        let afterSyncKill = pending.makeProgress()
        XCTAssertEqual(afterSyncKill.pauseReason, .syncFailed)
        XCTAssertTrue(afterSyncKill.pendingSyncChapterCredit)
        XCTAssertTrue(afterSyncKill.shouldContinueSameBatch)

        // 已同步成功后补记账：credit 清掉、completed+1（未达 target 时 batch 未完成）。
        var mid = afterSyncKill
        mid.completedChapterCount = 2
        mid.targetChapterCount = 5
        mid.pendingSyncChapterCredit = true
        XCTAssertFalse(mid.applyPendingSyncChapterCredit())
        XCTAssertEqual(mid.completedChapterCount, 3)
        XCTAssertFalse(mid.pendingSyncChapterCredit)
        XCTAssertNil(mid.pauseReason)

        var done = encoded
        done.completedChapterCount = 5
        done.phase = .waitingUser
        done.pauseReason = .batchCompleted
        XCTAssertFalse(done.shouldPersist)
    }

    func testGhostwriteBatchProgressSidecarRepositoryRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostwrite-progress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)

        let binding = NovelSessionBinding(
            projectID: document.project.id,
            branchID: document.project.mainBranchID
        )
        let progress = NovelGhostwriteProgress(
            binding: binding,
            phase: .paused,
            pauseReason: .healBudgetExhausted,
            detailMessage: "待润修",
            startedAt: Date(timeIntervalSince1970: 1),
            targetChapterCount: 4,
            completedChapterCount: 1,
            currentChapterIndex: 2,
            qualityAttemptIndex: 3
        )
        let record = NovelGhostwriteBatchProgressRecord.from(progress: progress)
        try await repository.saveGhostwriteBatchProgress(record)
        let loaded = try await repository.loadGhostwriteBatchProgress(
            projectID: binding.projectID,
            branchID: binding.branchID
        )
        XCTAssertEqual(loaded?.completedChapterCount, 1)
        XCTAssertEqual(loaded?.pauseReason, .healBudgetExhausted)
        XCTAssertEqual(loaded?.targetChapterCount, 4)

        try await repository.removeGhostwriteBatchProgress(
            projectID: binding.projectID,
            branchID: binding.branchID
        )
        let gone = try await repository.loadGhostwriteBatchProgress(
            projectID: binding.projectID,
            branchID: binding.branchID
        )
        XCTAssertNil(gone)
    }

    func testGhostwriteHealInjectionUsesEmptySessionCursorContract() {
        // GenerationLifecycle 在 suppressRecentSessionMessages 时传 sessionCursorLimit=.empty 且 max messages 0。
        // 这里锁 planner 契约：empty cursor → 无近期会话段。
        let request = NovelInjectionPlanningRequest(
            branchID: NovelBranchID(),
            promptKind: .proseWholeChapter,
            userText: "重写",
            sessionCursorLimit: .empty,
            budget: NovelInjectionBudget(
                maxEstimatedInputTokens: 16_000,
                chapterTailCharacterLimit: 6_000,
                maximumRecentSessionMessages: 0
            )
        )
        XCTAssertEqual(request.sessionCursorLimit, .empty)
        XCTAssertEqual(request.budget.maximumRecentSessionMessages, 0)
    }

}

/// 重试测试的计数探针：闭包是 @Sendable，计数走锁保证可变捕获合法。
private final class GhostwriteRetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0
    private var retryLog: [Int] = []

    var attempts: Int { lock.withLock { attemptCount } }
    var retries: [Int] { lock.withLock { retryLog } }

    func bumpAttempt() {
        lock.withLock { attemptCount += 1 }
    }

    func recordRetry(_ attempt: Int) {
        lock.withLock { retryLog.append(attempt) }
    }
}
