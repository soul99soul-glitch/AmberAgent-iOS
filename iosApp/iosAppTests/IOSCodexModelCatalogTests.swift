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
        let languageKey = IOSAppLanguagePreference.defaultsKey
        let previousLanguage = UserDefaults.standard.object(forKey: languageKey)
        UserDefaults.standard.set("zh-Hans", forKey: languageKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: languageKey) }
            else { UserDefaults.standard.removeObject(forKey: languageKey) }
        }
        let settings = IOSSharedSettingsStore(userDefaults: defaults)
        struct EmptyKeyStore: SettingsAPIKeyStore {
            func loadApiKey() -> String? { nil }
            func saveApiKey(_ key: String) -> Bool { true }
        }
        let legacy = SettingsStore(userDefaults: defaults, apiKeyStore: EmptyKeyStore())
        let registry = ProviderRegistryStore(settingsStore: legacy, userDefaults: defaults,
            keyNamespace: suite, keychainPrefix: suite)
        let provider = settings.addProvider(IosSettingsMutations.shared.buildOpenAIProvider(
            name: "Provider Review · 自定义 OpenAI 兼容服务商", apiKey: "",
            baseUrl: "https://gateway.example.test/region/team/openai/v1",
            modelName: "GPT-6-Astra · 自定义推理模型", modelId: "gpt-6-astra"))
        let providerID = provider.id.description()
        settings.setCurrentChatModelId(try XCTUnwrap(provider.models.first).id.description())
        _ = settings.upsertProviderImageModel(providerId: providerID,
            modelId: "gpt-image-2.5-sunburst", displayName: "GPT Image 2.5 Sunburst")
        _ = settings.upsertProviderChatModel(providerId: providerID, modelUuid: nil,
            modelId: "text-embedding-3-small", displayName: "Embedding", contextWindowTokens: nil,
            modelType: .embedding, headers: [])
        let image = try XCTUnwrap(settings.snapshot.providers.first { $0.id == provider.id }?.models.first { $0.type == .image })
        settings.setImageGenerationModelId(image.id.description())
        let raw = IosSettingsJsonBridge.shared.encode(settings: settings.snapshot)
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        fixture["providers"] = (fixture["providers"] as? [[String: Any]])?.filter { $0["id"] as? String == providerID }
        settings.restoreSnapshot(try IosSettingsJsonBridge.shared.decode(
            json: String(decoding: JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let pages: [(String, AnyView)] = [
            ("providers", AnyView(ProvidersView(settingsStore: legacy, providerRegistry: registry, sharedSettings: settings))),
            ("provider-config", AnyView(ProviderDetailView(settingsStore: legacy, providerRegistry: registry,
                sharedSettings: settings, providerId: providerID))),
            ("provider-models", AnyView(ProviderDetailView(settingsStore: legacy, providerRegistry: registry,
                sharedSettings: settings, providerId: providerID, initiallyShowsModels: true))),
            ("provider-add", AnyView(ProviderAddView(settingsStore: legacy, providerRegistry: registry, sharedSettings: settings))),
            ("provider-defaults", AnyView(ModelDefaultsView(settingsStore: legacy, sharedSettings: settings))),
            ("provider-codex-login", AnyView(CodexLoginView(providerId: providerID,
                onAuthModeChange: { _ in }, onModelsFetched: { _ in }))),
        ]
        for (suffix, size, type) in [
            ("normal", CGSize(width: 393, height: 852), DynamicTypeSize.large),
            ("narrow-large", CGSize(width: 320, height: 760), DynamicTypeSize.accessibility1),
        ] {
            for (name, page) in pages {
                let window = UIWindow(windowScene: scene)
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKey()
                }
                let captureSize = name == "provider-models" && suffix == "narrow-large"
                    ? CGSize(width: size.width, height: 1_400) : size
                window.frame = CGRect(origin: .zero, size: captureSize)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = UIHostingController(rootView: NavigationStack { page }
                    .environment(RouterPath())
                    .environment(\.locale, Locale(identifier: "zh_Hans"))
                    .environment(\.dynamicTypeSize, type)
                    .defaultAppStorage(defaults))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let filename = "\(name)-\(suffix)"
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = filename
                attachment.lifetime = .keepAlways
                add(attachment)
                let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(filename).png")
                try XCTUnwrap(screenshot.pngData()).write(to: path)
                print("PROVIDER_UI_EVIDENCE \(path.path)")
            }
        }
    }
}
