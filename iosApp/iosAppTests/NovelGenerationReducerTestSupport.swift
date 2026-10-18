import XCTest
@testable import iosApp

extension NovelGenerationReducerTests {
    func assertInvalid(
        _ document: NovelProjectDocumentV1,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NovelDocumentValidator.validate(document),
            file: file,
            line: line
        ) { error in
            guard let novelError = error as? NovelError,
                  case .invalidDocument(let issues) = novelError else {
                return XCTFail("Expected invalidDocument, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                issues.contains(where: { $0.localizedCaseInsensitiveContains(expected) }),
                "Expected an issue containing '\(expected)', got \(issues)",
                file: file,
                line: line
            )
        }
    }

    func mutateEncodedDocument(
        _ document: NovelProjectDocumentV1,
        mutation: (inout [String: Any]) throws -> Void
    ) throws -> NovelProjectDocumentV1 {
        let encoded = try JSONEncoder().encode(document)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutation(&object)
        return try JSONDecoder().decode(
            NovelProjectDocumentV1.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    func encodedJSONValue<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value),
            options: [.fragmentsAllowed]
        )
    }

    func begin(
        _ request: NovelRunRequest,
        in document: NovelProjectDocumentV1
    ) throws -> NovelProjectDocumentV1 {
        try NovelGenerationReducer.begin(
            request,
            artifacts: makeArtifacts(document: document, request: request),
            in: document,
            now: startTime
        ).document
    }

    func completedQuickStartRounds(count: Int) throws -> NovelProjectDocumentV1 {
        var document = try quickStartDocument()
        for offset in 0..<count {
            let request = makeRequest(document: document, kind: .quickStart)
            let started = try begin(request, in: document)
            document = try NovelGenerationReducer.complete(
                runID: request.id,
                content: quickStartSuggestionsJSON,
                in: started,
                now: terminalTime.addingTimeInterval(TimeInterval(offset))
            ).document
        }
        return document
    }

    func replacingSourceVersion(
        in request: NovelRunRequest,
        with sourceChapterVersionID: NovelChapterVersionID
    ) -> NovelRunRequest {
        NovelRunRequest(
            id: request.id,
            operationID: request.operationID,
            projectID: request.projectID,
            branchID: request.branchID,
            kind: request.kind,
            mode: request.mode,
            granularity: request.granularity,
            userText: request.userText,
            userMessageID: request.userMessageID,
            assistantMessageID: request.assistantMessageID,
            candidateID: request.candidateID,
            generationReceiptID: request.generationReceiptID,
            injectionReceiptID: request.injectionReceiptID,
            sourceChapterVersionID: sourceChapterVersionID,
            askUserResponse: request.askUserResponse,
            injectionOverrides: request.injectionOverrides,
            inputBudgetTokens: request.inputBudgetTokens,
            expectedProjectRevision: request.expectedProjectRevision,
            expectedConfigRevision: request.expectedConfigRevision,
            expectedBranchHeadRevision: request.expectedBranchHeadRevision
        )
    }

    func replacingSourceVersion(
        in run: NovelActiveRunRecord,
        with sourceChapterVersionID: NovelChapterVersionID
    ) -> NovelActiveRunRecord {
        NovelActiveRunRecord(
            id: run.id,
            operationID: run.operationID,
            requestPayloadSHA256: run.requestPayloadSHA256,
            branchID: run.branchID,
            sessionID: run.sessionID,
            kind: run.kind,
            mode: run.mode,
            granularity: run.granularity,
            userMessageID: run.userMessageID,
            messageID: run.messageID,
            candidateID: run.candidateID,
            sourceChapterVersionID: sourceChapterVersionID,
            contextualCharacterMention: run.contextualCharacterMention,
            baseCheckpointID: run.baseCheckpointID,
            baseHeadRevision: run.baseHeadRevision,
            status: run.status,
            partialContent: run.partialContent,
            receiptID: run.receiptID,
            startedAt: run.startedAt,
            terminalAt: run.terminalAt,
            interruptionReason: run.interruptionReason,
            terminalFailure: run.terminalFailure,
            chapterPlanDigest: run.chapterPlanDigest
        )
    }

    func makeRequest(
        document: NovelProjectDocumentV1,
        kind: NovelRunKind,
        granularity: NovelGenerationGranularity? = nil,
        sourceChapterVersionID: NovelChapterVersionID? = nil,
        askUserResponse: NovelAskUserResponse? = nil,
        contextualCharacterMention: String? = nil,
        expectedProjectRevision: Int64? = nil
    ) -> NovelRunRequest {
        let branch = document.branches[0]
        let mode: NovelSessionMode = switch kind {
        case .quickStart, .discussion, .characterProposal: .discussPlan
        case .prose, .polish, .regenerate: .writeProse
        }
        let candidateID: NovelCandidateID? = switch kind {
        case .prose, .polish, .regenerate: NovelCandidateID()
        case .quickStart, .discussion, .characterProposal: nil
        }
        return NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: branch.id,
            kind: kind,
            mode: mode,
            granularity: granularity,
            userText: "Help with the next beat.",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: candidateID,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: sourceChapterVersionID,
            askUserResponse: askUserResponse,
            contextualCharacterMention: contextualCharacterMention,
            inputBudgetTokens: 16_000,
            expectedProjectRevision: expectedProjectRevision ?? document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
    }

    func makeArtifacts(
        document: NovelProjectDocumentV1,
        request: NovelRunRequest,
        planningDocument: NovelProjectDocumentV1? = nil,
        planningUserText: String? = nil
    ) throws -> NovelGenerationStartArtifacts {
        let promptKind: NovelPromptKind = switch request.kind {
        case .quickStart:
            .quickStart
        case .characterProposal:
            .characterProposal
        case .discussion:
            .discussion
        case .prose:
            request.granularity == .continuation ? .proseContinuation : .proseWholeChapter
        case .polish:
            .wholeChapterPolish
        case .regenerate:
            .wholeChapterRegeneration
        }
        let budget = NovelInjectionBudget(
            maxEstimatedInputTokens: request.inputBudgetTokens,
            chapterTailCharacterLimit: 6_000,
            maximumRecentSessionMessages: 12
        )
        let plan = try NovelInjectionPlanner.plan(
            document: planningDocument ?? document,
            request: NovelInjectionPlanningRequest(
                branchID: request.branchID,
                promptKind: promptKind,
                userText: planningUserText ?? request.userText,
                sourceChapterVersionID: request.sourceChapterVersionID,
                overrides: request.injectionOverrides,
                budget: budget
            )
        )
        let parameters = ["temperature": "0.8", "topP": "0.95"]
        let injection = NovelInjectionReceiptRecord(
            id: request.injectionReceiptID,
            runID: request.id,
            projectID: request.projectID,
            branchID: request.branchID,
            plan: plan,
            overrides: request.injectionOverrides,
            providerID: "provider-id",
            modelID: "model-id",
            parameters: parameters,
            createdAt: startTime
        )
        let generation = NovelGenerationReceiptRecord(
            id: request.generationReceiptID,
            runID: request.id,
            providerID: injection.providerID,
            modelID: injection.modelID,
            promptVersion: injection.promptVersion,
            injectionReceiptID: injection.id,
            parameters: injection.parameters,
            requestSHA256: NovelDocumentValidator.sha256(plan.canonicalInput + "\nMODEL REQUEST"),
            createdAt: startTime
        )
        return NovelGenerationStartArtifacts(
            injectionReceipt: injection,
            generationReceipt: generation
        )
    }

    func quickStartDocument() throws -> NovelProjectDocumentV1 {
        let command = NovelCreateProjectCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: NovelProjectID(),
            branchID: NovelBranchID(),
            sessionID: NovelSessionID(),
            initialStateSnapshotID: NovelStateSnapshotID(),
            initialCheckpointID: NovelCheckpointID(),
            name: "Quick Novel",
            branchName: "Main",
            creationMode: .quickStart,
            quickStartSeed: NovelQuickStartSeed(
                genre: "Mystery",
                coreIdea: "A memory can testify in court."
            )
        )
        return try NovelReducer.createProject(
            command,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        ).document
    }

    var quickStartSuggestionsJSON: String {
        """
        {
          "schemaVersion": 2,
          "overview": "A courtroom mystery built around traded memories.",
          "world": {"title": "Memory law", "content": "A verified memory may testify once."},
          "characters": [
            {"title": "Mara", "content": "The advocate risks her last childhood memory."},
            {"title": "Ivo", "content": "The witness knows who forged the first memory."}
          ],
          "masterOutline": {"title": "The appeal", "content": "A false memory forces the case to reopen."},
          "writingRequirements": {"title": "Voice", "content": "Keep clues concrete and courtroom scenes brisk."}
        }
        """
    }

    var characterProposalJSON: String {
        """
        {
          "schemaVersion": 1,
          "character": {
            "title": "郭威",
            "content": "后汉枢密使，连接柴荣与赵匡胤的关键人物。",
            "aliases": ["郭雀儿"]
          },
          "relatedSuggestions": [
            {
              "kind": "relationship",
              "title": "郭威与柴荣",
              "content": "养父子关系既是权力继承，也是情感牵引。"
            },
            {
              "kind": "world",
              "title": "后汉军政格局",
              "content": "枢密使掌握的军权决定朝局走向。"
            },
            {
              "kind": "plot",
              "title": "后周权力交接",
              "content": "郭威、柴荣、赵匡胤的故事线应依次推进。"
            }
          ]
        }
        """
    }

    func documentWithChapter() throws -> (
        document: NovelProjectDocumentV1,
        versionID: NovelChapterVersionID
    ) {
        var document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let chapterID = NovelChapterID()
        let versionID = NovelChapterVersionID()
        let operationID = document.appliedOperations[0].operationID
        let now = document.project.updatedAt
        document.chapters.append(NovelChapterRecord(id: chapterID, createdAt: now))
        document.chapterVersions.append(NovelChapterVersionRecord(
            id: versionID,
            chapterID: chapterID,
            kind: .collected,
            title: "Chapter One",
            content: "The witness entered the silent courtroom.",
            factCompatibilityID: UUID(),
            sourceCandidateID: nil,
            createdAt: now,
            operationID: operationID
        ))

        let checkpointID = document.branches[0].headCheckpointID
        let checkpointIndex = try XCTUnwrap(document.checkpoints.firstIndex(where: {
            $0.id == checkpointID
        }))
        let checkpoint = document.checkpoints[checkpointIndex]
        let selection = NovelChapterSelection(chapterID: chapterID, versionID: versionID)
        document.checkpoints[checkpointIndex] = NovelBranchCheckpointRecord(
            id: checkpoint.id,
            kind: checkpoint.kind,
            createdOnBranchID: checkpoint.createdOnBranchID,
            parentCheckpointID: checkpoint.parentCheckpointID,
            chapterSelections: [selection],
            stateSnapshotID: checkpoint.stateSnapshotID,
            sessionCursor: checkpoint.sessionCursor,
            branchOverrideRevisionIDs: checkpoint.branchOverrideRevisionIDs,
            sourceCandidateID: checkpoint.sourceCandidateID,
            baseHeadRevision: checkpoint.baseHeadRevision,
            operationID: checkpoint.operationID,
            createdAt: checkpoint.createdAt
        )
        document.branches[0].workingChapterSelections = [selection]
        try NovelDocumentValidator.validate(document)
        return (document, versionID)
    }

    func appendUnselectedVersion(
        to document: inout NovelProjectDocumentV1
    ) -> NovelChapterVersionID {
        let selectedVersion = document.chapterVersions[0]
        let versionID = NovelChapterVersionID()
        document.chapterVersions.append(NovelChapterVersionRecord(
            id: versionID,
            chapterID: selectedVersion.chapterID,
            kind: .manualEdit,
            title: selectedVersion.title,
            content: "An older, unselected chapter version.",
            factCompatibilityID: UUID(),
            sourceChapterVersionID: selectedVersion.id,
            sourceCandidateID: nil,
            createdAt: selectedVersion.createdAt,
            operationID: selectedVersion.operationID
        ))
        return versionID
    }
}
