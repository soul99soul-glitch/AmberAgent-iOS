import Foundation
@preconcurrency import Shared

/// Codex's /models currently lists routing models only. Image tool choices
/// are documented presets, not a claim that the account's catalog listed them.
enum IOSCodexModelCatalog {
    static let imagePresets: [(modelId: String, displayName: String)] = [
        ("gpt-image-2.5-sunburst", "GPT Image 2.5 Sunburst"),
        ("gpt-image-2.5-flare", "GPT Image 2.5 Flare"),
        ("gpt-image-2", "GPT Image 2"),
        (IOSCodexOAuthConstants.imageModelId, "Codex 生图 (ChatGPT)")
    ]

    static func isImageModelID(_ id: String) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id.hasPrefix("gpt-image-") || id.hasPrefix("chatgpt-image-")
            || id == IOSCodexOAuthConstants.imageModelId
    }

    static func models(discovered: [(modelId: String, displayName: String)]) -> [Model] {
        var seen = Set<String>()
        return (discovered + imagePresets).compactMap { item in
            guard seen.insert(item.modelId).inserted else { return nil }
            let image = isImageModelID(item.modelId)
            return Model(
                modelId: item.modelId, displayName: item.displayName,
                id: KotlinUuid.companion.random(), type: image ? .image : .chat,
                customHeaders: [], customBodies: [],
                inputModalities: image ? [.text, .image] : [],
                outputModalities: image ? [.image] : [],
                abilities: [], tools: Set<BuiltInTools>(), contextWindowTokens: nil, providerOverwrite: nil
            )
        }
    }
}
