import XCTest
import WebKit
@preconcurrency import Shared
@testable import iosApp

final class ImageUploadRecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var uploads: [[UIMessage]] = []

    init(fails: Bool = false) { self.fails = fails }

    var lastUpload: [UIMessage]? { lock.withLock { uploads.last } }
    var uploadedImageURLs: [String] {
        lock.withLock {
            uploads.flatMap { $0 }.flatMap(\.parts).compactMap { ($0 as? UIMessagePart.Image)?.url }
        }
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        lock.withLock { uploads.append(messages) }
        if fails {
            throw NSError(domain: "ImageUploadTest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "vision test failure"
            ])
        }
        return IOSChatForegroundFixtures.chunk(
            with: IOSChatForegroundFixtures.assistantText("recognized image")
        )
    }
}

final class BlockingVisionProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MessageChunk, Error>?
    private var started = false
    private var cancelled = false

    var hasStarted: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    started = true
                    self.continuation = continuation
                }
            }
        } onCancel: {
            lock.withLock { cancelled = true }
        }
    }

    func finish(text: String) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        let message = UIMessage.companion.assistant(prompt: text)
        continuation?.resume(returning: MessageChunk(
            id: "vision-test-chunk",
            model: "vision-test-model",
            choices: [UIMessageChoice(index: 0, delta: nil, message: message, finishReason: "stop")],
            usage: nil
        ))
    }
}

