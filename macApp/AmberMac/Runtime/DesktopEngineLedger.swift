import Foundation
@preconcurrency import Shared

final class DesktopEngineLedger: IOSAgentRunLedgering, @unchecked Sendable {
    private let tasks: DesktopAgentTasks
    private let journal: DesktopAgentJournal
    private let runID: UUID
    private let lock = NSLock()
    private var roundOffset = 0

    @MainActor init(tasks: DesktopAgentTasks, runID: UUID) {
        self.tasks = tasks; self.journal = tasks.journal; self.runID = runID
    }

    func advanceRound(by count: Int) { lock.lock(); roundOffset += count; lock.unlock() }

    func recordRequestSnapshot(runId: String, snapshot: IOSRunRequestSnapshot) async -> Bool {
        guard UUID(uuidString: runId) == runID else { return false }
        let offset = lock.withLock { roundOffset }
        return await change { $0.requestDigests = ($0.requestDigests ?? []) + ["\(offset + snapshot.roundIndex):\(snapshot.requestDigest)"] }
    }

    func recordToolCallPrepared(runId: String, toolCallId: String, toolName: String, argsDigest: String,
        effectClass: IOSToolEffectClass) async -> IOSToolTransactionPreparation {
        guard UUID(uuidString: runId) == runID else { return .blocked(reason: "任务归属不匹配。") }
        do {
            let result = try await journal.prepare(runID, callID: toolCallId, name: toolName,
                argsDigest: argsDigest, effect: effectClass.rawValue)
            await tasks.publish(try await journal.value(runID))
            switch result {
            case .ready: return .ready
            case .replay(let payload): return .replay(resultPayload: payload)
            case .blocked(let reason): return .blocked(reason: reason)
            }
        } catch { return .blocked(reason: "无法保存工具准备记录，工具未执行。") }
    }

    func recordToolCallStarted(runId: String, toolCallId: String, toolName: String, argsDigest: String,
        effectClass: IOSToolEffectClass) async -> Bool {
        guard UUID(uuidString: runId) == runID else { return false }
        return await change {
            guard let index = $0.transactions.firstIndex(where: { $0.id == toolCallId }),
                  $0.transactions[index].name == toolName, $0.transactions[index].argsDigest == argsDigest,
                  ["prepared", "waiting_user"].contains($0.transactions[index].state) else { throw DesktopRuntimeError.message("此工具不能重复开始。") }
            $0.transactions[index].state = "started"
        }
    }

    func recordToolCallFinished(runId: String, toolCallId: String, outcome: String) async -> Bool {
        await recordToolCallTerminal(runId: runId, toolCallId: toolCallId, outcome: outcome, resultPayload: nil)
    }

    func recordToolCallFinished(runId: String, toolCallId: String, outcome: String,
        artifactId: String?, artifactVersion: String?, outcomeKind: String?, errorCode: String?, sourceRef: String?) async -> Bool {
        await recordToolCallFinished(runId: runId, toolCallId: toolCallId, outcome: outcome)
    }

    func recordApprovalDenied(runId: String, toolCallId: String, toolName: String, reason: String, capabilityId: String?) async {
        _ = await recordToolCallFinished(runId: runId, toolCallId: toolCallId, outcome: "denied")
    }

    func recordToolCallTerminal(runId: String, toolCallId: String, outcome: String, resultPayload: String?) async -> Bool {
        guard UUID(uuidString: runId) == runID else { return false }
        return await change {
            guard let index = $0.transactions.firstIndex(where: { $0.id == toolCallId }) else { throw DesktopRuntimeError.message("缺少工具开始记录。") }
            $0.transactions[index].state = outcome == "paused_for_approval" ? "waiting_user" : "finished"
            $0.transactions[index].outcome = outcome
            $0.transactions[index].resultPayload = resultPayload
        }
    }

    func toolTransactions(runId: String) async -> [IOSToolTransactionSnapshot]? {
        guard UUID(uuidString: runId) == runID, let value = try? await journal.value(runID) else { return nil }
        return value.transactions.compactMap {
            guard let state = IOSToolTransactionState(rawValue: $0.state), let effect = IOSToolEffectClass(rawValue: $0.effect) else { return nil }
            return IOSToolTransactionSnapshot(runId: runId, toolCallId: $0.id, toolName: $0.name, argsDigest: $0.argsDigest,
                effectClass: effect, state: state, outcome: $0.outcome, resultPayload: $0.resultPayload)
        }
    }

    func transitionToolTransaction(runId: String, toolCallId: String, expected: IOSToolTransactionState,
        to state: IOSToolTransactionState, outcome: String?, resultPayload: String?) async -> Bool {
        guard UUID(uuidString: runId) == runID else { return false }
        return await change {
            guard let index = $0.transactions.firstIndex(where: { $0.id == toolCallId }),
                  $0.transactions[index].state == expected.rawValue else { throw DesktopRuntimeError.message("工具状态已变化。") }
            $0.transactions[index].state = state.rawValue
            $0.transactions[index].outcome = outcome
            $0.transactions[index].resultPayload = resultPayload
        }
    }

    private func change(_ update: @escaping @Sendable (inout DesktopAgentTask) throws -> Void) async -> Bool {
        do {
            let value = try await journal.change(runID, update)
            await tasks.publish(value)
            return true
        } catch { return false }
    }
}
