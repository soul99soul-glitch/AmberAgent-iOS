import XCTest
import SwiftUI
import Observation
@preconcurrency import Shared
@testable import iosApp


@MainActor
class IOSCouncilMechanicsTestCase: XCTestCase {
    func runChatCouncilTool(
        outputs: [Result<String, Error>],
        toolCallId: String
    ) async -> [String: Any] {
        let defaults = isolatedDefaults()
        let roomSettingsStore = IOSCouncilRoomSettingsStore(
            userDefaults: defaults,
            storageKey: "tool-live-room-settings",
            currentModelId: "gpt-main"
        )
        roomSettingsStore.settings = compactRoomSettings(defaultRounds: 1)
        roomSettingsStore.dynamicSeatGeneration = false
        let models = ["gpt-main", "gpt-host", "gpt-engineer", "gpt-risk"].map(makeCouncilModel)
        let currentModel = models[0]
        let runner = CouncilRunner(
            taskStore: IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks"),
            roomSettingsStore: roomSettingsStore,
            roomStreamer: ScriptedCouncilStreamer(outputs)
        )
        let text = await runner.run(
            objective: "验证过程可见",
            providerSetting: makeCouncilProvider(models: models),
            currentModel: currentModel,
            baseParams: TextGenerationParams(
                model: currentModel,
                temperature: nil,
                topP: nil,
                maxTokens: nil,
                tools: [],
                reasoningLevel: .off,
                customHeaders: [],
                customBody: []
            ),
            toolCallId: toolCallId
        )
        let data = Data(text.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func compactRoomSettings(
        currentModelId: String = "gpt-main",
        defaultRounds: Int = 2
    ) -> IOSCouncilRoomSettings {
        IOSCouncilRoomSettings(
            host: IOSCouncilHostConfig(
                modelId: "gpt-host",
                reasoning: .off,
                prompt: "主持人只做议题组织和总结。"
            ),
            seats: [
                IOSCouncilRoomSeatConfig(
                    id: "engineering",
                    name: "工程",
                    rolePrompt: "工程实现",
                    modelId: "gpt-engineer",
                    reasoning: .medium,
                    prompt: "短句",
                    isDefault: true
                ),
                IOSCouncilRoomSeatConfig(
                    id: "risk",
                    name: "风险",
                    rolePrompt: "风险审计",
                    modelId: "gpt-risk",
                    reasoning: .high,
                    prompt: "指出缺口",
                    isDefault: true
                )
            ],
            limits: IOSCouncilRoomLimits(
                maxSeats: 2,
                defaultRounds: defaultRounds,
                seatTimeoutSeconds: 30,
                outputBudgetCharacters: 6_000
            ),
            legacySeatsImported: true
        ).normalized(currentModelId: currentModelId)
    }

    func makeCouncilModel(_ modelId: String) -> Model {
        makeCouncilModel(modelId, providerOverwrite: nil)
    }

    func makeCouncilModel(
        _ modelId: String,
        providerOverwrite: ProviderSetting?
    ) -> Model {
        Model(
            modelId: modelId,
            displayName: modelId,
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [ModelAbility.reasoning],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: providerOverwrite
        )
    }

    func makeCouncilProvider(
        name: String = "Council Test Provider",
        models: [Model]
    ) -> ProviderSetting {
        ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: name,
            models: models,
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "test-key",
            baseUrl: "https://example.com/v1",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }

    func roomRequest(
        mode: IOSCouncilRoomRunMode = .freeChat,
        settings: IOSCouncilRoomSettings,
        apiKey: String = "test-key",
        researchConsent: IOSCouncilResearchConsent = .unavailable,
        providerSetting: ProviderSetting? = nil,
        providerSettings: [ProviderSetting] = [],
        currentModel: Model? = nil
    ) -> IOSCouncilRoomRunRequest {
        IOSCouncilRoomRunRequest(
            objective: "完善 iOS 模型议会",
            mode: mode,
            settings: settings,
            currentModelId: "gpt-main",
            currentModel: currentModel,
            providerSetting: providerSetting ?? IOSCouncilRoomRunner.makeProviderSetting(
                baseUrl: "https://example.com/v1",
                apiKey: apiKey
            ),
            providerSettings: providerSettings,
            searchSettings: nil,
            researchConsent: researchConsent
        )
    }

    func roomSpeaker(id: String, name: String, modelId: String) -> IOSCouncilRoomSpeaker {
        IOSCouncilRoomSpeaker(
            id: id,
            name: name,
            rolePrompt: "\(name)职责",
            modelId: modelId,
            reasoning: .medium,
            prompt: "",
            isHost: false
        )
    }

    func makeViewModelHarness(
        streamer: any IOSCouncilTextStreaming,
        researcher: any IOSCouncilResearching = StaticCouncilResearcher(),
        durableRunAwaiter: @escaping CouncilChatViewModel.DurableRunAwaiter = { _, operation in await operation() }
    ) throws -> (
        viewModel: CouncilChatViewModel,
        archiveStore: CouncilRoomArchiveStore,
        archiveBaseDirectory: URL,
        taskStore: IOSAdvancedTaskStore,
        sharedSettings: IOSSharedSettingsStore,
        defaults: UserDefaults
    ) {
        let defaults = isolatedDefaults()
        let taskStore = IOSAdvancedTaskStore(userDefaults: defaults, storageKey: "tasks")
        let permissionStore = IOSPermissionStore(
            userDefaults: defaults,
            storageKey: "policies",
            approvalStorageKey: "approvals",
            taskStore: taskStore
        )
        let runner = IOSCouncilRoomRunner(
            streamer: streamer,
            researcher: researcher,
            taskStore: taskStore,
            permissionStore: permissionStore
        )
        let settingsStore = SettingsStore(
            userDefaults: defaults,
            storageKey: "legacy-settings",
            apiKeyStore: CouncilTestAPIKeyStore(key: "test-key")
        )
        let sharedSettings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Council Test Provider",
            apiKey: "test-key",
            baseUrl: "https://example.com/v1",
            modelName: "Council Test Model",
            modelId: "gpt-main"
        )
        _ = sharedSettings.addProvider(provider)
        let model = try XCTUnwrap(
            sharedSettings.availableChatModels().first { $0.providerName == "Council Test Provider" }
        )
        sharedSettings.setCurrentChatModelId(model.id)
        let roomSettings = IOSCouncilRoomSettingsStore(
            userDefaults: defaults,
            storageKey: "room-settings",
            currentModelId: "gpt-main"
        )
        roomSettings.settings = compactRoomSettings(defaultRounds: 1)
        roomSettings.dynamicSeatGeneration = false
        let archiveBaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-vm-test-\(UUID().uuidString)", isDirectory: true)
        let archiveStore = CouncilRoomArchiveStore(baseDirectory: archiveBaseDirectory)
        let viewModel = CouncilChatViewModel(
            settingsStore: settingsStore,
            sharedSettings: sharedSettings,
            providerRegistry: nil,
            permissionStore: permissionStore,
            roomSettingsStore: roomSettings,
            runner: runner,
            transcriptDefaults: defaults,
            archiveStore: archiveStore,
            durableRunAwaiter: durableRunAwaiter
        )
        return (
            viewModel,
            archiveStore,
            archiveBaseDirectory,
            taskStore,
            sharedSettings,
            defaults
        )
    }

    func sourceBlock(_ source: String, from startNeedle: String, to endNeedle: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startNeedle))
        let end = try XCTUnwrap(source.range(of: endNeedle, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func assertOrdered(_ source: String, _ needles: String...) {
        let offsets = needles.compactMap { source.range(of: $0)?.lowerBound }
        XCTAssertEqual(offsets.count, needles.count)
        XCTAssertEqual(offsets, offsets.sorted())
    }

    func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.council.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
