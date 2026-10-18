import Foundation
@preconcurrency import Shared

@MainActor
final class IOSOrchestrationLaunchPolicy {
    struct ResolvedAgentLaunch {
        let configuration: IOSOrchestrationAgentConfiguration?
        let providerSetting: ProviderSetting
        let params: TextGenerationParams
        let modelReservation: IOSSubAgentModelPool.Reservation?
        let baselinePoolModelId: String?
        let poolSelectionSnapshot: IOSSubAgentModelPool.SelectionSnapshot?
        let poolSelectionCandidates: [IOSSubAgentModelPool.SelectionKey]
    }

    struct AgentLaunchError: Error {
        let reason: String
    }

    private let sharedSettingsProvider: () -> IOSSharedSettingsStore?
    private let modelPool: IOSSubAgentModelPool
    private let backgroundCoordinator: any IOSThreadOrchestrationToolService.BackgroundScheduling

    init(sharedSettingsProvider: @escaping () -> IOSSharedSettingsStore?, modelPool: IOSSubAgentModelPool, backgroundCoordinator: any IOSThreadOrchestrationToolService.BackgroundScheduling) {
        self.sharedSettingsProvider = sharedSettingsProvider
        self.modelPool = modelPool
        self.backgroundCoordinator = backgroundCoordinator
    }

    func resolveAgentLaunch(
        arguments: [String: Any],
        providerSetting: ProviderSetting,
        params: TextGenerationParams,
        toolExposureBridge: IosToolExposureBridge?,
        inherited: IOSOrchestrationAgentConfiguration?,
        allowPoolForInheritedModel: Bool = false,
        jevPreferredModelIds: [String] = [],
        jevObservedPreferredModelIds: [String] = [],
        jevSuggestedRoleId: String? = nil
    ) -> Result<ResolvedAgentLaunch, AgentLaunchError> {
        let settings = sharedSettingsProvider()?.snapshot
        let allowDynamic = settings?.agentRuntime.subAgent.allowDynamicSubAgents ?? true

        let roleArgument = Self.optionalTrimmedString(arguments["role_id"])
        let systemPromptPresent = arguments.keys.contains("system_prompt")
        let contextPresent = arguments.keys.contains("context")
        let toolScopeArgument = Self.stringArrayArgument(arguments, keys: ["tool_scope", "tools"])
        let skillNamesArgument = Self.stringArrayArgument(arguments, keys: ["skill_names", "skills"])
        let hasTaskDefinition = roleArgument != nil
            || systemPromptPresent
            || contextPresent
            || toolScopeArgument.present
            || skillNamesArgument.present

        let inheritedBase = roleArgument == nil ? inherited : nil
        // Jev 意图路由建议仅在没有显式定义、也没有继承配置时补位
        // （服务侧已做目录校验与置信门）。!allowDynamic 时一律 explorer：
        // 该开关关闭的是"子代理形态的裁量权"，Jev 建议同属裁量源，不让位。
        // 对齐回执（标注）不受此限，照常产出。
        let canApplyJevRoleSuggestion = Self.shouldRequestJevSubAgentIntent(
            arguments: arguments,
            inheritedConfiguration: inheritedBase
        )
        let effectiveRoleId = roleArgument
            ?? inheritedBase?.roleId
            ?? (allowDynamic && canApplyJevRoleSuggestion ? jevSuggestedRoleId : nil)
            ?? (allowDynamic ? nil : "explorer")
        let role = effectiveRoleId.flatMap(IOSSubAgentRoleCatalog.resolve)

        if !allowDynamic {
            if role == nil, inheritedBase == nil {
                return .failure(AgentLaunchError(reason: "动态子代理开关已关闭，只能使用内置 role_id。"))
            }
            if systemPromptPresent || contextPresent || toolScopeArgument.present || skillNamesArgument.present {
                return .failure(AgentLaunchError(reason: "动态子代理开关已关闭，内置 role 只能使用设置中保存的配置。"))
            }
        } else if hasTaskDefinition, roleArgument != nil, role == nil,
                  effectiveRoleId?.isEmpty == false {
            // Unknown role ids are valid only as explicit dynamic definitions.
            // They still need a prompt or another definition field to be useful.
            if !systemPromptPresent && !contextPresent && !toolScopeArgument.present && !skillNamesArgument.present {
                return .failure(AgentLaunchError(reason: "未知 role_id 需要同时提供 system_prompt、context、tool_scope 或 skill_names。"))
            }
        }
        if toolScopeArgument.present, toolScopeArgument.values == nil {
            return .failure(AgentLaunchError(reason: "tool_scope 必须是字符串数组。"))
        }
        if skillNamesArgument.present, skillNamesArgument.values == nil {
            return .failure(AgentLaunchError(reason: "skill_names 必须是字符串数组。"))
        }

        let savedOverride = effectiveRoleId.flatMap { settings?.agentRuntime.subAgent.overrides[$0] }
        let availableToolNames = Set(
            (toolExposureBridge?.fullToolDeclarations() ?? params.tools).map(\.name)
        )
        let explicitPrompt = systemPromptPresent
            ? Self.optionalTrimmedString(arguments["system_prompt"])
            : nil
        let explicitContext = contextPresent
            ? Self.optionalTrimmedString(arguments["context"])
            : nil
        let systemPrompt = systemPromptPresent
            ? explicitPrompt
            : (inheritedBase?.systemPrompt ?? savedOverride?.systemPrompt ?? role?.systemPrompt)
        let context = contextPresent ? explicitContext : inheritedBase?.context
        let toolScope: [String]?
        if toolScopeArgument.present {
            toolScope = toolScopeArgument.values
        } else if let inheritedScope = inheritedBase?.toolScope {
            toolScope = inheritedScope
        } else if let savedScope = savedOverride?.toolAllowlist {
            toolScope = Array(savedScope).sorted()
        } else if let effectiveRoleId, role != nil {
            let mcpServers = (settings?.mcpServers.compactMap(IOSMcpServerConfig.init) ?? [])
                + IOSMcpConfigStore.shared.servers
            toolScope = IOSSubAgentRoleCatalog.defaultToolNames(
                roleId: effectiveRoleId,
                availableToolNames: Array(availableToolNames),
                mcpServers: mcpServers
            )
        } else {
            toolScope = nil
        }
        let skillNames: [String]
        if skillNamesArgument.present {
            skillNames = skillNamesArgument.values ?? []
        } else if let inheritedSkills = inheritedBase?.skillNames {
            skillNames = inheritedSkills
        } else if let savedSkills = savedOverride?.defaultSkillNames {
            skillNames = savedSkills
        } else {
            skillNames = []
        }

        if let toolScope {
            let unknown = toolScope.filter { !availableToolNames.contains($0) }
            if !unknown.isEmpty {
                return .failure(AgentLaunchError(
                    reason: "tool_scope 包含当前父线程不可用的工具：\(unknown.joined(separator: ", "))。"
                ))
            }
        }

        let normalizedSkills = skillNames.map(IOSSkillFileStore.normalizedSkillName)
        let skillContext: String
        do {
            skillContext = try IOSSkillMcpToolService.loadEnabledSkillContext(
                skillNames: normalizedSkills,
                enabledSkillNames: sharedSettingsProvider()?.currentAssistantEnabledSkillNames ?? []
            )
        } catch {
            return .failure(AgentLaunchError(reason: "无法加载子代理默认技能：\(error.localizedDescription)"))
        }

        var childProvider = providerSetting
        var childModel = params.model
        var switchedModel = false
        let configuredModelId = inheritedBase?.modelId ?? savedOverride?.modelId?.description()
        let explicitModelId = Self.optionalTrimmedString(arguments["model_id"])
        let explicitReasoningRaw = Self.optionalTrimmedString(arguments["reasoning_level"])
        var modelReservation: IOSSubAgentModelPool.Reservation?
        var selectedPoolCandidate: IOSSubAgentModelPool.Candidate?
        var baselinePoolModelId: String?
        var poolSelectionSnapshot: IOSSubAgentModelPool.SelectionSnapshot?
        var poolSelectionCandidates: [IOSSubAgentModelPool.SelectionKey] = []
        let poolCandidates = settings.flatMap { settings in
            sharedSettingsProvider().map { modelPool.candidates(settings: settings, sharedSettings: $0) }
        } ?? []

        if let explicitModelId {
            guard let parsed = Self.parseKotlinUuid(explicitModelId),
                  let candidate = modelPool.candidate(
                    for: parsed.toHexDashString(),
                    from: poolCandidates
                  ) else {
                return .failure(AgentLaunchError(
                    reason: "显式 model_id 必须是当前用户模型池中的可用模型：\(explicitModelId)"
                ))
            }
            selectedPoolCandidate = candidate
        } else {
            let shouldSelectFromPool = configuredModelId == nil
                || (allowPoolForInheritedModel && inheritedBase != nil)
            if shouldSelectFromPool, !poolCandidates.isEmpty {
                // Jev Phase 3（模型调度）：active 判断在这里之前完成，shadow
                // 只排入后台观察；两者都不提前占用模型名额。select 与 reserve
                // 仍在无 await 的同步临界段内；空首选集沿用本地负载/轮转选择。
                let refreshedPoolCandidates = settings.flatMap { settings in
                    sharedSettingsProvider().map { modelPool.candidates(settings: settings, sharedSettings: $0) }
                } ?? []
                let selectionPool = IOSJevModelRoutingService.preferredCandidates(
                    from: refreshedPoolCandidates,
                    rankedIds: jevPreferredModelIds
                )
                let rankedPool = selectionPool.isEmpty ? refreshedPoolCandidates : selectionPool
                let activeModelCounts = backgroundCoordinator.activeModelCounts
                let activeProviderCounts = backgroundCoordinator.activeProviderCounts
                let snapshot = modelPool.selectionSnapshot(
                    activeModelCounts: activeModelCounts,
                    activeProviderCounts: activeProviderCounts
                )
                poolSelectionSnapshot = snapshot
                poolSelectionCandidates = refreshedPoolCandidates.map(\.selectionKey)
                baselinePoolModelId = snapshot.selectedModelId(from: poolSelectionCandidates)
                guard let selected = modelPool.select(
                    from: rankedPool,
                    activeModelCounts: activeModelCounts,
                    activeProviderCounts: activeProviderCounts
                ) else {
                    return .failure(AgentLaunchError(reason: "模型池中没有可用模型，请在子代理设置中重新选择。"))
                }
                selectedPoolCandidate = selected
            } else if shouldSelectFromPool,
                      settings?.agentRuntime.subAgent.modelPool.isEmpty == false {
                return .failure(AgentLaunchError(reason: "模型池中的模型均已停用、移除或配置不可用。"))
            }
        }

        if let selectedPoolCandidate {
            childProvider = selectedPoolCandidate.provider
            childModel = selectedPoolCandidate.model
            switchedModel = childModel.id != params.model.id
        } else if let configuredModelId,
                  let parsed = Self.parseKotlinUuid(configuredModelId),
                  let settings,
                  let configuredModel = settings.findModelById(uuid: parsed),
                  let configuredProvider = ChatProviderConfiguration.provider(
                      for: configuredModel,
                      providers: settings.providers
                  ) {
            if let issue = ChatProviderConfiguration.issue(for: configuredModel, provider: configuredProvider) {
                return .failure(AgentLaunchError(reason: "子代理模型不可用：\(issue.message)"))
            }
            childProvider = configuredProvider
            childModel = configuredModel
            switchedModel = configuredModel.id != params.model.id
        } else if let configuredModelId, configuredModelId != params.model.id.description(), settings != nil {
            return .failure(AgentLaunchError(reason: "子代理配置的模型已不存在，请重新选择模型。"))
        }

        let supportedReasoning = sharedSettingsProvider()?.subAgentReasoningLevels(
            modelId: childModel.id.toHexDashString()
        ) ?? []
        let reasoning: ReasoningLevel
        if let explicitReasoningRaw {
            guard let parsed = Self.reasoningLevel(named: explicitReasoningRaw) else {
                return .failure(AgentLaunchError(reason: "reasoning_level 无效：\(explicitReasoningRaw)"))
            }
            guard supportedReasoning.contains(parsed) else {
                return .failure(AgentLaunchError(reason: "模型不支持 reasoning_level=\(explicitReasoningRaw)。"))
            }
            reasoning = parsed
        } else if let selectedPoolCandidate {
            let configured = selectedPoolCandidate.configuredReasoning
            reasoning = configured.flatMap { supportedReasoning.contains($0) ? $0 : nil }
                ?? modelPool.defaultReasoning(for: selectedPoolCandidate)
        } else if let inheritedReasoning = inheritedBase?.reasoningLevel,
                  let parsed = Self.reasoningLevel(named: inheritedReasoning) {
            reasoning = parsed
        } else if let savedReasoning = savedOverride?.reasoningLevel {
            reasoning = savedReasoning
        } else {
            reasoning = params.reasoningLevel
        }
        if let selectedPoolCandidate {
            modelReservation = modelPool.reserve(selectedPoolCandidate)
        }

        let configuration = IOSOrchestrationAgentConfiguration(
            roleId: effectiveRoleId,
            systemPrompt: systemPrompt,
            context: context,
            toolScope: toolScope,
            skillNames: normalizedSkills,
            skillContext: skillContext,
            modelId: childModel.id.description(),
            reasoningLevel: reasoning.name
        )
        let childHeaders: [CustomHeader]
        let childBodies: [CustomBody]
        if switchedModel, let settings {
            let assistant = settings.getCurrentAssistant()
            childHeaders = IOSProviderRequestHeaderStore.headers(
                for: childProvider.id.description()
            ) + assistant.customHeaders + childModel.customHeaders
            childBodies = assistant.customBodies + childModel.customBodies
        } else {
            childHeaders = params.customHeaders
            childBodies = params.customBody
        }
        let childParams = TextGenerationParams(
            model: childModel,
            temperature: params.temperature,
            topP: params.topP,
            maxTokens: params.maxTokens,
            tools: toolScope.map { scope in params.tools.filter { scope.contains($0.name) } } ?? params.tools,
            reasoningLevel: reasoning,
            customHeaders: childHeaders,
            customBody: childBodies
        )
        return .success(ResolvedAgentLaunch(
            configuration: configuration,
            providerSetting: childProvider,
            params: childParams,
            modelReservation: modelReservation,
            baselinePoolModelId: baselinePoolModelId,
            poolSelectionSnapshot: poolSelectionSnapshot,
            poolSelectionCandidates: poolSelectionCandidates
        ))
    }

    static func shouldRequestJevSubAgentIntent(
        arguments: [String: Any],
        inheritedConfiguration: IOSOrchestrationAgentConfiguration?
    ) -> Bool {
        !Self.hasAgentConfigurationArguments(arguments) && inheritedConfiguration == nil
    }

    static func optionalTrimmedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArrayArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> (present: Bool, values: [String]?) {
        guard let key = keys.first(where: { arguments.keys.contains($0) }) else {
            return (false, nil)
        }
        let value = arguments[key]
        if let values = value as? [String] {
            return (true, values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return (true, nil)
    }

    static func hasAgentConfigurationArguments(_ arguments: [String: Any]) -> Bool {
        arguments.keys.contains { key in
            ["role_id", "system_prompt", "context", "tool_scope", "tools", "skill_names", "skills",
             "model_id", "reasoning_level"].contains(key)
        }
    }

    static func parseKotlinUuid(_ value: String) -> KotlinUuid? {
        let normalized = value.lowercased()
        guard UUID(uuidString: normalized) != nil else { return nil }
        return KotlinUuid.companion.parse(uuidString: normalized)
    }

    private static func reasoningLevel(named raw: String) -> ReasoningLevel? {
        switch raw.lowercased() {
        case "off": return .off
        case "auto": return .auto_
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "xhigh": return .xhigh
        case "max": return .max
        default: return nil
        }
    }

    func subAgentTimeoutSeconds(
        for configuration: IOSOrchestrationAgentConfiguration?
    ) -> TimeInterval {
        let settings = sharedSettingsProvider()?.snapshot
        let globalMilliseconds = settings?.agentRuntime.subAgent.timeoutMs ?? 300_000
        let global = min(3_600, max(1, Double(globalMilliseconds) / 1_000))
        guard let roleId = configuration?.roleId,
              let override = settings?.agentRuntime.subAgent.overrides[roleId]?.timeoutMsOverride else {
            return global
        }
        let roleSeconds = min(3_600, max(1, Double(truncating: override) / 1_000))
        return min(global, roleSeconds)
    }

}
