import Foundation
import UIKit
@preconcurrency import Shared

struct NovelGenerationPolicy: Equatable, Sendable {
    let sidecarByteThreshold: Int
    let sidecarInterval: TimeInterval
    let chapterTailCharacterLimit: Int
    let maximumRecentSessionMessages: Int

    static let standard = NovelGenerationPolicy(
        sidecarByteThreshold: 8 * 1_024,
        sidecarInterval: 2,
        chapterTailCharacterLimit: 6_000,
        maximumRecentSessionMessages: 12
    )
}

actor UnavailableNovelModelAdapter: NovelModelRunning {
    func resolveModel(for policy: NovelProjectModelPolicy) async throws -> NovelResolvedModel {
        _ = policy
        throw NovelError.generationUnavailable
    }

    func start(_ request: NovelModelRequest) async throws -> AsyncStream<NovelModelEvent> {
        _ = request
        throw NovelError.generationUnavailable
    }

    func cancel(runID: NovelRunID) async {
        _ = runID
    }
}

enum NovelRunTerminalIntent: Equatable, Sendable {
    case completed
    case awaitingUser(NovelAskUserPrompt, preface: String)
    case interrupted(reason: NovelRunInterruptionReason, command: NovelCancelRunCommand?)
    case failed(NovelFailure)
}

enum NovelTerminalPersistenceState: Equatable, Sendable {
    case pending
    case persisting
    case blocked(NovelFailure)
}

struct NovelRunTerminalClaim: Equatable, Sendable {
    let intent: NovelRunTerminalIntent
    let partialContent: String
    let claimedAt: Date
    var persistenceState: NovelTerminalPersistenceState
}

struct NovelTerminalCommit: Sendable {
    let outcome: NovelOutcome?
    let event: NovelRunEvent
}

private final class NovelBackgroundDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignalled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        guard !isSignalled else {
            lock.unlock()
            return
        }
        isSignalled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

struct NovelRunRuntime: Sendable {
    let projectID: NovelProjectID
    let branchID: NovelBranchID
    let kind: NovelRunKind
    let startProjectRevision: Int64
    var partialContent: String
    var usage: NovelModelUsage?
    var subscribers: [UUID: AsyncStream<NovelRunEvent>.Continuation]
    var modelTask: Task<Void, Never>?
    // The currently authorized local stream; detach revokes it before the adapter closes it.
    var modelStreamID: UUID?
    var sidecarSequence: Int64
    var lastSidecarAt: Date
    var lastSidecarByteCount: Int
    let resumeModel: NovelResolvedModel
    let resumePurpose: NovelModelPurpose
    var responseCursor: NovelResponsesResumeCursor?
    var isDetachedForBackground: Bool
    var didAutoReconnectAfterDisconnect: Bool
    var terminalClaim: NovelRunTerminalClaim?
    /// Text and reasoning characters received, reported as background-task progress.
    var streamedCharacters: Int64 = 0
    var reportedStreamedCharacters: Int64 = 0
    var lastStreamProgressAt: Date = .distantPast
}

extension DefaultNovelCreation {
    func resumeDetachedGenerationRuns() async {
        // A fresh process has no in-memory runtimes. Reuse the existing global
        // recovery barrier so persisted response cursors are reconstructed
        // before the detached-runtime scan below.
        try? await recoverGenerationStateIfNeeded()
        await resumeAllDetachedGenerationRuns()
    }

    func startGeneration(_ request: NovelRunRequest) async throws -> NovelRun {
        if let interruption = preStartInterruptions[request.id] {
            guard interruption.projectID == request.projectID else {
                throw NovelError.runNotFound(request.id)
            }
            preStartInterruptions[request.id] = nil
            throw CancellationError()
        }
        let payloadSHA256 = try request.canonicalPayloadSHA256()
        if let runtime = generationRuntimes[request.id],
           runtime.projectID != request.projectID {
            throw NovelError.invalidInput(
                "A live generation run ID belongs to another project."
            )
        }
        if let reservation = generationStartReservations[request.id] {
            guard reservation.projectID == request.projectID,
                  reservation.operationID == request.operationID,
                  reservation.payloadSHA256 == payloadSHA256 else {
                throw NovelError.idempotencyConflict(request.operationID)
            }
            _ = try await reservation.task.value
            return try await observeStartedRun(request)
        }
        if generationStartRunIDsByProject[request.projectID] != nil {
            throw NovelError.projectBusy(request.projectID)
        }
        if let pending = pendingLifecycleOperationsByProject[request.projectID],
           !pending.isEmpty {
            if pending.contains(request.operationID) {
                throw NovelError.idempotencyConflict(request.operationID)
            }
            throw NovelError.projectBusy(request.projectID)
        }
        guard !isRecoveringGenerationState,
              !mutationIsInFlight(projectID: request.projectID),
              !generationWriteProjectIDs.contains(request.projectID),
              !lifecycleReadProjectIDs.contains(request.projectID) else {
            throw NovelError.projectBusy(request.projectID)
        }

        generationStartProjectIDs.insert(request.projectID)
        generationStartRunIDsByProject[request.projectID] = request.id
        let task = Task { [self] in
            try await startGenerationCore(request)
        }
        generationStartReservations[request.id] = NovelGenerationStartReservation(
            projectID: request.projectID,
            operationID: request.operationID,
            payloadSHA256: payloadSHA256,
            task: task
        )

        do {
            let run = try await task.value
            clearGenerationStartReservation(request)
            return run
        } catch {
            clearGenerationStartReservation(request)
            throw error
        }
    }

    private func startGenerationCore(_ request: NovelRunRequest) async throws -> NovelRun {
        if try await repository.lifecycleOperation(
            projectID: request.projectID,
            operationID: request.operationID
        ) != nil {
            throw NovelError.idempotencyConflict(request.operationID)
        }

        let loaded = try await loadCommittedProject(id: request.projectID)
        if let replay = try await replayOrObserve(request, document: loaded.document) {
            return replay
        }
        guard loaded.access == .readWrite else {
            throw NovelError.degradedReadOnly(projectID: request.projectID)
        }

        let model = try await resolveModel(for: modelPolicy(for: .creation, in: loaded.document))
        let parameters = modelParameters(for: request)
        let effectiveInputBudget = try effectiveInputBudget(
            request,
            model: model,
            parameters: parameters
        )

        let promptKind = promptKind(for: request)
        let planningRequest = NovelInjectionPlanningRequest(
            branchID: request.branchID,
            promptKind: promptKind,
            userText: request.userText,
            sourceChapterVersionID: request.sourceChapterVersionID,
            sessionCursorLimit: request.suppressRecentSessionMessages ? .empty : nil,
            overrides: request.injectionOverrides,
            budget: NovelInjectionBudget(
                maxEstimatedInputTokens: effectiveInputBudget,
                chapterTailCharacterLimit: generationPolicy.chapterTailCharacterLimit,
                maximumRecentSessionMessages: request.suppressRecentSessionMessages
                    ? 0
                    : generationPolicy.maximumRecentSessionMessages
            )
        )
        let plan: NovelInjectionPlan
        do {
            plan = try NovelInjectionPlanner.plan(
                document: loaded.document,
                request: planningRequest
            )
        } catch {
            throw mapInjectionError(error)
        }

        let modelRequest = NovelModelRequest(
            runID: request.id,
            model: model,
            purpose: modelPurpose(for: request),
            messages: modelMessages(plan: plan, userText: request.userText),
            parameters: parameters,
            projectID: request.projectID,
            branchID: request.branchID
        )
        let parameterEvidence = parameters.evidenceDictionary
        let startedAt = now()
        let injectionReceipt = NovelInjectionReceiptRecord(
            id: request.injectionReceiptID,
            runID: request.id,
            projectID: request.projectID,
            branchID: request.branchID,
            plan: plan,
            overrides: request.injectionOverrides,
            providerID: model.providerID,
            ownerProviderID: model.ownerProviderID,
            modelID: model.modelID,
            wireModelID: model.wireModelID,
            parameters: parameterEvidence,
            requestedInputBudgetTokens: request.inputBudgetTokens,
            createdAt: startedAt
        )
        let generationReceipt = NovelGenerationReceiptRecord(
            id: request.generationReceiptID,
            runID: request.id,
            providerID: model.providerID,
            ownerProviderID: model.ownerProviderID,
            modelID: model.modelID,
            wireModelID: model.wireModelID,
            promptVersion: plan.prompt.version,
            injectionReceiptID: request.injectionReceiptID,
            parameters: injectionReceipt.parameters,
            requestSHA256: try modelRequest.canonicalSHA256(),
            createdAt: startedAt
        )
        try Task.checkCancellation()
        let reduced = try NovelGenerationReducer.begin(
            request,
            artifacts: NovelGenerationStartArtifacts(
                injectionReceipt: injectionReceipt,
                generationReceipt: generationReceipt
            ),
            in: loaded.document,
            now: startedAt
        )
        try Task.checkCancellation()

        let committed: NovelLoadedProject
        do {
            let transition = try NovelDocumentValidator.validateTransitionFromValidatedCurrent(
                from: loaded.document,
                to: reduced.document
            )
            committed = try await repository.commitProject(
                transition,
                authorization: nil
            )
        } catch {
            if requiresRepositoryReconciliation(error) {
                frozenProjectIDs.insert(request.projectID)
                if let reconciled = try? await loadCommittedProject(id: request.projectID),
                   reconciled.document.activeRuns.contains(where: {
                       $0.id == request.id && $0.operationID == request.operationID
                   }) {
                    return try await resumeDurablyStartedRun(
                        request,
                        modelRequest: modelRequest,
                        loaded: reconciled
                    )
                }
            }
            throw error
        }
        guard committed.document == reduced.document ||
                committed.document == NovelWorkspaceProjectStore.persistableAtRest(reduced.document) else {
            frozenProjectIDs.insert(request.projectID)
            throw NovelError.storageIndeterminate(request.projectID)
        }
        _ = try installLoadedProject(
            committed,
            id: request.projectID,
            allowsRollback: false
        )
        try Task.checkCancellation()
        return try await resumeDurablyStartedRun(
            request,
            modelRequest: modelRequest,
            loaded: committed
        )
    }

    private func clearGenerationStartReservation(_ request: NovelRunRequest) {
        clearGenerationStartReservation(
            runID: request.id,
            projectID: request.projectID,
            operationID: request.operationID
        )
    }

    private func clearGenerationStartReservation(
        runID: NovelRunID,
        projectID: NovelProjectID,
        operationID: NovelOperationID
    ) {
        guard let reservation = generationStartReservations[runID],
              reservation.projectID == projectID,
              reservation.operationID == operationID else {
            return
        }
        generationStartReservations[runID] = nil
        if generationStartRunIDsByProject[projectID] == runID {
            generationStartRunIDsByProject[projectID] = nil
            generationStartProjectIDs.remove(projectID)
        }
    }

    func interruptRun(_ command: NovelCancelRunCommand) async throws {
        let reservation = generationStartReservations[command.runID]
        if generationRuntimes[command.runID] != nil {
            // Once the durable runtime exists, terminal ownership must be claimed
            // before cancelling the still-returning start task. Otherwise a
            // CancellationError from modelRunner.start can win as a failed run,
            // or an uncooperative start can keep route exit waiting forever.
            _ = try await executeCancelRun(command)
            reservation?.task.cancel()
            if let reservation {
                clearGenerationStartReservation(
                    runID: command.runID,
                    projectID: reservation.projectID,
                    operationID: reservation.operationID
                )
            }
            return
        }

        if let reservation {
            guard reservation.projectID == command.projectID else {
                throw NovelError.runNotFound(command.runID)
            }
            reservation.task.cancel()
            _ = try? await reservation.task.value
            clearGenerationStartReservation(
                runID: command.runID,
                projectID: reservation.projectID,
                operationID: reservation.operationID
            )
        }

        if generationRuntimes[command.runID] != nil {
            _ = try await executeCancelRun(command)
            return
        }

        if reservation == nil {
            try registerPreStartInterruption(command)
        }
        let loaded: NovelLoadedProject
        do {
            loaded = try await loadCommittedProject(id: command.projectID)
        } catch {
            if let novelError = error as? NovelError,
               case .projectNotFound = novelError {
                clearPreStartInterruption(command)
            }
            throw error
        }
        if let run = loaded.document.activeRuns.first(where: { $0.id == command.runID }) {
            if run.status == .running {
                _ = try await executeCancelRun(command)
            }
            clearPreStartInterruption(command)
            return
        }

        // With no reservation or durable run, the tombstone remains for a
        // start call that has not entered this actor yet.
    }

    private func registerPreStartInterruption(
        _ command: NovelCancelRunCommand
    ) throws {
        if let existing = preStartInterruptions[command.runID] {
            guard existing.projectID == command.projectID else {
                throw NovelError.runNotFound(command.runID)
            }
            return
        }
        preStartInterruptions[command.runID] = command
    }

    private func clearPreStartInterruption(_ command: NovelCancelRunCommand) {
        guard preStartInterruptions[command.runID] == command else { return }
        preStartInterruptions[command.runID] = nil
    }

    private func observeStartedRun(_ request: NovelRunRequest) async throws -> NovelRun {
        let loaded = try await loadCommittedProject(id: request.projectID)
        guard let replay = try await replayOrObserve(request, document: loaded.document) else {
            throw NovelError.storageIndeterminate(request.projectID)
        }
        return replay
    }

    func executeCancelRun(_ command: NovelCancelRunCommand) async throws -> NovelOutcome {
        if let runtime = generationRuntimes[command.runID] {
            guard runtime.projectID == command.projectID else {
                throw NovelError.runNotFound(command.runID)
            }
            let intent = NovelRunTerminalIntent.interrupted(
                reason: command.reason,
                command: command
            )
            let isNewClaim = generationRuntimes[command.runID]?.terminalClaim == nil
            guard claimTerminal(runID: command.runID, intent: intent) else {
                throw NovelError.projectBusy(command.projectID)
            }
            if isNewClaim {
                cancelProviderWithoutWaiting(runID: command.runID)
            }
            let committed = try await persistTerminalClaim(command.runID)
            guard let outcome = committed?.outcome else {
                throw NovelError.runNotFound(command.runID)
            }
            return outcome
        }

        let result: (
            outcome: NovelOutcome?,
            message: NovelSessionMessageSnapshot?
        ) = try await commitGenerationMutation(
            projectID: command.projectID,
            waitForMutations: false
        ) { document in
            let reduced = try NovelGenerationReducer.interrupt(
                command,
                partialContent: "",
                in: document,
                now: self.now()
            )
            return (reduced.document, (reduced.outcome, reduced.message))
        }

        guard let outcome = result.outcome else {
            throw NovelError.runNotFound(command.runID)
        }
        try? await repository.removeRecoverySidecar(
            projectID: command.projectID,
            runID: command.runID
        )
        finishRuntime(
            runID: command.runID,
            event: .interrupted(result.message)
        )
        return outcome
    }

    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async {
        let startedAt = now()
        let reason: NovelRunInterruptionReason = startedAt >= deadline
            ? .expiration
            : .background
        if let runID,
           generationStartReservations[runID] == nil,
           generationRuntimes[runID] == nil {
            let command = NovelCancelRunCommand(
                context: NovelMutationContext(
                    operationID: NovelOperationID(),
                    expectedProjectRevision: nil,
                    expectedConfigRevision: nil,
                    expectedBranchHeadRevision: nil
                ),
                projectID: projectID,
                runID: runID,
                reason: reason
            )
            // An expiration callback can arrive after the run already reached
            // a durable terminal state. Consult storage before creating a
            // tombstone, otherwise a later replay of this run would be
            // cancelled before it can observe its terminal record.
            var durableRun: NovelActiveRunRecord?
            var didLoadDurableState = false
            if let loaded = try? await repository.loadProject(id: projectID) {
                durableRun = loaded.document.activeRuns.first { $0.id == runID }
                didLoadDurableState = true
            }
            if didLoadDurableState {
                switch durableRun?.status {
                case .some(.running):
                    _ = try? await interruptRun(command)
                case .some(.completed), .some(.failed), .some(.interrupted):
                    break
                case nil:
                    try? registerPreStartInterruption(command)
                }
            }
        }
        // A lease callback with an explicit run ID belongs to that run only;
        // the project-wide scan is reserved for the legacy runID == nil path.
        let preDurableCommands = generationStartReservations.compactMap {
            candidateRunID, reservation -> NovelCancelRunCommand? in
            guard (runID == nil || candidateRunID == runID),
                  reservation.projectID == projectID,
                  generationRuntimes[candidateRunID] == nil else { return nil }
            return NovelCancelRunCommand(
                context: NovelMutationContext(
                    operationID: NovelOperationID(),
                    expectedProjectRevision: nil,
                    expectedConfigRevision: nil,
                    expectedBranchHeadRevision: nil
                ),
                projectID: projectID,
                runID: candidateRunID,
                reason: reason
            )
        }
        // Publish cancellation before the first suspension in this method so a
        // commit that resumes concurrently cannot continue into provider start.
        for command in preDurableCommands {
            generationStartReservations[command.runID]?.task.cancel()
        }
        let startTasks = preDurableCommands.map { command in
            Task { [weak self] in
                try await self?.interruptRun(command)
            }
        }
        var claimedRunIDs: [NovelRunID] = []
        let mutationTasks: [Task<NovelOutcome, Error>]
        if runID == nil {
            mutationTasks = cancelInFlightBackgroundMutationTasks(
                projectID: projectID,
                includePolishAdoption: true
            )
        } else {
            mutationTasks = []
        }
        for candidateRunID in generationRuntimes.keys.sorted(by: {
            $0.description < $1.description
        }) {
            guard (runID == nil || candidateRunID == runID),
                  let runtime = generationRuntimes[candidateRunID],
                  runtime.projectID == projectID else {
                continue
            }
            if await detachResumableRunForBackground(candidateRunID) {
                continue
            }
            if let claim = runtime.terminalClaim {
                if case .interrupted(let existingReason, _) = claim.intent,
                   existingReason == .background || existingReason == .expiration,
                   claim.persistenceState != .persisting {
                    claimedRunIDs.append(candidateRunID)
                }
                continue
            }
            guard claimTerminal(
                runID: candidateRunID,
                intent: .interrupted(reason: reason, command: nil)
            ) else {
                continue
            }
            claimedRunIDs.append(candidateRunID)
            cancelProviderWithoutWaiting(runID: candidateRunID)
            if let reservation = generationStartReservations[candidateRunID] {
                reservation.task.cancel()
                clearGenerationStartReservation(
                    runID: candidateRunID,
                    projectID: reservation.projectID,
                    operationID: reservation.operationID
                )
            }
        }

        guard !claimedRunIDs.isEmpty || !mutationTasks.isEmpty || !startTasks.isEmpty else {
            return
        }
        let gate = NovelBackgroundDeadlineGate()
        Task { [weak self] in
            for task in startTasks {
                _ = try? await task.value
            }
            for runID in claimedRunIDs {
                _ = try? await self?.persistTerminalClaim(runID)
            }
            for task in mutationTasks {
                _ = try? await task.value
            }
            gate.signal()
        }

        let waitSeconds = min(5, max(0, deadline.timeIntervalSince(startedAt)))
        guard waitSeconds > 0 else { return }
        let nanoseconds = UInt64(waitSeconds * 1_000_000_000)
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            if !Task.isCancelled {
                gate.signal()
            }
        }
        await gate.wait()
        timeoutTask.cancel()
    }

    func retryPendingTerminal(runID: NovelRunID) async throws {
        guard let runtime = generationRuntimes[runID] else {
            throw NovelError.runNotFound(runID)
        }
        guard let claim = runtime.terminalClaim else {
            throw NovelError.invalidInput("The run has no pending terminal state.")
        }
        guard claim.persistenceState != .persisting else {
            throw NovelError.projectBusy(runtime.projectID)
        }
        guard try await persistTerminalClaim(runID) != nil else {
            throw NovelError.projectBusy(runtime.projectID)
        }
    }

    func recoverGenerationStateIfNeeded(
        requiredProjectID: NovelProjectID? = nil,
        allowsMissingRequiredProject: Bool = false,
        allowsConcurrentMutationOnRequiredProject: Bool = false
    ) async throws {
        if didRecoverGenerationState { return }
        if isRecoveringGenerationState {
            if allowsConcurrentMutationOnRequiredProject,
               recoveringGenerationProjectID == requiredProjectID {
                return
            }
            while isRecoveringGenerationState {
                await withCheckedContinuation { continuation in
                    generationRecoveryWaiters.append(continuation)
                }
            }
            return try await recoverGenerationStateIfNeeded(
                requiredProjectID: requiredProjectID,
                allowsMissingRequiredProject: allowsMissingRequiredProject,
                allowsConcurrentMutationOnRequiredProject: allowsConcurrentMutationOnRequiredProject
            )
        }
        if let requiredProjectID,
           recoveredGenerationProjectIDs.contains(requiredProjectID) {
            return
        }
        // Recovery may be waiting on storage while another user action arrives.
        // Lifecycle-ledger reconciliation is the global write barrier. Once it
        // finishes, durable run markers and revision checks protect project-local
        // mutations while the remaining recovery scan continues.
        isRecoveringGenerationState = true
        recoveringGenerationProjectID = requiredProjectID
        defer {
            recoveringGenerationProjectID = nil
            isRecoveringGenerationState = false
            let waiters = generationRecoveryWaiters
            generationRecoveryWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        isReconcilingLifecycleOperations = true
        do {
            try await reconcilePendingLifecycleOperations()
            isReconcilingLifecycleOperations = false
        } catch {
            isReconcilingLifecycleOperations = false
            throw error
        }
        let sidecars = try await repository.listRecoverySidecars()
        let summaries: [NovelProjectSummary]
        let scopedLoadedProject: NovelLoadedProject?
        if let requiredProjectID {
            do {
                // Install into the in-memory cache so the caller's subsequent
                // loadCommittedProject does not re-decode the same large document.
                let loaded = try installLoadedProject(
                    try await repository.loadProject(id: requiredProjectID),
                    id: requiredProjectID,
                    allowsRollback: frozenProjectIDs.contains(requiredProjectID)
                )
                scopedLoadedProject = loaded
                summaries = [NovelProjectSummary(
                    document: loaded.document,
                    isDegraded: loaded.access != .readWrite
                )]
            } catch NovelError.projectNotFound where allowsMissingRequiredProject {
                recoveredGenerationProjectIDs.insert(requiredProjectID)
                return
            }
        } else {
            scopedLoadedProject = nil
            summaries = try await repository.listProjects()
        }
        var hasDeferredRunningRecovery = false
        for summary in summaries where summary.loadError == nil {
            let loaded: NovelLoadedProject
            if let scopedLoadedProject {
                loaded = scopedLoadedProject
            } else {
                do {
                    loaded = try await repository.loadProject(id: summary.id)
                } catch NovelError.projectNotFound {
                    // The project may be deleted after the summary snapshot.
                    continue
                }
            }
            let hasLifecycleWriteBarrier = blockedLifecycleProjectIDs.contains(summary.id) ||
                !(pendingLifecycleOperationsByProject[summary.id]?.isEmpty ?? true)
            if hasLifecycleWriteBarrier {
                if loaded.document.activeRuns.contains(where: { $0.status == .running }) ||
                    sidecars.contains(where: { $0.projectID == summary.id }) {
                    hasDeferredRunningRecovery = true
                }
                continue
            }
            for run in loaded.document.activeRuns {
                if run.status == .running {
                    // A live runtime is already the authoritative owner in this
                    // process. Global cold-start recovery must not reinterpret
                    // its durable marker as an orphan before the detached scan.
                    if generationRuntimes[run.id] != nil {
                        continue
                    }
                    guard loaded.access == .readWrite else {
                        // A degraded snapshot is not authoritative for writes.
                        // Keep its recovery sidecar until a writable primary is
                        // available or a durable terminal is observed.
                        hasDeferredRunningRecovery = true
                        continue
                    }
                    let matchingRunSidecars = sidecars.filter {
                        $0.projectID == summary.id && $0.runID == run.id
                    }
                    let startRevision = loaded.document.appliedOperations.first {
                        $0.operationID == run.operationID && $0.kind == .startRun
                    }?.appliedProjectRevision
                    let sidecar = matchingRunSidecars
                        .filter {
                            $0.branchID == run.branchID &&
                                $0.sessionID == run.sessionID &&
                                $0.messageID == run.messageID &&
                                $0.baseProjectRevision == startRevision
                        }
                        .max { $0.sequence < $1.sequence }
                    if let sidecar,
                       await resumeRecoveredRunIfPossible(
                           run,
                           sidecar: sidecar,
                           document: loaded.document
                       ) {
                        continue
                    }
                    // An identity mismatch never contributes text to a run. The
                    // durable marker is the only safe fallback.
                    let partial = sidecar?.partialContent ?? run.partialContent
                    do {
                        let _: NovelSessionMessageSnapshot? = try await commitGenerationMutation(
                            projectID: summary.id,
                            waitForMutations: true
                        ) { document in
                            let reduced = try NovelGenerationReducer.interrupt(
                                runID: run.id,
                                reason: .recovery,
                                partialContent: partial,
                                in: document,
                                now: self.now()
                            )
                            return (reduced.document, reduced.message)
                        }
                        try? await repository.removeRecoverySidecar(
                            projectID: summary.id,
                            runID: run.id
                        )
                        _ = try? await durableRunStore?.transitionFromAnyActive(
                            runId: run.id.description,
                            to: .interrupted,
                            detail: NovelRunInterruptionReason.recovery.rawValue
                        )
                    } catch {
                        frozenProjectIDs.insert(summary.id)
                        throw error
                    }
                } else {
                    await settleDurableNovelRecord(run)
                    if sidecars.contains(where: {
                        $0.projectID == summary.id && $0.runID == run.id
                    }) {
                        try? await repository.removeRecoverySidecar(
                            projectID: summary.id,
                            runID: run.id
                        )
                    }
                }
            }
        }
        if requiredProjectID == nil {
            didRecoverGenerationState = !hasDeferredRunningRecovery
        } else if !hasDeferredRunningRecovery, let requiredProjectID {
            recoveredGenerationProjectIDs.insert(requiredProjectID)
        }
    }
}

extension DefaultNovelCreation {
    func makeInjectionPreview(
        _ request: NovelInjectionPreviewRequest
    ) async throws -> NovelInjectionPreviewSnapshot {
        let first = try await loadCommittedProject(id: request.projectID)
        guard first.access == .readWrite else {
            throw NovelError.degradedReadOnly(projectID: request.projectID)
        }
        guard let firstBranch = first.document.branches.first(where: {
            $0.id == request.branchID && $0.lifecycle == .active
        }) else {
            throw NovelError.branchNotFound(request.branchID)
        }
        guard firstBranch.activeRunID == nil else {
            throw NovelError.projectBusy(request.projectID)
        }

        let firstModelPolicy = modelPolicy(for: .creation, in: first.document)
        let model = try await resolveModel(for: firstModelPolicy)
        let current = try await loadCommittedProject(id: request.projectID)
        guard current.document.project.revision == first.document.project.revision,
              current.document.project.configRevision == first.document.project.configRevision,
              modelPolicy(for: .creation, in: current.document) == firstModelPolicy,
              let branch = current.document.branches.first(where: {
                  $0.id == request.branchID && $0.lifecycle == .active
              }),
              branch.headRevision == firstBranch.headRevision,
              branch.activeRunID == nil else {
            throw NovelError.projectBusy(request.projectID)
        }

        let candidateID: NovelCandidateID?
        switch request.kind {
        case .prose, .polish, .regenerate:
            candidateID = NovelCandidateID()
        case .quickStart, .characterProposal, .discussion:
            candidateID = nil
        }
        let synthetic = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: request.projectID,
            branchID: request.branchID,
            kind: request.kind,
            mode: request.mode,
            granularity: request.granularity,
            userText: request.userText,
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: candidateID,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: request.sourceChapterVersionID,
            injectionOverrides: request.injectionOverrides,
            inputBudgetTokens: request.inputBudgetTokens,
            expectedProjectRevision: current.document.project.revision,
            expectedConfigRevision: current.document.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
        let parameters = modelParameters(for: synthetic)
        let effectiveBudget = try effectiveInputBudget(
            synthetic,
            model: model,
            parameters: parameters
        )
        let planning = NovelInjectionPlanningRequest(
            branchID: request.branchID,
            promptKind: promptKind(for: synthetic),
            userText: request.userText,
            sourceChapterVersionID: request.sourceChapterVersionID,
            overrides: request.injectionOverrides,
            budget: NovelInjectionBudget(
                maxEstimatedInputTokens: effectiveBudget,
                chapterTailCharacterLimit: generationPolicy.chapterTailCharacterLimit,
                maximumRecentSessionMessages: generationPolicy.maximumRecentSessionMessages
            )
        )
        let plan: NovelInjectionPlan
        do {
            plan = try NovelInjectionPlanner.plan(document: current.document, request: planning)
        } catch {
            throw mapInjectionError(error)
        }
        return NovelInjectionPreviewSnapshot(
            projectID: request.projectID,
            branchID: request.branchID,
            projectRevision: current.document.project.revision,
            configRevision: current.document.project.configRevision,
            branchHeadRevision: branch.headRevision,
            resolvedModel: model,
            parameters: parameters,
            requestedInputBudgetTokens: request.inputBudgetTokens,
            effectiveInputBudgetTokens: effectiveBudget,
            plan: plan
        )
    }
}

extension DefaultNovelCreation {
    func mapInjectionError(_ error: Error) -> NovelError {
        guard let error = error as? NovelInjectionPlanningError else {
            return .invalidInput(error.localizedDescription)
        }
        return switch error {
        case .requiredContentExceedsBudget(let limit, let estimated, let items):
            NovelError.injectionBudgetExceeded(
                required: estimated,
                limit: limit,
                items: items
            )
        case .missingBranch(let id): NovelError.branchNotFound(id)
        case .missingSession(let id): NovelError.sessionNotFound(id)
        case .missingStateSnapshot(let id): NovelError.stateSnapshotNotFound(id)
        case .missingChapterVersion(let id):
            NovelError.invalidInput("Chapter version \(id) is unavailable.")
        case .missingMaterialRevision(let id):
            NovelError.invalidInput("Material revision \(id) is unavailable.")
        case .branchRequiresSync:
            NovelError.invalidInput("The branch must be synchronized before formal generation.")
        case .invalidInput(let message): NovelError.invalidInput(message)
        }
    }
}
