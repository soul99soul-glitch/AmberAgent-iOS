import Foundation
import Observation
@preconcurrency import Shared

@MainActor
protocol IOSCouncilResearching {
    func research(
        objective: String,
        settings: Settings?,
        maxSearches: Int,
        maxScrapes: Int
    ) async -> IOSCouncilResearchBundle
}

@MainActor
struct IOSCouncilSearchResearcher: IOSCouncilResearching {
    var transport: any IOSSearchHTTPTransport = IOSURLSessionSearchHTTPTransport()

    func research(
        objective: String,
        settings: Settings?,
        maxSearches: Int = 4,
        maxScrapes: Int = 4
    ) async -> IOSCouncilResearchBundle {
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return IOSCouncilResearchBundle(searches: [], scrapedPages: [], failures: ["empty objective"])
        }

        let queries = Array([
            trimmed,
            "\(trimmed) 最新 信息",
            "\(trimmed) 分析 观点",
            "\(trimmed) 背景 影响"
        ].prefix(max(0, maxSearches)))

        var executions: [IOSSearchExecution] = []
        var scraped: [IOSCouncilScrapedPage] = []
        var failures: [String] = []
        var scrapeCandidates: [String] = []

        for query in queries {
            if Task.isCancelled {
                return IOSCouncilResearchBundle(
                    searches: executions,
                    scrapedPages: scraped,
                    failures: failures
                )
            }
            do {
                let input = Self.json(["query": query, "max_results": 5])
                let execution = try await IOSSearchExecutor.searchResults(
                    toolInput: input,
                    maxResults: 5,
                    settings: settings,
                    transport: transport
                )
                executions.append(execution)
                scrapeCandidates.append(contentsOf: execution.results.map(\.url))
            } catch {
                if Task.isCancelled {
                    return IOSCouncilResearchBundle(
                        searches: executions,
                        scrapedPages: scraped,
                        failures: failures
                    )
                }
                failures.append("search_web \(query): \(error.localizedDescription)")
            }
        }

        var seen = Set<String>()
        for url in scrapeCandidates where scraped.count < maxScrapes {
            if Task.isCancelled {
                return IOSCouncilResearchBundle(
                    searches: executions,
                    scrapedPages: scraped,
                    failures: failures
                )
            }
            guard seen.insert(url).inserted else { continue }
            do {
                let input = Self.json(["url": url, "max_chars": 4_000])
                let content = try await IOSSearchExecutor.execute(
                    toolName: "scrape_web",
                    toolInput: input,
                    maxResults: 1,
                    settings: settings,
                    transport: transport
                )
                scraped.append(IOSCouncilScrapedPage(url: url, content: content))
            } catch {
                if Task.isCancelled {
                    return IOSCouncilResearchBundle(
                        searches: executions,
                        scrapedPages: scraped,
                        failures: failures
                    )
                }
                failures.append("scrape_web \(url): \(error.localizedDescription)")
            }
        }

        return IOSCouncilResearchBundle(searches: executions, scrapedPages: scraped, failures: failures)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }
}

@MainActor
protocol IOSCouncilTextStreaming: AnyObject {
    /// `onUpdate` 携带 (可见前缀文本, 滚动跟随滞后允许度)。流式拍恒为 1；
    /// 终态排空拍随剩余积压连续衰减到 0（与 Chat/小说同源，驱动收紧 τ_eff）。
    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String

    func cancel()
}

/// A presentation-only gate for council text streams. Provider chunks continue to
/// accumulate losslessly; the expensive full snapshot is deferred until the one
/// scheduled UI flush (or an exact terminal/cancel flush).
///
/// 节奏层（与小说的 `NovelSessionPresentationPacer` 共用
/// `StreamPresentationPacingPolicy`）：
/// 每个 48ms 刷新窗只发布一个节奏拍（流式 `textAdvance` 预算），大积压时
/// 自续拍直到追平——上游再快，显示侧仍以平滑节拍输出，模型慢时零损失。
/// 完成路径走 `drainAndClose`：以锚速 whoosh 中段 + 优雅尾连续减速收尾，
/// 每拍透出随剩余积压衰减的 lagAllowance。
@MainActor
final class IOSCouncilTextPresentationSession {
    private let flushDelayNanoseconds: UInt64
    private let snapshotProvider: @MainActor () -> String
    private let onUpdate: @MainActor (String, CGFloat) -> Void
    private var flushTask: Task<Void, Never>?
    private var lastPublishedText: String?
    private(set) var isClosed = false
    private(set) var finalText = ""

    init(
        flushDelayNanoseconds: UInt64 = 48_000_000,
        snapshotProvider: @escaping @MainActor () -> String,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) {
        self.flushDelayNanoseconds = flushDelayNanoseconds
        self.snapshotProvider = snapshotProvider
        self.onUpdate = onUpdate
    }

    func scheduleFlush() {
        guard !isClosed, flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.flushDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, !self.isClosed else { return }
            self.flushTask = nil
            // 一个刷新窗一拍；未追平（provider 快于显示节拍）时自续下一个窗，
            // 保持 48ms 稳定节拍直到积压清空。
            if !self.publishBeat(from: self.snapshotProvider(), terminal: false, fixedAdvance: nil, drainStartBacklog: nil) {
                self.scheduleFlush()
            }
        }
    }

    /// Cancels any delayed publication and synchronously exposes the exact latest
    /// authoritative text before the caller publishes failed/cancelled state.
    /// 失败/取消不做优雅排空（与 Chat 错误路径一致：整段一次落定）。
    @discardableResult
    func flushAndClose() -> String {
        if isClosed {
            if lastPublishedText != finalText {
                lastPublishedText = finalText
                onUpdate(finalText, 1)
            }
            return finalText
        }
        isClosed = true
        flushTask?.cancel()
        flushTask = nil
        let text = snapshotProvider()
        finalText = text
        if lastPublishedText != text {
            lastPublishedText = text
            onUpdate(text, 1)
        }
        return text
    }

    /// 完成路径的终态排空：以完成时积压一次定锚，每拍随剩余积压连续减速
    /// （`terminalTextAdvance` 优雅尾），拍间隔按减速后的实际拍速逐拍重算
    /// （8ms whoosh → 48ms 打字节奏），每拍透出 `lagAllowance`（1→0）。
    /// 取消/中断时立即落定权威全文，绝不留半截前缀上屏。
    func drainAndClose() async -> String {
        guard !isClosed else { return finalText }
        isClosed = true
        flushTask?.cancel()
        flushTask = nil
        let target = snapshotProvider()
        finalText = target
        let drainStartBacklog = max(0, target.count - (lastPublishedText?.count ?? 0))
        guard drainStartBacklog > 0 else {
            if lastPublishedText != target {
                lastPublishedText = target
                onUpdate(target, 0)
            }
            return target
        }
        let drainAdvance = StreamPresentationPacingPolicy.terminalDrainAdvance(
            backlogCount: drainStartBacklog
        )
        while !Task.isCancelled {
            if publishBeat(
                from: target,
                terminal: true,
                fixedAdvance: drainAdvance,
                drainStartBacklog: drainStartBacklog
            ) {
                return target
            }
            let remainingBefore = max(0, target.count - (lastPublishedText?.count ?? 0))
            let beatAdvance = StreamPresentationPacingPolicy.terminalTextAdvance(
                backlogCount: remainingBefore,
                fixedAdvance: drainAdvance
            )
            do {
                try await Task.sleep(
                    nanoseconds: StreamPresentationPacingPolicy.terminalDrainDelayNanos(
                        advance: beatAdvance
                    )
                )
            } catch {
                break
            }
        }
        if lastPublishedText != target {
            lastPublishedText = target
            onUpdate(target, 0)
        }
        return target
    }

    /// 发布一个节奏拍。返回是否已追平权威快照。
    ///
    /// 注意：不能在开头用 `!isClosed` 收口——`drainAndClose` 在排空循环前
    /// 置 `isClosed = true`（封死迟到的 flush），排空拍仍必须照常发布；
    /// 流式 flush 路径已在任务内检查 `!isClosed`。
    @discardableResult
    private func publishBeat(
        from target: String,
        terminal: Bool,
        fixedAdvance: Int?,
        drainStartBacklog: Int?
    ) -> Bool {
        let published = lastPublishedText ?? ""
        guard target != published else { return true }
        guard target.hasPrefix(published), target.count > published.count else {
            // 非前缀替换（理论不达：accumulator 只追加）：直接落定权威全文。
            lastPublishedText = target
            onUpdate(target, terminal ? 0 : 1)
            return true
        }
        let backlog = target.count - published.count
        let advance: Int
        let allowance: CGFloat
        if terminal {
            advance = StreamPresentationPacingPolicy.terminalTextAdvance(
                backlogCount: backlog,
                fixedAdvance: fixedAdvance
            )
            allowance = StreamPresentationPacingPolicy.lagAllowance(
                remainingBacklog: max(0, backlog - advance),
                drainStartBacklog: drainStartBacklog ?? max(backlog, 1)
            )
        } else {
            advance = StreamPresentationPacingPolicy.textAdvance(backlogCount: backlog)
            allowance = 1
        }
        let next = String(target.prefix(published.count + advance))
        lastPublishedText = next
        onUpdate(next, allowance)
        return next == target
    }
}

enum IOSCouncilGeneratedTextSnapshot {
    static func text(from messages: [UIMessage]) -> String {
        guard let message = messages.last,
              message.role == MessageRole.assistant else {
            return ""
        }
        return message.toText()
    }
}

@MainActor
private final class IOSCouncilActiveTextStream {
    let accumulator: MessageStreamAccumulator
    let eventSink: ChatStreamEventSink
    let presentation: IOSCouncilTextPresentationSession

    init(
        accumulator: MessageStreamAccumulator,
        eventSink: ChatStreamEventSink,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) {
        self.accumulator = accumulator
        self.eventSink = eventSink
        self.presentation = IOSCouncilTextPresentationSession(
            snapshotProvider: {
                IOSCouncilGeneratedTextSnapshot.text(from: accumulator.snapshot())
            },
            onUpdate: onUpdate
        )
    }

    func accept(_ chunk: MessageChunk) {
        guard !presentation.isClosed else { return }
        accumulator.append(chunk: chunk)
        presentation.scheduleFlush()
    }

    /// 完成路径：先收口 sink 与排空队列，再以节奏拍逐拍追平剩余积压
    /// （优雅尾减速 + lagAllowance 收紧），返回权威全文。
    func drainAndClose(drainingQueuedChunks: Bool) async -> String {
        if drainingQueuedChunks, !presentation.isClosed {
            // Close the sink first so the drained prefix has an exact acceptance
            // boundary: callbacks racing cancellation are either already queued or
            // rejected, never admitted between drain and snapshot.
            eventSink.finish()
            for chunk in eventSink.takePendingChunks() {
                accumulator.append(chunk: chunk)
            }
        }
        let text = await presentation.drainAndClose()
        eventSink.finish()
        return text
    }

    @discardableResult
    func flushAndClose(drainingQueuedChunks: Bool) -> String {
        if drainingQueuedChunks, !presentation.isClosed {
            // Close the sink first so the drained prefix has an exact acceptance
            // boundary: callbacks racing cancellation are either already queued or
            // rejected, never admitted between drain and snapshot.
            eventSink.finish()
            for chunk in eventSink.takePendingChunks() {
                accumulator.append(chunk: chunk)
            }
        }
        let text = presentation.flushAndClose()
        eventSink.finish()
        return text
    }
}

@MainActor
final class IOSCouncilTextStreamer: IOSCouncilTextStreaming {
    private let openAIProvider: OpenAIKmpProvider
    private let claudeProvider: ClaudeKmpProvider
    private var job: Kotlinx_coroutines_coreJob?
    private var grokWebStreamTask: Task<Void, Never>?
    private var activeStream: IOSCouncilActiveTextStream?

    init(
        provider: OpenAIKmpProvider = OpenAIKmpProvider(),
        claudeProvider: ClaudeKmpProvider = ClaudeKmpProvider()
    ) {
        self.openAIProvider = provider
        self.claudeProvider = claudeProvider
    }

    func streamText(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onUpdate: @escaping @MainActor (String, CGFloat) -> Void
    ) async throws -> String {
        let effectiveProvider = try await IOSGrokWebProviderResolver.resolved(
            try await IOSCodexProviderResolver.resolved(providerSetting)
        )
        let effectiveParams = IOSGrokWebProviderResolver.augmentParamsForGrok(
            IOSCodexProviderResolver.augmentParamsForCodex(
                params,
                provider: effectiveProvider
            ),
            provider: effectiveProvider
        )
        let accumulator = MessageStreamAccumulator(initialMessages: messages, model: effectiveParams.model)
        let eventSink = ChatStreamEventSink()
        let eventStream = AsyncStream<ChatStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            eventSink.bind(continuation)
        }
        let stream = IOSCouncilActiveTextStream(
            accumulator: accumulator,
            eventSink: eventSink,
            onUpdate: onUpdate
        )
        activeStream = stream

        job = dispatchCouncilStream(
            providerSetting: effectiveProvider,
            messages: messages,
            params: effectiveParams,
            onChunk: { chunk in
                eventSink.yield(.chunk(chunk))
            },
            onComplete: {
                eventSink.yield(.complete())
                eventSink.finish()
            },
            onError: { error in
                eventSink.yield(.error(error))
                eventSink.finish()
            }
        )

        for await event in eventStream {
            guard eventSink.claim(event) else { continue }
            switch event.payload {
            case .chunk(let chunk):
                stream.accept(chunk)
            case .complete:
                // 完成路径走优雅排空：锚速 whoosh 中段 + 连续减速收尾，
                // 每拍透出 lagAllowance（与 Chat/小说终态同源）。
                let text = await stream.drainAndClose(drainingQueuedChunks: false)
                clearActiveStreamIfNeeded(stream)
                return text
            case .error(let error):
                _ = stream.flushAndClose(drainingQueuedChunks: false)
                clearActiveStreamIfNeeded(stream)
                throw IOSCouncilRoomRunnerError.generationFailed(
                    error.message ?? String(describing: error)
                )
            }
        }

        let text = stream.flushAndClose(drainingQueuedChunks: true)
        if Task.isCancelled, activeStream === stream {
            job?.cancel(cause: nil)
        }
        clearActiveStreamIfNeeded(stream)
        return text
    }

    /// Dispatch a council seat stream to the OpenAI or Claude executor based on
    /// the resolved provider's sealed type. Both share streamTextCancellable.
    private func dispatchCouncilStream(
        providerSetting: ProviderSetting,
        messages: [UIMessage],
        params: TextGenerationParams,
        onChunk: @escaping (MessageChunk) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (KotlinThrowable) -> Void
    ) -> Kotlinx_coroutines_coreJob? {
        if let openAI = providerSetting as? ProviderSetting.OpenAI {
            if IOSGrokWebProviderResolver.isGrokWebConfiguration(openAI) {
                grokWebStreamTask?.cancel()
                let providerId = IOSGrokWebProviderResolver.providerKey(openAI)
                grokWebStreamTask = Task {
                    do {
                        try await IOSGrokWebClient(providerId: providerId).streamText(
                            messages: messages,
                            params: params,
                            onChunk: onChunk
                        )
                        guard !Task.isCancelled else { return }
                        onComplete()
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        onError(KotlinThrowable(message: (error as NSError).localizedDescription))
                    }
                }
                return nil
            }
            return openAIProvider.streamTextCancellable(
                providerSetting: openAI, messages: messages, params: params,
                onChunk: onChunk, onComplete: onComplete, onError: onError
            )
        }
        if let claude = providerSetting as? ProviderSetting.Claude {
            return claudeProvider.streamTextCancellable(
                providerSetting: claude, messages: messages, params: params,
                onChunk: onChunk, onComplete: onComplete, onError: onError
            )
        }
        onError(KotlinThrowable(message: "当前服务商类型暂不支持 council"))
        return nil
    }

    func cancel() {
        if let activeStream {
            _ = activeStream.flushAndClose(drainingQueuedChunks: true)
            self.activeStream = nil
        }
        job?.cancel(cause: nil)
        job = nil
        grokWebStreamTask?.cancel()
        grokWebStreamTask = nil
    }

    private func clearActiveStreamIfNeeded(_ stream: IOSCouncilActiveTextStream) {
        guard activeStream === stream else { return }
        activeStream = nil
        job = nil
        grokWebStreamTask = nil
    }

    deinit {
        job?.cancel(cause: nil)
        grokWebStreamTask?.cancel()
    }
}

