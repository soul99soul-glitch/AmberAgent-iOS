import Foundation

enum NovelStructuredOutputValidation {
    static func validate(_ value: NovelCharacterProposalV1) throws {
        try schemaVersion(
            value.schemaVersion,
            expected: NovelCharacterProposalV1.currentSchemaVersion
        )
        try required(value.character.title, path: "$.character.title")
        try required(value.character.content, path: "$.character.content")
        let aliases = NovelCharacterIdentityResolver.normalizedAliases(
            value.character.aliases ?? []
        )
        guard aliases.count == value.character.aliases?.count else {
            throw failure(
                .invalidValue,
                path: "$.character.aliases",
                message: "Character aliases must be unique non-empty strings."
            )
        }
        guard value.relatedSuggestions.count <= NovelCharacterRelatedSuggestionKind.allCases.count,
              Set(value.relatedSuggestions.map(\.kind)).count == value.relatedSuggestions.count else {
            throw failure(
                .invalidValue,
                path: "$.relatedSuggestions",
                message: "Related setting suggestions may contain each supported kind at most once."
            )
        }
        for (index, suggestion) in value.relatedSuggestions.enumerated() {
            try required(suggestion.title, path: "$.relatedSuggestions[\(index)].title")
            try required(suggestion.content, path: "$.relatedSuggestions[\(index)].content")
        }
    }

    static func validate(_ value: NovelQuickStartSuggestionsV2) throws {
        guard value.schemaVersion == NovelQuickStartSuggestionsV2.legacySchemaVersion ||
                value.schemaVersion == NovelQuickStartSuggestionsV2.previousSchemaVersion ||
                value.schemaVersion == NovelQuickStartSuggestionsV2.currentSchemaVersion else {
            throw failure(
                .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned unsupported quick-start schema version \(value.schemaVersion)."
            )
        }
        try required(value.overview, path: "$.overview")
        let suggestions: [(String, NovelQuickStartSuggestionV1)] = [
            ("world", value.world),
            ("masterOutline", value.masterOutline),
            ("writingRequirements", value.writingRequirements)
        ]
        for (key, suggestion) in suggestions {
            try required(suggestion.title, path: "$.\(key).title")
            try required(suggestion.content, path: "$.\(key).content")
        }
        guard !value.characters.isEmpty else {
            throw failure(
                .invalidValue,
                path: "$.characters",
                message: "Quick Start must propose at least one independent character."
            )
        }
        for (index, character) in value.characters.enumerated() {
            try required(character.title, path: "$.characters[\(index)].title")
            try required(character.content, path: "$.characters[\(index)].content")
            if value.schemaVersion == NovelQuickStartSuggestionsV2.currentSchemaVersion {
                let aliases = NovelCharacterIdentityResolver.normalizedAliases(character.aliases ?? [])
                guard aliases.count == character.aliases?.count else {
                    throw failure(
                        .invalidValue,
                        path: "$.characters[\(index)].aliases",
                        message: "Character aliases must be unique non-empty strings."
                    )
                }
            }
        }
    }

    static func validate(_ value: NovelStateDeltaV1) throws {
        try schemaVersion(value.schemaVersion, expected: NovelStateDeltaV1.currentSchemaVersion)
        try required(value.stateSummary, path: "$.stateSummary")
        if let patch = value.branchOutlinePatch {
            try required(patch, path: "$.branchOutlinePatch")
        }
        try stateFacts(
            events: value.events,
            characters: value.characterChanges,
            relationships: value.relationshipChanges,
            foreshadowing: value.foreshadowingChanges,
            unresolvedEntityNames: value.unresolvedEntityNames,
            proposals: value.settingProposals
        )
    }

    static func validate(_ value: NovelStateRebuildV1) throws {
        try schemaVersion(value.schemaVersion, expected: NovelStateRebuildV1.currentSchemaVersion)
        try required(value.stateSummary, path: "$.stateSummary")
        try required(value.branchOutline, path: "$.branchOutline")
        try stateFacts(
            events: value.events,
            characters: value.characterStates,
            relationships: value.relationships,
            foreshadowing: value.foreshadowing,
            unresolvedEntityNames: value.unresolvedEntityNames,
            proposals: value.settingProposals
        )
    }

    static func validate(_ value: NovelPolishDriftV1) throws {
        try schemaVersion(value.schemaVersion, expected: NovelPolishDriftV1.currentSchemaVersion)
        var identifiers: Set<String> = []
        for (index, difference) in value.differences.enumerated() {
            let base = "$.differences[\(index)]"
            try identifier(difference.id, path: base + ".id", identifiers: &identifiers)
            try required(difference.summary, path: base + ".summary")
            try required(difference.sourceEvidence, path: base + ".sourceEvidence")
            try required(difference.candidateEvidence, path: base + ".candidateEvidence")
        }
        if value.compatible && !value.differences.isEmpty {
            throw failure(
                .invalidValue,
                path: "$.differences",
                message: "A compatible polish result cannot contain semantic differences."
            )
        }
        if !value.compatible && value.differences.isEmpty {
            throw failure(
                .invalidValue,
                path: "$.differences",
                message: "An incompatible polish result must describe at least one difference."
            )
        }
    }

    static func validate(
        _ value: NovelChapterPlanAcceptanceV1,
        enforceDecisionFlag: Bool = true
    ) throws {
        guard value.schemaVersion == NovelChapterPlanAcceptanceV1.legacySchemaVersion ||
            value.schemaVersion == NovelChapterPlanAcceptanceV1.currentSchemaVersion else {
            throw failure(
                .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned schema version \(value.schemaVersion); version \(NovelChapterPlanAcceptanceV1.currentSchemaVersion) is required."
            )
        }
        try required(value.summary, path: "$.summary")
        for (index, item) in value.missingMustHappen.enumerated() {
            try required(item, path: "$.missingMustHappen[\(index)]")
        }
        for (index, item) in value.forbiddenViolations.enumerated() {
            try required(item, path: "$.forbiddenViolations[\(index)]")
        }
        for (index, item) in value.obviousRepetition.enumerated() {
            try required(item, path: "$.obviousRepetition[\(index)]")
        }
        let hasViolation = !value.missingMustHappen.isEmpty || !value.forbiddenViolations.isEmpty
        if enforceDecisionFlag && value.accepted && hasViolation {
            throw failure(
                .invalidValue,
                path: "$",
                message: "An accepted chapter-plan result cannot list contract violations."
            )
        }
        if enforceDecisionFlag && !value.accepted && !hasViolation {
            throw failure(
                .invalidValue,
                path: "$",
                message: "A rejected chapter-plan result must list at least one violation."
            )
        }
    }

    static func validate(_ value: NovelChapterPlanProposalV1) throws {
        try schemaVersion(
            value.schemaVersion,
            expected: NovelChapterPlanProposalV1.currentSchemaVersion
        )
        try required(value.goalAndConflict, path: "$.goalAndConflict")
        if value.goalAndConflict.count > 8_000 {
            throw failure(
                .invalidValue,
                path: "$.goalAndConflict",
                message: "The chapter-plan goal is too long."
            )
        }
        if value.outlinePlacement.count > 500 {
            throw failure(
                .invalidValue,
                path: "$.outlinePlacement",
                message: "The chapter-plan placement note is too long."
            )
        }
        if value.endingHook.count > 4_000 {
            throw failure(
                .invalidValue,
                path: "$.endingHook",
                message: "The chapter-plan ending hook is too long."
            )
        }
        let mustHappen = NovelChapterPlanRecord.normalizedLines(value.mustHappen)
        let mustNotHappen = NovelChapterPlanRecord.normalizedLines(value.mustNotHappen)
        let visibleFacts = NovelChapterPlanRecord.normalizedLines(value.visibleFacts)
        guard !mustHappen.isEmpty else {
            throw failure(
                .invalidValue,
                path: "$.mustHappen",
                message: "A confirmed chapter plan requires at least one must-happen item."
            )
        }
        guard mustHappen.count <= 32, mustNotHappen.count <= 32, visibleFacts.count <= 32 else {
            throw failure(
                .invalidValue,
                path: "$",
                message: "The chapter plan has too many checklist items."
            )
        }
        for (index, item) in mustHappen.enumerated() {
            try required(item, path: "$.mustHappen[\(index)]")
        }
        for (index, item) in mustNotHappen.enumerated() {
            try required(item, path: "$.mustNotHappen[\(index)]")
        }
        for (index, item) in visibleFacts.enumerated() {
            try required(item, path: "$.visibleFacts[\(index)]")
        }
    }

    static func validate(
        _ value: NovelContinuityAuditV1,
        enforceDecisionFlag: Bool = true
    ) throws {
        try schemaVersion(
            value.schemaVersion,
            expected: NovelContinuityAuditV1.currentSchemaVersion
        )
        var identifiers: Set<String> = []
        for (index, issue) in value.issues.enumerated() {
            let base = "$.issues[\(index)]"
            try identifier(issue.id, path: base + ".id", identifiers: &identifiers)
            try required(issue.summary, path: base + ".summary")
            guard issue.references.count >= NovelContinuityAuditV1.minimumReferenceCount else {
                throw failure(
                    .invalidValue,
                    path: base + ".references",
                    message: "A continuity issue must cite at least \(NovelContinuityAuditV1.minimumReferenceCount) passages."
                )
            }
            for (referenceIndex, reference) in issue.references.enumerated() {
                let referencePath = base + ".references[\(referenceIndex)]"
                guard reference.chapterOrdinal >= 1 else {
                    throw failure(
                        .invalidValue,
                        path: referencePath + ".chapterOrdinal",
                        message: "Chapter ordinals start at 1."
                    )
                }
                try required(reference.chapterTitle, path: referencePath + ".chapterTitle")
                try required(reference.evidence, path: referencePath + ".evidence")
            }
        }
        if enforceDecisionFlag && value.consistent && !value.issues.isEmpty {
            throw failure(
                .invalidValue,
                path: "$.issues",
                message: "A consistent audit cannot report issues."
            )
        }
        if enforceDecisionFlag && !value.consistent && value.issues.isEmpty {
            throw failure(
                .invalidValue,
                path: "$.issues",
                message: "An inconsistent audit must describe at least one issue."
            )
        }
    }

    static func validate(_ value: NovelContinuityRepairV1) throws {
        try schemaVersion(
            value.schemaVersion,
            expected: NovelContinuityRepairV1.currentSchemaVersion
        )
        var identifiers: Set<String> = []
        for (index, patch) in value.patches.enumerated() {
            let base = "$.patches[\(index)]"
            try identifier(patch.issueId, path: base + ".issueId", identifiers: &identifiers)
            try required(patch.oldText, path: base + ".oldText")
            try required(patch.newText, path: base + ".newText")
            if patch.oldText == patch.newText {
                throw failure(
                    .invalidValue,
                    path: base,
                    message: "A continuity repair patch must change the cited text."
                )
            }
        }
    }

    static func validate(_ value: NovelChapterAdjudicationV1) throws {
        guard value.schemaVersion == NovelChapterAdjudicationV1.legacySchemaVersion ||
            value.schemaVersion == NovelChapterAdjudicationV1.currentSchemaVersion else {
            throw failure(
                .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned unsupported chapter-adjudication schema version \(value.schemaVersion)."
            )
        }
        if value.schemaVersion == NovelChapterAdjudicationV1.legacySchemaVersion,
           value.nextPlan != nil {
            throw failure(
                .invalidValue,
                path: "$.nextPlan",
                message: "Legacy chapter-adjudication output cannot contain nextPlan."
            )
        }
        // The outer host gates on concrete evidence arrays/issues. Summary booleans
        // are advisory in this combined pass and cannot block collection alone.
        try validate(value.acceptance, enforceDecisionFlag: false)
        try validate(value.continuity, enforceDecisionFlag: false)
        try validate(value.stateDelta)
        if let nextPlan = value.nextPlan {
            try validate(nextPlan)
            guard NovelChapterPlanRecord.normalizedLines(nextPlan.mustHappen).count <= 3 else {
                throw failure(
                    .invalidValue,
                    path: "$.nextPlan.mustHappen",
                    message: "An adjudication next plan may contain at most three must-happen items."
                )
            }
        }
    }

    static func validate(_ value: NovelDiscussionArchiveV1) throws {
        try schemaVersion(
            value.schemaVersion,
            expected: NovelDiscussionArchiveV1.currentSchemaVersion
        )
        guard !value.decisions.isEmpty else {
            throw failure(
                .invalidValue,
                path: "$.decisions",
                message: "A discussion archive must contain at least one decision."
            )
        }
        for (index, decision) in value.decisions.enumerated() {
            try required(decision.topic, path: "$.decisions[\(index)].topic")
            try required(decision.decision, path: "$.decisions[\(index)].decision")
            if let relatedMaterialID = decision.relatedMaterialID,
               UUID(uuidString: relatedMaterialID) == nil {
                throw failure(
                    .invalidReference,
                    path: "$.decisions[\(index)].relatedMaterialID",
                    message: "A related material ID must be a UUID."
                )
            }
        }
        try required(value.summary, path: "$.summary")
        guard value.summary.count <= 300 else {
            throw failure(
                .invalidValue,
                path: "$.summary",
                message: "A discussion archive summary must not exceed 300 characters."
            )
        }
    }

    private static func stateFacts(
        events: [NovelStateEventV1],
        characters: [NovelCharacterStateFactV1],
        relationships: [NovelRelationshipFactV1],
        foreshadowing: [NovelForeshadowingFactV1],
        unresolvedEntityNames: [String],
        proposals: [NovelSettingProposalDraftV1]
    ) throws {
        var identifiers: Set<String> = []
        for (index, event) in events.enumerated() {
            let base = "$.events[\(index)]"
            try identifier(event.id, path: base + ".id", identifiers: &identifiers)
            try required(event.kind, path: base + ".kind")
            try required(event.summary, path: base + ".summary")
            try required(event.evidence, path: base + ".evidence")
            try uniqueNames(event.entityReferences, path: base + ".entityReferences")
        }
        for (index, character) in characters.enumerated() {
            let base = "$.characterFacts[\(index)]"
            try identifier(character.id, path: base + ".id", identifiers: &identifiers)
            try required(character.characterName, path: base + ".characterName")
            try required(character.attribute, path: base + ".attribute")
            try required(character.value, path: base + ".value")
            try required(character.evidence, path: base + ".evidence")
        }
        for (index, relationship) in relationships.enumerated() {
            let base = "$.relationshipFacts[\(index)]"
            try identifier(relationship.id, path: base + ".id", identifiers: &identifiers)
            try required(relationship.sourceEntity, path: base + ".sourceEntity")
            try required(relationship.targetEntity, path: base + ".targetEntity")
            try required(relationship.relationship, path: base + ".relationship")
            try required(relationship.state, path: base + ".state")
            try required(relationship.evidence, path: base + ".evidence")
            if normalized(relationship.sourceEntity) == normalized(relationship.targetEntity) {
                throw failure(
                    .invalidReference,
                    path: base,
                    message: "A relationship must reference two different entities."
                )
            }
        }
        for (index, thread) in foreshadowing.enumerated() {
            let base = "$.foreshadowingFacts[\(index)]"
            try identifier(thread.id, path: base + ".id", identifiers: &identifiers)
            try required(thread.thread, path: base + ".thread")
            try required(thread.summary, path: base + ".summary")
            try required(thread.evidence, path: base + ".evidence")
        }
        for (index, proposal) in proposals.enumerated() {
            let base = "$.settingProposals[\(index)]"
            try identifier(proposal.id, path: base + ".id", identifiers: &identifiers)
            try required(proposal.title, path: base + ".title")
            try required(proposal.content, path: base + ".content")
            try required(proposal.evidence, path: base + ".evidence")
        }
        try uniqueNames(unresolvedEntityNames, path: "$.unresolvedEntityNames")
    }

    private static func schemaVersion(_ actual: Int, expected: Int) throws {
        guard actual == expected else {
            throw failure(
                .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned schema version \(actual); version \(expected) is required."
            )
        }
    }

    private static func required(_ value: String, path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure(
                .invalidValue,
                path: path,
                message: "The model output contains an empty required value at \(path)."
            )
        }
    }

    private static func identifier(
        _ value: String,
        path: String,
        identifiers: inout Set<String>
    ) throws {
        try required(value, path: path)
        guard value.count <= 128,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw failure(
                .invalidValue,
                path: path,
                message: "The model output contains an invalid identifier at \(path)."
            )
        }
        guard identifiers.insert(value).inserted else {
            throw failure(
                .duplicateIdentifier,
                path: path,
                message: "The model output repeats identifier '\(value)'."
            )
        }
    }

    private static func uniqueNames(_ values: [String], path: String) throws {
        var seen: Set<String> = []
        for (index, value) in values.enumerated() {
            try required(value, path: "\(path)[\(index)]")
            let key = normalized(value)
            guard seen.insert(key).inserted else {
                throw failure(
                    .invalidReference,
                    path: path,
                    message: "The model output repeats an entity reference at \(path)."
                )
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func failure(
        _ category: NovelStructuredOutputErrorCategory,
        path: String,
        message: String
    ) -> NovelStructuredOutputFailure {
        NovelStructuredOutputFailure(category: category, path: path, message: message)
    }
}
