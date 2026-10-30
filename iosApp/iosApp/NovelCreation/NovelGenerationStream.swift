import Foundation
import UIKit
@preconcurrency import Shared

extension DefaultNovelCreation {
    func resumeRecoveredRunIfPossible(
        _ run: NovelActiveRunRecord,
        sidecar: NovelRecoverySidecarV1,
        document: NovelProjectDocumentV1
    ) async -> Bool {
        guard generationRuntimes[run.id] == nil,
              let responseID = sidecar.responseID,
              let responseSequenceNumber = sidecar.responseSequenceNumber,
              let purpose = resumablePurpose(for: run.kind),
              modelRunner is any NovelDurableModelRunning,
              let receipt = document.generationReceipts.first(where: {
                  $0.id == run.receiptID && $0.runID == run.id
              }) else {
            return false
        }
        let model = NovelResolvedModel(
            providerID: receipt.providerID,
            ownerProviderID: receipt.ownerProviderID,
            modelID: receipt.modelID,
            wireModelID: receipt.wireModelID,
            displayName: receipt.wireModelID,
            contextWindowTokens: nil
        )
        generationRuntimes[run.id] = NovelRunRuntime(
            projectID: document.project.id,
            branchID: run.branchID,
            kind: run.kind,
            startProjectRevision: sidecar.baseProjectRevision,
            partialContent: sidecar.partialContent,
            usage: nil,
            subscribers: [:],
            modelTask: nil,
            modelStreamID: nil,
            sidecarSequence: sidecar.sequence,
            lastSidecarAt: now(),
            lastSidecarByteCount: sidecar.partialContent.utf8.count,
            resumeModel: model,
            resumePurpose: purpose,
            responseCursor: NovelResponsesResumeCursor(
                responseID: responseID,
                sequenceNumber: responseSequenceNumber
            ),
            isDetachedForBackground: true,
            didAutoReconnectAfterDisconnect: false,
            terminalClaim: nil
        )
        guard await ensureDurableNovelRun(run, projectID: document.project.id) else {
            await failRun(
                run.id,
                failure: NovelFailure(
                    code: "run_ledger_start_failed",
                    message: "无法保存运行状态，已停止生成。",
                    isRetryable: true
                )
            )
            return true
        }
        do {
            try await resumeDetachedRun(run.id)
            return true
        } catch {
            await modelRunner.cancel(runID: run.id)
            guard let runtime = generationRuntimes[run.id] else {
                return true
            }
            guard runtime.terminalClaim == nil else {
                return true
            }
            runtime.modelTask?.cancel()
            generationRuntimes.removeValue(forKey: run.id)
            await endBackgroundLease(for: run.id)
            return false
        }
    }

    func resumablePurpose(for kind: NovelRunKind) -> NovelModelPurpose? {
        switch kind {
        case .prose, .regenerate:
            .prose
        case .polish:
            .polish
        case .quickStart, .characterProposal, .discussion:
            nil
        }
    }

    func resumeDurablyStartedRun(
        _ request: NovelRunRequest,
        modelRequest: NovelModelRequest,
        loaded: NovelLoadedProject
    ) async throws -> NovelRun {
        guard let runRecord = loaded.document.activeRuns.first(where: {
            $0.id == request.id && $0.status == .running
        }) else {
            if let replay = try await replayOrObserve(request, document: loaded.document) {
                return replay
            }
            throw NovelError.storageIndeterminate(request.projectID)
        }

        publishMutation(
            projectID: request.projectID,
            operationID: request.operationID,
            refreshesSelection: false
        )

        let run = makeRuntimeAndStream(
            run: runRecord,
            projectID: request.projectID,
            startProjectRevision: loaded.document.project.revision,
            modelRequest: modelRequest
        )
        broadcast(
            .started(NovelRunReceipt(
                runID: request.id,
                projectID: request.projectID,
                branchID: request.branchID,
                receiptID: request.generationReceiptID
            )),
            runID: request.id
        )

        guard await ensureDurableNovelRun(runRecord, projectID: request.projectID) else {
            await failRun(
                request.id,
                failure: NovelFailure(
                    code: "run_ledger_start_failed",
                    message: "无法保存运行状态，已停止生成。",
                    isRetryable: true
                )
            )
            return run
        }

        // The durable marker is in place and the provider is about to start.
        updateBackgroundLease(
            runID: request.id,
            completed: 1,
            subtitle: IOSAppLocalization.string(
                "等待模型响应",
                defaultValue: "等待模型响应"
            )
        )

        do {
            let modelEvents = try await modelRunner.start(modelRequest)
            installModelStream(modelEvents, runID: request.id)
        } catch is CancellationError {
            // Reservation cancellation is owned by interruptRun/background.
            // Those paths claim and persist interruption before cancelling this
            // task, so cancellation must never overwrite it as model_start_failed.
        } catch {
            await failRun(
                request.id,
                failure: failure(from: error, fallbackCode: "model_start_failed")
            )
        }
        return run
    }

    func updateBackgroundLease(
        runID: NovelRunID,
        completed: Int64,
        subtitle: String
    ) {
        let leaseID = novelRunBackgroundLeaseID(for: runID)
        Task { @MainActor in
            BackgroundGenerationKeepAlive.shared.updateProgress(
                leaseID,
                completed: completed,
                subtitle: subtitle
            )
        }
    }

    /// The system expires a continued-processing task whose progress has not
    /// moved for ~30s once the app is backgrounded, so a long stream reports
    /// its received characters (at most once a second). Ghostwrite chapters
    /// run under the batch lease instead of their own.
    private func reportStreamedCharacters(_ count: Int, runID: NovelRunID) {
        guard count > 0, var runtime = generationRuntimes[runID] else { return }
        runtime.streamedCharacters += Int64(count)
        let now = Date()
        let units = runtime.streamedCharacters - runtime.reportedStreamedCharacters
        guard now.timeIntervalSince(runtime.lastStreamProgressAt) >= 1 else {
            generationRuntimes[runID] = runtime
            return
        }
        runtime.reportedStreamedCharacters = runtime.streamedCharacters
        runtime.lastStreamProgressAt = now
        generationRuntimes[runID] = runtime
        let runLeaseID = novelRunBackgroundLeaseID(for: runID)
        let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
            projectID: runtime.projectID,
            branchID: runtime.branchID
        )
        Task { @MainActor in
            let keepAlive = BackgroundGenerationKeepAlive.shared
            if keepAlive.holdsLease(runLeaseID) {
                keepAlive.advanceProgress(runLeaseID, by: units)
            } else if keepAlive.holdsLease(ghostwriteLeaseID) {
                keepAlive.advanceProgress(ghostwriteLeaseID, by: units)
            }
        }
    }

    func endBackgroundLease(for runID: NovelRunID) async {
        let leaseID = novelRunBackgroundLeaseID(for: runID)
        await MainActor.run {
            BackgroundGenerationKeepAlive.shared.end(leaseID)
        }
    }

    func replayOrObserve(
        _ request: NovelRunRequest,
        document: NovelProjectDocumentV1
    ) async throws -> NovelRun? {
        guard let operation = document.appliedOperations.first(where: {
            $0.operationID == request.operationID
        }) else {
            return nil
        }
        let payloadSHA256 = try request.canonicalPayloadSHA256()
        guard operation.kind == .startRun,
              operation.payloadSHA256 == payloadSHA256,
              let run = document.activeRuns.first(where: { $0.id == request.id }),
              run.operationID == request.operationID else {
            throw NovelError.idempotencyConflict(request.operationID)
        }

        return try await observeExistingRun(run, projectID: request.projectID, document: document)
    }

    func observeExistingRun(
        _ run: NovelActiveRunRecord,
        projectID: NovelProjectID,
        document: NovelProjectDocumentV1
    ) async throws -> NovelRun {
        if run.status == .running {
            guard generationRuntimes[run.id] != nil else {
                throw NovelError.projectBusy(projectID)
            }
            return attachSubscriber(to: run)
        }

        let pair = AsyncStream<NovelRunEvent>.makeStream(bufferingPolicy: .unbounded)
        pair.continuation.yield(.started(NovelRunReceipt(
            runID: run.id,
            projectID: projectID,
            branchID: run.branchID,
            receiptID: run.receiptID
        )))
        yieldReplayTerminal(run, document: document, to: pair.continuation)
        pair.continuation.finish()
        await endBackgroundLease(for: run.id)
        return NovelRun(id: run.id, events: pair.stream)
    }

    func makeRuntimeAndStream(
        run: NovelActiveRunRecord,
        projectID: NovelProjectID,
        startProjectRevision: Int64,
        modelRequest: NovelModelRequest
    ) -> NovelRun {
        let pair = AsyncStream<NovelRunEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID, runID: run.id) }
        }
        generationRuntimes[run.id] = NovelRunRuntime(
            projectID: projectID,
            branchID: run.branchID,
            kind: run.kind,
            startProjectRevision: startProjectRevision,
            partialContent: run.partialContent,
            usage: nil,
            subscribers: [subscriberID: pair.continuation],
            modelTask: nil,
            modelStreamID: nil,
            sidecarSequence: 0,
            lastSidecarAt: now(),
            lastSidecarByteCount: run.partialContent.utf8.count,
            resumeModel: modelRequest.model,
            resumePurpose: modelRequest.purpose,
            responseCursor: nil,
            isDetachedForBackground: false,
            didAutoReconnectAfterDisconnect: false,
            terminalClaim: nil
        )
        return NovelRun(id: run.id, events: pair.stream)
    }

    func installModelStream(
        _ events: AsyncStream<NovelModelEvent>,
        runID: NovelRunID
    ) {
        let streamID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            var transportTerminal = false
            var disconnectedFailure: NovelModelFailure?
            for await event in events {
                if case .completed = event { transportTerminal = true }
                if case .askUser = event { transportTerminal = true }
                if case .failed = event { transportTerminal = true }
                if case .responseDisconnected(let failure) = event {
                    transportTerminal = true
                    disconnectedFailure = failure
                }
                await consumeModelEvent(event, runID: runID, streamID: streamID)
            }
            await modelStreamEnded(
                runID: runID,
                streamID: streamID,
                hadTransportTerminal: transportTerminal
            )
            if let disconnectedFailure {
                await reconnectAfterTransportDisconnect(
                    runID: runID,
                    streamID: streamID,
                    failure: disconnectedFailure
                )
            }
        }
        guard generationRuntimes[runID] != nil else {
            task.cancel()
            return
        }
        generationRuntimes[runID]?.modelStreamID = streamID
        generationRuntimes[runID]?.modelTask?.cancel()
        generationRuntimes[runID]?.modelTask = task
    }

    func resumeAllDetachedGenerationRuns() async {
        let runIDs = generationRuntimes.compactMap { runID, runtime in
            runtime.isDetachedForBackground && runtime.terminalClaim == nil ? runID : nil
        }.sorted { $0.description < $1.description }
        for runID in runIDs {
            do {
                try await resumeDetachedRun(runID)
            } catch {
                await modelRunner.cancel(runID: runID)
                await failRun(
                    runID,
                    failure: failure(from: error, fallbackCode: "provider_resume_failed")
                )
            }
        }
    }

    private func resumeDetachedRun(_ runID: NovelRunID) async throws {
        guard var runtime = generationRuntimes[runID],
              runtime.terminalClaim == nil,
              runtime.isDetachedForBackground,
              runtime.responseCursor != nil,
              let durableRunner = modelRunner as? any NovelDurableModelRunning else {
            return
        }
        runtime.isDetachedForBackground = false
        generationRuntimes[runID] = runtime
        await beginRecoveredBackgroundLease(
            projectID: runtime.projectID,
            runID: runID
        )
        guard let resumedRuntime = generationRuntimes[runID],
              resumedRuntime.terminalClaim == nil,
              !resumedRuntime.isDetachedForBackground,
              let resumedCursor = resumedRuntime.responseCursor else {
            await endBackgroundLease(for: runID)
            return
        }
        do {
            let events = try await durableRunner.resume(NovelModelResumeRequest(
                runID: runID,
                model: resumedRuntime.resumeModel,
                purpose: resumedRuntime.resumePurpose,
                cursor: resumedCursor
            ))
            installModelStream(events, runID: runID)
        } catch {
            if generationRuntimes[runID]?.terminalClaim == nil {
                generationRuntimes[runID]?.isDetachedForBackground = true
            }
            await endBackgroundLease(for: runID)
            throw error
        }
    }

    private func reconnectAfterTransportDisconnect(
        runID: NovelRunID,
        streamID: UUID,
        failure transportFailure: NovelModelFailure
    ) async {
        guard var runtime = generationRuntimes[runID],
              runtime.modelStreamID == streamID,
              runtime.terminalClaim == nil,
              runtime.isDetachedForBackground else { return }
        guard !runtime.didAutoReconnectAfterDisconnect else {
            await modelRunner.cancel(runID: runID)
            await failRun(
                runID,
                failure: NovelFailure(
                    code: transportFailure.code,
                    message: transportFailure.message,
                    isRetryable: true
                )
            )
            return
        }
        runtime.didAutoReconnectAfterDisconnect = true
        generationRuntimes[runID] = runtime
        do {
            try await resumeDetachedRun(runID)
        } catch {
            await modelRunner.cancel(runID: runID)
            await failRun(
                runID,
                failure: failure(from: error, fallbackCode: "provider_resume_failed")
            )
        }
    }

    private func beginRecoveredBackgroundLease(
        projectID: NovelProjectID,
        runID: NovelRunID
    ) async {
        let hasCursor = generationRuntimes[runID]?.responseCursor != nil
        await MainActor.run {
            let leaseID = novelRunBackgroundLeaseID(for: runID)
            let rearm: () -> Void = { [weak self] in
                Task { await self?.beginRecoveredBackgroundLease(projectID: projectID, runID: runID) }
            }
            let onLoss: () -> Void = { [weak self] in
                Task { @MainActor in
                    // 非后台丢租约：重挂，避免控制中心/进度卡误杀。
                    if UIApplication.shared.applicationState != .background {
                        rearm()
                        return
                    }
                    await self?.interruptForBackground(
                        projectID: projectID,
                        deadline: Date(),
                        runID: runID
                    )
                }
            }
            // 恢复时若已有 cursor，说明已有输出，可直接挂系统卡；否则等同首 token 前。
            BackgroundGenerationKeepAlive.shared.begin(
                leaseID,
                title: IOSAppLocalization.string(
                    "Amber 小说创作中",
                    defaultValue: "Amber 小说创作中"
                ),
                subtitle: IOSAppLocalization.string(
                    "恢复后台生成",
                    defaultValue: "恢复后台生成"
                ),
                onExpire: onLoss,
                onSystemTaskExpiration: onLoss,
                submitSystemTask: hasCursor
            )
            BackgroundGenerationKeepAlive.shared.updateProgress(
                leaseID,
                completed: hasCursor ? 2 : 1,
                total: -1,
                subtitle: hasCursor
                    ? IOSAppLocalization.string(
                        "恢复生成正文",
                        defaultValue: "恢复生成正文"
                    )
                    : IOSAppLocalization.string(
                        "恢复模型响应",
                        defaultValue: "恢复模型响应"
                    )
            )
            if hasCursor {
                BackgroundGenerationKeepAlive.shared.promoteSystemTaskIfNeeded(
                    leaseID,
                    subtitle: IOSAppLocalization.string(
                        "恢复生成正文",
                        defaultValue: "恢复生成正文"
                    )
                )
            }
        }
    }

    func attachSubscriber(to run: NovelActiveRunRecord) -> NovelRun {
        let pair = AsyncStream<NovelRunEvent>.makeStream(bufferingPolicy: .unbounded)
        let subscriberID = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID, runID: run.id) }
        }
        guard var runtime = generationRuntimes[run.id] else {
            pair.continuation.finish()
            return NovelRun(id: run.id, events: pair.stream)
        }
        runtime.subscribers[subscriberID] = pair.continuation
        generationRuntimes[run.id] = runtime
        pair.continuation.yield(.started(NovelRunReceipt(
            runID: run.id,
            projectID: runtime.projectID,
            branchID: run.branchID,
            receiptID: run.receiptID
        )))
        if !runtime.partialContent.isEmpty {
            pair.continuation.yield(.replaced(runtime.partialContent))
        }
        if case .blocked(let failure) = runtime.terminalClaim?.persistenceState {
            pair.continuation.yield(.persistenceBlocked(failure))
        }
        return NovelRun(id: run.id, events: pair.stream)
    }

    func removeSubscriber(_ subscriberID: UUID, runID: NovelRunID) {
        generationRuntimes[runID]?.subscribers[subscriberID] = nil
    }

    func broadcast(_ event: NovelRunEvent, runID: NovelRunID) {
        generationRuntimes[runID]?.subscribers.values.forEach { $0.yield(event) }
    }

    func finishRuntime(runID: NovelRunID, event: NovelRunEvent) {
        guard let runtime = generationRuntimes.removeValue(forKey: runID) else { return }
        runtime.subscribers.values.forEach {
            $0.yield(event)
            $0.finish()
        }
    }

    func claimTerminal(runID: NovelRunID, intent: NovelRunTerminalIntent) -> Bool {
        guard var runtime = generationRuntimes[runID] else { return false }
        if let claim = runtime.terminalClaim {
            return claim.intent == intent && claim.persistenceState != .persisting
        }
        // Manuscript-like runs: strip mistaken outer ```html / ```markdown fences once
        // at the terminal boundary so complete, interrupt, and fail share one clean
        // snapshot for messages, candidates, collect, and adopt. Idempotent if complete
        // path already normalized (e.g. polish sentinel handling).
        if let normalized = Self.normalizedManuscriptPartial(
            kind: runtime.kind,
            partialContent: runtime.partialContent
        ), normalized != runtime.partialContent {
            runtime.partialContent = normalized
            generationRuntimes[runID] = runtime
            broadcast(.replaced(normalized), runID: runID)
        }
        runtime.terminalClaim = NovelRunTerminalClaim(
            intent: intent,
            partialContent: runtime.partialContent,
            claimedAt: now(),
            persistenceState: .pending
        )
        generationRuntimes[runID] = runtime
        return true
    }

    /// Returns cleaned manuscript partial when this run kind produces user-collectable prose.
    private static func normalizedManuscriptPartial(
        kind: NovelRunKind,
        partialContent: String
    ) -> String? {
        switch kind {
        case .prose, .regenerate:
            return NovelPromptCatalog.normalizedCandidateProse(partialContent)
        case .polish:
            // Prefer full polish contract (sentinel + strip). Fall back to fence-only
            // strip for interrupted/partial polish messages.
            if let completed = NovelPromptCatalog.completedPolishContent(from: partialContent) {
                return completed
            }
            return NovelPromptCatalog.normalizedCandidateProse(partialContent)
        case .quickStart, .characterProposal, .discussion:
            return nil
        }
    }

    func cancelProviderWithoutWaiting(runID: NovelRunID) {
        Task { [modelRunner] in
            await modelRunner.cancel(runID: runID)
        }
    }

    func detachResumableRunForBackground(
        _ runID: NovelRunID,
        streamID expectedStreamID: UUID? = nil
    ) async -> Bool {
        guard let runtime = generationRuntimes[runID],
              expectedStreamID == nil || runtime.modelStreamID == expectedStreamID,
              runtime.terminalClaim == nil,
              runtime.responseCursor != nil,
              let durableRunner = modelRunner as? any NovelDurableModelRunning else {
            return false
        }
        if runtime.isDetachedForBackground {
            await endBackgroundLease(for: runID)
            return true
        }
        // Persist the last accepted partial/cursor pair before closing the local
        // stream. The server response remains alive and is resumed on foreground.
        guard await flushRecoverySidecar(runID: runID, force: true),
              var current = generationRuntimes[runID],
              expectedStreamID == nil || current.modelStreamID == expectedStreamID,
              current.terminalClaim == nil else {
            return false
        }
        current.isDetachedForBackground = true
        current.modelStreamID = nil
        generationRuntimes[runID] = current
        // Finish the adapter stream first so its AsyncStream terminates as
        // `.finished`. Cancelling the consumer first would surface as
        // `.cancelled` and the adapter's termination hook would cancel the
        // still-running server response.
        await durableRunner.detach(runID: runID)
        guard var detached = generationRuntimes[runID],
              detached.terminalClaim == nil else {
            return true
        }
        // Foreground recovery may have installed a replacement stream while
        // the cross-actor detach call was suspended. That new owner wins.
        guard detached.isDetachedForBackground else { return true }
        detached.modelTask?.cancel()
        detached.modelTask = nil
        generationRuntimes[runID] = detached
        await endBackgroundLease(for: runID)
        return true
    }

    func consumeModelEvent(
        _ event: NovelModelEvent,
        runID: NovelRunID,
        streamID: UUID
    ) async {
        guard generationRuntimes[runID]?.modelStreamID == streamID,
              generationRuntimes[runID]?.terminalClaim == nil else {
            return
        }
        switch event {
        case .activity:
            break
        case .reasoningDelta(let text), .reasoningReplacement(let text):
            // Presentation-only: refresh "still alive" lease subtitle path without
            // touching manuscript partialContent / sidecar body.
            guard !text.isEmpty else { return }
            if case .reasoningReplacement = event {
                broadcast(.reasoningReplacement(text), runID: runID)
            } else {
                broadcast(.reasoningDelta(text), runID: runID)
            }
            reportStreamedCharacters(text.count, runID: runID)
            if generationRuntimes[runID]?.partialContent.isEmpty == true {
                updateBackgroundLease(
                    runID: runID,
                    completed: 1,
                    subtitle: IOSAppLocalization.string(
                        "模型思考中",
                        defaultValue: "模型思考中"
                    )
                )
            }
        case .textDelta(let text):
            guard !text.isEmpty else { return }
            let isFirstVisibleContent = generationRuntimes[runID]?.partialContent.isEmpty == true
            generationRuntimes[runID]?.partialContent.append(contentsOf: text)
            reportStreamedCharacters(text.count, runID: runID)
            if isFirstVisibleContent {
                updateBackgroundLease(
                    runID: runID,
                    completed: 2,
                    subtitle: IOSAppLocalization.string(
                        "正在生成正文",
                        defaultValue: "正在生成正文"
                    )
                )
            }
            broadcast(.delta(text), runID: runID)
            _ = await flushRecoverySidecar(runID: runID, force: false)
        case .textReplacement(let text):
            guard var runtime = generationRuntimes[runID] else { return }
            let isFirstVisibleContent = runtime.partialContent.isEmpty && !text.isEmpty
            let grownCharacters = text.count - runtime.partialContent.count
            runtime.partialContent = text
            generationRuntimes[runID] = runtime
            reportStreamedCharacters(grownCharacters, runID: runID)
            if isFirstVisibleContent {
                updateBackgroundLease(
                    runID: runID,
                    completed: 2,
                    subtitle: IOSAppLocalization.string(
                        "正在生成正文",
                        defaultValue: "正在生成正文"
                    )
                )
            }
            broadcast(.replaced(text), runID: runID)
            _ = await flushRecoverySidecar(runID: runID, force: false)
        case .usage(let usage):
            generationRuntimes[runID]?.usage = usage
        case .responseFrame(let frame):
            guard var runtime = generationRuntimes[runID] else { return }
            let mustPersistFirstCursor = runtime.responseCursor == nil
            if let current = runtime.responseCursor {
                guard current.responseID == frame.cursor.responseID else {
                    await failRun(
                        runID,
                        failure: NovelFailure(
                            code: "provider_response_changed",
                            message: "远端生成标识发生变化，请重试。",
                            isRetryable: true
                        )
                    )
                    return
                }
                guard frame.cursor.sequenceNumber > current.sequenceNumber else { return }
            }
            var presentationEvents: [NovelRunEvent] = []
            var shouldUpdateVisibleLease = false
            var hasReasoningOnlyActivity = false
            var frameCharacters = 0
            for frameEvent in frame.events {
                switch frameEvent {
                case .activity:
                    break
                case .reasoningDelta(let text), .reasoningReplacement(let text):
                    guard !text.isEmpty else { continue }
                    // Never fold reasoning into runtime.partialContent.
                    if case .reasoningReplacement = frameEvent {
                        presentationEvents.append(.reasoningReplacement(text))
                    } else {
                        presentationEvents.append(.reasoningDelta(text))
                    }
                    frameCharacters += text.count
                    hasReasoningOnlyActivity = hasReasoningOnlyActivity || runtime.partialContent.isEmpty
                case .textDelta(let text):
                    guard !text.isEmpty else { continue }
                    shouldUpdateVisibleLease = shouldUpdateVisibleLease || runtime.partialContent.isEmpty
                    runtime.partialContent.append(contentsOf: text)
                    frameCharacters += text.count
                    presentationEvents.append(.delta(text))
                case .textReplacement(let text):
                    shouldUpdateVisibleLease = shouldUpdateVisibleLease ||
                        (runtime.partialContent.isEmpty && !text.isEmpty)
                    frameCharacters += max(0, text.count - runtime.partialContent.count)
                    runtime.partialContent = text
                    presentationEvents.append(.replaced(text))
                case .usage(let usage):
                    runtime.usage = usage
                }
            }
            // Commit content, usage, cursor and attachment state together before
            // the first await. Background expiration may interleave at the lease
            // update below and must observe the complete resumable frame.
            runtime.responseCursor = frame.cursor
            runtime.isDetachedForBackground = false
            generationRuntimes[runID] = runtime
            reportStreamedCharacters(frameCharacters, runID: runID)
            presentationEvents.forEach { broadcast($0, runID: runID) }
            if shouldUpdateVisibleLease {
                updateBackgroundLease(
                    runID: runID,
                    completed: 2,
                    subtitle: IOSAppLocalization.string(
                        "正在生成正文",
                        defaultValue: "正在生成正文"
                    )
                )
            } else if hasReasoningOnlyActivity {
                updateBackgroundLease(
                    runID: runID,
                    completed: 1,
                    subtitle: IOSAppLocalization.string(
                        "模型思考中",
                        defaultValue: "模型思考中"
                    )
                )
            }
            // The partial and its remote cursor move in one sidecar record. The
            // first response ID is forced immediately; later frames use the
            // existing byte/time throttle so streaming does not write per token.
            let didPersistCursor = await flushRecoverySidecar(
                runID: runID,
                force: mustPersistFirstCursor
            )
            if didPersistCursor,
               generationRuntimes[runID]?.modelStreamID == streamID {
                let shouldDetachForBackground = await MainActor.run {
                    guard UIApplication.shared.applicationState == .background else {
                        return false
                    }
                    let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
                        projectID: runtime.projectID,
                        branchID: runtime.branchID
                    )
                    return !BackgroundGenerationKeepAlive.shared.holdsLease(
                        ghostwriteLeaseID
                    )
                }
                if shouldDetachForBackground,
                   generationRuntimes[runID]?.modelStreamID == streamID {
                    _ = await detachResumableRunForBackground(
                        runID,
                        streamID: streamID
                    )
                }
            }
        case .responseDisconnected:
            generationRuntimes[runID]?.isDetachedForBackground = true
            _ = await flushRecoverySidecar(runID: runID, force: true)
        case .askUser(let prompt, let preface):
            await awaitUser(runID, prompt: prompt, preface: preface)
        case .completed:
            await completeRun(runID)
        case .failed(let failure):
            await failRun(
                runID,
                failure: NovelFailure(
                    code: failure.code,
                    message: failure.message,
                    isRetryable: failure.isRetryable
                )
            )
        }
    }

}
