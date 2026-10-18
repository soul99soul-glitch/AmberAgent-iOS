import XCTest
@testable import iosApp

extension NovelGenerationLifecycleTests {
    struct Harness {
        let repository: ObservingNovelRepository
        let adapter: ScriptedNovelModelAdapter
        let creation: DefaultNovelCreation
    }

    struct CompletionCase {
        let kind: NovelRunKind
        let granularity: NovelGenerationGranularity?
        let content: String
        let expectedMessage: NovelSessionMessageKind
    }

    enum CapturedEvent: Equatable {
        case started(NovelRunID)
        case reasoningDelta(String)
        case reasoningReplacement(String)
        case delta(String)
        case replaced(String)
        case completed(NovelSessionMessageSnapshot)
        case interrupted(NovelSessionMessageSnapshot?)
        case failed(NovelFailure)
        case persistenceBlocked(NovelFailure)
    }

    func makeHarness(
        document: NovelProjectDocumentV1,
        scripts: [NovelModelScript],
        policy: NovelGenerationPolicy = .standard,
        contextWindowTokens: Int = 128_000
    ) async throws -> Harness {
        let repository = ObservingNovelRepository()
        try await repository.seed(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider-id",
                ownerProviderID: "provider-id",
                modelID: "model-uuid",
                wireModelID: "novel-model-v1",
                displayName: "Novel Model",
                contextWindowTokens: contextWindowTokens
            ),
            scripts: scripts
        )
        return Harness(
            repository: repository,
            adapter: adapter,
            creation: DefaultNovelCreation(
                repository: repository,
                modelRunner: adapter,
                generationPolicy: policy,
                now: { Date(timeIntervalSince1970: 1_700_001_000) }
            )
        )
    }

    func makeRequest(
        document: NovelProjectDocumentV1,
        kind: NovelRunKind,
        granularity: NovelGenerationGranularity? = nil,
        sourceChapterVersionID: NovelChapterVersionID? = nil,
        runID: NovelRunID = NovelRunID(),
        operationID: NovelOperationID = NovelOperationID(),
        contextualCharacterMention: String? = nil,
        inputBudgetTokens: Int = 16_000
    ) -> NovelRunRequest {
        let branch = document.branches[0]
        let mode: NovelSessionMode = switch kind {
        case .quickStart, .characterProposal, .discussion: .discussPlan
        case .prose, .polish, .regenerate: .writeProse
        }
        let candidateID: NovelCandidateID? = switch kind {
        case .quickStart, .characterProposal, .discussion: nil
        case .prose, .polish, .regenerate: NovelCandidateID()
        }
        return NovelRunRequest(
            id: runID,
            operationID: operationID,
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
            contextualCharacterMention: contextualCharacterMention,
            inputBudgetTokens: inputBudgetTokens,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
    }

    func quickStartDocument() throws -> NovelProjectDocumentV1 {
        try NovelReducer.createProject(NovelCreateProjectCommand(
            context: NovelTestFixtures.context(operationID: NovelOperationID()),
            projectID: NovelProjectID(),
            branchID: NovelBranchID(),
            sessionID: NovelSessionID(),
            initialStateSnapshotID: NovelStateSnapshotID(),
            initialCheckpointID: NovelCheckpointID(),
            name: "Quick Start",
            branchName: "Main",
            creationMode: .quickStart,
            quickStartSeed: NovelQuickStartSeed(
                genre: "Mystery",
                coreIdea: "Memories can testify."
            )
        ), now: Date(timeIntervalSince1970: 1_700_000_000)).document
    }

    func documentWithUnresolvedCharacter(_ mention: String) throws -> NovelProjectDocumentV1 {
        var document = try NovelTestFixtures.document()
        let state = document.stateSnapshots[0]
        document.stateSnapshots[0] = NovelStateSnapshotRecord(
            id: state.id,
            eventIDs: state.eventIDs,
            summary: state.summary,
            branchOutline: state.branchOutline,
            unresolvedEntityNames: [mention],
            createdAt: state.createdAt,
            settingProposalIDs: state.settingProposalIDs,
            characterIdentityClarifications: state.characterIdentityClarifications
        )
        return document
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
            {"kind":"relationship","title":"郭威与柴荣","content":"养父子关系。"},
            {"kind":"world","title":"后汉军政格局","content":"军权影响朝局。"},
            {"kind":"plot","title":"后周权力交接","content":"三人的故事线依次推进。"}
          ]
        }
        """
    }

    func cancelCommand(
        document: NovelProjectDocumentV1,
        runID: NovelRunID
    ) -> NovelCancelRunCommand {
        NovelCancelRunCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: document.project.revision,
                expectedConfigRevision: document.project.configRevision,
                expectedBranchHeadRevision: document.branches[0].headRevision
            ),
            projectID: document.project.id,
            runID: runID,
            reason: .user
        )
    }

    func capturedEvents(_ stream: AsyncStream<NovelRunEvent>) async -> [CapturedEvent] {
        var result: [CapturedEvent] = []
        for await event in stream {
            switch event {
            case .started(let receipt): result.append(.started(receipt.runID))
            case .reasoningDelta(let text): result.append(.reasoningDelta(text))
            case .reasoningReplacement(let text): result.append(.reasoningReplacement(text))
            case .delta(let text): result.append(.delta(text))
            case .replaced(let text): result.append(.replaced(text))
            case .completed(let message): result.append(.completed(message))
            case .interrupted(let message): result.append(.interrupted(message))
            case .failed(let failure): result.append(.failed(failure))
            case .persistenceBlocked(let failure): result.append(.persistenceBlocked(failure))
            }
        }
        return result
    }

    func eventually(
        timeout: TimeInterval = 1,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    func documentWithChapter() throws -> (NovelProjectDocumentV1, NovelChapterVersionID?) {
        var document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let chapterID = NovelChapterID()
        let versionID = NovelChapterVersionID()
        let operationID = document.appliedOperations[0].operationID
        let timestamp = document.project.updatedAt
        document.chapters.append(NovelChapterRecord(id: chapterID, createdAt: timestamp))
        document.chapterVersions.append(NovelChapterVersionRecord(
            id: versionID,
            chapterID: chapterID,
            kind: .collected,
            title: "Chapter One",
            content: "The witness entered the silent courtroom.",
            factCompatibilityID: UUID(),
            sourceCandidateID: nil,
            createdAt: timestamp,
            operationID: operationID
        ))
        let checkpointIndex = try XCTUnwrap(document.checkpoints.firstIndex {
            $0.id == document.branches[0].headCheckpointID
        })
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
}

actor ObservingNovelRepository: NovelProjectPersisting {
    private let base = InMemoryNovelProjectRepository()
    private var commits: [NovelProjectDocumentV1] = []
    private var writtenSidecars: [NovelRecoverySidecarV1] = []
    private var removedSidecarRunIDs: [NovelRunID] = []
    private var remainingCommitFailures = 0
    private var failingCommitProjectIDs: Set<NovelProjectID> = []
    private var remainingSidecarWriteFailures = 0
    private var remainingSidecarRemovalFailures = 0
    private var forcedAccess: [NovelProjectID: NovelProjectLoadAccess] = [:]
    private var omittedSummaryProjectIDs: Set<NovelProjectID> = []
    private var projectLoadCounts: [NovelProjectID: Int] = [:]
    private var shouldBlockNextCommit = false
    private var blockedCommitContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockNextLoad = false
    private var blockedLoadContinuation: CheckedContinuation<Void, Never>?

    func seed(_ document: NovelProjectDocumentV1) async throws {
        _ = try await base.createProject(document)
    }

    func document(_ id: NovelProjectID) async throws -> NovelProjectDocumentV1 {
        let loaded = try await base.loadProject(id: id)
        return loaded.document
    }

    func commitHistory() -> [NovelProjectDocumentV1] { commits }
    func sidecarWrites() -> [NovelRecoverySidecarV1] { writtenSidecars }
    func sidecarRemovals() -> [NovelRunID] { removedSidecarRunIDs }
    func failNextCommits(_ count: Int) { remainingCommitFailures = count }
    func failCommits(for projectID: NovelProjectID) {
        failingCommitProjectIDs.insert(projectID)
    }
    func allowCommits(for projectID: NovelProjectID) {
        failingCommitProjectIDs.remove(projectID)
    }
    func omitFromProjectList(_ projectID: NovelProjectID) {
        omittedSummaryProjectIDs.insert(projectID)
    }
    func loadCount(for projectID: NovelProjectID) -> Int {
        projectLoadCounts[projectID, default: 0]
    }
    func failNextSidecarRemovals(_ count: Int) {
        remainingSidecarRemovalFailures = count
    }
    func failNextSidecarWrites(_ count: Int) {
        remainingSidecarWriteFailures = count
    }
    func setLoadAccess(_ access: NovelProjectLoadAccess?, projectID: NovelProjectID) {
        forcedAccess[projectID] = access
    }
    func blockNextCommit() { shouldBlockNextCommit = true }
    func commitIsBlocked() -> Bool { blockedCommitContinuation != nil }
    func resumeBlockedCommit() {
        let continuation = blockedCommitContinuation
        blockedCommitContinuation = nil
        continuation?.resume()
    }
    func blockNextLoad() { shouldBlockNextLoad = true }
    func loadIsBlocked() -> Bool { blockedLoadContinuation != nil }
    func resumeBlockedLoad() {
        let continuation = blockedLoadContinuation
        blockedLoadContinuation = nil
        continuation?.resume()
    }

    func listProjects() async throws -> [NovelProjectSummary] {
        let summaries = try await base.listProjects()
        return summaries.filter { !omittedSummaryProjectIDs.contains($0.id) }
    }

    func loadProject(id: NovelProjectID) async throws -> NovelLoadedProject {
        projectLoadCounts[id, default: 0] += 1
        let loaded = try await base.loadProject(id: id)
        if shouldBlockNextLoad {
            shouldBlockNextLoad = false
            await withCheckedContinuation { continuation in
                blockedLoadContinuation = continuation
            }
        }
        guard let access = forcedAccess[id] else { return loaded }
        return NovelLoadedProject(document: loaded.document, access: access)
    }

    func createProject(_ document: NovelProjectDocumentV1) async throws -> NovelLoadedProject {
        try await base.createProject(document)
    }

    func commitProject(
        _ document: NovelProjectDocumentV1,
        expectedRevision: Int64,
        authorization: NovelRepositoryCommitAuthorization?
    ) async throws -> NovelLoadedProject {
        if shouldBlockNextCommit {
            shouldBlockNextCommit = false
            await withCheckedContinuation { continuation in
                blockedCommitContinuation = continuation
            }
        }
        if failingCommitProjectIDs.contains(document.project.id) {
            throw NovelError.repositoryFailure("Injected project commit failure.")
        }
        if remainingCommitFailures > 0 {
            remainingCommitFailures -= 1
            throw NovelError.repositoryFailure("Injected commit failure.")
        }
        let loaded = try await base.commitProject(
            document,
            expectedRevision: expectedRevision,
            authorization: authorization
        )
        commits.append(loaded.document)
        return loaded
    }

    func restorePreviousProject(
        id: NovelProjectID,
        expectedDocumentSHA256: String
    ) async throws -> NovelLoadedProject {
        try await base.restorePreviousProject(
            id: id,
            expectedDocumentSHA256: expectedDocumentSHA256
        )
    }

    func listRecoverySidecars() async throws -> [NovelRecoverySidecarV1] {
        try await base.listRecoverySidecars()
    }

    func writeRecoverySidecar(_ sidecar: NovelRecoverySidecarV1) async throws {
        if remainingSidecarWriteFailures > 0 {
            remainingSidecarWriteFailures -= 1
            throw NovelError.repositoryFailure("Injected sidecar write failure.")
        }
        try await base.writeRecoverySidecar(sidecar)
        writtenSidecars.append(sidecar)
    }

    func removeRecoverySidecar(projectID: NovelProjectID, runID: NovelRunID) async throws {
        if remainingSidecarRemovalFailures > 0 {
            remainingSidecarRemovalFailures -= 1
            throw NovelError.repositoryFailure("Injected sidecar removal failure.")
        }
        try await base.removeRecoverySidecar(projectID: projectID, runID: runID)
        removedSidecarRunIDs.append(runID)
    }
}

actor NovelSnapshotCompletionProbe {
    private var started = false
    private var completed = false

    var isStarted: Bool { started }
    var isCompleted: Bool { completed }

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }
}

actor BlockingCancelNovelModelAdapter: NovelModelRunning {
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private var didStartCancel = false

    func resolveModel(for policy: NovelProjectModelPolicy) async throws -> NovelResolvedModel {
        _ = policy
        return NovelResolvedModel(
            providerID: "provider-id",
            ownerProviderID: "provider-id",
            modelID: "model-uuid",
            wireModelID: "novel-model-v1",
            displayName: "Novel Model",
            contextWindowTokens: 128_000
        )
    }

    func start(_ request: NovelModelRequest) async throws -> AsyncStream<NovelModelEvent> {
        _ = request
        return AsyncStream { _ in }
    }

    func cancel(runID: NovelRunID) async {
        _ = runID
        didStartCancel = true
        await withCheckedContinuation { continuation in
            cancelContinuation = continuation
        }
    }

    func cancelDidStart() -> Bool { didStartCancel }

    func releaseCancel() {
        let continuation = cancelContinuation
        cancelContinuation = nil
        continuation?.resume()
    }
}

actor CancellableStartNovelModelAdapter: NovelModelRunning {
    private var didBegin = false
    private var cancellations: [NovelRunID] = []

    func resolveModel(for policy: NovelProjectModelPolicy) async throws -> NovelResolvedModel {
        _ = policy
        return NovelResolvedModel(
            providerID: "provider-id",
            ownerProviderID: "provider-id",
            modelID: "model-uuid",
            wireModelID: "novel-model-v1",
            displayName: "Novel Model",
            contextWindowTokens: 128_000
        )
    }

    func start(_ request: NovelModelRequest) async throws -> AsyncStream<NovelModelEvent> {
        _ = request
        didBegin = true
        try await Task.sleep(for: .seconds(30))
        return AsyncStream { _ in }
    }

    func cancel(runID: NovelRunID) async {
        cancellations.append(runID)
    }

    func startDidBegin() -> Bool { didBegin }
    func cancelledRunIDs() -> [NovelRunID] { cancellations }
}

actor BlockingStartNovelModelAdapter: NovelModelRunning {
    private var didBegin = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    func resolveModel(for policy: NovelProjectModelPolicy) async throws -> NovelResolvedModel {
        _ = policy
        return NovelResolvedModel(
            providerID: "provider-id",
            ownerProviderID: "provider-id",
            modelID: "model-uuid",
            wireModelID: "novel-model-v1",
            displayName: "Novel Model",
            contextWindowTokens: 128_000
        )
    }

    func start(_ request: NovelModelRequest) async throws -> AsyncStream<NovelModelEvent> {
        _ = request
        didBegin = true
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        return AsyncStream { _ in }
    }

    func cancel(runID: NovelRunID) async {
        _ = runID
    }

    func startDidBegin() -> Bool { didBegin }

    func releaseStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }
}

actor DurableNovelModelAdapter: NovelDurableModelRunning {
    private let model = NovelResolvedModel(
        providerID: "provider-id",
        ownerProviderID: "provider-id",
        modelID: "model-uuid",
        wireModelID: "novel-model-v1",
        displayName: "Novel Model",
        contextWindowTokens: 128_000
    )
    private var initialContinuations: [
        NovelRunID: AsyncStream<NovelModelEvent>.Continuation
    ] = [:]
    private var resumedContinuations: [
        NovelRunID: AsyncStream<NovelModelEvent>.Continuation
    ] = [:]
    private var shouldBlockNextDetach = false
    private var keepInitialStreamOpenDuringNextDetach = false
    private var blockedDetachContinuation: CheckedContinuation<Void, Never>?
    private var pullControlledInitialRunID: NovelRunID?
    private var usePullControlledNextInitialStream = false
    private var initialPullEvents: [NovelModelEvent] = []
    private var initialPullWaiter: CheckedContinuation<NovelModelEvent?, Never>?
    private var initialPullCallCount = 0
    private var initialPullFinished = false

    private(set) var startRequests: [NovelModelRequest] = []
    private(set) var resumeRequests: [NovelModelResumeRequest] = []
    private(set) var detachedRunIDs: [NovelRunID] = []
    private(set) var cancelledRunIDs: [NovelRunID] = []

    func resolveModel(for policy: NovelProjectModelPolicy) async throws -> NovelResolvedModel {
        _ = policy
        return model
    }

    func start(_ request: NovelModelRequest) async throws -> AsyncStream<NovelModelEvent> {
        startRequests.append(request)
        if usePullControlledNextInitialStream {
            usePullControlledNextInitialStream = false
            pullControlledInitialRunID = request.runID
            initialPullEvents = []
            initialPullWaiter = nil
            initialPullCallCount = 0
            initialPullFinished = false
            return AsyncStream(
                unfolding: { await self.nextInitialEvent(runID: request.runID) },
                onCancel: { Task { await self.cancel(runID: request.runID) } }
            )
        }
        let pair = AsyncStream<NovelModelEvent>.makeStream(bufferingPolicy: .unbounded)
        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel(runID: request.runID) }
        }
        initialContinuations[request.runID] = pair.continuation
        return pair.stream
    }

    func resume(_ request: NovelModelResumeRequest) async throws -> AsyncStream<NovelModelEvent> {
        resumeRequests.append(request)
        let pair = AsyncStream<NovelModelEvent>.makeStream(bufferingPolicy: .unbounded)
        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel(runID: request.runID) }
        }
        resumedContinuations[request.runID] = pair.continuation
        return pair.stream
    }

    func cancel(runID: NovelRunID) async {
        cancelledRunIDs.append(runID)
        if pullControlledInitialRunID == runID {
            finishInitialStream(runID: runID)
        }
        initialContinuations.removeValue(forKey: runID)?.finish()
        resumedContinuations.removeValue(forKey: runID)?.finish()
    }

    func detach(runID: NovelRunID) async {
        detachedRunIDs.append(runID)
        let keepInitialStreamOpen = keepInitialStreamOpenDuringNextDetach
        keepInitialStreamOpenDuringNextDetach = false
        if !keepInitialStreamOpen {
            finishInitialStream(runID: runID)
        }
        resumedContinuations.removeValue(forKey: runID)?.finish()
        if shouldBlockNextDetach {
            shouldBlockNextDetach = false
            await withCheckedContinuation { continuation in
                blockedDetachContinuation = continuation
            }
        }
        if keepInitialStreamOpen {
            finishInitialStream(runID: runID)
        }
    }

    func usePullBarrierForNextInitialStream() {
        usePullControlledNextInitialStream = true
    }

    func secondInitialPullIsWaiting(runID: NovelRunID) -> Bool {
        pullControlledInitialRunID == runID && initialPullCallCount >= 2 && initialPullWaiter != nil
    }

    private func nextInitialEvent(runID: NovelRunID) async -> NovelModelEvent? {
        guard pullControlledInitialRunID == runID else { return nil }
        initialPullCallCount += 1
        if !initialPullEvents.isEmpty { return initialPullEvents.removeFirst() }
        if initialPullFinished { return nil }
        return await withCheckedContinuation { continuation in
            initialPullWaiter = continuation
        }
    }

    func blockNextDetach() {
        shouldBlockNextDetach = true
    }

    func blockNextDetachBeforeFinishingInitialStream() {
        shouldBlockNextDetach = true
        keepInitialStreamOpenDuringNextDetach = true
    }

    func detachIsBlocked() -> Bool {
        blockedDetachContinuation != nil
    }

    func resumeBlockedDetach() {
        let continuation = blockedDetachContinuation
        blockedDetachContinuation = nil
        continuation?.resume()
    }

    func yieldInitial(
        _ event: NovelModelEvent,
        runID: NovelRunID,
        finish: Bool = false
    ) {
        if pullControlledInitialRunID == runID {
            if let waiter = initialPullWaiter {
                initialPullWaiter = nil
                waiter.resume(returning: event)
            } else {
                initialPullEvents.append(event)
            }
            if finish { finishInitialStream(runID: runID) }
            return
        }
        initialContinuations[runID]?.yield(event)
        if finish {
            initialContinuations.removeValue(forKey: runID)?.finish()
        }
    }

    func finishInitialStream(runID: NovelRunID) {
        if pullControlledInitialRunID == runID {
            initialPullFinished = true
            let waiter = initialPullWaiter
            initialPullWaiter = nil
            waiter?.resume(returning: nil)
            return
        }
        initialContinuations.removeValue(forKey: runID)?.finish()
    }

    func yieldResumed(
        _ event: NovelModelEvent,
        runID: NovelRunID,
        finish: Bool = false
    ) {
        resumedContinuations[runID]?.yield(event)
        if finish {
            resumedContinuations.removeValue(forKey: runID)?.finish()
        }
    }
}
