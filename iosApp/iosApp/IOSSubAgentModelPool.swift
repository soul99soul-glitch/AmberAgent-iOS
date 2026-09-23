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

        var selectionKey: SelectionKey {
            SelectionKey(modelId: modelId, providerId: providerId)
        }
    }

    struct SelectionKey: Equatable, Sendable {
        let modelId: String
        let providerId: String
    }

    /// Immutable selector inputs captured before the real pool choice. A shadow
    /// result may arrive after reservations and the rotation cursor have moved;
    /// evaluating against this snapshot keeps its counterfactual tied to the
    /// actual bootstrap decision point.
    struct SelectionSnapshot: Sendable {
        let roundRobinCursor: Int
        let activeModelCounts: [String: Int]
        let activeProviderCounts: [String: Int]
        let reservedModelCounts: [String: Int]
        let reservedProviderCounts: [String: Int]

        func selectedModelId(from candidates: [SelectionKey]) -> String? {
            guard !candidates.isEmpty else { return nil }
            let start = roundRobinCursor % candidates.count
            guard let best = candidates.enumerated().min(by: { lhs, rhs in
                score(lhs.element, originalIndex: lhs.offset, start: start, candidateCount: candidates.count)
                    < score(rhs.element, originalIndex: rhs.offset, start: start, candidateCount: candidates.count)
            }) else { return nil }
            return best.element.modelId
        }

        private func score(
            _ candidate: SelectionKey,
            originalIndex: Int,
            start: Int,
            candidateCount: Int
        ) -> (Int, Int, Int) {
            let providerLoad = activeProviderCounts[candidate.providerId, default: 0]
                + reservedProviderCounts[candidate.providerId, default: 0]
            let modelLoad = activeModelCounts[candidate.modelId, default: 0]
                + reservedModelCounts[candidate.modelId, default: 0]
            let rotation = (originalIndex - start + candidateCount) % candidateCount
            return (providerLoad, modelLoad, rotation)
        }
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
        let snapshot = selectionSnapshot(
            activeModelCounts: activeModelCounts,
            activeProviderCounts: activeProviderCounts
        )
        let selectedId = snapshot.selectedModelId(from: candidates.map(\.selectionKey))
        roundRobinCursor = (roundRobinCursor + 1) % candidates.count
        return candidates.first { $0.modelId == selectedId }
    }

    func selectionSnapshot(
        activeModelCounts: [String: Int],
        activeProviderCounts: [String: Int]
    ) -> SelectionSnapshot {
        SelectionSnapshot(
            roundRobinCursor: roundRobinCursor,
            activeModelCounts: activeModelCounts,
            activeProviderCounts: activeProviderCounts,
            reservedModelCounts: reservedModelCounts,
            reservedProviderCounts: reservedProviderCounts
        )
    }

    /// 只读反事实：同一预留/负载/轮转状态下，本地池当前会选择谁。
    func previewSelection(
        from candidates: [Candidate],
        activeModelCounts: [String: Int],
        activeProviderCounts: [String: Int]
    ) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let selectedId = selectionSnapshot(
            activeModelCounts: activeModelCounts,
            activeProviderCounts: activeProviderCounts
        ).selectedModelId(from: candidates.map(\.selectionKey))
        return candidates.first { $0.modelId == selectedId }
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
