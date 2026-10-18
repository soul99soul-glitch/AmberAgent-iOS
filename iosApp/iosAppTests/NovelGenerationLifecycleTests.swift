import XCTest
@testable import iosApp

final class NovelGenerationLifecycleTests: XCTestCase {
    func testRunStartAndTerminalNotifyProjectObservers() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("完成正文"), .complete])]
        )
        let mutations = await harness.creation.mutationEvents()
        let startedNotice = expectation(description: "run start project mutation")
        let terminalNotice = expectation(description: "run terminal project mutation")
        let observer = Task {
            var count = 0
            for await event in mutations {
                guard event.projectID == document.project.id else { continue }
                count += 1
                if count == 1 { startedNotice.fulfill() }
                if count == 2 {
                    terminalNotice.fulfill()
                    return
                }
            }
        }

        let run = try await harness.creation.start(
            makeRequest(document: document, kind: .discussion)
        )
        let events = await capturedEvents(run.events)
        XCTAssertTrue(events.contains { if case .completed = $0 { true } else { false } })
        await fulfillment(of: [startedNotice, terminalNotice], timeout: 2)
        observer.cancel()
    }

    func testDiscussionDoesNotImposeAnOutputLimit() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("Detailed discussion."), .complete])]
        )

        _ = await capturedEvents(try await harness.creation.start(
            makeRequest(document: document, kind: .discussion)
        ).events)

        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.parameters.maxOutputTokens)
    }

    func testGenerationUsesCreativeModelInsteadOfStateSyncModel() async throws {
        var document = try NovelTestFixtures.document()
        document.project.modelPolicy = .fixed(providerID: "creative-provider", modelID: "creative-model")
        document.project.stateSyncModelPolicy = .fixed(providerID: "sync-provider", modelID: "sync-model")
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("A scene."), .complete])]
        )

        _ = await capturedEvents(try await harness.creation.start(
            makeRequest(document: document, kind: .prose, granularity: .continuation)
        ).events)

        let policies = await harness.adapter.resolvedPolicies
        XCTAssertEqual(policies.first, .fixed(providerID: "creative-provider", modelID: "creative-model"))
        XCTAssertFalse(policies.contains(.fixed(providerID: "sync-provider", modelID: "sync-model")))
    }

    func testMarkerUserMessageAndReceiptsAreDurableBeforeProviderResume() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause, .delta("Planned beat"), .complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)

        let run = try await harness.creation.start(request)
        let persisted = try await harness.repository.document(request.projectID)

        XCTAssertEqual(persisted.project.revision, document.project.revision + 1)
        XCTAssertEqual(persisted.branches[0].activeRunID, request.id)
        XCTAssertEqual(persisted.activeRuns.first?.status, .running)
        XCTAssertEqual(persisted.sessions[0].messages.map(\.id), [request.userMessageID])
        XCTAssertEqual(persisted.sessions[0].messages.first?.kind, .userInput)
        XCTAssertEqual(persisted.injectionReceipts.map(\.id), [request.injectionReceiptID])
        XCTAssertEqual(persisted.generationReceipts.map(\.id), [request.generationReceiptID])
        XCTAssertEqual(persisted.appliedOperations.last?.kind, .startRun)
        XCTAssertTrue(persisted.candidates.isEmpty)

        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.runID, request.id)
        XCTAssertEqual(requests.first?.model.providerID, persisted.generationReceipts[0].providerID)
        XCTAssertEqual(
            requests.first?.model.ownerProviderID,
            persisted.generationReceipts[0].ownerProviderID
        )
        XCTAssertEqual(requests.first?.model.modelID, persisted.generationReceipts[0].modelID)
        XCTAssertEqual(requests.first?.model.wireModelID, persisted.generationReceipts[0].wireModelID)
        let commits = await harness.repository.commitHistory()
        XCTAssertEqual(commits.first?.activeRuns.first?.status, .running)

        await harness.adapter.resume(runID: request.id)
        let events = await capturedEvents(run.events)
        XCTAssertEqual(events.first, .started(request.id))
        XCTAssertEqual(events.dropFirst().first, .delta("Planned beat"))
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected a completed discussion")
        }
        XCTAssertEqual(snapshot.message.kind, .discussion)
    }

    func testAskUserEndsTheRunAndPersistsAnAnswerableMessage() async throws {
        let document = try NovelTestFixtures.document()
        let prompt = NovelAskUserPrompt(
            question: "他此刻更害怕失去谁？",
            options: ["家人", "同伴"]
        )
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .askUser(prompt, preface: "这个选择会改变下一步建议。")
            ])]
        )
        let request = makeRequest(document: document, kind: .discussion)

        let events = await capturedEvents(try await harness.creation.start(request).events)
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected Ask User to persist as a completed discussion turn.")
        }
        let persisted = try await harness.repository.document(request.projectID)

        XCTAssertEqual(snapshot.message.interaction, .askUser(prompt))
        XCTAssertEqual(snapshot.message.content, "这个选择会改变下一步建议。")
        XCTAssertNil(persisted.branches[0].activeRunID)
        XCTAssertEqual(persisted.activeRuns.last?.status, .completed)
    }

    func testAskUserFallbackCompletesAsAnAnswerableMessage() async throws {
        let prompt = NovelAskUserPrompt(question: "选择哪条线？", options: ["主线", "支线"])
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .replacement(#"{"amberAskUser":{"question":"选择哪条线？","options":["主线","支线"]}}"#),
                .complete,
            ])]
        )

        let events = await capturedEvents(try await harness.creation.start(
            makeRequest(document: document, kind: .discussion)
        ).events)
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected fallback Ask User to complete the discussion turn.")
        }
        XCTAssertEqual(snapshot.message.interaction, .askUser(prompt))
    }

    func testQuickStartAskUserEndsTheRunWithoutCommittingProposals() async throws {
        let prompt = NovelAskUserPrompt(
            question: "世界观更强调哪种代价？",
            options: ["失去记忆", "失去时间"]
        )
        let document = try quickStartDocument()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .askUser(prompt, preface: "这个决定会改变人物动机和主线。")
            ])]
        )

        let events = await capturedEvents(try await harness.creation.start(
            makeRequest(document: document, kind: .quickStart)
        ).events)
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected Quick Start Ask User to persist as a completed turn.")
        }
        let persisted = try await harness.repository.document(document.project.id)

        XCTAssertEqual(snapshot.message.interaction, .askUser(prompt))
        XCTAssertTrue(persisted.settingProposals.isEmpty)
        XCTAssertNil(persisted.branches[0].activeRunID)
    }

    func testQuickStartAskUserFallbackCompletesAsAnAnswerableMessage() async throws {
        let prompt = NovelAskUserPrompt(
            question: "主角应先失去什么？",
            options: ["名字", "亲人"]
        )
        let document = try quickStartDocument()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .replacement(#"{"amberAskUser":{"question":"主角应先失去什么？","options":["名字","亲人"]}}"#),
                .complete,
            ])]
        )

        let events = await capturedEvents(try await harness.creation.start(
            makeRequest(document: document, kind: .quickStart)
        ).events)

        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected Quick Start fallback Ask User to complete.")
        }
        XCTAssertEqual(snapshot.message.interaction, .askUser(prompt))
    }

    func testDiscussionProseGranularitiesAndPolishCompleteWithoutChangingCanonicalState() async throws {
        let cases: [CompletionCase] = [
            CompletionCase(kind: .discussion, granularity: nil, content: "Delay the reveal.", expectedMessage: .discussion),
            CompletionCase(kind: .prose, granularity: .continuation, content: "A short continuation.", expectedMessage: .proseCandidate),
            CompletionCase(kind: .prose, granularity: .wholeChapter, content: "A complete next chapter.", expectedMessage: .proseCandidate),
            CompletionCase(
                kind: .polish,
                granularity: nil,
                content: "The polished chapter.\n\(NovelPromptCatalog.polishCompletionSentinel)",
                expectedMessage: .polishCandidate
            )
        ]

        for testCase in cases {
            let fixture: (NovelProjectDocumentV1, NovelChapterVersionID?)
            if testCase.kind == .polish {
                fixture = try documentWithChapter()
            } else {
                fixture = (try NovelTestFixtures.document(), nil)
            }
            let baseline = fixture.0
            let harness = try await makeHarness(
                document: baseline,
                scripts: [NovelModelScript(steps: [.delta(testCase.content), .complete])]
            )
            let request = makeRequest(
                document: baseline,
                kind: testCase.kind,
                granularity: testCase.granularity,
                sourceChapterVersionID: fixture.1
            )

            let events = await capturedEvents(try await harness.creation.start(request).events)
            guard case .completed(let snapshot) = events.last else {
                XCTFail("Expected completion for \(testCase.kind)")
                continue
            }
            XCTAssertEqual(snapshot.message.kind, testCase.expectedMessage)
            XCTAssertEqual(
                snapshot.message.content,
                testCase.kind == .polish ? "The polished chapter." : testCase.content
            )

            let final = try await harness.repository.document(request.projectID)
            XCTAssertEqual(final.chapters, baseline.chapters)
            XCTAssertEqual(final.chapterVersions, baseline.chapterVersions)
            XCTAssertEqual(final.events, baseline.events)
            XCTAssertEqual(final.stateSnapshots, baseline.stateSnapshots)
            XCTAssertEqual(final.checkpoints, baseline.checkpoints)
            XCTAssertEqual(final.branches[0].headRevision, baseline.branches[0].headRevision)
            if testCase.kind == .discussion {
                XCTAssertTrue(final.candidates.isEmpty)
                XCTAssertNil(snapshot.message.candidateID)
            } else {
                XCTAssertEqual(final.candidates.count, 1)
                XCTAssertEqual(final.candidates[0].id, request.candidateID)
                XCTAssertEqual(final.candidates[0].status, .available)
                XCTAssertEqual(final.candidates[0].sourceChapterVersionID, fixture.1)
            }
        }
    }

    func testProseCompletionKeepsDurableLeadingTrim() async throws {
        let document = try NovelTestFixtures.document()
        let raw = "\n　Mara entered the archive.\n"
        let expected = "Mara entered the archive."
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta(raw), .complete])]
        )
        let events = await capturedEvents(try await harness.creation.start(
            makeRequest(document: document, kind: .prose, granularity: .continuation)
        ).events)
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected completed prose run")
        }
        let persisted = try await harness.repository.document(document.project.id)
        XCTAssertEqual(snapshot.message.content, expected)
        XCTAssertEqual(persisted.sessions[0].messages.last?.content, expected)
        XCTAssertEqual(persisted.candidates.first?.content, expected)
    }

    func testEmptyProviderCompletionClosesAsFailureInsteadOfBlockingPersistence() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)

        let events = await capturedEvents(try await harness.creation.start(request).events)
        let failure = NovelFailure(
            code: "empty_completion",
            message: "The model completed without returning any text.",
            isRetryable: true
        )
        XCTAssertEqual(events.last, .failed(failure))

        let final = try await harness.repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .failed)
        XCTAssertEqual(final.activeRuns.first?.terminalFailure, failure)
        XCTAssertNil(final.branches.first?.activeRunID)
        XCTAssertTrue(final.candidates.isEmpty)
    }

    /// Reasoning is presentation-only: broadcast to UI, never manuscript partial/candidate/message.
    func testReasoningDeltaIsBroadcastAndNeverPollutesManuscript() async throws {
        let reasoning = "先分析人物动机与冲突。"
        let prose = "雨夜的巷口，她停住了脚步。"
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .reasoningDelta(reasoning),
                .delta(prose),
                .complete,
            ])]
        )
        let request = makeRequest(document: document, kind: .prose, granularity: .continuation)

        let events = await capturedEvents(try await harness.creation.start(request).events)
        XCTAssertTrue(events.contains(.reasoningDelta(reasoning)))
        XCTAssertTrue(events.contains(.delta(prose)))
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected prose completion")
        }
        XCTAssertEqual(snapshot.message.content, prose)
        XCTAssertFalse(snapshot.message.content.contains(reasoning))

        let final = try await harness.repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .completed)
        XCTAssertEqual(final.activeRuns.first?.partialContent, prose)
        XCTAssertFalse(final.activeRuns.first?.partialContent.contains(reasoning) ?? true)
        XCTAssertEqual(final.candidates.count, 1)
        XCTAssertEqual(final.candidates[0].content, prose)
        XCTAssertFalse(final.candidates[0].content.contains(reasoning))
        let assistantBodies = final.sessions[0].messages
            .filter { $0.role == .assistant }
            .map(\.content)
        XCTAssertTrue(assistantBodies.contains(prose))
        XCTAssertFalse(assistantBodies.contains { $0.contains(reasoning) })
    }

    func testInvalidQuickStartJSONFailsBeforeAnyProposalIsCommitted() async throws {
        let document = try quickStartDocument()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("{not-json"), .complete])]
        )
        let request = makeRequest(document: document, kind: .quickStart)

        let events = await capturedEvents(try await harness.creation.start(request).events)
        let failure = NovelFailure(
            code: "invalid_quick_start_output",
            message: "The quick-start suggestions were not valid structured output.",
            isRetryable: true
        )
        XCTAssertEqual(events.last, .failed(failure))
        let final = try await harness.repository.document(request.projectID)
        XCTAssertTrue(final.settingProposals.isEmpty)
        XCTAssertTrue(final.materials.isEmpty)
        XCTAssertEqual(final.activeRuns.first?.status, .failed)
        XCTAssertEqual(final.activeRuns.first?.terminalFailure, failure)
    }

    func testCapturedDeepSeekQuickStartWithNullTranslationHintsCompletes() async throws {
        let document = try quickStartDocument()
        let captured = """
        Suggestions are ready:
        ```json
        {
          "schemaVersion": 3,
          "overview": "完整方向",
          "world": {"title":"五代末世","content":"后周至宋初。","title_cn":null},
          "characters": [
            {"title":"沈越","content":"现代社畜。","aliases":[]},
            {"title":"赵匡胤","content":"年轻游侠。","aliases":["赵大"]}
          ],
          "masterOutline": {"title":"从江湖到朝堂","content":"五幕结构。","title_cn":null},
          "writingRequirements": {"title":"温情喜剧","content":"活泼幽默。","title_cn":null}
        }
        ```
        """
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta(captured), .complete])]
        )
        let request = makeRequest(document: document, kind: .quickStart)

        let events = await capturedEvents(try await harness.creation.start(request).events)
        guard case .completed? = events.last else {
            return XCTFail("Expected the captured complete suggestion set to be accepted.")
        }
        let final = try await harness.repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .completed)
        XCTAssertEqual(final.settingProposals.count, 5)
        XCTAssertNil(final.activeRuns.first?.terminalFailure)
    }

    func testCharacterProposalLifecycleCreatesSuggestionsButNotMaterials() async throws {
        let document = try documentWithUnresolvedCharacter("郭威")
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .delta(characterProposalJSON),
                .complete
            ])]
        )
        let request = makeRequest(
            document: document,
            kind: .characterProposal,
            contextualCharacterMention: "郭威"
        )

        let events = await capturedEvents(try await harness.creation.start(request).events)
        guard case .completed? = events.last else {
            return XCTFail("Expected a completed contextual character proposal.")
        }
        let final = try await harness.repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .completed)
        XCTAssertEqual(final.settingProposals.count, 4)
        XCTAssertTrue(final.materials.isEmpty)
        XCTAssertEqual(final.stateSnapshots[0].unresolvedEntityNames, ["郭威"])
    }

    func testInvalidCharacterProposalLeavesIdentityQuestionUnresolved() async throws {
        let document = try documentWithUnresolvedCharacter("郭威")
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("not a proposal"), .complete])]
        )
        let request = makeRequest(
            document: document,
            kind: .characterProposal,
            contextualCharacterMention: "郭威"
        )

        let events = await capturedEvents(try await harness.creation.start(request).events)
        XCTAssertEqual(events.last, .failed(NovelFailure(
            code: "invalid_character_proposal_output",
            message: "人物建议不是有效的结构化结果。",
            isRetryable: true
        )))
        let final = try await harness.repository.document(request.projectID)
        XCTAssertTrue(final.settingProposals.isEmpty)
        XCTAssertTrue(final.materials.isEmpty)
        XCTAssertEqual(final.stateSnapshots[0].unresolvedEntityNames, ["郭威"])
    }

    func testCancellingCharacterProposalLeavesIdentityQuestionUnresolved() async throws {
        let document = try documentWithUnresolvedCharacter("郭威")
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(
            document: document,
            kind: .characterProposal,
            contextualCharacterMention: "郭威"
        )
        let run = try await harness.creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        guard case .started? = await iterator.next() else {
            return XCTFail("Expected start event")
        }

        let running = try await harness.repository.document(request.projectID)
        _ = try await harness.creation.perform(.cancelRun(cancelCommand(
            document: running,
            runID: request.id
        )))
        guard case .interrupted? = await iterator.next() else {
            return XCTFail("Expected interrupted event")
        }

        let final = try await harness.repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .interrupted)
        XCTAssertTrue(final.settingProposals.isEmpty)
        XCTAssertTrue(final.materials.isEmpty)
        XCTAssertEqual(final.stateSnapshots[0].unresolvedEntityNames, ["郭威"])
        XCTAssertNil(final.branches.first?.activeRunID)
    }

    func testCancelPersistsOptionalPartialAndForcedSidecarWithoutWaitingForProvider() async throws {
        for partial in ["", "Keep this partial"] {
            let document = try NovelTestFixtures.document()
            let steps: [NovelModelScriptStep] = partial.isEmpty
                ? [.pause]
                : [.delta(partial), .pause]
            let policy = NovelGenerationPolicy(
                sidecarByteThreshold: 1_000_000,
                sidecarInterval: 10_000,
                chapterTailCharacterLimit: 6_000,
                maximumRecentSessionMessages: 12
            )
            let harness = try await makeHarness(
                document: document,
                scripts: [NovelModelScript(steps: steps)],
                policy: policy
            )
            let request = makeRequest(document: document, kind: .prose, granularity: .continuation)
            let run = try await harness.creation.start(request)
            var iterator = run.events.makeAsyncIterator()
            guard case .started? = await iterator.next() else {
                return XCTFail("Expected start event")
            }
            if !partial.isEmpty {
                guard case .delta(partial)? = await iterator.next() else {
                    return XCTFail("Expected partial delta")
                }
            }

            let running = try await harness.repository.document(request.projectID)
            let outcome = try await harness.creation.perform(.cancelRun(cancelCommand(
                document: running,
                runID: request.id
            )))
            guard case .runInterrupted(_, let runID, .user, _) = outcome else {
                return XCTFail("Expected interruption outcome")
            }
            XCTAssertEqual(runID, request.id)
            guard case .interrupted(let message)? = await iterator.next() else {
                return XCTFail("Expected interrupted event")
            }
            XCTAssertEqual(message?.message.content, partial.isEmpty ? nil : partial)
            let streamEnd = await iterator.next()
            XCTAssertNil(streamEnd)

            let final = try await harness.repository.document(request.projectID)
            XCTAssertEqual(final.activeRuns[0].status, .interrupted)
            XCTAssertEqual(final.activeRuns[0].partialContent, partial)
            XCTAssertEqual(final.sessions[0].messages.count, partial.isEmpty ? 1 : 2)
            XCTAssertEqual(final.candidates.count, partial.isEmpty ? 0 : 1)
            XCTAssertEqual(final.candidates.first?.status, partial.isEmpty ? nil : .interrupted)
            XCTAssertNil(final.branches[0].activeRunID)

            let wroteSidecar = await eventually {
                let writes = await harness.repository.sidecarWrites()
                return writes.contains { $0.runID == request.id }
            }
            XCTAssertTrue(wroteSidecar)
            let removedSidecar = await eventually {
                let removals = await harness.repository.sidecarRemovals()
                return removals.contains(request.id)
            }
            XCTAssertTrue(removedSidecar)
            let cancelledProvider = await eventually {
                let cancelledRunIDs = await harness.adapter.cancelledRunIDs
                return cancelledRunIDs.contains(request.id)
            }
            XCTAssertTrue(cancelledProvider)
        }
    }

    func testInterruptClaimsRuntimeBeforeCancellingSuspendedModelStart() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = CancellableStartNovelModelAdapter()
        let creation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            now: { Date(timeIntervalSince1970: 1_700_001_000) }
        )
        let request = makeRequest(document: document, kind: .discussion)
        let startTask = Task { try await creation.start(request) }
        let enteredModelStart = await eventually { await adapter.startDidBegin() }
        XCTAssertTrue(enteredModelStart)

        try await creation.interruptRun(NovelCancelRunCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: request.projectID,
            runID: request.id,
            reason: .routeExit
        ))
        _ = try? await startTask.value

        let final = try await repository.document(request.projectID)
        let terminal = try XCTUnwrap(final.activeRuns.first { $0.id == request.id })
        XCTAssertEqual(terminal.status, .interrupted)
        XCTAssertEqual(terminal.interruptionReason, .routeExit)
        XCTAssertNil(final.branches[0].activeRunID)
        let providerCancelled = await eventually {
            await adapter.cancelledRunIDs().contains(request.id)
        }
        XCTAssertTrue(providerCancelled)
    }

    func testInterruptDoesNotAwaitAnUncooperativeModelStart() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = BlockingStartNovelModelAdapter()
        let creation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            now: { Date(timeIntervalSince1970: 1_700_001_000) }
        )
        let request = makeRequest(document: document, kind: .discussion)
        let startTask = Task { try await creation.start(request) }
        let enteredModelStart = await eventually { await adapter.startDidBegin() }
        XCTAssertTrue(enteredModelStart)
        let safetyRelease = Task {
            try? await Task.sleep(for: .milliseconds(500))
            await adapter.releaseStart()
        }

        let interruptStartedAt = Date()
        try await creation.interruptRun(NovelCancelRunCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: request.projectID,
            runID: request.id,
            reason: .routeExit
        ))
        XCTAssertLessThan(Date().timeIntervalSince(interruptStartedAt), 0.25)
        safetyRelease.cancel()
        await adapter.releaseStart()
        _ = try? await startTask.value

        let final = try await repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first { $0.id == request.id }?.status, .interrupted)
        XCTAssertEqual(
            final.activeRuns.first { $0.id == request.id }?.interruptionReason,
            .routeExit
        )
    }

    func testInterruptBeforeStartPreventsTheLateRunFromBecomingDurable() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)

        try await harness.creation.interruptRun(NovelCancelRunCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: request.projectID,
            runID: request.id,
            reason: .routeExit
        ))
        do {
            _ = try await harness.creation.start(request)
            XCTFail("A pre-start interruption must cancel the late start.")
        } catch is CancellationError {
            // Expected.
        }

        let final = try await harness.repository.document(request.projectID)
        let requests = await harness.adapter.requests
        XCTAssertEqual(final, document)
        XCTAssertTrue(requests.isEmpty)
    }

    func testInterruptPublishesPreStartCancellationBeforeRepositoryLoadResumes() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        await harness.repository.blockNextLoad()

        let interruptTask = Task {
            try await harness.creation.interruptRun(NovelCancelRunCommand(
                context: NovelMutationContext(
                    operationID: NovelOperationID(),
                    expectedProjectRevision: nil,
                    expectedConfigRevision: nil,
                    expectedBranchHeadRevision: nil
                ),
                projectID: request.projectID,
                runID: request.id,
                reason: .routeExit
            ))
        }
        let loadBlocked = await eventually { await harness.repository.loadIsBlocked() }
        XCTAssertTrue(loadBlocked)

        do {
            _ = try await harness.creation.start(request)
            XCTFail("The late start must observe cancellation while interrupt is loading state.")
        } catch is CancellationError {
            // Expected.
        }
        await harness.repository.resumeBlockedLoad()
        try await interruptTask.value

        let final = try await harness.repository.document(request.projectID)
        let requests = await harness.adapter.requests
        XCTAssertEqual(final, document)
        XCTAssertTrue(requests.isEmpty)
    }

    func testBackgroundBeforeStartPreventsTheLateRunFromBecomingDurable() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)

        await harness.creation.interruptForBackground(
            projectID: request.projectID,
            deadline: Date().addingTimeInterval(5),
            runID: request.id
        )
        do {
            _ = try await harness.creation.start(request)
            XCTFail("A pre-start background interruption must cancel the late start.")
        } catch is CancellationError {
            // Expected.
        }

        let final = try await harness.repository.document(request.projectID)
        let requests = await harness.adapter.requests
        XCTAssertEqual(final, document)
        XCTAssertTrue(requests.isEmpty)
    }

    func testLateBackgroundInterruptionDoesNotTombstoneCompletedRun() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("Finished"), .complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)

        let events = await capturedEvents(try await harness.creation.start(request).events)
        guard case .completed = events.last else {
            return XCTFail("Expected the run to complete before the late callback.")
        }

        await harness.creation.interruptForBackground(
            projectID: request.projectID,
            deadline: Date().addingTimeInterval(5),
            runID: request.id
        )

        let replayEvents = await capturedEvents(try await harness.creation.start(request).events)
        guard case .completed = replayEvents.last else {
            return XCTFail("A late background callback must not cancel a completed replay.")
        }
    }

    func testIgnoreCancelDuplicateAndLateProviderCallbacksCannotRewriteFirstTerminal() async throws {
        let document = try NovelTestFixtures.document()
        let lateFailure = NovelModelFailure(code: "late", message: "late", isRetryable: false)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(
                steps: [.delta("Durable partial"), .pause, .delta(" late"), .complete, .complete, .fail(lateFailure)],
                ignoresCancellation: true
            )]
        )
        let request = makeRequest(document: document, kind: .prose, granularity: .wholeChapter)
        let run = try await harness.creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        let running = try await harness.repository.document(request.projectID)
        _ = try await harness.creation.perform(.cancelRun(cancelCommand(document: running, runID: request.id)))
        guard case .interrupted(let snapshot)? = await iterator.next() else {
            return XCTFail("Expected interruption")
        }
        XCTAssertEqual(snapshot?.message.content, "Durable partial")
        let firstTerminal = try await harness.repository.document(request.projectID)

        await harness.adapter.resume(runID: request.id)
        try? await Task.sleep(nanoseconds: 40_000_000)
        let afterLateCallbacks = try await harness.repository.document(request.projectID)
        XCTAssertEqual(afterLateCallbacks, firstTerminal)
        XCTAssertEqual(afterLateCallbacks.activeRuns[0].status, .interrupted)
        XCTAssertEqual(afterLateCallbacks.candidates.first?.status, .interrupted)
        XCTAssertEqual(afterLateCallbacks.sessions[0].messages.filter { $0.role == .assistant }.count, 1)
    }

}
