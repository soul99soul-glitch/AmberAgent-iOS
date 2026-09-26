import XCTest
import SwiftUI
import UIKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatArtifactIntegrationTests: XCTestCase {
    func testConversationDeletionCleansShelfOnlyAfterCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversations = IOSConversationStore(baseDirectory: directory)
        await conversations.bootstrap()
        let id = try XCTUnwrap(conversations.currentConversation?.id)
        let snippet = IOSPinnedSnippet(
            id: "message", messageID: "message", turn: 1, text: "保留的片段", kind: .message, codeLanguage: nil
        )
        try conversations.artifactStore.pin(snippet, for: id.toHexDashString())
        try conversations.artifactStore.adopt(versionID: "v1", path: "notes.md", for: id.toHexDashString())
        conversations.beforeDeleteForTesting = { throw CocoaError(.fileWriteNoPermission) }
        let failed = await conversations.deleteConversation(id: id)
        XCTAssertFalse(failed)
        XCTAssertEqual(conversations.artifactStore.snippets(for: id.toHexDashString()), [snippet])
        conversations.beforeDeleteForTesting = nil
        let deleted = await conversations.deleteConversation(id: id)
        XCTAssertTrue(deleted)
        let reloaded = IOSConversationStore(baseDirectory: directory)
        XCTAssertTrue(reloaded.artifactStore.snippets(for: id.toHexDashString()).isEmpty)
        XCTAssertTrue(reloaded.artifactStore.adoptedVersions(for: id.toHexDashString()).isEmpty)
    }

    func testPinnedSnippetContinuesInNativeChatComposer() async throws {
        let suite = "Phase4Chat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let conversations = IOSConversationStore(baseDirectory: directory)
        await conversations.bootstrap()
        let id = try XCTUnwrap(conversations.currentConversation?.id)
        await conversations.renameConversation(id: id, title: "城市漫游计划")
        let response = UIMessage.companion.assistant(prompt: "先沿河边散步，再去老街喝咖啡。\n把行程留白，慢慢发现城市。")
        let codeResponse = UIMessage.companion.assistant(prompt: "```swift\nlet route = [\"河边\", \"老街\"]\n```")
        let messages = [
            UIMessage.companion.user(prompt: "帮我安排周末的城市漫游。"), response,
            UIMessage.companion.user(prompt: "写成代码。"), codeResponse
        ]
        await conversations.saveCurrent(messages: messages)
        let snippet = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: ChatMessageProjector.messageId(for: response), text: response.toText(),
            kind: .message, messages: messages
        ))
        XCTAssertEqual(snippet.turn, 1)
        XCTAssertNotNil(ChatArtifactPinning.anchor(for: snippet, conversationID: id.toHexDashString(), messages: messages))
        XCTAssertNil(ChatArtifactPinning.anchor(for: snippet, conversationID: id.toHexDashString(), messages: []))
        try conversations.artifactStore.pin(snippet, for: id.toHexDashString())
        let settings = SettingsStore(userDefaults: defaults)
        let shared = IOSSharedSettingsStore(userDefaults: defaults)
        let viewModel = ChatViewModel(settingsStore: settings, sharedSettings: shared)
        viewModel.conversationStore = conversations
        viewModel.reloadFromStore(reason: .conversationSwitch)
        let activity = IOSSubAgentActivityStore(
            tasks: IOSAdvancedTaskStore(userDefaults: defaults), defaults: defaults,
            launchedAt: Date(), loadRuns: { [] }
        )
        let center = ConversationActivityCenter(
            conversationStore: conversations,
            dao: IosDatabaseFactory.shared.createDatabase(atFilePath: directory.appendingPathComponent("runs.db").path).agentRuntimeDao()
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(
                settingsStore: settings, sharedSettings: shared,
                workspaceStore: IOSWorkspaceStore(baseDirectory: directory.appendingPathComponent("workspace")),
                viewModel: viewModel, activityStore: activity
            )
        }.environment(conversations).environment(center).environment(RouterPath())
            .environment(\.locale, Locale(identifier: "zh_Hans")))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        if ProcessInfo.processInfo.environment["AMBER_PHASE4_CHAT_PROBE"] == "1" {
            print("PHASE4_CHAT_PROBE_READY")
            let deadline = Date().addingTimeInterval(90)
            while viewModel.inputText.isEmpty, Date() < deadline {
                try await Task.sleep(for: .milliseconds(150))
            }
        } else {
            viewModel.inputText = "参考这段："
            try await ChatArtifactComposerSupport.apply(
                ChatArtifactActions.continuation(for: .snippet(snippet)), to: viewModel
            )
            XCTAssertEqual(viewModel.inputText, "参考这段：\n\n> 先沿河边散步，再去老街喝咖啡。\n> 把行程留白，慢慢发现城市。")
        }
        if ProcessInfo.processInfo.environment["AMBER_PHASE4_CHAT_PROBE"] != "1" {
            let png = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).pngData { context in
                UIColor(red: 0.13, green: 0.26, blue: 0.42, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            }
            let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
            try await ChatArtifactComposerSupport.apply(.image(url: dataURL), to: viewModel)
            XCTAssertEqual(viewModel.pendingImages.count, 1)
            XCTAssertNil(viewModel.selectedFileContextError)

            // 达到上限时不抛错、面板照常关闭，由既有输入区错误提示说明。
            let beforeLimit = viewModel.pendingImages
            for _ in viewModel.pendingImages.count..<ChatViewModel.maxImagesPerMessage {
                viewModel.addPendingImage(dataUrl: dataURL, previewData: png)
            }
            try await ChatArtifactComposerSupport.apply(.image(url: dataURL), to: viewModel)
            XCTAssertEqual(viewModel.pendingImages.count, ChatViewModel.maxImagesPerMessage)
            XCTAssertNotNil(viewModel.selectedFileContextError)
            viewModel.pendingImages = beforeLimit
            viewModel.selectedFileContextError = nil
        }
        XCTAssertTrue(viewModel.inputText.contains("> 先沿河边散步"))
        // 输入框高度在下一轮布局后才更新，截图前等待组合器动画完成。
        try await Task.sleep(for: .milliseconds(2000))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "phase4-composer-continue"
        attachment.lifetime = .keepAlways
        add(attachment)
        let output = URL(fileURLWithPath: "/tmp/amber-topbar")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: output.appendingPathComponent("phase4-composer-continue.png"), options: .atomic)
    }

    func testSnippetsOutsideCurrentBranchAreHiddenButKept() throws {
        let user = UIMessage.companion.user(prompt: "问题")
        let first = UIMessage.companion.assistant(prompt: "第一版回答")
        let second = UIMessage.companion.assistant(prompt: "另一分支回答")
        let branchA = [user, first]
        let branchB = [user, second]
        let pinnedA = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: ChatMessageProjector.messageId(for: first), text: "第一版回答", kind: .message, messages: branchA
        ))
        let pinnedB = try XCTUnwrap(ChatArtifactPinning.snippet(
            messageID: ChatMessageProjector.messageId(for: second), text: "另一分支回答", kind: .message, messages: branchB
        ))
        let stored = [pinnedA, pinnedB]

        XCTAssertEqual(ChatArtifactPinning.visibleSnippets(stored, messages: branchA), [pinnedA])
        XCTAssertEqual(ChatArtifactPinning.visibleSnippets(stored, messages: branchB), [pinnedB])
        XCTAssertEqual(ChatArtifactPinning.visibleSnippets([], messages: branchA), [])
        XCTAssertEqual(stored.count, 2)
    }
}
