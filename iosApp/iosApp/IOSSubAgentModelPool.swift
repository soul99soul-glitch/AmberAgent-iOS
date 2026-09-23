import Foundation
@preconcurrency import Shared

/// Main-actor model-pool selector used by spawn/followup bootstrap. It keeps
/// reservations separate from the durable run registry so two concurrent
/// spawns cannot choose the same apparently-idle model before either run is
/// visible to the background coordinator.
@MainActor
final class IOSSubAgentModelPool {
    final class Reservation {
        fileprivate let modelId: String
        fileprivate let providerId: String
        fileprivate var released = false

        fileprivate init(modelId: String, providerId: String) {
            self.modelId = modelId
            self.providerId = providerId
        }
    }

    struct Candidate {
        let model: Model
        let provider: ProviderSetting
        let configuredReasoning: ReasoningLevel?
        let supportedReasoning: [ReasoningLevel]

        var modelId: String { model.id.toHexDashString() }
        var providerId: String { provider.id.toHexDashString() }
    }

    private var reservedModelCounts: [String: Int] = [:]
    private var reservedProviderCounts: [String: Int] = [:]
    private var roundRobinCursor = 0

    func candidates(
        settings: Settings,
        sharedSettings: IOSSharedSettingsStore
    ) -> [Candidate] {
        settings.agentRuntime.subAgent.modelPool.compactMap { entry in
            guard let model = settings.findModelById(uuid: entry.modelId),
                  let provider = ChatProviderConfiguration.provider(
                    for: model,
                    providers: settings.providers
                  ),
                  provider.enabled,
                  ChatProviderConfiguration.issue(for: model, provider: provider) == nil else {
                return nil
            }
            return Candidate(
                model: model,
                provider: provider,
                configuredReasoning: entry.reasoningLevel,
                supportedReasoning: sharedSettings.subAgentReasoningLevels(
                    modelId: model.id.toHexDashString()
                )
            )
        }
    }

    func reserve(_ candidate: Candidate) -> Reservation {
        let reservation = Reservation(modelId: candidate.modelId, providerId: candidate.providerId)
        reservedModelCounts[candidate.modelId, default: 0] += 1
        reservedProviderCounts[candidate.providerId, default: 0] += 1
        return reservation
    }

    func defaultReasoning(for candidate: Candidate) -> ReasoningLevel {
        for preferred in [ReasoningLevel.auto_, .medium, .high] {
            if candidate.supportedReasoning.contains(preferred) { return preferred }
        }
        return candidate.supportedReasoning.first ?? .off
    }

    func candidate(
        for modelId: String,
        from candidates: [Candidate]
    ) -> Candidate? {
        candidates.first { $0.modelId.caseInsensitiveCompare(modelId) == .orderedSame }
    }

    func release(_ reservation: Reservation?) {
        guard let reservation, !reservation.released else { return }
        reservation.released = true
        decrement(&reservedModelCounts, key: reservation.modelId)
        decrement(&reservedProviderCounts, key: reservation.providerId)
    }

    func select(
        from candidates: [Candidate],
        activeModelCounts: [String: Int],
        activeProviderCounts: [String: Int]
    ) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let selected = previewSelection(
            from: candidates,
            activeModelCounts: activeModelCounts,
            activeProviderCounts: activeProviderCounts
        )
        roundRobinCursor = (roundRobinCursor + 1) % candidates.count
        return selected
    }

    /// 只读反事实：同一预留/负载/轮转状态下，本地池当前会选择谁。
    /// 供 Jev shadow/active 差异指标使用，不改变下次真实选择。
    func previewSelection(
        from candidates: [Candidate],
        activeModelCounts: [String: Int],
        activeProviderCounts: [String: Int]
    ) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let start = roundRobinCursor % candidates.count
        guard let best = candidates.enumerated().min(by: { lhs, rhs in
            let left = score(
                candidate: lhs.element,
                originalIndex: lhs.offset,
                start: start,
                candidateCount: candidates.count,
                activeModelCounts: activeModelCounts,
                activeProviderCounts: activeProviderCounts
            )
            let right = score(
                candidate: rhs.element,
                originalIndex: rhs.offset,
                start: start,
                candidateCount: candidates.count,
                activeModelCounts: activeModelCounts,
                activeProviderCounts: activeProviderCounts
            )
            return left < right
        }) else { return nil }
        return best.element
    }

    private func score(
        candidate: Candidate,
        originalIndex: Int,
        start: Int,
        candidateCount: Int,
        activeModelCounts: [String: Int],
        activeProviderCounts: [String: Int]
    ) -> (Int, Int, Int) {
        let providerLoad = activeProviderCounts[candidate.providerId, default: 0]
            + reservedProviderCounts[candidate.providerId, default: 0]
        let modelLoad = activeModelCounts[candidate.modelId, default: 0]
            + reservedModelCounts[candidate.modelId, default: 0]
        let rotation = (originalIndex - start + candidateCount) % candidateCount
        // Provider occupancy is the primary spread key; model occupancy and
        // round-robin are deterministic tie breakers.
        return (providerLoad, modelLoad, rotation)
    }

    private func decrement(_ values: inout [String: Int], key: String) {
        guard let count = values[key] else { return }
        if count <= 1 {
            values.removeValue(forKey: key)
        } else {
            values[key] = count - 1
        }
    }
}
