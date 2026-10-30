import Foundation
import Observation

@MainActor @Observable final class DesktopTitleGeneration {
    private(set) var activeOwners: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: DesktopGeneration] = [:]
    @ObservationIgnored private var tokens: [UUID: UUID] = [:]

    @discardableResult
    func generate(conversation: DesktopConversation, configuration: DesktopProviderConfiguration, apiKey: String,
        provider: any DesktopTextProvider, accept: @escaping @MainActor (String) -> Bool) -> Task<Void, Never>? {
        let owner = conversation.id
        guard !activeOwners.contains(owner), !conversation.messages.isEmpty else { return nil }
        let excerpts = conversation.messages.suffix(8).map { "\($0.role.rawValue): \(String($0.text.prefix(1_000)))" }.joined(separator: "\n")
        let input = [DesktopMessage(role: .system, text: "根据提供的会话生成简短准确的标题，最多 24 个字。只输出标题，不加引号、说明或 Markdown。"),
            DesktopMessage(role: .user, text: excerpts)]
        let token = UUID()
        tokens[owner] = token; activeOwners.insert(owner); errors[owner] = nil
        let task = Task {
            defer {
                if tokens[owner] == token {
                    tokens[owner] = nil; activeOwners.remove(owner); tasks[owner] = nil; generations[owner] = nil
                }
            }
            do {
                try Task.checkCancellation()
                let generation = try provider.start(configuration: configuration, apiKey: apiKey, messages: input, responseID: UUID())
                generations[owner] = generation
                var text = ""
                var completed = false
                try await withTaskCancellationHandler {
                    for await _ in generation.signals {
                        try Task.checkCancellation()
                        for event in generation.drain() {
                            switch event {
                            case .snapshot(let value, _, _, _, _): text = value
                            case .transcript: break
                            case .complete: completed = true
                            case .cancelled: throw CancellationError()
                            case .failed: throw DesktopRuntimeError.message("生成标题失败，原标题已保留。")
                            }
                        }
                    }
                } onCancel: { generation.cancel() }
                try Task.checkCancellation()
                guard tokens[owner] == token else { return }
                let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(80) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」 "))
                guard completed, !title.isEmpty else { throw DesktopRuntimeError.message("模型没有返回有效标题，原标题已保留。") }
                if !accept(title) { errors[owner] = "会话已更改，未替换现有标题。请按需要重新生成。" }
            } catch is CancellationError { }
            catch { errors[owner] = error is DesktopRuntimeError ? error.localizedDescription : "生成标题失败，原标题已保留。" }
        }
        tasks[owner] = task
        return task
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel(); generations[id]?.cancel() }
    func cancelAll() { for id in Array(tasks.keys) { cancel(id) } }
    func flush() async { for task in Array(tasks.values) { await task.value } }
}
