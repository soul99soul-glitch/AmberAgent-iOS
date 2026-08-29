import XCTest
import UIKit
@preconcurrency import Shared
@testable import iosApp

final class IOSChatBackgroundStaleSweepTests: XCTestCase {
    private let taskMapKey = "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").chat.backgroundTaskMap"
    private var originalTaskMap: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalTaskMap = UserDefaults.standard.object(forKey: taskMapKey)
        UserDefaults.standard.removeObject(forKey: taskMapKey)
    }

    override func tearDownWithError() throws {
        if let originalTaskMap {
            UserDefaults.standard.set(originalTaskMap, forKey: taskMapKey)
        } else {
            UserDefaults.standard.removeObject(forKey: taskMapKey)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testColdStartSweepRemovesPersistedOwnerWithoutSubmittingAnotherRequest() {
        let requestId = "\(Bundle.main.bundleIdentifier ?? "app.amber.ios").chat.stale-run"
        UserDefaults.standard.set([requestId: "stale-run"], forKey: taskMapKey)

        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        coordinator.finalizeStalePersistedJobsIfNeeded()
        coordinator.finalizeStalePersistedJobsIfNeeded()

        XCTAssertTrue(
            UserDefaults.standard
                .dictionary(forKey: taskMapKey)?[requestId] == nil,
            "冷启动扫尾后不能保留会触发下一次后台提交的 task map owner"
        )
    }

    /// detach 后只剩 task-map/payload，没有 `activeJobs`。按 runId 取消必须
    /// 能水合这份 owner，否则服务端 response 会继续跑、回前台还会续上。
    @MainActor
    func testCancelJobFindsCheckpointedDurableResponseWithoutActiveJob() async {
        let fixture = DurableCancelFixture(name: "durable-cancel")
        await assertCancelFindsCheckpointedOwner(fixture) { coordinator, handoff in
            coordinator.cancelJob(runId: handoff.runId)
        }
    }

    /// Chat 停止按钮走 `cancelActiveJob(conversationId:)`，不是 runId。
    @MainActor
    func testCancelActiveJobFindsCheckpointedDurableResponseWithoutActiveJob() async {
        let fixture = DurableCancelFixture(name: "durable-cancel-conv")
        await assertCancelFindsCheckpointedOwner(fixture) { coordinator, handoff in
            coordinator.cancelActiveJob(conversationId: handoff.conversationId)
        }
    }

    @MainActor
    private func assertCancelFindsCheckpointedOwner(
        _ fixture: DurableCancelFixture,
        cancel: (IOSChatBackgroundGenerationCoordinator, IOSChatBackgroundHandoff) -> Bool
    ) async {
        let coordinator = IOSChatBackgroundGenerationCoordinator.shared
        XCTAssertTrue(coordinator.persistDurableResponseCheckpointForTesting(fixture.handoff))
        let requestId = UserDefaults.standard
            .dictionary(forKey: taskMapKey)?
            .first(where: { ($0.value as? String) == fixture.handoff.runId })?
            .key
        XCTAssertNotNil(requestId, "checkpoint 必须持有唯一 task-map owner")
        XCTAssertFalse(
            coordinator.restorableRunIds.contains(fixture.handoff.runId),
            "checkpoint 不得提前挂进 activeJobs"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableCancel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            coordinator.discardDurableResponse(runId: fixture.handoff.runId)
            try? FileManager.default.removeItem(at: directory)
        }

        let sharedSettings = IOSSharedSettingsStore(
            userDefaults: UserDefaults(suiteName: "\(fixture.name)-\(UUID().uuidString)")!
        )
        _ = sharedSettings.addProvider(fixture.provider)
        let store = IOSConversationStore(baseDirectory: directory)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: HandoffTestSearchTransport(),
            mcpManager: IOSMcpManager(serverProvider: { [] })
        )

        var didCancel = false
        coordinator.withDependenciesForTesting(
            conversationStore: store,
            toolRuntime: runtime,
            sharedSettings: sharedSettings
        ) {
            didCancel = cancel(coordinator, fixture.handoff)
        }
        XCTAssertTrue(didCancel, "只有 payload/task map 时取消也必须生效")

        let deadline = Date().addingTimeInterval(5)
        while let requestId,
              UserDefaults.standard.dictionary(forKey: taskMapKey)?[requestId] != nil,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if let requestId {
            XCTAssertNil(
                UserDefaults.standard.dictionary(forKey: taskMapKey)?[requestId],
                "取消即使终态 transcript 保存失败，也必须清理 durable response owner"
            )
        }
    }
}

private final class HandoffTestSearchTransport: IOSSearchHTTPTransport {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (response, Data())
    }
}

private struct DurableCancelFixture {
    let name: String
    let provider: ProviderSetting.OpenAI
    let handoff: IOSChatBackgroundHandoff

    @MainActor
    init(name: String) {
        let runId = "\(name)-\(UUID().uuidString)"
        let model = Model(
            modelId: "\(name)-model",
            displayName: "\(name)-model",
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: [],
            outputModalities: [],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        let provider = ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: name,
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: "sk-test",
            baseUrl: "https://example.test",
            chatCompletionsPath: "/chat/completions",
            useResponseApi: true,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
        let messages = [
            UIMessage(
                id: KotlinUuid.companion.random(),
                role: MessageRole.assistant,
                parts: [],
                annotations: [],
                createdAt: Kotlinx_datetimeLocalDateTime(
                    year: 2026, month: 8, day: 16, hour: 0, minute: 0, second: 0, nanosecond: 0
                ),
                finishedAt: nil,
                modelId: nil,
                usage: nil,
                translation: nil
            )
        ]
        var handoff = IOSChatBackgroundHandoff(
            runId: runId,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000),
            inputDigest: "\(name)-digest",
            conversationId: KotlinUuid.companion.random(),
            providerId: provider.id.toHexDashString(),
            providerSetting: provider,
            params: TextGenerationParams(
                model: model,
                temperature: KotlinFloat(value: 0.7),
                topP: nil,
                maxTokens: nil,
                tools: [],
                reasoningLevel: .off,
                customHeaders: [],
                customBody: []
            ),
            uploadMessages: messages,
            displayMessages: messages,
            mode: .resumeResponse,
            generativeUiRequirement: .none,
            generativeUiFallbackAttempted: false,
            fullToolNames: []
        )
        handoff.responseId = "resp-\(runId)"
        self.name = name
        self.provider = provider
        self.handoff = handoff
    }
}
