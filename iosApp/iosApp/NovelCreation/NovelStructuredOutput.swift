import Foundation

enum NovelStructuredOutputDecoder {
    static func decodeCharacterProposal(from text: String) throws -> NovelCharacterProposalV1 {
        try decodeCharacterProposal(from: Data(text.utf8))
    }

    static func decodeCharacterProposal(from data: Data) throws -> NovelCharacterProposalV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateCharacterProposal(root.object)
        let value: NovelCharacterProposalV1 = try decode(
            NovelCharacterProposalV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeQuickStartSuggestions(
        from text: String
    ) throws -> NovelQuickStartSuggestionsV2 {
        try decodeQuickStartSuggestions(from: Data(text.utf8))
    }

    static func decodeQuickStartSuggestions(
        from data: Data
    ) throws -> NovelQuickStartSuggestionsV2 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateQuickStartSuggestions(root.object)
        let value: NovelQuickStartSuggestionsV2 = try decode(
            NovelQuickStartSuggestionsV2.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeStateDelta(from text: String) throws -> NovelStateDeltaV1 {
        try decodeStateDelta(from: Data(text.utf8))
    }

    static func decodeStateDelta(from data: Data) throws -> NovelStateDeltaV1 {
        try decodeFromObjectCandidates(data) { objectData in
            let root = try StrictJSON.rootObject(from: objectData)
            try StrictJSON.validateStateDelta(root.object)
            let value: NovelStateDeltaV1 = try decode(NovelStateDeltaV1.self, from: root.data)
            try NovelStructuredOutputValidation.validate(value)
            return value
        }
    }

    static func decodeStateRebuild(from text: String) throws -> NovelStateRebuildV1 {
        try decodeStateRebuild(from: Data(text.utf8))
    }

    static func decodeStateRebuild(from data: Data) throws -> NovelStateRebuildV1 {
        // Prefer the first object that fully validates. Models sometimes emit a
        // complete rebuild plus a trailer/duplicate object — local heal avoids
        // re-invoking the model over the same expensive manuscript chunk.
        try decodeFromObjectCandidates(data) { objectData in
            let root = try StrictJSON.rootObject(from: objectData)
            try StrictJSON.validateStateRebuild(root.object)
            let value: NovelStateRebuildV1 = try decode(NovelStateRebuildV1.self, from: root.data)
            try NovelStructuredOutputValidation.validate(value)
            return value
        }
    }

    /// Try each top-level JSON object candidate until `body` succeeds.
    private static func decodeFromObjectCandidates<T>(
        _ data: Data,
        _ body: (Data) throws -> T
    ) throws -> T {
        let candidates = try StrictJSON.objectCandidateDataList(from: data)
        var lastError: Error?
        for candidate in candidates {
            do {
                return try body(candidate)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NovelStructuredOutputFailure(
            category: .malformedJSON,
            path: "$",
            message: "The model returned malformed JSON."
        )
    }

    static func decodePolishDrift(from text: String) throws -> NovelPolishDriftV1 {
        try decodePolishDrift(from: Data(text.utf8))
    }

    static func decodePolishDrift(from data: Data) throws -> NovelPolishDriftV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validatePolishDrift(root.object)
        let value: NovelPolishDriftV1 = try decode(NovelPolishDriftV1.self, from: root.data)
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeChapterPlanAcceptance(from text: String) throws -> NovelChapterPlanAcceptanceV1 {
        try decodeChapterPlanAcceptance(from: Data(text.utf8))
    }

    static func decodeChapterPlanAcceptance(from data: Data) throws -> NovelChapterPlanAcceptanceV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateChapterPlanAcceptance(root.object)
        let value: NovelChapterPlanAcceptanceV1 = try decode(
            NovelChapterPlanAcceptanceV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeChapterAdjudication(from text: String) throws -> NovelChapterAdjudicationV1 {
        try decodeChapterAdjudication(from: Data(text.utf8))
    }

    static func decodeChapterAdjudication(from data: Data) throws -> NovelChapterAdjudicationV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateChapterAdjudication(root.object)
        let value: NovelChapterAdjudicationV1 = try decode(
            NovelChapterAdjudicationV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeChapterPlanProposal(from text: String) throws -> NovelChapterPlanProposalV1 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if NovelChapterPlanMarkdown.looksLike(trimmed) {
            let value = try NovelChapterPlanMarkdown.parse(trimmed)
            try NovelStructuredOutputValidation.validate(value)
            return value
        }
        return try decodeChapterPlanProposal(from: Data(text.utf8))
    }

    static func decodeChapterPlanProposal(from data: Data) throws -> NovelChapterPlanProposalV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateChapterPlanProposal(root.object)
        let value: NovelChapterPlanProposalV1 = try decode(
            NovelChapterPlanProposalV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeContinuityRepair(from text: String) throws -> NovelContinuityRepairV1 {
        try decodeContinuityRepair(from: Data(text.utf8))
    }

    static func decodeContinuityRepair(from data: Data) throws -> NovelContinuityRepairV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateContinuityRepair(root.object)
        let value: NovelContinuityRepairV1 = try decode(
            NovelContinuityRepairV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeContinuityAudit(from text: String) throws -> NovelContinuityAuditV1 {
        try decodeContinuityAudit(from: Data(text.utf8))
    }

    static func decodeContinuityAudit(from data: Data) throws -> NovelContinuityAuditV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateContinuityAudit(root.object)
        let value: NovelContinuityAuditV1 = try decode(
            NovelContinuityAuditV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func decodeDiscussionArchive(from text: String) throws -> NovelDiscussionArchiveV1 {
        try decodeDiscussionArchive(from: Data(text.utf8))
    }

    static func decodeDiscussionArchive(from data: Data) throws -> NovelDiscussionArchiveV1 {
        let root = try StrictJSON.rootObject(from: data)
        try StrictJSON.validateDiscussionArchive(root.object)
        let value: NovelDiscussionArchiveV1 = try decode(
            NovelDiscussionArchiveV1.self,
            from: root.data
        )
        try NovelStructuredOutputValidation.validate(value)
        return value
    }

    static func polishDriftVerdict(from text: String) -> NovelPolishDriftVerdict {
        polishDriftVerdict(from: Data(text.utf8))
    }

    static func polishDriftVerdict(from data: Data) -> NovelPolishDriftVerdict {
        do {
            let result = try decodePolishDrift(from: data)
            return result.compatible ? .compatible : .incompatible(result.differences)
        } catch let failure as NovelStructuredOutputFailure {
            return .invalidOutput(failure)
        } catch {
            return .invalidOutput(NovelStructuredOutputFailure(
                category: .malformedJSON,
                path: "$",
                message: "The polish drift check returned unreadable JSON."
            ))
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw map(error)
        } catch {
            throw NovelStructuredOutputFailure(
                category: .malformedJSON,
                path: "$",
                message: "The model returned unreadable JSON."
            )
        }
    }

    private static func map(_ error: DecodingError) -> NovelStructuredOutputFailure {
        switch error {
        case .keyNotFound(let key, let context):
            NovelStructuredOutputFailure(
                category: .missingField,
                path: StrictJSON.path(context.codingPath),
                message: "The model output is missing required field '\(key.stringValue)'."
            )
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            NovelStructuredOutputFailure(
                category: .typeMismatch,
                path: StrictJSON.path(context.codingPath),
                message: "The model output contains a value with the wrong type."
            )
        case .dataCorrupted(let context):
            NovelStructuredOutputFailure(
                category: .invalidValue,
                path: StrictJSON.path(context.codingPath),
                message: "The model output contains an unsupported value."
            )
        @unknown default:
            NovelStructuredOutputFailure(
                category: .malformedJSON,
                path: "$",
                message: "The model returned unreadable JSON."
            )
        }
    }
}
