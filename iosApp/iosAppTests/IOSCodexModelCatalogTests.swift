import XCTest
import SwiftUI
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSCodexModelCatalogTests: XCTestCase {
    func testLiveCatalogExcludesHiddenModelsAndStaleRouter() throws {
        let data = Data(#"{"models":[{"slug":"gpt-6-astra","visibility":"list"},{"slug":"gpt-reserve","visibility":"hide"},{"slug":"gpt-5.6-sol","visibility":"list"}]}"#.utf8)
        let ids = IOSCodexOAuthClient.parseModels(data).map(\.modelId)
        XCTAssertEqual(ids, ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(try IOSCodexOAuthClient.imageRoutingModel(availableModelIDs: ids,
            preferredModelID: "gpt-5.4"), "gpt-6-astra")
        XCTAssertEqual(try IOSCodexOAuthClient.imageRoutingModel(availableModelIDs: ids,
            preferredModelID: "gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertThrowsError(try IOSCodexOAuthClient.imageRoutingModel(
            availableModelIDs: ["gpt-image-2.5-sunburst"], preferredModelID: "gpt-5.4"))
    }

    func testImagePresetsAndRefreshPreserveSelectedModelThroughReload() throws {
        let suite = "CodexModelCatalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = settings.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Codex", apiKey: "", baseUrl: IOSCodexOAuthConstants.codexBackendBaseUrl,
            modelName: "GPT-6-Astra", modelId: "gpt-6-astra"))
        let providerID = provider.id.description()
        let discovered = [(modelId: "gpt-6-astra", displayName: "GPT-6-Astra"),
                          (modelId: "gpt-image-2.5-sunburst", displayName: "Discovered Sunburst")]
        let choices = IOSCodexModelCatalog.models(discovered: discovered)
        XCTAssertEqual(choices.filter { $0.modelId == "gpt-image-2.5-sunburst" }.count, 1)
        XCTAssertEqual(choices.filter { $0.type == .image }.count, 4)
        XCTAssertFalse(choices.contains { $0.type == .chat && $0.modelId.contains("image") })

        let first = try XCTUnwrap(settings.mergeCodexModels(providerId: providerID, discovered: discovered))
        let image = try XCTUnwrap(first.models.first { $0.modelId == "gpt-image-2.5-sunburst" })
        settings.setImageGenerationModelId(image.id.description())
        _ = settings.mergeCodexModels(providerId: providerID, discovered: discovered)
        let reloaded = IOSSharedSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.snapshot.imageGenerationModelId, image.id)
        let saved = try XCTUnwrap(reloaded.snapshot.findModelById(uuid: image.id))
        XCTAssertEqual(saved.type, .image)
        XCTAssertEqual(saved.modelId, "gpt-image-2.5-sunburst")
        XCTAssertEqual(saved.displayName, "Discovered Sunburst")
    }

    func testProviderModelPageShowsImageAndEmbeddingChoices() async throws {
        let suite = "ProviderModelPage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        let legacy = SettingsStore(userDefaults: defaults)
        let registry = ProviderRegistryStore(settingsStore: legacy, userDefaults: defaults)
        let provider = settings.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Codex", apiKey: "", baseUrl: IOSCodexOAuthConstants.codexBackendBaseUrl,
            modelName: "GPT-6-Astra", modelId: "gpt-6-astra"))
        let providerID = provider.id.description()
        _ = settings.upsertProviderImageModel(providerId: providerID,
            modelId: "gpt-image-2.5-sunburst", displayName: "GPT Image 2.5 Sunburst")
        _ = settings.upsertProviderChatModel(providerId: providerID, modelUuid: nil,
            modelId: "text-embedding-3-small", displayName: "Embedding", contextWindowTokens: nil,
            modelType: .embedding, headers: [])
        let image = try XCTUnwrap(settings.snapshot.providers.first { $0.id == provider.id }?.models.first { $0.type == .image })
        settings.setImageGenerationModelId(image.id.description())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: ProviderDetailView(
            settingsStore: legacy, providerRegistry: registry, sharedSettings: settings,
            providerId: providerID, initiallyShowsModels: true)
            .environment(\.locale, Locale(identifier: "zh_Hans")))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(650))
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "provider-chat-image-embedding-models"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
