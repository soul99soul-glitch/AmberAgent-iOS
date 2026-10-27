import AppKit
import SwiftUI

extension AmberOffscreenMain {
    @MainActor static func capturePhase2States() async throws {
        let defaults = UserDefaults(suiteName: "amber.review.phase2." + UUID().uuidString)!
        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        let config = DesktopProviderConfiguration(name: "本地界面验证", kind: .openAI,
            baseURL: "https://example.test/v1", modelID: "fixture-no-network")
        try settings.saveProvider(config, apiKey: "fixture-only")
        settings.setAuxiliaryModel(config.selectedModelID, for: .imageGeneration)
        let old = DesktopMessage(role: .assistant, text: "这是上一轮已经完整保存的回答。取消下一轮时应保持完成状态。", state: .complete)
        let cancelled = DesktopMessage(role: .assistant, text: "", state: .cancelled)
        let value = DesktopConversation(title: "已取消排队请求 · 原回复保持完成", messages: [
            DesktopMessage(role: .user, text: "上一轮的问题"), old,
            DesktopMessage(role: .user, text: "这条排队请求已保存，但准备阶段被停止。"), cancelled])
        let provider = ReviewNoNetworkProvider()
        let queueWorkspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([value]),
            provider: provider, initialConversations: [value])
        assert(queueWorkspace.selectedConversation?.messages[1].state == .complete)
        assert(queueWorkspace.selectedConversation?.messages.last?.state == .cancelled)
        try await capture("phase2-cancelled-steer-860-light", view: DesktopWorkspaceView(workspace: queueWorkspace, searchRequest: 0), width: 860, height: 600, dark: false)
        try await capture("phase2-cancelled-steer-860-dark", view: DesktopWorkspaceView(workspace: queueWorkspace, searchRequest: 0), width: 860, height: 600, dark: true)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("amber-review-images-" + UUID().uuidString)
        let staging = folder.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j9ZkAAAAASUVORK5CYII=")!
        let first = staging.appendingPathComponent("已保存到原会话的图片.png")
        let remaining = staging.appendingPathComponent("待恢复的第二张生成结果.png")
        try png.write(to: first)
        let owner = DesktopConversation(title: "图片保存失败后可原地重试 · 不重新请求模型")
        let history = IOSImageGenerationHistoryStore(userDefaults: defaults, key: "review.pending.images")
        history.insert(IOSImageGenerationRecord(id: UUID().uuidString, prompt: "本地生成结果恢复fixture", model: "fixture-no-network",
            aspectRatio: .square, count: 2, style: "", source: "macos:" + owner.id.uuidString,
            files: [.init(id: UUID().uuidString, path: first.path, mimeType: "image/png"),
                .init(id: UUID().uuidString, path: remaining.path, mimeType: "image/png")], createdAt: 1))
        let files = DesktopWorkspaceFiles(directory: folder.appendingPathComponent("workspaces"))
        let transport = ReviewNoNetworkImageTransport()
        let generator = DesktopImageGeneration(settings: settings, files: files, history: history, stagingDirectory: staging, transport: transport)
        let workspace = DesktopWorkspace(settings: settings, storage: DesktopMemoryConversationStorage([owner]),
            provider: provider, initialConversations: [owner], files: files, imageGeneration: generator)
        assert(generator.pendingSaveCount(for: owner.id) == 2)
        try await capture("phase2-images-pending-light", view: DesktopImageGenerationView(workspace: workspace, ownerID: owner.id), width: 740, height: 660, dark: false)
        try await Task.sleep(for: .milliseconds(300))
        do { _ = try await workspace.retryGeneratedImageSaving(ownerID: owner.id); assertionFailure("Missing staging image must fail") }
        catch { FileHandle.standardError.write(Data(("EXPECTED PARTIAL LOCAL FAILURE: " + error.localizedDescription + "\n").utf8)) }
        FileHandle.standardError.write(Data("IMAGE COUNTS artifacts=\(generator.artifacts.count) pending=\(generator.pendingSaveCount(for: owner.id))\n".utf8))
        assert(generator.artifacts.count == 1 && generator.pendingSaveCount(for: owner.id) == 1)
        assert(transport.requests == 0)
        try await capture("phase2-images-partial-light", view: DesktopImageGenerationView(workspace: workspace, ownerID: owner.id), width: 740, height: 660, dark: false)
        try await capture("phase2-images-partial-dark", view: DesktopImageGenerationView(workspace: workspace, ownerID: owner.id), width: 740, height: 660, dark: true)
        try await Task.sleep(for: .milliseconds(300))
        try png.write(to: remaining)
        _ = try await workspace.retryGeneratedImageSaving(ownerID: owner.id)
        assert(generator.artifacts.count == 2 && generator.pendingSaveCount(for: owner.id) == 0)
        assert(transport.requests == 0)
        try await capture("phase2-images-recovered-light", view: DesktopImageGenerationView(workspace: workspace, ownerID: owner.id), width: 740, height: 660, dark: false)
        print("PHASE2 UI STATES COMPLETE, network requests", transport.requests)
    }
}

@MainActor private final class ReviewNoNetworkProvider: DesktopTextProvider {
    func start(configuration: DesktopProviderConfiguration, apiKey: String, messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
        throw DesktopRuntimeError.message("UI fixture must not start a provider request.")
    }
}

@MainActor private final class ReviewNoNetworkImageTransport: IOSImageGenerationHTTPTransport {
    private(set) var requests = 0
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        requests += 1
        throw DesktopRuntimeError.message("UI fixture must not make an image request.")
    }
}
