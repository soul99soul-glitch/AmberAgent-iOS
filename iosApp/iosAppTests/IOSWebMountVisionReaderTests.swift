import XCTest
@preconcurrency import Shared
@testable import iosApp

@MainActor
final class IOSWebMountVisionReaderTests: XCTestCase {
    func testReadSendsQuestionAndPNGToVisionProviderWithoutTools() async throws {
        let provider = RecordingProvider(result: "截图里看到了登录按钮。")
        let reader = IOSWebMountVisionReader(textProvider: provider)
        let result = try await reader.read(
            capture: capture(),
            question: "截图里是否显示登录按钮？",
            settings: makeSettings(modelId: "gpt-4o", configureOCR: true, supportsImageInput: true)
        )

        XCTAssertEqual(result, "截图里看到了登录按钮。")
        let messages = try XCTUnwrap(provider.messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].toText().contains("untrusted page content"))
        let userParts = messages[1].parts
        XCTAssertTrue(userParts.contains { ($0 as? UIMessagePart.Text)?.text == "截图里是否显示登录按钮？" })
        let image = try XCTUnwrap(userParts.compactMap { $0 as? UIMessagePart.Image }.first)
        XCTAssertEqual(image.url, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        XCTAssertEqual(provider.params?.tools.count, 0)
    }

    func testReadUsesImageCapableCurrentChatModelWhenOCRIsUnset() async throws {
        let provider = RecordingProvider(result: "视觉确认完成。")
        let reader = IOSWebMountVisionReader(textProvider: provider)

        _ = try await reader.read(
            capture: capture(),
            question: "页面是否已经加载？",
            settings: makeSettings(modelId: "gpt-4o", configureOCR: false, supportsImageInput: true)
        )

        XCTAssertEqual(provider.params?.model.modelId, "gpt-4o")
    }

    func testReadPrefersNativeVisionCurrentChatModelOverConfiguredOCRModel() async throws {
        let provider = RecordingProvider(result: "使用当前聊天模型完成视觉确认。")
        let reader = IOSWebMountVisionReader(textProvider: provider)

        _ = try await reader.read(
            capture: capture(),
            question: "检查页面",
            settings: makeSettingsWithNativeVisionAndConfiguredOCR()
        )

        XCTAssertEqual(provider.params?.model.modelId, "gpt-4o")
    }

    func testReadFallsBackToDifferentConfiguredOCRModelWhenCurrentChatLacksImageInput() async throws {
        let provider = RecordingProvider(result: "使用辅助视觉模型完成确认。")
        let reader = IOSWebMountVisionReader(textProvider: provider)

        _ = try await reader.read(
            capture: capture(),
            question: "检查页面",
            settings: makeSettingsWithNativeVisionAndConfiguredOCR(
                nativeModelId: "text-native",
                nativeSupportsImageInput: false
            )
        )

        XCTAssertEqual(provider.params?.model.modelId, "text-ocr")
    }

    func testNativeVisionProviderFailureDoesNotFallBackToOCRModel() async throws {
        let provider = RecordingProvider(result: "must not be called")
        let reader = IOSWebMountVisionReader(textProvider: provider)

        do {
            _ = try await reader.read(
                capture: capture(),
                question: "检查页面",
                settings: makeSettingsWithNativeVisionAndConfiguredOCR(nativeAPIKey: "")
            )
            XCTFail("Expected native vision provider configuration error")
        } catch let error as IOSWebMountVisionReader.Error {
            XCTAssertEqual(error, .visionProviderUnavailable)
            XCTAssertNil(provider.params)
        }
    }

    func testReadRejectsMissingVisionConfiguration() async throws {
        let reader = IOSWebMountVisionReader(textProvider: RecordingProvider(result: "unused"))

        do {
            _ = try await reader.read(
                capture: capture(),
                question: "看一下页面",
                settings: makeSettings(modelId: "text-only-model", configureOCR: false)
            )
            XCTFail("Expected no visual model error")
        } catch let error as IOSWebMountVisionReader.Error {
            XCTAssertEqual(error, .noVisionModel)
        }
    }

    func testReadRejectsExplicitTextOnlyOCRModel() async throws {
        let provider = RecordingProvider(result: "must not be called")
        let reader = IOSWebMountVisionReader(textProvider: provider)

        do {
            _ = try await reader.read(
                capture: capture(),
                question: "看一下页面",
                settings: makeSettings(modelId: "text-only-model", configureOCR: true)
            )
            XCTFail("Expected explicit text-only OCR model to be rejected")
        } catch let error as IOSWebMountVisionReader.Error {
            XCTAssertEqual(error, .noVisionModel)
            XCTAssertNil(provider.params)
        }
    }

    func testReadAllowsExplicitlySelectedOCRModelWhenCapabilityMetadataIsUnknown() async throws {
        let provider = RecordingProvider(result: "使用用户选择的模型完成读取。")
        let reader = IOSWebMountVisionReader(textProvider: provider)

        _ = try await reader.read(
            capture: capture(),
            question: "检查页面",
            settings: makeSettingsWithNativeVisionAndConfiguredOCR(
                nativeModelId: "text-native",
                nativeSupportsImageInput: false,
                ocrModelId: "custom-vision-unknown",
                ocrInputModalities: []
            )
        )

        XCTAssertEqual(provider.params?.model.modelId, "custom-vision-unknown")
    }

    func testReadRejectsNonPNGOrMismatchedPNGCapture() async throws {
        let reader = IOSWebMountVisionReader(textProvider: RecordingProvider(result: "must not be called"))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let cases = [
            IOSWebMountScreenshotCapture(data: png, width: 1, height: 1, format: "jpeg"),
            IOSWebMountScreenshotCapture(data: Data([0, 1, 2]), width: 1, height: 1, format: "png"),
            IOSWebMountScreenshotCapture(data: png, width: 2, height: 1, format: "png")
        ]

        for capture in cases {
            do {
                _ = try await reader.read(
                    capture: capture,
                    question: "检查页面",
                    settings: makeSettings(modelId: "gpt-4o", configureOCR: true, supportsImageInput: true)
                )
                XCTFail("Expected invalid PNG capture to be rejected")
            } catch let error as IOSWebMountVisionReader.Error {
                XCTAssertEqual(error, .screenshotUnavailable)
            }
        }
    }

    func testReadRejectsEmptyProviderResult() async throws {
        let reader = IOSWebMountVisionReader(textProvider: RecordingProvider(result: ""))

        do {
            _ = try await reader.read(
            capture: capture(),
            question: "页面上有什么？",
                settings: makeSettings(modelId: "gpt-4o", configureOCR: true, supportsImageInput: true)
            )
            XCTFail("Expected empty response error")
        } catch let error as IOSWebMountVisionReader.Error {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    func testReadHidesProviderFailureDetails() async throws {
        let provider = RecordingProvider(failure: NSError(
            domain: "provider",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "apiKey=secret response body=private"]
        ))
        let reader = IOSWebMountVisionReader(textProvider: provider)

        do {
            _ = try await reader.read(
                capture: capture(),
                question: "验证页面",
                settings: makeSettings(modelId: "gpt-4o", configureOCR: true, supportsImageInput: true)
            )
            XCTFail("Expected provider failure")
        } catch let error as IOSWebMountVisionReader.RequestFailure {
            XCTAssertEqual(error.model, "gpt-4o")
            XCTAssertEqual(error.provider, "Vision Test")
            XCTAssertEqual(error.category, "provider_error")
            XCTAssertNil(error.httpStatus, "An arbitrary NSError code is not an HTTP status")
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
    }

    func testRequestDiagnosticsExtractOnlyKnownHTTPStatusAndNetworkCode() {
        for prefix in ["OpenAI", "OpenAI Responses", "Claude"] {
            let failure = IOSWebMountVisionReader.RequestFailure(
                error: NSError(domain: "Kotlin", code: 0, userInfo: [
                    "KotlinException": KotlinException(message: "\(prefix) request failed: 400 apiKey=secret image=private")
                ]), model: "vision-model", provider: "Vision"
            )
            XCTAssertEqual(failure.httpStatus, 400)
            XCTAssertEqual(failure.category, "request_rejected")
            XCTAssertFalse(failure.localizedDescription.contains("secret"))
            XCTAssertFalse(failure.localizedDescription.contains("private"))
            XCTAssertEqual(failure.diagnostics["http_status"] as? Int, 400)
        }
        let timeout = IOSWebMountVisionReader.RequestFailure(
            error: URLError(.timedOut), model: "vision-model", provider: "Vision"
        )
        XCTAssertEqual(timeout.category, "timeout")
        XCTAssertEqual(timeout.networkCode, NSURLErrorTimedOut)
        XCTAssertNil(timeout.httpStatus)
    }

    func testRequestDiagnosticsExplainCodexRejectionsWithoutEchoingResponseContent() {
        for (detail, parameter) in [
            ("Stream must be set to true", "stream"),
            ("Unsupported parameter: max_output_tokens", "max_output_tokens")
        ] {
            let failure = IOSWebMountVisionReader.RequestFailure(
                error: NSError(domain: "Kotlin", code: 0, userInfo: [
                    "KotlinException": KotlinException(message: "HTTP 400: {\"detail\":\"\(detail)\"}")
                ]), model: "gpt-6-astra", provider: "Codex"
            )
            XCTAssertEqual(failure.httpStatus, 400)
            XCTAssertEqual(failure.providerErrorParameter, parameter)
            XCTAssertNotNil(failure.providerErrorReason)
        }
        let failure = IOSWebMountVisionReader.RequestFailure(
            error: NSError(domain: "Kotlin", code: 0, userInfo: [
                "KotlinException": KotlinException(message: #"OpenAI Responses request failed: 400 {"error":{"code":"invalid_value","param":"input[0].content","message":"apiKey=secret screenshot=private data:image/png;base64,private"}}"#)
            ]), model: "gpt-6-astra", provider: "Codex"
        )
        XCTAssertEqual(failure.diagnostics["provider_error_code"] as? String, "invalid_value")
        XCTAssertEqual(failure.diagnostics["provider_error_param"] as? String, "input[0].content")
        XCTAssertNil(failure.providerErrorReason)
        XCTAssertFalse(failure.localizedDescription.contains("secret"))
        XCTAssertFalse(String(describing: failure.diagnostics).contains("private"))
    }

    func testReadPropagatesCancellation() async throws {
        let provider = BlockingProvider()
        let reader = IOSWebMountVisionReader(textProvider: provider)
        let task = Task { @MainActor in
            try await reader.read(
                capture: capture(),
                question: "等待页面稳定",
                settings: makeSettings(modelId: "gpt-4o", configureOCR: true, supportsImageInput: true)
            )
        }

        while !provider.started {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(provider.observedCancellation)
        }
    }

    private func capture() -> IOSWebMountScreenshotCapture {
        IOSWebMountScreenshotCapture(
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
            width: 1,
            height: 1,
            format: "png"
        )
    }

    private func makeSettings(
        modelId: String,
        configureOCR: Bool,
        supportsImageInput: Bool = false
    ) -> Settings {
        let suite = "WebMountVision-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let provider = makeOpenAIProvider(
            name: "Vision Test",
            apiKey: "sk-test",
            baseUrl: "https://example.test/v1",
            modelName: modelId,
            modelId: modelId,
            supportsImageInput: supportsImageInput
        )
        let added = store.addProvider(provider)
        let model = added.models[0]
        store.setCurrentChatModelId(model.id.description())
        store.setOcrModelId(configureOCR ? model.id.description() : "")
        return store.snapshot
    }

    private func makeSettingsWithNativeVisionAndConfiguredOCR(
        nativeModelId: String = "gpt-4o",
        nativeAPIKey: String = "sk-native",
        nativeSupportsImageInput: Bool = true,
        ocrModelId: String = "text-ocr",
        ocrInputModalities: [Modality] = [Modality.text, Modality.image]
    ) -> Settings {
        let suite = "WebMountVision-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = IOSSharedSettingsStore(userDefaults: defaults)
        let nativeProvider = makeOpenAIProvider(
            name: "Native Vision Test",
            apiKey: nativeAPIKey,
            baseUrl: "https://native.example/v1",
            modelName: nativeModelId,
            modelId: nativeModelId,
            supportsImageInput: nativeSupportsImageInput
        )
        let ocrProvider = makeOpenAIProvider(
            name: "OCR Test",
            apiKey: "sk-ocr",
            baseUrl: "https://ocr.example/v1",
            modelName: "OCR Model",
            modelId: ocrModelId,
            supportsImageInput: true,
            inputModalities: ocrInputModalities
        )
        let native = store.addProvider(nativeProvider).models[0]
        let ocr = store.addProvider(ocrProvider).models[0]
        store.setCurrentChatModelId(native.id.description())
        store.setOcrModelId(ocr.id.description())
        return store.snapshot
    }

    private func makeOpenAIProvider(
        name: String,
        apiKey: String,
        baseUrl: String,
        modelName: String,
        modelId: String,
        supportsImageInput: Bool,
        inputModalities: [Modality]? = nil
    ) -> ProviderSetting.OpenAI {
        let model = Model(
            modelId: modelId,
            displayName: modelName,
            id: KotlinUuid.companion.random(),
            type: ModelType.chat,
            customHeaders: [],
            customBodies: [],
            inputModalities: inputModalities ?? (supportsImageInput ? [Modality.text, Modality.image] : [Modality.text]),
            outputModalities: [Modality.text],
            abilities: [],
            tools: Set<BuiltInTools>(),
            contextWindowTokens: nil,
            providerOverwrite: nil
        )
        return ProviderSetting.OpenAI(
            id: KotlinUuid.companion.random(),
            enabled: true,
            name: name,
            models: [model],
            balanceOption: BalanceOption(enabled: false, apiPath: "", resultPath: ""),
            builtIn: false,
            descriptionText: nil,
            shortDescriptionText: nil,
            apiKey: apiKey,
            baseUrl: baseUrl,
            chatCompletionsPath: "/chat/completions",
            useResponseApi: false,
            authMode: OpenAIAuthMode.apiKey,
            brand: OpenAIBrand.generic
        )
    }
}

private final class RecordingProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let result: String?
    private let failure: Swift.Error?
    private let lock = NSLock()
    private(set) var messages: [UIMessage]?
    private(set) var params: TextGenerationParams?

    init(result: String) {
        self.result = result
        self.failure = nil
    }

    init(failure: Swift.Error) {
        self.result = nil
        self.failure = failure
    }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        lock.withLock {
            self.messages = messages
            self.params = params
        }
        if let failure { throw failure }
        let answer = UIMessage.companion.assistant(prompt: result ?? "")
        return MessageChunk(
            id: "vision-test",
            model: params.model.modelId,
            choices: [UIMessageChoice(index: 0, delta: nil, message: answer, finishReason: "stop")],
            usage: nil
        )
    }
}

private final class BlockingProvider: IOSAgentTextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _observedCancellation = false

    var started: Bool { lock.withLock { _started } }
    var observedCancellation: Bool { lock.withLock { _observedCancellation } }

    func generateText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams
    ) async throws -> MessageChunk {
        lock.withLock { _started = true }
        do {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            lock.withLock { _observedCancellation = Task.isCancelled }
            throw error
        }
    }
}
