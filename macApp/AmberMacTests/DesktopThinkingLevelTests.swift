import Darwin
import Foundation
import XCTest
@testable import AmberMac

@MainActor
final class DesktopThinkingLevelTests: XCTestCase {
    private final class CapturingProvider: DesktopTextProvider {
        var configurations: [DesktopProviderConfiguration] = []
        var requests: [[DesktopMessage]] = []

        func start(
            configuration: DesktopProviderConfiguration,
            apiKey: String,
            messages: [DesktopMessage],
            responseID: UUID
        ) throws -> DesktopGeneration {
            configurations.append(configuration)
            requests.append(messages)
            return DesktopGeneration()
        }
    }

    func testSupportedLevelsMatchProviderCapabilitiesAndHideUnsupportedModels() {
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "o3", kind: .openAI),
            [.off, .low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "gpt-5.4", kind: .responses),
            [.off, .low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "claude-sonnet-4-5-20250929", kind: .claude),
            [.off, .auto, .low, .medium, .high, .max]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "claude-sonnet-4-6", kind: .claude),
            [.off, .auto, .low, .medium, .high]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "claude-opus-4-7", kind: .claude),
            [.off, .auto, .low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "deepseek-chat", kind: .openAI, providerName: "DeepSeek"),
            [.off, .auto]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "deepseek-v4", kind: .openAI, providerName: "DeepSeek"),
            [.off, .low, .high, .max]
        )
        XCTAssertEqual(
            DesktopThinkingPolicy.supportedLevels(modelID: "gemini-2.5-pro", kind: .gemini),
            [.off, .auto, .low, .medium, .high]
        )

        // Unsupported models must return empty so the composer hides the thinking icon.
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "gpt-4o", kind: .openAI).isEmpty)
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "gpt-4o-mini", kind: .openAI).isEmpty)
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "gpt-4.1", kind: .openAI).isEmpty)
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "gpt-5-chat", kind: .openAI).isEmpty)
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "claude-3-haiku-20240307", kind: .claude).isEmpty)
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "claude-3-5-sonnet-20241022", kind: .claude).isEmpty)
        XCTAssertTrue(DesktopThinkingPolicy.supportedLevels(modelID: "gemini-2.0-flash", kind: .gemini).isEmpty)
    }

    func testPerModelPersistencePreservesDefaultAndCoercesAcrossModelSwitches() throws {
        let suite = "amber.thinking.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let credentials = DesktopMemoryCredentials()
        let settings = DesktopSettings(defaults: defaults, credentials: credentials)
        let o3 = DesktopModelConfiguration(modelID: "o3", name: "o3")
        let gpt4o = DesktopModelConfiguration(modelID: "gpt-4o", name: "GPT-4o")
        let config = DesktopProviderConfiguration(
            name: "OpenAI",
            kind: .openAI,
            baseURL: "https://api.openai.com/v1",
            models: [o3, gpt4o],
            selectedModelID: o3.id
        )
        try settings.saveProvider(config, apiKey: "sk-test")

        let provider = CapturingProvider()
        let conversation = DesktopConversation(title: "思考等级")
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider,
            initialConversations: [conversation]
        )

        // Default behavior stays .off until the user selects a thinking level.
        XCTAssertTrue(workspace.isThinkingLevelAvailable)
        XCTAssertEqual(workspace.selectedThinkingLevel, .off)

        workspace.setThinkingLevel(.high)
        XCTAssertEqual(workspace.selectedThinkingLevel, .high)

        // Relaunching settings from the same UserDefaults keeps the per-model choice.
        let relaunched = DesktopSettings(defaults: defaults, credentials: credentials)
        XCTAssertEqual(relaunched.selectedModelReasoning, .high)

        // Switching to gpt-4o hides the thinking selector and sends .off.
        settings.selectModel(gpt4o.id)
        XCTAssertFalse(workspace.isThinkingLevelAvailable)
        XCTAssertEqual(workspace.selectedThinkingLevel, .off)

        // Switching back to o3 restores .high and passes it into the provider request configuration.
        settings.selectModel(o3.id)
        XCTAssertTrue(workspace.isThinkingLevelAvailable)
        XCTAssertEqual(workspace.selectedThinkingLevel, .high)

        workspace.draft = "测试推理参数"
        workspace.send()
        XCTAssertEqual(provider.configurations.last?.selectedModel?.reasoning, .high)
    }

    func testBoostAndThinkingLevelCoexistWithoutOverwritingEachOther() throws {
        let suite = "amber.thinking.boost.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = DesktopSettings(defaults: defaults, credentials: DesktopMemoryCredentials())
        var config = try XCTUnwrap(settings.selectedProvider)
        config.name = "DeepSeek"
        config.baseURL = "https://api.deepseek.com/v1"
        config.modelID = "deepseek-v4"
        try settings.saveProvider(config, apiKey: "sk-deepseek")

        let provider = CapturingProvider()
        let conversation = DesktopConversation(title: "DeepSeek Boost + Thinking")
        let boost = DesktopDeepSeekBoostStore(defaults: defaults)
        let workspace = DesktopWorkspace(
            settings: settings,
            storage: DesktopMemoryConversationStorage([conversation]),
            provider: provider,
            initialConversations: [conversation],
            boost: boost
        )

        XCTAssertTrue(workspace.isBoostAvailable)
        XCTAssertTrue(workspace.isThinkingLevelAvailable)
        XCTAssertEqual(workspace.supportedThinkingLevels, [.off, .low, .high, .max])

        workspace.toggleBoost()
        workspace.setThinkingLevel(.max)
        XCTAssertTrue(workspace.isBoostActive)
        XCTAssertEqual(workspace.selectedThinkingLevel, .max)

        workspace.draft = "请深入分析"
        workspace.send()

        let sentConfig = try XCTUnwrap(provider.configurations.last)
        let sentMessages = try XCTUnwrap(provider.requests.last)
        XCTAssertEqual(sentConfig.selectedModel?.reasoning, .max)
        XCTAssertEqual(sentMessages.first(where: { $0.role == .system })?.text, DesktopDeepSeekBoost.prompt)

        // Turning off /boost only removes the system prompt suffix; the model's thinking level stays .max.
        workspace.toggleBoost()
        XCTAssertFalse(workspace.isBoostActive)
        XCTAssertEqual(workspace.selectedThinkingLevel, .max)
    }

    func testOpenAIAndClaudeRequestBodiesIncludeSelectedThinkingLevelFields() async throws {
        let capture = try LoopbackRequestCaptureServer()
        defer { capture.stop() }

        let kmp = DesktopKMPProvider()

        // 1. OpenAI reasoning model (o3 -> reasoning_effort: "high")
        let openAIModel = DesktopModelConfiguration(modelID: "o3", name: "o3", reasoning: .high)
        let openAIConfig = DesktopProviderConfiguration(
            name: "OpenAI",
            kind: .openAI,
            baseURL: capture.baseURL + "/v1",
            models: [openAIModel],
            selectedModelID: openAIModel.id
        )
        let openAIRun = try kmp.start(
            configuration: openAIConfig,
            apiKey: "sk-test-openai",
            messages: [DesktopMessage(role: .user, text: "Hello OpenAI")],
            responseID: UUID()
        )
        _ = try await collectUntilComplete(openAIRun)
        let openAIBody = try XCTUnwrap(capture.recordedBodies.last)
        XCTAssertEqual(openAIBody["model"] as? String, "o3")
        XCTAssertEqual(openAIBody["reasoning_effort"] as? String, "high")

        // 2. Claude extended thinking model (claude-sonnet-4-5-20250929 -> thinking: {type: "enabled", budget_tokens: 8000})
        let claudeLegacyModel = DesktopModelConfiguration(
            modelID: "claude-sonnet-4-5-20250929",
            name: "Claude Sonnet 4.5",
            reasoning: .high
        )
        let claudeLegacyConfig = DesktopProviderConfiguration(
            name: "Claude",
            kind: .claude,
            baseURL: capture.baseURL + "/v1",
            models: [claudeLegacyModel],
            selectedModelID: claudeLegacyModel.id
        )
        let claudeLegacyRun = try kmp.start(
            configuration: claudeLegacyConfig,
            apiKey: "sk-ant-test",
            messages: [DesktopMessage(role: .user, text: "Hello Claude 4.5")],
            responseID: UUID()
        )
        _ = try await collectUntilComplete(claudeLegacyRun)
        let claudeLegacyBody = try XCTUnwrap(capture.recordedBodies.last)
        let claudeThinking = try XCTUnwrap(claudeLegacyBody["thinking"] as? [String: Any])
        XCTAssertEqual(claudeThinking["type"] as? String, "enabled")
        XCTAssertEqual(claudeThinking["budget_tokens"] as? Int, 8_000)

        // 3. Claude adaptive thinking model (claude-sonnet-4-6 -> thinking.type = "adaptive", output_config.effort = "medium")
        let claudeAdaptiveModel = DesktopModelConfiguration(
            modelID: "claude-sonnet-4-6",
            name: "Claude Sonnet 4.6",
            reasoning: .medium
        )
        let claudeAdaptiveConfig = DesktopProviderConfiguration(
            name: "Claude",
            kind: .claude,
            baseURL: capture.baseURL + "/v1",
            models: [claudeAdaptiveModel],
            selectedModelID: claudeAdaptiveModel.id
        )
        let claudeAdaptiveRun = try kmp.start(
            configuration: claudeAdaptiveConfig,
            apiKey: "sk-ant-test",
            messages: [DesktopMessage(role: .user, text: "Hello Claude 4.6")],
            responseID: UUID()
        )
        _ = try await collectUntilComplete(claudeAdaptiveRun)
        let claudeAdaptiveBody = try XCTUnwrap(capture.recordedBodies.last)
        let adaptiveThinking = try XCTUnwrap(claudeAdaptiveBody["thinking"] as? [String: Any])
        let outputConfig = try XCTUnwrap(claudeAdaptiveBody["output_config"] as? [String: Any])
        XCTAssertEqual(adaptiveThinking["type"] as? String, "adaptive")
        XCTAssertEqual(outputConfig["effort"] as? String, "medium")
    }

    private func collectUntilComplete(_ run: DesktopGeneration) async throws -> [DesktopProviderEvent] {
        var collected: [DesktopProviderEvent] = []
        for _ in 0..<200 {
            let batch = run.drain()
            collected.append(contentsOf: batch)
            if collected.contains(where: {
                if case .complete = $0 { return true }
                if case .failed = $0 { return true }
                if case .cancelled = $0 { return true }
                return false
            }) {
                return collected
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for generation to finish: \(collected)")
        return collected
    }
}

private final class LoopbackRequestCaptureServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false
    private(set) var recordedBodies: [[String: Any]] = []

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        if !wasStopped {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            if clientFD < 0 { break }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEndIndex: Int?
        var expectedContentLength = 0

        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if headerEndIndex == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEndIndex = range.upperBound
                let headerString = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                for line in headerString.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                        expectedContentLength = Int(value) ?? 0
                    }
                }
            }
            if let headerEndIndex, data.count >= headerEndIndex + expectedContentLength {
                break
            }
        }

        guard let headerEndIndex else { return }
        let headerString = String(decoding: data[..<(headerEndIndex - 4)], as: UTF8.self)
        let requestLine = headerString.components(separatedBy: "\r\n").first ?? ""
        let isClaude = requestLine.contains("/messages")
        let bodyData = data.subdata(in: headerEndIndex..<min(data.count, headerEndIndex + expectedContentLength))
        if let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
            lock.lock()
            recordedBodies.append(json)
            lock.unlock()
        }

        let ssePayload: String
        if isClaude {
            ssePayload = [
                #"event: message_start"#,
                #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":4,"output_tokens":0}}}"#,
                "",
                #"event: content_block_start"#,
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                "",
                #"event: content_block_delta"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
                "",
                #"event: content_block_stop"#,
                #"data: {"type":"content_block_stop","index":0}"#,
                "",
                #"event: message_delta"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}"#,
                "",
                #"event: message_stop"#,
                #"data: {"type":"message_stop"}"#,
                "",
                ""
            ].joined(separator: "\n")
        } else {
            ssePayload = [
                #"data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"o3","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#,
                "",
                #"data: [DONE]"#,
                "",
                ""
            ].joined(separator: "\n")
        }

        let responseData = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" + ssePayload).utf8)
        _ = responseData.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
    }
}
