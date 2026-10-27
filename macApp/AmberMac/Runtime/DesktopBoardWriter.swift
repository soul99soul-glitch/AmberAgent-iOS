import Foundation
@preconcurrency import GatewayCore
@preconcurrency import GatewayTransport

/// Writes what the task board shows but nobody typed: titles for gateway Claude Code / Codex sessions (from their
/// opening prompt, sent back as `retitle` events) and a one-line summary + noteworthy flag for scheduled runs.
/// Both use the 「生成会话标题」 model; with none resolving it does nothing, and the board falls back to the opening words.
@MainActor final class DesktopBoardWriter {
    private let provider: any DesktopTextProvider
    private let paths: GatewayPaths
    private let request: @MainActor () -> (DesktopProviderConfiguration, String)?
    private let queue = DispatchQueue(label: "amber.board.writer")
    /// Session keys ever queued; a failed title is not retried (the board keeps the opening words).
    private var attempted: Set<String> = []
    private var pending: [SessionRecord] = []
    /// The one title generation in flight.
    private(set) var titling: Task<Void, Never>?
    var timeout: Duration = .seconds(30)

    init(provider: any DesktopTextProvider, paths: GatewayPaths = .resolve(),
         request: @escaping @MainActor () -> (DesktopProviderConfiguration, String)?) {
        self.provider = provider; self.paths = paths; self.request = request
    }

    // MARK: Session titles

    /// Queues untitled sessions that have an opening; generates one at a time.
    /// The model (and its Keychain key) is only looked up when there is something to title.
    func queueTitles(_ sessions: [SessionRecord]) {
        let fresh = sessions.sorted { $0.startedAt < $1.startedAt }.filter {
            ($0.agent == .claude || $0.agent == .codex) && $0.generatedTitle == nil && $0.opening?.isEmpty == false
                && !attempted.contains($0.key)
        }
        guard !fresh.isEmpty, request() != nil else { return }
        attempted.formUnion(fresh.map(\.key))
        pending += fresh
        next()
    }

    private func next() {
        guard titling == nil, !pending.isEmpty, let (configuration, apiKey) = request() else { return }
        let rec = pending.removeFirst()
        let input = [DesktopMessage(role: .system, text: "为下面这段任务描述写一个标题：中文最多 12 个字，英文最多 6 个词。只输出标题，不加引号、标点、说明或 Markdown。"),
            DesktopMessage(role: .user, text: rec.opening ?? "")]
        titling = Task { [weak self] in
            guard let self else { return }
            let text = await complete(input, configuration: configuration, apiKey: apiKey)
            if let title = text.flatMap(Self.cleanTitle) {
                let event = GatewayEvent(agent: rec.agent, kind: .retitle, sessionId: rec.sessionId, title: title)
                let paths = paths
                queue.async { EventDelivery.deliver(event, paths: paths) }
            }
            titling = nil
            next()
        }
    }

    static func cleanTitle(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = String(line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」《》#*` 。.")).prefix(40))
        return title.isEmpty ? nil : title
    }

    // MARK: Run summaries

    /// One line and whether it is news, from a finished run's final reply. nil when no model, a slow model, or bad JSON.
    func summarize(_ reply: String) async -> (summary: String, noteworthy: Bool)? {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, let (configuration, apiKey) = request() else { return nil }
        let input = [DesktopMessage(role: .system, text: """
            下面是一个定时任务本次运行的最终回复。用一行中文（不超过 40 个字）概括结果，并判断是否有值得用户马上知道的新情况\
            （例如发现新内容、异常、需要处理的事项；例行的“没有变化”“一切正常”不算）。\
            只输出一行 JSON：{"summary":"…","noteworthy":true 或 false}，不要代码块或其他文字。
            """),
            DesktopMessage(role: .user, text: String(reply.prefix(4_000)))]
        return await complete(input, configuration: configuration, apiKey: apiKey).flatMap(Self.parseSummary)
    }

    /// Tolerates code fences and surrounding prose: takes the outermost `{…}`.
    static func parseSummary(_ text: String) -> (summary: String, noteworthy: Bool)? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any],
              let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
              let noteworthy = object["noteworthy"] as? Bool else { return nil }
        return (String(summary.prefix(40)), noteworthy)
    }

    // MARK: Model call

    /// Final text of a plain completion, or nil on failure, cancellation or after `timeout`.
    private func complete(_ messages: [DesktopMessage], configuration: DesktopProviderConfiguration, apiKey: String) async -> String? {
        guard let generation = try? provider.start(configuration: configuration, apiKey: apiKey, messages: messages, responseID: UUID())
        else { return nil }
        let consume = Task { @MainActor () -> String? in
            var text = ""
            for await _ in generation.signals {
                for event in generation.drain() {
                    switch event {
                    case .snapshot(let value, _, _, _): text = value
                    case .transcript(let turns): text = turns.last { $0.role == .assistant }?.text ?? text
                    case .complete: return text
                    case .failed, .cancelled: return nil
                    }
                }
            }
            return nil
        }
        let timeout = timeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            consume.cancel(); generation.cancel()
        }
        let text = await withTaskCancellationHandler { await consume.value } onCancel: { consume.cancel(); generation.cancel() }
        timer.cancel()
        return text
    }
}
