import Foundation

struct NovelInjectionPanelMaterialModel: Equatable, Identifiable, Sendable {
    let id: NovelMaterialID
    let title: String
    let kindTitle: String
}

struct NovelInjectionPanelModel: Equatable, Sendable {
    let hasReceipt: Bool
    let materials: [NovelInjectionPanelMaterialModel]
    let includesPlotState: Bool
    let recentMessageRoundCount: Int
    let budgetExcludedItemCount: Int
    let estimatedInputTokens: Int
    let maxEstimatedInputTokens: Int

    static let empty = NovelInjectionPanelModel(
        hasReceipt: false,
        materials: [],
        includesPlotState: false,
        recentMessageRoundCount: 0,
        budgetExcludedItemCount: 0,
        estimatedInputTokens: 0,
        maxEstimatedInputTokens: 0
    )
}

enum NovelInjectionPanelPresentation {
    static func project(_ receipt: NovelInjectionReceiptRecord?) -> NovelInjectionPanelModel {
        guard let receipt else { return .empty }

        let materials: [NovelInjectionPanelMaterialModel]
        if let recorded = receipt.includedMaterials {
            materials = recorded.map {
                NovelInjectionPanelMaterialModel(
                    id: $0.materialID,
                    title: $0.title,
                    kindTitle: $0.kind.displayName
                )
            }
        } else {
            materials = receipt.materialDecisions.filter(\.included).map {
                NovelInjectionPanelMaterialModel(
                    id: $0.materialID,
                    title: $0.materialID.description,
                    kindTitle: "资料"
                )
            }
        }

        let includesPlotState = receipt.includesPlotState ?? receipt.sections.contains { section in
            switch section.kind {
            case .currentState, .pendingManualState: true
            default: false
            }
        }
        let sessionMessageCount = receipt.sections.reduce(into: 0) { count, section in
            if case .sessionMessage = section.kind { count += 1 }
        }

        return NovelInjectionPanelModel(
            hasReceipt: true,
            materials: materials,
            includesPlotState: includesPlotState,
            recentMessageRoundCount: receipt.recentMessageRoundCount ??
                (sessionMessageCount + 1) / 2,
            budgetExcludedItemCount: receipt.budgetExcludedItemCount ??
                receipt.materialDecisions.filter { $0.reason == .budgetTrimmed }.count,
            estimatedInputTokens: receipt.estimatedInputTokens,
            maxEstimatedInputTokens: receipt.maxEstimatedInputTokens
        )
    }
}

