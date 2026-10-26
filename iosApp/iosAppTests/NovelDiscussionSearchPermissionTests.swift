import XCTest
@testable import iosApp

extension NovelLiveModelAdapterTests {
    func testDiscussionSearchApprovalExplainsThePermissionAndRetryPaths() async throws {
        let fixture = makeFixture(apiKey: "test-key")
        let provider = ScriptedNovelDiscussionProvider()
        let adapter = NovelLiveModelAdapter(
            catalogProvider: { fixture.catalog },
            kmpTransport: { _, _ in nil },
            discussionTransport: NovelLiveModelAdapter.discussionSearchTransport(
                using: provider,
                executors: { _ in
                    ["search_web": IOSClosureToolExecutor { _, _, _ in
                        .needsApproval("Network search requires approval.")
                    }]
                }
            )
        )
        let resolved = try await adapter.resolveModel(for: .global)
        let events = await Self.collect(try await adapter.start(makeRequest(
            model: resolved, purpose: .discussion
        )))
        let failure = try XCTUnwrap(events.compactMap { event -> NovelModelFailure? in
            if case .failed(let failure) = event { return failure }
            return nil
        }.first)

        XCTAssertEqual(failure.code, "discussion_search_approval_required")
        XCTAssertTrue(failure.isRetryable)
        XCTAssertTrue(failure.message.contains("暂不支持逐次搜索审批"))
        XCTAssertTrue(failure.message.contains("权限与批准 → 搜索与网页读取"))
        XCTAssertTrue(failure.message.contains("关闭「Agent 网络搜索」后重试"))
        XCTAssertFalse(events.contains(.completed))
        XCTAssertEqual(provider.callCount, 1)
    }
}
