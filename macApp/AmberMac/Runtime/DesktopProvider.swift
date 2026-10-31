import Foundation
@preconcurrency import Shared

@MainActor final class DesktopKMPProvider: DesktopTextProvider {
    private let openAI = OpenAIKmpProvider()
    private let claude = ClaudeKmpProvider()

    func userMessage(id: UUID, text: String, attachments: [DesktopMessageAttachment]) throws -> DesktopMessage {
        try DesktopJSON.decode(DesktopMessage.self, from: DesktopProviderBridge.shared.userMessage(
            id: id.uuidString, text: text, attachmentsJSON: DesktopJSON.encode(attachments)))
    }

    func start(configuration: DesktopProviderConfiguration, apiKey: String,
        messages: [DesktopMessage], responseID: UUID) throws -> DesktopGeneration {
        guard !messages.isEmpty else { throw DesktopRuntimeError.message("请先提供用户消息再开始生成。") }
        guard let model = configuration.selectedModel else { throw DesktopRuntimeError.message("请先选择已启用的模型。") }
        let bridge = DesktopProviderBridge.shared
        let params = try bridge.paramsFromJSON(json: DesktopJSON.encode(model))
        let input = try bridge.messages(json: DesktopJSON.encode(messages))
        let run = DesktopGeneration()
        if configuration.authMode == .codexOAuth {
            let task = Task {
                do {
                    let providerID = configuration.id.uuidString.lowercased()
                    let token = try await IOSCodexOAuthClient(providerId: providerID).getValidAccessToken()
                    try Task.checkCancellation()
                    let provider = try bridge.configurationWithAuth(kind: "responses", id: configuration.id.uuidString,
                        name: configuration.name, baseUrl: IOSCodexOAuthConstants.codexBackendBaseUrl,
                        apiKey: token, authMode: configuration.authMode.rawValue)
                    let codexParams = bridge.withCodexHeaders(params: params,
                        accountID: IOSCodexAuthStore.load(providerId: providerID)?.accountId,
                        originator: IOSCodexOAuthConstants.originator)
                    try self.startKMP(provider: provider, messages: input, params: codexParams, responseID: responseID, run: run)
                } catch is CancellationError { run.yield(.cancelled) }
                catch { run.yield(.failed(Self.failureMessage(error.localizedDescription))) }
            }
            run.installCancellation { task.cancel() }
            return run
        }
        if configuration.authMode == .grokOAuth {
            let task = Task {
                do {
                    let providerID = configuration.id.uuidString.lowercased()
                    guard IOSGrokOAuthAuthStore.load(providerId: providerID) != nil else { throw IOSGrokWebError.notSignedIn }
                    let provider = try await IOSGrokWebProviderResolver.resolved(try bridge.configurationWithAuth(
                        kind: configuration.kind.rawValue, id: configuration.id.uuidString, name: configuration.name,
                        baseUrl: IOSGrokOAuthConstants.cliProxyBaseUrl, apiKey: "", authMode: configuration.authMode.rawValue))
                    try Task.checkCancellation()
                    try self.startKMP(provider: provider, messages: input,
                        params: IOSGrokWebProviderResolver.augmentParamsForGrok(params, provider: provider),
                        responseID: responseID, run: run)
                } catch is CancellationError { run.yield(.cancelled) }
                catch { run.yield(.failed(Self.failureMessage(error.localizedDescription))) }
            }
            run.installCancellation { task.cancel() }
            return run
        }
        let provider = try bridge.configurationWithAuth(kind: configuration.kind.rawValue,
            id: configuration.id.uuidString, name: configuration.name,
            baseUrl: configuration.baseURL, apiKey: apiKey, authMode: configuration.authMode.rawValue)
        // Claude sends `cache_control` only when the provider setting asks for it; the prefix is stable per turn
        // (see DesktopContextBudget.prefixFingerprint) so it can be reused.
        if let claude = provider as? ProviderSetting.Claude, configuration.kind == .claude {
            claude.promptCaching = configuration.promptCaching
        }
        if let google = provider as? ProviderSetting.Google {
            let accumulator = DesktopKMPAccumulator(messages: input, model: params.model, responseID: responseID, run: run)
            let task = Task {
                do {
                    try await IOSGeminiClient(provider: google).streamText(messages: input, params: params) {
                        accumulator.append($0)
                    }
                    if accumulator.flushAndStop() { run.yield(.complete) }
                } catch is CancellationError { run.yield(.cancelled) }
                catch {
                    _ = accumulator.flushAndStop()
                    run.yield(.failed(Self.failureMessage(error.localizedDescription)))
                }
            }
            run.installCancellation({ task.cancel() }, flushBeforeCancellation: { _ = accumulator.flushAndStop() })
        } else {
            try startKMP(provider: provider, messages: input, params: params, responseID: responseID, run: run)
        }
        return run
    }

    private func startKMP(provider: ProviderSetting, messages: [UIMessage], params: TextGenerationParams,
        responseID: UUID, run: DesktopGeneration) throws {
        let input = messages
        // Kotlin invokes these callbacks on its own threads; they must not inherit MainActor isolation.
        let accumulator = DesktopKMPAccumulator(messages: input, model: params.model, responseID: responseID, run: run)
        let job: Kotlinx_coroutines_coreJob
        if let value = provider as? ProviderSetting.OpenAI {
            job = openAI.streamTextCancellable(providerSetting: value, messages: input, params: params,
                onChunk: { @Sendable in accumulator.append($0) },
                onComplete: { @Sendable in if accumulator.flushAndStop() { run.yield(.complete) } },
                onError: { @Sendable in
                    _ = accumulator.flushAndStop()
                    run.yield(.failed(Self.failureMessage($0.message ?? "")))
                })
        } else if let value = provider as? ProviderSetting.Claude {
            job = claude.streamTextCancellable(providerSetting: value, messages: input, params: params,
                onChunk: { @Sendable in accumulator.append($0) },
                onComplete: { @Sendable in if accumulator.flushAndStop() { run.yield(.complete) } },
                onError: { @Sendable in
                    _ = accumulator.flushAndStop()
                    run.yield(.failed(Self.failureMessage($0.message ?? "")))
                })
        } else { throw DesktopRuntimeError.message("此服务商协议尚未接入桌面版。") }
        let box = DesktopKMPJob(job)
        run.installCancellation({ box.cancel() }, flushBeforeCancellation: { _ = accumulator.flushAndStop() })
    }

    nonisolated private static func failureMessage(_ raw: String) -> String {
        // Provider bodies can echo credentials; present classified status, never raw bodies.
        if raw.contains("401") || raw.contains("403") { return "服务商拒绝认证，请检查 API Key 与账号权限后重试。" }
        if raw.contains("429") { return "服务商请求限额已到，请稍后重试或检查余额。" }
        if raw.contains("404") { return "服务商未找到模型或 API 路径，请检查地址与 Model ID。" }
        if DesktopContextBudget.isContextOverflow(raw) {
            return "本轮内容超出模型上下文窗口。Amber 已省略最早的部分消息并把摘要保留在上下文面板；仍失败时请先「压缩上下文」或换用更大窗口的模型。"
        }
        return "生成失败，请检查网络、API 地址与模型设置，然后重试。已收到的内容已保留。"
    }
}

private final class DesktopKMPJob: @unchecked Sendable {
    let value: Kotlinx_coroutines_coreJob
    init(_ value: Kotlinx_coroutines_coreJob) { self.value = value }
    func cancel() { value.cancel(cause: nil) }
}

private final class DesktopKMPAccumulator: @unchecked Sendable {
    private static let publishIntervalNanoseconds: UInt64 = 33_000_000
    private let lock = NSLock()
    private let accumulator: MessageStreamAccumulator
    private let run: DesktopGeneration
    private let responseID: UUID
    private let timerQueue = DispatchQueue(label: "app.amber.mac.kmp-snapshot", qos: .userInitiated)
    private var timer: DispatchWorkItem?
    private var dirty = false
    private var stopped = false
    private var lastPublishedUptime: UInt64?

    init(messages: [UIMessage], model: Model, responseID: UUID, run: DesktopGeneration) {
        accumulator = MessageStreamAccumulator(initialMessages: messages, model: model)
        self.run = run
        self.responseID = responseID
    }

    func append(_ chunk: MessageChunk) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        accumulator.append(chunk: chunk)
        dirty = true
        let now = DispatchTime.now().uptimeNanoseconds
        let flushNow: Bool
        if let lastPublishedUptime {
            flushNow = now >= lastPublishedUptime
                && now - lastPublishedUptime >= Self.publishIntervalNanoseconds
        } else {
            flushNow = true
        }
        if flushNow {
            timer?.cancel()
            timer = nil
        } else {
            scheduleFlushLocked(now: now, lastPublishedUptime: lastPublishedUptime)
        }
        lock.unlock()
        if flushNow { _ = publishCurrent() }
    }

    @discardableResult
    func flushAndStop() -> Bool {
        lock.lock()
        stopped = true
        timer?.cancel()
        timer = nil
        lock.unlock()
        return publishCurrent()
    }

    private func scheduleFlushLocked(now: UInt64, lastPublishedUptime: UInt64?) {
        guard timer == nil, !stopped else { return }
        let elapsed = lastPublishedUptime.map { now >= $0 ? now - $0 : 0 } ?? 0
        let delay = max(1, Self.publishIntervalNanoseconds - min(Self.publishIntervalNanoseconds, elapsed))
        let work = DispatchWorkItem { [weak self] in _ = self?.publishCurrent() }
        timer = work
        timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: work)
    }

    @discardableResult
    private func publishCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        guard dirty else {
            return true
        }
        dirty = false
        lastPublishedUptime = DispatchTime.now().uptimeNanoseconds
        let input = Array(accumulator.snapshot().suffix(1))
        do {
            let json = try DesktopProviderBridge.shared.snapshot(messages: input, assistantId: responseID.uuidString)
            let messages = try DesktopJSON.decode([DesktopMessage].self, from: json)
            if let last = messages.last, last.role == .assistant {
                run.yield(.snapshot(text: last.text, reasoning: last.reasoning,
                    canonicalJSON: last.canonicalJSON, unsupportedPartCount: last.unsupportedPartCount, tools: last.tools))
            }
            return true
        } catch {
            run.yield(.failed("无法读取服务商返回的消息，请重试。"))
            return false
        }
    }
}
