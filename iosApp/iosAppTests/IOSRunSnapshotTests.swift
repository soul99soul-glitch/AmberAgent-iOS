import XCTest
@preconcurrency import Shared
@testable import iosApp

/// Provider resolve single-flight 与冻结工具目录的行为测试。
final class IOSRunSnapshotTests: XCTestCase {

    // MARK: - Single-flight：并发调用合并为一次底层解析，结果共享

    func testResolveCoordinatorMergesConcurrentCallsForSameKeyIntoOneUnderlyingResolve() async {
        let coordinator = IOSCodexResolveCoordinator()
        let counter = ResolveCallCounter()
        let token = "shared-token"

        // 三个“并发”调用者（模拟前台流 + 后台交接同时解析同一个 provider），
        // 每个调用里的闭包本应各自跑一次网络刷新——single-flight 要把它们合并成一次。
        let tasks = (0..<3).map { _ in
            Task {
                try await coordinator.resolve(key: "provider-a") {
                    await counter.increment()
                    // 故意留一点时间窗口，让另外两个调用者有机会在第一个完成前
                    // 就撞上同一个 in-flight task。
                    try await Task.sleep(nanoseconds: 30_000_000)
                    return token
                }
            }
        }

        var results: [String] = []
        for task in tasks {
            switch await task.result {
            case .success(let resolved):
                results.append(resolved)
            case .failure(let error):
                XCTFail("unexpected failure: \(error)")
            }
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results, Array(repeating: token, count: 3))
        let invocationCount = await counter.count
        XCTAssertEqual(invocationCount, 1, "N 个并发调用应只触发一次底层解析闭包")
    }

    func testResolveCoordinatorSharesFailureAcrossConcurrentCallersWithoutAmplifyingIt() async {
        let coordinator = IOSCodexResolveCoordinator()
        let counter = ResolveCallCounter()
        struct ProbeError: Error, Equatable, Hashable { let token: Int }

        let tasks = (0..<3).map { _ in
            Task {
                try await coordinator.resolve(key: "provider-b") {
                    await counter.increment()
                    try await Task.sleep(nanoseconds: 30_000_000)
                    throw ProbeError(token: 7)
                }
            }
        }

        var observedErrors: [ProbeError] = []
        for task in tasks {
            switch await task.result {
            case .success:
                XCTFail("expected all callers to observe the shared failure")
            case .failure(let error):
                guard let probe = error as? ProbeError else {
                    return XCTFail("unexpected error type: \(error)")
                }
                observedErrors.append(probe)
            }
        }

        XCTAssertEqual(observedErrors.count, 3)
        XCTAssertEqual(Set(observedErrors), [ProbeError(token: 7)], "失败也应共享同一个结果，不放大成三次不同的错误")
        let invocationCount = await counter.count
        XCTAssertEqual(invocationCount, 1, "失败路径同样只应触发一次底层解析闭包")
    }

    func testResolveCoordinatorDoesNotMergeCallsForDifferentKeys() async {
        let coordinator = IOSCodexResolveCoordinator()
        let counter = ResolveCallCounter()
        async let resolvedA = coordinator.resolve(key: "provider-a") {
            await counter.increment()
            return "token-a"
        }
        async let resolvedB = coordinator.resolve(key: "provider-b") {
            await counter.increment()
            return "token-b"
        }

        // Xcode 27 beta 编译器对 `try! await (a, b)` 元组聚合在此处触发 SIL
        // ownership 校验崩溃；分两次 await 语义不变（async let 仍并发执行）。
        let a = try! await resolvedA
        let b = try! await resolvedB
        XCTAssertEqual(a, "token-a")
        XCTAssertEqual(b, "token-b")
        let invocationCount = await counter.count
        XCTAssertEqual(invocationCount, 2, "不同 key 之间不应互相合并")
    }

    // MARK: - I-4 冻结语义：`settingsSnapshot(forRun:)` 是压缩 prepare/finalize 两处的注入缝

    @MainActor
    func testPendingToolSelectionUsesFrozenToolNamesAfterLiveSettingChanges() {
        let sharedSettings = IOSSharedSettingsStore(userDefaults: isolatedDefaults())
        sharedSettings.setEnableWebSearch(true)
        let runtime = ChatToolRuntime(
            settingsStore: SettingsStore(),
            sharedSettings: sharedSettings,
            localToolExecutor: nil,
            searchTransport: NoopSearchTransport(),
            mcpManager: IOSMcpManager(sharedSettings: sharedSettings, configStore: .shared)
        )
        let tool = UIMessagePart.Tool(
            toolCallId: "search-1",
            toolName: "search_web",
            input: #"{"query":"amber"}"#,
            output: [],
            approvalState: ToolApprovalState.Auto.shared,
            streamIndex: nil,
            metadata: nil
        )
        let message = UIMessage(
            id: KotlinUuid.companion.random(),
            role: MessageRole.assistant,
            parts: [tool],
            annotations: [],
            createdAt: chatNowLocalDateTime(),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )

        // Simulate changing the global switch after this run's params.tools was frozen.
        sharedSettings.setEnableWebSearch(false)

        XCTAssertNotNil(runtime.nextPendingToolCall(
            in: [message],
            availableToolNames: ["search_web"]
        ))
        XCTAssertNil(runtime.nextPendingToolCall(
            in: [message],
            availableToolNames: []
        ))
    }

    // MARK: - Harness

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.tests.runsnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

}

private actor ResolveCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
private final class NoopSearchTransport: IOSSearchHTTPTransport {
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
