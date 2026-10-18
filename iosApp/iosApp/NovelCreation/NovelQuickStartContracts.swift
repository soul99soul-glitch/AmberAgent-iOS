import Foundation

struct NovelQuickStartSuggestionV1: Codable, Equatable, Sendable {
    let title: String
    let content: String
    let aliases: [String]?

    init(title: String, content: String, aliases: [String]? = nil) {
        self.title = title
        self.content = content
        self.aliases = aliases
    }
}

struct NovelQuickStartSuggestionsV2: Codable, Equatable, Sendable {
    static let legacySchemaVersion = 1
    static let previousSchemaVersion = 2
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let overview: String
    let world: NovelQuickStartSuggestionV1
    let characters: [NovelQuickStartSuggestionV1]
    let masterOutline: NovelQuickStartSuggestionV1
    let writingRequirements: NovelQuickStartSuggestionV1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case overview
        case world
        case characters
        case masterOutline
        case writingRequirements
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        overview = try values.decode(String.self, forKey: .overview)
        world = try values.decode(NovelQuickStartSuggestionV1.self, forKey: .world)
        if schemaVersion == Self.legacySchemaVersion {
            characters = [try values.decode(NovelQuickStartSuggestionV1.self, forKey: .characters)]
        } else {
            characters = try values.decode([NovelQuickStartSuggestionV1].self, forKey: .characters)
        }
        masterOutline = try values.decode(NovelQuickStartSuggestionV1.self, forKey: .masterOutline)
        writingRequirements = try values.decode(
            NovelQuickStartSuggestionV1.self,
            forKey: .writingRequirements
        )
    }
}

enum NovelCharacterRelatedSuggestionKind: String, Codable, CaseIterable, Sendable {
    case relationship
    case world
    case plot
}

struct NovelCharacterRelatedSuggestionV1: Codable, Equatable, Sendable {
    let kind: NovelCharacterRelatedSuggestionKind
    let title: String
    let content: String
}

struct NovelCharacterProposalV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let character: NovelQuickStartSuggestionV1
    let relatedSuggestions: [NovelCharacterRelatedSuggestionV1]
}

/// Converts the incomplete Quick Start JSON stream into the same user-facing
/// section order used by the durable completion message. It never creates
/// proposal records; the full strict decoder remains the only commit gate.
