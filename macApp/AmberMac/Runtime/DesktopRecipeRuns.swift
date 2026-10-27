import Foundation
import Observation

typealias DesktopRecipeToolExecution = @MainActor @Sendable (_ runID: UUID, _ owner: UUID, _ name: String, _ argumentsJSON: String) async throws -> String

struct DesktopRecipeOperation: Identifiable, Equatable, Sendable {
    let id: UUID
    let owner: UUID
    let name: String
    var result: DesktopRecipeRunResult?
    var error: String?
    var isRunning = true
}

@MainActor @Observable
final class DesktopRecipeRuns {
    let store: DesktopRecipeStore
    private(set) var operations: [DesktopRecipeOperation] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let tasks: DesktopAgentTasks
    @ObservationIgnored private let execute: DesktopRecipeToolExecution
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]

    init(store: DesktopRecipeStore, tasks: DesktopAgentTasks, execute: @escaping DesktopRecipeToolExecution = { _, _, _, _ in
        throw DesktopRuntimeError.message("当前界面预览未接入原生工具执行。")
    }) {
        self.store = store; self.tasks = tasks; self.execute = execute
    }

    @discardableResult
    func start(name: String, inputs: [String: DesktopRecipeJSONValue], conversationID: UUID) -> UUID {
        let id = UUID()
        operations.insert(DesktopRecipeOperation(id: id, owner: conversationID, name: name), at: 0)
        running[id] = Task {
            defer {
                running[id] = nil
                if let index = operations.firstIndex(where: { $0.id == id }) { operations[index].isRunning = false }
            }
            do {
                _ = try await tasks.begin(id: id, conversationID: conversationID, title: "Recipe · \(name)", cancel: { [weak self] in self?.cancel(id) })
                try Task.checkCancellation()
                let result = await store.run(name: name, inputs: inputs) { [execute] tool, arguments in
                    try await execute(id, conversationID, tool, arguments)
                }
                if let index = operations.firstIndex(where: { $0.id == id }) { operations[index].result = result }
                let resultData = try JSONEncoder().encode(DesktopRecipeJSONValue.object([
                    "outputs": .object(result.outputs), "completed_steps": .array(result.completedSteps.map(DesktopRecipeJSONValue.string)),
                    "error": result.error.map(DesktopRecipeJSONValue.string) ?? .null
                ]))
                let resultText = String(decoding: resultData, as: UTF8.self)
                let stored = try await tasks.journal.change(id) { $0.resultText = resultText }
                tasks.publish(stored)
                let unknown = stored.transactions.contains { ["started", "outcome_unknown"].contains($0.state) }
                await tasks.finish(id, status: unknown ? .outcomeUnknown : Task.isCancelled ? .cancelled : result.succeeded ? .completed : .failed,
                    error: result.error)
            } catch {
                errorMessage = error is DesktopRuntimeError ? error.localizedDescription : "Recipe任务无法启动或保存，请检查配置与存储权限。"
                if let index = operations.firstIndex(where: { $0.id == id }) { operations[index].error = errorMessage }
                if let record = tasks.records.first(where: { $0.id == id }) {
                    let unknown = record.transactions.contains { ["started", "outcome_unknown"].contains($0.state) }
                    await tasks.finish(id, status: unknown ? .outcomeUnknown : Task.isCancelled ? .cancelled : .failed, error: errorMessage)
                }
            }
        }
        return id
    }

    func cancel(_ id: UUID) { running[id]?.cancel() }
    func cancel(conversationID: UUID) {
        for operation in operations where operation.owner == conversationID && operation.isRunning { cancel(operation.id) }
    }
    func cancelAll() { for task in running.values { task.cancel() } }
    func waitUntilFinished(_ id: UUID) async { await running[id]?.value }
    func flush() async { for task in Array(running.values) { await task.value } }
}
