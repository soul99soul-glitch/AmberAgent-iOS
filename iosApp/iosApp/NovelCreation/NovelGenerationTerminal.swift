import Foundation
import UIKit
@preconcurrency import Shared

extension DefaultNovelCreation {
    func modelStreamEnded(
        runID: NovelRunID,
        streamID: UUID,
        hadTransportTerminal: Bool
    ) async {
        guard !hadTransportTerminal,
              generationRuntimes[runID]?.modelStreamID == streamID,
              generationRuntimes[runID]?.terminalClaim == nil,
              generationRuntimes[runID]?.isDetachedForBackground != true else {
            return
        }
        await failRun(
            runID,
            failure: NovelFailure(
                code: "stream_ended",
                message: "模型流式响应异常结束，未收到完整回复。",
                isRetryable: true
            )
        )
    }

    func completeRun(_ runID: NovelRunID) async {
        guard var runtime = generationRuntimes[runID] else { return }
        if (runtime.kind == .discussion || runtime.kind == .quickStart),
           let prompt = try? Self.decodeAskUserFallback(runtime.partialContent) {
            runtime.partialContent = ""
            generationRuntimes[runID] = runtime
            await awaitUser(runID, prompt: prompt, preface: "")
            return
        }
        guard !runtime.partialContent.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            await failRun(
                runID,
                failure: NovelFailure(
                    code: "empty_completion",
                    message: "The model completed without returning any text.",
                    isRetryable: true
                )
            )
            return
        }
        if runtime.kind == .quickStart {
            do {
                _ = try NovelStructuredOutputDecoder.decodeQuickStartSuggestions(
                    from: runtime.partialContent
                )
            } catch {
                await failRun(
                    runID,
                    failure: NovelFailure(
                        code: "invalid_quick_start_output",
                        message: "The quick-start suggestions were not valid structured output.",
                        isRetryable: true
                    )
                )
                return
            }
        }
        if runtime.kind == .characterProposal {
            do {
                _ = try NovelStructuredOutputDecoder.decodeCharacterProposal(
                    from: runtime.partialContent
                )
            } catch {
                await failRun(
                    runID,
                    failure: NovelFailure(
                        code: "invalid_character_proposal_output",
                        message: "人物建议不是有效的结构化结果。",
                        isRetryable: true
                    )
                )
                return
            }
        }
        if runtime.kind == .polish {
            // Sentinel is a hard completion contract; fence-stripping happens inside
            // completedPolishContent and again at claimTerminal for interrupt paths.
            guard let completed = NovelPromptCatalog.completedPolishContent(
                from: runtime.partialContent
            ) else {
                await failRun(
                    runID,
                    failure: NovelFailure(
                        code: "incomplete_polish_output",
                        message: "The whole-chapter polish did not return a verified complete chapter.",
                        isRetryable: true
                    )
                )
                return
            }
            runtime.partialContent = completed
            generationRuntimes[runID] = runtime
            broadcast(.replaced(completed), runID: runID)
        }
        // claimTerminal normalizes prose/regenerate/polish partials so complete,
        // interrupt, and fail all share one durable clean snapshot.
        guard claimTerminal(runID: runID, intent: .completed) else { return }
        _ = try? await persistTerminalClaim(runID)
    }

    func awaitUser(
        _ runID: NovelRunID,
        prompt: NovelAskUserPrompt,
        preface: String
    ) async {
        do {
            try NovelGenerationReducer.validateAskUserPrompt(prompt)
        } catch {
            await failRun(
                runID,
                failure: NovelFailure(
                    code: "invalid_ask_user_output",
                    message: "模型提出的问题格式无法读取，请重试。",
                    isRetryable: true
                )
            )
            return
        }
        guard claimTerminal(
            runID: runID,
            intent: .awaitingUser(
                prompt,
                preface: preface.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ) else { return }
        _ = try? await persistTerminalClaim(runID)
    }

    func failRun(_ runID: NovelRunID, failure: NovelFailure) async {
        guard claimTerminal(runID: runID, intent: .failed(failure)) else { return }
        _ = try? await persistTerminalClaim(runID)
    }

    func persistTerminalClaim(_ runID: NovelRunID) async throws -> NovelTerminalCommit? {
        guard var runtime = generationRuntimes[runID],
              var claim = runtime.terminalClaim,
              claim.persistenceState != .persisting else {
            return nil
        }
        claim.persistenceState = .persisting
        runtime.terminalClaim = claim
        generationRuntimes[runID] = runtime

        updateBackgroundLease(
            runID: runID,
            completed: 3,
            subtitle: IOSAppLocalization.string("保存结果", defaultValue: "保存结果")
        )

        _ = await flushRecoverySidecar(runID: runID, force: true)
        do {
            let waitForMutations: Bool
            if case .interrupted(_, let command) = claim.intent, command != nil {
                waitForMutations = false
            } else {
                waitForMutations = true
            }
            let committed: NovelTerminalCommit = try await commitGenerationMutation(
                projectID: runtime.projectID,
                waitForMutations: waitForMutations
            ) { document in
                try self.reduceTerminalClaim(
                    runID: runID,
                    claim: claim,
                    document: document
                )
            }
            try? await repository.removeRecoverySidecar(
                projectID: runtime.projectID,
                runID: runID
            )
            updateBackgroundLease(
                runID: runID,
                completed: 4,
                subtitle: IOSAppLocalization.string("已保存", defaultValue: "已保存")
            )
            await settleDurableNovelRun(
                runID: runID,
                intent: claim.intent
            )
            finishRuntime(runID: runID, event: committed.event)
            await endBackgroundLease(for: runID)
            return committed
        } catch {
            let persistenceFailure = failure(
                from: error,
                fallbackCode: "terminal_persist_failed"
            )
            if var current = generationRuntimes[runID],
               var currentClaim = current.terminalClaim,
               currentClaim.intent == claim.intent,
               currentClaim.claimedAt == claim.claimedAt {
                currentClaim.persistenceState = .blocked(persistenceFailure)
                current.terminalClaim = currentClaim
                generationRuntimes[runID] = current
                broadcast(.persistenceBlocked(persistenceFailure), runID: runID)
            }
            if let durableRunStore {
                _ = try? await durableRunStore.transition(
                    runId: runID.description,
                    expected: .running,
                    to: .recoveryPending,
                    inputSnapshotRef: novelDurableInputRef(
                        projectID: runtime.projectID,
                        branchID: runtime.branchID
                    ),
                    detail: persistenceFailure.message
                )
            }
            await endBackgroundLease(for: runID)
            throw error
        }
    }

    func ensureDurableNovelRun(
        _ run: NovelActiveRunRecord,
        projectID: NovelProjectID
    ) async -> Bool {
        guard let durableRunStore else { return true }
        do {
            return try await durableRunStore.ensureRunning(
                runId: run.id.description,
                descriptorId: IOSDurableRunStore.Descriptor.novelGeneration,
                startedAt: Int64(run.startedAt.timeIntervalSince1970 * 1_000),
                inputDigest: run.requestPayloadSHA256,
                inputSnapshotRef: novelDurableInputRef(
                    projectID: projectID,
                    branchID: run.branchID
                )
            )
        } catch {
            return false
        }
    }

    func settleDurableNovelRun(
        runID: NovelRunID,
        intent: NovelRunTerminalIntent
    ) async {
        let status: AgentRunStatus
        let detail: String?
        switch intent {
        case .completed, .awaitingUser:
            status = .completed
            detail = nil
        case .interrupted(let reason, _):
            status = .interrupted
            detail = reason.rawValue
        case .failed(let failure):
            status = .failed
            detail = failure.message
        }
        _ = try? await durableRunStore?.transitionFromAnyActive(
            runId: runID.description,
            to: status,
            detail: detail
        )
    }

    func settleDurableNovelRecord(_ run: NovelActiveRunRecord) async {
        let status: AgentRunStatus
        switch run.status {
        case .running:
            return
        case .completed:
            status = .completed
        case .interrupted:
            status = .interrupted
        case .failed:
            status = .failed
        }
        _ = try? await durableRunStore?.transitionFromAnyActive(
            runId: run.id.description,
            to: status,
            detail: run.terminalFailure?.message ?? run.interruptionReason?.rawValue
        )
    }

    func novelDurableInputRef(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) -> String {
        "novel:\(projectID.description):\(branchID.description)"
    }

    func reduceTerminalClaim(
        runID: NovelRunID,
        claim: NovelRunTerminalClaim,
        document: NovelProjectDocumentV1
    ) throws -> (document: NovelProjectDocumentV1, result: NovelTerminalCommit) {
        switch claim.intent {
        case .completed:
            if let replay = try replayTerminalCommit(
                runID: runID,
                claim: claim,
                document: document
            ) {
                return (document, replay)
            }
            let reduced = try NovelGenerationReducer.complete(
                runID: runID,
                content: claim.partialContent,
                in: document,
                now: claim.claimedAt
            )
            guard let message = reduced.message else {
                throw NovelError.storageIndeterminate(document.project.id)
            }
            return (
                reduced.document,
                NovelTerminalCommit(outcome: nil, event: .completed(message))
            )

        case .awaitingUser(let prompt, let preface):
            if let replay = try replayTerminalCommit(
                runID: runID,
                claim: claim,
                document: document
            ) {
                return (document, replay)
            }
            let reduced = try NovelGenerationReducer.completeAwaitingUser(
                runID: runID,
                prompt: prompt,
                preface: preface,
                in: document,
                now: claim.claimedAt
            )
            guard let message = reduced.message else {
                throw NovelError.storageIndeterminate(document.project.id)
            }
            return (
                reduced.document,
                NovelTerminalCommit(outcome: nil, event: .completed(message))
            )

        case .interrupted(let reason, let command):
            if let command {
                let reduced = try NovelGenerationReducer.interrupt(
                    command,
                    partialContent: claim.partialContent,
                    in: document,
                    now: claim.claimedAt
                )
                guard let outcome = reduced.outcome else {
                    throw NovelError.storageIndeterminate(document.project.id)
                }
                let message = reduced.message ?? sessionMessageSnapshot(
                    runID: runID,
                    document: reduced.document
                )
                return (
                    reduced.document,
                    NovelTerminalCommit(
                        outcome: outcome,
                        event: .interrupted(message)
                    )
                )
            }
            if let replay = try replayTerminalCommit(
                runID: runID,
                claim: claim,
                document: document
            ) {
                return (document, replay)
            }
            let reduced = try NovelGenerationReducer.interrupt(
                runID: runID,
                reason: reason,
                partialContent: claim.partialContent,
                in: document,
                now: claim.claimedAt
            )
            return (
                reduced.document,
                NovelTerminalCommit(
                    outcome: nil,
                    event: .interrupted(reduced.message)
                )
            )

        case .failed(let failure):
            if let replay = try replayTerminalCommit(
                runID: runID,
                claim: claim,
                document: document
            ) {
                return (document, replay)
            }
            let reduced = try NovelGenerationReducer.fail(
                runID: runID,
                failure: failure,
                partialContent: claim.partialContent,
                in: document,
                now: claim.claimedAt
            )
            return (
                reduced.document,
                NovelTerminalCommit(outcome: nil, event: .failed(failure))
            )
        }
    }

    func replayTerminalCommit(
        runID: NovelRunID,
        claim: NovelRunTerminalClaim,
        document: NovelProjectDocumentV1
    ) throws -> NovelTerminalCommit? {
        guard let run = document.activeRuns.first(where: { $0.id == runID }) else {
            throw NovelError.runNotFound(runID)
        }
        guard run.status != .running else { return nil }
        guard run.partialContent == claim.partialContent else {
            throw NovelError.storageIndeterminate(document.project.id)
        }

        switch claim.intent {
        case .completed:
            guard run.status == .completed,
                  let message = sessionMessageSnapshot(
                    runID: runID,
                    document: document
                  ) else {
                throw NovelError.storageIndeterminate(document.project.id)
            }
            return NovelTerminalCommit(outcome: nil, event: .completed(message))
        case .awaitingUser(let prompt, _):
            guard run.status == .completed,
                  let message = sessionMessageSnapshot(
                      runID: runID,
                      document: document
                  ),
                  message.message.interaction == .askUser(prompt) else {
                throw NovelError.storageIndeterminate(document.project.id)
            }
            return NovelTerminalCommit(outcome: nil, event: .completed(message))
        case .interrupted(let reason, let command):
            guard command == nil,
                  run.status == .interrupted,
                  run.interruptionReason == reason else {
                throw NovelError.storageIndeterminate(document.project.id)
            }
            return NovelTerminalCommit(
                outcome: nil,
                event: .interrupted(sessionMessageSnapshot(
                    runID: runID,
                    document: document
                ))
            )
        case .failed(let failure):
            guard run.status == .failed,
                  run.terminalFailure == failure else {
                throw NovelError.storageIndeterminate(document.project.id)
            }
            return NovelTerminalCommit(outcome: nil, event: .failed(failure))
        }
    }

    static func decodeAskUserFallback(_ output: String) throws -> NovelAskUserPrompt? {
        struct FallbackEnvelope: Decodable {
            let amberAskUser: NovelAskUserPrompt
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}",
              let data = trimmed.data(using: .utf8) else { return nil }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["amberAskUser"] else { return nil }
        let prompt = try JSONDecoder().decode(FallbackEnvelope.self, from: data).amberAskUser
        try NovelGenerationReducer.validateAskUserPrompt(prompt)
        return prompt
    }

    func sessionMessageSnapshot(
        runID: NovelRunID,
        document: NovelProjectDocumentV1
    ) -> NovelSessionMessageSnapshot? {
        guard let run = document.activeRuns.first(where: { $0.id == runID }),
              let message = document.sessions
                .first(where: { $0.id == run.sessionID })?
                .messages
                .first(where: { $0.id == run.messageID }) else {
            return nil
        }
        return NovelSessionMessageSnapshot(
            projectID: document.project.id,
            branchID: run.branchID,
            message: message
        )
    }

    func flushRecoverySidecar(runID: NovelRunID, force: Bool) async -> Bool {
        if force {
            while let inFlight = recoverySidecarFlushes[runID] {
                _ = await inFlight.value
            }
        } else if recoverySidecarFlushes[runID] != nil {
            recoverySidecarFlushPending.insert(runID)
            return true
        }

        guard let runtime = generationRuntimes[runID] else { return false }
        let timestamp = now()
        let byteCount = runtime.partialContent.utf8.count
        let bytesAdded = max(0, byteCount - runtime.lastSidecarByteCount)
        guard force ||
            bytesAdded >= generationPolicy.sidecarByteThreshold ||
            timestamp.timeIntervalSince(runtime.lastSidecarAt) >= generationPolicy.sidecarInterval else {
            return true
        }

        let task = Task { [self] in
            let result = await writeRecoverySidecarNow(runID: runID)
            recoverySidecarFlushes[runID] = nil
            if recoverySidecarFlushPending.remove(runID) != nil {
                _ = await flushRecoverySidecar(runID: runID, force: false)
            }
            return result
        }
        recoverySidecarFlushes[runID] = task
        if force { return await task.value }
        return true
    }

    func writeRecoverySidecarNow(runID: NovelRunID) async -> Bool {
        guard var runtime = generationRuntimes[runID] else { return false }
        let timestamp = now()
        let byteCount = runtime.partialContent.utf8.count
        runtime.sidecarSequence += 1
        runtime.lastSidecarAt = timestamp
        runtime.lastSidecarByteCount = byteCount
        generationRuntimes[runID] = runtime
        guard let loaded = try? await loadCommittedProject(id: runtime.projectID),
              let run = loaded.document.activeRuns.first(where: { $0.id == runID }) else {
            return false
        }
        let sidecar = NovelRecoverySidecarV1(
            schemaVersion: NovelRecoverySidecarV1.currentSchemaVersion,
            projectID: runtime.projectID,
            runID: runID,
            branchID: run.branchID,
            sessionID: run.sessionID,
            messageID: run.messageID,
            baseProjectRevision: runtime.startProjectRevision,
            sequence: runtime.sidecarSequence,
            partialContent: runtime.partialContent,
            partialSHA256: NovelDocumentValidator.sha256(runtime.partialContent),
            updatedAt: timestamp,
            responseID: runtime.responseCursor?.responseID,
            responseSequenceNumber: runtime.responseCursor?.sequenceNumber
        )
        do {
            try await repository.writeRecoverySidecar(sidecar)
            if generationRuntimes[runID] == nil {
                try? await repository.removeRecoverySidecar(
                    projectID: runtime.projectID,
                    runID: runID
                )
            }
            return true
        } catch {
            // The project terminal remains authoritative. A later forced flush
            // or startup recovery retries without publishing false durability.
            return false
        }
    }

    func commitGenerationMutation<Result: Sendable>(
        projectID: NovelProjectID,
        waitForMutations: Bool,
        reducer: (NovelProjectDocumentV1) throws -> (
            document: NovelProjectDocumentV1,
            result: Result
        )
    ) async throws -> Result {
        if waitForMutations {
            await waitForInFlightMutation(projectID: projectID)
        }
        await waitForGenerationWrite(projectID: projectID)
        generationWriteProjectIDs.insert(projectID)
        defer { finishGenerationWrite(projectID: projectID) }

        var lastError: Error?
        for _ in 0..<3 {
            let loaded = try await loadCommittedProject(id: projectID)
            guard loaded.access == .readWrite else {
                throw NovelError.degradedReadOnly(projectID: projectID)
            }
            let reduced = try reducer(loaded.document)
            if reduced.document == loaded.document {
                return reduced.result
            }
            do {
                let transition = try NovelDocumentValidator.validateTransitionFromValidatedCurrent(
                    from: loaded.document,
                    to: reduced.document
                )
                let committed = try await repository.commitProject(
                    transition,
                    authorization: nil
                )
                guard committed.document == reduced.document ||
                    committed.document == NovelWorkspaceProjectStore.persistableAtRest(reduced.document) else {
                    throw NovelError.storageIndeterminate(projectID)
                }
                _ = try installLoadedProject(
                    committed,
                    id: projectID,
                    allowsRollback: false
                )
                // Run/terminal writes bypass NovelAction.perform, so notify
                // project-list observers after the durable project revision lands.
                publishMutation(
                    projectID: projectID,
                    operationID: NovelOperationID(),
                    refreshesSelection: false
                )
                return reduced.result
            } catch {
                lastError = error
                if requiresRepositoryReconciliation(error) {
                    frozenProjectIDs.insert(projectID)
                } else if case NovelError.repositoryFailure = error {
                    // One retry covers injected pre-install failures while the
                    // reducer replays from the still-authoritative snapshot.
                } else {
                    throw error
                }
                await Task.yield()
            }
        }
        throw lastError ?? NovelError.storageIndeterminate(projectID)
    }

}
