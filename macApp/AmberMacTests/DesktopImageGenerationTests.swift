import XCTest
import Observation
@testable import AmberMac

@MainActor final class DesktopImageGenerationTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j9ZkAAAAASUVORK5CYII="

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "amber.image.tests." + UUID().uuidString)! }
    private func settings() throws -> (DesktopSettings, DesktopProviderConfiguration) {
        let settings = DesktopSettings(defaults: defaults(), credentials: DesktopMemoryCredentials())
        let provider = DesktopProviderConfiguration(name: "Image fixture", kind: .openAI,
            baseURL: "https://image.example.test/v1", modelID: "image-fixture")
        try settings.saveProvider(provider, apiKey: "fixture-key")
        return (settings, provider)
    }

    func testActualRepositoryRequestSavesAnImageToTheCapturedOwnerAndCleansStaging() async throws {
        let (settings, provider) = try settings()
        settings.setAuxiliaryModel(provider.selectedModelID, for: .imageGeneration)
        let root = directory(), staging = directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let files = DesktopWorkspaceFiles(directory: root)
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let transport = ImageFixtureTransport(body: try json(["data": [["b64_json": png, "mime_type": "image/png"]]]))
        let generator = DesktopImageGeneration(settings: settings, files: files, enabled: true,
            history: history, stagingDirectory: staging, transport: transport)
        let owner = UUID(), other = UUID()
        let result = try await generator.generate(ownerID: owner, prompt: "Amber lamp", aspectRatio: .landscape, count: 2, style: "ink")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://image.example.test/v1/images/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "image-fixture")
        XCTAssertEqual(body["n"] as? Int, 2)
        XCTAssertEqual(body["size"] as? String, "1536x1024")
        XCTAssertEqual(body["prompt"] as? String, "Amber lamp\nStyle: ink")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.document.kind, .image)
        XCTAssertTrue(result.first?.document.image?.dataURL.hasPrefix("data:image/png;base64,") == true)
        let saved = try await files.list(conversationID: owner)
        let untouched = try await files.list(conversationID: other)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(untouched.isEmpty)
        XCTAssertEqual(generator.ownerID, owner)
        XCTAssertFalse(generator.isRunning)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testFailedWorkspaceSaveRetainsRemoteImageAndRetriesWithoutAnotherRequest() async throws {
        let (settings, provider) = try settings()
        settings.setAuxiliaryModel(provider.selectedModelID, for: .imageGeneration)
        let root = directory(), staging = directory(), owner = UUID()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        try Data("blocked workspace root".utf8).write(to: root)
        let files = DesktopWorkspaceFiles(directory: root)
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let transport = ImageFixtureTransport(body: try json(["data": [["b64_json": png, "mime_type": "image/png"]]]))
        let generator = DesktopImageGeneration(settings: settings, files: files, enabled: true,
            history: history, stagingDirectory: staging, transport: transport)
        do { _ = try await generator.generate(ownerID: owner, prompt: "Lamp"); XCTFail("Workspace must fail") } catch {}
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(generator.hasPendingSave(for: owner))
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.source, "macos:" + owner.uuidString)
        let original = try XCTUnwrap(record.files.first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original.path)), Data(base64Encoded: png))
        do { _ = try await generator.generate(ownerID: owner, prompt: "Do not regenerate"); XCTFail("Save pending result first") } catch {}
        XCTAssertEqual(transport.requests.count, 1)
        try FileManager.default.removeItem(at: root)
        let result = try await generator.retrySaving(ownerID: owner)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(generator.hasPendingSave(for: owner))
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let saved = try await files.read(conversationID: owner, path: result[0].file.id)
        XCTAssertEqual(saved, Data(base64Encoded: png))
    }

    func testReopenRecoversOriginalOwnerAndDoesNotCleanAnotherOwnersPendingImage() async throws {
        let (settings, _) = try settings()
        let root = directory(), staging = directory(), owner = UUID(), other = UUID()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let historyDefaults = defaults()
        let history = IOSImageGenerationHistoryStore(userDefaults: historyDefaults)
        let first = try pendingRecord(owner: owner, staging: staging, names: ["first.png"])
        let second = try pendingRecord(owner: other, staging: staging, names: ["other.png"])
        history.insert(first); history.insert(second)
        let reopenedHistory = IOSImageGenerationHistoryStore(userDefaults: historyDefaults)
        let transport = ImageFixtureTransport(body: Data())
        let files = DesktopWorkspaceFiles(directory: root)
        let generator = DesktopImageGeneration(settings: settings, files: files, enabled: true,
            history: reopenedHistory, stagingDirectory: staging, transport: transport)
        XCTAssertEqual(generator.pendingSaveCount(for: owner), 1)
        XCTAssertEqual(generator.pendingSaveCount(for: other), 1)
        _ = try await generator.retrySaving(ownerID: owner)
        XCTAssertEqual(generator.ownerID, owner)
        XCTAssertEqual(reopenedHistory.records.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.files[0].path))
        XCTAssertTrue(transport.requests.isEmpty)

        let remainingConversation = DesktopConversation()
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([remainingConversation]),
            provider: ImageTestTextProvider(), initialConversations: [remainingConversation], files: files, imageGeneration: generator)
        do { _ = try await workspace.retryGeneratedImageSaving(ownerID: other); XCTFail("Deleted original owner must not be recreated") } catch {}
        let otherFiles = try await files.list(conversationID: other)
        XCTAssertTrue(otherFiles.isEmpty)
        XCTAssertEqual(generator.pendingSaveCount(for: other), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.files[0].path))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testPartialLocalSaveRetriesOnlyRemainingImages() async throws {
        let (settings, _) = try settings()
        let root = directory(), heldRoot = directory(), staging = directory(), owner = UUID()
        defer {
            try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: heldRoot)
            try? FileManager.default.removeItem(at: staging)
        }
        let files = DesktopWorkspaceFiles(directory: root)
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let record = try pendingRecord(owner: owner, staging: staging, names: ["first.png", "remaining.png"])
        history.insert(record)
        let transport = ImageFixtureTransport(body: Data())
        let generator = DesktopImageGeneration(settings: settings, files: files, enabled: true,
            history: history, stagingDirectory: staging, transport: transport)
        let pending = Task { try await generator.retrySaving(ownerID: owner) }
        withObservationTracking { _ = generator.artifacts.count } onChange: {
            do {
                // Keep the first durable copy while making the next workspace write fail.
                try FileManager.default.moveItem(at: root, to: heldRoot)
                try Data("blocked workspace root".utf8).write(to: root)
            } catch { XCTFail("Unable to arrange second-write failure: \(error)") }
        }
        do { _ = try await pending.value; XCTFail("Second workspace save must fail") } catch {}
        XCTAssertEqual(generator.artifacts.count, 1)
        XCTAssertEqual(history.records.first?.files.map(\.id), [record.files[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.files[1].path))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: heldRoot, to: root)
        let result = try await generator.retrySaving(ownerID: owner)
        XCTAssertEqual(result.count, 2)
        let saved = try await files.list(conversationID: owner)
        XCTAssertEqual(saved.map(\.id), ["first.png", "remaining.png"])
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCancelAfterFirstLocalSaveKeepsRemainingImagesRecoverable() async throws {
        let (settings, _) = try settings()
        let root = directory(), staging = directory(), owner = UUID()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let files = DesktopWorkspaceFiles(directory: root)
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let record = try pendingRecord(owner: owner, staging: staging, names: ["first.png", "remaining.png"])
        history.insert(record)
        let transport = ImageFixtureTransport(body: Data())
        let generator = DesktopImageGeneration(settings: settings, files: files, enabled: true,
            history: history, stagingDirectory: staging, transport: transport)
        let pending = Task { try await generator.retrySaving(ownerID: owner) }
        withObservationTracking { _ = generator.artifacts.count } onChange: { pending.cancel() }
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(generator.artifacts.count, 1)
        XCTAssertEqual(generator.pendingSaveCount(for: owner), 1)
        XCTAssertEqual(history.records.first?.files.map(\.id), [record.files[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.files[1].path))
        let result = try await generator.retrySaving(ownerID: owner)
        XCTAssertEqual(result.count, 2)
        let saved = try await files.list(conversationID: owner)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    private func pendingRecord(owner: UUID, staging: URL, names: [String]) throws -> IOSImageGenerationRecord {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let files = try names.map { name in
            let url = staging.appendingPathComponent(name)
            try XCTUnwrap(Data(base64Encoded: png)).write(to: url)
            return IOSGeneratedImageFile(id: UUID().uuidString, path: url.path, mimeType: "image/png")
        }
        return IOSImageGenerationRecord(id: UUID().uuidString, prompt: "Lamp", model: "image-fixture", aspectRatio: .square,
            count: files.count, style: "", source: "macos:" + owner.uuidString, files: files, createdAt: 1)
    }

    func testPreviewAndMissingExplicitImageModelCannotDispatchNetwork() async throws {
        let (settings, _) = try settings()
        let transport = ImageFixtureTransport(body: Data())
        let files = DesktopWorkspaceFiles(directory: directory())
        let preview = DesktopImageGeneration(settings: settings, files: files, transport: transport)
        do { _ = try await preview.generate(ownerID: UUID(), prompt: "Lamp"); XCTFail() } catch { }
        XCTAssertFalse(preview.isAvailable)
        let formal = DesktopImageGeneration(settings: settings, files: files, enabled: true, transport: transport)
        do { _ = try await formal.generate(ownerID: UUID(), prompt: "Lamp"); XCTFail() } catch { }
        XCTAssertTrue(transport.requests.isEmpty, "Conversation model fallback must not be used for image generation")
    }

    func testCancellationStopsTheActualTransportAndDoesNotPublishFiles() async throws {
        let (settings, provider) = try settings()
        settings.setAuxiliaryModel(provider.selectedModelID, for: .imageGeneration)
        let root = directory(), staging = directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let files = DesktopWorkspaceFiles(directory: root), owner = UUID()
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let transport = ImageFixtureTransport(body: try json(["data": [["b64_json": png]]]))
        transport.waitForCancellation = true
        let generator = DesktopImageGeneration(settings: settings, files: files, enabled: true,
            history: history, stagingDirectory: staging, transport: transport)
        let pending = Task { try await generator.generate(ownerID: owner, prompt: "Lamp") }
        for _ in 0..<100 { if !transport.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        generator.cancel()
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await generator.shutdown()
        let saved = try await files.list(conversationID: owner)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(generator.isRunning)
        XCTAssertNil(generator.errorMessage)
    }

    func testRetryValidationReplacesThePreviousProviderFailureWithoutAnotherRequest() async throws {
        let (settings, provider) = try settings()
        settings.setAuxiliaryModel(provider.selectedModelID, for: .imageGeneration)
        let root = directory(), staging = directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let transport = ImageFixtureTransport(body: Data("provider-private-body".utf8), statusCode: 500)
        let generator = DesktopImageGeneration(settings: settings, files: DesktopWorkspaceFiles(directory: root), enabled: true,
            history: IOSImageGenerationHistoryStore(userDefaults: defaults()), stagingDirectory: staging, transport: transport)
        do { _ = try await generator.generate(ownerID: UUID(), prompt: "Lamp"); XCTFail() }
        catch { XCTAssertEqual(error as? IOSImageGenerationError, .httpStatus(500, "provider-private-body")) }
        XCTAssertEqual(generator.errorMessage, "图片生成失败：HTTP 500。")
        XCTAssertEqual(transport.requests.count, 1)

        settings.setAuxiliaryModel(nil, for: .imageGeneration)
        do { _ = try await generator.generate(ownerID: UUID(), prompt: "Lamp"); XCTFail() }
        catch {
            XCTAssertTrue(error is DesktopRuntimeError)
            XCTAssertEqual(error.localizedDescription, "请先在设置的辅助任务中选择生图模型。")
        }
        XCTAssertEqual(generator.errorMessage, "请先在设置的辅助任务中选择生图模型。")
        XCTAssertNil(generator.statusMessage)
        XCTAssertFalse(generator.isRunning)
        XCTAssertEqual(transport.requests.count, 1, "Validation failure must not dispatch a retry")
    }

    func testBusyReentryPreservesTheRunningOwnerAndStatus() async throws {
        let (settings, provider) = try settings()
        settings.setAuxiliaryModel(provider.selectedModelID, for: .imageGeneration)
        let root = directory(), staging = directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let transport = ImageFixtureTransport(body: Data())
        transport.waitForCancellation = true
        let generator = DesktopImageGeneration(settings: settings, files: DesktopWorkspaceFiles(directory: root), enabled: true,
            history: IOSImageGenerationHistoryStore(userDefaults: defaults()), stagingDirectory: staging, transport: transport)
        let owner = UUID()
        let pending = Task { try await generator.generate(ownerID: owner, prompt: "Lamp") }
        for _ in 0..<100 { if !transport.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(generator.isRunning)
        let runningStatus = generator.statusMessage
        XCTAssertEqual(runningStatus, "正在生成图片…")
        do { _ = try await generator.generate(ownerID: UUID(), prompt: "Another lamp"); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "图片正在生成，请等待完成或先取消。") }
        XCTAssertTrue(generator.isRunning)
        XCTAssertEqual(generator.ownerID, owner)
        XCTAssertEqual(generator.statusMessage, runningStatus)
        XCTAssertNil(generator.errorMessage)
        XCTAssertEqual(transport.requests.count, 1)
        generator.cancel()
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await generator.shutdown()
    }

    func testActualRepositoryRollsBackEarlierImagesWhenLaterDataIsInvalid() async throws {
        let staging = directory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let repository = IOSImageGenerationRepository(historyStore: history, outputDirectory: staging)
        let transport = ImageFixtureTransport(body: try json(["data": [["b64_json": png], ["b64_json": "!invalid!"]]]))
        do {
            _ = try await repository.generate(request: .init(prompt: "Lamp", model: "image-fixture", aspectRatio: .square,
                count: 2, style: "", source: "test"), apiKey: "fixture-key", baseURL: "https://image.example.test/v1", transport: transport)
            XCTFail()
        } catch { XCTAssertEqual(error as? IOSImageGenerationError, .invalidImageData) }
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty) == true)
    }

    func testOriginalCodexRequestBodyAndPendingResultPollingAreReused() async throws {
        let request = IOSImageGenerationRequest(prompt: "Lamp", model: IOSCodexOAuthConstants.imageModelId,
            aspectRatio: .portrait, count: 1, style: "ink", source: "macos")
        let body = IOSImageGenerationRepository.codexResponsesRequestBody(for: request, routingModel: "gpt-fixture")
        XCTAssertEqual(body["model"] as? String, "gpt-fixture")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "image_generation")
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults())
        let repository = IOSImageGenerationRepository(historyStore: history)
        let transport = ImageFixtureTransport(body: try json(["status": "completed", "output": [["type": "image_generation_call", "result": png]]]))
        let pending = try json(["id": "resp_fixture", "status": "in_progress", "output": []])
        let image = try await repository.resolveCodexImageResult(from: pending, token: "fixture-bearer", accountId: "fixture-account",
            transport: transport, maxPollAttempts: 1, pollDelayNanoseconds: 0)
        XCTAssertEqual(image, png)
        let poll = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(poll.httpMethod, "GET")
        XCTAssertEqual(poll.url?.absoluteString, IOSCodexOAuthConstants.codexBackendBaseUrl + "/responses/resp_fixture")
        XCTAssertEqual(poll.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
        XCTAssertEqual(poll.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture-account")
        XCTAssertEqual(poll.value(forHTTPHeaderField: "originator"), IOSCodexOAuthConstants.originator)
        XCTAssertEqual(poll.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
    }

    func testActualCodexSSEParserReturnsToolImage() async throws {
        let sse = "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image_generation_call\",\"status\":\"completed\",\"result\":\"\(png)\"}}\n\ndata: [DONE]\n\n"
        let transport = ImageFixtureTransport(body: Data(sse.utf8))
        let (_, events) = try await transport.streamEvents(URLRequest(url: URL(string: "https://image.example.test/responses")!))
        let repository = IOSImageGenerationRepository(historyStore: IOSImageGenerationHistoryStore(userDefaults: defaults()))
        let result = try await repository.resolveCodexImageResult(fromEvents: events)
        XCTAssertEqual(result, png)
    }

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

@MainActor private final class ImageTestTextProvider: DesktopTextProvider {
    func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration { DesktopGeneration() }
}

@MainActor private final class ImageFixtureTransport: IOSImageGenerationHTTPTransport {
    let body: Data
    var requests: [URLRequest] = []
    var waitForCancellation = false
    let statusCode: Int
    init(body: Data, statusCode: Int = 200) { self.body = body; self.statusCode = statusCode }
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests.append(request)
        if waitForCancellation { try await Task.sleep(for: .seconds(30)) }
        return (HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, body)
    }
}
