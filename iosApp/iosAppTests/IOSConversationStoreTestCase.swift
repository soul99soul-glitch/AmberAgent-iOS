import XCTest
@preconcurrency import Shared
@testable import iosApp


@MainActor
class IOSConversationStoreTestCase: XCTestCase {
    func makeMessage(role: MessageRole, parts: [UIMessagePart]) -> UIMessage {
        UIMessage(
            id: KotlinUuid.companion.random(),
            role: role,
            parts: parts,
            annotations: [],
            createdAt: Kotlinx_datetimeLocalDateTime(
                year: 2026,
                month: 7,
                day: 9,
                hour: 0,
                minute: 0,
                second: 0,
                nanosecond: 0
            ),
            finishedAt: nil,
            modelId: nil,
            usage: nil,
            translation: nil
        )
    }

    func assistantToolMessage(output: [UIMessagePart] = []) -> UIMessage {
        makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(
                    toolCallId: "tool-1",
                    toolName: "web_search",
                    input: "{\"q\":\"amber\"}",
                    output: output,
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            ]
        )
    }

    func imageGenerationMessage(
        toolCallID: String,
        prompt: String,
        output: [UIMessagePart]
    ) -> UIMessage {
        makeMessage(
            role: MessageRole.assistant,
            parts: [
                UIMessagePart.Tool(
                    toolCallId: toolCallID,
                    toolName: "generate_image",
                    input: #"{"prompt":"\#(prompt)"}"#,
                    output: output,
                    approvalState: ToolApprovalState.Auto.shared,
                    streamIndex: nil,
                    metadata: nil
                )
            ]
        )
    }
    func waitFor(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func makeTempFile(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    func isolatedDefaults() -> UserDefaults {
        let suiteName = "app.amber.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
