import Foundation
@preconcurrency import Shared

extension IOSSharedSettingsStore {
    var savedSubAgentOverrides: [[String: String]] {
        get { (defaults.array(forKey: subAgentOverridesKey) as? [[String: String]]) ?? [] }
        set { defaults.set(newValue, forKey: subAgentOverridesKey) }
    }

    var allowsDynamicSubAgents: Bool {
        snapshot.agentRuntime.subAgent.allowDynamicSubAgents
    }

    var subAgentMaxConcurrentRuns: Int {
        min(10, max(1, Int(snapshot.agentRuntime.subAgent.maxConcurrentRuns)))
    }

    var subAgentTimeoutMinutes: Int {
        min(60, max(1, Int(snapshot.agentRuntime.subAgent.timeoutMs / 60_000)))
    }

    var subAgentModelPool: [ApiSubAgentPoolModel] {
        snapshot.agentRuntime.subAgent.modelPool
    }

    func setDynamicSubAgentsAllowed(_ allowed: Bool) {
        restoreSnapshot(IosSettingsMutations.shared.setDynamicSubAgentsAllowed(settings: snapshot, allowed: allowed))
    }

    func setSubAgentExecutionLimits(maxConcurrentRuns: Int, timeoutMinutes: Int) {
        restoreSnapshot(IosSettingsMutations.shared.setSubAgentExecutionLimits(
            settings: snapshot,
            maxConcurrentRuns: Int32(maxConcurrentRuns),
            timeoutMinutes: Int32(timeoutMinutes)
        ))
    }

    func setSubAgentModelPool(modelIds: [String]) {
        restoreSnapshot(IosSettingsMutations.shared.setSubAgentModelPool(
            settings: snapshot,
            modelIds: modelIds
        ))
    }

    func setSubAgentPoolReasoning(modelId: String, reasoningLevel: ReasoningLevel?) {
        restoreSnapshot(IosSettingsMutations.shared.setSubAgentPoolReasoning(
            settings: snapshot,
            modelId: modelId,
            reasoningLevel: reasoningLevel
        ))
    }

    func configureSubAgentRole(
        roleId: String,
        systemPrompt: String?,
        modelId: String?,
        reasoningLevel: ReasoningLevel?,
        toolAllowlist: Set<String>?,
        defaultSkillNames: [String]
    ) {
        precondition(modelId == nil || UUID(uuidString: modelId!) != nil)
        restoreSnapshot(IosSettingsMutations.shared.configureSubAgentRole(
            settings: snapshot,
            roleId: roleId,
            systemPrompt: systemPrompt,
            modelId: modelId,
            reasoningLevel: reasoningLevel,
            toolAllowlist: toolAllowlist,
            defaultSkillNames: defaultSkillNames
        ))
        var overrides = savedSubAgentOverrides.filter { $0["roleId"] != roleId }
        overrides.append(["id": UUID().uuidString, "roleId": roleId, "systemPrompt": systemPrompt ?? ""])
        savedSubAgentOverrides = overrides
    }

    func resetSubAgentRole(_ roleId: String) {
        restoreSnapshot(IosSettingsMutations.shared.removeSubAgentOverride(settings: snapshot, roleId: roleId))
        savedSubAgentOverrides = savedSubAgentOverrides.filter { $0["roleId"] != roleId }
    }

    func subAgentReasoningLevels(modelId: String?) -> [ReasoningLevel] {
        IosSettingsMutations.shared.subAgentReasoningLevels(settings: snapshot, modelId: modelId)
    }

    /// [Slice 4] Now merges a real SubAgentOverride into
    /// `snapshot.agentRuntime.subAgent.overrides` via
    /// `IosSettingsMutations.putSubAgentOverride`, then `restoreSnapshot`.
    /// Survives restart. The legacy `savedSubAgentOverrides` mirror is kept in
    /// sync (records roleId for removal) for backward-compatible readers.
    func addSubAgentOverride(roleId: String, systemPrompt: String) {
        let merged = IosSettingsMutations.shared.putSubAgentOverride(
            settings: snapshot,
            roleId: roleId,
            systemPrompt: systemPrompt
        )
        restoreSnapshot(merged)
        var overrides = savedSubAgentOverrides
        overrides.removeAll { $0["roleId"] == roleId }
        overrides.append([
            "id": UUID().uuidString,
            "roleId": roleId,
            "systemPrompt": systemPrompt,
        ])
        savedSubAgentOverrides = overrides
    }

    /// [Slice 4] Removes from BOTH the snapshot (via removeSubAgentOverride by
    /// roleId) and the legacy mirror.
    func removeSubAgentOverride(at index: Int) {
        var overrides = savedSubAgentOverrides
        guard index >= 0 && index < overrides.count else { return }
        let removed = overrides.remove(at: index)
        if let roleId = removed["roleId"] {
            // Repair compatibility mirrors created by older builds that could
            // stack several rows for the same role. One delete owns the role,
            // so no ghost row should remain after the canonical map is cleared.
            overrides.removeAll { $0["roleId"] == roleId }
            savedSubAgentOverrides = overrides
            let merged = IosSettingsMutations.shared.removeSubAgentOverride(
                settings: snapshot,
                roleId: roleId
            )
            restoreSnapshot(merged)
        } else {
            savedSubAgentOverrides = overrides
        }
    }

    // MARK: - Skill enablement write-back

    var currentAssistantEnabledSkillNames: Set<String> {
        Set(IosSettingsMutations.shared.currentAssistantEnabledSkillNames(settings: snapshot))
    }

    func isSkillEnabled(_ name: String) -> Bool {
        currentAssistantEnabledSkillNames.contains(name)
    }

    func setSkillEnabled(name: String, enabled: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let merged = IosSettingsMutations.shared.setSkillEnabledForCurrentAssistant(
            settings: snapshot,
            skillName: trimmed,
            enabled: enabled
        )
        restoreSnapshot(merged)
    }

    /// Update the user nickname (displaySetting.userNickname). Android
    /// ChatDrawer parity — iOS AccountView was preview-only before this.
    func updateUserNickname(_ nickname: String) {
        let merged = IosSettingsMutations.shared.updateUserNickname(settings: snapshot, nickname: nickname)
        restoreSnapshot(merged)
    }

    // MARK: - Mode injections (PromptInjection.ModeInjection) — Android PromptPage parity

    var modeInjections: [PromptInjection.ModeInjection] {
        snapshot.modeInjections
    }

    func upsertModeInjection(id: String, name: String, content: String, enabled: Bool, priority: Int, position: String, role: String) {
        let merged = IosSettingsMutations.shared.upsertModeInjection(
            settings: snapshot, id: id, name: name, content: content,
            enabled: enabled, priority: Int32(priority), position: position, role: role
        )
        restoreSnapshot(merged)
    }

    func deleteModeInjection(id: String) {
        restoreSnapshot(IosSettingsMutations.shared.deleteModeInjection(settings: snapshot, id: id))
    }

    // MARK: - Lorebooks — Android PromptPage parity

    var lorebooks: [Lorebook] {
        snapshot.lorebooks
    }

    func upsertLorebook(id: String, name: String, description: String, enabled: Bool) {
        let merged = IosSettingsMutations.shared.upsertLorebook(
            settings: snapshot, id: id, name: name, description: description, enabled: enabled
        )
        restoreSnapshot(merged)
    }

    func deleteLorebook(id: String) {
        restoreSnapshot(IosSettingsMutations.shared.deleteLorebook(settings: snapshot, id: id))
    }

    func removeSkillFromAllAssistants(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let merged = IosSettingsMutations.shared.removeSkillFromAllAssistants(
            settings: snapshot,
            skillName: trimmed
        )
        restoreSnapshot(merged)
    }

    // MARK: - MiniApp host access write-back

    func setMiniAppHostContextEnabled(_ enabled: Bool) {
        let miniApp = snapshot.agentRuntime.miniApp
        let merged = IosSettingsMutations.shared.setMiniAppHostAccess(
            settings: snapshot,
            hostContextEnabled: enabled,
            hostWriteEnabled: miniApp.hostWriteEnabled
        )
        restoreSnapshot(merged)
    }

    func setMiniAppHostWriteEnabled(_ enabled: Bool) {
        let miniApp = snapshot.agentRuntime.miniApp
        let merged = IosSettingsMutations.shared.setMiniAppHostAccess(
            settings: snapshot,
            hostContextEnabled: miniApp.hostContextEnabled,
            hostWriteEnabled: enabled
        )
        restoreSnapshot(merged)
    }

    func updateMiniAppRuntime(_ transform: (MiniAppSetting) -> MiniAppSettingPatch) {
        let miniApp = snapshot.agentRuntime.miniApp
        let patch = transform(miniApp)
        let merged = IosSettingsMutations.shared.setMiniAppRuntimeOptions(
            settings: snapshot,
            enabled: patch.enabled ?? miniApp.enabled,
            networkEnabled: patch.networkEnabled ?? miniApp.networkEnabled,
            externalImagesEnabled: patch.externalImagesEnabled ?? miniApp.externalImagesEnabled,
            searchEnabled: patch.searchEnabled ?? miniApp.searchEnabled,
            clipboardCopyEnabled: patch.clipboardCopyEnabled ?? miniApp.clipboardCopyEnabled,
            boardSummaryUpdateEnabled: patch.boardSummaryUpdateEnabled ?? miniApp.boardSummaryUpdateEnabled,
            hostContextEnabled: patch.hostContextEnabled ?? miniApp.hostContextEnabled,
            hostWriteEnabled: patch.hostWriteEnabled ?? miniApp.hostWriteEnabled,
            aiEnabled: patch.aiEnabled ?? miniApp.aiEnabled,
            sharedStoreEnabled: patch.sharedStoreEnabled ?? miniApp.sharedStoreEnabled,
            eventBusEnabled: patch.eventBusEnabled ?? miniApp.eventBusEnabled,
            launchEnabled: patch.launchEnabled ?? miniApp.launchEnabled,
            sensorEnabled: patch.sensorEnabled ?? miniApp.sensorEnabled,
            locationEnabled: patch.locationEnabled ?? miniApp.locationEnabled,
            clipboardReadEnabled: patch.clipboardReadEnabled ?? miniApp.clipboardReadEnabled,
            webViewDebugEnabled: patch.webViewDebugEnabled ?? miniApp.webViewDebugEnabled,
            showSourceButton: patch.showSourceButton ?? miniApp.showSourceButton
        )
        restoreSnapshot(merged)
    }

    // MARK: - Today Board / Deep Read write-back

    var todayBoard: TodayBoardSetting {
        snapshot.agentRuntime.todayBoard
    }

    func updateTodayBoard(_ transform: (TodayBoardSetting) -> TodayBoardSettingPatch) {
        let board = snapshot.agentRuntime.todayBoard
        let patch = transform(board)
        let merged = IosSettingsMutations.shared.setTodayBoardOptions(
            settings: snapshot,
            boardModelId: patch.boardModelId ?? board.boardModelId,
            clearBoardModelId: patch.clearBoardModelId,
            hotListRefreshIntervalMinutes: Int32(
                patch.hotListRefreshIntervalMinutes ?? Int(board.hotListRefreshIntervalMinutes)
            ),
            hotListWifiOnly: patch.hotListWifiOnly ?? board.hotListWifiOnly,
            hotListEnabledSources: patch.hotListEnabledSources ?? Array(board.hotListEnabledSources),
            hotListFocusKeywords: patch.hotListFocusKeywords ?? board.hotListFocusKeywords,
            hotListFilterModeWireName: patch.hotListFilterModeWireName ?? board.hotListFilterMode.wireName,
            boardReadingFontModeWireName: patch.boardReadingFontModeWireName ?? board.boardReadingFontMode.wireName,
            boardReadingFontPackId: patch.boardReadingFontPackId ?? board.boardReadingFontPackId,
            clearBoardReadingFontPackId: patch.clearBoardReadingFontPackId,
            deepReadFontScale: patch.deepReadFontScale ?? board.deepReadFontScale,
            deepReadTemplateId: patch.deepReadTemplateId ?? board.deepReadTemplateId,
            hotListTranslateToChinese: patch.hotListTranslateToChinese ?? board.hotListTranslateToChinese
        )
        restoreSnapshot(merged)
    }

    // MARK: - Real seeded collections (for UI display)

    /// Real KMP default TTS providers (DEFAULT_TTS_PROVIDERS), seeded + de-duplicated.
    /// E.g. the SystemTTS default plus cloud-provider templates. Read-only.
    var ttsProviders: [TTSProviderSetting] {
        snapshot.ttsProviders
    }

    /// The id of the seeded default TTS provider (DEFAULT_SYSTEM_TTS_ID).
    var selectedTTSProviderId: KotlinUuid {
        snapshot.selectedTTSProviderId
    }

    /// Real KMP default providers (DEFAULT_PROVIDERS), seeded + de-duplicated.
    /// Read-only preset templates (the Provider registry already consumes these).
    var providers: [ProviderSetting] {
        snapshot.providers
    }

    /// Chat-capable model ids from the real KMP providers snapshot. This is the
    /// list the iOS default-model menu can safely offer because ChatViewModel
    /// already consumes `SettingsStore.modelId` as the request model id.
    var chatModelIds: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for provider in snapshot.providers {
            for model in provider.models where model.type == ModelType.chat {
                let modelId = model.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelId.isEmpty else { continue }
                guard seen.insert(modelId).inserted else { continue }
                ids.append(modelId)
            }
        }
        return ids
    }

    /// Real KMP default assistants (DEFAULT_ASSISTANTS), with branding applied.
    var assistants: [Assistant] {
        snapshot.assistants
    }

    /// Real KMP default search services (a default SearchServiceOptions entry).
    var searchServices: [SearchServiceOptions] {
        snapshot.searchServices
    }

    /// Index of the real seeded default selected search service.
    var searchServiceSelected: Int32 { snapshot.searchServiceSelected }

    /// Real seeded built-in search source toggles + web-search master switch (read-only).
    var enableWebSearch: Bool { snapshot.enableWebSearch }
    var searchBuiltinJinaEnabled: Bool { snapshot.searchBuiltinJinaEnabled }
    var searchBuiltinDuckDuckGoEnabled: Bool { snapshot.searchBuiltinDuckDuckGoEnabled }
    var searchBuiltinBingEnabled: Bool { snapshot.searchBuiltinBingEnabled }
    var searchBuiltinWikipediaEnabled: Bool { snapshot.searchBuiltinWikipediaEnabled }
    var searchBuiltinHackerNewsEnabled: Bool { snapshot.searchBuiltinHackerNewsEnabled }
    var searchGoogleWebViewFallbackEnabled: Bool { snapshot.searchGoogleWebViewFallbackEnabled }

    /// iOS search tools return at most ten results, including restored settings.
    var searchResultSize: Int { min(max(Int(snapshot.searchCommonOptions.resultSize), 1), 10) }

    /// Real default display setting.
    var displaySetting: DisplaySetting {
        snapshot.displaySetting
    }

    /// Real default agent-runtime setting (council/subagent/memory/miniApp/etc.
    /// default config). Read-only display; iOS cannot execute any of these yet.
    var agentRuntime: AgentRuntimeSetting {
        snapshot.agentRuntime
    }

    // MARK: - Scalar model-id pointers (Uuids into providers' models)

    /// Seeded image-generation model pointer (Uuid). NOTE: in the seed snapshot
    /// these modelIds are freshly random Uuids that may not resolve to a real
    /// model in any provider — display as a pointer only, do not assume a label.
    var imageGenerationModelId: KotlinUuid { snapshot.imageGenerationModelId }
    var titleModelId: KotlinUuid { snapshot.titleModelId }
    var suggestionModelId: KotlinUuid { snapshot.suggestionModelId }
    var ocrModelId: KotlinUuid { snapshot.ocrModelId }
    var compressModelId: KotlinUuid { snapshot.compressModelId }
}
