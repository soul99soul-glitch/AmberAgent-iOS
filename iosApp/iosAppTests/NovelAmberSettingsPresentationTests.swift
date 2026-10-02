import XCTest
@testable import iosApp

/// Novel model presentation against Amber's own seeded `IOSSharedSettingsStore`
/// (provider basics, current chat model). Amber-only: the standalone Novel app
/// has its own settings store and does not compile this file.
@MainActor
final class NovelAmberSettingsPresentationTests: XCTestCase {
    func testModelSelectionResolvesStableOwnerWithoutChangingGlobalChatModel() async throws {
        let suite = "NovelModelPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let globalModelIDBefore = settings.snapshot.getCurrentChatModel()?.id.description()
        let provider = try XCTUnwrap(settings.snapshot.providers.first { !$0.models.isEmpty })
        let model = try XCTUnwrap(provider.models.first)
        let providerID = provider.id.description()
        let modelID = model.id.description()

        XCTAssertEqual(
            NovelPresentation.providerID(forModelID: modelID, sharedSettings: settings),
            providerID
        )

        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        _ = await viewModel.createProject(name: "模型隔离", mode: .blank)
        await viewModel.setModelPolicy(.fixed(providerID: providerID, modelID: modelID))

        XCTAssertEqual(
            viewModel.projectSnapshot?.project.modelPolicy,
            .fixed(providerID: providerID, modelID: modelID)
        )
        XCTAssertEqual(settings.snapshot.getCurrentChatModel()?.id.description(), globalModelIDBefore)
    }

    func testDisabledOrMismatchedProviderDoesNotPresentItsFixedModelAsAvailable() throws {
        let suite = "NovelModelAvailabilityPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let option = try XCTUnwrap(settings.availableChatModels().first)
        let provider = try XCTUnwrap(settings.snapshot.providers.first { provider in
            provider.models.contains { $0.id.description() == option.id }
        })
        let providerID = provider.id.description()
        let modelID = option.id

        _ = settings.updateProviderBasics(
            providerId: providerID,
            name: provider.name,
            enabled: true
        )
        settings.setCurrentChatModelId(modelID)
        let selectedModel = try XCTUnwrap(provider.models.first {
            $0.id.description() == modelID
        })
        let selectedName = selectedModel.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            NovelPresentation.modelDisplayName(for: .global, sharedSettings: settings),
            selectedName.isEmpty ? selectedModel.modelId : selectedName
        )

        XCTAssertEqual(
            NovelPresentation.modelDisplayName(
                for: .fixed(providerID: "missing-provider", modelID: modelID),
                sharedSettings: settings
            ),
            "固定模型不可用"
        )

        _ = settings.updateProviderBasics(
            providerId: providerID,
            name: provider.name,
            enabled: false
        )
        XCTAssertEqual(
            NovelPresentation.modelDisplayName(
                for: .fixed(providerID: providerID, modelID: modelID),
                sharedSettings: settings
            ),
            "固定模型不可用"
        )

        settings.setCurrentChatModelId(modelID)
        XCTAssertEqual(
            NovelPresentation.modelDisplayName(for: .global, sharedSettings: settings),
            "全局模型不可用"
        )
    }
}
