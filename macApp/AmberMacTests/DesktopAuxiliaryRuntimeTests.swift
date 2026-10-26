import XCTest
@testable import AmberMac

@MainActor final class DesktopAuxiliaryRuntimeTests: XCTestCase {
    private func settings() -> DesktopSettings {
        DesktopSettings(defaults: UserDefaults(suiteName: "amber.auxiliary-test." + UUID().uuidString)!, credentials: DesktopMemoryCredentials())
    }

    func testVisualRoutingUsesConfiguredModelAndItsProviderWithoutChangingChatSelection() throws {
        let settings = settings()
        let text = DesktopModelConfiguration(modelID: "text", supportsVision: false)
        let image = DesktopModelConfiguration(modelID: "vision", supportsVision: true)
        let provider = DesktopProviderConfiguration(name: "Local", kind: .openAI, baseURL: "http://localhost:1234/v1", modelID: "text")
        var configured = provider
        configured.models = [text, image]; configured.selectedModelID = text.id
        try settings.saveProvider(configured, apiKey: "")
        settings.selectModel(text.id)
        XCTAssertThrowsError(try DesktopAuxiliaryRouting.chatConfiguration(settings: settings, hasImages: true))
        settings.setAuxiliaryModel(image.id, for: .vision)
        XCTAssertEqual(try DesktopAuxiliaryRouting.chatConfiguration(settings: settings, hasImages: true)?.selectedModelID, image.id)
        XCTAssertEqual(try DesktopAuxiliaryRouting.chatConfiguration(settings: settings, hasImages: false)?.selectedModelID, text.id)
        XCTAssertEqual(settings.selectedModelID, text.id)
        settings.selectModel(image.id)
        XCTAssertEqual(try DesktopAuxiliaryRouting.chatConfiguration(settings: settings, hasImages: true)?.selectedModelID, image.id)
    }

    func testTitleUsesProvidedModelAndLeavesMetadataUntilAcceptedCompleteOutput() async throws {
        let titles = DesktopTitleGeneration()
        let provider = TitleProvider()
        let conversation = DesktopConversation(title: "Old", messages: [.init(role: .user, text: "summarize this conversation")])
        let config = DesktopProviderConfiguration(name: "Title", kind: .openAI, baseURL: "http://localhost:1234/v1", modelID: "title-model")
        var title = conversation.title
        let task = titles.generate(conversation: conversation, configuration: config, apiKey: "", provider: provider) { title = $0; return true }
        await Task.yield()
        XCTAssertEqual(provider.model, "title-model")
        XCTAssertEqual(title, "Old")
        provider.run?.yield(.snapshot(text: "“准确标题”\nextra explanation", reasoning: ""))
        provider.run?.yield(.complete)
        await task?.value
        XCTAssertEqual(title, "准确标题")
        XCTAssertFalse(titles.activeOwners.contains(conversation.id))
        let next = titles.generate(conversation: conversation, configuration: config, apiKey: "", provider: provider) { _ in XCTFail("Cancelled title cannot replace metadata"); return true }
        await Task.yield()
        titles.cancel(conversation.id)
        provider.run?.yield(.snapshot(text: "late title", reasoning: ""))
        provider.run?.yield(.complete)
        await next?.value
        XCTAssertNil(titles.errors[conversation.id])
        let started = provider.startCount
        let immediate = titles.generate(conversation: conversation, configuration: config, apiKey: "", provider: provider) { _ in XCTFail(); return true }
        titles.cancel(conversation.id)
        await immediate?.value
        XCTAssertEqual(provider.startCount, started, "Cancelling before scheduling must not start a provider request")
    }

    func testSearchPreferencesKeepKeyInCredentialStoreAndReachRequestSnapshot() throws {
        let defaults = UserDefaults(suiteName: "amber.search-test." + UUID().uuidString)!
        let credentials = DesktopMemoryCredentials()
        let search = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        try search.save(service: .tavily, resultCount: 4, apiKey: "fixture-secret")
        XCTAssertFalse(String(decoding: defaults.data(forKey: "desktop.search.v1")!, as: UTF8.self).contains("fixture-secret"))
        let reloaded = DesktopSearchSettings(defaults: defaults, credentials: credentials)
        let object = try JSONSerialization.jsonObject(with: Data(reloaded.requestJSON().utf8)) as! [String: Any]
        let service = (object["searchServices"] as! [[String: Any]])[0]
        XCTAssertEqual(service["type"] as? String, "tavily")
        XCTAssertEqual(service["apiKey"] as? String, "fixture-secret")
        XCTAssertEqual((object["searchCommonOptions"] as? [String: Int])?["resultSize"], 4)
        XCTAssertEqual(object["searchGoogleWebViewFallbackEnabled"] as? Bool, false)
        XCTAssertThrowsError(try search.save(service: .brave, resultCount: 5, apiKey: ""))
        XCTAssertEqual(search.service, .tavily)
        try credentials.delete(id: DesktopSearchService.tavily.credentialID)
        XCTAssertThrowsError(try reloaded.requestJSON())
    }

    func testWorkspaceImageRequestConsumesTheVisionProviderKeyWithoutChangingSelection() async throws {
        let settings = settings()
        let chat = DesktopModelConfiguration(modelID: "chat", supportsVision: false)
        let vision = DesktopModelConfiguration(modelID: "vision", supportsVision: true)
        let chatProvider = DesktopProviderConfiguration(name: "Chat", kind: .openAI,
            baseURL: "https://chat.example.test/v1", models: [chat])
        let visionProvider = DesktopProviderConfiguration(name: "Vision", kind: .openAI,
            baseURL: "https://vision.example.test/v1", models: [vision])
        try settings.saveProvider(chatProvider, apiKey: "chat-key")
        try settings.saveProvider(visionProvider, apiKey: "vision-key")
        settings.selectModel(chat.id); settings.setAuxiliaryModel(vision.id, for: .vision)
        let conversation = DesktopConversation(messages: [.init(role: .user, text: "describe image",
            images: [.init(url: "data:image/png;base64,fixture", name: "picture")])])
        let provider = TitleProvider()
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider, initialConversations: [conversation])
        workspace.draft = "continue"; workspace.send()
        XCTAssertEqual(provider.model, "vision")
        XCTAssertEqual(provider.apiKey, "vision-key")
        XCTAssertEqual(settings.selectedModelID, chat.id)
        workspace.stop(); _ = await workspace.flush()
    }

    func testWorkspaceTitlePersistsToCapturedOwnerAndCannotOverwriteManualRename() async throws {
        let settings = settings()
        let title = DesktopModelConfiguration(modelID: "title-model")
        let config = DesktopProviderConfiguration(name: "Title", kind: .openAI,
            baseURL: "https://title.example.test/v1", models: [title])
        try settings.saveProvider(config, apiKey: "title-key")
        settings.setAuxiliaryModel(title.id, for: .title)
        let owner = DesktopConversation(title: "Original", messages: [.init(role: .user, text: "request")])
        let other = DesktopConversation(title: "Other")
        let storage = DesktopMemoryConversationStorage([owner, other]), provider = TitleProvider()
        let workspace = DesktopWorkspace(settings: settings, storage: storage, provider: provider, initialConversations: [owner, other])
        let run = workspace.generateTitle(owner.id)
        workspace.select(other.id)
        await Task.yield()
        XCTAssertEqual(provider.apiKey, "title-key")
        provider.run?.yield(.snapshot(text: "Generated", reasoning: "")); provider.run?.yield(.complete)
        await run?.value
        _ = await workspace.flush()
        XCTAssertEqual(storage.values.first(where: { $0.id == owner.id })?.title, "Generated")
        XCTAssertEqual(workspace.selectedID, other.id)
        let second = workspace.generateTitle(owner.id)
        await Task.yield()
        workspace.rename(owner.id, title: "Manual")
        provider.run?.yield(.snapshot(text: "Late title", reasoning: "")); provider.run?.yield(.complete)
        await second?.value
        _ = await workspace.flush()
        XCTAssertEqual(storage.values.first(where: { $0.id == owner.id })?.title, "Manual")
        XCTAssertNotNil(workspace.titles.errors[owner.id])
        workspace.select(owner.id)
        XCTAssertNotNil(workspace.errorMessage)
        let retry = workspace.generateTitle(owner.id)
        XCTAssertNil(workspace.errorMessage, "Retry only clears the error owned by the preceding title operation")
        await Task.yield()
        provider.run?.yield(.snapshot(text: "Retry title", reasoning: "")); provider.run?.yield(.complete)
        await retry?.value
        _ = await workspace.flush()
        XCTAssertEqual(storage.values.first(where: { $0.id == owner.id })?.title, "Retry title")
        XCTAssertNil(workspace.errorMessage)
    }
}

@MainActor private final class TitleProvider: DesktopTextProvider {
    var run: DesktopGeneration?
    var model: String?
    var startCount = 0
    var apiKey: String?
    func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
        model = configuration.modelID
        startCount += 1
        self.apiKey = apiKey
        let run = DesktopGeneration(); self.run = run
        return run
    }
}
