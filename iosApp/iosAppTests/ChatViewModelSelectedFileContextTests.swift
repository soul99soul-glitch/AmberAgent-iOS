import XCTest
import WebKit
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatViewModelSelectedFileContextTests: ChatViewModelContextTestCase {

    func testAttachSuccessAddsPreviewToNextMessageAndClearsIt() async throws {
        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(text: "Selected file body"))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )

        await viewModel.attachSelectedFilePreviewToNextMessage()
        XCTAssertNotNil(viewModel.pendingSelectedFilePreview)

        viewModel.inputText = "Summarize this"
        viewModel.sendMessage()

        let content = try XCTUnwrap(viewModel.messages.first).parts
            .compactMap { ($0 as? UIMessagePart.Text)?.text }
            .joined(separator: "\n")
        XCTAssertTrue(content.contains("Summarize this"))
        XCTAssertTrue(content.contains("[文件上下文]"))
        XCTAssertTrue(content.contains("来源文件："))
        XCTAssertTrue(content.contains("状态：完整读取"))
        XCTAssertTrue(content.contains("Selected file body"))
        XCTAssertNil(viewModel.pendingSelectedFilePreview)
    }

    func testSelectedFileAttachmentRejectsAReplacedGrant() async throws {
        let documentStore = DocumentAccessStore()
        let firstFile = try makeTempFile(text: "First selected file")
        let secondFile = try makeTempFile(text: "Second selected file")
        defer {
            try? FileManager.default.removeItem(at: firstFile)
            try? FileManager.default.removeItem(at: secondFile)
        }
        let firstGrant = documentStore.registerPickedFile(firstFile)
        let secondGrant = documentStore.registerPickedFile(secondFile)
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )

        await viewModel.attachSelectedFilePreviewToNextMessage(expectedFileScopeDigest: firstGrant.scopeDigest)

        XCTAssertNil(viewModel.pendingSelectedFilePreview)
        XCTAssertNotNil(viewModel.selectedFileContextError)
        XCTAssertFalse(viewModel.isAttachingSelectedFile)
        XCTAssertEqual(documentStore.grantSummary?.id, secondGrant.id)
        XCTAssertEqual(documentStore.grantSummary?.usedCount, 0)
    }

    func testSelectedFileResultCannotAttachToAConversationOpenedAfterPickerPresentation() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatSelectedFileOwner-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(text: "Conversation A file"))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let pickerOwner = String(describing: try XCTUnwrap(store.currentConversation?.id))
        await store.newConversation()

        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        viewModel.conversationStore = store
        viewModel.reloadFromStore()

        await viewModel.attachSelectedFilePreviewToNextMessage(
            expectedConversationId: pickerOwner
        )

        XCTAssertNil(viewModel.pendingSelectedFilePreview)
        XCTAssertNil(viewModel.selectedFileContextError)
        XCTAssertFalse(viewModel.isAttachingSelectedFile)
    }

    func testConversationChangeDiscardsSelectedFileContext() async throws {
        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(text: "Conversation-owned file"))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )

        await viewModel.attachSelectedFilePreviewToNextMessage()
        XCTAssertNotNil(viewModel.pendingSelectedFilePreview)

        XCTAssertTrue(viewModel.prepareForConversationChange())
        XCTAssertNil(viewModel.pendingSelectedFilePreview)
        XCTAssertNil(viewModel.selectedFileContextError)
    }

    func testConversationChangeClearsInFlightSelectedFileState() {
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            autoGenerateResponses: false
        )
        viewModel.isAttachingSelectedFile = true

        XCTAssertTrue(viewModel.prepareForConversationChange())
        XCTAssertFalse(viewModel.isAttachingSelectedFile)
    }

    func testDeletingCurrentConversationDiscardsSelectedFileContext() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelDeleteConversationContext-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let conversationId = try XCTUnwrap(store.currentConversation?.id)
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        viewModel.isAttachingSelectedFile = true
        viewModel.selectedFileContextError = "reading"

        viewModel.prepareForConversationDeletion(conversationId)

        XCTAssertFalse(viewModel.isAttachingSelectedFile)
        XCTAssertNil(viewModel.selectedFileContextError)
    }

    func testDeletingAnotherConversationKeepsCurrentSelectedFileContext() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatViewModelDeleteOtherConversationContext-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let store = IOSConversationStore(baseDirectory: baseDirectory)
        await store.bootstrap()
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        viewModel.isAttachingSelectedFile = true
        viewModel.selectedFileContextError = "reading"

        viewModel.prepareForConversationDeletion(KotlinUuid.companion.random())

        XCTAssertTrue(viewModel.isAttachingSelectedFile)
        XCTAssertEqual(viewModel.selectedFileContextError, "reading")
    }

    func testPendingPreviewIsNotAutomaticallyReused() async throws {
        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(text: "One shot"))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )

        await viewModel.attachSelectedFilePreviewToNextMessage()
        viewModel.inputText = "First"
        viewModel.sendMessage()
        viewModel.inputText = "Second"
        viewModel.sendMessage()

        XCTAssertTrue(textContent(of: viewModel.messages[0]).contains("One shot"))
        XCTAssertFalse(textContent(of: viewModel.messages[1]).contains("One shot"))
    }

    func testAttachDeniedDoesNotModifyInputOrAppendMessages() async {
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: DocumentAccessStore()
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )
        viewModel.inputText = "Keep this"

        await viewModel.attachSelectedFilePreviewToNextMessage()

        XCTAssertEqual(viewModel.inputText, "Keep this")
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.pendingSelectedFilePreview)
        XCTAssertNotNil(viewModel.selectedFileContextError)
    }

    func testChatDoesNotCreateToolParts() async throws {
        let documentStore = DocumentAccessStore()
        _ = documentStore.registerPickedFile(try makeTempFile(text: "plain text"))
        let executor = IOSLocalToolExecutor(
            permissionStore: IOSPermissionStore(userDefaults: isolatedDefaults()),
            documentStore: documentStore
        )
        let viewModel = ChatViewModel(
            settingsStore: SettingsStore(),
            localToolExecutor: executor,
            autoGenerateResponses: false
        )

        await viewModel.attachSelectedFilePreviewToNextMessage()
        viewModel.inputText = "Use context"
        viewModel.sendMessage()

        let hasToolPart = viewModel.messages.flatMap(\.parts).contains { $0 is UIMessagePart.Tool }
        XCTAssertFalse(hasToolPart)
    }

    private func makeTempFile(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data(text.utf8).write(to: url)
        return url
    }
}
