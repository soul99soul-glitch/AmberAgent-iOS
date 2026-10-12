import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSConversationStartupTests: XCTestCase {
    func testColdHomeImageResumeDoesNotLoadOrdinaryHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationCount = 160
        try await seedOrdinaryHistory(in: directory, count: conversationCount)

        let store = IOSConversationStore(baseDirectory: directory)
        let bootstrapStart = Date.timeIntervalSinceReferenceDate
        await store.bootstrap()
        let bootstrapMilliseconds = (Date.timeIntervalSinceReferenceDate - bootstrapStart) * 1_000
        XCTAssertEqual(store.summaries.count, conversationCount)
        XCTAssertTrue(store.summaries.allSatisfy { !$0.hasImageGenerationTool })
        XCTAssertNotNil(store.currentConversation)

        var loadedIDs: [String] = []
        store.beforeMessageLoadForTesting = { loadedIDs.append($0.toHexDashString()) }
        let viewModel = makeViewModel(store: store)
        let filteredStart = Date.timeIntervalSinceReferenceDate
        let context = await viewModel.latestImageGenerationResumeContext()
        let filteredMilliseconds = (Date.timeIntervalSinceReferenceDate - filteredStart) * 1_000
        XCTAssertNil(context)
        XCTAssertTrue(loadedIDs.isEmpty, "Ordinary history must not load messages for the home image card")

        // Retain the former all-history scan as a measured baseline on the same
        // synthetic data. A new store keeps its decoded-conversation cache cold.
        let baselineStore = IOSConversationStore(baseDirectory: directory)
        await baselineStore.bootstrap()
        var baselineLoads = 0
        baselineStore.beforeMessageLoadForTesting = { _ in baselineLoads += 1 }
        let baselineStart = Date.timeIntervalSinceReferenceDate
        for summary in baselineStore.summaries {
            let loadedMessages = await baselineStore.messages(for: summary.id)
            let messages = try XCTUnwrap(loadedMessages)
            XCTAssertNil(ChatImageGenerationResumeProjection.latest(
                in: messages,
                conversationID: summary.id.toHexDashString(),
                isGenerationActive: false
            ))
        }
        let baselineMilliseconds = (Date.timeIntervalSinceReferenceDate - baselineStart) * 1_000
        XCTAssertEqual(baselineLoads, conversationCount - 1)
        print(String(
            format: "HOME_STARTUP conversations=%d bootstrap_ms=%.2f image_scan_before_ms=%.2f image_scan_after_ms=%.2f message_loads_before=%d message_loads_after=%d",
            conversationCount, bootstrapMilliseconds, baselineMilliseconds,
            filteredMilliseconds, baselineLoads, loadedIDs.count
        ))
    }

    func testColdHomeImageResumeLoadsOnlyImageOwnersAndPreservesPriority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seedOrdinaryHistory(in: directory, count: 24)
        let seed = IOSConversationStore(baseDirectory: directory)
        await seed.bootstrap()
        let completedID = try await addConversation(
            to: seed,
            messages: [imageMessage(toolCallID: "completed", completed: true, hour: 14)]
        )
        let runningID = try await addConversation(
            to: seed,
            messages: [imageMessage(toolCallID: "running", completed: false, hour: 12)]
        )
        let ordinaryID = try await addConversation(
            to: seed, messages: [UIMessage.companion.user(prompt: "普通会话")]
        )

        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        let selected = await store.selectConversationIfAvailable(id: ordinaryID)
        XCTAssertTrue(selected)
        XCTAssertEqual(
            Set(store.summaries.filter(\.hasImageGenerationTool).map { $0.id.toHexDashString() }),
            Set([completedID.toHexDashString(), runningID.toHexDashString()])
        )
        var loadedIDs: [String] = []
        store.beforeMessageLoadForTesting = { loadedIDs.append($0.toHexDashString()) }
        let viewModel = makeViewModel(store: store)
        viewModel.generationActiveOverrideForTesting = { $0 == runningID }

        let running = await viewModel.latestImageGenerationResumeContext()
        XCTAssertEqual(running?.conversationID, runningID.toHexDashString())
        XCTAssertEqual(running?.toolCallID, "running")
        XCTAssertEqual(running?.state, .running, "An older active image task must outrank a newer completed image")
        XCTAssertEqual(loadedIDs.count, 2)
        XCTAssertEqual(Set(loadedIDs), Set([completedID.toHexDashString(), runningID.toHexDashString()]))

        loadedIDs.removeAll()
        viewModel.generationActiveOverrideForTesting = { _ in false }
        let completed = await viewModel.latestImageGenerationResumeContext()
        XCTAssertEqual(completed?.conversationID, completedID.toHexDashString())
        XCTAssertEqual(completed?.toolCallID, "completed")
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(loadedIDs, [runningID.toHexDashString()])

        await store.deleteConversation(id: completedID)
        let afterDeletion = await viewModel.latestImageGenerationResumeContext()
        XCTAssertNil(afterDeletion, "An inactive empty tool result must not become a completed image card")
    }

    func testCurrentImageVariantRemainsAvailableBeforeSummaryRefresh() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IOSConversationStore(baseDirectory: directory)
        await store.bootstrap()
        await store.saveCurrent(messages: [UIMessage.companion.assistant(prompt: "原始分支")])
        let conversationID = try XCTUnwrap(store.currentConversation?.id)
        XCTAssertEqual(store.summaries.first?.hasImageGenerationTool, false)

        // This branch operation updates the in-memory selected conversation
        // before publishing a fresh summary list.
        let variant = await store.appendVariant(
            messageIndex: 0,
            message: imageMessage(toolCallID: "selected-variant", completed: true, hour: 12)
        )
        XCTAssertEqual(variant, 0)
        var messageLoads = 0
        store.beforeMessageLoadForTesting = { _ in messageLoads += 1 }
        let context = await makeViewModel(store: store).latestImageGenerationResumeContext()
        XCTAssertEqual(context?.conversationID, conversationID.toHexDashString())
        XCTAssertEqual(context?.toolCallID, "selected-variant")
        XCTAssertEqual(context?.state, .completed)
        XCTAssertEqual(messageLoads, 0)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSConversationStartup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeViewModel(store: IOSConversationStore) -> ChatViewModel {
        let viewModel = ChatViewModel(settingsStore: SettingsStore(), autoGenerateResponses: false)
        viewModel.conversationStore = store
        return viewModel
    }

    private func seedOrdinaryHistory(in directory: URL, count: Int) async throws {
        let seed = IOSConversationStore(baseDirectory: directory)
        await seed.bootstrap()
        await seed.saveCurrent(messages: [UIMessage.companion.user(
            prompt: String(repeating: "ordinary history ", count: 1_024)
        )])
        let id = try XCTUnwrap(seed.currentConversation?.id)
        let data = try Data(contentsOf: directory.appendingPathComponent("\(id.toHexDashString()).json"))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for index in 1..<count {
            let copiedID = UUID().uuidString.lowercased()
            document["id"] = copiedID
            document["title"] = "Ordinary \(index)"
            try JSONSerialization.data(withJSONObject: document)
                .write(to: directory.appendingPathComponent("\(copiedID).json"))
        }
        // Establish the current persisted summary index before measuring a
        // fresh process's normal startup; migration cost is tested in KMP.
        await seed.bootstrap()
        XCTAssertEqual(seed.summaries.count, count)
    }

    private func addConversation(to store: IOSConversationStore, messages: [UIMessage]) async throws -> KotlinUuid {
        let created = await store.newConversation()
        XCTAssertTrue(created)
        await store.saveCurrent(messages: messages)
        return try XCTUnwrap(store.currentConversation?.id)
    }

    private func imageMessage(toolCallID: String, completed: Bool, hour: Int32) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: .assistant,
            parts: [UIMessagePart.Tool(
                toolCallId: toolCallID,
                toolName: "generate_image",
                input: #"{"prompt":"测试图片"}"#,
                output: completed ? [UIMessagePart.Image(url: "amber-image-generation://\(toolCallID).png", metadata: nil)] : [],
                approvalState: ToolApprovalState.Auto.shared,
                streamIndex: nil,
                metadata: nil
            )],
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026, month: 10, day: 12, hour: hour, minute: 0, second: 0, nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }
}
