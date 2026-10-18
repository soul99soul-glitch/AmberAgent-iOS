import XCTest
@testable import iosApp

@MainActor
final class NovelCreationActionPresentationTests: XCTestCase {
    func testAskUserExplainsWhyItCannotBeAnswered() {
        XCTAssertEqual(
            NovelSessionComposerPolicy.askUserBlocker(
                access: .degradedPrevious(primaryFailure: "primary unavailable"),
                requiresReload: false,
                isBusy: false
            ),
            .projectReadOnly
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.askUserBlocker(
                access: .readWrite,
                requiresReload: true,
                isBusy: false
            ),
            .reloadRequired
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.askUserBlocker(
                access: .readWrite,
                requiresReload: false,
                isBusy: true
            ),
            .transactionInProgress
        )
        XCTAssertNil(NovelSessionComposerPolicy.askUserBlocker(
            access: .readWrite,
            requiresReload: false,
            isBusy: false
        ))
    }

    func testPolishTransactionActionsExplainTheFirstBlockingCondition() {
        XCTAssertEqual(
            NovelSessionComposerPolicy.polishTransactionBlocker(
                access: .degradedPrevious(primaryFailure: "corrupt"),
                requiresReload: true,
                isRunning: true,
                isBusy: true
            ),
            .projectReadOnly
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.polishTransactionBlocker(
                access: .readWrite,
                requiresReload: true,
                isRunning: true,
                isBusy: true
            ),
            .reloadRequired
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.polishTransactionBlocker(
                access: .readWrite,
                requiresReload: false,
                isRunning: true,
                isBusy: true
            ),
            .generationRunning
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.polishTransactionBlocker(
                access: .readWrite,
                requiresReload: false,
                isRunning: false,
                isBusy: true
            ),
            .transactionInProgress
        )
        XCTAssertNil(NovelSessionComposerPolicy.polishTransactionBlocker(
            access: .readWrite,
            requiresReload: false,
            isRunning: false,
            isBusy: false
        ))
    }

    func testGenerationStatusFollowsTheActiveRunInsteadOfTheComposerSelection() {
        XCTAssertTrue(NovelSessionComposerPolicy.showsGenerationStatus(
            isRunning: true,
            activeRunKind: .prose
        ))
        XCTAssertTrue(NovelSessionComposerPolicy.showsGenerationStatus(
            isRunning: true,
            activeRunKind: .regenerate
        ))
        XCTAssertTrue(NovelSessionComposerPolicy.showsGenerationStatus(
            isRunning: true,
            activeRunKind: .polish
        ))
        XCTAssertFalse(NovelSessionComposerPolicy.showsGenerationStatus(
            isRunning: true,
            activeRunKind: .discussion
        ))
        XCTAssertFalse(NovelSessionComposerPolicy.showsGenerationStatus(
            isRunning: false,
            activeRunKind: .prose
        ))
        XCTAssertFalse(
            NovelSessionComposerPolicy.showsGenerationStatus(
                isRunning: true,
                activeRunKind: .prose,
                hasGhostwriteProgress: true
            ),
            "Ghostwrite chrome owns the dock; co-create strip must not stack above it."
        )
    }

    func testRuntimeRowActionsExposeTheirBlockingReasonInsteadOfDroppingTaps() {
        XCTAssertEqual(
            NovelSessionComposerPolicy.runtimeActionBlocker(
                requiresReload: true,
                hasRefreshError: false,
                isBusy: false
            ),
            .reloadRequired
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.runtimeActionBlocker(
                requiresReload: false,
                hasRefreshError: true,
                isBusy: false
            ),
            .reloadRequired
        )
        XCTAssertEqual(
            NovelSessionComposerPolicy.runtimeActionBlocker(
                requiresReload: false,
                hasRefreshError: false,
                isBusy: true
            ),
            .transactionInProgress
        )
        XCTAssertNil(NovelSessionComposerPolicy.runtimeActionBlocker(
            requiresReload: false,
            hasRefreshError: false,
            isBusy: false
        ))
    }

    func testDerivedProposalRequiresAnExplicitMaterialKindAndRoutesToMore() {
        let proposal = NovelSettingProposalRecord(
            id: NovelProposalID(),
            branchID: NovelBranchID(),
            title: "新增线索",
            content: "旧港口可能藏有一条密道。",
            createdAt: Date(),
            isResolved: false,
            origin: .derivedState
        )

        XCTAssertNil(NovelProposalAcceptanceSheet.initialKindChoice(for: proposal))
        XCTAssertEqual(
            NovelSettingProposalRoute(kind: proposal.suggestedMaterialKind),
            .more
        )
    }

    func testQuickStartProposalKeepsItsSuggestedMaterialKind() {
        let proposal = NovelSettingProposalRecord(
            id: NovelProposalID(),
            branchID: NovelBranchID(),
            title: "潮汐城",
            content: "退潮会暴露旧城区。",
            createdAt: Date(),
            isResolved: false,
            origin: .quickStart(runID: NovelRunID(), suggestedKind: .world)
        )

        XCTAssertEqual(
            NovelProposalAcceptanceSheet.initialKindChoice(for: proposal),
            NovelMaterialKindChoice(kind: .world)
        )
    }

    func testContextualCharacterProposalKeepsItsSuggestedMaterialKind() {
        let proposal = NovelSettingProposalRecord(
            id: NovelProposalID(),
            branchID: NovelBranchID(),
            title: "郭威",
            content: "后汉枢密使，后来建立后周。",
            createdAt: Date(),
            isResolved: false,
            origin: .contextualCharacter(
                runID: NovelRunID(),
                sourceMention: "郭威",
                suggestedKind: .character
            ),
            suggestedCharacterAliases: ["郭威", "郭雀儿"]
        )

        XCTAssertEqual(
            NovelProposalAcceptanceSheet.initialKindChoice(for: proposal),
            NovelMaterialKindChoice(kind: .character)
        )
    }

    func testWritingRequirementsProposalDefaultsToTheExistingManagedMaterial() {
        let existingID = NovelMaterialID()
        let existingRevisionID = NovelMaterialRevisionID()
        let existing = NovelMaterialRecord(
            id: existingID,
            kind: .writingRequirements,
            currentRevisionID: existingRevisionID,
            revisionIDs: [existingRevisionID]
        )
        let otherID = NovelMaterialID()
        let otherRevisionID = NovelMaterialRevisionID()
        let other = NovelMaterialRecord(
            id: otherID,
            kind: .world,
            currentRevisionID: otherRevisionID,
            revisionIDs: [otherRevisionID]
        )
        let proposal = NovelSettingProposalRecord(
            id: NovelProposalID(),
            branchID: NovelBranchID(),
            title: "写作要求",
            content: "克制叙述，保持线索公平。",
            createdAt: Date(),
            isResolved: false,
            origin: .quickStart(runID: NovelRunID(), suggestedKind: .writingRequirements)
        )

        XCTAssertEqual(
            NovelProposalAcceptanceSheet.initialTargetMaterialID(
                for: proposal,
                activeMaterials: [other, existing]
            ),
            existingID
        )
    }

    func testEnglishGenerationFailuresUseAChinesePresentationMessage() {
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "invalid_quick_start_output",
                message: "The quick-start output was invalid.",
                isRetryable: true
            )),
            "模型返回的创作建议格式不完整，请重新生成。"
        )
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "network",
                message: "网络连接已断开",
                isRetryable: true
            )),
            "网络连接已断开"
        )
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "provider_stream_failed",
                message: #"OpenAI stream error: {"type":"upstream_error","message":"Upstream request failed"}"#,
                isRetryable: true
            )),
            "模型上游服务在生成过程中中断，已保留当前回复，可以重试。"
        )
    }

    func testCollectionTargetDefaultsToNewChapterForWholeChapterCandidate() {
        XCTAssertEqual(
            NovelCollectionTargetChoice.initial(chapterCount: 3, granularity: .wholeChapter, hasRegenerationTarget: false),
            .createNext
        )
        XCTAssertEqual(
            NovelCollectionTargetChoice.initial(chapterCount: 0, granularity: .wholeChapter, hasRegenerationTarget: false),
            .createNext
        )
    }

    /// 重新生成的候选默认就该替换来源章——那是发起这次生成的本意;
    /// 这条优先级高于按粒度推断的默认值。
    func testCollectionTargetDefaultsToReplaceForRegeneratedCandidate() {
        XCTAssertEqual(
            NovelCollectionTargetChoice.initial(
                chapterCount: 3,
                granularity: .wholeChapter,
                hasRegenerationTarget: true
            ),
            .replaceChapter
        )
        XCTAssertEqual(
            NovelCollectionTargetChoice.initial(
                chapterCount: 3,
                granularity: .continuation,
                hasRegenerationTarget: true
            ),
            .replaceChapter
        )
    }

    func testCollectionTargetDefaultsToCurrentChapterForContinuationCandidate() {
        XCTAssertEqual(
            NovelCollectionTargetChoice.initial(chapterCount: 3, granularity: .continuation, hasRegenerationTarget: false),
            .appendCurrent
        )
        XCTAssertEqual(
            NovelCollectionTargetChoice.initial(chapterCount: 0, granularity: .continuation, hasRegenerationTarget: false),
            .createNext
        )
    }

}
