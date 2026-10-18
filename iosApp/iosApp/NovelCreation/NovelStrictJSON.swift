import CoreFoundation
import Foundation

enum StrictJSON {
    typealias Object = [String: Any]

    static func rootObject(from data: Data) throws -> (object: Object, data: Data) {
        // Callers that already pass a single-object blob, or non-state decoders
        // that only need "first extractable object", use the first candidate.
        let objectData = try singleObjectData(from: data)
        try JSONDuplicateKeyValidator.validate(objectData)
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: objectData)
        } catch {
            throw NovelStructuredOutputFailure(
                category: .malformedJSON,
                path: "$",
                message: "The model returned malformed JSON."
            )
        }
        guard let object = value as? Object else {
            throw NovelStructuredOutputFailure(
                category: .expectedObject,
                path: "$",
                message: "The model output must be one JSON object."
            )
        }
        return (object, objectData)
    }

    /// All complete top-level `{...}` objects found in model text, in order.
    /// Whole-buffer JSON wins as a single candidate (do not also split nested braces).
    static func objectCandidateDataList(from data: Data) throws -> [Data] {
        if let value = try? JSONSerialization.jsonObject(with: data) {
            // Valid whole-buffer JSON: object, array, or scalar.
            // Keep as one candidate so rootObject can classify non-objects as
            // `.expectedObject` instead of re-scanning into malformedJSON.
            if value is Object || !(value is NSNull) {
                return [data]
            }
        }

        let bytes = Array(data)
        var candidates: [Data] = []
        var index = bytes.startIndex

        while index < bytes.endIndex {
            guard bytes[index] == 0x7B,
                  let endIndex = balancedObjectEnd(in: bytes, startingAt: index) else {
                index += 1
                continue
            }

            let candidate = Data(bytes[index...endIndex])
            if let value = try? JSONSerialization.jsonObject(with: candidate),
               value is Object {
                candidates.append(candidate)
                index = endIndex + 1
            } else {
                index += 1
            }
        }

        guard !candidates.isEmpty else {
            throw NovelStructuredOutputFailure(
                category: .malformedJSON,
                path: "$",
                message: "The model returned malformed JSON."
            )
        }
        return candidates
    }

    private static func singleObjectData(from data: Data) throws -> Data {
        // Prefer the first complete object when the model emits extras after it.
        // Re-invoking the model over the same manuscript chunk is far more expensive
        // than accepting the first well-formed object (schema still fail-closes).
        try objectCandidateDataList(from: data)[0]
    }

    private static func balancedObjectEnd(
        in bytes: [UInt8],
        startingAt startIndex: Int
    ) -> Int? {
        var depth = 0
        var isInsideString = false
        var index = startIndex

        while index < bytes.endIndex {
            let byte = bytes[index]
            if isInsideString {
                if byte == 0x5C {
                    index += 2
                    continue
                }
                if byte == 0x22 {
                    isInsideString = false
                }
            } else {
                switch byte {
                case 0x22:
                    isInsideString = true
                case 0x7B:
                    depth += 1
                case 0x7D:
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    static func validateQuickStartSuggestions(_ object: Object) throws {
        try keys(
            object,
            path: "$",
            required: [
                "schemaVersion", "overview", "world", "characters",
                "masterOutline", "writingRequirements"
            ]
        )
        guard let number = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else {
            throw typeFailure(path: "$.schemaVersion", expected: "an integer")
        }
        let version = number.intValue
        guard version == NovelQuickStartSuggestionsV2.legacySchemaVersion ||
                version == NovelQuickStartSuggestionsV2.previousSchemaVersion ||
                version == NovelQuickStartSuggestionsV2.currentSchemaVersion else {
            throw NovelStructuredOutputFailure(
                category: .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned an unsupported quick-start schema version."
            )
        }
        try string(object["overview"], path: "$.overview")
        for key in ["world", "masterOutline", "writingRequirements"] {
            guard let suggestion = object[key] as? Object else {
                throw NovelStructuredOutputFailure(
                    category: .typeMismatch,
                    path: "$.\(key)",
                    message: "The quick-start suggestion at $.\(key) must be an object."
                )
            }
            try keys(
                suggestion,
                path: "$.\(key)",
                required: ["title", "content"],
                optional: ["title_cn"]
            )
            try string(suggestion["title"], path: "$.\(key).title")
            try string(suggestion["content"], path: "$.\(key).content")
            if let translationHint = suggestion["title_cn"], !(translationHint is NSNull) {
                throw NovelStructuredOutputFailure(
                    category: .invalidValue,
                    path: "$.\(key).title_cn",
                    message: "Quick Start only accepts an empty title translation hint."
                )
            }
        }
        let characters: [Object]
        if version == NovelQuickStartSuggestionsV2.legacySchemaVersion {
            guard let character = object["characters"] as? Object else {
                throw typeFailure(path: "$.characters", expected: "an object")
            }
            characters = [character]
        } else {
            guard let values = object["characters"] as? [Any] else {
                throw typeFailure(path: "$.characters", expected: "an array")
            }
            guard !values.isEmpty else {
                throw NovelStructuredOutputFailure(
                    category: .invalidValue,
                    path: "$.characters",
                    message: "Quick Start must propose at least one independent character."
                )
            }
            characters = try values.enumerated().map { index, value in
                guard let character = value as? Object else {
                    throw typeFailure(path: "$.characters[\(index)]", expected: "an object")
                }
                return character
            }
        }
        for (index, character) in characters.enumerated() {
            let path = version == NovelQuickStartSuggestionsV2.legacySchemaVersion
                ? "$.characters"
                : "$.characters[\(index)]"
            let requiredKeys: Set<String> = version == NovelQuickStartSuggestionsV2.currentSchemaVersion
                ? ["title", "content", "aliases"]
                : ["title", "content"]
            try keys(
                character,
                path: path,
                required: requiredKeys,
                optional: ["title_cn"]
            )
            try string(character["title"], path: path + ".title")
            try string(character["content"], path: path + ".content")
            if let translationHint = character["title_cn"], !(translationHint is NSNull) {
                throw NovelStructuredOutputFailure(
                    category: .invalidValue,
                    path: path + ".title_cn",
                    message: "Quick Start only accepts an empty title translation hint."
                )
            }
            if version == NovelQuickStartSuggestionsV2.currentSchemaVersion {
                try stringArray(character["aliases"], path: path + ".aliases")
            }
        }
    }

    static func validateCharacterProposal(_ object: Object) throws {
        try keys(
            object,
            path: "$",
            required: ["schemaVersion", "character", "relatedSuggestions"]
        )
        try schemaVersion(
            object["schemaVersion"],
            expected: NovelCharacterProposalV1.currentSchemaVersion
        )
        guard let character = object["character"] as? Object else {
            throw typeFailure(path: "$.character", expected: "an object")
        }
        try keys(
            character,
            path: "$.character",
            required: ["title", "content", "aliases"]
        )
        try string(character["title"], path: "$.character.title")
        try string(character["content"], path: "$.character.content")
        try stringArray(character["aliases"], path: "$.character.aliases")
        try objectArray(
            object["relatedSuggestions"],
            path: "$.relatedSuggestions",
            requiredKeys: ["kind", "title", "content"]
        ) { item, path in
            try enumString(
                item["kind"],
                path: path + ".kind",
                allowed: Set(NovelCharacterRelatedSuggestionKind.allCases.map(\.rawValue))
            )
            try string(item["title"], path: path + ".title")
            try string(item["content"], path: path + ".content")
        }
    }

    static func validateStateDelta(_ object: Object) throws {
        try keys(
            object,
            path: "$",
            required: [
                "schemaVersion", "stateSummary", "events", "characterChanges",
                "relationshipChanges", "foreshadowingChanges", "unresolvedEntityNames",
                "branchOutlinePatch", "settingProposals"
            ]
        )
        try schemaVersion(object["schemaVersion"], expected: NovelStateDeltaV1.currentSchemaVersion)
        try string(object["stateSummary"], path: "$.stateSummary")
        try eventArray(object["events"], path: "$.events")
        try characterArray(object["characterChanges"], path: "$.characterChanges")
        try relationshipArray(object["relationshipChanges"], path: "$.relationshipChanges")
        try foreshadowingArray(object["foreshadowingChanges"], path: "$.foreshadowingChanges")
        try stringArray(object["unresolvedEntityNames"], path: "$.unresolvedEntityNames")
        try nullableString(object["branchOutlinePatch"], path: "$.branchOutlinePatch")
        try proposalArray(object["settingProposals"], path: "$.settingProposals")
    }

    static func validateStateRebuild(_ object: Object) throws {
        try keys(
            object,
            path: "$",
            required: [
                "schemaVersion", "stateSummary", "branchOutline", "events", "characterStates",
                "relationships", "foreshadowing", "unresolvedEntityNames", "settingProposals"
            ]
        )
        try schemaVersion(object["schemaVersion"], expected: NovelStateRebuildV1.currentSchemaVersion)
        try string(object["stateSummary"], path: "$.stateSummary")
        try string(object["branchOutline"], path: "$.branchOutline")
        try eventArray(object["events"], path: "$.events")
        try characterArray(object["characterStates"], path: "$.characterStates")
        try relationshipArray(object["relationships"], path: "$.relationships")
        try foreshadowingArray(object["foreshadowing"], path: "$.foreshadowing")
        try stringArray(object["unresolvedEntityNames"], path: "$.unresolvedEntityNames")
        try proposalArray(object["settingProposals"], path: "$.settingProposals")
    }

    static func validatePolishDrift(_ object: Object) throws {
        try keys(object, path: "$", required: ["schemaVersion", "compatible", "differences"])
        try schemaVersion(object["schemaVersion"], expected: NovelPolishDriftV1.currentSchemaVersion)
        try boolean(object["compatible"], path: "$.compatible")
        try objectArray(
            object["differences"],
            path: "$.differences",
            requiredKeys: ["id", "category", "summary", "sourceEvidence", "candidateEvidence"]
        ) { item, path in
            try string(item["id"], path: path + ".id")
            try enumString(
                item["category"],
                path: path + ".category",
                allowed: Set(NovelPolishDifferenceCategoryV1.allCases.map(\.rawValue))
            )
            try string(item["summary"], path: path + ".summary")
            try string(item["sourceEvidence"], path: path + ".sourceEvidence")
            try string(item["candidateEvidence"], path: path + ".candidateEvidence")
        }
    }

    static func validateChapterPlanAcceptance(_ object: Object) throws {
        guard let number = object["schemaVersion"] as? NSNumber,
              floor(number.doubleValue) == number.doubleValue else {
            throw typeFailure(path: "$.schemaVersion", expected: "an integer")
        }
        let version = number.intValue
        guard version == NovelChapterPlanAcceptanceV1.legacySchemaVersion ||
            version == NovelChapterPlanAcceptanceV1.currentSchemaVersion else {
            throw NovelStructuredOutputFailure(
                category: .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned schema version \(version); version \(NovelChapterPlanAcceptanceV1.currentSchemaVersion) is required."
            )
        }
        if version == NovelChapterPlanAcceptanceV1.currentSchemaVersion {
            try keys(
                object,
                path: "$",
                required: [
                    "schemaVersion",
                    "accepted",
                    "missingMustHappen",
                    "forbiddenViolations",
                    "obviousRepetition",
                    "summary",
                ]
            )
        } else {
            try keys(
                object,
                path: "$",
                required: [
                    "schemaVersion",
                    "accepted",
                    "missingMustHappen",
                    "forbiddenViolations",
                    "summary",
                ],
                optional: ["obviousRepetition"]
            )
        }
        try boolean(object["accepted"], path: "$.accepted")
        try string(object["summary"], path: "$.summary")
        try stringArray(object["missingMustHappen"], path: "$.missingMustHappen")
        try stringArray(object["forbiddenViolations"], path: "$.forbiddenViolations")
        if object["obviousRepetition"] != nil {
            try stringArray(object["obviousRepetition"], path: "$.obviousRepetition")
        }
    }

    static func validateChapterPlanProposal(_ object: Object) throws {
        try keys(
            object,
            path: "$",
            required: [
                "schemaVersion",
                "outlinePlacement",
                "goalAndConflict",
                "mustHappen",
                "mustNotHappen",
                "endingHook",
                "visibleFacts",
            ]
        )
        try schemaVersion(
            object["schemaVersion"],
            expected: NovelChapterPlanProposalV1.currentSchemaVersion
        )
        try string(object["outlinePlacement"], path: "$.outlinePlacement")
        try string(object["goalAndConflict"], path: "$.goalAndConflict")
        try string(object["endingHook"], path: "$.endingHook")
        try stringArray(object["mustHappen"], path: "$.mustHappen")
        try stringArray(object["mustNotHappen"], path: "$.mustNotHappen")
        try stringArray(object["visibleFacts"], path: "$.visibleFacts")
    }

    static func validateContinuityRepair(_ object: Object) throws {
        try keys(object, path: "$", required: ["schemaVersion", "patches"])
        try schemaVersion(
            object["schemaVersion"],
            expected: NovelContinuityRepairV1.currentSchemaVersion
        )
        try objectArray(
            object["patches"],
            path: "$.patches",
            requiredKeys: ["issueId", "oldText", "newText"]
        ) { item, path in
            try string(item["issueId"], path: path + ".issueId")
            try string(item["oldText"], path: path + ".oldText")
            try string(item["newText"], path: path + ".newText")
        }
    }

    static func validateContinuityAudit(_ object: Object) throws {
        try keys(object, path: "$", required: ["schemaVersion", "consistent", "issues"])
        try schemaVersion(
            object["schemaVersion"],
            expected: NovelContinuityAuditV1.currentSchemaVersion
        )
        try boolean(object["consistent"], path: "$.consistent")
        try objectArray(
            object["issues"],
            path: "$.issues",
            requiredKeys: ["id", "category", "severity", "summary", "references"]
        ) { item, path in
            try string(item["id"], path: path + ".id")
            try enumString(
                item["category"],
                path: path + ".category",
                allowed: Set(NovelContinuityIssueCategoryV1.allCases.map(\.rawValue))
            )
            try enumString(
                item["severity"],
                path: path + ".severity",
                allowed: Set(NovelContinuityIssueSeverityV1.allCases.map(\.rawValue))
            )
            try string(item["summary"], path: path + ".summary")
            try objectArray(
                item["references"],
                path: path + ".references",
                requiredKeys: ["chapterOrdinal", "chapterTitle", "evidence"]
            ) { reference, referencePath in
                try integer(reference["chapterOrdinal"], path: referencePath + ".chapterOrdinal")
                try string(reference["chapterTitle"], path: referencePath + ".chapterTitle")
                try string(reference["evidence"], path: referencePath + ".evidence")
            }
        }
    }

    static func validateChapterAdjudication(_ object: Object) throws {
        guard let number = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else {
            throw typeFailure(path: "$.schemaVersion", expected: "an integer")
        }
        let version = number.intValue
        guard version == NovelChapterAdjudicationV1.legacySchemaVersion ||
            version == NovelChapterAdjudicationV1.currentSchemaVersion else {
            throw NovelStructuredOutputFailure(
                category: .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned unsupported chapter-adjudication schema version \(version)."
            )
        }
        try keys(
            object,
            path: "$",
            required: ["schemaVersion", "acceptance", "continuity", "stateDelta"],
            optional: version == NovelChapterAdjudicationV1.currentSchemaVersion
                ? ["nextPlan"]
                : []
        )
        guard let acceptance = object["acceptance"] as? Object else {
            throw typeFailure(path: "$.acceptance", expected: "an object")
        }
        try validateChapterPlanAcceptance(acceptance)
        guard let continuity = object["continuity"] as? Object else {
            throw typeFailure(path: "$.continuity", expected: "an object")
        }
        try validateContinuityAudit(continuity)
        guard let stateDelta = object["stateDelta"] as? Object else {
            throw typeFailure(path: "$.stateDelta", expected: "an object")
        }
        try validateStateDelta(stateDelta)
        if let nextPlan = object["nextPlan"], !(nextPlan is NSNull) {
            guard let nextPlan = nextPlan as? Object else {
                throw typeFailure(path: "$.nextPlan", expected: "an object or null")
            }
            try validateChapterPlanProposal(nextPlan)
        }
    }

    static func validateDiscussionArchive(_ object: Object) throws {
        try keys(object, path: "$", required: ["schemaVersion", "decisions", "summary"])
        try schemaVersion(
            object["schemaVersion"],
            expected: NovelDiscussionArchiveV1.currentSchemaVersion
        )
        try objectArray(
            object["decisions"],
            path: "$.decisions",
            requiredKeys: ["topic", "decision"],
            optionalKeys: ["relatedMaterialID"]
        ) { item, path in
            try string(item["topic"], path: path + ".topic")
            try string(item["decision"], path: path + ".decision")
            if let relatedMaterialID = item["relatedMaterialID"] {
                try nullableString(relatedMaterialID, path: path + ".relatedMaterialID")
            }
        }
        try string(object["summary"], path: "$.summary")
    }

    static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("$") { result, key in
            if let index = key.intValue { return result + "[\(index)]" }
            return result + "." + key.stringValue
        }
    }

    private static func eventArray(_ value: Any?, path: String) throws {
        try objectArray(
            value,
            path: path,
            requiredKeys: ["id", "kind", "summary", "entityReferences", "evidence"]
        ) { item, itemPath in
            try string(item["id"], path: itemPath + ".id")
            try string(item["kind"], path: itemPath + ".kind")
            try string(item["summary"], path: itemPath + ".summary")
            try stringArray(item["entityReferences"], path: itemPath + ".entityReferences")
            try string(item["evidence"], path: itemPath + ".evidence")
        }
    }

    private static func characterArray(_ value: Any?, path: String) throws {
        try objectArray(
            value,
            path: path,
            requiredKeys: ["id", "characterName", "attribute", "value", "evidence"]
        ) { item, itemPath in
            try string(item["id"], path: itemPath + ".id")
            try string(item["characterName"], path: itemPath + ".characterName")
            try string(item["attribute"], path: itemPath + ".attribute")
            try string(item["value"], path: itemPath + ".value")
            try string(item["evidence"], path: itemPath + ".evidence")
        }
    }

    private static func relationshipArray(_ value: Any?, path: String) throws {
        try objectArray(
            value,
            path: path,
            requiredKeys: [
                "id", "sourceEntity", "targetEntity", "relationship", "state", "evidence"
            ]
        ) { item, itemPath in
            try string(item["id"], path: itemPath + ".id")
            try string(item["sourceEntity"], path: itemPath + ".sourceEntity")
            try string(item["targetEntity"], path: itemPath + ".targetEntity")
            try string(item["relationship"], path: itemPath + ".relationship")
            try string(item["state"], path: itemPath + ".state")
            try string(item["evidence"], path: itemPath + ".evidence")
        }
    }

    private static func foreshadowingArray(_ value: Any?, path: String) throws {
        try objectArray(
            value,
            path: path,
            requiredKeys: ["id", "thread", "status", "summary", "evidence"]
        ) { item, itemPath in
            try string(item["id"], path: itemPath + ".id")
            try string(item["thread"], path: itemPath + ".thread")
            try enumString(
                item["status"],
                path: itemPath + ".status",
                allowed: Set(NovelForeshadowingStatusV1.allCases.map(\.rawValue))
            )
            try string(item["summary"], path: itemPath + ".summary")
            try string(item["evidence"], path: itemPath + ".evidence")
        }
    }

    private static func proposalArray(_ value: Any?, path: String) throws {
        try objectArray(
            value,
            path: path,
            requiredKeys: ["id", "title", "content", "evidence"]
        ) { item, itemPath in
            try string(item["id"], path: itemPath + ".id")
            try string(item["title"], path: itemPath + ".title")
            try string(item["content"], path: itemPath + ".content")
            try string(item["evidence"], path: itemPath + ".evidence")
        }
    }

    private static func objectArray(
        _ value: Any?,
        path: String,
        requiredKeys: Set<String>,
        optionalKeys: Set<String> = [],
        validate: (Object, String) throws -> Void
    ) throws {
        guard let array = value as? [Any] else {
            throw typeFailure(path: path, expected: "an array")
        }
        for (index, element) in array.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard let object = element as? Object else {
                throw typeFailure(path: itemPath, expected: "an object")
            }
            try keys(
                object,
                path: itemPath,
                required: requiredKeys,
                optional: optionalKeys
            )
            try validate(object, itemPath)
        }
    }

    private static func stringArray(_ value: Any?, path: String) throws {
        guard let array = value as? [Any] else {
            throw typeFailure(path: path, expected: "an array")
        }
        for (index, element) in array.enumerated() {
            try string(element, path: "\(path)[\(index)]")
        }
    }

    private static func string(_ value: Any?, path: String) throws {
        guard value is String else {
            throw typeFailure(path: path, expected: "a string")
        }
    }

    private static func nullableString(_ value: Any?, path: String) throws {
        guard value is NSNull || value is String else {
            throw typeFailure(path: path, expected: "a string or null")
        }
    }

    private static func integer(_ value: Any?, path: String) throws {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else {
            throw typeFailure(path: path, expected: "an integer")
        }
    }

    private static func boolean(_ value: Any?, path: String) throws {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw typeFailure(path: path, expected: "a boolean")
        }
    }

    private static func enumString(
        _ value: Any?,
        path: String,
        allowed: Set<String>
    ) throws {
        try string(value, path: path)
        guard let rawValue = value as? String, allowed.contains(rawValue) else {
            throw NovelStructuredOutputFailure(
                category: .invalidValue,
                path: path,
                message: "The model output contains an unsupported value at \(path)."
            )
        }
    }

    private static func schemaVersion(_ value: Any?, expected: Int) throws {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else {
            throw typeFailure(path: "$.schemaVersion", expected: "an integer")
        }
        guard number.intValue == expected else {
            throw NovelStructuredOutputFailure(
                category: .unsupportedVersion,
                path: "$.schemaVersion",
                message: "The model returned schema version \(number.intValue); version \(expected) is required."
            )
        }
    }

    private static func keys(
        _ object: Object,
        path: String,
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let present = Set(object.keys)
        let missing = required.subtracting(present).sorted()
        if !missing.isEmpty {
            throw NovelStructuredOutputFailure(
                category: .missingField,
                path: path,
                message: "The model output is missing required fields: \(missing.joined(separator: ", "))."
            )
        }
        let unknown = present.subtracting(required.union(optional)).sorted()
        if !unknown.isEmpty {
            throw NovelStructuredOutputFailure(
                category: .unknownField,
                path: path,
                message: "The model output contains unknown fields: \(unknown.joined(separator: ", "))."
            )
        }
    }

    private static func typeFailure(
        path: String,
        expected: String
    ) -> NovelStructuredOutputFailure {
        NovelStructuredOutputFailure(
            category: .typeMismatch,
            path: path,
            message: "The model output must contain \(expected) at \(path)."
        )
    }
}

/// `JSONSerialization` accepts duplicate object keys and silently keeps one
/// value. Validate that narrow integrity property before Foundation decodes the
/// otherwise-valid JSON document.
