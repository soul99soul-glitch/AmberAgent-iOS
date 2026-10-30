import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class ChatCompletionClaimOwnershipTests: XCTestCase {
    func testOlderCompletionCheckCannotReplaceCurrentNotice() async throws {
        let state = ChatConversationRunState(conversationId: nil)
        let verifier = ControlledVerifier()
        defer { verifier.releaseAll() }
        let firstReply = IOSChatForegroundFixtures.assistantText("第一轮答复")
        state.messages = [firstReply]
        let firstCheck = try XCTUnwrap(ChatViewModel.checkCompletionClaim(
            state: state,
            runId: "first",
            messages: state.messages,
            needsVerification: verifier.verify
        ))
        await verifier.waitUntilPending("first")

        let currentReply = IOSChatForegroundFixtures.assistantText("当前轮答复")
        state.messages = [firstReply, currentReply]
        let currentCheck = try XCTUnwrap(ChatViewModel.checkCompletionClaim(
            state: state,
            runId: "current",
            messages: state.messages,
            needsVerification: verifier.verify
        ))
        await verifier.waitUntilPending("current")
        try verifier.complete("current", result: true)
        await currentCheck.value
        XCTAssertEqual(state.jevCompletionNoticeMessageId, currentReply.id.description())

        try verifier.complete("first", result: true)
        await firstCheck.value
        XCTAssertEqual(
            state.jevCompletionNoticeMessageId,
            currentReply.id.description(),
            "旧轮完成校验晚返回时，不能覆盖当前答复已有的提示。"
        )
    }

    func testNewMessagePreventsOldCompletionNoticeFromAppearing() async throws {
        let state = ChatConversationRunState(conversationId: nil)
        let verifier = ControlledVerifier()
        defer { verifier.releaseAll() }
        let reply = IOSChatForegroundFixtures.assistantText("等待完成校验的答复")
        state.messages = [reply]
        let check = try XCTUnwrap(ChatViewModel.checkCompletionClaim(
            state: state,
            runId: "previous",
            messages: state.messages,
            needsVerification: verifier.verify
        ))
        await verifier.waitUntilPending("previous")

        state.messages.append(IOSChatForegroundFixtures.userMessage("继续下一轮"))
        try verifier.complete("previous", result: true)
        await check.value

        XCTAssertNil(state.jevCompletionNoticeMessageId, "已有新消息时，旧答复不能再获得完成校验提示。")
    }

    @MainActor
    private final class ControlledVerifier {
        private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
        private var entryWaiters: [String: CheckedContinuation<Void, Never>] = [:]

        func verify(_ messages: [UIMessage], _ runId: String) async -> Bool {
            await withCheckedContinuation { continuation in
                pending[runId] = continuation
                entryWaiters.removeValue(forKey: runId)?.resume()
            }
        }

        func waitUntilPending(_ runId: String) async {
            guard pending[runId] == nil else { return }
            await withCheckedContinuation { entryWaiters[runId] = $0 }
        }

        func complete(_ runId: String, result: Bool) throws {
            let continuation = try XCTUnwrap(pending.removeValue(forKey: runId))
            continuation.resume(returning: result)
        }

        func releaseAll() {
            let continuations = Array(pending.values)
            pending.removeAll()
            continuations.forEach { $0.resume(returning: false) }
        }
    }
}
