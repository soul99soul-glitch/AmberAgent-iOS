import XCTest
@testable import iosApp

private actor NovelOldStreamExitProbe {
    private(set) var hasFinished = false

    func markFinished() {
        hasFinished = true
    }
}

extension NovelGenerationLifecycleTests {
    func testRestartRecoversLatestThresholdSidecarExactlyOnce() async throws {
        let document = try NovelTestFixtures.document()
        let policy = NovelGenerationPolicy(
            sidecarByteThreshold: 1,
            sidecarInterval: 10_000,
            chapterTailCharacterLimit: 6_000,
            maximumRecentSessionMessages: 12
        )
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(
                steps: [.delta("Recover this draft"), .pause, .complete],
                ignoresCancellation: true
            )],
            policy: policy
        )
        let request = makeRequest(document: document, kind: .prose, granularity: .wholeChapter)
        let run = try await harness.creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        let wroteRecoverySidecar = await eventually {
            let writes = await harness.repository.sidecarWrites()
            return writes.contains {
                $0.runID == request.id && $0.partialContent == "Recover this draft"
            }
        }
        XCTAssertTrue(wroteRecoverySidecar)

        let restarted = DefaultNovelCreation(repository: harness.repository)
        _ = try await restarted.snapshot(.project(request.projectID))
        let recovered = try await harness.repository.document(request.projectID)
        XCTAssertEqual(recovered.activeRuns[0].status, .interrupted)
        XCTAssertEqual(recovered.activeRuns[0].interruptionReason, .recovery)
        XCTAssertEqual(recovered.activeRuns[0].partialContent, "Recover this draft")
        XCTAssertEqual(recovered.sessions[0].messages.last?.kind, .interruptedDraft)
        XCTAssertEqual(recovered.sessions[0].messages.last?.content, "Recover this draft")
        XCTAssertEqual(recovered.candidates.first?.status, .interrupted)
        let remainingSidecars = try await harness.repository.listRecoverySidecars()
        XCTAssertTrue(remainingSidecars.isEmpty)

        _ = try await restarted.snapshot(.project(request.projectID))
        let documentAfterSecondSnapshot = try await harness.repository.document(request.projectID)
        XCTAssertEqual(documentAfterSecondSnapshot, recovered)
        await harness.adapter.resume(runID: request.id)
    }

    func testResponsesFramePersistsPartialAndCursorAsOneRecoveryRecord() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            generationPolicy: NovelGenerationPolicy(
                sidecarByteThreshold: 1,
                sidecarInterval: 10_000,
                chapterTailCharacterLimit: 6_000,
                maximumRecentSessionMessages: 12
            )
        )
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()

        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_atomic", sequenceNumber: 0),
                events: []
            )),
            runID: request.id
        )
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_atomic", sequenceNumber: 1),
                events: [.textDelta("中文正文")]
            )),
            runID: request.id
        )
        guard case .delta("中文正文")? = await iterator.next() else {
            return XCTFail("Expected the response frame text")
        }

        let wrotePair = await eventually {
            await repository.sidecarWrites().contains {
                $0.runID == request.id &&
                    $0.partialContent == "中文正文" &&
                    $0.responseID == "resp_atomic" &&
                    $0.responseSequenceNumber == 1
            }
        }
        XCTAssertTrue(wrotePair)
        await adapter.yieldInitial(.completed, runID: request.id, finish: true)
        guard case .completed? = await iterator.next() else {
            return XCTFail("Expected completion")
        }
    }

    func testRestartResumesStoredResponseWithoutPostingPromptAgain() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let firstAdapter = DurableNovelModelAdapter()
        let policy = NovelGenerationPolicy(
            sidecarByteThreshold: 1,
            sidecarInterval: 10_000,
            chapterTailCharacterLimit: 6_000,
            maximumRecentSessionMessages: 12
        )
        let first = DefaultNovelCreation(
            repository: repository,
            modelRunner: firstAdapter,
            generationPolicy: policy
        )
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let originalRun = try await first.start(request)
        var originalIterator = originalRun.events.makeAsyncIterator()
        _ = await originalIterator.next()
        await firstAdapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_restart", sequenceNumber: 4),
                events: [.textDelta("前半段")]
            )),
            runID: request.id
        )
        _ = await originalIterator.next()
        let wroteRestartCursor = await eventually {
            await repository.sidecarWrites().contains {
                $0.runID == request.id && $0.responseSequenceNumber == 4
            }
        }
        XCTAssertTrue(wroteRestartCursor)

        let resumedAdapter = DurableNovelModelAdapter()
        let restarted = DefaultNovelCreation(
            repository: repository,
            modelRunner: resumedAdapter,
            generationPolicy: policy
        )
        await restarted.resumeDetachedGenerationRuns()
        let didResume = await eventually {
            await resumedAdapter.resumeRequests.count == 1
        }
        XCTAssertTrue(didResume)
        let recordedResumeRequests = await resumedAdapter.resumeRequests
        let resumeRequest = try XCTUnwrap(recordedResumeRequests.first)
        XCTAssertEqual(resumeRequest.cursor.responseID, "resp_restart")
        XCTAssertEqual(resumeRequest.cursor.sequenceNumber, 4)
        let restartedStartRequests = await resumedAdapter.startRequests
        XCTAssertTrue(restartedStartRequests.isEmpty)

        let observed = try await restarted.start(request)
        var iterator = observed.events.makeAsyncIterator()
        guard case .started? = await iterator.next(),
              case .replaced("前半段")? = await iterator.next() else {
            return XCTFail("Expected the recovered partial to replay on attach")
        }
        await resumedAdapter.yieldResumed(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_restart", sequenceNumber: 5),
                events: [.textDelta("后半段")]
            )),
            runID: request.id
        )
        guard case .delta("后半段")? = await iterator.next() else {
            return XCTFail("Expected resumed text")
        }
        await resumedAdapter.yieldResumed(.completed, runID: request.id, finish: true)
        guard case .completed(let snapshot)? = await iterator.next() else {
            return XCTFail("Expected resumed completion")
        }
        XCTAssertEqual(snapshot.message.content, "前半段后半段")
    }

    func testBackgroundExpirationDetachesResponseAndForegroundResumeUsesCursor() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_detach", sequenceNumber: 2),
                events: [.textDelta("保留")]
            )),
            runID: request.id
        )
        _ = await iterator.next()

        await creation.interruptForBackground(
            projectID: request.projectID,
            deadline: Date.distantPast,
            runID: request.id
        )
        let afterExpiration = try await repository.document(request.projectID)
        XCTAssertEqual(afterExpiration.activeRuns.first?.status, .running)
        let detachedRunIDs = await adapter.detachedRunIDs
        let cancelledRunIDs = await adapter.cancelledRunIDs
        XCTAssertEqual(detachedRunIDs, [request.id])
        XCTAssertTrue(cancelledRunIDs.isEmpty)

        await creation.resumeDetachedGenerationRuns()
        let didResume = await eventually { await adapter.resumeRequests.count == 1 }
        XCTAssertTrue(didResume)
        let resumeRequests = await adapter.resumeRequests
        XCTAssertEqual(resumeRequests.first?.cursor.responseID, "resp_detach")
        await adapter.yieldResumed(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_detach", sequenceNumber: 3),
                events: [.textDelta("续写")]
            )),
            runID: request.id
        )
        guard case .delta("续写")? = await iterator.next() else {
            return XCTFail("Expected foreground resume delta")
        }
        await adapter.yieldResumed(.completed, runID: request.id, finish: true)
        guard case .completed(let snapshot)? = await iterator.next() else {
            return XCTFail("Expected completion after foreground resume")
        }
        XCTAssertEqual(snapshot.message.content, "保留续写")
    }

    func testForegroundResumeKeepsReplacementStreamWhenDetachReturnsLate() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_late_detach", sequenceNumber: 1),
                events: [.textDelta("前段")]
            )),
            runID: request.id
        )
        _ = await iterator.next()

        await adapter.blockNextDetach()
        let interruption = Task {
            await creation.interruptForBackground(
                projectID: request.projectID,
                deadline: .distantPast,
                runID: request.id
            )
        }
        let detachBlocked = await eventually { await adapter.detachIsBlocked() }
        XCTAssertTrue(detachBlocked)

        await creation.resumeDetachedGenerationRuns()
        let didResume = await eventually { await adapter.resumeRequests.count == 1 }
        XCTAssertTrue(didResume)
        await adapter.resumeBlockedDetach()
        await interruption.value

        await adapter.yieldResumed(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_late_detach", sequenceNumber: 2),
                events: [.textDelta("后段")]
            )),
            runID: request.id
        )
        guard case .delta("后段")? = await iterator.next() else {
            return XCTFail("The foreground replacement stream must survive the older detach call")
        }
        await adapter.yieldResumed(.completed, runID: request.id, finish: true)
        guard case .completed(let snapshot)? = await iterator.next() else {
            return XCTFail("Expected the replacement stream to complete")
        }
        XCTAssertEqual(snapshot.message.content, "前段后段")
    }

    func testOldDetachedStreamEndCannotTerminalizeForegroundResume() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        await adapter.usePullBarrierForNextInitialStream()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_old_stream_end", sequenceNumber: 1),
                events: [.textDelta("前段")]
            )),
            runID: request.id
        )
        guard case .delta("前段")? = await iterator.next() else {
            return XCTFail("Expected the initial durable frame")
        }
        let initialFrameFullyConsumed = await eventually {
            await adapter.secondInitialPullIsWaiting(runID: request.id)
        }
        guard initialFrameFullyConsumed else {
            await adapter.finishInitialStream(runID: request.id)
            return XCTFail("Initial frame consumer did not request the next model event")
        }

        // Keep the old local stream open while detach is suspended. Its normal
        // end is delivered only after foreground recovery has claimed the run.
        await adapter.blockNextDetachBeforeFinishingInitialStream()
        let interruption = Task {
            await creation.interruptForBackground(
                projectID: request.projectID,
                deadline: .distantPast,
                runID: request.id
            )
        }
        let detachBlocked = await eventually { await adapter.detachIsBlocked() }
        guard detachBlocked else {
            await adapter.resumeBlockedDetach()
            await interruption.value
            return XCTFail("Expected background detach to suspend")
        }
        guard let oldConsumer = await creation.generationRuntimes[request.id]?.modelTask else {
            await adapter.resumeBlockedDetach()
            await interruption.value
            return XCTFail("Expected the initial model stream consumer")
        }

        let mainActorEntered = expectation(description: "Foreground lease hop is suspended")
        let releaseMainActor = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainActorEntered.fulfill()
            releaseMainActor.wait()
        }
        await fulfillment(of: [mainActorEntered], timeout: 1)

        let resumeTask = Task(priority: .high) {
            await creation.resumeDetachedGenerationRuns()
        }
        let resumeClaimedOwner = await eventually {
            await creation.generationRuntimes[request.id]?.isDetachedForBackground == false
        }
        guard resumeClaimedOwner else {
            releaseMainActor.signal()
            await resumeTask.value
            await adapter.resumeBlockedDetach()
            await interruption.value
            return XCTFail("Foreground resume did not reach the lease hop")
        }

        let exitProbe = NovelOldStreamExitProbe()
        let observeOldConsumer = Task {
            await oldConsumer.value
            await exitProbe.markFinished()
        }
        await adapter.finishInitialStream(runID: request.id)
        let oldConsumerSettledOrClaimed = await eventually {
            if await exitProbe.hasFinished { return true }
            let runtime = await creation.generationRuntimes[request.id]
            return runtime == nil || runtime?.terminalClaim != nil
        }
        releaseMainActor.signal()
        await resumeTask.value
        await adapter.resumeBlockedDetach()
        await interruption.value
        await observeOldConsumer.value

        XCTAssertTrue(oldConsumerSettledOrClaimed)
        let resumeRequests = await adapter.resumeRequests
        XCTAssertEqual(resumeRequests.count, 1, "The old detached stream must not claim the resumed run")
        guard resumeRequests.count == 1 else { return }
        await adapter.yieldResumed(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_old_stream_end", sequenceNumber: 2),
                events: [.textDelta("后段")]
            )),
            runID: request.id
        )
        guard case .delta("后段")? = await iterator.next() else {
            return XCTFail("Expected the foreground replacement stream to receive the next frame")
        }
        await adapter.yieldResumed(.completed, runID: request.id, finish: true)
        guard case .completed(let snapshot)? = await iterator.next() else {
            return XCTFail("Expected completion from the foreground replacement stream")
        }
        XCTAssertEqual(snapshot.message.content, "前段后段")
    }

    func testExpirationDuringResumeLeaseHopDoesNotStartReplacementStream() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_lease_race", sequenceNumber: 1),
                events: [.textDelta("已保存")]
            )),
            runID: request.id
        )
        _ = await iterator.next()
        await creation.interruptForBackground(
            projectID: request.projectID,
            deadline: .distantPast,
            runID: request.id
        )
        let initialDetachCount = await adapter.detachedRunIDs.count
        XCTAssertEqual(initialDetachCount, 1)

        let mainActorEntered = expectation(description: "Recovered lease hop is suspended")
        let releaseMainActor = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainActorEntered.fulfill()
            releaseMainActor.wait()
        }
        await fulfillment(of: [mainActorEntered], timeout: 1)

        let resumeTask = Task(priority: .high) {
            await creation.resumeDetachedGenerationRuns()
        }
        let resumeClaimedOwner = await eventually {
            await creation.generationRuntimes[request.id]?.isDetachedForBackground == false
        }
        guard resumeClaimedOwner else {
            releaseMainActor.signal()
            await resumeTask.value
            return XCTFail("Resume did not reach the blocked lease hop")
        }
        let expirationTask = Task {
            await creation.interruptForBackground(
                projectID: request.projectID,
                deadline: .distantPast,
                runID: request.id
            )
        }
        let detachedAgain = await eventually {
            await adapter.detachedRunIDs.count == 2
        }
        releaseMainActor.signal()
        await resumeTask.value
        await expirationTask.value

        XCTAssertTrue(detachedAgain)
        let resumeRequests = await adapter.resumeRequests
        XCTAssertTrue(resumeRequests.isEmpty)
        let final = try await repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .running)
    }

    func testLateDetachCannotResurrectAConcurrentlyInterruptedRuntime() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_no_ghost", sequenceNumber: 1),
                events: [.textDelta("保留正文")]
            )),
            runID: request.id
        )
        _ = await iterator.next()

        await adapter.blockNextDetach()
        let backgroundInterruption = Task {
            await creation.interruptForBackground(
                projectID: request.projectID,
                deadline: .distantPast,
                runID: request.id
            )
        }
        let detachBlocked = await eventually { await adapter.detachIsBlocked() }
        XCTAssertTrue(detachBlocked)

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
        await adapter.resumeBlockedDetach()
        await backgroundInterruption.value
        await creation.resumeDetachedGenerationRuns()

        let resumeRequests = await adapter.resumeRequests
        XCTAssertTrue(resumeRequests.isEmpty)
        let final = try await repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(final.activeRuns.first?.interruptionReason, .routeExit)
    }

    func testFailedForcedSidecarWriteInterruptsInsteadOfDetaching() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_sidecar_failure", sequenceNumber: 1),
                events: [.textDelta("已生成正文")]
            )),
            runID: request.id
        )
        _ = await iterator.next()
        let wroteInitialCursor = await eventually {
            await repository.sidecarWrites().contains {
                $0.runID == request.id && $0.responseSequenceNumber == 1
            }
        }
        XCTAssertTrue(wroteInitialCursor)
        await repository.failNextSidecarWrites(1)

        await creation.interruptForBackground(
            projectID: request.projectID,
            deadline: Date().addingTimeInterval(2),
            runID: request.id
        )

        let final = try await repository.document(request.projectID)
        XCTAssertEqual(final.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(final.activeRuns.first?.interruptionReason, .background)
        let detachedRunIDs = await adapter.detachedRunIDs
        XCTAssertTrue(detachedRunIDs.isEmpty)
        let cancelledProvider = await eventually {
            await adapter.cancelledRunIDs.contains(request.id)
        }
        XCTAssertTrue(cancelledProvider)
    }

    func testTransportDisconnectAutomaticallyResumesOnlyOncePerRun() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let failure = NovelModelFailure(
            code: "provider_background_disconnected",
            message: "network dropped",
            isRetryable: true
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_one_retry", sequenceNumber: 1),
                events: [.textDelta("第一段")]
            )),
            runID: request.id
        )
        _ = await iterator.next()
        await adapter.yieldInitial(.responseDisconnected(failure), runID: request.id, finish: true)
        let firstReconnect = await eventually { await adapter.resumeRequests.count == 1 }
        XCTAssertTrue(firstReconnect)

        await adapter.yieldResumed(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_one_retry", sequenceNumber: 2),
                events: [.textDelta("第二段")]
            )),
            runID: request.id
        )
        guard case .delta("第二段")? = await iterator.next() else {
            return XCTFail("Expected text from the first reconnect")
        }
        await adapter.yieldResumed(.responseDisconnected(failure), runID: request.id, finish: true)

        guard case .failed(let terminalFailure)? = await iterator.next() else {
            return XCTFail("The second disconnect must fail the run")
        }
        XCTAssertEqual(terminalFailure.code, failure.code)
        let resumeRequests = await adapter.resumeRequests
        XCTAssertEqual(resumeRequests.count, 1)
        let cancelledRemoteOwner = await eventually {
            await adapter.cancelledRunIDs.contains(request.id)
        }
        XCTAssertTrue(cancelledRemoteOwner)
    }

    func testResponseFrameCursorCannotBeLostToConcurrentBackgroundDetach() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = DurableNovelModelAdapter()
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let request = makeRequest(
            document: document,
            kind: .prose,
            granularity: .wholeChapter
        )
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()

        let mainActorEntered = expectation(description: "MainActor lease update is suspended")
        let releaseMainActor = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainActorEntered.fulfill()
            releaseMainActor.wait()
        }
        await fulfillment(of: [mainActorEntered], timeout: 1)

        await adapter.yieldInitial(
            .responseFrame(NovelModelResponseFrame(
                cursor: NovelResponsesResumeCursor(responseID: "resp_interleave", sequenceNumber: 1),
                events: [.textDelta("原子帧")]
            )),
            runID: request.id
        )
        guard case .delta("原子帧")? = await iterator.next() else {
            releaseMainActor.signal()
            return XCTFail("Expected frame text before lease update resumes")
        }

        let expiration = Task {
            await creation.interruptForBackground(
                projectID: request.projectID,
                deadline: .distantPast,
                runID: request.id
            )
        }
        let didDetach = await eventually {
            await adapter.detachedRunIDs.contains(request.id)
        }
        releaseMainActor.signal()
        await expiration.value

        XCTAssertTrue(didDetach)
        await creation.resumeDetachedGenerationRuns()
        let didResume = await eventually {
            await adapter.resumeRequests.contains { $0.runID == request.id }
        }
        XCTAssertTrue(didResume)
    }

    func testMaterialRevisionWhileProviderAwaitsIsPreservedWithCandidateTerminal() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause, .delta("Candidate after config edit"), .complete])]
        )
        let request = makeRequest(document: document, kind: .prose, granularity: .continuation)
        let run = try await harness.creation.start(request)
        let afterMarker = try await harness.repository.document(request.projectID)
        let materialID = NovelMaterialID()
        let revisionID = NovelMaterialRevisionID()

        _ = try await harness.creation.perform(NovelTestFixtures.materialAction(
            document: afterMarker,
            materialID: materialID,
            revisionID: revisionID,
            content: "The river remembers every name."
        ))
        await harness.adapter.resume(runID: request.id)
        let events = await capturedEvents(run.events)
        guard case .completed(let snapshot) = events.last else {
            return XCTFail("Expected candidate completion")
        }
        XCTAssertEqual(snapshot.message.candidateID, request.candidateID)

        let final = try await harness.repository.document(request.projectID)
        XCTAssertEqual(final.materials.first(where: { $0.id == materialID })?.currentRevisionID, revisionID)
        XCTAssertEqual(final.materialRevisions.first(where: { $0.id == revisionID })?.content, "The river remembers every name.")
        XCTAssertEqual(final.candidates.first(where: { $0.id == request.candidateID })?.content, "Candidate after config edit")
        XCTAssertEqual(final.activeRuns.first(where: { $0.id == request.id })?.status, .completed)
        XCTAssertEqual(final.checkpoints, document.checkpoints)
        XCTAssertEqual(final.stateSnapshots, document.stateSnapshots)
    }

    func testBackgroundDeadlineClaimsOnceAndDropsLateCallbacks() async throws {
        let cases: [(TimeInterval, NovelRunInterruptionReason)] = [
            (5, .background),
            (-1, .expiration)
        ]
        for (deadlineOffset, expectedReason) in cases {
            let document = try NovelTestFixtures.document()
            let harness = try await makeHarness(
                document: document,
                scripts: [NovelModelScript(
                    steps: [.delta("Kept"), .pause, .delta(" late"), .complete],
                    ignoresCancellation: true
                )]
            )
            let request = makeRequest(
                document: document,
                kind: .prose,
                granularity: .continuation
            )
            let run = try await harness.creation.start(request)
            var iterator = run.events.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()

            await harness.creation.interruptForBackground(
                projectID: request.projectID,
                deadline: Date(timeIntervalSince1970: 1_700_001_000 + deadlineOffset)
            )
            guard case .interrupted(let snapshot)? = await iterator.next() else {
                return XCTFail("Expected a background interruption")
            }
            XCTAssertEqual(snapshot?.message.content, "Kept")
            let firstTerminal = try await harness.repository.document(request.projectID)
            XCTAssertEqual(firstTerminal.activeRuns[0].interruptionReason, expectedReason)

            await harness.adapter.resume(runID: request.id)
            try? await Task.sleep(nanoseconds: 30_000_000)
            let afterLateCallbacks = try await harness.repository.document(request.projectID)
            XCTAssertEqual(afterLateCallbacks, firstTerminal)
            XCTAssertEqual(afterLateCallbacks.activeRuns[0].partialContent, "Kept")
        }
    }

    func testTerminalPersistenceFailureIsObservableAndRetryable() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("Retry this"), .pause, .complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        let run = try await harness.creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()

        await harness.repository.failNextCommits(3)
        await harness.adapter.resume(runID: request.id)
        guard case .persistenceBlocked(let failure)? = await iterator.next() else {
            return XCTFail("Expected an observable persistence failure")
        }
        XCTAssertEqual(failure.code, "terminal_persist_failed")
        let stillRunning = try await harness.repository.document(request.projectID)
        XCTAssertEqual(stillRunning.activeRuns[0].status, .running)

        let reattached = try await harness.creation.start(request)
        var reattachedIterator = reattached.events.makeAsyncIterator()
        guard case .started? = await reattachedIterator.next(),
              case .replaced("Retry this")? = await reattachedIterator.next(),
              case .persistenceBlocked(let replayedFailure)? = await reattachedIterator.next() else {
            return XCTFail("Expected blocked persistence to replay on reattach")
        }
        XCTAssertEqual(replayedFailure, failure)

        try await harness.creation.retryPendingTerminal(runID: request.id)
        guard case .completed(let snapshot)? = await iterator.next() else {
            return XCTFail("Expected retry to publish the durable terminal")
        }
        XCTAssertEqual(snapshot.message.content, "Retry this")
        guard case .completed(let reattachedSnapshot)? = await reattachedIterator.next() else {
            return XCTFail("Expected retry to finish the reattached stream")
        }
        XCTAssertEqual(reattachedSnapshot, snapshot)
    }

    func testProjectListDefersCrashRecoveryUntilProjectSnapshot() async throws {
        let document = try NovelTestFixtures.document()
        let seedHarness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        let seedRun = try await seedHarness.creation.start(request)
        let runningDocument = try await seedHarness.repository.document(request.projectID)

        let repository = ObservingNovelRepository()
        try await repository.seed(runningDocument)
        let restarted = DefaultNovelCreation(repository: repository)

        guard case .projects(let summaries) = try await restarted.snapshot(.projects) else {
            return XCTFail("Expected a project list snapshot")
        }
        XCTAssertEqual(summaries.map(\.id), [request.projectID])
        let afterList = try await repository.document(request.projectID)
        XCTAssertEqual(afterList.activeRuns.first?.status, .running)

        _ = try await restarted.snapshot(.project(request.projectID))
        let afterOpen = try await repository.document(request.projectID)
        XCTAssertEqual(afterOpen.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(afterOpen.activeRuns.first?.interruptionReason, .recovery)

        await seedHarness.adapter.resume(runID: request.id)
        _ = await capturedEvents(seedRun.events)
    }

    func testRecoveryRejectsMismatchedSidecarIdentity() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        _ = try await harness.creation.start(request)
        let running = try await harness.repository.document(request.projectID)
        let run = try XCTUnwrap(running.activeRuns.first(where: { $0.id == request.id }))
        let untrusted = "Content from another run"
        try await harness.repository.writeRecoverySidecar(NovelRecoverySidecarV1(
            schemaVersion: NovelRecoverySidecarV1.currentSchemaVersion,
            projectID: request.projectID,
            runID: request.id,
            branchID: run.branchID,
            sessionID: run.sessionID,
            messageID: NovelMessageID(),
            baseProjectRevision: running.project.revision,
            sequence: 1,
            partialContent: untrusted,
            partialSHA256: NovelDocumentValidator.sha256(untrusted),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_001)
        ))

        let restarted = DefaultNovelCreation(repository: harness.repository)
        _ = try await restarted.snapshot(.project(request.projectID))
        let recovered = try await harness.repository.document(request.projectID)
        XCTAssertEqual(recovered.activeRuns[0].status, .interrupted)
        XCTAssertEqual(recovered.activeRuns[0].interruptionReason, .recovery)
        XCTAssertEqual(recovered.activeRuns[0].partialContent, "")
        XCTAssertFalse(recovered.sessions[0].messages.contains {
            $0.content == untrusted
        })
    }

    func testRecoveryFailureLeavesRecoveryRetryable() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        _ = try await harness.creation.start(request)
        await harness.repository.failNextCommits(3)

        let restarted = DefaultNovelCreation(repository: harness.repository)
        do {
            _ = try await restarted.snapshot(.project(request.projectID))
            XCTFail("Expected the first recovery attempt to fail")
        } catch let error as NovelError {
            guard case .repositoryFailure = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        let stillRunning = try await harness.repository.document(request.projectID)
        XCTAssertEqual(stillRunning.activeRuns[0].status, .running)

        _ = try await restarted.snapshot(.project(request.projectID))
        let recovered = try await harness.repository.document(request.projectID)
        XCTAssertEqual(recovered.activeRuns[0].status, .interrupted)
        XCTAssertEqual(recovered.activeRuns[0].interruptionReason, .recovery)
    }

    func testRecoveryFailureInOneProjectDoesNotBlockAnotherProjectSnapshot() async throws {
        let firstProjectID = NovelProjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondProjectID = NovelProjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let firstDocument = try NovelTestFixtures.document(projectID: firstProjectID)
        let secondDocument = try NovelTestFixtures.document(projectID: secondProjectID)
        let firstHarness = try await makeHarness(
            document: firstDocument,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let secondHarness = try await makeHarness(
            document: secondDocument,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let firstRequest = makeRequest(document: firstDocument, kind: .discussion)
        let secondRequest = makeRequest(document: secondDocument, kind: .discussion)
        let firstRun = try await firstHarness.creation.start(firstRequest)
        let secondRun = try await secondHarness.creation.start(secondRequest)

        let repository = ObservingNovelRepository()
        try await repository.seed(firstHarness.repository.document(firstProjectID))
        try await repository.seed(secondHarness.repository.document(secondProjectID))
        await repository.failCommits(for: firstProjectID)
        let restarted = DefaultNovelCreation(repository: repository)

        guard case .project(let secondSnapshot) = try await restarted.snapshot(.project(secondProjectID)) else {
            return XCTFail("Expected the healthy project snapshot")
        }
        XCTAssertEqual(secondSnapshot.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(secondSnapshot.activeRuns.first?.interruptionReason, .recovery)
        let firstAfterSecondRecovery = try await repository.document(firstProjectID)
        XCTAssertEqual(
            firstAfterSecondRecovery.activeRuns.first?.status,
            .running,
            "The failed project's marker must not be treated as recovered."
        )

        do {
            _ = try await restarted.snapshot(.project(firstProjectID))
            XCTFail("Expected the failed project to remain fail-closed")
        } catch let error as NovelError {
            guard case .repositoryFailure = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }
        let firstAfterFailedOpen = try await repository.document(firstProjectID)
        XCTAssertEqual(firstAfterFailedOpen.activeRuns.first?.status, .running)

        await repository.allowCommits(for: firstProjectID)
        guard case .project(let firstSnapshot) = try await restarted.snapshot(.project(firstProjectID)) else {
            return XCTFail("Expected the failed project recovery to remain retryable")
        }
        XCTAssertEqual(firstSnapshot.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(firstSnapshot.activeRuns.first?.interruptionReason, .recovery)

        await firstHarness.adapter.resume(runID: firstRequest.id)
        await secondHarness.adapter.resume(runID: secondRequest.id)
        _ = await capturedEvents(firstRun.events)
        _ = await capturedEvents(secondRun.events)
    }

    func testConcurrentProjectSnapshotWaitsForCurrentRecoveryThenRecoversItsOwnMarker() async throws {
        let firstDocument = try NovelTestFixtures.document()
        let secondDocument = try NovelTestFixtures.document()
        let firstHarness = try await makeHarness(
            document: firstDocument,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let secondHarness = try await makeHarness(
            document: secondDocument,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let firstRequest = makeRequest(document: firstDocument, kind: .discussion)
        let secondRequest = makeRequest(document: secondDocument, kind: .discussion)
        let firstRun = try await firstHarness.creation.start(firstRequest)
        let secondRun = try await secondHarness.creation.start(secondRequest)

        let repository = ObservingNovelRepository()
        try await repository.seed(firstHarness.repository.document(firstDocument.project.id))
        try await repository.seed(secondHarness.repository.document(secondDocument.project.id))
        await repository.blockNextCommit()
        let restarted = DefaultNovelCreation(repository: repository)
        let firstSnapshotTask = Task {
            try await restarted.snapshot(.project(firstDocument.project.id))
        }
        let firstCommitBlocked = await eventually { await repository.commitIsBlocked() }
        XCTAssertTrue(firstCommitBlocked)

        let secondCompletion = NovelSnapshotCompletionProbe()
        let secondSnapshotTask = Task {
            await secondCompletion.markStarted()
            do {
                let snapshot = try await restarted.snapshot(.project(secondDocument.project.id))
                await secondCompletion.markCompleted()
                return snapshot
            } catch {
                await secondCompletion.markCompleted()
                throw error
            }
        }
        let secondStarted = await eventually { await secondCompletion.isStarted }
        XCTAssertTrue(secondStarted)
        let secondReturnedBeforeFirstRecovery = await eventually(timeout: 0.1) {
            await secondCompletion.isCompleted
        }
        XCTAssertFalse(
            secondReturnedBeforeFirstRecovery,
            "A concurrent project request must not cross an active recovery barrier."
        )

        await repository.resumeBlockedCommit()
        guard case .project(let firstSnapshot) = try await firstSnapshotTask.value,
              case .project(let secondSnapshot) = try await secondSnapshotTask.value else {
            return XCTFail("Expected both recovered project snapshots")
        }
        XCTAssertEqual(firstSnapshot.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(secondSnapshot.activeRuns.first?.status, .interrupted)

        await firstHarness.adapter.resume(runID: firstRequest.id)
        await secondHarness.adapter.resume(runID: secondRequest.id)
        _ = await capturedEvents(firstRun.events)
        _ = await capturedEvents(secondRun.events)
    }

    func testScopedRecoveryLoadsRequiredProjectWhenInventoryOmitsIt() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        let run = try await harness.creation.start(request)
        let repository = ObservingNovelRepository()
        try await repository.seed(harness.repository.document(document.project.id))
        await repository.omitFromProjectList(document.project.id)

        let restarted = DefaultNovelCreation(repository: repository)
        guard case .project(let snapshot) = try await restarted.snapshot(.project(document.project.id)) else {
            return XCTFail("Expected a project snapshot")
        }
        XCTAssertEqual(snapshot.activeRuns.first?.status, .interrupted)
        XCTAssertEqual(snapshot.activeRuns.first?.interruptionReason, .recovery)

        await harness.adapter.resume(runID: request.id)
        _ = await capturedEvents(run.events)
    }

    func testImportPreviewRecoversOnlyDecodedProject() async throws {
        let existingDocument = try NovelTestFixtures.document()
        let seedHarness = try await makeHarness(
            document: existingDocument,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let existingRequest = makeRequest(document: existingDocument, kind: .discussion)
        let existingRun = try await seedHarness.creation.start(existingRequest)
        let importedDocument = try NovelTestFixtures.document()
        let package = try NovelProjectPackageCodec.encode(importedDocument)

        let repository = ObservingNovelRepository()
        try await repository.seed(seedHarness.repository.document(existingDocument.project.id))
        await repository.failCommits(for: existingDocument.project.id)
        let restarted = DefaultNovelCreation(repository: repository)

        guard case .projectImportPreview(let preview) = try await restarted.snapshot(
            .projectImportPreview(package.data)
        ) else {
            return XCTFail("Expected an import preview")
        }
        XCTAssertEqual(preview.sourceProjectID, importedDocument.project.id)
        let existingAfterPreview = try await repository.document(existingDocument.project.id)
        XCTAssertEqual(existingAfterPreview.activeRuns.first?.status, .running)

        await seedHarness.adapter.resume(runID: existingRequest.id)
        _ = await capturedEvents(existingRun.events)
    }

    func testScopedRecoveryIsRememberedAcrossProjectAndBranchSnapshots() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let restarted = DefaultNovelCreation(repository: repository)

        _ = try await restarted.snapshot(.project(document.project.id))
        let loadCountAfterProject = await repository.loadCount(for: document.project.id)
        _ = try await restarted.snapshot(.branch(
            projectID: document.project.id,
            branchID: document.branches[0].id
        ))

        let loadCountAfterBranch = await repository.loadCount(for: document.project.id)
        XCTAssertEqual(loadCountAfterBranch, loadCountAfterProject)
    }

    func testCancelCannotClaimSameRunIDFromAnotherProject() async throws {
        let first = try NovelTestFixtures.document()
        let second = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: first,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        try await harness.repository.seed(second)
        let request = makeRequest(document: first, kind: .discussion)
        _ = try await harness.creation.start(request)

        do {
            _ = try await harness.creation.perform(.cancelRun(cancelCommand(
                document: second,
                runID: request.id
            )))
            XCTFail("Expected a cross-project cancel to be rejected")
        } catch let error as NovelError {
            XCTAssertEqual(error, .runNotFound(request.id))
        }

        let firstAfterCancel = try await harness.repository.document(first.project.id)
        let secondAfterCancel = try await harness.repository.document(second.project.id)
        let cancelledRunIDs = await harness.adapter.cancelledRunIDs
        XCTAssertEqual(firstAfterCancel.activeRuns[0].status, .running)
        XCTAssertTrue(secondAfterCancel.activeRuns.isEmpty)
        XCTAssertFalse(cancelledRunIDs.contains(request.id))
    }

    func testStartPreservesRequiredBudgetItemDetails() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let request = makeRequest(
            document: document,
            kind: .discussion,
            inputBudgetTokens: 1
        )

        do {
            _ = try await harness.creation.start(request)
            XCTFail("Expected protected context to exceed the budget")
        } catch let error as NovelError {
            guard case .injectionBudgetExceeded(
                let required,
                let limit,
                let items
            ) = error else {
                return XCTFail("Unexpected budget error: \(error)")
            }
            XCTAssertGreaterThan(required, limit)
            XCTAssertEqual(limit, 1)
            XCTAssertFalse(items.isEmpty)
            XCTAssertTrue(items.allSatisfy {
                !$0.label.isEmpty && $0.estimatedTokens > 0
            })
        }
    }

    func testModelWindowClampsPlannerBudgetInsteadOfRejectingSmallRequest() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("A small response."), .complete])],
            contextWindowTokens: 8_192
        )
        let request = makeRequest(
            document: document,
            kind: .discussion,
            inputBudgetTokens: 16_000
        )

        let run = try await harness.creation.start(request)
        let events = await capturedEvents(run.events)

        XCTAssertTrue(events.contains { event in
            if case .completed = event { return true }
            return false
        })
        let stored = try await harness.repository.document(document.project.id)
        let expectedBudget = 8_192 - NovelRunKind.discussion.outputReservationTokens - 1_024
        XCTAssertEqual(stored.injectionReceipts.count, 1)
        XCTAssertEqual(stored.injectionReceipts[0].requestedInputBudgetTokens, 16_000)
        XCTAssertEqual(stored.injectionReceipts[0].maxEstimatedInputTokens, expectedBudget)
        XCTAssertLessThan(stored.injectionReceipts[0].estimatedInputTokens, expectedBudget)
    }

    func testConcurrentExactStartUsesOneReservationAndTwoSubscribers() async throws {
        let document = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause, .delta("One run"), .complete])]
        )
        let request = makeRequest(document: document, kind: .discussion)
        await harness.repository.blockNextCommit()
        let firstTask = Task { try await harness.creation.start(request) }
        let firstCommitBlocked = await eventually {
            await harness.repository.commitIsBlocked()
        }
        XCTAssertTrue(firstCommitBlocked)
        let secondTask = Task { try await harness.creation.start(request) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await harness.repository.resumeBlockedCommit()

        let firstRun = try await firstTask.value
        let secondRun = try await secondTask.value
        await harness.adapter.resume(runID: request.id)
        let eventsA = await capturedEvents(firstRun.events)
        let eventsB = await capturedEvents(secondRun.events)
        let requests = await harness.adapter.requests
        XCTAssertEqual(eventsA.last, eventsB.last)
        XCTAssertEqual(requests.count, 1)
        let persisted = try await harness.repository.document(request.projectID)
        XCTAssertEqual(persisted.generationReceipts.filter { $0.runID == request.id }.count, 1)
    }

    func testConcurrentCrossProjectRunIDCannotOverwriteReservation() async throws {
        let first = try NovelTestFixtures.document()
        let second = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: first,
            scripts: [
                NovelModelScript(steps: [.pause]),
                NovelModelScript(steps: [.pause])
            ]
        )
        try await harness.repository.seed(second)
        let sharedRunID = NovelRunID()
        let firstRequest = makeRequest(
            document: first,
            kind: .discussion,
            runID: sharedRunID
        )
        let secondRequest = makeRequest(
            document: second,
            kind: .discussion,
            runID: sharedRunID
        )
        await harness.repository.blockNextCommit()
        let firstTask = Task { try await harness.creation.start(firstRequest) }
        let firstCommitBlocked = await eventually {
            await harness.repository.commitIsBlocked()
        }
        XCTAssertTrue(firstCommitBlocked)

        do {
            _ = try await harness.creation.start(secondRequest)
            XCTFail("Expected the reserved run ID to reject another project")
        } catch let error as NovelError {
            XCTAssertEqual(error, .idempotencyConflict(secondRequest.operationID))
        }
        await harness.repository.resumeBlockedCommit()
        _ = try await firstTask.value
        let secondAfterStart = try await harness.repository.document(second.project.id)
        let requests = await harness.adapter.requests
        XCTAssertTrue(secondAfterStart.activeRuns.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    func testDegradedRecoveryKeepsRunningMarkerAndValidSidecar() async throws {
        let document = try NovelTestFixtures.document()
        let policy = NovelGenerationPolicy(
            sidecarByteThreshold: 1,
            sidecarInterval: 10_000,
            chapterTailCharacterLimit: 6_000,
            maximumRecentSessionMessages: 12
        )
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("Keep safely"), .pause])],
            policy: policy
        )
        let request = makeRequest(document: document, kind: .discussion)
        let run = try await harness.creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        let wroteSidecar = await eventually {
            (try? await harness.repository.listRecoverySidecars().isEmpty) == false
        }
        XCTAssertTrue(wroteSidecar)
        await harness.repository.setLoadAccess(
            .degradedPrevious(primaryFailure: "Injected primary failure."),
            projectID: request.projectID
        )

        let restarted = DefaultNovelCreation(repository: harness.repository)
        _ = try await restarted.snapshot(.project(request.projectID))
        let durable = try await harness.repository.document(request.projectID)
        let remainingSidecars = try await harness.repository.listRecoverySidecars()
        XCTAssertEqual(durable.activeRuns[0].status, .running)
        XCTAssertEqual(remainingSidecars.count, 1)

        await harness.repository.setLoadAccess(nil, projectID: request.projectID)
        let writableRestart = DefaultNovelCreation(repository: harness.repository)
        _ = try await writableRestart.snapshot(.project(request.projectID))
        let recovered = try await harness.repository.document(request.projectID)
        XCTAssertEqual(recovered.activeRuns[0].status, .interrupted)
        XCTAssertEqual(recovered.activeRuns[0].interruptionReason, .recovery)
        XCTAssertEqual(recovered.activeRuns[0].partialContent, "Keep safely")
        XCTAssertEqual(recovered.sessions[0].messages.last?.content, "Keep safely")
        let sidecarsAfterRecovery = try await harness.repository.listRecoverySidecars()
        XCTAssertTrue(sidecarsAfterRecovery.isEmpty)
        _ = try await writableRestart.snapshot(.project(request.projectID))
        let afterSecondRecovery = try await harness.repository.document(request.projectID)
        XCTAssertEqual(afterSecondRecovery, recovered)
    }

    func testBackgroundInterruptionReturnsAtDeadlineWhilePersistenceAndCancelAreBlocked() async throws {
        let document = try NovelTestFixtures.document()
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = BlockingCancelNovelModelAdapter()
        let creation = DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter,
            now: { Date(timeIntervalSince1970: 1_700_001_000) }
        )
        let request = makeRequest(document: document, kind: .discussion)
        let run = try await creation.start(request)
        var iterator = run.events.makeAsyncIterator()
        _ = await iterator.next()
        await repository.blockNextCommit()

        let wallStart = Date()
        await creation.interruptForBackground(
            projectID: request.projectID,
            deadline: Date(timeIntervalSince1970: 1_700_001_000.02)
        )
        XCTAssertLessThan(Date().timeIntervalSince(wallStart), 0.5)
        let commitBlocked = await eventually { await repository.commitIsBlocked() }
        let cancelStarted = await eventually { await adapter.cancelDidStart() }
        XCTAssertTrue(commitBlocked)
        XCTAssertTrue(cancelStarted)

        await creation.interruptForBackground(
            projectID: request.projectID,
            deadline: Date(timeIntervalSince1970: 1_700_000_999)
        )
        await repository.resumeBlockedCommit()
        guard case .interrupted? = await iterator.next() else {
            return XCTFail("Expected the original background claim to finish")
        }
        let terminal = try await repository.document(request.projectID)
        XCTAssertEqual(terminal.activeRuns[0].interruptionReason, .background)
        await adapter.releaseCancel()
    }

    func testRestartCoversTerminalWrittenSidecarPresentAndSidecarDeletedCrashPoints() async throws {
        for leaveSidecar in [true, false] {
            let document = try NovelTestFixtures.document()
            let policy = NovelGenerationPolicy(
                sidecarByteThreshold: 1,
                sidecarInterval: 10_000,
                chapterTailCharacterLimit: 6_000,
                maximumRecentSessionMessages: 12
            )
            let harness = try await makeHarness(
                document: document,
                scripts: [NovelModelScript(steps: [.delta("Terminal"), .pause, .complete])],
                policy: policy
            )
            let request = makeRequest(document: document, kind: .discussion)
            let run = try await harness.creation.start(request)
            var iterator = run.events.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
            let wroteSidecar = await eventually {
                (try? await harness.repository.listRecoverySidecars().isEmpty) == false
            }
            XCTAssertTrue(wroteSidecar)
            if leaveSidecar {
                await harness.repository.failNextSidecarRemovals(1)
            }
            await harness.adapter.resume(runID: request.id)
            guard case .completed? = await iterator.next() else {
                return XCTFail("Expected a durable terminal")
            }
            let terminal = try await harness.repository.document(request.projectID)
            let sidecarsAtCrash = try await harness.repository.listRecoverySidecars()
            XCTAssertEqual(sidecarsAtCrash.isEmpty, !leaveSidecar)

            let restarted = DefaultNovelCreation(repository: harness.repository)
            _ = try await restarted.snapshot(.project(request.projectID))
            let afterRestart = try await harness.repository.document(request.projectID)
            let sidecarsAfterRestart = try await harness.repository.listRecoverySidecars()
            XCTAssertEqual(afterRestart, terminal)
            XCTAssertTrue(sidecarsAfterRestart.isEmpty)
        }
    }

    func testStartupRecoveryWaitsForConcurrentProjectMutationAfterLedgerDiscovery() async throws {
        let seedDocument = try NovelTestFixtures.document()
        let seedHarness = try await makeHarness(
            document: seedDocument,
            scripts: [NovelModelScript(steps: [.pause, .delta("Cleanup"), .complete])]
        )
        let request = makeRequest(document: seedDocument, kind: .discussion)
        let seedRun = try await seedHarness.creation.start(request)
        let runningDocument = try await seedHarness.repository.document(request.projectID)
        await seedHarness.adapter.resume(runID: request.id)
        _ = await capturedEvents(seedRun.events)

        let repository = ObservingNovelRepository()
        try await repository.seed(runningDocument)
        let restarted = DefaultNovelCreation(repository: repository)
        await repository.blockNextLoad()

        let recoverySnapshot = Task {
            try await restarted.snapshot(.project(request.projectID))
        }
        let loadBlocked = await eventually { await repository.loadIsBlocked() }
        XCTAssertTrue(loadBlocked)

        await repository.blockNextCommit()
        let rename = NovelAction.renameProject(NovelRenameProjectCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: runningDocument.project.revision,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: request.projectID,
            name: "Recovered After Rename"
        ))
        let renameTask = Task { try await restarted.perform(rename) }
        let commitBlocked = await eventually { await repository.commitIsBlocked() }
        XCTAssertTrue(commitBlocked)

        await repository.resumeBlockedLoad()
        let recoveryCommittedBeforeRename = await eventually(timeout: 0.1) {
            await repository.commitHistory().isEmpty == false
        }
        XCTAssertFalse(recoveryCommittedBeforeRename)

        await repository.resumeBlockedCommit()
        _ = try await renameTask.value
        guard case .project(let snapshot) = try await recoverySnapshot.value else {
            return XCTFail("Expected a recovered project snapshot")
        }
        XCTAssertEqual(snapshot.project.name, "Recovered After Rename")
        XCTAssertEqual(snapshot.project.revision, runningDocument.project.revision + 2)
        XCTAssertEqual(snapshot.activeRuns.first?.status, .interrupted)
        XCTAssertNil(snapshot.branches.first?.activeRunID)
    }
}
