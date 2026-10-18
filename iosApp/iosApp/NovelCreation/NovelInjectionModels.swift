import Foundation

struct NovelInjectionOverrides: Codable, Equatable, Sendable {
    var forceIncludeMaterialIDs: [NovelMaterialID]
    var forceExcludeMaterialIDs: [NovelMaterialID]

    static let none = NovelInjectionOverrides(
        forceIncludeMaterialIDs: [],
        forceExcludeMaterialIDs: []
    )
}

struct NovelInjectionBudget: Codable, Equatable, Sendable {
    let maxEstimatedInputTokens: Int
    let chapterTailCharacterLimit: Int
    let maximumRecentSessionMessages: Int

    static let standard = NovelInjectionBudget(
        maxEstimatedInputTokens: 16_000,
        chapterTailCharacterLimit: 6_000,
        maximumRecentSessionMessages: 12
    )
}

struct NovelPendingStateInjection: Equatable, Sendable {
    let pendingID: NovelPendingOperationID
    let chunkIndex: Int
    let content: String
}

struct NovelInjectionPlanningRequest: Equatable, Sendable {
    let branchID: NovelBranchID
    let promptKind: NovelPromptKind
    let userText: String
    let sourceChapterVersionID: NovelChapterVersionID?
    let stateSnapshotIDOverride: NovelStateSnapshotID?
    let sessionCursorLimit: NovelSessionCursor?
    let includeUnsynchronizedStateWarning: Bool
    let pendingState: NovelPendingStateInjection?
    let overrides: NovelInjectionOverrides
    /// Optional sections stop packing at this total-input estimate. Required
    /// sections still use `budget.maxEstimatedInputTokens` as the hard limit.
    let optionalPackingLimitTokens: Int?
    let budget: NovelInjectionBudget

    init(
        branchID: NovelBranchID,
        promptKind: NovelPromptKind,
        userText: String,
        sourceChapterVersionID: NovelChapterVersionID? = nil,
        stateSnapshotIDOverride: NovelStateSnapshotID? = nil,
        sessionCursorLimit: NovelSessionCursor? = nil,
        includeUnsynchronizedStateWarning: Bool = true,
        pendingState: NovelPendingStateInjection? = nil,
        overrides: NovelInjectionOverrides = .none,
        optionalPackingLimitTokens: Int? = nil,
        budget: NovelInjectionBudget = .standard
    ) {
        self.branchID = branchID
        self.promptKind = promptKind
        self.userText = userText
        self.sourceChapterVersionID = sourceChapterVersionID
        self.stateSnapshotIDOverride = stateSnapshotIDOverride
        self.sessionCursorLimit = sessionCursorLimit
        self.includeUnsynchronizedStateWarning = includeUnsynchronizedStateWarning
        self.pendingState = pendingState
        self.overrides = overrides
        self.optionalPackingLimitTokens = optionalPackingLimitTokens
        self.budget = budget
    }
}

enum NovelInjectionSectionKind: Codable, Equatable, Sendable {
    case fixedPrompt
    case polishPreference
    case chapterPlan(NovelChapterPlanID)
    case recentWrittenHighlights(NovelStateSnapshotID)
    case upcomingArc(NovelBranchID)
    case currentState(NovelStateSnapshotID)
    case pendingManualState(NovelPendingOperationID, chunkIndex: Int)
    case quickStartSeed
    case chapterContext(NovelChapterVersionID?)
    case discussionArchive(NovelMessageID, throughSequence: Int64)
    case sessionMessage(NovelMessageID)
    case storyEvent(NovelEventID)
    case material(NovelMaterialRevisionID)
    case userInput
}

enum NovelInjectionSelectionReason: String, Codable, Equatable, Sendable {
    case requiredPrompt
    case requiredPolishPreference
    case confirmedChapterPlan
    case recentWrittenHighlights
    case upcomingArc
    case requiredUserInput
    case requiredCurrentState
    case requiredQuickStartSeed
    case currentChapterTail
    case previousChapterTail
    case fullSourceChapter
    case archivedDiscussion
    case recentSession
    case branchEventHistory
    case branchOverride
    case always
    case forceIncluded
    case smartMatch
    case forceExcluded
    case disabled
    case noSmartMatch
    case budgetTrimmed
}

struct NovelInjectionSection: Codable, Equatable, Sendable {
    let kind: NovelInjectionSectionKind
    let label: String
    let content: String
    let reason: NovelInjectionSelectionReason
    let estimatedTokens: Int
    let contentSHA256: String
}

struct NovelMaterialInjectionDecision: Codable, Equatable, Sendable {
    let materialID: NovelMaterialID
    let revisionID: NovelMaterialRevisionID
    let included: Bool
    let reason: NovelInjectionSelectionReason
    let relevanceScore: Int
    let estimatedTokens: Int
    let contentSHA256: String
}

struct NovelInjectionReceiptSectionRecord: Codable, Equatable, Sendable {
    let kind: NovelInjectionSectionKind
    let label: String
    let reason: NovelInjectionSelectionReason
    let estimatedTokens: Int
    let contentSHA256: String
}

struct NovelInjectionMaterialReceiptItem: Codable, Equatable, Sendable {
    let materialID: NovelMaterialID
    let kind: NovelMaterialKind
    let title: String
}

struct NovelInjectionReceiptRecord: Codable, Equatable, Sendable {
    let id: NovelReceiptID
    let runID: NovelRunID
    private(set) var projectID: NovelProjectID
    let branchID: NovelBranchID
    let promptVersion: String
    /// Effective transport provider UUID.
    let providerID: String
    let ownerProviderID: String
    let modelID: String
    let wireModelID: String
    let parameters: [String: String]
    let sections: [NovelInjectionReceiptSectionRecord]
    let materialDecisions: [NovelMaterialInjectionDecision]
    let includedMaterials: [NovelInjectionMaterialReceiptItem]?
    let includesPlotState: Bool?
    let recentMessageRoundCount: Int?
    let budgetExcludedItemCount: Int?
    let forceIncludeMaterialIDs: [NovelMaterialID]
    let forceExcludeMaterialIDs: [NovelMaterialID]
    let requestedInputBudgetTokens: Int
    let maxEstimatedInputTokens: Int
    let estimatedInputTokens: Int
    let canonicalInputSHA256: String
    let factTransaction: NovelFactReceiptLink?
    let createdAt: Date

    init(
        id: NovelReceiptID,
        runID: NovelRunID,
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        plan: NovelInjectionPlan,
        overrides: NovelInjectionOverrides,
        providerID: String,
        ownerProviderID: String? = nil,
        modelID: String,
        wireModelID: String? = nil,
        parameters: [String: String],
        requestedInputBudgetTokens: Int? = nil,
        factTransaction: NovelFactReceiptLink? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.projectID = projectID
        self.branchID = branchID
        promptVersion = plan.prompt.version
        self.providerID = providerID
        self.ownerProviderID = ownerProviderID ?? providerID
        self.modelID = modelID
        self.wireModelID = wireModelID ?? modelID
        self.parameters = Self.removingSensitiveParameters(parameters)
        sections = plan.sections.map {
            NovelInjectionReceiptSectionRecord(
                kind: $0.kind,
                label: $0.label,
                reason: $0.reason,
                estimatedTokens: $0.estimatedTokens,
                contentSHA256: $0.contentSHA256
            )
        }
        materialDecisions = plan.materialDecisions
        includedMaterials = plan.includedMaterials
        includesPlotState = plan.includesPlotState
        recentMessageRoundCount = plan.recentMessageRoundCount
        budgetExcludedItemCount = plan.budgetExcludedItemCount
        forceIncludeMaterialIDs = Array(Set(overrides.forceIncludeMaterialIDs)).sorted {
            $0.description < $1.description
        }
        forceExcludeMaterialIDs = Array(Set(overrides.forceExcludeMaterialIDs)).sorted {
            $0.description < $1.description
        }
        self.requestedInputBudgetTokens = requestedInputBudgetTokens ?? plan.maxEstimatedInputTokens
        maxEstimatedInputTokens = plan.maxEstimatedInputTokens
        estimatedInputTokens = plan.estimatedInputTokens
        canonicalInputSHA256 = plan.canonicalInputSHA256
        self.factTransaction = factTransaction
        self.createdAt = createdAt
    }

    func remappingProjectID(to projectID: NovelProjectID) -> NovelInjectionReceiptRecord {
        var copy = self
        copy.projectID = projectID
        return copy
    }

    private static func removingSensitiveParameters(
        _ parameters: [String: String]
    ) -> [String: String] {
        let sensitiveFragments = [
            "apikey", "authorization", "baseurl", "cookie", "credential",
            "oauth", "password", "secret", "accesstoken", "refreshtoken", "idtoken"
        ]
        return parameters.filter { key, _ in
            let normalizedKey = key.lowercased().filter(\.isLetter)
            return !sensitiveFragments.contains(where: normalizedKey.contains)
        }
    }
}

struct NovelInjectionPlan: Codable, Equatable, Sendable {
    let prompt: NovelPromptTemplate
    let sections: [NovelInjectionSection]
    let materialDecisions: [NovelMaterialInjectionDecision]
    let maxEstimatedInputTokens: Int
    let estimatedInputTokens: Int
    let contextText: String
    let canonicalInput: String
    let canonicalInputSHA256: String
    let includedMaterials: [NovelInjectionMaterialReceiptItem]
    let includesPlotState: Bool
    let recentMessageRoundCount: Int
    let budgetExcludedItemCount: Int

    init(
        prompt: NovelPromptTemplate,
        sections: [NovelInjectionSection],
        materialDecisions: [NovelMaterialInjectionDecision],
        maxEstimatedInputTokens: Int,
        estimatedInputTokens: Int,
        contextText: String,
        canonicalInput: String,
        canonicalInputSHA256: String,
        includedMaterials: [NovelInjectionMaterialReceiptItem] = [],
        includesPlotState: Bool = false,
        recentMessageRoundCount: Int = 0,
        budgetExcludedItemCount: Int = 0
    ) {
        self.prompt = prompt
        self.sections = sections
        self.materialDecisions = materialDecisions
        self.maxEstimatedInputTokens = maxEstimatedInputTokens
        self.estimatedInputTokens = estimatedInputTokens
        self.contextText = contextText
        self.canonicalInput = canonicalInput
        self.canonicalInputSHA256 = canonicalInputSHA256
        self.includedMaterials = includedMaterials
        self.includesPlotState = includesPlotState
        self.recentMessageRoundCount = recentMessageRoundCount
        self.budgetExcludedItemCount = budgetExcludedItemCount
    }
}

