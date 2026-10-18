import Foundation
@preconcurrency import Shared

@MainActor
final class IOSOrchestrationJevRouting {
    struct DeferredShadowT3Batch {
        let parts: [IOSJevBatchPart]
        let context: IOSJevRunContext
        let settings: IOSJevSettings
        let modelCandidates: [IOSSubAgentModelPool.Candidate]
        let modelPartId: String?
        let hasIntentPart: Bool
    }

    struct JevSpawnDecision {
        var preferredModelIds: [String] = []
        var observedPreferredModelIds: [String] = []
        var modelRoutingObserved = false
        var intent = IOSJevSubAgentIntentService.Suggestion(roleId: nil, alignmentDoubtful: false)
        var intentRoutingRequested = false
        var observedIntentRoleId: String?
        var deferredShadowBatch: DeferredShadowT3Batch?
        var settings = IOSJevSettings()
        var modelRoutingRequested = false
    }


    private let sharedSettingsProvider: () -> IOSSharedSettingsStore?
    private let modelPool: IOSSubAgentModelPool
    private let jevCoordinator: IOSJevDecisionCoordinator
    private let jevSettingsProvider: () -> IOSJevSettings

    init(sharedSettingsProvider: @escaping () -> IOSSharedSettingsStore?, modelPool: IOSSubAgentModelPool, jevCoordinator: IOSJevDecisionCoordinator, jevSettingsProvider: @escaping () -> IOSJevSettings) {
        self.sharedSettingsProvider = sharedSettingsProvider
        self.modelPool = modelPool
        self.jevCoordinator = jevCoordinator
        self.jevSettingsProvider = jevSettingsProvider
    }

    func jevSpawnDecision(
        arguments: [String: Any],
        parentRunId: String,
        allowPoolForInheritedModel: Bool,
        inherited: IOSOrchestrationAgentConfiguration?,
        sourceConversation: Conversation?,
        includeRoleIntent: Bool
    ) async -> JevSpawnDecision {
        let jevSettings = jevSettingsProvider()
        var result = JevSpawnDecision(settings: jevSettings)
        guard IOSOrchestrationLaunchPolicy.optionalTrimmedString(arguments["model_id"]) == nil,
              IOSOrchestrationLaunchPolicy.optionalTrimmedString(arguments["role_id"]) == nil else {
            return result
        }

        let taskName = IOSOrchestrationLaunchPolicy.optionalTrimmedString(arguments["task_name"]) ?? ""
        let message = IOSOrchestrationLaunchPolicy.optionalTrimmedString(arguments["message"]) ?? ""
        let taskText = "\(taskName)\n\(message)"
        let questionLimit = max(1, min(jevSettings.policy.maxQuestions, jevSettings.policy.maxCandidates))
        var parts: [IOSJevBatchPart] = []
        var modelCandidates: [IOSSubAgentModelPool.Candidate] = []
        var modelPartId: String?

        // 显式任务定义和继承角色继续优先于 Jev 角色建议。
        if includeRoleIntent,
           let sourceConversation,
           (questionLimit >= 2
               || jevSettings.effectiveMode(for: .subagentIntent) == .off
               || !jevSettings.canSend(useCase: .subagentIntent, required: [.selectedTaskText, .toolMetadata])),
           IOSOrchestrationLaunchPolicy.shouldRequestJevSubAgentIntent(
               arguments: arguments,
               inheritedConfiguration: IOSOrchestrationConfigurationCodec.orchestrationConfiguration(from: sourceConversation.currentMessages)
           ) {
            let parentRequest = sourceConversation.currentMessages.reversed()
                .first { $0.role == MessageRole.user }?.toText()
            if let part = IOSJevSubAgentIntentService.makeBatchPart(
                taskText: taskText,
                parentRequestText: parentRequest,
                settings: jevSettings
            ) {
                parts.append(part)
            }
        }

        if let sharedSettings = sharedSettingsProvider() {
            let inheritedBase = inherited
            let allowDynamic = sharedSettings.snapshot.agentRuntime.subAgent.allowDynamicSubAgents
            let effectiveRoleId = inheritedBase?.roleId ?? (allowDynamic ? nil : "explorer")
            let savedModelId = effectiveRoleId.flatMap {
                sharedSettings.snapshot.agentRuntime.subAgent.overrides[$0]?.modelId?.description()
            }
            let configuredModelId = inheritedBase?.modelId ?? savedModelId
            let shouldSelectFromPool = configuredModelId == nil
                || (allowPoolForInheritedModel && inheritedBase != nil)
            if shouldSelectFromPool {
                modelCandidates = modelPool.candidates(
                    settings: sharedSettings.snapshot,
                    sharedSettings: sharedSettings
                )
            }
        }

        // 同一 T3 请求不因模型池过大而在协调器内拆成多次出站。
        // 适用且获允许的角色 part 占两题，其余额度给模型候选。
        let intentPartIsSendable = parts.contains(where: { $0.id == IOSJevSubAgentIntentService.batchPartId })
            && jevSettings.effectiveMode(for: .subagentIntent) != .off
            && jevSettings.canSend(useCase: .subagentIntent, required: [.selectedTaskText, .toolMetadata])
        result.intentRoutingRequested = intentPartIsSendable
        let intentQuestionCount = intentPartIsSendable ? 2 : 0
        let modelQuestionLimit = max(0, questionLimit - intentQuestionCount)
        if !modelCandidates.isEmpty,
           modelQuestionLimit > 0,
           jevSettings.effectiveMode(for: .modelRouting) != .off {
            let boundedCandidates = Array(modelCandidates.prefix(modelQuestionLimit))
            if var part = IOSJevModelRoutingService.makeBatchPart(
                taskText: taskText,
                candidates: boundedCandidates
            ) {
                let mode = jevSettings.effectiveMode(for: .modelRouting)
                part.cacheKey = mode == .shadow ? "model_routing_shadow" : "model_routing"
                modelPartId = part.id
                parts.append(part)
                result.modelRoutingRequested = jevSettings.canSend(
                    useCase: .modelRouting,
                    required: part.requiredScopes
                )
            }
        }

        guard !parts.isEmpty else { return result }
        let inputHash = IOSJevToolDiscoveryService.stableHash(
            parts.map { "\($0.id):\($0.state)" }.joined(separator: "\n\n")
        )
        let context = IOSJevRunContext(
            runId: parentRunId,
            turnBudgetKey: parentRunId,
            inputHash: inputHash
        )
        let sendableParts = parts.filter { part in
            jevSettings.effectiveMode(for: part.useCase) != .off
                && jevSettings.canSend(useCase: part.useCase, required: part.requiredScopes)
        }
        guard !sendableParts.isEmpty else { return result }
        if sendableParts.allSatisfy({ jevSettings.effectiveMode(for: $0.useCase) == .shadow }) {
            result.deferredShadowBatch = DeferredShadowT3Batch(
                parts: parts,
                context: context,
                settings: jevSettings,
                modelCandidates: modelCandidates,
                modelPartId: modelPartId,
                hasIntentPart: parts.contains { $0.id == IOSJevSubAgentIntentService.batchPartId }
            )
            return result
        }
        let outcomes = await jevCoordinator.decideBatch(
            parts: parts,
            context: context,
            waitBudgetMs: jevSettings.policy.t3WaitBudgetMs
        )
        if let modelPartId {
            let outcome = outcomes[modelPartId] ?? .skipped(reason: "missing_part_result")
            result.preferredModelIds = IOSJevModelRoutingService.preferredModelIds(
                from: outcome,
                candidates: modelCandidates,
                settings: jevSettings
            )
            if case .observed(let decision) = outcome {
                result.modelRoutingObserved = true
                result.observedPreferredModelIds = IOSJevModelRoutingService.preferredModelIds(
                    from: decision, candidates: modelCandidates, settings: jevSettings
                )
            }
        }
        if parts.contains(where: { $0.id == IOSJevSubAgentIntentService.batchPartId }) {
            let outcome = outcomes[IOSJevSubAgentIntentService.batchPartId] ?? .skipped(reason: "missing_part_result")
            result.intent = IOSJevSubAgentIntentService.suggestion(
                from: outcome,
                settings: jevSettings
            )
            let observedDecision: IOSJevDecision?
            switch outcome {
            case .applied(let decision), .observed(let decision): observedDecision = decision
            case .skipped, .failed: observedDecision = nil
            }
            result.observedIntentRoleId = observedDecision?.answers.first(where: { $0.id == "role_choice" })?.choice
        }
        return result
    }

    /// 只存被实际后台启动的池内候选 UUID；展示名和 API 模型名均不写指标。
    func recordSelectedPoolModelIfNeeded(
        launch: IOSOrchestrationLaunchPolicy.ResolvedAgentLaunch,
        decision: JevSpawnDecision,
        runId: String,
        childRunId: String,
        childThreadId: String
    ) {
        guard decision.modelRoutingRequested,
              launch.modelReservation != nil,
              let modelId = launch.configuration?.modelId,
              let uuid = IOSOrchestrationLaunchPolicy.parseKotlinUuid(modelId) else { return }
        let settings = decision.settings
        let mode = settings.effectiveMode(for: .modelRouting)
        var numbers: [String: Double]?
        if mode == .shadow {
            if decision.modelRoutingObserved,
               let snapshot = launch.poolSelectionSnapshot {
                let preferred = decision.observedPreferredModelIds
                let keysById = launch.poolSelectionCandidates.reduce(into: [String: IOSSubAgentModelPool.SelectionKey]()) {
                    $0[$1.modelId] = $1
                }
                let preferredKeys = preferred.compactMap { keysById[$0] }
                let hypothetical = snapshot.selectedModelId(
                    from: preferredKeys.isEmpty ? launch.poolSelectionCandidates : preferredKeys
                )
                var values = ["preferred_set_size": Double(preferred.count)]
                if let hypothetical {
                    values["difference"] = hypothetical == uuid.toHexDashString() ? 0 : 1
                }
                numbers = values
            }
        } else {
            var values = ["preferred_set_size": Double(decision.preferredModelIds.count)]
            if launch.baselinePoolModelId != nil {
                values["difference"] = launch.baselinePoolModelId == uuid.toHexDashString() ? 0 : 1
            }
            numbers = values
        }
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(),
            useCase: .modelRouting,
            mode: settings.effectiveMode(for: .modelRouting),
            modelVersion: settings.activeModelVersion,
            outcome: "summary",
            latencyMs: 0,
            requestBytes: 0,
            responseBytes: 0,
            inputTokens: nil,
            outputTokens: nil,
            reason: nil,
            suggestedTop1: nil,
            keywordTop1: nil,
            topConfidence: nil,
            topScore: nil,
            runId: runId,
            waitPhase: "t3",
            waitedMs: nil,
            numbers: numbers,
            ids: [
                "selected_model_id": uuid.toHexDashString(),
                "child_run_id": childRunId,
                "child_thread_id": childThreadId,
            ]
        ))
    }

    static let modelRoutingTimeoutTerminalReason = "subagent_timeout"

    static func modelRoutingChildOutcomeNumber(
        status: AgentRunStatus,
        terminalReason: String?
    ) -> String? {
        switch status {
        case .completed:
            return "child_succeeded"
        case .failed:
            return terminalReason == modelRoutingTimeoutTerminalReason
                ? "child_timed_out"
                : "child_failed"
        default:
            return nil
        }
    }

    /// Outcome counters are attached only to a durable child run that was
    /// actually launched with a Jev-routed pool model. IDs are local and contain
    /// no task text.
    func recordModelRoutingChildOutcomeIfNeeded(
        childThreadId: String,
        childRunId: String,
        terminalStatus: AgentRunStatus,
        terminalReason: String?
    ) {
        guard let number = Self.modelRoutingChildOutcomeNumber(
            status: terminalStatus,
            terminalReason: terminalReason
        ) else { return }
        let records = IOSJevMetricsStore.load()
        guard let routingRecord = records.last(where: {
            $0.useCase == .modelRouting
                && $0.outcome == "summary"
                && $0.ids?["child_run_id"] == childRunId
                && $0.ids?["child_thread_id"] == childThreadId
        }),
        let parentRunId = routingRecord.runId else {
            return
        }
        guard !records.contains(where: {
            $0.useCase == .modelRouting
                && $0.outcome == "summary"
                && $0.runId == parentRunId
                && $0.ids?["child_run_id"] == childRunId
                && $0.ids?["child_thread_id"] == childThreadId
                && $0.ids?["child_outcome"] == "terminal"
        }) else { return }

        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(),
            useCase: .modelRouting,
            mode: routingRecord.mode,
            modelVersion: routingRecord.modelVersion,
            outcome: "summary",
            latencyMs: 0,
            requestBytes: 0,
            responseBytes: 0,
            inputTokens: nil,
            outputTokens: nil,
            reason: number,
            suggestedTop1: nil,
            keywordTop1: nil,
            topConfidence: nil,
            topScore: nil,
            runId: parentRunId,
            waitPhase: "t3",
            waitedMs: nil,
            numbers: [number: 1],
            ids: [
                "child_run_id": childRunId,
                "child_thread_id": childThreadId,
                "child_outcome": "terminal",
            ]
        ))
    }

    func recordIntentSelectionIfNeeded(
        launch: IOSOrchestrationLaunchPolicy.ResolvedAgentLaunch,
        decision: JevSpawnDecision,
        runId: String
    ) {
        guard decision.intentRoutingRequested,
              let suggested = decision.observedIntentRoleId else { return }
        let selected = launch.configuration?.roleId ?? "none"
        let settings = decision.settings
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(), useCase: .subagentIntent,
            mode: settings.effectiveMode(for: .subagentIntent),
            modelVersion: settings.activeModelVersion,
            outcome: "summary", latencyMs: 0, requestBytes: 0, responseBytes: 0,
            inputTokens: nil, outputTokens: nil, reason: nil,
            runId: runId, waitPhase: "T3",
            numbers: ["difference": suggested == selected ? 0 : 1],
            ids: ["suggested_role_id": suggested, "selected_role_id": selected]
        ))
    }

    /// 全 shadow 的 T3 在 durable child 接受后才出站。它不参与当前 spawn 的
    /// 选择；后台观察完成后，只将同一选择点快照下的反事实差异写入指标。
    func scheduleDeferredShadowT3ObservationIfNeeded(
        decision: JevSpawnDecision,
        launch: IOSOrchestrationLaunchPolicy.ResolvedAgentLaunch,
        runId: String,
        childRunId: String,
        childThreadId: String
    ) {
        guard let request = decision.deferredShadowBatch else { return }
        let modelSelection = ShadowModelSelection(
            selectionSnapshot: launch.poolSelectionSnapshot,
            poolCandidates: launch.poolSelectionCandidates,
            baselineModelId: launch.baselinePoolModelId,
            selectedModelId: launch.configuration?.modelId.flatMap(IOSOrchestrationLaunchPolicy.parseKotlinUuid)?.toHexDashString(),
            selectedRoleId: launch.configuration?.roleId ?? "none"
        )
        let coordinator = jevCoordinator
        Task(priority: .utility) { @MainActor [request, modelSelection] in
            let outcomes = await coordinator.decideBatch(
                parts: request.parts,
                context: request.context,
                // Background shadow may finish after the T3 foreground wait budget;
                // wait up to the request deadline here so an observed result can be measured.
                waitBudgetMs: max(request.settings.policy.deadlineMs, request.settings.policy.t3WaitBudgetMs),
                expectedSettingsRevision: request.settings.revision
            )
            if let partId = request.modelPartId,
               case .observed(let observed)? = outcomes[partId] {
                self.recordDeferredShadowModelMetric(
                    decision: observed,
                    candidates: request.modelCandidates,
                    selection: modelSelection,
                    settings: request.settings,
                    runId: runId,
                    childRunId: childRunId,
                    childThreadId: childThreadId
                )
            }
            if request.hasIntentPart,
               case .observed(let observed)? = outcomes[IOSJevSubAgentIntentService.batchPartId],
               let suggestedRoleId = observed.answers.first(where: { $0.id == "role_choice" })?.choice {
                self.recordDeferredShadowIntentMetric(
                    suggestedRoleId: suggestedRoleId,
                    selectedRoleId: modelSelection.selectedRoleId,
                    settings: request.settings,
                    runId: runId,
                    childRunId: childRunId,
                    childThreadId: childThreadId
                )
            }
        }
    }

    private struct ShadowModelSelection {
        let selectionSnapshot: IOSSubAgentModelPool.SelectionSnapshot?
        let poolCandidates: [IOSSubAgentModelPool.SelectionKey]
        let baselineModelId: String?
        let selectedModelId: String?
        let selectedRoleId: String
    }

    private func recordDeferredShadowModelMetric(
        decision: IOSJevDecision,
        candidates: [IOSSubAgentModelPool.Candidate],
        selection: ShadowModelSelection,
        settings: IOSJevSettings,
        runId: String,
        childRunId: String,
        childThreadId: String
    ) {
        guard let snapshot = selection.selectionSnapshot,
              let selectedModelId = selection.selectedModelId,
              selection.baselineModelId != nil else { return }
        let preferredIds = IOSJevModelRoutingService.preferredModelIds(
            from: decision,
            candidates: candidates,
            settings: settings
        )
        let keysById = selection.poolCandidates.reduce(into: [String: IOSSubAgentModelPool.SelectionKey]()) {
            $0[$1.modelId] = $1
        }
        let preferredKeys = preferredIds.compactMap { keysById[$0] }
        let counterfactual = snapshot.selectedModelId(
            from: preferredKeys.isEmpty ? selection.poolCandidates : preferredKeys
        )
        guard let counterfactual else { return }
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(),
            useCase: .modelRouting,
            mode: .shadow,
            modelVersion: settings.activeModelVersion,
            outcome: "summary",
            latencyMs: 0,
            requestBytes: 0,
            responseBytes: 0,
            inputTokens: nil,
            outputTokens: nil,
            reason: nil,
            suggestedTop1: nil,
            keywordTop1: nil,
            topConfidence: nil,
            topScore: nil,
            runId: runId,
            waitPhase: "t3",
            waitedMs: nil,
            numbers: [
                "preferred_set_size": Double(preferredIds.count),
                "difference": selectedModelId == counterfactual ? 0 : 1,
            ],
            ids: [
                "selected_model_id": selectedModelId,
                "counterfactual_model_id": counterfactual,
                "child_run_id": childRunId,
                "child_thread_id": childThreadId,
            ]
        ))
    }

    private func recordDeferredShadowIntentMetric(
        suggestedRoleId: String,
        selectedRoleId: String,
        settings: IOSJevSettings,
        runId: String,
        childRunId: String,
        childThreadId: String
    ) {
        IOSJevMetricsStore.append(IOSJevMetricsRecord(
            timestamp: Date(),
            useCase: .subagentIntent,
            mode: .shadow,
            modelVersion: settings.activeModelVersion,
            outcome: "summary",
            latencyMs: 0,
            requestBytes: 0,
            responseBytes: 0,
            inputTokens: nil,
            outputTokens: nil,
            reason: nil,
            suggestedTop1: nil,
            keywordTop1: nil,
            topConfidence: nil,
            topScore: nil,
            runId: runId,
            waitPhase: "t3",
            waitedMs: nil,
            numbers: ["difference": suggestedRoleId == selectedRoleId ? 0 : 1],
            ids: [
                "suggested_role_id": suggestedRoleId,
                "selected_role_id": selectedRoleId,
                "child_run_id": childRunId,
                "child_thread_id": childThreadId,
            ]
        ))
    }

}
